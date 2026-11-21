-- ============================================================================
-- DEAD AS DISCO - LOCAL CO-OP MULTIPLAYER MOD (v1.0 Experimental)
-- ============================================================================
-- Modular Architecture:
--   * Utils/      Logger, UObjectUtils, Json
--   * Core/       Scheduler (single Game-Thread loop), HookRegistry, SessionManager
--   * State/      CatalogService, ProfileStore, PlayerStateIsolation
--   * Characters/ PakScanner, CharacterApplier (Vanilla + CSM full visual stack)
--   * Camera/     ViewportController (Split-Screen, Cutscene/Pause collapse, Midpoint Cam)
--   * Input/      InputRouting (per-player native locks, P2 pad routing, Pause safety)
--   * Gameplay/   ReviveSystem (Clean FSM, GAS effects, Proximity Hold UI, Wipe)
--   * UI/         UITheme, VanillaHUD (Native P2 HUD widgets), JoinPrompt,
--                 P2Menu (5-Tab), Notifications
-- ============================================================================

print("[Dead as Disco - Local Co-op Mod] Booting v1.0 (Experimental)...\n")

local Config               = require("config")
local Logger               = require("Utils.Logger")
local UObjectUtils         = require("Utils.UObjectUtils")
local Scheduler            = require("Core.Scheduler")
local HookRegistry         = require("Core.HookRegistry")
local SessionManager       = require("Core.SessionManager")
local CatalogService       = require("State.CatalogService")
local ProfileStore         = require("State.ProfileStore")
local PlayerStateIsolation = require("State.PlayerStateIsolation")
local CharacterApplier     = require("Characters.CharacterApplier")
local ViewportController   = require("Camera.ViewportController")
local InputRouting         = require("Input.InputRouting")
local ReviveSystem         = require("Gameplay.ReviveSystem")
local UITheme              = require("UI.UITheme")
local Notifications        = require("UI.Notifications")
local JoinPrompt           = require("UI.JoinPrompt")
local ReviveOverlay        = require("UI.ReviveOverlay")
local VanillaHUD           = require("UI.VanillaHUD")
local PlayerMarkers        = require("UI.PlayerMarkers")
local P2Menu               = require("UI.P2Menu")

local InstallRuntimeHooks
local LastFastHudSyncAt = 0.0

-- ============================================================================
-- SHARED ORCHESTRATION HELPERS
-- ============================================================================

local function Notify(msg, severity)
    Notifications.Show(msg, severity or "Info")
end

local function SaveP2Profile()
    ProfileStore.SaveP2Profile({
        TintMode = CharacterApplier.CurrentTintMode,
        TintPaletteIndex = CharacterApplier.CurrentTintPaletteIdx,
        ScreenMode = ViewportController.CurrentScreenMode,
        LastSplitScreenMode = ViewportController.LastSplitScreenMode,
        HUDSharedScale = VanillaHUD.GetSharedScale(),
        ShowSharedPlayerCircles = (Config.HUD and Config.HUD.ShowSharedPlayerCircles ~= false),
        ExperimentalEnabled = (Config.Experimental and Config.Experimental.Enabled == true),
        CustomFOVEnabled = ViewportController.CustomFOVEnabled,
        CustomFOV = ViewportController.CustomFOV,
        DynamicSharedCameraEnabled = ViewportController.DynamicSharedCameraEnabled,
    })
end

local function ApplyFullP2Setup(p1Ctrl, p2Ctrl)
    if not UObjectUtils.IsLive(p2Ctrl) then return end
    local p2Pawn = SessionManager.GetP2Pawn()
    if not p2Pawn then return end

    CatalogService.Refresh(true)
    PlayerStateIsolation.IsolatePlayer2State(p1Ctrl, p2Ctrl)
    SessionManager.SetNativeMultiplayerState(true)
    ProfileStore.EnsureP2Initialized(function() return PlayerStateIsolation.CaptureP1Snapshot(p1Ctrl) end)
    ProfileStore.RehydrateFromCatalog()

    local p2Store = ProfileStore.GetP2()
    local charEntry = p2Store.CharacterKey and CharacterApplier.FindEntry(p2Store.CharacterKey) or nil
    if p2Store.CharacterKey and p2Store.CharacterKey ~= "Default"
        and (not CharacterApplier.IsEntryExperimental(charEntry) or CharacterApplier.IsExperimentalEnabled()) then
        CharacterApplier.ApplyToP2(p1Ctrl, p2Ctrl, p2Pawn, p2Store.CharacterKey)
    else
        p2Store.CharacterKey = "Default"
        CharacterApplier.SetModularAttachmentsHidden(p2Pawn, false)
        PlayerStateIsolation.ApplyOutfitToP2(p1Ctrl, p2Ctrl, p2Pawn)
    end

    PlayerStateIsolation.ApplyDancesAndSkillsToP2(p1Ctrl, p2Ctrl, p2Pawn)
    CharacterApplier.ApplyP2VisualStyling(p2Pawn)

    if not ViewportController.InCutsceneFullscreen and not ViewportController.InPauseFullscreen then
        ViewportController.ApplyScreenMode(ViewportController.CurrentScreenMode, true)
    end
    ViewportController.SuppressP2DiveBarCredits()
    ViewportController.ApplyCustomFOV()
    VanillaHUD.Sync()

    local revCfg = Config.Revive or {}
    if revCfg.Enabled ~= false then
        local p1Pawn = SessionManager.GetP1Pawn()
        if p1Pawn then ReviveSystem.ProtectPawn(0, p1Pawn, p1Ctrl) end
        ReviveSystem.ProtectPawn(1, p2Pawn, p2Ctrl)
    end

    -- Coalesced post-streaming pass after async BeginPlay / CosmeticComponent loads settle
    Scheduler.ReplaceDelay(420, "Main.PostSpawnVerify", function()
        if not SessionManager.IsSafeForGameplayHooks() then return end
        SessionManager.RefreshControllers()
        local c1, c2, pawn2 = SessionManager.GetP1(), SessionManager.GetP2(), SessionManager.GetP2Pawn()
        if c1 and c2 and pawn2 then
            ProfileStore.RehydrateFromCatalog()
            PlayerStateIsolation.IsolatePlayer2State(c1, c2)
            CharacterApplier.ReassertMeshOnly(pawn2)
            PlayerStateIsolation.ApplyDancesAndSkillsToP2(c1, c2, pawn2)
            if not ViewportController.InCutsceneFullscreen and not ViewportController.InPauseFullscreen then
                ViewportController.ApplyScreenMode(ViewportController.CurrentScreenMode, true)
            end
            ViewportController.SuppressP2DiveBarCredits()
            ViewportController.ApplyCustomFOV()
            VanillaHUD.Sync()
            HookRegistry.ReportMissingHooks("GameplayReady")
        end
    end, true)
