--[[
DESIGN DECISION: Service Locator Pattern with Dependency Injection
WHY: Centralizes object creation and dependency management
     Makes testing easier (can inject mock dependencies)
     Clear lifecycle management (init → run → cleanup)
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
    self.logger = require('core.logger').new()
    self.events = require('core.events').new(self.logger)
    self.state = require('core.state').new()
    self.config = require('core.config').new(self.logger)
    
    function self:init()
        self.logger:info("Initializing LuaLooter v0.5.0 (Alpha)")
        
        -- Load configuration
        self.config:load()
        
        -- Initialize services (business logic)
        self.services.ini = require('services.iniservice').new(self.config, self.logger)
        self.services.items = require('services.itemservice').new(self.config, self.logger, self.services.ini)
        self.services.profit = require('services.profitservice').new(self.state, self.config, self.logger, self.events)
        self.services.loot = require('services.lootservice').new(self.state, self.config, self.logger, self.events, self.services.items)
        
        -- Initialize GUI Manager (NEW) - add to services
        local success, gui = pcall(require, 'gui.manager')
        if success then
            self.services.gui = gui.new(self.state, self.config, self.logger)
            self.logger:debug("GUI Manager initialized")
        else
            self.logger:warn("GUI not available: %s", gui)
            self.services.gui = nil
        end
        
        -- Initialize modules (features)
        self.modules.filters = require('modules.filters').new(self.state, self.config, self.logger, self.events, self.services.items)
        self.modules.logic = require('modules.lootlogic').new(self.state, self.config, self.logger, self.events, self.services.items, self.modules.filters)
        self.modules.inventory = require('modules.inventory').new(self.state, self.config, self.logger, self.events)
        
        -- Initialize command system
        self.commands = require('commands.commandhandler').new(self.state, self.config, self.logger, self.events, self.services)
        
        -- Bind commands
        mq.bind("/looter", function(cmd, arg) self.commands:handle(cmd, arg) end)
        mq.bind("/ll", function(cmd, arg) self.commands:handle(cmd, arg) end)
                
        self.logger:info("LuaLooter initialized successfully")
        self.logger:info("Mode: " .. (self.config.settings.alpha_mode and "ALPHA (log only)" or "PRODUCTION (looting active)"))
        if self.services.gui then
            self.logger:info("GUI: Available (use /ll gui)")
        end
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
        
        self.logger:info("Shutdown complete")
    end
    
    return self
end

return Main