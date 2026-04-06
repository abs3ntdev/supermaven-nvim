local binary = require("supermaven-nvim.binary.binary_handler")
local listener = require("supermaven-nvim.document_listener")
local log = require("supermaven-nvim.logger")
local u = require("supermaven-nvim.util")
local nes = require("supermaven-nvim.nes")

local loop = u.uv

local M = {}

M.is_running = function()
  return binary:is_running()
end

M.start = function()
  if M.is_running() then
    log:warn("Supermaven is already running.")
    return
  else
    log:trace("Starting Supermaven...")
  end
  vim.g.SUPERMAVEN_DISABLED = 0
  binary:start_binary()
  listener.setup()
end

M.stop = function()
  vim.g.SUPERMAVEN_DISABLED = 1
  if not M.is_running() then
    log:warn("Supermaven is not running.")
    return
  else
    log:trace("Stopping Supermaven...")
  end
  listener.teardown()
  nes:teardown()
  binary:stop_binary()
end

M.restart = function()
  if M.is_running() then
    M.stop()
  end
  M.start()
end

M.toggle = function()
  if M.is_running() then
    M.stop()
  else
    M.start()
  end
end

M.use_free_version = function()
  binary:use_free_version()
end

M.use_pro = function()
  binary:use_pro()
end

M.logout = function()
  binary:logout()
end

M.show_log = function()
  local log_path = log:get_log_path()
  if log_path ~= nil then
    vim.cmd.tabnew()
    vim.cmd(string.format(":e %s", log_path))
  else
    log:warn("No log file found to show!")
  end
end

M.clear_log = function()
  local log_path = log:get_log_path()
  if log_path ~= nil then
    loop.fs_unlink(log_path)
  else
    log:warn("No log file found to remove!")
  end
end

--- NES API functions ---

--- Check if there is a pending NES edit in the current buffer
---@return boolean
M.nes_has_edit = function()
  return nes:has_edit()
end

--- Accept the pending NES edit and jump to its end
---@return boolean true if an edit was applied
M.nes_accept = function()
  return nes:accept_and_goto()
end

--- Dismiss the pending NES edit in the current buffer
M.nes_dismiss = function()
  nes:dismiss()
end

--- Jump cursor to the pending NES edit location
---@return boolean true if cursor was moved
M.nes_jump = function()
  return nes:jump_to_edit()
end

--- Statusline API ---

--- Get the current Supermaven status suitable for statusline display.
--- Returns a table with fields: running, service_tier, service_display, task_status, active_repo
---@return { running: boolean, service_tier: string|nil, service_display: string|nil, task_status: string|nil, active_repo: string|nil }
M.get_status = function()
  return {
    running = binary:is_running(),
    service_tier = binary.service_tier,
    service_display = binary.service_display,
    task_status = binary.task_status,
    active_repo = binary.active_repo,
  }
end

--- Get a short string suitable for direct statusline use.
--- Examples: " Pro", " Free", " Off"
---@return string
M.get_status_string = function()
  if not binary:is_running() then
    return "Supermaven Off"
  end
  local display = binary.service_display
  if display and display ~= "" then
    return "Supermaven " .. display
  end
  return "Supermaven"
end

--- Check if Supermaven is currently completing (has pending inline completions)
---@return boolean
M.is_completing = function()
  if not binary:is_running() then
    return false
  end
  return binary.wants_polling == true
end

return M