end

local function InitEngineState()
    SessionManager.EnforceSingletonP2()
    SessionManager.RefreshControllers()
    SessionManager.ClearNativeMultiplayerIfSolo()
    InputRouting.SyncGamepadOffset(false)
    if SessionManager.IsP2Active() then
        ViewportController.ApplyScreenMode(ViewportController.CurrentScreenMode, true)
    end
    ViewportController.LocalizeAllLayouts()
    ViewportController.ApplyCustomFOV()
    VanillaHUD.Sync()
end

local function ScheduleP2VisualStyling(delayMs)
    Scheduler.ReplaceDelay(delayMs or 280, "Main.DelayedVisualStyle", function()
        if not SessionManager.IsSafeForGameplayHooks() then return end
        local liveP2 = SessionManager.GetP2Pawn()
        if liveP2 then CharacterApplier.ApplyP2VisualStyling(liveP2) end
    end, true)
end

local function CycleP2TintMode()
    if not UObjectUtils.CanTrigger("CycleTintMode", 0.20) then return end
    Scheduler.RunOnGameThread("CycleTintMode", function()
        if CharacterApplier.CurrentTintMode == "FullBody" then
            CharacterApplier.CurrentTintMode = "AccentOnly"
        elseif CharacterApplier.CurrentTintMode == "AccentOnly" then
            CharacterApplier.CurrentTintMode = "Off"
        else
            CharacterApplier.CurrentTintMode = "FullBody"
        end

        SessionManager.RefreshControllers()
        local p1, p2, p2Pawn = SessionManager.GetP1(), SessionManager.GetP2(), SessionManager.GetP2Pawn()
        if p2 and p2Pawn then
            if ProfileStore.GetP2().CharacterKey == "Default" then
                PlayerStateIsolation.ApplyOutfitToP2(p1, p2, p2Pawn)
            end
            CharacterApplier.ApplyP2VisualStyling(p2Pawn)
        end
        SaveP2Profile()
    end)
end

local function ToggleExperimentalFeatures()
    local expCfg = Config.Experimental
    if not expCfg then
        Config.Experimental = { Enabled = true }
        expCfg = Config.Experimental
    else
        expCfg.Enabled = not (expCfg.Enabled == true)
    end

    SessionManager.RefreshControllers()
    local p1, p2, p2Pawn = SessionManager.GetP1(), SessionManager.GetP2(), SessionManager.GetP2Pawn()
    if p2 and p2Pawn then
        if not expCfg.Enabled then
            local p2Store = ProfileStore.GetP2()
            local curEntry = CharacterApplier.FindEntry(p2Store.CharacterKey)
            if CharacterApplier.IsEntryExperimental(curEntry) then
                CharacterApplier.ApplyToP2(p1, p2, p2Pawn, "Default")
            elseif p2Store.CharacterKey == "Default" then
                PlayerStateIsolation.ApplyOutfitToP2(p1, p2, p2Pawn)
                CharacterApplier.ApplyP2VisualStyling(p2Pawn)
            else
                CharacterApplier.ApplyP2VisualStyling(p2Pawn)
            end
        else
            CharacterApplier.ApplyP2VisualStyling(p2Pawn)
        end
    end
    SaveP2Profile()
end

-- ============================================================================
-- MODULE INITIALIZATION & DEPENDENCY WIRING
-- ============================================================================

Logger.Init(Config)
UObjectUtils.EnsurePlaythroughDataBridges()
PlayerStateIsolation.Init(Config)
CharacterApplier.Init(Config, {
    SaveProfile = SaveP2Profile,
    Notify = Notify,
})
Notifications.Init(Config, {
    IsP2MenuOpen = P2Menu.IsOpen,
})
JoinPrompt.Init(Config)
ReviveOverlay.Init(Config)

ViewportController.Init(Config, {
    CloseP2MenuIfOpen = function() if P2Menu.IsOpen() then P2Menu.Close(true) end end,
    OnScreenModeChanged = function()
        P2Menu.OnScreenModeChanged()
        VanillaHUD.Sync()
    end,
    SyncHUD = VanillaHUD.Sync,
    SaveProfile = SaveP2Profile,
    Notify = Notify,
})

VanillaHUD.Init(Config, {
    IsP2MenuOpen = P2Menu.IsOpen,
})

ProfileStore.Init(Config, {
    OnProfileLoaded = function(prefs)
        local charCfg = Config.Characters or {}
        if type(prefs.TintMode) == "string" and prefs.TintMode ~= "" then
            CharacterApplier.CurrentTintMode = prefs.TintMode
        end
        if type(prefs.TintPaletteIndex) == "number" then
            CharacterApplier.CurrentTintPaletteIdx = prefs.TintPaletteIndex
            local pal = charCfg.TintColorPalettes and charCfg.TintColorPalettes[prefs.TintPaletteIndex]
            if pal and pal.Color then charCfg.TintColor = pal.Color end
        end
        if prefs.LastSplitScreenMode == 0 or prefs.LastSplitScreenMode == 1 then
            ViewportController.LastSplitScreenMode = prefs.LastSplitScreenMode
        end
        if type(prefs.ScreenMode) == "number" and prefs.ScreenMode >= 0 and prefs.ScreenMode <= 2 then
            ViewportController.CurrentScreenMode = prefs.ScreenMode
            if prefs.ScreenMode == 0 or prefs.ScreenMode == 1 then
                ViewportController.LastSplitScreenMode = prefs.ScreenMode
            end
            if SessionManager.IsP2Active() and not ViewportController.InCutsceneFullscreen and not ViewportController.InPauseFullscreen then
                ViewportController.ApplyScreenMode(ViewportController.CurrentScreenMode, true)
            end
        end
        if type(prefs.HUDSharedScale) == "number" then
            VanillaHUD.SetSharedScale(prefs.HUDSharedScale)
        end
        if type(prefs.ShowSharedPlayerCircles) == "boolean" and Config.HUD then
            Config.HUD.ShowSharedPlayerCircles = prefs.ShowSharedPlayerCircles
        end
        if type(prefs.ExperimentalEnabled) == "boolean" and Config.Experimental then
            Config.Experimental.Enabled = prefs.ExperimentalEnabled
        end
        if type(prefs.CustomFOVEnabled) == "boolean" then
            ViewportController.CustomFOVEnabled = prefs.CustomFOVEnabled
        end
        if type(prefs.CustomFOV) == "number" and prefs.CustomFOV >= 70.0 and prefs.CustomFOV <= 120.0 then
            ViewportController.CustomFOV = prefs.CustomFOV
        end
        if type(prefs.DynamicSharedCameraEnabled) == "boolean" then
            ViewportController.DynamicSharedCameraEnabled = prefs.DynamicSharedCameraEnabled
        end
    end,
})

