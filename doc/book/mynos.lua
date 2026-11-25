-- mynos.lua: a pandoc filter, from the manual's Markdown (doc/manual) to
-- the LaTeX of the A5 book. One file = one chapter; build.sh passes:
--   MYNOS_BOOK_DATA  the directory with labels.txt, commands.txt, modules.txt
--   MYNOS_MANUAL     doc/manual (the screenshots are relative to it)
--   MYNOS_CHAPTER    this file's chapter: 1..24, or A..J
--
-- Three passes:
--   1. headings and code blocks, to the book's macros
--   2. text: cross-references get their page, terms go to the index
--   3. tables, figures, boxes

local stringify = pandoc.utils.stringify
local data = os.getenv('MYNOS_BOOK_DATA') or '.'
local manual = os.getenv('MYNOS_MANUAL') or '.'
local chapter = os.getenv('MYNOS_CHAPTER') or ''

local function set_from(file)
  local s = {}
  local f = io.open(data .. '/' .. file)
  if f then
    for l in f:lines() do s[l] = true end
    f:close()
  end
  return s
end
local labels = set_from('labels.txt')     -- ch:3, sec:3.1, ch:A, sec:A.1
local commands = set_from('commands.txt') -- cat, ls... (chapter 13)
local modules = set_from('modules.txt')   -- Mynos, Ipc... (chapter 24)
local glossary = {}                       -- appendix I's terms: lower case -> as written
for k in pairs(set_from('glossary.txt')) do glossary[pandoc.text.lower(k)] = k end

-- the text width, in points, for the code and the tables (A5, 115 mm,
-- a little less), and Courier's advance: every character 0.6 em
local TEXTW = tonumber(os.getenv('MYNOS_TEXTW') or '322')
-- the largest code, and the tables' two sizes (the second when the first
-- does not fit)
local CODESIZE = tonumber(os.getenv('MYNOS_CODESIZE') or '8')
local TABLESIZE = CODESIZE
local ADVANCE = 0.6
-- the text's average advance, and its space (Times)
local TEXT_ADV = 0.46
local SPACE_ADV = 0.25

local function ulen(s) return utf8.len(s) or #s end

local function tex(s)
  return (s:gsub('[\\{}%$&#%^_%%~]', function(c)
    if c == '\\' then return '\\textbackslash{}'
    elseif c == '^' then return '\\textasciicircum{}'
    elseif c == '~' then return '\\textasciitilde{}'
    else return '\\' .. c end
  end))
end

local function upper(s) return pandoc.text.upper(s) end

-- makeindex: ! @ | " are quoted with "
local function iq(s) return (s:gsub('[!@|"]', '"%0')) end
local function index(sortkey, shown, fmt)
  local e = iq(pandoc.text.lower(sortkey)) .. '@' .. iq(shown)
  if fmt then e = e .. '|' .. fmt end
  return '\\index{' .. e .. '}'
end

local function latex(blocks)
  return (pandoc.write(pandoc.Pandoc(blocks), 'latex'):gsub('%s+$', ''))
end
local function latex_inlines(inl) return latex({pandoc.Plain(inl)}) end

local function raw(s) return pandoc.RawBlock('latex', s) end
local function rawi(s) return pandoc.RawInline('latex', s) end

