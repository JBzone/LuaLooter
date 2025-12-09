--[[
DESIGN DECISION: Separate profit tracking from loot logic
WHY: Single responsibility - only tracks profit
     Can export to different formats (CSV, JSON, etc.)
     Easy to add per-session, per-zone, or per-hour stats
--]]

local ProfitService = {}

function ProfitService.new(state, config, logger, events)
    local self = {
        state = state,
        config = config,
        logger = logger,
        events = events,
        
        session_start = os.time(),
        items_looted = 0,
        value_looted = 0,
        cash_looted = 0,
        
        -- NEW: Expanded tracking
        items_destroyed_value = 0,
        items_by_name = {},        -- {item_name = {count = X, total_value = Y, destroyed = Z, passed = A, left = B}}
        items_passed = {},
        items_left = {},
        
        -- Per-hour tracking
        hourly_stats = {}
    }
    
    local function format_money(copper)
        local plat = math.floor(copper / 1000)
        local gold = math.floor((copper % 1000) / 100)
        local silver = math.floor((copper % 100) / 10)
        local cop = copper % 10
        return string.format("\ag%dp \ay%dg \aw%ds \ao%dc\ax", plat, gold, silver, cop)
    end
    
    function self:track_cash(plat, gold, silver, copper)
        local p = tonumber(plat) or 0
        local g = tonumber(gold) or 0
        local s = tonumber(silver) or 0
        local c = tonumber(copper) or 0
        
        local total = (p * 1000) + (g * 100) + (s * 10) + c
        
        if total > 0 then
            self.cash_looted = self.cash_looted + total
            self.events:publish(self.events.EVENT_TYPES.CASH_LOOTED, {
                amount = total,
                breakdown = {plat = p, gold = g, silver = s, copper = c},
                total = self.cash_looted
            })
            
            self.logger:info("Cash loot: +%s (Total: %s)", 
                format_money(total), format_money(self.cash_looted))
        end
    end
    
    function self:track_item(item_name, value)
        if value and value > 0 then
            self.value_looted = self.value_looted + value
            self.items_looted = self.items_looted + 1
            
            -- Track by item name
            if not self.items_by_name[item_name] then
                self.items_by_name[item_name] = {
                    count = 0,
                    total_value = 0,
                    destroyed = 0,
                    passed = 0,
                    left = 0
                }
            end
            self.items_by_name[item_name].count = self.items_by_name[item_name].count + 1
            self.items_by_name[item_name].total_value = self.items_by_name[item_name].total_value + value
            
            self.events:publish(self.events.EVENT_TYPES.LOOT_ITEM, {
                name = item_name,
                value = value,
                items_total = self.items_looted,
                value_total = self.value_looted
            })
            
            self.logger:info("Profit: %s (+%s)", item_name, format_money(value))
        end
    end
    
    -- NEW: Track destroyed item
    function self:track_item_destroyed(item_name, value)
        if value and value > 0 then
            self.items_destroyed_value = self.items_destroyed_value + value
            
            -- Track in items_by_name
            if not self.items_by_name[item_name] then
                self.items_by_name[item_name] = {
                    count = 0,
                    total_value = 0,
                    destroyed = 0,
                    passed = 0,
                    left = 0
                }
            end
            self.items_by_name[item_name].destroyed = (self.items_by_name[item_name].destroyed or 0) + 1
            
            self.events:publish(self.events.EVENT_TYPES.ITEM_DESTROYED, {
                name = item_name,
                value = value,
                destroyed_total = self.items_destroyed_value
            })
            
            self.logger:info("Destroyed: %s (-%s)", item_name, format_money(value))
        end
    end
    
    -- NEW: Track passed item
    function self:track_item_passed(item_name)
        self.items_passed[item_name] = (self.items_passed[item_name] or 0) + 1
        
        -- Track in items_by_name
        if not self.items_by_name[item_name] then
            self.items_by_name[item_name] = {
                count = 0,
                total_value = 0,
                destroyed = 0,
                passed = 0,
                left = 0
            }
        end
        self.items_by_name[item_name].passed = (self.items_by_name[item_name].passed or 0) + 1
        
        self.events:publish(self.events.EVENT_TYPES.ITEM_PASSED, {
            name = item_name,
            passed_total = self.items_passed[item_name]
        })
        
        self.logger:info("Passed: %s", item_name)
    end
    
    -- NEW: Track left item
    function self:track_item_left(item_name)
        self.items_left[item_name] = (self.items_left[item_name] or 0) + 1
        
        -- Track in items_by_name
        if not self.items_by_name[item_name] then
            self.items_by_name[item_name] = {
                count = 0,
                total_value = 0,
                destroyed = 0,
                passed = 0,
                left = 0
            }
        end
        self.items_by_name[item_name].left = (self.items_by_name[item_name].left or 0) + 1
        
        self.events:publish(self.events.EVENT_TYPES.ITEM_LEFT, {
            name = item_name,
            left_total = self.items_left[item_name]
        })
        
        self.logger:info("Left: %s", item_name)
    end
    
    function self:get_stats()
        local run_time = os.difftime(os.time(), self.session_start) / 60  -- minutes
        local net_profit = self.value_looted + self.cash_looted - self.items_destroyed_value
        
        local stats = {
            run_time = run_time,
            items_looted = self.items_looted,
            value_looted = self.value_looted,
            cash_looted = self.cash_looted,
            items_destroyed_value = self.items_destroyed_value,
            net_profit = net_profit,
            total_profit = self.value_looted + self.cash_looted,
            items_passed = self.items_passed,
            items_left = self.items_left,
            items_by_name = self.items_by_name,
            formatted = {
                value = format_money(self.value_looted),
                cash = format_money(self.cash_looted),
                destroyed = format_money(self.items_destroyed_value),
                net_profit = format_money(net_profit),
                total = format_money(self.value_looted + self.cash_looted)
            }
        }
        
        -- Calculate per-hour rates
        if run_time > 0 then
            stats.items_per_hour = (self.items_looted / run_time) * 60
            stats.profit_per_hour = ((self.value_looted + self.cash_looted) / run_time) * 60
            stats.net_profit_per_hour = (net_profit / run_time) * 60
            stats.formatted.profit_per_hour = format_money(stats.profit_per_hour)
            stats.formatted.net_profit_per_hour = format_money(stats.net_profit_per_hour)
        end
        
        -- Calculate item distribution
        local top_items = {}
        for item_name, data in pairs(self.items_by_name) do
            if data.total_value > 0 then
                table.insert(top_items, {
                    name = item_name,
                    count = data.count,
                    total_value = data.total_value,
                    destroyed = data.destroyed or 0,
                    passed = data.passed or 0,
                    left = data.left or 0
                })
            end
        end
        table.sort(top_items, function(a, b) return a.total_value > b.total_value end)
        stats.top_items = top_items
        
        return stats
    end
    
    function self:reset()
        self.session_start = os.time()
        self.items_looted = 0
        self.value_looted = 0
        self.cash_looted = 0
        self.items_destroyed_value = 0
        self.items_by_name = {}
        self.items_passed = {}
        self.items_left = {}
        self.hourly_stats = {}
        
        self.logger:info("Profit stats reset")
        self.events:publish(self.events.EVENT_TYPES.CONFIG_CHANGED, {reset_stats = true})
    end
    
    function self:export(format)
        format = format or "text"
        local stats = self:get_stats()
        
        if format == "text" then
            local text = string.format(
                "Session: %.1f minutes\n" ..
                "Items Looted: %d\n" ..
                "Item Value: %s\n" ..
                "Cash Looted: %s\n" ..
                "Destroyed Value: %s\n" ..
                "Net Profit: %s\n" ..
                "Total Looted: %s\n" ..
                "Items/Hour: %.1f\n" ..
                "Profit/Hour: %s\n" ..
                "Net Profit/Hour: %s",
                stats.run_time, 
                stats.items_looted, 
                stats.formatted.value, 
                stats.formatted.cash,
                stats.formatted.destroyed,
                stats.formatted.net_profit,
                stats.formatted.total,
                stats.items_per_hour or 0, 
                stats.formatted.profit_per_hour or "0p 0g 0s 0c",
                stats.formatted.net_profit_per_hour or "0p 0g 0s 0c"
            )
            
            -- Add top items if any
            if #stats.top_items > 0 then
                text = text .. "\n\nTop Items:"
                for i = 1, math.min(5, #stats.top_items) do
                    local item = stats.top_items[i]
                    text = text .. string.format("\n  %s: %dx (%s)", 
                        item.name, item.count, format_money(item.total_value))
                end
            end
            
            return text
        elseif format == "json" then
            -- Simple JSON serialization
            return string.format(
                '{"run_time":%.1f,"items":%d,"value":%d,"cash":%d,"destroyed":%d,"net_profit":%d,"total":%d}',
                stats.run_time, stats.items_looted, stats.value_looted,
                stats.cash_looted, stats.items_destroyed_value, stats.net_profit, stats.total_profit
            )
        elseif format == "detailed" then
            local detailed = {
                session = {
                    start_time = self.session_start,
                    duration_minutes = stats.run_time
                },
                profit = {
                    items_looted = stats.items_looted,
                    value_looted = stats.value_looted,
                    cash_looted = stats.cash_looted,
                    destroyed_value = stats.items_destroyed_value,
                    net_profit = stats.net_profit,
                    total_looted = stats.total_profit
                },
                rates = {
                    items_per_hour = stats.items_per_hour,
                    profit_per_hour = stats.profit_per_hour,
                    net_profit_per_hour = stats.net_profit_per_hour
                },
                items_by_name = self.items_by_name,
                items_passed = self.items_passed,
                items_left = self.items_left
            }
            
            -- Convert to JSON string (simple implementation)
            local json_parts = {}
            table.insert(json_parts, '"session":{')
            table.insert(json_parts, string.format('"start_time":%d,', detailed.session.start_time))
            table.insert(json_parts, string.format('"duration_minutes":%.1f', detailed.session.duration_minutes))
            table.insert(json_parts, '},')
            
            table.insert(json_parts, '"profit":{')
            table.insert(json_parts, string.format('"items_looted":%d,', detailed.profit.items_looted))
            table.insert(json_parts, string.format('"value_looted":%d,', detailed.profit.value_looted))
            table.insert(json_parts, string.format('"cash_looted":%d,', detailed.profit.cash_looted))
            table.insert(json_parts, string.format('"destroyed_value":%d,', detailed.profit.destroyed_value))
            table.insert(json_parts, string.format('"net_profit":%d,', detailed.profit.net_profit))
            table.insert(json_parts, string.format('"total_looted":%d', detailed.profit.total_looted))
            table.insert(json_parts, '}')
            
            return "{" .. table.concat(json_parts) .. "}"
        end
    end
    
    -- NEW: Register event handlers
    function self:register_event_handlers()
        self.events:subscribe(self.events.EVENT_TYPES.ITEM_LOOTED, function(data)
            self:track_item(data.item_name, data.value)
        end)
        
        self.events:subscribe(self.events.EVENT_TYPES.ITEM_DESTROYED, function(data)
            self:track_item_destroyed(data.item_name, data.value)
        end)
        
        self.events:subscribe(self.events.EVENT_TYPES.ITEM_PASSED, function(data)
            self:track_item_passed(data.item_name)
        end)
        
        self.events:subscribe(self.events.EVENT_TYPES.ITEM_LEFT, function(data)
            self:track_item_left(data.item_name)
        end)
    end
    
    -- Initialize event handlers
    self:register_event_handlers()
    
    return self
end

return ProfitService