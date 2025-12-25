-- db.lua - FIXED VERSION with type conversion fixes
local mq = require('mq')

local DB = {}
DB.__index = DB

function DB.new(logger, db_file)
    local self = setmetatable({}, DB)
    self.logger = logger
    self.db_file = db_file or mq.configDir .. "\\LuaLooter.sqlite3"
    self.db = nil
    self.initialized = false
    self.lsqlite3 = nil
    return self
end

-- SAFE logging - SIMPLIFIED
function DB:safe_log(level, msg, ...)
    -- Check if we have varargs
    local args = {...}
    local formatted = "[DB] " .. msg
    
    if #args > 0 then
        formatted = string.format("[DB] " .. msg, ...)
    end
    
    -- Console output only (skip logger to avoid recursion)
    if level == "error" then
        print("\ar" .. formatted .. "\ax")
    elseif level == "warn" then
        print("\ay" .. formatted .. "\ax")
    else
        print(formatted)
    end
end

-- Check if ready
function DB:is_ready()
    return self.db ~= nil
end

-- Initialize DB
function DB:init()
    if self.db and self.initialized then
        return true
    end
    
    self:safe_log("info", "Initializing SQLite database at: %s", self.db_file)
    
    -- Load PackageMan
    local PackageMan = require('mq/PackageMan')
    if not PackageMan then
        self:safe_log("error", "Failed to load PackageMan")
        return false
    end
    
    -- Load lsqlite3
    self.lsqlite3 = PackageMan.Require('lsqlite3')
    if not self.lsqlite3 then
        self:safe_log("error", "Failed to load lsqlite3")
        return false
    end
    
    -- Open database
    self.db = self.lsqlite3.open(self.db_file)
    if not self.db then
        self:safe_log("error", "Failed to open database: %s", self.db_file)
        return false
    end
    
    self:safe_log("debug", "Database opened successfully")
    
    -- Create tables
    if not self:create_tables() then
        self:safe_log("error", "Failed to create tables")
        self.db:close()
        self.db = nil
        return false
    end
    
    self.initialized = true
    self:safe_log("info", "Database initialization complete")
    return true
end

-- Table creation
function DB:create_tables()
    if not self.db then
        self:safe_log("error", "No database connection")
        return false
    end
    
    local queries = {
        [[
        CREATE TABLE IF NOT EXISTS settings (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        )
        ]],
        [[
        CREATE TABLE IF NOT EXISTS char_settings (
            char_name TEXT,
            key TEXT,
            value TEXT,
            PRIMARY KEY (char_name, key)
        )
        ]]
    }
    
    for i, query in ipairs(queries) do
        local stmt = self.db:prepare(query)
        if stmt then
            stmt:step()
            stmt:finalize()
        else
            self:safe_log("error", "Failed to prepare table query %d", i)
            return false
        end
    end
    
    return true
end

-- get_setting - IMPROVED with proper type conversion
function DB:get_setting(key, default_value)
    if not self:is_ready() then
        return default_value
    end
    
    local stmt = self.db:prepare("SELECT value FROM settings WHERE key = ?")
    if not stmt then
        return default_value
    end
    
    stmt:bind_values(key)
    
    local db_value = default_value
    for row in stmt:nrows() do
        db_value = row.value
        break
    end
    
    stmt:finalize()
    
    -- CRITICAL FIX: Type conversion based on default_value type
    if db_value ~= nil then
        if type(default_value) == "number" then
            -- Convert string to number for numeric defaults
            local num = tonumber(db_value)
            return num or default_value
        elseif type(default_value) == "boolean" then
            -- Convert string to boolean for boolean defaults
            if db_value == "true" or db_value == "1" then
                return true
            elseif db_value == "false" or db_value == "0" then
                return false
            else
                return default_value
            end
        else
            -- For string defaults, return as-is
            return db_value
        end
    end
    
    return default_value
end

-- set_setting - ADDED TYPE HANDLING
function DB:set_setting(key, value, category)
    if not self:is_ready() then
        return false
    end
    
    local str_value
    if type(value) == "boolean" then
        str_value = value and "true" or "false"
    elseif type(value) == "number" then
        str_value = tostring(value)
    else
        str_value = tostring(value)
    end
    
    local stmt = self.db:prepare("INSERT OR REPLACE INTO settings (key, value) VALUES (?, ?)")
    if not stmt then
        return false
    end
    
    stmt:bind_values(key, str_value)
    stmt:step()
    stmt:finalize()
    
    return true
