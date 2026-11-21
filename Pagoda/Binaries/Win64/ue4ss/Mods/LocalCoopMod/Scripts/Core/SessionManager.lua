-- ============================================================================
-- CO-OP SESSION MANAGER (EXPLICIT FSM, WORLD TRANSITIONS & MULTIPLAYER)
-- ============================================================================
-- Manages Player 1 (index 0) and Player 2 (index 1) identity, world transitions,
-- singleton P2 enforcement (without destroying combat clones/phantoms),
-- PagodaLocalMultiplayerSubsystem integration,
-- WBP_LevelEndScreen_C detection, and spawn / regroup / despawn / auto-leash.
-- ============================================================================

local UEHelpers = require("UEHelpers")
local UObjectUtils = require("Utils.UObjectUtils")
local Logger = require("Utils.Logger")
local Scheduler = require("Core.Scheduler")

local SessionManager = {}

local Config = {}
local Callbacks = {}

SessionManager.State = {
    Phase = "Solo",             -- "Solo" | "Spawning" | "Active" | "Cutscene" | "Transitioning" | "Despawning"
    IsSpawned = false,
    IsTransitioning = false,
    IsInCutscene = false,
    AutoLeashEnabled = true,
    ActiveWorldKey = nil,
}

-- Indexed strictly by 0-based Unreal PlayerIndex: [0] = P1, [1] = P2
local Controllers = { [0] = nil, [1] = nil }
local ModSpawnedP2Pawns = {} -- [pawnKey] = pawnRef (ONLY pawns created via fallback SpawnActor)

function SessionManager.Init(config, callbacks)
    Config = config or {}
    Callbacks = callbacks or {}
    local sessCfg = Config.Session or {}
    SessionManager.State.AutoLeashEnabled = (sessCfg.AutoLeashEnabled ~= false)
end

function SessionManager.GetPhase()
    return SessionManager.State.Phase
end

function SessionManager.SetCutsceneState(inCutscene)
    SessionManager.State.IsInCutscene = (inCutscene == true)
    if SessionManager.State.IsInCutscene and SessionManager.State.IsSpawned then
        SessionManager.State.Phase = "Cutscene"
    elseif not SessionManager.State.IsInCutscene then
        SessionManager.State.Phase = SessionManager.State.IsSpawned and "Active" or "Solo"
    end
end

function SessionManager.SetTransitioning(isTransitioning)
    SessionManager.State.IsTransitioning = (isTransitioning == true)
    if isTransitioning then
        SessionManager.State.Phase = "Transitioning"
    else
        SessionManager.State.Phase = SessionManager.State.IsSpawned and "Active" or "Solo"
    end
end

function SessionManager.IsSafeForGameplayHooks()
    local s = SessionManager.State
    return (s.Phase ~= "Spawning") and (s.Phase ~= "Despawning") and (not s.IsTransitioning)
end

-- ============================================================================
-- CONTROLLER & PAWN IDENTITY (ELIMINATES HARDCODED PLAYER 0 LOOKUPS)
-- ============================================================================

function SessionManager.GetPlayerIndex(pc)
    if not UObjectUtils.IsLive(pc) then return nil end

    local okLp, id = pcall(function()
        local lp = pc.Player
        if UObjectUtils.IsValid(lp) then
            return lp.ControllerId
        end
        return nil
    end)
    if okLp and type(id) == "number" and id >= 0 then
        return id
    end

    local okGs, gsId = pcall(function()
        local gs = UObjectUtils.GetGameplayStatics()
        if UObjectUtils.IsValid(gs) then
            return gs:GetPlayerControllerID(pc)
        end
        return nil
    end)
    if okGs and type(gsId) == "number" and gsId >= 0 then
        return gsId
    end

    local okPrimary, isPrimary = pcall(function()
        local primary = UEHelpers.GetPlayerController()
        return UObjectUtils.IsValid(primary) and UObjectUtils.Same(primary, pc)
    end)
    if okPrimary and isPrimary then
        return 0
    end

    return nil
end

