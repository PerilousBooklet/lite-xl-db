-- Small compatibility layer around core.process, shared by the SQLite
-- and Postgres backends.
--
-- We deliberately avoid the higher-level proc.stdout/proc.stderr stream
-- objects and proc:wait() convenience method: those aren't present in
-- every lite-xl release (older versions' process.start() returns the
-- plain native process handle instead of a wrapped Lua object). What
-- IS present on every version we've checked is the lower-level
-- primitive the wrapper itself is built on: proc:read(fd, n),
-- proc:running() and proc:returncode(). Sticking to those directly
-- keeps this working regardless of which one you have installed.

local process_util = {}

---Reads a whole stream (process.STREAM_STDOUT / process.STREAM_STDERR)
---until the process closes it / exits, polling in a coroutine-friendly
---way (i.e. it yields instead of blocking when called from inside a
---coroutine such as one started with core.add_thread()).
---@param proc process
---@param fd integer process.STREAM_STDOUT or process.STREAM_STDERR
---@param poll_interval? number Seconds to yield between polls. Defaults to 1/30.
---@return string
function process_util.read_all(proc, fd, poll_interval)
  poll_interval = poll_interval or (1 / 30)
  local chunks = {}
  while true do
    local chunk = proc:read(fd, 65536)
    if chunk and #chunk > 0 then
      chunks[#chunks + 1] = chunk
    elseif not proc:running() then
      break
    elseif coroutine.isyieldable() then
      coroutine.yield(poll_interval)
    else
      -- Not inside a coroutine and nothing to read yet: bail out
      -- rather than spin/block the editor. Callers should always run
      -- this via core.add_thread() so this branch shouldn't normally
      -- be hit -- see SQLiteConnection:query_async / PostgresConnection:query_async.
      break
    end
  end
  return table.concat(chunks)
end

---Waits for `proc` to exit and returns its exit code, polling in a
---coroutine-friendly way. Returns nil if `timeout` seconds pass first.
---@param proc process
---@param timeout? number Seconds to wait before giving up. Defaults to 30.
---@param poll_interval? number Seconds to yield between polls. Defaults to 1/30.
---@return integer|nil
function process_util.wait(proc, timeout, poll_interval)
  timeout = timeout or 30
  poll_interval = poll_interval or (1 / 30)
  local start = system.get_time()
  while proc:running() do
    if system.get_time() - start > timeout then
      return nil
    end
    if coroutine.isyieldable() then
      coroutine.yield(poll_interval)
    end
  end
  return proc:returncode()
end

return process_util
