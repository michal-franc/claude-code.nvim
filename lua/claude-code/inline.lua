---@mod claude-code.inline Inline editing for claude-code.nvim
---@brief [[
--- This module provides inline editing functionality using a popup prompt
--- with a hidden terminal for Claude Code interactions.
---@brief ]]

local M = {}

local terminal = require('claude-code.terminal')

--- Inline session state
--- @class InlineSession
--- @field bufnr number|nil Buffer number of the terminal
--- @field job_id number|nil Job ID for channel communication
--- @field win_id number|nil Window ID when terminal is visible
--- @field instance_id string Instance identifier (git root or cwd)
--- @field ready boolean Whether Claude is ready to receive input

--- Active inline sessions, keyed by instance_id
M.sessions = {}

--- Namespace for extmarks
M.ns_id = vim.api.nvim_create_namespace('claude_code_inline')

--- Pending inline requests (placeholder info)
--- @class InlineRequest
--- @field bufnr number Buffer where placeholder was inserted
--- @field extmark_id number Extmark ID tracking the placeholder position
--- @field prompt string The original prompt sent to Claude
--- @field spinner_timer userdata|nil Timer for spinner animation
--- @field spinner_frame number Current spinner frame index
M.pending_requests = {}

--- Placeholder text shown while waiting for Claude (fallback)
M.placeholder_text = '-- [Claude is thinking...]'

--- Active spinner configuration (set during prompt)
M.active_spinner_config = nil

--- Strip ANSI escape codes from a string
--- @param str string The string to strip
--- @return string stripped The string without ANSI codes
local function strip_ansi(str)
  if not str then
    return ''
  end
  -- Remove ANSI escape sequences
  str = str:gsub('\027%[%d*;?%d*;?%d*;?%d*;?%d*m', '') -- Color codes
  str = str:gsub('\027%[%d*[ABCDEFGJKST]', '') -- Cursor movement
  str = str:gsub('\027%[%?%d*[hl]', '') -- Mode changes
  str = str:gsub('\027%]%d*;[^\007]*\007', '') -- OSC sequences
  str = str:gsub('\027%[%d*;%d*[Hf]', '') -- Cursor position
  str = str:gsub('\027%[[%d;]*m', '') -- SGR sequences
  str = str:gsub('\027%[K', '') -- Erase line
  str = str:gsub('\027', '') -- Any remaining escapes
  str = str:gsub('%c', '') -- Control characters
  return str
end

--- Get instance identifier based on configuration
--- @param config table Plugin configuration
--- @param git table Git module
--- @return string instance_id Instance identifier
local function get_instance_id(config, git)
  if config.git.multi_instance then
    if config.git.use_git_root then
      local git_root = git.get_git_root()
      if git_root then
        return git_root
      end
    end
    return vim.fn.getcwd()
  else
    return 'global'
  end
end

--- Check if a session is valid (buffer exists and job is running)
--- @param session InlineSession The session to check
--- @return boolean is_valid True if session is valid
local function is_valid_session(session)
  if not session or not session.bufnr then
    return false
  end

  if not vim.api.nvim_buf_is_valid(session.bufnr) then
    return false
  end

  -- Try to get job_id from buffer if not set
  if not session.job_id then
    session.job_id = vim.b[session.bufnr].terminal_job_id
  end

  if not session.job_id then
    return false
  end

  -- Check if job is still running
  local status = vim.fn.jobwait({ session.job_id }, 0)[1]
  return status == -1
end

