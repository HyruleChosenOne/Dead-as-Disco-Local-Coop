-- ============================================================================
-- DYNAMIC REVIVE CIRCLE (3D FLOOR RING + WORLD-PROJECTED NATIVE MEDALLION)
-- ============================================================================
-- Visualizes teammate revive state in real time via two synchronized layers:
--   1. 3D Floor Revive Circle (StaticMeshActors beneath downed pawn):
--        * Outer boundary ring scaled cleanly to Config.Revive.ReviveRadius
--        * Inner spinning progress ring scaling from 0.14x -> 1.00x as
--          revive progresses (Crimson -> Cyan -> Emerald glow).
--   2. Projected Native Circular Medallion & Callout Strip:
--        * Anchored above the downed player via World-to-Widget projection
--          (with bottom-center fallback when off-screen).
--        * Native M_UI_InputHoldProgress_Circular radial fill + spinning
--          counterRing_inner + Heart_full pulse + skewed progress strip.
-- ============================================================================

local UObjectUtils = require("Utils.UObjectUtils")
local Logger = require("Utils.Logger")
local SessionManager = require("Core.SessionManager")
local ViewportController = require("Camera.ViewportController")
local UITheme = require("UI.UITheme")

local ReviveOverlay = {}

local Config = {}

local REVIVE_ASSETS = {
    RingMesh       = "/Game/Pagoda/Common/FX_C/FX_C_Meshes/FX_Meshes/SM_FX_Ring_Top_01.SM_FX_Ring_Top_01",
    FallbackDisc   = "/Game/Pagoda/Common/FX_C/FX_C_Meshes/FX_Meshes/SM_FX_Disc_01.SM_FX_Disc_01",
    OuterMat       = "/Game/Pagoda/Common/FX_C/Indicators/MI_Indicator_01.MI_Indicator_01",
    OuterMatAlt    = "/Game/Pagoda/Characters/Player/FX_C_Player/Boss_Abilities/BA_Dancer/MI_Blast_Ring_01.MI_Blast_Ring_01",
    InnerMat       = "/Game/Pagoda/Common/FX_C/Indicators/MI_Indicator_02.MI_Indicator_02",
    InnerMatAlt    = "/Game/Pagoda/Common/FX_C/FX_C_Materials/MI_Sprite_Circle_01.MI_Sprite_Circle_01",
    RadialMat      = "/Game/Pagoda/UI/PendingMoveMenuAssets/Generic_Elements/Materials/M_UI_InputHoldProgress_Circular.M_UI_InputHoldProgress_Circular",
    RadialMatAlt   = "/Game/Pagoda/UI/PendingMoveMenuAssets/Generic_Elements/Materials/M_UI_HollowCircularProgressBar_Base.M_UI_HollowCircularProgressBar_Base",
}

local CachedAssets = {}
local CachedWLL = nil
local CachedSMClass = nil
local CachedWCClass = nil

local RingWorld = {
    WorldKey = nil,
    OuterActor = nil,
    InnerActor = nil,
    OuterWC = nil,
    InnerWC = nil,
    OuterRingImg = nil,
    OuterPoolImg = nil,
    InnerRingImg = nil,
    OuterMID = nil,
    InnerMID = nil,
    IsWidgetMode = false,
    MeshRadius = 50.0,
    LastColorMode = nil,
    OuterYaw = 0.0,
    InnerYaw = 0.0,
}

local ProjHUD = {
    Widget = nil,
    OwnerPC = nil,
    World = nil,
    AttachedHost = nil,
    PosSlot = nil,
    SpinRingImg = nil,
    RadialImg = nil,
    RadialMID = nil,
    HeartImg = nil,
    Card = nil,
    TitleText = nil,
    PctText = nil,
    PromptText = nil,
    FillBorder = nil,
    FillSlot = nil,
    EmptySlot = nil,
    Visible = false,
}

-- Latest state snapshot pushed by ReviveSystem and rendered smoothly on frame
local ActiveState = {
    Active = false,
    DownedPid = nil,
    RescuerPid = nil,
    DownedPawn = nil,
    Progress = 0.0,
    InRange = false,
    IsHolding = false,
    DistMeters = 0.0,
    Radius = 210.0,
    LastUiUpdateAt = 0.0,
}

-- Authentic Dead as Disco Neon Club Palette (Electric Magenta -> Cyber Cyan -> Acid Gold)
local COLOR_WAITING  = { R = 1.00, G = 0.12, B = 0.56, A = 0.42 }
local COLOR_PROX     = { R = 0.00, G = 0.93, B = 1.00, A = 0.48 }
local COLOR_FASTHOLD = { R = 1.00, G = 0.85, B = 0.14, A = 0.56 }
local SCALAR_PROGRESS_PARAMS = { "Progress", "Percent", "Fill", "Value", "Alpha", "Amount" }
local MAT_COLOR_PARAMS = { "Color", "Tint", "EmissiveColor", "BaseColor", "PrimaryColor" }

function ReviveOverlay.Init(config)
    Config = config or {}
    ViewportController.RegisterModWidget("ReviveOverlay", function() return ProjHUD.Widget end)
end

local function LoadCachedAsset(key)
    if CachedAssets[key] ~= nil then
        return UObjectUtils.IsValid(CachedAssets[key]) and CachedAssets[key] or nil
    end
    local path = REVIVE_ASSETS[key]
    if not path then return nil end
    local obj = nil
    pcall(function() obj = StaticFindObject(path) end)
    if not UObjectUtils.IsValid(obj) and type(LoadAsset) == "function" then
        local pkg = path:match("^([^%.]+)%.") or path
        pcall(function() LoadAsset(pkg) end)
        pcall(function() LoadAsset(path) end)
        pcall(function() obj = StaticFindObject(path) end)
    end
    CachedAssets[key] = UObjectUtils.IsValid(obj) and obj or false
    return UObjectUtils.IsValid(obj) and obj or nil
