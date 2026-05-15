-- This module renders MR discussion threads as inline virtual lines directly
-- below the commented line in the Diffview reviewer buffers. It mirrors the
-- placement logic of `indicators.diagnostics` so it stays in sync with the
-- existing signs/diagnostics pipeline.

local u = require("gitlab.utils")
local diffview_lib = require("diffview.lib")
local indicators_common = require("gitlab.indicators.common")
local actions_common = require("gitlab.actions.common")
local List = require("gitlab.utils.list")
local state = require("gitlab.state")

local M = {}
local ns = vim.api.nvim_create_namespace("gitlab_inline_discussions")
M.namespace = ns

-- collapse_state[discussion_id] = true|false (explicit user choice; nil = use default)
M.collapse_state = {}
-- line_map[bufnr][1-based-line] = discussion_id (anchor lookup for keymaps)
M.line_map = {}
-- extmark_map[bufnr][discussion_id] = extmark_id
M.extmark_map = {}

-- Define default highlight groups with `default = true` so any user-defined
-- group of the same name overrides ours. These link to commonly-themed groups
-- that have subtle background shading on most colorschemes.
local function setup_highlights()
  local set = vim.api.nvim_set_hl
  -- Background groups (set fg + bg). These define the per-row tint.
  set(0, "GitlabDiscussionBody", { default = true, link = "CursorLine" })
  set(0, "GitlabDiscussionBodyAlt", { default = true, link = "ColorColumn" })
  set(0, "GitlabDiscussionSeparator", { default = true, link = "NonText" })
  set(0, "GitlabDiscussionFooter", { default = true, link = "Folded" })
  set(0, "GitlabDiscussionBorder", { default = true, link = "Comment" })
  set(0, "GitlabDiscussionCollapsed", { default = true, link = "Folded" })
  set(0, "GitlabDiscussionResolved", { default = true, link = "DiagnosticHint" })
  set(0, "GitlabDiscussionSystem", { default = true, link = "NonText" })
  -- Foreground-only groups layered on top of body bg via virt_lines'
  -- list-of-highlights support. Setting fg without bg preserves the bg color
  -- of the underlying body group.
  set(0, "GitlabDiscussionHeader", { default = true, link = "Identifier" })
  set(0, "GitlabDiscussionMention", { default = true, link = "Identifier" })
  set(0, "GitlabDiscussionCode", { default = true, link = "String" })
  set(0, "GitlabDiscussionLink", { default = true, link = "Underlined" })
  set(0, "GitlabDiscussionIssueRef", { default = true, link = "Number" })
  set(0, "GitlabDiscussionQuote", { default = true, link = "Comment" })
end
setup_highlights()
-- Re-apply on colorscheme change so links survive theme switches.
vim.api.nvim_create_autocmd("ColorScheme", {
  group = vim.api.nvim_create_augroup("gitlab.inline_discussions.hl", { clear = true }),
  callback = setup_highlights,
})

local function ensure_buf_tables(bufnr)
  M.line_map[bufnr] = M.line_map[bufnr] or {}
  M.extmark_map[bufnr] = M.extmark_map[bufnr] or {}
end

---Word-wrap a body of text to a max column width.
---@param text string
---@param max_width number
---@return string[]
local function wrap_text(text, max_width)
  local lines = {}
  for raw_line in (text .. "\n"):gmatch("([^\n]*)\n") do
    if raw_line == "" then
      table.insert(lines, "")
    else
      local current = ""
      for word in raw_line:gmatch("%S+") do
        if #current == 0 then
          current = word
        elseif #current + 1 + #word <= max_width then
          current = current .. " " .. word
        else
          table.insert(lines, current)
          current = word
        end
      end
      if #current > 0 then
        table.insert(lines, current)
      end
    end
  end
  return lines
end

---Find a discussion by id in the loaded state.
---@param id any
---@return table|nil
local function find_discussion(id)
  local list = u.ensure_table(state.DISCUSSION_DATA and state.DISCUSSION_DATA.discussions)
  for _, d in ipairs(list) do
    if d.id == id then
      return d
    end
  end
  local drafts = u.ensure_table(state.DRAFT_NOTES)
  for _, d in ipairs(drafts) do
    if d.id == id then
      return d
    end
  end
  return nil
end

