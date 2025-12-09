--[[
DESIGN DECISION: Separate INI operations from item logic
WHY: Single responsibility principle
     Can change INI format without affecting item logic
     Easy to add encryption, compression, or cloud sync (future)
--]]

local mq = require('mq')

local IniService = {}

function IniService.new(config, logger)
    local self = {
        config = config,
        logger = logger
    }
    
    -- Helper to safely get INI value
    function self:get_ini_value(section, key, default)
        local value = mq.TLO.Ini(self.config.ini_file, section, key, default)()
        
        -- Handle "NULL" string that MQ returns for missing entries
        if value and type(value) == 'string' and string.lower(value) == 'null' then
            return default
        end
        
        return value
    end
    
    -- Helper to safely set INI value
    function self:set_ini_value(section, key, value)
        -- Escape quotes in the value
        local safe_value = tostring(value):gsub('"', '\\"')
        
        -- Use MQ's /ini command
        mq.cmdf('/ini "%s" "%s" "%s" "%s"', 
            self.config.ini_file, 
            section, 
            key, 
            safe_value)
        
        self.logger:debug("Set INI: [%s] %s = %s", section, key, value)
        return true
    end
    
    -- Get all keys in a section
    function self:get_section_keys(section)
        local keys = {}
        -- MQ doesn't have a direct way to get all keys, so we'll use a different approach
        -- We'll rely on other methods to handle this
        return keys
    end
    
    -- Check if section exists by trying to read a dummy key
    function self:section_exists(section)
        local test = self:get_ini_value(section, "__test__", "NOT_FOUND")
        return test ~= "NOT_FOUND"
    end
    
    function self:get_item_rule(item_name, section)
        return self:get_ini_value(section, item_name, "null")
    end
    
    function self:save_item_rule(item_name, rule, is_personal_override, should_update_changeme)
        local char_name = mq.TLO.Me.Name()
        
        -- Determine target section
        local target_section
        if is_personal_override then
            target_section = char_name
            self.logger:debug("Saving personal override: [%s] %s = %s", target_section, item_name, rule)
        else
            local first_char = string.upper(string.sub(item_name, 1, 1))
            if not first_char:match("[A-Z]") then first_char = "X" end
            target_section = first_char
            self.logger:debug("Saving new rule: [%s] %s = %s", target_section, item_name, rule)
        end
        
        -- Update CHANGEME/ASK rules in original section
        if should_update_changeme then
            local first_char = string.upper(string.sub(item_name, 1, 1))
            if not first_char:match("[A-Z]") then first_char = "X" end
            
            local current_rule = self:get_item_rule(item_name, first_char)
            if current_rule and current_rule ~= "null" then
                local lower = string.lower(current_rule:match("^(%w+)") or "")
                
                if lower == "changeme" or lower == "ask" then
                    target_section = first_char
                    self.logger:info("Updating CHANGEME/ASK: [%s] %s = %s (was: %s)", 
                        target_section, item_name, rule, current_rule)
                end
            end
        end
        
        -- Save the rule
        return self:set_ini_value(target_section, item_name, rule)
    end
    
    function self:parse_ini_rule(rule)
        if not rule or rule == "null" then return {} end
        
        local parts = {}
        for part in string.gmatch(rule, "([^|]+)") do
            table.insert(parts, part)
        end
        
        return {
            action = parts[1] or rule,
            quantity = tonumber(parts[2]),
            quest_name = parts[3],
            player_name = parts[2]  -- For Pass|Player rules
        }
    end
    
    -- New method: Get all sections from INI file
    function self:get_all_sections()
        -- This is a limitation of MQ's INI handling - we can't easily list all sections
        -- We'll maintain a list of known sections instead
        local known_sections = {
            "Settings",
            "Quests",
            "A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M",
            "N", "O", "P", "Q", "R", "S", "T", "U", "V", "W", "X", "Y", "Z"
        }
        
        local sections = {}
        for _, section in ipairs(known_sections) do
            if self:section_exists(section) then
                table.insert(sections, section)
            end
        end
        
        -- Also check for character section
        local char_name = mq.TLO.Me.Name()
        if self:section_exists(char_name) then
            table.insert(sections, char_name)
        end
        
        return sections
    end
    
    -- New method: Get all rules in a section
    function self:get_section_rules(section)
        -- MQ limitation: Can't list all keys in a section
        -- We'll need to know what items to look for
        -- This will be handled by the item service caching
        return {}
    end
    
    return self
end

return IniService