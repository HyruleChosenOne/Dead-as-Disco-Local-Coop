-- ============================================================================
-- SINGLE-THREADED GAME-THREAD SCHEDULER (ZERO ASYNC-THREAD RACES)
-- ============================================================================
-- Lua 5.4 is strictly single-threaded per lua_State*.
-- Uses ONE permanently-rooted EngineTick loop (LoopInGameThreadAfterFrames)
-- running synchronously on the Unreal Game Thread at UEngine::Tick.
-- Supports per-frame callbacks (OnFrame), next-tick coalesced defers,
-- generation-scoped delays (automatically cancelled on world change/despawn),
-- and throttled repeating intervals.
-- ============================================================================

local Logger = require("Utils.Logger")

local Scheduler = {}

local Started = false
local NextTaskId = 1
local CurrentGeneration = 1
local ImmediateQueue = {}  -- { Tag, Fn }
local PendingDelays = {}   -- { Id, DueTime, Generation, Tag, Fn }
local Intervals = {}       -- { Id, IntervalSec, NextRun, Tag, Fn }
local FrameCallbacks = {}  -- { Tag, Fn }
local DeferredQueue = {}   -- { Generation, Tag, Fn }
local DeferredTags = {}    -- [tag] = true
local LastTickAt = 0.0
local LastFrameAt = 0.0
local TickHandle = nil
local HeartbeatMode = "NotStarted"

function Scheduler.GetGeneration()
    return CurrentGeneration
end

function Scheduler.BumpGeneration(reason)
    CurrentGeneration = CurrentGeneration + 1
    Logger.Debug("Scheduler", "Generation -> %d (%s)", CurrentGeneration, tostring(reason or "reset"))
    return CurrentGeneration
end

function Scheduler.Defer(tag, fn, bindGeneration)
    if type(fn) ~= "function" then return false end
    local t = tostring(tag or "Defer")
    if DeferredTags[t] then return true end
    DeferredTags[t] = true
    DeferredQueue[#DeferredQueue + 1] = {
        Generation = bindGeneration and CurrentGeneration or nil,
        Tag = t,
        Fn = fn,
    }
    return true
end

function Scheduler.Delay(delayMs, tag, fn, bindGeneration)
    if type(fn) ~= "function" then return nil end
    local id = NextTaskId
    NextTaskId = NextTaskId + 1
    local sec = math.max(0.0, (tonumber(delayMs) or 0) / 1000.0)
    PendingDelays[#PendingDelays + 1] = {
        Id = id,
        DueTime = os.clock() + sec,
        Generation = bindGeneration and CurrentGeneration or nil,
        Tag = tostring(tag or "Delay"),
        Fn = fn,
    }
    return id
end

function Scheduler.ReplaceDelay(delayMs, tag, fn, bindGeneration)
    local t = tostring(tag or "Delay")
    for i = #PendingDelays, 1, -1 do
        if PendingDelays[i].Tag == t then
            table.remove(PendingDelays, i)
        end
    end
    return Scheduler.Delay(delayMs, t, fn, bindGeneration)
end

function Scheduler.CancelByTag(tag)
    local t = tostring(tag or "")
    if t == "" then return end
    for i = #PendingDelays, 1, -1 do
        if PendingDelays[i].Tag == t then
            table.remove(PendingDelays, i)
        end
    end
end

function Scheduler.Cancel(taskId)
    if not taskId then return end
    for i = #PendingDelays, 1, -1 do
        if PendingDelays[i].Id == taskId then
            table.remove(PendingDelays, i)
            return
        end
    end
    for i = #Intervals, 1, -1 do
        if Intervals[i].Id == taskId then
            table.remove(Intervals, i)
            return
        end
    end
end

function Scheduler.Every(intervalMs, tag, fn)
    if type(fn) ~= "function" then return nil end
    local id = NextTaskId
    NextTaskId = NextTaskId + 1
    local sec = math.max(0.025, (tonumber(intervalMs) or 100) / 1000.0)
    Intervals[#Intervals + 1] = {
        Id = id,
        IntervalSec = sec,
        NextRun = os.clock() + sec,
        Tag = tostring(tag or "Loop"),
        Fn = fn,
    }
    return id
end

function Scheduler.RunOnGameThread(tag, fn)
    if type(fn) ~= "function" then return end
    ImmediateQueue[#ImmediateQueue + 1] = {
        Tag = tostring(tag or "Task"),
        Fn = fn,
    }
end

