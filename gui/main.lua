--[[
DESIGN DECISION: Main application window with tabbed interface
WHY: Central hub for all GUI functionality
     Tabbed navigation for different features
     Consistent user experience
--]]

local mq = require('mq')
local ImGui = require 'ImGui'
local BaseWindow = require 'gui.window'

local MainWindow = {}

function MainWindow.new(state, config, logger)
    local self = BaseWindow.new("LuaLooter v0.5.0", state, config, logger)
    
    -- Tab states
    self.active_tab = 1
    self.tabs = {
        {id = 1, name = "Log", icon = "📋"},
        {id = 2, name = "Settings", icon = "⚙️"},
        {id = 3, name = "Loot Rules", icon = "📦"}
    }
    
    -- Load panel modules (will be created in later phases)
    self.panels = {
        log = nil,      -- Will be gui.log_panel
        settings = nil, -- Will be gui.settings_panel  
        rules = nil     -- Will be gui.rules_panel
    }
    
    -- ============================================
    -- FIXED LOG CAPTURE SYSTEM (handles format strings AND tables)
    -- ============================================
    self.log_messages = {}
    self.max_log_lines = 200
    
    -- Helper function to safely convert any message to string
    local function safe_tostring(msg)
        if msg == nil then
            return "nil"
        elseif type(msg) == "table" then
            -- Simple table representation
            if next(msg) == nil then
                return "{}"  -- Empty table
            end
            -- Try to show key-value pairs for small tables
            local str = "{"
            local count = 0
            for k, v in pairs(msg) do
                if count > 0 then str = str .. ", " end
                if type(k) == "string" and not k:find(" ") then
                    str = str .. k .. "=" .. safe_tostring(v)
                else
                    str = str .. safe_tostring(v)
                end
                count = count + 1
                if count > 3 then  -- Limit to avoid huge strings
                    str = str .. ", ..."
                    break
                end
            end
            return str .. "}"
        elseif type(msg) == "boolean" then
            return msg and "true" or "false"
        elseif type(msg) == "number" then
            return tostring(msg)
        else
            return tostring(msg)
        end
    end
    
    -- Helper to capture log messages WITH FORMATTING and table handling
    local function capture_log(original_fn, level, ...)
        -- Call original logger first
        original_fn(...)
        
        local args = {...}
        local format_str = args[1]
        local msg_str
        
        if type(format_str) == "string" and #args > 1 and format_str:find("%%") then
            -- We have a format string with arguments
            local format_args = {}
            for i = 2, #args do
                -- Convert args to strings for string.format
                if type(args[i]) == "table" then
                    table.insert(format_args, safe_tostring(args[i]))
                else
                    table.insert(format_args, args[i])
                end
            end
            
            local success, result = pcall(string.format, format_str, unpack(format_args))
            if success then
                msg_str = result
            else
                -- Fallback: convert all args to strings and join
                local str_parts = {}
                for i, arg in ipairs(args) do
                    table.insert(str_parts, safe_tostring(arg))
                end
                msg_str = table.concat(str_parts, " ")
            end
        else
            -- No format string, convert all args to strings and join
            local str_parts = {}
            for i, arg in ipairs(args) do
                table.insert(str_parts, safe_tostring(arg))
            end
            msg_str = table.concat(str_parts, " ")
        end
        
        table.insert(self.log_messages, os.date("%H:%M:%S") .. " [" .. level .. "] " .. msg_str)
        
        -- Trim if too long
        if #self.log_messages > self.max_log_lines then
            table.remove(self.log_messages, 1)
        end
    end
    
    -- Capture logger output PROPERLY
    local original_info = logger.info
    logger.info = function(...)
        capture_log(original_info, "INFO", ...)
    end
    
    local original_debug = logger.debug
    logger.debug = function(...)
        capture_log(original_debug, "DEBUG", ...)
    end
    
    local original_error = logger.error
    logger.error = function(...)
        capture_log(original_error, "ERROR", ...)
    end
    
    -- Optional: Capture warnings if your logger has them
    local original_warn = logger.warn
    if original_warn then
        logger.warn = function(...)
            capture_log(original_warn, "WARN", ...)
        end
    end
    -- ============================================
    
    -- Window settings
    self:set_size(900, 700)
    self:add_flag(ImGuiWindowFlags_MenuBar)
    
    function self:render_content()
        -- === 1. MENU BAR ===
        if ImGui.BeginMenuBar() then
            -- File Menu
            if ImGui.BeginMenu("File") then
                if ImGui.MenuItem("Save Configuration") then
                  self.config:save()
                  logger.info("Configuration saved")
                end
                if ImGui.MenuItem("Reload Configuration") then
                  self.config:load()
                  logger.info("Configuration reloaded")
                end
                ImGui.Separator()
                if ImGui.MenuItem("Exit") then
                  self.state:set_gui_visible(false)
                  self:close()
                end
                ImGui.EndMenu()
            end
            
            -- View Menu
            if ImGui.BeginMenu("View") then
                if ImGui.MenuItem("Reset Window Position") then
                    self:set_position(100, 100)
                    logger.debug("Window position reset")
                end
                if ImGui.MenuItem("Toggle Console Output", nil, self.config:get('show_messages_in_console')) then
                    local current = self.config:get('show_messages_in_console')
                    self.config:set('show_messages_in_console', not current)
                    logger.info("Console output " .. (not current and "enabled" or "disabled"))
                end
                ImGui.EndMenu()
            end
            
            -- Help Menu
            if ImGui.BeginMenu("Help") then
                if ImGui.MenuItem("About") then
                    logger.info("LuaLooter v0.5.0 - Advanced Looting System")
                end
                ImGui.EndMenu()
            end
            
            -- Status indicator (Right-aligned)
            ImGui.SameLine(ImGui.GetWindowWidth() - 150)
            local status_text = self.state:is_enabled() and "ACTIVE" or "PAUSED"
            local r, g, b
            if self.state:is_enabled() then
                r, g, b = 0.0, 1.0, 0.0  -- Green
            else
                r, g, b = 1.0, 0.0, 0.0  -- Red
            end
            ImGui.TextColored(r, g, b, 1.0, status_text)
            
            ImGui.EndMenuBar()
        end
        
        -- === 2. TAB BAR ===
        if ImGui.BeginTabBar("MainTabs") then
            for _, tab in ipairs(self.tabs) do
                local tab_flags = 0
                if self.active_tab == tab.id and ImGuiTabItemFlags_SetSelected then
                    tab_flags = ImGuiTabItemFlags_SetSelected
                end
                
                if ImGui.BeginTabItem(tab.icon .. " " .. tab.name, nil, tab_flags) then
                    self.active_tab = tab.id
                    self:render_panel(tab.id)
                    ImGui.EndTabItem()
                end
            end
            ImGui.EndTabBar()
        end
    end
    
    function self:render_panel(tab_id)
        ImGui.BeginChild("PanelContent", 0, 0, true)
        
        if tab_id == 1 then
            -- Log Panel with captured messages
            ImGui.Text("Event Log (Last " .. self.max_log_lines .. " lines):")
            ImGui.Separator()
            ImGui.BeginChild("LogList", 0, 0, false, ImGuiWindowFlags_HorizontalScrollbar)
            for _, msg in ipairs(self.log_messages) do
                ImGui.TextWrapped(msg)
            end
            -- Auto-scroll to bottom
            if ImGui.GetScrollY() >= ImGui.GetScrollMaxY() then
                ImGui.SetScrollHereY(1.0)
            end
            ImGui.EndChild()
        elseif tab_id == 2 then
            ImGui.Text("Settings Panel - Coming in Phase 3")
            ImGui.Text("Character and system settings")
        elseif tab_id == 3 then
            ImGui.Text("Loot Rules Panel - Coming in Phase 4")
            ImGui.Text("Manage item loot rules")
        end
        
        ImGui.EndChild()
    end
    
    function self:load_panels()
        if not self.panels.log then
            local success, panel = pcall(require, 'gui.log_panel')
            if success then
                self.panels.log = panel.new(self.state, self.config, self.logger)
            end
        end
    end
    
    return self
end

return MainWindow