-- Supports UTF quotation marks, not just the ASCII versions.
-- thin-space-quotes.lua
-- Pandoc Lua filter: inserts a thin space (U+2009)
--   1. between consecutive single/double quotation marks
--      (nested: “‘text’”  ->  “ ‘text’ ”,  adjacent: “a”‘b’ -> “a” ‘b’)
--   2. between a quotation mark and a citation
--      (before or after, inside or outside the quotation)
--
-- It handles both
--   * quotes Pandoc parses as quotations (Quoted elements, e.g. from
--     straight quotes with the `smart` extension), and
--   * literal curly quotes in the text: “ ” ‘ ’
--
-- Usage: pandoc input.md --lua-filter=thin-space-quotes.lua -o output.pdf
-- (With LaTeX, use a Unicode engine such as xelatex or lualatex.)

local THIN = "\u{2009}"

-- Literal quote characters treated as quotation marks.
local QUOTES = {
  [0x201C] = true,  -- “
  [0x201D] = true,  -- ”
  [0x2018] = true,  -- ‘
  [0x2019] = true,  -- ’
}

local function thin() return pandoc.Str(THIN) end

local function is_quoted(el) return el ~= nil and el.t == "Quoted" end
local function is_cite(el)   return el ~= nil and el.t == "Cite" end
local function is_thin(el)   return el ~= nil and el.t == "Str" and el.text == THIN end

-- Does this inline begin / end with a quotation mark?
local function starts_with_quote(el)
  if el == nil then return false end
  if el.t == "Quoted" then return true end
  if el.t == "Str" and #el.text > 0 then
    return QUOTES[utf8.codepoint(el.text, 1)] or false
  end
  return false
end

local function ends_with_quote(el)
  if el == nil then return false end
  if el.t == "Quoted" then return true end
  if el.t == "Str" and #el.text > 0 then
    return QUOTES[utf8.codepoint(el.text, utf8.offset(el.text, -1))] or false
  end
  return false
end

-- Literal curly quotes touching each other inside one Str.
function Str(el)
  local out, prev_q, changed = {}, false, false
  for _, cp in utf8.codes(el.text) do
    local q = QUOTES[cp] or false
    if q and prev_q then
      out[#out + 1] = THIN
      changed = true
    end
    out[#out + 1] = utf8.char(cp)
    prev_q = q
  end
  if changed then return pandoc.Str(table.concat(out)) end
end

-- Edges of a Quoted element: a nested quote, a literal quote character,
-- or a citation touching the (writer-generated) opening/closing mark.
function Quoted(el)
  local c = el.content
  local first, last = c[1], c[#c]

  if is_cite(first) or starts_with_quote(first) then
    c:insert(1, thin())
  end
  if #c > 0 and (is_cite(last) or ends_with_quote(last)) then
    c:insert(thin())
  end

  el.content = c
  return el
end

-- Adjacent inlines: quote|quote, quote|cite, cite|quote
-- (a "quote" being a Quoted element or a Str edged by a curly quote).
-- Cite next to Cite is left alone.
function Inlines(inlines)
  local out = pandoc.List()
  local changed = false

  for i = 1, #inlines do
    local cur, nxt = inlines[i], inlines[i + 1]
    out:insert(cur)

    if nxt ~= nil and not is_thin(cur) and not is_thin(nxt) then
      local gap =
        (ends_with_quote(cur) and starts_with_quote(nxt)) or
        (ends_with_quote(cur) and is_cite(nxt))           or
        (is_cite(cur)         and starts_with_quote(nxt))
      if gap then
        out:insert(thin())
        changed = true
      end
    end
  end

  if changed then return out end
end
