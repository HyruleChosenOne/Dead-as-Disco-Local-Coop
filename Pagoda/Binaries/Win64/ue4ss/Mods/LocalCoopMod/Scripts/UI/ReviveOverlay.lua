-- World-space revive floor rings and screen-projected revive status card.

local UObjectUtils = require("Utils.UObjectUtils")
local Logger = require("Utils.Logger")
local SessionManager = require("Core.SessionManager")
local ViewportController = require("Camera.ViewportController")
local InputRouting = require("Input.InputRouting")
local UITheme = require("UI.UITheme")

local ReviveOverlay = {}

local Config = {}
local IsP2MenuOpenFn = nil

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
    OuterWidget = nil,
    InnerWidget = nil,
    OuterRingImg = nil,
    OuterGlowImg = nil,
    OuterPoolImg = nil,
    InnerRingImg = nil,
    InnerFillImg = nil,
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
    LastColorMode = nil,
    SmoothedPosX = nil,
    SmoothedPosY = nil,
}

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

local COLOR_WAITING     = { R = 1.00, G = 0.10, B = 0.58, A = 0.76 }
local COLOR_PROX        = { R = 0.00, G = 0.94, B = 1.00, A = 0.82 }
local COLOR_FASTHOLD    = { R = 1.00, G = 0.86, B = 0.14, A = 0.88 }
local COLOR_ACCENT_CYAN = { R = 0.00, G = 0.94, B = 1.00, A = 0.68 }
local SCALAR_PROGRESS_PARAMS = { "Progress", "Percent", "Fill", "Value", "Alpha", "Amount" }
local MAT_COLOR_PARAMS = { "Color", "Tint", "EmissiveColor", "BaseColor", "PrimaryColor" }
local CachedParamFNames = {}
local CachedPelvisFName = nil

local function GetCachedFName(str)
    local fn = CachedParamFNames[str]
    if not fn then
        fn = FName(str)
        CachedParamFNames[str] = fn
    end
    return fn
end

function ReviveOverlay.Init(config, callbacks)
    Config = config or {}
    if callbacks and type(callbacks.IsP2MenuOpen) == "function" then
        IsP2MenuOpenFn = callbacks.IsP2MenuOpen
    end
    ViewportController.RegisterModWidget("ReviveOverlay", function() return ProjHUD.Widget end)
end

local function LoadCachedAsset(key)
    local cached = CachedAssets[key]
    if cached == false then return nil end
    if cached ~= nil and UObjectUtils.IsValid(cached) then
        return cached
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
        pcall(function() mid:SetVectorParameterValue(GetCachedFName(pname), color) end)
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