function Scheduler.OnFrame(tag, fn)
    if type(fn) ~= "function" then return end
    local t = tostring(tag or "Frame")
    for i = 1, #FrameCallbacks do
        if FrameCallbacks[i].Tag == t then
            FrameCallbacks[i].Fn = fn
            return
        end
    end
    FrameCallbacks[#FrameCallbacks + 1] = { Tag = t, Fn = fn }
end

function Scheduler.RemoveOnFrame(tag)
    local t = tostring(tag or "")
    for i = #FrameCallbacks, 1, -1 do
        if FrameCallbacks[i].Tag == t then
            table.remove(FrameCallbacks, i)
            return
        end
    end
end

local function ProcessTick()
    local now = os.clock()

    if #FrameCallbacks > 0 then
        local dt = (LastFrameAt > 0.0) and math.min(0.10, math.max(0.001, now - LastFrameAt)) or 0.016
        LastFrameAt = now
        for i = 1, #FrameCallbacks do
            local cb = FrameCallbacks[i]
            if cb then
                local ok, err = pcall(cb.Fn, dt, now)
                if not ok then
                    Logger.Warn("Frame:" .. cb.Tag, "%s", tostring(err))
                end
            end
        end
    end

    if #ImmediateQueue == 0 and #DeferredQueue == 0 and (now - LastTickAt) < 0.030 then
        return
    end
    LastTickAt = now

    if #ImmediateQueue > 0 then
        local imm = ImmediateQueue
        ImmediateQueue = {}
        for i = 1, #imm do
            local item = imm[i]
            local ok, err = pcall(item.Fn)
            if not ok then
                Logger.Warn("GameThread:" .. item.Tag, "%s", tostring(err))
            end
        end
    end

    if #DeferredQueue > 0 then
        local batch = DeferredQueue
        DeferredQueue = {}
        DeferredTags = {}
        for i = 1, #batch do
            local item = batch[i]
            if item.Generation == nil or item.Generation == CurrentGeneration then
                local ok, err = pcall(item.Fn)
                if not ok then
                    Logger.Warn("Defer:" .. item.Tag, "%s", tostring(err))
                end
            end
        end
    end

    if #PendingDelays > 0 then
        local remaining = {}
        local due = {}
        for i = 1, #PendingDelays do
            local task = PendingDelays[i]
            if task.Generation ~= nil and task.Generation ~= CurrentGeneration then
                -- Automatically dropped when generation changes
            elseif now >= task.DueTime then
                due[#due + 1] = task
            else
                remaining[#remaining + 1] = task
            end
        end
        PendingDelays = remaining

        for i = 1, #due do
            local task = due[i]
            if task.Generation == nil or task.Generation == CurrentGeneration then
                local ok, err = pcall(task.Fn)
                if not ok then
                    Logger.Warn("Delay:" .. task.Tag, "%s", tostring(err))
                end
            end
        end
    end

    for i = 1, #Intervals do
        local loop = Intervals[i]
        if now >= loop.NextRun then
            loop.NextRun = now + loop.IntervalSec
            local ok, err = pcall(loop.Fn, now)
            if not ok then
                Logger.Warn("Loop:" .. loop.Tag, "%s", tostring(err))
            end
        end
    end
end

local function GameThreadTickThunk()
    local ok, err = pcall(ProcessTick)
    if not ok then
        Logger.Error("Scheduler.Tick", "%s", tostring(err))
    end
end

function Scheduler.Start()
    if Started then return end
    Started = true

    local okEngineTick = false
    if type(LoopInGameThreadAfterFrames) == "function" then
        local ok, handle = pcall(LoopInGameThreadAfterFrames, 1, GameThreadTickThunk)
        if ok and handle ~= nil then
            TickHandle = handle
            okEngineTick = true
            HeartbeatMode = "EngineTick"
            Logger.Info("Scheduler", "Single Game-Thread EngineTick scheduler started.")
        end
    end

    if not okEngineTick then
        local hooked = pcall(function()
            RegisterHook("/Script/Engine.HUD:ReceiveDrawHUD", GameThreadTickThunk)
        end)
        HeartbeatMode = hooked and "DrawHUD" or "Unavailable"
        Logger.Warn("Scheduler", "LoopInGameThreadAfterFrames unavailable; fallback heartbeat = %s", HeartbeatMode)
    end
end

function Scheduler.GetStats()
    return {
        Generation = CurrentGeneration,
        PendingDelays = #PendingDelays,
        Intervals = #Intervals,
        Deferred = #DeferredQueue,
        Mode = HeartbeatMode,
        Handle = TickHandle,
    }
end

return Scheduler
