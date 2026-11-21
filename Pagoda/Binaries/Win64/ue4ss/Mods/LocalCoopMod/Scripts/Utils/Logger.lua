-- Ring-buffered logger for UE4SS output and in-game diagnostics.

local Logger = {}

local ConfigRef = {}
local RingBuffer = {}
local MaxEntries = 100
local MissingReported = {}
local ErrorCount = 0
local MissingCount = 0

function Logger.Init(config)
    ConfigRef = config or {}
    local logCfg = ConfigRef.Logging or {}
    MaxEntries = (type(logCfg.MaxRecentLogs) == "number" and logCfg.MaxRecentLogs >= 16)
        and logCfg.MaxRecentLogs or 100
end

function Logger.IsDebugEnabled()
    return ConfigRef.Logging and (ConfigRef.Logging.DebugLogging == true)
end

local function FormatSafe(fmt, ...)
    if select("#", ...) == 0 then
        return tostring(fmt or "")
    end
    local ok, out = pcall(string.format, tostring(fmt), ...)
    return ok and out or tostring(fmt or "")
end

local function Record(level, tag, msg)
    RingBuffer[#RingBuffer + 1] = {
        Time = os.clock(),
        Level = level,
        Tag = tostring(tag or "Core"),
        Message = tostring(msg or ""),
    }
    if #RingBuffer > MaxEntries then
        table.remove(RingBuffer, 1)
    end
    print(string.format("[LocalCoop][%s][%s] %s\n", level, tostring(tag or "Core"), msg))
end

function Logger.Info(tag, fmt, ...)
    Record("INFO", tag, FormatSafe(fmt, ...))
end

function Logger.Warn(tag, fmt, ...)
    Record("WARN", tag, FormatSafe(fmt, ...))
end

function Logger.Error(tag, fmt, ...)
    ErrorCount = ErrorCount + 1
    Record("ERROR", tag, FormatSafe(fmt, ...))
end

function Logger.Debug(tag, fmt, ...)
    if Logger.IsDebugEnabled() then
        Record("DBG", tag, FormatSafe(fmt, ...))
    end
end

-- Log missing UObject/UFunction/Widget once per world to avoid per-frame spam.
function Logger.Missing(tag, assetOrFnName, context)
    local key = tostring(tag or "Core") .. "|" .. tostring(assetOrFnName or "?")
    if MissingReported[key] then return false end
    MissingReported[key] = true
    MissingCount = MissingCount + 1
    local ctxStr = context and (" (" .. tostring(context) .. ")") or ""
    Record("WARN", tag, string.format("Missing expected UObject/UFunction/Widget: '%s'%s",
        tostring(assetOrFnName), ctxStr))
    return true
end

function Logger.ResetMissingCache()
    MissingReported = {}
end

function Logger.GetRecent(limit)
    local n = #RingBuffer
    local want = math.min(n, limit or n)
    local out = {}
    for i = n - want + 1, n do
        out[#out + 1] = RingBuffer[i]
    end
    return out
end

function Logger.GetStats()
    return {
        ErrorCount = ErrorCount,
        MissingCount = MissingCount,
        BufferedLines = #RingBuffer,
    }
end

return Logger