--- Create a hidden terminal buffer for inline editing
--- @param config table Plugin configuration
--- @param git table Git module
--- @param instance_id string Instance identifier
--- @return InlineSession session The created session
local function create_hidden_terminal(config, git, instance_id)
  -- Save current window to restore later
  local current_win = vim.api.nvim_get_current_win()

  -- Create unlisted, scratch buffer
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value('bufhidden', 'hide', { buf = bufnr })

  -- Create a properly-sized floating window off-screen (terminal needs good dimensions)
  -- Position it far outside visible area so user doesn't see it
  local temp_win = vim.api.nvim_open_win(bufnr, true, {
    relative = 'editor',
    width = 80,
    height = 24,
    row = 9999, -- Position far off-screen
    col = 9999,
    style = 'minimal',
    focusable = true,
    noautocmd = true,
  })

  -- Build command (reuse terminal.lua helper)
  local cmd = terminal.build_command_with_git_root(config, git, config.command)

  -- Run termopen - this starts the terminal process
  local job_id = vim.fn.termopen(cmd)

  -- Set buffer name
  local buffer_name = 'claude-code-inline-' .. instance_id:gsub('[^%w%-_]', '-')
  pcall(function()
    vim.api.nvim_buf_set_name(bufnr, buffer_name)
  end)

  -- Close the temporary window after terminal initializes
  vim.defer_fn(function()
    if temp_win and vim.api.nvim_win_is_valid(temp_win) then
      vim.api.nvim_win_close(temp_win, true)
    end
  end, 100)

  -- Restore focus to original window
  if vim.api.nvim_win_is_valid(current_win) then
    vim.api.nvim_set_current_win(current_win)
  end

  -- Create the session object
  local session = {
    bufnr = bufnr,
    job_id = job_id,
    win_id = nil,
    instance_id = instance_id,
    ready = false,
  }

  return session
end

--- Show the inline terminal window
--- @param session InlineSession The inline session
--- @param config table Plugin configuration
local function show_terminal(session, config)
  if not session or not session.bufnr then
    return
  end

  -- Check if already visible
  if session.win_id and vim.api.nvim_win_is_valid(session.win_id) then
    -- Focus the existing window
    vim.api.nvim_set_current_win(session.win_id)
    return
  end

  -- Create window based on config
  if config.window.position == 'float' then
    session.win_id = terminal.create_float(config, session.bufnr)
  else
    terminal.create_split(config.window.position, config, session.bufnr)
    session.win_id = vim.api.nvim_get_current_win()
  end

  -- Configure window options
  if session.win_id then
    terminal.configure_window_options(session.win_id, config)
  end
end

--- Hide the inline terminal window
--- @param session InlineSession The inline session
local function hide_terminal(session)
  if session and session.win_id and vim.api.nvim_win_is_valid(session.win_id) then
    vim.api.nvim_win_close(session.win_id, true)
    session.win_id = nil
  end
end

--- Get or create an inline session for the current context
--- @param claude_code table Main plugin module
--- @param config table Plugin configuration
--- @param git table Git module
--- @return InlineSession session The inline session
function M.get_or_create_session(claude_code, config, git)
  local instance_id = get_instance_id(config, git)

  local session = M.sessions[instance_id]

  -- Check if existing session is still valid
  if session then
    if is_valid_session(session) then
      return session
    else
      -- Clean up invalid session
      if session.bufnr and vim.api.nvim_buf_is_valid(session.bufnr) then
        pcall(function()
          vim.api.nvim_buf_delete(session.bufnr, { force = true })
        end)
      end
      M.sessions[instance_id] = nil
    end
  end

  -- Create new session
  session = create_hidden_terminal(config, git, instance_id)
  M.sessions[instance_id] = session

  -- Mark as ready after startup delay
  vim.defer_fn(function()
    if M.sessions[instance_id] and M.sessions[instance_id] == session then
      session.ready = true
    end
  end, config.inline.startup_delay)

  return session
end

