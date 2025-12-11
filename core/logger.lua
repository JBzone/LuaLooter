--[[
    LuaLooter Enhanced Logging System
    ==================================
    Professional-grade logging with:
    1. Strict verbosity filtering at SOURCE (zero overhead for filtered messages)
    2. Dual color systems (MQ Console vs ImGui RGBA)
    3. Smart routing based on GUI visibility
    4. Event-driven log message distribution

    UPDATED: Enhanced existing logger with new smart features
    PRESERVES: All existing functionality for backward compatibility
--]]

local mq = require('mq')

local Logger = {}

function Logger.new(events, config)
  local self = {
    -- Configuration (supports both old and new config)
    config = {
      -- Old settings (for backward compatibility)
      current_level = 2,       -- Old debug=1, info=2, warn=3, error=4, fatal=5

      -- New smart logging settings
      verbosity = config and config.verbosity or 3,                       -- Default INFO
      console_enabled = config and config.console_enabled ~= false,       -- Default true
      gui_enabled = config and config.gui_enabled ~= false,               -- Default true
      smart_routing = config and config.smart_routing ~= false,           -- Default true
      max_gui_lines = config and config.max_gui_lines or 500
    },

    -- Runtime state
    events = events,
    gui_visible = false,
    log_file = nil,
    log_file_path = nil,

    -- Callback for GUI to register log panel
    gui_log_callback = nil,

    -- Performance tracking
    stats = {
      messages_logged = 0,
      messages_filtered = 0,
      console_outputs = 0,
      gui_outputs = 0
    }
  }

  -- Verbosity levels as per requirements (0-5) - NEW
  self.LEVELS = {
    FATAL = 0,      -- System crashing/dying (ALWAYS if verbosity >= 0)
    ERROR = 1,      -- Errors affecting functionality (if verbosity >= 1)
    WARN  = 2,      -- Warnings about potential issues (if verbosity >= 2)
    INFO  = 3,      -- Normal operational messages (if verbosity >= 3) DEFAULT
    DEBUG = 4,      -- Detailed debugging (if verbosity >= 4)
    TRACE = 5       -- Extremely verbose (if verbosity >= 5)
  }

  -- Level names for display - NEW
  self.LEVEL_NAMES = {
    [0] = "FATAL",
    [1] = "ERROR",
    [2] = "WARN",
    [3] = "INFO",
    [4] = "DEBUG",
    [5] = "TRACE"
  }

  -- Old log levels (for backward compatibility)
  local old_levels = {
    debug = 1,
    info = 2,
    warn = 3,
    error = 4,
    fatal = 5
  }

  -- Color codes for MQ console (expanded)
  local colors = {
    -- Old colors (backward compatibility)
    debug = '\at',     -- Green
    info = '\aw',      -- White
    warn = '\ay',      -- Yellow
    error = '\ar',     -- Red
    fatal = '\ar',     -- Red

    -- New colors for verbosity levels
    [0] = '\ar',     -- FATAL: Red
    [1] = '\ar',     -- ERROR: Red
    [2] = '\ay',     -- WARN: Yellow
    [3] = '\ag',     -- INFO: Green
    [4] = '\at',     -- DEBUG: Teal/Cyan
    [5] = '\a-w'     -- TRACE: Gray-white
  }

  -- ImGui RGBA colors (0.0-1.0 range) - NEW
  local IMGUI_COLORS = {
    [0] = { 1.0, 0.2, 0.2, 1.0 },   -- FATAL: Bright red
    [1] = { 1.0, 0.4, 0.4, 1.0 },   -- ERROR: Light red
    [2] = { 1.0, 1.0, 0.4, 1.0 },   -- WARN: Yellow
    [3] = { 0.4, 1.0, 0.4, 1.0 },   -- INFO: Green
    [4] = { 0.4, 0.8, 1.0, 1.0 },   -- DEBUG: Blue
    [5] = { 0.8, 0.8, 0.8, 1.0 }    -- TRACE: Gray
  }

  -- Reset color
  local reset = '\ax'

  -- Subscribe to GUI visibility changes - NEW
  if events then
    events:subscribe(events.EVENT_TYPES.GUI_TOGGLE, function(data)
      self.gui_visible = data.visible or false
    end)

    events:subscribe(events.EVENT_TYPES.GUI_UPDATE, function(data)
      if data.visible ~= nil then
        self.gui_visible = data.visible
      end
    end)
  end

  -- ===== OLD METHODS (Backward Compatibility) =====

  function self:set_level(level)
    -- Convert old level names to new verbosity
    if type(level) == 'string' and old_levels[level] then
      self.config.current_level = old_levels[level]

      -- Map old levels to new verbosity (approximate mapping)
      local mapping = {
        debug = 4,         -- Old debug = new DEBUG level
        info = 3,          -- Old info = new INFO level
        warn = 2,          -- Old warn = new WARN level
        error = 1,         -- Old error = new ERROR level
        fatal = 0          -- Old fatal = new FATAL level
      }
      if mapping[level] then
        self.config.verbosity = mapping[level]
      end
    elseif type(level) == 'number' then
      self.config.current_level = level
    end
  end

  function self:get_level_name()
    for name, value in pairs(old_levels) do
      if value == self.config.current_level then
        return name
      end
    end
    return 'info'
  end

  function self:should_log(level)
    if type(level) == 'string' and old_levels[level] then
      -- Old style: check against current_level
      return old_levels[level] >= self.config.current_level
    elseif type(level) == 'number' then
      -- New style: check against verbosity
      return level <= self.config.verbosity
    end
    return false
  end

  function self:format_message(level, msg, ...)
    local formatted = string.format(msg, ...)
    local timestamp = mq.TLO.Time() or "00:00:00"

    -- Determine level name and color
    local level_name, color_code

    if type(level) == 'string' then
      -- Old style
      level_name = string.upper(level)
      color_code = colors[level] or '\aw'
    else
      -- New style
      level_name = self.LEVEL_NAMES[level] or "UNKNOWN"
      color_code = colors[level] or '\aw'
    end

    -- For console: with colors
    local console_msg = string.format('%s[%s] [LuaLooter] [%s] %s%s',
      color_code,
      timestamp,
      level_name,
      formatted,
      reset)

    -- For file: without colors (strip MQ color codes)
    local file_msg = string.format('[%s] [LuaLooter] [%s] %s',
      timestamp,
      level_name,
      formatted)

    -- For GUI: structured data - NEW
    local gui_data = {
      text = string.format('[%s] [%s] %s', timestamp, level_name, formatted),
      color = type(level) == 'number' and IMGUI_COLORS[level] or { 1.0, 1.0, 1.0, 1.0 },
      level = type(level) == 'number' and level or 3,       -- Default to INFO
      timestamp = os.time()
    }

    return console_msg, file_msg, gui_data
  end

  function self:set_log_file(path)
    if self.log_file then
      self.log_file:close()
      self.log_file = nil
    end

    if path then
      self.log_file, err = io.open(path, "a")
      if not self.log_file then
        print(string.format('\ar[ERROR] Failed to open log file: %s - %s\ax', path, err))
        self.log_file_path = nil
        return false
      end

      self.log_file_path = path
      self:info("Log file opened: %s", path)
      return true
    else
      self.log_file_path = nil
      return true
    end
  end

  function self:get_log_file_path()
    return self.log_file_path
  end

  function self:rotate_log(max_size_mb)
    if not self.log_file or not self.log_file_path then
      return false
    end

    local max_size = (max_size_mb or 10) * 1024 * 1024

    local current_pos = self.log_file:seek()
    self.log_file:seek("end")
    local file_size = self.log_file:seek()
    self.log_file:seek("set", current_pos)

    if file_size > max_size then
      self:info("Log file rotation needed (%d bytes > %d bytes)", file_size, max_size)

      self.log_file:close()
      self.log_file = nil

      local timestamp = os.date("%Y%m%d_%H%M%S")
      local base_path = self.log_file_path
      local dir, name, ext = base_path:match("^(.*[/\\])([^/\\]-)([^.]+)$")

      if not dir then
        dir = ""
        name, ext = base_path:match("^([^/\\]-)([^.]+)$")
      end

      local rotated_name = string.format("%s%s_%s.%s", dir or "", name or "log", timestamp, ext or "log")

      local success, err = os.rename(base_path, rotated_name)
      if success then
        self:info("Rotated log file to: %s", rotated_name)
      else
        self:error("Failed to rotate log file: %s", err)
      end

      return self:set_log_file(base_path)
    end

    return true
  end

  function self:write_to_file(message)
    if self.log_file then
      local status, err = pcall(function()
        self.log_file:write(message .. "\n")
        self.log_file:flush()
      end)

      if not status then
        print(string.format('\ar[ERROR] Log file write failed: %s\ax', err))
        self.log_file = nil
        if self.log_file_path then
          self:set_log_file(self.log_file_path)
        end
      end
    end
  end

  -- ===== SMART ROUTING LOGIC - NEW =====

  function self:route_message(formatted, level, is_old_style)
    -- Update statistics
    self.stats.messages_logged = self.stats.messages_logged + 1

    -- Determine routing based on configuration and GUI visibility
    local send_to_console = self.config.console_enabled
    local send_to_gui = self.config.gui_enabled

    -- Smart routing: reduce console spam when GUI is visible
    if self.config.smart_routing and self.gui_visible then
      -- When GUI is open, only send high-priority messages to console
      if is_old_style then
        -- Old style: only error/fatal to console
        local old_level = type(level) == 'string' and level or "info"
        if old_level ~= "error" and old_level ~= "fatal" then
          send_to_console = false
        end
      else
        -- New style: only FATAL, ERROR, WARN to console
        if level > self.LEVELS.WARN then         -- DEBUG and TRACE go only to GUI
          send_to_console = false
        end
      end
    end

    -- Route to console
    if send_to_console then
      print(formatted.mq_console or formatted[1])       -- Support both formats
      self.stats.console_outputs = self.stats.console_outputs + 1
    end

    -- Route to GUI via callback
    if send_to_gui and self.gui_log_callback then
      local gui_data = formatted.gui or formatted[3]       -- Support both formats
      if gui_data then
        local success, err = pcall(self.gui_log_callback, gui_data)
        if not success then
          print(string.format("\ar[LOGGER ERROR] GUI callback failed: %s\ax", err))
        else
          self.stats.gui_outputs = self.stats.gui_outputs + 1
        end
      end
    end

    -- Publish log event for other subscribers
    if self.events then
      self.events:publish("LOG_MESSAGE", {
        level = is_old_style and (old_levels[level] or 3) or level,
        message = formatted.raw or formatted[2],
        timestamp = os.time()
      })
    end
  end

  -- ===== CORE LOGGING METHOD (Enhanced) =====

  function self:log(level, msg, ...)
    -- Determine if this is old-style or new-style call
    local is_old_style = type(level) == 'string'
    local should_log

    if is_old_style then
      -- Old style: check against current_level
      should_log = old_levels[level] and old_levels[level] >= self.config.current_level
    else
      -- New style: check against verbosity (STRICT FILTERING AT SOURCE)
      should_log = level <= self.config.verbosity
    end

    if not should_log then
      self.stats.messages_filtered = self.stats.messages_filtered + 1
      return self       -- Return self for chaining
    end

    -- Only format message if it passes filter
    local formatted = self:format_message(level, msg, ...)
    self:route_message(formatted, level, is_old_style)

    -- Write to file if enabled
    if self.log_file then
      self:write_to_file(formatted[2])       -- file_msg is second return value
    end

    return self     -- Method chaining support
  end

  -- ===== OLD CONVENIENCE METHODS (Unchanged) =====

  function self:debug(msg, ...)
    return self:log('debug', msg, ...)
  end

  function self:info(msg, ...)
    return self:log('info', msg, ...)
  end

  function self:warn(msg, ...)
    return self:log('warn', msg, ...)
  end

  function self:error(msg, ...)
    return self:log('error', msg, ...)
  end

  function self:fatal(msg, ...)
    return self:log('fatal', msg, ...)
  end

  -- ===== NEW CONVENIENCE METHODS =====

  function self:trace(msg, ...)
    return self:log(self.LEVELS.TRACE, msg, ...)
  end

  -- ===== NEW SMART LOGGING METHODS =====

  function self:set_verbosity(level)
    if level >= 0 and level <= 5 then
      self.config.verbosity = level
      self:info("Log verbosity set to %d (%s)", level, self.LEVEL_NAMES[level])
    end
    return self
  end

  function self:set_console_enabled(enabled)
    self.config.console_enabled = enabled
    self:info("Console logging %s", enabled and "enabled" or "disabled")
    return self
  end

  function self:set_gui_enabled(enabled)
    self.config.gui_enabled = enabled
    self:info("GUI logging %s", enabled and "enabled" or "disabled")
    return self
  end

  function self:set_smart_routing(enabled)
    self.config.smart_routing = enabled
    self:info("Smart routing %s", enabled and "enabled" or "disabled")
    return self
  end

  function self:set_max_gui_lines(max_lines)
    self.config.max_gui_lines = max_lines
    return self
  end

  -- GUI integration
  function self:register_gui_callback(callback)
    self.gui_log_callback = callback
    self:debug("GUI log callback registered")
    return self
  end

  function self:unregister_gui_callback()
    self.gui_log_callback = nil
    self:debug("GUI log callback unregistered")
    return self
  end

  -- Statistics
  function self:get_stats()
    return {
      messages_logged = self.stats.messages_logged,
      messages_filtered = self.stats.messages_filtered,
      console_outputs = self.stats.console_outputs,
      gui_outputs = self.stats.gui_outputs,
      filter_rate = self.stats.messages_logged > 0 and
          (self.stats.messages_filtered / self.stats.messages_logged) * 100 or 0
    }
  end

  function self:log_stats()
    local stats = self:get_stats()
    self:info("Logger Statistics: %d logged, %d filtered (%.1f%%), %d console, %d GUI",
      stats.messages_logged, stats.messages_filtered, stats.filter_rate,
      stats.console_outputs, stats.gui_outputs)
    return self
  end

  -- Old startup logging (preserved)
  function self:log_startup()
    self:info("=" .. string.rep("=", 60))
    self:info("LuaLooter Starting")
    self:info("Date: %s", os.date("%Y-%m-%d %H:%M:%S"))
    self:info("Character: %s", mq.TLO.Me.Name() or "Unknown")
    self:info("Server: %s", mq.TLO.EverQuest.Server() or "Unknown")
    self:info("Log Level: %s", self:get_level_name())
    self:info("Log Verbosity: %d (%s)", self.config.verbosity,
      self.LEVEL_NAMES[self.config.verbosity] or "Unknown")
    if self.log_file_path then
      self:info("Log File: %s", self.log_file_path)
    end
    self:info("=" .. string.rep("=", 60))
  end

  -- Cleanup on shutdown
  function self:shutdown()
    if self.log_file then
      self:info("Shutting down logger")
      self.log_file:close()
      self.log_file = nil
    end
  end

  return self
end

return Logger