function SessionManager.ResolvePlayerIndex(obj)
    if not UObjectUtils.IsLive(obj) then return nil end
    local p1, p2 = SessionManager.GetController(0), SessionManager.GetController(1)
    if p1 and UObjectUtils.Same(obj, p1) then return 0 end
    if p2 and UObjectUtils.Same(obj, p2) then return 1 end

    local p1Pawn, p2Pawn = SessionManager.GetPawn(0), SessionManager.GetPawn(1)
    if p1Pawn and UObjectUtils.Same(obj, p1Pawn) then return 0 end
    if p2Pawn and UObjectUtils.Same(obj, p2Pawn) then return 1 end

    local okCtrl, ctrl = pcall(function() return obj.Controller end)
    if okCtrl and UObjectUtils.IsLive(ctrl) then
        return SessionManager.GetPlayerIndex(ctrl)
    end

    local okOwn, owner = pcall(function() return obj:GetOwner() end)
    if okOwn and UObjectUtils.IsLive(owner) and not UObjectUtils.Same(owner, obj) then
        if p1 and UObjectUtils.Same(owner, p1) then return 0 end
        if p2 and UObjectUtils.Same(owner, p2) then return 1 end
        if p1Pawn and UObjectUtils.Same(owner, p1Pawn) then return 0 end
        if p2Pawn and UObjectUtils.Same(owner, p2Pawn) then return 1 end
    end

    return SessionManager.GetPlayerIndex(obj)
end

function SessionManager.DestroyActorSafely(actor)
    if not UObjectUtils.IsValid(actor) then return end
    UObjectUtils.MarkDestroyed(actor)

    pcall(function()
        local ctrl = actor.Controller
        if UObjectUtils.IsLive(ctrl) then
            ctrl:UnPossess()
        end
    end)
    pcall(function() actor:K2_DetachFromActor(1, 1, 1) end)
    pcall(function() actor:SetActorHiddenInGame(true) end)
    pcall(function() actor:SetActorEnableCollision(false) end)
    pcall(function() actor:SetActorTickEnabled(false) end)
    pcall(function() actor:K2_DestroyActor() end)
end

function SessionManager.RefreshControllers()
    local inGameplay, currentWorld = UObjectUtils.IsGameplayWorld()
    local worldKey = UObjectUtils.GetKey(currentWorld)

    if worldKey ~= nil and SessionManager.State.ActiveWorldKey ~= nil and worldKey ~= SessionManager.State.ActiveWorldKey then
        Logger.Info("SessionManager", "World transition detected -> resetting transient co-op state.")
        SessionManager.State.ActiveWorldKey = worldKey
        ModSpawnedP2Pawns = {}
        UObjectUtils.InvalidateWorldCache()
        Logger.ResetMissingCache()
        Scheduler.BumpGeneration("WorldChanged")
        if Callbacks.OnWorldChanged then
            UObjectUtils.SafeCall("Session.OnWorldChanged", Callbacks.OnWorldChanged, currentWorld, inGameplay)
        end
    elseif worldKey ~= nil then
        SessionManager.State.ActiveWorldKey = worldKey
    end

    Controllers[0] = nil
    Controllers[1] = nil

    local allControllers = nil
    pcall(function() allControllers = FindAllOf("PlayerController") end)
    if allControllers then
        for _, pc in pairs(allControllers) do
            if UObjectUtils.IsLive(pc) then
                local fn = ""
                pcall(function() fn = pc:GetFullName() end)
                if not fn:find("DebugCameraController", 1, true)
                    and not fn:find("ReplayPlayerController", 1, true) then
                    local okW, ctrlWorld = pcall(function() return pc:GetWorld() end)
                    local inWorld = (not UObjectUtils.IsValid(currentWorld)) or (okW and UObjectUtils.Same(ctrlWorld, currentWorld))
                    if inWorld then
                        local pid = SessionManager.GetPlayerIndex(pc)
                        if pid == 0 or pid == 1 then
                            local existing = Controllers[pid]
                            if not existing then
                                Controllers[pid] = pc
                            else
                                local newHasPawn = UObjectUtils.IsLive(pc.Pawn)
                                local oldHasPawn = UObjectUtils.IsLive(existing.Pawn)
                                if newHasPawn and not oldHasPawn then
                                    Controllers[pid] = pc
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    if not Controllers[0] then
        pcall(function()
            local primary = UEHelpers.GetPlayerController()
            if UObjectUtils.IsLive(primary) then
                local okW, ctrlWorld = pcall(function() return primary:GetWorld() end)
                local inWorld = (not UObjectUtils.IsValid(currentWorld)) or (okW and UObjectUtils.Same(ctrlWorld, currentWorld))
                if inWorld then
                    Controllers[0] = primary
                end
            end
        end)
    end

    local p2Live = UObjectUtils.IsLive(Controllers[1])
    SessionManager.State.IsSpawned = p2Live
    if SessionManager.State.Phase ~= "Spawning"
        and SessionManager.State.Phase ~= "Despawning"
        and SessionManager.State.Phase ~= "Transitioning" then
        if SessionManager.State.IsInCutscene and p2Live then
            SessionManager.State.Phase = "Cutscene"
        else
            SessionManager.State.Phase = p2Live and "Active" or "Solo"
        end
    end

    return Controllers[0], Controllers[1]
