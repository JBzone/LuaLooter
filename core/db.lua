-- db.lua - SQLite helper with PackageMan auto-load and extended API for LuaLooter
local mq = require('mq')

local DB = {}
DB.__index = DB

function DB.new(logger, db_file)
    local self = setmetatable({}, DB)
    self.logger = logger
    self.db_file = db_file or mq.configDir .. "\\LuaLooter.sqlite3"
    self.db = nil
    return self
end

-- Initialize DB and create tables
function DB:init()
    self.logger:info("Initializing SQLite database...")

    local ok, PackageMan = pcall(require, 'mq/PackageMan')
    if not ok then
        self.logger:error("PackageMan not found at mq/PackageMan")
        return false
    end

    local lsqlite3 = PackageMan.Require('lsqlite3')
    if not lsqlite3 then
        self.logger:error("Failed to load lsqlite3")
        return false
    end

    self.db = lsqlite3.open(self.db_file)
    if not self.db then
        self.logger:error("Failed to open SQLite database: %s", self.db_file)
        return false
    end

    self:create_tables()
    self.logger:info("Database ready")
    return true
end

-- Table creation
function DB:create_tables()
    local queries = {
        [[
        CREATE TABLE IF NOT EXISTS settings (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL,
            category TEXT DEFAULT 'general',
            data_type TEXT DEFAULT 'string',
            description TEXT,
            updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        )
        ]],
        [[
        CREATE TABLE IF NOT EXISTS char_settings (
            char_name TEXT,
            key TEXT,
            value TEXT,
            data_type TEXT DEFAULT 'string',
            description TEXT,
            updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            PRIMARY KEY (char_name, key)
        )
        ]],
        [[
        CREATE TABLE IF NOT EXISTS loot_rules (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            item_name TEXT NOT NULL,
            item_id INTEGER,
            action TEXT NOT NULL CHECK(action IN ('keep','sell','destroy','bank','ignore','quest','tribute')),
            priority INTEGER DEFAULT 5,
            min_value INTEGER DEFAULT 0,
            max_value INTEGER DEFAULT 999999,
            stack_size INTEGER DEFAULT 1,
            char_specific BOOLEAN DEFAULT 0,
            char_name TEXT,
            zone_filter TEXT,
            mob_filter TEXT,
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            UNIQUE(item_name, char_name)
        )
        ]],
        [[
        CREATE TABLE IF NOT EXISTS loot_history (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            item_name TEXT NOT NULL,
            item_id INTEGER,
            char_name TEXT,
            action_taken TEXT,
            value INTEGER,
            quantity INTEGER DEFAULT 1,
            zone TEXT,
            mob_name TEXT,
            timestamp TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        )
        ]]
    }

    for _, q in ipairs(queries) do self.db:exec(q) end

    local indexes = {
        "CREATE INDEX IF NOT EXISTS idx_settings_category ON settings(category)",
        "CREATE INDEX IF NOT EXISTS idx_char_settings_name ON char_settings(char_name)",
        "CREATE INDEX IF NOT EXISTS idx_loot_rules_item ON loot_rules(item_name)",
        "CREATE INDEX IF NOT EXISTS idx_loot_rules_char ON loot_rules(char_name)",
        "CREATE INDEX IF NOT EXISTS idx_loot_rules_action ON loot_rules(action)",
        "CREATE INDEX IF NOT EXISTS idx_loot_history_time ON loot_history(timestamp)",
        "CREATE INDEX IF NOT EXISTS idx_loot_history_char ON loot_history(char_name)"
    }

    for _, q in ipairs(indexes) do self.db:exec(q) end
end

-- Generic execute helper
function DB:exec(query, params)
    local stmt = self.db:prepare(query)
    if not stmt then return false end
    if params then
        for i, v in ipairs(params) do stmt:bind(i, v) end
    end
    local success = stmt:step()
    stmt:finalize()
    return success
end

-- Query helper
function DB:query(query, params)
    local rows = {}
    local stmt = self.db:prepare(query)
    if not stmt then return rows end
    if params then
        for i, v in ipairs(params) do stmt:bind(i, v) end
    end
    for row in stmt:nrows() do table.insert(rows, row) end
    stmt:finalize()
    return rows