SessionManager.Init(Config, {
    EnsureHooksInstalled = function() InstallRuntimeHooks() end,
    Notify = Notify,
    SaveProfile = SaveP2Profile,
    OnWorldChanged = function()
        CatalogService.OnWorldChanged()
        ViewportController.ResetOnWorldRestart()
        ReviveSystem.Reset()
        ReviveOverlay.Destroy()
        PlayerMarkers.Destroy()
        P2Menu.OnWorldChanged()
        VanillaHUD.Destroy()
        JoinPrompt.Destroy()
        Notifications.Destroy()
        InputRouting.ResetAllLocks()
        InputRouting.ResetMenuState()
    end,
    BeforeP2Create = function()
        InputRouting.ApplyGamepadOffsetBeforeSpawn()
    end,
    OnP2ConnectingStart = function(msg)
        JoinPrompt.ShowConnecting(msg)
    end,
    OnP2ConnectingStatus = function(msg)
        JoinPrompt.ShowConnecting(msg)
    end,
    OnP2ConnectingEnd = function(success)
        JoinPrompt.FinishConnecting(success == true)
    end,
    WrapP2Spawn = function(p1Ctrl, spawnFn)
        return PlayerStateIsolation.WrapP2Spawn(p1Ctrl, spawnFn)
    end,
    OnP2ControllerCreated = function(p1Ctrl, p2Ctrl)
        PlayerStateIsolation.IsolatePlayer2State(p1Ctrl, p2Ctrl)
    end,
    OnP2SpawnImmediate = function()
        UITheme.PlayUISound("Join", true)
        InputRouting.SyncGamepadOffset(false)
        ViewportController.ApplyScreenMode(ViewportController.CurrentScreenMode, true)
    end,
    OnP2Ready = function(p1Ctrl, p2Ctrl)
        ApplyFullP2Setup(p1Ctrl, p2Ctrl)
        ViewportController.LocalizeAllLayouts()
    end,
    OnP2Regrouped = function(p1Ctrl, p2Ctrl)
        if p2Ctrl then PlayerStateIsolation.IsolatePlayer2State(p1Ctrl, p2Ctrl) end
    end,
    BeforeP2Despawn = function()
        SaveP2Profile()
        local p2 = SessionManager.GetP2()
        if P2Menu.IsOpen() then P2Menu.Close(true) end
        P2Menu.OnWorldChanged()
        if p2 then InputRouting.ClearAllLocksForPlayer(1, p2) end
        VanillaHUD.Destroy()
        PlayerMarkers.Destroy()
        ReviveSystem.Reset()
        ReviveOverlay.Destroy()
        ViewportController.ReleaseSharedMidpointCamera(0.10)
        ViewportController.InCutsceneFullscreen = false
        ViewportController.InPauseFullscreen = false
        ViewportController.SavedPreCutsceneMode = nil
    end,
    AfterP2Despawn = function()
        InputRouting.SyncGamepadOffset(false)
        ViewportController.LocalizeAllLayouts()
        if not InputRouting.IsAnyNativeMenuOpen() then
            InputRouting.RestoreInputForAllPlayers()
        end
        VanillaHUD.Destroy()
    end,
})

InputRouting.Init(Config, {
    IsP2MenuOpen = P2Menu.IsOpen,
    IsPausedByP2Menu = P2Menu.IsPausedByP2Menu,
    OpenP2Menu = function(tabIdx, subIdx) P2Menu.Open(tabIdx, subIdx) end,
    CloseP2MenuIfOpen = function() if P2Menu.IsOpen() then P2Menu.Close(false) end end,
    OnJoinHoldProgress = JoinPrompt.SetJoinProgress,
    Notify = Notify,
})

ReviveSystem.Init(Config, {
    Notify = Notify,
    OnPlayerRevived = function(pid, pawn)
        if pid == 1 then
            CharacterApplier.ApplyP2VisualStyling(pawn)
        end
        if not ViewportController.IsArenaCameraActive() then
            local p1, p1Pawn = SessionManager.GetP1(), SessionManager.GetP1Pawn()
            if p1 and p1Pawn then
                pcall(function() p1:SetViewTargetWithBlend(p1Pawn, 0.25, 0, 0.0, false) end)
            end
        end
        VanillaHUD.Sync()
    end,
})

PlayerMarkers.Init(Config, {
    IsPlayerDowned = function(pid)
        local s = ReviveSystem.Players[pid]
        return s ~= nil and (s.State == "Downed" or s.State == "BeingRevived")
    end,
})

