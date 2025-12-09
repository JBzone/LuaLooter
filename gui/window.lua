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
        open = true,
        flags = 0,
        position = {x = 100, y = 100},
        size = {width = 800, height = 600},
        first_render = true
    }
    
    function self:begin_window()
        -- Set window position/size on first render
        if self.first_render then
            ImGui.SetNextWindowPos(self.position.x, self.position.y, ImGuiCond_FirstUseEver)
            ImGui.SetNextWindowSize(self.size.width, self.size.height, ImGuiCond_FirstUseEver)
            self.first_render = false
        end
        
        -- Begin the window
        self.open, self.open = ImGui.Begin(self.title, self.open, self.flags)
        return self.open
    end
    
    function self:end_window()
        ImGui.End()
    end
    
    function self:render()
        -- Override in derived classes
        if self:begin_window() then
            self:render_content()
            self:end_window()
        end
    end
    
    function self:render_content()
        -- Override in derived classes
        ImGui.Text("Override render_content() in derived window class")
    end
    
    function self:set_position(x, y)
        self.position = {x = x, y = y}
        self.first_render = true
    end
    
    function self:set_size(width, height)
        self.size = {width = width, height = height}
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
    
    function self:is_open()
        return self.open
    end
    
    function self:close()
        self.open = false
    end
    
    return self
end

return BaseWindow