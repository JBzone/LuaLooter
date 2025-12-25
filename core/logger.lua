--[[
    LuaLooter Enhanced Logging System (Modernized & Future-Proof)
    =============================================================
    Full-featured logging with:
    1. Strict verbosity filtering (0-5, expandable)
    2. Dual output (MQ console + ImGui)
    3. Smart routing based on GUI visibility
    4. Event-driven log message distribution
    5. Single source of truth for verbosity boundaries
--]]

local mq = require('mq')

local Logger = {}

function Logger.new(events, config)
    local self = {}

    -- References
    self.config_object = config
    self.events = events
    self.gui_visible = false
    self.log_file = nil
    self.log_file_path = nil
    self.gui_log_callback = nil

    -- Runtime statistics
    self.stats = {
        messages_logged = 0,
        messages_filtered = 0,
        console_outputs = 0,
        gui_outputs = 0
    }

    -- Verbosity levels - SINGLE SOURCE OF TRUTH
    self.LEVELS = { FATAL = 0, ERROR = 1, WARN = 2, INFO = 3, DEBUG = 4, TRACE = 5 }
    self.LEVEL_NAMES = { [0] = "FATAL", [1] = "ERROR", [2] = "WARN", [3] = "INFO", [4] = "DEBUG", [5] = "TRACE" }
    self.VERBOSITY_DESCRIPTIONS = {
        [0] = "System crashing/dying (ALWAYS if verbosity >= 0)",
        [1] = "Errors affecting functionality (if verbosity >= 1)",
        [2] = "Warnings about potential issues (if verbosity >= 2)",
        [3] = "Normal operational messages (if verbosity >= 3) DEFAULT",
        [4] = "Detailed debugging (if verbosity >= 4)",
        [5] = "Extremely verbose (if verbosity >= 5)"
    }

    -- MQ console colors
    self.COLORS = { [0] = '\ar', [1] = '\ar', [2] = '\ay', [3] = '\ag', [4] = '\at', [5] = '\a-w' }

    -- ImGui RGBA colors
    self.IMGUI_COLORS = {
        [0] = { 1, 0.2, 0.2, 1 },     -- FATAL: Bright red
        [1] = { 1, 0.4, 0.4, 1 },     -- ERROR: Light red
        [2] = { 1, 1, 0.4, 1 },       -- WARN: Yellow
        [3] = { 0.4, 1, 0.4, 1 },     -- INFO: Green
        [4] = { 0.4, 0.8, 1, 1 },     -- DEBUG: Blue
        [5] = { 0.8, 0.8, 0.8, 1 }    -- TRACE: Gray
    }

    -- Subscribe to GUI visibility updates
    if self.events then
        self.events:subscribe(self.events.EVENT_TYPES.GUI_TOGGLE, function(data)
            self.gui_visible = data.visible or false
        end)
        self.events:subscribe(self.events.EVENT_TYPES.GUI_UPDATE, function(data)
            if data.visible ~= nil then self.gui_visible = data.visible end
        end)
    end

    -- ===== FUTURE-PROOF BOUNDARY FUNCTIONS =====
    function self:get_min_verbosity()
        return 0  -- FATAL - Change here affects entire system
    end

    function self:get_max_verbosity()
        return 5  -- TRACE - Change here affects entire system
    end

    function self:get_all_verbosity_levels()
        local levels = {}
        for i = self:get_min_verbosity(), self:get_max_verbosity() do
            levels[i] = self.LEVEL_NAMES[i]
        end
        return levels
    end

    function self:get_verbosity_count()
        return (self:get_max_verbosity() - self:get_min_verbosity()) + 1
    end

    function self:get_all_verbosity_descriptions()
        local descriptions = {}
        for i = self:get_min_verbosity(), self:get_max_verbosity() do
            descriptions[i] = {
                level = i,
                name = self.LEVEL_NAMES[i],
                description = self.VERBOSITY_DESCRIPTIONS[i]
            }
        end
        return descriptions
    end

    function self:get_verbosity_description(level)
        local level_num = self:get_verbosity_num(level)
        return self.VERBOSITY_DESCRIPTIONS[level_num] or ""
    end

    -- ===== HELPER FUNCTIONS =====
    function self:get_verbosity_num(level)
        if type(level) == "number" then
            return math.max(self:get_min_verbosity(), math.min(self:get_max_verbosity(), level))
        end
        if type(level) == "string" then
            return self.LEVELS[level:upper()] or 3
        end
        return 3
    end

    function self:get_verbosity_name(level)
        return self.LEVEL_NAMES[self:get_verbosity_num(level)] or "INFO"
    end

    function self:get_config_value(key, default)
      -- Config is guaranteed to be initialized before logger is created
      if not self.config_object then return default end
      
      if self.config_object.get then
          local val = self.config_object:get(key)
          if val ~= nil then return val end
      end
      
      return default
    end

    function self:format_message(level, msg, ...)
        local args = { ... }
        local timestamp = os.date("%H:%M:%S")
        local safe_args = {}
        for i, a in ipairs(args) do safe_args[i] = tostring(a) end
        
        local formatted_msg = type(msg) == "string" and (#safe_args > 0 and string.format(msg, unpack(safe_args)) or msg)
                            or tostring(msg)
        
        local level_num = self:get_verbosity_num(level)
        return {
            console_msg = string.format("[%s] [%s] %s", timestamp, self:get_verbosity_name(level_num), formatted_msg),
            file_msg = string.format("%s [%s] %s", timestamp, self:get_verbosity_name(level_num), formatted_msg),
            gui_msg = string.format("%s [%s] %s", timestamp, self:get_verbosity_name(level_num), formatted_msg),
            color = self.IMGUI_COLORS[level_num] or self.IMGUI_COLORS[3],
            level_num = level_num
        }
    end

    function self:write_to_file(msg)
        if self.log_file then
            local ok, err = pcall(function()
                self.log_file:write(msg .. "\n")
                self.log_file:flush()
            end)
            if not ok then
                self.log_file:close()
                self.log_file = nil
                if self.log_file_path then
                    self:set_log_file(self.log_file_path)
                end
            end
        end
    end

    function self:route_message(formatted, level)
        self.stats.messages_logged = self.stats.messages_logged + 1
        local verbosity = self:get_config_value('log_verbosity', 3)
        local send_to_console = self:get_config_value('log_console_enabled', true)
        local send_to_gui = self:get_config_value('log_gui_enabled', true)
        local smart_routing = self:get_config_value('log_smart_routing', true)
        local level_num = formatted.level_num or self:get_verbosity_num(level)

        -- Smart routing: reduce console spam when GUI is visible
        if smart_routing and self.gui_visible and level_num > self.LEVELS.WARN then
            send_to_console = false
        end

        if send_to_console then
            print(formatted.console_msg)
            self.stats.console_outputs = self.stats.console_outputs + 1
        end
        
        if send_to_gui and self.gui_log_callback then
            local ok, err = pcall(self.gui_log_callback, formatted.gui_msg)
            if ok then
                self.stats.gui_outputs = self.stats.gui_outputs + 1
            else
                print("\ar[LOGGER ERROR] GUI callback failed: " .. err .. "\ax")
            end
        end

        if self.events then
            self.events:publish("LOG_MESSAGE", {
                level = level_num,
                message = formatted.file_msg,
                timestamp = os.time()
            })
        end
    end

    -- ===== CORE LOGGING =====
    function self:log(level, msg, ...)
      local level_num = self:get_verbosity_num(level)
      local verbosity_setting = self:get_config_value('log_verbosity', 3)
      -- FIX: Convert to number if it's a string
      local verbosity = tonumber(verbosity_setting) or 3
      if level_num > verbosity then
        self.stats.messages_filtered = self.stats.messages_filtered + 1
        return self
      end
      local formatted = self:format_message(level, msg, ...)
      self:route_message(formatted, level)
      self:write_to_file(formatted.file_msg)
      return self
    end

    -- Convenience methods
    function self:debug(...) return self:log("DEBUG", ...) end
    function self:info(...) return self:log("INFO", ...) end
    function self:warn(...) return self:log("WARN", ...) end
    function self:error(...) return self:log("ERROR", ...) end
    function self:fatal(...) return self:log("FATAL", ...) end
    function self:trace(...) return self:log("TRACE", ...) end

    -- ===== CONFIGURATION SETTERS (Call config:set) =====
    function self:set_level(level)
        local level_num = self:get_verbosity_num(level)
        if self.config_object and self.config_object.set then
            self.config_object:set('log_verbosity', level_num)
        end
        return self
    end

    function self:set_console_enabled(val)
        if self.config_object and self.config_object.set then
            self.config_object:set('log_console_enabled', val)
        end
        return self
    end

    function self:set_gui_enabled(val)
        if self.config_object and self.config_object.set then
            self.config_object:set('log_gui_enabled', val)
        end
        return self
    end

    function self:set_smart_routing(val)
        if self.config_object and self.config_object.set then
            self.config_object:set('log_smart_routing', val)
        end
        return self
    end

    function self:set_max_gui_lines(val)
        if self.config_object and self.config_object.set then
            self.config_object:set('max_log_lines', val)
        end
        return self
    end

    -- ===== GUI INTEGRATION =====
    function self:register_gui_callback(cb)
        self.gui_log_callback = cb
        return self
    end

    function self:unregister_gui_callback()
        self.gui_log_callback = nil
        return self
    end

    -- ===== FILE HANDLING =====
    function self:set_log_file(path)
        if self.log_file then
            self.log_file:close()
            self.log_file = nil
        end

        if path then
            self.log_file, err = io.open(path, "a")
            if self.log_file then
                self.log_file_path = path
                self:info("Log file opened: %s", path)
                return true
            else
                self.log_file_path = nil
                return false
            end
        else
            self.log_file_path = nil
            return true
        end
    end

    function self:get_log_file_path()
        return self.log_file_path
    end

    -- ===== STATISTICS =====
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

    -- ===== STARTUP/SHUTDOWN =====
    function self:log_startup()
        local v = self:get_config_value('log_verbosity', 3)
        self:info("=" .. string.rep("=", 60))
        self:info("LuaLooter Starting")
        self:info("Date: %s", os.date("%Y-%m-%d %H:%M:%S"))
        self:info("Character: %s", mq.TLO.Me.Name() or "Unknown")
        self:info("Server: %s", mq.TLO.EverQuest.Server() or "Unknown")
        self:info("Log Verbosity: %d (%s)", v, self:get_verbosity_name(v))
        if self.log_file_path then
            self:info("Log File: %s", self.log_file_path)
        end
        self:info("=" .. string.rep("=", 60))
        return self
    end

    function self:shutdown()
        if self.log_file then
            self:info("Shutting down logger")
            self.log_file:close()
            self.log_file = nil
        end
        return self
    end

    return self
end

return Logger