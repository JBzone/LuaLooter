-- db.lua - SQLite helper with full error handling and safety
local mq = require('mq')

local DB = {}
DB.__index = DB

function DB.new(logger, db_file)
    local self = setmetatable({}, DB)
    self.logger = logger
    self.db_file = db_file or mq.configDir .. "\\LuaLooter.sqlite3"
    self.db = nil
    self.initialized = false
    return self
end

-- Safe logging helper (NEVER crash if logger issues)
function DB:safe_log(level, msg, ...)
    local args = {...}
    if self.logger and self.logger[level] then
        local success, err = pcall(function()
            self.logger[level](self.logger, msg, unpack(args))
        end)
        if not success and level == "error" then
            -- Fallback to console for critical errors
            print(string.format("\ar[DB ERROR] " .. msg .. "\ax", unpack(args)))
        end
    elseif level == "error" or level == "warn" then
        -- Basic console fallback
        local formatted = string.format("[DB %s] " .. msg, string.upper(level), unpack(args))
        if level == "error" then
            print("\ar" .. formatted .. "\ax")
        elseif level == "warn" then
            print("\ay" .. formatted .. "\ax")
        else
            print(formatted)
        end
    end
end

-- Check if database is ready for operations
function DB:is_ready()
  local ready = (self.db ~= nil)
  self:safe_log("debug", "is_ready() = %s (db: %s, initialized: %s)", 
                tostring(ready), tostring(self.db), tostring(self.initialized))
  return ready
end

-- Initialize DB and create tables
function DB:init()
  if self.initialized and self.db then
      self:safe_log("debug", "Database already initialized")
      return true
  end
  
  self:safe_log("info", "Initializing SQLite database at: %s", self.db_file)
  
  -- Step 1: Try to load PackageMan
  local ok, PackageMan = pcall(require, 'mq/PackageMan')
  if not ok then
      self:safe_log("error", "PackageMan not found at mq/PackageMan")
      self:safe_log("error", "Make sure you're running inside MacroQuest2")
      return false
  end
  
  -- Step 2: Try to load lsqlite3
  local lsqlite3 = PackageMan.Require('lsqlite3')
  if not lsqlite3 then
      self:safe_log("error", "Failed to load lsqlite3")
      self:safe_log("error", "Try: /lua require('mq/PackageMan').Install('lsqlite3')")
      return false
  end
  
  -- Step 3: Try to open/create database file with error details
  self:safe_log("debug", "Attempting to open database file: %s", self.db_file)
  
  -- Check if directory exists
  local path = self.db_file:match("^(.*[\\/])")
  if path then
      self:safe_log("debug", "Database directory: %s", path)
      -- Note: Can't check directory in Lua without extra code, but good for logging
  end
  
  -- Try to open with error capture
  local db, err = lsqlite3.open(self.db_file)
  if not db then
      self:safe_log("error", "FAILED to open SQLite database")
      self:safe_log("error", "Path: %s", self.db_file)
      self:safe_log("error", "SQLite error: %s", tostring(err))
      self:safe_log("error", "Possible fixes:")
      self:safe_log("error", "1. Check file/directory permissions")
      self:safe_log("error", "2. Try a different path (e.g., C:\\temp\\LuaLooter.sqlite3)")
      self:safe_log("error", "3. Close any program using the file")
      return false
  end
  
  self.db = db
  self:safe_log("debug", "Database opened successfully")
  
  -- Step 4: Set PRAGMA options
  self.db:exec("PRAGMA foreign_keys = ON")
  self.db:exec("PRAGMA journal_mode = WAL")
  self.db:exec("PRAGMA synchronous = NORMAL")
  
  -- Step 5: Create tables
  if not self:create_tables() then
      self:safe_log("error", "Failed to create database tables")
      self.db:close()
      self.db = nil
      return false
  end
  
  self.initialized = true
  self:safe_log("info", "Database initialization COMPLETE")
  return true
end

