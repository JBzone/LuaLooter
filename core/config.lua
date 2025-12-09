--[[
DESIGN DECISION: Configuration as a service with validation
WHY: Separates config loading from config usage
     Type validation and default values
     Hot-reload capability (future)
--]]

local mq = require('mq')

local Config = {}

function Config.new(logger)
    local self = {
        logger = logger,
        ini_file = mq.configDir .. "\\Loot.ini",
        
        -- Default settings structure
      settings = {
        alpha_mode = true,
        loot_check_delay = 2000,
        debug_logging = false,
        auto_open_window = true,
        no_drop_wait_time = 300,
        enable_file_logging = false,      -- NEW
        log_file_path = "logs/LuaLooter.log", -- NEW
        max_log_size_mb = 10              -- NEW
      },
        
      char_settings = {
        MasterLoot = true,
        LootFromGeneralSection = true,
        LootValue = 1000,
        LootTrash = false,
        LootPersonalOnly = false,
        AlwaysLootTradeskills = true,
        SaveSlots = 3,
        AutoLootCash = true,
        AutoLootQuest = true,
        AutoLootCollectible = true,
        QuestLootValue = 500,
      }
    }
    
    -- Helper functions
    local function to_bool(val)
        if type(val) == 'boolean' then return val end
        if type(val) == 'number' then return val ~= 0 end
        if type(val) == 'string' then
            local lower = string.lower(val)
            return lower == 'true' or lower == '1' or lower == 'yes'
        end
        return false
    end
    
    local function clean_numeric(val, default)
        if type(val) == 'string' then
            local lower = string.lower(val)
            if lower == 'nil' or lower == 'null' or lower == '' then
                return default
            end
        end
        return tonumber(val) or default
    end
    
    -- Helper to safely get INI value
    local function get_ini_value(ini_file, section, key, default)
        local value = mq.TLO.Ini(ini_file, section, key, default)()
        
        -- Handle "NULL" string that MQ returns for missing entries
        if value and type(value) == 'string' and string.lower(value) == 'null' then
            return default
        end
        
        return value
    end
    
    -- Helper to safely set INI value
    local function set_ini_value(ini_file, section, key, value)
        -- Escape quotes in the value
        local safe_value = tostring(value):gsub('"', '\\"')
        
        -- Use MQ's /ini command
        mq.cmdf('/ini "%s" "%s" "%s" "%s"', 
            ini_file, 
            section, 
            key, 
            safe_value)
        
        return true
    end
    
    function self:load()
        self.logger:info("Loading configuration from: %s", self.ini_file)
        
        local char_name = mq.TLO.Me.Name()
        
        -- Load Settings section
        for key, default_val in pairs(self.settings) do
            local value = get_ini_value(self.ini_file, "Settings", key, default_val)
            
            -- Convert boolean strings
            if type(default_val) == 'boolean' then
                value = to_bool(value)
            end
            
            -- Convert numeric strings
            if type(default_val) == 'number' then
                value = clean_numeric(value, default_val)
            end
            
            self.settings[key] = value
        end
        
        -- Load character-specific settings
        for key, default_val in pairs(self.char_settings) do
            local value = get_ini_value(self.ini_file, char_name, key, default_val)
            
            -- Convert boolean strings
            if type(default_val) == 'boolean' then
                value = to_bool(value)
            end
            
            -- Convert numeric strings
            if type(default_val) == 'number' then
                value = clean_numeric(value, default_val)
            end
            
            self.char_settings[key] = value
        end
        
        self.logger:info("Configuration loaded successfully")
    end
    
    function self:save()
        local char_name = mq.TLO.Me.Name()
        
        -- Save Settings section
        for key, value in pairs(self.settings) do
            set_ini_value(self.ini_file, "Settings", key, value)
        end
        
        -- Save character-specific settings
        for key, value in pairs(self.char_settings) do
            set_ini_value(self.ini_file, char_name, key, value)
        end
        
        self.logger:info("Configuration saved to: %s", self.ini_file)
    end
    
    function self:get(setting)
        return self.settings[setting]
    end
    
    function self:get_char(setting)
        return self.char_settings[setting]
    end
    
    function self:set(setting, value)
        self.settings[setting] = value
        return self
    end
    
    function self:set_char(setting, value)
        self.char_settings[setting] = value
        return self
    end
    
    return self
end

return Config