-- inline code that may break after / , ( . _ : (paths, signatures)
local function code_tex(s)
  local out = {}
  for _, cp in utf8.codes(s) do
    local c = utf8.char(cp)
    out[#out + 1] = (c == ' ') and '\\ ' or tex(c)
    if c:match('[/,%(_:]') then out[#out + 1] = '\\allowbreak{}' end
  end
  return '\\texttt{' .. table.concat(out) .. '}'
end
local function breakable(blocks)
  return pandoc.walk_block(pandoc.Div(blocks), {
    Code = function(c) return rawi(code_tex(c.text)) end }).content
end

------------------------------------------------------------------------
-- pass 1: headings, code blocks

local pass1 = {}

function pass1.Header(h)
  local s = stringify(h)
  if h.level == 1 then
    local n, t = s:match('^(%d+)%. (.*)$')
    if n then
      return raw(string.format('\\mynoschapter{%s}{%s.}{%s}{%s}',
        n, n, tex(upper(t)), tex(t)))
    end
    local a
    a, t = s:match('^Appendix (%u)%. (.*)$')
    if a then
      return raw(string.format('\\mynoschapter{%s}{APPENDIX %s.}{%s}{%s}',
        a, a, tex(upper(t)), tex(t)))
    end
    return raw('\\mynoschapter{}{}{' .. tex(upper(s)) .. '}{' .. tex(s) .. '}')
  elseif h.level == 2 then
    local n, t = s:match('^([%dA-J]+%.%d+) (.*)$')
    if not n then
      return raw('\\mynossection{}{' .. tex(upper(s)) .. '}{' .. tex(s) .. '}')
    end
    local extra = ''
    local name, kind = t:match('^([%w_%.]+)%((%d)%)$')
    if name and chapter == '24' then           -- a reference page
      local what = kind == '2' and ' (native calls)'
        or (name:match('^%u') and ' (module)' or ' (C library)')
      extra = index(name, tex(name) .. what, 'mynosdef')
      return raw(string.format('\\mynosrefpage{%s}{%s}{%s}%s',
        n, tex(upper(t)), tex(t), extra))
    end
    return raw(string.format('\\mynossection{%s}{%s}{%s}', n, tex(upper(t)), tex(t)))
  else
    local extra = ''
    if chapter == '13' then                    -- a command's entry
      local name = pandoc.text.lower(s:match('^(%S+)'))
      if name ~= '.' then
        extra = index(name, tex(name) .. ' (command)', 'mynosdef')
      end
    end
    return raw('\\mynosentry{' .. tex(s) .. '}' .. extra)
  end
end

-- each block as large as it can be, up to 8 pt, so that its longest line
-- fits: diagrams cannot wrap. Below 5.5 pt, the long lines wrap.
local function codeblock(cb, width)
  local text = cb.text:gsub('\t', '        ')
  local maxlen = 0
  for l in (text .. '\n'):gmatch('(.-)\n') do
    if ulen(l) > maxlen then maxlen = ulen(l) end
  end
  local size, brk = CODESIZE, 'false'
  if maxlen * ADVANCE * size > width then size = width / (ADVANCE * maxlen) end
  if size < 5.5 then size, brk = 5.5, 'true' end
  -- a diagram's lines touch (\\mynoscodelines: no extra space between
  -- them); a block whose lines wrap keeps the normal spacing, or its
  -- wrapped lines are printed over each other
  local fmt = brk == 'true' and '' or ',formatcom=\\mynoscodelines'
  local block = string.format(
    '\\begin{Verbatim}[fontsize=\\fontsize{%.2f}{%.2f}\\selectfont,breaklines=%s%s]\n%s\n\\end{Verbatim}',
    size, size * 1.12, brk, fmt, text)
  -- a diagram (box-drawing characters) stays on one page: in a minipage,
  -- which LaTeX does not break (a whole page is left for it if need be)
  if text:find('[\226][\148\149]') then
    block = '\\par\\noindent\\begin{minipage}{\\linewidth}\n' .. block ..
            '\n\\end{minipage}\\par\\smallskip'
  end
  return raw(block)
end
function pass1.CodeBlock(cb) return codeblock(cb, TEXTW) end

-- pass 0: a code block inside a box (a quotation, THE MyNOS FACTOR) has
-- the box's margins and rules less: 2 x 3 mm and about 6 pt
local pass0 = {}
function pass0.BlockQuote(q)
  return pandoc.walk_block(q, {
    CodeBlock = function(cb) return codeblock(cb, TEXTW - 24) end })
end

------------------------------------------------------------------------
-- pass 2: cross-references and the index

local pass2 = {}
local mentioned = {}

-- "chapter 17" -> "chapter 17, p. 203": the word, then the number
local prefixes = { chapter = true, chapters = true, appendix = true,
                   appendices = true, section = true, sections = true }

local function ref_key(tok)
  local num, rest = tok:match('^(%d+%.%d+)(.*)$')
  if not num then num, rest = tok:match('^(%u%.%d+)(.*)$') end
  if not num then num, rest = tok:match('^(%d+)(.*)$') end
  if not num then num, rest = tok:match('^(%u)(.*)$') end
  if not num or not rest:match('^[%)%],;:%.]*$') then return nil end
  local lab = (num:find('%.') and 'sec:' or 'ch:') .. num
  if labels[lab] then return lab, num, rest end
end

function pass2.Inlines(inl)
  local i = 1
  while i <= #inl do
    local el = inl[i]
    if el.t == 'Str' then
      local w = pandoc.text.lower((el.text:gsub('^%(', '')))
      local nx, nn = inl[i + 1], inl[i + 2]
      if prefixes[w] and nx and nx.t == 'Space' and nn and nn.t == 'Str' then
        local lab, num, rest = ref_key(nn.text)
        -- "section 3" is a section of the UNIX manual: only "section 3.1"
        if lab and w:match('^section') and lab:match('^ch:') then lab = nil end
        if lab then
          inl[i + 2] = pandoc.Str(num)
          inl:insert(i + 3, rawi('\\mynospage{' .. lab .. '}'))
          if rest ~= '' then inl:insert(i + 4, pandoc.Str(rest)) end
          i = i + 3
        end
      else
        -- a bare "(14.2)"
        local num, rest = el.text:match('^%((%d+%.%d+)([%),;:].*)$')
        if num and labels['sec:' .. num] then
          inl[i] = pandoc.Str('(' .. num)
          inl:insert(i + 1, rawi('\\mynospage{sec:' .. num .. '}'))
          inl:insert(i + 2, pandoc.Str(rest))
          i = i + 2
        end
      end
    end
    i = i + 1
  end
  return inl
end

-- a command or a module named in the text: indexed once per chapter
function pass2.Code(el)
  if chapter == '13' then return nil end
  local t = el.text
  local out = ''
  local w = t:match('^(%S+)')
  if w and commands[w] and not mentioned['c:' .. w] then
    mentioned['c:' .. w] = true
    out = out .. index(w, tex(w) .. ' (command)')
  end
  local m = t:match('^(%u[%w_]*)')
  if m and modules[m] and not mentioned['m:' .. m] then
    local after = t:sub(#m + 1, #m + 1)
    if after == '' or after == '.' or after == ' ' then
      mentioned['m:' .. m] = true
      out = out .. index(m, tex(m) .. ' (module)')
    end
  end
  if out ~= '' then return { el, rawi(out) } end
end

-- a term in bold, as the text defines it: to the index. Not the run-in
-- headings ("**Using the library.**"), nor the labels of the reference
-- entries.
local labels_bold = { Purpose = true, Syntax = true, Type = true,
  Description = true, Examples = true, Example = true, ['See also'] = true }

local stopwords = { the = true, a = true, an = true, its = true, to = true,
  ['in'] = true, with = true, without = true, ['not'] = true, before = true,
  one = true, all = true, at = true, on = true, it = true, this = true }

function pass2.Strong(el)
  local s = stringify(el)
  if s:match('[%.:%?!]$') or labels_bold[s] then return nil end
  local words = select(2, s:gsub('%S+', ''))
  if ulen(s) > 40 or words > 4 then return nil end
  local low = pandoc.text.lower(s)
  local key
  if glossary[low] then key = glossary[low]
  elseif glossary[(low:gsub('s$', ''))] then key = glossary[(low:gsub('s$', ''))]
  else
    if s == upper(s) and ulen(s) > 3 then return nil end   -- NAME, SYNOPSIS
    if s:match('[%(:]') or s:match('^[%-_]') then return nil end
    local first = pandoc.text.lower(s:match('^(%S+)'))
    if stopwords[first] or s:match('^%d+$') then return nil end
    local technical = s:match('[%u%d/_%.]', 2) or s:match('^%u%u')
    if words == 1 and not technical then return nil end
    key = s
  end
  return { el, rawi(index(key, tex(key))) }
end

function pass2.Strikeout(el)
  return { rawi('\\mynosstrike{'), table.unpack(el.content), rawi('}') }
end

------------------------------------------------------------------------
-- pass 3: tables, figures, boxes

local pass3 = {}

-- columns as wide as their text, when it fits; otherwise each gets its
-- longest word (at most 18 characters) and the rest is shared by need
function pass3.Table(t)
  local rows = {}
  for _, r in ipairs(t.head.rows) do rows[#rows + 1] = { r, true } end
  for _, b in ipairs(t.bodies) do
    for _, r in ipairs(b.body) do rows[#rows + 1] = { r, false } end
  end
  local ncol = #t.colspecs
  -- widths in em: a cell's whole text (nat), and its longest piece that
  -- cannot break (minw); code is Courier, the rest the text's face
  local function measure(blocks)
    local total, piece, longest = 0, 0, 0
    local function brk() if piece > longest then longest = piece end; piece = 0 end
    pandoc.walk_block(pandoc.Div(blocks), {
      Str = function(s) local w = ulen(s.text) * TEXT_ADV
              total = total + w; piece = piece + w end,
      Space = function() total = total + SPACE_ADV; brk() end,
      SoftBreak = function() total = total + SPACE_ADV; brk() end,
      Code = function(c)
        for _, cp in utf8.codes(c.text) do
          local ch = utf8.char(cp)
          total = total + ADVANCE; piece = piece + ADVANCE
          if ch == ' ' or ch:match('[,%(:]') then brk() end
        end
      end })
    brk()
    return total, longest
  end
  local nat, minw = {}, {}
  for c = 1, ncol do nat[c], minw[c] = 0.6, 0.6 end
  for _, rr in ipairs(rows) do
    for c, cell in ipairs(rr[1].cells) do
      local n, m = measure(cell.contents)
      if rr[2] then n, m = n * 1.1, m * 1.1 end        -- the header, bold
      -- a short cell (a number and a name) is not broken at all
      if n <= 16 * ADVANCE then m = n end
      if n > nat[c] then nat[c] = n end
      if m > minw[c] then minw[c] = m end
    end
  end
  local sep = 6                                 -- 2 \tabcolsep, in pt
  local function fit(sz)
    local avail = (TEXTW - sep * (ncol - 1)) / sz
    local w, sumnat, summin = {}, 0, 0
    for c = 1, ncol do
      minw[c] = math.min(minw[c], 24 * ADVANCE, nat[c])
      sumnat, summin = sumnat + nat[c], summin + minw[c]
    end
    if sumnat <= avail then
      for c = 1, ncol do w[c] = nat[c] end
      return w, true
    end
    local rem = avail - summin
    local need = sumnat - summin
    for c = 1, ncol do
      w[c] = minw[c] + (need > 0 and rem * (nat[c] - minw[c]) / need or 0)
    end
    return w, rem >= 0
  end
  local size = TABLESIZE
  local w, ok = fit(size)
  if not ok then size = TABLESIZE - 1; w = fit(size) end
  local spec = {}
  for c = 1, ncol do
    spec[c] = string.format('>{\\RaggedRight\\arraybackslash}p{%.1fpt}',
      math.max(w[c], 0.6) * size + 1)
  end
  local out = { string.format('{\\fontsize{%d}{%.1f}\\selectfont', size, size * 1.2),
    '\\begin{longtable}[l]{@{}' .. table.concat(spec) .. '@{}}', '\\toprule' }
  local head_done = false
  for _, rr in ipairs(rows) do
    local r, is_head = rr[1], rr[2]
    if not is_head and not head_done and #t.head.rows > 0 then
      out[#out + 1] = '\\midrule\\endhead'
      head_done = true
    end
    local cells = {}
    for c, cell in ipairs(r.cells) do
      local s = latex(breakable(cell.contents))
      if is_head then s = '\\textbf{' .. s .. '}' end
      cells[c] = s
    end
    out[#out + 1] = table.concat(cells, ' & ') .. ' \\\\'
  end
  out[#out + 1] = '\\bottomrule\n\\end{longtable}}'
  return raw(table.concat(out, '\n'))
end

-- "> **THE MyNOS FACTOR — Title.** text" -> a double-ruled box
function pass3.BlockQuote(q)
  local first = q.content[1]
  if first and first.t == 'Para' and first.content[1] and first.content[1].t == 'Strong' then
    local s = stringify(first.content[1])
    local title = s:match('^THE MyNOS FACTOR — (.*)$')
    if title then
      title = title:gsub('%.$', '')
      local inl = first.content
      inl:remove(1)
      while inl[1] and (inl[1].t == 'Space' or inl[1].t == 'SoftBreak') do inl:remove(1) end
      local body = pandoc.List(q.content)
      if #inl == 0 then body:remove(1) end
      return pandoc.List({ raw('\\FloatBarrier\\begin{mynosfactor}{' .. tex(title) .. '}') })
        .. body .. pandoc.List({ raw('\\end{mynosfactor}') })
    end
  end
  return pandoc.List({ raw('\\FloatBarrier\\begin{mynosquote}') }) .. pandoc.List(q.content)
    .. pandoc.List({ raw('\\end{mynosquote}') })
end

function pass3.HorizontalRule() return raw('\\mynosrule') end

-- an image alone in its paragraph, and its caption, the italic paragraph
-- after it ("*Figure 10-1. ...*")
function pass3.Blocks(blocks)
  local out = pandoc.List()
  local i = 1
  while i <= #blocks do
    local b = blocks[i]
    if b.t == 'Para' and #b.content == 1 and b.content[1].t == 'Image' then
      local img = b.content[1]
      local cap = latex_inlines(img.caption)
      local nb = blocks[i + 1]
      if nb and nb.t == 'Para' and nb.content[1] and nb.content[1].t == 'Emph'
         and stringify(nb):match('^Figure') then
        cap = latex_inlines(nb.content[1].content)
        i = i + 1
      end
      local path = manual .. '/' .. img.src
      out:insert(raw('\\mynosfigure{' .. path .. '}{' .. cap .. '}'))
    else
      out:insert(b)
    end
    i = i + 1
  end
  return out
end

------------------------------------------------------------------------
-- pass 4: the inline code left, breakable

local pass4 = {}
function pass4.Code(c) return rawi(code_tex(c.text)) end

return { pass0, pass1, pass2, pass3, pass4 }