---Decide whether a discussion should render collapsed.
---Explicit user toggle wins; otherwise resolved discussions auto-collapse,
---falling back to the configured default.
local function is_collapsed(d_or_n)
  local override = M.collapse_state[d_or_n.id]
  if override ~= nil then
    return override
  end
  -- Resolvable/resolved flags live on the first note of a discussion, not on
  -- the discussion object itself — matches how actions/discussions/tree.lua
  -- reads them when populating the bottom-panel tree.
  local first = indicators_common.get_first_note(d_or_n)
  if first.resolvable and first.resolved then
    return true
  end
  return state.settings.discussion_inline.default_collapsed
end

---Determine the render width for padding (full visible width of the window
---showing `bufnr`, falling back to half the editor width).
---@param bufnr number
---@return number
local function get_render_width(bufnr)
  for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
    if vim.api.nvim_win_is_valid(win) then
      return vim.api.nvim_win_get_width(win)
    end
  end
  return math.floor(vim.o.columns / 2)
end

-- Inline syntax patterns for body text. Order doesn't matter — we always pick
-- the leftmost match. Lua patterns, not regex.
local SYNTAX_PATTERNS = {
  { pat = "`[^`]+`", hl_key = "code" },
  { pat = "https?://[%w/%-_.~:?#@!&=+%%]+", hl_key = "link" },
  { pat = "@[%w._%-]+", hl_key = "mention" },
  { pat = "[#!]%d+", hl_key = "issue_ref" },
}

---Tokenise a single body line into segments suitable for layered highlights.
---Each segment is `{ text, hl_key }` where `hl_key` is nil for plain text.
---@param line string
---@return table[]
local function tokenize_body_line(line)
  local segments = {}
  local pos = 1
  local len = #line
  while pos <= len do
    local best_s, best_e, best_key
    for _, p in ipairs(SYNTAX_PATTERNS) do
      local s, e = line:find(p.pat, pos)
      if s and (best_s == nil or s < best_s) then
        best_s, best_e, best_key = s, e, p.hl_key
      end
    end
    if best_s == nil then
      table.insert(segments, { line:sub(pos), nil })
      break
    end
    if best_s > pos then
      table.insert(segments, { line:sub(pos, best_s - 1), nil })
    end
    table.insert(segments, { line:sub(best_s, best_e), best_key })
    pos = best_e + 1
  end
  return segments
end

---Pad a chunk-list to the given display width using the provided bg hl group
---so the row's background colour reaches the right edge of the window.
---@param chunks table[]
---@param bg_hl string
---@param width number
---@return table[]
local function pad_row(chunks, bg_hl, width)
  local total = 0
  for _, c in ipairs(chunks) do
    total = total + vim.fn.strdisplaywidth(c[1])
  end
  if total < width then
    table.insert(chunks, { string.rep(" ", width - total), bg_hl })
  end
  return chunks
end

---Wrap the given chunks with left/right `│` border characters and pad the
---inner content so the right border lands exactly at column `width`. Use this
---for every body/header/footer row inside the framed discussion block; the
---top/bottom border rows already span the full width with their own corner
---characters.
---@param chunks table[]
---@param bg_hl string
---@param width number
---@return table[]
local function frame_row(chunks, bg_hl, width)
  local border_hl = state.settings.discussion_inline.highlights.border
  local result = { { "│", border_hl } }
  for _, c in ipairs(chunks) do
    table.insert(result, c)
  end
  local total = 1 -- left border already counted
  for _, c in ipairs(chunks) do
    total = total + vim.fn.strdisplaywidth(c[1])
  end
  local inner_target = width - 1 -- leave one cell for the right border
  if total < inner_target then
    table.insert(result, { string.rep(" ", inner_target - total), bg_hl })
  end
  table.insert(result, { "│", border_hl })
  return result
end

