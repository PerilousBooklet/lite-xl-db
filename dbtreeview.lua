-- mod-version:3
local core = require "core"
local common = require "core.common"
local command = require "core.command"
local config = require "core.config"
local keymap = require "core.keymap"
local style = require "core.style"
local View = require "core.view"
local CommandView = require "core.commandview"

-- TODO: use custom database icons (connection, schema, table)

local DbTreeView = View:extend()

-- Merged into the same shared config table init.lua/tableview.lua/
-- queryconsoleview.lua all contribute to, following this plugin's
-- existing convention of one config.plugins.database_manager table
-- fed by common.merge from every file that cares about a slice of it.
config.plugins.database_manager = common.merge({
  tree_root_color = { name = style.text, hover = style.accent },
  tree_schema_color = { name = style.text, hover = style.accent },
  tree_table_color = { name = style.text, hover = style.accent },
  tree_message_color = style.dim,
  tree_error_color = { common.color "#fb4934" },

  -- Tells if the tree should start with schema nodes expanded once
  -- their tables are loaded (the root/connection node always starts
  -- expanded regardless -- an unexpandable root wouldn't be useful).
  tree_expanded = true,

  tree_size = 200 * SCALE, -- default panel width
}, config.plugins.database_manager)

local icon_small_font = style.icon_font:copy(10 * SCALE)


function DbTreeView:new()
  DbTreeView.super.new(self)
  self.scrollable = true
  self.focusable = false
  self.visible = false
  self.init_size = true
  self.focus_index = 0
  self.filter = ""
  self.hovered_item = nil

  -- last_connection is an identity token (whatever
  -- db.get_active_connection() returns) used purely to detect "the
  -- active connection changed since we last checked" -- see
  -- check_connection() below. It's intentionally not compared by
  -- label/kind: a fresh connection to the exact same database should
  -- still trigger a reload (e.g. tables may have changed).
  self.last_connection = nil

  -- The whole tree is exactly one root (the active connection),
  -- holding a list of schemas, each holding a list of tables. Distinct
  -- from an empty list, `schemas`/`tables` being nil means "not
  -- fetched yet" (or errored -- see the `error` field alongside it).
  self.root = {
    type = "root",
    name = "no active connection",
    expanded = true,
    schemas = nil,
    error = nil,
  }
end


-- Lazily required rather than at the top of the file: this file is
-- itself required unconditionally from the bottom of init.lua (see
-- the comment there), before init.lua has returned its module table.
-- Calling `require "plugins.db"` right here at file scope would hand
-- back Lua's circular-require sentinel instead of the real module, so
-- every access goes through this method instead, which is only ever
-- called later (from update()/each_item(), i.e. after init.lua has
-- finished loading).
local db_module = nil
local function get_db()
  db_module = db_module or require "plugins.db"
  return db_module
end


function DbTreeView:get_name()
  return "Database Tree"
end


function DbTreeView:set_target_size(axis, value)
  if axis == "x" then
    config.plugins.database_manager.tree_size = value
    return true
  end
end


function DbTreeView:get_item_height()
  return style.font:get_height() + style.padding.y
end


----------------------------------------------------------------
-- Data loading
----------------------------------------------------------------

-- (Re)fetches the schema list for the current connection from
-- scratch. Existing expand state on schemas that still exist after
-- the refresh is preserved (mirrors todotreeview's "copy expanded from
-- old items" step), so reconnecting to the same database doesn't
-- collapse everything you had open.
function DbTreeView:refresh_schemas()
  local db = get_db()
  local old_schemas = self.root.schemas

  self.root.error = nil
  self.root.schemas = nil

  if not db.get_active_connection() then
    self.root.error = "no active connection"
    return
  end

  db.list_schemas(function(schemas, err)
    if err then
      self.root.error = err
      return
    end

    local old_by_name = {}
    if old_schemas then
      for _, s in ipairs(old_schemas) do
        old_by_name[s.name] = s
      end
    end

    local list = {}
    for _, name in ipairs(schemas) do
      local old = old_by_name[name]
      list[#list + 1] = {
        type = "schema",
        name = name,
        expanded = old and old.expanded or false,
        tables = old and old.tables or nil,
        error = nil,
      }
    end
    self.root.schemas = list
    core.redraw = true
  end)
end


-- Lazily fetches the table list for `schema`, if it hasn't been
-- fetched already. Doesn't re-fetch on every expand -- use
-- "dbtreeview:refresh" (or reconnect) to pick up newly created tables.
function DbTreeView:load_tables(schema)
  if schema.tables or schema.loading then return end
  schema.loading = true
  local db = get_db()
  db.list_tables(schema.name, function(tables, err)
    schema.loading = false
    if err then
      schema.error = err
      return
    end
    local list = {}
    for _, name in ipairs(tables) do
      list[#list + 1] = { type = "table", name = name, schema = schema }
    end
    schema.tables = list
    core.redraw = true
  end)
end


-- Polls whether the active connection has changed since the last time
-- we looked, and kicks off a fresh schema fetch if so. Playing the
-- same role todotreeview's check_cache() (mtime comparison) plays,
-- just against connection identity instead of file modification time.
function DbTreeView:check_connection()
  local db = get_db()
  local conn = db.get_active_connection()
  if conn ~= self.last_connection then
    self.last_connection = conn
    self.root.name = db.get_active_connection_label() or "no active connection"
    self:refresh_schemas()
  end
end


----------------------------------------------------------------
-- Tree iteration (shared by draw() and mouse/keyboard hit-testing,
-- so they can never disagree about what's on screen)
----------------------------------------------------------------

function DbTreeView:each_item()
  self:check_connection()

  return coroutine.wrap(function()
    local ox, oy = self:get_content_offset()
    local y = oy + style.padding.y
    local w = self.size.x
    local h = self:get_item_height()

    coroutine.yield(self.root, ox, y, w, h)
    y = y + h

    if not self.root.expanded then return end

    if self.root.schemas then
      for _, schema in ipairs(self.root.schemas) do
        coroutine.yield(schema, ox, y, w, h)
        y = y + h

        if schema.expanded then
          if schema.tables then
            for _, tbl in ipairs(schema.tables) do
              local matches = #self.filter == 0
                or string.find(tbl.name:lower(), self.filter:lower(), 1, true)
              if matches then
                coroutine.yield(tbl, ox, y, w, h)
                y = y + h
              end
            end
            if #schema.tables == 0 then
              coroutine.yield({ type = "message", text = "(no tables)" }, ox, y, w, h)
              y = y + h
            end
          elseif schema.error then
            coroutine.yield({ type = "message", text = "Error: " .. schema.error }, ox, y, w, h)
            y = y + h
          else
            coroutine.yield({ type = "message", text = "Loading…" }, ox, y, w, h)
            y = y + h
          end
        end
      end
    elseif self.root.error then
      coroutine.yield({ type = "message", text = "Error: " .. self.root.error }, ox, y, w, h)
    else
      coroutine.yield({ type = "message", text = "Loading…" }, ox, y, w, h)
    end
  end)
end


function DbTreeView:get_item_by_index(index)
  local i = 0
  for item in self:each_item() do
    if index == i then return item end
    i = i + 1
  end
  return nil
end


function DbTreeView:get_index_of(target)
  local i = 0
  for item in self:each_item() do
    if item == target then return i end
    i = i + 1
  end
  return 0
end


-- Nearest expandable ancestor of `item`: a table's schema, or the root
-- for anything else. Used by the "collapse" command below to know
-- where to jump focus to when the current item has nothing left to
-- collapse itself.
function DbTreeView:get_parent(item)
  if item.type == "table" then
    return item.schema
  end
  return self.root
end


----------------------------------------------------------------
-- Mouse input
----------------------------------------------------------------

function DbTreeView:on_mouse_moved(px, py)
  self.hovered_item = nil
  for item, x, y, w, h in self:each_item() do
    if px > x and py > y and px <= x + w and py <= y + h then
      self.hovered_item = item
      break
    end
  end
end


-- Runs "SELECT * FROM "schema"."table" LIMIT <default_row_limit>"
-- against a table leaf. No-op for anything else (root/schema clicks
-- are handled as expand/collapse in on_mouse_pressed, not here).
function DbTreeView:goto_hovered_item()
  if not self.hovered_item or self.hovered_item.type ~= "table" then
    return
  end
  core.try(function()
    local item = self.hovered_item
    local db = get_db()
    local limit = config.plugins.database_manager.default_row_limit
    local full_name = db.quote_ident(item.schema.name) .. "." .. db.quote_ident(item.name)
    local sql = ("SELECT * FROM %s"):format(full_name)
    if limit then
      sql = sql .. (" LIMIT %d"):format(limit)
    end
    -- Deliberately not db.run_query here: that anchors the result off
    -- core.root_view:get_active_node(), which -- when triggered by a
    -- click in this very panel -- is this panel's own node. Targeting
    -- the primary node instead makes a table open like any ordinary
    -- file: a normal tab in the main editing area.
    local target_node = core.root_view:get_primary_node()
    db.open_query_in_node(sql, target_node)
  end)
end


function DbTreeView:on_mouse_pressed(button, x, y)
  if not self.hovered_item then
    return
  elseif self.hovered_item.type == "root" or self.hovered_item.type == "schema" then
    self.hovered_item.expanded = not self.hovered_item.expanded
    if self.hovered_item.type == "schema" and self.hovered_item.expanded then
      self:load_tables(self.hovered_item)
    end
  else
    self:goto_hovered_item()
  end
end


----------------------------------------------------------------
-- Update / layout
----------------------------------------------------------------

function DbTreeView:update()
  self.scroll.to.y = math.max(0, self.scroll.to.y)

  local dest = self.visible and config.plugins.database_manager.tree_size or 0
  if self.init_size then
    self.size.x = dest
    self.init_size = false
  else
    self:move_towards(self.size, "x", dest)
  end

  DbTreeView.super.update(self)
end


----------------------------------------------------------------
-- Drawing
----------------------------------------------------------------

function DbTreeView:draw()
  self:draw_background(style.background2)

  local icon_width = style.icon_font:get_width("D")
  local spacing = style.font:get_width(" ") * 2

  for item, x, y, w, h in self:each_item() do
    local cfg = config.plugins.database_manager
    local text_color = style.text

    if item.type == "root" then text_color = cfg.tree_root_color.name
    elseif item.type == "schema" then text_color = cfg.tree_schema_color.name
    elseif item.type == "table" then text_color = cfg.tree_table_color.name
    elseif item.type == "message" then
      text_color = item.text:match("^Error") and cfg.tree_error_color or cfg.tree_message_color
    end

    if item == self.hovered_item then
      renderer.draw_rect(x, y, w, h, style.line_highlight)
      if item.type == "root" then text_color = cfg.tree_root_color.hover
      elseif item.type == "schema" then text_color = cfg.tree_schema_color.hover
      elseif item.type == "table" then text_color = cfg.tree_table_color.hover
      end
    end

    local cx = x + style.padding.x

    if item.type == "root" then
      local icon = item.expanded and "-" or "+"
      common.draw_text(style.icon_font, text_color, icon, nil, cx, y, 0, h)
      cx = cx + style.padding.x
      common.draw_text(style.icon_font, text_color, "f", nil, cx, y, 0, h)
      cx = cx + icon_width

    elseif item.type == "schema" then
      cx = cx + style.padding.x * 0.75
      if item.expanded then
        common.draw_text(style.icon_font, text_color, "-", nil, cx, y, 0, h)
      else
        common.draw_text(icon_small_font, text_color, ">", nil, cx, y, 0, h)
      end
      cx = cx + icon_width / 2

    elseif item.type == "table" then
      cx = cx + style.padding.x * 1.5
      common.draw_text(style.icon_font, text_color, "i", nil, cx, y, 0, h)
      cx = cx + icon_width

    else -- "message": loading / error / empty placeholders, no icon
      cx = cx + style.padding.x * 1.5
    end

    cx = cx + spacing
    common.draw_text(style.font, text_color, item.name or item.text, nil, cx, y, 0, h)
  end
end


----------------------------------------------------------------
-- Keyboard navigation (scoped to when this view is focused)
----------------------------------------------------------------

function DbTreeView:update_scroll_position()
  local h = self:get_item_height()
  local _, min_y, _, max_y = self:get_content_bounds()
  local start_row = math.floor(min_y / h)
  local end_row = math.floor(max_y / h)
  if self.focus_index < start_row then
    self.scroll.to.y = self.focus_index * h
  end
  if self.focus_index + 1 > end_row then
    self.scroll.to.y = (self.focus_index * h) - self.size.y + h
  end
end


----------------------------------------------------------------
-- Init: create the view and split it into the layout immediately,
-- same as todotreeview.lua does for itself -- this is a persistent
-- panel, not something opened on demand.
----------------------------------------------------------------

local view = DbTreeView()
local node = core.root_view:get_active_node()
view.size.x = config.plugins.database_manager.tree_size
node:split("right", view, { x = true }, true)

core.status_view:add_item({
  predicate = function()
    return #view.filter > 0 and core.active_view and not core.active_view:is(CommandView)
  end,
  name = "dbtreeview:filter",
  alignment = core.status_view.Item.RIGHT,
  get_item = function()
    return {
      style.text,
      string.format("Filter: %s", view.filter)
    }
  end,
  position = 1,
  tooltip = "Tables filtered by",
  separator = core.status_view.separator2
})


--------------
-- Commands --
--------------

local previous_view = nil

command.add(nil, {
  ["dbtreeview:toggle"] = function()
    view.visible = not view.visible
  end,

  ["dbtreeview:refresh"] = function()
    -- Forces a re-fetch even though check_connection() would normally
    -- consider nothing to have changed -- useful after creating a
    -- table on an already-open, already-expanded schema.
    view.last_connection = nil
    for _, schema in ipairs(view.root.schemas or {}) do
      schema.tables = nil
      schema.error = nil
    end
  end,

  ["dbtreeview:expand-items"] = function()
    view.root.expanded = true
    for _, schema in ipairs(view.root.schemas or {}) do
      schema.expanded = true
      view:load_tables(schema)
    end
  end,

  ["dbtreeview:hide-items"] = function()
    for _, schema in ipairs(view.root.schemas or {}) do
      schema.expanded = false
    end
  end,

  ["dbtreeview:toggle-focus"] = function()
    if not core.active_view:is(DbTreeView) then
      previous_view = core.active_view
      core.set_active_view(view)
      view.hovered_item = view:get_item_by_index(view.focus_index)
    else
      command.perform("dbtreeview:release-focus")
    end
  end,

  ["dbtreeview:filter-tables"] = function()
    local dbtree_focus = core.active_view:is(DbTreeView)
    local previous_filter = view.filter
    core.command_view:enter("Filter Tables", {
      text = view.filter,
      submit = function(text)
        view.filter = text
        if dbtree_focus then
          view.focus_index = 0
          view.hovered_item = view:get_item_by_index(view.focus_index)
          view:update_scroll_position()
        end
      end,
      suggest = function(text)
        view.filter = text
      end,
      cancel = function()
        view.filter = previous_filter
      end,
    })
  end,
})

command.add(
  function()
    return core.active_view:is(DbTreeView)
  end, {

  ["dbtreeview:previous"] = function()
    if view.focus_index > 0 then
      view.focus_index = view.focus_index - 1
      view.hovered_item = view:get_item_by_index(view.focus_index)
      view:update_scroll_position()
    end
  end,

  ["dbtreeview:next"] = function()
    local next_index = view.focus_index + 1
    local next_item = view:get_item_by_index(next_index)
    if next_item then
      view.focus_index = next_index
      view.hovered_item = next_item
      view:update_scroll_position()
    end
  end,

  ["dbtreeview:collapse"] = function()
    local item = view.hovered_item
    if not item then return end

    if item.type == "table" then
      view.hovered_item = item.schema
      view.focus_index = view:get_index_of(item.schema)
    elseif item.expanded then
      item.expanded = false
    else
      local parent = view:get_parent(item)
      view.hovered_item = parent
      view.focus_index = view:get_index_of(parent)
    end

    view:update_scroll_position()
  end,

  ["dbtreeview:expand"] = function()
    local item = view.hovered_item
    if not item or item.type == "table" or item.type == "message" then return end

    if item.expanded then
      command.perform("dbtreeview:next")
    else
      item.expanded = true
      if item.type == "schema" then
        view:load_tables(item)
      end
    end
  end,

  ["dbtreeview:open"] = function()
    view:goto_hovered_item()
  end,

  ["dbtreeview:release-focus"] = function()
    core.set_active_view(
      previous_view or core.root_view:get_primary_node().active_view
    )
    view.hovered_item = nil
  end,
})

keymap.add { ["ctrl+alt+d"] = "dbtreeview:toggle" }
keymap.add { ["ctrl+alt+e"] = "dbtreeview:expand-items" }
keymap.add { ["ctrl+alt+h"] = "dbtreeview:hide-items" }
keymap.add { ["ctrl+alt+f"] = "dbtreeview:filter-tables" }
keymap.add { ["up"]         = "dbtreeview:previous" }
keymap.add { ["down"]       = "dbtreeview:next" }
keymap.add { ["left"]       = "dbtreeview:collapse" }
keymap.add { ["right"]      = "dbtreeview:expand" }
keymap.add { ["return"]     = "dbtreeview:open" }
keymap.add { ["escape"]     = "dbtreeview:release-focus" }


return DbTreeView