end

function SessionManager.GetController(playerIndex)
    local pc = Controllers[playerIndex]
    if not UObjectUtils.IsLive(pc) then return nil end
    if playerIndex == 1 and SessionManager.GetPlayerIndex(pc) ~= 1 then return nil end
    return pc
end

function SessionManager.GetPawn(playerIndex)
    local pc = SessionManager.GetController(playerIndex)
    if not pc then return nil end
    local pawn = nil
    pcall(function() pawn = pc.Pawn end)
    return UObjectUtils.IsLive(pawn) and pawn or nil
end

function SessionManager.GetP1() return SessionManager.GetController(0) end
function SessionManager.GetP2() return SessionManager.GetController(1) end
function SessionManager.GetP1Pawn() return SessionManager.GetPawn(0) end
function SessionManager.GetP2Pawn() return SessionManager.GetPawn(1) end

function SessionManager.IsP2Active()
    return SessionManager.GetController(1) ~= nil
end

-- ============================================================================
-- NATIVE MULTIPLAYER SUBSYSTEM CONTROL
-- ============================================================================

function SessionManager.SetNativeMultiplayerState(active)
    local lms = nil
    pcall(function() lms = FindFirstOf("PagodaLocalMultiplayerSubsystem") end)
    if not UObjectUtils.IsValid(lms) then
        Logger.Debug("SessionManager", "PagodaLocalMultiplayerSubsystem not active in current world.")
        return false
    end

    if UObjectUtils.IsValid(lms.SavedSettings) then
        pcall(function() lms.SavedSettings.bAllowFriendlyFire = false end)
    end

    local okGet, allowed = pcall(function() return lms:GetIsJoinOrLeaveAllowed() end)
    if not okGet then
        Logger.Missing("SessionManager", "PagodaLocalMultiplayerSubsystem:GetIsJoinOrLeaveAllowed", "SetNativeMultiplayerState")
    end
    if not (okGet and allowed == (active == true)) then
        local okSet, errSet = pcall(function() lms:SetIsJoinOrLeaveAllowed(active == true) end)
        if not okSet then
            Logger.Warn("SessionManager", "SetIsJoinOrLeaveAllowed failed: %s", tostring(errSet))
            return false
        end
    end
    return true
end

function SessionManager.ClearNativeMultiplayerIfSolo()
    if SessionManager.IsP2Active() then return end
    SessionManager.SetNativeMultiplayerState(false)
end

-- ============================================================================
-- VERIFIED UI / SCENE QUERIES & MOVEMENT INTEGRITY
-- ============================================================================

local CachedLevelEndActive = false
local CachedLevelEndAt = -1.0

function SessionManager.IsLevelEndActive()
    local now = os.clock()
    if (now - CachedLevelEndAt) < 0.25 then
        return CachedLevelEndActive
    end
    local active = false
    pcall(function()
        local widgets = FindAllOf("WBP_LevelEndScreen_C")
        if widgets then
            for _, w in pairs(widgets) do
                if UObjectUtils.IsLive(w) then
                    local okA, act = pcall(function() return w:IsActivated() end)
                    local vis = 0
                    pcall(function() vis = tonumber(w:GetVisibility()) or 0 end)
                    if okA and act == true and vis ~= 1 and vis ~= 2 then
                        active = true
                        return
                    end
                end
            end
        end
    end)
    CachedLevelEndActive = active
    CachedLevelEndAt = now
    return active
end

