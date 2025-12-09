--[[
DESIGN DECISION: Filter system as a standalone module
WHY: Filters are a distinct feature that can be enabled/disabled
     Clean separation from core loot logic
     Easy to expand with new filter types or conditions
--]]

local mq = require('mq')

local Filters = {}

function Filters.new(state, config, logger, events, item_service)
    local self = {
        state = state,
        config = config,
        logger = logger,
        events = events,
        items = item_service,
        
        filter_types = {
            "AlwaysNeed",
            "Need", 
            "AlwaysGreed",
            "Greed",
            "Never",
            "No"
        },
        
        filter_cache = {}  -- Cache filter checks
    }
    
    function self:check_filter(index, is_shared, filter_type)
        local cache_key = string.format("%s_%d_%s", is_shared and "S" or "P", index, filter_type)
        
        if self.filter_cache[cache_key] then
            local cached = self.filter_cache[cache_key]
            if os.time() - cached.timestamp < 5 then  -- 5 second cache
                return cached.value
            end
        end
        
        local filter_value = false
        
        if not mq.TLO.AdvLoot then
            self.logger:warn("AdvLoot TLO not available")
            return false
        end
        
        -- Get the AdvLootItem object
        local loot_item = nil
        if is_shared then
            local shared_count = mq.TLO.AdvLoot.SCount()
            if shared_count and shared_count >= index then
                loot_item = mq.TLO.AdvLoot.SList(index)
            end
        else
            local personal_count = mq.TLO.AdvLoot.PCount()
            if personal_count and personal_count >= index then
                loot_item = mq.TLO.AdvLoot.PList(index)
            end
        end
        
        if loot_item and loot_item() then
            -- Access the filter property directly from the AdvLootItem
            -- According to the source code, these are boolean properties
            if filter_type == "AlwaysNeed" then
                filter_value = loot_item.AlwaysNeed()
            elseif filter_type == "Need" then
                filter_value = loot_item.Need()
            elseif filter_type == "AlwaysGreed" then
                filter_value = loot_item.AlwaysGreed()
            elseif filter_type == "Greed" then
                filter_value = loot_item.Greed()
            elseif filter_type == "Never" then
                filter_value = loot_item.Never()
            elseif filter_type == "No" then
                filter_value = loot_item.No()
            end
        end
        
        -- Cache the result (convert boolean to 1 or 0 for consistency)
        self.filter_cache[cache_key] = {
            value = filter_value and 1 or 0,
            timestamp = os.time()
        }
        
        return filter_value and 1 or 0
    end
    
    function self:has_any_filter(index, is_shared)
        for _, filter_type in ipairs(self.filter_types) do
            local value = self:check_filter(index, is_shared, filter_type)
            if value and value > 0 then
                return true, filter_type, value
            end
        end
        return false, nil, 0
    end
    
  function self:filter_to_action(filter_type, item_info, item_name)
    self.logger:debug("Filter %s active for %s", filter_type, item_name)
    
    -- Helper function to check INI for pass rules (ELIMINATES DUPLICATION)
    local function check_ini_for_pass_rule()
        local ini_config = self.items:get_ini_config(item_name)
        if ini_config and ini_config.personal then
            local parsed = self.items.ini:parse_ini_rule(ini_config.personal)
            
            if parsed.action and string.lower(parsed.action) == "pass" and parsed.player_name then
                return "PASS|" .. parsed.player_name
            end
        end
        return nil
    end
    
    if filter_type == "AlwaysNeed" or filter_type == "Need" then
        -- Check Lore for Need filters
        if item_info and item_info.lore then
            local existing_count = self.items.inventory:get_item_count(item_name)
            if existing_count > 0 then
                self.logger:info("Lore item %s already in inventory, ignoring despite Need filter", item_name)
                return "IGNORE"
            end
        end
        return "KEEP"
        
    elseif filter_type == "AlwaysGreed" or filter_type == "Greed" then
        -- Greed items with sufficient value
        if item_info.value and item_info.value >= 1000 then
            return "KEEP"
        else
            return "IGNORE"
        end
        
    elseif filter_type == "Never" or filter_type == "No" then
        -- SINGLE call to check INI for pass rules (no duplication)
        local pass_rule = check_ini_for_pass_rule()
        if pass_rule then
            self.logger:debug("Never/No filter with pass rule found for %s", item_name)
            return pass_rule
        end
        
        -- No pass rule found in INI
        if item_info and item_info.no_drop then
            -- No-drop item with Never/No filter and no pass rule = wait 5 minutes
            self.logger:debug("Never/No filter on no-drop item %s with no pass rule, waiting 5 minutes", item_name)
            return "LEAVE"  -- Leave in window for 5 minutes
        else
            -- Non-no-drop item with Never/No filter and no pass rule = ignore immediately
            self.logger:debug("Never/No filter on non-no-drop item %s with no pass rule, ignoring", item_name)
            return "IGNORE"  -- Execute /advloot never immediately
        end
    end
    
    return nil
  end
    
    function self:process()
        local filter_actions = {}
        
        -- Check shared loot
        local shared_count = mq.TLO.AdvLoot.SCount()
        if shared_count then
            for i = 1, shared_count do
                local has_filter, filter_type, value = self:has_any_filter(i, true)
                if has_filter then
                    local item = mq.TLO.AdvLoot.SList(i)
                    if item and item() then
                        local name = item.Name()
                        local info = self.items:get_item_info(name)
                        local action = self:filter_to_action(filter_type, info, name)
                        
                        if action then
                            filter_actions[name] = {
                                index = i,
                                action = action,
                                is_shared = true,
                                filter_type = filter_type,
                                filter_value = value
                            }
                            
                            self.events:publish(self.events.EVENT_TYPES.LOOT_ITEM, {
                                name = name,
                                filter = filter_type,
                                action = action
                            })
                        end
                    end
                end
            end
        end
        
        -- Check personal loot
        local personal_count = mq.TLO.AdvLoot.PCount()
        if personal_count then
            for i = 1, personal_count do
                local has_filter, filter_type, value = self:has_any_filter(i, false)
                if has_filter then
                    local item = mq.TLO.AdvLoot.PList(i)
                    if item and item() then
                        local name = item.Name()
                        local info = self.items:get_item_info(name)
                        local action = self:filter_to_action(filter_type, info, name)
                        
                        if action then
                            filter_actions[name] = {
                                index = i,
                                action = action,
                                is_shared = false,
                                filter_type = filter_type,
                                filter_value = value
                            }
                        end
                    end
                end
            end
        end
        
        -- Clear old cache entries
        self:clean_cache()
        
        return filter_actions
    end
    
    function self:clean_cache()
        local now = os.time()
        for key, cached in pairs(self.filter_cache) do
            if now - cached.timestamp > 30 then  -- 30 second TTL
                self.filter_cache[key] = nil
            end
        end
    end
    
    function self:clear_cache()
        self.filter_cache = {}
        self.logger:debug("Filter cache cleared")
    end
    
    return self
end

return Filters