--- NES (Next Edit Suggestions) module for supermaven-nvim
--- Handles delete, jump, and skip completions from the sm-agent as
--- proactive edit suggestions displayed in normal mode.
local u = require("supermaven-nvim.util")
local config = require("supermaven-nvim.config")
local log = require("supermaven-nvim.logger")

---@class Nes
local Nes = {
  ns_id = vim.api.nvim_create_namespace("supermaven_nes"),
  augroup = nil,
  prior_keymaps = {},
  preview_win = nil, ---@type integer | nil floating preview window for cross-file edits
  preview_buf = nil, ---@type integer | nil floating preview buffer
}

--- Per-buffer NES state stored in vim.b
---@param bufnr integer
---@return NesState | nil
local function get_state(bufnr)
  return vim.b[bufnr].supermaven_nes_state
end

---@param bufnr integer
---@param state NesState | nil
local function set_state(bufnr, state)
  vim.b[bufnr].supermaven_nes_state = state
end

--- Open a file (optionally creating it and its parent dirs), return its buffer number
---@param file_name string
---@param create boolean
---@return integer bufnr
local function open_file(file_name, create)
  if create then
    local dir = vim.fn.fnamemodify(file_name, ":h")
    if vim.fn.isdirectory(dir) == 0 then
      vim.fn.mkdir(dir, "p")
    end
    if vim.fn.filereadable(file_name) == 0 then
      local fd = io.open(file_name, "w")
      if fd then
        fd:close()
      end
    end
  end
  vim.cmd.edit(file_name)
  return vim.api.nvim_get_current_buf()
end

--- Set up NES highlight groups
local function setup_highlights()
  -- Use DiffAdd/DiffDelete style like copilot-lsp NES
  vim.api.nvim_set_hl(0, "SupermavenNesAdd", { link = "DiffAdd", default = true })
  vim.api.nvim_set_hl(0, "SupermavenNesDelete", { link = "DiffDelete", default = true })
  vim.api.nvim_set_hl(0, "SupermavenNesJump", { link = "DiagnosticHint", default = true })
  vim.api.nvim_set_hl(0, "SupermavenNesPortalBorder", { link = "FloatBorder", default = true })
  vim.api.nvim_set_hl(0, "SupermavenNesPortalTitle", { link = "Title", default = true })
end

--- Close the floating cross-file preview window if open
function Nes:close_preview()
  if self.preview_win and vim.api.nvim_win_is_valid(self.preview_win) then
    vim.api.nvim_win_close(self.preview_win, true)
  end
  self.preview_win = nil
  if self.preview_buf and vim.api.nvim_buf_is_valid(self.preview_buf) then
    vim.api.nvim_buf_delete(self.preview_buf, { force = true })
  end
  self.preview_buf = nil
end

