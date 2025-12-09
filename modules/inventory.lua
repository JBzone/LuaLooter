--[[
DESIGN DECISION: Separate inventory concerns
WHY: Bag management is a distinct concern from loot decisions
     Can add advanced features like bag sorting, consolidation
     Easy to support different inventory systems or expansions
--]]

local mq = require('mq')

local Inventory = {}

function Inventory.new(state, config, logger, events)
    local self = {
        state = state,
        config = config,
        logger = logger,
        events = events
    }
    
    function self:get_free_slots()
        return mq.TLO.Me.FreeInventory() or 0
    end
    
    function self:has_space_for_item(item_name, save_slots)
        save_slots = save_slots or self.config.char_settings.SaveSlots
        
        if self:get_free_slots() > save_slots then
            return true
        end
        
        -- Check if we can stack
        local existing = mq.TLO.FindItem("=" .. item_name)
        if existing() and existing.Stackable() then
            local current = existing.StackCount() or 0
            local max = existing.StackSize() or 0
            
            if current < max then
                return true
            end
        end
        
        return false
    end
    
    function self:get_item_count(item_name)
        local item = mq.TLO.FindItem("=" .. item_name)
        if item() then
            return item.StackCount() or 0
        end
        return 0
    end
    
    function self:check_quantity_limit(item_name, limit)
        if not limit then return false end
        
        local current = self:get_item_count(item_name)
        if current >= limit then
            self.logger:debug("Quantity limit reached for %s: %d/%d", item_name, current, limit)
            return true
        end
        
        return false
    end
    
    function self:consolidate_stacks()
        -- Future feature: auto-consolidate stackable items
        self.logger:debug("Stack consolidation not yet implemented")
        return false
    end
    
    function self:get_bag_summary()
        local summary = {
            total_slots = mq.TLO.Me.NumBagSlots() or 0,
            free_slots = self:get_free_slots(),
            used_slots = 0,
            bags = {}
        }
        
        summary.used_slots = summary.total_slots - summary.free_slots
        
        -- Count items by type
        summary.item_types = {
            tradeskill = 0,
            quest = 0,
            collectible = 0,
            sellable = 0,
            other = 0
        }
        
        return summary
    end
    
    return self
end

return Inventory