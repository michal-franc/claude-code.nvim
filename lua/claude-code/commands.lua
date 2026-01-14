---@mod claude-code.commands Command registration for claude-code.nvim
---@brief [[
--- This module provides command registration and handling for claude-code.nvim.
--- It defines user commands and command handlers.
---@brief ]]

local M = {}

--- @type table<string, function> List of available commands and their handlers
M.commands = {}

--- Register commands for the claude-code plugin
--- @param claude_code table The main plugin module
function M.register_commands(claude_code)
  -- Create the user command for toggling Claude Code
  vim.api.nvim_create_user_command('ClaudeCode', function()
    claude_code.toggle()
  end, { desc = 'Toggle Claude Code terminal' })

  -- Create commands for each command variant
  for variant_name, variant_args in pairs(claude_code.config.command_variants) do
    if variant_args ~= false then
      -- Convert variant name to PascalCase for command name (e.g., "continue" -> "Continue")
      local capitalized_name = variant_name:gsub('^%l', string.upper)
      local cmd_name = 'ClaudeCode' .. capitalized_name

      vim.api.nvim_create_user_command(cmd_name, function()
        claude_code.toggle_with_variant(variant_name)
      end, { desc = 'Toggle Claude Code terminal with ' .. variant_name .. ' option' })
    end
  end

  -- Add version command
  vim.api.nvim_create_user_command('ClaudeCodeVersion', function()
    vim.notify('Claude Code version: ' .. claude_code.version(), vim.log.levels.INFO)
  end, { desc = 'Display Claude Code version' })

  -- Add inline editing commands if enabled
  if claude_code.config.inline.enable then
    vim.api.nvim_create_user_command('ClaudeCodeInline', function()
      claude_code.inline_prompt()
    end, { desc = 'Open Claude Code inline prompt' })

    vim.api.nvim_create_user_command('ClaudeCodeInlineVisual', function()
      claude_code.inline_prompt({ visual = true })
    end, { desc = 'Open Claude Code inline prompt with visual selection', range = true })

    vim.api.nvim_create_user_command('ClaudeCodeInlineToggle', function()
      claude_code.inline_toggle()
    end, { desc = 'Toggle Claude Code inline terminal visibility' })

    vim.api.nvim_create_user_command('ClaudeCodeInlineClear', function()
      claude_code.inline_clear()
    end, { desc = 'Clear Claude Code inline session' })
  end
end

return M
