--[[
DESIGN DECISION: Separate entry point from main logic
WHY: Allows for different initialization paths (GUI mode, CLI mode, test mode)
     Makes it easy to add pre-init checks, dependency validation, or alternative entry points
--]]

local mq = require('mq')

-- Check for required TLOs
if not mq.TLO.AdvLoot then
    print("\arERROR: MQ2AdvLoot plugin not loaded!")
    print("\arPlease load plugin with: /plugin mq2advloot")
    return
end

-- Load and run the main looter
local Looter = require('main')
local looter = Looter.new()

-- Start the looter
looter:run()