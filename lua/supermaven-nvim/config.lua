local default_config = {
  keymaps = {
    accept_suggestion = "<Tab>",
    clear_suggestion = "<C-]>",
    accept_word = "<C-j>",
  },
  color = {
    suggestion_color = nil,
    cterm = nil,
  },
  ignore_filetypes = {},
  disable_inline_completion = false,
  disable_keymaps = false,
  condition = function()
    return false
  end,
  log_level = "info",
  --- Optional callbacks for hooking into plugin events
  ---@type fun()|nil
  on_accept_suggestion = nil,
  ---@type fun()|nil
  on_accept_nes = nil,
  ---@type fun()|nil
  on_dismiss_nes = nil,
  nes = {
    enabled = false,
    keymaps = {
      accept = "<Tab>",
      dismiss = "<C-]>",
      next = "]s",
    },
    move_count_threshold = 3,
    distance_threshold = 40,
  },
}

local M = {
  config = vim.deepcopy(default_config),
}

M.setup = function(args)
  M.config = vim.tbl_deep_extend("force", vim.deepcopy(default_config), args)
end

return setmetatable(M, {
  __index = function(_, key)
    if key == "setup" then
      return M.setup
    end
    return rawget(M.config, key)
  end,
})
