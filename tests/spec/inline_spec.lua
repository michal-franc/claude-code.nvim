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

-- Multiple conversation turns - should return only the LATEST response
local MOCK_TERMINAL_MULTIPLE_TURNS = {
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
  '> say hello hello',
  '',
  '● Hello hello!',
  '',
  '>',
  '',
  '> say hello',
  '',
  '● Hello!',
  '',
  '>',
  '',
  'mfranc@mfranc-MS-7E06 mfranc git:(master*) [Opus 4.5]',
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

    it('should return only the latest response with multiple conversation turns', function()
      bufnr = create_mock_buffer(MOCK_TERMINAL_MULTIPLE_TURNS)
      local mock_session = { bufnr = bufnr }

      -- Same prompt "say hello" appears 3 times, should get the LATEST response
      local response = inline.get_terminal_response(mock_session, 'say hello')

      assert.is_not_nil(response)
      -- Should be "Hello!" (the third/latest response), NOT "Hello! How can I help you today?" (first)
      assert.are.equal('Hello!', response)
    end)
  end)

  describe('_internal.extract_selection', function()
    it('should extract character-wise selection on single line (v mode)', function()
      local lines = { 'Hello World' }
      local result = inline._internal.extract_selection(lines, 7, 11, 'v')
      assert.are.equal('World', result)
    end)

    it('should extract character-wise selection across multiple lines (v mode)', function()
      local lines = { 'First line here', 'Second line', 'Third line end' }
      -- Select from column 7 of first line to column 5 of last line
      local result = inline._internal.extract_selection(lines, 7, 5, 'v')
      assert.are.equal('line here\nSecond line\nThird', result)
    end)

    it('should extract full lines for line-wise selection (V mode)', function()
      local lines = { 'First line', 'Second line', 'Third line' }
      -- In V mode, columns don't matter - full lines are returned
      local result = inline._internal.extract_selection(lines, 1, 100, 'V')
      assert.are.equal('First line\nSecond line\nThird line', result)
    end)

    it('should extract single full line for line-wise selection (V mode)', function()
      local lines = { 'Only this line' }
      local result = inline._internal.extract_selection(lines, 1, 100, 'V')
      assert.are.equal('Only this line', result)
    end)

    it('should extract block selection (Ctrl-V mode)', function()
      local lines = { 'AAABBBCCC', 'DDDEEEFFF', 'GGGHHHIII' }
      -- Select columns 4-6 (BBB, EEE, HHH)
      local result = inline._internal.extract_selection(lines, 4, 6, '\22')
      assert.are.equal('BBB\nEEE\nHHH', result)
    end)

    it('should handle empty lines array', function()
      local result = inline._internal.extract_selection({}, 1, 10, 'v')
      assert.are.equal('', result)
    end)

    it('should not modify original lines array', function()
      local lines = { 'Hello World' }
      inline._internal.extract_selection(lines, 7, 11, 'v')
      assert.are.equal('Hello World', lines[1])
    end)
  end)

  describe('build_prompt', function()
    it('should build prompt with selection', function()
      local prompt = inline.build_prompt('make it shorter', 'Hello World', '/path/to/file.lua')

      assert.is_truthy(prompt:match('You are an assistant helping a user in nvim'))
      assert.is_truthy(prompt:match('File being edited: /path/to/file.lua'))
      assert.is_truthy(prompt:match('Selected text: Hello World'))
      assert.is_truthy(prompt:match('User request: make it shorter'))
    end)

    it('should build prompt without selection', function()
      local prompt = inline.build_prompt('write hello world', nil, '/path/to/file.lua')

      assert.is_truthy(prompt:match('Selected text: none'))
      assert.is_truthy(prompt:match('User request: write hello world'))
    end)

    it('should handle multiline selection', function()
      local selection = 'line 1\nline 2\nline 3'
      local prompt = inline.build_prompt('refactor this', selection, '/path/to/file.lua')

      assert.is_truthy(prompt:match('line 1\nline 2\nline 3'))
    end)

    it('should include important instructions', function()
      local prompt = inline.build_prompt('test', 'code', '/file.lua')

      assert.is_truthy(prompt:match('IMPORTANT: Only respond with text'))
      assert.is_truthy(prompt:match('Do NOT write to or modify any files'))
      assert.is_truthy(prompt:match('Your response will be inserted into the document'))
    end)
  end)

  describe('visual selection integration', function()
    it('should build correct prompt with character-wise selection', function()
      -- Simulate v mode selection of "World" from "Hello World"
      local lines = { 'Hello World' }
      local selection = inline._internal.extract_selection(lines, 7, 11, 'v')
      local prompt = inline.build_prompt('translate to French', selection, '/test.txt')

      assert.are.equal('World', selection)
      assert.is_truthy(prompt:match('Selected text: World'))
      assert.is_truthy(prompt:match('User request: translate to French'))
    end)

    it('should build correct prompt with line-wise selection', function()
      -- Simulate V mode selection of multiple lines
      local lines = { 'function hello()', '  print("Hello")', 'end' }
      local selection = inline._internal.extract_selection(lines, 1, 100, 'V')
      local prompt = inline.build_prompt('add documentation', selection, '/code.lua')

      assert.is_truthy(selection:match('function hello'))
      assert.is_truthy(selection:match('print'))
      assert.is_truthy(selection:match('end'))
      assert.is_truthy(prompt:match('User request: add documentation'))
    end)

    it('should build correct prompt with block selection', function()
      -- Simulate Ctrl-V block selection
      local lines = { 'name: John', 'name: Jane', 'name: Jack' }
      local selection = inline._internal.extract_selection(lines, 7, 10, '\22')
      local prompt = inline.build_prompt('make uppercase', selection, '/data.txt')

      assert.are.equal('John\nJane\nJack', selection)
      assert.is_truthy(prompt:match('Selected text: John\nJane\nJack'))
    end)

    it('should build correct prompt without selection (normal mode)', function()
      local prompt = inline.build_prompt('write a hello function', nil, '/new.lua')

      assert.is_truthy(prompt:match('Selected text: none'))
      assert.is_truthy(prompt:match('User request: write a hello function'))
      assert.is_truthy(prompt:match('File being edited: /new.lua'))
    end)
  end)

  describe('format_response', function()
    it('should wrap response in Claude code block', function()
      local response = 'Hello! How can I help you today?'
      local formatted = inline.format_response(response)

      assert.are.equal('```Claude\nHello! How can I help you today?\n```', formatted)
    end)

    it('should handle multiline responses', function()
      local response = 'Here is the code:\n\nfunction hello()\n  print("Hello")\nend'
      local formatted = inline.format_response(response)

      local expected = '```Claude\nHere is the code:\n\nfunction hello()\n  print("Hello")\nend\n```'
      assert.are.equal(expected, formatted)
    end)

    it('should handle empty response', function()
      local formatted = inline.format_response('')
      assert.are.equal('```Claude\n\n```', formatted)
    end)
  end)

  describe('spinner timer', function()
    local test_bufnr

    before_each(function()
      test_bufnr = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(test_bufnr, 0, -1, false, { 'line 1', 'line 2' })
    end)

    after_each(function()
      if test_bufnr and vim.api.nvim_buf_is_valid(test_bufnr) then
        vim.api.nvim_buf_delete(test_bufnr, { force = true })
      end
      -- Clean up any pending requests
      inline.pending_requests = {}
    end)

    it('should not error when replace_placeholder is called multiple times (race condition)', function()
      -- Switch to test buffer
      vim.api.nvim_set_current_buf(test_bufnr)
      vim.api.nvim_win_set_cursor(0, { 1, 0 })

      -- Create a placeholder with spinner
      local request = inline.insert_placeholder('test prompt', {
        inline = {
          spinner = {
            frames = { '⠋', '⠙', '⠹' },
            interval = 50,
            text = 'Testing...',
          },
        },
      })

      assert.is_not_nil(request)
      assert.is_not_nil(request.spinner_timer)

      -- Call replace_placeholder multiple times in quick succession
      -- This simulates the race condition where callbacks might still be pending
      local success = true
      local err_msg = nil

      for i = 1, 3 do
        local ok, err = pcall(function()
          inline.replace_placeholder(request, 'Response ' .. i)
        end)
        if not ok then
          success = false
          err_msg = err
          break
        end
      end

      assert.is_true(success, 'replace_placeholder should not error: ' .. (err_msg or ''))
      assert.is_nil(request.spinner_timer, 'spinner_timer should be nil after replace')
    end)

    it('should safely stop timer when buffer is deleted', function()
      -- Switch to test buffer
      vim.api.nvim_set_current_buf(test_bufnr)
      vim.api.nvim_win_set_cursor(0, { 1, 0 })

      -- Create a placeholder with spinner
      local request = inline.insert_placeholder('test prompt', {
        inline = {
          spinner = {
            frames = { '⠋', '⠙', '⠹' },
            interval = 50,
            text = 'Testing...',
          },
        },
      })

      assert.is_not_nil(request)
      assert.is_not_nil(request.spinner_timer)

      -- Delete the buffer while spinner is running
      local ok, err = pcall(function()
        vim.api.nvim_buf_delete(test_bufnr, { force = true })
      end)

      assert.is_true(ok, 'Buffer deletion should not error: ' .. (err or ''))
      test_bufnr = nil -- Mark as deleted so after_each doesn't try again

      -- Give the timer a chance to fire and handle the deleted buffer
      vim.wait(100, function()
        return false
      end)

      -- Cleanup should not error
      ok, err = pcall(function()
        inline.replace_placeholder(request, 'Response')
      end)
      assert.is_true(ok, 'replace_placeholder after buffer delete should not error: ' .. (err or ''))
    end)

    it('should handle cleanup with multiple pending timers', function()
      -- Create multiple buffers and placeholders
      local buffers = {}
      local requests = {}

      for i = 1, 3 do
        local buf = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'line 1' })
        vim.api.nvim_set_current_buf(buf)
        vim.api.nvim_win_set_cursor(0, { 1, 0 })

        local req = inline.insert_placeholder('prompt ' .. i, {
          inline = {
            spinner = {
              frames = { '⠋', '⠙' },
              interval = 50,
              text = 'Test',
            },
          },
        })

        table.insert(buffers, buf)
        table.insert(requests, req)
      end

      -- Verify all timers are running
      for _, req in ipairs(requests) do
        assert.is_not_nil(req.spinner_timer)
      end

      -- Cleanup should not error
      local ok, err = pcall(function()
        inline.cleanup()
      end)

      assert.is_true(ok, 'cleanup should not error: ' .. (err or ''))
      assert.are.equal(0, #inline.pending_requests, 'pending_requests should be empty after cleanup')

      -- Clean up buffers
      for _, buf in ipairs(buffers) do
        if vim.api.nvim_buf_is_valid(buf) then
          vim.api.nvim_buf_delete(buf, { force = true })
        end
      end
    end)
  end)
end)