local function SpawnRingWidgetActor(world, loc, rot, drawPx, initScale, initColor, isInner)
    local smCls = GetStaticMeshActorClass()
    local wcCls = GetWidgetComponentClass()
    local p1Ctrl = SessionManager.GetP1()
    local cls = UITheme.GetUMGClasses()
    -- Use pure circular ring textures (avoid TargeterMain crosshair).
    local ringTex = UITheme.GetNativeTexture("CounterRing")
        or UITheme.GetNativeTexture("CounterRingMMS")
    local accentRingTex = UITheme.GetNativeTexture("CounterRingMMS") or ringTex
    local poolTex = UITheme.GetNativeTexture("HalftoneCircle")
        or UITheme.GetNativeTexture("HalftoneRadial")

    if not (UObjectUtils.IsValid(smCls) and UObjectUtils.IsValid(wcCls) and p1Ctrl
        and cls and UObjectUtils.IsValid(cls.Overlay) and UObjectUtils.IsValid(cls.Image) and UObjectUtils.IsValid(ringTex)) then
        Logger.Warn("ReviveOverlay", "SpawnRingWidgetActor missing prerequisites (sm=%s wc=%s p1=%s ringTex=%s)",
            tostring(UObjectUtils.IsValid(smCls)), tostring(UObjectUtils.IsValid(wcCls)),
            tostring(p1Ctrl ~= nil), tostring(UObjectUtils.IsValid(ringTex)))
        return nil, nil, nil, nil, nil, nil
    end

    local actor = world:SpawnActor(smCls, loc, rot)
    if not UObjectUtils.IsLive(actor) then
        Logger.Warn("ReviveOverlay", "SpawnRingWidgetActor: world:SpawnActor(StaticMeshActor) returned nil")
        return nil, nil, nil, nil, nil, nil
    end

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

        local baseA = initColor.A or 0.74

        -- Layer 0: Subtle dark contrast ring on outer circle so neon glow pops on bright floors
        if not isInner then
            local halo = StaticConstructObject(cls.Image, wt)
            pcall(function()
                halo:SetBrushFromTexture(ringTex, false)
                halo:SetColorAndOpacity({ R = 0.02, G = 0.01, B = 0.05, A = 0.46 })
            end)
            local hSlot = ov:AddChildToOverlay(halo)
            pcall(function()
                hSlot:SetHorizontalAlignment(0)
                hSlot:SetVerticalAlignment(0)
                hSlot:SetPadding({ Left = 4.0, Top = 4.0, Right = 4.0, Bottom = 4.0 })
            end)
        end

        -- Layer 1: Semi-transparent neon disco floor pool (soft halftone radial glow inside the circle)
        local poolImg = nil
        if UObjectUtils.IsValid(poolTex) then
            poolImg = StaticConstructObject(cls.Image, wt)
            pcall(function()
                poolImg:SetBrushFromTexture(poolTex, false)
                poolImg:SetColorAndOpacity({
                    R = initColor.R,
                    G = initColor.G,
                    B = initColor.B,
                    A = isInner and (baseA * 0.28) or (baseA * 0.24),
                })
            end)
            local pSlot = ov:AddChildToOverlay(poolImg)
            local poolPad = isInner and 18.0 or 14.0
            pcall(function()
                pSlot:SetHorizontalAlignment(0)
                pSlot:SetVerticalAlignment(0)
                pSlot:SetPadding({ Left = poolPad, Top = poolPad, Right = poolPad, Bottom = poolPad })
            end)
        end

        -- Layer 2: Soft outer neon bloom ring (wider semi-transparent halo around the primary circle)
        local glowImg = nil
        if not isInner then
            glowImg = StaticConstructObject(cls.Image, wt)
            pcall(function()
                glowImg:SetBrushFromTexture(accentRingTex, false)
                glowImg:SetColorAndOpacity({
                    R = initColor.R,
                    G = initColor.G,
                    B = initColor.B,
                    A = baseA * 0.52,
                })
            end)
            local gSlot = ov:AddChildToOverlay(glowImg)
            pcall(function()
                gSlot:SetHorizontalAlignment(0)
                gSlot:SetVerticalAlignment(0)
                gSlot:SetPadding({ Left = 2.0, Top = 2.0, Right = 2.0, Bottom = 2.0 })
            end)
        end

        -- Layer 3: Crisp semi-transparent neon primary circle
        local img = StaticConstructObject(cls.Image, wt)
        pcall(function()
            img:SetBrushFromTexture(isInner and accentRingTex or ringTex, false)
            img:SetColorAndOpacity({
                R = initColor.R,
                G = initColor.G,
                B = initColor.B,
                A = isInner and math.min(0.92, baseA * 1.12) or baseA,
            })
        end)
        local iSlot = ov:AddChildToOverlay(img)
        local pad = isInner and 6.0 or 8.0
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

        local sf = math.max(0.25, tonumber(initScale) or 1.0)
        pcall(function() wComp:SetMobility(2) end)
        if UObjectUtils.IsValid(smComp) then
            pcall(function() wComp:K2_AttachToComponent(smComp, FName("None"), 2, 2, 2, false) end)
        end
        pcall(function() wComp:SetCollisionEnabled(0) end)
        pcall(function() wComp:SetCastShadow(false) end)
        pcall(function() wComp:SetCullDistance(0.0); wComp.bNeverDistanceCull = true; wComp.bAllowCullDistanceVolume = false end)
        pcall(function() wComp:SetWidgetSpace(0) end)        -- EWidgetSpace::World
        pcall(function() wComp:SetTwoSided(true) end)
        pcall(function() wComp:SetBlendMode(2) end)          -- EWidgetBlendMode::Transparent
        pcall(function() wComp:SetDrawAtDesiredSize(false) end)
        pcall(function() wComp:SetDrawSize({ X = drawPx, Y = drawPx }) end)
        pcall(function() wComp:SetPivot({ X = 0.5, Y = 0.5 }) end)
        pcall(function() wComp:SetBackgroundColor({ R = 0.0, G = 0.0, B = 0.0, A = 0.0 }) end)
        pcall(function() wComp:K2_SetRelativeLocation({ X = 0.0, Y = 0.0, Z = 0.0 }, false, {}, false) end)
        pcall(function() wComp:K2_SetRelativeRotation({ Pitch = 90.0, Yaw = 0.0, Roll = 0.0 }, false, {}, false) end)
        pcall(function() wComp:SetWorldScale3D({ X = sf, Y = sf, Z = sf }) end)
        pcall(function() wComp:SetWidget(uw) end)
        pcall(function() wComp:SetVisibility(true, true) end)
        return { wComp = wComp, uw = uw, img = img, poolImg = poolImg, glowImg = glowImg }
    end)

    if okWidget and built and UObjectUtils.IsValid(built.wComp) and UObjectUtils.IsValid(built.img) then
        return actor, built.wComp, built.uw, built.img, built.poolImg, built.glowImg
    end

    if not okWidget then
        Logger.Warn("ReviveOverlay", "SpawnRingWidgetActor build error: %s", tostring(built))
    end
    SessionManager.DestroyActorSafely(actor)
    return nil, nil, nil, nil, nil, nil
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
    RingWorld.OuterWidget = nil
    RingWorld.InnerWidget = nil
    RingWorld.OuterRingImg = nil
    RingWorld.OuterGlowImg = nil
    RingWorld.OuterPoolImg = nil
    RingWorld.InnerRingImg = nil
    RingWorld.InnerFillImg = nil
    RingWorld.OuterMID = nil
    RingWorld.InnerMID = nil
    RingWorld.IsWidgetMode = false
    RingWorld.WorldKey = nil
    RingWorld.LastColorMode = nil
