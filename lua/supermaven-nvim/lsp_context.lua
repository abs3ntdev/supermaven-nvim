--- LSP context bridge for supermaven-nvim
--- Queries LSP servers for definitions/references near the cursor and sends
--- the source files to the sm-agent so it has richer type/signature context.
local config = require("supermaven-nvim.config")
local log = require("supermaven-nvim.logger")
local u = require("supermaven-nvim.util")

local M = {
  --- Cache of file paths already sent in this session to avoid redundant sends
  ---@type table<string, integer> path -> timestamp (loop.now())
  sent_paths = {},
  --- Cooldown: don't re-send the same file within this many ms
  RESEND_COOLDOWN_MS = 60000,
  --- Maximum files to send per trigger to avoid flooding
  MAX_FILES_PER_TRIGGER = 10,
  --- Debounce timer
  timer = nil,
  --- Debounce delay in ms
  DEBOUNCE_MS = 500,
}

--- Check if LSP context enrichment is enabled
---@return boolean
local function is_enabled()
  local lsp_config = config.lsp_context
  if lsp_config == nil then
    return false
  end
  return lsp_config.enabled == true
end

--- Get the binary handler (lazy require to avoid circular deps)
---@return table
local function get_binary()
  return require("supermaven-nvim.binary.binary_handler")
end

--- Send a file's contents to the agent if not recently sent
---@param file_path string absolute path
local function send_file(file_path)
  if not file_path or file_path == "" then
    return
  end

  local binary = get_binary()
  if not binary:is_running() then
    return
  end

  -- Check cooldown
  local now = u.uv.now()
  local last_sent = M.sent_paths[file_path]
  if last_sent and (now - last_sent) < M.RESEND_COOLDOWN_MS then
    return
  end

  -- Read the file — prefer buffer contents if loaded, else read from disk
  local text
  local bufnr = vim.fn.bufnr(file_path)
  if bufnr ~= -1 and vim.api.nvim_buf_is_loaded(bufnr) then
    text = u.get_text(bufnr)
  else
    local fd = io.open(file_path, "r")
    if not fd then
      return
    end
    text = fd:read("*a")
    fd:close()
  end

  if not text or #text > binary.HARD_SIZE_LIMIT then
    return
  end

  binary:document_changed(file_path, text)
  M.sent_paths[file_path] = now
end

--- Extract unique file paths from LSP location results
---@param results table[] LSP Location or LocationLink items
---@return string[] unique absolute file paths
local function extract_paths(results)
  local seen = {}
  local paths = {}
  for _, item in ipairs(results) do
    local uri = item.uri or item.targetUri
    if uri then
      local path = vim.uri_to_fname(uri)
      if path and not seen[path] then
        seen[path] = true
        paths[#paths + 1] = path
      end
    end
  end
  return paths
end

--- Check if any LSP client attached to a buffer supports a given method
---@param bufnr integer
---@param method string
---@return boolean
local function has_capability(bufnr, method)
  local clients = vim.lsp.get_clients({ bufnr = bufnr, method = method })
  return #clients > 0
end

--- Safely send an LSP request only if a capable client exists
---@param bufnr integer
---@param method string
---@param params table
---@param callback fun(results: table)
local function safe_request(bufnr, method, params, callback)
  if not has_capability(bufnr, method) then
    return
  end
  pcall(vim.lsp.buf_request_all, bufnr, method, params, callback)
end

--- Query LSP for definitions/type definitions of the symbol under cursor
--- and send those files to the agent
---@param bufnr integer
---@param cursor integer[] {row, col} 1-indexed
local function query_definitions(bufnr, cursor)
  local clients = vim.lsp.get_clients({ bufnr = bufnr })
  if #clients == 0 then
    return
  end

  local params = vim.lsp.util.make_position_params(0, clients[1].offset_encoding or "utf-16")
  local files_sent = 0
  local current_file = vim.api.nvim_buf_get_name(bufnr)

  --- Process results from an LSP request
  ---@param results table
  local function process_results(results)
    if not results then
      return
    end
    for _, result in pairs(results) do
      if result and result.result then
        local items = result.result
        -- Normalize: single result vs array
        if items.uri or items.targetUri then
          items = { items }
        end
        local paths = extract_paths(items)
        for _, path in ipairs(paths) do
          if path ~= current_file and files_sent < M.MAX_FILES_PER_TRIGGER then
            send_file(path)
            files_sent = files_sent + 1
          end
        end
      end
    end
  end

  safe_request(bufnr, "textDocument/definition", params, process_results)
  safe_request(bufnr, "textDocument/typeDefinition", params, process_results)
end

--- Query LSP for document symbols and send definition files for imported types
---@param bufnr integer
local function query_document_symbols(bufnr)
  if not has_capability(bufnr, "textDocument/documentSymbol") then
    return
  end

  local clients = vim.lsp.get_clients({ bufnr = bufnr })
  if #clients == 0 then
    return
  end

  local params = { textDocument = vim.lsp.util.make_text_document_params(bufnr) }

  safe_request(bufnr, "textDocument/documentSymbol", params, function(results)
    if not results then
      return
    end

    local files_sent = 0
    local current_file = vim.api.nvim_buf_get_name(bufnr)

    for _, result in pairs(results) do
      if result and result.result then
        for _, symbol in ipairs(result.result) do
          if files_sent >= M.MAX_FILES_PER_TRIGGER then
            break
          end

          -- SymbolKind: 2=Module, 3=Namespace, 5=Class, 11=Function, 13=Variable
          local kind = symbol.kind
          if kind == 2 or kind == 3 or kind == 5 then
            local range = symbol.selectionRange or symbol.range
            if range then
              local sym_params = {
                textDocument = vim.lsp.util.make_text_document_params(bufnr),
                position = range.start,
              }
              safe_request(bufnr, "textDocument/definition", sym_params, function(def_results)
                if not def_results then
                  return
                end
                for _, def_result in pairs(def_results) do
                  if def_result and def_result.result then
                    local items = def_result.result
                    if items.uri or items.targetUri then
                      items = { items }
                    end
                    local paths = extract_paths(items)
                    for _, path in ipairs(paths) do
                      if path ~= current_file and files_sent < M.MAX_FILES_PER_TRIGGER then
                        send_file(path)
                        files_sent = files_sent + 1
                      end
                    end
                  end
                end
              end)
            end
          end
        end
      end
    end
  end)
end

--- Trigger context enrichment for a buffer (debounced)
---@param bufnr integer
---@param cursor integer[]
function M.enrich(bufnr, cursor)
  if not is_enabled() then
    return
  end

  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  -- Only enrich for buffers with active LSP clients
  local clients = vim.lsp.get_clients({ bufnr = bufnr })
  if #clients == 0 then
    return
  end

  -- Debounce: cancel any pending enrichment
  if M.timer then
    M.timer:stop()
    if not M.timer:is_closing() then
      M.timer:close()
    end
    M.timer = nil
  end

  M.timer = u.uv.new_timer()
  M.timer:start(M.DEBOUNCE_MS, 0, function()
    M.timer:stop()
    if not M.timer:is_closing() then
      M.timer:close()
    end
    M.timer = nil

    vim.schedule(function()
      if not vim.api.nvim_buf_is_valid(bufnr) then
        return
      end
      query_definitions(bufnr, cursor)
      query_document_symbols(bufnr)
    end)
  end)
end

--- Clear the sent-paths cache (e.g. on binary restart)
function M.reset()
  M.sent_paths = {}
  if M.timer then
    M.timer:stop()
    if not M.timer:is_closing() then
      M.timer:close()
    end
    M.timer = nil
  end
end

return M