function SessionManager.ShouldViewTargetTriggerCutscene(pc, newViewTarget)
    if not (UObjectUtils.IsLive(pc) and UObjectUtils.IsLive(newViewTarget)) then return false end
    if SessionManager.GetPlayerIndex(pc) ~= 0 then return false end

    local vtName = ""
    pcall(function() vtName = newViewTarget:GetFullName() end)
    if vtName == "" or not vtName:find("CineCameraActor", 1, true) then return false end
    if vtName:find("Level_MainMenu", 1, true)
        or vtName:find("ModelRenderer", 1, true)
        or vtName:find("ModelViewer", 1, true)
        or vtName:find("Takedown", 1, true)
        or vtName:find("Finisher", 1, true)
        or vtName:find("BossSkill", 1, true) then
        return false
    end
    return true
end

function SessionManager.VerifyP2MovementSanity(p2Pawn, isDowned, isMenuOpen)
    if isDowned or isMenuOpen or not UObjectUtils.IsLive(p2Pawn) then return end
    pcall(function()
        local cm = p2Pawn.CharacterMovement
        if UObjectUtils.IsValid(cm) then
            local mode = cm.MovementMode
            if mode == 0 and not SessionManager.State.IsInCutscene then
                cm:SetMovementMode(1) -- MOVE_Walking
                Logger.Debug("SessionManager", "Recovered stuck MOVE_None on P2 pawn.")
            end
        end
    end)
end

-- ============================================================================
-- STRICT SINGLETON GUARD (PRESERVES COMBAT CLONES & PHANTOMS)
-- ============================================================================

function SessionManager.EnforceSingletonP2()
    if not SessionManager.IsSafeForGameplayHooks() then return end
    pcall(function()
        local inGameplay, currentWorld = UObjectUtils.IsGameplayWorld()
        if not inGameplay or not UObjectUtils.IsValid(currentWorld) then return end

        local gs = UObjectUtils.GetGameplayStatics()
        local allControllers = FindAllOf("PlayerController")
        if allControllers then
            for _, ctrl in pairs(allControllers) do
                if UObjectUtils.IsLive(ctrl) then
                    local id = SessionManager.GetPlayerIndex(ctrl)
                    if id ~= nil and id >= 2 then
                        Logger.Info("SessionManager", "Removing extra LocalPlayer ControllerId=%d", id)
                        if UObjectUtils.IsLive(ctrl.Pawn) then
                            SessionManager.DestroyActorSafely(ctrl.Pawn)
                        end
                        UObjectUtils.MarkDestroyed(ctrl)
                        if gs then
                            pcall(function() gs:RemovePlayer(ctrl, true) end)
                        else
                            SessionManager.DestroyActorSafely(ctrl)
                        end
                    end
                end
            end
        end

        SessionManager.RefreshControllers()
        local p1Pawn, p2Pawn = SessionManager.GetP1Pawn(), SessionManager.GetP2Pawn()

        for key, ref in pairs(ModSpawnedP2Pawns) do
            if not UObjectUtils.IsLive(ref) then
                ModSpawnedP2Pawns[key] = nil
            elseif not UObjectUtils.Same(ref, p1Pawn) and not UObjectUtils.Same(ref, p2Pawn) then
                local chCtrl = nil
                pcall(function() chCtrl = ref.Controller end)
                if not UObjectUtils.IsLive(chCtrl) then
                    Logger.Debug("SessionManager", "Cleaning orphaned mod-spawned P2 pawn: %s", key)
                    SessionManager.DestroyActorSafely(ref)
                    ModSpawnedP2Pawns[key] = nil
                end
            end
        end
    end)
end

-- ============================================================================
-- SPAWN / REGROUP / DESPAWN / TELEPORT / AUTO-LEASH
-- ============================================================================

