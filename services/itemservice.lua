--[[
DESIGN DECISION: Centralized item information service
WHY: Caches item lookups to improve performance
     Single point for item data transformation
     Easy to add item database or external API lookups (future)
--]]

local mq = require('mq')

local ItemService = {}

function ItemService.new(config, logger, ini_service)
    local self = {
        config = config,
        logger = logger,
        ini = ini_service,
        cache = {},  -- Cache item lookups
        cache_ttl = 60  -- Cache for 60 seconds
    }
    
    function self:get_item_info(name, force_refresh)
        if not name or name == "" then return nil end
        
        -- Check cache
        if not force_refresh and self.cache[name] then
            local cached = self.cache[name]
            if os.time() - cached.timestamp < self.cache_ttl then
                self.logger:debug("Cache hit for: %s", name)
                return cached.data
            end
        end
        
        self.logger:debug("Getting item info for: %s", name)
        
        -- Check for cash loot
        local cash_info = self:parse_cash_name(name)
        if cash_info then
            self.cache[name] = {
                data = cash_info,
                timestamp = os.time()
            }
            return cash_info
        end
        
        -- Try to find item in various locations
        local item = self:find_item(name)
        if item then
            self.cache[name] = {
                data = item,
                timestamp = os.time()
            }
            return item
        end
        
        -- Unknown item
        self.logger:warn("Could not find item details for: %s", name)
        local unknown = {
            name = name,
            value = 0,
            no_drop = false,
            stackable = false,
            cash_loot = false,
            tradeskills = false,
            lore = false,
            quest = false,
            collectible = false,
            id = 0
        }
        
        self.cache[name] = {
            data = unknown,
            timestamp = os.time()
        }
        
        return unknown
    end
    
    function self:parse_cash_name(name)
        if name:find("Platinum") or name:find("Gold") or name:find("Silver") or name:find("Copper") or
           name:find("pp") or name:find("gp") or name:find("sp") or name:find("cp") then
            
            local plat, gold, silver, copper
            
            plat, gold, silver, copper = name:match("(%d+) Platinum, (%d+) Gold, (%d+) Silver, (%d+) Copper")
            if not plat then
                plat, gold, silver, copper = name:match("(%d+) pp, (%d+) gp, (%d+) sp, (%d+) cp")
            end
            if not plat then
                plat, gold, silver, copper = name:match("(%d+)p (%d+)g (%d+)s (%d+)c")
            end
            
            plat = tonumber(plat) or 0
            gold = tonumber(gold) or 0
            silver = tonumber(silver) or 0
            copper = tonumber(copper) or 0
            
            local cash_value = (plat * 1000) + (gold * 100) + (silver * 10) + copper
            
            return {
                name = name,
                value = cash_value,
                cash_loot = true,
                no_drop = false,
                stackable = true,
                tradeskills = false,
                lore = false,
                quest = false,
                collectible = false,
                id = 0
            }
        end
        
        return nil
    end
    
    function self:find_item(name)
        -- Try inventory
        local item = mq.TLO.FindItem("=" .. name)
        if item() then
            return self:item_to_info(item, name)
        end
        
        -- Try cursor
        if mq.TLO.Cursor.Name() == name then
            return self:item_to_info(mq.TLO.Cursor, name)
        end
        
        -- Try display item
        if mq.TLO.DisplayItem.Name() == name then
            return self:item_to_info(mq.TLO.DisplayItem, name)
        end
        
        return nil
    end
    
    function self:item_to_info(item_obj, name)
        return {
            name = item_obj.Name(),
            value = item_obj.Value() or 0,
            no_drop = item_obj.NoDrop(),
            stackable = item_obj.Stackable(),
            cash_loot = item_obj.CashLoot(),
            tradeskills = item_obj.Tradeskills(),
            lore = item_obj.Lore(),
            quest = item_obj.Quest(),
            collectible = item_obj.Collectible(),
            id = item_obj.ID()
        }
    end
    
    function self:get_ini_config(item_name)
        local first_char = string.sub(item_name, 1, 1)
        return {
            general = self.ini:get_item_rule(item_name, first_char),
            personal = self.ini:get_item_rule(item_name, mq.TLO.Me.Name()),
            quest = self.ini:get_item_rule(item_name, "Quests")
        }
    end
    
    function self:get_item_count(item_name)
        local item = mq.TLO.FindItem("=" .. item_name)
        if item() then
            return item.StackCount() or 0
        end
        return 0
    end
    
    function self:clear_cache()
        self.cache = {}
        self.logger:debug("Item cache cleared")
    end
    
    return self
end

return ItemService