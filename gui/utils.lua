--[[
DESIGN DECISION: Common GUI utility functions
WHY: Reusable UI components
     Consistent behavior across panels
     Reduces code duplication
--]]

local mq = require('mq')
local ImGui = require 'ImGui'

local GUIUtils = {}

-- Create a labeled input field with validation
function GUIUtils.input_text(label, value, buffer_size, flags)
    local flags = flags or ImGui.InputTextFlags.None
    local buffer = mq.imguiBuffer(value or "", buffer_size or 256)
    
    ImGui.Text(label)
    ImGui.SameLine()
    local changed = ImGui.InputText("##" .. label, buffer, buffer_size or 256, flags)
    
    if changed then
        return buffer:sub(1, buffer_size or 256)
    end
    
    return nil
end

-- Create a checkbox with label
function GUIUtils.checkbox(label, value)
    ImGui.Text(label)
    ImGui.SameLine()
    local changed, new_value = ImGui.Checkbox("##" .. label, value)
    return changed, new_value
end

-- Create a slider for numeric values
function GUIUtils.slider_int(label, value, min_val, max_val)
    ImGui.Text(label)
    ImGui.SameLine()
    local changed, new_value = ImGui.SliderInt("##" .. label, value, min_val, max_val)
    return changed, new_value
end

-- Create a slider for float values
function GUIUtils.slider_float(label, value, min_val, max_val, format)
    ImGui.Text(label)
    ImGui.SameLine()
    local changed, new_value = ImGui.SliderFloat("##" .. label, value, min_val, max_val, format or "%.2f")
    return changed, new_value
end

-- Create a combo box (dropdown)
function GUIUtils.combo(label, current_item, items)
    ImGui.Text(label)
    ImGui.SameLine()
    
    if ImGui.BeginCombo("##" .. label, items[current_item] or "") then
        for i, item in ipairs(items) do
            local is_selected = (current_item == i)
            if ImGui.Selectable(item, is_selected) then
                current_item = i
            end
            if is_selected then
                ImGui.SetItemDefaultFocus()
            end
        end
        ImGui.EndCombo()
    end
    
    return current_item
end

-- Create a button with confirmation
function GUIUtils.confirm_button(label, confirm_text, color)
    if color then
        ImGui.PushStyleColor(ImGui.Col.Button, color)
    end
    
    local clicked = ImGui.Button(label)
    
    if color then
        ImGui.PopStyleColor()
    end
    
    if clicked then
        ImGui.OpenPopup("ConfirmAction")
    end
    
    -- Always center the confirmation popup
    local center = ImGui.GetMainViewport():GetCenter()
    ImGui.SetNextWindowPos(center.x, center.y, ImGui.Cond.Appearing, ImGui.ImVec2(0.5, 0.5))
    
    if ImGui.BeginPopupModal("ConfirmAction", nil, ImGui.WindowFlags.AlwaysAutoResize) then
        ImGui.Text(confirm_text)
        ImGui.Separator()
        
        if ImGui.Button("OK", ImGui.ImVec2(120, 0)) then
            ImGui.CloseCurrentPopup()
            ImGui.EndPopup()
            return true
        end
        
        ImGui.SetItemDefaultFocus()
        ImGui.SameLine()
        
        if ImGui.Button("Cancel", ImGui.ImVec2(120, 0)) then
            ImGui.CloseCurrentPopup()
        end
        
        ImGui.EndPopup()
    end
    
    return false
end

-- Create a help marker with tooltip
function GUIUtils.help_marker(description)
    ImGui.TextDisabled("(?)")
    if ImGui.IsItemHovered() then
        ImGui.BeginTooltip()
        ImGui.PushTextWrapPos(ImGui.GetFontSize() * 35.0)
        ImGui.TextUnformatted(description)
        ImGui.PopTextWrapPos()
        ImGui.EndTooltip()
    end
end

-- Format money display
function GUIUtils.format_money(copper)
    local plat = math.floor(copper / 1000)
    local gold = math.floor((copper % 1000) / 100)
    local silver = math.floor((copper % 100) / 10)
    local cop = copper % 10
    
    local parts = {}
    if plat > 0 then table.insert(parts, string.format("%dp", plat)) end
    if gold > 0 then table.insert(parts, string.format("%dg", gold)) end
    if silver > 0 then table.insert(parts, string.format("%ds", silver)) end
    if cop > 0 or #parts == 0 then table.insert(parts, string.format("%dc", cop)) end
    
    return table.concat(parts, " ")
end

-- Create a collapsible section
function GUIUtils.collapsing_header(label, default_open)
    local flags = ImGui.TreeNodeFlags.None
    if default_open then
        flags = bit32.bor(flags, ImGui.TreeNodeFlags.DefaultOpen)
    end
    
    if ImGui.CollapsingHeader(label, flags) then
        ImGui.Indent(10)
        return true
    end
    
    return false
end

-- End a collapsible section
function GUIUtils.end_collapsing_header()
    ImGui.Unindent(10)
end

return GUIUtils