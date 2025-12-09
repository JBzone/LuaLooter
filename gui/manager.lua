--[[
DESIGN DECISION: Centralized GUI management
WHY: Single point for GUI state and lifecycle
     Handles ImGui initialization and cleanup
     Manages window creation/destruction
--]]

local mq = require('mq')

local GUIManager = {}

function GUIManager.new(state, config, logger)
    local self = {
        state = state,
        config = config,
        logger = logger,
        visible = false,
        windows = {},
        initialized = false
    }
    
    function self:init()
        if self.initialized then return end
        
        self.logger:debug("Initializing GUI Manager")
        
        -- Create main GUI window
        local MainWindow = require('gui.main')
        self.windows.main = MainWindow.new(self.state, self.config, self.logger)
        
        self.initialized = true
        self.logger:debug("GUI Manager initialized")
    end
    
    function self:toggle()
        self.visible = not self.visible
        if self.visible and not self.initialized then
            self:init()
        end
        
        local action = self.visible and "shown" or "hidden"
        self.logger:info("GUI %s", action)
        return self.visible
    end
    
    function self:show()
        if not self.initialized then
            self:init()
        end
        self.visible = true
        self.logger:debug("GUI shown")
    end
    
    function self:hide()
        self.visible = false
        self.logger:debug("GUI hidden")
    end
    
    function self:is_visible()
        return self.visible
    end
    
    function self:render()
        if not self.visible or not self.initialized then
            return
        end
        
        -- Render all windows
        for _, window in pairs(self.windows) do
            if window.render then
                window:render()
            end
        end
    end
    
    function self:shutdown()
        self.logger:debug("Shutting down GUI Manager")
        self.visible = false
        self.windows = {}
        self.initialized = false
    end
    
    return self
end

return GUIManager