end

local function GetWidgetLayoutLibrary()
    if UObjectUtils.IsValid(CachedWLL) then return CachedWLL end
    pcall(function() CachedWLL = StaticFindObject("/Script/UMG.Default__WidgetLayoutLibrary") end)
    return UObjectUtils.IsValid(CachedWLL) and CachedWLL or nil
end

local function ApplyColorToMID(mid, color)
    if not (UObjectUtils.IsValid(mid) and color) then return end
    for _, pname in ipairs(MAT_COLOR_PARAMS) do
        pcall(function() mid:SetVectorParameterValue(FName(pname), color) end)
    end
end

-- ============================================================================
-- 1. 3D WORLD-SPACE DISCO SPOTLIGHT & TARGETER REVIVE RINGS
-- ============================================================================

local function GetStaticMeshActorClass()
    if UObjectUtils.IsValid(CachedSMClass) then return CachedSMClass end
    pcall(function() CachedSMClass = StaticFindObject("/Script/Engine.StaticMeshActor") end)
    return UObjectUtils.IsValid(CachedSMClass) and CachedSMClass or nil
end

local function GetWidgetComponentClass()
    if UObjectUtils.IsValid(CachedWCClass) then return CachedWCClass end
    pcall(function() CachedWCClass = StaticFindObject("/Script/UMG.WidgetComponent") end)
    return UObjectUtils.IsValid(CachedWCClass) and CachedWCClass or nil
end

local function SpawnRingWidgetActor(world, loc, rot, drawPx, initColor, isInner)
    local smCls = GetStaticMeshActorClass()
    local wcCls = GetWidgetComponentClass()
    local p1Ctrl = SessionManager.GetP1()
    local cls = UITheme.GetUMGClasses()
    local ringTex = UITheme.GetNativeTexture("TargeterMain")
        or UITheme.GetNativeTexture("CounterRingMMS")
        or UITheme.GetNativeTexture("CounterRing")
    local poolTex = UITheme.GetNativeTexture("HalftoneCircle")
        or UITheme.GetNativeTexture("HalftoneRadial")

    if not (UObjectUtils.IsValid(smCls) and UObjectUtils.IsValid(wcCls) and p1Ctrl
        and cls and UObjectUtils.IsValid(cls.Overlay) and UObjectUtils.IsValid(cls.Image) and UObjectUtils.IsValid(ringTex)) then
        return nil, nil, nil, nil
    end

    local actor = world:SpawnActor(smCls, loc, rot)
    if not UObjectUtils.IsLive(actor) then return nil, nil, nil, nil end

    pcall(function() actor:SetActorEnableCollision(false) end)
    pcall(function() actor:SetActorTickEnabled(false) end)

    local smComp = nil
    pcall(function() smComp = actor.StaticMeshComponent end)
    if UObjectUtils.IsValid(smComp) then
        pcall(function() smComp:SetMobility(2) end)
        pcall(function() smComp:SetCollisionEnabled(0) end)
        pcall(function() smComp:SetCastShadow(false) end)
    end

    local okWidget, built = pcall(function()
        local uw = cls.WBL:Create(world, cls.Widget, p1Ctrl)
        if not (UObjectUtils.IsValid(uw) and UObjectUtils.IsValid(uw.WidgetTree)) then return nil end
        local wt = uw.WidgetTree

        local box = StaticConstructObject(cls.SizeBox, wt)
        pcall(function() box:SetWidthOverride(drawPx); box:SetHeightOverride(drawPx) end)
        wt.RootWidget = box

        local ov = StaticConstructObject(cls.Overlay, wt)
        box:AddChild(ov)

        -- Subtle comic halftone disco spotlight pool on the outer ring only (zero dark square/muddy halo)
        local poolImg = nil
        if (not isInner) and UObjectUtils.IsValid(poolTex) then
            poolImg = StaticConstructObject(cls.Image, wt)
            pcall(function()
                poolImg:SetBrushFromTexture(poolTex, false)
                poolImg:SetColorAndOpacity({
                    R = initColor.R,
                    G = initColor.G,
                    B = initColor.B,
                    A = (initColor.A or 0.40) * 0.35,
                })
            end)
            local pSlot = ov:AddChildToOverlay(poolImg)
            pcall(function()
                pSlot:SetHorizontalAlignment(0)
                pSlot:SetVerticalAlignment(0)
                pSlot:SetPadding({ Left = 28.0, Top = 28.0, Right = 28.0, Bottom = 28.0 })
            end)
        end

        local img = StaticConstructObject(cls.Image, wt)
        pcall(function()
            img:SetBrushFromTexture(ringTex, false)
            img:SetColorAndOpacity(initColor)
        end)
        local iSlot = ov:AddChildToOverlay(img)
        local pad = isInner and 18.0 or 6.0
        pcall(function()
            iSlot:SetHorizontalAlignment(0)
            iSlot:SetVerticalAlignment(0)
            iSlot:SetPadding({ Left = pad, Top = pad, Right = pad, Bottom = pad })
        end)

        local wComp = actor:AddComponentByClass(
            wcCls,
            false,
            { Rotation = { X = 0.0, Y = 0.0, Z = 0.0, W = 1.0 }, Translation = { X = 0.0, Y = 0.0, Z = 0.0 }, Scale3D = { X = 1.0, Y = 1.0, Z = 1.0 } },
            false
        )
        if not UObjectUtils.IsValid(wComp) then return nil end

        pcall(function() wComp:SetMobility(2) end)
        if UObjectUtils.IsValid(smComp) then
            pcall(function() wComp:K2_AttachToComponent(smComp, FName("None"), 2, 2, 2, false) end)
        end
        pcall(function() wComp:SetCollisionEnabled(0) end)
        pcall(function() wComp:SetCastShadow(false) end)
        pcall(function() wComp:SetWidgetSpace(0) end)
        pcall(function() wComp:SetTwoSided(true) end)
        pcall(function() wComp:SetBlendMode(2) end)
        pcall(function() wComp:SetDrawAtDesiredSize(false) end)
        pcall(function() wComp:SetDrawSize({ X = drawPx, Y = drawPx }) end)
        pcall(function() wComp:SetPivot({ X = 0.5, Y = 0.5 }) end)
        pcall(function() wComp:SetBackgroundColor({ R = 0.0, G = 0.0, B = 0.0, A = 0.0 }) end)
        pcall(function() wComp:K2_SetRelativeLocation({ X = 0.0, Y = 0.0, Z = 0.0 }, false, {}, false) end)
        pcall(function() wComp:K2_SetRelativeRotation({ Pitch = 90.0, Yaw = 0.0, Roll = 0.0 }, false, {}, false) end)
        pcall(function() wComp:SetWidget(uw) end)
        pcall(function() wComp:SetVisibility(true, true) end)
        return { wComp = wComp, img = img, poolImg = poolImg }
    end)

    if okWidget and built and UObjectUtils.IsValid(built.wComp) and UObjectUtils.IsValid(built.img) then
        return actor, built.wComp, built.img, built.poolImg
    end

    SessionManager.DestroyActorSafely(actor)
    return nil, nil, nil, nil
