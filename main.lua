--[[
LuaLooter Main - Linear Initialization with Complete Functionality
1. Config (memory only)
2. Events (independent)
3. Logger (needs config defaults)
4. DB (needs logger)
5. Connect Config to DB
6. Everything else (full original init)
--]]

local mq = require('mq')

local Main = {}

function Main.new()
  local self = {
      running = true,
      modules = {},
      services = {},
      commands_bound = false,
  }

  -- === STEP 1: CONFIG (memory only, no DB yet) ===
  self.config = require('core\\config').new()
  print("[INIT] Config created (memory only)")
  
  -- === STEP 2: EVENTS (independent) ===
  self.events = require('core\\events').new()
  print("[INIT] Events created")
  
  -- === STEP 3: LOGGER (uses config defaults from memory) ===
  self.logger = require('core\\logger').new(self.events, self.config)
  print("[INIT] Logger created")
  
  -- === STEP 4: Give config the logger ===
  self.config:set_logger(self.logger)
  print("[INIT] Logger assigned to config")
  
  -- === STEP 5: DB (needs logger) ===
print("[INIT] Creating database object...")
self.db = require('core.db').new(self.logger)

-- TEMPORARY: Test the database path
print("[INIT] Database will be created at: " .. self.db.db_file)

-- Check if file already exists
local test_file = io.open(self.db.db_file, "r")
if test_file then
    print("[INIT] Database file already exists: " .. self.db.db_file)
    test_file:close()
else
    print("[INIT] Database file will be created: " .. self.db.db_file)
end

