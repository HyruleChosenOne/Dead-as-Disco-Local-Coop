-- ============================================================================
-- VIEWPORT CONTROLLER, SPLIT-SCREEN, CUTSCENE COLLAPSE & SHARED MIDPOINT CAM
-- ============================================================================
-- * Non-destructive CommonUI PagodaUILayoutWidget scaling (never breaks
--   CommonUI ActionRouter pause/settings focus!).
-- * Excludes Settings, Remapping, Enemy Health Bars, Takedown Indicators,
--   Status Effects, and all mod-registered UI widgets.
-- * Suppresses ONLY P2's real Dive Bar currency widget (WBP_CreditsDisplay_C).
-- * Flicker-free mod-owned ACameraActor midpoint camera for Shared/Arena mode.
-- ============================================================================

local UObjectUtils = require("Utils.UObjectUtils")
local Logger = require("Utils.Logger")
local SessionManager = require("Core.SessionManager")

local ViewportController = {}

local Config = {}
local Callbacks = {}

ViewportController.CurrentScreenMode = 0      -- 0=Horizontal Split, 1=Vertical Split, 2=Arena Camera
ViewportController.LastSplitScreenMode = 0
ViewportController.InCutsceneFullscreen = false
ViewportController.InPauseFullscreen = false
ViewportController.SavedPreCutsceneMode = nil
ViewportController.RehostingGuard = false
ViewportController.DynamicSharedCameraEnabled = true
ViewportController.CustomFOVEnabled = false
ViewportController.CustomFOV = 90.0

local CutsceneIdleChecks = 0
local SavedOriginalUIScaleRule = nil
local LocalizedLayoutKeys = {}
local HiddenPauseP2Layouts = {}
local ModOwnedWidgets = {} -- [tag] = getterFn

local SharedCamActor = nil
local SharedCamWorldKey = nil
local SharedCamActive = false
local SharedCamLoc = nil
local SharedCamRot = nil
local SharedCamOrbitYaw = nil
local LastSetP1CtrlYaw = nil

local P1_DIVEBAR_MENU_CLASSES = {
    "WBP_Cosmetics_Main_C",
    "WBP_SkillTree_Main_C",
    "WBP_MoveList_Main_C",
    "WBP_Collectibles_Main_C",
    "WBP_Drumkit_Main_C",
}
local CachedWLL = nil
local CachedSBL = nil
local SavedStackSlotStates = {}
local SavedGlobalDiveBarMenus = {}

local EXCLUDED_GLOBAL_PATTERNS = {
    "CutsceneVideo", "LoadingScreen", "Splash", "Transition", "FadeToBlack",
    "Movie", "MainMenu", "PagodaSettings", "SettingsExtension", "AudioCalibration",
    "AudioOffsetCalibration", "ConfirmationDialog", "DisconnectedController",
    "Remap", "Keybind", "NPCIndicator", "ActorIndicator", "Takedown",
    "StatusEffect", "Tutorial_Note", "OnHealthBar", "BossHealth",
    "PauseMenu", "LevelEndScreen",
}

function ViewportController.Init(config, callbacks)
    Config = config or {}
    Callbacks = callbacks or {}
    local vpCfg = Config.Viewport or {}
    ViewportController.CurrentScreenMode = vpCfg.ScreenMode or 0
    if ViewportController.CurrentScreenMode == 0 or ViewportController.CurrentScreenMode == 1 then
        ViewportController.LastSplitScreenMode = ViewportController.CurrentScreenMode
    end
    ViewportController.DynamicSharedCameraEnabled = (vpCfg.EnableDynamicSharedCamera ~= false)
    ViewportController.CustomFOVEnabled = (vpCfg.CustomFOVEnabled == true)
    ViewportController.CustomFOV = tonumber(vpCfg.CustomFOV) or 90.0
end

function ViewportController.RegisterModWidget(tag, getterFn)
    if type(tag) == "string" and type(getterFn) == "function" then
        ModOwnedWidgets[tag] = getterFn
    end
end

function ViewportController.ClearLocalizedCache()
    LocalizedLayoutKeys = {}
end

function ViewportController.GetEffectiveScreenMode()
    if ViewportController.InCutsceneFullscreen then
        return 2
    end
    local m = ViewportController.CurrentScreenMode
    if m == 2 and UObjectUtils.IsInDiveBar(SessionManager.GetP1()) then
        return (ViewportController.LastSplitScreenMode == 1) and 1 or 0
    end
    return m
end

function ViewportController.IsArenaCameraActive()
    if not SessionManager.IsP2Active() then return false end
    if ViewportController.InCutsceneFullscreen or ViewportController.InPauseFullscreen then return false end
    return ViewportController.GetEffectiveScreenMode() == 2
end

function ViewportController.IsSplitScreenActive()
    if not SessionManager.IsP2Active() then return false end
    if ViewportController.InCutsceneFullscreen or ViewportController.InPauseFullscreen then return false end
    local eff = ViewportController.GetEffectiveScreenMode()
    return (eff == 0 or eff == 1)
end

function ViewportController.GetScreenModeLabel(mode)
    local m = (mode ~= nil) and mode or ViewportController.CurrentScreenMode
    if m == 0 then return "Horizontal Split"
    elseif m == 1 then return "Vertical Split"
    else return "Arena Camera" end
end

function ViewportController.GetScreenModeShortTag()
    if ViewportController.InCutsceneFullscreen then return "CUTSCENE" end
    local eff = ViewportController.GetEffectiveScreenMode()
    if eff == 0 then return "H-SPLIT"
    elseif eff == 1 then return "V-SPLIT"
    else return "ARENA" end
end

function ViewportController.ShouldKeepGlobal(widget)
    if not UObjectUtils.IsValid(widget) then return true end
    for _, getter in pairs(ModOwnedWidgets) do
        local mw = getter()
        if UObjectUtils.IsValid(mw) and UObjectUtils.Same(widget, mw) then
            return true
        end
    end
    local fn = ""
    pcall(function() fn = widget:GetFullName() end)
    for _, pat in ipairs(EXCLUDED_GLOBAL_PATTERNS) do
        if fn:find(pat, 1, true) then return true end
    end
    return false
end