P2Menu.Init(Config, {
    Notify = Notify,
    SaveProfile = SaveP2Profile,
    SyncHUD = VanillaHUD.Sync,
    CycleTintMode = CycleP2TintMode,
    ToggleExperimental = ToggleExperimentalFeatures,
    SetTintPalette = function(pIdx)
        local charCfg = Config.Characters or {}
        local pal = charCfg.TintColorPalettes and charCfg.TintColorPalettes[pIdx]
        if not pal then return end
        CharacterApplier.CurrentTintPaletteIdx = pIdx
        charCfg.TintColor = pal.Color
        if CharacterApplier.CurrentTintMode == "Off" then
            CharacterApplier.CurrentTintMode = "AccentOnly"
        end
        SessionManager.RefreshControllers()
        local p2Pawn = SessionManager.GetP2Pawn()
        if p2Pawn then CharacterApplier.ApplyP2VisualStyling(p2Pawn) end
        SaveP2Profile()
    end,
    ApplyCharacter = function(charKey)
        SessionManager.RefreshControllers()
        local p1, p2, p2Pawn = SessionManager.GetP1(), SessionManager.GetP2(), SessionManager.GetP2Pawn()
        if not (p2 and p2Pawn) then return end
        local ok, entry = CharacterApplier.ApplyToP2(p1, p2, p2Pawn, charKey)
        if ok and entry then
            SaveP2Profile()
            Notify("Player 2 Character: " .. tostring(entry.Name), "Success")
        else
            Notify("Could not load character assets (check UE4SS.log).", "Error")
        end
    end,
    EquipDance = function(slotIdx, danceDef)
        SessionManager.RefreshControllers()
        local p1, p2, p2Pawn = SessionManager.GetP1(), SessionManager.GetP2(), SessionManager.GetP2Pawn()
        if not (p2 and p2Pawn and UObjectUtils.IsValid(danceDef)) then return end
        local p2Store = ProfileStore.GetP2()
        for other = 0, 3 do
            if other ~= slotIdx and UObjectUtils.IsValid(p2Store.DanceSlots[other])
                and UObjectUtils.Same(p2Store.DanceSlots[other], danceDef) then
                ProfileStore.SetP2Dance(other, p2Store.DanceSlots[slotIdx])
            end
        end
        ProfileStore.SetP2Dance(slotIdx, danceDef)
        PlayerStateIsolation.ApplyDancesAndSkillsToP2(p1, p2, p2Pawn)
        SaveP2Profile()
    end,
    ApplySkillPreset = function(idx)
        SessionManager.RefreshControllers()
        local p1, p2, p2Pawn = SessionManager.GetP1(), SessionManager.GetP2(), SessionManager.GetP2Pawn()
        if not (p2 and p2Pawn) then return end
        local p2Store = ProfileStore.GetP2()
        p2Store.CustomSkillsOverride = false
        ProfileStore.ApplyLoadoutPresetToStore(idx, function() return PlayerStateIsolation.CaptureP1Snapshot(p1) end)
        p2Store.CustomSkillsOverride = true
        PlayerStateIsolation.ApplyDancesAndSkillsToP2(p1, p2, p2Pawn)
        SaveP2Profile()
        VanillaHUD.Sync()
    end,
    EquipBossSkill = function(slotIdx, bossDef)
        SessionManager.RefreshControllers()
        local p1, p2, p2Pawn = SessionManager.GetP1(), SessionManager.GetP2(), SessionManager.GetP2Pawn()
        if not (p2 and p2Pawn and UObjectUtils.IsValid(bossDef)) then return end
        local p2Store = ProfileStore.GetP2()
        p2Store.CustomSkillsOverride = true
        for other = 0, 3 do
            if other ~= slotIdx and UObjectUtils.IsValid(p2Store.BossAbilitySlots[other])
                and UObjectUtils.Same(p2Store.BossAbilitySlots[other], bossDef) then
                ProfileStore.SetP2BossAbility(other, p2Store.BossAbilitySlots[slotIdx])
                if UObjectUtils.IsValid(p2Store.BossAbilitySlots[other]) then
                    PlayerStateIsolation.EquipBossAbilityOnP2(p1, p2, p2Store.BossAbilitySlots[other], other)
                end
            end
        end
        ProfileStore.SetP2BossAbility(slotIdx, bossDef)
        PlayerStateIsolation.EquipBossAbilityOnP2(p1, p2, bossDef, slotIdx)
        SaveP2Profile()
        VanillaHUD.Sync()
    end,
    ToggleUpgrade = function(def)
        SessionManager.RefreshControllers()
        PlayerStateIsolation.ToggleUpgradeOnP2(SessionManager.GetP1(), SessionManager.GetP2(), def)
        SaveP2Profile()
        VanillaHUD.Sync()
    end,
    ToggleUnlockAllUpgrades = function(enableAll)
        SessionManager.RefreshControllers()
        PlayerStateIsolation.SetAllUpgradesForP2(SessionManager.GetP1(), SessionManager.GetP2(), enableAll == true)
        SaveP2Profile()
        VanillaHUD.Sync()
    end,
    ApplyOutfitPreset = function(idx)
        if not UObjectUtils.CanTrigger("P2OutfitApply", 0.55) then return end
        SessionManager.RefreshControllers()
        local p1, p2, p2Pawn = SessionManager.GetP1(), SessionManager.GetP2(), SessionManager.GetP2Pawn()
        if not (p2 and p2Pawn) then return end
        ProfileStore.ApplyOutfitPresetToStore(idx)
        if ProfileStore.GetP2().CharacterKey ~= "Default" then
            CharacterApplier.ApplyToP2(p1, p2, p2Pawn, "Default")
        else
            PlayerStateIsolation.ApplyOutfitToP2(p1, p2, p2Pawn)
            ScheduleP2VisualStyling(280)
        end
        SaveP2Profile()
    end,
    EquipCosmetic = function(slotNum, def)
        if not UObjectUtils.CanTrigger("P2OutfitApply", 0.45) then return end
        SessionManager.RefreshControllers()
        local p1, p2, p2Pawn = SessionManager.GetP1(), SessionManager.GetP2(), SessionManager.GetP2Pawn()
        if not (p2 and p2Pawn and UObjectUtils.IsValid(def)) then return end
        local p2Store = ProfileStore.GetP2()
        ProfileStore.SetP2Cosmetic(slotNum, def)
        p2Store.CustomPieceOverride = true
        if p2Store.CharacterKey ~= "Default" then
            CharacterApplier.ApplyToP2(p1, p2, p2Pawn, "Default")
            return
        end
        PlayerStateIsolation.ApplyOutfitToP2(p1, p2, p2Pawn)
        ScheduleP2VisualStyling(280)
        SaveP2Profile()
    end,
})

-- ============================================================================
-- ENGINE & BLUEPRINT HOOK INSTALLATION
-- ============================================================================

