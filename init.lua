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

config.plugins.database_manager = common.merge({
  background_color  = style.background,
  -- Safety net for "db:open-table": avoids accidentally pulling
  -- millions of rows into a TableView that has no virtualization for
  -- horizontal content yet. Set to math.huge (or nil-out the LIMIT
  -- clause in run_query below) if you don't want a cap.
  default_row_limit = 200,
}, config.plugins.database_manager)


---------------------------
-- Connection management --
---------------------------

-- This skeleton keeps exactly one "active" connection at a time, set by
-- either db:connect-sqlite or db:connect-postgres. A fuller
-- implementation could keep a named table of connections and let
-- commands pick which one to run against.
local active_connection = nil
local active_connection_label = nil -- for status/log messages only


local function require_connection()
  if not active_connection then
    core.error('No active database connection. Run "Db: Connect Sqlite" or "Db: Connect Postgres" first.')
    return nil
  end
  return active_connection
end


-- Runs `sql` against the active connection and opens the results in a
-- new TableView. Both backends expose the same :query_async(sql, cb)
-- shape, so this code doesn't need to know or care which one is active.
local function run_query(sql)
  local conn = require_connection()
  if not conn then return end

  core.log('Running query against %s...', active_connection_label)
  conn:query_async(sql, function(columns, rows, err)
    if err then
      core.error("Query failed: %s", err)
      return
    end
    local root_node = core.root_view:get_active_node()
    local db_view = TableView(columns, rows)
    root_node:add_view(db_view)
    core.log("Query returned %d row(s)", #rows)
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
        print(sql)
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
    })
  end,
})


------------
-- Keymap --
------------

keymap.add({
  ["alt+z"] = "db:open-table",
})


----------
-- Init --
----------
-- Nothing else to do at load time: connections are created lazily by
-- db:connect-sqlite / db:connect-postgres, and TableViews are only
-- opened once a query actually runs.
