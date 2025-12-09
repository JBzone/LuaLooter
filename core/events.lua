--[[
DESIGN DECISION: Observer pattern for loose coupling
WHY: Modules can communicate without direct dependencies
     Enables plugin system and hot-swapping modules
     Easy to add logging, debugging, or metrics to events
--]]

local Events = {}

function Events.new()
    local self = {
        listeners = {},
        event_history = {}  -- For debugging
    }
    
    -- Event types (expand as needed)
    self.EVENT_TYPES = {
        LOOT_START = "loot_start",
        LOOT_ITEM = "loot_item",
        LOOT_COMPLETE = "loot_complete",
        CASH_LOOTED = "cash_looted",
        ITEM_IGNORED = "item_ignored",
        NO_DROP_WAIT = "no_drop_wait",
        CONFIG_CHANGED = "config_changed",
        ERROR = "error"
    }
    
    function self:subscribe(event_type, listener_id, callback)
        if not self.listeners[event_type] then
            self.listeners[event_type] = {}
        end
        self.listeners[event_type][listener_id] = callback
        return self
    end
    
    function self:unsubscribe(event_type, listener_id)
        if self.listeners[event_type] then
            self.listeners[event_type][listener_id] = nil
        end
        return self
    end
    
    function self:publish(event_type, data)
        -- Store for debugging (optional)
        table.insert(self.event_history, {
            time = os.time(),
            event = event_type,
            data = data
        })
        
        -- Trim history if too large
        if #self.event_history > 1000 then
            table.remove(self.event_history, 1)
        end
        
        -- Notify listeners
        if self.listeners[event_type] then
            for id, callback in pairs(self.listeners[event_type]) do
                local success, err = pcall(callback, data)
                if not success then
                    -- Log error but don't crash
                    print(string.format("Event listener error [%s:%s]: %s", event_type, id, err))
                end
            end
        end
        
        return self
    end
    
    function self:get_history(count)
        count = count or 10
        local start = math.max(1, #self.event_history - count + 1)
        local result = {}
        for i = start, #self.event_history do
            table.insert(result, self.event_history[i])
        end
        return result
    end
    
    return self
end

return Events