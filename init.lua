--mod-version:3
local core = require "core"
local config = require "core.config"
local common = require "core.common"
local command = require "core.command"
local keymap = require "core.keymap"
local style = require "core.style"

local SQLiteConnection   = require "plugins.db.backends.sqlite"
local PostgresConnection = require "plugins.db.backends.postgres"

local TableView = require "plugins.db.tableview"

-- TODO: add message (logs or right-side treeview ?) for when the current project db connection is not configured
-- TODO: add command to refresh a db connection (with fuzzy suggest to list connections and commandview to choose one)
-- TODO: store info about current connections in lua table in text file
-- TODO: add possibility of connecting to more than one db at the same time
--       (and showing data from both at the same time, in separate views)

-- TODO: le run delle query NON devono essere blocking (come faccio ?)

-- TODO: add treeview to show all tables; clicking on row item opens that table
-- TODO: 

-- TODO: add boolean variable (`is_prod = true/false`) to indicate if db treeview should be colored as RED
--       (look how intellij does it)
--       (instead of no custom color)
--       (add custom colors ?)

-- TODO: `db` and `lsp_sql` (with `sqls`) must share the DB connection details, maybe with `.lite_project.lua`
-- TODO: debugger integration: make sure you can place a breakpoint on a line that returns a complex composite
--       (assembled with multipled strings, ...) SQL query and ctrl+LMB click the query to be viewed separately

-- FUTURE_TODO: write a small C API to interact with the db (look at the official plugin template)
-- FUTURE_TODO: update messageview layout structure following Guldoman's Pockets PR

config.plugins.database_manager = common.merge({
  background_color  = style.background,
  -- Safety net for "db:open-table": avoids accidentally pulling
  -- millions of rows into a TableView that has no virtualization for
  -- horizontal content yet. Set to math.huge (or nil-out the LIMIT
  -- clause in run_query below) if you don't want a cap.
  default_row_limit = 200,
  -- Fraction of the origin node's height given to the result TableView
  -- when it's split open beneath a query (see open_result_view below).
  result_split_size = 0.35,
  -- Postgres only: pg_catalog/information_schema/pg_toast* are real
  -- schemas but rarely what you want cluttering a table browser. Flip
  -- this on to see them in the schema/table tree too. SQLite has no
  -- equivalent notion of "system schema" (main/temp are just schemas
  -- like any other), so this has no effect there.
  show_system_schemas = false,
}, config.plugins.database_manager)


-- Public module table. Returned at the end of this file so that other
-- files in the plugin (queryconsoleview.lua and dbtreeview.lua in
-- particular) can `require "plugins.db"` and drive the same
-- connection / query-running / introspection logic the commands below
-- use, instead of duplicating it.
local M = {}


---------------------------
-- Connection management --
---------------------------

-- This skeleton keeps exactly one "active" connection at a time, set by
-- either db:connect-sqlite or db:connect-postgres. A fuller
-- implementation could keep a named table of connections and let
-- commands pick which one to run against.
local active_connection = nil
local active_connection_label = nil -- for status/log messages only
local active_connection_kind = nil  -- "sqlite" | "postgres", drives the
                                    -- dialect-specific SQL in
                                    -- list_schemas/list_tables below


local function require_connection()
  if not active_connection then
    core.error('No active database connection. Run "Db: Connect Sqlite" or "Db: Connect Postgres" first.')
    return nil
  end
  return active_connection
end

-- Returned as-is (not just a boolean) so callers like DbTreeView can
-- use it as an identity token to detect "the connection changed"
-- across frames, without needing a separate notification mechanism.
function M.get_active_connection()
  return active_connection
end

function M.get_active_connection_label()
  return active_connection_label
end

function M.get_active_connection_kind()
  return active_connection_kind
end


-- Recursively checks whether `target` is still somewhere in the node
-- tree rooted at `node` -- used below to tell whether a node we saved
-- a reference to earlier has since been closed by the user (e.g. by
-- closing the last tab in it, which collapses/removes the node).
local function node_exists(node, target)
  if node == target then return true end
  if node.type ~= "leaf" then
    return node_exists(node.a, target) or node_exists(node.b, target)
  end
  return false
end

