-- Mounts and synchronizes native UMG HUD widgets and combat indicators for Player 2
-- across split-screen (P2's GameHUDStack) and shared arena camera (modular P2 cluster).

local UObjectUtils = require("Utils.UObjectUtils")
local Logger = require("Utils.Logger")
local SessionManager = require("Core.SessionManager")
local PlayerStateIsolation = require("State.PlayerStateIsolation")
local ViewportController = require("Camera.ViewportController")
local InputRouting = require("Input.InputRouting")
local UITheme = require("UI.UITheme")

local VanillaHUD = {}

local Config = {}
local P2MenuIsOpenFn = nil

local NATIVE_WIDGETS = {
    HUDCanvas  = { Pkg = "/Game/Pagoda/UI/Game/WBP_HUDCanvas",                                  Cls = "WBP_HUDCanvas_C" },
    GameHUD    = { Pkg = "/Game/Pagoda/UI/Game/WBP_GameHUD",                                    Cls = "WBP_GameHUD_C" },
    Hearts     = { Pkg = "/Game/Pagoda/UI/Game/PlayerBars/WBP_PlayerHealth_Hearts",             Cls = "WBP_PlayerHealth_Hearts_C" },
    Tokens     = { Pkg = "/Game/Pagoda/UI/Game/ExecutionTokens/WBP_ExecutionTokenPips",         Cls = "WBP_ExecutionTokenPips_C" },
    FeverBar   = { Pkg = "/Game/Pagoda/UI/Game/PlayerBars/WBP_PlayerFeverBar",                  Cls = "WBP_PlayerFeverBar_C" },
    FeverMult  = { Pkg = "/Game/Pagoda/UI/Game/PlayerBars/WBP_FeverMultiplierIndicator",        Cls = "WBP_FeverMultiplierIndicator_C" },
    AbilityBar = { Pkg = "/Game/Pagoda/UI/Game/AbilityBar/WBP_AbilityBar_V2",                   Cls = "WBP_AbilityBar_V2_C" },
}

local SharedHost = {
    RootWidget = nil,
    ClusterBox = nil,
    SubWidgets = {},
    OwnerCtrlKey = nil,
    BoundPawnKey = nil,
    BoundWorldKey = nil,
    Visible = false,
}

local SplitMountedHUD = nil
local CachedP2GameLayout = nil
local SharedScaleOverride = nil
local CachedInActiveMatch = false
local CachedInActiveMatchAt = -1.0
local RegisteredTimedCompKeys = {}
local SyncedSettingsKeys = {}
local LastP2DangerOwnerMode = nil
local LastP2DangerPawnKey = nil
local LastIndicatorSweepAt = 0.0
local LastAttackTickUpdateAt = {} -- [widgetKey] = timestamp
local CachedPagodaAICompClass = nil

function VanillaHUD.InvalidateMatchState()
    CachedInActiveMatchAt = -1.0
end

function VanillaHUD.Init(config, callbacks)
    Config = config or {}
    local hudCfg = Config.HUD or {}
    SharedScaleOverride = tonumber(hudCfg.SharedScreenScale) or 0.78
    if callbacks and type(callbacks.IsP2MenuOpen) == "function" then
        P2MenuIsOpenFn = callbacks.IsP2MenuOpen
    end
    ViewportController.RegisterModWidget("VanillaHUD_Shared", function() return SharedHost.RootWidget end)
end

function VanillaHUD.GetSharedScale()
    local hudCfg = Config.HUD or {}
    return SharedScaleOverride or tonumber(hudCfg.SharedScreenScale) or 0.78
end

function VanillaHUD.SetSharedScale(scale)
    local clamped = math.max(0.55, math.min(1.15, tonumber(scale) or 0.78))
    SharedScaleOverride = clamped
    if Config.HUD then Config.HUD.SharedScreenScale = clamped end
    if UObjectUtils.IsValid(SharedHost.ClusterBox) then
        local hudCfg = Config.HUD or {}
        local ax = tonumber(hudCfg.SharedScreenAnchorX) or 0.020
        local pivotX = (ax <= 0.5) and 0.0 or 1.0
        pcall(function()
            SharedHost.ClusterBox:SetRenderTransformPivot({ X = pivotX, Y = 1.0 })
            SharedHost.ClusterBox:SetRenderScale({ X = clamped, Y = clamped })
        end)
    end
end

function VanillaHUD.StepSharedScale(delta)
    local cur = VanillaHUD.GetSharedScale()
    local nextVal = cur + (tonumber(delta) or 0.08)
    if nextVal > 1.12 then nextVal = 0.60 end
    if nextVal < 0.58 then nextVal = 1.10 end
    VanillaHUD.SetSharedScale(math.floor(nextVal * 100 + 0.5) / 100.0)
    return VanillaHUD.GetSharedScale()
end

function VanillaHUD.DestroySharedHost()
    for k, sw in pairs(SharedHost.SubWidgets) do
        if UObjectUtils.IsValid(sw) then
            pcall(function() sw:RemoveFromParent() end)
        end
        SharedHost.SubWidgets[k] = nil
    end
    if UObjectUtils.IsValid(SharedHost.RootWidget) then
        pcall(function() SharedHost.RootWidget:RemoveFromParent() end)
    end
    SharedHost.RootWidget = nil
    SharedHost.ClusterBox = nil
    SharedHost.OwnerCtrlKey = nil
    SharedHost.BoundPawnKey = nil
    SharedHost.BoundWorldKey = nil
    SharedHost.Visible = false
end

function VanillaHUD.DestroySplitMounted()
    if UObjectUtils.IsValid(SplitMountedHUD) then
        pcall(function()
            if type(SplitMountedHUD.DeactivateWidget) == "function" then
                SplitMountedHUD:DeactivateWidget()
            end
        end)
        pcall(function() SplitMountedHUD:RemoveFromParent() end)
    end
    SplitMountedHUD = nil
end

function VanillaHUD.ResetIndicators()
    CachedP2GameLayout = nil
    RegisteredTimedCompKeys = {}
    SyncedSettingsKeys = {}
    LastP2DangerOwnerMode = nil
    LastP2DangerPawnKey = nil
    LastIndicatorSweepAt = 0.0
    LastAttackTickUpdateAt = {}
end

function VanillaHUD.Destroy()
    VanillaHUD.DestroySharedHost()
    VanillaHUD.DestroySplitMounted()
    VanillaHUD.ResetIndicators()
end

function VanillaHUD.Hide()
    if UObjectUtils.IsValid(SharedHost.RootWidget) and SharedHost.Visible then
        pcall(function() SharedHost.RootWidget:SetVisibility(2) end) -- Hidden
        SharedHost.Visible = false
    end
end

local function ComputeIsInActiveMatch()
    if not SessionManager.IsP2Active() or not SessionManager.IsSafeForGameplayHooks() then return false end
    local p1Ctrl = SessionManager.GetP1()
    if not p1Ctrl then return false end
    if UObjectUtils.IsInDiveBar(p1Ctrl) then return false end
    if ViewportController.InPauseFullscreen or ViewportController.InP1MenuFullscreen then return false end
    if SessionManager.State.IsInCutscene or ViewportController.InCutsceneFullscreen then return false end
    if not (SessionManager.GetP1Pawn() and SessionManager.GetP2Pawn()) then return false end
    if SessionManager.IsLevelEndActive() then return false end

    local hudCfg = Config.HUD or {}
    if hudCfg.HideSharedHUDInMenus ~= false then
        if InputRouting.IsAnyNativeMenuOpen() then return false end
    end
    return true
end

function VanillaHUD.IsInActiveMatch()
    local now = os.clock()
    if (now - CachedInActiveMatchAt) < 0.18 then
        return CachedInActiveMatch
    end
    CachedInActiveMatch = ComputeIsInActiveMatch()
    CachedInActiveMatchAt = now
    return CachedInActiveMatch
end

local function ShouldShowSharedP2HUD()
    local hudCfg = Config.HUD or {}
    if hudCfg.EnableNativeP2HUD == false then return false end
    if not ViewportController.IsArenaCameraActive() then return false end
    if not SessionManager.GetP2Pawn() then return false end
    if P2MenuIsOpenFn and P2MenuIsOpenFn() then return false end
    return VanillaHUD.IsInActiveMatch()
end

-- ============================================================================
-- SPLIT-SCREEN NATIVE HUD VERIFICATION & MID-STAGE FALLBACK MOUNT
-- ============================================================================

local function EnsureHUDCanvasIndicatorsVisible(hudCanvas)
    if not UObjectUtils.IsLive(hudCanvas) then return end
    pcall(function()
        local v = hudCanvas:GetVisibility()
        if v == 1 or v == 2 then hudCanvas:SetVisibility(3) end
        if UObjectUtils.IsLive(hudCanvas.IndicatorLayer) then
            local iv = hudCanvas.IndicatorLayer:GetVisibility()
            if iv == 1 or iv == 2 then hudCanvas.IndicatorLayer:SetVisibility(3) end
        end
        pcall(function() hudCanvas:UpdateIndicatorVisbility() end)
    end)
end

local function FindP2GameLayoutAndHUD()
    local p2Layout = nil
    local hasNativeHUD = false
    -- Fast path: reuse cached P2 game layout instead of scanning all PagodaUILayoutWidgets repeatedly
    if UObjectUtils.IsLive(CachedP2GameLayout) then
        pcall(function()
            p2Layout = CachedP2GameLayout
            if UObjectUtils.IsLive(p2Layout.HUDCanvas) then
                EnsureHUDCanvasIndicatorsVisible(p2Layout.HUDCanvas)
                hasNativeHUD = true
            end
            if UObjectUtils.IsLive(p2Layout.GameHUDStack) then
                local act = p2Layout.GameHUDStack:GetActiveWidget()
                if UObjectUtils.IsLive(act) then
                    EnsureHUDCanvasIndicatorsVisible(act)
                    hasNativeHUD = true
                end
            end
        end)
        if hasNativeHUD then
            return p2Layout, true
        end
    end

    pcall(function()
        local layouts = FindAllOf("PagodaUILayoutWidget")
        if layouts then
            for _, lay in pairs(layouts) do
                if UObjectUtils.IsLive(lay) then
                    local own = nil
                    pcall(function() own = lay:GetOwningPlayer() end)
                    if SessionManager.GetPlayerIndex(own) == 1 then
                        local fn = ""
                        pcall(function() fn = lay:GetFullName() end)
                        if fn:find("UI_Layout_Game", 1, true) then
                            p2Layout = lay
                            CachedP2GameLayout = lay
                            if UObjectUtils.IsLive(lay.HUDCanvas) then
                                EnsureHUDCanvasIndicatorsVisible(lay.HUDCanvas)
                                hasNativeHUD = true
                            end
                            if UObjectUtils.IsLive(lay.GameHUDStack) then
                                local act = nil
                                pcall(function() act = lay.GameHUDStack:GetActiveWidget() end)
                                if UObjectUtils.IsLive(act) then
                                    EnsureHUDCanvasIndicatorsVisible(act)
                                    hasNativeHUD = true
                                end
                            end
                        end
                    end
                end
            end
        end

        if not hasNativeHUD then
            for _, clsName in ipairs({ "WBP_HUDCanvas_C", "WBP_GameHUD_C", "WBP_InfiniteDiscoHUD_C", "WBP_TowerHUD_C" }) do
                local list = FindAllOf(clsName)
                if list then
                    for _, w in pairs(list) do
                        if UObjectUtils.IsLive(w) then
                            local own = nil
                            pcall(function() own = w:GetOwningPlayer() end)
                            if SessionManager.GetPlayerIndex(own) == 1 then
                                EnsureHUDCanvasIndicatorsVisible(w)
                                hasNativeHUD = true
                                return
                            end
                        end
                    end
                end
            end
        end
    end)
    return p2Layout, hasNativeHUD
end

local function EnsureSplitScreenP2NativeHUD(p1Ctrl, p2Ctrl)
    local hudCfg = Config.HUD or {}
    if hudCfg.EnableNativeP2HUD == false then return end
    if not (p1Ctrl and p2Ctrl and SessionManager.GetP2Pawn()) then return end
    if UObjectUtils.IsInDiveBar(p1Ctrl) or SessionManager.State.IsInCutscene then return end
    if ViewportController.InPauseFullscreen or ViewportController.InP1MenuFullscreen then return end

    local p2Layout, hasNativeHUD = FindP2GameLayoutAndHUD()
    if UObjectUtils.IsLive(p2Layout) then
        pcall(function()
            local v = p2Layout:GetVisibility()
            if v == 1 or v == 2 then
                p2Layout:SetVisibility(3) -- SelfHitTestInvisible
            end
            if UObjectUtils.IsLive(p2Layout.GameHUDStack) then
                local sv = p2Layout.GameHUDStack:GetVisibility()
                if sv == 1 or sv == 2 then
                    p2Layout.GameHUDStack:SetVisibility(3)
                end
            end
            if UObjectUtils.IsLive(p2Layout.HUDCanvas) then
                EnsureHUDCanvasIndicatorsVisible(p2Layout.HUDCanvas)
            end
        end)
    end
    if hasNativeHUD then return end

    local hudCanvasCls = UObjectUtils.LoadClass(NATIVE_WIDGETS.HUDCanvas.Pkg, NATIVE_WIDGETS.HUDCanvas.Cls)
    local gameHudCls = UObjectUtils.IsValid(hudCanvasCls) and hudCanvasCls
        or UObjectUtils.LoadClass(NATIVE_WIDGETS.GameHUD.Pkg, NATIVE_WIDGETS.GameHUD.Cls)
    if not UObjectUtils.IsValid(gameHudCls) then return end

    local world = UObjectUtils.GetWorld()
    local wbl = UObjectUtils.GetWidgetBlueprintLibrary()
    if not (UObjectUtils.IsValid(world) and UObjectUtils.IsValid(wbl)) then return end

    PlayerStateIsolation.WithScopedP2PPD(p1Ctrl, "VanillaHUD.SplitMount", function()
        local mounted = nil
        if UObjectUtils.IsLive(p2Layout) and UObjectUtils.IsLive(p2Layout.GameHUDStack) then
            local okPush, pushed = pcall(function() return p2Layout.GameHUDStack:BP_AddWidget(gameHudCls) end)
            if okPush and UObjectUtils.IsLive(pushed) then
                mounted = pushed
                pcall(function() pushed:ActivateWidget() end)
            end
        end
        if not UObjectUtils.IsLive(mounted) then
            local okCreate, w = pcall(function() return wbl:Create(world, gameHudCls, p2Ctrl) end)
            if okCreate and UObjectUtils.IsLive(w) then
                ViewportController.RehostingGuard = true
                local okPS = pcall(function() w:AddToPlayerScreen(0) end)
                ViewportController.RehostingGuard = false
                if okPS then mounted = w end
            end
        end

        if UObjectUtils.IsLive(mounted) then
            SplitMountedHUD = mounted
            EnsureHUDCanvasIndicatorsVisible(mounted)
            Logger.Info("VanillaHUD", "Mounted native HUDCanvas/GameHUD onto Player 2 split viewport.")
        else
            Logger.Warn("VanillaHUD", "Could not mount fallback HUD on P2 split screen.")
        end
    end)
end

-- ============================================================================
-- PLAYER 2 ATTACK / COUNTER & DODGE / EVADE PROMPTS SYNCHRONIZATION
-- ============================================================================

local function GetActorDistance3D(a, b)
    if not (UObjectUtils.IsLive(a) and UObjectUtils.IsLive(b)) then return nil end
    local dist = nil
    pcall(function()
        local la = a:K2_GetActorLocation()
        local lb = b:K2_GetActorLocation()
        if la and lb then
            local dx, dy, dz = la.X - lb.X, la.Y - lb.Y, la.Z - lb.Z
            dist = math.sqrt(dx * dx + dy * dy + dz * dz)
        end
    end)
    return dist
end

local function ConfigurePawnDangerWidgets(pawn, ownerLP, isP2, forceUpdate)
    if not UObjectUtils.IsLive(pawn) then return end
    pcall(function()
        local dangerComp = pawn.DangerIndicatorComponent
        if UObjectUtils.IsValid(dangerComp) then
            dangerComp.PlayerBP = pawn
            dangerComp.EnableUIIndicator = true
            dangerComp.EnableVFX = true
        end

        if isP2 then
            for _, senseName in ipairs({ "RedCharlieSense", "YellowCharlieSense" }) do
                local sc = pawn[senseName]
                if UObjectUtils.IsValid(sc) then
                    pcall(function() sc:SetHiddenInGame(false, false) end)
                end
            end
        end

        -- Leave idle indicator widgets hidden until an attack or interaction activates them.
        for _, widgetCompName in ipairs({ "DangerIndicatorWidget", "InteractionIndicatorWidget" }) do
            local wc = pawn[widgetCompName]
            if UObjectUtils.IsValid(wc) then
                pcall(function()
                    if isP2 then
                        wc:SetHiddenInGame(false, false)
                    end
                    wc:SetCullDistance(0.0)
                    wc.bNeverDistanceCull = true
                    wc.bAllowCullDistanceVolume = false
                end)
                if UObjectUtils.IsValid(ownerLP) and forceUpdate then
                    pcall(function() wc:SetOwnerPlayer(ownerLP) end)
                end
            end
        end

        if isP2 and forceUpdate and UObjectUtils.IsValid(dangerComp) then
            pcall(function() dangerComp:UpdateIndicators() end)
        end
    end)
end

local function SyncP2DangerIndicatorComponent(p1Ctrl, p2Ctrl, p2Pawn)
    if not UObjectUtils.IsLive(p2Pawn) then return end
    pcall(function()
        local wantArenaOwner = ViewportController.IsArenaCameraActive()
        local modeKey = wantArenaOwner and "SharedP1" or "SplitP2"
        local pawnKey = UObjectUtils.GetKey(p2Pawn)
        local p1LP = UObjectUtils.IsLive(p1Ctrl) and p1Ctrl.Player or nil
        local p2LP = UObjectUtils.IsLive(p2Ctrl) and p2Ctrl.Player or nil
        local targetLP = wantArenaOwner and p1LP or p2LP
        local modeChanged = (LastP2DangerOwnerMode ~= modeKey or LastP2DangerPawnKey ~= pawnKey)

        local p1Pawn = SessionManager.GetP1Pawn()
        if UObjectUtils.IsLive(p1Pawn) then
            ConfigurePawnDangerWidgets(p1Pawn, p1LP, false, modeChanged)
        end
        ConfigurePawnDangerWidgets(p2Pawn, targetLP, true, modeChanged)

        if UObjectUtils.IsValid(targetLP) then
            LastP2DangerOwnerMode = modeKey
            LastP2DangerPawnKey = pawnKey
        end
    end)
end

function VanillaHUD.OnAttackSingleSetFarAway(single, bFarAwayParam)
    if not (SessionManager.IsP2Active() and UObjectUtils.IsLive(single)) then return end
    local shouldForce = ViewportController.IsArenaCameraActive()
    if not shouldForce then
        pcall(function()
            local own = single:GetOwningPlayer()
            if SessionManager.GetPlayerIndex(own) == 1 then shouldForce = true end
        end)
    end
    if shouldForce and bFarAwayParam then
        pcall(function() bFarAwayParam:set(false) end)
    end
end

function VanillaHUD.OnAttackSingleSetInteraction(single, bEnabledParam)
    if not (SessionManager.IsP2Active() and UObjectUtils.IsLive(single)) then return end
    local shouldForce = ViewportController.IsArenaCameraActive()
    if not shouldForce then
        pcall(function()
            local own = single:GetOwningPlayer()
            if SessionManager.GetPlayerIndex(own) == 1 then shouldForce = true end
        end)
    end
    if shouldForce and bEnabledParam then
        pcall(function() bEnabledParam:set(true) end)
    end
end

function VanillaHUD.OnAttackIndicatorPreUpdate(w)
    if not (SessionManager.IsP2Active() and UObjectUtils.IsLive(w)) then return end
    pcall(function()
        w.ShowAllPlayersIndicators = true
    end)
end

function VanillaHUD.OnAttackIndicatorPostUpdate(w, fromTick)
    if not (SessionManager.IsP2Active() and UObjectUtils.IsLive(w)) then return end
    local isSharedArena = ViewportController.IsArenaCameraActive()
    if fromTick and not isSharedArena then
        local now = os.clock()
        local wKey = UObjectUtils.GetKey(w)
        if wKey then
            local last = LastAttackTickUpdateAt[wKey] or 0.0
            if (now - last) < 0.06 then return end
            LastAttackTickUpdateAt[wKey] = now
        end
    end
    pcall(function()
        w.ShowAllPlayersIndicators = true

        local p2Pawn = SessionManager.GetP2Pawn()
        if not UObjectUtils.IsLive(p2Pawn) then return end

        local ownCtrl = nil
        pcall(function() ownCtrl = w:GetOwningPlayer() end)
        local pid = SessionManager.GetPlayerIndex(ownCtrl)
        local isRelevant = (pid == 1) or isSharedArena
        if not isRelevant then return end

        if isSharedArena then
            pcall(function()
                w:SetRenderOpacity(1.0)
                w:SetRenderScale({ X = 1.0, Y = 1.0 })
            end)
        end

        -- Keep counter prompts interactive and prevent distance culling from collapsing them to dots.
        local function enableSinglePrompt(single)
            if not UObjectUtils.IsLive(single) then return end
            pcall(function() single:SetInteractionEnabled(true) end)
            pcall(function() single:SetDisplayFarAwayIndicator(false) end)
        end

        local cached = nil
        pcall(function() cached = w.CachedIndicatorLocal end)
        if cached then
            UObjectUtils.ForEachObj(cached, enableSinglePrompt)
        end

        local overlay = nil
        pcall(function() overlay = w.IndicatorOverlay end)
        if UObjectUtils.IsValid(overlay) then
            local nChild = 0
            pcall(function() nChild = tonumber(overlay:GetChildrenCount()) or 0 end)
            for i = 0, nChild - 1 do
                local ch = nil
                pcall(function() ch = overlay:GetChildAt(i) end)
                if UObjectUtils.IsLive(ch) then
                    enableSinglePrompt(ch)
                end
            end
        end
    end)
end

function VanillaHUD.OnEnemyIndicatorPre(comp)
    if not (SessionManager.IsP2Active() and UObjectUtils.IsLive(comp)) then return end
    pcall(function()
        local p2Ctrl = SessionManager.GetP2()
        if not p2Ctrl then return end
        local cKey = UObjectUtils.GetKey(comp)
        local p2Key = UObjectUtils.GetKey(p2Ctrl)
        if cKey and p2Key and RegisteredTimedCompKeys[cKey] ~= p2Key then
            RegisteredTimedCompKeys[cKey] = p2Key
            pcall(function() comp:SetRegisterIndicatorForLocalPlayers(true) end)
        end
        if ViewportController.IsArenaCameraActive() then
            pcall(function()
                local data = comp.LastTimedIndicatorData
                if data then data.ShowToAllPlayers = true end
            end)
        end
    end)
end

local function ResolveEnemyAggroTargetPawn(enemy)
    if not UObjectUtils.IsLive(enemy) then return nil end
    local target = nil
    pcall(function()
        if not UObjectUtils.IsValid(CachedPagodaAICompClass) then
            CachedPagodaAICompClass = StaticFindObject("/Script/Pagoda.PagodaAIComponent")
        end
        local aiComp = enemy.PagodaAIComponent
            or (UObjectUtils.IsValid(CachedPagodaAICompClass) and enemy:GetComponentByClass(CachedPagodaAICompClass) or nil)
        if UObjectUtils.IsValid(aiComp) then
            local pt = aiComp.PendingAttackPlayerTarget
            if UObjectUtils.IsLive(pt) then target = pt; return end
            local at = aiComp.AggroTarget
            if UObjectUtils.IsLive(at) then target = at; return end
        end
    end)
    return target
end

function VanillaHUD.OnEnemySetIndicatorOnTarget(comp)
    if not (SessionManager.IsP2Active() and UObjectUtils.IsLive(comp)) then return end
    pcall(function()
        local p2Ctrl = SessionManager.GetP2()
        local p2Pawn = SessionManager.GetP2Pawn()
        if not (p2Ctrl and p2Pawn) then return end

        local cKey = UObjectUtils.GetKey(comp)
        local p2Key = UObjectUtils.GetKey(p2Ctrl)
        if cKey and p2Key and RegisteredTimedCompKeys[cKey] ~= p2Key then
            RegisteredTimedCompKeys[cKey] = p2Key
            pcall(function() comp:SetRegisterIndicatorForLocalPlayers(true) end)
        end

        local enemy = comp:GetOwner()
        if not UObjectUtils.IsLive(enemy) then return end

        local dangerComp = p2Pawn.DangerIndicatorComponent
        if not UObjectUtils.IsValid(dangerComp) then return end
        dangerComp.PlayerBP = p2Pawn
        dangerComp.EnableUIIndicator = true
        dangerComp.EnableVFX = true

        local isActive = false
        local isUnblockable = false
        local p2InTargets = false
        local p1InTargets = false
        local p1Pawn = SessionManager.GetP1Pawn()

        pcall(function()
            local data = comp.LastTimedIndicatorData
            if data then
                if ViewportController.IsArenaCameraActive() then
                    pcall(function() data.ShowToAllPlayers = true end)
                end
                if data.IsActive == true then isActive = true end
                if data.Targets then
                    UObjectUtils.ForEachObj(data.Targets, function(t)
                        if UObjectUtils.Same(t, p2Pawn) then p2InTargets = true end
                        if p1Pawn and UObjectUtils.Same(t, p1Pawn) then p1InTargets = true end
                    end)
                end
                if data.Indicators then
                    local len = #data.Indicators
                    for i = 1, len do
                        local ind = data.Indicators[i]
                        if ind and ind.Type then
                            local ts = UObjectUtils.GetTagString(ind.Type)
                            if ts:find("UnBlockable", 1, true) or ts:find("Unblockable", 1, true) then
                                isUnblockable = true
                            end
                        end
                    end
                end
            end
        end)

        if not isActive then
            local okAny, anyAct = pcall(function() return comp:AreAnyIndicatorEffectsActive() end)
            if okAny and anyAct == true then isActive = true end
        end

        -- Fallback target resolution from PagodaAIComponent when LastTimedIndicatorData.Targets is empty
        if isActive and (not p1InTargets) and (not p2InTargets) then
            local aiTgt = ResolveEnemyAggroTargetPawn(enemy)
            if UObjectUtils.IsLive(aiTgt) then
                if UObjectUtils.Same(aiTgt, p2Pawn) then p2InTargets = true end
                if p1Pawn and UObjectUtils.Same(aiTgt, p1Pawn) then p1InTargets = true end
            end
        end

        if isActive then
            local d2 = GetActorDistance3D(enemy, p2Pawn)
            local d1 = p1Pawn and GetActorDistance3D(enemy, p1Pawn) or 99999.0
            if p2InTargets or (d2 and (d2 <= 1600.0 and (not p1InTargets or d2 <= d1 + 180.0))) then
                pcall(function() dangerComp:AddAsAttackSource(enemy, isUnblockable, 1.5) end)
            end
            if (p1InTargets or (d1 and d1 <= 1600.0 and (not p2InTargets or d1 <= d2 + 180.0)))
                and UObjectUtils.IsLive(p1Pawn) and UObjectUtils.IsValid(p1Pawn.DangerIndicatorComponent) then
                pcall(function()
                    p1Pawn.DangerIndicatorComponent.PlayerBP = p1Pawn
                    p1Pawn.DangerIndicatorComponent.EnableUIIndicator = true
                    p1Pawn.DangerIndicatorComponent.EnableVFX = true
                    p1Pawn.DangerIndicatorComponent:AddAsAttackSource(enemy, isUnblockable, 1.5)
                end)
            end
        else
            pcall(function() dangerComp:RemoveAsAttackSource(enemy) end)
            if UObjectUtils.IsLive(p1Pawn) and UObjectUtils.IsValid(p1Pawn.DangerIndicatorComponent) then
                pcall(function() p1Pawn.DangerIndicatorComponent:RemoveAsAttackSource(enemy) end)
            end
        end
    end)
end

function VanillaHUD.SyncCombatIndicators()
    if not SessionManager.IsP2Active() or not SessionManager.IsSafeForGameplayHooks() then return end
    local p1Ctrl = SessionManager.GetP1()
    local p2Ctrl = SessionManager.GetP2()
    local p2Pawn = SessionManager.GetP2Pawn()
    if not (p1Ctrl and p2Ctrl and p2Pawn) then return end
    if UObjectUtils.IsInDiveBar(p1Ctrl) then return end

    SyncP2DangerIndicatorComponent(p1Ctrl, p2Ctrl, p2Pawn)

    local now = os.clock()
    if (now - LastIndicatorSweepAt) < 0.45 then return end
    LastIndicatorSweepAt = now
    for k, ts in pairs(LastAttackTickUpdateAt) do
        if (now - ts) > 15.0 then
            LastAttackTickUpdateAt[k] = nil
        end
    end

    pcall(function()
        -- 1. Ensure PagodaSettingsShared has Attack/Takedown/Offscreen indicators enabled for both players
        local sharedSettings = FindAllOf("PagodaSettingsShared")
        if sharedSettings then
            for _, s in pairs(sharedSettings) do
                if UObjectUtils.IsValid(s) then
                    local sKey = UObjectUtils.GetKey(s)
                    if sKey and not SyncedSettingsKeys[sKey] then
                        SyncedSettingsKeys[sKey] = true
                        pcall(function() s.bAttackIndicatorsEnabled = true end)
                        pcall(function() s.bTakedownIndicatorEnabled = true end)
                        pcall(function() s.bOffscreenEnemyIndicatorsEnabled = true end)
                        pcall(function() s:SetAttackIndicatorsEnabled(true) end)
                    end
                end
            end
        end

        -- 2. Register any live enemy BP_TimedIndicatorsComponent_C with both P1 and P2 controllers once
        local isArena = ViewportController.IsArenaCameraActive()
        local p2Key = UObjectUtils.GetKey(p2Ctrl)
        local timedComps = FindAllOf("BP_TimedIndicatorsComponent_C")
        if timedComps and p2Key then
            for _, comp in pairs(timedComps) do
                if UObjectUtils.IsLive(comp) then
                    local cKey = UObjectUtils.GetKey(comp)
                    if cKey and RegisteredTimedCompKeys[cKey] ~= p2Key then
                        RegisteredTimedCompKeys[cKey] = p2Key
                        pcall(function() comp:SetRegisterIndicatorForLocalPlayers(true) end)
                    end
                    if isArena then
                        pcall(function()
                            local data = comp.LastTimedIndicatorData
                            if data then data.ShowToAllPlayers = true end
                        end)
                    end
                end
            end
        end

        -- 3. Ensure all live WBP_NPCIndicator_Attack_Master_C widgets display prompts for P1 & P2
        local attackWidgets = FindAllOf("WBP_NPCIndicator_Attack_Master_C")
        if attackWidgets then
            for _, w in pairs(attackWidgets) do
                if UObjectUtils.IsLive(w) then
                    VanillaHUD.OnAttackIndicatorPostUpdate(w)
                end
            end
        end

        -- 4. In Arena Camera mode, keep P1's IndicatorLayer visible so projected attack rings always render
        if isArena then
            local hudCanvases = FindAllOf("WBP_HUDCanvas_C")
            if hudCanvases then
                for _, hc in pairs(hudCanvases) do
                    if UObjectUtils.IsLive(hc) then
                        local own = nil
                        pcall(function() own = hc:GetOwningPlayer() end)
                        if SessionManager.GetPlayerIndex(own) == 0 then
                            EnsureHUDCanvasIndicatorsVisible(hc)
                        end
                    end
                end
            end
        end
    end)
end

-- ============================================================================
-- SHARED / ARENA SCREEN NATIVE P2 HUD CLUSTER
-- ============================================================================

local function BuildSharedNativeHUD(p1Ctrl, p2Ctrl, p2Pawn)
    local inGameplay, world = UObjectUtils.IsGameplayWorld()
    if not (inGameplay and UObjectUtils.IsValid(world) and UObjectUtils.IsLive(p2Ctrl) and UObjectUtils.IsLive(p2Pawn)) then
        return false
    end

    local cls = UITheme.GetUMGClasses()
    if not cls then return false end

    local ctrlKey = UObjectUtils.GetKey(p2Ctrl)
    local pawnKey = UObjectUtils.GetKey(p2Pawn)
    local worldKey = UObjectUtils.GetKey(world)
    if UObjectUtils.IsValid(SharedHost.RootWidget)
        and SharedHost.OwnerCtrlKey == ctrlKey
        and SharedHost.BoundPawnKey == pawnKey
        and SharedHost.BoundWorldKey == worldKey then
        return true
    end

    VanillaHUD.DestroySharedHost()

    local hudCfg = Config.HUD or {}
    local subStatus = {}

    local okBuild, built = PlayerStateIsolation.WithScopedP2PPD(p1Ctrl, "VanillaHUD.SharedBuild", function()
        local rootUW = cls.WBL:Create(world, cls.Widget, p2Ctrl)
        if not (UObjectUtils.IsValid(rootUW) and UObjectUtils.IsValid(rootUW.WidgetTree)) then
            Logger.Missing("VanillaHUD", "UserWidget Root for P2 Shared HUD", "WBL:Create(p2Ctrl)")
            return false
        end

        local wt = rootUW.WidgetTree
        local rootCanvas = StaticConstructObject(cls.Canvas, wt)
        wt.RootWidget = rootCanvas

        local ax = tonumber(hudCfg.SharedScreenAnchorX) or 0.020
        local ay = tonumber(hudCfg.SharedScreenAnchorY) or 0.960
        local isLeft = (ax <= 0.5)
        local alignX = isLeft and 0.0 or 1.0
        local rowHAlign = isLeft and 1 or 3 -- 1 = Left, 3 = Right

        if hudCfg.ShowPlayerBadges ~= false and hudCfg.ShowP1Badge ~= false then
            local p1Badge = StaticConstructObject(cls.Border, wt)
            UITheme.StyleDiscoFrame(p1Badge, { R = 0.042, G = 0.018, B = 0.092, A = 0.90 }, UITheme.Colors.Cyan, 1.8, 3.0)
            p1Badge:SetPadding({ Left = 9, Top = 3, Right = 10, Bottom = 3 })
            UITheme.ApplyNativeSkew(p1Badge, -8.0)

            local p1H = StaticConstructObject(cls.HBox, wt)
            p1Badge:SetContent(p1H)
            local shardTex = UITheme.GetNativeTexture("Shard")
            if UObjectUtils.IsValid(shardTex) and UObjectUtils.IsValid(cls.Image) then
                local sBox = StaticConstructObject(cls.SizeBox, wt)
                pcall(function() sBox:SetWidthOverride(10.0); sBox:SetHeightOverride(10.0) end)
                local sImg = StaticConstructObject(cls.Image, wt)
                pcall(function() sImg:SetBrushFromTexture(shardTex, false); sImg:SetColorAndOpacity(UITheme.Colors.Cyan) end)
                sBox:AddChild(sImg)
                local siSlot = p1H:AddChildToHorizontalBox(sBox)
                pcall(function() siSlot:SetVerticalAlignment(2); siSlot:SetPadding({ Left = 0, Top = 0, Right = 5, Bottom = 0 }) end)
            end

            local p1Txt = StaticConstructObject(cls.Text, wt)
            UITheme.StyleText(p1Txt, 10, UITheme.Fonts.Primary, UITheme.Colors.Cyan, false)
            UITheme.SetText(p1Txt, "PLAYER 1")
            local p1TSlot = p1H:AddChildToHorizontalBox(p1Txt)
            pcall(function() p1TSlot:SetVerticalAlignment(2) end)

            local p1Slot = rootCanvas:AddChildToCanvas(p1Badge)
            p1Slot:SetAnchors({ Minimum = { X = 0.024, Y = 0.014 }, Maximum = { X = 0.024, Y = 0.014 } })
            pcall(function() p1Slot:SetAlignment({ X = 0.0, Y = 0.0 }) end)
            pcall(function() p1Slot:SetAutoSize(true) end)
        end

        local p2V = StaticConstructObject(cls.VBox, wt)
        local p2Slot = rootCanvas:AddChildToCanvas(p2V)
        p2Slot:SetAnchors({ Minimum = { X = ax, Y = ay }, Maximum = { X = ax, Y = ay } })
        pcall(function() p2Slot:SetAlignment({ X = alignX, Y = 1.0 }) end)
        pcall(function() p2Slot:SetAutoSize(true) end)

        local scale = VanillaHUD.GetSharedScale()
        pcall(function()
            p2V:SetRenderTransformPivot({ X = alignX, Y = 1.0 })
            p2V:SetRenderScale({ X = scale, Y = scale })
        end)

        if hudCfg.ShowPlayerBadges ~= false and hudCfg.ShowP2Badge ~= false then
            local hdrH = StaticConstructObject(cls.HBox, wt)
            local hdrSlot = p2V:AddChildToVerticalBox(hdrH)
            pcall(function() hdrSlot:SetHorizontalAlignment(rowHAlign); hdrSlot:SetPadding({ Left = 0, Top = 0, Right = 0, Bottom = 6 }) end)

            local p2Badge = StaticConstructObject(cls.Border, wt)
            UITheme.StyleDiscoFrame(p2Badge, { R = 0.042, G = 0.018, B = 0.092, A = 0.90 }, UITheme.Colors.Magenta, 1.8, 3.0)
            p2Badge:SetPadding({ Left = 9, Top = 3, Right = 10, Bottom = 3 })
            UITheme.ApplyNativeSkew(p2Badge, -8.0)

            local p2BH = StaticConstructObject(cls.HBox, wt)
            p2Badge:SetContent(p2BH)
            local shardTex = UITheme.GetNativeTexture("Shard")
            if UObjectUtils.IsValid(shardTex) and UObjectUtils.IsValid(cls.Image) then
                local sBox = StaticConstructObject(cls.SizeBox, wt)
                pcall(function() sBox:SetWidthOverride(10.0); sBox:SetHeightOverride(10.0) end)
                local sImg = StaticConstructObject(cls.Image, wt)
                pcall(function() sImg:SetBrushFromTexture(shardTex, false); sImg:SetColorAndOpacity(UITheme.Colors.Magenta) end)
                sBox:AddChild(sImg)
                local siSlot = p2BH:AddChildToHorizontalBox(sBox)
                pcall(function() siSlot:SetVerticalAlignment(2); siSlot:SetPadding({ Left = 0, Top = 0, Right = 5, Bottom = 0 }) end)
            end

            local p2Txt = StaticConstructObject(cls.Text, wt)
            UITheme.StyleText(p2Txt, 10, UITheme.Fonts.Primary, UITheme.Colors.Magenta, false)
            UITheme.SetText(p2Txt, "PLAYER 2")
            local p2TSlot = p2BH:AddChildToHorizontalBox(p2Txt)
            pcall(function() p2TSlot:SetVerticalAlignment(2) end)
            hdrH:AddChildToHorizontalBox(p2Badge)
        end

        local function CreateNativeSubWidget(key)
            local spec = NATIVE_WIDGETS[key]
            local wCls = UObjectUtils.LoadClass(spec.Pkg, spec.Cls)
            if not UObjectUtils.IsValid(wCls) then
                subStatus[key] = false
                return nil
            end
            local okC, inst = pcall(function() return cls.WBL:Create(world, wCls, p2Ctrl) end)
            if okC and UObjectUtils.IsValid(inst) then
                SharedHost.SubWidgets[key] = inst
                subStatus[key] = true
                return inst
            end
            Logger.Missing("VanillaHUD", spec.Pkg .. "." .. spec.Cls, "WBL:Create(p2Ctrl)")
            subStatus[key] = false
            return nil
        end

        local row1 = StaticConstructObject(cls.HBox, wt)
        local r1S = p2V:AddChildToVerticalBox(row1)
        pcall(function() r1S:SetHorizontalAlignment(rowHAlign); r1S:SetPadding({ Left = 0, Top = 0, Right = 0, Bottom = 5 }) end)

        local tokensW = CreateNativeSubWidget("Tokens")
        local heartsW = CreateNativeSubWidget("Hearts")
        if isLeft then
            if heartsW then
                local hs = row1:AddChildToHorizontalBox(heartsW)
                pcall(function() hs:SetVerticalAlignment(2) end)
            end
            if tokensW then
                local ts = row1:AddChildToHorizontalBox(tokensW)
                pcall(function() ts:SetVerticalAlignment(2); ts:SetPadding({ Left = 8, Top = 0, Right = 0, Bottom = 0 }) end)
            end
        else
            if tokensW then
                local ts = row1:AddChildToHorizontalBox(tokensW)
                pcall(function() ts:SetVerticalAlignment(2); ts:SetPadding({ Left = 0, Top = 0, Right = 8, Bottom = 0 }) end)
            end
            if heartsW then
                local hs = row1:AddChildToHorizontalBox(heartsW)
                pcall(function() hs:SetVerticalAlignment(2) end)
            end
        end

        -- Row 2: Native Fever Bar + Native Fever Multiplier Indicator
        local row2 = StaticConstructObject(cls.HBox, wt)
        local r2S = p2V:AddChildToVerticalBox(row2)
        pcall(function() r2S:SetHorizontalAlignment(rowHAlign); r2S:SetPadding({ Left = 0, Top = 0, Right = 0, Bottom = 6 }) end)

        local feverMultW = CreateNativeSubWidget("FeverMult")
        local feverBarW = CreateNativeSubWidget("FeverBar")
        if isLeft then
            if feverBarW then
                local fbs = row2:AddChildToHorizontalBox(feverBarW)
                pcall(function() fbs:SetVerticalAlignment(2) end)
            end
            if feverMultW then
                local fms = row2:AddChildToHorizontalBox(feverMultW)
                pcall(function() fms:SetVerticalAlignment(2); fms:SetPadding({ Left = 6, Top = 0, Right = 0, Bottom = 0 }) end)
            end
        else
            if feverMultW then
                local fms = row2:AddChildToHorizontalBox(feverMultW)
                pcall(function() fms:SetVerticalAlignment(2); fms:SetPadding({ Left = 0, Top = 0, Right = 6, Bottom = 0 }) end)
            end
            if feverBarW then
                local fbs = row2:AddChildToHorizontalBox(feverBarW)
                pcall(function() fbs:SetVerticalAlignment(2) end)
            end
        end

        -- Row 3: Native 4-Slot Boss Ability Bar (WBP_AbilityBar_V2)
        local abilityBarW = CreateNativeSubWidget("AbilityBar")
        if abilityBarW then
            local r3S = p2V:AddChildToVerticalBox(abilityBarW)
            pcall(function() r3S:SetHorizontalAlignment(rowHAlign) end)
        end

        ViewportController.RehostingGuard = true
        rootUW:AddToViewport(tonumber(hudCfg.SharedViewportZOrder) or 50)
        ViewportController.RehostingGuard = false
        pcall(function() rootUW:SetVisibility(2) end)

        SharedHost.RootWidget = rootUW
        SharedHost.ClusterBox = p2V
        SharedHost.OwnerCtrlKey = ctrlKey
        SharedHost.BoundPawnKey = pawnKey
        SharedHost.BoundWorldKey = worldKey
        SharedHost.Visible = false

        Logger.Info("VanillaHUD",
            "Mounted native P2 Shared HUD (Hearts=%s Tokens=%s Fever=%s Mult=%s AbilityBar=%s Scale=%.2f)",
            tostring(subStatus.Hearts == true), tostring(subStatus.Tokens == true),
            tostring(subStatus.FeverBar == true), tostring(subStatus.FeverMult == true),
            tostring(subStatus.AbilityBar == true), scale)
        return true
    end)

    ViewportController.RehostingGuard = false
    return okBuild == true and built == true and UObjectUtils.IsValid(SharedHost.RootWidget)
end

-- ============================================================================
-- PUBLIC LIFECYCLE & SYNC API
-- ============================================================================

function VanillaHUD.Sync()
    if not SessionManager.IsP2Active() then
        if UObjectUtils.IsValid(SharedHost.RootWidget) or UObjectUtils.IsValid(SplitMountedHUD) then
            VanillaHUD.Destroy()
        end
        return
    end

    local p1Ctrl = SessionManager.GetP1()
    local p2Ctrl = SessionManager.GetP2()
    local p2Pawn = SessionManager.GetP2Pawn()

    if ViewportController.IsSplitScreenActive() then
        VanillaHUD.Hide()
        if p1Ctrl and p2Ctrl and p2Pawn then
            EnsureSplitScreenP2NativeHUD(p1Ctrl, p2Ctrl)
            VanillaHUD.SyncCombatIndicators()
        end
        return
    end

    if UObjectUtils.IsValid(SplitMountedHUD) then
        VanillaHUD.DestroySplitMounted()
    end

    if not ShouldShowSharedP2HUD() then
        VanillaHUD.Hide()
        return
    end

    VanillaHUD.SyncCombatIndicators()

    if not BuildSharedNativeHUD(p1Ctrl, p2Ctrl, p2Pawn) then return end

    if not SharedHost.Visible and UObjectUtils.IsValid(SharedHost.RootWidget) then
        pcall(function() SharedHost.RootWidget:SetVisibility(3) end) -- SelfHitTestInvisible
        SharedHost.Visible = true
    end
end

function VanillaHUD.Rebuild()
    VanillaHUD.DestroySharedHost()
    VanillaHUD.Sync()
end

function VanillaHUD.GetStatus()
    local count = 0
    for _, w in pairs(SharedHost.SubWidgets) do
        if UObjectUtils.IsValid(w) then count = count + 1 end
    end
    return {
        Mode = ViewportController.IsSplitScreenActive() and "SplitScreen"
            or (ViewportController.IsArenaCameraActive() and "SharedNative" or "Inactive"),
        SharedWidgetsMounted = count,
        SharedVisible = SharedHost.Visible == true,
        SplitFallbackMounted = UObjectUtils.IsLive(SplitMountedHUD),
        SharedScale = VanillaHUD.GetSharedScale(),
    }
end

return VanillaHUD
