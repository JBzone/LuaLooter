--[[
DESIGN DECISION: Separate loot execution from decision logic
WHY: Clean separation of "what to loot" from "how to loot"
     Can add different loot methods (fast loot, safe loot, etc.)
     Easy to add cooldowns, retries, or error recovery
--]]

local mq = require('mq')

local LootService = {}

function LootService.new(state, config, logger, events, item_service)
    local self = {
        state = state,
        config = config,
        logger = logger,
        events = events,
        items = item_service,
        
        -- FIX: Add proper event-driven processing
        waiting_for_loot = false,
        last_command_time = 0,
        command_cooldown = 1500,  -- 1.5 seconds between commands (INCREASED for safety)
        max_retries = 3,
        pending_actions = {},
        current_action = nil
    }
    
    -- Register loot completion events (FIXES RACE CONDITION)
    function self:init()
        self.logger:debug("Initializing LootService with event-driven processing")
    end
    
    function self:handle_loot_complete()
        self.logger:debug("Loot completed event received")
        mq.delay(100)
        self.waiting_for_loot = false
        self.state:set_processing(false)
        self.last_command_time = mq.gettime()
        
        if self.current_action then
            -- FIX: Track item profit properly
            local item_name = self.current_action.name
            local action = self.current_action.action
            local item_value = self.items:get_item_value(item_name) or 0
            
            self.events:publish(self.events.EVENT_TYPES.ITEM_LOOTED, {
                name = item_name,
                value = item_value,
                action = action
            })
            
            self.current_action = nil
        end
        
        self:process_next_pending()
    end
    
    function self:handle_destroy_complete(line)
        local item_name = line:match("You successfully destroyed (%d+) (.+)%.")
        if item_name then
            item_name = item_name:gsub("^%d+ ", "")
            self.logger:debug("Destroy completed: %s", item_name)
            
            local item_value = self.items:get_item_value(item_name) or 0
            self.events:publish(self.events.EVENT_TYPES.ITEM_DESTROYED, {
                name = item_name,
                value = item_value
            })
        end
        
        mq.delay(100)
        self.waiting_for_loot = false
        self.state:set_processing(false)
        self.last_command_time = mq.gettime()
        
        self.current_action = nil
        self:process_next_pending()
    end
    
    function self:handle_action_complete()
        self.logger:debug("Loot action (pass/leave) completed")
        mq.delay(100)
        self.waiting_for_loot = false
        self.state:set_processing(false)
        self.last_command_time = mq.gettime()
        
        if self.current_action then
            local item_name = self.current_action.name
            local action = self.current_action.action
            
            if action == "PASS" then
                self.events:publish(self.events.EVENT_TYPES.ITEM_PASSED, {
                    name = item_name
                })
            elseif action == "IGNORE" or action == "LEAVE" then
                self.events:publish(self.events.EVENT_TYPES.ITEM_LEFT, {
                    name = item_name
                })
            end
            
            self.current_action = nil
        end
        
        self:process_next_pending()
    end
    
    function self:can_execute()
        if self.waiting_for_loot then
            self.logger:debug("Cannot execute - waiting for loot to complete")
            return false
        end
        
        if self.state:is_processing() then
            self.logger:debug("Cannot execute - already processing loot")
            return false
        end
        
        local now = mq.gettime()
        if now - self.last_command_time < self.command_cooldown then
            self.logger:debug("Cannot execute - command on cooldown (cooldown: %dms)", 
                self.command_cooldown - (now - self.last_command_time))
            return false
        end
        
        return true
    end
    
    function self:wait_for_cooldown()
        local now = mq.gettime()
        local time_since_last = now - self.last_command_time
        
        if time_since_last < self.command_cooldown then
            local wait_time = self.command_cooldown - time_since_last
            self.logger:debug("Waiting %dms for command cooldown", wait_time)
            mq.delay(wait_time)
        end
        
        -- Also wait if we're currently processing
        local start_wait = mq.gettime()
        while self.waiting_for_loot do
            local time_waiting = mq.gettime() - self.last_command_time
            if time_waiting > 5000 then  -- 5 second timeout
                self.logger:warn("Loot timeout, resetting state")
                self.waiting_for_loot = false
                self.state:set_processing(false)
                break
            end
            mq.delay(100)
            
            if mq.gettime() - start_wait > 10000 then
                self.logger:warn("Safety timeout, forcing reset")
                self.waiting_for_loot = false
                self.state:set_processing(false)
                break
            end
        end
    end
    
    function self:execute_safely(command, item_name, action, item_value)
        -- FIX: Wait for cooldown and any in-progress loot
        self:wait_for_cooldown()
        
        if self.config.settings.alpha_mode then
            self.logger:info("[ALPHA] Would execute: %s", command)
            self.events:publish(self.events.EVENT_TYPES.LOOT_COMPLETE, {
                name = item_name,
                action = action,
                command = command,
                alpha_mode = true
            })
            return true
        end
        
        -- Set state before execution
        self.waiting_for_loot = true
        self.state:set_processing(true)
        self.last_command_time = mq.gettime()
        self.current_action = {
            name = item_name,
            action = action,
            value = item_value
        }
        
        self.logger:debug("Executing: %s", command)
        mq.cmd(command)
        
        -- Don't set processing to false here - wait for event
        return true
    end
    
    function self:process_next_pending()
        if #self.pending_actions > 0 then
            mq.delay(500)  -- Small delay before next action
            local next_action = table.remove(self.pending_actions, 1)
            self:loot_item(next_action.index, next_action.action, next_action.name, 
                          next_action.info, next_action.is_shared, next_action.item_value)
        end
    end
    
    function self:loot_item(index, action, name, info, is_shared, item_value)
        -- FIX: Queue if we're already processing
        if self.waiting_for_loot then
            table.insert(self.pending_actions, {
                index = index,
                action = action,
                name = name,
                info = info,
                is_shared = is_shared,
                item_value = item_value
            })
            self.logger:info("Queued %s for %s", action, name)
            return false
        end
        
        local command
        
        if action:match("^PASS|") then
            local _, target = action:match("^(PASS)|(.+)$")
            if target and is_shared then
                command = string.format("/advloot shared %d giveto %s", index, target)
            end
        elseif action == "CASH" or action == "KEEP" or action == "SELL" or action == "QUEST" or action == "TRADESKILL" then
            local target = is_shared and " giveto " .. mq.TLO.Me.Name() or " loot"
            command = string.format("/advloot %s %d%s", is_shared and "shared" or "personal", index, target)
        elseif action == "DESTROY" then
            if is_shared then
                command = string.format('/advloot shared %d giveto %s', index, mq.TLO.Me.Name())
            else
                command = string.format('/advloot personal %d loot', index)
            end
        elseif action == "PASS" and is_shared then
            command = string.format("/advloot shared %d giveto %s", index, self.config.char_settings.PassLootPlayer or "Unknown")
        elseif action == "IGNORE" and is_shared then
            command = string.format("/advloot shared %d leave", index)
        elseif action == "LEAVE" then
            command = string.format("/advloot %s %d leave", is_shared and "shared" or "personal", index)
        end
        
        if command then
            -- FIX: Pass item_value for proper profit tracking
            return self:execute_safely(command, name, action, item_value)
        end
        
        self.logger:warn("No command for action: %s on %s", action, name)
        return false
    end
    
    function self:open_window()
        if not self.config.settings.auto_open_window or 
           self.config.settings.alpha_mode or
           mq.TLO.Window("AdvancedLootWnd").Open() then
            return
        end
        
        self.logger:info("Auto-opening Advanced Loot window")
        mq.cmd('/advloot')
        self.state.window_was_opened = true
        mq.delay(1000)  -- Give window time to open
    end
    
    function self:close_window_if_done()
        if self.state.window_was_opened and mq.TLO.Window("AdvancedLootWnd").Open() then
            local remaining_shared = mq.TLO.AdvLoot.SCount()
            local remaining_personal = mq.TLO.AdvLoot.PCount()
            
            if remaining_shared == 0 and remaining_personal == 0 then
                self.logger:info("Closing Advanced Loot window")
                mq.cmd('/advloot')
                self.state.window_was_opened = false
                self.events:publish(self.events.EVENT_TYPES.LOOT_WINDOW_CLOSE)
            end
        end
    end
    
    function self:clear_pending()
        self.pending_actions = {}
        self.waiting_for_loot = false
        self.current_action = nil
        self.state:set_processing(false)
        self.logger:debug("Cleared all pending loot actions")
    end
    
    -- Initialize on creation
    self:init()
    
    return self
end

return LootService