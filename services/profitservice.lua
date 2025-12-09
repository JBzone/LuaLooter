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
            
            self.events:publish(self.events.EVENT_TYPES.LOOT_ITEM, {
                name = item_name,
                value = value,
                items_total = self.items_looted,
                value_total = self.value_looted
            })
            
            self.logger:info("Profit: %s (+%s)", item_name, format_money(value))
        end
    end
    
    function self:get_stats()
        local run_time = os.difftime(os.time(), self.session_start) / 60  -- minutes
        
        local stats = {
            run_time = run_time,
            items_looted = self.items_looted,
            value_looted = self.value_looted,
            cash_looted = self.cash_looted,
            total_profit = self.value_looted + self.cash_looted,
            formatted = {
                value = format_money(self.value_looted),
                cash = format_money(self.cash_looted),
                total = format_money(self.value_looted + self.cash_looted)
            }
        }
        
        -- Calculate per-hour rates
        if run_time > 0 then
            stats.items_per_hour = (self.items_looted / run_time) * 60
            stats.profit_per_hour = ((self.value_looted + self.cash_looted) / run_time) * 60
            stats.formatted.profit_per_hour = format_money(stats.profit_per_hour)
        end
        
        return stats
    end
    
    function self:reset()
        self.session_start = os.time()
        self.items_looted = 0
        self.value_looted = 0
        self.cash_looted = 0
        self.hourly_stats = {}
        
        self.logger:info("Profit stats reset")
        self.events:publish(self.events.EVENT_TYPES.CONFIG_CHANGED, {reset_stats = true})
    end
    
    function self:export(format)
        format = format or "text"
        local stats = self:get_stats()
        
        if format == "text" then
            return string.format(
                "Session: %.1f minutes\nItems: %d\nItem Value: %s\nCash: %s\nTotal: %s\nItems/Hour: %.1f\nProfit/Hour: %s",
                stats.run_time, stats.items_looted, stats.formatted.value, 
                stats.formatted.cash, stats.formatted.total,
                stats.items_per_hour or 0, stats.formatted.profit_per_hour or "0p 0g 0s 0c"
            )
        elseif format == "json" then
            -- Simple JSON serialization
            return string.format(
                '{"run_time":%.1f,"items":%d,"value":%d,"cash":%d,"total":%d}',
                stats.run_time, stats.items_looted, stats.value_looted,
                stats.cash_looted, stats.total_profit
            )
        end
    end
    
    return self
end

return ProfitService