--[[
DESIGN DECISION: Service Locator Pattern with Dependency Injection
WHY: Centralizes object creation and dependency management
     Makes testing easier (can inject mock dependencies)
     Clear lifecycle management (init → run → cleanup)

UPDATED: Integrated enhanced logger with smart logging features
PRESERVES: All existing functionality
--]]

local mq = require('mq')

local Main = {}

function Main.new()
  local self = {
    running = true,
    modules = {},
    services = {}
  }

  -- Core systems (always loaded)
  self.events = require('core.events').new(nil) -- Logger will be injected later
  self.state = require('core.state').new()
  self.config = require('core.config').new(nil) -- Logger will be injected later

  -- Initialize logger with events and config
  local log_config = self.config:get_log_config() or {
    verbosity = 3,
    console_enabled = true,
    gui_enabled = true,
    smart_routing = true,
    max_gui_lines = 500
  }

  self.logger = require('core.logger').new(self.events, log_config)

  -- Now inject logger into events and config
  self.events.logger = self.logger
  self.config.logger = self.logger

  function self:init()
    self.logger:log_startup()
    self.logger:info("Initializing LuaLooter v0.5.0 (Alpha)")

    -- Load configuration
    self.config:load()

    -- Update logger config from loaded configuration
    local loaded_log_config = self.config:get_log_config()
    if loaded_log_config then
      self.logger:set_verbosity(loaded_log_config.verbosity)
      self.logger:set_console_enabled(loaded_log_config.console_enabled)
      self.logger:set_gui_enabled(loaded_log_config.gui_enabled)
      self.logger:set_smart_routing(loaded_log_config.smart_routing)
      self.logger:set_max_gui_lines(loaded_log_config.max_gui_lines)
    end

    -- Initialize services (business logic)
    self.services.ini = require('services.iniservice').new(self.config, self.logger)
    self.services.items = require('services.itemservice').new(self.config, self.logger, self.services.ini)
    self.services.profit = require('services.profitservice').new(self.state, self.config, self.logger, self.events)
    self.services.loot = require('services.lootservice').new(self.state, self.config, self.logger, self.events,
      self.services.items)

    -- Initialize GUI Manager (FIXED: Only 3 arguments)
    local success, gui = pcall(require, 'gui.manager')
    if success then
      self.services.gui = gui.new(self.state, self.config, self.logger)
      self.logger:debug("GUI Manager initialized")

      -- Pass events to GUI manager if it supports it
      if self.services.gui.set_events then
        self.services.gui:set_events(self.events)
      end

      -- Register smart logger with GUI main window
      if self.services.gui.windows and self.services.gui.windows.main then
        if self.services.gui.windows.main.register_smart_logger then
          self.services.gui.windows.main:register_smart_logger(self.logger)
        end
      end
    else
      self.logger:warn("GUI not available: %s", gui)
      self.services.gui = nil
    end

    -- Initialize modules (features)
    self.modules.filters = require('modules.filters').new(self.state, self.config, self.logger, self.events,
      self.services.items)
    self.modules.logic = require('modules.lootlogic').new(self.state, self.config, self.logger, self.events,
      self.services.items, self.modules.filters)
    self.modules.inventory = require('modules.inventory').new(self.state, self.config, self.logger, self.events)

    -- Initialize command system
    self.commands = require('commands.commandhandler').new(self.state, self.config, self.logger, self.events,
      self.services)

    -- Bind commands
    mq.bind("/looter", function(cmd, arg) self.commands:handle(cmd, arg) end)
    mq.bind("/ll", function(cmd, arg) self.commands:handle(cmd, arg) end)

    self.logger:info("LuaLooter initialized successfully")
    self.logger:info("Mode: " ..
      (self.config.settings.alpha_mode and "ALPHA (log only)" or "PRODUCTION (looting active)"))

    -- Log current verbosity level
    local level_names = {
      [0] = "FATAL only",
      [1] = "ERROR+",
      [2] = "WARN+",
      [3] = "INFO+",
      [4] = "DEBUG+",
      [5] = "TRACE+"
    }
    local verbosity = self.config:get('log_verbosity') or 3
    self.logger:info("Log verbosity: %d (%s)", verbosity,
      level_names[verbosity] or "Unknown")

    if self.services.gui then
      self.logger:info("GUI: Available (use /ll gui)")
    end

    -- Test different log levels
    self.logger:debug("Debug message test (verbosity >= 4)")
    self.logger:trace("Trace message test (verbosity >= 5)")
  end

  function self:process()
    if not self.state.enabled or self.state.processing_loot then
      return
    end

    -- Update state
    self.state.last_check = os.time()

    -- Check for loot
    local has_loot = mq.TLO.AdvLoot.SCount() > 0 or mq.TLO.AdvLoot.PCount() > 0

    if has_loot then
      -- Process through filter system first
      local filter_actions = self.modules.filters:process()

      -- Apply loot logic with filter overrides
      self.modules.logic:process(filter_actions)

      -- Check no-drop timers
      self.modules.logic:check_waiting_items()
    end
  end

  function self:run()
    self:init()

    self.logger:info("Entering main loop")
    while self.running do
      self:process()
      mq.doevents()
      mq.delay(100) -- 10 FPS
    end
  end

  function self:shutdown()
    self.logger:info("Shutting down LuaLooter")
    self.running = false

    -- Unbind commands
    mq.unbind("/looter")
    mq.unbind("/ll")

    -- Save settings
    self.config:save()

    -- Shutdown logger
    self.logger:shutdown()

    self.logger:info("Shutdown complete")
  end

  return self
end

return Main