InstallRuntimeHooks = function()
    local inCfg = Config.Input or {}
    local vpCfg = Config.Viewport or {}

    -- 1. ClientRestart: PRE isolates P2 PlayerState; DeferredPost restores session & HUD
    HookRegistry.RegisterNative(
        "/Script/Engine.PlayerController:ClientRestart",
        function(Context)
            local pc = Context:get()
            if UObjectUtils.IsLive(pc) and SessionManager.GetPlayerIndex(pc) == 1 then
                PlayerStateIsolation.IsolatePlayer2State(SessionManager.GetP1(), pc)
            end
        end,
        function()
            if SessionManager.State.Phase == "Spawning" or SessionManager.State.Phase == "Despawning" then return end
            Scheduler.ReplaceDelay(220, "ClientRestart.Restore", function()
                if SessionManager.State.Phase == "Spawning" or SessionManager.State.Phase == "Despawning" then return end
                ViewportController.ResetOnWorldRestart()
                ReviveSystem.Reset()
                if not P2Menu.IsOpen() then P2Menu.OnWorldChanged() end
                VanillaHUD.Destroy()
                InstallRuntimeHooks()
                InitEngineState()
                SessionManager.RefreshControllers()
                local p1, p2 = SessionManager.GetP1(), SessionManager.GetP2()
                if p1 and p2 then
                    ApplyFullP2Setup(p1, p2)
                    SessionManager.EnforceSingletonP2()
                end
            end, true)
        end,
        { DeferredPost = true }
    )

    -- 2. Strict P1 <-> P2 Skill Isolation Guards
    HookRegistry.RegisterNative(
        "/Script/Pagoda.PagodaPlayerUpgradeComponent:HandleUpgradeEquippedStateChanged",
        function(Context, TagParam)
            local comp = Context and Context:get() or nil
            local tagStruct = TagParam and TagParam:get() or nil
            PlayerStateIsolation.OnHandleUpgradeStateChanged(comp, tagStruct)
        end
    )
    HookRegistry.RegisterNative(
        "/Script/Pagoda.PagodaPlayerUpgradeCatalogSubsystem:ToggleUpgradeEquippedState",
        function()
            PlayerStateIsolation.OnP1LoadoutEdited()
        end
    )
    HookRegistry.RegisterNative(
        "/Script/Pagoda.PagodaPlayerUpgradeComponent:EquipOrSwapBossAbilityAtSlot",
        function(Context)
            if PlayerStateIsolation.IsInScopedP2Write() then return end
            local comp = Context and Context:get() or nil
            local owner = UObjectUtils.IsValid(comp) and comp:GetOwner() or nil
            local p2Pawn = SessionManager.GetP2Pawn()
            if p2Pawn and UObjectUtils.IsLive(owner) and UObjectUtils.Same(owner, p2Pawn) then return end
            PlayerStateIsolation.OnP1LoadoutEdited()
        end
    )
    HookRegistry.RegisterNative(
        "/Script/Pagoda.PagodaPlaythroughPlayerData:EquipDanceMoveToSlot",
        function(Context)
            local obj = Context and Context:get() or nil
            if PlayerStateIsolation.IsDedicatedP2PPD(obj) then return end
            PlayerStateIsolation.OnP1LoadoutEdited()
        end
    )

    -- 3. Event-Driven Revive FSM Interception (OnHealthChanged / OnDamageReceived / OnDeathStarted)
    for _, dmgHook in ipairs({
        "/Script/Pagoda.PagodaCharacter:OnHealthChanged",
        "/Script/Pagoda.PagodaCharacter:OnDamageReceived",
        "/Script/Pagoda.PagodaCharacter:OnDeathStarted",
    }) do
        HookRegistry.RegisterNative(dmgHook, function(Context)
            local victim = Context and Context:get() or nil
            if UObjectUtils.IsLive(victim) then
                ReviveSystem.OnPawnEvent(victim)
            end
        end)
    end

    -- 4. Async Cosmetics & Dive Bar Wardrobe Close -> Reassert P2 Visual Stack
    local function OnCosmeticsApplied(Context)
        if not SessionManager.IsSafeForGameplayHooks() then return end
        local comp = Context:get()
        if not UObjectUtils.IsLive(comp) then return end
        local owner = comp:GetOwner()
        if not UObjectUtils.IsLive(owner) then return end

        Scheduler.Defer("OnCosmeticsApplied", function()
            if not (SessionManager.IsSafeForGameplayHooks() and UObjectUtils.IsLive(owner)) then return end
            SessionManager.RefreshControllers()
            local p2Pawn = SessionManager.GetP2Pawn()
            if p2Pawn and UObjectUtils.Same(p2Pawn, owner) then
                CharacterApplier.ReassertMeshOnly(p2Pawn)
            end
        end, true)
    end
    HookRegistry.RegisterNative("/Script/Pagoda.PagodaPlayerCosmeticComponent:OnCosmeticsApplied", OnCosmeticsApplied)
    HookRegistry.RegisterScript("/Game/Pagoda/Characters/Player/Components/BPC_PlayerCosmeticComponent.BPC_PlayerCosmeticComponent_C:OnCosmeticsApplied", OnCosmeticsApplied)

    HookRegistry.RegisterScript("/Game/Pagoda/UI/Cosmetics/WBP_Cosmetics_Main.WBP_Cosmetics_Main_C:BP_OnActivated", function()
        Scheduler.Delay(35, "DiveBar.CosmeticsAspect", ViewportController.SyncP1DiveBarMenuAspect, true)
    end)

    HookRegistry.RegisterScript("/Game/Pagoda/UI/Cosmetics/WBP_Cosmetics_Main.WBP_Cosmetics_Main_C:BP_OnDeactivated", function()
        Scheduler.Delay(40, "CosmeticsClose.RestoreAspect", ViewportController.SyncP1DiveBarMenuAspect, true)
        Scheduler.Delay(160, "CosmeticsClose.ReapplyP2", function()
            SessionManager.RefreshControllers()
            local p1, p2, p2Pawn = SessionManager.GetP1(), SessionManager.GetP2(), SessionManager.GetP2Pawn()
            if p2 and p2Pawn then
                local key = ProfileStore.GetP2().CharacterKey
                if key and key ~= "Default" then
                    CharacterApplier.ReassertMeshOnly(p2Pawn)
                else
                    PlayerStateIsolation.ApplyOutfitToP2(p1, p2, p2Pawn)
                    CharacterApplier.ApplyP2VisualStyling(p2Pawn)
                end
            end
        end, true)
    end)

    for _, diveMenuHook in ipairs({
        "/Game/Pagoda/UI/SkillTree/WBP_SkillTree_Main.WBP_SkillTree_Main_C:BP_OnActivated",
        "/Game/Pagoda/UI/SkillTree/WBP_SkillTree_Main.WBP_SkillTree_Main_C:BP_OnDeactivated",
        "/Game/Pagoda/UI/MoveList/WBP_MoveList_Main.WBP_MoveList_Main_C:BP_OnActivated",
        "/Game/Pagoda/UI/MoveList/WBP_MoveList_Main.WBP_MoveList_Main_C:BP_OnDeactivated",
    }) do
        HookRegistry.RegisterScript(diveMenuHook, function()
            Scheduler.Delay(35, "DiveBar.MenuAspect", ViewportController.SyncP1DiveBarMenuAspect, true)
        end)
    end

    -- 5. Dive Bar Station Interception for Player 2 (Exact 5-Tab Indices)
    HookRegistry.RegisterScript("/Game/Pagoda/Levels/DiveBar/BP_DiveBar_Interact_Cosmetics.BP_DiveBar_Interact_Cosmetics_C:Interact", function(Context)
        if inCfg.InterceptDiveBarStationsForP2 == false then return end
        local st = Context:get()
        if InputRouting.DidP2TriggerStation(st) then
            Scheduler.Delay(35, "DiveBar.OpenOutfits", function()
                local menus = FindAllOf("WBP_Cosmetics_Main_C")
                if menus then
                    for _, m in pairs(menus) do
                        if UObjectUtils.IsLive(m) then
                            local okA, act = pcall(function() return m:IsActivated() end)
                            if okA and act then pcall(function() m:DeactivateWidget() end) end
                        end
                    end
                end
                InputRouting.RestoreInputForAllPlayers()
                P2Menu.Open(1, 2) -- Tab 1 (CHARACTER), Sub 2 (OUTFITS)
            end, true)
        end
    end)

    HookRegistry.RegisterScript("/Game/Pagoda/Levels/DiveBar/BP_DiveBar_Interact_SkillTree.BP_DiveBar_Interact_SkillTree_C:Interact", function(Context)
        if inCfg.InterceptDiveBarStationsForP2 == false then return end
        local st = Context:get()
        if InputRouting.DidP2TriggerStation(st) then
            Scheduler.Delay(35, "DiveBar.OpenSkills", function()
                local menus = FindAllOf("WBP_SkillTree_Main_C")
                if menus then
                    for _, m in pairs(menus) do
                        if UObjectUtils.IsLive(m) then
                            local okA, act = pcall(function() return m:IsActivated() end)
                            if okA and act then pcall(function() m:DeactivateWidget() end) end
                        end
                    end
                end
                InputRouting.RestoreInputForAllPlayers()
                P2Menu.Open(2, 1) -- Tab 2 (MOVES / Boss Skills)
            end, true)
        end
    end)

    -- 6. Deadlock-Free Universal Centralized Pause Menu
    HookRegistry.RegisterScript("/Game/Pagoda/UI/BPFL_UI.BPFL_UI_C:PushToGameUIStack", function()
        Scheduler.Delay(25, "UIStack.PauseGuard", function()
            if inCfg.RoutePauseMenuToPrimaryViewport ~= false then
                InputRouting.DeactivateOrphanP2PauseMenus()
            end
            ViewportController.LocalizeAllLayouts()
            VanillaHUD.Sync()
        end)
    end)

    HookRegistry.RegisterScript("/Game/Pagoda/UI/Game/WBP_PauseMenu_Main.WBP_PauseMenu_Main_C:BP_OnActivated", function(Context)
        local pm = Context and Context:get() or nil
        if not UObjectUtils.IsLive(pm) then return end
        local own = nil
        pcall(function() own = pm:GetOwningPlayer() end)
        local pid = SessionManager.GetPlayerIndex(own)
        if pid ~= nil and pid >= 1 and inCfg.RoutePauseMenuToPrimaryViewport ~= false then
            Scheduler.Defer("Pause.CentralizeFromP2", InputRouting.DeactivateOrphanP2PauseMenus)
        end
    end)

    HookRegistry.RegisterNative("/Script/Pagoda.PagodaGamePauseSubsystem:SetIsPaused", function()
        Scheduler.Delay(30, "PauseSubsystem.Post", function()
            if P2Menu.IsPausedByP2Menu() then
                VanillaHUD.Sync()
                return
            end
            if InputRouting.IsGamePaused() then
                if P2Menu.IsOpen() then P2Menu.Close(true) end
                InputRouting.SyncGamepadOffset(false)
                if inCfg.RoutePauseMenuToPrimaryViewport ~= false then
                    InputRouting.DeactivateOrphanP2PauseMenus()
                end
                InputRouting.EnsurePauseMenuFocused()
            else
                pcall(function()
                    local menus = FindAllOf("WBP_PauseMenu_Main_C")
                    if menus then
                        for _, pm in pairs(menus) do
                            if UObjectUtils.IsLive(pm) then
                                local okA, act = pcall(function() return pm:IsActivated() end)
                                if okA and act then
                                    pm.bResumeGameOnDeactivation = false
                                    pm.bShowCountdownOnDeactivate = false
                                    pm:DeactivateWidget()
                                end
                            end
                        end
                    end
                end)
                InputRouting.SyncGamepadOffset(false)
                Scheduler.ReplaceDelay(150, "Pause.UnpauseRestore", function()
                    if not P2Menu.IsPausedByP2Menu()
                        and not InputRouting.IsGamePaused()
                        and not InputRouting.IsAnyNativeMenuOpen()
                        and UObjectUtils.IsGameplayWorld() then
                        InputRouting.RestoreInputForAllPlayers()
                    end
                end, true)
            end
            VanillaHUD.Sync()
        end)
    end)

    HookRegistry.RegisterScript("/Game/Pagoda/UI/Game/WBP_PauseMenu_Main.WBP_PauseMenu_Main_C:HandleCountdownComplete", function()
        Scheduler.Defer("Pause.CountdownDone", function()
            InputRouting.SyncGamepadOffset(false)
            if not P2Menu.IsPausedByP2Menu() and not InputRouting.IsAnyNativeMenuOpen() then
                InputRouting.RestoreInputForAllPlayers()
            end
        end)
    end)

    HookRegistry.RegisterScript("/Game/Pagoda/UI/Game/WBP_PauseMenu_Main.WBP_PauseMenu_Main_C:HandleResumeGame", function(Context)
        local pm = Context:get()
        local hasCountdown = false
        if UObjectUtils.IsValid(pm) then
            pcall(function() hasCountdown = (pm.bShowCountdownOnDeactivate == true) end)
        end
        if not hasCountdown then
            Scheduler.Delay(60, "Pause.EnsureResume", function()
                local sub = FindFirstOf("PagodaGamePauseSubsystem")
                if UObjectUtils.IsValid(sub) and sub:IsPaused() then
                    pcall(function() sub:SetIsPaused(false) end)
                end
            end)
        end
    end)

    -- 7. Cutscene Fullscreen Collapse (filters out Takedown / Finisher / P2 cameras)
    HookRegistry.RegisterNative("/Script/Engine.PlayerController:SetCinematicMode", function(_, bInCinematic)
        local enabled = bInCinematic and bInCinematic:get()
        Scheduler.Defer("CinematicMode", function()
            if enabled == true then
                ViewportController.EnterCutsceneFullscreen("SetCinematicMode")
            elseif enabled == false then
                ViewportController.ExitCutsceneFullscreen("SetCinematicMode(false)")
            end
        end)
    end)

    HookRegistry.RegisterNative("/Script/Engine.PlayerController:SetViewTargetWithBlend", function(Context, NewTarget)
        local pc = Context and Context:get() or nil
        local vt = NewTarget and NewTarget:get() or nil
        if not (UObjectUtils.IsLive(pc) and UObjectUtils.IsLive(vt)) then return end
        if ViewportController.IsSharedMidpointCameraActor(vt) then return end

        if SessionManager.ShouldViewTargetTriggerCutscene(pc, vt) then
            Scheduler.Defer("ViewTarget.Cutscene", function()
                ViewportController.EnterCutsceneFullscreen("CineCameraActor")
            end)
        elseif SessionManager.GetPlayerIndex(pc) == 0 and ViewportController.InCutsceneFullscreen then
            local vtName = ""
            pcall(function() vtName = vt:GetFullName() end)
            if vtName:find("PagodaPlayerCharacter", 1, true) then
                Scheduler.Defer("ViewTarget.ExitCutscene", function()
                    if not ViewportController.IsAnyCutsceneActive() then
                        ViewportController.ExitCutsceneFullscreen("ViewTarget->Player")
                    end
                end)
            end
        end
    end)

    for _, enterPath in ipairs({
        "/Game/Pagoda/Gameplay/BP_LevelSequenceDirector_Base.BP_LevelSequenceDirector_Base_C:SetCinematicMode",
        "/Game/Pagoda/Gameplay/BP_LevelSequenceDirector_Base.BP_LevelSequenceDirector_Base_C:SetCinematicModeByTag",
        "/Game/Pagoda/Gameplay/GameplaySegments/GA_GS_LevelIntro_Base.GA_GS_LevelIntro_Base_C:K2_ActivateAbilityWithPagodaParams",
        "/Game/Pagoda/UI/BPFL_UI.BPFL_UI_C:PushCutsceneToUIStack",
        "/Game/Pagoda/UI/Cutscenes/BP_BossCardVideoPlayer.BP_BossCardVideoPlayer_C:PushCutsceneWidget",
    }) do
        HookRegistry.RegisterScript(enterPath, function()
            Scheduler.Defer("CutsceneEnter", function() ViewportController.EnterCutsceneFullscreen(enterPath) end)
        end)
    end

    for _, exitPath in ipairs({
        "/Game/Pagoda/Gameplay/BP_LevelSequenceDirector_Base.BP_LevelSequenceDirector_Base_C:ClearCinematicMode",
        "/Game/Pagoda/Gameplay/BP_LevelSequenceDirector_Base.BP_LevelSequenceDirector_Base_C:ClearCinematicModeForIndex",
        "/Game/Pagoda/Gameplay/BP_LevelSequenceDirector_Base.BP_LevelSequenceDirector_Base_C:HandleSequenceComplete",
        "/Game/Pagoda/Gameplay/GameplaySegments/GA_GS_LevelIntro_Base.GA_GS_LevelIntro_Base_C:HandleSequenceComplete",
        "/Game/Pagoda/Gameplay/GameplaySegments/GA_GS_LevelIntro_Base.GA_GS_LevelIntro_Base_C:K2_OnEndAbility",
        "/Game/Pagoda/Gameplay/GameplaySegments/GA_GS_LevelIntro_Base.GA_GS_LevelIntro_Base_C:SkipLevelSequence",
        "/Game/Pagoda/Gameplay/GameplaySegments/GA_GS_BossTransition_Base.GA_GS_BossTransition_Base_C:K2_OnEndAbility",
        "/Game/Pagoda/UI/Cutscenes/WBP_CutsceneVideoContainer.WBP_CutsceneVideoContainer_C:HandlePlayEnded",
        "/Game/Pagoda/UI/Cutscenes/WBP_CutsceneVideoContainer.WBP_CutsceneVideoContainer_C:HandleVideoSkipped",
        "/Game/Pagoda/UI/Cutscenes/WBP_CutsceneVideoContainer.WBP_CutsceneVideoContainer_C:BP_OnDeactivated",
        "/Game/Pagoda/UI/Cutscenes/BP_BossCardVideoPlayer.BP_BossCardVideoPlayer_C:HideCutsceneWidget",
    }) do
        HookRegistry.RegisterScript(exitPath, function()
            Scheduler.Defer("CutsceneExit", function()
                if not ViewportController.IsAnyCutsceneActive() then
                    ViewportController.ExitCutsceneFullscreen(exitPath)
                end
            end)
        end)
    end

    -- 8. Non-Destructive Viewport Localization & Native HUD Sync
    HookRegistry.RegisterNative("/Script/UMG.UserWidget:AddToViewport", function(Context, ZOrder)
        if ViewportController.RehostingGuard or not SessionManager.IsSafeForGameplayHooks() then return end
        local widget = Context and Context:get() or nil
        local z = (ZOrder and ZOrder:get()) or 0
        if UObjectUtils.IsLive(widget) and ViewportController.IsSplitScreenActive() then
            Scheduler.Defer("ConfineWidget", function()
                if UObjectUtils.IsLive(widget) then
                    ViewportController.ConfineRootHUDWidget(widget, z)
                end
            end, true)
        end
    end)

    for _, layoutHook in ipairs({
        "/Script/Pagoda.PagodaActivatableWidget:OnPushToContainer",
        "/Script/Pagoda.PagodaActivatableWidget:OnAddNonInteractiveHUDElement",
    }) do
        HookRegistry.RegisterNative(layoutHook, function()
            if not SessionManager.IsSafeForGameplayHooks() then return end
            Scheduler.Defer("LocalizeLayouts", function()
                ViewportController.LocalizeAllLayouts()
            end, true)
        end)
    end

    for _, layoutBpHook in ipairs({
        "/Game/Pagoda/UI/Game/UI_Layout_Game.UI_Layout_Game_C:Construct",
        "/Game/Pagoda/UI/Game/UI_Layout_Game.UI_Layout_Game_C:PushToStack",
        "/Game/Pagoda/UI/Game/UI_Layout_HubArea.UI_Layout_HubArea_C:OnPushToContainer",
    }) do
        HookRegistry.RegisterScript(layoutBpHook, function()
            if not SessionManager.IsSafeForGameplayHooks() then return end
            Scheduler.Defer("LocalizeLayouts", function()
                ViewportController.LocalizeAllLayouts()
            end, true)
        end)
    end

    -- 9. Event-Driven Gamepad AnyKey Listener (routes all P2 gamepad key events)
    local function HandleAnyGamepadKey(Context, KeyParam)
        local pc = Context:get()
        if not UObjectUtils.IsLive(pc) then return end
        local ks = (KeyParam and KeyParam:get()) or KeyParam
        local keyName = (ks and ks.KeyName and ks.KeyName:ToString()) or ""
        if keyName:find("^Gamepad_") then
            InputRouting.OnGamepadKey(pc, keyName)
            if keyName == (inCfg.GamepadMenuToggleKey or "Gamepad_Special_Left") then
                Scheduler.Delay(160, "Input.ChordFollowup", function()
                    if UObjectUtils.IsLive(pc) then
                        InputRouting.OnGamepadKey(pc, nil)
                    end
                end, true)
            end
        end
    end
    HookRegistry.RegisterScript(
        "/Game/Pagoda/Characters/Player/BP_PagodaPlayerController.BP_PagodaPlayerController_C:InpActEvt_AnyKey_K2Node_InputKeyEvent_0",
        HandleAnyGamepadKey
    )

    -- Silence unused variable warning cleanly
    local _ = vpCfg
