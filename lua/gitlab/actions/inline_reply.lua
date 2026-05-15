-- Lightweight reply popup invoked from the inline discussion view in the
-- Diffview reviewer. Posts a non-draft reply to an existing discussion and
-- refreshes both the inline view and the bottom discussion tree.

local Popup = require("nui.popup")
local job = require("gitlab.job")
local u = require("gitlab.utils")
local popup = require("gitlab.popup")
local state = require("gitlab.state")

local M = {}

---Submit a reply to the given discussion.
---@param discussion_id string|integer
---@param text string
local function submit_reply(discussion_id, text)
  if text == nil or text:gsub("%s", "") == "" then
    u.notify("Reply is empty", vim.log.levels.WARN)
    return
  end
  local body = { discussion_id = discussion_id, reply = text, draft = false }
  job.run_job("/mr/reply", "POST", body, function()
    u.notify("Sent reply!", vim.log.levels.INFO)
    require("gitlab.actions.discussions").rebuild_view(false)
  end)
end

---Open the inline reply popup for the given discussion.
---@param discussion_id string|integer
M.open = function(discussion_id)
  local user_settings = state.settings.popup.reply
  local view_opts = popup.create_popup_state("Reply", user_settings)
  local current_win = vim.api.nvim_get_current_win()
  local reply_popup = Popup(view_opts)
  reply_popup:mount()

  popup.set_popup_keymaps(reply_popup, function(text)
    submit_reply(discussion_id, text)
  end, nil, popup.editable_popup_opts)

  popup.set_up_autocommands(reply_popup, nil, current_win)
end

return M
