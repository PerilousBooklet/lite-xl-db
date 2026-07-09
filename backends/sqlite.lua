-- SQLite backend: shells out to the `sqlite3` CLI rather than requiring
-- a compiled Lua binding (lite-xl plugins can't easily ship native
-- modules across platforms). Query results come back as CSV, which we
-- parse with plugins.db.csv.

local core = require "core"
local process = require "core.process"
local csv = require "plugins.db.csv"
local process_util = require "plugins.db.process_util"

---@class SQLiteConnection
local SQLiteConnection = {}
SQLiteConnection.__index = SQLiteConnection

---Creates a new SQLite connection handle.
---Nothing is actually opened yet -- `sqlite3` is invoked fresh for each
---query, since the CLI doesn't keep a persistent session for us anyway.
---@param path string Path to the .sqlite/.db file.
---@param sqlite3_binary? string Override the executable name/path (defaults to "sqlite3" on PATH).
function SQLiteConnection.new(path, sqlite3_binary)
  assert(type(path) == "string" and path ~= "", "SQLiteConnection.new requires a database file path")
  return setmetatable({
    path = path,
    binary = sqlite3_binary or "sqlite3",
  }, SQLiteConnection)
end

---Runs `sql` and returns (columns, rows) as parsed CSV, or
---(nil, nil, error_message) on failure.
---
---IMPORTANT: this reads/waits on the child process, which only yields
---properly (i.e. without blocking the editor) when called from inside
---a coroutine such as one started with core.add_thread(). Prefer
---:query_async() below unless you already know you're in a coroutine.
---@param sql string
---@return string[]|nil columns
---@return string[][]|nil rows
---@return string|nil err
function SQLiteConnection:query(sql)
  local proc = process.start(
    { self.binary, "-csv", "-header", "-batch", self.path, sql },
    { stdout = process.REDIRECT_PIPE, stderr = process.REDIRECT_PIPE }
  )

  local out = process_util.read_all(proc, process.STREAM_STDOUT)
  local err = process_util.read_all(proc, process.STREAM_STDERR)
  local code = process_util.wait(proc, 30)

  if code ~= 0 then
    return nil, nil, (err ~= "" and err) or ("sqlite3 exited with code " .. tostring(code))
  end
  if out == "" then
    return {}, {}
  end

  local table_rows = csv.parse(out)
  local columns = table.remove(table_rows, 1) or {}
  return columns, table_rows
end

---Runs `sql` on a background coroutine (via core.add_thread) so the
---editor never blocks while `sqlite3` runs, and reports the result
---through `callback(columns, rows, err)`.
---@param sql string
---@param callback fun(columns: string[]|nil, rows: string[][]|nil, err: string|nil)
function SQLiteConnection:query_async(sql, callback)
  core.add_thread(function()
    local ok, columns, rows, err = pcall(SQLiteConnection.query, self, sql)
    if not ok then
      -- `columns` holds the pcall error message in this branch
      callback(nil, nil, tostring(columns))
    else
      callback(columns, rows, err)
    end
  end)
end

return SQLiteConnection
