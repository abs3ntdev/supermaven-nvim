local api = require("supermaven-nvim.api")
local log = require("supermaven-nvim.logger")
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
    local status = api.get_status()
    local parts = { "Supermaven: " .. (status.running and "running" or "stopped") }
    if status.service_display and status.service_display ~= "" then
      table.insert(parts, "Tier: " .. status.service_display)
    end
    if status.user_email and status.user_email ~= "" then
      table.insert(parts, "Account: " .. status.user_email)
    end
    if status.is_connected == false then
      table.insert(
        parts,
        "Connection: disconnected"
          .. (status.connection_status_text and (" (" .. status.connection_status_text .. ")") or "")
      )
    end
    if status.disabled then
      table.insert(parts, "Disabled: " .. (status.disable_reason or "yes"))
    end
    if status.active_repo and status.active_repo ~= "" then
      table.insert(parts, "Repo: " .. status.active_repo)
    end
    log:trace(table.concat(parts, " | "))
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

end

return M
