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
    
    -- Window settings
    self:set_size(900, 700)
    self:add_flag(ImGuiWindowFlags_MenuBar)
    
    function self:render_content()
        -- Menu bar
        if ImGui.BeginMenuBar() then
            if ImGui.BeginMenu("File") then
                if ImGui.MenuItem("Save Configuration") then
                    self.config:save()
                    self.logger:info("Configuration saved")
                end
                if ImGui.MenuItem("Reload Configuration") then
                    self.config:load()
                    self.logger:info("Configuration reloaded")
                end
                ImGui.Separator()
                if ImGui.MenuItem("Exit") then
                    self:close()
                end
                ImGui.EndMenu()
            end
            
            if ImGui.BeginMenu("View") then
                if ImGui.MenuItem("Reset Window Position") then
                    self:set_position(100, 100)
                    self.logger:debug("Window position reset")
                end
                if ImGui.MenuItem("Toggle Console Output", nil, self.config:get('show_messages_in_console')) then
                    local current = self.config:get('show_messages_in_console')
                    self.config:set('show_messages_in_console', not current)
                    self.logger:info("Console output " .. (not current and "enabled" or "disabled"))
                end
                ImGui.EndMenu()
            end
            
            if ImGui.BeginMenu("Help") then
                if ImGui.MenuItem("About") then
                    self.logger:info("LuaLooter v0.5.0 - Advanced Looting System")
                end
                ImGui.EndMenu()
            end
            
            -- Status indicator
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
        
        -- Tab bar with SAFE selected tab highlighting
        if ImGui.BeginTabBar("MainTabs") then
            for _, tab in ipairs(self.tabs) do
                -- SAFE Tweak: Check if the global flag exists, otherwise use 0.
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
        -- This will be implemented as we create each panel
        ImGui.BeginChild("PanelContent", 0, 0, true)
        
        if tab_id == 1 then
            ImGui.Text("Log Panel - Coming in Phase 2")
            ImGui.Text("Real-time messages will appear here")
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
        -- Load panel modules when they're created
        -- This will be called during initialization
        if not self.panels.log then
            local success, panel = pcall(require, 'gui.log_panel')
            if success then
                self.panels.log = panel.new(self.state, self.config, self.logger)
            end
        end
        
        -- Similar for other panels...
    end
    
    return self
end

return MainWindow