-- ============================================================================
-- PURE LUA JSON SERIALIZER / DESERIALIZER & DETERMINISTIC FILE I/O
-- ============================================================================

local Logger = require("Utils.Logger")

local Json = {}

local function EscapeString(s)
    s = tostring(s or "")
    s = s:gsub("\\", "\\\\")
    s = s:gsub('"', '\\"')
    s = s:gsub("\n", "\\n")
    s = s:gsub("\r", "\\r")
    s = s:gsub("\t", "\\t")
    return '"' .. s .. '"'
end

function Json.Encode(val, indent)
    indent = indent or ""
    local t = type(val)
    if t == "string" then
        return EscapeString(val)
    elseif t == "number" then
        if val ~= val or val == math.huge or val == -math.huge then
            return "0"
        end
        return tostring(val)
    elseif t == "boolean" then
        return val and "true" or "false"
    elseif t == "table" then
        local isArray = true
        local maxIdx = 0
        local count = 0
        for k in pairs(val) do
            count = count + 1
            if type(k) ~= "number" or k < 1 or math.floor(k) ~= k then
                isArray = false
            elseif k > maxIdx then
                maxIdx = k
            end
        end
        if count == 0 then return "{}" end
        if isArray and maxIdx == count then
            local parts = {}
            for i = 1, maxIdx do
                parts[i] = indent .. "  " .. Json.Encode(val[i], indent .. "  ")
            end
            return "[\n" .. table.concat(parts, ",\n") .. "\n" .. indent .. "]"
        else
            local keys = {}
            for k in pairs(val) do keys[#keys + 1] = tostring(k) end
            table.sort(keys)
            local parts = {}
            for _, kStr in ipairs(keys) do
                local v = val[kStr]
                if v == nil then v = val[tonumber(kStr)] end
                parts[#parts + 1] = indent .. "  " .. EscapeString(kStr) .. ": " .. Json.Encode(v, indent .. "  ")
            end
            return "{\n" .. table.concat(parts, ",\n") .. "\n" .. indent .. "}"
        end
    end
    return "null"
end

function Json.Decode(str)
    if type(str) ~= "string" or str == "" then return nil, "empty" end
    local pos = 1
    local len = #str

    local function skipWS()
        while pos <= len do
            local b = str:byte(pos)
            if b == 32 or b == 9 or b == 10 or b == 13 then
                pos = pos + 1
            else
                break
            end
        end
    end

    local parseValue

    local function parseString()
        pos = pos + 1
        local out = {}
        while pos <= len do
            local ch = str:sub(pos, pos)
            if ch == '"' then
                pos = pos + 1
                return table.concat(out)
            elseif ch == "\\" then
                pos = pos + 1
                local esc = str:sub(pos, pos)
                if esc == "n" then out[#out + 1] = "\n"
                elseif esc == "r" then out[#out + 1] = "\r"
                elseif esc == "t" then out[#out + 1] = "\t"
                else out[#out + 1] = esc end
                pos = pos + 1
            else
                out[#out + 1] = ch
                pos = pos + 1
            end
        end
        error("unterminated string")
    end

    local function parseNumber()
        local startPos = pos
        while pos <= len do
            local ch = str:sub(pos, pos)
            if ch:match("[%d%.%-+%eE]") then
                pos = pos + 1
            else
                break
            end
        end
        local n = tonumber(str:sub(startPos, pos - 1))
        if n == nil then error("invalid number near pos " .. tostring(startPos)) end
        return n
    end

    local function parseArray()
        pos = pos + 1
        local arr = {}
        skipWS()
        if str:sub(pos, pos) == "]" then
            pos = pos + 1
            return arr
        end
        while pos <= len do
            skipWS()
            arr[#arr + 1] = parseValue()
            skipWS()
            local ch = str:sub(pos, pos)
            if ch == "," then
                pos = pos + 1
            elseif ch == "]" then
                pos = pos + 1
                break
            else
                error("expected ',' or ']' in array near pos " .. tostring(pos))
            end
        end
        return arr
    end

    local function parseObject()
        pos = pos + 1
        local obj = {}
        skipWS()
        if str:sub(pos, pos) == "}" then
            pos = pos + 1
            return obj
        end
        while pos <= len do
            skipWS()
            if str:sub(pos, pos) ~= '"' then
                error("expected string key near pos " .. tostring(pos))
            end
            local key = parseString()
            skipWS()
            if str:sub(pos, pos) == ":" then pos = pos + 1 end
            skipWS()
            obj[key] = parseValue()
            skipWS()
            local ch = str:sub(pos, pos)
            if ch == "," then
                pos = pos + 1
            elseif ch == "}" then
                pos = pos + 1
                break
            else
                error("expected ',' or '}' in object near pos " .. tostring(pos))
            end
        end
        return obj
    end

    parseValue = function()
        skipWS()
        local ch = str:sub(pos, pos)
        if ch == '"' then return parseString()
        elseif ch == "{" then return parseObject()
        elseif ch == "[" then return parseArray()
        elseif str:sub(pos, pos + 3) == "true" then pos = pos + 4; return true
        elseif str:sub(pos, pos + 4) == "false" then pos = pos + 5; return false
        elseif str:sub(pos, pos + 3) == "null" then pos = pos + 4; return nil
        else return parseNumber() end
    end

    local ok, res = pcall(parseValue)
    if not ok then
        return nil, tostring(res)
    end
    return res, nil
end

function Json.ReadFile(path)
    if type(path) ~= "string" or path == "" then return nil, "invalid_path" end
    local f = io.open(path, "r")
    if not f then return nil, "not_found" end
    local content = f:read("*a")
    f:close()
    if not content or content == "" then return nil, "empty" end
    local decoded, err = Json.Decode(content)
    if not decoded then
        Logger.Warn("Json", "Failed to decode JSON file '%s': %s", path, tostring(err))
        return nil, err
    end
    return decoded, path
end

function Json.WriteFile(path, tbl)
    if type(path) ~= "string" or path == "" then return false, "invalid_path" end
    local encoded = Json.Encode(tbl)
    if not encoded or encoded == "" then
        Logger.Warn("Json", "Failed to encode payload for '%s'", path)
        return false, "encode_failed"
    end
    local f, openErr = io.open(path, "w")
    if not f then
        Logger.Warn("Json", "Failed to open '%s' for writing: %s", path, tostring(openErr))
        return false, openErr
    end
    f:write(encoded)
    f:close()
    return true, path
end

return Json
