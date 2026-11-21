-- ============================================================================
-- SHARED / ARENA SCREEN PLAYER FLOOR CIRCLES (P1 = CYAN, P2 = PINK)
-- ============================================================================
-- Spawns compact, collision-free horizontal ground circles beneath Player 1
-- (Cyan) and Player 2 (Hot Pink) while in Shared/Arena Screen active combat.
-- Auto-hides in Split-Screen, Dive Bar, Cutscenes, Pause, Song Select/Menus,
-- and while a player is Downed (letting ReviveOverlay own the floor ring).
-- Uses flat World-Space UWidgetComponent with native counterRing_inner texture
-- for 100% exact color accuracy, with StaticMeshActor ring fallback.
-- ============================================================================

local UObjectUtils = require("Utils.UObjectUtils")
local Logger = require("Utils.Logger")
local SessionManager = require("Core.SessionManager")
local ViewportController = require("Camera.ViewportController")
local VanillaHUD = require("UI.VanillaHUD")
local UITheme = require("UI.UITheme")

local PlayerMarkers = {}

local Config = {}
local IsDownedFn = nil

local RING_MESH_PATH = "/Game/Pagoda/Common/FX_C/FX_C_Meshes/FX_Meshes/SM_FX_Ring_Top_01.SM_FX_Ring_Top_01"
local RING_MAT_PATH  = "/Game/Pagoda/Common/FX_C/Indicators/MI_Indicator_01.MI_Indicator_01"
local MAT_COLOR_PARAMS = { "Color", "Tint", "EmissiveColor", "BaseColor", "PrimaryColor" }

local DEFAULT_P1_COLOR = { R = 0.00, G = 0.94, B = 1.00, A = 0.92 } -- Cyan
local DEFAULT_P2_COLOR = { R = 1.00, G = 0.14, B = 0.62, A = 0.92 } -- Hot Pink

local Markers = {
    [0] = { Actor = nil, WidgetComp = nil, Widget = nil, WorldKey = nil, Visible = false, Yaw = 0.0, MeshRadius = 50.0, IsFallbackMesh = false },
    [1] = { Actor = nil, WidgetComp = nil, Widget = nil, WorldKey = nil, Visible = false, Yaw = 0.0, MeshRadius = 50.0, IsFallbackMesh = false },
}

local CachedMesh = nil
local CachedMat = nil
local CachedSMClass = nil
local CachedWCClass = nil

function PlayerMarkers.Init(config, callbacks)
    Config = config or {}
    if callbacks and type(callbacks.IsPlayerDowned) == "function" then
        IsDownedFn = callbacks.IsPlayerDowned
    end
end

local function LoadCached(path, cur)
    if cur ~= nil then
        return UObjectUtils.IsValid(cur) and cur or nil
    end
    local obj = UObjectUtils.LoadObject(path)
    return UObjectUtils.IsValid(obj) and obj or nil
end

local function DestroyMarker(pid)
    local m = Markers[pid]
    if not m then return end
    if UObjectUtils.IsLive(m.Actor) then
        SessionManager.DestroyActorSafely(m.Actor)
    end
    m.Actor = nil
    m.WidgetComp = nil
    m.Widget = nil
    m.WorldKey = nil
    m.Visible = false
    m.IsFallbackMesh = false
end

function PlayerMarkers.Destroy()
    DestroyMarker(0)
    DestroyMarker(1)
end

local function SetMarkerVisible(m, show)
    if not UObjectUtils.IsLive(m.Actor) then
        m.Visible = false
        return
    end
    if m.Visible == show then return end
    m.Visible = show
    pcall(function() m.Actor:SetActorHiddenInGame(not show) end)
    if UObjectUtils.IsValid(m.WidgetComp) then
        pcall(function() m.WidgetComp:SetVisibility(show, true) end)
    end
end

