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

  -- ===== ENHANCED VALIDATION HELPERS =====
  local function validate_number(arg, min, max, default, show_warning)
    -- Handle nil/empty
    if arg == nil or arg == "" then
      return default, false
    end
    
    local num = tonumber(arg)
    if not num then
      -- Try to parse "1k", "2.5k", etc.
      if arg:lower():match("%d+%.?%d*[km]?$") then
        local number_part = arg:lower():match("(%d+%.?%d*)")
        local suffix = arg:lower():match("[km]$")
        num = tonumber(number_part)
        if suffix == "k" then num = num * 1000 end
        if suffix == "m" then num = num * 1000000 end
      end
    end
    
    if not num then
      if show_warning then
        return default, true
      end
      return default, false
    end
    
    if min and num < min then
      if show_warning then
        return default, true
      end
      return default, false
    end
    
    if max and num > max then
      if show_warning then
        return default, true
      end
      return default, false
    end
    
    return num, false
  end

  local function validate_boolean(arg, default, show_warning)
    -- Handle nil/empty
    if arg == nil or arg == "" then
      return default, false
    end
    
    local lower = arg:lower()
    if lower == "on" or lower == "true" or lower == "1" or lower == "yes" or lower == "enable" then
      return true, false
    elseif lower == "off" or lower == "false" or lower == "0" or lower == "no" or lower == "disable" then
      return false, false
    end
    
    if show_warning then
      return default, true
    end
    
    return default, false
  end

  local function validate_string(arg, allowed_values, default, show_warning)
    -- Handle nil/empty
    if arg == nil or arg == "" then
      return default, false
    end
    
    for _, allowed in ipairs(allowed_values) do
      if arg:lower() == allowed:lower() then
        return allowed, false
      end
    end
    
    if show_warning then
      return default, true
    end
    
    return default, false
  end

  -- ===== EXISTING HELPERS (KEEP FOR BACKWARD COMPATIBILITY) =====
  local function parse_bool_arg(arg, current_value)
    -- Use enhanced validator with toggle behavior
    local result, warning = validate_boolean(arg, nil, false)
    if result == nil then
      -- No valid boolean found, toggle current value
      return not current_value
    end
    return result
  end

  local function parse_numeric_arg(arg, default)
    -- Use enhanced validator (no min/max constraints by default)
    local value, warning = validate_number(arg, nil, nil, default, false)
    return value
  end

  -- Register all commands
  function self:register_commands()
    self.commands = {
      on = { fn = self.cmd_on, help = "Enable production mode (start looting)" },
      off = { fn = self.cmd_off, help = "Enable alpha mode (log only)" },
      profit = { fn = self.cmd_profit, help = "Show session profit stats" },
      stats = { fn = self.cmd_profit, help = "Alias for /ll profit" },
      reload = { fn = self.cmd_reload, help = "Reload settings from INI" },
      settings = { fn = self.cmd_settings, help = "Show current settings" },
      help = { fn = self.cmd_help, help = "Show this help" },
      debug = { fn = self.cmd_debug, help = "Show debug information" },
      resetstats = { fn = self.cmd_resetstats, help = "Reset profit statistics" },
      gui = { fn = self.cmd_gui, help = "Toggle GUI window (gui show/hide)" },
      perf = { fn = self.cmd_perf, help = "Show performance statistics" },
      pause = { fn = self.cmd_pause, help = "Pause loot processing" },
      resume = { fn = self.cmd_resume, help = "Resume loot processing" },
      status = { fn = self.cmd_status, help = "Show current status" },

      -- Settings commands (with aliases)
      alwaysloottradeskill = { fn = self.cmd_tradeskill, help = "Toggle auto-looting tradeskill items" },
      tradeskill = { fn = self.cmd_tradeskill, help = "Alias for /ll alwaysloottradeskill" },
      autolootcash = { fn = self.cmd_cash, help = "Toggle auto-looting cash" },
      cash = { fn = self.cmd_cash, help = "Alias for /ll autolootcash" },
      autolootquest = { fn = self.cmd_quest, help = "Toggle auto-looting quest items" },
      quest = { fn = self.cmd_quest, help = "Alias for /ll autolootquest" },
      autolootcollectible = { fn = self.cmd_collectible, help = "Toggle auto-looting collectible items" },
      collectible = { fn = self.cmd_collectible, help = "Alias for /ll autolootcollectible" },
      lootvalue = { fn = self.cmd_lootvalue, help = "Set minimum value to loot (in copper)" },
      questlootvalue = { fn = self.cmd_questvalue, help = "Set minimum value for tradeable quest items" },
      saveslots = { fn = self.cmd_saveslots, help = "Set number of bag slots to keep free" },
      autowindow = { fn = self.cmd_autowindow, help = "Toggle auto-opening advloot window" },
      nodropwait = { fn = self.cmd_nodropwait, help = "Set wait time for no-drop items (seconds)" },

      -- Logging commands
      log = { fn = self.cmd_log, help = "Configure logging (verbosity, console, gui, smart, stats, test)" },

      -- Additional commands
      masterloot = { fn = self.cmd_masterloot, help = "Toggle master looter mode" },
      loottrash = { fn = self.cmd_loottrash, help = "Toggle looting trash items" },
      lootpersonalmode = { fn = self.cmd_lootpersonalmode, help = "Toggle personal loot only mode" },
      lootfromgeneral = { fn = self.cmd_lootfromgeneral, help = "Toggle using general section rules" },
      clearcache = { fn = self.cmd_clearcache, help = "Clear item cache" },
      test = { fn = self.cmd_test, help = "Test functionality" },
      version = { fn = self.cmd_version, help = "Show version information" }
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

  function self:cmd_perf(arg)
    if self.services.loot and self.services.loot.get_performance_stats then
      local stats = self.services.loot:get_performance_stats()
      self.logger:info("=== Performance Statistics ===")
      self.logger:info("Cache Hits: %d", stats.cache_hits)
      self.logger:info("Cache Misses: %d", stats.cache_misses)
      self.logger:info("Cache Hit Rate: %.1f%%", stats.hit_rate)
      self.logger:info("Items Processed: %d", stats.items_processed)
      self.logger:info("Active Session: %s", stats.current_session or "none")
      self.logger:info("Processed Items in Memory: %d", stats.processed_count)
    else
      self.logger:error("Performance stats not available")
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
    local new_value, warning = validate_boolean(arg, current, true)
    
    if warning and arg and arg ~= "" then
      -- Invalid input, toggle instead
      new_value = not current
      self.logger:info("AlwaysLootTradeskills toggled to: %s", new_value and "ENABLED" or "DISABLED")
    elseif not warning and arg and arg ~= "" then
      self.logger:info("AlwaysLootTradeskills: %s", new_value and "ENABLED" or "DISABLED")
    end
    
    self.config.char_settings.AlwaysLootTradeskills = new_value
    self.config:save()
  end

  function self:cmd_cash(arg)
    local current = self.config.char_settings.AutoLootCash
    local new_value, warning = validate_boolean(arg, current, true)
    
    if warning and arg and arg ~= "" then
      new_value = not current
      self.logger:info("AutoLootCash toggled to: %s", new_value and "ENABLED" or "DISABLED")
    elseif not warning and arg and arg ~= "" then
      self.logger:info("AutoLootCash: %s", new_value and "ENABLED" or "DISABLED")
    end
    
    self.config.char_settings.AutoLootCash = new_value
    self.config:save()
  end

  function self:cmd_quest(arg)
    local current = self.config.char_settings.AutoLootQuest
    local new_value, warning = validate_boolean(arg, current, true)
    
    if warning and arg and arg ~= "" then
      new_value = not current
      self.logger:info("AutoLootQuest toggled to: %s", new_value and "ENABLED" or "DISABLED")
    elseif not warning and arg and arg ~= "" then
      self.logger:info("AutoLootQuest: %s", new_value and "ENABLED" or "DISABLED")
    end
    
    self.config.char_settings.AutoLootQuest = new_value
    self.config:save()
  end

  function self:cmd_collectible(arg)
    local current = self.config.char_settings.AutoLootCollectible
    local new_value, warning = validate_boolean(arg, current, true)
    
    if warning and arg and arg ~= "" then
      new_value = not current
      self.logger:info("AutoLootCollectible toggled to: %s", new_value and "ENABLED" or "DISABLED")
    elseif not warning and arg and arg ~= "" then
      self.logger:info("AutoLootCollectible: %s", new_value and "ENABLED" or "DISABLED")
    end
    
    self.config.char_settings.AutoLootCollectible = new_value
    self.config:save()
  end

  function self:cmd_lootvalue(arg)
    local current = self.config.char_settings.LootValue or 1000
    local value, warning = validate_number(arg, 0, 1000000, current, true)
    
    if warning and arg and arg ~= "" then
      self.logger:warn("Invalid LootValue: %s. Keeping current: %d", arg, current)
      return
    end
    
    self.config.char_settings.LootValue = value
    self.config:save()
    self.logger:info("LootValue set to: %d copper", value)
  end

  function self:cmd_questvalue(arg)
    local current = self.config.char_settings.QuestLootValue or 500
    local value, warning = validate_number(arg, 0, 1000000, current, true)
    
    if warning and arg and arg ~= "" then
      self.logger:warn("Invalid QuestLootValue: %s. Keeping current: %d", arg, current)
      return
    end
    
    self.config.char_settings.QuestLootValue = value
    self.config:save()
    self.logger:info("QuestLootValue set to: %d copper", value)
  end

  function self:cmd_saveslots(arg)
    local current = self.config.char_settings.SaveSlots or 3
    local slots, warning = validate_number(arg, 0, 10, current, true)
    
    if warning and arg and arg ~= "" then
      self.logger:warn("Invalid SaveSlots: %s. Must be 0-10. Keeping current: %d", arg, current)
      return
    end
    
    self.config.char_settings.SaveSlots = slots
    self.config:save()
    self.logger:info("SaveSlots set to: %d", slots)
  end

  function self:cmd_autowindow(arg)
    local current = self.config.settings.auto_open_window or true
    local new_value, warning = validate_boolean(arg, current, true)
    
    if warning and arg and arg ~= "" then
      new_value = not current
      self.logger:info("Auto-open window toggled to: %s", new_value and "ENABLED" or "DISABLED")
    elseif not warning and arg and arg ~= "" then
      self.logger:info("Auto-open window: %s", new_value and "ENABLED" or "DISABLED")
    end
    
    self.config.settings.auto_open_window = new_value
    self.config:save()
  end

  function self:cmd_nodropwait(arg)
    local current = self.config.settings.no_drop_wait_time or 300
    local seconds, warning = validate_number(arg, 60, 3600, current, true)
    
    if warning and arg and arg ~= "" then
      self.logger:warn("Invalid wait time: %s. Must be 60-3600 seconds. Keeping current: %d", arg, current)
      return
    end
    
    self.config.settings.no_drop_wait_time = seconds
    self.config:save()
    self.logger:info("No-drop wait time set to: %d seconds", seconds)
  end

  function self:cmd_masterloot(arg)
    local current = self.config.char_settings.MasterLoot or true
    local new_value, warning = validate_boolean(arg, current, true)
    
    if warning and arg and arg ~= "" then
      new_value = not current
      self.logger:info("MasterLoot toggled to: %s", new_value and "ENABLED" or "DISABLED")
    elseif not warning and arg and arg ~= "" then
      self.logger:info("MasterLoot: %s", new_value and "ENABLED" or "DISABLED")
    end
    
    self.config.char_settings.MasterLoot = new_value
    self.config:save()
  end

  function self:cmd_loottrash(arg)
    local current = self.config.char_settings.LootTrash or false
    local new_value, warning = validate_boolean(arg, current, true)
    
    if warning and arg and arg ~= "" then
      new_value = not current
      self.logger:info("LootTrash toggled to: %s", new_value and "ENABLED" or "DISABLED")
    elseif not warning and arg and arg ~= "" then
      self.logger:info("LootTrash: %s", new_value and "ENABLED" or "DISABLED")
    end
    
    self.config.char_settings.LootTrash = new_value
    self.config:save()
  end

  function self:cmd_lootpersonalmode(arg)
    local current = self.config.char_settings.LootPersonalOnly or false
    local new_value, warning = validate_boolean(arg, current, true)
    
    if warning and arg and arg ~= "" then
      new_value = not current
      self.logger:info("LootPersonalOnly toggled to: %s", new_value and "ENABLED" or "DISABLED")
    elseif not warning and arg and arg ~= "" then
      self.logger:info("LootPersonalOnly: %s", new_value and "ENABLED" or "DISABLED")
    end
    
    self.config.char_settings.LootPersonalOnly = new_value
    self.config:save()
  end

  function self:cmd_lootfromgeneral(arg)
    local current = self.config.char_settings.LootFromGeneralSection or true
    local new_value, warning = validate_boolean(arg, current, true)
    
    if warning and arg and arg ~= "" then
      new_value = not current
      self.logger:info("LootFromGeneralSection toggled to: %s", new_value and "ENABLED" or "DISABLED")
    elseif not warning and arg and arg ~= "" then
      self.logger:info("LootFromGeneralSection: %s", new_value and "ENABLED" or "DISABLED")
    end
    
    self.config.char_settings.LootFromGeneralSection = new_value
    self.config:save()
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

  -- === LOGGING COMMANDS ===
  
  function self:cmd_log(arg)
    local parts = {}
    for part in string.gmatch(arg or "", "[^%s]+") do
      table.insert(parts, part)
    end
    
    -- Safe table check
    if type(parts) ~= "table" or #parts == 0 then
      self:show_log_help()
      return
    end
    
    local subcmd = parts[1]:lower()
    
    if subcmd == "verbosity" then
      local current = self.config:get('log_verbosity') or 3
      local level, warning = validate_number(parts[2], 0, 5, current, true)
      
      if warning and parts[2] and parts[2] ~= "" then
        self.logger:warn("Invalid verbosity: %s. Must be 0-5. Keeping current: %d", parts[2], current)
        return
      end
      
      self.logger:set_verbosity(level)
      self.config:set('log_verbosity', level)
      self.config:save()
      self.logger:info("Verbosity set to %d", level)
      
    elseif subcmd == "console" then
      local current = self.logger.config.console_enabled
      local enabled, warning = validate_boolean(parts[2], current, false)
      
      if warning and parts[2] and parts[2] ~= "" then
        -- Toggle on invalid input
        enabled = not current
      elseif not parts[2] or parts[2] == "" then
        -- Toggle on empty input
        enabled = not current
      end
      
      self.logger:set_console_enabled(enabled)
      self.config:set('log_console_enabled', enabled)
      self.config:save()
      self.logger:info("Console logging %s", enabled and "enabled" or "disabled")
      
    elseif subcmd == "gui" then
      local current = self.logger.config.gui_enabled
      local enabled, warning = validate_boolean(parts[2], current, false)
      
      if warning and parts[2] and parts[2] ~= "" then
        enabled = not current
      elseif not parts[2] or parts[2] == "" then
        enabled = not current
      end
      
      self.logger:set_gui_enabled(enabled)
      self.config:set('log_gui_enabled', enabled)
      self.config:save()
      self.logger:info("GUI logging %s", enabled and "enabled" or "disabled")
      
    elseif subcmd == "smart" then
      local current = self.logger.config.smart_routing
      local enabled, warning = validate_boolean(parts[2], current, false)
      
      if warning and parts[2] and parts[2] ~= "" then
        enabled = not current
      elseif not parts[2] or parts[2] == "" then
        enabled = not current
      end
      
      self.logger:set_smart_routing(enabled)
      self.config:set('log_smart_routing', enabled)
      self.config:save()
      self.logger:info("Smart routing %s", enabled and "enabled" or "disabled")
      
    elseif subcmd == "stats" then
      self.logger:log_stats()
      
    elseif subcmd == "test" then
      self.logger:info("=== Testing Log Levels ===")
      self.logger:fatal("FATAL message (level 0)")
      self.logger:error("ERROR message (level 1)")
      self.logger:warn("WARN message (level 2)")
      self.logger:info("INFO message (level 3)")
      self.logger:debug("DEBUG message (level 4)")
      self.logger:trace("TRACE message (level 5)")
      self.logger:info("Log test complete")
      
    else
      self.logger:error("Unknown log command: %s", subcmd)
      self:show_log_help()
    end
  end
  
  function self:show_log_help()
    self.logger:info("=== Logging Commands ===")
    self.logger:info("/ll log verbosity [0-5]  - Set verbosity level")
    self.logger:info("  0=FATAL only, 1=ERROR+, 2=WARN+, 3=INFO+ (default)")
    self.logger:info("  4=DEBUG+, 5=TRACE+ (everything)")
    self.logger:info("/ll log console [on/off] - Toggle console output")
    self.logger:info("/ll log gui [on/off]     - Toggle GUI output")
    self.logger:info("/ll log smart [on/off]   - Toggle smart routing")
    self.logger:info("/ll log stats            - Show logger statistics")
    self.logger:info("/ll log test             - Test all log levels")
  end

  -- Initialize
  self:register_commands()

  return self
end

return CommandHandler