function SessionManager.SpawnOrRegroupP2()
    if SessionManager.State.Phase == "Spawning" or SessionManager.State.Phase == "Despawning" then return end
    if not UObjectUtils.CanTrigger("SpawnOrRegroupP2", 0.45) then return end

    Scheduler.RunOnGameThread("SpawnOrRegroupP2", function()
        if SessionManager.State.Phase == "Spawning" or SessionManager.State.Phase == "Despawning" then return end

        local inGameplay, world = UObjectUtils.IsGameplayWorld()
        if not inGameplay or not UObjectUtils.IsValid(world) then
            if Callbacks.Notify then
                Callbacks.Notify("Enter the Dive Bar or a Stage before connecting Player 2.", "Warning")
            end
            return
        end

        if Callbacks.EnsureHooksInstalled then Callbacks.EnsureHooksInstalled() end
        SessionManager.EnforceSingletonP2()
        SessionManager.RefreshControllers()

        local p1Ctrl = SessionManager.GetP1()
        local p1Pawn = SessionManager.GetP1Pawn()
        if not (p1Ctrl and p1Pawn) then
            if Callbacks.Notify then
                Callbacks.Notify("Wait for Player 1 to spawn before connecting Player 2.", "Warning")
            end
            return
        end

        local existingP2Pawn = SessionManager.GetP2Pawn()
        if existingP2Pawn then
            pcall(function()
                local loc = p1Pawn:K2_GetActorLocation()
                loc.X = loc.X + 125.0
                local rot = p1Pawn:K2_GetActorRotation()
                existingP2Pawn:K2_SetActorLocationAndRotation(loc, rot, false, {}, false)
            end)
            if Callbacks.OnP2Regrouped then
                UObjectUtils.SafeCall("Session.OnP2Regrouped", Callbacks.OnP2Regrouped, p1Ctrl, SessionManager.GetP2())
            end
            if Callbacks.Notify then
                Callbacks.Notify("Player 2 Regrouped Beside Player 1", "Info")
            end
            return
        end

        local gs = UObjectUtils.GetGameplayStatics()
        if not gs then return end

        SessionManager.State.Phase = "Spawning"
        Logger.Info("SessionManager", "Spawning Player 2...")

        if Callbacks.OnP2ConnectingStart then
            UObjectUtils.SafeCall("ConnectingStart", Callbacks.OnP2ConnectingStart, "CONNECTING PLAYER 2...")
        end

        -- Yield 2 frames so the dedicated "CONNECTING PLAYER 2..." card paints visibly before synchronous CreatePlayer
        Scheduler.Delay(40, "Session.DoSpawnP2", function()
            if SessionManager.State.Phase ~= "Spawning" then return end
            if Callbacks.EnsureHooksInstalled then Callbacks.EnsureHooksInstalled() end
            SessionManager.RefreshControllers()
            local curP1Ctrl = SessionManager.GetP1()
            local curP1Pawn = SessionManager.GetP1Pawn()
            local curWorld = UObjectUtils.GetWorld()
            if not (curP1Ctrl and curP1Pawn and UObjectUtils.IsValid(curWorld)) then
                SessionManager.State.Phase = "Solo"
                SessionManager.State.IsSpawned = false
                if Callbacks.OnP2ConnectingEnd then UObjectUtils.SafeCall("ConnectingFail", Callbacks.OnP2ConnectingEnd, false) end
                return
            end

            if Callbacks.BeforeP2Create then
                UObjectUtils.SafeCall("BeforeP2Create", Callbacks.BeforeP2Create)
            end

            local function spawnBody()
                local newCtrl = SessionManager.GetP2()
                if not UObjectUtils.IsLive(newCtrl) then
                    newCtrl = gs:CreatePlayer(curP1Ctrl, 1, true)
                elseif not UObjectUtils.IsLive(newCtrl.Pawn) then
                    local gm = UEHelpers.GetGameModeBase()
                    if UObjectUtils.IsValid(gm) then
                        pcall(function() gm:RestartPlayer(newCtrl) end)
                    end
                end

                if UObjectUtils.IsLive(newCtrl) and SessionManager.GetPlayerIndex(newCtrl) == 1 then
                    Controllers[1] = newCtrl
                    SessionManager.State.IsSpawned = true
                    Logger.Info("SessionManager", "P2 Controller active: %s", newCtrl:GetFullName())

                    if Callbacks.OnP2ConnectingStatus then
                        UObjectUtils.SafeCall("ConnectingStatus", Callbacks.OnP2ConnectingStatus, "LOADING PLAYER 2 PROFILE...")
                    end
                    if Callbacks.OnP2ControllerCreated then
                        UObjectUtils.SafeCall("OnP2ControllerCreated", Callbacks.OnP2ControllerCreated, curP1Ctrl, newCtrl)
                    end

                    if not UObjectUtils.IsLive(newCtrl.Pawn) then
                        local spawnLoc = curP1Pawn:K2_GetActorLocation()
                        spawnLoc.X = spawnLoc.X + 145.0
                        local spawnRot = curP1Pawn:K2_GetActorRotation()
                        local spawnClass = curP1Pawn:GetClass()
                        local spawnedPawn = curWorld:SpawnActor(spawnClass, spawnLoc, spawnRot)
                        if UObjectUtils.IsLive(spawnedPawn) then
                            local pKey = UObjectUtils.GetKey(spawnedPawn)
                            if pKey then ModSpawnedP2Pawns[pKey] = spawnedPawn end
                            newCtrl:Possess(spawnedPawn)
                            pcall(function() newCtrl:ClientRestart(spawnedPawn) end)
                            if not UObjectUtils.Same(newCtrl.Pawn, spawnedPawn) then
                                SessionManager.DestroyActorSafely(spawnedPawn)
                                if pKey then ModSpawnedP2Pawns[pKey] = nil end
                            end
                        end
                    else
                        pcall(function()
                            local loc = curP1Pawn:K2_GetActorLocation()
                            loc.X = loc.X + 140.0
                            local rot = curP1Pawn:K2_GetActorRotation()
                            newCtrl.Pawn:K2_SetActorLocationAndRotation(loc, rot, false, {}, false)
                        end)
                    end

                    if Callbacks.OnP2SpawnImmediate then
                        UObjectUtils.SafeCall("OnP2SpawnImmediate", Callbacks.OnP2SpawnImmediate, curP1Ctrl, newCtrl)
                    end

                    Scheduler.Delay(180, "Session.OnP2Ready", function()
                        SessionManager.State.Phase = "Active"
                        SessionManager.RefreshControllers()
                        local cP1, cP2 = SessionManager.GetP1(), SessionManager.GetP2()
                        if cP1 and cP2 and Callbacks.OnP2Ready then
                            UObjectUtils.SafeCall("OnP2Ready", Callbacks.OnP2Ready, cP1, cP2)
                        end
                        SessionManager.EnforceSingletonP2()
                        if Callbacks.OnP2ConnectingEnd then
                            UObjectUtils.SafeCall("ConnectingDone", Callbacks.OnP2ConnectingEnd, cP2 ~= nil)
                        end
                    end, true)
                else
                    SessionManager.State.Phase = "Solo"
                    SessionManager.State.IsSpawned = false
                    if Callbacks.OnP2ConnectingEnd then
                        UObjectUtils.SafeCall("ConnectingFail", Callbacks.OnP2ConnectingEnd, false)
                    end
                    if Callbacks.Notify then
                        Callbacks.Notify("Failed to spawn Player 2 in current level.", "Error")
                    end
                end
            end

            local okSpawn, errSpawn
            if type(Callbacks.WrapP2Spawn) == "function" then
                okSpawn, errSpawn = pcall(Callbacks.WrapP2Spawn, curP1Ctrl, spawnBody)
            else
                okSpawn, errSpawn = pcall(spawnBody)
            end

            if not okSpawn then
                SessionManager.State.Phase = SessionManager.IsP2Active() and "Active" or "Solo"
                if Callbacks.OnP2ConnectingEnd then
                    UObjectUtils.SafeCall("ConnectingErr", Callbacks.OnP2ConnectingEnd, false)
                end
                Logger.Warn("SessionManager", "SpawnOrRegroupP2 failed: %s", tostring(errSpawn))
            end
        end, true)
    end)