end

local function EnsureWorldRings(world, loc, initRadius)
    local revCfg = Config.Revive or {}
    if revCfg.ShowWorldReviveCircle == false then return false end
    if not UObjectUtils.IsValid(world) then return false end

    local wKey = UObjectUtils.GetKey(world)
    if UObjectUtils.IsLive(RingWorld.OuterActor) and UObjectUtils.IsLive(RingWorld.InnerActor) and RingWorld.WorldKey == wKey then
        return true
    end

    ReviveOverlay.DestroyWorldRings()
    local rot = { Pitch = 0.0, Yaw = 0.0, Roll = 0.0 }
    local drawPx = 256.0
    local visScale = tonumber(revCfg.ReviveCircleVisualScale) or 0.92
    local startScale = ((math.max(120.0, tonumber(initRadius) or 260.0) * visScale) * 2.0) / drawPx

    -- Primary: Flat World-Space UWidgetComponent semi-transparent neon disco rings (pure circles, zero X)
    local outerA, outerWC, outerUW, outerImg, outerPoolImg, outerGlowImg = SpawnRingWidgetActor(world, loc, rot, drawPx, startScale, COLOR_WAITING, false)
    if UObjectUtils.IsLive(outerA) then
        local innerA, innerWC, innerUW, innerImg, innerFillImg = SpawnRingWidgetActor(
            world, { X = loc.X, Y = loc.Y, Z = loc.Z + 2.0 }, rot, drawPx, startScale * 0.28, COLOR_ACCENT_CYAN, true
        )
        if UObjectUtils.IsLive(innerA) then
            RingWorld.WorldKey = wKey
            RingWorld.OuterActor = outerA
            RingWorld.InnerActor = innerA
            RingWorld.OuterWC = outerWC
            RingWorld.InnerWC = innerWC
            RingWorld.OuterWidget = outerUW
            RingWorld.InnerWidget = innerUW
            RingWorld.OuterRingImg = outerImg
            RingWorld.OuterGlowImg = outerGlowImg
            RingWorld.OuterPoolImg = outerPoolImg
            RingWorld.InnerRingImg = innerImg
            RingWorld.InnerFillImg = innerFillImg
            RingWorld.IsWidgetMode = true
            RingWorld.LastColorMode = nil
            Logger.Info("ReviveOverlay", "Spawned 3D Widget revive circle (radius=%.0f, scale=%.2f).",
                tonumber(initRadius) or 260.0, startScale)
            return true
        end
        SessionManager.DestroyActorSafely(outerA)
    end

    -- Fallback: StaticMeshActor FX ring
    local meshObj = LoadCachedAsset("RingMesh") or LoadCachedAsset("FallbackDisc")
    if not UObjectUtils.IsValid(meshObj) then
        Logger.Warn("ReviveOverlay", "Both Widget and Mesh revive ring spawns failed!")
        return false
    end

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
    Logger.Info("ReviveOverlay", "Spawned 3D Fallback Mesh revive circle.")
    return true
end