end

-- ============================================================================
-- OBJECT CREATION NOTIFICATIONS
-- ============================================================================

HookRegistry.NotifyNewObject("/Script/Pagoda.PagodaPlayerState", function(ps)
    PlayerStateIsolation.IsolatePlayerStateObject(ps)
end, true)

HookRegistry.NotifyNewObject("/Script/Pagoda.PagodaUILayoutWidget", function(obj)
    InstallRuntimeHooks()
    if UObjectUtils.IsLive(obj) then ViewportController.RefreshLayoutLocalization(obj) end
end, false)

for _, clsPath in ipairs({
    "/Script/Pagoda.PagodaPlayerController",
    "/Script/Engine.LevelSequenceActor",
    "/Game/Pagoda/Levels/DiveBar/BP_DiveBar_Interact_Cosmetics.BP_DiveBar_Interact_Cosmetics_C",
    "/Game/Pagoda/Levels/DiveBar/BP_DiveBar_Interact_SkillTree.BP_DiveBar_Interact_SkillTree_C",
    "/Game/Pagoda/UI/Game/WBP_LevelEndScreen.WBP_LevelEndScreen_C",
}) do
    HookRegistry.NotifyNewObject(clsPath, function()
        InstallRuntimeHooks()
        VanillaHUD.Sync()
    end, false)
