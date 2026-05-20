-- Shared renderer for inline MR discussion threads. Used by both:
--   indicators/inline_discussions.lua             (Diffview reviewer)
--   indicators/workspace_inline_discussions.lua   (regular file buffers)
--
-- Each consumer manages its own namespace, line_map, and refresh function,
-- and registers per-buffer ownership via `register_buffer` so the shared
-- keymap handlers know which discussion lookup to consult and which refresh
-- to invoke after a state change.

local u = require("gitlab.utils")
local indicators_common = require("gitlab.indicators.common")
local actions_common = require("gitlab.actions.common")
local state = require("gitlab.state")

local M = {}

-- Shared across all consumers so collapse state survives switching between
-- the Diffview reviewer and a regular file buffer.
-- collapse_state[discussion_id] = true|false (explicit user choice; nil = use default)
M.collapse_state = {}

-- buffer_owners[bufnr] = { line_map = <[lnum]=id>, refresh = <fn> }
-- Populated by consumers in their refresh routines so shared keymap handlers
-- can look up the right discussion for the current buffer.
M.buffer_owners = {}

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
  group = vim.api.nvim_create_augroup("gitlab.inline_thread_renderer.hl", { clear = true }),
  callback = setup_highlights,
})

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
M.find_discussion = function(id)
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
M.is_collapsed = function(d_or_n)
  local override = M.collapse_state[d_or_n.id]
  if override ~= nil then
    return override
  end
  -- Resolvable/resolved flags live on the first note of a discussion, not on
  -- the discussion object itself.
  local first = indicators_common.get_first_note(d_or_n)
  if first.resolvable and first.resolved then
    return true
  end
  return state.settings.discussion_inline.default_collapsed
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
---@param keymaps table|nil { toggle, reply, resolve } used to render the footer
---@return table[][]
M.build_virt_lines = function(discussion, collapsed, render_width, keymaps)
  local settings = state.settings.discussion_inline
  local hl = settings.highlights
  keymaps = keymaps or settings.keymaps
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
      -- System note bodies are markdown and often contain a long link to the
      -- diff or MR. Strip aggressively so the inline sentence is readable.
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
      -- username/timestamp so it stands out from body text.
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
    keymaps.reply,
    keymaps.resolve,
    is_resolved and "unresolve" or "resolve",
    keymaps.toggle
  )
  table.insert(rows, frame_row({ { footer, hl.footer } }, hl.footer, render_width))

  -- Bottom border row matching the top.
  table.insert(rows, { { "╰" .. border_middle .. "╯", hl.border } })

  return rows
end

---Resolve the 0-based anchor line for a discussion's extmark.
---Single-line: comment line - 1. Multi-line: end of range - 1.
---Returns both old- and new-side line numbers so callers can choose the
---side appropriate to their buffer.
---@param d_or_n table
---@return integer|nil old_lnum, integer|nil new_lnum
M.get_anchor_lnums = function(d_or_n)
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

---Register the owner of a buffer so shared keymap handlers can find the
---right discussion lookup and the right refresh function.
---@param bufnr number
---@param info table { line_map = <table>, refresh = <fn> }
M.register_buffer = function(bufnr, info)
  M.buffer_owners[bufnr] = info
end

---@param bufnr number
M.unregister_buffer = function(bufnr)
  M.buffer_owners[bufnr] = nil
end

---Install buffer-local keymaps for inline thread interaction.
---Idempotent: vim.keymap.set replaces any prior mapping.
---@param bufnr number
---@param keymaps table { toggle = string, reply = string, resolve = string }
M.set_buf_keymaps = function(bufnr, keymaps)
  local opts = { buffer = bufnr, silent = true, nowait = true }
  vim.keymap.set("n", keymaps.toggle, M.toggle_at_cursor, vim.tbl_extend("force", opts, { desc = "Toggle inline discussion" }))
  vim.keymap.set("n", keymaps.reply, M.reply_at_cursor, vim.tbl_extend("force", opts, { desc = "Reply to inline discussion" }))
  vim.keymap.set("n", keymaps.resolve, M.resolve_at_cursor, vim.tbl_extend("force", opts, { desc = "Toggle resolved on inline discussion" }))
end

---Find the discussion id anchored at the current cursor line in the current
---buffer, using whichever owner has registered for this buffer.
---@return string|integer|nil
local function find_discussion_at_cursor()
  local bufnr = vim.api.nvim_get_current_buf()
  local owner = M.buffer_owners[bufnr]
  if owner == nil or owner.line_map == nil then
    return nil
  end
  local cursor_line = vim.api.nvim_win_get_cursor(0)[1]
  return owner.line_map[cursor_line]
end

---Toggle collapsed state of the thread under the cursor.
M.toggle_at_cursor = function()
  local id = find_discussion_at_cursor()
  if id == nil then
    return
  end
  local current = M.collapse_state[id]
  if current == nil then
    local d = M.find_discussion(id)
    local was_collapsed = d and M.is_collapsed(d) or state.settings.discussion_inline.default_collapsed
    M.collapse_state[id] = not was_collapsed
  else
    M.collapse_state[id] = not current
  end
  local owner = M.buffer_owners[vim.api.nvim_get_current_buf()]
  if owner and owner.refresh then
    owner.refresh()
  end
end

---Open the inline reply popup for the thread under the cursor.
M.reply_at_cursor = function()
  local id = find_discussion_at_cursor()
  if id == nil then
    return
  end
  require("gitlab.actions.inline_reply").open(id)
end

---Toggle resolved state on the thread under the cursor.
M.resolve_at_cursor = function()
  local id = find_discussion_at_cursor()
  if id == nil then
    return
  end
  local d = M.find_discussion(id)
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

return M