local function GetDownedBodyFloorLocation(pawn)
    local loc = nil
    pcall(function() loc = pawn:K2_GetActorLocation() end)
    if not loc then return nil end

    local halfH = 88.0
    pcall(function()
        if UObjectUtils.IsValid(pawn.CapsuleComponent) then
            local ch = pawn.CapsuleComponent:GetScaledCapsuleHalfHeight()
            if type(ch) == "number" and ch > 15.0 then halfH = ch end
        end
    end)

    local cx, cy = loc.X, loc.Y
    pcall(function()
        if UObjectUtils.IsValid(pawn.Mesh) then
            if not CachedPelvisFName then CachedPelvisFName = FName("pelvis") end
            local pel = pawn.Mesh:GetSocketLocation(CachedPelvisFName)
            if pel and (pel.X ~= 0.0 or pel.Y ~= 0.0) then
                local dx, dy = pel.X - loc.X, pel.Y - loc.Y
                if (dx * dx + dy * dy) <= (180.0 * 180.0) then
                    cx, cy = pel.X, pel.Y
                end
            end
        end
    end)

    return { X = cx, Y = cy, Z = loc.Z - halfH + 4.5 }
end

local function UpdateWorldRings(dt)
    local pawn = ActiveState.DownedPawn
    local inGameplay, world = UObjectUtils.IsGameplayWorld()
    if not (inGameplay and UObjectUtils.IsValid(world) and UObjectUtils.IsLive(pawn)) then
        ReviveOverlay.DestroyWorldRings()
        return
    end

    local floorLoc = GetDownedBodyFloorLocation(pawn)
    if not floorLoc then return end

    if not EnsureWorldRings(world, floorLoc, ActiveState.Radius or 260.0) then return end

    local revCfg = Config.Revive or {}
    local visScale = tonumber(revCfg.ReviveCircleVisualScale) or 0.92
    local opacityMul = math.max(0.35, math.min(0.92, tonumber(revCfg.ReviveCircleOpacity) or 0.72))
    local radius = (ActiveState.Radius or 260.0) * visScale
    local stepDt = (type(dt) == "number" and dt > 0.0) and math.min(0.10, dt) or 0.016
    local outerSpeed = ActiveState.InRange and 42.0 or 20.0
    local innerSpeed = (ActiveState.InRange and ActiveState.IsHolding) and 175.0 or (ActiveState.InRange and 92.0 or 32.0)
    RingWorld.OuterYaw = (RingWorld.OuterYaw + outerSpeed * stepDt) % 360.0
    RingWorld.InnerYaw = (RingWorld.InnerYaw - innerSpeed * stepDt) % 360.0

    -- Smooth 128 BPM disco beat pulse + dynamic inner ring expansion (0.24 -> 1.00 as progress charges)
    local now = os.clock()
    local beatSin = math.sin(now * 6.7)
    local beatPulse = 1.0 + 0.032 * beatSin
    local p = math.max(0.0, math.min(1.0, ActiveState.Progress or 0.0))

    pcall(function()
        RingWorld.OuterActor:K2_SetActorLocationAndRotation(floorLoc, { Pitch = 0.0, Yaw = RingWorld.OuterYaw, Roll = 0.0 }, false, {}, false)
        RingWorld.InnerActor:K2_SetActorLocationAndRotation({ X = floorLoc.X, Y = floorLoc.Y, Z = floorLoc.Z + 2.0 }, { Pitch = 0.0, Yaw = RingWorld.InnerYaw, Roll = 0.0 }, false, {}, false)
    end)

    if RingWorld.IsWidgetMode then
        local outerWScale = ((radius * 2.0) / 256.0) * (1.0 + 0.018 * beatSin)
        local innerFrac = ActiveState.InRange and (0.26 + 0.74 * p) or (0.22 + 0.70 * p + 0.04 * (0.5 + 0.5 * beatSin))
        local innerWScale = outerWScale * innerFrac * beatPulse
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
        local innerScale = outerScale * (0.24 + 0.76 * p) * beatPulse
        pcall(function()
            RingWorld.OuterActor:SetActorScale3D({ X = outerScale, Y = outerScale, Z = 1.0 })
            RingWorld.InnerActor:SetActorScale3D({ X = innerScale, Y = innerScale, Z = 1.15 })
        end)
    end

    local colorMode = (ActiveState.InRange and ActiveState.IsHolding) and "Hold" or (ActiveState.InRange and "Prox" or "Wait")
    if colorMode ~= RingWorld.LastColorMode then
        RingWorld.LastColorMode = colorMode
        local base = (colorMode == "Hold") and COLOR_FASTHOLD or ((colorMode == "Prox") and COLOR_PROX or COLOR_WAITING)
        local c = { R = base.R, G = base.G, B = base.B, A = math.min(0.90, opacityMul * 1.08) }
        local glowCol = { R = base.R, G = base.G, B = base.B, A = opacityMul * 0.55 }
        local poolCol = { R = base.R, G = base.G, B = base.B, A = opacityMul * 0.26 }
        local ic = (colorMode == "Wait")
            and { R = 0.00, G = 0.94, B = 1.00, A = math.min(0.86, opacityMul * 1.10) }
            or  { R = base.R, G = base.G, B = base.B, A = math.min(0.94, opacityMul * 1.22) }
        local iFill = { R = ic.R, G = ic.G, B = ic.B, A = opacityMul * (colorMode == "Wait" and 0.20 or 0.30) }
        if RingWorld.IsWidgetMode then
            if UObjectUtils.IsValid(RingWorld.OuterRingImg) then pcall(function() RingWorld.OuterRingImg:SetColorAndOpacity(c) end) end
            if UObjectUtils.IsValid(RingWorld.OuterGlowImg) then pcall(function() RingWorld.OuterGlowImg:SetColorAndOpacity(glowCol) end) end
            if UObjectUtils.IsValid(RingWorld.OuterPoolImg) then pcall(function() RingWorld.OuterPoolImg:SetColorAndOpacity(poolCol) end) end
            if UObjectUtils.IsValid(RingWorld.InnerRingImg) then pcall(function() RingWorld.InnerRingImg:SetColorAndOpacity(ic) end) end
            if UObjectUtils.IsValid(RingWorld.InnerFillImg) then pcall(function() RingWorld.InnerFillImg:SetColorAndOpacity(iFill) end) end
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
    ProjHUD.LastColorMode = nil
    ProjHUD.SmoothedPosX = nil
    ProjHUD.SmoothedPosY = nil
