-- Postgres backend: shells out to the `psql` CLI, same rationale as
-- plugins.db.sqlite (no cross-platform native driver dependency).
-- Query results come back as CSV, parsed with plugins.db.csv.

local core = require "core"
local process = require "core.process"
local csv = require "plugins.db.csv"
local process_util = require "plugins.db.process_util"

---@class PostgresConnection
local PostgresConnection = {}
PostgresConnection.__index = PostgresConnection

---@class PostgresConnection.options
---@field host? string Defaults to "localhost".
---@field port? number Defaults to 5432.
---@field user? string Defaults to "postgres".
---@field password? string Sent via the PGPASSWORD env var, never on argv (so it won't show up in a process list). Omit to rely on .pgpass / trust auth.
---@field database? string Defaults to "postgres".
---@field psql_binary? string Override the executable name/path (defaults to "psql" on PATH).

---Creates a new Postgres connection handle. Like SQLiteConnection, this
---doesn't open a persistent session -- each query spawns its own `psql`
---process, since the CLI has no simple way to keep one alive for us.
---@param opts PostgresConnection.options
function PostgresConnection.new(opts)
  opts = opts or {}
  return setmetatable({
    host     = opts.host or "localhost",
    port     = opts.port or 5432,
    user     = opts.user or "postgres",
    password = opts.password,
    database = opts.database or "postgres",
    binary   = opts.psql_binary or "psql",
  }, PostgresConnection)
end

---Runs `sql` and returns (columns, rows) as parsed CSV, or
---(nil, nil, error_message) on failure.
---
---Same caveat as SQLiteConnection:query() -- this only avoids blocking
---the editor when called from inside a coroutine. Prefer :query_async().
---@param sql string
---@return string[]|nil columns
---@return string[][]|nil rows
---@return string|nil err
function PostgresConnection:query(sql)
  local proc = process.start(
    {
      self.binary,
      "--csv", "--no-psqlrc", "--quiet",
      "-h", self.host,
      "-p", tostring(self.port),
      "-U", self.user,
      "-d", self.database,
      "-c", sql,
    },
    {
      stdout = process.REDIRECT_PIPE,
      stderr = process.REDIRECT_PIPE,
      -- Passed as a real env var (not a CLI argument), so it won't
      -- leak into `ps` output the way "-c PGPASSWORD=..." would.
      env = self.password and { PGPASSWORD = self.password } or nil,
    }
  )

  local out = process_util.read_all(proc, process.STREAM_STDOUT)
  local err = process_util.read_all(proc, process.STREAM_STDERR)
  local code = process_util.wait(proc, 30)

  if code ~= 0 then
    return nil, nil, (err ~= "" and err) or ("psql exited with code " .. tostring(code))
  end
  if out == "" then
    return {}, {}
  end

  local table_rows = csv.parse(out)
  local columns = table.remove(table_rows, 1) or {}
  return columns, table_rows
end

---Runs `sql` on a background coroutine (via core.add_thread) so the
---editor never blocks while `psql` runs, and reports the result
---through `callback(columns, rows, err)`.
---@param sql string
---@param callback fun(columns: string[]|nil, rows: string[][]|nil, err: string|nil)
function PostgresConnection:query_async(sql, callback)
  core.add_thread(function()
    local ok, columns, rows, err = pcall(PostgresConnection.query, self, sql)
    if not ok then
      callback(nil, nil, tostring(columns))
    else
      callback(columns, rows, err)
    end
  end)
end

return PostgresConnection
