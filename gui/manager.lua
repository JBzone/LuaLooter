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
    
    -- === CRITICAL: REGISTER THE WINDOW WITH IMGUI ===
    -- Store a STRONG reference to the main window. Use 'main_window' as a local.
    local main_window = self.windows.main
    
    -- Create and register the render function
    local render_func = function()
        -- Directly use the captured 'main_window' variable, not self.windows.main
        if main_window and main_window.render then
            main_window:render()
        end
    end
    
    ImGui.Register('LuaLooter_MainWindow', render_func)
    print("[DEBUG] MainWindow registered with ImGui.")
    -- ================================================
    
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
        print("[MANAGER] render() SKIPPED. visible:", self.visible, "initialized:", self.initialized)
        return
    end

    print("[MANAGER] render() called. Rendering windows...")
    -- ... rest of your existing code to loop through windows ...
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