end

function ReviveOverlay.HideHUDOnly()
    if UObjectUtils.IsValid(ProjHUD.Widget) and ProjHUD.Visible then
        pcall(function() ProjHUD.Widget:SetVisibility(2) end)
        ProjHUD.Visible = false
    end
    ProjHUD.SmoothedPosX = nil
    ProjHUD.SmoothedPosY = nil
end

function ReviveOverlay.Hide()
    ActiveState.Active = false
    ReviveOverlay.DestroyWorldRings()
    ReviveOverlay.HideHUDOnly()
end

function ReviveOverlay.Destroy()
    ActiveState.Active = false
    ActiveState.DownedPawn = nil
    ReviveOverlay.DestroyWorldRings()
    ReviveOverlay.DestroyHUD()
end

local function EnsureHUDBuilt(ownerPC)
    local inGameplay, world = UObjectUtils.IsGameplayWorld()
    if not (inGameplay and UObjectUtils.IsValid(world) and UObjectUtils.IsLive(ownerPC)) then return false end

    if UObjectUtils.IsValid(ProjHUD.Widget)
        and UObjectUtils.Same(ProjHUD.OwnerPC, ownerPC)
        and UObjectUtils.Same(ProjHUD.World, world)
        and ProjHUD.AttachedHost == "Viewport" then
        return true
    end

    ReviveOverlay.DestroyHUD()
    local cls = UITheme.GetUMGClasses()
    if not (cls and UObjectUtils.IsValid(cls.Overlay)) then
        Logger.Warn("ReviveOverlay", "EnsureHUDBuilt: UMG classes unavailable.")
        return false
    end

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

        local card = StaticConstructObject(cls.Border, wt)
        UITheme.StyleDiscoFrame(card, { R = 0.040, G = 0.015, B = 0.088, A = 0.93 }, UITheme.Colors.Magenta, 2.0, 3.0)
        card:SetPadding({ Left = 10, Top = 7, Right = 13, Bottom = 7 })
        UITheme.ApplyNativeSkew(card, -7.0)
        local crSlot = containerV:AddChildToVerticalBox(card)
        pcall(function() crSlot:SetHorizontalAlignment(2) end)

        local mainH = StaticConstructObject(cls.HBox, wt)
        card:SetContent(mainH)

        -- Left: 42x42 radial heart medallion
        local medBox = StaticConstructObject(cls.SizeBox, wt)
        pcall(function() medBox:SetWidthOverride(42.0); medBox:SetHeightOverride(42.0) end)
        local medSlot = mainH:AddChildToHorizontalBox(medBox)
        pcall(function() medSlot:SetVerticalAlignment(2); medSlot:SetPadding({ Left = 0, Top = 0, Right = 10, Bottom = 0 }) end)

        local ov = StaticConstructObject(cls.Overlay, wt)
        medBox:AddChild(ov)

        local revCfg = Config.Revive or {}
        local spinRingImg, radialImg, radialMID, heartImg = nil, nil, nil, nil
        if revCfg.ShowProjectedReviveRing ~= false and UObjectUtils.IsValid(cls.Image) then
            local ringTex = UITheme.GetNativeTexture("CounterRing")
                or UITheme.GetNativeTexture("CounterRingMMS")
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
                pcall(function() hBox:SetWidthOverride(18.0); hBox:SetHeightOverride(18.0) end)
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

        -- Right: status header, progress bar, and contextual prompt
        local vb = StaticConstructObject(cls.VBox, wt)
        local vbSlot = mainH:AddChildToHorizontalBox(vb)
        pcall(function() vbSlot:SetVerticalAlignment(2) end)

        local topH = StaticConstructObject(cls.HBox, wt)
        local tSlot = vb:AddChildToVerticalBox(topH)
        pcall(function() tSlot:SetPadding({ Left = 0, Top = 0, Right = 0, Bottom = 3 }) end)

        local titleTxt = StaticConstructObject(cls.Text, wt)
        UITheme.StyleText(titleTxt, 11, UITheme.Fonts.Primary, UITheme.Colors.Magenta, false)
        UITheme.SetText(titleTxt, "P2 DOWN")
        local titS = topH:AddChildToHorizontalBox(titleTxt)
        pcall(function() titS:SetSize({ Value = 1.0, SizeRule = 1 }); titS:SetVerticalAlignment(2) end)

        local pctTxt = StaticConstructObject(cls.Text, wt)
        UITheme.StyleText(pctTxt, 10, UITheme.Fonts.Secondary, UITheme.Colors.Gold, false)
        UITheme.SetText(pctTxt, "0%")
        local pS = topH:AddChildToHorizontalBox(pctTxt)
        pcall(function() pS:SetVerticalAlignment(2); pS:SetPadding({ Left = 10, Top = 0, Right = 0, Bottom = 0 }) end)

        local trackBox = StaticConstructObject(cls.SizeBox, wt)
        pcall(function() trackBox:SetWidthOverride(164.0); trackBox:SetHeightOverride(6.0) end)
        local tbS = vb:AddChildToVerticalBox(trackBox)
        pcall(function() tbS:SetPadding({ Left = 0, Top = 0, Right = 0, Bottom = 3 }) end)

        local track = StaticConstructObject(cls.Border, wt)
        UITheme.StyleDiscoFrame(track, UITheme.Colors.TrackDark, UITheme.Colors.HairlineBright, 0.9, 2.0)
        track:SetPadding({ Left = 1, Top = 1, Right = 1, Bottom = 1 })
        trackBox:AddChild(track)

        local barH = StaticConstructObject(cls.HBox, wt)
        track:SetContent(barH)

        local fill = StaticConstructObject(cls.Border, wt)
        UITheme.StyleDiscoFrame(fill, UITheme.Colors.Cyan, nil, 0.0, 1.5)
        fill:SetPadding({ Left = 0, Top = 0, Right = 0, Bottom = 0 })
        local fillSlot = barH:AddChildToHorizontalBox(fill)

        local empty = StaticConstructObject(cls.Border, wt)
        UITheme.SetFill(empty, UITheme.Colors.Transparent)
        empty:SetPadding({ Left = 0, Top = 0, Right = 0, Bottom = 0 })
        local emptySlot = barH:AddChildToHorizontalBox(empty)

        local promptTxt = StaticConstructObject(cls.Text, wt)
        UITheme.StyleText(promptTxt, 9, UITheme.Fonts.Secondary, UITheme.Colors.TextPrimary, false, 0)
        UITheme.SetText(promptTxt, "HOLD [X / A] TO REVIVE")
        vb:AddChildToVerticalBox(promptTxt)

        -- Always attach to full Viewport (Z=9940) so coordinates match full-window projection
        -- cleanly in Horizontal Split, Vertical Split, AND Arena Camera without half-screen clipping.
        ViewportController.RehostingGuard = true
        uw:AddToViewport(9940)
        ViewportController.RehostingGuard = false
        pcall(function() uw:SetVisibility(2) end)

        ProjHUD.Widget = uw
        ProjHUD.OwnerPC = ownerPC
        ProjHUD.World = world
        ProjHUD.AttachedHost = "Viewport"
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
    if not ok then
        Logger.Warn("ReviveOverlay", "EnsureHUDBuilt error: %s", tostring(built))
        return false
    end
    return built == true
