--[[
DESIGN DECISION: Core logic separate from filter system
WHY: Filters can override, but core logic handles everything else
     Clean business logic without filter complexity
     Easy to modify loot rules without affecting filters
--]]

local mq = require('mq')

local LootLogic = {}

function LootLogic.new(state, config, logger, events, item_service, filter_module)
    local self = {
        state = state,
        config = config,
        logger = logger,
        events = events,
        items = item_service,
        filters = filter_module,
        
        -- Track processed items PER LOOT WINDOW SESSION
        current_session_id = nil,
        processed_items = {},  -- item_name -> {session_id, processed_at, action}
        
        -- Cache for item decisions to avoid recalculation
        decision_cache = {},  -- cache_key -> {action, expires_at}
        
        -- Store items that are waiting due to no-drop items with no rules
        waiting_items = {},
        
        -- Performance tracking
        stats = {
            cache_hits = 0,
            cache_misses = 0,
            items_processed = 0,
            session_items = 0
        },
        
        -- FIX: Add event-driven processing state
        waiting_for_loot = false,
        last_loot_time = 0,
        pending_loot_actions = {},
        loot_delay = 1500,  -- 1.5 seconds between commands
        loot_timeout = 5000, -- 5 second timeout
    }
    
    -- Initialize event handlers (FIXES RACE CONDITION)
    function self:init_event_handlers()
        self.logger:debug("Initializing LootLogic event handlers")
        
        -- Subscribe to loot action events
        self.events:subscribe(self.events.EVENT_TYPES.LOOT_ACTION, function(data)
            self:execute_loot_action(data)
        end)
        
        self.last_loot_time = mq.gettime()
    end
    
    -- Event handlers (FIXES RACE CONDITION)
    function self:handle_loot_complete()
        self.logger:debug("Loot completed event received")
        mq.delay(100)
        self.waiting_for_loot = false
        self.last_loot_time = mq.gettime()
        self.state:set_processing(false)
        
        self:process_next_queued()
    end
    
    function self:handle_destroy_complete(line)
        local item_name = line:match("You successfully destroyed (%d+) (.+)%.")
        if item_name then
            item_name = item_name:gsub("^%d+ ", "")
            self.logger:debug("Destroy completed: %s", item_name)
            
            -- Track destroyed item value
            local item_value = self.items:get_item_value(item_name) or 0
            self.events:publish(self.events.EVENT_TYPES.ITEM_DESTROYED, {
                name = item_name,
                value = item_value
            })
        end
        
        mq.delay(100)
        self.waiting_for_loot = false
        self.last_loot_time = mq.gettime()
        self.state:set_processing(false)
        
        self:process_next_queued()
    end
    
    function self:handle_action_complete()
        self.logger:debug("Loot action (pass/leave) completed")
        mq.delay(100)
        self.waiting_for_loot = false
        self.last_loot_time = mq.gettime()
        self.state:set_processing(false)
        
        self:process_next_queued()
    end
    
    function self:process_next_queued()
        if #self.pending_loot_actions > 0 then
            mq.delay(500)
            local next_action = table.remove(self.pending_loot_actions, 1)
            self:execute_loot_action(next_action)
        end
    end
    
    function self:wait_for_loot_cooldown()
        local current_time = mq.gettime()
        local time_since_last = current_time - self.last_loot_time
        
        -- Wait minimum delay between loot commands
        if time_since_last < self.loot_delay then
            local wait_time = self.loot_delay - time_since_last
            self.logger:debug("Waiting %dms for loot cooldown", wait_time)
            mq.delay(wait_time)
        end
        
        -- Wait if we're currently processing loot
        local start_wait = mq.gettime()
        while self.waiting_for_loot do
            local time_waiting = mq.gettime() - self.last_loot_time
            if time_waiting > self.loot_timeout then
                self.logger:warn("Loot timeout, resetting state")
                self.waiting_for_loot = false
                self.state:set_processing(false)
                break
            end
            mq.delay(100)
            
            if mq.gettime() - start_wait > 10000 then
                self.logger:warn("Safety timeout, forcing reset")
                self.waiting_for_loot = false
                self.state:set_processing(false)
                break
            end
        end
    end
    
    -- Execute loot action with event waiting (FIXES RACE CONDITION)
    function self:execute_loot_action(data)
        -- Wait for cooldown
        self:wait_for_loot_cooldown()
        
        -- Set state
        self.waiting_for_loot = true
        self.state:set_processing(true)
        self.last_loot_time = mq.gettime()
        
        local index = data.index
        local action = data.action
        local name = data.name
        local is_shared = data.is_shared
        local item_value = data.item_value or 0
        local item_info = data.info or {}
        
        self.logger:info("Executing %s on %s (slot %d, shared: %s)", 
                        action, name, index, tostring(is_shared))
        
        -- Parse action string (could be "PASS|Playername")
        local action_parts = {}
        for part in string.gmatch(action, "[^|]+") do
            table.insert(action_parts, part)
        end
        
        local base_action = action_parts[1]
        local target_player = action_parts[2]
        
        -- Execute the command
        local command = nil
        if base_action == "KEEP" or base_action == "CASH" or base_action == "TRADESKILL" or 
           base_action == "QUEST" or base_action == "SELL" then
            if is_shared then
                command = string.format('/advloot shared %d giveto %s', index, mq.TLO.Me.Name())
            else
                command = string.format('/advloot personal %d loot', index)
            end
            
        elseif base_action == "IGNORE" or base_action == "DESTROY" then
            if is_shared then
                command = string.format('/advloot shared %d leave', index)
            else
                command = string.format('/advloot personal %d never', index)
            end
            
        elseif base_action == "PASS" and target_player then
            if is_shared then
                command = string.format('/advloot shared %d giveto %s', index, target_player)
            else
                command = string.format('/advloot personal %d loot', index)
            end
            
        elseif base_action == "LEAVE" then
            if is_shared then
                command = string.format('/advloot shared %d leave', index)
            else
                command = string.format('/advloot personal %d never', index)
            end
        end
        
        if command then
            if self.config.settings.alpha_mode then
                self.logger:info("[ALPHA] Would execute: %s", command)
                self.waiting_for_loot = false
                self.state:set_processing(false)
                self.events:publish(self.events.EVENT_TYPES.LOOT_COMPLETE, {
                    name = name,
                    action = action,
                    command = command,
                    alpha_mode = true
                })
                return true
            end
            
            self.logger:debug("Executing command: %s", command)
            mq.cmd(command)
            
            -- Track profit immediately (will be confirmed by event)
            if base_action == "KEEP" or base_action == "CASH" or base_action == "TRADESKILL" or 
               base_action == "QUEST" or base_action == "SELL" then
                self.events:publish(self.events.EVENT_TYPES.ITEM_LOOTED, {
                    name = name,
                    value = item_value,
                    action = action
                })
            elseif base_action == "DESTROY" then
                self.events:publish(self.events.EVENT_TYPES.ITEM_DESTROYED, {
                    name = name,
                    value = item_value,
                    action = action
                })
            elseif base_action == "PASS" then
                self.events:publish(self.events.EVENT_TYPES.ITEM_PASSED, {
                    name = name,
                    action = action
                })
            elseif base_action == "LEAVE" or base_action == "IGNORE" then
                self.events:publish(self.events.EVENT_TYPES.ITEM_LEFT, {
                    name = name,
                    action = action
                })
            end
            
            return true
        end
        
        self.logger:warn("No command for action: %s on %s", action, name)
        self.waiting_for_loot = false
        self.state:set_processing(false)
        return false
    end
    
    -- Generate a unique session ID for current loot window
    function self:generate_session_id()
        local npc_id = mq.TLO.Target.ID() or 0
        local timestamp = os.time()
        return string.format("session_%d_%d", npc_id, timestamp)
    end
    
    -- Get cache key for an item decision
    function self:get_cache_key(item_name, is_shared, filter_actions)
        local session_id = self.current_session_id or "no_session"
        local filter_key = "no_filter"
        
        if filter_actions and filter_actions[item_name] then
            local action = filter_actions[item_name].action
            filter_key = action:gsub("[^%w]", "_")
        end
        
        return string.format("%s_%s_%s_%s", 
            session_id, item_name, is_shared and "shared" or "personal", filter_key)
    end
    
    -- Check if item was already processed in current session
    function self:is_item_processed(item_name)
        if not self.current_session_id then return false end
        
        local processed = self.processed_items[item_name]
        if not processed then return false end
        
        -- Check if it's from current session (not an old one)
        return processed.session_id == self.current_session_id
    end
    
    -- Mark item as processed in current session
    function self:mark_item_processed(item_name, action)
        if not self.current_session_id then
            self.current_session_id = self:generate_session_id()
        end
        
        self.processed_items[item_name] = {
            session_id = self.current_session_id,
            processed_at = os.time(),
            action = action
        }
        
        self.stats.session_items = self.stats.session_items + 1
        
        -- Clean up old entries (keep last 100 items max)
        self:cleanup_old_entries()
    end
    
    -- Clean up old processed items to prevent memory bloat
    function self:cleanup_old_entries()
        if #self.processed_items > 100 then
            local count = 0
            local current_time = os.time()
            local max_age = 3600  -- 1 hour
            
            for item_name, data in pairs(self.processed_items) do
                if current_time - data.processed_at > max_age then
                    self.processed_items[item_name] = nil
                    count = count + 1
                end
            end
            
            if count > 0 then
                self.logger:debug("Cleaned up %d old processed items", count)
            end
        end
    end
    
    -- Clear all processed items (call when loot window closes)
    function self:clear_processed_items()
        self.processed_items = {}
        self.decision_cache = {}
        self.current_session_id = nil
        self.stats.session_items = 0
        self.pending_loot_actions = {}
        self.waiting_for_loot = false
        self.logger:debug("Cleared all processed items and cache")
    end
    
    -- Get performance statistics
    function self:get_performance_stats()
        local total = self.stats.cache_hits + self.stats.cache_misses
        local hit_rate = total > 0 and (self.stats.cache_hits / total * 100) or 0
        
        return {
            cache_hits = self.stats.cache_hits,
            cache_misses = self.stats.cache_misses,
            hit_rate = hit_rate,
            items_processed = self.stats.items_processed,
            current_session = self.current_session_id,
            processed_count = #self.processed_items,
            session_items = self.stats.session_items
        }
    end
    
    -- Main processing function with performance improvements
    function self:process(filter_actions)
        if not self.state:is_enabled() or self.waiting_for_loot then
            return
        end
        
        local has_loot = mq.TLO.AdvLoot.SCount() > 0 or mq.TLO.AdvLoot.PCount() > 0
        
        if has_loot then
            -- Generate new session ID if this is first loot detection
            if not self.current_session_id then
                self.current_session_id = self:generate_session_id()
                self.logger:debug("New loot session started: %s", self.current_session_id)
            end
            
            self.events:publish(self.events.EVENT_TYPES.LOOT_START, {})
            
            -- Check for expired waiting periods
            self:check_waiting_items()
            
            -- Process items with filter overrides (OPTIMIZED)
            self:process_items_optimized(filter_actions)
            
            self.events:publish(self.events.EVENT_TYPES.LOOT_COMPLETE, {})
        else
            -- No loot detected, clear session
            if self.current_session_id then
                self.logger:debug("Loot window empty, session %s ended", self.current_session_id)
                self:clear_processed_items()
            end
        end
        
        -- Log performance stats occasionally
        if os.time() % 30 == 0 then  -- Every 30 seconds
            self:log_performance_stats()
        end
    end
    
    local function is_master_looter()
      -- 1. Check if we're in a group and are its master looter
      if mq.TLO.Group and mq.TLO.Group.MasterLooter.ID() == mq.TLO.Me.ID() then
        return true
      end
      -- 2. Check if we're in a raid and are its master looter
      if mq.TLO.Raid and mq.TLO.Raid.MasterLooter.ID() == mq.TLO.Me.ID() then
        return true
      end
      -- 3. Default: If we're not in a group AND not in a raid, we are the solo master looter.
      if not mq.TLO.Group and not mq.TLO.Raid then
        return true
      end
      -- 4. Otherwise, we are in a group/raid but are NOT the master looter.
      return false
    end

    -- OPTIMIZED: Process items with caching and session tracking
    function self:process_items_optimized(filter_actions)
        -- Process shared loot
        local shared_count = mq.TLO.AdvLoot.SCount()
        local is_master = is_master_looter()
        
        if shared_count > 0 and is_master and self.config.char_settings.MasterLoot then
            self.logger:debug("Processing %d shared items in session %s", 
                shared_count, self.current_session_id)
            
            for i = shared_count, 1, -1 do
                local item = mq.TLO.AdvLoot.SList(i)
                if item() then
                    local name = item.Name()
                    
                    -- PERFORMANCE OPTIMIZATION: Skip if already processed this session
                    if self:is_item_processed(name) then
                        self.logger:debug("Skipping already processed item: %s", name)
                        goto continue
                    end
                    
                    -- Check no-drop timer
                    local wait_elapsed = self.state:get_no_drop_wait_time(name, 
                        self.config.settings.no_drop_wait_time or 300)
                    
                    if wait_elapsed and wait_elapsed < (self.config.settings.no_drop_wait_time or 300) then
                        self.logger:debug("No-drop item %s in wait period, skipping", name)
                        self:mark_item_processed(name, "WAIT")
                        goto continue
                    end
                    
                    -- Get action with caching using EXACT PHASE 1-3 LOGIC
                    local action = self:get_cached_action(name, i, true, filter_actions)
                    
                    if action and action ~= "ASK" then
                        -- Queue or execute action
                        if self.waiting_for_loot then
                            -- Queue for later execution
                            table.insert(self.pending_loot_actions, {
                                index = i,
                                action = action,
                                name = name,
                                info = {link = item.Link()},
                                is_shared = true,
                                item_value = self.items:get_item_value(name) or 0
                            })
                            self.logger:info("Queued %s for %s", action, name)
                        else
                            -- Execute immediately via event
                            self.events:publish(self.events.EVENT_TYPES.LOOT_ACTION, {
                                index = i,
                                action = action,
                                name = name,
                                info = {link = item.Link()},
                                is_shared = true,
                                item_value = self.items:get_item_value(name) or 0
                            })
                        end
                        
                        self:mark_item_processed(name, action)
                        return true -- Process one at a time
                    else
                        -- Mark as processed even if no action (e.g., ASK)
                        self:mark_item_processed(name, action or "NO_ACTION")
                    end
                    ::continue::
                end
            end
        end
        
        -- Process personal loot (similar optimization)
        local personal_count = mq.TLO.AdvLoot.PCount()
        if personal_count > 0 then
            self.logger:debug("Processing %d personal items in session %s", 
                personal_count, self.current_session_id)
            
            for i = personal_count, 1, -1 do
                local item = mq.TLO.AdvLoot.PList(i)
                if item() then
                    local name = item.Name()
                    
                    -- PERFORMANCE OPTIMIZATION: Skip if already processed
                    if self:is_item_processed(name) then
                        self.logger:debug("Skipping already processed item: %s", name)
                        goto personal_continue
                    end
                    
                    -- Check no-drop timer
                    local wait_elapsed = self.state:get_no_drop_wait_time(name, 
                        self.config.settings.no_drop_wait_time or 300)
                    
                    if wait_elapsed and wait_elapsed < (self.config.settings.no_drop_wait_time or 300) then
                        self.logger:debug("No-drop item %s in wait period, skipping", name)
                        self:mark_item_processed(name, "WAIT")
                        goto personal_continue
                    end
                    
                    -- Get action with caching using EXACT PHASE 1-3 LOGIC
                    local action = self:get_cached_action(name, i, false, filter_actions)
                    
                    if action and action ~= "ASK" then
                        -- Queue or execute action
                        if self.waiting_for_loot then
                            -- Queue for later execution
                            table.insert(self.pending_loot_actions, {
                                index = i,
                                action = action,
                                name = name,
                                info = {link = item.Link()},
                                is_shared = false,
                                item_value = self.items:get_item_value(name) or 0
                            })
                            self.logger:info("Queued %s for %s", action, name)
                        else
                            -- Execute immediately via event
                            self.events:publish(self.events.EVENT_TYPES.LOOT_ACTION, {
                                index = i,
                                action = action,
                                name = name,
                                info = {link = item.Link()},
                                is_shared = false,
                                item_value = self.items:get_item_value(name) or 0
                            })
                        end
                        
                        self:mark_item_processed(name, action)
                        return true -- Process one at a time
                    else
                        self:mark_item_processed(name, action or "NO_ACTION")
                    end
                    ::personal_continue::
                end
            end
        end
        
        return false
    end
    
    -- Get action with caching layer
    function self:get_cached_action(name, index, is_shared, filter_actions)
        local cache_key = self:get_cache_key(name, is_shared, filter_actions)
        local now = os.time()
        
        -- Check cache first
        if self.decision_cache[cache_key] then
            local cached = self.decision_cache[cache_key]
            if cached.expires_at > now then
                self.stats.cache_hits = self.stats.cache_hits + 1
                self.logger:debug("Cache hit for %s: %s", name, cached.action)
                return cached.action
            else
                -- Cache expired
                self.decision_cache[cache_key] = nil
            end
        end
        
        -- Cache miss, calculate action using EXACT PHASE 1-3 LOGIC
        self.stats.cache_misses = self.stats.cache_misses + 1
        local action = self:get_action_for_item_phases(name, index, is_shared, filter_actions)
        
        -- Cache the decision (valid for 30 seconds)
        if action then
            self.decision_cache[cache_key] = {
                action = action,
                expires_at = now + 30
            }
        end
        
        return action
    end
    
    -- Clear decision cache
    function self:clear_decision_cache()
        self.decision_cache = {}
        self.logger:debug("Decision cache cleared")
    end
    
    -- Log performance statistics
    function self:log_performance_stats()
        local total = self.stats.cache_hits + self.stats.cache_misses
        local hit_rate = total > 0 and (self.stats.cache_hits / total * 100) or 0
        
        self.logger:debug("Performance: Cache hits=%d, misses=%d, rate=%.1f%%", 
            self.stats.cache_hits, self.stats.cache_misses, hit_rate)
        self.logger:debug("Session %s: %d items processed", 
            self.current_session_id or "none", self.stats.session_items)
    end
    
    -- Get action for item using EXACT PHASE 1-3 LOGIC as you specified
    function self:get_action_for_item_phases(name, index, is_shared, filter_actions)
        self.logger:debug("PHASE START for %s (filter: %s)", name, filter_actions and filter_actions[name] or "nil")
        
        -- Get item info first
        local item_info = self.items:get_item_info(name)
        local item_link = item_info and item_info.link or nil
        
        -- PHASE 1: ADVANCED LOOT FILTER (Highest Priority)
        if filter_actions and filter_actions[name] then
            local filter_action = filter_actions[name]
            if filter_action.is_shared == is_shared and filter_action.index == index then
                local advloot_filter = filter_action.action
                
                self.logger:debug("PHASE 1: Filter action: %s", advloot_filter)
                
                if advloot_filter == "Need" or advloot_filter == "Greed" then
                    self.logger:info("PHASE 1: Need/Greed filter -> KEEP")
                    return "KEEP"
                    
                elseif advloot_filter == "Never" or advloot_filter == "No" then
                    self.logger:info("PHASE 1: Never/No filter")
                    
                    -- Step 1: Check INI PassTo Rule
                    local ini_rule = self.items:get_item_rule(name)
                    if ini_rule and ini_rule:find("PassTo") then
                        self.logger:info("  Step 1: INI PassTo rule -> PASS")
                        return self:process_passto_rule(name, ini_rule)
                    end
                    
                    -- Step 2: Check NO DROP Property
                    local is_no_drop = item_info and item_info.no_drop
                    
                    if is_no_drop then
                        self.logger:info("  Step 2: NO DROP -> LEAVE_IN_WINDOW (5min timer)")
                        -- Start 5-minute timer
                        self:start_waiting_period(name, "no_drop_never_filter")
                        return "LEAVE"
                    else
                        self.logger:info("  Step 2: Not NO DROP -> LEAVE_ON_CORPSE")
                        return "LEAVE"
                    end
                end
            end
        end
        
        -- PHASE 2: NO FILTER SET (advloot_filter is nil/blank)
        local ini_rule = self.items:get_item_rule(name)
        
        if ini_rule then
            self.logger:debug("PHASE 2: INI rule exists: %s", ini_rule)
            
            if ini_rule == "CHANGEME" or ini_rule == "ASK" then
                self.logger:info("PHASE 2: Rule is CHANGEME/ASK -> Phase 3")
                -- PHASE 3: Default Logic
                return self:apply_default_logic(name, item_info)
                
            elseif ini_rule:find("PassTo") then
                self.logger:info("PHASE 2: Rule is PassTo -> Process Waterfall")
                return self:process_passto_rule(name, ini_rule)
                
            else
                -- Specific action rule
                self.logger:info("PHASE 2: Specific action -> %s", ini_rule)
                return self:handle_ini_rule(name, {action = ini_rule}, item_info)
            end
        else
            -- No rule exists
            self.logger:info("PHASE 2: No INI rule -> Phase 3")
            return self:apply_default_logic(name, item_info)
        end
    end
    
    -- PHASE 3: DEFAULT LOGIC
    function self:apply_default_logic(item_name, item_info)
        self.logger:info("PHASE 3: Applying default logic for %s", item_name)
        
        local action = "ASK"
        
        if item_info then
            -- Use Item TLO properties as you specified
            if item_info.cash then
                action = "CASH"
                self.logger:info("  CashLoot -> CASH")
                
            elseif item_info.tradeskill then
                -- Check value thresholds
                local item_value = self.items:get_item_value(item_name) or 0
                local threshold = self.config.settings.tradeskill_threshold or 100
                
                if item_value > threshold then
                    action = "TRADESKILL"
                    self.logger:info("  Tradeskill (value %d > %d) -> TRADESKILL", item_value, threshold)
                else
                    action = "SELL"
                    self.logger:info("  Tradeskill (value %d <= %d) -> SELL", item_value, threshold)
                end
                
            elseif item_info.quest then
                action = "QUEST"
                self.logger:info("  Quest -> QUEST")
                
            elseif item_info.no_drop then
                -- Apply global thresholds for NoDrop items
                local item_value = self.items:get_item_value(item_name) or 0
                local keep_threshold = self.config.settings.keep_threshold or 1000
                
                if item_value > keep_threshold then
                    action = "KEEP"
                    self.logger:info("  NoDrop (value %d > %d) -> KEEP", item_value, keep_threshold)
                else
                    action = "DESTROY"
                    self.logger:info("  NoDrop (value %d <= %d) -> DESTROY", item_value, keep_threshold)
                end
                
            else
                -- Regular item, check value
                local item_value = self.items:get_item_value(item_name) or 0
                local keep_threshold = self.config.settings.keep_threshold or 5000
                local sell_threshold = self.config.settings.sell_threshold or 100
                
                if item_value > keep_threshold then
                    action = "KEEP"
                    self.logger:info("  Regular (value %d > %d) -> KEEP", item_value, keep_threshold)
                elseif item_value > sell_threshold then
                    action = "SELL"
                    self.logger:info("  Regular (value %d > %d) -> SELL", item_value, sell_threshold)
                else
                    action = "DESTROY"
                    self.logger:info("  Regular (value %d <= %d) -> DESTROY", item_value, sell_threshold)
                end
            end
        else
            -- Can't inspect item
            action = "ASK"
            self.logger:info("  Can't inspect item -> ASK")
        end
        
        -- Update INI with new permanent rule
        self.items:update_item_rule(item_name, action)
        
        return action
    end
    
    -- Process PassTo rule with quantity-limited waterfall
    function self:process_passto_rule(item_name, rule_value)
        self.logger:debug("Processing PassTo waterfall: %s = %s", item_name, rule_value)
        
        -- Parse rule like "PassTo|PlayerA[5]|PlayerB[5]|"
        local players = {}
        local player_counts = {}
        
        for player, count in rule_value:gmatch("([^|]+)%[(%d+)%]") do
            table.insert(players, player)
            player_counts[player] = tonumber(count)
        end
        
        -- Find first player with remaining passes
        for i, player in ipairs(players) do
            local count = player_counts[player]
            
            if count and count > 0 then
                self.logger:info("  Passing to %s (%d remaining)", player, count)
                
                -- Update rule with decremented count
                local new_count = count - 1
                local old_pattern = player .. "%[" .. count .. "%]"
                local new_entry = player .. "[" .. new_count .. "]"
                
                if new_count == 0 then
                    -- Remove player from rule
                    rule_value = rule_value:gsub(old_pattern .. "|", "")
                    rule_value = rule_value:gsub("|" .. old_pattern, "")
                    
                    -- If rule becomes empty, set to just "PassTo"
                    if rule_value == "PassTo|" then
                        rule_value = "PassTo"
                        self.logger:debug("  All counts exhausted, rule now: PassTo")
                    end
                else
                    rule_value = rule_value:gsub(old_pattern, new_entry)
                    self.logger:debug("  Updated %s count to %d", player, new_count)
                end
                
                -- Update INI
                self.items:update_item_rule(item_name, rule_value)
                
                return "PASS|" .. player
            end
        end
        
        -- If all counts are 0, just pass to first player
        if #players > 0 then
            self.logger:debug("  All counts 0, passing to %s", players[1])
            return "PASS|" .. players[1]
        end
        
        -- Default to leave
        self.logger:debug("  No players in rule, leaving")
        return "LEAVE"
    end
    
    function self:handle_ini_rule(item_name, ini_config, item_info)
        if not ini_config.action then
            return nil
        end
        
        local action_lower = string.lower(ini_config.action)
        
        -- Handle PASS action
        if action_lower == "pass" and ini_config.player_name then
            return "PASS|" .. ini_config.player_name
        end
        
        -- Handle KEEP action - check for Lore items
        if action_lower == "keep" or action_lower == "need" or action_lower == "always" then
            -- Check if item is Lore
            if item_info and item_info.lore then
                local existing_count = self.items.inventory:get_item_count(item_name)
                if existing_count > 0 then
                    self.logger:info("Lore item %s already in inventory, ignoring", item_name)
                    return "IGNORE"
                end
            end
            
            -- Check quantity limit
            if ini_config.limit then
                local current = self.items.inventory:get_item_count(item_name)
                if current >= ini_config.limit then
                    self.logger:info("Quantity limit reached for %s: %d/%d", 
                                   item_name, current, ini_config.limit)
                    return "IGNORE"
                end
            end
            
            return "KEEP"
        end
        
        -- Handle GREED action
        if action_lower == "greed" then
            if item_info and item_info.value and item_info.value >= 1000 then
                return "KEEP"
            else
                return "IGNORE"
            end
        end
        
        -- Handle IGNORE/DESTROY
        if action_lower == "ignore" or action_lower == "destroy" then
            return "IGNORE"
        end
        
        return nil
    end
    
    function self:start_waiting_period(item_name, reason)
        if not self.waiting_items[item_name] then
            local wait_time = self.config.settings.no_drop_wait_time or 300  -- Default 5 minutes
            
            self.logger:info("No-drop item %s (%s), starting %d second wait period", 
                           item_name, reason, wait_time)
            self.waiting_items[item_name] = {
                start_time = os.time(),
                wait_time = wait_time,
                reason = reason
            }
            
            -- Publish event
            self.events:publish(self.events.EVENT_TYPES.NO_DROP_WAIT_START, {
                item = item_name,
                reason = reason,
                wait_time = wait_time
            })
        end
    end
    
    function self:check_waiting_items()
        local now = os.time()
        
        for item_name, wait_data in pairs(self.waiting_items) do
            local elapsed = now - wait_data.start_time
            
            if elapsed >= wait_data.wait_time then
                self.logger:info("Wait period expired for %s (%d seconds). Item will be left on corpse.", 
                               item_name, elapsed)
                
                -- Trigger leave action
                self.events:publish(self.events.EVENT_TYPES.LOOT_ACTION, {
                    index = 0, -- Unknown index
                    action = "LEAVE",
                    name = item_name,
                    info = {},
                    is_shared = true,
                    item_value = 0
                })
                
                -- Remove from waiting list
                self.waiting_items[item_name] = nil
                
                -- Publish event
                self.events:publish(self.events.EVENT_TYPES.NO_DROP_WAIT_EXPIRED, {
                    item = item_name,
                    reason = wait_data.reason,
                    elapsed = elapsed,
                    action = "leave_on_corpse"
                })
            elseif elapsed >= wait_data.wait_time - 60 then  -- 1 minute warning
                self.logger:debug("Item %s: %d seconds remaining in wait period", 
                                item_name, wait_data.wait_time - elapsed)
            end
        end
    end
    
    function self:is_item_waiting(item_name)
        return self.waiting_items[item_name] ~= nil
    end
    
    function self:clear_waiting_items()
        self.waiting_items = {}
        self.pending_loot_actions = {}
        self.waiting_for_loot = false
        self.logger:info("Cleared all waiting items and pending actions")
    end
    
    -- Initialize event handlers on creation
    self:init_event_handlers()
    
    return self
end

return LootLogic