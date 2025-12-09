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
    
    -- Helper function for boolean toggles
    local function parse_bool_arg(arg, current_value)
        if arg == "" or arg == "on" or arg == "true" or arg == "1" then
            return true
        elseif arg == "off" or arg == "false" or arg == "0" then
            return false
        else
            -- Toggle if no specific value given
            return not current_value
        end
    end
    
    -- Helper function for numeric arguments
    local function parse_numeric_arg(arg, default)
        local num = tonumber(arg)
        if num and num > 0 then
            return num
        end
        return default
    end
    
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
            gui = {fn = self.cmd_gui, help = "Toggle GUI window (gui show/hide)"},
            pause = {fn = self.cmd_pause, help = "Pause loot processing"},
            resume = {fn = self.cmd_resume, help = "Resume loot processing"},
            status = {fn = self.cmd_status, help = "Show current status"},
            
            -- Settings commands (with aliases)
            alwaysloottradeskill = {fn = self.cmd_tradeskill, help = "Toggle auto-looting tradeskill items"},
            tradeskill = {fn = self.cmd_tradeskill, help = "Alias for /ll alwaysloottradeskill"},
            autolootcash = {fn = self.cmd_cash, help = "Toggle auto-looting cash"},
            cash = {fn = self.cmd_cash, help = "Alias for /ll autolootcash"},
            autolootquest = {fn = self.cmd_quest, help = "Toggle auto-looting quest items"},
            quest = {fn = self.cmd_quest, help = "Alias for /ll autolootquest"},
            autolootcollectible = {fn = self.cmd_collectible, help = "Toggle auto-looting collectible items"},
            collectible = {fn = self.cmd_collectible, help = "Alias for /ll autolootcollectible"},
            lootvalue = {fn = self.cmd_lootvalue, help = "Set minimum value to loot (in copper)"},
            questlootvalue = {fn = self.cmd_questvalue, help = "Set minimum value for tradeable quest items"},
            saveslots = {fn = self.cmd_saveslots, help = "Set number of bag slots to keep free"},
            autowindow = {fn = self.cmd_autowindow, help = "Toggle auto-opening advloot window"},
            nodropwait = {fn = self.cmd_nodropwait, help = "Set wait time for no-drop items (seconds)"},
            
            -- Additional commands
            masterloot = {fn = self.cmd_masterloot, help = "Toggle master looter mode"},
            loottrash = {fn = self.cmd_loottrash, help = "Toggle looting trash items"},
            lootpersonalmode = {fn = self.cmd_lootpersonalmode, help = "Toggle personal loot only mode"},
            lootfromgeneral = {fn = self.cmd_lootfromgeneral, help = "Toggle using general section rules"},
            clearcache = {fn = self.cmd_clearcache, help = "Clear item cache"},
            test = {fn = self.cmd_test, help = "Test functionality"},
            version = {fn = self.cmd_version, help = "Show version information"}
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
    
    -- === CORE COMMANDS ===
    
    function self:cmd_on(arg)
        self.config.settings.alpha_mode = false
        self.config:save()
        self.logger:warn("PRODUCTION MODE ENABLED. Looting active.")
    end
    
    function self:cmd_off(arg)
        self.config.settings.alpha_mode = true
        self.config:save()
        self.logger:info("Alpha Mode Enabled. Logging only.")
    end
    
    function self:cmd_profit(arg)
        if self.services.profit and self.services.profit.get_stats then
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
        else
            self.logger:error("Profit service not available")
        end
    end
    
    function self:cmd_reload(arg)
        self.config:load()
        self.logger:info("Settings reloaded from INI")
    end
    
    function self:cmd_settings(arg)
        local cs = self.config.char_settings
        local ss = self.config.settings
        
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
        self.logger:info("LootPersonalOnly: %s", tostring(cs.LootPersonalOnly))
        self.logger:info("LootFromGeneralSection: %s", tostring(cs.LootFromGeneralSection))
        self.logger:info("Auto-open window: %s", tostring(ss.auto_open_window))
        self.logger:info("No-drop wait time: %d seconds", ss.no_drop_wait_time or 300)
        self.logger:info("Alpha Mode: %s", tostring(ss.alpha_mode))
        self.logger:info("Debug Logging: %s", tostring(ss.debug_logging))
    end
    
    function self:cmd_help(arg)
        self.logger:info("=== LuaLooter Commands ===")
        
        -- Sort commands alphabetically for better display
        local sorted_commands = {}
        for cmd_name, _ in pairs(self.commands) do
            table.insert(sorted_commands, cmd_name)
        end
        table.sort(sorted_commands)
        
        for _, cmd_name in ipairs(sorted_commands) do
            local cmd_info = self.commands[cmd_name]
            self.logger:info("/ll %-20s - %s", cmd_name, cmd_info.help)
        end
        
        self.logger:info("")
        self.logger:info("=== INI Rule Examples ===")
        self.logger:info("Keep|5 - Keep up to 5 of this item")
        self.logger:info("Quest|5 - Keep up to 5 of this quest item")
        self.logger:info("Quest|5|Walking the dog - Keep up to 5 only if you have the quest")
        self.logger:info("Pass|Selien - Always pass this item to Selien")
        self.logger:info("Ignore - Never loot this item")
        self.logger:info("Destroy - Loot and destroy this item")
        self.logger:info("Sell - Loot to sell (value-based)")
        self.logger:info("Tradeskill - Always loot tradeskill items")
        self.logger:info("Collectible - Always loot collectible items")
    end
    
    function self:cmd_debug(arg)
        self.logger:info("=== DEBUG INFO ===")
        self.logger:info("State Enabled: %s", tostring(self.state:is_enabled()))
        self.logger:info("State Processing: %s", tostring(self.state:is_processing()))
        self.logger:info("Last Check: %d seconds ago", os.time() - self.state.last_check)
        
        if self.services.profit then
            local stats = self.services.profit:get_stats()
            self.logger:info("Cash looted: %s", stats.formatted.cash)
            self.logger:info("Item value looted: %s", stats.formatted.value)
            self.logger:info("Total items looted: %d", stats.items_looted)
        end
        
        self.logger:info("=== Current Loot ===")
        
        local shared_count = mq.TLO.AdvLoot.SCount() or 0
        local personal_count = mq.TLO.AdvLoot.PCount() or 0
        
        self.logger:info("Shared items: %d", shared_count)
        for i = 1, shared_count do
            local item = mq.TLO.AdvLoot.SList(i)
            if item() then
                local name = item.Name()
                self.logger:info("  [S%d] %s", i, name)
            end
        end
        
        self.logger:info("Personal items: %d", personal_count)
        for i = 1, personal_count do
            local item = mq.TLO.AdvLoot.PList(i)
            if item() then
                local name = item.Name()
                self.logger:info("  [P%d] %s", i, name)
            end
        end
    end
    
    function self:cmd_resetstats(arg)
        if self.services.profit then
            self.services.profit:reset_stats()
            self.logger:info("Profit stats reset")
        else
            self.logger:error("Profit service not available")
        end
    end
    
    function self:cmd_gui(arg)
        -- Check if GUI is available in services
        if not self.services.gui then
            self.logger:error("GUI not available. Make sure GUI files are loaded.")
            return
        end
    
        -- Handle sub-commands
        if arg == "show" then
            self.services.gui:show()
            self.logger:info("GUI shown")
        elseif arg == "hide" then
            self.services.gui:hide()
            self.logger:info("GUI hidden")
        else
            -- Toggle GUI
            local visible = self.services.gui:toggle()
            self.logger:info("GUI %s", visible and "shown" or "hidden")
        end
    end
    
    function self:cmd_pause(arg)
        self.state:set_enabled(false)
        self.logger:info("LuaLooter PAUSED")
    end
    
    function self:cmd_resume(arg)
        self.state:set_enabled(true)
        self.logger:info("LuaLooter RESUMED")
    end
    
    function self:cmd_status(arg)
        self.logger:info("=== Status ===")
        self.logger:info("Enabled: %s", tostring(self.state:is_enabled()))
        self.logger:info("Alpha Mode: %s", tostring(self.config.settings.alpha_mode))
        self.logger:info("Master Looter: %s", tostring(self.config.char_settings.MasterLoot))
        self.logger:info("GUI Available: %s", tostring(self.services.gui ~= nil))
        if self.services.gui then
            self.logger:info("GUI Visible: %s", tostring(self.services.gui:is_visible()))
        end
    end
    
    -- === SETTINGS COMMANDS ===
    
    function self:cmd_tradeskill(arg)
        local current = self.config.char_settings.AlwaysLootTradeskills
        local new_value = parse_bool_arg(arg, current)
        
        self.config.char_settings.AlwaysLootTradeskills = new_value
        self.config:save()
        self.logger:info("AlwaysLootTradeskills: %s", new_value and "ENABLED" or "DISABLED")
    end
    
    function self:cmd_cash(arg)
        local current = self.config.char_settings.AutoLootCash
        local new_value = parse_bool_arg(arg, current)
        
        self.config.char_settings.AutoLootCash = new_value
        self.config:save()
        self.logger:info("AutoLootCash: %s", new_value and "ENABLED" or "DISABLED")
    end
    
    function self:cmd_quest(arg)
        local current = self.config.char_settings.AutoLootQuest
        local new_value = parse_bool_arg(arg, current)
        
        self.config.char_settings.AutoLootQuest = new_value
        self.config:save()
        self.logger:info("AutoLootQuest: %s", new_value and "ENABLED" or "DISABLED")
    end
    
    function self:cmd_collectible(arg)
        local current = self.config.char_settings.AutoLootCollectible
        local new_value = parse_bool_arg(arg, current)
        
        self.config.char_settings.AutoLootCollectible = new_value
        self.config:save()
        self.logger:info("AutoLootCollectible: %s", new_value and "ENABLED" or "DISABLED")
    end
    
    function self:cmd_lootvalue(arg)
        local value = parse_numeric_arg(arg, 1000)
        
        self.config.char_settings.LootValue = value
        self.config:save()
        self.logger:info("LootValue set to: %d copper", value)
    end
    
    function self:cmd_questvalue(arg)
        local value = parse_numeric_arg(arg, 500)
        
        self.config.char_settings.QuestLootValue = value
        self.config:save()
        self.logger:info("QuestLootValue set to: %d copper", value)
    end
    
    function self:cmd_saveslots(arg)
        local slots = parse_numeric_arg(arg, 3)
        
        self.config.char_settings.SaveSlots = slots
        self.config:save()
        self.logger:info("SaveSlots set to: %d", slots)
    end
    
    function self:cmd_autowindow(arg)
        local current = self.config.settings.auto_open_window
        local new_value = parse_bool_arg(arg, current)
        
        self.config.settings.auto_open_window = new_value
        self.config:save()
        self.logger:info("Auto-open window: %s", new_value and "ENABLED" or "DISABLED")
    end
    
    function self:cmd_nodropwait(arg)
        local seconds = parse_numeric_arg(arg, 300)
        
        self.config.settings.no_drop_wait_time = seconds
        self.config:save()
        self.logger:info("No-drop wait time set to: %d seconds", seconds)
    end
    
    function self:cmd_masterloot(arg)
        local current = self.config.char_settings.MasterLoot
        local new_value = parse_bool_arg(arg, current)
        
        self.config.char_settings.MasterLoot = new_value
        self.config:save()
        self.logger:info("MasterLoot: %s", new_value and "ENABLED" or "DISABLED")
    end
    
    function self:cmd_loottrash(arg)
        local current = self.config.char_settings.LootTrash
        local new_value = parse_bool_arg(arg, current)
        
        self.config.char_settings.LootTrash = new_value
        self.config:save()
        self.logger:info("LootTrash: %s", new_value and "ENABLED" or "DISABLED")
    end
    
    function self:cmd_lootpersonalmode(arg)
        local current = self.config.char_settings.LootPersonalOnly
        local new_value = parse_bool_arg(arg, current)
        
        self.config.char_settings.LootPersonalOnly = new_value
        self.config:save()
        self.logger:info("LootPersonalOnly: %s", new_value and "ENABLED" or "DISABLED")
    end
    
    function self:cmd_lootfromgeneral(arg)
        local current = self.config.char_settings.LootFromGeneralSection
        local new_value = parse_bool_arg(arg, current)
        
        self.config.char_settings.LootFromGeneralSection = new_value
        self.config:save()
        self.logger:info("LootFromGeneralSection: %s", new_value and "ENABLED" or "DISABLED")
    end
    
    -- === ADDITIONAL COMMANDS ===
    
    function self:cmd_clearcache(arg)
        if self.services.items then
            self.services.items:clear_cache()
            self.logger:info("Item cache cleared")
        else
            self.logger:error("Item service not available")
        end
    end
    
    function self:cmd_test(arg)
        self.logger:info("=== Test Mode ===")
        self.logger:info("Testing logger: DEBUG message")
        self.logger:debug("This is a debug message")
        self.logger:info("This is an info message")
        self.logger:warn("This is a warning message")
        self.logger:error("This is an error message")
        self.logger:info("Test complete")
    end
    
    function self:cmd_version(arg)
        self.logger:info("LuaLooter v0.5.0")
        self.logger:info("Advanced Looting System for EverQuest")
        self.logger:info("GUI Support: Included")
        self.logger:info("Profile Tracking: Enabled")
        self.logger:info("INI Configuration: Supported")
    end
    
    -- Initialize
    self:register_commands()
    
    return self
end

return CommandHandler