end

function SessionManager.DespawnP2()
    if SessionManager.State.Phase == "Despawning" then return end
    if not UObjectUtils.CanTrigger("DespawnP2", 0.40) then return end

    Scheduler.RunOnGameThread("DespawnP2", function()
        SessionManager.State.Phase = "Despawning"
        Scheduler.BumpGeneration("DespawnP2")

        if Callbacks.BeforeP2Despawn then
            UObjectUtils.SafeCall("BeforeP2Despawn", Callbacks.BeforeP2Despawn)
        end

        SessionManager.RefreshControllers()

        local p2Ctrl = SessionManager.GetP2()
        if not p2Ctrl then
            SessionManager.State.Phase = "Solo"
            SessionManager.State.IsSpawned = false
            SessionManager.ClearNativeMultiplayerIfSolo()
            if Callbacks.Notify then
                Callbacks.Notify("Player 2 is not currently active.", "Warning")
            end
            return
        end

        local gs = UObjectUtils.GetGameplayStatics()
        if gs and UObjectUtils.IsLive(p2Ctrl) then
            local p2Pawn = nil
            pcall(function() p2Pawn = p2Ctrl.Pawn end)
            if UObjectUtils.IsLive(p2Pawn) then
                local pKey = UObjectUtils.GetKey(p2Pawn)
                if pKey then ModSpawnedP2Pawns[pKey] = nil end
                SessionManager.DestroyActorSafely(p2Pawn)
            end
            UObjectUtils.MarkDestroyed(p2Ctrl)
            pcall(function() gs:RemovePlayer(p2Ctrl, true) end)
            Controllers[1] = nil
        end

        SessionManager.State.IsSpawned = false
        SessionManager.State.IsInCutscene = false
        SessionManager.State.Phase = "Solo"
        SessionManager.ClearNativeMultiplayerIfSolo()

        if Callbacks.AfterP2Despawn then
            UObjectUtils.SafeCall("AfterP2Despawn", Callbacks.AfterP2Despawn, SessionManager.GetP1())
        end

        if Callbacks.Notify then
            Callbacks.Notify("Player 2 Left", "Warning")
        end
    end)
