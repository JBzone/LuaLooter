--[[
DESIGN DECISION: Centralized UI styling
WHY: Consistent look and feel
     Easy to change themes
     Separates style from logic
--]]

local mq = require('mq')
local ImGui = require('ImGui')

local Styles = {}

function Styles.apply_default_style()
    -- Get ImGui style
    local style = ImGui.GetStyle()
    
    -- Colors (RGBA)
    local colors = style.Colors
    
    -- Window
    colors[ImGui.Col.WindowBg] = ImGui.ImVec4(0.06, 0.06, 0.06, 0.94)
    colors[ImGui.Col.TitleBg] = ImGui.ImVec4(0.04, 0.04, 0.04, 1.00)
    colors[ImGui.Col.TitleBgActive] = ImGui.ImVec4(0.16, 0.29, 0.48, 1.00)
    colors[ImGui.Col.TitleBgCollapsed] = ImGui.ImVec4(0.00, 0.00, 0.00, 0.51)
    
    -- Buttons
    colors[ImGui.Col.Button] = ImGui.ImVec4(0.16, 0.29, 0.48, 0.40)
    colors[ImGui.Col.ButtonHovered] = ImGui.ImVec4(0.26, 0.59, 0.98, 1.00)
    colors[ImGui.Col.ButtonActive] = ImGui.ImVec4(0.06, 0.53, 0.98, 1.00)
    
    -- Frame BG (Input fields, etc.)
    colors[ImGui.Col.FrameBg] = ImGui.ImVec4(0.16, 0.29, 0.48, 0.54)
    colors[ImGui.Col.FrameBgHovered] = ImGui.ImVec4(0.26, 0.59, 0.98, 0.40)
    colors[ImGui.Col.FrameBgActive] = ImGui.ImVec4(0.26, 0.59, 0.98, 0.67)
    
    -- Tabs
    colors[ImGui.Col.Tab] = ImGui.ImVec4(0.16, 0.29, 0.48, 0.86)
    colors[ImGui.Col.TabHovered] = ImGui.ImVec4(0.26, 0.59, 0.98, 0.80)
    colors[ImGui.Col.TabActive] = ImGui.ImVec4(0.20, 0.41, 0.68, 1.00)
    colors[ImGui.Col.TabUnfocused] = ImGui.ImVec4(0.07, 0.10, 0.15, 0.97)
    colors[ImGui.Col.TabUnfocusedActive] = ImGui.ImVec4(0.14, 0.26, 0.42, 1.00)
    
    -- Headers
    colors[ImGui.Col.Header] = ImGui.ImVec4(0.26, 0.59, 0.98, 0.31)
    colors[ImGui.Col.HeaderHovered] = ImGui.ImVec4(0.26, 0.59, 0.98, 0.80)
    colors[ImGui.Col.HeaderActive] = ImGui.ImVec4(0.26, 0.59, 0.98, 1.00)
    
    -- Text
    colors[ImGui.Col.Text] = ImGui.ImVec4(1.00, 1.00, 1.00, 1.00)
    colors[ImGui.Col.TextDisabled] = ImGui.ImVec4(0.50, 0.50, 0.50, 1.00)
    
    -- Borders
    colors[ImGui.Col.Border] = ImGui.ImVec4(0.43, 0.43, 0.50, 0.50)
    colors[ImGui.Col.BorderShadow] = ImGui.ImVec4(0.00, 0.00, 0.00, 0.00)
    
    -- Log message colors
    colors[ImGui.Col.CustomLogDebug] = ImGui.ImVec4(0.00, 1.00, 0.00, 1.00)   -- Green
    colors[ImGui.Col.CustomLogInfo] = ImGui.ImVec4(1.00, 1.00, 1.00, 1.00)    -- White
    colors[ImGui.Col.CustomLogWarn] = ImGui.ImVec4(1.00, 1.00, 0.00, 1.00)    -- Yellow
    colors[ImGui.Col.CustomLogError] = ImGui.ImVec4(1.00, 0.00, 0.00, 1.00)   -- Red
    
    -- Spacing
    style.WindowPadding = ImGui.ImVec2(8, 8)
    style.FramePadding = ImGui.ImVec2(4, 3)
    style.ItemSpacing = ImGui.ImVec2(8, 4)
    style.ItemInnerSpacing = ImGui.ImVec2(4, 4)
    style.IndentSpacing = 21
    
    -- Sizes
    style.ScrollbarSize = 14
    style.GrabMinSize = 10
    
    -- Borders
    style.WindowBorderSize = 1
    style.ChildBorderSize = 1
    style.PopupBorderSize = 1
    style.FrameBorderSize = 0
    style.TabBorderSize = 0
    
    -- Rounding
    style.WindowRounding = 7
    style.ChildRounding = 4
    style.FrameRounding = 3
    style.PopupRounding = 4
    style.ScrollbarRounding = 9
    style.GrabRounding = 3
    style.TabRounding = 4
end

return Styles