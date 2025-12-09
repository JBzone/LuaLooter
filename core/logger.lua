--[[
DESIGN DECISION: Abstracted logging service with file support
WHY: Decouples logging implementation from business logic
     Easy to switch logging libraries or add log levels
     Centralized log formatting and output control
     Supports both console and file logging
--]]

local mq = require('mq')

local Logger = {}

function Logger.new()
    local self = {
        log_file = nil,
        log_file_path = nil
    }
    
    -- Log levels in order of severity
    local levels = {
        debug = 1,
        info = 2,
        warn = 3,
        error = 4,
        fatal = 5
    }
    
    self.current_level = levels.info  -- Default level
    
    -- Color codes for MQ console
    local colors = {
        debug = '\at',  -- Green
        info = '\aw',   -- White
        warn = '\ay',   -- Yellow
        error = '\ar',  -- Red
        fatal = '\ar'   -- Red
    }
    
    -- Reset color
    local reset = '\ax'
    
    function self:set_level(level)
        if levels[level] then
            self.current_level = levels[level]
        end
    end
    
    function self:get_level_name()
        for name, value in pairs(levels) do
            if value == self.current_level then
                return name
            end
        end
        return 'info'
    end
    
    function self:should_log(level)
        return levels[level] >= self.current_level
    end
    
    function self:format_message(level, msg, ...)
        local formatted = string.format(msg, ...)
        local timestamp = mq.TLO.Time() or "00:00:00"
        local level_name = string.upper(level)
        
        -- For console: with colors
        local console_msg = string.format('%s[%s] [LuaLooter] [%s] %s%s', 
            colors[level] or '\aw', 
            timestamp, 
            level_name, 
            formatted, 
            reset)
        
        -- For file: without colors (strip MQ color codes)
        local file_msg = string.format('[%s] [LuaLooter] [%s] %s', 
            timestamp, 
            level_name, 
            formatted)
        
        return console_msg, file_msg
    end
    
    function self:set_log_file(path)
        if self.log_file then
            self.log_file:close()
            self.log_file = nil
        end
        
        if path then
            -- Ensure directory exists
            local dir = path:match("^(.*[/\\])")
            if dir and dir ~= "" then
                -- Try to create directory if it doesn't exist
                -- Note: Lua doesn't have built-in directory creation
                -- We'll rely on the directory existing or let it fail gracefully
            end
            
            -- Open file in append mode
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
        
        local max_size = (max_size_mb or 10) * 1024 * 1024  -- Default 10MB
        
        -- Get current file size
        local current_pos = self.log_file:seek()
        self.log_file:seek("end")
        local file_size = self.log_file:seek()
        self.log_file:seek("set", current_pos)  -- Restore position
        
        if file_size > max_size then
            self:info("Log file rotation needed (%d bytes > %d bytes)", file_size, max_size)
            
            -- Close current file
            self.log_file:close()
            self.log_file = nil
            
            -- Generate timestamp for rotated file
            local timestamp = os.date("%Y%m%d_%H%M%S")
            local base_path = self.log_file_path
            local dir, name, ext = base_path:match("^(.*[/\\])([^/\\]-)([^.]+)$")
            
            if not dir then
                dir = ""
                name, ext = base_path:match("^([^/\\]-)([^.]+)$")
            end
            
            local rotated_name = string.format("%s%s_%s.%s", dir or "", name or "log", timestamp, ext or "log")
            
            -- Rename current log to rotated name
            local success, err = os.rename(base_path, rotated_name)
            if success then
                self:info("Rotated log file to: %s", rotated_name)
            else
                self:error("Failed to rotate log file: %s", err)
            end
            
            -- Reopen log file
            return self:set_log_file(base_path)
        end
        
        return true
    end
    
    function self:write_to_file(message)
        if self.log_file then
            -- Ensure file is still open
            local status, err = pcall(function()
                self.log_file:write(message .. "\n")
                self.log_file:flush()  -- Ensure it's written immediately
            end)
            
            if not status then
                -- File might be closed, try to reopen
                print(string.format('\ar[ERROR] Log file write failed: %s\ax', err))
                self.log_file = nil
                -- Try to reopen
                if self.log_file_path then
                    self:set_log_file(self.log_file_path)
                end
            end
        end
    end
    
    function self:log(level, msg, ...)
        if self:should_log(level) then
            local console_msg, file_msg = self:format_message(level, msg, ...)
            
            -- Output to console
            print(console_msg)
            
            -- Output to file (if enabled)
            if self.log_file then
                self:write_to_file(file_msg)
            end
        end
    end
    
    function self:debug(msg, ...)
        self:log('debug', msg, ...)
    end
    
    function self:info(msg, ...)
        self:log('info', msg, ...)
    end
    
    function self:warn(msg, ...)
        self:log('warn', msg, ...)
    end
    
    function self:error(msg, ...)
        self:log('error', msg, ...)
    end
    
    function self:fatal(msg, ...)
        self:log('fatal', msg, ...)
    end
    
    -- Log startup information
    function self:log_startup()
        self:info("=" .. string.rep("=", 60))
        self:info("LuaLooter Starting")
        self:info("Date: %s", os.date("%Y-%m-%d %H:%M:%S"))
        self:info("Character: %s", mq.TLO.Me.Name() or "Unknown")
        self:info("Server: %s", mq.TLO.EverQuest.Server() or "Unknown")
        self:info("Log Level: %s", self:get_level_name())
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