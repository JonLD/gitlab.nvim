-- Places MR discussion threads as inline virtual lines inside regular file
-- buffers (not the Diffview reviewer). Threads are anchored using a diff-aware
-- line mapper that translates each comment's `position.new_line` (a line in
-- the MR head_sha version of the file) to a line in the current working-tree
-- buffer, so comments stay on the right line even when the user has committed
-- or saved changes on top of the MR head.
--
-- Only new-side comments are shown (`indicators_common.is_new_sha(d)`).
-- Activation is automatic on file open for files in the MR diff, scoped to
-- the MR's source branch.

local u = require("gitlab.utils")
local indicators_common = require("gitlab.indicators.common")
local actions_common = require("gitlab.actions.common")
local renderer = require("gitlab.indicators.inline_thread_renderer")
local hunks = require("gitlab.hunks")
local git = require("gitlab.git")
local state = require("gitlab.state")
local List = require("gitlab.utils.list")

-- Reuse the diagnostics namespace + sign group from the existing indicators
-- pipeline so workspace placements participate in the same clear / refresh
-- lifecycle and look identical to the diffview ones.
local diagnostics_ns_name = "gitlab_discussion"
local diagnostics_namespace = vim.api.nvim_create_namespace(diagnostics_ns_name)
local sign_group = diagnostics_ns_name

local M = {}
local ns = vim.api.nvim_create_namespace("gitlab_workspace_inline_discussions")
M.namespace = ns

-- line_map[bufnr][1-based-line] = discussion_id (anchor lookup for keymaps)
M.line_map = {}
-- extmark_map[bufnr][discussion_id] = extmark_id
M.extmark_map = {}
-- Per-buffer toggle override: when true, refresh_buf clears the buffer and
-- does not place anything. Cleared by toggle_buf.
M.disabled_bufs = {}

-- repo_root: cached output of `git rev-parse --show-toplevel`, normalized to
-- forward slashes and lowercase. Cleared on first use per session.
local repo_root_cache = nil

-- line_map_cache[repo_relative_path] = { head_sha = <sha>, mtime = <number>, mapper = <fn> }
-- mapper(head_line) returns buffer_line | nil
local line_map_cache = {}

-- refresh_scheduled[bufnr] = true while a refresh is pending in vim.schedule.
local refresh_scheduled = {}

---Normalize a filesystem path: forward slashes, trim trailing slash,
---lowercase drive letter on Windows (so case-insensitive prefix match works).
---@param path string
---@return string
local function normalize_path(path)
  if path == nil or path == "" then
    return ""
  end
  path = path:gsub("\\", "/")
  -- Lowercase a Windows drive letter so `C:/foo` and `c:/foo` compare equal.
  path = path:gsub("^(%a):", function(letter) return letter:lower() .. ":" end)
  return path
end

---Get the repo root (normalized), cached for the session.
---@return string|nil
local function get_repo_root()
  if repo_root_cache ~= nil then
    return repo_root_cache ~= false and repo_root_cache or nil
  end
  local root, err = git.base_dir()
  if err or root == nil or root == "" then
    repo_root_cache = false
    return nil
  end
  repo_root_cache = normalize_path(root)
  return repo_root_cache
end