---Build the virt_lines payload for a single discussion.
---@param discussion table
---@param collapsed boolean
---@param render_width number
---@return table[][]
local function build_virt_lines(discussion, collapsed, render_width)
  local settings = state.settings.discussion_inline
  local hl = settings.highlights
  local notes = discussion.notes or { discussion }
  local first_note = indicators_common.get_first_note(discussion)
  -- resolvable / resolved are properties of the first note, not the
  -- discussion. Same convention as the bottom-panel tree.
  local is_resolved = first_note.resolvable and first_note.resolved

  -- Collapsed threads render no inline content — placement adds a gutter sign
  -- instead. Returning zero rows also means no spacer is needed on the
  -- opposite side, so alignment is unaffected.
  if collapsed then
    return {}
  end

  local rows = {}
  -- Top border row: rounded box-drawing chars filling the full width so the
  -- thread reads as a visually-distinct block.
  local border_middle = ("─"):rep(math.max(0, render_width - 2))
  table.insert(rows, { { "╭" .. border_middle .. "╮", hl.border } })

  -- System notes (GitLab auto-generated "changed this line in version X"
  -- entries) get their own muted style and don't count towards the
  -- body/body_alt alternation so the rhythm of human replies stays even.
  local human_idx = 0

  for i, note in ipairs(notes) do
    local is_system = note.system == true
    -- Resolved threads use a single uniform bg so they read as "closed".
    -- Whichever colours are configured for hl.resolved should set bg only
    -- (and leave fg at the default) so body text stays readable.
    local note_bg
    if is_resolved then
      note_bg = hl.resolved
    elseif is_system then
      note_bg = hl.system
    else
      human_idx = human_idx + 1
      note_bg = (human_idx % 2 == 1) and hl.body or hl.body_alt
    end

    if is_system then
      -- System notes render as a single inline sentence:
      --   "ⓘ Jon Lloyd Davies changed this line in version 7 of the diff 1 day ago"
      -- The body already reads as a sentence fragment; we surround it with the
      -- author name and a relative timestamp so the whole row scans naturally.
      -- System note bodies are markdown and often contain a long link to the
      -- diff or MR. Strip aggressively so the inline sentence is readable:
      --   1. Markdown links [text](url) -> text
      --   2. HTML anchors <a href="...">text</a> -> text
      --   3. Bare http(s) URLs -> removed
      --   4. Bare absolute paths (/foo/bar/...) -> removed
      --   5. Collapse whitespace and trim
      local body = (note.body or note.note or "")
        :gsub("%[([^%]]*)%]%([^)]*%)", "%1")
        :gsub("<a%s+[^>]*>(.-)</a>", "%1")
        :gsub("https?://%S+", "")
        :gsub("/[%w%-_./?#=&%%]+", "")
        :gsub("%s+", " ")
        :gsub("^%s+", "")
        :gsub("%s+$", "")
      local author = (note.author and note.author.name) or (note.author and note.author.username) or "system"
      local time = note.created_at and u.time_since(note.created_at) or ""
      local sentence = author .. " " .. body
      if time ~= "" then
        sentence = sentence .. " " .. time
      end
      table.insert(rows, frame_row({ { "   ⓘ " .. sentence, note_bg } }, note_bg, render_width))
    else
      -- Header row: layer hl.header (fg-only, e.g. bold light blue) on the
      -- username/timestamp so it stands out from body text. The first note's
      -- header in a resolved thread carries a prominent [resolved] badge so
      -- resolution status is obvious even with the thread expanded.
      local header = actions_common.build_note_header(note)
      local prefix = (i == 1) and "▼ " or "   ↳ "
      local row = {
        { prefix, note_bg },
        { header, { note_bg, hl.header } },
      }
      if i == 1 and is_resolved then
        table.insert(row, { "   ", note_bg })
        table.insert(row, { " ✓ resolved ", { note_bg, hl.resolved } })
      end
      table.insert(rows, frame_row(row, note_bg, render_width))

      -- Body rows with inline syntax highlighting and blockquote detection.
      local body = note.body or note.note or ""
      for _, line in ipairs(wrap_text(body, settings.max_body_width)) do
        local is_quote = line:match("^%s*>%s") ~= nil
        local default_fg = is_quote and hl.quote or nil
        local chunks = { { "    ", note_bg } }
        for _, seg in ipairs(tokenize_body_line(line)) do
          local text, hl_key = seg[1], seg[2]
          if hl_key then
            table.insert(chunks, { text, { note_bg, hl[hl_key] } })
          elseif default_fg then
            table.insert(chunks, { text, { note_bg, default_fg } })
          else
            table.insert(chunks, { text, note_bg })
          end
        end
        table.insert(rows, frame_row(chunks, note_bg, render_width))
      end
    end
  end

  -- Uniform footer bg (no Special-highlight chunks since they'd break the row's
  -- background fill). Brackets give the keys enough visual weight.
  local footer = string.format(
    "    [%s] reply   [%s] %s   [%s] collapse",
    settings.keymaps.reply,
    settings.keymaps.resolve,
    is_resolved and "unresolve" or "resolve",
    settings.keymaps.toggle
  )
  table.insert(rows, frame_row({ { footer, hl.footer } }, hl.footer, render_width))

  -- Bottom border row matching the top.
  table.insert(rows, { { "╰" .. border_middle .. "╯", hl.border } })

  return rows
