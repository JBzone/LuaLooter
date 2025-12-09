-- core/events.lua
local Events = {}

function Events.new()
    local self = {
        EVENT_TYPES = {
            -- Cash events
            CASH_LOOTED = "cash_looted",
            
            -- Item events
            ITEM_LOOTED = "item_looted",
            ITEM_DESTROYED = "item_destroyed",
            ITEM_PASSED = "item_passed",
            ITEM_LEFT = "item_left",
            
            -- Loot processing events
            LOOT_ACTION = "loot_action",         -- From logic to execution
            LOOT_START = "loot_start",           -- Loot processing started
            LOOT_COMPLETE = "loot_complete",     -- Loot processing completed
            LOOT_ITEM = "loot_item",             -- Legacy/alias for item_looted
            
            -- Window events
            LOOT_WINDOW_OPEN = "loot_window_open",
            LOOT_WINDOW_CLOSE = "loot_window_close",
            
            -- No-drop timer events
            NO_DROP_WAIT_START = "no_drop_wait_start",
            NO_DROP_WAIT_EXPIRED = "no_drop_wait_expired",
            
            -- Configuration events
            CONFIG_CHANGED = "config_changed",
            PROFIT_UPDATED = "profit_updated",
            
            -- UI events
            GUI_TOGGLE = "gui_toggle",
            GUI_UPDATE = "gui_update",
            
            -- State events
            STATE_CHANGED = "state_changed",
            MODULE_TOGGLE = "module_toggle",
            
            -- Error events
            ERROR_OCCURRED = "error_occurred",
            WARNING_OCCURRED = "warning_occurred"
        },
        subscribers = {}
    }
    
    function self:publish(event_type, data)
        data = data or {}
        data.event_type = event_type
        data.timestamp = os.time()
        
        local subscribers = self.subscribers[event_type]
        if subscribers then
            for _, callback in ipairs(subscribers) do
                local success, err = pcall(callback, data)
                if not success then
                    print(string.format("[Events] Callback error for %s: %s", event_type, err))
                end
            end
        end
        
        -- Also trigger global subscribers
        local all_subscribers = self.subscribers["*"]
        if all_subscribers then
            for _, callback in ipairs(all_subscribers) do
                local success, err = pcall(callback, data)
                if not success then
                    print(string.format("[Events] Global callback error: %s", err))
                end
            end
        end
        
        self.logger:debug("Event published: %s", event_type)
    end
    
    function self:subscribe(event_type, callback)
        if not self.subscribers[event_type] then
            self.subscribers[event_type] = {}
        end
        table.insert(self.subscribers[event_type], callback)
        
        self.logger:debug("Subscribed to event: %s", event_type)
    end
    
    function self:subscribe_all(callback)
        self:subscribe("*", callback)
    end
    
    function self:unsubscribe(event_type, callback)
        if not self.subscribers[event_type] then return end
        
        for i, cb in ipairs(self.subscribers[event_type]) do
            if cb == callback then
                table.remove(self.subscribers[event_type], i)
                self.logger:debug("Unsubscribed from event: %s", event_type)
                break
            end
        end
    end
    
    function self:get_event_types()
        return self.EVENT_TYPES
    end
    
    return self
end

return Events