end

local function SpawnRingMeshActor(world, loc, rot, meshObj, matObj)
    local smCls = GetStaticMeshActorClass()
    if not UObjectUtils.IsValid(smCls) then return nil, nil end

    local actor = world:SpawnActor(smCls, loc, rot)
    if not UObjectUtils.IsLive(actor) then return nil, nil end

    pcall(function() actor:SetActorEnableCollision(false) end)
    pcall(function() actor:SetActorTickEnabled(false) end)

    local mid = nil
    local comp = nil
    pcall(function() comp = actor.StaticMeshComponent end)
    if UObjectUtils.IsValid(comp) then
        pcall(function() comp:SetMobility(2) end) -- Movable
        pcall(function() comp:SetCollisionEnabled(0) end)
        pcall(function() comp:SetCastShadow(false) end)
        pcall(function() comp:SetStaticMesh(meshObj) end)

        -- Estimate unscaled radius in UU
        pcall(function()
            local b = comp:GetLocalBounds()
            if b and b.BoxExtent then
                local r = math.max(b.BoxExtent.X or 0.0, b.BoxExtent.Y or 0.0)
                if r > 5.0 then RingWorld.MeshRadius = r end
            end
        end)

        if UObjectUtils.IsValid(matObj) then
            pcall(function() mid = comp:CreateDynamicMaterialInstance(0, matObj) end)
            if not UObjectUtils.IsValid(mid) then
                pcall(function() comp:SetMaterial(0, matObj) end)
            end
        end
    end

    return actor, mid
end

function ReviveOverlay.DestroyWorldRings()
    if UObjectUtils.IsLive(RingWorld.OuterActor) then
        SessionManager.DestroyActorSafely(RingWorld.OuterActor)
    end
    if UObjectUtils.IsLive(RingWorld.InnerActor) then
        SessionManager.DestroyActorSafely(RingWorld.InnerActor)
    end
    RingWorld.OuterActor = nil
    RingWorld.InnerActor = nil
    RingWorld.OuterWC = nil
    RingWorld.InnerWC = nil
    RingWorld.OuterRingImg = nil
    RingWorld.OuterPoolImg = nil
    RingWorld.InnerRingImg = nil
    RingWorld.OuterMID = nil
    RingWorld.InnerMID = nil
    RingWorld.IsWidgetMode = false
    RingWorld.WorldKey = nil
    RingWorld.LastColorMode = nil
end

