-- This module places MR discussion threads as inline virtual lines directly
-- below the commented line in the Diffview reviewer buffers. The actual
-- rendering (building virt_lines, keymap handlers, collapse state) lives in
-- the shared `inline_thread_renderer` module so the workspace-buffer
-- placement can reuse it.

local u = require("gitlab.utils")
local diffview_lib = require("diffview.lib")
local indicators_common = require("gitlab.indicators.common")
local renderer = require("gitlab.indicators.inline_thread_renderer")
local List = require("gitlab.utils.list")
local state = require("gitlab.state")

local M = {}
local ns = vim.api.nvim_create_namespace("gitlab_inline_discussions")
M.namespace = ns

-- line_map[bufnr][1-based-line] = discussion_id (anchor lookup for keymaps)
M.line_map = {}
-- extmark_map[bufnr][discussion_id] = extmark_id
M.extmark_map = {}

local function ensure_buf_tables(bufnr)
  M.line_map[bufnr] = M.line_map[bufnr] or {}
  M.extmark_map[bufnr] = M.extmark_map[bufnr] or {}
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

---Clear inline extmarks for a buffer and reset its lookup tables.
---@param bufnr number
M.clear_buf = function(bufnr)
  if vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  end
  M.line_map[bufnr] = {}
  M.extmark_map[bufnr] = {}
  renderer.unregister_buffer(bufnr)
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
  renderer.set_buf_keymaps(buf_a, state.settings.discussion_inline.keymaps)
  renderer.set_buf_keymaps(buf_b, state.settings.discussion_inline.keymaps)
  renderer.register_buffer(buf_a, { line_map = M.line_map[buf_a], refresh = M.refresh })
  renderer.register_buffer(buf_b, { line_map = M.line_map[buf_b], refresh = M.refresh })

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
      local o1, n1 = renderer.get_anchor_lnums(d1)
      local o2, n2 = renderer.get_anchor_lnums(d2)
      return (o1 or n1 or 0) < (o2 or n2 or 0)
    end)

    local render_width_a = get_render_width(buf_a)
    local render_width_b = get_render_width(buf_b)

    for _, d in ipairs(file_discussions) do
      local old_lnum, new_lnum = renderer.get_anchor_lnums(d)
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

        local collapsed = renderer.is_collapsed(d)
        local real_virt_lines = renderer.build_virt_lines(d, collapsed, render_width, state.settings.discussion_inline.keymaps)

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

---Clear all inline state across known buffers (e.g. on reviewer leave).
M.clear_all = function()
  for bufnr, _ in pairs(M.extmark_map) do
    M.clear_buf(bufnr)
  end
end

return M