end

local function ProjectDownedPosition(viewerPC, downedPawn, isSplitScreen, rescuerPid)
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

    -- Compute safe bounds within the rescuer's viewport half so the callout
    -- never straddles the split seam or clips off screen edges.
    local minX, maxX = 148.0, math.max(220.0, vpSize.X - 148.0)
    local minY, maxY = 74.0,  math.max(180.0, vpSize.Y - 88.0)
    local px, py = vpSize.X * 0.5, vpSize.Y * 0.78

    if isSplitScreen then
        local eff = ViewportController.GetEffectiveScreenMode()
        if eff == 0 then
            local halfY = vpSize.Y * 0.5
            if rescuerPid == 1 then
                minY = halfY + 52.0
                maxY = math.max(minY, vpSize.Y - 64.0)
                py = vpSize.Y * 0.80
            else
                minY = 64.0
                maxY = math.max(minY, halfY - 52.0)
                py = vpSize.Y * 0.34
            end
            px = vpSize.X * 0.5
        elseif eff == 1 then
            local halfX = vpSize.X * 0.5
            if rescuerPid == 1 then
                minX = halfX + 132.0
                maxX = math.max(minX, vpSize.X - 132.0)
                px = vpSize.X * 0.75
            else
                minX = 132.0
                maxX = math.max(minX, halfX - 132.0)
                px = vpSize.X * 0.25
            end
            py = vpSize.Y * 0.76
        end
    end

    local projected = false
    if UObjectUtils.IsLive(viewerPC) and UObjectUtils.IsLive(downedPawn) then
        local floorLoc = GetDownedBodyFloorLocation(downedPawn)
        if floorLoc then
            local targetPos = { X = floorLoc.X, Y = floorLoc.Y, Z = floorLoc.Z + 125.0 }
            if UObjectUtils.IsValid(wll) then
                local outPos = { X = 0.0, Y = 0.0 }
                local okProj, onScr, retPos = pcall(function()
                    return wll:ProjectWorldLocationToWidgetPosition(viewerPC, targetPos, outPos, false)
                end)
                local pos = (type(retPos) == "table" and type(retPos.X) == "number") and retPos or outPos
                if okProj and onScr == true and type(pos.X) == "number" and type(pos.Y) == "number"
                    and (math.abs(pos.X) > 1.0 or math.abs(pos.Y) > 1.0) then
                    px, py = pos.X, pos.Y
                    projected = true
                end
            end
            if not projected then
                local outScr = { X = 0.0, Y = 0.0 }
                local okS, onS, retScr = pcall(function()
                    return viewerPC:ProjectWorldLocationToScreen(targetPos, outScr, false)
                end)
                local scr = (type(retScr) == "table" and type(retScr.X) == "number") and retScr or outScr
                if okS and onS == true and type(scr.X) == "number" and type(scr.Y) == "number"
                    and (math.abs(scr.X) > 1.0 or math.abs(scr.Y) > 1.0) then
                    px, py = scr.X / vpScale, scr.Y / vpScale
                    projected = true
                end
            end
        end
    end

    px = math.max(minX, math.min(maxX, px))
    py = math.max(minY, math.min(maxY, py))
    return px, py, projected