local function EnsureWorldRings(world, loc)
    local revCfg = Config.Revive or {}
    if revCfg.ShowWorldReviveCircle == false then return false end
    if not UObjectUtils.IsValid(world) then return false end

    local wKey = UObjectUtils.GetKey(world)
    if UObjectUtils.IsLive(RingWorld.OuterActor) and UObjectUtils.IsLive(RingWorld.InnerActor) and RingWorld.WorldKey == wKey then
        return true
    end

    ReviveOverlay.DestroyWorldRings()
    local rot = { Pitch = 0.0, Yaw = 0.0, Roll = 0.0 }

    -- Primary: Flat World-Space UWidgetComponent disco targeter + halftone spotlight rings
    local outerA, outerWC, outerImg, outerPoolImg = SpawnRingWidgetActor(world, loc, rot, 512.0, COLOR_WAITING, false)
    if UObjectUtils.IsLive(outerA) then
        local innerA, innerWC, innerImg = SpawnRingWidgetActor(
            world, { X = loc.X, Y = loc.Y, Z = loc.Z + 1.5 }, rot, 512.0, { R = 0.00, G = 0.93, B = 1.00, A = 0.65 }, true
        )
        if UObjectUtils.IsLive(innerA) then
            RingWorld.WorldKey = wKey
            RingWorld.OuterActor = outerA
            RingWorld.InnerActor = innerA
            RingWorld.OuterWC = outerWC
            RingWorld.InnerWC = innerWC
            RingWorld.OuterRingImg = outerImg
            RingWorld.OuterPoolImg = outerPoolImg
            RingWorld.InnerRingImg = innerImg
            RingWorld.IsWidgetMode = true
            RingWorld.LastColorMode = nil
            return true
        end
        SessionManager.DestroyActorSafely(outerA)
    end

    -- Fallback: StaticMeshActor FX ring
    local meshObj = LoadCachedAsset("RingMesh") or LoadCachedAsset("FallbackDisc")
    if not UObjectUtils.IsValid(meshObj) then return false end

    local outerMat = LoadCachedAsset("OuterMat") or LoadCachedAsset("OuterMatAlt")
    local innerMat = LoadCachedAsset("InnerMat") or LoadCachedAsset("InnerMatAlt") or outerMat

    local mOuterA, outerMID = SpawnRingMeshActor(world, loc, rot, meshObj, outerMat)
    if not UObjectUtils.IsLive(mOuterA) then return false end

    local mInnerA, innerMID = SpawnRingMeshActor(world, { X = loc.X, Y = loc.Y, Z = loc.Z + 2.0 }, rot, meshObj, innerMat)
    if not UObjectUtils.IsLive(mInnerA) then
        SessionManager.DestroyActorSafely(mOuterA)
        return false
    end

    RingWorld.WorldKey = wKey
    RingWorld.OuterActor = mOuterA
    RingWorld.InnerActor = mInnerA
    RingWorld.OuterMID = outerMID
    RingWorld.InnerMID = innerMID
    RingWorld.IsWidgetMode = false
    RingWorld.LastColorMode = nil
    return true
end

local function UpdateWorldRings(dt)
    local pawn = ActiveState.DownedPawn
    local inGameplay, world = UObjectUtils.IsGameplayWorld()
    if not (inGameplay and UObjectUtils.IsValid(world) and UObjectUtils.IsLive(pawn)) then
        ReviveOverlay.DestroyWorldRings()
        return
    end

    local loc = nil
    pcall(function() loc = pawn:K2_GetActorLocation() end)
    if not loc then return end

    local halfH = 88.0
    pcall(function()
        if UObjectUtils.IsValid(pawn.CapsuleComponent) then
            local ch = pawn.CapsuleComponent:GetScaledCapsuleHalfHeight()
            if type(ch) == "number" and ch > 15.0 then halfH = ch end
        end
    end)
    local floorLoc = { X = loc.X, Y = loc.Y, Z = loc.Z - halfH + 4.0 }

    if not EnsureWorldRings(world, floorLoc) then return end

    local revCfg = Config.Revive or {}
    local visScale = tonumber(revCfg.ReviveCircleVisualScale) or 0.64
    local opacityMul = math.max(0.18, math.min(0.85, tonumber(revCfg.ReviveCircleOpacity) or 0.40))
    local radius = (ActiveState.Radius or 210.0) * visScale
    local stepDt = (type(dt) == "number" and dt > 0.0) and math.min(0.10, dt) or 0.016
    local outerSpeed = ActiveState.InRange and 32.0 or 16.0
    local innerSpeed = (ActiveState.InRange and ActiveState.IsHolding) and 150.0 or (ActiveState.InRange and 78.0 or 26.0)
    RingWorld.OuterYaw = (RingWorld.OuterYaw + outerSpeed * stepDt) % 360.0
    RingWorld.InnerYaw = (RingWorld.InnerYaw - innerSpeed * stepDt) % 360.0

    -- 128 BPM disco beat pulse
    local beatPulse = 1.0 + 0.035 * math.sin(os.clock() * 6.7)
    local p = math.max(0.0, math.min(1.0, ActiveState.Progress or 0.0))

    pcall(function()
        RingWorld.OuterActor:K2_SetActorLocationAndRotation(floorLoc, { Pitch = 0.0, Yaw = RingWorld.OuterYaw, Roll = 0.0 }, false, {}, false)
        RingWorld.InnerActor:K2_SetActorLocationAndRotation({ X = floorLoc.X, Y = floorLoc.Y, Z = floorLoc.Z + 1.5 }, { Pitch = 0.0, Yaw = RingWorld.InnerYaw, Roll = 0.0 }, false, {}, false)
    end)

    if RingWorld.IsWidgetMode then
        local outerWScale = ((radius * 2.0) / 512.0) * (1.0 + 0.015 * math.sin(os.clock() * 6.7))
        local innerWScale = outerWScale * (0.22 + 0.78 * p) * beatPulse
        pcall(function()
            if UObjectUtils.IsValid(RingWorld.OuterWC) then
                RingWorld.OuterWC:SetWorldScale3D({ X = outerWScale, Y = outerWScale, Z = outerWScale })
            end
            if UObjectUtils.IsValid(RingWorld.InnerWC) then
                RingWorld.InnerWC:SetWorldScale3D({ X = innerWScale, Y = innerWScale, Z = innerWScale })
            end
        end)
    else
        local meshR = math.max(10.0, RingWorld.MeshRadius or 50.0)
        local outerScale = radius / meshR
        local innerScale = outerScale * (0.22 + 0.78 * p) * beatPulse
        pcall(function()
            RingWorld.OuterActor:SetActorScale3D({ X = outerScale, Y = outerScale, Z = 1.0 })
            RingWorld.InnerActor:SetActorScale3D({ X = innerScale, Y = innerScale, Z = 1.15 })
        end)
    end

    local colorMode = (ActiveState.InRange and ActiveState.IsHolding) and "Hold" or (ActiveState.InRange and "Prox" or "Wait")
    if colorMode ~= RingWorld.LastColorMode then
        RingWorld.LastColorMode = colorMode
        local base = (colorMode == "Hold") and COLOR_FASTHOLD or ((colorMode == "Prox") and COLOR_PROX or COLOR_WAITING)
        local c = { R = base.R, G = base.G, B = base.B, A = opacityMul }
        local poolCol = { R = base.R, G = base.G, B = base.B, A = opacityMul * 0.34 }
        local ic = (colorMode == "Wait")
            and { R = 0.00, G = 0.93, B = 1.00, A = math.min(0.75, opacityMul * 1.15) }
            or  { R = base.R, G = base.G, B = base.B, A = math.min(0.80, opacityMul * 1.25) }
        if RingWorld.IsWidgetMode then
            if UObjectUtils.IsValid(RingWorld.OuterRingImg) then pcall(function() RingWorld.OuterRingImg:SetColorAndOpacity(c) end) end
            if UObjectUtils.IsValid(RingWorld.OuterPoolImg) then pcall(function() RingWorld.OuterPoolImg:SetColorAndOpacity(poolCol) end) end
            if UObjectUtils.IsValid(RingWorld.InnerRingImg) then pcall(function() RingWorld.InnerRingImg:SetColorAndOpacity(ic) end) end
        else
            ApplyColorToMID(RingWorld.OuterMID, c)
            ApplyColorToMID(RingWorld.InnerMID, ic)
        end
    end
