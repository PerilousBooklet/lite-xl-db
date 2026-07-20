local core = require "core"
local common = require "core.common"
local config = require "core.config"
local command = require "core.command"
local keymap = require "core.keymap"
local style = require "core.style"

local Doc = require "core.doc"
local DocView = require "core.docview"


-- QueryConsoleView is a DocView subclass (not a plain View): the SQL
-- text area is a real Doc + the real DocView drawing/input code, so we
-- get selection, undo/redo, copy-paste, scrolling, etc. "for free" --
-- including all the built-in `doc:*` commands, since their predicates
-- just check `core.active_view:is(DocView)`, which a subclass passes.
--
-- On top of that we draw a fixed topbar strip (Run / Clear buttons,
-- connection label, status message) by temporarily shrinking
-- self.position/self.size before delegating to the real DocView
-- methods, then restoring them -- see with_content_area() below.
local QueryConsoleView = DocView:extend()

config.plugins.database_manager = common.merge({
  topbar_background      = style.background2,
  topbar_text_color       = style.text,
  topbar_dim_text_color   = style.dim,
  topbar_button_color     = style.background2,
  topbar_button_hover     = style.line_highlight or style.background3,
  topbar_button_text      = style.accent,
  status_ok_color         = { common.color "#8ec07c" },
  status_error_color      = { common.color "#fb4934" },
  status_info_color       = style.dim,
}, config.plugins.database_manager)


local function doc_get_all_text(doc)
  local last_line = #doc.lines
  local last_col = #doc.lines[last_line] and #doc.lines[last_line] + 1 or 1
  return doc:get_text(1, 1, last_line, last_col)
end


function QueryConsoleView:new(db)
  -- `db` is the module table returned by plugins/db/init.lua (has
  -- run_query / get_active_connection_label). Kept optional + lazily
  -- re-required in run_query() below so this file never has to be
  -- required at the top of init.lua (that would be circular, since
  -- init.lua requires this file too, from the db:open-query-console
  -- command).
  self.db = db

  local doc = Doc()
  QueryConsoleView.super.new(self, doc)

  -- Best-effort SQL syntax highlighting. Falls back silently to plain
  -- text if no "sql" language plugin/syntax is registered.
  core.try(function()
    local syntax = require "core.syntax"
    doc.syntax = syntax.get("query.sql") or doc.syntax
  end)

  self.topbar_font = style.font
  self.status_message = nil
  self.status_color = style.dim
  self.hovered_button = nil

  self.buttons = {
    {
      id = "run",
      label = "Run  (Ctrl+Enter)",
      accent = true,
      action = function() self:run_query() end,
    },
    {
      id = "clear",
      label = "Clear",
      action = function() self:clear_query() end,
    },
  }
end


function QueryConsoleView:get_name()
  return "Query Console"
end


----------------------------------------------------------------
-- Content-area offsetting (reserves space for the topbar)
----------------------------------------------------------------

function QueryConsoleView:get_topbar_height()
  return self.topbar_font:get_height() + style.padding.y * 2
end


-- Temporarily shrinks self.position/self.size to exclude the topbar
-- strip, calls `fn(self, ...)`, then restores the original values.
-- Used to delegate drawing/input/update to the real DocView methods
-- without them ever knowing about the topbar.
function QueryConsoleView:with_content_area(fn, ...)
  local topbar_h = self:get_topbar_height()
  local saved_y, saved_h = self.position.y, self.size.y
  self.position.y = saved_y + topbar_h
  self.size.y = math.max(saved_h - topbar_h, 0)
  local a, b, c, d = fn(self, ...)
  self.position.y, self.size.y = saved_y, saved_h
  return a, b, c, d
end


----------------------------------------------------------------
-- Query execution
----------------------------------------------------------------

function QueryConsoleView:set_status(message, kind)
  self.status_message = message
  if kind == "ok" then
    self.status_color = config.plugins.database_manager.status_ok_color
  elseif kind == "error" then
    self.status_color = config.plugins.database_manager.status_error_color
  else
    self.status_color = config.plugins.database_manager.status_info_color
  end
end


function QueryConsoleView:run_query()
  local sql = doc_get_all_text(self.doc):gsub("%s+$", "")
  if sql == "" then
    self:set_status("Nothing to run", "error")
    return
  end

  -- Lazily required: by the time a user clicks Run, init.lua has long
  -- since finished loading and cached its module table, so this is
  -- safe even though init.lua requires this file too.
  local db = self.db or require "plugins.db"

  self:set_status("Running…", "info")
  db.run_query(sql, function(err)
    if err then
      self:set_status("Error: " .. tostring(err), "error")
    else
      self:set_status("Query executed", "ok")
    end
  end)
end


