--[[
DESIGN DECISION: Main application window with tabbed interface
WHY: Central hub for all GUI functionality
    Tabbed navigation for different features
    Consistent user experience

UPDATED: Added enhanced log panel with smart logging integration
PRESERVES: All existing functionality
--]]

local mq = require('mq')
local ImGui = require 'ImGui'
local BaseWindow = require 'gui.window'

local MainWindow = {}

function MainWindow.new(state, config, logger, events)
  local self = BaseWindow.new("LuaLooter v0.5.0", state, config, logger)

  -- Store events if provided
  self.log_events = events

  -- Tab states (expanded with Log Settings tab)
  self.active_tab = 1
  self.tabs = {
    { id = 1, name = "Log", icon = "📋" },
    { id = 2, name = "Settings", icon = "⚙️" },
    { id = 3, name = "Loot Rules", icon = "📦" },
    { id = 4, name = "Log Settings", icon = "📊" } -- NEW tab
  }

  -- Load panel modules (will be created in later phases)
  self.panels = {
    log = nil,             -- Will be gui.log_panel
    settings = nil,        -- Will be gui.settings_panel
    rules = nil,           -- Will be gui.rules_panel
    log_settings = nil     -- NEW
  }

  -- ============================================
  -- ENHANCED LOG CAPTURE SYSTEM with SmartLogger
  -- ============================================
  self.log_messages = {}
  self.max_log_lines = config:get('max_log_lines') or 500
  self.smart_logger = nil   -- Will be set by main initialization

  -- Log panel state for smart logging
  self.log_panel_state = {
    auto_scroll = config:get('log_auto_scroll') ~= false,
    show_timestamps = config:get('log_show_timestamps') ~= false,
    show_levels = config:get('log_show_levels') ~= false,
    scroll_to_bottom = false
  }

  -- Helper function to safely convert any message to string
  local function safe_tostring(msg)
    if msg == nil then
      return "nil"
    elseif type(msg) == "table" then
      if next(msg) == nil then
        return "{}"
      end
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
        if count > 3 then
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
  local function capture_log(level, ...)
    local verbosity = self.config:get('log_verbosity')
    if verbosity == nil then
      print("ERROR: self.config:get('log_verbosity') returned nil")
      verbosity = 3  -- Default to INFO
    end

    -- Now use verbosity for comparison
    local level_num = self.logger:get_verbosity_num(level) or 3
    
    if level_num > verbosity then  -- Use the retrieved verbosity
      return
    end
  
    local args = { ... }
    local format_str = args[1]
    local msg_str
  
    if type(format_str) == "string" and #args > 1 and format_str:find("%%") then
      local format_args = {}
      for i = 2, #args do
        table.insert(format_args, safe_tostring(args[i]))
      end
  
      local success, result = pcall(string.format, format_str, unpack(format_args))
      if success then
        msg_str = result
      else
        local str_parts = {}
        for i, arg in ipairs(args) do
          table.insert(str_parts, safe_tostring(arg))
        end
        msg_str = table.concat(str_parts, " ")
      end
    else
      local str_parts = {}
      for i, arg in ipairs(args) do
        table.insert(str_parts, safe_tostring(arg))
      end
      msg_str = table.concat(str_parts, " ")
    end
  
    local log_entry = {
      time = os.date("%H:%M:%S"),
      level = level,  -- Use the parameter passed in
      text = msg_str
    }
  
    table.insert(self.log_messages, log_entry)
    
    -- Request scroll to bottom if auto-scroll is enabled
    if self.log_panel_state.auto_scroll then
      self.log_panel_state.scroll_to_bottom = true
    end
  
    -- Trim if too long
    if #self.log_messages > self.max_log_lines then
      table.remove(self.log_messages, 1)
    end
  end

  -- Capture logger output PROPERLY (for backward compatibility)
  local original_info = logger.info
  logger.info = function(self, ...)
    original_info(self, ...)  -- Pass self to original logger
    capture_log("INFO", ...)  -- Don't pass self to capture function
  end

  local original_debug = logger.debug
  logger.debug = function(self, ...)  -- ADD 'self' parameter here!
    original_debug(self, ...)  -- Pass self to original logger
    capture_log("DEBUG", ...)
  end

  local original_error = logger.error
  logger.error = function(self, ...)  -- ADD 'self' parameter here!
    original_error(self, ...)  -- Pass self to original logger
    capture_log("ERROR", ...)
  end

  -- Optional: Capture warnings if your logger has them
  local original_warn = logger.warn
  if original_warn then
    logger.warn = function(self, ...)  -- ADD 'self' parameter here!
      original_warn(self, ...)  -- Pass self to original logger
      capture_log("WARN", ...)
    end
  end
  -- ============================================

  -- Window settings
  self:set_size(1000, 800)
  self:add_flag(ImGuiWindowFlags_HorizontalScrollbar)

  -- ===== NEW: Smart Logger Integration =====

  -- Register with SmartLogger (called from main.lua)
  function self:register_smart_logger(smart_logger)
    self.smart_logger = smart_logger

    -- Register callback to receive log messages
    if smart_logger and smart_logger.register_gui_callback then
      smart_logger:register_gui_callback(function(log_entry)
        self:add_smart_log_message(log_entry)
      end)

      logger:info("SmartLogger registered with GUI")
    end
  end

  -- Add smart log message to panel
  function self:add_smart_log_message(log_entry)
    local level = log_entry.level or "INFO"  -- Use level if exists, default to "INFO"
    local text = log_entry.text or log_entry  -- Handle both string and table
    
    local entry = {
        time = os.date("%H:%M:%S"),
        level = level,
        text = text
    }
    
    local verbosity = self.config:get('log_verbosity')
    if verbosity == nil then
      print("ERROR: self.config:get('log_verbosity') returned nil")
      verbosity = 3  -- Default to INFO
    end

    -- Now use verbosity for comparison
    local level_num = self.logger:get_verbosity_num(level) or 3
    
    if level_num <= verbosity then
      table.insert(self.log_messages, entry)
    end

    if level_num<=self.config:get('log_verbosity') then
      table.insert(self.log_messages, entry)
    end
    
    -- Trim if too many messages
    while #self.log_messages > self.max_log_lines do
      table.remove(self.log_messages, 1)
    end
    
    -- Request scroll to bottom if auto-scroll is enabled
    if self.log_panel_state.auto_scroll then
      self.log_panel_state.scroll_to_bottom = true
    end
  end

  -- Render enhanced log panel
  function self:render_log_panel()
    -- Log panel header with controls
    ImGui.SeparatorText("Event Log")
  
    -- Controls row
    ImGui.BeginGroup()
  
    -- Auto-scroll toggle (using IsItemClicked for immediate feedback)
    ImGui.Checkbox("Auto-scroll", self.log_panel_state.auto_scroll)
    if ImGui.IsItemClicked() then
      -- Toggle the state
      self.log_panel_state.auto_scroll = not self.log_panel_state.auto_scroll
      self.config:set('log_auto_scroll', self.log_panel_state.auto_scroll)
      self.config:save()
      self.logger:info("Auto-scroll %s", self.log_panel_state.auto_scroll and "enabled" or "disabled")
    end
  
    ImGui.SameLine()
  
    -- Timestamps toggle
    ImGui.Checkbox("Timestamps", self.log_panel_state.show_timestamps)
    if ImGui.IsItemClicked() then
      self.log_panel_state.show_timestamps = not self.log_panel_state.show_timestamps
      self.config:set('log_show_timestamps', self.log_panel_state.show_timestamps)
      self.config:save()
      self.logger:info("Timestamps %s", self.log_panel_state.show_timestamps and "shown" or "hidden")
    end
  
    ImGui.SameLine()
  
    -- Levels toggle
    ImGui.Checkbox("Levels", self.log_panel_state.show_levels)
    if ImGui.IsItemClicked() then
      self.log_panel_state.show_levels = not self.log_panel_state.show_levels
      self.config:set('log_show_levels', self.log_panel_state.show_levels)
      self.config:save()
      self.logger:info("Log levels %s", self.log_panel_state.show_levels and "shown" or "hidden")
    end
  
    ImGui.SameLine()
  
    -- Clear button
    if ImGui.Button("Clear Log") then
      self.log_messages = {}
      if self.smart_logger then
        self.smart_logger:info("Log panel cleared")
      else
        logger:info("Log panel cleared")
      end
    end
  
    ImGui.SameLine()
  
    -- Copy to clipboard button
    if ImGui.Button("Copy to Clipboard") then
      self:copy_log_to_clipboard()
    end
  
    ImGui.SameLine()
  
    -- Stats button (only if smart logger is available)
    if self.smart_logger and ImGui.Button("Stats") then
      self.smart_logger:log_stats()
    end
  
    ImGui.EndGroup()
  
    -- Message count
    ImGui.SameLine(ImGui.GetWindowWidth() - 120)
    ImGui.TextDisabled(string.format("%d messages", #self.log_messages))
  
    -- Log display area
    ImGui.Separator()
  
    -- Begin child window for scrolling
    ImGui.BeginChild("LogDisplay", 0, 0, true, ImGuiWindowFlags_HorizontalScrollbar)
  
    -- Display messages
    for _, entry in ipairs(self.log_messages) do
      -- entry is now a TABLE, not a string
      local display_text = ""
      
      -- Add timestamp if checkbox is checked
      if self.log_panel_state.show_timestamps then
          display_text = display_text .. "<" .. entry.time .. ">" .. " "
      end
      
      -- Add level if checkbox is checked
      if self.log_panel_state.show_levels then
          display_text = display_text .. "[" .. entry.level .. "] "
      end
      
      -- Add the actual message text
      display_text = display_text .. entry.text
      
      ImGui.TextWrapped(display_text)
    end
  
    -- Auto-scroll to bottom if needed
    if self.log_panel_state.scroll_to_bottom and self.log_panel_state.auto_scroll then
      -- Scroll to the maximum Y position (bottom)
      ImGui.SetScrollY(ImGui.GetScrollMaxY())
    end
  
    ImGui.EndChild()
  end

  -- Render log settings panel (NEW)
  function self:render_log_settings_panel()
    ImGui.SeparatorText("Logging Configuration")
    
    -- Initialize temp_settings if not exists
    if not self.temp_settings then
      self.temp_settings = {
        verbosity = tonumber(self.config:get('log_verbosity')) or 3,
        max_lines = tonumber(self.config:get('max_log_lines')) or 500,
        console_enabled = self.config:get('log_console_enabled') ~= false,
        gui_enabled = self.config:get('log_gui_enabled') ~= false,
        smart_routing = self.config:get('log_smart_routing') ~= false
      }
    end
  
    -- === VERBOSITY SLIDER ===
    ImGui.Text("Verbosity Level:")
    ImGui.SameLine()
    ImGui.TextDisabled("(?)")
    if ImGui.IsItemHovered() then
        ImGui.BeginTooltip()
        ImGui.PushTextWrapPos(ImGui.GetFontSize() * 35.0)
        ImGui.Text("0=FATAL only (system crashing)\n1=ERROR and above (critical)\n2=WARN and above (important)\n3=INFO and above (normal)\n4=DEBUG and above (debugging)\n5=TRACE and above (everything)")
        ImGui.PopTextWrapPos()
        ImGui.EndTooltip()
    end

    self.temp_settings.verbosity = ImGui.SliderInt("##verbosity_slider", self.temp_settings.verbosity, 0, 5)

    -- Show description (using the potentially updated value)
    local level_names = {
        [0] = "FATAL only (system crashing)",
        [1] = "ERROR and above (critical)",
        [2] = "WARN and above (important)",
        [3] = "INFO and above (normal)",
        [4] = "DEBUG and above (debugging)",
        [5] = "TRACE and above (everything)"
    }
    ImGui.TextDisabled("Current: " .. (level_names[current_verbosity] or "Unknown"))
  
    ImGui.Spacing()
    ImGui.Separator()
    ImGui.Spacing()
  
    -- === OUTPUT DESTINATIONS ===
    ImGui.Text("Output Destinations:")
  
    -- Console output checkbox
    ImGui.Checkbox("Console Output", self.temp_settings.console_enabled)
    if ImGui.IsItemClicked() then
      self.temp_settings.console_enabled = not self.temp_settings.console_enabled
    end
  
    -- GUI output checkbox
    ImGui.Checkbox("GUI Output", self.temp_settings.gui_enabled)
    if ImGui.IsItemClicked() then
      self.temp_settings.gui_enabled = not self.temp_settings.gui_enabled
    end
  
    ImGui.Spacing()
  
    -- Smart routing checkbox
    ImGui.Checkbox("Smart Routing", self.temp_settings.smart_routing)
    if ImGui.IsItemClicked() then
      self.temp_settings.smart_routing = not self.temp_settings.smart_routing
    end
    
    ImGui.SameLine()
    ImGui.TextDisabled("(?)")
    if ImGui.IsItemHovered() then
      ImGui.BeginTooltip()
      ImGui.PushTextWrapPos(ImGui.GetFontSize() * 35.0)
      ImGui.Text("When GUI is open: reduces console spam by sending only high-priority messages (FATAL, ERROR, WARN) to console")
      ImGui.PopTextWrapPos()
      ImGui.EndTooltip()
    end
  
    ImGui.Spacing()
    ImGui.Separator()
    ImGui.Spacing()
  
    -- === MAX LINES INPUT ===
    ImGui.Text("GUI Display Settings:")

    -- Use local variable
    self.temp_settings.max_lines = ImGui.InputInt("Max Lines", self.temp_settings.max_lines)

    -- Validate and update
    local num = tonumber(self.temp_settings.max_lines)
    if num then
      if num < 100 then
        self.temp_settings.max_lines = 100
      elseif num > 5000 then
        self.temp_settings.max_lines = 5000
      else
      end
    end

    -- === ACTION BUTTONS ===
    ImGui.Spacing()
    ImGui.Separator()
    ImGui.Spacing()
    
    ImGui.BeginGroup()
    
    -- SAVE button
    if ImGui.Button("Save Configuration", 120, 0) then
      -- Save to config
      self.config:set('log_verbosity', self.temp_settings.verbosity)
      self.config:set('max_log_lines', self.temp_settings.max_lines)
      self.config:set('log_console_enabled', self.temp_settings.console_enabled)
      self.config:set('log_gui_enabled', self.temp_settings.gui_enabled)
      self.config:set('log_smart_routing', self.temp_settings.smart_routing)
      self.config:save()
      
      -- Apply to logger
      if self.smart_logger then
        self.smart_logger:set_verbosity(self.temp_settings.verbosity)
        self.smart_logger:set_console_enabled(self.temp_settings.console_enabled)
        self.smart_logger:set_gui_enabled(self.temp_settings.gui_enabled)
        self.smart_logger:set_smart_routing(self.temp_settings.smart_routing)
        self.smart_logger:set_max_gui_lines(self.temp_settings.max_lines)
      end
      
      -- Update window
      self.max_log_lines = self.temp_settings.max_lines
      while #self.log_messages > self.max_log_lines do
        table.remove(self.log_messages, 1)
      end
      
      self.logger:info("Log configuration saved and applied")
    end
    
    ImGui.SameLine()
    
    -- APPLY button
    if ImGui.Button("Apply (No Save)", 120, 0) then
      -- Apply to logger only
      if self.smart_logger then
        self.smart_logger:set_verbosity(self.temp_settings.verbosity)
        self.smart_logger:set_console_enabled(self.temp_settings.console_enabled)
        self.smart_logger:set_gui_enabled(self.temp_settings.gui_enabled)
        self.smart_logger:set_smart_routing(self.temp_settings.smart_routing)
        self.smart_logger:set_max_gui_lines(self.temp_settings.max_lines)
      end
      
      -- Update window
      self.max_log_lines = self.temp_settings.max_lines
      while #self.log_messages > self.max_log_lines do
        table.remove(self.log_messages, 1)
      end
      
      self.logger:info("Log configuration applied (not saved to file)")
    end
    
    ImGui.SameLine()
    
    -- RESET button
    if ImGui.Button("Reset to Saved", 120, 0) then
      -- Reload config
      self.config:load()
      
      -- Reset temp settings
      self.temp_settings = {
        verbosity = tonumber(self.config:get('log_verbosity')) or 3,
        max_lines = tonumber(self.config:get('max_log_lines')) or 500,
        console_enabled = self.config:get('log_console_enabled') ~= false,
        gui_enabled = self.config:get('log_gui_enabled') ~= false,
        smart_routing = self.config:get('log_smart_routing') ~= false
      }
      
      -- Apply to logger
      if self.smart_logger then
        self.smart_logger:set_verbosity(self.temp_settings.verbosity)
        self.smart_logger:set_console_enabled(self.temp_settings.console_enabled)
        self.smart_logger:set_gui_enabled(self.temp_settings.gui_enabled)
        self.smart_logger:set_smart_routing(self.temp_settings.smart_routing)
        self.smart_logger:set_max_gui_lines(self.temp_settings.max_lines)
      end
      
      -- Update window
      self.max_log_lines = self.temp_settings.max_lines
      
      self.logger:info("Log configuration reset to saved values")
    end
    
    ImGui.EndGroup()
  end

  -- Copy log to clipboard
  function self:copy_log_to_clipboard()
    local log_text = ""
    for _, msg in ipairs(self.log_messages) do
      log_text = log_text .. msg .. "\n"
    end

    -- Set clipboard text
    if ImGui.SetClipboardText then
      ImGui.SetClipboardText(log_text)
      if self.smart_logger then
        self.smart_logger:info("Log copied to clipboard (%d lines)", #self.log_messages)
      else
        logger:info("Log copied to clipboard (%d lines)", #self.log_messages)
      end
    else
      if self.smart_logger then
        self.smart_logger:warn("Clipboard not available in this environment")
      else
        logger:warn("Clipboard not available in this environment")
      end
    end
  end

  -- Override render_content to include log settings tab
  function self:render_content()
    -- === 1. MENU BAR ===
    if ImGui.BeginMenuBar() then
      -- File Menu
      if ImGui.BeginMenu("File") then
        if ImGui.MenuItem("Save Configuration") then
          self.config:save()
          logger:info("Configuration saved")
        end
        if ImGui.MenuItem("Reload Configuration") then
          self.config:load()
          logger:info("Configuration reloaded")
        end
        ImGui.Separator()
        if ImGui.MenuItem("Exit") then
          self.state:gui_set_visible(false)
          self:close()
        end
        ImGui.EndMenu()
      end

      -- View Menu
      if ImGui.BeginMenu("View") then
        if ImGui.MenuItem("Reset Window Position") then
          self:set_position(100, 100)
          logger:debug("Window position reset")
        end
        if ImGui.MenuItem("Toggle Console Output", nil, self.config:get('show_messages_in_console')) then
          local current = self.config:get('show_messages_in_console')
          self.config:set('show_messages_in_console', not current)
          logger:info("Console output " .. (not current and "enabled" or "disabled"))
        end
        ImGui.EndMenu()
      end

      -- Help Menu
      if ImGui.BeginMenu("Help") then
        if ImGui.MenuItem("About") then
          logger:info("LuaLooter v0.5.0 - Advanced Looting System")
        end
        ImGui.EndMenu()
      end

      -- Status indicator (Right-aligned)
      ImGui.SameLine(ImGui.GetWindowWidth() - 150)
      local status_text = self.state:is_enabled() and "ACTIVE" or "PAUSED"
      local r, g, b
      if self.state:is_enabled() then
        r, g, b = 0.0, 1.0, 0.0         -- Green
      else
        r, g, b = 1.0, 0.0, 0.0         -- Red
      end
      ImGui.TextColored(r, g, b, 1.0, status_text)

      ImGui.EndMenuBar()
    end

    -- === 2. TAB BAR ===
    if ImGui.BeginTabBar("MainTabs") then
      for _, tab in ipairs(self.tabs) do
        local tab_flags = 0
        if self.active_tab == tab.id then
          tab_flags = ImGuiTabItemFlags_SetSelected
        end

        if ImGui.BeginTabItem(tab.icon .. " " .. tab.name, nil, tab_flags) then
          self.active_tab = tab.id
          self:render_tab_content(tab.id)
          ImGui.EndTabItem()
        end
      end
      ImGui.EndTabBar()
    end
  end

  -- Render tab content
  function self:render_tab_content(tab_id)
    ImGui.BeginChild("PanelContent", 0, 0, true)
    
    -- Use pcall to catch errors and ensure EndChild is called
    local success, error_msg = pcall(function()
      if tab_id == 1 then
        -- Log Panel
        self:render_log_panel()
      elseif tab_id == 2 then
        -- Settings Panel (existing)
        ImGui.Text("Settings Panel - Coming in Phase 3")
        ImGui.Text("Character and system settings")
      elseif tab_id == 3 then
        -- Loot Rules Panel (existing)
        ImGui.Text("Loot Rules Panel - Coming in Phase 4")
        ImGui.Text("Manage item loot rules")
      elseif tab_id == 4 then
        -- Log Settings Panel (new)
        self:render_log_settings_panel()
      end
    end)
    
    if not success then
      -- Use simple print to avoid recursive logger errors
      print(string.format("[GUI ERROR] Error rendering tab %d: %s", tab_id, tostring(error_msg)))
      ImGui.TextColored(1.0, 0.0, 0.0, 1.0, "ERROR: " .. tostring(error_msg))
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