function ViewportController.SyncUIScaleRule()
    local vpCfg = Config.Viewport or {}
    if vpCfg.UseScaleToFitInSplitScreen == false then return end
    pcall(function()
        local uiSettings = StaticFindObject("/Script/Engine.Default__UserInterfaceSettings")
        if not UObjectUtils.IsValid(uiSettings) then return end

        if SavedOriginalUIScaleRule == nil then
            local okCur, cur = pcall(function() return uiSettings.UIScaleRule end)
            SavedOriginalUIScaleRule = (okCur and type(cur) == "number") and cur or 0
        end

        if ViewportController.IsSplitScreenActive() then
            uiSettings.UIScaleRule = 4 -- ScaleToFit
        elseif SavedOriginalUIScaleRule ~= nil then
            uiSettings.UIScaleRule = SavedOriginalUIScaleRule
        end
    end)
end

local function ApplyRenderScale(subWidget, scale)
    if not UObjectUtils.IsLive(subWidget) then return end
    pcall(function()
        subWidget:SetRenderTransformPivot({ X = 0.5, Y = 0.5 })
        subWidget:SetRenderScale({ X = scale, Y = scale })
    end)
end

function ViewportController.SuppressP2DiveBarCredits()
    local hudCfg = Config.HUD or {}
    if hudCfg.HideP2DiveBarCredits == false then return end
    pcall(function()
        if not UObjectUtils.IsInDiveBar(SessionManager.GetP1()) then return end
        if not SessionManager.IsP2Active() then return end

        -- Real verified Dive Bar currency widget from Pagoda-Windows.utoc
        local credits = FindAllOf("WBP_CreditsDisplay_C")
        if credits then
            for _, w in pairs(credits) do
                if UObjectUtils.IsLive(w) then
                    local owner = nil
                    pcall(function() owner = w:GetOwningPlayer() end)
                    if SessionManager.GetPlayerIndex(owner) == 1 then
                        pcall(function() w:SetVisibility(1) end) -- Collapsed
                    end
                end
            end
        end

        local layouts = FindAllOf("PagodaUILayoutWidget")
        if layouts then
            for _, layout in pairs(layouts) do
                if UObjectUtils.IsLive(layout) then
                    local owner = nil
                    pcall(function() owner = layout:GetOwningPlayer() end)
                    if SessionManager.GetPlayerIndex(owner) == 1 then
                        local fn = ""
                        pcall(function() fn = layout:GetFullName() end)
                        if fn:find("HubArea", 1, true) then
                            if UObjectUtils.IsLive(layout.GameHUDStack) then
                                pcall(function() layout.GameHUDStack:SetVisibility(1) end)
                            end
                        end
                    end
                end
            end
        end
    end)
end

local function GetWidgetLayoutLibrary()
    if UObjectUtils.IsValid(CachedWLL) then return CachedWLL end
    pcall(function() CachedWLL = StaticFindObject("/Script/UMG.Default__WidgetLayoutLibrary") end)
    return UObjectUtils.IsValid(CachedWLL) and CachedWLL or nil
end

local function GetSlateBlueprintLibrary()
    if UObjectUtils.IsValid(CachedSBL) then return CachedSBL end
    pcall(function() CachedSBL = StaticFindObject("/Script/UMG.Default__SlateBlueprintLibrary") end)
    return UObjectUtils.IsValid(CachedSBL) and CachedSBL or nil
end

local function GetPlayer1SplitViewportMetrics(p1Ctrl)
    local wll = GetWidgetLayoutLibrary()
    local sbl = GetSlateBlueprintLibrary()
    local fullW, fullH, dpi = 1920.0, 1080.0, 1.0

    if UObjectUtils.IsValid(wll) then
        pcall(function()
            local s = wll:GetViewportScale(p1Ctrl)
            if type(s) == "number" and s > 0.05 then dpi = s end
        end)
        pcall(function()
            local rawSz = wll:GetViewportSize(p1Ctrl)
            if rawSz and type(rawSz.X) == "number" and type(rawSz.Y) == "number" and rawSz.X > 100.0 and rawSz.Y > 100.0 then
                fullW = rawSz.X / dpi
                fullH = rawSz.Y / dpi
            end
        end)
    end

    local effMode = ViewportController.GetEffectiveScreenMode()
    local vpW, vpH = fullW, fullH
    if effMode == 0 then
        vpH = fullH * 0.5
    elseif effMode == 1 then
        vpW = fullW * 0.5
    end

    if UObjectUtils.IsValid(wll) and UObjectUtils.IsValid(sbl) and UObjectUtils.IsLive(p1Ctrl) then
        pcall(function()
            local geo = wll:GetPlayerScreenWidgetGeometry(p1Ctrl)
            if geo then
                local localSz = sbl:GetLocalSize(geo)
                if localSz and type(localSz.X) == "number" and type(localSz.Y) == "number"
                    and localSz.X > 100.0 and localSz.Y > 100.0 then
                    local matchesSplit = (effMode == 0 and localSz.Y < (fullH * 0.85))
                        or (effMode == 1 and localSz.X < (fullW * 0.85))
                    if matchesSplit then
                        vpW, vpH = localSz.X, localSz.Y
                    end
                end
            end
        end)
    end

    local fitScale = math.max(0.35, math.min(1.0, math.min(vpW / math.max(1.0, fullW), vpH / math.max(1.0, fullH))))
    local virtualW = vpW / fitScale
    local virtualH = vpH / fitScale
    local padX = math.max(0.0, (virtualW - vpW) * 0.5)
    local padY = math.max(0.0, (virtualH - vpH) * 0.5)
    return vpW, vpH, fullW, fullH, fitScale, padX, padY, effMode
end

local function IsP1DiveBarMenuName(name)
    if type(name) ~= "string" or name == "" then return false end
    return name:find("Cosmetics", 1, true) ~= nil
        or name:find("SkillTree", 1, true) ~= nil
        or name:find("MoveList", 1, true) ~= nil
        or name:find("Collectibles", 1, true) ~= nil
        or name:find("Drumkit", 1, true) ~= nil
end

