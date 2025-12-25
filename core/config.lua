-- config.lua - Complete independent configuration system with full API
local mq = require('mq')

local Config = {}
Config.__index = Config

function Config.new()
    local self = setmetatable({}, Config)
    self.db = nil  -- Will be set later
    self.logger = nil  -- Will be set later
    self.ini_file = mq.configDir .. "\\Loot.ini"
    self.conversion_done = false
    self.initialized = false

    -- Default settings - MUST match original exactly
    self.defaults = {
        -- Logging
        log_verbosity = 3,
        max_log_lines = 500,
        log_auto_scroll = true,
        log_show_timestamps = true,
        log_show_levels = true,
        log_console_enabled = true,
        log_gui_enabled = true,
        log_smart_routing = true,

        -- Loot
        loot_enabled = true,
        loot_delay = 1000,
        loot_check_delay = 2000,
        auto_open_window = true,
        no_drop_wait_time = 300,
        enable_file_logging = false,
        log_file_path = "logs/LuaLooter.log",
        max_log_size_mb = 10,

        -- Character defaults
        master_loot = true,
        loot_from_general_section = true,
        loot_value = 1000,
        loot_trash = false,
        loot_personal_only = false,
        always_loot_tradeskills = true,
        save_slots = 3,
        auto_loot_cash = true,
        auto_loot_quest = true,
        auto_loot_collectible = true,
        quest_loot_value = 500,
        
        -- Alpha mode
        alpha_mode = false
    }
    
    -- Store values in memory until DB is ready
    self.in_memory_settings = {}
    
    return self
end

-- Set dependencies after they're created
function Config:set_logger(logger)
    self.logger = logger
end

function Config:set_db(db)
    self.db = db
    self.initialized = true
end

-- ==================== ORIGINAL HELPER FUNCTIONS ====================
local function to_bool(val)
    if type(val) == 'boolean' then return val end
    if type(val) == 'number' then return val ~= 0 end
    if type(val) == 'string' then
        local lower = val:lower()
        return lower == 'true' or lower == '1' or lower == 'yes' or lower == 'on'
    end
    return false
end

local function clean_numeric(val, default)
    if type(val) == 'string' then
        local lower = val:lower()
        if lower == 'nil' or lower == 'null' or lower == '' then
            return default
        end
    end
    return tonumber(val) or default
end

local function parse_ini_file(filename)
    local config = {}
    local current_section = nil
    local file = io.open(filename, "r")
    if not file then return config end

    for line in file:lines() do
        line = line:match("^%s*(.-)%s*$")
        if line ~= "" and not line:match("^[;#]") then
            local section = line:match("^%[([^%]]+)%]$")
            if section then
                current_section = section
                config[current_section] = {}
            elseif current_section then
                local key, value = line:match("^([^=]+)=(.*)$")
                if key and value then
                    key = key:match("^%s*(.-)%s*$")
                    value = value:match("^%s*(.-)%s*$")
                    if value:match('^".*"$') then
                        value = value:sub(2, -2)
                    end
                    config[current_section][key] = value
                end
            end
        end
    end

    file:close()
    return config
end

-- ==================== ORIGINAL API METHODS ====================

function Config:init()
  if self.initialized then return true end
  
  -- Initialize DB
  self.db = require('core.db').new(self.logger)
  if not self.db:init() then
      return false
  end
  
  -- Check if database is fresh (no settings)
  local status = self:get_conversion_status()
  
  if not status.converted then
      -- Fresh database or no settings exist
      self.logger:info("Fresh database detected")
      
      -- Check if loot.ini exists for conversion
      if status.ini_exists then
          self.logger:info("loot.ini found - ready for conversion")
          -- Database is ready, but user needs to run convert_from_ini()
      else
          self.logger:info("No loot.ini found - creating default settings")
          self:create_default_settings()  -- Populate with defaults
      end
  else
      self.logger:info("Existing database loaded with %d settings", status.db_settings_count)
  end
  
  self.initialized = true
  return true
end

function Config:load() 
    return self:init() 
end

function Config:save() 
    return true  -- SQLite auto-saves
end

function Config:get(key, default_value)
    -- First check in-memory (if set via :set during initialization)
    if self.in_memory_settings[key] ~= nil then
        return self.in_memory_settings[key]
    end
    
    -- Then check DB if available
    if self.db and self.initialized then
        return self.db:get_setting(key, default_value or self.defaults[key])
    end
    
    -- Fallback to defaults
    return default_value or self.defaults[key]
