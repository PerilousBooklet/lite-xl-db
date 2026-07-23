local core = require "core"
local common = require "core.common"
local config = require "core.config"
local style = require "core.style"
local keymap = require "core.keymap"
local View = require "core.view"

local TableView = View:extend()

-- TODO: make cells resizable (including width of field title cells)
-- TODO: add context menu with actions for editing cells/rows/columns

-- TODO: bulk-edit of a table's rows
--       (es. copy a vertical/horizontal selection of cells, then paste it into another table)

-- TODO: add DDL read-only DocView for selected table
--       (look how intellij does it; show the SQL code that creates the table, for read-only DocView look at how scm does it)

config.plugins.database_manager = common.merge({
  background_color      = style.background,
  header_color          = style.background2,
  grid_line_color       = style.divider,
  text_color            = style.text,
  header_text_color     = style.accent,
  row_number_color      = style.background2,
  row_number_text_color = style.dim,
  min_column_width      = 120,
  min_zoom              = 0.5,
  max_zoom              = 3.0,
  zoom_step             = 0.1
}, config.plugins.database_manager)

function TableView:new(columns, rows)
  TableView.super.new(self)

  -- `columns` is a list of column names: { "id", "name", "email" }
  -- `rows` is a list of rows, each row a list of cell values: { {1, "Alice", "a@x.com"}, ... }
  self.columns = columns or {}
  self.rows = rows or {}

  self.scrollable = true
  self.column_widths = {}

  -- Zoom state: `zoom` is a multiplier applied to the base UI font size.
  -- We keep a dedicated font object (rather than mutating style.font)
  -- so other views/plugins aren't affected.
  self.zoom = 1
  self.base_font_size = style.font:get_size()
  self.font = style.font
  self.padding_x = style.padding.x
  self.padding_y = style.padding.y
  self.row_height = self.font:get_height() + self.padding_y

  -- Width of the fixed row-number gutter on the left. Recomputed
  -- alongside column widths whenever the font/zoom changes.
  self.row_number_width = 0

  self:recalculate_column_widths()
  self:recalculate_row_number_width()
end


function TableView:get_name()
  return "Table View"
end


-- Set the zoom level (clamped to configured min/max) and recompute
-- everything that depends on font size: the font itself, row height,
-- padding, column widths and the row-number gutter width.
function TableView:set_zoom(zoom)
  zoom = math.max(config.plugins.database_manager.min_zoom, math.min(config.plugins.database_manager.max_zoom, zoom))
  if zoom == self.zoom and self.font ~= style.font then
    return
  end
  self.zoom = zoom

  local new_size = math.max(1, math.floor(self.base_font_size * zoom + 0.5))
  self.font = style.font:copy(new_size)

  self.padding_x = style.padding.x * zoom
  self.padding_y = style.padding.y * zoom
  self.row_height = self.font:get_height() + self.padding_y

  self:recalculate_column_widths()
  self:recalculate_row_number_width()
end


function TableView:get_zoom()
  return self.zoom
end


-- Compute a width for each column based on header/content length and
-- a configurable minimum width. This is intentionally simple; a fuller
-- implementation could support user-resizable columns.
function TableView:recalculate_column_widths()
  local font = self.font
  local min_width = config.plugins.database_manager.min_column_width * self.zoom
  for i, col_name in ipairs(self.columns) do
    local width = font:get_width(tostring(col_name)) + self.padding_x * 2
    for _, row in ipairs(self.rows) do
      local cell = row[i]
      if cell then
        local w = font:get_width(tostring(cell)) + self.padding_x * 2
        if w > width then width = w end
      end
    end
    self.column_widths[i] = math.max(width, min_width)
  end
end


