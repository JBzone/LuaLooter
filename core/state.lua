--[[
DESIGN DECISION: Immutable state pattern with getters/setters
WHY: Prevents accidental state mutation from multiple modules
     Single source of truth for application state
     Easy to add state persistence or undo/redo
--]]

local State = {}

function State.new()
    local self = {
        -- Runtime state
        enabled = true,
        processing_loot = false,
        window_was_opened = false,
        last_check = 0,
        
        -- Tracking state
        loot_decisions = {},
        loot_attempts = {},
        no_drop_timers = {},
        
        -- Profit tracking (NEW)
        profit_stats = {
            session_start = os.time(),
            items_looted = 0,
            value_looted = 0,  -- In copper
            cash_looted = 0    -- In copper
        },
        
        -- Future GUI state (structured for expansion)
        gui = {
            visible = false,
            active_tab = "loot",
            settings = {}
        },
        
        -- Module enable/disable state
        modules = {
            filters = true,
            inventory = true,
            quests = false  -- Future module
        }
    }
    
    -- Getters (read-only access)
    function self:is_enabled() return self.enabled end
    function self:is_processing() return self.processing_loot end
    function self:get_decision(key) return self.loot_decisions[key] end
    
    -- Profit stats getters
    function self:get_profit_stats() return self.profit_stats end
    function self:get_items_looted() return self.profit_stats.items_looted end
    function self:get_value_looted() return self.profit_stats.value_looted end
    function self:get_cash_looted() return self.profit_stats.cash_looted end
    function self:get_session_start() return self.profit_stats.session_start end
    
    -- Profit stats setters
    function self:add_item_value(value)
        if value and value > 0 then
            self.profit_stats.value_looted = self.profit_stats.value_looted + value
            self.profit_stats.items_looted = self.profit_stats.items_looted + 1
        end
        return self
    end
    
    function self:add_cash_value(plat, gold, silver, copper)
        local total_copper = (plat or 0) * 1000 + (gold or 0) * 100 + (silver or 0) * 10 + (copper or 0)
        if total_copper > 0 then
            self.profit_stats.cash_looted = self.profit_stats.cash_looted + total_copper
        end
        return self
    end
    
    function self:reset_profit_stats()
        self.profit_stats = {
            session_start = os.time(),
            items_looted = 0,
            value_looted = 0,
            cash_looted = 0
        }
        return self
    end
    
    -- Setters (controlled mutation)
    function self:set_enabled(value) 
        self.enabled = value 
        return self
    end
    
    function self:set_processing(value)
        self.processing_loot = value
        return self
    end
    
    function self:add_decision(key, value)
        self.loot_decisions[key] = value
        return self
    end
    
    function self:clear_decisions()
        self.loot_decisions = {}
        return self
    end
    
    -- No-drop timer management
    function self:start_no_drop_timer(item_name)
        self.no_drop_timers[item_name] = os.time()
        return self
    end
    
    function self:get_no_drop_wait_time(item_name, wait_time)
        local start = self.no_drop_timers[item_name]
        if not start then return nil end
        
        local elapsed = os.time() - start
        if elapsed >= wait_time then
            self.no_drop_timers[item_name] = nil
            return nil  -- Timer expired
        end
        return elapsed  -- Timer still active
    end
    
    -- NEW: Clear no-drop timers when appropriate
    function self:clear_expired_no_drop_timers(wait_time)
        local now = os.time()
        local cleared = 0
        for item_name, start_time in pairs(self.no_drop_timers) do
            if now - start_time >= wait_time then
                self.no_drop_timers[item_name] = nil
                cleared = cleared + 1
            end
        end
        return cleared
    end
    
    return self
end

return State