--- Send text to the inline terminal
--- @param session InlineSession The inline session
--- @param text string Text to send
--- @param config table Plugin configuration
--- @return boolean success True if text was sent
function M.send_to_terminal(session, text, config)
  if not session then
    vim.notify('No active inline session', vim.log.levels.ERROR)
    return false
  end

  if not session.bufnr or not vim.api.nvim_buf_is_valid(session.bufnr) then
    vim.notify('Terminal buffer not valid', vim.log.levels.ERROR)
    return false
  end

  -- Save current window
  local current_win = vim.api.nvim_get_current_win()

  -- Create a floating window for the terminal (briefly visible while sending)
  local editor_width = vim.o.columns
  local editor_height = vim.o.lines
  local width = math.floor(editor_width * 0.8)
  local height = math.floor(editor_height * 0.8)
  local row = math.floor((editor_height - height) / 2)
  local col = math.floor((editor_width - width) / 2)

  local temp_win = vim.api.nvim_open_win(session.bufnr, true, {
    relative = 'editor',
    width = width,
    height = height,
    row = row,
    col = col,
    style = 'minimal',
    border = 'rounded',
    focusable = true,
  })

  -- Enter terminal mode and send keys
  vim.cmd('startinsert')

  -- Send text first, then Enter separately with a small delay
  vim.api.nvim_feedkeys(text, 'nt', false)

  -- Send Enter after a tiny delay to ensure text is processed first
  vim.defer_fn(function()
    local enter = vim.api.nvim_replace_termcodes('<CR>', true, false, true)
    vim.api.nvim_feedkeys(enter, 'nt', false)

    -- Schedule cleanup (after Enter is processed)
    vim.defer_fn(function()
      -- Close the temporary window
      if temp_win and vim.api.nvim_win_is_valid(temp_win) then
        vim.api.nvim_win_close(temp_win, true)
      end

      -- Return to original window
      if vim.api.nvim_win_is_valid(current_win) then
        vim.api.nvim_set_current_win(current_win)
        vim.cmd('stopinsert')
      end

      -- Force screen redraw to fix any display glitches
      vim.cmd('redraw!')
    end, 200)
  end, 50)

  return true
end

