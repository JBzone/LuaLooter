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
        
        last_command_time = 0,
        command_cooldown = 500,  -- 500ms between commands
        max_retries = 3
    }
    
    function self:can_execute()
        if self.state:is_processing() then
            self.logger:debug("Cannot execute - already processing loot")
            return false
        end
        
        local now = mq.gettime()
        if now - self.last_command_time < self.command_cooldown then
            self.logger:debug("Cannot execute - command on cooldown")
            return false
        end
        
        return true
    end
    
    function self:execute_safely(command, item_name, action)
        if not self:can_execute() then
            return false
        end
        
        if self.config.settings.alpha_mode then
            self.logger:info("[ALPHA] Would execute: %s", command)
            return true
        end
        
        self.state:set_processing(true)
        self.last_command_time = mq.gettime()
        
        self.logger:debug("Executing: %s", command)
        mq.cmd(command)
        
        -- Wait for command to process
        mq.delay(500)
        
        self.state:set_processing(false)
        self.logger:info("Looted: %s (%s)", item_name, action)
        
        self.events:publish(self.events.EVENT_TYPES.LOOT_ITEM, {
            name = item_name,
            action = action,
            command = command
        })
        
        return true
    end
    
    function self:loot_item(index, action, name, info, is_shared)
        local command
        
        if action:match("^PASS|") then
            local _, target = action:match("^(PASS)|(.+)$")
            if target and is_shared then
                command = string.format("/advloot shared %d giveto %s", index, target)
            end
        elseif action == "CASH" or action == "KEEP" or action == "SELL" then
            local target = is_shared and " giveto " .. mq.TLO.Me.Name() or " loot"
            command = string.format("/advloot %s %d%s", is_shared and "shared" or "personal", index, target)
        elseif action == "DESTROY" then
            if is_shared then
                command = string.format('/advloot shared %d giveto %s', index, mq.TLO.Me.Name())
            else
                command = string.format('/advloot personal %d loot', index)
            end
        elseif action == "PASS" and is_shared then
            command = string.format("/advloot shared %d giveto %s", index, self.config.char_settings.PassLootPlayer)
        elseif action == "IGNORE" and is_shared then
            command = string.format("/advloot shared %d leave", index)
        end
        
        if command then
            return self:execute_safely(command, name, action)
        end
        
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
            end
        end
    end
    
    return self
end

return LootService