end

-- ============================================================================
-- SINGLE GAME-THREAD SCHEDULER LOOP BINDINGS
-- ============================================================================

Scheduler.Start()

-- Per-frame: Smooth Arena Camera midpoint, P2 Menu transitions, 3D/projected Revive circle & P1/P2 floor markers
Scheduler.OnFrame("MidpointCamera", ViewportController.TickDynamicMidpointCamera)
Scheduler.OnFrame("P2MenuTransition", P2Menu.TickTransition)
Scheduler.OnFrame("ReviveOverlay", ReviveOverlay.TickFrame)
Scheduler.OnFrame("PlayerMarkers", PlayerMarkers.TickFrame)

-- 50ms interactive loop: P2 Menu input, Revive hold/proximity FSM, Pause & Join bridge, Dive Bar prompt, Toasts
Scheduler.Every(50, "FastInteractive", function(now)
    P2Menu.TickInput(now)
    InputRouting.TickPauseSafety(now)
    InputRouting.TickJoinChord(now)
    JoinPrompt.Tick(now)
    ReviveSystem.Tick(now)
    Notifications.Tick(now)
    if (now - LastFastHudSyncAt) >= 0.20 then
        LastFastHudSyncAt = now
        VanillaHUD.Sync()
    end
end)

-- 500ms loop: Auto-gamepad detection, native P2 HUD verification & Dive Bar menu aspect ratio sync
Scheduler.Every(500, "HUDSyncAndInput", function(now)
    InputRouting.TickAutoGamepadRouting(now)
    VanillaHUD.Sync()
    if UObjectUtils.IsInDiveBar(SessionManager.GetP1()) and ViewportController.IsSplitScreenActive() then
        ViewportController.SyncP1DiveBarMenuAspect()
    end
end)