end

---Resolve the 0-based anchor line for a discussion's extmark.
---Single-line: comment line - 1. Multi-line: end of range - 1.
---Resolve 0-based anchor lines on BOTH sides of the diff so we can mirror the
---thread's virt_lines with empty spacer rows on the opposite side. This keeps
---the side-by-side diff visually aligned even though only one side gets the
---real content.
---@param d_or_n table
---@return integer|nil old_lnum, integer|nil new_lnum
local function get_anchor_lnums(d_or_n)
  local first_note = indicators_common.get_first_note(d_or_n)
  local pos = first_note.position
  if pos == nil then
    return nil, nil
  end

  local function valid(n)
    return (type(n) == "number" and n > 0) and (n - 1) or nil
  end

  if indicators_common.is_single_line(d_or_n) then
    return valid(pos.old_line), valid(pos.new_line)
  end

  local line_range = pos.line_range
  if line_range == nil then
    return nil, nil
  end
  local end_old, end_new = indicators_common.parse_line_code(line_range["end"].line_code)
  return valid(end_old), valid(end_new)
end

---Build a list of empty virt_lines used as a spacer on the side that doesn't
---hold the real thread content. Each empty row takes one display row so the
---two diff buffers stay aligned.
---@param count number
---@return table[][]
local function build_spacer(count)
  local rows = {}
  for _ = 1, count do
    table.insert(rows, { { "", "Normal" } })
  end
  return rows
end

---Binary search for the 0-based lnum on `win` whose visual end row (including
---preceding diff fillers and virt_lines from any namespace) is closest to
---`target_height`. Returns nil if the window/buffer is invalid.
---
---Why this exists: diffview inserts its own filler virt_lines on whichever
---side is missing lines (e.g. blank fillers on the old side for new-side
---additions). Using raw line numbers as anchors ignores those fillers and the
---spacer side ends up one or more rows off. Mapping by visual row aligns
---both sides regardless of how the diff is laid out.
---@param win number
---@param target_height number
---@param max_lnum number
---@return number|nil
local function find_lnum_at_visual_height(win, target_height, max_lnum)
  if not vim.api.nvim_win_is_valid(win) then
    return nil
  end
  if max_lnum < 0 then
    return nil
  end
  if target_height <= 0 then
    return 0
  end

  local low, high = 0, max_lnum
  local best, best_diff = nil, math.huge
  while low <= high do
    local mid = math.floor((low + high) / 2)
    local ok, h = pcall(vim.api.nvim_win_text_height, win, { end_row = mid })
    if not ok then
      return nil
    end
    local total = h.all or 0
    local diff = math.abs(total - target_height)
    if diff < best_diff then
      best, best_diff = mid, diff
    end
    if total < target_height then
      low = mid + 1
    elseif total > target_height then
      high = mid - 1
    else
      return mid
    end
  end
  return best
end

---Find the discussion id anchored at the current cursor line in `bufnr`.
---@param bufnr number
---@return string|integer|nil
local function find_discussion_at_cursor(bufnr)
  local cursor_line = vim.api.nvim_win_get_cursor(0)[1]
  local map = M.line_map[bufnr]
  return map and map[cursor_line] or nil
end

---Install buffer-local keymaps for inline thread interaction.
---Idempotent: vim.keymap.set replaces any prior mapping.
---@param bufnr number
local function set_buf_keymaps(bufnr)
  local km = state.settings.discussion_inline.keymaps
  local opts = { buffer = bufnr, silent = true, nowait = true }
  vim.keymap.set("n", km.toggle, M.toggle_at_cursor, vim.tbl_extend("force", opts, { desc = "Toggle inline discussion" }))
  vim.keymap.set("n", km.reply, M.reply_at_cursor, vim.tbl_extend("force", opts, { desc = "Reply to inline discussion" }))
  vim.keymap.set("n", km.resolve, M.resolve_at_cursor, vim.tbl_extend("force", opts, { desc = "Toggle resolved on inline discussion" }))