local function BuildRingUserWidget(world, ownerPC, color, sizePx)
    local cls = UITheme.GetUMGClasses()
    if not (cls and UObjectUtils.IsValid(cls.Overlay) and UObjectUtils.IsValid(cls.Image)) then return nil end
    local ringTex = UITheme.GetNativeTexture("CounterRing")
    if not UObjectUtils.IsValid(ringTex) then return nil end

    local builtWidget = nil
    pcall(function()
        local uw = cls.WBL:Create(world, cls.Widget, ownerPC)
        if not (UObjectUtils.IsValid(uw) and UObjectUtils.IsValid(uw.WidgetTree)) then return end
        local wt = uw.WidgetTree

        local box = StaticConstructObject(cls.SizeBox, wt)
        pcall(function()
            box:SetWidthOverride(sizePx)
            box:SetHeightOverride(sizePx)
        end)
        wt.RootWidget = box

        local ov = StaticConstructObject(cls.Overlay, wt)
        box:AddChild(ov)

        -- Subtle dark contrast halo so Cyan / Pink stays readable on bright arena floors
        local halo = StaticConstructObject(cls.Image, wt)
        pcall(function()
            halo:SetBrushFromTexture(ringTex, false)
            halo:SetColorAndOpacity({ R = 0.02, G = 0.01, B = 0.05, A = 0.68 })
        end)
        local hSlot = ov:AddChildToOverlay(halo)
        pcall(function()
            hSlot:SetHorizontalAlignment(0)
            hSlot:SetVerticalAlignment(0)
        end)

        -- Crisp primary colored circle (Cyan for P1, Pink for P2)
        local ring = StaticConstructObject(cls.Image, wt)
        pcall(function()
            ring:SetBrushFromTexture(ringTex, false)
            ring:SetColorAndOpacity(color)
        end)
        local rSlot = ov:AddChildToOverlay(ring)
        pcall(function()
            rSlot:SetHorizontalAlignment(0)
            rSlot:SetVerticalAlignment(0)
            rSlot:SetPadding({ Left = 10, Top = 10, Right = 10, Bottom = 10 })
        end)

        -- Soft inner glow ring
        local glow = StaticConstructObject(cls.Image, wt)
        pcall(function()
            glow:SetBrushFromTexture(ringTex, false)
            glow:SetColorAndOpacity({ R = color.R, G = color.G, B = color.B, A = 0.34 })
        end)
        local gSlot = ov:AddChildToOverlay(glow)
        pcall(function()
            gSlot:SetHorizontalAlignment(0)
            gSlot:SetVerticalAlignment(0)
            gSlot:SetPadding({ Left = 26, Top = 26, Right = 26, Bottom = 26 })
        end)

        builtWidget = uw
    end)
    return builtWidget
end