--- Insert placeholder at current cursor position and track with extmark
--- @param prompt string The prompt being sent to Claude
--- @param config table|nil Plugin configuration (for spinner settings)
--- @return InlineRequest|nil request The request info or nil on failure
function M.insert_placeholder(prompt, config)
  local bufnr = vim.api.nvim_get_current_buf()
  local cursor = vim.api.nvim_win_get_cursor(0)
  local row = cursor[1] - 1 -- 0-indexed

  -- Get spinner config (use defaults if not provided)
  local spinner_config = config and config.inline and config.inline.spinner
    or {
      frames = { '⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏' },
      interval = 80,
      text = 'Claude is thinking...',
    }

  -- Insert an empty line (placeholder will be shown as virtual text)
  vim.api.nvim_buf_set_lines(bufnr, row + 1, row + 1, false, { '' })

  -- Create extmark with virtual text showing initial spinner frame
  local initial_text = spinner_config.frames[1] .. ' ' .. spinner_config.text
  local extmark_id = vim.api.nvim_buf_set_extmark(bufnr, M.ns_id, row + 1, 0, {
    virt_text = { { initial_text, 'Comment' } },
    virt_text_pos = 'overlay',
  })

  local request = {
    bufnr = bufnr,
    extmark_id = extmark_id,
    prompt = prompt,
    spinner_timer = nil,
    spinner_frame = 1,
  }

  -- Start spinner animation timer
  local timer = vim.loop.new_timer()
  request.spinner_timer = timer

  -- Helper to safely stop the timer
  local function stop_timer()
    if request.spinner_timer then
      local t = request.spinner_timer
      request.spinner_timer = nil -- Clear reference first to prevent double-close
      pcall(function()
        if t:is_active() then
          t:stop()
        end
        if not t:is_closing() then
          t:close()
        end
      end)
    end
  end

  timer:start(
    spinner_config.interval,
    spinner_config.interval,
    vim.schedule_wrap(function()
      -- Check if timer was already stopped
      if not request.spinner_timer then
        return
      end

      -- Check if buffer still exists
      if not vim.api.nvim_buf_is_valid(request.bufnr) then
        stop_timer()
        return
      end

      -- Get current extmark position
      local extmark =
        vim.api.nvim_buf_get_extmark_by_id(request.bufnr, M.ns_id, request.extmark_id, {})
      if not extmark or #extmark == 0 then
        stop_timer()
        return
      end

      -- Advance to next frame
      request.spinner_frame = (request.spinner_frame % #spinner_config.frames) + 1
      local spinner_text = spinner_config.frames[request.spinner_frame]
        .. ' '
        .. spinner_config.text

      -- Update extmark with new spinner frame
      vim.api.nvim_buf_set_extmark(request.bufnr, M.ns_id, extmark[1], 0, {
        id = request.extmark_id,
        virt_text = { { spinner_text, 'Comment' } },
        virt_text_pos = 'overlay',
      })
    end)
  )

  table.insert(M.pending_requests, request)

  return request
end

--- Check if a line is a terminal UI artifact (separators, line numbers, etc.)
--- @param line string The line to check
--- @return boolean is_artifact True if this is a UI artifact
local function is_terminal_artifact(line)
  local cleaned = strip_ansi(line)
  -- Remove leading/trailing whitespace for checking
  local trimmed = cleaned:match('^%s*(.-)%s*$') or ''

  -- Empty line is not an artifact (will be handled elsewhere)
  if trimmed == '' then
    return false
  end

  -- Lines that are just a number (line counts, token counts, etc.)
  if trimmed:match('^%d+$') then
    return true
  end

  -- Check for box-drawing characters using string.find (UTF-8 safe)
  -- Common box-drawing chars used in Claude's TUI
  local box_chars = { '─', '│', '┌', '┐', '└', '┘', '━', '═', '║' }
  local cursor_chars = { '█', '▌', '▐', '░', '▒', '▓' }

  -- Check if line is ONLY box-drawing/cursor characters (separator lines)
  local only_decorative = true
  local has_decorative = false
  for char in trimmed:gmatch('[%z\1-\127\194-\244][\128-\191]*') do
    local is_box = false
    for _, bc in ipairs(box_chars) do
      if char == bc then
        is_box = true
        has_decorative = true
        break
      end
    end
    if not is_box then
      for _, cc in ipairs(cursor_chars) do
        if char == cc then
          is_box = true
          has_decorative = true
          break
        end
      end
    end
    if not is_box and char ~= ' ' then
      only_decorative = false
      break
    end
  end

  if only_decorative and has_decorative then
    return true
  end

  -- Lines that are just a number followed by cursor block (like "457 █")
  local num_prefix = trimmed:match('^(%d+)%s*(.*)$')
  if num_prefix then
    local rest = trimmed:sub(#num_prefix + 1):match('^%s*(.*)$') or ''
    -- Check if rest is only cursor/box chars
    if rest ~= '' then
      local rest_only_decorative = true
      for char in rest:gmatch('[%z\1-\127\194-\244][\128-\191]*') do
        local is_dec = false
        for _, bc in ipairs(box_chars) do
          if char == bc then
            is_dec = true
            break
          end
        end
        if not is_dec then
          for _, cc in ipairs(cursor_chars) do
            if char == cc then
              is_dec = true
              break
            end
          end
        end
        if not is_dec and char ~= ' ' then
          rest_only_decorative = false
          break
        end
      end
      if rest_only_decorative then
        return true
      end
    end
  end

  return false
end

--- Clean a response line - remove prompt chars, bullets, etc.
--- @param line string The line to clean
--- @return string cleaned The cleaned line
local function clean_response_line(line)
  local cleaned = strip_ansi(line)
  -- Remove leading prompt characters (UTF-8 chars need separate gsub calls)
  cleaned = cleaned:gsub('^>%s*', '')
  cleaned = cleaned:gsub('^❯%s*', '')
  cleaned = cleaned:gsub('^●%s*', '')
  cleaned = cleaned:gsub('^•%s*', '')
  -- Remove trailing prompt chars
  cleaned = cleaned:gsub('%s*>%s*$', '')
  cleaned = cleaned:gsub('%s*❯%s*$', '')
  cleaned = cleaned:gsub('%s*%$%s*$', '')
  return cleaned
end

--- Check if a line is Claude's prompt (not a shell prompt)
--- @param line string The line to check
--- @return boolean is_prompt True if this is Claude's input prompt
local function is_claude_prompt(line)
  local cleaned = strip_ansi(line)
  -- Empty or whitespace only - not a prompt
  if not cleaned:match('%S') then
    return false
  end
  -- Shell prompts contain @, $, ~, paths, git:, etc - skip these
  if
    cleaned:match('@')
    or cleaned:match('%$')
    or cleaned:match('~')
    or cleaned:match('git:')
    or cleaned:match('/')
  then
    return false
  end
  -- Claude's prompt is just > or ❯, possibly with ) for the style
  local trimmed = cleaned:match('^%s*(.-)%s*$')
  -- Check for various Claude prompt patterns (UTF-8 chars need separate checks)
  -- Just >
  if trimmed == '>' then
    return true
  end
  -- Just ❯
  if trimmed == '❯' then
    return true
  end
  -- Just )
  if trimmed == ')' then
    return true
  end
  -- > ) or ❯ )
  if trimmed:match('^>%s*%)$') then
    return true
  end
  if trimmed:match('^❯%s*%)$') then
    return true
  end
  return false