end

function SessionManager.TeleportP2ToP1()
    if not UObjectUtils.CanTrigger("TeleportP2", 0.25) then return end
    Scheduler.RunOnGameThread("TeleportP2", function()
        SessionManager.RefreshControllers()
        local p1Pawn, p2Pawn = SessionManager.GetP1Pawn(), SessionManager.GetP2Pawn()
        if not p2Pawn then
            if Callbacks.Notify then Callbacks.Notify("Player 2 is not active.", "Warning") end
            return
        end
        if p1Pawn and p2Pawn then
            pcall(function()
                local loc = p1Pawn:K2_GetActorLocation()
                loc.X = loc.X + 120.0
                local rot = p1Pawn:K2_GetActorRotation()
                p2Pawn:K2_SetActorLocationAndRotation(loc, rot, false, {}, false)
            end)
            if Callbacks.Notify then Callbacks.Notify("Player 2 Regrouped to Player 1", "Info") end
        end
    end)
end

function SessionManager.ToggleAutoLeash()
    if not UObjectUtils.CanTrigger("ToggleAutoLeash", 0.25) then return end
    SessionManager.State.AutoLeashEnabled = not SessionManager.State.AutoLeashEnabled
    if Callbacks.Notify then
        Callbacks.Notify(
            SessionManager.State.AutoLeashEnabled and "Auto-Leash: ENABLED" or "Auto-Leash: DISABLED",
            SessionManager.State.AutoLeashEnabled and "Success" or "Warning"
        )
    end
end

function SessionManager.TickAutoLeash(isSharedScreenActive)
    if not (SessionManager.State.AutoLeashEnabled and isSharedScreenActive and SessionManager.IsP2Active()) then return end
    if not SessionManager.IsSafeForGameplayHooks() or SessionManager.State.IsInCutscene then return end

    local p1Pawn, p2Pawn = SessionManager.GetP1Pawn(), SessionManager.GetP2Pawn()
    if not (p1Pawn and p2Pawn) then return end

    pcall(function()
        local l1 = p1Pawn:K2_GetActorLocation()
        local l2 = p2Pawn:K2_GetActorLocation()
        local dx, dy, dz = l1.X - l2.X, l1.Y - l2.Y, l1.Z - l2.Z
        local sessCfg = Config.Session or {}
        local maxDist = sessCfg.MaxLeashDistance or 2500.0
        local maxDZ = sessCfg.MaxLeashZDiff or 600.0
        if (dx * dx + dy * dy + dz * dz) > (maxDist * maxDist) or math.abs(dz) > maxDZ then
            local loc = p1Pawn:K2_GetActorLocation()
            loc.X = loc.X + 100.0
            local rot = p1Pawn:K2_GetActorRotation()
            p2Pawn:K2_SetActorLocationAndRotation(loc, rot, false, {}, false)
            Logger.Debug("SessionManager", "Auto-leashed Player 2 back into arena range.")
        end
    end)
end

return SessionManager
