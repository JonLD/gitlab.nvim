local u = require("gitlab.utils")
local state = require("gitlab.state")
local List = require("gitlab.utils.list")
local discussion_sign_name = require("gitlab.indicators.diagnostics").discussion_sign_name

local M = {}
M.clear_signs = function()
  vim.fn.sign_unplace(discussion_sign_name)
end

local gitlab_comment = "GitlabComment"
local gitlab_range = "GitlabRange"
local gitlab_resolved_comment = "GitlabResolvedComment"
local gitlab_resolved_range = "GitlabResolvedRange"

local severity_map = {
  "Error",
  "Warn",
  "Info",
  "Hint",
}

---Refresh the discussion signs for currently loaded file in reviewer For convinience we use same
---string for sign name and sign group ( currently there is only one sign needed)
---@param diagnostics Diagnostic[]
---@param bufnr number
M.set_signs = function(diagnostics, bufnr)
  if not state.settings.discussion_signs.enabled then
    return
  end

  -- Filter diagnostics from the 'gitlab' source and apply custom signs.
  -- Layout per discussion:
  --   • single-line: comment sign on the commented line.
  --   • multi-line range: range signs on each line of the range EXCEPT the
  --     end line, which gets the comment sign. This matches the inline
  --     thread anchor, which sits just below the end of the range.
  for _, diagnostic in ipairs(diagnostics) do
    ---@type SignTable[]
    local existing_signs =
      vim.fn.sign_getplaced(vim.api.nvim_get_current_buf(), { group = discussion_sign_name })[1].signs

    local start_lnum = diagnostic.lnum + 1
    local end_lnum = (diagnostic.end_lnum or diagnostic.lnum) + 1
    local is_resolved = diagnostic.user_data and diagnostic.user_data.resolved
    -- Resolved discussions use a separate sign pair (own icon + own highlight)
    -- so resolution state is obvious in the gutter without expanding the thread.
    local comment_sign_name = is_resolved and gitlab_resolved_comment
      or ("DiagnosticSign" .. M.severity .. gitlab_comment)
    local range_sign_name = is_resolved and gitlab_resolved_range
      or ("DiagnosticSign" .. M.severity .. gitlab_range)

    if diagnostic.end_lnum then
      for linenr = start_lnum, end_lnum - 1 do
        local conflicting_comment_sign = List.new(existing_signs):find(function(sign)
          return (u.ends_with(sign.name, gitlab_comment) or u.ends_with(sign.name, gitlab_resolved_comment))
            and sign.lnum == linenr
        end)
        if conflicting_comment_sign == nil then
          vim.fn.sign_place(
            linenr,
            discussion_sign_name,
            range_sign_name,
            bufnr,
            { lnum = linenr, priority = state.settings.discussion_signs.priority }
          )
        end
      end
    end

    -- Comment sign anchors at the end of the range so it visually correlates
    -- with where the inline thread (or, when collapsed, the empty anchor)
    -- appears just below.
    vim.fn.sign_place(
      end_lnum,
      discussion_sign_name,
      comment_sign_name,
      bufnr,
      { lnum = end_lnum, priority = state.settings.discussion_signs.priority }
    )
  end
end

---Define signs for discussions
M.setup_signs = function()
  local discussion_sign_settings = state.settings.discussion_signs
  local comment_icon = discussion_sign_settings.icons.comment
  local range_icon = discussion_sign_settings.icons.range
  local resolved_icon = discussion_sign_settings.icons.resolved or "✓"
  local resolved_range_icon = discussion_sign_settings.icons.resolved_range or range_icon
  M.severity = severity_map[state.settings.discussion_signs.severity]
  local signs = { "Error", "Warn", "Hint", "Info" }
  for _, type in ipairs(signs) do
    -- Define comment highlight group
    local hl = "DiagnosticSign" .. type
    local comment_hl = hl .. gitlab_comment
    vim.fn.sign_define(comment_hl, {
      text = comment_icon,
      texthl = comment_hl,
    })
    vim.cmd(string.format("highlight link %s %s", comment_hl, hl))

    -- Define range highlight group
    local range_hl = hl .. gitlab_range
    vim.fn.sign_define(range_hl, {
      text = range_icon,
      texthl = range_hl,
    })
    vim.cmd(string.format("highlight link %s %s", range_hl, hl))
  end

  -- Resolved-discussion sign pair (severity-agnostic; resolution state is more
  -- meaningful than severity for closed threads). User-overridable by
  -- redefining the GitlabResolvedComment / GitlabResolvedRange highlights.
  vim.fn.sign_define(gitlab_resolved_comment, {
    text = resolved_icon,
    texthl = gitlab_resolved_comment,
  })
  vim.fn.sign_define(gitlab_resolved_range, {
    text = resolved_range_icon,
    texthl = gitlab_resolved_range,
  })
  -- Match the colour of the regular comment sign so resolution is signalled by
  -- the icon alone, not by a colour change.
  local base_sign_hl = "DiagnosticSign" .. M.severity
  vim.cmd("highlight default link " .. gitlab_resolved_comment .. " " .. base_sign_hl)
  vim.cmd("highlight default link " .. gitlab_resolved_range .. " " .. base_sign_hl)
end

return M
