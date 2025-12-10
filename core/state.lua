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
        processed_items = {}, -- NEW: Track items already processed in current window
        
        -- Tracking state
        loot_decisions = {},
        loot_attempts = {},
        no_drop_timers = {},
        
        -- Profit tracking (UPDATED for proper item tracking)
        profit_stats = {
            session_start = os.time(),
            items_looted = 0,
            value_looted = 0,          -- In copper (items + cash)
            cash_looted = 0,           -- In copper (cash only)
            items_destroyed_value = 0, -- NEW: Value of destroyed items
            items_passed = {},         -- NEW: Count of passed items
            items_left = {},           -- NEW: Count of left items
            items_by_name = {}         -- NEW: Detailed tracking by item name
        },
        
        -- Future GUI state (structured for expansion)
        gui = {
            visible = false,
            active_tab = "loot",
            initialized = false,
            settings = {  window = {  position = { x = 100, y = 100 }, 
                                      size = { width = 800, height = 600 }
                                   }
                       }
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
    
    -- NEW: Processed items management
    function self:is_processed(item_name) return self.processed_items[item_name] == true end
    function self:add_processed(item_name) self.processed_items[item_name] = true; return self end
    function self:clear_processed_items() self.processed_items = {}; return self end
    
    -- Profit stats getters (UPDATED)
    function self:get_profit_stats() return self.profit_stats end
    function self:get_items_looted() return self.profit_stats.items_looted end
    function self:get_value_looted() return self.profit_stats.value_looted end
    function self:get_cash_looted() return self.profit_stats.cash_looted end
    function self:get_session_start() return self.profit_stats.session_start end
    function self:get_destroyed_value() return self.profit_stats.items_destroyed_value end
    function self:get_passed_items() return self.profit_stats.items_passed end
    function self:get_left_items() return self.profit_stats.items_left end
    function self:get_items_by_name() return self.profit_stats.items_by_name end
    
    -- NEW: Get total profit display (items + cash - destroyed)
    function self:get_net_profit()
        return self.profit_stats.value_looted + self.profit_stats.cash_looted - self.profit_stats.items_destroyed_value
    end
    
    -- NEW: Get profit display string
    function self:get_profit_display()
        local net_profit = self:get_net_profit()
        local plat = math.floor(net_profit / 1000)
        local remainder = net_profit % 1000
        local gold = math.floor(remainder / 100)
        remainder = remainder % 100
        local silver = math.floor(remainder / 10)
        local copper = remainder % 10
        
        return string.format("%dpp %dgp %dsp %dcp", plat, gold, silver, copper)
    end
    
    -- NEW: Get cash display string
    function self:get_cash_display()
        local cash = self.profit_stats.cash_looted
        local plat = math.floor(cash / 1000)
        local remainder = cash % 1000
        local gold = math.floor(remainder / 100)
        remainder = remainder % 100
        local silver = math.floor(remainder / 10)
        local copper = remainder % 10
        
        return string.format("%dpp %dgp %dsp %dcp", plat, gold, silver, copper)
    end
    
    -- NEW: Get destroyed value display string
    function self:get_destroyed_display()
        local destroyed = self.profit_stats.items_destroyed_value
        local plat = math.floor(destroyed / 1000)
        local remainder = destroyed % 1000
        local gold = math.floor(remainder / 100)
        remainder = remainder % 100
        local silver = math.floor(remainder / 10)
        local copper = remainder % 10
        
        return string.format("%dpp %dgp %dsp %dcp", plat, gold, silver, copper)
    end
    
    -- GUI visibility getters/setters
    function self:set_gui_visible(visible) 
        self.gui.visible = visible 
        return self
    end
    
    function self:is_gui_visible() 
        return self.gui.visible 
    end
    
    -- Optional: GUI tab management
    function self:set_gui_tab(tab_name)
        self.gui.active_tab = tab_name
        return self
    end
    
    function self:get_gui_tab()
        return self.gui.active_tab
    end
    
    function self:set_initalized(value)
        self.gui.initialized = value
        return self
    end

    function self:is_initialized()
        return self.gui.initialized
    end

    -- Profit stats setters (UPDATED)
    function self:add_item_value(item_name, value)
        if value and value > 0 then
            self.profit_stats.value_looted = self.profit_stats.value_looted + value
            self.profit_stats.items_looted = self.profit_stats.items_looted + 1
            
            -- Track by item name
            if not self.profit_stats.items_by_name[item_name] then
                self.profit_stats.items_by_name[item_name] = {
                    count = 0,
                    total_value = 0
                }
            end
            self.profit_stats.items_by_name[item_name].count = self.profit_stats.items_by_name[item_name].count + 1
            self.profit_stats.items_by_name[item_name].total_value = self.profit_stats.items_by_name[item_name].total_value + value
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
    
    -- NEW: Track destroyed item value
    function self:add_destroyed_value(item_name, value)
        if value and value > 0 then
            self.profit_stats.items_destroyed_value = self.profit_stats.items_destroyed_value + value
            
            -- Track in items_by_name
            if not self.profit_stats.items_by_name[item_name] then
                self.profit_stats.items_by_name[item_name] = {
                    count = 0,
                    destroyed = 0,
                    total_value = 0
                }
            end
            self.profit_stats.items_by_name[item_name].destroyed = (self.profit_stats.items_by_name[item_name].destroyed or 0) + 1
        end
        return self
    end
    
    -- NEW: Track passed item
    function self:add_passed_item(item_name)
        self.profit_stats.items_passed[item_name] = (self.profit_stats.items_passed[item_name] or 0) + 1
        
        -- Track in items_by_name
        if not self.profit_stats.items_by_name[item_name] then
            self.profit_stats.items_by_name[item_name] = {
                count = 0,
                passed = 0
            }
        end
        self.profit_stats.items_by_name[item_name].passed = (self.profit_stats.items_by_name[item_name].passed or 0) + 1
        return self
    end
    
    -- NEW: Track left item
    function self:add_left_item(item_name)
        self.profit_stats.items_left[item_name] = (self.profit_stats.items_left[item_name] or 0) + 1
        
        -- Track in items_by_name
        if not self.profit_stats.items_by_name[item_name] then
            self.profit_stats.items_by_name[item_name] = {
                count = 0,
                left = 0
            }
        end
        self.profit_stats.items_by_name[item_name].left = (self.profit_stats.items_by_name[item_name].left or 0) + 1
        return self
    end
    
    function self:reset_profit_stats()
        self.profit_stats = {
            session_start = os.time(),
            items_looted = 0,
            value_looted = 0,
            cash_looted = 0,
            items_destroyed_value = 0,
            items_passed = {},
            items_left = {},
            items_by_name = {}
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
    
    -- NEW: Check if any no-drop timers are active
    function self:has_active_no_drop_timers()
        return next(self.no_drop_timers) ~= nil
    end
    
    -- NEW: Get all active no-drop items
    function self:get_active_no_drop_items()
        local items = {}
        for item_name, _ in pairs(self.no_drop_timers) do
            table.insert(items, item_name)
        end
        return items
    end
    
    return self
end

return State