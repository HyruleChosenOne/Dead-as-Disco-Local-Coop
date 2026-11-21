-- ============================================================================
-- HOOK REGISTRY (PROPER PRE / POST / DEFERRED SEMANTICS & MISSING REPORTING)
-- ============================================================================
-- Fixes legacy HookManager bugs:
--   * Never runs postCallback pre-call alongside preCallback.
--   * Returns a real UE4SS post-hook closure ONLY when postFn is supplied
--     (and opts.DeferredPost ~= true); otherwise returns nothing so non-void
--     UFunction return values remain untouched.
--   * Supports opts.DeferredPost + opts.CaptureFn to safely extract parameters
--     pre-call and run post-logic cleanly on the next EngineTick.
--   * Explicitly logs missing native hooks immediately and reports missing
--     script hooks once gameplay loads (zero silent failures).
-- ============================================================================

local UObjectUtils = require("Utils.UObjectUtils")
local Logger = require("Utils.Logger")
local Scheduler = require("Core.Scheduler")

local HookRegistry = {}

local Hooks = {}           -- [funcPath] = { Kind, Path, Registered, Calls, Errors, ReportedMissing }
local ObjectNotifiers = {} -- [classPath] = true

local function RegisterInternal(kind, funcPath, preFn, postFn, opts)
    local rec = Hooks[funcPath]
    if rec and rec.Registered then return true end

    local hasPre = (type(preFn) == "function")
    local hasPost = (type(postFn) == "function")
    if not (hasPre or hasPost) then
        Logger.Warn("HookRegistry", "Ignored hook '%s': no callback provided.", tostring(funcPath))
        return false
    end

    rec = rec or {
        Kind = kind,
        Path = funcPath,
        Registered = false,
        Calls = 0,
        Errors = 0,
        ReportedMissing = false,
    }
    Hooks[funcPath] = rec

    local deferredPost = (opts and opts.DeferredPost == true)
    local captureFn = (opts and type(opts.CaptureFn) == "function") and opts.CaptureFn or nil
    local bindGen = (opts and opts.BindGeneration == true)

    local okFind, fnObj = pcall(StaticFindObject, funcPath)
    if not (okFind and UObjectUtils.IsValid(fnObj)) then
        if kind == "Native" then
            Logger.Missing("HookRegistry", funcPath, "native UFunction not found")
        else
            local clsPath = funcPath:match("^(.+):[^:]+$")
            if clsPath then
                local okCls, clsObj = pcall(StaticFindObject, clsPath)
                if okCls and UObjectUtils.IsValid(clsObj) then
                    Logger.Missing("HookRegistry", funcPath, "Blueprint class loaded but UFunction missing")
                end
            end
        end
        return false
    end

    local okReg, regErr = pcall(function()
        RegisterHook(funcPath, function(...)
            rec.Calls = rec.Calls + 1

            if hasPre then
                local okPre, errPre = pcall(preFn, ...)
                if not okPre then
                    rec.Errors = rec.Errors + 1
                    Logger.Warn("HookPre:" .. funcPath, "%s", tostring(errPre))
                end
            end

            if hasPost then
                if deferredPost then
                    if captureFn then
                        local okCap, c1, c2, c3, c4 = pcall(captureFn, ...)
                        if okCap then
                            Scheduler.Defer("Post:" .. funcPath, function()
                                local okP, errP = pcall(postFn, c1, c2, c3, c4)
                                if not okP then
                                    rec.Errors = rec.Errors + 1
                                    Logger.Warn("HookPostDef:" .. funcPath, "%s", tostring(errP))
                                end
                            end, bindGen)
                        else
                            rec.Errors = rec.Errors + 1
                            Logger.Warn("HookCapture:" .. funcPath, "%s", tostring(c1))
                        end
                    else
                        Scheduler.Defer("Post:" .. funcPath, function()
                            local okP, errP = pcall(postFn)
                            if not okP then
                                rec.Errors = rec.Errors + 1
                                Logger.Warn("HookPostDef:" .. funcPath, "%s", tostring(errP))
                            end
                        end, bindGen)
                    end
                else
                    -- Real UE4SS post-hook callback (only safe on void UFunctions)
                    return function(...)
                        local okPost, errPost = pcall(postFn, ...)
                        if not okPost then
                            rec.Errors = rec.Errors + 1
                            Logger.Warn("HookPost:" .. funcPath, "%s", tostring(errPost))
                        end
                    end
                end
            end
        end)
    end)

    if okReg then
        rec.Registered = true
        rec.ReportedMissing = false
        Logger.Debug("HookRegistry", "Registered %s hook: %s", kind, funcPath)
        return true
    else
        rec.Errors = rec.Errors + 1
        Logger.Warn("HookRegistry", "RegisterHook failed for '%s': %s", funcPath, tostring(regErr))
        return false
    end