-- 1000ms maintenance: GC cleanup, world transition check, singleton guard, isolation audit, CSM & leash
Scheduler.Every(1000, "Maintenance", function()
    UObjectUtils.PruneDestroyedCache()
    SessionManager.EnforceSingletonP2()
    SessionManager.RefreshControllers()

    local p1, p2 = SessionManager.GetP1(), SessionManager.GetP2()
    if p2 then
        PlayerStateIsolation.AuditIntegrity()
        CharacterApplier.TickWatchdog()
        SessionManager.VerifyP2MovementSanity(
            SessionManager.GetP2Pawn(),
            ReviveSystem.Players[1].State == "Downed" or ReviveSystem.Players[1].State == "BeingRevived",
            P2Menu.IsOpen()
        )
        if UObjectUtils.IsInDiveBar(p1) then
            ViewportController.EnforceDiveBarSplitScreen()
            ViewportController.SuppressP2DiveBarCredits()
        else
            local revCfg = Config.Revive or {}
            if revCfg.Enabled ~= false then
                local p1Pawn, p2Pawn = SessionManager.GetP1Pawn(), SessionManager.GetP2Pawn()
                if p1Pawn then ReviveSystem.ProtectPawn(0, p1Pawn, p1) end
                if p2Pawn then ReviveSystem.ProtectPawn(1, p2Pawn, p2) end
            end
        end
    end

    ViewportController.TickCutsceneWatchdog()
    SessionManager.TickAutoLeash(ViewportController.IsArenaCameraActive())
end)

-- ============================================================================
-- STARTUP & KEYBINDINGS
-- ============================================================================

InstallRuntimeHooks()
Scheduler.Defer("Startup.InitEngine", InitEngineState)

local function ToggleMenuTab(tabIdx)
    if not UObjectUtils.CanTrigger("ToggleMenuTab" .. tostring(tabIdx or "any"), 0.25) then return end
    Scheduler.RunOnGameThread("ToggleMenuTab", function()
        SessionManager.RefreshControllers()
        P2Menu.Toggle(tabIdx)
    end)
end

-- Minimal Keybindings Only: Connect P2, Open P2 Menu, Screen/Camera Mode
RegisterKeyBind(Key.F6, SessionManager.SpawnOrRegroupP2)
RegisterKeyBind(Key.F2, function() ToggleMenuTab(nil) end)
RegisterKeyBind(Key.F9, function() ViewportController.CycleScreenMode(false) end)

_G.__LocalCoopMod = {
    Version = "1.0-experimental",
    Config = Config,
    Logger = Logger,
    UObjectUtils = UObjectUtils,
    Scheduler = Scheduler,
    HookRegistry = HookRegistry,
    SessionManager = SessionManager,
    CatalogService = CatalogService,
    ProfileStore = ProfileStore,
    PlayerStateIsolation = PlayerStateIsolation,
    CharacterApplier = CharacterApplier,
    ViewportController = ViewportController,
    InputRouting = InputRouting,
    ReviveSystem = ReviveSystem,
    ReviveOverlay = ReviveOverlay,
    UITheme = UITheme,
    Notifications = Notifications,
    JoinPrompt = JoinPrompt,
    VanillaHUD = VanillaHUD,
    PlayerMarkers = PlayerMarkers,
    P2Menu = P2Menu,
}

print("[Dead as Disco - Local Co-op Mod] v1.0 (Experimental) Loaded Successfully!\n")
print("  [Hold L3+R3 or F6] : Connect Player 2\n")
print("  [P2 Select or F2]  : Player 2 Menu (Full in Dive Bar | Paused Limited Menu in Play)\n")
print("  [F9]               : Cycle Screen / Camera Mode\n")
