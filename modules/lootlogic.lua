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
        }
    }
    
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
        if not self.state:is_enabled() or self.state:is_processing() then
            return
        end
        
        self.state:set_processing(true)
        
        local has_loot = mq.TLO.AdvLoot.SCount() > 0 or mq.TLO.AdvLoot.PCount() > 0
        
        if has_loot then
            -- Generate new session ID if this is first loot detection
            if not self.current_session_id then
                self.current_session_id = self:generate_session_id()
                self.logger:debug("New loot session started: %s", self.current_session_id)
            end
            
            self.events:publish(self.events.EVENT_TYPES.LOOT_START, {})
            
            -- Open window if needed
            if self.config.settings.auto_open_window and 
               not self.config.settings.alpha_mode and
               not mq.TLO.Window("AdvancedLootWnd").Open() then
                mq.cmd('/advloot')
                self.state.window_was_opened = true
                mq.delay(1000)
            end
            
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
        
        self.state:set_processing(false)
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
                    
                    -- Get action with caching
                    local action = self:get_cached_action(name, i, true, filter_actions)
                    
                    if action and action ~= "ASK" then
                        -- Execute with delay between items
                        if i < shared_count then
                            mq.delay(100)
                        end
                        
                        local executed = self:execute_action(i, action, name, true)
                        if executed then
                            self:mark_item_processed(name, action)
                        end
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
                    
                    -- Get action with caching
                    local action = self:get_cached_action(name, i, false, filter_actions)
                    
                    if action and action ~= "ASK" then
                        if i < personal_count then
                            mq.delay(100)
                        end
                        
                        local executed = self:execute_action(i, action, name, false)
                        if executed then
                            self:mark_item_processed(name, action)
                        end
                    else
                        self:mark_item_processed(name, action or "NO_ACTION")
                    end
                    ::personal_continue::
                end
            end
        end
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
        
        -- Cache miss, calculate action
        self.stats.cache_misses = self.stats.cache_misses + 1
        local action = self:get_action_for_item(name, index, is_shared, filter_actions)
        
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
    
    -- Get action for item (ORIGINAL LOGIC WITH MINIMAL CHANGES)
    function self:get_action_for_item(name, index, is_shared, filter_actions)
        -- Get item info first
        local item_info = self.items:get_item_info(name)
        
        -- SPECIAL HANDLING FOR NO-DROP ITEMS
        if item_info and item_info.no_drop then
            -- Check filters first for no-drop items
            if filter_actions and filter_actions[name] then
                local filter_action = filter_actions[name]
                if filter_action.is_shared == is_shared and filter_action.index == index then
                    self.logger:debug("Filter action found for no-drop item %s: %s", name, filter_action.action)
                    
                    -- Never/No filters should already have checked INI for pass rules in filter_to_action
                    -- So we can use the filter action directly
                    if filter_action.action == "KEEP" or filter_action.action == "PASS" then
                        -- Explicit rule to loot or pass no-drop item
                        return filter_action.action
                    elseif filter_action.action == "LEAVE" then
                        -- Never/No filter on no-drop with no pass rule = wait 5 minutes
                        self:start_waiting_period(name, "no_drop_never_filter")
                        return "LEAVE"
                    elseif filter_action.action == "IGNORE" then
                        -- Shouldn't happen for no-drop items with Never/No filter, but handle it
                        self:start_waiting_period(name, "no_drop_filter_ignore")
                        return "LEAVE"
                    end
                end
            end
            
            -- Check INI rules for no-drop items (when no filter)
            local ini_config = self.items:get_ini_config(name)
            if ini_config then
                -- Check if we should use the general section
                if not self.config.char_settings.LootFromGeneralSection then
                    if ini_config.general then
                        self.logger:debug("Skipping general section rule for no-drop item %s", name)
                        ini_config = nil
                    end
                end
                
                if ini_config then
                    self.logger:debug("Found INI config for no-drop item %s", name)
                    local action = self:handle_ini_rule(name, ini_config, item_info)
                    if action then
                        if action == "KEEP" or action:match("^PASS|") then
                            -- Explicit rule to loot or pass no-drop item
                            return action
                        end
                        -- INI says IGNORE for no-drop = wait 5 minutes
                    end
                end
            end
            
            -- No explicit rule to loot/pass no-drop item = wait 5 minutes
            self:start_waiting_period(name, "no_drop_no_explicit_rule")
            return "LEAVE"
        end
        
        -- NORMAL ITEMS (not no-drop)
        
        -- 1. CHECK FILTERS FIRST (PRIORITY)
        if filter_actions and filter_actions[name] then
            local filter_action = filter_actions[name]
            if filter_action.is_shared == is_shared and filter_action.index == index then
                self.logger:debug("Using filter action for %s: %s", name, filter_action.action)
                
                -- For Never/No filters on non-no-drop items, the action will be:
                -- "PASS|playername" if INI has pass rule
                -- "IGNORE" if no pass rule
                return filter_action.action
            end
        end
        
        -- 2. NO FILTER - CHECK INI RULES
        local ini_config = self.items:get_ini_config(name)
        if ini_config then
            -- Check if we should use the general section
            if not self.config.char_settings.LootFromGeneralSection then
                if ini_config.general then
                    self.logger:debug("Skipping general section rule for %s (LootFromGeneralSection=false)", name)
                    ini_config = nil
                end
            end
            
            if ini_config then
                self.logger:debug("Found INI config for %s", name)
                local action = self:handle_ini_rule(name, ini_config, item_info)
                if action then
                    return action
                end
            end
        end
        
        -- 3. NO INI RULE - CHECK ITEM PROPERTIES WITH DEFAULT BEHAVIOR
        return self:determine_action(name, nil, item_info, 0)
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
    
    function self:determine_action(name, ini_config, item_info, depth)
        -- If we're too deep in recursion, default to ignore
        if depth > 10 then
            self.logger:warn("Recursion depth exceeded for: %s, defaulting to IGNORE", name)
            return "IGNORE"
        end
        
        -- Check if item is no-drop (SPECIAL CASE - always wait unless explicit rule)
        if item_info and item_info.no_drop then
            -- No filter, no INI rule for no-drop item = ALWAYS wait 5 minutes
            self:start_waiting_period(name, "no_drop_no_rule")
            return "LEAVE"
        end
        
        -- Check if item is Lore
        if item_info and item_info.lore then
            local existing_count = self.items.inventory:get_item_count(name)
            if existing_count > 0 then
                self.logger:info("Lore item %s already in inventory, ignoring", name)
                return "IGNORE"
            end
        end
        
        -- DEFAULT BEHAVIOR BASED ON CONFIG SETTINGS
        if item_info then
            -- Check for cash/coin items
            if item_info.cash and self.config.char_settings.AutoLootCash then
                self.logger:info("Auto-looting cash item: %s", name)
                return "KEEP"
            end
            
            -- Check for quest items (LOOT REGARDLESS OF VALUE)
            if item_info.quest and self.config.char_settings.AutoLootQuest then
                self.logger:info("Auto-looting quest item: %s", name)
                return "KEEP"
            end
            
            -- Check for collectible items
            if item_info.collectible and self.config.char_settings.AutoLootCollectible then
                self.logger:info("Auto-looting collectible item: %s", name)
                return "KEEP"
            end
            
            -- Check for tradeskill items
            if item_info.tradeskill then
                if self.config.char_settings.AlwaysLootTradeskills then
                    self.logger:info("Auto-looting tradeskill item: %s", name)
                    return "KEEP"
                else
                    local keep_tradeskill = self.config.settings.keep_tradeskill_items or false
                    if keep_tradeskill then
                        self.logger:info("Tradeskill item detected: %s (keeping)", name)
                        return "KEEP"
                    else
                        self.logger:info("Tradeskill item detected: %s (ignoring)", name)
                        return "IGNORE"
                    end
                end
            end
            
            -- Check item value for general items
            if item_info.value then
                local min_value = self.config.char_settings.LootValue or 0
                if item_info.value >= min_value then
                    self.logger:debug("Item %s value %d >= min %d, keeping", name, item_info.value, min_value)
                    return "KEEP"
                else
                    -- Check if we should loot trash items
                    if self.config.char_settings.LootTrash then
                        self.logger:debug("Looting trash item: %s (value: %d)", name, item_info.value)
                        return "KEEP"
                    else
                        self.logger:debug("Item %s value %d < min %d, ignoring", name, item_info.value, min_value)
                        return "IGNORE"
                    end
                end
            end
        end
        
        -- Default action if nothing matched
        local default_action = "IGNORE"  -- Default to ignore for safety
        self.logger:debug("No specific rule matched for %s, defaulting to: %s", name, default_action)
        return default_action
    end
    
    function self:execute_action(index, action, name, is_shared)
        -- Parse action string (could be "PASS|Playername")
        local action_parts = {}
        for part in string.gmatch(action, "[^|]+") do
            table.insert(action_parts, part)
        end
        
        local base_action = action_parts[1]
        local target_player = action_parts[2]
        
        -- Check if we're already processing - wait a bit if we are
        if self.state:is_processing() then
            self.logger:debug("Waiting for previous loot to complete...")
            mq.delay(500)
        end
        
        -- Set processing flag
        self.state:set_processing(true)
        
        -- Create a unique key for this loot attempt
        local npc_id = mq.TLO.Target.ID() or 0
        local item_key = string.format("%d_%s_%d", npc_id, name, os.time())
        
        -- Check if we should attempt this loot (prevent spam)
        local now = os.time()
        local attempts = self.state.loot_attempts[item_key] or {count = 0, last_attempt = 0}
        
        -- Reset counter if it's been more than 10 seconds
        if now - attempts.last_attempt > 10 then
            attempts.count = 0
        end
        
        attempts.count = attempts.count + 1
        attempts.last_attempt = now
        
        -- Save back to state
        self.state.loot_attempts[item_key] = attempts
        
        -- If we've tried this item 3 times in 10 seconds, skip it
        if attempts.count > 3 then
            self.logger:warn("Skipping %s - too many attempts (NPC: %d)", name, npc_id)
            self.state:set_processing(false)
            return false
        end
        
        -- Execute the command
        local command = nil
        if base_action == "KEEP" then
            if is_shared then
                command = string.format('/advloot shared %d giveto %s', index, mq.TLO.Me.Name())
            else
                command = string.format('/advloot personal %d loot', index)
            end
            self.logger:info("KEEPING %s (shared: %s, NPC: %d)", name, tostring(is_shared), npc_id)
            
        elseif base_action == "IGNORE" then
            if is_shared then
                command = string.format('/advloot shared %d leave', index)
            else
                command = string.format('/advloot personal %d never', index)
            end
            self.logger:info("IGNORING %s (shared: %s, NPC: %d)", name, tostring(is_shared), npc_id)
            
        elseif base_action == "PASS" and target_player then
            if is_shared then
                command = string.format('/advloot shared %d giveto %s', index, target_player)
                self.logger:info("PASSING %s to %s (NPC: %d)", name, target_player, npc_id)
            else
                -- Can't pass personal loot
                self.logger:warn("Cannot pass personal loot item: %s, keeping instead (NPC: %d)", name, npc_id)
                command = string.format('/advloot personal %d loot', index)
            end
            
        elseif base_action == "LEAVE" then
            -- For "LEAVE" action on no-drop items, DO NOT issue any command
            if is_shared then
                self.logger:info("LEAVING %s in loot window (no-drop item, NPC: %d, will expire in 5 min)", name, npc_id)
                self.state:set_processing(false)
                return true  -- No command, item stays in window
            else
                self.logger:info("LEAVING %s in window (personal, no-drop waiting period, NPC: %d)", name, npc_id)
                self.state:set_processing(false)
                return true  -- No command executed
            end
            
        else
            self.logger:warn("Unknown action: %s for %s, ignoring (NPC: %d)", action, name, npc_id)
            if is_shared then
                command = string.format('/advloot shared %d leave', index)
            else
                command = string.format('/advloot personal %d never', index)
            end
        end
        
        if command then
            -- In alpha mode, just log
            if self.config.settings.alpha_mode then
                self.logger:info("[ALPHA] Would execute: %s", command)
                self.state:set_processing(false)
                return true
            end
            
            -- Production mode - actually execute (with proper delay)
            self.logger:debug("Executing command: %s", command)
            mq.delay(500)  -- CRITICAL: 500ms delay for command to process
            mq.cmd(command)
            
            -- Clear processing flag
            self.state:set_processing(false)
            
            self.logger:info("Looted: %s (%s, NPC: %d)", name, action, npc_id)
            return true
        end
        
        -- Clear processing flag if we didn't execute a command
        self.state:set_processing(false)
        return false
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
        self.logger:info("Cleared all waiting items")
    end
    
    return self
end

return LootLogic