end

--- Check if a line indicates Claude is still working
--- @param line string The line to check
--- @return boolean is_working True if Claude is still processing
local function is_working_indicator(line)
  local cleaned = strip_ansi(line)
  if cleaned:match('^%+') then
    return true
  end -- + at start (working indicator)
  if cleaned:match('interrupt') then
    return true
  end
  if cleaned:match('%.%.%.') then
    return true
  end -- ...
  return false
end

--- Get response from terminal buffer
--- @param session InlineSession The inline session
--- @param prompt string The original prompt to help locate the response
--- @return string|nil response The response text or nil
function M.get_terminal_response(session, prompt)
  if not session or not session.bufnr or not vim.api.nvim_buf_is_valid(session.bufnr) then
    return nil
  end

  local lines = vim.api.nvim_buf_get_lines(session.bufnr, 0, -1, false)
  local prompt_start = prompt:sub(1, 20) -- First 20 chars of user's prompt

  -- First pass: check if Claude is still working (no prompt after response yet)
  local last_non_empty = nil
  for i = #lines, 1, -1 do
    local line = strip_ansi(lines[i] or '')
    if line:match('%S') then
      last_non_empty = line
      break
    end
  end

  -- If the last non-empty line is a working indicator, Claude isn't done yet
  if last_non_empty and is_working_indicator(last_non_empty) then
    return nil
  end

  -- Find the LAST occurrence of the user's input by searching backwards
  local user_input_line = nil
  for i = #lines, 1, -1 do
    local line = strip_ansi(lines[i] or '')
    -- Look for the user's input (may be prefixed with > or ❯)
    if line:match(vim.pesc(prompt_start)) then
      user_input_line = i
      break
    end
  end

  -- If we didn't find the user input, return nil
  if not user_input_line then
    return nil
  end

  -- Now collect the response starting from after the user input line
  local response_lines = {}
  local collecting = false
  local found_prompt_after = false

  for i = user_input_line + 1, #lines do
    local line = strip_ansi(lines[i] or '')

    if not collecting then
      -- Skip empty lines right after user input, start collecting on first content
      if line:match('%S') then
        -- Skip working indicators
        if is_working_indicator(line) then
          -- Still working, but continue looking
        elseif is_claude_prompt(line) then
          -- Hit prompt without response
          found_prompt_after = true
          break
        elseif is_terminal_artifact(line) then
          -- Skip terminal UI artifacts (separators, line numbers, etc.)
        else
          collecting = true
          local cleaned = clean_response_line(line)
          if cleaned:match('%S') then
            table.insert(response_lines, cleaned)
          end
        end
      end
    else
      -- Stop at the next prompt
      if is_claude_prompt(line) then
        found_prompt_after = true
        break
      end
      -- Skip working indicators and terminal artifacts in the middle
      if not is_working_indicator(line) and not is_terminal_artifact(line) then
        local cleaned = clean_response_line(line)
        table.insert(response_lines, cleaned)
      end
    end
  end

  -- Trim trailing empty lines
  while #response_lines > 0 and not response_lines[#response_lines]:match('%S') do
    table.remove(response_lines)
  end

  -- Only return if we found a complete response (prompt appeared after)
  if #response_lines > 0 and found_prompt_after then
    return table.concat(response_lines, '\n')
  end
  return nil
end