local function SpawnMarkerActor(pid, world, loc, color, sizeUU)
    local m = Markers[pid]
    DestroyMarker(pid)

    if not UObjectUtils.IsValid(CachedSMClass) then
        pcall(function() CachedSMClass = StaticFindObject("/Script/Engine.StaticMeshActor") end)
    end
    local smCls = CachedSMClass
    if not UObjectUtils.IsValid(smCls) then return false end

    local actor = world:SpawnActor(smCls, loc, { Pitch = 0.0, Yaw = 0.0, Roll = 0.0 })
    if not UObjectUtils.IsLive(actor) then return false end

    pcall(function() actor:SetActorEnableCollision(false) end)
    pcall(function() actor:SetActorTickEnabled(false) end)

    local smComp = nil
    pcall(function() smComp = actor.StaticMeshComponent end)
    if UObjectUtils.IsValid(smComp) then
        pcall(function() smComp:SetMobility(2) end) -- Movable root
        pcall(function() smComp:SetCollisionEnabled(0) end)
        pcall(function() smComp:SetCastShadow(false) end)
    end

    local p1Ctrl = SessionManager.GetP1()
    if not UObjectUtils.IsValid(CachedWCClass) then
        pcall(function() CachedWCClass = StaticFindObject("/Script/UMG.WidgetComponent") end)
    end
    local wcCls = CachedWCClass
    local drawPx = 256.0
    local scaleFactor = math.max(0.20, sizeUU / drawPx)

    if UObjectUtils.IsValid(wcCls) and UObjectUtils.IsValid(smComp) and p1Ctrl then
        local uw = BuildRingUserWidget(world, p1Ctrl, color, drawPx)
        if UObjectUtils.IsValid(uw) then
            local wComp = nil
            pcall(function()
                wComp = actor:AddComponentByClass(
                    wcCls,
                    false,
                    { Rotation = { X = 0.0, Y = 0.0, Z = 0.0, W = 1.0 }, Translation = { X = 0.0, Y = 0.0, Z = 0.0 }, Scale3D = { X = 1.0, Y = 1.0, Z = 1.0 } },
                    false
                )
            end)
            if UObjectUtils.IsValid(wComp) then
                pcall(function() wComp:SetMobility(2) end)
                pcall(function() wComp:K2_AttachToComponent(smComp, FName("None"), 2, 2, 2, false) end)
                pcall(function() wComp:SetCollisionEnabled(0) end)
                pcall(function() wComp:SetCastShadow(false) end)
                pcall(function() wComp:SetWidgetSpace(0) end)        -- EWidgetSpace::World
                pcall(function() wComp:SetTwoSided(true) end)
                pcall(function() wComp:SetBlendMode(2) end)          -- EWidgetBlendMode::Transparent
                pcall(function() wComp:SetDrawAtDesiredSize(false) end)
                pcall(function() wComp:SetDrawSize({ X = drawPx, Y = drawPx }) end)
                pcall(function() wComp:SetPivot({ X = 0.5, Y = 0.5 }) end)
                pcall(function() wComp:SetBackgroundColor({ R = 0.0, G = 0.0, B = 0.0, A = 0.0 }) end)
                pcall(function() wComp:K2_SetRelativeLocation({ X = 0.0, Y = 0.0, Z = 0.0 }, false, {}, false) end)
                pcall(function() wComp:K2_SetRelativeRotation({ Pitch = 90.0, Yaw = 0.0, Roll = 0.0 }, false, {}, false) end)
                pcall(function() wComp:SetWorldScale3D({ X = scaleFactor, Y = scaleFactor, Z = scaleFactor }) end)
                pcall(function() wComp:SetWidget(uw) end)
                pcall(function() wComp:SetVisibility(true, true) end)

                m.Actor = actor
                m.WidgetComp = wComp
                m.Widget = uw
                m.WorldKey = UObjectUtils.GetKey(world)
                m.Visible = true
                m.IsFallbackMesh = false
                Logger.Debug("PlayerMarkers", "Spawned P%d World Widget circle (size=%.0f UU).", pid + 1, sizeUU)
                return true
            end
        end
    end

    -- Fallback: Native FX Ring StaticMesh tinted Cyan / Pink
    if CachedMesh == nil then CachedMesh = LoadCached(RING_MESH_PATH, nil) or false end
    if CachedMat == nil then CachedMat = LoadCached(RING_MAT_PATH, nil) or false end
    if UObjectUtils.IsValid(smComp) and UObjectUtils.IsValid(CachedMesh) then
        pcall(function() smComp:SetStaticMesh(CachedMesh) end)
        pcall(function()
            local b = smComp:GetLocalBounds()
            if b and b.BoxExtent then
                local r = math.max(b.BoxExtent.X or 0.0, b.BoxExtent.Y or 0.0)
                if r > 5.0 then m.MeshRadius = r end
            end
        end)
        if UObjectUtils.IsValid(CachedMat) then
            local mid = nil
            pcall(function() mid = smComp:CreateDynamicMaterialInstance(0, CachedMat) end)
            if UObjectUtils.IsValid(mid) then
                for _, pname in ipairs(MAT_COLOR_PARAMS) do
                    pcall(function() mid:SetVectorParameterValue(FName(pname), color) end)
                end
            else
                pcall(function() smComp:SetMaterial(0, CachedMat) end)
            end
        end
        m.Actor = actor
        m.WorldKey = UObjectUtils.GetKey(world)
        m.Visible = true
        m.IsFallbackMesh = true
        Logger.Debug("PlayerMarkers", "Spawned P%d Fallback Mesh circle (size=%.0f UU).", pid + 1, sizeUU)
        return true
    end

    SessionManager.DestroyActorSafely(actor)
    return false
