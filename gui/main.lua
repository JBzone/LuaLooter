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
  local function capture_log(original_fn, level, ...)
    -- Call original logger first
    original_fn(...)

    local args = { ... }
    local format_str = args[1]
    local msg_str

    if type(format_str) == "string" and #args > 1 and format_str:find("%%") then
      local format_args = {}
      for i = 2, #args do
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

    table.insert(self.log_messages, os.date("%H:%M:%S") .. " [" .. level .. "] " .. msg_str)

    -- Trim if too long
    if #self.log_messages > self.max_log_lines then
      table.remove(self.log_messages, 1)
    end
  end

  -- Capture logger output PROPERLY (for backward compatibility)
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
  self:set_size(1000, 800)
  self:add_flag(ImGui.WindowFlags.MenuBar)

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
    -- Add to message buffer
    table.insert(self.log_messages, log_entry.text)

    -- Trim if too many messages
    while #self.log_messages > self.max_log_lines do
      table.remove(self.log_messages, 1)
    end

    -- Request scroll to bottom
    self.log_panel_state.scroll_to_bottom = self.log_panel_state.auto_scroll
  end

  -- Render enhanced log panel
  function self:render_log_panel()
    -- Log panel header with controls
    ImGui.SeparatorText("Event Log")

    -- Controls row
    ImGui.BeginGroup()

    -- Auto-scroll toggle
    local changed, auto_scroll = ImGui.Checkbox("Auto-scroll", self.log_panel_state.auto_scroll)
    if changed then
      self.log_panel_state.auto_scroll = auto_scroll
      self.config:set('log_auto_scroll', auto_scroll)
      self.config:save()
    end

    ImGui.SameLine()

    -- Timestamps toggle
    local changed, show_ts = ImGui.Checkbox("Timestamps", self.log_panel_state.show_timestamps)
    if changed then
      self.log_panel_state.show_timestamps = show_ts
      self.config:set('log_show_timestamps', show_ts)
      self.config:save()
    end

    ImGui.SameLine()

    -- Levels toggle
    local changed, show_lv = ImGui.Checkbox("Levels", self.log_panel_state.show_levels)
    if changed then
      self.log_panel_state.show_levels = show_lv
      self.config:set('log_show_levels', show_lv)
      self.config:save()
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
    ImGui.BeginChild("LogDisplay", 0, 0, true, ImGui.WindowFlags.HorizontalScrollbar)

    -- Display messages
    for _, msg in ipairs(self.log_messages) do
      ImGui.TextWrapped(msg)
    end

    -- Auto-scroll to bottom if requested
    if self.log_panel_state.scroll_to_bottom then
      ImGui.SetScrollHereY(1.0)
      self.log_panel_state.scroll_to_bottom = false
    end

    ImGui.EndChild()
  end

  -- Render log settings panel (NEW)
  function self:render_log_settings_panel()
    ImGui.SeparatorText("Logging Configuration")

    -- Verbosity level slider
    local verbosity = self.config:get('log_verbosity') or 3
    ImGui.Text("Verbosity Level:")
    ImGui.SameLine()
    ImGui.TextDisabled("(?)")
    if ImGui.IsItemHovered() then
      ImGui.BeginTooltip()
      ImGui.PushTextWrapPos(ImGui.GetFontSize() * 35.0)
      ImGui.Text(
      "0=FATAL only (system crashing)\n1=ERROR and above (critical)\n2=WARN and above (important)\n3=INFO and above (normal)\n4=DEBUG and above (debugging)\n5=TRACE and above (everything)")
      ImGui.PopTextWrapPos()
      ImGui.EndTooltip()
    end

    local changed, new_verbosity = ImGui.SliderInt("##verbosity", verbosity, 0, 5)
    if changed then
      self.config:set('log_verbosity', new_verbosity)
      if self.smart_logger then
        self.smart_logger:set_verbosity(new_verbosity)
      end
      logger:info("Verbosity set to %d", new_verbosity)
    end

    -- Show current verbosity description
    local level_names = {
      [0] = "FATAL only (system crashing)",
      [1] = "ERROR and above (critical)",
      [2] = "WARN and above (important)",
      [3] = "INFO and above (normal)",
      [4] = "DEBUG and above (debugging)",
      [5] = "TRACE and above (everything)"
    }
    ImGui.TextDisabled("Current: " .. (level_names[verbosity] or "Unknown"))

    ImGui.Spacing()
    ImGui.Separator()
    ImGui.Spacing()

    -- Output destinations
    ImGui.Text("Output Destinations:")

    local console_enabled = self.config:get('log_console_enabled') ~= false
    local changed, new_console = ImGui.Checkbox("Console Output", console_enabled)
    if changed then
      self.config:set('log_console_enabled', new_console)
      if self.smart_logger then
        self.smart_logger:set_console_enabled(new_console)
      end
      logger:info("Console output %s", new_console and "enabled" or "disabled")
    end

    local gui_enabled = self.config:get('log_gui_enabled') ~= false
    local changed, new_gui = ImGui.Checkbox("GUI Output", gui_enabled)
    if changed then
      self.config:set('log_gui_enabled', new_gui)
      if self.smart_logger then
        self.smart_logger:set_gui_enabled(new_gui)
      end
      logger:info("GUI output %s", new_gui and "enabled" or "disabled")
    end

    ImGui.Spacing()

    -- Smart routing
    local smart_routing = self.config:get('log_smart_routing') ~= false
    local changed, new_smart = ImGui.Checkbox("Smart Routing", smart_routing)
    if changed then
      self.config:set('log_smart_routing', new_smart)
      if self.smart_logger then
        self.smart_logger:set_smart_routing(new_smart)
      end
      logger:info("Smart routing %s", new_smart and "enabled" or "disabled")
    end

    ImGui.SameLine()
    ImGui.TextDisabled("(?)")
    if ImGui.IsItemHovered() then
      ImGui.BeginTooltip()
      ImGui.PushTextWrapPos(ImGui.GetFontSize() * 35.0)
      ImGui.Text(
      "When GUI is open: reduces console spam by sending only high-priority messages (FATAL, ERROR, WARN) to console")
      ImGui.PopTextWrapPos()
      ImGui.EndTooltip()
    end

    ImGui.Spacing()
    ImGui.Separator()
    ImGui.Spacing()

    -- GUI display settings
    ImGui.Text("GUI Display Settings:")

    local changed, max_lines = ImGui.InputInt("Max Lines", self.max_log_lines)
    if changed and max_lines >= 100 and max_lines <= 5000 then
      self.max_log_lines = max_lines
      self.config:set('max_log_lines', max_lines)

      -- Trim messages if new max is smaller
      while #self.log_messages > max_lines do
        table.remove(self.log_messages, 1)
      end

      if self.smart_logger then
        self.smart_logger:set_max_gui_lines(max_lines)
      end
    end

    -- Save button
    ImGui.Spacing()
    if ImGui.Button("Save Configuration") then
      self.config:save()
      logger:info("Log configuration saved")
    end

    ImGui.SameLine()

    -- Reload button
    if ImGui.Button("Reload Configuration") then
      self.config:load()

      -- Update local state from config
      self.max_log_lines = self.config:get('max_log_lines') or 500
      self.log_panel_state.auto_scroll = self.config:get('log_auto_scroll') ~= false
      self.log_panel_state.show_timestamps = self.config:get('log_show_timestamps') ~= false
      self.log_panel_state.show_levels = self.config:get('log_show_levels') ~= false

      -- Update smart logger if available
      if self.smart_logger then
        local log_config = self.config:get_log_config()
        if log_config then
          self.smart_logger:set_verbosity(log_config.verbosity)
          self.smart_logger:set_console_enabled(log_config.console_enabled)
          self.smart_logger:set_gui_enabled(log_config.gui_enabled)
          self.smart_logger:set_smart_routing(log_config.smart_routing)
          self.smart_logger:set_max_gui_lines(log_config.max_gui_lines)
        end
      end

      logger:info("Log configuration reloaded")
    end
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
          tab_flags = ImGui.TabItemFlags.SetSelected
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