--- Show a floating window previewing an edit (cross-file or off-screen same-file)
---@param edit NesEdit
function Nes:show_cross_file_preview(edit)
  self:close_preview()

  local file_name = edit.file_name or "(unknown)"
  local short_name = vim.fn.fnamemodify(file_name, ":~:.")
  -- Include the target line number in the title so the user knows where the edit is
  local target_line = edit.range.start.line + 1 -- 0-indexed → 1-indexed
  local title = " " .. short_name .. ":" .. target_line .. " "

  -- Build preview lines with diff-style +/- prefixes
  local preview_lines = {}
  local hl_lines = {} ---@type { line: integer, group: string }[]

  if edit.kind == "delete" or edit.kind == "replace" then
    for _, l in ipairs(vim.split(edit.old_text, "\n", { plain = true })) do
      table.insert(preview_lines, "- " .. l)
      table.insert(hl_lines, { line = #preview_lines - 1, group = "SupermavenNesDelete" })
    end
  end
  if (edit.kind == "insert" or edit.kind == "replace") and edit.new_text ~= "" then
    for _, l in ipairs(vim.split(edit.new_text, "\n", { plain = true })) do
      table.insert(preview_lines, "+ " .. l)
      table.insert(hl_lines, { line = #preview_lines - 1, group = "SupermavenNesAdd" })
    end
  end

  if #preview_lines == 0 then
    return
  end

  -- Create scratch buffer
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, preview_lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "diff"
  self.preview_buf = buf

  -- Calculate window size
  local max_width = 0
  for _, l in ipairs(preview_lines) do
    max_width = math.max(max_width, #l)
  end
  local win_width = math.min(max_width + 2, math.floor(vim.o.columns * 0.8))
  local win_height = math.min(#preview_lines, math.floor(vim.o.lines * 0.4))

  local win = vim.api.nvim_open_win(buf, false, {
    relative = "cursor",
    row = 1,
    col = 0,
    width = win_width,
    height = win_height,
    style = "minimal",
    border = "rounded",
    title = title,
    title_pos = "center",
    focusable = false,
  })
  self.preview_win = win

  -- Apply line highlights
  local hl_ns = vim.api.nvim_create_namespace("supermaven_nes_preview")
  for _, hl in ipairs(hl_lines) do
    vim.api.nvim_buf_set_extmark(buf, hl_ns, hl.line, 0, {
      end_col = #preview_lines[hl.line + 1],
      hl_group = hl.group,
    })
  end

  -- Style the window border
  vim.api.nvim_set_option_value("winhl", "FloatBorder:SupermavenNesPortalBorder,FloatTitle:SupermavenNesPortalTitle", {
    win = win,
  })
end

--- Check if an edit targets a different file than the one in the given buffer
---@param bufnr integer
---@param edit NesEdit
---@return boolean
local function is_cross_file(bufnr, edit)
  if not edit.file_name or edit.file_name == "" then
    return false
  end
  local buf_name = vim.api.nvim_buf_get_name(bufnr)
  -- Normalize for comparison
  local target = vim.fn.fnamemodify(edit.file_name, ":p")
  local current = vim.fn.fnamemodify(buf_name, ":p")
  return target ~= current
end

--- Check if an edit's target lines are outside the visible window
---@param edit NesEdit
---@return boolean
local function is_off_screen(edit)
  local win_top = vim.fn.line("w0") -- 1-indexed
  local win_bot = vim.fn.line("w$") -- 1-indexed
  local edit_start = edit.range.start.line + 1 -- 0-indexed → 1-indexed
  local edit_end = edit.range["end"].line + 1
  -- Off-screen if the entire edit range is above or below the visible window
  return edit_end < win_top or edit_start > win_bot
end

--- Clear all NES extmarks from a buffer
---@param bufnr integer
function Nes:clear(bufnr)
  self:close_preview()
  if vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_buf_clear_namespace(bufnr, self.ns_id, 0, -1)
  end
  set_state(bufnr, nil)
end

--- Clear NES state in the current buffer
function Nes:dismiss()
  local bufnr = vim.api.nvim_get_current_buf()
  self:clear(bufnr)
end

--- Render a delete suggestion (strikethrough/highlight over lines to be deleted)
---@param bufnr integer
---@param edit NesEdit
function Nes:render_delete(bufnr, edit)
  local start_line = edit.range.start.line
  local end_line = edit.range["end"].line

  for line = start_line, end_line do
    local line_count = vim.api.nvim_buf_line_count(bufnr)
    if line >= 0 and line < line_count then
      local line_text = vim.api.nvim_buf_get_lines(bufnr, line, line + 1, false)[1] or ""
      vim.api.nvim_buf_set_extmark(bufnr, self.ns_id, line, 0, {
        end_col = #line_text,
        hl_group = "SupermavenNesDelete",
        priority = 200,
      })
    end
  end
end

--- Render an insert suggestion (virtual text showing new text)
---@param bufnr integer
---@param edit NesEdit
function Nes:render_insert(bufnr, edit)
  local line = edit.range.start.line
  local col = edit.range.start.character
  local line_count = vim.api.nvim_buf_line_count(bufnr)

  if line < 0 or line >= line_count then
    return
  end

  local lines = vim.split(edit.new_text, "\n", { plain = true })

  if #lines == 1 then
    -- Single line insertion: inline virtual text
    vim.api.nvim_buf_set_extmark(bufnr, self.ns_id, line, col, {
      virt_text = { { lines[1], "SupermavenNesAdd" } },
      virt_text_pos = "inline",
      priority = 200,
    })
  else
    -- Multi-line insertion: virtual lines
    local virt_lines = {}
    for _, l in ipairs(lines) do
      table.insert(virt_lines, { { l, "SupermavenNesAdd" } })
    end
    vim.api.nvim_buf_set_extmark(bufnr, self.ns_id, line, 0, {
      virt_lines = virt_lines,
      virt_lines_above = false,
      priority = 200,
    })
  end
end

--- Render a replace suggestion (delete highlight + insert virtual text)
---@param bufnr integer
---@param edit NesEdit
function Nes:render_replace(bufnr, edit)
  -- Show the old text as deleted
  local delete_edit = vim.deepcopy(edit)
  delete_edit.kind = "delete"
  self:render_delete(bufnr, delete_edit)

  -- Show the new text as an insertion after the deleted range
  local end_line = edit.range["end"].line
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  if end_line >= 0 and end_line < line_count then
    local lines = vim.split(edit.new_text, "\n", { plain = true })
    local virt_lines = {}
    for _, l in ipairs(lines) do
      table.insert(virt_lines, { { l, "SupermavenNesAdd" } })
    end
    vim.api.nvim_buf_set_extmark(bufnr, self.ns_id, end_line, 0, {
      virt_lines = virt_lines,
      virt_lines_above = false,
      priority = 200,
    })
  end
end

--- Display an NES edit in the buffer
---@param bufnr integer
---@param edit NesEdit
function Nes:show(bufnr, edit)
  self:clear(bufnr)

  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  -- Cross-file edits: show a floating preview instead of inline extmarks
  if is_cross_file(bufnr, edit) then
    self:show_cross_file_preview(edit)
    local cursor = vim.api.nvim_win_get_cursor(0)
    set_state(bufnr, {
      edit = edit,
      bufnr = bufnr,
      ns_id = self.ns_id,
      cursor_moves = 0,
      last_cursor = cursor,
    })
    return
  end

  -- Same-file but off-screen: show a floating preview so the user knows an edit is pending
  if is_off_screen(edit) then
    -- Temporarily tag the edit with the current file name so the preview shows the location
    local preview_edit = vim.deepcopy(edit)
    local buf_name = vim.api.nvim_buf_get_name(bufnr)
    preview_edit.file_name = buf_name
    self:show_cross_file_preview(preview_edit)
    local cursor = vim.api.nvim_win_get_cursor(0)
    set_state(bufnr, {
      edit = edit,
      bufnr = bufnr,
      ns_id = self.ns_id,
      cursor_moves = 0,
      last_cursor = cursor,
    })
    return
  end

  if edit.kind == "delete" then
    self:render_delete(bufnr, edit)
  elseif edit.kind == "insert" then
    self:render_insert(bufnr, edit)
  elseif edit.kind == "replace" then
    self:render_replace(bufnr, edit)
  end

  local cursor = vim.api.nvim_win_get_cursor(0)
  set_state(bufnr, {
    edit = edit,
    bufnr = bufnr,
    ns_id = self.ns_id,
    cursor_moves = 0,
    last_cursor = cursor,
  })
end

--- Check if the current buffer has a pending NES edit
---@return boolean
function Nes:has_edit()
  local bufnr = vim.api.nvim_get_current_buf()
  local state = get_state(bufnr)
  return state ~= nil and state.edit ~= nil
end

--- Get the pending NES edit for the current buffer
---@return NesEdit | nil
function Nes:get_edit()
  local bufnr = vim.api.nvim_get_current_buf()
  local state = get_state(bufnr)
  if state then
    return state.edit
  end
  return nil
end

--- Apply the pending NES edit
---@return boolean true if an edit was applied
function Nes:accept()
  local bufnr = vim.api.nvim_get_current_buf()
  local state = get_state(bufnr)
  if not state or not state.edit then
    return false
  end

  local edit = state.edit
  self:clear(bufnr)

  -- Cross-file edits: open the target file first, then apply the edit there
  local target_bufnr = bufnr
  if edit.file_name and edit.file_name ~= "" then
    local target = vim.fn.fnamemodify(edit.file_name, ":p")
    local current = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":p")
    if target ~= current then
      target_bufnr = open_file(edit.file_name, edit.is_create_file or false)
    end
  end

  if edit.kind == "delete" then
    local start_line = edit.range.start.line
    local end_line = edit.range["end"].line
    local line_count = vim.api.nvim_buf_line_count(target_bufnr)
    if start_line >= 0 and end_line < line_count then
      vim.api.nvim_buf_set_lines(target_bufnr, start_line, end_line + 1, false, {})
    end
    return true
  elseif edit.kind == "insert" then
    local line = edit.range.start.line
    local col = edit.range.start.character
    vim.lsp.util.apply_text_edits({
      {
        range = {
          start = { line = line, character = col },
          ["end"] = { line = line, character = col },
        },
        newText = edit.new_text,
      },
    }, target_bufnr, "utf-8")
    return true
  elseif edit.kind == "replace" then
    vim.lsp.util.apply_text_edits({
      {
        range = {
          start = { line = edit.range.start.line, character = edit.range.start.character },
          ["end"] = { line = edit.range["end"].line, character = edit.range["end"].character },
        },
        newText = edit.new_text,
      },
    }, target_bufnr, "utf-8")
    return true
  end

  return false
end

--- Jump cursor to the location of the pending NES edit
---@return boolean true if cursor was moved
function Nes:jump_to_edit()
  local bufnr = vim.api.nvim_get_current_buf()
  local state = get_state(bufnr)
  if not state or not state.edit then
    return false
  end

  local edit = state.edit

  -- Cross-file jump: open the target file, transfer state, re-show
  if edit.file_name and edit.file_name ~= "" then
    local target = vim.fn.fnamemodify(edit.file_name, ":p")
    local current = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":p")
    if target ~= current then
      -- Clear state from the old buffer
      self:clear(bufnr)
      -- Open target file
      local new_bufnr = open_file(edit.file_name, edit.is_create_file or false)
      -- Re-show the edit in the new buffer (now it's same-file, so inline extmarks)
      local same_file_edit = vim.deepcopy(edit)
      same_file_edit.file_name = nil
      same_file_edit.is_create_file = nil
      vim.b[new_bufnr].supermaven_nes_jump = true
      self:show(new_bufnr, same_file_edit)
      -- Position cursor
      local target_line = edit.range.start.line + 1
      local target_col = edit.range.start.character
      pcall(vim.api.nvim_win_set_cursor, 0, { target_line, target_col })
      return true
    end
  end

  local target_line = edit.range.start.line + 1 -- 1-indexed
  local target_col = edit.range.start.character
  local cursor = vim.api.nvim_win_get_cursor(0)

  if cursor[1] == target_line and cursor[2] == target_col then
    return false -- already there
  end

  -- Set a flag to prevent auto-clearing on this cursor move
  vim.b[bufnr].supermaven_nes_jump = true
  vim.api.nvim_win_set_cursor(0, { target_line, target_col })
  return true
end

--- Accept the edit and jump to its end
---@return boolean
function Nes:accept_and_goto()
  local bufnr = vim.api.nvim_get_current_buf()
  local state = get_state(bufnr)
  if not state or not state.edit then
    return false
  end

  local edit = state.edit
  local applied = self:accept()
  if applied then
    -- The target buffer is now the current buffer (accept opens it for cross-file)
    local target_bufnr = vim.api.nvim_get_current_buf()
    -- Move cursor to end of the edit
    local new_lines = vim.split(edit.new_text, "\n", { plain = true })
    local target_line, target_col
    if edit.kind == "delete" then
      target_line = edit.range.start.line + 1
      target_col = 0
    else
      target_line = edit.range.start.line + #new_lines
      target_col = #new_lines[#new_lines]
      if #new_lines == 1 then
        target_col = target_col + edit.range.start.character
      end
    end

    local line_count = vim.api.nvim_buf_line_count(target_bufnr)
    if target_line > line_count then
      target_line = line_count
    end
    if target_line >= 1 then
      pcall(vim.api.nvim_win_set_cursor, 0, { target_line, target_col })
    end
  end
  return applied
end

--- Smart auto-clearing: track cursor movement and clear if too far away
---@param bufnr integer
function Nes:on_cursor_moved(bufnr)
  -- Don't clear if we just jumped to the edit
  if vim.b[bufnr].supermaven_nes_jump then
    vim.b[bufnr].supermaven_nes_jump = false
    return
  end

  local state = get_state(bufnr)
  if not state or not state.edit then
    return
  end

  local cursor = vim.api.nvim_win_get_cursor(0)
  local nes_config = config.nes or {}

  -- Skip distance-based clearing for cross-file edits (the edit line is in another file)
  if not is_cross_file(bufnr, state.edit) then
    local edit_line = state.edit.range.start.line + 1
    local distance = math.abs(cursor[1] - edit_line)
    local distance_threshold = nes_config.distance_threshold or 40
    if distance > distance_threshold then
      self:clear(bufnr)
      return
    end
  end

  -- Movement counting
  if state.last_cursor and (cursor[1] ~= state.last_cursor[1] or cursor[2] ~= state.last_cursor[2]) then
    state.cursor_moves = state.cursor_moves + 1
    state.last_cursor = cursor
    set_state(bufnr, state)

    local move_threshold = nes_config.move_count_threshold or 3
    if state.cursor_moves >= move_threshold then
      self:clear(bufnr)
    end
  end
end

--- Save an existing keymap before overriding it
---@param mode string
---@param lhs string
function Nes:save_prior_keymap(mode, lhs)
  local existing = vim.fn.maparg(lhs, mode, false, true)
  if existing and existing.lhs then
    self.prior_keymaps[mode .. ":" .. lhs] = existing
  end
end

--- Fall through to the original keymap or feed the raw key
---@param mode string
---@param lhs string
function Nes:fallback_keymap(mode, lhs)
  local key = mode .. ":" .. lhs
  local prior = self.prior_keymaps[key]
  if prior and prior.callback then
    prior.callback()
  elseif prior and prior.rhs and prior.rhs ~= "" then
    local rhs = vim.api.nvim_replace_termcodes(prior.rhs, true, false, true)
    vim.api.nvim_feedkeys(rhs, "n", false)
  else
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(lhs, true, false, true), "n", true)
  end
end

--- Set up NES autocommands and keymaps
function Nes:setup()
  local nes_config = config.nes or {}
  if not nes_config.enabled then
    return
  end

  setup_highlights()

  self.augroup = vim.api.nvim_create_augroup("supermaven_nes", { clear = true })

  -- Track cursor movement for smart auto-clearing
  vim.api.nvim_create_autocmd({ "CursorMoved" }, {
    group = self.augroup,
    callback = function(event)
      self:on_cursor_moved(event.buf)
    end,
  })

  -- Clear NES on insert mode entry (NES is for normal mode)
  vim.api.nvim_create_autocmd({ "InsertEnter" }, {
    group = self.augroup,
    callback = function(event)
      self:clear(event.buf)
    end,
  })

  -- Re-setup highlights on colorscheme change
  vim.api.nvim_create_autocmd({ "ColorScheme" }, {
    group = self.augroup,
    callback = function()
      setup_highlights()
    end,
  })

  -- Set up normal-mode keymaps
  if not config.disable_keymaps and nes_config.keymaps then
    local keymaps = nes_config.keymaps

    if keymaps.accept then
      self:save_prior_keymap("n", keymaps.accept)
      vim.keymap.set("n", keymaps.accept, function()
        if not self:accept_and_goto() then
          self:fallback_keymap("n", keymaps.accept)
        end
      end, { noremap = true, silent = true, desc = "Supermaven NES: accept edit" })
    end

    if keymaps.dismiss then
      self:save_prior_keymap("n", keymaps.dismiss)
      vim.keymap.set("n", keymaps.dismiss, function()
        if self:has_edit() then
          self:dismiss()
        else
          self:fallback_keymap("n", keymaps.dismiss)
        end
      end, { noremap = true, silent = true, desc = "Supermaven NES: dismiss edit" })
    end

    if keymaps.next then
      self:save_prior_keymap("n", keymaps.next)
      vim.keymap.set("n", keymaps.next, function()
        if self:has_edit() then
          self:jump_to_edit()
        else
          self:fallback_keymap("n", keymaps.next)
        end
      end, { noremap = true, silent = true, desc = "Supermaven NES: jump to edit" })
    end
  end

  log:debug("NES module initialized")
end

--- Tear down NES autocommands and clear all NES state
function Nes:teardown()
  self:close_preview()

  -- Clear extmarks from all loaded buffers
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) then
      self:clear(bufnr)
    end
  end

  if self.augroup then
    vim.api.nvim_del_augroup_by_id(self.augroup)
    self.augroup = nil
  end
end

return Nes