local function RestoreSavedStackSlot(key)
    local rec = SavedStackSlotStates[key]
    if not rec then return end
    SavedStackSlotStates[key] = nil
    pcall(function()
        if UObjectUtils.IsValid(rec.Slot) then
            if rec.Kind == "Canvas" then
                if rec.OrigAnchors then rec.Slot:SetAnchors(rec.OrigAnchors) end
                if rec.OrigOffsets then rec.Slot:SetOffsets(rec.OrigOffsets) end
            elseif rec.Kind == "Padding" and rec.OrigPadding then
                rec.Slot:SetPadding(rec.OrigPadding)
            end
        end
        if UObjectUtils.IsLive(rec.Widget) then
            ApplyRenderScale(rec.Widget, 1.0)
        end
    end)
end

local function RestoreAllSavedP1DiveBarMenus()
    local keys = {}
    for k in pairs(SavedStackSlotStates) do keys[#keys + 1] = k end
    for _, k in ipairs(keys) do
        RestoreSavedStackSlot(k)
    end
    for k, rec in pairs(SavedGlobalDiveBarMenus) do
        if rec and UObjectUtils.IsLive(rec.Widget) then
            pcall(function()
                rec.Widget:SetAnchorsInViewport({ Minimum = { X = 0.0, Y = 0.0 }, Maximum = { X = 1.0, Y = 1.0 } })
                ApplyRenderScale(rec.Widget, 1.0)
            end)
        end
        SavedGlobalDiveBarMenus[k] = nil
    end
end

function ViewportController.SyncP1DiveBarMenuAspect()
    local p1 = SessionManager.GetP1()
    local shouldLocalize = (p1 ~= nil)
        and UObjectUtils.IsInDiveBar(p1)
        and ViewportController.IsSplitScreenActive()
        and (not ViewportController.InPauseFullscreen)
        and (not ViewportController.InCutsceneFullscreen)

    if not shouldLocalize then
        RestoreAllSavedP1DiveBarMenus()
        return
    end

    local activeStacks = {}
    local activeGlobalWidgets = {}
    local anyMenuActive = false

    pcall(function()
        local layouts = FindAllOf("PagodaUILayoutWidget")
        if layouts then
            for _, layout in pairs(layouts) do
                if UObjectUtils.IsLive(layout) then
                    local own = nil
                    pcall(function() own = layout:GetOwningPlayer() end)
                    if SessionManager.GetPlayerIndex(own) == 0 and UObjectUtils.IsLive(layout.GameMenuStack) then
                        local actW = nil
                        pcall(function() actW = layout.GameMenuStack:GetActiveWidget() end)
                        if UObjectUtils.IsLive(actW) then
                            local wName = ""
                            pcall(function() wName = actW:GetFullName() end)
                            if IsP1DiveBarMenuName(wName) then
                                anyMenuActive = true
                                local sk = UObjectUtils.GetKey(layout.GameMenuStack)
                                if sk then
                                    activeStacks[sk] = { Layout = layout, Stack = layout.GameMenuStack, ActiveWidget = actW }
                                end
                            end
                        end
                    end
                end
            end
        end

        for _, clsName in ipairs(P1_DIVEBAR_MENU_CLASSES) do
            local list = FindAllOf(clsName)
            if list then
                for _, w in pairs(list) do
                    if UObjectUtils.IsLive(w) then
                        local own = nil
                        pcall(function() own = w:GetOwningPlayer() end)
                        local pid = SessionManager.GetPlayerIndex(own)
                        if pid == 0 or pid == nil then
                            local act, vis, inVP, visEnum = false, false, false, 0
                            pcall(function() act = (type(w.IsActivated) == "function" and w:IsActivated() == true) end)
                            pcall(function() vis = (type(w.IsVisible) == "function" and w:IsVisible() == true) end)
                            pcall(function() inVP = (type(w.IsInViewport) == "function" and w:IsInViewport() == true) end)
                            pcall(function()
                                local v = w:GetVisibility()
                                if type(v) == "number" then visEnum = v end
                            end)
                            if visEnum ~= 1 and visEnum ~= 2 and (act or (vis and inVP)) then
                                anyMenuActive = true
                                local parent = nil
                                pcall(function() parent = w:GetParent() end)
                                if not UObjectUtils.IsValid(parent) and inVP then
                                    local wk = UObjectUtils.GetKey(w)
                                    if wk then activeGlobalWidgets[wk] = w end
                                end
                            end
                        end
                    end
                end
            end
        end
    end)

    for k in pairs(SavedStackSlotStates) do
        if not activeStacks[k] then
            RestoreSavedStackSlot(k)
        end
    end
    for k, rec in pairs(SavedGlobalDiveBarMenus) do
        if not activeGlobalWidgets[k] then
            if rec and UObjectUtils.IsLive(rec.Widget) then
                pcall(function()
                    rec.Widget:SetAnchorsInViewport({ Minimum = { X = 0.0, Y = 0.0 }, Maximum = { X = 1.0, Y = 1.0 } })
                    ApplyRenderScale(rec.Widget, 1.0)
                end)
            end
            SavedGlobalDiveBarMenus[k] = nil
        end
    end

    if not anyMenuActive then return end

    local _, _, _, _, fitScale, padX, padY, effMode = GetPlayer1SplitViewportMetrics(p1)

    for sk, entry in pairs(activeStacks) do
        local layout, stack = entry.Layout, entry.Stack
        pcall(function()
            local slot = stack.Slot
            if UObjectUtils.IsValid(slot) then
                if not SavedStackSlotStates[sk] then
                    if type(slot.SetOffsets) == "function" then
                        local oa, oo = nil, nil
                        pcall(function()
                            local a = slot:GetAnchors()
                            if a and a.Minimum and a.Maximum then
                                oa = { Minimum = { X = a.Minimum.X, Y = a.Minimum.Y }, Maximum = { X = a.Maximum.X, Y = a.Maximum.Y } }
                            end
                            local o = slot:GetOffsets()
                            if o then
                                oo = { Left = o.Left, Top = o.Top, Right = o.Right, Bottom = o.Bottom }
                            end
                        end)
                        SavedStackSlotStates[sk] = { Widget = stack, Layout = layout, Slot = slot, Kind = "Canvas", OrigAnchors = oa, OrigOffsets = oo }
                    elseif type(slot.SetPadding) == "function" then
                        local op = nil
                        pcall(function()
                            local p = slot.Padding
                            if p then op = { Left = p.Left, Top = p.Top, Right = p.Right, Bottom = p.Bottom } end
                        end)
                        SavedStackSlotStates[sk] = { Widget = stack, Layout = layout, Slot = slot, Kind = "Padding", OrigPadding = op }
                    end
                end

                if type(slot.SetOffsets) == "function" then
                    slot:SetAnchors({ Minimum = { X = 0.0, Y = 0.0 }, Maximum = { X = 1.0, Y = 1.0 } })
                    slot:SetOffsets({ Left = -padX, Top = -padY, Right = -padX, Bottom = -padY })
                elseif type(slot.SetPadding) == "function" then
                    slot:SetPadding({ Left = -padX, Top = -padY, Right = -padX, Bottom = -padY })
                end
            end

            pcall(function() layout:SetClipping(0) end)
            pcall(function() stack:SetClipping(0) end)
            ApplyRenderScale(stack, fitScale)
        end)
    end

    for wk, w in pairs(activeGlobalWidgets) do
        pcall(function()
            if effMode == 0 then
                w:SetAnchorsInViewport({ Minimum = { X = 0.0, Y = 0.0 }, Maximum = { X = 1.0, Y = 0.5 } })
            elseif effMode == 1 then
                w:SetAnchorsInViewport({ Minimum = { X = 0.0, Y = 0.0 }, Maximum = { X = 0.5, Y = 1.0 } })
            end
            ApplyRenderScale(w, fitScale)
            SavedGlobalDiveBarMenus[wk] = { Widget = w, Applied = true }
        end)
    end

    -- Ensure Wardrobe / SkillTree 3D preview cameras don't letterbox inside P1's split aspect ratio
    pcall(function()
        local vt = p1:GetViewTarget()
        if UObjectUtils.IsLive(vt) and not UObjectUtils.Same(vt, SessionManager.GetP1Pawn()) then
            local camComp = vt.CameraComponent
            if UObjectUtils.IsValid(camComp) and camComp.bConstrainAspectRatio == true then
                camComp.bConstrainAspectRatio = false
            end
        end
    end)
end

function ViewportController.RefreshLayoutLocalization(layoutWidget)
    if not UObjectUtils.IsLive(layoutWidget) then return end

    pcall(function()
        local owner = layoutWidget:GetOwningPlayer()
        if not UObjectUtils.IsLive(owner) then return end
        local pid = SessionManager.GetPlayerIndex(owner)
        if pid == nil then return end

        local hudCfg = Config.HUD or {}
        local splitActive = ViewportController.IsSplitScreenActive()
        local hudScale, menuScale = 1.0, 1.0
        if splitActive then
            hudScale = (ViewportController.GetEffectiveScreenMode() == 0)
                and (hudCfg.HorizontalSplitScale or 1.0)
                or (hudCfg.VerticalSplitScale or 0.92)
            menuScale = hudCfg.SplitScreenMenuScale or 0.95
        end

        -- NEVER call RemoveFromParent() + AddToPlayerScreen() on PagodaUILayoutWidget
        -- (breaks CommonUI ActionRouter for Pause Menu / Settings!)
        if UObjectUtils.IsLive(layoutWidget.GameHUDStack) then
            ApplyRenderScale(layoutWidget.GameHUDStack, hudScale)
        end
        if UObjectUtils.IsLive(layoutWidget.GameMenuStack) then
            local sk = UObjectUtils.GetKey(layoutWidget.GameMenuStack)
            if not (sk and SavedStackSlotStates[sk]) then
                ApplyRenderScale(layoutWidget.GameMenuStack, menuScale)
            end
        end
        if UObjectUtils.IsLive(layoutWidget.SystemMenuStack) then
            ApplyRenderScale(layoutWidget.SystemMenuStack, menuScale)
        end

        if UObjectUtils.IsInDiveBar(SessionManager.GetP1()) then
            ViewportController.SuppressP2DiveBarCredits()
        end
    end)
    ViewportController.RehostingGuard = false
end

function ViewportController.LocalizeAllLayouts()
    pcall(function()
        ViewportController.SyncUIScaleRule()
        local layouts = FindAllOf("PagodaUILayoutWidget")
        if layouts then
            for _, layout in pairs(layouts) do
                if UObjectUtils.IsLive(layout) then
                    ViewportController.RefreshLayoutLocalization(layout)
                end
            end
        end
        ViewportController.SuppressP2DiveBarCredits()
        ViewportController.SyncP1DiveBarMenuAspect()
        if Callbacks.SyncHUD then
            UObjectUtils.SafeCall("Viewport.SyncHUD", Callbacks.SyncHUD)
        end
    end)
end

function ViewportController.ConfineRootHUDWidget(widget, zOrder)
    if ViewportController.RehostingGuard or not SessionManager.IsSafeForGameplayHooks() then return end
    if not UObjectUtils.IsLive(widget) or not ViewportController.IsSplitScreenActive() then return end
    if ViewportController.ShouldKeepGlobal(widget) then return end

    pcall(function()
        local key = UObjectUtils.GetKey(widget)
        if key and LocalizedLayoutKeys[key] then return end

        local owner = widget:GetOwningPlayer()
        if not UObjectUtils.IsLive(owner) then return end
        if SessionManager.GetPlayerIndex(owner) == nil then return end

        local okVP, inVP = pcall(function() return widget:IsInViewport() end)
        if not (okVP and inVP) then return end

        local fn = ""
        pcall(function() fn = widget:GetFullName() end)
        if fn:find("UI_Layout_", 1, true) or fn:find("PagodaUILayout", 1, true) then return end

        local isKnownRoot = fn:find("WBP_GameHUD", 1, true)
            or fn:find("WBP_HUDCanvas", 1, true)
            or fn:find("WBP_InfiniteDiscoHUD", 1, true)
            or fn:find("WBP_TowerHUD", 1, true)
        if not isKnownRoot then return end

        ViewportController.RehostingGuard = true
        local okRehost = pcall(function()
            widget:RemoveFromParent()
            widget:AddToPlayerScreen(zOrder or 0)
        end)
        ViewportController.RehostingGuard = false

        if okRehost then
            if key then LocalizedLayoutKeys[key] = true end
            local hudCfg = Config.HUD or {}
            local scale = (ViewportController.GetEffectiveScreenMode() == 0)
                and (hudCfg.HorizontalSplitScale or 1.0)
                or (hudCfg.VerticalSplitScale or 0.92)
            ApplyRenderScale(widget, scale)
        end
    end)
    ViewportController.RehostingGuard = false
end

-- ============================================================================
-- SCREEN MODE SWITCHING, CUTSCENES & PAUSE COLLAPSING
-- ============================================================================

function ViewportController.ApplyScreenMode(mode, silent)
    ViewportController.CurrentScreenMode = mode
    if not ViewportController.InCutsceneFullscreen and (mode == 0 or mode == 1) then
        ViewportController.LastSplitScreenMode = mode
    end
    ViewportController.ClearLocalizedCache()

    local effMode = ViewportController.GetEffectiveScreenMode()

    pcall(function()
        local mapsSettings = UObjectUtils.GetGameMapsSettings()
        local gs = UObjectUtils.GetGameplayStatics()
        local world = UObjectUtils.GetWorld()
        if not mapsSettings then return end

        if effMode == 0 or effMode == 1 then
            mapsSettings.bUseSplitscreen = true
            mapsSettings.TwoPlayerSplitscreenLayout = effMode
            if gs and world then pcall(function() gs:SetForceDisableSplitscreen(world, false) end) end
        else
            mapsSettings.bUseSplitscreen = false
            if gs and world then pcall(function() gs:SetForceDisableSplitscreen(world, true) end) end
        end

        ViewportController.LocalizeAllLayouts()
        ViewportController.ApplyCustomFOV()
        if effMode ~= 2 then
            ViewportController.ReleaseSharedMidpointCamera(0.10)
        end
    end)

    if Callbacks.OnScreenModeChanged then
        UObjectUtils.SafeCall("Viewport.OnScreenModeChanged", Callbacks.OnScreenModeChanged, effMode)
    end
    if not silent and Callbacks.Notify then
        Callbacks.Notify("Screen Mode: " .. ViewportController.GetScreenModeLabel(effMode), "Info")
    end
end

function ViewportController.EnforceDiveBarSplitScreen()
    if ViewportController.InCutsceneFullscreen or ViewportController.InPauseFullscreen then return end
    if not SessionManager.IsP2Active() or not UObjectUtils.IsInDiveBar(SessionManager.GetP1()) then return end

    pcall(function()
        local expected = (ViewportController.LastSplitScreenMode == 1) and 1 or 0
        if ViewportController.CurrentScreenMode == 0 or ViewportController.CurrentScreenMode == 1 then
            expected = ViewportController.CurrentScreenMode
        end
        local mapsSettings = UObjectUtils.GetGameMapsSettings()
        local needFix = (SharedCamActive == true)
        if mapsSettings then
            if mapsSettings.bUseSplitscreen ~= true or mapsSettings.TwoPlayerSplitscreenLayout ~= expected then
                needFix = true
            end
        end
        if needFix then
            ViewportController.ApplyScreenMode(ViewportController.CurrentScreenMode, true)
        end
    end)
end

function ViewportController.CycleScreenMode(allowArenaInDiveBarSetting)
    if not UObjectUtils.CanTrigger("CycleScreenMode", 0.25) then return end
    ViewportController.InCutsceneFullscreen = false
    ViewportController.SavedPreCutsceneMode = nil
    SessionManager.SetCutsceneState(false)

    if (not allowArenaInDiveBarSetting) and UObjectUtils.IsInDiveBar(SessionManager.GetP1()) then
        local nextSplit = (ViewportController.GetEffectiveScreenMode() == 0) and 1 or 0
        ViewportController.LastSplitScreenMode = nextSplit
        ViewportController.CurrentScreenMode = nextSplit
    else
        ViewportController.CurrentScreenMode = (ViewportController.CurrentScreenMode + 1) % 3
        if ViewportController.CurrentScreenMode == 0 or ViewportController.CurrentScreenMode == 1 then
            ViewportController.LastSplitScreenMode = ViewportController.CurrentScreenMode
        end
    end

    if Callbacks.SaveProfile then UObjectUtils.SafeCall("Viewport.Save", Callbacks.SaveProfile) end
    ViewportController.ApplyScreenMode(ViewportController.CurrentScreenMode, false)
end

function ViewportController.EnterCutsceneFullscreen(reason)
    local vpCfg = Config.Viewport or {}
    if vpCfg.AutoFullscreenOnCutscene == false then return end
    if not UObjectUtils.IsGameplayWorld() then return end

    SessionManager.RefreshControllers()
    if not SessionManager.IsP2Active() then return end
    if Callbacks.CloseP2MenuIfOpen then UObjectUtils.SafeCall("Cutscene.CloseMenu", Callbacks.CloseP2MenuIfOpen) end

    CutsceneIdleChecks = 0
    SessionManager.SetCutsceneState(true)
    if ViewportController.InCutsceneFullscreen then return end
    if ViewportController.GetEffectiveScreenMode() == 2 then
        if Callbacks.SyncHUD then UObjectUtils.SafeCall("Cutscene.SyncHUD", Callbacks.SyncHUD) end
        return
    end

    ViewportController.SavedPreCutsceneMode = ViewportController.CurrentScreenMode
    ViewportController.InCutsceneFullscreen = true
    ViewportController.ReleaseSharedMidpointCamera(0.05)
    Logger.Info("ViewportController", "Cutscene (%s) -> Fullscreen (saved mode=%d)",
        tostring(reason), ViewportController.SavedPreCutsceneMode)

    ViewportController.ApplyScreenMode(vpCfg.CutsceneViewportMode or 2, not vpCfg.ShowCutsceneSwitchNotification)
end

function ViewportController.ExitCutsceneFullscreen(reason)
    SessionManager.SetCutsceneState(false)
    if not ViewportController.InCutsceneFullscreen then
        if Callbacks.SyncHUD then UObjectUtils.SafeCall("CutsceneExit.SyncHUD", Callbacks.SyncHUD) end
        return
    end

    local restoreMode = ViewportController.SavedPreCutsceneMode
    ViewportController.InCutsceneFullscreen = false
    ViewportController.SavedPreCutsceneMode = nil
    CutsceneIdleChecks = 0

    Logger.Info("ViewportController", "Cutscene ended (%s) -> restoring mode %s", tostring(reason), tostring(restoreMode))
    SessionManager.RefreshControllers()
    local vpCfg = Config.Viewport or {}
    if restoreMode ~= nil and SessionManager.IsP2Active() then
        ViewportController.ApplyScreenMode(restoreMode, not vpCfg.ShowCutsceneSwitchNotification)
    elseif restoreMode ~= nil then
        ViewportController.CurrentScreenMode = restoreMode
        ViewportController.ApplyCustomFOV()
    end
end

local function SuppressP2LayoutsForPause(hide)
    pcall(function()
        if hide then
            local layouts = FindAllOf("PagodaUILayoutWidget")
            if not layouts then return end
            for _, lay in pairs(layouts) do
                if UObjectUtils.IsLive(lay) then
                    local own = nil
                    pcall(function() own = lay:GetOwningPlayer() end)
                    local pid = SessionManager.GetPlayerIndex(own)
                    if pid ~= nil and pid >= 1 then
                        local key = UObjectUtils.GetKey(lay)
                        if key and HiddenPauseP2Layouts[key] == nil then
                            local vis = 3
                            pcall(function()
                                local v = lay:GetVisibility()
                                if type(v) == "number" then vis = v end
                            end)
                            HiddenPauseP2Layouts[key] = { Widget = lay, OrigVis = vis }
                        end
                        pcall(function() lay:SetVisibility(1) end) -- Collapsed
                    end
                end
            end
        else
            for _, rec in pairs(HiddenPauseP2Layouts) do
                if rec and UObjectUtils.IsLive(rec.Widget) then
                    local targetVis = (type(rec.OrigVis) == "number" and rec.OrigVis ~= 1 and rec.OrigVis ~= 2)
                        and rec.OrigVis or 3
                    pcall(function() rec.Widget:SetVisibility(targetVis) end)
                end
            end
            HiddenPauseP2Layouts = {}
        end
    end)
end

ViewportController.SuppressP2LayoutsForPause = SuppressP2LayoutsForPause

function ViewportController.EnterPauseFullscreen()
    local vpCfg = Config.Viewport or {}
    if vpCfg.UniversalPauseFullscreen == false then return end
    if ViewportController.InCutsceneFullscreen or not SessionManager.IsP2Active() then return end
    if ViewportController.InPauseFullscreen then
        SuppressP2LayoutsForPause(true)
        return
    end

    ViewportController.InPauseFullscreen = true
    SuppressP2LayoutsForPause(true)

    if ViewportController.GetEffectiveScreenMode() == 2 then
        ViewportController.ReleaseSharedMidpointCamera(0.05)
        if Callbacks.SyncHUD then UObjectUtils.SafeCall("PauseEnter.SyncHUD", Callbacks.SyncHUD) end
        return
    end

    pcall(function()
        local mapsSettings = UObjectUtils.GetGameMapsSettings()
        local gs = UObjectUtils.GetGameplayStatics()
        local world = UObjectUtils.GetWorld()
        if mapsSettings then mapsSettings.bUseSplitscreen = false end
        if gs and world then pcall(function() gs:SetForceDisableSplitscreen(world, true) end) end
        ViewportController.SyncUIScaleRule()
        ViewportController.LocalizeAllLayouts()
        if Callbacks.SyncHUD then UObjectUtils.SafeCall("PauseEnter.SyncHUD", Callbacks.SyncHUD) end
    end)
end

function ViewportController.ExitPauseFullscreen()
    if not ViewportController.InPauseFullscreen then return end
    ViewportController.InPauseFullscreen = false
    SuppressP2LayoutsForPause(false)
    if SessionManager.IsP2Active() and not ViewportController.InCutsceneFullscreen then
        ViewportController.ApplyScreenMode(ViewportController.CurrentScreenMode, true)
    elseif Callbacks.SyncHUD then
        UObjectUtils.SafeCall("PauseExit.SyncHUD", Callbacks.SyncHUD)
    end
end

function ViewportController.ResetOnWorldRestart()
    ViewportController.ClearLocalizedCache()
    RestoreAllSavedP1DiveBarMenus()
    SavedStackSlotStates = {}
    SavedGlobalDiveBarMenus = {}
    HiddenPauseP2Layouts = {}
    SharedCamActor = nil
    SharedCamWorldKey = nil
    SharedCamActive = false
    SharedCamLoc = nil
    SharedCamRot = nil
    SharedCamOrbitYaw = nil
    LastSetP1CtrlYaw = nil
    ViewportController.InPauseFullscreen = false
    if ViewportController.InCutsceneFullscreen and ViewportController.SavedPreCutsceneMode ~= nil then
        ViewportController.CurrentScreenMode = ViewportController.SavedPreCutsceneMode
    end
    ViewportController.InCutsceneFullscreen = false
    ViewportController.SavedPreCutsceneMode = nil
    CutsceneIdleChecks = 0
    SessionManager.SetCutsceneState(false)
end

-- ============================================================================
-- CUSTOM CAMERA FOV & FLICKER-FREE SHARED MIDPOINT CAMERA
-- ============================================================================

function ViewportController.ApplyCustomFOV()
    if ViewportController.InCutsceneFullscreen then return end
    pcall(function()
        SessionManager.RefreshControllers()
        local targetFov = ViewportController.CustomFOVEnabled and (tonumber(ViewportController.CustomFOV) or 90.0) or 0.0
        for pid = 0, 1 do
            local pc = SessionManager.GetController(pid)
            if pc then pcall(function() pc:FOV(targetFov) end) end
        end
    end)
end

function ViewportController.ToggleCustomFOV()
    ViewportController.CustomFOVEnabled = not ViewportController.CustomFOVEnabled
    ViewportController.ApplyCustomFOV()
    if Callbacks.SaveProfile then UObjectUtils.SafeCall("Viewport.SaveFOV", Callbacks.SaveProfile) end
    if Callbacks.Notify then
        Callbacks.Notify(
            ViewportController.CustomFOVEnabled
                and string.format("Custom Camera FOV: %d deg", math.floor(ViewportController.CustomFOV + 0.5))
                or "Custom Camera FOV: OFF (Default)",
            "Info"
        )
    end
end

function ViewportController.AdjustCustomFOV(delta)
    local cur = tonumber(ViewportController.CustomFOV) or 90.0
    local nextVal = cur + (tonumber(delta) or 5.0)
    if nextVal > 120.0 then nextVal = 70.0 end
    if nextVal < 70.0 then nextVal = 120.0 end
    ViewportController.CustomFOV = nextVal
    ViewportController.CustomFOVEnabled = true
    ViewportController.ApplyCustomFOV()
    if Callbacks.SaveProfile then UObjectUtils.SafeCall("Viewport.SaveFOV", Callbacks.SaveProfile) end
    if Callbacks.Notify then
        Callbacks.Notify(string.format("Custom Camera FOV: %d deg", math.floor(ViewportController.CustomFOV + 0.5)), "Info")
    end
end

local function NormalizeAngleDeg(a)
    while a > 180.0 do a = a - 360.0 end
    while a < -180.0 do a = a + 360.0 end
    return a
end

function ViewportController.IsSharedMidpointCameraActor(actor)
    return UObjectUtils.IsLive(SharedCamActor) and UObjectUtils.IsLive(actor) and UObjectUtils.Same(SharedCamActor, actor)
end

function ViewportController.ReleaseSharedMidpointCamera(blendSec)
    if not SharedCamActive then return end
    SharedCamActive = false
    SharedCamOrbitYaw = nil
    LastSetP1CtrlYaw = nil
    pcall(function()
        local p1, p1Pawn = SessionManager.GetP1(), SessionManager.GetP1Pawn()
        if p1 and p1Pawn then
            local vt = nil
            pcall(function() vt = p1:GetViewTarget() end)
            if UObjectUtils.IsLive(SharedCamActor) and UObjectUtils.Same(vt, SharedCamActor) then
                p1:SetViewTargetWithBlend(p1Pawn, blendSec or 0.15, 0, 0.0, false)
            end
        end
    end)
end

function ViewportController.ToggleDynamicSharedCamera()
    ViewportController.DynamicSharedCameraEnabled = not ViewportController.DynamicSharedCameraEnabled
    if not ViewportController.DynamicSharedCameraEnabled then
        ViewportController.ReleaseSharedMidpointCamera(0.15)
    end
    if Callbacks.SaveProfile then UObjectUtils.SafeCall("Viewport.SaveDynCam", Callbacks.SaveProfile) end
end

function ViewportController.TickDynamicMidpointCamera(dt)
    local wantMidpoint = (ViewportController.DynamicSharedCameraEnabled == true)
        and ViewportController.IsArenaCameraActive()
        and SessionManager.IsSafeForGameplayHooks()

    if not wantMidpoint then
        if SharedCamActive then ViewportController.ReleaseSharedMidpointCamera(0.15) end
        return
    end

    local inGameplay, world = UObjectUtils.IsGameplayWorld()
    if not (inGameplay and UObjectUtils.IsValid(world)) then return end

    local p1 = SessionManager.GetP1()
    if not p1 or UObjectUtils.IsInDiveBar(p1) then
        if SharedCamActive then ViewportController.ReleaseSharedMidpointCamera(0.15) end
        return
    end
    local p1Pawn, p2Pawn = SessionManager.GetP1Pawn(), SessionManager.GetP2Pawn()
    if not (p1Pawn and p2Pawn) then return end

    pcall(function()
        local curVT = nil
        pcall(function() curVT = p1:GetViewTarget() end)
        if UObjectUtils.IsLive(curVT) and not UObjectUtils.Same(curVT, SharedCamActor) and not UObjectUtils.Same(curVT, p1Pawn) then
            local vtName = ""
            pcall(function() vtName = curVT:GetFullName() end)
            if vtName:find("CineCamera", 1, true) or vtName:find("Takedown", 1, true) or vtName:find("Finisher", 1, true) then
                SharedCamActive = false
                return
            end
        end

        local wKey = UObjectUtils.GetKey(world)
        if not UObjectUtils.IsLive(SharedCamActor) or SharedCamWorldKey ~= wKey then
            SharedCamActor = nil
            SharedCamActive = false
            SharedCamLoc = nil
            SharedCamRot = nil
            local camCls = StaticFindObject("/Script/Engine.CameraActor")
            if not UObjectUtils.IsValid(camCls) then return end
            local initLoc = p1Pawn:K2_GetActorLocation()
            local initRot = p1:GetControlRotation()
            local camMgr = p1.PlayerCameraManager
            if UObjectUtils.IsLive(camMgr) then
                pcall(function() initLoc = camMgr:GetCameraLocation() end)
                pcall(function() initRot = camMgr:GetCameraRotation() end)
            end
            SharedCamActor = world:SpawnActor(camCls, initLoc, initRot)
            if not UObjectUtils.IsLive(SharedCamActor) then return end
            SharedCamWorldKey = wKey
            SharedCamLoc = { X = initLoc.X, Y = initLoc.Y, Z = initLoc.Z }
            SharedCamRot = { Pitch = initRot.Pitch or -28.0, Yaw = initRot.Yaw or 0.0, Roll = 0.0 }
            pcall(function()
                if UObjectUtils.IsValid(SharedCamActor.CameraComponent) then
                    SharedCamActor.CameraComponent.bConstrainAspectRatio = false
                end
            end)
        end

        local l1 = p1Pawn:K2_GetActorLocation()
        local l2 = p2Pawn:K2_GetActorLocation()
        local midX = (l1.X + l2.X) * 0.5
        local midY = (l1.Y + l2.Y) * 0.5
        local midZ = (l1.Z + l2.Z) * 0.5 + 55.0

        local dxP, dyP = l1.X - l2.X, l1.Y - l2.Y
        local sep = math.sqrt(dxP * dxP + dyP * dyP)

        local vpCfg = Config.Viewport or {}
        local baseArm = vpCfg.SharedCameraBaseArm or 680.0
        local maxArm = vpCfg.SharedCameraMaxArm or 1380.0
        local targetArm = math.min(maxArm, math.max(baseArm, baseArm + sep * 0.72))

        local ctrlRot = p1:GetControlRotation()
        local curP1Yaw = (ctrlRot and ctrlRot.Yaw) or (SharedCamRot and SharedCamRot.Yaw) or 0.0
        local curP1Pitch = (ctrlRot and ctrlRot.Pitch) or 0.0
        if SharedCamOrbitYaw == nil or LastSetP1CtrlYaw == nil then
            SharedCamOrbitYaw = curP1Yaw
            LastSetP1CtrlYaw = curP1Yaw
        else
            local yawDelta = NormalizeAngleDeg(curP1Yaw - LastSetP1CtrlYaw)
            if math.abs(yawDelta) > 0.001 then
                SharedCamOrbitYaw = NormalizeAngleDeg(SharedCamOrbitYaw + yawDelta)
            end
        end

        local targetPitch = -26.0 - math.min(14.0, sep * 0.012)
        local d2r = math.pi / 180.0
        local cy, sy = math.cos(SharedCamOrbitYaw * d2r), math.sin(SharedCamOrbitYaw * d2r)
        local cp, sp = math.cos(targetPitch * d2r), math.sin(targetPitch * d2r)
        local fwdX, fwdY, fwdZ = cp * cy, cp * sy, sp

        local targetLocX = midX - fwdX * targetArm
        local targetLocY = midY - fwdY * targetArm
        local targetLocZ = midZ - fwdZ * targetArm

        local stepDt = (type(dt) == "number" and dt > 0.0) and math.min(0.10, dt) or 0.016
        local alpha = 1.0 - math.exp(-9.0 * stepDt)
        if not SharedCamLoc then
            SharedCamLoc = { X = targetLocX, Y = targetLocY, Z = targetLocZ }
            SharedCamRot = { Pitch = targetPitch, Yaw = SharedCamOrbitYaw, Roll = 0.0 }
        else
            SharedCamLoc.X = SharedCamLoc.X + (targetLocX - SharedCamLoc.X) * alpha
            SharedCamLoc.Y = SharedCamLoc.Y + (targetLocY - SharedCamLoc.Y) * alpha
            SharedCamLoc.Z = SharedCamLoc.Z + (targetLocZ - SharedCamLoc.Z) * alpha
        end

        local lx, ly, lz = midX - SharedCamLoc.X, midY - SharedCamLoc.Y, midZ - SharedCamLoc.Z
        local horiz = math.max(1.0, math.sqrt(lx * lx + ly * ly))
        local lookYaw = math.atan(ly, lx) * (180.0 / math.pi)
        local lookPitch = math.atan(lz, horiz) * (180.0 / math.pi)
        SharedCamRot.Pitch = lookPitch
        SharedCamRot.Yaw   = lookYaw
        SharedCamRot.Roll  = 0.0

        SharedCamActor:K2_SetActorLocationAndRotation(SharedCamLoc, SharedCamRot, false, {}, true)

        pcall(function() p1:SetControlRotation({ Pitch = curP1Pitch, Yaw = lookYaw, Roll = 0.0 }) end)
        LastSetP1CtrlYaw = lookYaw
        local p2 = SessionManager.GetP2()
        if p2 then
            pcall(function() p2:SetControlRotation({ Pitch = 0.0, Yaw = lookYaw, Roll = 0.0 }) end)
        end

        if UObjectUtils.IsValid(SharedCamActor.CameraComponent) then
            local fov = ViewportController.CustomFOVEnabled and (tonumber(ViewportController.CustomFOV) or 90.0) or 90.0
            pcall(function() SharedCamActor.CameraComponent.FieldOfView = fov end)
        end

        if not SharedCamActive or not UObjectUtils.Same(curVT, SharedCamActor) then
            p1:SetViewTargetWithBlend(SharedCamActor, 0.20, 0, 0.0, false)
            SharedCamActive = true
        end
    end)
end

function ViewportController.IsAnyCutsceneActive()
    local active = false
    pcall(function()
        local videos = FindAllOf("WBP_CutsceneVideoContainer_C")
        if videos then
            for _, v in pairs(videos) do
                if UObjectUtils.IsLive(v) then
                    local okV, vis = pcall(function() return v:IsVisible() end)
                    local okA, act = pcall(function() return v:IsActivated() end)
                    if (okV and vis) or (okA and act) then active = true; return end
                end
            end
        end

        local seqActors = FindAllOf("LevelSequenceActor")
        if seqActors then
            for _, sa in pairs(seqActors) do
                if UObjectUtils.IsLive(sa) then
                    local player = nil
                    pcall(function() player = sa:GetSequencePlayer() end)
                    if UObjectUtils.IsValid(player) then
                        local okP, playing = pcall(function() return player:IsPlaying() end)
                        if okP and playing then active = true; return end
                    end
                end
            end
        end

        local p1 = SessionManager.GetP1()
        if p1 then
            local vt = nil
            pcall(function() vt = p1:GetViewTarget() end)
            if UObjectUtils.IsLive(vt) then
                local vtName = ""
                pcall(function() vtName = vt:GetFullName() end)
                if vtName:find("CineCameraActor", 1, true)
                    and not vtName:find("ModelRenderer", 1, true)
                    and not vtName:find("ModelViewer", 1, true)
                    and not vtName:find("Takedown", 1, true) then
                    active = true; return
                end
            end
        end
    end)
    return active
end

function ViewportController.TickCutsceneWatchdog()
    if not ViewportController.InCutsceneFullscreen then return end
    if not UObjectUtils.IsGameplayWorld() or not SessionManager.IsP2Active() then
        ViewportController.ExitCutsceneFullscreen("WorldOrP2Changed")
    elseif not ViewportController.IsAnyCutsceneActive() then
        CutsceneIdleChecks = CutsceneIdleChecks + 1
        if CutsceneIdleChecks >= 2 then
            ViewportController.ExitCutsceneFullscreen("CutsceneFinished")
        end
    else
        CutsceneIdleChecks = 0
    end
end

return ViewportController
