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
        windows = {},
        initialized = false
    }
    
  function self:init()
    if self.initialized then return end
    
    self.logger:debug("Initializing GUI Manager")
    
    -- Create main window
    local MainWindow = require('gui.main')
    self.windows.main = MainWindow.new(self.state, self.config, self.logger)
    
    -- Create wrapper
    local main_window = self.windows.main
    
    local render_func = function()
        -- Only render if GUI should be visible
        if self.state:is_gui_visible() then
            if main_window and main_window.render then
                main_window:render()
            end
        end
        -- If not visible, do nothing (function still called by MQ)
    end
    
    ImGui.Register('LuaLooter_MainWindow', render_func)
    self.state.set_initalized(true)
    self.logger:debug("GUI Manager initialized")
end
    
  function self:toggle()
    local new_visibility = not self.state:is_gui_visible()
    self.state:set_gui_visible(new_visibility)
    
    if new_visibility then
        -- If showing, ensure window is initialized and open
        if not self.state.initialized then
            self:init()
        end
        if self.windows.main then
            self.windows.main.open = true  -- Reopen the window
        end
        self.logger:info("GUI shown")
    else
        -- If hiding, close the window
        if self.windows.main then
            self.windows.main.open = false
        end
        self.logger:info("GUI hidden")
    end
    
    return new_visibility
  end
    
    function self:show()
        if not self.initialized then
            self:init()
        end
        self.state:set_gui_visible(true)
        self.logger:debug("GUI shown")
    end
    
    function self:hide()
        self.state:set_gui_visible(false)
        self.logger:debug("GUI hidden")
    end
    
    function self:is_visible()
        return self.state:is_gui_visible()
    end

    function self:shutdown()
        self.logger:debug("Shutting down GUI Manager")
        self.state:set_gui_visible(false)
        self.windows = {}
        self.initialized = false
    end
    
    return self
end

return GUIManager