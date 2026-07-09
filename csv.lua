-- Minimal CSV parser used to read the output of `sqlite3 -csv -header`
-- and `psql --csv`. Handles double-quoted fields, escaped quotes ("")
-- inside them, and embedded commas/newlines within quoted fields.

local csv = {}

---Parses a full CSV text blob into rows of string fields.
---@param text string
---@return string[][] rows
function csv.parse(text)
  local rows = {}
  local row = {}
  local field = {}
  local in_quotes = false
  local i, n = 1, #text

  local function push_field()
    row[#row + 1] = table.concat(field)
    field = {}
  end

  local function push_row()
    push_field()
    rows[#rows + 1] = row
    row = {}
  end

  while i <= n do
    local c = text:sub(i, i)
    if in_quotes then
      if c == '"' then
        if text:sub(i + 1, i + 1) == '"' then
          field[#field + 1] = '"'
          i = i + 1 -- skip the second quote of the "" escape
        else
          in_quotes = false
        end
      else
        field[#field + 1] = c
      end
    else
      if c == '"' then
        in_quotes = true
      elseif c == ',' then
        push_field()
      elseif c == '\r' then
        -- ignore; handled by the following \n (or a lone \r as EOL,
        -- which we treat the same as \n for simplicity)
      elseif c == '\n' then
        push_row()
      else
        field[#field + 1] = c
      end
    end
    i = i + 1
  end

  -- Flush a trailing row if the text didn't end with a newline.
  if #field > 0 or #row > 0 then
    push_row()
  end

  return rows
end

return csv
