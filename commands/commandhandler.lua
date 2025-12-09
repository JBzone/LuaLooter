--[[
DESIGN DECISION: Command handler as a dispatcher
WHY: Clean separation of command parsing from command execution
     Easy to add new commands without modifying core logic
     Supports aliases, help text, and argument validation
--]]

local CommandHandler = {}

function CommandHandler.new(state, config, logger, events, services)
    local self = {
        state = state,
        config = config,
        logger = logger,
        events = events,
        services = services,
        
        commands = {}
    }
    
    -- Register all commands
    function self:register_commands()
        self.commands = {
            on = {fn = self.cmd_on, help = "Enable production mode (start looting)"},
            off = {fn = self.cmd_off, help = "Enable alpha mode (log only)"},
            profit = {fn = self.cmd_profit, help = "Show session profit stats"},
            stats = {fn = self.cmd_profit, help = "Alias for /ll profit"},
            reload = {fn = self.cmd_reload, help = "Reload settings from INI"},
            settings = {fn = self.cmd_settings, help = "Show current settings"},
            help = {fn = self.cmd_help, help = "Show this help"},
            debug = {fn = self.cmd_debug, help = "Show debug information"},
            resetstats = {fn = self.cmd_resetstats, help = "Reset profit statistics"},
            
            -- Settings commands
            alwaysloottradeskill = {fn = self.cmd_tradeskill, help = "Toggle auto-looting tradeskill items"},
            autolootcash = {fn = self.cmd_cash, help = "Toggle auto-looting cash"},
            autolootquest = {fn = self.cmd_quest, help = "Toggle auto-looting quest items"},
            autolootcollectible = {fn = self.cmd_collectible, help = "Toggle auto-looting collectible items"},
            lootvalue = {fn = self.cmd_lootvalue, help = "Set minimum value to loot (in copper)"},
            questlootvalue = {fn = self.cmd_questvalue, help = "Set minimum value for tradeable quest items"},
            saveslots = {fn = self.cmd_saveslots, help = "Set number of bag slots to keep free"},
            autowindow = {fn = self.cmd_autowindow, help = "Toggle auto-opening advloot window"},
            nodropwait = {fn = self.cmd_nodropwait, help = "Set wait time for no-drop items (seconds)"}
        }
    end
    
    function self:handle(raw_cmd, raw_arg)
        local cmd = string.lower(raw_cmd or "")
        local arg = raw_arg and string.lower(raw_arg) or ""
        
        self.logger:debug("Command received: /ll %s %s", cmd, arg)
        
        if self.commands[cmd] then
            local success, err = pcall(self.commands[cmd].fn, self, arg)
            if not success then
                self.logger:error("Command error: %s", err)
            end
        else
            self.logger:info("Unknown command: %s. Type /ll help for commands.", cmd)
        end
    end
    
    -- Command implementations
    function self:cmd_on(arg)
        self.config.settings.alpha_mode = false
        self.config:save()
        self.logger:warn("PRODUCTION MODE ENABLED. Looting active.")
    end
    
    function self:cmd_off(arg)
        self.config.settings.alpha_mode = true
        self.logger:info("Alpha Mode Enabled. Logging only.")
    end
    
    function self:cmd_profit(arg)
        local stats = self.services.profit:get_stats()
        local formatted = stats.formatted
        
        self.logger:info("=== Session Profit Stats ===")
        self.logger:info("Time Running: \ay%.1f minutes\ax", stats.run_time)
        self.logger:info("Items Looted: \ag%d\ax", stats.items_looted)
        self.logger:info("Item Value:   %s", formatted.value)
        self.logger:info("Cash Drops:   %s", formatted.cash)
        self.logger:info("TOTAL PROFIT: %s", formatted.total)
        
        if stats.items_per_hour then
            self.logger:info("Items/Hour:   \ag%.1f\ax", stats.items_per_hour)
            self.logger:info("Profit/Hour:  %s", formatted.profit_per_hour)
        end
    end
    
    function self:cmd_settings(arg)
        local cs = self.config.char_settings
        
        self.logger:info("=== Current Settings ===")
        self.logger:info("AlwaysLootTradeskills: %s", tostring(cs.AlwaysLootTradeskills))
        self.logger:info("AutoLootCash: %s", tostring(cs.AutoLootCash))
        self.logger:info("AutoLootQuest: %s", tostring(cs.AutoLootQuest))
        self.logger:info("AutoLootCollectible: %s", tostring(cs.AutoLootCollectible))
        self.logger:info("LootValue: %d copper", cs.LootValue)
        self.logger:info("QuestLootValue: %d copper", cs.QuestLootValue)
        self.logger:info("SaveSlots: %d", cs.SaveSlots)
        self.logger:info("MasterLoot: %s", tostring(cs.MasterLoot))
        self.logger:info("LootTrash: %s", tostring(cs.LootTrash))
        self.logger:info("Auto-open window: %s", tostring(self.config.settings.auto_open_window))
        self.logger:info("No-drop wait time: %d seconds", self.config.settings.no_drop_wait_time)
    end
    
    function self:cmd_help(arg)
        self.logger:info("=== LuaLooter Commands ===")
        
        for cmd_name, cmd_info in pairs(self.commands) do
            self.logger:info("/ll %s - %s", cmd_name, cmd_info.help)
        end
        
        self.logger:info("=== INI Rule Examples ===")
        self.logger:info("Keep|5 - Keep up to 5 of this item")
        self.logger:info("Quest|5 - Keep up to 5 of this quest item")
        self.logger:info("Quest|5|Walking the dog - Keep up to 5 only if you have the quest")
        self.logger:info("Pass|Selien - Always pass this item to Selien")
    end
    
    -- ... other command implementations
    
    -- Initialize
    self:register_commands()
    
    return self
end

return CommandHandler