end

local function UpdateProjectedHUD(now, dt)
    local revCfg = Config.Revive or {}
    if revCfg.ShowReviveUI == false then
        ReviveOverlay.HideHUDOnly()
        return
    end

    local isSplit = ViewportController.IsSplitScreenActive()
    local rescuerPid = ActiveState.RescuerPid or 0
    local p1Ctrl = SessionManager.GetP1()
    local viewerPC = isSplit and SessionManager.GetController(rescuerPid) or p1Ctrl
    if not UObjectUtils.IsLive(viewerPC) then viewerPC = p1Ctrl end
    if not (p1Ctrl and viewerPC) or not EnsureHUDBuilt(p1Ctrl) then return end

    if not ProjHUD.Visible then
        pcall(function() ProjHUD.Widget:SetVisibility(3) end) -- SelfHitTestInvisible
        ProjHUD.Visible = true
        ProjHUD.LastColorMode = nil
    end

    local targetX, targetY, isOnScreen = ProjectDownedPosition(viewerPC, ActiveState.DownedPawn, isSplit, rescuerPid)
    if ProjHUD.SmoothedPosX == nil or ProjHUD.SmoothedPosY == nil then
        ProjHUD.SmoothedPosX = targetX
        ProjHUD.SmoothedPosY = targetY
    else
        local dx, dy = targetX - ProjHUD.SmoothedPosX, targetY - ProjHUD.SmoothedPosY
        if (dx * dx + dy * dy) > (360.0 * 360.0) then
            ProjHUD.SmoothedPosX = targetX
            ProjHUD.SmoothedPosY = targetY
        else
            local stepDt = (type(dt) == "number" and dt > 0.0) and math.min(0.10, dt) or 0.016
            local alpha = 1.0 - math.exp(-16.0 * stepDt)
            ProjHUD.SmoothedPosX = ProjHUD.SmoothedPosX + dx * alpha
            ProjHUD.SmoothedPosY = ProjHUD.SmoothedPosY + dy * alpha
        end
    end

    if UObjectUtils.IsValid(ProjHUD.PosSlot) then
        pcall(function() ProjHUD.PosSlot:SetPosition({ X = ProjHUD.SmoothedPosX, Y = ProjHUD.SmoothedPosY }) end)
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
            pcall(function() ProjHUD.RadialMID:SetScalarParameterValue(GetCachedFName(sp), clamped) end)
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

    -- Refresh text and linear bar at ~20Hz to keep Slate FText churn low.
    if (now - (ActiveState.LastUiUpdateAt or 0.0)) >= 0.045 then
        ActiveState.LastUiUpdateAt = now
        local who = (ActiveState.DownedPid == 0) and "P1 DOWN" or "P2 DOWN"
        UITheme.SetText(ProjHUD.TitleText, who)
        UITheme.SetText(ProjHUD.PctText, string.format("%d%%", math.floor(clamped * 100 + 0.5)))

        local colorMode = (ActiveState.IsHolding and ActiveState.InRange) and "Hold"
            or (ActiveState.InRange and "Prox" or "Wait")
        if colorMode ~= ProjHUD.LastColorMode then
            ProjHUD.LastColorMode = colorMode
            if colorMode == "Hold" then
                UITheme.SetOutlineColor(ProjHUD.Card, UITheme.Colors.Gold, 2.2)
                UITheme.SetTextColor(ProjHUD.TitleText, UITheme.Colors.Gold)
                UITheme.SetTextColor(ProjHUD.PctText, UITheme.Colors.Gold)
                UITheme.SetFill(ProjHUD.FillBorder, UITheme.Colors.Gold)
            elseif colorMode == "Prox" then
                UITheme.SetOutlineColor(ProjHUD.Card, UITheme.Colors.Cyan, 2.0)
                UITheme.SetTextColor(ProjHUD.TitleText, UITheme.Colors.Cyan)
                UITheme.SetTextColor(ProjHUD.PctText, UITheme.Colors.Cyan)
                UITheme.SetFill(ProjHUD.FillBorder, UITheme.Colors.Cyan)
            else
                UITheme.SetOutlineColor(ProjHUD.Card, UITheme.Colors.Magenta, 1.8)
                UITheme.SetTextColor(ProjHUD.TitleText, UITheme.Colors.Magenta)
                UITheme.SetTextColor(ProjHUD.PctText, UITheme.Colors.Gold)
                UITheme.SetFill(ProjHUD.FillBorder, UITheme.Colors.Magenta)
            end
        end

        local prompt
        if colorMode == "Hold" then
            prompt = "FAST REVIVING..."
        elseif colorMode == "Prox" then
            local rescuerUsesKB = (rescuerPid == 0 and InputRouting.OffsetGamepad == true)
            prompt = rescuerUsesKB
                and "HOLD [E / F] FAST REVIVE"
                or  "HOLD [X / A] FAST REVIVE"
        else
            local dist = ActiveState.DistMeters or 0.0
            prompt = isOnScreen
                and string.format("STEP IN RING (%.1fm)", dist)
                or  string.format("OFF-SCREEN (%.1fm)", dist)
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
    if InputRouting.IsGamePaused()
        or SessionManager.State.IsInCutscene
        or SessionManager.IsLevelEndActive()
        or (IsP2MenuOpenFn and IsP2MenuOpenFn()) then
        ReviveOverlay.HideHUDOnly()
        return
    end
    local now = os.clock()
    UpdateWorldRings(dt)
    UpdateProjectedHUD(now, dt)
end

return ReviveOverlay