end

---Clear inline extmarks for a buffer and reset its lookup tables.
---@param bufnr number
M.clear_buf = function(bufnr)
  if vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  end
  M.line_map[bufnr] = {}
  M.extmark_map[bufnr] = {}
end

---Per-buffer hook for the existing diagnostics lifecycle. Inline placement
---needs to coordinate BOTH diff buffers to keep them aligned (each spacer
---anchor depends on the real side's visual row, which depends on diffview's
---fillers and any prior virt_lines we've placed). So this just schedules a
---single full refresh on the next event-loop tick, debouncing the two
---per-buffer calls that diagnostics fires.
---@param _bufnr number
local refresh_scheduled = false
M.place_for_buf = function(_bufnr)
  if refresh_scheduled then
    return
  end
  refresh_scheduled = true
  vim.schedule(function()
    refresh_scheduled = false
    M.refresh()
  end)
end

---Refresh inline view across both reviewer buffers in a single coordinated
---pass. Discussions are processed top-to-bottom of the file so that each
---spacer's visual-row anchor accounts for prior placements on both sides.
M.refresh = function()
  if not state.settings.discussion_inline.enabled then
    return
  end
  local view = diffview_lib.get_current_view()
  if view == nil then
    return
  end
  local a, b = view.cur_layout.a, view.cur_layout.b
  if not a or not b or not a.file or not b.file then
    return
  end
  local buf_a, buf_b = a.file.bufnr, b.file.bufnr
  if not buf_a or not buf_b then
    return
  end
  if not vim.api.nvim_buf_is_valid(buf_a) or not vim.api.nvim_buf_is_valid(buf_b) then
    return
  end
  if vim.api.nvim_buf_get_name(buf_a) == "diffview://null" or vim.api.nvim_buf_get_name(buf_b) == "diffview://null" then
    return
  end

  M.clear_buf(buf_a)
  M.clear_buf(buf_b)
  ensure_buf_tables(buf_a)
  ensure_buf_tables(buf_b)
  set_buf_keymaps(buf_a)
  set_buf_keymaps(buf_b)

  local win_a = vim.fn.win_findbuf(buf_a)[1]
  local win_b = vim.fn.win_findbuf(buf_b)[1]
  if not win_a or not win_b then
    return
  end

  local ok, err = pcall(function()
    local placeable = indicators_common.filter_placeable_discussions()
    if not state.settings.discussion_inline.show_resolved then
      placeable = List.new(placeable):filter(function(d)
        return not (d.resolvable and d.resolved)
      end)
    end

    local file_discussions = List.new(placeable):filter(function(d)
      local note = d.notes and d.notes[1] or d
      return note.position
        and (
          note.position.new_path == b.file.path
          or note.position.old_path == a.file.path
        )
    end)

    if #file_discussions == 0 then
      return
    end

    -- Process top-to-bottom so each placement's text_height query accounts for
    -- the virt_lines already inserted by earlier discussions in this loop.
    table.sort(file_discussions, function(d1, d2)
      local o1, n1 = get_anchor_lnums(d1)
      local o2, n2 = get_anchor_lnums(d2)
      return (o1 or n1 or 0) < (o2 or n2 or 0)
    end)

    local render_width_a = get_render_width(buf_a)
    local render_width_b = get_render_width(buf_b)

    for _, d in ipairs(file_discussions) do
      local old_lnum, new_lnum = get_anchor_lnums(d)
      local is_b_real = indicators_common.is_new_sha(d)
      local real_bufnr = is_b_real and buf_b or buf_a
      local real_win = is_b_real and win_b or win_a
      local spacer_bufnr = is_b_real and buf_a or buf_b
      local spacer_win = is_b_real and win_a or win_b
      local real_anchor_lnum = is_b_real and new_lnum or old_lnum
      local render_width = is_b_real and render_width_b or render_width_a

      if real_anchor_lnum ~= nil and real_anchor_lnum >= 0 then
        -- Find the visual row at the end of the real anchor line. This
        -- includes diffview's fillers and any virt_lines we've already placed
        -- in this refresh.
        local h_ok, h = pcall(vim.api.nvim_win_text_height, real_win, { end_row = real_anchor_lnum })
        local R = h_ok and h.all or nil

        -- Map that visual row to the corresponding line on the spacer buffer.
        local spacer_anchor_lnum
        if R ~= nil then
          local max_lnum = vim.api.nvim_buf_line_count(spacer_bufnr) - 1
          spacer_anchor_lnum = find_lnum_at_visual_height(spacer_win, R, max_lnum)
        end

        local collapsed = is_collapsed(d)
        local real_virt_lines = build_virt_lines(d, collapsed, render_width)

        -- Collapsed threads render no inline content. The existing diagnostics
        -- gutter sign (managed by indicators/signs.lua) marks the anchor line
        -- and is the only visible cue. Expanded threads add inline virt_lines.
        local real_ok, real_id = pcall(vim.api.nvim_buf_set_extmark, real_bufnr, ns, real_anchor_lnum, 0, {
          virt_lines = real_virt_lines,
          virt_lines_above = false,
        })
        if real_ok then
          M.extmark_map[real_bufnr][d.id] = real_id
          M.line_map[real_bufnr][real_anchor_lnum + 1] = d.id
        end

        -- Spacer alignment only matters when there's real content to mirror.
        if not collapsed and spacer_anchor_lnum ~= nil and spacer_anchor_lnum >= 0 then
          local spacer_virt_lines = build_spacer(#real_virt_lines)
          local sp_ok, sp_id = pcall(vim.api.nvim_buf_set_extmark, spacer_bufnr, ns, spacer_anchor_lnum, 0, {
            virt_lines = spacer_virt_lines,
            virt_lines_above = false,
          })
          if sp_ok then
            M.extmark_map[spacer_bufnr][d.id] = sp_id
          end
        end
      end
    end
  end)

  if not ok then
    u.notify(string.format("Error placing inline discussions: %s", err), vim.log.levels.ERROR)
  end
end

---Toggle collapsed state of the thread under the cursor.
M.toggle_at_cursor = function()
  local bufnr = vim.api.nvim_get_current_buf()
  local id = find_discussion_at_cursor(bufnr)
  if id == nil then
    return
  end
  local current = M.collapse_state[id]
  if current == nil then
    local d = find_discussion(id)
    local was_collapsed = d and is_collapsed(d) or state.settings.discussion_inline.default_collapsed
    M.collapse_state[id] = not was_collapsed
  else
    M.collapse_state[id] = not current
  end
  M.refresh()
end

---Open the inline reply popup for the thread under the cursor.
M.reply_at_cursor = function()
  local bufnr = vim.api.nvim_get_current_buf()
  local id = find_discussion_at_cursor(bufnr)
  if id == nil then
    return
  end
  require("gitlab.actions.inline_reply").open(id)
end

---Toggle resolved state on the thread under the cursor.
M.resolve_at_cursor = function()
  local bufnr = vim.api.nvim_get_current_buf()
  local id = find_discussion_at_cursor(bufnr)
  if id == nil then
    return
  end
  local d = find_discussion(id)
  if d == nil then
    u.notify("Discussion not found", vim.log.levels.ERROR)
    return
  end
  -- resolvable / resolved are properties of the first note, not the
  -- discussion. Same convention as the bottom-panel tree.
  local first = indicators_common.get_first_note(d)
  if not first.resolvable then
    u.notify("Discussion is not resolvable", vim.log.levels.WARN)
    return
  end
  local body = { discussion_id = id, resolved = not first.resolved }
  local job = require("gitlab.job")
  job.run_job("/mr/discussions/resolve", "PUT", body, function(data)
    u.notify(data.message, vim.log.levels.INFO)
    -- Clear any manual collapse override so the default rule applies after
    -- toggle: resolved threads auto-collapse, unresolved threads auto-expand
    -- (unless default_collapsed is set).
    M.collapse_state[id] = nil
    require("gitlab.actions.discussions").rebuild_view(false)
  end)
end

---Clear all inline state across known buffers (e.g. on reviewer leave).
M.clear_all = function()
  for bufnr, _ in pairs(M.extmark_map) do
    M.clear_buf(bufnr)
  end
end

return M
