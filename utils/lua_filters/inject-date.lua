--[[
  inject-date.lua
  ---------------
  Pandoc Lua filter (compatible with Pandoc 2.x and 3.x) that replaces the
  literal word  DATE  anywhere in YAML front-matter metadata with the current
  local date/time and timezone information.

  Replacement format example:
    2026-06-20 14:35:09 PKT (UTC+05:00)

  Usage:
    pandoc input.md --lua-filter inject-date.lua -o output.pdf

  Notes:
  • Only metadata is touched; body text is left unchanged.
  • Works for every metadata type: plain string values, nested maps, and lists.
  • DATE must appear as a complete YAML word to be replaced (e.g.  date: DATE
    or  label: "Report DATE"  — the latter replaces the substring).
--]]

-----------------------------------------------------------------------
-- 1. Build the replacement string once, at filter load time
-----------------------------------------------------------------------

--- Return the UTC offset as "+HH:MM" or "-HH:MM".
local function utc_offset_string()
  local now     = os.time()
  local local_t = os.date("*t",  now)   -- local broken-down time
  local utc_t   = os.date("!*t", now)   -- UTC broken-down time

  -- Minutes-since-start-of-year (sufficient for a same-moment comparison).
  local function to_mins(t)
    return t.yday * 1440 + t.hour * 60 + t.min
  end

  local delta = to_mins(local_t) - to_mins(utc_t)

  -- Handle year-boundary edge cases.
  if     local_t.year > utc_t.year then delta = delta + 527040
  elseif local_t.year < utc_t.year then delta = delta - 527040
  end

  local sign    = delta >= 0 and "+" or "-"
  delta         = math.abs(delta)
  return string.format("%s%02d:%02d", sign, math.floor(delta / 60), delta % 60)
end

--- Return the abbreviated local timezone name (e.g. "PKT", "EST").
--- Falls back to "local" on platforms where %Z is unavailable.
local function tz_name()
  local name = os.date("%Z")
  return (name and name ~= "") and name or "local"
end

-- Compose the full replacement string, e.g. "2026-06-20 14:35:09 PKT (UTC+05:00)"
local DATE_REPLACEMENT = string.format(
  "%s %s (UTC%s)",
  os.date("%Y-%m-%d %H:%M:%S"),
  tz_name(),
  utc_offset_string()
)

-----------------------------------------------------------------------
-- 2. Helpers to detect MetaValue kinds (Pandoc 2.x vs 3.x compatible)
-----------------------------------------------------------------------

--- True when the value is a MetaInlines / Inlines list.
local function is_inlines(v)
  if type(v) ~= "table" and type(v) ~= "userdata" then return false end
  -- Pandoc 2.x stores MetaInlines as a table with .t == "MetaInlines".
  -- Pandoc 3.x stores them as an Inlines userdata with metatable.__name == "Inlines".
  if type(v) == "table" and v.t == "MetaInlines" then return true end
  local mt = getmetatable(v)
  return mt ~= nil and mt.__name == "Inlines"
end

--- True when the value is a Pandoc 2.x MetaString.
local function is_meta_string(v)
  return type(v) == "table" and v.t == "MetaString"
end

--- True when the value is a MetaMap (nested YAML map).
--- In both Pandoc versions this is a plain Lua table without a special .t field.
local function is_meta_map(v)
  if type(v) ~= "table" then return false end
  if v.t then return false end   -- has a type tag → not a plain map
  local mt = getmetatable(v)
  -- MetaMaps have no metatable in Pandoc 2.x;
  -- in Pandoc 3.x they may have one but __name won't be "Inlines"/"List"/etc.
  if mt and mt.__name and mt.__name ~= "" then return false end
  return true
end

--- True when the value looks like a MetaList.
local function is_meta_list(v)
  if type(v) ~= "table" and type(v) ~= "userdata" then return false end
  if type(v) == "table" and v.t == "MetaList" then return true end
  local mt = getmetatable(v)
  return mt ~= nil and (mt.__name == "List" or mt.__name == "MetaList")
end

-----------------------------------------------------------------------
-- 3. Replace DATE inside an Inlines sequence
-----------------------------------------------------------------------

--- Walk a sequence of Inline elements; replace every Str "DATE" node.
--- Returns a new MetaInlines if anything changed, otherwise nil.
local function patch_inlines(inlines)
  local changed  = false
  local new_list = {}

  for i, el in ipairs(inlines) do
    if el.t == "Str" and el.text == "DATE" then
      new_list[i] = pandoc.Str(DATE_REPLACEMENT)
      changed = true
    elseif el.t == "Str" and el.text:find("DATE") then
      -- DATE is embedded inside a longer token (e.g. "Report-DATE").
      new_list[i] = pandoc.Str((el.text:gsub("DATE", DATE_REPLACEMENT)))
      changed = true
    else
      new_list[i] = el
    end
  end

  return changed and pandoc.MetaInlines(new_list) or nil
end

-----------------------------------------------------------------------
-- 4. Recursively patch any MetaValue
-----------------------------------------------------------------------

local patch_meta_value  -- forward declaration for mutual recursion

patch_meta_value = function(val)
  -- MetaInlines / Inlines
  if is_inlines(val) then
    return patch_inlines(val)

  -- Pandoc 2.x MetaString
  elseif is_meta_string(val) then
    if val.text == "DATE" then
      return pandoc.MetaString(DATE_REPLACEMENT)
    elseif val.text:find("DATE") then
      return pandoc.MetaString((val.text:gsub("DATE", DATE_REPLACEMENT)))
    end

  -- Nested YAML map
  elseif is_meta_map(val) then
    local dirty   = false
    local new_map = {}
    for k, v in pairs(val) do
      local patched = patch_meta_value(v)
      if patched ~= nil then
        new_map[k] = patched
        dirty = true
      else
        new_map[k] = v
      end
    end
    if dirty then return pandoc.MetaMap(new_map) end

  -- List of meta values
  elseif is_meta_list(val) then
    local dirty    = false
    local new_list = {}
    for i, v in ipairs(val) do
      local patched = patch_meta_value(v)
      if patched ~= nil then
        new_list[i] = patched
        dirty = true
      else
        new_list[i] = v
      end
    end
    if dirty then return pandoc.MetaList(new_list) end
  end

  return nil  -- no change needed
end

-----------------------------------------------------------------------
-- 5. Pandoc filter entry point
-----------------------------------------------------------------------

local function Meta(meta)
  local changed = false
  for key, val in pairs(meta) do
    local patched = patch_meta_value(val)
    if patched ~= nil then
      meta[key] = patched
      changed = true
    end
  end
  return changed and meta or nil
end

-- Pandoc calls filters by returning a list of filter tables.
return { { Meta = Meta } }