---Convert an absolute buffer path to a path relative to the repo root.
---Returns nil if the path is outside the repo.
---@param abs_path string
---@return string|nil
local function repo_relative_path(abs_path)
  local root = get_repo_root()
  if root == nil then
    return nil
  end
  local norm = normalize_path(abs_path)
  if norm:sub(1, #root + 1) ~= root .. "/" then
    return nil
  end
  return norm:sub(#root + 2)
end

---Run `git diff <head_sha> -- <file>` against the working tree and parse it
---into a list of hunks.
---@param head_sha string
---@param repo_path string Path relative to repo root.
---@return table[] hunks list of { old_line, old_range, new_line, new_range }
local function git_diff_hunks(head_sha, repo_path)
  local root = get_repo_root()
  if root == nil then
    return {}
  end
  -- Use -U0 so hunks contain only changed lines. Pass cwd via -C so the diff
  -- runs in the repo root regardless of Neovim's cwd.
  local cmd = string.format(
    'git -C "%s" diff --no-color --no-ext-diff -U0 %s -- "%s"',
    root,
    head_sha,
    repo_path
  )
  local output = vim.fn.systemlist(cmd)
  if vim.v.shell_error ~= 0 then
    return {}
  end
  local result = {}
  for _, line in ipairs(output) do
    local hunk = hunks.parse_possible_hunk_headers(line)
    if hunk ~= nil then
      -- A `,` omitted in the header means range=1; parse_possible_hunk_headers
      -- already returns 0 for missing range, so coerce to 1 for the standard case.
      if hunk.old_range == 0 and not line:match("^@@+ %-%d+,0") then
        hunk.old_range = 1
      end
      if hunk.new_range == 0 and not line:match("%+%d+,0 @@") then
        hunk.new_range = 1
      end
      table.insert(result, hunk)
    end
  end
  return result
end

---Build a line mapper closure for `repo_path`. Maps a 1-based line number in
---the MR head_sha version of the file to the corresponding 1-based line in
---the current working-tree buffer.
---
---When the head_sha line falls inside a region that was modified locally,
---the exact anchor is uncertain. We deliberately fall back to a "best-effort"
---anchor at the end of the new hunk (or just before a pure deletion) so the
---thread stays visible — the common case is the user editing the very line
---they were given feedback on, and hiding the comment exactly when they need
---it is the wrong default.
---@param repo_path string
---@param head_sha string
---@param mtime number
---@return fun(head_line: integer): integer|nil
local function build_line_map(repo_path, head_sha, mtime)
  local cached = line_map_cache[repo_path]
  if cached and cached.head_sha == head_sha and cached.mtime == mtime then
    return cached.mapper
  end

  local diff_hunks = git_diff_hunks(head_sha, repo_path)

  local mapper = function(head_line)
    if type(head_line) ~= "number" or head_line < 1 then
      return nil
    end
    local offset = 0
    for _, h in ipairs(diff_hunks) do
      -- Pure insertion (old_range == 0): the insertion sits between
      -- old line (old_line) and (old_line + 1) in the head_sha version. Any
      -- head_line <= old_line is unaffected by this hunk's insertions.
      if h.old_range == 0 then
        if head_line <= h.old_line then
          return head_line + offset
        end
        offset = offset + h.new_range
      else
        if head_line < h.old_line then
          return head_line + offset
        end
        if head_line < h.old_line + h.old_range then
          -- Line falls inside a modified/deleted region. Anchor at the end of
          -- the new hunk so the thread sits right under the user's edits.
          -- For pure deletions (new_range == 0), anchor at the line just
          -- before where the deletion was; clamp to >= 1.
          if h.new_range > 0 then
            return h.new_line + h.new_range - 1
          else
            return h.new_line > 0 and h.new_line or 1
          end
        end
        offset = offset + (h.new_range - h.old_range)
      end
    end
    return head_line + offset
  end

  line_map_cache[repo_path] = { head_sha = head_sha, mtime = mtime, mapper = mapper }
  return mapper
end

---Invalidate the cached line mapper for the buffer's file. Call after
---BufWritePost.
---@param bufnr number
local function invalidate_line_map_for_buf(bufnr)
  local name = vim.api.nvim_buf_get_name(bufnr)
  local rel = name ~= "" and repo_relative_path(name) or nil
  if rel ~= nil then
    line_map_cache[rel] = nil
  end
end

---Cheap pre-filter: is this buffer one we should consider rendering threads in?
---@param bufnr number
---@return boolean
local function is_eligible(bufnr)
  if not state.settings.discussion_inline.workspace.enabled then
    return false
  end
  if M.disabled_bufs[bufnr] then
    return false
  end
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return false
  end
  if vim.bo[bufnr].buftype ~= "" then
    return false
  end
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == "" or name:match("^%w+://") then
    return false
  end
  if state.INFO == nil or state.INFO.diff_refs == nil or state.INFO.diff_refs.head_sha == nil then
    return false
  end
  if state.INFO.source_branch and git.get_current_branch() ~= state.INFO.source_branch then
    return false
  end
  return true
end

---Determine the render width for the buffer's window.
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

---Clear inline extmarks, diagnostics, and signs for a buffer and reset its
---lookup tables. Skips work and ownership cleanup if we never placed anything
---for this buffer — otherwise the BufEnter autocmd fires for diffview buffers
---(which is_eligible rejects) and we'd clobber the diffview module's
---registration.
---@param bufnr number
M.clear_buf = function(bufnr)
  if M.line_map[bufnr] == nil and M.extmark_map[bufnr] == nil then
    return
  end
  if vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
    vim.diagnostic.reset(diagnostics_namespace, bufnr)
    vim.fn.sign_unplace(sign_group, { buffer = bufnr })
  end
  -- Only unregister if we're the current owner. The diffview module may have
  -- registered for the same bufnr (it shouldn't, since paths differ, but be
  -- defensive).
  local owner = renderer.buffer_owners[bufnr]
  if owner and owner.line_map == M.line_map[bufnr] then
    renderer.unregister_buffer(bufnr)
  end
  M.line_map[bufnr] = nil
  M.extmark_map[bufnr] = nil
end

---Build a single vim.diagnostic entry for the discussion at the given
---1-based buffer line.
---@param d table
---@param lnum_one_based integer
local function build_diagnostic(d, lnum_one_based)
  local first_note = indicators_common.get_first_note(d)
  local header = actions_common.build_note_header(first_note)
  local message = header
  if d.notes then
    for _, note in ipairs(d.notes) do
      message = message .. "\n" .. (note.body or note.note or "") .. "\n"
    end
  else
    message = message .. "\n" .. (d.body or d.note or "") .. "\n"
  end
  return {
    message = message,
    lnum = lnum_one_based - 1,
    col = 0,
    severity = state.settings.discussion_signs.severity,
    user_data = {
      discussion_id = d.id,
      header = header,
      resolved = first_note.resolvable and first_note.resolved or false,
    },
    source = "gitlab",
    code = "gitlab.nvim",
  }
end

---Place the gutter sign matching the discussion's resolution state at the
---given 1-based buffer line. Mirrors `signs.set_signs` but bufnr-targeted
---(no reliance on the current buffer).
---@param d table
---@param bufnr integer
---@param lnum_one_based integer
local function place_sign_for_discussion(d, bufnr, lnum_one_based)
  local signs = require("gitlab.indicators.signs")
  local first_note = indicators_common.get_first_note(d)
  local is_resolved = first_note.resolvable and first_note.resolved
  local sign_name = is_resolved
    and "GitlabResolvedComment"
    or ("DiagnosticSign" .. (signs.severity or "Hint") .. "GitlabComment")
  vim.fn.sign_place(
    lnum_one_based,
    sign_group,
    sign_name,
    bufnr,
    { lnum = lnum_one_based, priority = state.settings.discussion_signs.priority }
  )
end

---Run a refresh for `bufnr`. Debounced via vim.schedule so rapid-fire
---BufEnter events collapse to a single placement pass.
---@param bufnr number
M.refresh_buf = function(bufnr)
  if refresh_scheduled[bufnr] then
    return
  end
  refresh_scheduled[bufnr] = true
  vim.schedule(function()
    refresh_scheduled[bufnr] = nil
    M._do_refresh_buf(bufnr)
  end)
end

---@param bufnr number
M._do_refresh_buf = function(bufnr)
  if not is_eligible(bufnr) then
    M.clear_buf(bufnr)
    return
  end

  local name = vim.api.nvim_buf_get_name(bufnr)
  local repo_path = repo_relative_path(name)
  if repo_path == nil then
    M.clear_buf(bufnr)
    return
  end

  local placeable = indicators_common.filter_placeable_discussions()
  if not state.settings.discussion_inline.show_resolved then
    placeable = List.new(placeable):filter(function(d)
      return not (d.resolvable and d.resolved)
    end)
  end

  local file_discussions = List.new(placeable):filter(function(d)
    if not indicators_common.is_new_sha(d) then
      return false
    end
    local note = indicators_common.get_first_note(d)
    return note.position and note.position.new_path == repo_path
  end)

  if #file_discussions == 0 then
    M.clear_buf(bufnr)
    return
  end

  -- Always start from a clean slate so removed/resolved threads disappear.
  M.clear_buf(bufnr)
  M.line_map[bufnr] = {}
  M.extmark_map[bufnr] = {}
  renderer.set_buf_keymaps(bufnr, state.settings.discussion_inline.workspace.keymaps)
  renderer.register_buffer(bufnr, {
    line_map = M.line_map[bufnr],
    refresh = function() M.refresh_buf(bufnr) end,
  })

  local head_sha = state.INFO.diff_refs.head_sha
  local mtime_info = vim.uv and vim.uv.fs_stat(name) or vim.loop.fs_stat(name)
  local mtime = mtime_info and mtime_info.mtime and mtime_info.mtime.sec or 0
  local mapper = build_line_map(repo_path, head_sha, mtime)

  -- Sort top-to-bottom for stable rendering order.
  table.sort(file_discussions, function(d1, d2)
    local _, n1 = renderer.get_anchor_lnums(d1)
    local _, n2 = renderer.get_anchor_lnums(d2)
    return (n1 or 0) < (n2 or 0)
  end)

  local render_width = get_render_width(bufnr)
  local buf_line_count = vim.api.nvim_buf_line_count(bufnr)
  local signs_enabled = state.settings.discussion_signs.enabled
  local diagnostics_to_set = {}

  local ok, err = pcall(function()
    for _, d in ipairs(file_discussions) do
      -- new-side anchor (0-based) — convert to 1-based for the mapper, then
      -- back to 0-based for nvim_buf_set_extmark.
      local _, new_lnum_zero = renderer.get_anchor_lnums(d)
      if new_lnum_zero ~= nil and new_lnum_zero >= 0 then
        local head_line_one_based = new_lnum_zero + 1
        local buffer_line_one_based = mapper(head_line_one_based)
        if buffer_line_one_based ~= nil and buffer_line_one_based >= 1 and buffer_line_one_based <= buf_line_count then
          local anchor_zero = buffer_line_one_based - 1
          local collapsed = renderer.is_collapsed(d)
          local virt_lines = renderer.build_virt_lines(d, collapsed, render_width, state.settings.discussion_inline.workspace.keymaps)
          local set_ok, extmark_id = pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, anchor_zero, 0, {
            virt_lines = virt_lines,
            virt_lines_above = false,
          })
          if set_ok then
            M.extmark_map[bufnr][d.id] = extmark_id
            M.line_map[bufnr][buffer_line_one_based] = d.id
          end
          if signs_enabled then
            table.insert(diagnostics_to_set, build_diagnostic(d, buffer_line_one_based))
            place_sign_for_discussion(d, bufnr, buffer_line_one_based)
          end
        end
      end
    end

    if signs_enabled and #diagnostics_to_set > 0 then
      vim.diagnostic.set(diagnostics_namespace, bufnr, diagnostics_to_set, {
        virtual_text = state.settings.discussion_signs.virtual_text,
        severity_sort = true,
        underline = false,
        signs = state.settings.discussion_signs.use_diagnostic_signs,
      })
    end
  end)

  if not ok then
    u.notify(string.format("Error placing workspace inline discussions: %s", err), vim.log.levels.ERROR)
  end
end

---Invalidate the line-map cache for the buffer's file and re-place threads.
---Called from BufWritePost.
---@param bufnr number
M.invalidate_and_refresh = function(bufnr)
  invalidate_line_map_for_buf(bufnr)
  M.refresh_buf(bufnr)
end

---Refresh inline threads in every currently-loaded buffer that's eligible.
---Called from `actions/discussions/init.lua`'s `refresh_diagnostics` after
---discussion data changes.
M.refresh_all = function()
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) then
      M.refresh_buf(bufnr)
    end
  end
end

---Clear all inline state across known buffers.
M.clear_all = function()
  for bufnr, _ in pairs(M.extmark_map) do
    M.clear_buf(bufnr)
  end
end

---Toggle per-buffer inline threads on/off. Persists across refreshes via
---`disabled_bufs`.
---@param bufnr number
M.toggle_buf = function(bufnr)
  if M.disabled_bufs[bufnr] then
    M.disabled_bufs[bufnr] = nil
    M.refresh_buf(bufnr)
  else
    M.disabled_bufs[bufnr] = true
    M.clear_buf(bufnr)
  end
end

return M
