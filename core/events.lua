-- core/events.lua - FIXED VERSION (SAME API)
local mq = require('mq')

local Events = {}

function Events.new(logger)
  local self = {
    EVENT_TYPES = {
      -- Cash events
      CASH_LOOTED = "cash_looted",

      -- Item events
      ITEM_LOOTED = "item_looted",
      ITEM_DESTROYED = "item_destroyed",
      ITEM_PASSED = "item_passed",
      ITEM_LEFT = "item_left",

      -- Loot processing events
      LOOT_ACTION = "loot_action",           -- From logic to execution
      LOOT_START = "loot_start",             -- Loot processing started
      LOOT_COMPLETE = "loot_complete",       -- Loot processing completed

      -- Window events
      LOOT_WINDOW_OPEN = "loot_window_open",
      LOOT_WINDOW_CLOSE = "loot_window_close",

      -- No-drop timer events
      NO_DROP_WAIT_START = "no_drop_wait_start",
      NO_DROP_WAIT_EXPIRED = "no_drop_wait_expired",

      -- Configuration events
      CONFIG_CHANGED = "config_changed",
      PROFIT_UPDATED = "profit_updated",

      -- UI events
      GUI_TOGGLE = "gui_toggle",
      GUI_UPDATE = "gui_update",

      -- State events
      STATE_CHANGED = "state_changed",
      MODULE_TOGGLE = "module_toggle",

      -- Error events
      ERROR_OCCURRED = "error_occurred",
      WARNING_OCCURRED = "warning_occurred"
    },
    subscribers = {},
    logger = logger,

    -- Track MQ event registrations
    mq_events_registered = false
  }

  -- SAFE logging helper (internal use only)
  local function safe_log(self, level, msg, ...)
    if self.logger and self.logger[level] then
      local ok, err = pcall(self.logger[level], self.logger, msg, ...)
      if not ok then
        -- Fallback to console
        print(string.format("[Events] Logger error: %s", err))
      end
    elseif level == "error" or level == "warn" then
      -- Console fallback for important messages
      local formatted = string.format("[Events] " .. msg, ...)
      if level == "error" then
        print("\ar" .. formatted .. "\ax")
      elseif level == "warn" then
        print("\ay" .. formatted .. "\ax")
      else
        print(formatted)
      end
    end
  end

  -- Register ALL MQ events in ONE PLACE
  function self:register_mq_events()
    if self.mq_events_registered then
      safe_log(self, "debug", "MQ events already registered")
      return
    end
    
    safe_log(self, "debug", "Starting MQ event registration")    

    -- Loot completion events
    mq.event("ItemLooted", "#*#You have looted a #*#", function()
      self:publish(self.EVENT_TYPES.ITEM_LOOTED, {})
    end)

    mq.event("ItemLootedAn", "#*#You have looted an #*#", function()
      self:publish(self.EVENT_TYPES.ITEM_LOOTED, {})
    end)

    mq.event("ItemDestroyed", "#*#You successfully destroyed #*#", function(line)
      local item_name = line:match("You successfully destroyed (%d+) (.+)%.")
      if item_name then
        item_name = item_name:gsub("^%d+ ", "")
        self:publish(self.EVENT_TYPES.ITEM_DESTROYED, {
          name = item_name
        })
      end
    end)

    mq.event("ItemPassed", "#*#You pass on #*#", function()
      self:publish(self.EVENT_TYPES.ITEM_PASSED, {})
    end)

    mq.event("ItemLeft", "#*#You decide to leave #*#", function()
      self:publish(self.EVENT_TYPES.ITEM_LEFT, {})
    end)

    -- Cash loot events
    mq.event('CashLootPlatOnlyCorpse', '#*#You receive #1# platinum from the corpse.#*#',
      function(line, plat)
        self:publish(self.EVENT_TYPES.CASH_LOOTED, {
          plat = tonumber(plat) or 0,
          gold = 0,
          silver = 0,
          copper = 0
        })
      end)

    mq.event('CashLootPlatGoldCorpse', '#*#You receive #1# platinum and #2# gold from the corpse.#*#',
      function(line, plat, gold)
        self:publish(self.EVENT_TYPES.CASH_LOOTED, {
          plat = tonumber(plat) or 0,
          gold = tonumber(gold) or 0,
          silver = 0,
          copper = 0
        })
      end)

    mq.event('CashLootPlatGoldSilverCorpse', '#*#You receive #1# platinum, #2# gold and #3# silver from the corpse.#*#',
      function(line, plat, gold, silver)
        self:publish(self.EVENT_TYPES.CASH_LOOTED, {
          plat = tonumber(plat) or 0,
          gold = tonumber(gold) or 0,
          silver = tonumber(silver) or 0,
          copper = 0
        })
      end)

    mq.event('CashLootPlatGoldSilverCopperCorpse',
      '#*#You receive #1# platinum, #2# gold, #3# silver and #4# copper from the corpse.#*#',
      function(line, plat, gold, silver, copper)
        self:publish(self.EVENT_TYPES.CASH_LOOTED, {
          plat = tonumber(plat) or 0,
          gold = tonumber(gold) or 0,
          silver = tonumber(silver) or 0,
          copper = tonumber(copper) or 0
        })
      end)

    -- Window events
    mq.event('LootWindowClosed', '#*#Loot #window# has been closed#*#', function()
      self:publish(self.EVENT_TYPES.LOOT_WINDOW_CLOSE, {})
    end)

    mq.event('BeginZone', '#*#LOADING, PLEASE WAIT...#*#', function()
      self:publish(self.EVENT_TYPES.LOOT_WINDOW_CLOSE, {})       -- Also triggers on zone
    end)

    self.mq_events_registered = true
    safe_log(self, "info", "MQ events registered successfully")
  end

  function self:publish(event_type, data)
    data = data or {}
    data.event_type = event_type
    data.timestamp = os.time()

    local subscribers = self.subscribers[event_type]
    if subscribers then
      for _, callback in ipairs(subscribers) do
        local success, err = pcall(callback, data)
        if not success then
          safe_log(self, "error", "Callback error for %s: %s", event_type, err)
        end
      end
    end

    -- Also trigger global subscribers
    local all_subscribers = self.subscribers["*"]
    if all_subscribers then
      for _, callback in ipairs(all_subscribers) do
        local success, err = pcall(callback, data)
        if not success then
          safe_log(self, "error", "Global callback error: %s", err)
        end
      end
    end

    safe_log(self, "debug", "Event published: %s", event_type)

    return self
  end

  function self:subscribe(event_type, callback)
    if not self.subscribers[event_type] then
      self.subscribers[event_type] = {}
    end
    table.insert(self.subscribers[event_type], callback)

    safe_log(self, "debug", "Subscribed to event: %s", event_type)

    return self
  end

  function self:subscribe_all(callback)
    return self:subscribe("*", callback)
  end

  function self:unsubscribe(event_type, callback)
    if not self.subscribers[event_type] then return self end

    for i, cb in ipairs(self.subscribers[event_type]) do
      if cb == callback then
        table.remove(self.subscribers[event_type], i)
        safe_log(self, "debug", "Unsubscribed from event: %s", event_type)
        break
      end
    end

    return self
  end

  function self:get_event_types()
    return self.EVENT_TYPES
  end

  return self
end

return Events