end

function HookRegistry.RegisterNative(funcPath, preFn, postFn, opts)
    return RegisterInternal("Native", funcPath, preFn, postFn, opts)
end

function HookRegistry.RegisterScript(funcPath, preFn, postFn, opts)
    return RegisterInternal("Script", funcPath, preFn, postFn, opts)
end

function HookRegistry.NotifyNewObject(classPath, callback, runSync)
    if ObjectNotifiers[classPath] then return true end
    if type(callback) ~= "function" then return false end
    if type(NotifyOnNewObject) ~= "function" then
        Logger.Missing("HookRegistry", "NotifyOnNewObject", classPath)
        return false
    end

    local ok, err = pcall(function()
        NotifyOnNewObject(classPath, function(obj)
            if runSync then
                local okSync, errSync = pcall(callback, obj)
                if not okSync then
                    Logger.Warn("NewObjSync:" .. classPath, "%s", tostring(errSync))
                end
            else
                Scheduler.RunOnGameThread("NewObj:" .. classPath, function()
                    if UObjectUtils.IsValid(obj) then
                        local okAsync, errAsync = pcall(callback, obj)
                        if not okAsync then
                            Logger.Warn("NewObj:" .. classPath, "%s", tostring(errAsync))
                        end
                    end
                end)
            end
        end)
    end)

    if ok then
        ObjectNotifiers[classPath] = true
        Logger.Debug("HookRegistry", "Registered NotifyOnNewObject: %s (sync=%s)", classPath, tostring(runSync == true))
        return true
    else
        Logger.Warn("HookRegistry", "NotifyOnNewObject failed for '%s': %s", classPath, tostring(err))
        return false
    end
end

-- Logs warnings for any registered hooks whose UFunctions remain unresolved
-- once a gameplay world is active (surfaces broken/changed asset paths cleanly).
function HookRegistry.ReportMissingHooks(contextLabel)
    local missing = {}
    for funcPath, rec in pairs(Hooks) do
        if not rec.Registered then
            local clsPath = funcPath:match("^(.+):[^:]+$")
            local classLoaded = (rec.Kind == "Native")
            if not classLoaded and clsPath then
                local okCls, clsObj = pcall(StaticFindObject, clsPath)
                classLoaded = (okCls and UObjectUtils.IsValid(clsObj))
            end
            if classLoaded then
                missing[#missing + 1] = funcPath
                if not rec.ReportedMissing then
                    rec.ReportedMissing = true
                    Logger.Missing("HookRegistry", funcPath,
                        string.format("%s hook unresolved while owning class is loaded (%s)",
                            rec.Kind, tostring(contextLabel or "Gameplay")))
                end
            end
        end
    end
    table.sort(missing)
    return missing
end

function HookRegistry.GetHealthSummary()
    local total, registered, errors, calls = 0, 0, 0, 0
    local missingList = {}
    for funcPath, rec in pairs(Hooks) do
        total = total + 1
        if rec.Registered then
            registered = registered + 1
        else
            missingList[#missingList + 1] = funcPath
        end
        errors = errors + (rec.Errors or 0)
        calls = calls + (rec.Calls or 0)
    end
    table.sort(missingList)
    return {
        Total = total,
        Registered = registered,
        Pending = total - registered,
        MissingList = missingList,
        Errors = errors,
        Calls = calls,
    }
end

return HookRegistry
