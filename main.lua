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
    self.events = require('core.events').new()
    self.state = require('core.state').new()
    self.config = require('core.config').new(self.logger)
    
    function self:init()
        self.logger:info("Initializing LuaLooter v0.5.0 (Alpha)")
    
        -- Load configuration
        self.config:load()
    
        -- Setup file logging if enabled
        if self.config:get('enable_file_logging') then
          local log_path = self.config:get('log_file_path') or (mq.configDir .. "\\LuaLooter.log")
          self.logger:set_log_file(log_path)
        end
    
        -- Log startup info
        self.logger:log_startup()
        
        -- Initialize services (business logic)
        self.services.ini = require('services.iniservice').new(self.config, self.logger)
        self.services.items = require('services.itemservice').new(self.config, self.logger, self.services.ini)
        self.services.profit = require('services.profitservice').new(self.state, self.config, self.logger, self.events)
        self.services.loot = require('services.lootservice').new(self.state, self.config, self.logger, self.events, self.services.items)
        
        -- Initialize modules (features)
        self.modules.filters = require('modules.filters').new(self.state, self.config, self.logger, self.events, self.services.items)
        self.modules.logic = require('modules.lootlogic').new(self.state, self.config, self.logger, self.events, self.services.items, self.modules.filters)
        self.modules.inventory = require('modules.inventory').new(self.state, self.config, self.logger, self.events)
        
        -- Initialize command system
        self.commands = require('commands.commandhandler').new(self.state, self.config, self.logger, self.events, self.services)
        
        -- Bind commands
        mq.bind("/looter", function(cmd, arg) self.commands:handle(cmd, arg) end)
        mq.bind("/ll", function(cmd, arg) self.commands:handle(cmd, arg) end)
        
        -- Register events
        self:register_events()
        
        self.logger:info("LuaLooter initialized successfully")
        self.logger:info("Mode: " .. (self.config.settings.alpha_mode and "ALPHA (log only)" or "PRODUCTION (looting active)"))
    end
    
    function self:register_events()
        -- Cash loot events
        mq.event('CashLootPlatOnlyCorpse', '#*#You receive #1# platinum from the corpse.#*#', 
            function(line, plat) self.services.profit:track_cash(plat or 0, 0, 0, 0) end)
        
        mq.event('CashLootPlatGoldCorpse', '#*#You receive #1# platinum and #2# gold from the corpse.#*#', 
            function(line, plat, gold) self.services.profit:track_cash(plat or 0, gold or 0, 0, 0) end)
        
        mq.event('CashLootPlatGoldSilverCorpse', '#*#You receive #1# platinum, #2# gold and #3# silver from the corpse.#*#', 
            function(line, plat, gold, silver) self.services.profit:track_cash(plat or 0, gold or 0, silver or 0, 0) end)
        
        mq.event('CashLootPlatGoldSilverCopperCorpse', '#*#You receive #1# platinum, #2# gold, #3# silver and #4# copper from the corpse.#*#', 
            function(line, plat, gold, silver, copper) self.services.profit:track_cash(plat or 0, gold or 0, silver or 0, copper or 0) end)
        
        -- Detect loot window close
        mq.event('LootWindowClosed', '#*#Loot #window# has been closed#*#', function()
            self.state:clear_processed_items()
            self.modules.logic:clear_waiting_items()
            self.logger:debug("Loot window closed, cleared processed and waiting items")
        end)
        
        -- Detect zoning (window closes on zone)
        mq.event('BeginZone', '#*#LOADING, PLEASE WAIT...#*#', function()
            self.state:clear_processed_items()
            self.modules.logic:clear_waiting_items()
            self.logger:debug("Zoning, cleared processed and waiting items")
        end)
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
            -- Check log rotation every minute
            if os.time() % 60 == 0 and self.config:get('enable_file_logging') then
              self.logger:rotate_log(self.config:get('max_log_size_mb'))
            end

            self:process()
            mq.doevents()
            mq.delay(100) -- 10 FPS
        end
    end
    
    function self:shutdown()
        self.logger:info("Shutting down LuaLooter")
        self.running = false
    
        -- Shutdown logger (closes file)
        self.logger:shutdown()
    
        -- Unbind commands
        mq.unbind("/looter")
        mq.unbind("/ll")
    
        -- Save settings
        self.config:save()
    
        print("\aw[LuaLooter] Shutdown complete\ax")
    end
    
    return self
end

return Main