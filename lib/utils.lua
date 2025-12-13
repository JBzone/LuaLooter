local utils = {}

function shallowcopy(orig)
  local orig_type = type(orig)
  local copy
  if orig_type == 'table' then
    copy = {}
    for orig_key, orig_value in pairs(orig) do
      copy[orig_key] = orig_value
    end
  else -- number, string, boolean, etc
    copy = orig
  end
  return copy
end

function file_exists(path)
  local f = io.open(path, "r")
  if f ~= nil then
    io.close(f)
    return true
  else
    return false
  end
end

function __gen_ordered_index(t)
  local ordered_index = {}
  for key in pairs(t) do
    table.insert(ordered_index, key)
  end
  table.sort(ordered_index)
  return ordered_index
end

function ordered_next(t, state)
  -- Equivalent of the next function, but returns the keys in the alphabetic
  -- order. We use a temporary ordered key table that is stored in the
  -- table being iterated.

  local key = nil
  --print("orderedNext: state = "..tostring(state) )
  if state == nil then
    -- the first time, generate the index
    t.__ordered_index = __gen_ordered_index(t)
    key = t.__ordered_index[1]
  else
    -- fetch the next value
    for i = 1, #t.__ordered_index do
      if t.__ordered_index[i] == state then
        key = t.__ordered_index[i + 1]
      end
    end
  end

  if key then
    return key, t[key]
  end

  -- no more value to return, cleanup
  t.__ordered_index = nil
  return
end

function ordered_pairs(t)
  -- Equivalent of the pairs() function on tables. Allows to iterate
  -- in order
  return ordered_next, t, nil
end

-- Print contents of `tbl`, with indentation.
-- `indent` sets the initial level of indentation.
function tprint(tbl, indent)
  if type(tbl) == "table" and next(tbl) ~= nil then
    if not indent then indent = 0 end
    for k, v in ordered_pairs(tbl) do
      formatting = string.rep("  ", indent) .. k .. ": "
      if type(v) == "table" then
        print(formatting)
        tprint(v, indent + 1)
      else
        print(formatting .. tostring(v))
      end
    end
  end
end

function get_table_size(tbl)
  local cnt = 0
  if type(tbl) == "table" and next(tbl) ~= nil then
    for k, v in pairs(tbl) do cnt = cnt + 1 end
  end
  return cnt
end

function sort_table(tbl)
  local t = {}
  local keys = {}
  -- get and sort table keys
  for k in pairs(tbl) do table.insert(keys, k) end
  table.sort(keys)
  -- rebuild tbl by key order and return it
  for _, k in ipairs(keys) do t[k] = tbl[k] end
  return t
end

function gsplit(text, pattern, plain)
  local split_start, length = 1 or nil, #text
  return function()
    if split_start then
      local sep_start, sep_end = string.find(text, pattern, split_start, plain)
      local ret
      if not sep_start then
        ret = string.sub(text, split_start)
        split_start = 0
      elseif sep_end < sep_start then
        -- Empty separator!
        ret = string.sub(text, split_start, sep_start)
        if sep_start < length then
          split_start = sep_start + 1
        else
          split_start = 0
        end
      else
        ret = sep_start > split_start and string.sub(text, split_start, sep_start - 1) or ''
        split_start = sep_end + 1
      end
      return ret
    end
  end
end

function split(text, pattern, plain)
  local ret = {}
  if text ~= nil then
    for match in gsplit(text, pattern, plain) do
      table.insert(ret, match)
    end
  end
  return ret
end

return utils