end

-- ============================================================================
-- 2. WORLD-PROJECTED NATIVE CIRCULAR REVIVE MEDALLION & CALLOUT STRIP
-- ============================================================================

function ReviveOverlay.DestroyHUD()
    if UObjectUtils.IsValid(ProjHUD.Widget) then
        pcall(function() ProjHUD.Widget:RemoveFromParent() end)
    end
    ProjHUD.Widget = nil
    ProjHUD.OwnerPC = nil
    ProjHUD.World = nil
    ProjHUD.AttachedHost = nil
    ProjHUD.PosSlot = nil
    ProjHUD.SpinRingImg = nil
    ProjHUD.RadialImg = nil
    ProjHUD.RadialMID = nil
    ProjHUD.HeartImg = nil
    ProjHUD.Card = nil
    ProjHUD.TitleText = nil
    ProjHUD.PctText = nil
    ProjHUD.PromptText = nil
    ProjHUD.FillBorder = nil
    ProjHUD.FillSlot = nil
    ProjHUD.EmptySlot = nil
    ProjHUD.Visible = false
end

function ReviveOverlay.Hide()
    ActiveState.Active = false
    ReviveOverlay.DestroyWorldRings()
    if UObjectUtils.IsValid(ProjHUD.Widget) and ProjHUD.Visible then
        pcall(function() ProjHUD.Widget:SetVisibility(2) end)
        ProjHUD.Visible = false
    end
end

function ReviveOverlay.Destroy()
    ActiveState.Active = false
    ActiveState.DownedPawn = nil
    ReviveOverlay.DestroyWorldRings()
    ReviveOverlay.DestroyHUD()
end

