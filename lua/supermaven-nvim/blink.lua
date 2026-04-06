--- blink.cmp completion source for supermaven-nvim
--- Register via blink.cmp sources config:
---   sources = {
---     default = { "supermaven", ... },
---     providers = {
---       supermaven = {
---         name = "Supermaven",
---         module = "supermaven-nvim.blink",
---       },
---     },
---   }
local CompletionPreview = require("supermaven-nvim.completion_preview")

---@class SupermavenBlinkSource
local source = {}

local label_text = function(text)
  local shorten = function(str)
    local short_prefix = string.sub(str, 0, 20)
    local short_suffix = string.sub(str, string.len(str) - 15, string.len(str))
    return short_prefix .. " ... " .. short_suffix
  end

  text = text:gsub("^%s*", "")
  return string.len(text) > 40 and shorten(text) or text
end

function source.new(_, _)
  local self = setmetatable({}, { __index = source })
  return self
end

function source:enabled()
  return true
end

function source:get_trigger_characters()
  return { "*" }
end

function source:get_completions(ctx, callback)
  local inlay_instance = CompletionPreview:get_inlay_instance()

  if inlay_instance == nil or inlay_instance.is_active == false then
    callback({
      items = {},
      is_incomplete_forward = true,
      is_incomplete_backward = true,
    })
    return
  end

  local cursor = ctx.cursor
  local completion_text = inlay_instance.line_before_cursor .. inlay_instance.completion_text
  local preview_text = completion_text
  local split = vim.split(completion_text, "\n", { plain = true })
  local label = label_text(split[1])

  local insert_text_format = vim.lsp.protocol.InsertTextFormat.PlainText
  if #split > 1 then
    insert_text_format = vim.lsp.protocol.InsertTextFormat.Snippet
  end

  local range = {
    start = {
      line = cursor[1] - 1, -- blink passes 1-indexed cursor, LSP range is 0-indexed
      character = math.max(cursor[2] - inlay_instance.prior_delete - #inlay_instance.line_before_cursor, 0),
    },
    ["end"] = {
      line = cursor[1] - 1,
      character = vim.fn.col("$") - 1,
    },
  }

  ---@type lsp.CompletionItem[]
  local items = {
    {
      label = label,
      kind = require("blink.cmp.types").CompletionItemKind.Text,
      score_offset = 100,
      insertTextFormat = insert_text_format,
      textEdit = {
        newText = completion_text,
        range = range,
      },
      documentation = {
        kind = "markdown",
        value = "```" .. vim.bo.filetype .. "\n" .. preview_text .. "\n```",
      },
    },
  }

  callback({
    items = items,
    is_incomplete_forward = true,
    is_incomplete_backward = true,
  })
end

function source:resolve(item, callback)
  CompletionPreview:dispose_inlay()
  callback(item)
end

return source