end

function Config:get_char(key, default_value)
    if self.db and self.initialized then
        local char_name = mq.TLO.Me.Name()
        return self.db:get_char_setting(char_name, key, default_value or self.defaults[key])
    end
    
    return default_value or self.defaults[key]
end

function Config:set(key, value)
    -- Store in memory first
    self.in_memory_settings[key] = value
    
    -- Save to DB if available
    if self.db and self.initialized then
        local category = "general"
        if key:find("^log_") then category = "log"
        elseif key:find("^loot_") then category = "loot" end
        
        self.db:set_setting(key, value, category)
    end
    
    return self
end

function Config:set_char(key, value)
    if self.db and self.initialized then
        local char_name = mq.TLO.Me.Name()
        self.db:set_char_setting(char_name, key, value)
    end
    
    return self
end

function Config:get_log_config()
    return {
        verbosity = self:get('log_verbosity', 3),
        console_enabled = self:get('log_console_enabled', true),
        gui_enabled = self:get('log_gui_enabled', true),
        smart_routing = self:get('log_smart_routing', true),
        max_gui_lines = self:get('max_log_lines', 500)
    }
end

-- Conversion function, called once via GUI
function Config:convert_from_ini()
    if not self.db or not self.initialized then
        return false, "Config system not initialized"
    end
    
    if self.conversion_done then
        return false, "Conversion already completed"
    end

    local file = io.open(self.ini_file, "r")
    if not file then
        return false, "Loot.ini file not found"
    end
    file:close()

    local ini_data = parse_ini_file(self.ini_file)
    if not ini_data or not next(ini_data) then
        return false, "Loot.ini is empty or invalid"
    end

    local imported_count = 0
    local errors = {}

    self.db:begin_transaction()

    -- Convert [Settings] section
    if ini_data["Settings"] then
        for key, value in pairs(ini_data["Settings"]) do
            local success, err = self.db:import_setting(key, value, "general")
            if success then imported_count = imported_count + 1
            else table.insert(errors, string.format("Settings.%s: %s", key, err)) end
        end
    end

    -- Convert [LogSettings] section
    if ini_data["LogSettings"] then
        for key, value in pairs(ini_data["LogSettings"]) do
            local success, err = self.db:import_setting(key, value, "log")
            if success then imported_count = imported_count + 1
            else table.insert(errors, string.format("LogSettings.%s: %s", key, err)) end
        end
    end

    -- Convert character-specific section
    local char_name = mq.TLO.Me.Name()
    if ini_data[char_name] then
        for key, value in pairs(ini_data[char_name]) do
            local success, err = self.db:import_char_setting(char_name, key, value)
            if success then imported_count = imported_count + 1
            else table.insert(errors, string.format("%s.%s: %s", char_name, key, err)) end
        end
    end

    self.db:commit_transaction()
    self.conversion_done = true

    if #errors > 0 then
        if self.logger then
            self.logger:warn("Conversion completed with %d errors", #errors)
            for _, err in ipairs(errors) do
                self.logger:warn("  %s", err)
            end
        end
    end

    return true, string.format("Converted %d settings successfully", imported_count)
end

function Config:get_conversion_status()
    if not self.db or not self.initialized then
        return {
            converted = false,
            ini_exists = false,
            ini_settings_count = 0,
            db_settings_count = 0,
            db_rules_count = 0,
            config_initialized = self.initialized,
            db_available = (self.db ~= nil)
        }
    end
    
    return self.db:get_conversion_status(self.ini_file)
end

function Config:create_default_settings()
    if not self.db or not self.initialized then
        if self.logger then
            self.logger:error("Cannot create defaults: DB not available")
        end
        return false
    end
    
    if self.logger then
        self.logger:info("Creating default settings in database")
    end
    
    for key, value in pairs(self.defaults) do
        self:set(key, value)  -- This will save to DB now
    end
    self.conversion_done = true
    return true
end

function Config:shutdown()
    if self.db and self.db.close then
        self.db:close()
    end
    self.initialized = false
    return true
end

-- Safe logging helper (used internally)
function Config:_log(level, msg, ...)
    if self.logger and self.logger[level] then
        self.logger[level](self.logger, msg, ...)
    end
    -- If no logger, just silently ignore (config should work without logging)
end

return Config