local function EnsureHUDBuilt(ownerPC, isSplitScreen)
    local inGameplay, world = UObjectUtils.IsGameplayWorld()
    if not (inGameplay and UObjectUtils.IsValid(world) and UObjectUtils.IsLive(ownerPC)) then return false end

    local wantedHost = isSplitScreen and "PlayerScreen" or "Viewport"
    if UObjectUtils.IsValid(ProjHUD.Widget)
        and UObjectUtils.Same(ProjHUD.OwnerPC, ownerPC)
        and UObjectUtils.Same(ProjHUD.World, world)
        and ProjHUD.AttachedHost == wantedHost then
        return true
    end

    ReviveOverlay.DestroyHUD()
    local cls = UITheme.GetUMGClasses()
    if not (cls and UObjectUtils.IsValid(cls.Overlay)) then return false end

    local ok, built = pcall(function()
        local uw = cls.WBL:Create(world, cls.Widget, ownerPC)
        if not (UObjectUtils.IsValid(uw) and UObjectUtils.IsValid(uw.WidgetTree)) then return false end
        local wt = uw.WidgetTree
        local root = StaticConstructObject(cls.Canvas, wt)
        wt.RootWidget = root

        local containerV = StaticConstructObject(cls.VBox, wt)
        local cSlot = root:AddChildToCanvas(containerV)
        cSlot:SetAnchors({ Minimum = { X = 0.0, Y = 0.0 }, Maximum = { X = 0.0, Y = 0.0 } })
        pcall(function() cSlot:SetAlignment({ X = 0.5, Y = 0.5 }) end)
        pcall(function() cSlot:SetAutoSize(true) end)

        -- Sleek Single-Unit Skewed Dead as Disco Callout Pill (38x38 radial heart medallion on left + compact disco status on right)
        local card = StaticConstructObject(cls.Border, wt)
        UITheme.StyleDiscoFrame(card, { R = 0.042, G = 0.016, B = 0.088, A = 0.90 }, UITheme.Colors.Magenta, 1.8, 3.0)
        card:SetPadding({ Left = 8, Top = 5, Right = 11, Bottom = 5 })
        UITheme.ApplyNativeSkew(card, -8.0)
        local crSlot = containerV:AddChildToVerticalBox(card)
        pcall(function() crSlot:SetHorizontalAlignment(2) end)

        local mainH = StaticConstructObject(cls.HBox, wt)
        card:SetContent(mainH)

        -- Left: 38x38 Radial Beat Medallion (targeter_main + M_UI_InputHoldProgress_Circular + Heart_full)
        local medBox = StaticConstructObject(cls.SizeBox, wt)
        pcall(function() medBox:SetWidthOverride(38.0); medBox:SetHeightOverride(38.0) end)
        local medSlot = mainH:AddChildToHorizontalBox(medBox)
        pcall(function() medSlot:SetVerticalAlignment(2); medSlot:SetPadding({ Left = 0, Top = 0, Right = 8, Bottom = 0 }) end)

        local ov = StaticConstructObject(cls.Overlay, wt)
        medBox:AddChild(ov)

        local revCfg = Config.Revive or {}
        local spinRingImg, radialImg, radialMID, heartImg = nil, nil, nil, nil
        if revCfg.ShowProjectedReviveRing ~= false and UObjectUtils.IsValid(cls.Image) then
            local ringTex = UITheme.GetNativeTexture("TargeterMain")
                or UITheme.GetNativeTexture("CounterRingMMS")
                or UITheme.GetNativeTexture("CounterRing")
            if UObjectUtils.IsValid(ringTex) then
                spinRingImg = StaticConstructObject(cls.Image, wt)
                pcall(function()
                    spinRingImg:SetBrushFromTexture(ringTex, false)
                    spinRingImg:SetColorAndOpacity(UITheme.Colors.Magenta)
                    spinRingImg:SetRenderTransformPivot({ X = 0.5, Y = 0.5 })
                end)
                local srSlot = ov:AddChildToOverlay(spinRingImg)
                pcall(function() srSlot:SetHorizontalAlignment(0); srSlot:SetVerticalAlignment(0) end)
            end

            local radialMat = LoadCachedAsset("RadialMat") or LoadCachedAsset("RadialMatAlt")
            if UObjectUtils.IsValid(radialMat) then
                radialImg = StaticConstructObject(cls.Image, wt)
                pcall(function()
                    radialImg:SetBrushFromMaterial(radialMat)
                    radialMID = radialImg:GetDynamicMaterial()
                end)
                local rdSlot = ov:AddChildToOverlay(radialImg)
                pcall(function() rdSlot:SetHorizontalAlignment(0); rdSlot:SetVerticalAlignment(0); rdSlot:SetPadding({ Left = 3, Top = 3, Right = 3, Bottom = 3 }) end)
            end

            local heartTex = UITheme.GetNativeTexture("HeartFull")
            if UObjectUtils.IsValid(heartTex) then
                local hBox = StaticConstructObject(cls.SizeBox, wt)
                pcall(function() hBox:SetWidthOverride(16.0); hBox:SetHeightOverride(16.0) end)
                heartImg = StaticConstructObject(cls.Image, wt)
                pcall(function()
                    heartImg:SetBrushFromTexture(heartTex, false)
                    heartImg:SetColorAndOpacity(UITheme.Colors.Magenta)
                    heartImg:SetRenderTransformPivot({ X = 0.5, Y = 0.5 })
                end)
                hBox:AddChild(heartImg)
                local hSlot = ov:AddChildToOverlay(hBox)
                pcall(function() hSlot:SetHorizontalAlignment(2); hSlot:SetVerticalAlignment(2) end)
            end
        else
            pcall(function() medBox:SetVisibility(1) end)
        end

        -- Right: Compact 2-line Disco Callout + slim 128x5px neon bar
        local vb = StaticConstructObject(cls.VBox, wt)
        local vbSlot = mainH:AddChildToHorizontalBox(vb)
        pcall(function() vbSlot:SetVerticalAlignment(2) end)

        local topH = StaticConstructObject(cls.HBox, wt)
        local tSlot = vb:AddChildToVerticalBox(topH)
        pcall(function() tSlot:SetPadding({ Left = 0, Top = 0, Right = 0, Bottom = 2 }) end)

        local titleTxt = StaticConstructObject(cls.Text, wt)
        UITheme.StyleText(titleTxt, 10, UITheme.Fonts.Primary, UITheme.Colors.Magenta, false)
        UITheme.SetText(titleTxt, "P2 DOWN")
        local titS = topH:AddChildToHorizontalBox(titleTxt)
        pcall(function() titS:SetSize({ Value = 1.0, SizeRule = 1 }); titS:SetVerticalAlignment(2) end)

        local pctTxt = StaticConstructObject(cls.Text, wt)
        UITheme.StyleText(pctTxt, 9, UITheme.Fonts.Secondary, UITheme.Colors.Gold, false)
        UITheme.SetText(pctTxt, "0%")
        local pS = topH:AddChildToHorizontalBox(pctTxt)
        pcall(function() pS:SetVerticalAlignment(2); pS:SetPadding({ Left = 8, Top = 0, Right = 0, Bottom = 0 }) end)

        local trackBox = StaticConstructObject(cls.SizeBox, wt)
        pcall(function() trackBox:SetWidthOverride(132.0); trackBox:SetHeightOverride(5.0) end)
        local tbS = vb:AddChildToVerticalBox(trackBox)
        pcall(function() tbS:SetPadding({ Left = 0, Top = 0, Right = 0, Bottom = 2 }) end)

        local track = StaticConstructObject(cls.Border, wt)
        UITheme.StyleDiscoFrame(track, UITheme.Colors.TrackDark, UITheme.Colors.HairlineSubtle, 0.8, 1.5)
        track:SetPadding({ Left = 0, Top = 0, Right = 0, Bottom = 0 })
        trackBox:AddChild(track)

        local barH = StaticConstructObject(cls.HBox, wt)
        track:SetContent(barH)

        local fill = StaticConstructObject(cls.Border, wt)
        UITheme.StyleDiscoFrame(fill, UITheme.Colors.Cyan, nil, 0.0, 1.0)
        fill:SetPadding({ Left = 0, Top = 0, Right = 0, Bottom = 0 })
        local fillSlot = barH:AddChildToHorizontalBox(fill)

        local empty = StaticConstructObject(cls.Border, wt)
        UITheme.SetFill(empty, UITheme.Colors.Transparent)
        empty:SetPadding({ Left = 0, Top = 0, Right = 0, Bottom = 0 })
        local emptySlot = barH:AddChildToHorizontalBox(empty)

        local promptTxt = StaticConstructObject(cls.Text, wt)
        UITheme.StyleText(promptTxt, 8, UITheme.Fonts.Secondary, UITheme.Colors.TextSecondary, false, 0)
        UITheme.SetText(promptTxt, "HOLD [X / E] TO REVIVE")
        vb:AddChildToVerticalBox(promptTxt)

        ViewportController.RehostingGuard = true
        if isSplitScreen then
            local okPS, added = pcall(function() return uw:AddToPlayerScreen(80) end)
            if not (okPS and added) then
                uw:AddToViewport(9940)
            end
        else
            uw:AddToViewport(9940)
        end
        ViewportController.RehostingGuard = false
        pcall(function() uw:SetVisibility(2) end)

        ProjHUD.Widget = uw
        ProjHUD.OwnerPC = ownerPC
        ProjHUD.World = world
        ProjHUD.AttachedHost = wantedHost
        ProjHUD.PosSlot = cSlot
        ProjHUD.SpinRingImg = spinRingImg
        ProjHUD.RadialImg = radialImg
        ProjHUD.RadialMID = radialMID
        ProjHUD.HeartImg = heartImg
        ProjHUD.Card = card
        ProjHUD.TitleText = titleTxt
        ProjHUD.PromptText = promptTxt
        ProjHUD.PctText = pctTxt
        ProjHUD.FillBorder = fill
        ProjHUD.FillSlot = fillSlot
        ProjHUD.EmptySlot = emptySlot
        ProjHUD.Visible = false
        return true
    end)

    ViewportController.RehostingGuard = false
    return ok == true and built == true
