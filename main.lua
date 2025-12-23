--[[
LuaLooter Main - Reload-Safe Version
DESIGN DECISION: Service Locator Pattern with Dependency Injection
WHY: Centralizes object creation, ensures clean lifecycle, prevents duplicate commands/events
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

    -- Initialize logger first
    self.logger = require('core\\logger').new(nil, {
        verbosity = 3,
        console_enabled = true,
        gui_enabled = true,
        smart_routing = true,
        max_gui_lines = 500
    })

    -- Initialize events and config with logger injected
    self.events = require('core\\events').new(self.logger)
    self.config = require('core\\config').new(self.logger)

    ----------------------------
    -- Lifecycle Methods
    ----------------------------
    function self:init()
        self.logger:log_startup()
        self.logger:info("Initializing LuaLooter v0.5.0 (Alpha) - SQLite Edition")

        -- --- SAFE COMMAND REBIND ---
        -- Unbind stale commands in case of crash/reload
        mq.unbind("/looter")
        mq.unbind("/ll")

        -- --- SAFE EVENT REGISTRATION ---
        if self.events.unregister_all then
            self.events:unregister_all()
        end
        self.events:register_mq_events()

        -- Initialize SQLite configuration system
        if not self.config:init() then
            self.logger:error("Failed to initialize SQLite configuration system!")
            return false
        end

        -- Check conversion status
        local status = self.config:get_conversion_status()
        self.logger:info("Configuration Status: %s", status.converted and "SQLite Database" or "Not Converted")
        self.logger:info("Loot.ini Found: %s", status.ini_exists and "Yes" or "No")

        if not status.converted then
            self.logger:warn("Loot.ini not yet converted to database.")
            self.logger:warn("Use 'Convert' button in Settings tab to import your settings.")
            self.config:create_default_settings()
        end

        -- Update logger config from loaded configuration
        local log_config = self.config:get_log_config()
        if log_config then
            self.logger:set_verbosity(log_config.verbosity)
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
            if self.services.gui.windows and self.services.gui.windows.main then
                if self.services.gui.windows.main.register_smart_logger then
                    self.services.gui.windows.main:register_smart_logger(self.logger)
                end
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
            mq.delay(100) -- 10 FPS, safe because we're inside run()
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

        -- Unbind commands
        mq.unbind("/looter")
        mq.unbind("/ll")
        self.commands_bound = false

        -- Unregister all events safely
        if self.events and self.events.unregister_all then
            self.events:unregister_all()
        end

        -- Shutdown config
        self.config:shutdown()

        -- Shutdown logger
        self.logger:shutdown()

        self.logger:info("Shutdown complete")
    end

    return self
end

----------------------------
-- Entry Point
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

        -- Write crash log
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

-- Start the app
main()

return Main
