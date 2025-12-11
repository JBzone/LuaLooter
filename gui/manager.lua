--[[
DESIGN DECISION: Centralized GUI management
WHY: Single point for GUI state and lifecycle
     Handles ImGui initialization and cleanup
     Manages window creation/destruction
--]]

local mq = require('mq')
local ImGui = require 'ImGui'

local GUIManager = {}

function GUIManager.new(state, config, logger)
  local self = {
    state = state,
    config = config,
    logger = logger,
    windows = {},
    events = nil     -- Will be set later
  }

  -- NEW: Method to set events after creation
  function self:set_events(events)
    self.events = events
    self.logger:debug("Events set on GUI Manager")

    -- Subscribe to GUI visibility changes for smart logger
    if events then
      events:subscribe(events.EVENT_TYPES.GUI_TOGGLE, function(data)
        if self.windows.main and self.windows.main.gui_visible_changed then
          self.windows.main:gui_visible_changed(data.visible or false)
        end
      end)
    end
  end

  function self:init()
    if self.state:gui_is_initialized() then return end

    self.logger:debug("Initializing GUI Manager")

    -- Create main window (UPDATED: Pass events if available)
    local MainWindow = require('gui.main')
    self.windows.main = MainWindow.new(self.state, self.config, self.logger, self.events)

    -- Create wrapper
    local main_window = self.windows.main

    local render_func = function()
      -- Only render if GUI should be visible
      if self.state:gui_is_visible() then
        if main_window and main_window.render then
          main_window:render()
        end
      end
      -- If not visible, do nothing (function still called by MQ)
    end

    ImGui.Register('LuaLooter_MainWindow', render_func)
    self.state:gui_set_initialized(true)
    self.logger:debug("GUI Manager initialized")
  end

  function self:toggle()
    local new_visibility = not self.state:gui_is_visible()
    self.state:gui_set_visible(new_visibility)

    -- Publish event for smart logger
    if self.events then
      self.events:publish(self.events.EVENT_TYPES.GUI_TOGGLE, {
        visible = new_visibility
      })
    end

    if new_visibility then
      -- If showing, ensure window is initialized and open
      if not self.state.initialized then
        self:init()
      end
      if self.windows.main then
        self.windows.main.open = true         -- Reopen the window
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
    if not self.state:gui_is_initialized() then
      self:init()
    end
    self.state:gui_set_visible(true)

    -- Publish event for smart logger
    if self.events then
      self.events:publish(self.events.EVENT_TYPES.GUI_TOGGLE, {
        visible = true
      })
    end

    self.logger:debug("GUI shown")
  end

  function self:hide()
    self.state:gui_set_visible(false)

    -- Publish event for smart logger
    if self.events then
      self.events:publish(self.events.EVENT_TYPES.GUI_TOGGLE, {
        visible = false
      })
    end

    self.logger:debug("GUI hidden")
  end

  function self:is_visible()
    return self.state:gui_is_visible()
  end

  function self:shutdown()
    self.logger:debug("Shutting down GUI Manager")
    self.state:gui_set_visible(false)
    self.windows = {}
    self.state:gui_set_initialized(false)
  end

  return self
end

return GUIManager