end

local function ProjectDownedPosition(viewerPC, downedPawn, isSplitScreen)
    local wll = GetWidgetLayoutLibrary()
    local vpSize = { X = 1920.0, Y = 1080.0 }
    local vpScale = 1.0
    if UObjectUtils.IsValid(wll) then
        pcall(function()
            local s = wll:GetViewportScale(viewerPC)
            if type(s) == "number" and s > 0.05 then vpScale = s end
        end)
        pcall(function()
            local sz = wll:GetViewportSize(viewerPC)
            if sz and type(sz.X) == "number" and sz.X > 100.0 then
                vpSize = { X = sz.X / vpScale, Y = sz.Y / vpScale }
            end
        end)
    end

    local px, py = vpSize.X * 0.5, vpSize.Y * (isSplitScreen and 0.68 or 0.78)
    local projected = false

    if UObjectUtils.IsLive(viewerPC) and UObjectUtils.IsLive(downedPawn) then
        local loc = nil
        pcall(function() loc = downedPawn:K2_GetActorLocation() end)
        if loc then
            local targetPos = { X = loc.X, Y = loc.Y, Z = loc.Z + 62.0 }
            if UObjectUtils.IsValid(wll) then
                local outPos = { X = 0.0, Y = 0.0 }
                local okProj, onScr = pcall(function()
                    return wll:ProjectWorldLocationToWidgetPosition(viewerPC, targetPos, outPos, isSplitScreen)
                end)
                if okProj and onScr == true and type(outPos.X) == "number" and type(outPos.Y) == "number" then
                    px, py = outPos.X, outPos.Y
                    projected = true
                end
            end
            if not projected then
                local outScr = { X = 0.0, Y = 0.0 }
                local okS, onS = pcall(function()
                    return viewerPC:ProjectWorldLocationToScreen(targetPos, outScr, isSplitScreen)
                end)
                if okS and onS == true and type(outScr.X) == "number" and type(outScr.Y) == "number" then
                    px, py = outScr.X / vpScale, outScr.Y / vpScale
                    projected = true
                end
            end
        end
    end

    local maxX = math.max(220.0, vpSize.X - 150.0)
    local maxY = math.max(180.0, vpSize.Y - 120.0)
    px = math.max(150.0, math.min(maxX, px))
    py = math.max(95.0,  math.min(maxY, py))
    return px, py, projected
end

