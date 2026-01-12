-- Tests for the inline module - simulates terminal buffer parsing
local assert = require('luassert')
local describe = require('plenary.busted').describe
local it = require('plenary.busted').it
local before_each = require('plenary.busted').before_each
local after_each = require('plenary.busted').after_each

local inline = require('claude-code.inline')

-- Helper to create a mock buffer with terminal-like content
local function create_mock_buffer(lines)
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  return bufnr
end

-- Simulated terminal output from Claude Code (based on real output)
local MOCK_TERMINAL_SIMPLE = {
  '',
  '  Claude Code v2.1.5',
  '  Opus 4.5 · Claude Max',
  '  /home/mfranc',
  '',
  '> say hello',
  '',
  '● Hello! How can I help you today?',
  '',
  '>',
  '',
  'mfranc@mfranc-MS-7E06 mfranc git:(master*) [Opus 4.5]',
}

local MOCK_TERMINAL_MULTILINE = {
  '',
  '  Claude Code v2.1.5',
  '  Opus 4.5 · Claude Max',
  '  /home/mfranc',
  '',
  '> write a hello function',
  '',
  '● Here is a simple hello function:',
  '',
  '```lua',
  'function hello(name)',
  '  print("Hello, " .. name .. "!")',
  'end',
  '```',
  '',
  '>',
  '',
  'mfranc@mfranc-MS-7E06 mfranc git:(master*) [Opus 4.5]',
}

local MOCK_TERMINAL_WITH_ANSI = {
  '',
  '\027[1m  Claude Code v2.1.5\027[0m',
  '\027[32m  Opus 4.5\027[0m · Claude Max',
  '  /home/mfranc',
  '',
  '\027[36m>\027[0m say hello',
  '',
  '\027[33m●\027[0m Hello! How can I help you today?',
  '',
  '\027[36m>\027[0m',
  '',
  'mfranc@mfranc-MS-7E06 mfranc git:(master*) [Opus 4.5]',
}

local MOCK_TERMINAL_WORKING = {
  '',
  '  Claude Code v2.1.5',
  '  Opus 4.5 · Claude Max',
  '  /home/mfranc',
  '',
  '> do something complex',
  '',
  '+ Analyzing... (ctrl+c to interrupt)',
  '',
}

describe('inline', function()
  describe('_internal.strip_ansi', function()
    it('should remove ANSI color codes', function()
      local input = '\027[32mHello\027[0m World'
      local result = inline._internal.strip_ansi(input)
      assert.are.equal('Hello World', result)
    end)

    it('should handle multiple ANSI codes', function()
      local input = '\027[1m\027[32mBold Green\027[0m Normal'
      local result = inline._internal.strip_ansi(input)
      assert.are.equal('Bold Green Normal', result)
    end)

    it('should return empty string for nil', function()
      local result = inline._internal.strip_ansi(nil)
      assert.are.equal('', result)
    end)

    it('should pass through plain text unchanged', function()
      local input = 'Hello World'
      local result = inline._internal.strip_ansi(input)
      assert.are.equal('Hello World', result)
    end)
  end)

  describe('_internal.is_claude_prompt', function()
    it('should detect simple > prompt', function()
      assert.is_true(inline._internal.is_claude_prompt('>'))
      assert.is_true(inline._internal.is_claude_prompt('> '))
      assert.is_true(inline._internal.is_claude_prompt(' > '))
    end)

    it('should detect ❯ prompt', function()
      assert.is_true(inline._internal.is_claude_prompt('❯'))
      assert.is_true(inline._internal.is_claude_prompt('❯ '))
    end)

    it('should detect > ) style prompt', function()
      assert.is_true(inline._internal.is_claude_prompt('> )'))
      assert.is_true(inline._internal.is_claude_prompt('❯ )'))
    end)

    it('should NOT detect shell prompts', function()
      assert.is_false(inline._internal.is_claude_prompt('mfranc@host git:(master) [Opus 4.5]'))
      assert.is_false(inline._internal.is_claude_prompt('user@machine:~$'))
      assert.is_false(inline._internal.is_claude_prompt('/home/user $'))
    end)

    it('should NOT detect user input lines', function()
      assert.is_false(inline._internal.is_claude_prompt('> say hello'))
      assert.is_false(inline._internal.is_claude_prompt('> write a function'))
    end)

    it('should NOT detect response lines', function()
      assert.is_false(inline._internal.is_claude_prompt('● Hello! How can I help you?'))
      assert.is_false(inline._internal.is_claude_prompt('Here is the code:'))
    end)

    it('should NOT detect empty lines', function()
      assert.is_false(inline._internal.is_claude_prompt(''))
      assert.is_false(inline._internal.is_claude_prompt('   '))
    end)

    it('should handle ANSI codes in prompt', function()
      assert.is_true(inline._internal.is_claude_prompt('\027[36m>\027[0m'))
    end)
  end)

  describe('_internal.clean_response_line', function()
    it('should remove leading bullet point', function()
      local result = inline._internal.clean_response_line('● Hello!')
      assert.are.equal('Hello!', result)
    end)

    it('should remove leading > prompt', function()
      local result = inline._internal.clean_response_line('> Hello!')
      assert.are.equal('Hello!', result)
    end)

    it('should strip ANSI codes', function()
      local result = inline._internal.clean_response_line('\027[33m● Hello!\027[0m')
      assert.are.equal('Hello!', result)
    end)

    it('should pass through normal text', function()
      local result = inline._internal.clean_response_line('Normal text here')
      assert.are.equal('Normal text here', result)
    end)
  end)

  describe('get_terminal_response', function()
    local bufnr

    after_each(function()
      if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
        vim.api.nvim_buf_delete(bufnr, { force = true })
      end
    end)

    it('should extract simple response', function()
      bufnr = create_mock_buffer(MOCK_TERMINAL_SIMPLE)
      local mock_session = { bufnr = bufnr }

      local response = inline.get_terminal_response(mock_session, 'say hello')

      assert.is_not_nil(response)
      assert.are.equal('Hello! How can I help you today?', response)
    end)

    it('should extract multiline response', function()
      bufnr = create_mock_buffer(MOCK_TERMINAL_MULTILINE)
      local mock_session = { bufnr = bufnr }

      local response = inline.get_terminal_response(mock_session, 'write a hello function')

      assert.is_not_nil(response)
      assert.is_truthy(response:match('Here is a simple hello function'))
      assert.is_truthy(response:match('function hello'))
    end)

    it('should handle ANSI codes in terminal output', function()
      bufnr = create_mock_buffer(MOCK_TERMINAL_WITH_ANSI)
      local mock_session = { bufnr = bufnr }

      local response = inline.get_terminal_response(mock_session, 'say hello')

      assert.is_not_nil(response)
      assert.are.equal('Hello! How can I help you today?', response)
    end)

    it('should return nil when Claude is still working', function()
      bufnr = create_mock_buffer(MOCK_TERMINAL_WORKING)
      local mock_session = { bufnr = bufnr }

      -- The response parser won't find a complete response yet
      local response = inline.get_terminal_response(mock_session, 'do something complex')

      -- Should return nil because there's no response yet (just working indicator)
      assert.is_nil(response)
    end)

    it('should return nil for invalid session', function()
      local response = inline.get_terminal_response(nil, 'test')
      assert.is_nil(response)
    end)

    it('should return nil for invalid buffer', function()
      local mock_session = { bufnr = 99999 }
      local response = inline.get_terminal_response(mock_session, 'test')
      assert.is_nil(response)
    end)
  end)
end)
