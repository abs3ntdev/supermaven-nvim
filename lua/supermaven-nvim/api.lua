local binary = require("supermaven-nvim.binary.binary_handler")
local listener = require("supermaven-nvim.document_listener")
local log = require("supermaven-nvim.logger")
local u = require("supermaven-nvim.util")
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

--- Statusline API ---

--- Get the current Supermaven status suitable for statusline display.
---@return { running: boolean, service_tier: string|nil, service_display: string|nil, task_status: string|nil, active_repo: string|nil, is_connected: boolean|nil, connection_status_text: string|nil, user_email: string|nil }
M.get_status = function()
  return {
    running = binary:is_running(),
    service_tier = binary.service_tier,
    service_display = binary.service_display,
    task_status = binary.task_status,
    active_repo = binary.active_repo,
    is_connected = binary.is_connected,
    connection_status_text = binary.connection_status_text,
    user_email = binary.user_email,
  }
end

--- Get a short string suitable for direct statusline use.
--- Examples: "Supermaven Pro", "Supermaven Free", "Supermaven Off", "Supermaven Disconnected"
---@return string
M.get_status_string = function()
  if not binary:is_running() then
    return "Supermaven Off"
  end

  if binary.is_connected == false then
    return "Supermaven Disconnected"
  end
  local display = binary.service_display
  if display and display ~= "" then
    return "Supermaven " .. display
  end
  return "Supermaven"
end

--- Check if the binary has an active connection to the Supermaven server
---@return boolean
M.is_connected = function()
  if not binary:is_running() then
    return false
  end
  -- nil means we haven't received a status yet; assume connected
  if binary.is_connected == nil then
    return true
  end
  return binary.is_connected
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