-- Width of the row-number gutter: wide enough for the largest row
-- number ("#rows") plus padding on both sides.
function TableView:recalculate_row_number_width()
  local widest_number = tostring(math.max(#self.rows, 1))
  self.row_number_width = self.font:get_width(widest_number) + self.padding_x * 2
end


-- Note: this deliberately still counts the header row (+1). The base
-- View clamps scroll.to.y to [0, get_scrollable_size() - size.y]; with
-- the header pinned in place (see draw() below), that's exactly the
-- max scroll needed to bring the last data row up to the bottom of the
-- view without leaving a gap, so this didn't need to change.
function TableView:get_scrollable_size()
  return self.row_height * (#self.rows + 1)
end


-- Total scrollable width: all data columns, plus the left padding
-- before them, plus the row-number gutter (which never scrolls, but
-- still needs to count towards what "fully scrolled right" means --
-- otherwise the base View's scroll-clamping formula would let the
-- last column be cut off by exactly the gutter's width).
function TableView:get_h_scrollable_size()
  return self:get_table_width() + self.padding_x + self.row_number_width
end


-- Ctrl + scroll wheel zooms the table in/out, mirroring the common
-- editor convention. Plain scrolling (including shift+wheel for
-- horizontal) still scrolls the view normally, since we only capture
-- the event here when zooming.
function TableView:on_mouse_wheel(y, ...)
  if keymap.modkeys["ctrl"] then
    self:set_zoom(self.zoom + (y > 0 and config.plugins.database_manager.zoom_step or -config.plugins.database_manager.zoom_step))
    return true
  end
  return TableView.super.on_mouse_wheel(self, y, ...)
end


function TableView:update()
  TableView.super.update(self)
end


-- Helper: total width of all columns combined
function TableView:get_table_width()
  local total = 0
  for _, w in ipairs(self.column_widths) do
    total = total + w
  end
  return total
end


-- `y` is always self.position.y here (see draw()) -- the header no
-- longer scrolls vertically. `x` still comes from the horizontally
-- scrolled content offset, so columns stay aligned with the rows
-- below when scrolled sideways.
function TableView:draw_header(x, y)
  local row_h = self.row_height
  local table_w = self:get_table_width()

  -- Header background
  renderer.draw_rect(x, y, table_w, row_h, config.plugins.database_manager.header_color)

  local cx = x
  for i, col_name in ipairs(self.columns) do
    local col_w = self.column_widths[i]

    common.draw_text(
      self.font,
      config.plugins.database_manager.header_text_color,
      tostring(col_name),
      "left",
      cx + self.padding_x,
      y,
      col_w - self.padding_x * 2,
      row_h
    )

    cx = cx + col_w
    -- Column separator. Drawn here (rather than relying on
    -- draw_grid_lines) because the header is now drawn in its own pass
    -- outside the clipped/scrolled row region -- see draw().
    renderer.draw_rect(cx - math.ceil(SCALE), y, math.ceil(SCALE), row_h, config.plugins.database_manager.grid_line_color)
  end

  -- Bottom border under header
  renderer.draw_rect(x, y + row_h - math.ceil(SCALE), table_w, math.ceil(SCALE), config.plugins.database_manager.grid_line_color)
end


function TableView:draw_rows(x, y)
  local row_h = self.row_height

  for r, row in ipairs(self.rows) do
    local row_y = y + r * row_h

    -- Skip rows fully outside the visible area (basic virtualization).
    -- The header now occupies the top row_h of the view permanently,
    -- so anything at/above that line doesn't need to be drawn -- it'd
    -- be clipped away regardless (see draw()).
    if row_y + row_h >= self.position.y + row_h and row_y <= self.position.y + self.size.y then
      local cx = x
      for c, col_w in ipairs(self.column_widths) do
        local cell_value = row[c]
        if cell_value ~= nil then
          common.draw_text(
            self.font,
            config.plugins.database_manager.text_color,
            tostring(cell_value),
            "left",
            cx + self.padding_x,
            row_y,
            col_w - self.padding_x * 2,
            row_h
          )
        end
        cx = cx + col_w
      end
    end
  end
end


-- Vertical column separators and horizontal row separators for the
-- *data* rows only. The header draws its own separators (see
-- draw_header) since it's rendered in a separate, unscrolled pass.
function TableView:draw_grid_lines(x, y)
  local table_h = self.row_height * (#self.rows + 1)
  local table_w = self:get_table_width()

  -- Vertical column separators
  local cx = x
  for _, col_w in ipairs(self.column_widths) do
    cx = cx + col_w
    renderer.draw_rect(cx - math.ceil(SCALE), y, math.ceil(SCALE), table_h, config.plugins.database_manager.grid_line_color)
  end

  -- Horizontal row separators
  for r = 1, #self.rows do
    local row_y = y + r * self.row_height
    renderer.draw_rect(x, row_y - math.ceil(SCALE), table_w, math.ceil(SCALE), config.plugins.database_manager.grid_line_color)
  end
end


-- Row-number gutter. `y` is the scrolled vertical content offset (same
-- as draw_rows gets) -- numbers scroll up/down with their rows -- but
-- it's always drawn at the view's fixed left edge (self.position.x),
-- so it never moves horizontally. See draw() for the clip that keeps
-- it out from under the header and pinned to the left.
function TableView:draw_row_numbers(y)
  local row_h = self.row_height
  local gx = self.position.x
  local gw = self.row_number_width

  renderer.draw_rect(gx, self.position.y + row_h, gw, math.max(self.size.y - row_h, 0), config.plugins.database_manager.row_number_color)

  for r = 1, #self.rows do
    local row_y = y + r * row_h
    if row_y + row_h >= self.position.y + row_h and row_y <= self.position.y + self.size.y then
      common.draw_text(
        self.font,
        config.plugins.database_manager.row_number_text_color,
        tostring(r),
        "right",
        gx + self.padding_x,
        row_y,
        gw - self.padding_x * 2,
        row_h
      )
    end
  end

  -- Divider line between the gutter and the scrollable columns
  renderer.draw_rect(gx + gw - math.ceil(SCALE), self.position.y + row_h, math.ceil(SCALE), math.max(self.size.y - row_h, 0), config.plugins.database_manager.grid_line_color)
end


-- Top-left corner cell: fixed both horizontally (like the gutter) and
-- vertically (like the header), so it's the one thing that never moves
-- no matter which way you scroll. Drawn last in draw() so it's always
-- on top of everything else.
function TableView:draw_corner()
  local row_h = self.row_height
  local gx, gy = self.position.x, self.position.y
  local gw = self.row_number_width

  renderer.draw_rect(gx, gy, gw, row_h, config.plugins.database_manager.header_color)
  common.draw_text(self.font, config.plugins.database_manager.header_text_color, "", "center", gx, gy, gw, row_h)

  renderer.draw_rect(gx, gy + row_h - math.ceil(SCALE), gw, math.ceil(SCALE), config.plugins.database_manager.grid_line_color)
  renderer.draw_rect(gx + gw - math.ceil(SCALE), gy, math.ceil(SCALE), row_h, config.plugins.database_manager.grid_line_color)
end


function TableView:draw()
  -- Draw background
  self:draw_background(config.plugins.database_manager.background_color)

  local ox, oy = self:get_content_offset()
  local row_h = self.row_height
  local gutter_w = self.row_number_width
  local x = ox + gutter_w -- scrollable column content start

  -- Row numbers: fixed horizontally, scroll vertically with the rows.
  -- Clipped to the area below the header, same reasoning as the rows.
  core.push_clip_rect(
    self.position.x,
    self.position.y + row_h,
    gutter_w,
    math.max(self.size.y - row_h, 0)
  )
  self:draw_row_numbers(oy)
  core.pop_clip_rect()

  -- Grid lines + data rows: scroll both ways. Clipped to the area
  -- below the header AND to the right of the row-number gutter, so
  -- scrolled content disappears behind both instead of over them.
  core.push_clip_rect(
    self.position.x + gutter_w,
    self.position.y + row_h,
    math.max(self.size.x - gutter_w, 0),
    math.max(self.size.y - row_h, 0)
  )
  self:draw_grid_lines(x, oy)
  self:draw_rows(x, oy)
  core.pop_clip_rect()

  -- Header: fixed vertically, scrolls horizontally with the columns.
  -- Clipped to the top strip, to the right of the gutter.
  core.push_clip_rect(
    self.position.x + gutter_w,
    self.position.y,
    math.max(self.size.x - gutter_w, 0),
    row_h
  )
  self:draw_header(x, self.position.y)
  core.pop_clip_rect()

  -- Corner: fixed both ways, drawn last so it's always on top of the
  -- header and the gutter where they'd otherwise meet.
  self:draw_corner()

  self:draw_scrollbar()
end


return TableView
