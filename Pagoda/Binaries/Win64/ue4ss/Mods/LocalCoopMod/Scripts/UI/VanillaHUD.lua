-- ============================================================================
-- VANILLA PLAYER 2 HUD CONTROLLER (NATIVE UMG WIDGETS — ZERO MOCK OVERLAYS)
-- ============================================================================
-- Instantiates, binds, scales, and cleans up Dead as Disco's real native HUD
-- widgets for Player 2:
--   * Split-Screen Mode (0 / 1):
--       Verifies P2's native UI_Layout_Game_C.GameHUDStack has an active HUD
--       widget (WBP_GameHUD_C / WBP_InfiniteDiscoHUD_C / WBP_TowerHUD_C).
--       If P2 joined mid-stage without one, mounts WBP_GameHUD_C strictly on
--       P2's PlayerScreen / GameHUDStack inside WithScopedP2PPD.
--   * Shared / Arena Screen Mode (2):
--       Creates P2-owned instances of Dead as Disco's real modular HUD widgets
--       (WBP_PlayerHealth_Hearts, WBP_ExecutionTokenPips, WBP_PlayerFeverBar,
--        WBP_FeverMultiplierIndicator, WBP_AbilityBar_V2) inside a resolution-
--       scaled bottom-left container (configurable) so P2's real hearts,
--       shatter/heal FX, fever bar, combo multiplier, tokens & ability cooldowns
--       render cleanly without overlapping P1's HUD.
-- ============================================================================

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
local SharedScaleOverride = nil
local CachedInActiveMatch = false
local CachedInActiveMatchAt = -1.0

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
        pcall(function() SplitMountedHUD:RemoveFromParent() end)
    end
    SplitMountedHUD = nil
end

function VanillaHUD.Destroy()
    VanillaHUD.DestroySharedHost()
    VanillaHUD.DestroySplitMounted()
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

local function FindP2GameLayoutAndHUD()
    local p2Layout = nil
    local hasNativeHUD = false
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
                            if UObjectUtils.IsLive(lay.GameHUDStack) then
                                local act = nil
                                pcall(function() act = lay.GameHUDStack:GetActiveWidget() end)
                                if UObjectUtils.IsLive(act) then
                                    hasNativeHUD = true
                                end
                            end
                        end
                    end
                end
            end
        end

        if not hasNativeHUD then
            for _, clsName in ipairs({ "WBP_GameHUD_C", "WBP_InfiniteDiscoHUD_C", "WBP_TowerHUD_C" }) do
                local list = FindAllOf(clsName)
                if list then
                    for _, w in pairs(list) do
                        if UObjectUtils.IsLive(w) then
                            local own = nil
                            pcall(function() own = w:GetOwningPlayer() end)
                            if SessionManager.GetPlayerIndex(own) == 1 then
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
        end)
    end
    if hasNativeHUD then return end

    local gameHudCls = UObjectUtils.LoadClass(NATIVE_WIDGETS.GameHUD.Pkg, NATIVE_WIDGETS.GameHUD.Cls)
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
            Logger.Info("VanillaHUD", "Mounted native WBP_GameHUD onto Player 2 split viewport.")
        else
            Logger.Warn("VanillaHUD", "Could not mount fallback WBP_GameHUD on P2 split screen.")
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

        local hudCfg = Config.HUD or {}
        local ax = tonumber(hudCfg.SharedScreenAnchorX) or 0.020
        local ay = tonumber(hudCfg.SharedScreenAnchorY) or 0.960
        local isLeft = (ax <= 0.5)
        local alignX = isLeft and 0.0 or 1.0
        local rowHAlign = isLeft and 1 or 3 -- 1 = Left, 3 = Right

        -- 1. Player 1 badge sits cleanly above P1's top-left hearts during Shared/Arena combat
        if hudCfg.ShowPlayerBadges ~= false and hudCfg.ShowP1Badge ~= false then
            local p1Badge = StaticConstructObject(cls.Border, wt)
            UITheme.StyleDiscoFrame(p1Badge, { R = 0.045, G = 0.020, B = 0.095, A = 0.88 }, UITheme.Colors.Cyan, 1.8, 3.0)
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
            p1H:AddChildToHorizontalBox(p1Txt)

            local p1Slot = rootCanvas:AddChildToCanvas(p1Badge)
            p1Slot:SetAnchors({ Minimum = { X = 0.024, Y = 0.010 }, Maximum = { X = 0.024, Y = 0.010 } })
            pcall(function() p1Slot:SetAlignment({ X = 0.0, Y = 0.0 }) end)
            pcall(function() p1Slot:SetAutoSize(true) end)
        end

        -- 2. Native P2 HUD Cluster (anchored Bottom-Left by default in Arena / Shared Camera)
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
            UITheme.StyleDiscoFrame(p2Badge, { R = 0.045, G = 0.020, B = 0.095, A = 0.88 }, UITheme.Colors.Magenta, 1.8, 3.0)
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
            p2BH:AddChildToHorizontalBox(p2Txt)
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

        -- Row 1: Native Hearts + Native Execution Token Pips
        local row1 = StaticConstructObject(cls.HBox, wt)
        local r1S = p2V:AddChildToVerticalBox(row1)
        pcall(function() r1S:SetHorizontalAlignment(rowHAlign); r1S:SetPadding({ Left = 0, Top = 0, Right = 0, Bottom = 4 }) end)

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