end

local function UpdateMarkerForPlayer(pid, world, wKey, pawn, color, sizeUU, dt)
    local m = Markers[pid]
    if not UObjectUtils.IsLive(pawn) or (IsDownedFn and IsDownedFn(pid)) then
        SetMarkerVisible(m, false)
        return
    end

    local loc = nil
    pcall(function() loc = pawn:K2_GetActorLocation() end)
    if not loc then
        SetMarkerVisible(m, false)
        return
    end

    local halfH = 88.0
    pcall(function()
        if UObjectUtils.IsValid(pawn.CapsuleComponent) then
            local ch = pawn.CapsuleComponent:GetScaledCapsuleHalfHeight()
            if type(ch) == "number" and ch > 15.0 then halfH = ch end
        end
    end)
    local floorLoc = { X = loc.X, Y = loc.Y, Z = loc.Z - halfH + 3.0 }

    if not UObjectUtils.IsLive(m.Actor) or m.WorldKey ~= wKey then
        if not SpawnMarkerActor(pid, world, floorLoc, color, sizeUU) then
            return
        end
    end

    SetMarkerVisible(m, true)

    local stepDt = (type(dt) == "number" and dt > 0.0) and math.min(0.10, dt) or 0.016
    m.Yaw = (m.Yaw + (pid == 0 and 20.0 or -20.0) * stepDt) % 360.0
    pcall(function()
        m.Actor:K2_SetActorLocationAndRotation(floorLoc, { Pitch = 0.0, Yaw = m.Yaw, Roll = 0.0 }, false, {}, false)
        if m.IsFallbackMesh then
            local s = (sizeUU * 0.5) / math.max(10.0, m.MeshRadius or 50.0)
            m.Actor:SetActorScale3D({ X = s, Y = s, Z = 1.0 })
        elseif UObjectUtils.IsValid(m.WidgetComp) then
            local sf = math.max(0.20, sizeUU / 256.0)
            m.WidgetComp:SetWorldScale3D({ X = sf, Y = sf, Z = sf })
        end
    end)
end

function PlayerMarkers.TickFrame(dt)
    local hudCfg = Config.HUD or {}
    if hudCfg.ShowSharedPlayerCircles == false or not ViewportController.IsArenaCameraActive() then
        if Markers[0].Actor or Markers[1].Actor then
            PlayerMarkers.Destroy()
        end
        return
    end

    if not VanillaHUD.IsInActiveMatch() then
        SetMarkerVisible(Markers[0], false)
        SetMarkerVisible(Markers[1], false)
        return
    end

    local inGameplay, world = UObjectUtils.IsGameplayWorld()
    if not (inGameplay and UObjectUtils.IsValid(world)) then
        PlayerMarkers.Destroy()
        return
    end

    local wKey = UObjectUtils.GetKey(world)
    local sizeUU = math.max(60.0, tonumber(hudCfg.SharedCircleSize) or 118.0)
    local p1Color = hudCfg.P1CircleColor or DEFAULT_P1_COLOR
    local p2Color = hudCfg.P2CircleColor or DEFAULT_P2_COLOR

    UpdateMarkerForPlayer(0, world, wKey, SessionManager.GetP1Pawn(), p1Color, sizeUU, dt)
    UpdateMarkerForPlayer(1, world, wKey, SessionManager.GetP2Pawn(), p2Color, sizeUU, dt)
end

return PlayerMarkers