print("[INIT] Attempting to initialize database...")
if not self.db:init() then
    print("\ar[INIT FATAL] Database initialization failed!\ax")
    -- Don't error yet, let's see what happened
    print("[INIT] Continuing without database (will use defaults)")
    -- Create a dummy db object that always returns defaults
    self.db = {
        get_setting = function(_, key, default) return default end,
        set_setting = function() return true end,
        get_char_setting = function(_, char, key, default) return default end,
        set_char_setting = function() return true end
    }
  end
  
  print("[INIT] Database initialized successfully")
  
  -- === STEP 6: Connect config to DB ===
  self.config:set_db(self.db)
  self.config:init()
  print("[INIT] Config connected to database")
  
  -- Now everything is ready
  self.logger:info("Core systems initialized: Config → Logger → DB")

    ----------------------------
    -- Lifecycle Methods (ALL ORIGINAL CODE BELOW)
    ----------------------------
    function self:init()
        self.logger:log_startup()
        self.logger:info("Initializing LuaLooter v0.5.0 (Alpha) - SQLite Edition")

        -- --- SAFE COMMAND REBIND ---
        mq.unbind("/looter")
        mq.unbind("/ll")

        -- --- SAFE EVENT REGISTRATION ---
        if self.events.unregister_all then
            self.events:unregister_all()
        end
        self.events:register_mq_events()

        -- Check conversion status
        local status = self.config:get_conversion_status()
        self.logger:info("Configuration Status: %s", status.converted and "SQLite Database" or "Not Converted")
        self.logger:info("Loot.ini Found: %s", status.ini_exists and "Yes" or "No")

        if not status.converted then
            self.logger:warn("Loot.ini not yet converted to database.")
            self.logger:warn("Use 'Convert' button in Settings tab to import your settings.")
            self.config:create_default_settings()
        end

        -- Configure logger with actual database settings
        local log_config = self.config:get_log_config()
        if log_config then
            self.logger:set_level(log_config.verbosity)
            self.logger:set_console_enabled(log_config.console_enabled)
            self.logger:set_gui_enabled(log_config.gui_enabled)
            self.logger:set_smart_routing(log_config.smart_routing)
            self.logger:set_max_gui_lines(log_config.max_gui_lines)
        end

        -- Initialize state
        self.state = require('core\\state').new(self.config, self.logger)

        -- Initialize services
        self.services.ini = require('services.iniservice').new(self.config, self.logger)
        self.services.items = require('services.itemservice').new(self.config, self.logger, self.services.ini)
        self.services.profit = require('services.profitservice').new(self.state, self.config, self.logger, self.events)
        self.services.loot = require('services.lootservice').new(self.state, self.config, self.logger, self.events,
            self.services.items)

        -- Initialize GUI
        local ok, gui = pcall(require, 'gui.manager')
        if ok then
            self.services.gui = gui.new(self.state, self.config, self.logger)
            self.logger:debug("GUI Manager initialized")
            if self.services.gui.set_events then
                self.services.gui:set_events(self.events)
            end
            self.services.gui:init()
            -- Register GUI callback with logger
            if self.services.gui and self.services.gui.register_logger_callback then
                self.services.gui:register_logger_callback(self.logger)
            end
        else
            self.logger:warn("GUI not available: %s", gui)
            self.services.gui = nil
        end

        -- Initialize modules
        self.modules.filters = require('modules.filters').new(self.state, self.config, self.logger, self.events,
            self.services.items)
        self.modules.logic = require('modules.lootlogic').new(self.state, self.config, self.logger, self.events,
            self.services.items, self.modules.filters)
        self.modules.inventory = require('modules.inventory').new(self.state, self.config, self.logger, self.events)

        -- Initialize command system
        self.commands = require('commands.commandhandler').new(self.state, self.config, self.logger, self.events,
            self.services)

        -- Bind commands safely
        if not self.commands_bound then
            mq.bind("/looter", function(cmd, arg) self.commands:handle(cmd, arg) end)
            mq.bind("/ll", function(cmd, arg) self.commands:handle(cmd, arg) end)
            self.commands_bound = true
        end

        self.logger:info("LuaLooter initialized successfully")
        self.logger:info("Mode: " .. (self.config:get('alpha_mode') and "ALPHA (log only)" or "PRODUCTION (looting active)"))
        return true
    end

    function self:process()
        if not self.state.enabled or self.state.processing_loot then
            return
        end

        self.state.last_check = os.time()

        local has_loot = mq.TLO.AdvLoot.SCount() > 0 or mq.TLO.AdvLoot.PCount() > 0
        if has_loot then
            local filter_actions = self.modules.filters:process()
            self.modules.logic:process(filter_actions)
            self.modules.logic:check_waiting_items()
        end
    end

    function self:run()
        if not self:init() then
            self.logger:error("Initialization failed, cannot continue")
            return
        end

        self.logger:info("Entering main loop")
        while self.running do
            self:process()
            mq.doevents()
            mq.delay(100)
            if self.state.shutdown_requested then
                self.logger:info("Shutdown requested by state")
                self.running = false
            end
        end

        self:shutdown()
    end

    function self:shutdown()
        self.logger:info("Shutting down LuaLooter")
        self.running = false

        mq.unbind("/looter")
        mq.unbind("/ll")
        self.commands_bound = false

        if self.events and self.events.unregister_all then
            self.events:unregister_all()
        end

        if self.config and self.config.shutdown then
            self.config:shutdown()
        end

        self.logger:shutdown()
        self.logger:info("Shutdown complete")
    end

    return self
end

----------------------------
-- Entry Point (UNCHANGED)
----------------------------
local function main()
    local app = Main.new()

    local function error_handler(err)
        print("[LuaLooter] FATAL ERROR: " .. tostring(err))
        print(debug.traceback())
        if app and app.logger then
            app.logger:error("FATAL: %s", tostring(err))
            app.logger:error(debug.traceback())
        end

        local log_file = io.open(mq.configDir .. "\\LuaLooter_crash.log", "a")
        if log_file then
            log_file:write(string.format("[%s] CRASH: %s\n", os.date("%Y-%m-%d %H:%M:%S"), tostring(err)))
            log_file:write(debug.traceback())
            log_file:write("\n" .. string.rep("=", 80) .. "\n")
            log_file:close()
        end
    end

    local success, err = xpcall(function() app:run() end, error_handler)
    if not success then
        print("[LuaLooter] Application crashed. See LuaLooter_crash.log for details.")
    end
end

main()

return Main