end

-- get_char_setting - ADDED TYPE CONVERSION
function DB:get_char_setting(char_name, key, default_value)
    if not self:is_ready() then
        return default_value
    end
    
    local stmt = self.db:prepare("SELECT value FROM char_settings WHERE char_name = ? AND key = ?")
    if not stmt then
        return default_value
    end
    
    stmt:bind_values(char_name, key)
    
    local value = default_value
    for row in stmt:nrows() do
        value = row.value
        break
    end
    
    stmt:finalize()
    
    -- TYPE CONVERSION
    if type(default_value) == "number" and value ~= nil then
        local num = tonumber(value)
        return num or default_value
    elseif type(default_value) == "boolean" and value ~= nil then
        if value == "true" or value == "1" then
            return true
        elseif value == "false" or value == "0" then
            return false
        end
    end
    
    return value
end

-- set_char_setting - ADDED TYPE HANDLING
function DB:set_char_setting(char_name, key, value)
    if not self:is_ready() then
        return false
    end
    
    local str_value
    if type(value) == "boolean" then
        str_value = value and "true" or "false"
    elseif type(value) == "number" then
        str_value = tostring(value)
    else
        str_value = tostring(value)
    end
    
    local stmt = self.db:prepare("INSERT OR REPLACE INTO char_settings (char_name, key, value) VALUES (?, ?, ?)")
    if not stmt then
        return false
    end
    
    stmt:bind_values(char_name, key, str_value)
    stmt:step()
    stmt:finalize()
    
    return true
end

-- exec
function DB:exec(query, params)
    if not self:is_ready() then
        return false
    end
    
    local stmt = self.db:prepare(query)
    if not stmt then
        return false
    end
    
    if params then
        for i, v in ipairs(params) do
            stmt:bind(i, v)
        end
    end
    
    stmt:step()
    stmt:finalize()
    return true
end

-- query
function DB:query(query, params)
    local rows = {}
    
    if not self:is_ready() then
        return rows
    end
    
    local stmt = self.db:prepare(query)
    if not stmt then
        return rows
    end
    
    if params then
        for i, v in ipairs(params) do
            stmt:bind(i, v)
        end
    end
    
    for row in stmt:nrows() do
        table.insert(rows, row)
    end
    
    stmt:finalize()
    return rows
end

-- Transaction methods
function DB:begin_transaction()
    return self:exec("BEGIN TRANSACTION")
end

function DB:commit_transaction()
    return self:exec("COMMIT")
end

function DB:rollback_transaction()
    return self:exec("ROLLBACK")
end

-- Import methods
function DB:import_setting(key, value, category)
    if not self:is_ready() then
        return false, "Database not ready"
    end
    
    local success = self:set_setting(key, value, category)
    return success, success and "Success" or "Failed"
end

function DB:import_char_setting(char_name, key, value)
    if not self:is_ready() then
        return false, "Database not ready"
    end
    
    local success = self:set_char_setting(char_name, key, value)
    return success, success and "Success" or "Failed"
end

-- Get conversion status
function DB:get_conversion_status(ini_file)
    local status = {
        converted = false,
        ini_exists = false,
        ini_settings_count = 0,
        db_settings_count = 0,
        db_rules_count = 0,
        db_ready = self:is_ready()
    }
    
    if ini_file then
        local file = io.open(ini_file, "r")
        if file then
            status.ini_exists = true
            file:close()
        end
    end
    
    if self:is_ready() then
        local stmt = self.db:prepare("SELECT COUNT(*) as count FROM settings")
        if stmt then
            for row in stmt:nrows() do
                status.db_settings_count = row.count or 0
                status.converted = status.db_settings_count > 0
            end
            stmt:finalize()
        end
    end
    
    return status
end

-- Close
function DB:close()
    if self.db then
        self.db:close()
        self.db = nil
        self.initialized = false
    end
    return true
end

-- Stats method
function DB:get_stats()
    return {
        db_connected = (self.db ~= nil),
        initialized = self.initialized,
        file = self.db_file
    }
end

return DB