--- Replace placeholder with response using extmark position
--- @param request InlineRequest The request with extmark info
--- @param response string The response text to insert
function M.replace_placeholder(request, response)
  if not request or not vim.api.nvim_buf_is_valid(request.bufnr) then
    return
  end

  -- Stop spinner timer if running (safely)
  if request.spinner_timer then
    local timer = request.spinner_timer
    request.spinner_timer = nil -- Clear reference first to prevent double-close
    pcall(function()
      if timer:is_active() then
        timer:stop()
      end
      if not timer:is_closing() then
        timer:close()
      end
    end)
  end

  -- Get current position from extmark
  local extmark = vim.api.nvim_buf_get_extmark_by_id(request.bufnr, M.ns_id, request.extmark_id, {})
  if not extmark or #extmark == 0 then
    return
  end

  local row = extmark[1]

  -- Get the current line at extmark position (should be empty line with virtual text)
  local current_lines = vim.api.nvim_buf_get_lines(request.bufnr, row, row + 1, false)
  -- Replace the line (empty or placeholder text) with response
  if #current_lines > 0 and (current_lines[1] == '' or current_lines[1] == M.placeholder_text) then
    local response_lines = vim.split(response, '\n')
    vim.api.nvim_buf_set_lines(request.bufnr, row, row + 1, false, response_lines)
  end

  -- Clean up extmark
  vim.api.nvim_buf_del_extmark(request.bufnr, M.ns_id, request.extmark_id)

  -- Remove from pending requests
  for i, req in ipairs(M.pending_requests) do
    if req.extmark_id == request.extmark_id then
      table.remove(M.pending_requests, i)
      break
    end
  end
end

--- Start monitoring terminal for response
--- @param session InlineSession The inline session
--- @param request InlineRequest The pending request
--- @param config table Plugin configuration
function M.start_response_monitor(session, request, config)
  local check_count = 0
  local max_checks = 300 -- 5 minutes max (300 * 1000ms)
  local last_line_count = -1 -- Start at -1 so first check doesn't trigger stabilization
  local stable_count = 0 -- Count how many checks output has been stable

  local timer = vim.loop.new_timer()
  timer:start(
    1000,
    1000,
    vim.schedule_wrap(function()
      check_count = check_count + 1

      -- Check if session is still valid
      if not session or not is_valid_session(session) then
        timer:stop()
        timer:close()
        return
      end

      -- Get current terminal line count
      local lines = vim.api.nvim_buf_get_lines(session.bufnr, 0, -1, false)
      local current_line_count = #lines

      -- Check if output has stabilized (no new lines for 2+ consecutive checks)
      if current_line_count == last_line_count then
        stable_count = stable_count + 1
      else
        stable_count = 0
      end

      last_line_count = current_line_count

      -- Search for Claude's prompt anywhere in recent lines (not just the very last)
      -- The shell prompt may appear after Claude's prompt
      local claude_prompt_line = nil
      local found_working = false

      for i = #lines, 1, -1 do
        local line = strip_ansi(lines[i] or '')
        if line:match('%S') then
          -- Check if Claude is still working (+ at start means processing)
          if line:match('^%+') then
            found_working = true
            break
          end
          -- Check if this is Claude's prompt (just >, ❯, or ))
          if is_claude_prompt(line) then
            claude_prompt_line = line
            break
          end
          -- Skip shell prompts and other lines, keep searching
        end
      end

      -- Only check for completion after output has been stable for 2 checks
      if stable_count >= 2 and claude_prompt_line and not found_working then
        -- Claude is done, get response
        local response = M.get_terminal_response(session, request.prompt)
        if response then
          M.replace_placeholder(request, response)
        else
          M.replace_placeholder(request, '-- [No response from Claude]')
        end
        timer:stop()
        timer:close()
        return
      end

      -- Timeout
      if check_count >= max_checks then
        M.replace_placeholder(request, '-- [Claude response timed out]')
        timer:stop()
        timer:close()
      end
    end)
  )
end

--- Toggle visibility of the inline terminal
--- @param claude_code table Main plugin module
--- @param config table Plugin configuration
--- @param git table Git module
function M.toggle_terminal(claude_code, config, git)
  local instance_id = get_instance_id(config, git)
  local session = M.sessions[instance_id]

  if not session or not is_valid_session(session) then
    vim.notify('No active inline session. Use prompt first.', vim.log.levels.INFO)
    return
  end

  -- Check if visible
  if session.win_id and vim.api.nvim_win_is_valid(session.win_id) then
    hide_terminal(session)
  else
    show_terminal(session, config)
  end
end

