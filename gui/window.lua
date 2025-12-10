--[[
DESIGN DECISION: Base window class for ImGui windows
WHY: Consistent window behavior and styling
     Handles ImGui window lifecycle
     Provides common functionality (position, size, etc.)
--]]

local mq = require('mq')
local ImGui = require 'ImGui'

local BaseWindow = {}

function BaseWindow.new(title, state, config, logger)
    local self = {
        title = title,
        state = state,
        config = config,
        logger = logger,
        flags = 0,
        first_render = true
    }
    
  function self:render()
    -- Set window position/size on first render
    if self.first_render then
        local pos = self.state.settings.window.position
        local size = self.state.settings.window.size
        ImGui.SetNextWindowPos(pos.x, pos.y, ImGuiCond_FirstUseEver)
        ImGui.SetNextWindowSize(size.width, size.height, ImGuiCond_FirstUseEver)
        self.first_render = false
    end
    
    -- BEST PRACTICE: Cache, single method call, clear intent
    local should_show = self.state:is_gui_visible()
    local window_open = ImGui.Begin(self.title, should_show, self.flags)
    
    -- Update state if window closed by user
    if not window_open and should_show then
        self.state:set_gui_visible(false)
    end
    
    -- Render content if window is actually open
    if window_open then
        self:render_content()
    end
    
    ImGui.End()
    return window_open
  end
    
    function self:render_content()
        -- Override in derived classes
        ImGui.Text("Override render_content() in derived window class")
    end
    
    function self:set_position(x, y)
        self.state.position = {x = x, y = y}
        self.first_render = true
    end
    
    function self:set_size(width, height)
        self.state.size = {width = width, height = height}
        self.first_render = true
    end
    
    function self:set_flags(flags)
        self.flags = flags
    end
    
    function self:add_flag(flag)
        self.flags = bit32.bor(self.flags, flag)
    end
    
    function self:remove_flag(flag)
        self.flags = bit32.band(self.flags, bit32.bnot(flag))
    end
    
    function self:is_visible()
        return self.state:is_gui_visible()
    end
    
    function self:close()
        self.state:set_gui_visible(false)
    end
    
    return self
end

return BaseWindow