end

-- Begin transaction
function DB:begin_transaction()
    return self:exec("BEGIN TRANSACTION")
end

-- Commit transaction
function DB:commit_transaction()
    return self:exec("COMMIT")
end

-- Rollback transaction
function DB:rollback_transaction()
    return self:exec("ROLLBACK")
end

-- Set a general setting
function DB:set_setting(key, value, category)
    category = category or "general"
    local data_type = type(value)
    local string_value = tostring(value)

    local stmt = self.db:prepare([[
        INSERT OR REPLACE INTO settings (key, value, category, data_type, updated_at)
        VALUES (?, ?, ?, ?, CURRENT_TIMESTAMP)
    ]])
    if not stmt then return false end
    stmt:bind_values(key, string_value, category, data_type)
    local success = stmt:step()
    stmt:finalize()
    return success
end

-- Set a character-specific setting
function DB:set_char_setting(char_name, key, value)
    local data_type = type(value)
    local string_value = tostring(value)

    local stmt = self.db:prepare([[
        INSERT OR REPLACE INTO char_settings (char_name, key, value, data_type, updated_at)
        VALUES (?, ?, ?, ?, CURRENT_TIMESTAMP)
    ]])
    if not stmt then return false end
    stmt:bind_values(char_name, key, string_value, data_type)
    local success = stmt:step()
    stmt:finalize()
    return success
end

-- Get a general setting
function DB:get_setting(key, default_value)
    local stmt = self.db:prepare("SELECT value, data_type FROM settings WHERE key = ?")
    if not stmt then return default_value end
    stmt:bind_values(key)
    local row = stmt:nrows()()
    stmt:finalize()
    if not row then return default_value end
    if row.data_type == "boolean" then return row.value == "true"
    elseif row.data_type == "number" then return tonumber(row.value)
    else return row.value end
end

-- Get a character-specific setting
function DB:get_char_setting(char_name, key, default_value)
    local stmt = self.db:prepare("SELECT value, data_type FROM char_settings WHERE char_name = ? AND key = ?")
    if not stmt then return default_value end
    stmt:bind_values(char_name, key)
    local row = stmt:nrows()()
    stmt:finalize()
    if not row then return default_value end
    if row.data_type == "boolean" then return row.value == "true"
    elseif row.data_type == "number" then return tonumber(row.value)
    else return row.value end
end

-- Import a general setting from INI
function DB:import_setting(key, value, category)
    local converted_value = value
    if type(value) == "string" then
        local lower = value:lower()
        if lower == "true" then converted_value = true
        elseif lower == "false" then converted_value = false
        elseif tonumber(value) then converted_value = tonumber(value)
        end
    end
    local success = self:set_setting(key, converted_value, category)
    if not success then return false, "Failed to import setting" end
    return true
end

-- Import a character-specific setting from INI
function DB:import_char_setting(char_name, key, value)
    local converted_value = value
    if type(value) == "string" then
        local lower = value:lower()
        if lower == "true" then converted_value = true
        elseif lower == "false" then converted_value = false
        elseif tonumber(value) then converted_value = tonumber(value)
        end
    end
    local success = self:set_char_setting(char_name, key, converted_value)
    if not success then return false, "Failed to import char setting" end
    return true
end

-- Get conversion status for GUI
function DB:get_conversion_status(ini_file)
    local status = {
        converted = false,
        ini_exists = false,
        ini_settings_count = 0,
        db_settings_count = 0,
        db_rules_count = 0
    }

    local file = io.open(ini_file, "r")
    if file then status.ini_exists = true; file:close() end

    local stmt = self.db:prepare("SELECT COUNT(*) AS count FROM settings")
    if stmt then
        for row in stmt:nrows() do status.db_settings_count = row.count or 0 end
        stmt:finalize()
    end

    stmt = self.db:prepare("SELECT COUNT(*) AS count FROM loot_rules")
    if stmt then
        for row in stmt:nrows() do status.db_rules_count = row.count or 0 end
        stmt:finalize()
    end

    status.converted = status.db_settings_count > 0
    return status
end

-- Close DB
function DB:close()
    if self.db then
        self.db:close()
        self.db = nil
        self.logger:info("Database connection closed")
    end
end

return DB