function QueryConsoleView:clear_query()
  local last_line = #self.doc.lines
  local last_col = #self.doc.lines[last_line] + 1
  self.doc:remove(1, 1, last_line, last_col)
  self.doc:set_selection(1, 1)
  self:set_status(nil)
end


----------------------------------------------------------------
-- Topbar layout / drawing
----------------------------------------------------------------

-- Iterates the left-hand buttons, yielding (button, x, y, w, h) for
-- each one -- mirrors the layout helper pattern used by other view
-- topbars in this codebase.
function QueryConsoleView:each_button()
  local font = self.topbar_font
  local h = self:get_topbar_height()
  local x = self.position.x + style.padding.x
  local y = self.position.y
  local index = 0

  return function()
    index = index + 1
    local btn = self.buttons[index]
    if not btn then return end
    local w = font:get_width(btn.label) + style.padding.x * 2
    local bx = x
    x = x + w + style.padding.x
    return btn, bx, y, w, h
  end
end


function QueryConsoleView:draw_topbar()
  local cfg = config.plugins.database_manager
  local font = self.topbar_font
  local h = self:get_topbar_height()

  renderer.draw_rect(self.position.x, self.position.y, self.size.x, h, cfg.topbar_background)
  renderer.draw_rect(self.position.x, self.position.y + h - math.ceil(SCALE), self.size.x, math.ceil(SCALE), cfg.topbar_button_color)

  for btn, x, y, w, bh in self:each_button() do
    local bg = btn == self.hovered_button and cfg.topbar_button_hover or cfg.topbar_button_color
    renderer.draw_rect(x, y + style.padding.y / 2, w, bh - style.padding.y, bg)
    local text_color = btn.accent and cfg.topbar_button_text or cfg.topbar_text_color
    common.draw_text(font, text_color, btn.label, "center", x, y, w, bh)
  end

  -- Right side: status message (if any), then connection label.
  local conn_label = (self.db and self.db.get_active_connection_label and self.db.get_active_connection_label())
    or "no active connection"
  local right_x = self.position.x + self.size.x - style.padding.x

  local conn_w = font:get_width(conn_label)
  right_x = right_x - conn_w
  common.draw_text(font, cfg.topbar_dim_text_color, conn_label, "left", right_x, self.position.y, conn_w, h)

  if self.status_message then
    right_x = right_x - style.padding.x * 2
    local status_w = font:get_width(self.status_message)
    right_x = right_x - status_w
    common.draw_text(font, self.status_color, self.status_message, "left", right_x, self.position.y, status_w, h)
  end
end


function QueryConsoleView:draw()
  self:draw_background(config.plugins.database_manager.background_color or style.background)
  self:draw_topbar()
  self:with_content_area(QueryConsoleView.super.draw)
end


----------------------------------------------------------------
-- Input: topbar buttons vs. forwarding to the real DocView
----------------------------------------------------------------

function QueryConsoleView:on_mouse_pressed(button, x, y, clicks)
  local topbar_h = self:get_topbar_height()
  if y >= self.position.y and y < self.position.y + topbar_h then
    for btn, bx, by, bw, bh in self:each_button() do
      if x >= bx and x < bx + bw and y >= by and y < by + bh then
        btn.action()
        return true
      end
    end
    return true -- swallow clicks on empty topbar space too
  end
  return self:with_content_area(QueryConsoleView.super.on_mouse_pressed, button, x, y, clicks)
end


function QueryConsoleView:on_mouse_moved(x, y, dx, dy)
  local topbar_h = self:get_topbar_height()
  self.hovered_button = nil
  if y >= self.position.y and y < self.position.y + topbar_h then
    for btn, bx, by, bw, bh in self:each_button() do
      if x >= bx and x < bx + bw and y >= by and y < by + bh then
        self.hovered_button = btn
        break
      end
    end
  end
  -- Always forward too, so drag-selection started inside the text area
  -- keeps working even if the mouse briefly crosses into the topbar.
  return self:with_content_area(QueryConsoleView.super.on_mouse_moved, x, y, dx, dy)
end


function QueryConsoleView:on_mouse_released(button, x, y)
  return self:with_content_area(QueryConsoleView.super.on_mouse_released, button, x, y)
end


function QueryConsoleView:on_mouse_wheel(y, ...)
  return self:with_content_area(QueryConsoleView.super.on_mouse_wheel, y, ...)
end


function QueryConsoleView:update()
  return self:with_content_area(QueryConsoleView.super.update)
end


----------------------------------------------------------------
-- Ctrl+Enter to run, scoped to this view only
----------------------------------------------------------------

command.add(function()
  return core.active_view:is(QueryConsoleView)
end, {
  ["db-console:run"] = function()
    core.active_view:run_query()
  end,
})

keymap.add({
  ["ctrl+return"] = "db-console:run",
})


return QueryConsoleView