-- Remembers, per "origin" node (the node a query was run from), which
-- node its results were last split into -- so re-running a query from
-- the same console reuses that split instead of stacking a new one
-- underneath every time. Keyed weakly so closed/GC'd nodes don't leak.
local result_nodes = setmetatable({}, { __mode = "k" })

-- Opens `view` (typically a TableView) in a tab underneath
-- `origin_node` (the node a query was run from), splitting it open the
-- first time and reusing that same split on subsequent runs from the
-- same origin. Falls back to the current active node if origin_node
-- is nil or no longer part of the tree (e.g. it was closed while the
-- query was in flight).
function M.open_result_view(view, origin_node)
  local root_node = core.root_view.root_node
  local existing = origin_node and result_nodes[origin_node]

  if existing and node_exists(root_node, existing) then
    existing:add_view(view)
    return existing
  end

  local target = (origin_node and node_exists(root_node, origin_node))
    and origin_node
    or core.root_view:get_active_node()

  local result_node = target:split("down", view, config.plugins.database_manager.result_split_size)
  if origin_node then
    result_nodes[origin_node] = result_node
  end
  return result_node
end


-- Runs `sql` against the active connection and opens the results in a
-- new TableView, split open beneath the node the query was run from.
-- Both backends expose the same :query_async(sql, cb) shape, so this
-- code doesn't need to know or care which one is active.
--
-- `on_done`, if given, is called exactly once as `on_done(err)` after
-- the query finishes (err is nil on success). This exists so callers
-- like queryconsoleview.lua can show inline status instead of relying
-- solely on core.error/core.log.
local function run_query(sql, on_done)
  local conn = require_connection()
  if not conn then
    if on_done then on_done("no active database connection") end
    return
  end

  -- Captured now, synchronously, rather than inside the async
  -- callback below: by the time the query finishes the user may have
  -- switched tabs or split focus elsewhere, so "the active node/view"
  -- at that point would no longer mean "the one the query came from".
  local origin_node = core.root_view:get_active_node()
  local origin_view = core.active_view

  core.log('Running query against %s...', active_connection_label)
  conn:query_async(sql, function(columns, rows, err)
    if err then
      core.error("Query failed: %s", err)
      if on_done then on_done(err) end
      return
    end
    local db_view = TableView(columns, rows)
    M.open_result_view(db_view, origin_node)
    -- Keep focus on the query editor/console rather than the new
    -- result tab, so you can immediately tweak and re-run the query.
    if origin_view then
      core.set_active_view(origin_view)
    end
    core.log("Query returned %d row(s)", #rows)
    if on_done then on_done(nil) end
  end)
end
M.run_query = run_query

-- Runs `sql` and adds the result as a plain new tab in `target_node`
-- -- no split, no "refocus the view the query came from" behavior.
-- run_query/open_result_view above are built around the query
-- console's workflow (keep the query editor visible, reuse the same
-- split on reruns); this is for the opposite case, e.g. DbTreeView
-- opening a table: `core.root_view:get_active_node()` at that point
-- is the tree panel itself (it's what's focused when you click a row
-- in it), so anchoring off "the active node" would nest the result
-- inside the sidebar instead of the main editing area. Callers that
-- want ordinary "open like any other file" behavior should pass
-- `core.root_view:get_primary_node()` as target_node instead.
function M.open_query_in_node(sql, target_node, on_done)
  local conn = require_connection()
  if not conn then
    if on_done then on_done("no active database connection") end
    return
  end

  core.log('Running query against %s...', active_connection_label)
  conn:query_async(sql, function(columns, rows, err)
    if err then
      core.error("Query failed: %s", err)
      if on_done then on_done(err) end
      return
    end
    local db_view = TableView(columns, rows)
    target_node:add_view(db_view)
    core.set_active_view(db_view)
    core.log("Query returned %d row(s)", #rows)
    if on_done then on_done(nil) end
  end)
end


-------------------------------
-- Schema / table discovery --
-------------------------------

-- Quotes `name` as a SQL identifier. Double-quote identifier quoting
-- is valid standard SQL and both SQLite and Postgres accept it (unlike
-- e.g. backticks, which are MySQL-only), so one implementation covers
-- both backends here.
local function quote_ident(name)
  return '"' .. tostring(name):gsub('"', '""') .. '"'
end
M.quote_ident = quote_ident

-- Finds the index of a column named `name` in a `columns` list
-- returned by :query_async. Introspection queries below ask for a
-- specific column name but don't want to hard-code its position,
-- since that can shift depending on how a given backend/CLI happens
-- to order PRAGMA/information_schema output.
local function find_col(columns, name)
  for i, c in ipairs(columns) do
    if c == name then return i end
  end
  return nil
end

-- Lists the schemas visible on the active connection.
-- callback(schema_names, err) -- schema_names is a plain list of
-- strings on success, nil on failure (err explains why).
--
-- SQLite doesn't have "schemas" in the Postgres sense, but it does
-- have a real, if smaller, version of the same idea: "main", "temp",
-- and whatever else has been ATTACHed -- all listed by
-- `PRAGMA database_list`. Using that (rather than hard-coding "main")
-- means attached databases show up in the tree too, for free.
function M.list_schemas(callback)
  local conn = require_connection()
  if not conn then
    callback(nil, "no active database connection")
    return
  end

  local sql
  if active_connection_kind == "sqlite" then
    sql = "PRAGMA database_list;"
  elseif active_connection_kind == "postgres" then
    sql = "SELECT schema_name FROM information_schema.schemata"
    if not config.plugins.database_manager.show_system_schemas then
      sql = sql ..
        " WHERE schema_name NOT IN ('pg_catalog', 'information_schema')" ..
        " AND schema_name NOT LIKE 'pg_toast%' AND schema_name NOT LIKE 'pg_temp\\_%' ESCAPE '\\'"
    end
    sql = sql .. " ORDER BY schema_name;"
  else
    callback(nil, "unknown connection kind")
    return
  end

  conn:query_async(sql, function(columns, rows, err)
    if err then
      callback(nil, err)
      return
    end
    -- PRAGMA database_list -> "name" column; information_schema.schemata
    -- -> "schema_name". Fall back to the first column if neither
    -- matches, rather than failing outright on some CLI/driver
    -- quirk we haven't seen yet.
    local name_col = find_col(columns, "name") or find_col(columns, "schema_name") or 1
    local schemas = {}
    for _, row in ipairs(rows) do
      schemas[#schemas + 1] = row[name_col]
    end
    callback(schemas, nil)
  end)
end

-- Lists the tables in `schema` on the active connection.
-- callback(table_names, err), same shape as list_schemas above.
function M.list_tables(schema, callback)
  local conn = require_connection()
  if not conn then
    callback(nil, "no active database connection")
    return
  end
  if not schema or schema == "" then
    callback(nil, "no schema given")
    return
  end

  local sql
  if active_connection_kind == "sqlite" then
    -- Schema-qualifying sqlite_master (e.g. "main".sqlite_master) is
    -- what lets this work for attached databases too, not just "main".
    sql = ("SELECT name FROM %s.sqlite_master WHERE type = 'table' " ..
      "AND name NOT LIKE 'sqlite\\_%%' ESCAPE '\\' ORDER BY name;")
      :format(quote_ident(schema))
  elseif active_connection_kind == "postgres" then
    -- schema came from our own list_schemas() above (i.e. from the
    -- database itself, not hand-typed by the user), but it's still
    -- interpolated into a string literal here, so escape it properly
    -- rather than assuming it's safe.
    sql = ("SELECT table_name FROM information_schema.tables " ..
      "WHERE table_schema = '%s' ORDER BY table_name;")
      :format(schema:gsub("'", "''"))
  else
    callback(nil, "unknown connection kind")
    return
  end

  conn:query_async(sql, function(columns, rows, err)
    if err then
      callback(nil, err)
      return
    end
    local name_col = find_col(columns, "name") or find_col(columns, "table_name") or 1
    local tables = {}
    for _, row in ipairs(rows) do
      tables[#tables + 1] = row[name_col]
    end
    callback(tables, nil)
  end)
end


--------------
-- Commands --
--------------

command.add(nil, {
  ["db:connect-sqlite"] = function()
    -- TODO: if project module contains table with connection data, use that
    core.command_view:enter("SQLite Database File", {
      submit = function(path)
        active_connection = SQLiteConnection.new(common.home_expand(path))
        active_connection_label = "sqlite:" .. path
        active_connection_kind = "sqlite"
        core.log("Connected to SQLite database: %s", path)
      end,
      suggest = function(text)
        return common.home_encode_list(common.path_suggest(common.home_expand(text)))
      end,
    })
  end,

  -- Gathered one field at a time (rather than parsing a single
  -- "postgresql://user:pass@host:port/db" string) since the user/
  -- password portion of that URL is optional and genuinely ambiguous
  -- to disambiguate reliably with plain Lua patterns. This chain is a
  -- bit verbose but never guesses wrong.
  ["db:connect-postgres"] = function()
    -- TODO: if project module contains table with connection data, use that
    core.command_view:enter("Postgres Host", {
      text = "localhost",
      submit = function(host)
        core.command_view:enter("Postgres Port", {
          text = "5432",
          submit = function(port)
            core.command_view:enter("Postgres Database", {
              submit = function(database)
                core.command_view:enter("Postgres User", {
                  text = "postgres",
                  submit = function(user)
                    -- Note: CommandView has no password-masking mode,
                    -- so this is typed and displayed in the clear. Fine
                    -- for a local skeleton; consider a .pgpass file or
                    -- trust auth instead of typing real passwords here.
                    core.command_view:enter("Postgres Password (blank for none)", {
                      submit = function(password)
                        active_connection = PostgresConnection.new({
                          host = host,
                          port = tonumber(port),
                          database = database,
                          user = user,
                          password = password ~= "" and password or nil,
                        })
                        active_connection_label = ("postgres:%s@%s/%s"):format(user, host, database)
                        active_connection_kind = "postgres"
                        core.log('Connected to Postgres database "%s" on %s', database, host)
                      end,
                    })
                  end,
                })
              end,
            })
          end,
        })
      end,
    })
  end,

  ["db:run-query"] = function()
    if not require_connection() then return end
    core.command_view:enter("SQL Query", {
      submit = function(sql)
        run_query(sql)
      end,
    })
  end,

  -- Prompts for a table name and opens "SELECT * FROM <table>" (capped
  -- by config.plugins.database_manager.default_row_limit) in a new TableView. Table
  -- names are inserted as-is into the query text, same as any other
  -- hand-typed SQL here -- there's no separate escaping step, so this
  -- is meant for your own trusted input, not untrusted table names.
  ["db:open-table"] = function()
    if not require_connection() then return end
    core.command_view:enter("Table Name", {
      submit = function(table_name)
        local limit = config.plugins.database_manager.default_row_limit
        local sql = ("SELECT * FROM %s"):format(table_name)
        if limit then
          sql = sql .. (" LIMIT %d"):format(limit)
        end
        run_query(sql)
      end,
      -- WIP: add table name suggestions to `db:open-table`
      suggest = function()
        -- ?
      end
    })
  end,

  -- Opens a scratch SQL editor (queryconsoleview.lua) in a new tab.
  -- Required lazily, rather than at the top of this file, to avoid a
  -- circular require: queryconsoleview.lua itself does
  -- `require "plugins.db"` to call back into M.run_query.
  ["db:open-query-console"] = function()
    local QueryConsoleView = require "plugins.db.queryconsoleview"
    local view = QueryConsoleView(M)
    local root_node = core.root_view:get_active_node()
    root_node:add_view(view)
    core.set_active_view(view)
  end,
})


------------
-- Keymap --
------------

keymap.add({
  ["alt+z"] = "db:open-table",
  ["alt+shift+q"] = "db:open-query-console",
})


----------
-- Init --
----------
-- Nothing else to do at load time for the commands above: connections
-- are created lazily by db:connect-sqlite / db:connect-postgres, and
-- TableViews are only opened once a query actually runs.
--
-- dbtreeview.lua is the odd one out: unlike queryconsoleview.lua
-- (opened on demand by db:open-query-console) it follows
-- todotreeview.lua's convention of instantiating its view and
-- splitting it into the layout unconditionally as soon as the plugin
-- loads, rather than waiting for a command. It's required here, at
-- the very end of this file, rather than at the top: dbtreeview.lua
-- does `require "plugins.db"` internally (same as
-- queryconsoleview.lua) to call list_schemas/list_tables/run_query,
-- and by requiring it only after M has been fully built above, that
-- inner require resolves to this exact module table instead of
-- tripping over Lua's circular-require sentinel. dbtreeview.lua itself
-- is careful never to call into "plugins.db" synchronously while
-- *its* file-scope code runs (only later, from update()/each_item()),
-- which is what makes this safe in either require order.
require "plugins.db.dbtreeview"

return M