-- Table creation with error handling
function DB:create_tables()
  self:safe_log("debug", "create_tables() called")
  self:safe_log("debug", "self.db = %s", tostring(self.db))
  self:safe_log("debug", "self.initialized = %s", tostring(self.initialized))
  
  -- Don't use is_ready() here - it might be misleading
  if not self.db then
      self:safe_log("error", "Cannot create tables: self.db is nil!")
      self:safe_log("error", "This means lsqlite3.open() failed or db was closed")
      return false
  end
  
  -- Test if database connection actually works
  self:safe_log("debug", "Testing database connection with simple query...")
  local test_stmt = self.db:prepare("SELECT 1 as test")
  if not test_stmt then
      self:safe_log("error", "Database connection test FAILED - cannot prepare statement")
      self:safe_log("error", "Database file may be corrupted or locked")
      return false
  end
  
  test_stmt:finalize()
  self:safe_log("debug", "Database connection test PASSED")
  
  -- Now create tables
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

  self:safe_log("debug", "Creating %d tables...", #queries)
  
  for i, q in ipairs(queries) do
      self:safe_log("debug", "Creating table %d/%d...", i, #queries)
      local stmt = self.db:prepare(q)
      if not stmt then
          self:safe_log("error", "FAILED to prepare table creation query %d", i)
          self:safe_log("error", "Query: %s", q)
          return false
      end
      
      local success, err = pcall(function()
          return stmt:step()
      end)
      
      stmt:finalize()
      
      if not success then
          self:safe_log("error", "FAILED to execute table creation query %d", i)
          self:safe_log("error", "Error: %s", tostring(err))
          self:safe_log("error", "Query: %s", q)
          return false
      end
  end

  -- Create indexes
  local indexes = {
      "CREATE INDEX IF NOT EXISTS idx_settings_category ON settings(category)",
      "CREATE INDEX IF NOT EXISTS idx_char_settings_name ON char_settings(char_name)",
      "CREATE INDEX IF NOT EXISTS idx_loot_rules_item ON loot_rules(item_name)",
      "CREATE INDEX IF NOT EXISTS idx_loot_rules_char ON loot_rules(char_name)",
      "CREATE INDEX IF NOT EXISTS idx_loot_rules_action ON loot_rules(action)",
      "CREATE INDEX IF NOT EXISTS idx_loot_history_time ON loot_history(timestamp)",
      "CREATE INDEX IF NOT EXISTS idx_loot_history_char ON loot_history(char_name)"
  }

  self:safe_log("debug", "Creating %d indexes...", #indexes)
  
  for i, q in ipairs(indexes) do
      self:safe_log("debug", "Creating index %d/%d...", i, #indexes)
      local stmt = self.db:prepare(q)
      if stmt then
          pcall(function() stmt:step() end)
          stmt:finalize()
      else
          self:safe_log("warn", "Failed to create index (non-critical): %s", q)
      end
  end
  
  self:safe_log("info", "Database tables created successfully")
  return true
end

-- Generic execute helper with full error handling
function DB:exec(query, params)
    if not self:is_ready() then
        self:safe_log("error", "Cannot execute query: database not ready")
        return false
    end
    
    local stmt, err = self.db:prepare(query)
    if not stmt then 
        self:safe_log("error", "Failed to prepare statement: %s", query)
        if err then
            self:safe_log("debug", "Prepare error: %s", tostring(err))
        end
        return false 
    end
    
    if params then
        for i, v in ipairs(params) do 
            local success = stmt:bind(i, v)
            if not success then
                self:safe_log("warn", "Failed to bind parameter %d: %s", i, tostring(v))
            end
        end
    end
    
    local success, step_err = pcall(function()
        return stmt:step()
    end)
    
    stmt:finalize()
    
    if not success then
        self:safe_log("error", "Failed to execute statement: %s", query)
        if step_err then
            self:safe_log("debug", "Step error: %s", tostring(step_err))
        end
        return false
    end
    
    return true
end

-- Query helper with full error handling
function DB:query(query, params)
    local rows = {}
    
    if not self:is_ready() then
        self:safe_log("error", "Cannot query: database not ready")
        return rows
    end
    
    local stmt, err = self.db:prepare(query)
    if not stmt then 
        self:safe_log("error", "Failed to prepare query: %s", query)
        if err then
            self:safe_log("debug", "Prepare error: %s", tostring(err))
        end
        return rows 
    end
    
    if params then
        for i, v in ipairs(params) do 
            local success = stmt:bind(i, v)
            if not success then
                self:safe_log("warn", "Failed to bind parameter %d: %s", i, tostring(v))
            end
        end
    end
    
    local success, iter_err = pcall(function()
        for row in stmt:nrows() do 
            table.insert(rows, row) 
        end
    end)
    
    stmt:finalize()
    
    if not success then
        self:safe_log("error", "Failed to iterate query results: %s", query)
        if iter_err then
            self:safe_log("debug", "Iteration error: %s", tostring(iter_err))
        end
    end
    
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

-- Set a general setting with error handling
function DB:set_setting(key, value, category)
    if not self:is_ready() then
        self:safe_log("error", "Cannot set setting: database not ready")
        return false
    end
    
    category = category or "general"
    local data_type = "string"
    local string_value = tostring(value)
    
    if type(value) == "boolean" then
        data_type = "boolean"
        string_value = value and "true" or "false"
    elseif type(value) == "number" then
        data_type = "number"
    end

    local stmt, err = self.db:prepare([[
        INSERT OR REPLACE INTO settings (key, value, category, data_type, updated_at)
        VALUES (?, ?, ?, ?, CURRENT_TIMESTAMP)
    ]])
    
    if not stmt then 
        self:safe_log("error", "Failed to prepare set_setting statement for key: %s", key)
        if err then
            self:safe_log("debug", "Prepare error: %s", tostring(err))
        end
        return false 
    end
    
    stmt:bind_values(key, string_value, category, data_type)
    
    local success, step_err = pcall(function()
        return stmt:step()
    end)
    
    stmt:finalize()
    
    if not success then
        self:safe_log("error", "Failed to set setting: %s = %s", key, string_value)
        if step_err then
            self:safe_log("debug", "Step error: %s", tostring(step_err))
        end
        return false
    end
    
    return true
end

-- Set a character-specific setting with error handling
function DB:set_char_setting(char_name, key, value)
    if not self:is_ready() then
        self:safe_log("error", "Cannot set char setting: database not ready")
        return false
    end
    
    local data_type = "string"
    local string_value = tostring(value)
    
    if type(value) == "boolean" then
        data_type = "boolean"
        string_value = value and "true" or "false"
    elseif type(value) == "number" then
        data_type = "number"
    end

    local stmt, err = self.db:prepare([[
        INSERT OR REPLACE INTO char_settings (char_name, key, value, data_type, updated_at)
        VALUES (?, ?, ?, ?, CURRENT_TIMESTAMP)
    ]])
    
    if not stmt then 
        self:safe_log("error", "Failed to prepare set_char_setting statement for %s/%s", char_name, key)
        if err then
            self:safe_log("debug", "Prepare error: %s", tostring(err))
        end
        return false 
    end
    
    stmt:bind_values(char_name, key, string_value, data_type)
    
    local success, step_err = pcall(function()
        return stmt:step()
    end)
    
    stmt:finalize()
    
    if not success then
        self:safe_log("error", "Failed to set char setting: %s/%s = %s", char_name, key, string_value)
        if step_err then
            self:safe_log("debug", "Step error: %s", tostring(step_err))
        end
        return false
    end
    
    return true
end

-- Get a general setting with error handling
function DB:get_setting(key, default_value)
    if not self:is_ready() then
        self:safe_log("warn", "Database not ready, returning default for key: %s", key)
        return default_value
    end
    
    local stmt, err = self.db:prepare("SELECT value, data_type FROM settings WHERE key = ?")
    if not stmt then 
        self:safe_log("warn", "Failed to prepare get_setting statement for key: %s", key)
        if err then
            self:safe_log("debug", "Prepare error: %s", tostring(err))
        end
        return default_value 
    end
    
    stmt:bind_values(key)
    
    local row
    local success, iter_err = pcall(function()
        row = stmt:nrows()()
    end)
    
    stmt:finalize()
    
    if not success then
        self:safe_log("error", "Failed to get setting: %s", key)
        if iter_err then
            self:safe_log("debug", "Iteration error: %s", tostring(iter_err))
        end
        return default_value
    end
    
    if not row then 
        return default_value 
    end
    
    if row.data_type == "boolean" then 
        return row.value == "true"
    elseif row.data_type == "number" then 
        return tonumber(row.value) or default_value
    else 
        return row.value 
    end
end

-- Get a character-specific setting with error handling
function DB:get_char_setting(char_name, key, default_value)
    if not self:is_ready() then
        self:safe_log("warn", "Database not ready, returning default for char/key: %s/%s", char_name, key)
        return default_value
    end
    
    local stmt, err = self.db:prepare("SELECT value, data_type FROM char_settings WHERE char_name = ? AND key = ?")
    if not stmt then 
        self:safe_log("warn", "Failed to prepare get_char_setting statement for %s/%s", char_name, key)
        if err then
            self:safe_log("debug", "Prepare error: %s", tostring(err))
        end
        return default_value 
    end
    
    stmt:bind_values(char_name, key)
    
    local row
    local success, iter_err = pcall(function()
        row = stmt:nrows()()
    end)
    
    stmt:finalize()
    
    if not success then
        self:safe_log("error", "Failed to get char setting: %s/%s", char_name, key)
        if iter_err then
            self:safe_log("debug", "Iteration error: %s", tostring(iter_err))
        end
        return default_value
    end
    
    if not row then 
        return default_value 
    end
    
    if row.data_type == "boolean" then 
        return row.value == "true"
    elseif row.data_type == "number" then 
        return tonumber(row.value) or default_value
    else 
        return row.value 
    end
end

-- Import a general setting from INI with transaction safety
function DB:import_setting(key, value, category)
    if not self:is_ready() then
        self:safe_log("error", "Cannot import setting: database not ready")
        return false, "Database not ready"
    end
    
    local converted_value = value
    local data_type = "string"
    
    if type(value) == "string" then
        local lower = value:lower()
        if lower == "true" then 
            converted_value = true
            data_type = "boolean"
        elseif lower == "false" then 
            converted_value = false
            data_type = "boolean"
        elseif tonumber(value) then 
            converted_value = tonumber(value)
            data_type = "number"
        end
    end
    
    local string_value
    if data_type == "boolean" then
        string_value = converted_value and "true" or "false"
    else
        string_value = tostring(converted_value)
    end

    local stmt, err = self.db:prepare([[
        INSERT OR REPLACE INTO settings (key, value, category, data_type, updated_at)
        VALUES (?, ?, ?, ?, CURRENT_TIMESTAMP)
    ]])
    
    if not stmt then 
        self:safe_log("error", "Failed to prepare import_setting statement for key: %s", key)
        if err then
            self:safe_log("debug", "Prepare error: %s", tostring(err))
        end
        return false, "Failed to prepare statement" 
    end
    
    stmt:bind_values(key, string_value, category, data_type)
    
    local success, step_err = pcall(function()
        return stmt:step()
    end)
    
    stmt:finalize()
    
    if not success then
        self:safe_log("error", "Failed to import setting: %s = %s", key, string_value)
        if step_err then
            self:safe_log("debug", "Step error: %s", tostring(step_err))
        end
        return false, "Failed to import setting" 
    end
    
    return true
end

-- Import a character-specific setting from INI with transaction safety
function DB:import_char_setting(char_name, key, value)
    if not self:is_ready() then
        self:safe_log("error", "Cannot import char setting: database not ready")
        return false, "Database not ready"
    end
    
    local converted_value = value
    local data_type = "string"
    
    if type(value) == "string" then
        local lower = value:lower()
        if lower == "true" then 
            converted_value = true
            data_type = "boolean"
        elseif lower == "false" then 
            converted_value = false
            data_type = "boolean"
        elseif tonumber(value) then 
            converted_value = tonumber(value)
            data_type = "number"
        end
    end
    
    local string_value
    if data_type == "boolean" then
        string_value = converted_value and "true" or "false"
    else
        string_value = tostring(converted_value)
    end

    local stmt, err = self.db:prepare([[
        INSERT OR REPLACE INTO char_settings (char_name, key, value, data_type, updated_at)
        VALUES (?, ?, ?, ?, CURRENT_TIMESTAMP)
    ]])
    
    if not stmt then 
        self:safe_log("error", "Failed to prepare import_char_setting statement for %s/%s", char_name, key)
        if err then
            self:safe_log("debug", "Prepare error: %s", tostring(err))
        end
        return false, "Failed to prepare statement" 
    end
    
    stmt:bind_values(char_name, key, string_value, data_type)
    
    local success, step_err = pcall(function()
        return stmt:step()
    end)
    
    stmt:finalize()
    
    if not success then
        self:safe_log("error", "Failed to import char setting: %s/%s = %s", char_name, key, string_value)
        if step_err then
            self:safe_log("debug", "Step error: %s", tostring(step_err))
        end
        return false, "Failed to import char setting" 
    end
    
    return true
end

-- Get conversion status for GUI with full error handling
function DB:get_conversion_status(ini_file)
    local status = {
        converted = false,
        ini_exists = false,
        ini_settings_count = 0,
        db_settings_count = 0,
        db_rules_count = 0,
        db_ready = self:is_ready(),
        errors = {}
    }

    -- Check if INI file exists
    local file = io.open(ini_file, "r")
    if file then 
        status.ini_exists = true
        
        -- Count INI settings
        local current_section = nil
        file:seek("set", 0)
        for line in file:lines() do
            line = line:match("^%s*(.-)%s*$")
            if line ~= "" and not line:match("^[;#]") then
                local section = line:match("^%[([^%]]+)%]$")
                if section then
                    current_section = section
                elseif current_section then
                    status.ini_settings_count = status.ini_settings_count + 1
                end
            end
        end
        file:close()
    end

    -- Check database counts ONLY if database is ready
    if self:is_ready() then
        -- Count settings
        local success, result = pcall(function()
            local stmt = self.db:prepare("SELECT COUNT(*) AS count FROM settings")
            if not stmt then return nil end
            local row = stmt:nrows()()
            stmt:finalize()
            return row
        end)
        
        if success and result then
            status.db_settings_count = result.count or 0
        else
            table.insert(status.errors, "Failed to count settings")
        end

        -- Count loot rules
        success, result = pcall(function()
            local stmt = self.db:prepare("SELECT COUNT(*) AS count FROM loot_rules")
            if not stmt then return nil end
            local row = stmt:nrows()()
            stmt:finalize()
            return row
        end)
        
        if success and result then
            status.db_rules_count = result.count or 0
        else
            table.insert(status.errors, "Failed to count loot rules")
        end

        status.converted = status.db_settings_count > 0
    else
        table.insert(status.errors, "Database not ready")
        self:safe_log("warn", "Database not ready, cannot check conversion status")
    end

    return status
end

-- Close DB with error handling
function DB:close()
    if self.db then
        local success, err = pcall(function()
            self.db:close()
        end)
        
        if not success then
            self:safe_log("error", "Failed to close database: %s", tostring(err))
        else
            self:safe_log("info", "Database connection closed")
        end
        
        self.db = nil
        self.initialized = false
    end
end

return DB