--- Open the prompt dialog for inline editing
--- @param claude_code table Main plugin module
--- @param config table Plugin configuration
--- @param git table Git module
function M.open_prompt(claude_code, config, git)
  local session = M.get_or_create_session(claude_code, config, git)

  -- Save cursor position and buffer info before opening input dialog
  local source_bufnr = vim.api.nvim_get_current_buf()
  local source_cursor = vim.api.nvim_win_get_cursor(0)

  vim.ui.input({
    prompt = config.inline.prompt_title .. ': ',
  }, function(input)
    if input == nil or input == '' then
      -- User cancelled or entered empty string
      return
    end

    -- Restore cursor to original position (input dialog may have moved it)
    if vim.api.nvim_buf_is_valid(source_bufnr) then
      local current_buf = vim.api.nvim_get_current_buf()
      if current_buf ~= source_bufnr then
        -- Switch back to source buffer
        vim.api.nvim_set_current_buf(source_bufnr)
      end
      pcall(vim.api.nvim_win_set_cursor, 0, source_cursor)
    end

    -- Insert placeholder at cursor position (tracked with extmark)
    local request = M.insert_placeholder(input, config)
    if not request then
      vim.notify('Failed to insert placeholder', vim.log.levels.ERROR)
      return
    end

    -- Function to send and monitor
    local function send_and_monitor()
      local success = M.send_to_terminal(session, input, config)
      if success then
        -- Start monitoring for response
        M.start_response_monitor(session, request, config)
      else
        -- Remove placeholder on failure
        M.replace_placeholder(request, '-- [Failed to send to Claude]')
      end
    end

    -- Check if session is ready
    if not session.ready then
      vim.notify('Claude Code is still starting up, please wait...', vim.log.levels.INFO)
      -- Try again after a short delay
      vim.defer_fn(function()
        if session.ready then
          send_and_monitor()
        else
          M.replace_placeholder(request, '-- [Claude Code startup timed out]')
          vim.notify('Claude Code startup timed out', vim.log.levels.ERROR)
        end
      end, config.inline.startup_delay)
      return
    end

    send_and_monitor()
  end)
end

--- Clear the current inline session
--- @param claude_code table Main plugin module
--- @param config table Plugin configuration
--- @param git table Git module
function M.clear_session(claude_code, config, git)
  local instance_id = get_instance_id(config, git)
  local session = M.sessions[instance_id]

  if session then
    -- Hide terminal if visible
    hide_terminal(session)

    -- Stop the job if running
    if session.job_id then
      pcall(function()
        vim.fn.jobstop(session.job_id)
      end)
    end

    -- Delete buffer if valid
    if session.bufnr and vim.api.nvim_buf_is_valid(session.bufnr) then
      pcall(function()
        vim.api.nvim_buf_delete(session.bufnr, { force = true })
      end)
    end

    M.sessions[instance_id] = nil
  end
end

--- Clean up all inline sessions
function M.cleanup()
  -- Stop all spinner timers for pending requests (safely)
  for _, request in ipairs(M.pending_requests) do
    if request.spinner_timer then
      local timer = request.spinner_timer
      request.spinner_timer = nil
      pcall(function()
        if timer:is_active() then
          timer:stop()
        end
        if not timer:is_closing() then
          timer:close()
        end
      end)
    end
  end
  M.pending_requests = {}

  for instance_id, session in pairs(M.sessions) do
    if session then
      -- Hide terminal if visible
      hide_terminal(session)

      -- Stop the job if running
      if session.job_id then
        pcall(function()
          vim.fn.jobstop(session.job_id)
        end)
      end

      -- Delete buffer if valid
      if session.bufnr and vim.api.nvim_buf_is_valid(session.bufnr) then
        pcall(function()
          vim.api.nvim_buf_delete(session.bufnr, { force = true })
        end)
      end
    end
  end

  M.sessions = {}
end

--- Setup inline editing functionality
--- @param claude_code table Main plugin module
--- @param config table Plugin configuration
function M.setup(claude_code, config)
  if not config.inline.enable then
    return
  end

  -- Set up cleanup on VimLeavePre
  vim.api.nvim_create_autocmd('VimLeavePre', {
    group = vim.api.nvim_create_augroup('ClaudeCodeInlineCleanup', { clear = true }),
    callback = function()
      M.cleanup()
    end,
  })
end

-- Expose internal functions for testing
M._internal = {
  strip_ansi = strip_ansi,
  clean_response_line = clean_response_line,
  is_claude_prompt = is_claude_prompt,
  is_working_indicator = is_working_indicator,
  is_terminal_artifact = is_terminal_artifact,
}

return M
