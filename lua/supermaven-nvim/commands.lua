local api = require("supermaven-nvim.api")
local log = require("supermaven-nvim.logger")
local nes = require("supermaven-nvim.nes")

local M = {}

M.setup = function()
  vim.api.nvim_create_user_command("SupermavenStart", function()
    api.start()
  end, {})

  vim.api.nvim_create_user_command("SupermavenStop", function()
    api.stop()
  end, {})

  vim.api.nvim_create_user_command("SupermavenRestart", function()
    api.restart()
  end, {})

  vim.api.nvim_create_user_command("SupermavenToggle", function()
    api.toggle()
  end, {})

  vim.api.nvim_create_user_command("SupermavenStatus", function()
    log:trace(string.format("Supermaven is %s", api.is_running() and "running" or "not running"))
  end, {})

  vim.api.nvim_create_user_command("SupermavenUseFree", function()
    api.use_free_version()
  end, {})

  vim.api.nvim_create_user_command("SupermavenUsePro", function()
    api.use_pro()
  end, {})

  vim.api.nvim_create_user_command("SupermavenLogout", function()
    api.logout()
  end, {})

  vim.api.nvim_create_user_command("SupermavenShowLog", function()
    api.show_log()
  end, {})

  vim.api.nvim_create_user_command("SupermavenClearLog", function()
    api.clear_log()
  end, {})

  -- NES commands
  vim.api.nvim_create_user_command("SupermavenNesAccept", function()
    nes:accept_and_goto()
  end, { desc = "Accept the pending NES edit suggestion" })

  vim.api.nvim_create_user_command("SupermavenNesDismiss", function()
    nes:dismiss()
  end, { desc = "Dismiss the pending NES edit suggestion" })

  vim.api.nvim_create_user_command("SupermavenNesJump", function()
    nes:jump_to_edit()
  end, { desc = "Jump cursor to the pending NES edit location" })
end

return M