local function UpdateProjectedHUD(now)
    local revCfg = Config.Revive or {}
    if revCfg.ShowReviveUI == false then
        if ProjHUD.Visible and UObjectUtils.IsValid(ProjHUD.Widget) then
            pcall(function() ProjHUD.Widget:SetVisibility(2) end)
            ProjHUD.Visible = false
        end
        return
    end

    local isSplit = ViewportController.IsSplitScreenActive()
    local viewerPC = isSplit and SessionManager.GetController(ActiveState.RescuerPid or 0) or SessionManager.GetP1()
    if not UObjectUtils.IsLive(viewerPC) then viewerPC = SessionManager.GetP1() end
    if not viewerPC or not EnsureHUDBuilt(viewerPC, isSplit) then return end

    if not ProjHUD.Visible then
        pcall(function() ProjHUD.Widget:SetVisibility(3) end) -- SelfHitTestInvisible
        ProjHUD.Visible = true
    end

    -- 1. Smoothly position marker over downed character & spin outer counter ring every frame
    local px, py = ProjectDownedPosition(viewerPC, ActiveState.DownedPawn, isSplit)
    if UObjectUtils.IsValid(ProjHUD.PosSlot) then
        pcall(function() ProjHUD.PosSlot:SetPosition({ X = px, Y = py }) end)
    end

    local accentCol = (ActiveState.InRange and ActiveState.IsHolding) and COLOR_FASTHOLD
        or (ActiveState.InRange and COLOR_PROX or COLOR_WAITING)
    local clamped = math.max(0.0, math.min(1.0, ActiveState.Progress or 0.0))

    if UObjectUtils.IsValid(ProjHUD.SpinRingImg) then
        local angle = ((now * (ActiveState.InRange and 130.0 or 45.0)) % 360.0)
        pcall(function()
            ProjHUD.SpinRingImg:SetRenderTransformAngle(angle)
            ProjHUD.SpinRingImg:SetColorAndOpacity(accentCol)
        end)
    end
    if UObjectUtils.IsValid(ProjHUD.RadialMID) then
        for _, sp in ipairs(SCALAR_PROGRESS_PARAMS) do
            pcall(function() ProjHUD.RadialMID:SetScalarParameterValue(FName(sp), clamped) end)
        end
        ApplyColorToMID(ProjHUD.RadialMID, accentCol)
    end
    if UObjectUtils.IsValid(ProjHUD.HeartImg) then
        local hScale = 1.0 + 0.14 * math.abs(math.sin(now * (ActiveState.InRange and 8.5 or 3.8)))
        pcall(function()
            ProjHUD.HeartImg:SetRenderScale({ X = hScale, Y = hScale })
            ProjHUD.HeartImg:SetColorAndOpacity(accentCol)
        end)
    end

    -- 2. Refresh text/bar at 20Hz to keep Slate FText updates lightweight
    if (now - (ActiveState.LastUiUpdateAt or 0.0)) >= 0.045 then
        ActiveState.LastUiUpdateAt = now
        local who = (ActiveState.DownedPid == 0) and "P1 DOWN" or "P2 DOWN"
        UITheme.SetText(ProjHUD.TitleText, who)
        UITheme.SetText(ProjHUD.PctText, string.format("%d%%", math.floor(clamped * 100 + 0.5)))

        local prompt
        if ActiveState.IsHolding and ActiveState.InRange then
            UITheme.SetOutlineColor(ProjHUD.Card, UITheme.Colors.Gold, 2.0)
            UITheme.SetTextColor(ProjHUD.TitleText, UITheme.Colors.Gold)
            UITheme.SetFill(ProjHUD.FillBorder, UITheme.Colors.Gold)
            prompt = "FAST REVIVING!"
        elseif ActiveState.InRange then
            UITheme.SetOutlineColor(ProjHUD.Card, UITheme.Colors.Cyan, 1.8)
            UITheme.SetTextColor(ProjHUD.TitleText, UITheme.Colors.Cyan)
            UITheme.SetFill(ProjHUD.FillBorder, UITheme.Colors.Cyan)
            prompt = (ActiveState.DownedPid == 0)
                and "HOLD [X / A] FAST REVIVE"
                or  "HOLD [E / F] OR [X / A]"
        else
            UITheme.SetOutlineColor(ProjHUD.Card, UITheme.Colors.Magenta, 1.6)
            UITheme.SetTextColor(ProjHUD.TitleText, UITheme.Colors.Magenta)
            UITheme.SetFill(ProjHUD.FillBorder, UITheme.Colors.Magenta)
            prompt = string.format("STEP IN SPOTLIGHT (%.1fm)", ActiveState.DistMeters or 0.0)
        end
        UITheme.SetText(ProjHUD.PromptText, prompt)

        pcall(function() ProjHUD.FillSlot:SetSize({ Value = math.max(0.001, clamped), SizeRule = 1 }) end)
        pcall(function() ProjHUD.EmptySlot:SetSize({ Value = math.max(0.001, 1.0 - clamped), SizeRule = 1 }) end)
    end
end

function ReviveOverlay.SetState(downedPid, rescuerPid, downedPawn, progress, inRange, distMeters, isHolding, radius)
    ActiveState.Active = UObjectUtils.IsLive(downedPawn)
    ActiveState.DownedPid = downedPid
    ActiveState.RescuerPid = rescuerPid
    ActiveState.DownedPawn = downedPawn
    ActiveState.Progress = progress or 0.0
    ActiveState.InRange = (inRange == true)
    ActiveState.DistMeters = distMeters or 0.0
    ActiveState.IsHolding = (isHolding == true)
    ActiveState.Radius = radius or 210.0
end

function ReviveOverlay.TickFrame(dt)
    if not ActiveState.Active then return end
    if not SessionManager.IsSafeForGameplayHooks() or not UObjectUtils.IsLive(ActiveState.DownedPawn) then
        ReviveOverlay.Hide()
        return
    end
    local now = os.clock()
    UpdateWorldRings(dt)
    UpdateProjectedHUD(now)
end

return ReviveOverlay
