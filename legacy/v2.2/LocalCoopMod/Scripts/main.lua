local UEHelpers = require("UEHelpers")
local Config = require("config")
local P2Menu = require("p2_menu")

print("[Dead as Disco - Local Co-op Mod] Initializing v2.1...\n")

local GetGameplayStatics = UEHelpers.GetGameplayStatics
local GetGameMapsSettings = UEHelpers.GetGameMapsSettings
local GetKismetSystemLibrary = UEHelpers.GetKismetSystemLibrary

-- ============================================================================
-- RUNTIME STATE
-- ============================================================================

local PlayerControllerTable = {}
local DestroyedObjectAddresses = {}
local LastActionTimes = {}

local CurrentScreenMode = Config.ScreenMode or 0
local CurrentOffsetGamepad = (Config.OffsetGamepad ~= false)
local AutoLeashActive = (Config.AutoLeashEnabled ~= false)

-- Customization runtime state
local CurrentP2Character = Config.Player2Character or "Charlie"
local CurrentTintMode = Config.TintMode or "AccentOnly"
local CurrentTintPaletteIdx = 1
local CurrentOutfitPresetIdx = Config.DefaultOutfitPresetIndex or 2
local CurrentLoadoutPresetIdx = Config.DefaultLoadoutPresetIndex or 1

-- Persistent per-slot customization state for Player 2
local P2CustomState = {
    Initialized = false,
    CustomPieceOverride = false,
    CosmeticSlots = {},     -- [1..5] = UPagodaPlayerCosmeticDefinition
    DanceSlots = {},        -- [0..3] = UPagodaPlayerCosmeticDefinition
    BossAbilitySlots = {},  -- [0..3] = UPagodaPlayerUpgradeDefinition
    ActiveUpgrades = {},    -- [tagStr] = UPagodaPlayerUpgradeDefinition
}

-- Cutscene viewport switching state
local InCutsceneFullscreen = false
local SavedPreCutsceneMode = nil
local CutsceneIdleChecks = 0

-- UI scaling state
local OriginalUIScaleRule = nil

-- Gamepad shortcut tracking
local LastGamepadChordTriggerTime = 0.0
local RecentKeyPressTimes = {}
local LastP2ControllerInputTime = 0.0

-- Hook & re-entrancy guards
local RegisteredHooks = {}
local RedirectingPauseMenu = false
local RehostingWidgetGuard = false
local SpawningPlayer2InProgress = false
local CharacterSwapInProgress = false

-- Cached catalogs for Player 2 customization & Custom UI Menu
local CachedCosmeticMap = nil
local CachedDanceMap = nil
local CachedUpgradeMap = nil
local CachedBossAbilityMap = nil
local OrderedCatalogs = {
    CosmeticsBySlot = nil,
    Dances = nil,
    BossAbilities = nil,
    UpgradesByIdol = nil,
}

-- ============================================================================
-- DEFENSIVE HELPERS & IDENTITY CHECKS
-- ============================================================================

local function IsValidObj(obj)
    if obj == nil or type(obj) ~= "userdata" then return false end
    local ok, valid = pcall(function() return obj:IsValid() end)
    return ok and valid == true
end

-- UE4SS wraps UObject* returns in fresh Lua userdata tables per call;
-- always compare underlying C++ pointer addresses rather than Lua `==`.
local function SameUObject(a, b)
    if a == nil or b == nil then return false end
    if not (IsValidObj(a) and IsValidObj(b)) then return false end
    local okA, addrA = pcall(function() return a:GetAddress() end)
    local okB, addrB = pcall(function() return b:GetAddress() end)
    if okA and okB and addrA ~= nil and addrB ~= nil then
        return addrA == addrB
    end
    local okFA, fnA = pcall(function() return a:GetFullName() end)
    local okFB, fnB = pcall(function() return b:GetFullName() end)
    return okFA and okFB and fnA ~= nil and fnA == fnB
end

local function MarkObjectDestroyed(obj)
    if not IsValidObj(obj) then return end
    pcall(function()
        local addr = obj:GetAddress()
        if addr ~= nil then
            DestroyedObjectAddresses[tostring(addr)] = true
        end
    end)
end

local function UnwrapParam(val)
    if val == nil or type(val) ~= "userdata" then return val end
    local okT, t = pcall(function() return val:type() end)
    if okT and (t == "RemoteUnrealParam" or t == "LocalUnrealParam") then
        local okG, inner = pcall(function() return val:get() end)
        if okG then return inner end
    end
    return val
end

local function ForEachArrayObj(arr, callback)
    if not arr then return end
    local usedForEach = false
    pcall(function()
        if type(arr.ForEach) == "function" then
            usedForEach = true
            arr:ForEach(function(idx, elem)
                local obj = UnwrapParam(elem)
                if IsValidObj(obj) then
                    callback(obj, idx)
                end
            end)
        end
    end)
    if not usedForEach then
        pcall(function()
            for i = 1, #arr do
                local obj = UnwrapParam(arr[i])
                if IsValidObj(obj) then
                    callback(obj, i)
                end
            end
        end)
    end
end

local function IsLiveWorldObject(obj)
    if not IsValidObj(obj) then return false end

    local okAddr, addr = pcall(function() return obj:GetAddress() end)
    if okAddr and addr ~= nil and DestroyedObjectAddresses[tostring(addr)] then
        return false
    end

    local ok, fullName = pcall(function() return obj:GetFullName() end)
    if not ok or not fullName then return false end
    if fullName:find("Default__", 1, true) then return false end

    -- Catch Actors torn down via RemovePlayer / K2_DestroyActor immediately on the same frame
    local okDest, beingDestroyed = pcall(function() return obj.bActorIsBeingDestroyed end)
    if okDest and beingDestroyed == true then
        return false
    end

    local okFlags, deadFlag = pcall(function()
        local flags = 0
        if EInternalObjectFlags then
            if EInternalObjectFlags.PendingKill then flags = flags | EInternalObjectFlags.PendingKill end
            if EInternalObjectFlags.Garbage then flags = flags | EInternalObjectFlags.Garbage end
            if EInternalObjectFlags.Unreachable then flags = flags | EInternalObjectFlags.Unreachable end
        end
        if flags ~= 0 then
            return obj:HasAnyInternalFlags(flags)
        end
        return false
    end)
    if okFlags and deadFlag then return false end

    return true
end

local function CanTriggerAction(actionKey, cooldownSec)
    local now = os.clock()
    local prev = LastActionTimes[actionKey]
    if prev and (now - prev) < (cooldownSec or 0.40) then
        return false
    end
    LastActionTimes[actionKey] = now
    return true
end

local function NormalizeId(str)
    if type(str) ~= "string" then return "" end
    return str:lower():gsub("[%s_%-%.%/]+", "")
end

local function MakeTagStruct(tagUserdata)
    if not tagUserdata then return nil end
    local ok, tagName = pcall(function() return tagUserdata.TagName end)
    if ok and tagName then
        return { TagName = tagName }
    end
    return nil
end

local function GetTagString(tagUserdata)
    if not tagUserdata then return "" end
    local ok, s = pcall(function() return tagUserdata.TagName:ToString() end)
    if ok and s then return s end
    return ""
end

local function GetSafeTextString(fTextProp, fallback)
    local out = nil
    pcall(function()
        if fTextProp then
            out = fTextProp:ToString()
        end
    end)
    if type(out) == "string" and out ~= "" then
        return out
    end
    return fallback or ""
end

local function ShowMessage(Message, Color)
    print(string.format("[Local Co-op] %s\n", Message))
    local function doPrint()
        pcall(function()
            local Kismet = GetKismetSystemLibrary()
            local World = UEHelpers.GetWorld()
            if IsValidObj(Kismet) and IsValidObj(World) then
                local TextColor = Color or { R = 0.2, G = 0.9, B = 1.0, A = 1.0 }
                Kismet:PrintString(
                    World,
                    "[Local Co-op] " .. Message,
                    true,
                    false,
                    TextColor,
                    Config.MessageDuration or 4.0,
                    FName("LocalCoopMsg")
                )
            end
        end)
    end
    local okGT, inGT = pcall(IsInGameThread)
    if okGT and inGT then
        doPrint()
    else
        ExecuteInGameThread(doPrint)
    end
end

local function GetObjectKey(obj)
    if not IsValidObj(obj) then return "invalid" end
    local ok, addr = pcall(function() return obj:GetAddress() end)
    if ok and addr ~= nil then return tostring(addr) end
    local okN, fn = pcall(function() return obj:GetFullName() end)
    if okN and fn then return fn end
    return tostring(obj)
end

local function TryRegisterNativeHook(funcPath, preCallback, postCallback)
    if RegisteredHooks[funcPath] then return true end
    local ok, registered = pcall(function()
        local fnObj = StaticFindObject(funcPath)
        if IsValidObj(fnObj) then
            if postCallback then
                RegisterHook(funcPath, preCallback or function() end, postCallback)
            else
                RegisterHook(funcPath, preCallback)
            end
            return true
        end
        return false
    end)
    if ok and registered then
        RegisteredHooks[funcPath] = true
        print(string.format("[Local Co-op] Hooked (native): %s\n", funcPath))
        return true
    end
    return false
end

local function TryRegisterScriptHook(funcPath, callback)
    if RegisteredHooks[funcPath] then return true end
    local ok, registered = pcall(function()
        local fnObj = StaticFindObject(funcPath)
        if IsValidObj(fnObj) then
            RegisterHook(funcPath, callback)
            return true
        end
        return false
    end)
    if ok and registered then
        RegisteredHooks[funcPath] = true
        print(string.format("[Local Co-op] Hooked (script): %s\n", funcPath))
        return true
    end
    return false
end

local function IsGameplayWorld()
    local World = nil
    pcall(function() World = UEHelpers.GetWorld() end)
    if not IsValidObj(World) then return false, nil end
    local ok, fullName = pcall(function() return World:GetFullName() end)
    if not ok or not fullName then return false, nil end
    if fullName:find("Level_MainMenu", 1, true)
        or fullName:find("L_Startup", 1, true)
        or fullName:find("Entry", 1, true)
        or fullName:find("Transition", 1, true) then
        return false, World
    end
    return true, World
end

-- ============================================================================
-- CONTROLLER DISCOVERY & STRICT SINGLETON PLAYER 2 ENFORCEMENT
-- ============================================================================

local function GetControllerPlayerId(pc)
    if not IsLiveWorldObject(pc) then return nil end
    local ok, id = pcall(function()
        local lp = pc.Player
        if IsLiveWorldObject(lp) then
            return lp.ControllerId
        end
        return nil
    end)
    if ok and type(id) == "number" and id >= 0 then
        return id
    end
    return nil
end

local function DestroyActorSafely(actor)
    if not IsValidObj(actor) then return end
    MarkObjectDestroyed(actor)
    pcall(function() actor:SetActorHiddenInGame(true) end)
    pcall(function() actor:SetActorEnableCollision(false) end)
    pcall(function() actor:K2_DestroyActor() end)
end

local function CachePlayerControllers()
    PlayerControllerTable = {}
    local _, currentWorld = IsGameplayWorld()
    local allControllers = FindAllOf("PlayerController")
    if not allControllers then return end

    for _, controller in pairs(allControllers) do
        if IsLiveWorldObject(controller) then
            local fullName = ""
            pcall(function() fullName = controller:GetFullName() end)
            if not fullName:find("DebugCameraController", 1, true)
                and not fullName:find("ReplayPlayerController", 1, true) then
                local okW, ctrlWorld = pcall(function() return controller:GetWorld() end)
                local inActiveWorld = (not IsValidObj(currentWorld)) or (okW and SameUObject(ctrlWorld, currentWorld))

                if inActiveWorld then
                    local id = GetControllerPlayerId(controller)
                    if id == 0 or id == 1 then
                        local slot = id + 1
                        local existing = PlayerControllerTable[slot]
                        if not existing then
                            PlayerControllerTable[slot] = controller
                        else
                            local newHasPawn = IsLiveWorldObject(controller.Pawn)
                            local oldHasPawn = IsLiveWorldObject(existing.Pawn)
                            if newHasPawn and not oldHasPawn then
                                PlayerControllerTable[slot] = controller
                            end
                        end
                    end
                end
            end
        end
    end
end

local function IsPlayer2Active()
    local p2 = PlayerControllerTable[2]
    return IsLiveWorldObject(p2) and GetControllerPlayerId(p2) == 1
end

-- Guarantees there is NEVER more than 1 Player 2 controller or 1 Player 2 character pawn,
-- and sweeps any unpossessed/unusable orphan PagodaPlayerCharacter clones from the world.
local function EnforceSinglePlayer2Instance()
    pcall(function()
        local inGameplay, currentWorld = IsGameplayWorld()
        if not inGameplay or not IsValidObj(currentWorld) then return end

        local gs = GetGameplayStatics()

        -- 1. Remove any accidental LocalPlayer with ControllerId >= 2
        local allControllers = FindAllOf("PlayerController")
        if allControllers then
            for _, ctrl in pairs(allControllers) do
                if IsLiveWorldObject(ctrl) then
                    local id = GetControllerPlayerId(ctrl)
                    if id ~= nil and id >= 2 then
                        if IsLiveWorldObject(ctrl.Pawn) then
                            DestroyActorSafely(ctrl.Pawn)
                        end
                        MarkObjectDestroyed(ctrl)
                        if IsValidObj(gs) then
                            pcall(function() gs:RemovePlayer(ctrl, true) end)
                        else
                            DestroyActorSafely(ctrl)
                        end
                    end
                end
            end
        end

        CachePlayerControllers()
        local p1 = PlayerControllerTable[1]
        local p2 = PlayerControllerTable[2]
        local p1Pawn = IsLiveWorldObject(p1) and p1.Pawn or nil
        local p2Pawn = IsLiveWorldObject(p2) and p2.Pawn or nil

        -- 2. Destroy any unpossessed / duplicate PagodaPlayerCharacter in the active gameplay world
        local chars = FindAllOf("PagodaPlayerCharacter")
        if chars then
            for _, ch in pairs(chars) do
                if IsLiveWorldObject(ch) then
                    local okW, chWorld = pcall(function() return ch:GetWorld() end)
                    if okW and SameUObject(chWorld, currentWorld) then
                        local chName = ""
                        pcall(function() chName = ch:GetFullName() end)
                        local isPreviewActor = chName:find("ModelRenderer", 1, true) or chName:find("ModelViewer", 1, true)

                        if not isPreviewActor
                            and not SameUObject(ch, p1Pawn)
                            and not SameUObject(ch, p2Pawn) then
                            local chCtrl = nil
                            pcall(function() chCtrl = ch.Controller end)
                            local ctrlId = GetControllerPlayerId(chCtrl)
                            if ctrlId ~= 0 and ctrlId ~= 1 then
                                print(string.format("[Local Co-op] Removing duplicate/orphan character: %s\n", chName))
                                DestroyActorSafely(ch)
                            end
                        end
                    end
                end
            end
        end
    end)
end

local function IsSplitScreenActive()
    if not IsPlayer2Active() then return false end
    if InCutsceneFullscreen then return false end
    return (CurrentScreenMode == 0 or CurrentScreenMode == 1)
end

local function SyncGamepadOffsetForPlayerCount(announce)
    pcall(function()
        local MapsSettings = GetGameMapsSettings()
        if not IsValidObj(MapsSettings) then return end

        local effectiveOffset = false
        if IsPlayer2Active() then
            effectiveOffset = CurrentOffsetGamepad
        end
        MapsSettings.bOffsetPlayerGamepadIds = effectiveOffset

        if announce then
            if CurrentOffsetGamepad then
                ShowMessage("Gamepad Setup: 1 Keyboard/Mouse (P1) + 1 Controller (P2)", { R = 0.3, G = 0.8, B = 1.0, A = 1.0 })
            else
                ShowMessage("Gamepad Setup: 2 Controllers (P1 = Controller 1, P2 = Controller 2)", { R = 0.3, G = 0.8, B = 1.0, A = 1.0 })
            end
        end
    end)
end

local function ClearNativeMultiplayerSavedFlagIfSolo()
    pcall(function()
        if not IsPlayer2Active() then
            local lms = FindFirstOf("PagodaLocalMultiplayerSubsystem")
            if IsValidObj(lms) and lms:GetIsActive() then
                lms:SetIsActive(false)
            end
        end
    end)
end

-- ============================================================================
-- MODULE 4: VIEWPORT UI LOCALIZATION & SPLIT-SCREEN SCALING
-- ============================================================================

local ExcludedGlobalWidgetPatterns = {
    "CutsceneVideo",
    "LoadingScreen",
    "Splash",
    "Transition",
    "FadeToBlack",
    "Movie",
    "MainMenu",
}

local function ShouldKeepWidgetGlobal(widget)
    if not IsValidObj(widget) then return true end
    local p2MenuW = P2Menu.GetMenuWidget()
    if IsValidObj(p2MenuW) and SameUObject(widget, p2MenuW) then
        return true
    end
    local fullName = ""
    pcall(function() fullName = widget:GetFullName() end)
    for _, pat in ipairs(ExcludedGlobalWidgetPatterns) do
        if fullName:find(pat, 1, true) then
            return true
        end
    end
    return false
end

local function SyncUIScaleRuleForViewportMode()
    if Config.LocalizePlayerViewports == false or Config.UseScaleToFitInSplitScreen == false then
        return
    end
    pcall(function()
        local uiSettings = StaticFindObject("/Script/Engine.Default__UserInterfaceSettings")
        if not IsValidObj(uiSettings) then return end

        if OriginalUIScaleRule == nil then
            OriginalUIScaleRule = uiSettings.UIScaleRule
        end

        if IsSplitScreenActive() then
            uiSettings.UIScaleRule = 4 -- EUIScalingRule::ScaleToFit
        elseif OriginalUIScaleRule ~= nil then
            uiSettings.UIScaleRule = OriginalUIScaleRule
        end
    end)
end

local function ApplySplitScaleToSubWidget(subWidget, scaleX, scaleY)
    if not IsValidObj(subWidget) then return end
    pcall(function()
        subWidget:SetRenderTransformPivot({ X = 0.5, Y = 0.5 })
        subWidget:SetRenderScale({ X = scaleX, Y = scaleY })
    end)
end

local function RefreshLayoutWidgetLocalization(layoutWidget)
    if Config.LocalizePlayerViewports == false then return end
    if not IsLiveWorldObject(layoutWidget) then return end

    pcall(function()
        local splitActive = IsSplitScreenActive()
        local hudScale = 1.0
        local menuScale = 1.0

        if splitActive then
            if CurrentScreenMode == 0 then
                hudScale = Config.HorizontalSplitHUDScale or 1.0
            elseif CurrentScreenMode == 1 then
                hudScale = Config.VerticalSplitHUDScale or 0.95
            end
            menuScale = Config.SplitScreenMenuScale or 0.95
        end

        local hudProps = { "HUDCanvas", "GameHUDStack", "GameOverlaysCanvas", "WBP_CombatBarks_Main", "WBP_CreditsDisplay" }
        for _, prop in ipairs(hudProps) do
            local ok, child = pcall(function() return layoutWidget[prop] end)
            if ok and IsValidObj(child) then
                ApplySplitScaleToSubWidget(child, hudScale, hudScale)
            end
        end

        local menuProps = { "GameMenuStack", "SystemMenuStack", "GamePopupStack", "SystemPopupStack" }
        for _, prop in ipairs(menuProps) do
            local ok, child = pcall(function() return layoutWidget[prop] end)
            if ok and IsValidObj(child) then
                ApplySplitScaleToSubWidget(child, menuScale, menuScale)
            end
        end
    end)
end

local function LocalizeAllPlayerUILayouts()
    if Config.LocalizePlayerViewports == false then return end
    SyncUIScaleRuleForViewportMode()

    pcall(function()
        local layouts = FindAllOf("PagodaUILayoutWidget")
        if not layouts then return end
        for _, layout in pairs(layouts) do
            if IsLiveWorldObject(layout) then
                local okVP, inVP = pcall(function() return layout:IsInViewport() end)
                if okVP and inVP then
                    RefreshLayoutWidgetLocalization(layout)
                end
            end
        end
    end)
end

local function ConfineWidgetToOwningPlayerScreen(widget, zOrder)
    if Config.LocalizePlayerViewports == false then return end
    if RehostingWidgetGuard then return end
    if not IsLiveWorldObject(widget) then return end
    if not IsSplitScreenActive() then return end
    if ShouldKeepWidgetGlobal(widget) then return end

    pcall(function()
        if widget:IsA(StaticFindObject("/Script/Pagoda.PagodaUILayoutWidget")) then
            RefreshLayoutWidgetLocalization(widget)
            return
        end

        local owningPC = widget:GetOwningPlayer()
        if not IsLiveWorldObject(owningPC) then return end

        local playerId = GetControllerPlayerId(owningPC)
        if playerId == nil then return end

        RehostingWidgetGuard = true
        local okScreen, added = pcall(function()
            widget:RemoveFromParent()
            return widget:AddToPlayerScreen(zOrder or 0)
        end)

        if not (okScreen and added) then
            local anchorsCfg = Config.ViewportAnchors or {}
            local modeCfg = (CurrentScreenMode == 1) and anchorsCfg.Vertical or anchorsCfg.Horizontal
            local bounds = (playerId == 0) and (modeCfg and modeCfg.Player1) or (modeCfg and modeCfg.Player2)
            if bounds then
                pcall(function()
                    widget:SetAnchorsInViewport({
                        Minimum = { X = bounds.MinX, Y = bounds.MinY },
                        Maximum = { X = bounds.MaxX, Y = bounds.MaxY },
                    })
                end)
            end
        end
        RehostingWidgetGuard = false
    end)
    RehostingWidgetGuard = false
end

-- ============================================================================
-- MODULE 2: SCREEN MODE & AUTOMATIC CUTSCENE VIEWPORT SWITCHING
-- ============================================================================

local function ApplyScreenModeInternal(mode, silent)
    pcall(function()
        local MapsSettings = GetGameMapsSettings()
        if not IsValidObj(MapsSettings) then return end

        if mode == 0 then
            MapsSettings.bUseSplitscreen = true
            MapsSettings.TwoPlayerSplitscreenLayout = 0
            if not silent then
                ShowMessage("Screen Mode: Split-Screen (Horizontal)", { R = 0.4, G = 1.0, B = 0.4, A = 1.0 })
            end
        elseif mode == 1 then
            MapsSettings.bUseSplitscreen = true
            MapsSettings.TwoPlayerSplitscreenLayout = 1
            if not silent then
                ShowMessage("Screen Mode: Split-Screen (Vertical)", { R = 0.4, G = 1.0, B = 0.4, A = 1.0 })
            end
        elseif mode == 2 then
            MapsSettings.bUseSplitscreen = false
            if not silent then
                ShowMessage("Screen Mode: Shared Single-Screen (Arena Camera)", { R = 1.0, G = 0.8, B = 0.2, A = 1.0 })
            end
        end
    end)
    LocalizeAllPlayerUILayouts()
end

local function ApplyScreenMode(mode)
    ApplyScreenModeInternal(mode, false)
end

local function EnterCutsceneFullscreen(reason)
    if Config.AutoFullscreenOnCutscene == false then return end
    local inGameplay = IsGameplayWorld()
    if not inGameplay then return end

    CachePlayerControllers()
    if not IsPlayer2Active() then return end

    if P2Menu.IsOpen() then
        P2Menu.Close()
    end

    CutsceneIdleChecks = 0
    if InCutsceneFullscreen then return end
    if CurrentScreenMode == 2 then return end

    SavedPreCutsceneMode = CurrentScreenMode
    InCutsceneFullscreen = true
    print(string.format("[Local Co-op] Cutscene started (%s) -> switching to Fullscreen (saving mode %d)\n", tostring(reason), SavedPreCutsceneMode))

    ApplyScreenModeInternal(Config.CutsceneViewportMode or 2, not Config.ShowCutsceneSwitchNotification)
end

local function ExitCutsceneFullscreen(reason)
    if not InCutsceneFullscreen then return end

    local modeToRestore = SavedPreCutsceneMode
    InCutsceneFullscreen = false
    SavedPreCutsceneMode = nil
    CutsceneIdleChecks = 0

    print(string.format("[Local Co-op] Cutscene ended (%s) -> restoring screen mode %s\n", tostring(reason), tostring(modeToRestore)))

    CachePlayerControllers()
    if modeToRestore ~= nil and IsPlayer2Active() then
        ApplyScreenModeInternal(modeToRestore, not Config.ShowCutsceneSwitchNotification)
    else
        ApplyScreenModeInternal(CurrentScreenMode, true)
    end
end

local function IsAnyCutsceneStillActive()
    local active = false
    pcall(function()
        local videos = FindAllOf("WBP_CutsceneVideoContainer_C")
        if videos then
            for _, v in pairs(videos) do
                if IsLiveWorldObject(v) then
                    local okVis, vis = pcall(function() return v:IsVisible() end)
                    local okAct, act = pcall(function() return v:IsActivated() end)
                    if (okVis and vis) or (okAct and act) then
                        active = true
                        return
                    end
                end
            end
        end

        local p1 = PlayerControllerTable[1]
        if IsLiveWorldObject(p1) then
            local okCin, bCin = pcall(function() return p1.bCinematicMode end)
            if okCin and bCin == true then
                active = true
                return
            end

            local okVT, vt = pcall(function() return p1:GetViewTarget() end)
            if okVT and IsLiveWorldObject(vt) then
                local vtName = vt:GetFullName()
                if vtName:find("CineCameraActor", 1, true)
                    and not vtName:find("Level_MainMenu", 1, true)
                    and not vtName:find("ModelRenderer", 1, true)
                    and not vtName:find("ModelViewer", 1, true) then
                    active = true
                    return
                end
            end
        end
    end)
    return active
end

-- ============================================================================
-- MODULE 1: FULL PLAYER 2 CUSTOMIZATION (MESHES, OUTFITS, DANCES, SKILLS)
-- ============================================================================

local ExcludedMaterialKeywords = {
    "eyes", "eyelash", "teeth", "tongue", "mouth", "clearcoatblack", "skull",
}

local ExcludedComponentKeywords = {
    "widget", "niagara", "trail", "afterimage", "dangerindicator", "interactionindicator",
}

local AccentVectorParams = {
    "Fresnel Color", "Inner Outline Color", "EmissionFresnelColor",
    "Emissive Tint", "Inner Color", "Outer Color", "EmissiveColor",
}

local SurfaceVectorParams = {
    "Color Tint", "Base Color", "Color01", "Color02",
    "Tint", "Color", "BaseColor", "BaseColorTint", "BodyColor",
}

local HairVectorParams = {
    "Hair Root", "Hair Tip",
}

local function ShouldSkipComponentForTint(comp)
    if not IsLiveWorldObject(comp) then return true end
    local okW, isWidgetComp = pcall(function()
        local wcClass = StaticFindObject("/Script/UMG.WidgetComponent")
        return IsValidObj(wcClass) and comp:IsA(wcClass)
    end)
    if okW and isWidgetComp then return true end

    local fullName = ""
    pcall(function() fullName = comp:GetFullName():lower() end)
    for _, kw in ipairs(ExcludedComponentKeywords) do
        if fullName:find(kw, 1, true) then
            return true
        end
    end
    if fullName:find("drumstick", 1, true) and Config.TintDrumsticks == false then
        return true
    end
    if fullName:find("hair", 1, true) and Config.TintHair == false then
        return true
    end
    return false
end

local function ShouldSkipMaterialSlot(mat)
    if not IsValidObj(mat) then return true end
    local matName = ""
    pcall(function() matName = mat:GetFullName():lower() end)
    for _, kw in ipairs(ExcludedMaterialKeywords) do
        if matName:find(kw, 1, true) then
            return true
        end
    end
    return false
end

local function CustomizePlayer2Visuals(P2Pawn)
    if not IsLiveWorldObject(P2Pawn) then return end

    pcall(function()
        local meshCompClass = StaticFindObject("/Script/Engine.MeshComponent")
        local midClass = StaticFindObject("/Script/Engine.MaterialInstanceDynamic")
        if not IsValidObj(meshCompClass) then return end

        local components = P2Pawn:K2_GetComponentsByClass(meshCompClass)
        if not components then return end

        local tintColor = Config.Player2TintColor or { R = 0.0, G = 1.0, B = 0.9, A = 1.0 }
        local surfaceColor = {
            R = 0.35 + (tintColor.R or 0.0) * 0.65,
            G = 0.35 + (tintColor.G or 1.0) * 0.65,
            B = 0.35 + (tintColor.B or 0.9) * 0.65,
            A = tintColor.A or 1.0,
        }

        local applyDepth = (Config.EnablePlayer2CustomDepth ~= false)
        local stencilVal = Config.Player2StencilValue or 250
        local applyTint = (Config.EnablePlayer2VisualTint ~= false) and (CurrentTintMode ~= "Off")
        local fullBody = (CurrentTintMode == "FullBody")

        ForEachArrayObj(components, function(meshComp)
            if not ShouldSkipComponentForTint(meshComp) then
                pcall(function()
                    meshComp.bRenderCustomDepth = applyDepth
                    if applyDepth then
                        meshComp.CustomDepthStencilValue = stencilVal
                    end
                end)

                if applyTint then
                    local numMats = 0
                    pcall(function() numMats = meshComp:GetNumMaterials() end)

                    for slotIdx = 0, numMats - 1 do
                        pcall(function()
                            local mat = meshComp:GetMaterial(slotIdx)
                            if IsValidObj(mat) and not ShouldSkipMaterialSlot(mat) then
                                local mid = mat
                                if not (IsValidObj(midClass) and mat:IsA(midClass)) then
                                    mid = meshComp:CreateDynamicMaterialInstance(slotIdx, mat, FName("None"))
                                end

                                if IsValidObj(mid) then
                                    for _, pName in ipairs(AccentVectorParams) do
                                        mid:SetVectorParameterValue(FName(pName), tintColor)
                                    end
                                    if fullBody then
                                        for _, pName in ipairs(SurfaceVectorParams) do
                                            mid:SetVectorParameterValue(FName(pName), surfaceColor)
                                        end
                                        if Config.TintHair ~= false then
                                            for _, pName in ipairs(HairVectorParams) do
                                                mid:SetVectorParameterValue(FName(pName), tintColor)
                                            end
                                        end
                                    end
                                end
                            end
                        end)
                    end
                end
            end
        end)
    end)
end

local function BuildCustomizationCatalogs()
    -- 1. Cosmetics & Dances Catalog
    if not CachedCosmeticMap or not CachedDanceMap or not OrderedCatalogs.CosmeticsBySlot then
        local cat = FindFirstOf("PagodaPlayerCosmeticCatalogSubsystem")
        if IsValidObj(cat) then
            pcall(function()
                local arr = cat.SortedCosmetics
                if not arr or #arr == 0 then return end
                CachedCosmeticMap = { [1] = {}, [2] = {}, [3] = {}, [4] = {}, [5] = {} }
                CachedDanceMap = {}
                OrderedCatalogs.CosmeticsBySlot = { [1] = {}, [2] = {}, [3] = {}, [4] = {}, [5] = {} }
                OrderedCatalogs.Dances = {}

                ForEachArrayObj(arr, function(def)
                    local slot = def.CosmeticSlot
                    local tagStr = GetTagString(def.CosmeticIdTag)
                    local objName = def:GetFName():ToString()
                    local shortTag = tagStr:match("([^%.]+)$") or ""
                    local shortAsset = objName:gsub("^PlayerCosmetic_Charlie_[A-Za-z]+_", ""):gsub("^PlayerCosmetic_Dance_", "")
                    local dispName = GetSafeTextString(def.DisplayName, shortAsset ~= "" and shortAsset or objName)
                    local descStr = GetSafeTextString(def.Description, "")

                    if slot == 6 then
                        for _, key in ipairs({ tagStr, shortTag, objName, shortAsset, dispName }) do
                            local nk = NormalizeId(key)
                            if nk ~= "" then CachedDanceMap[nk] = def end
                        end
                        table.insert(OrderedCatalogs.Dances, {
                            Name = dispName,
                            ShortId = shortAsset,
                            Description = descStr,
                            Def = def,
                        })
                    elseif CachedCosmeticMap[slot] then
                        for _, key in ipairs({ tagStr, shortTag, objName, shortAsset, dispName }) do
                            local nk = NormalizeId(key)
                            if nk ~= "" then CachedCosmeticMap[slot][nk] = def end
                        end
                        local nkShort = NormalizeId(shortAsset)
                        if nkShort:find("doll") then
                            local aroraKey = nkShort:gsub("doll", "arora")
                            CachedCosmeticMap[slot][aroraKey] = def
                        elseif nkShort:find("arora") then
                            local dollKey = nkShort:gsub("arora", "doll")
                            CachedCosmeticMap[slot][dollKey] = def
                        end
                        if nkShort:find("beach") then
                            local summerKey = nkShort:gsub("beach_?", "")
                            CachedCosmeticMap[slot][summerKey] = def
                        end
                        if nkShort:find("summer") then
                            local beachKey = "beach" .. nkShort:gsub("^beach", "")
                            CachedCosmeticMap[slot][beachKey] = def
                        end
                        if nkShort:find("summerheadset") then
                            CachedCosmeticMap[slot]["summerheadset"] = def
                            CachedCosmeticMap[slot]["beachsummerheadset"] = def
                        end
                        if nkShort:find("summerhat") then
                            CachedCosmeticMap[slot]["summerhat"] = def
                            CachedCosmeticMap[slot]["beachsummerhat"] = def
                        end
                        if nkShort:find("pumpkinhead") then
                            CachedCosmeticMap[slot]["pumpkinhead"] = def
                            CachedCosmeticMap[slot]["halloweenpumpkinhead"] = def
                        end
                        if shortAsset == "Female" then CachedCosmeticMap[slot]["slim"] = def end
                        if shortAsset == "Doll" and slot == 3 then CachedCosmeticMap[slot]["arora"] = def end

                        table.insert(OrderedCatalogs.CosmeticsBySlot[slot], {
                            Name = dispName,
                            ShortId = shortAsset,
                            Description = descStr,
                            Def = def,
                        })
                    end
                end)
            end)
        end
    end

    -- 2. Upgrades & Boss Abilities Catalog
    if not CachedUpgradeMap or not CachedBossAbilityMap or not OrderedCatalogs.UpgradesByIdol then
        local ucat = FindFirstOf("PagodaPlayerUpgradeCatalogSubsystem")
        if IsValidObj(ucat) then
            pcall(function()
                local arr = ucat.SortedUpgrades
                if not arr or #arr == 0 then return end
                CachedUpgradeMap = {}
                CachedBossAbilityMap = {}
                OrderedCatalogs.BossAbilities = {}
                OrderedCatalogs.UpgradesByIdol = {
                    Charlie = {}, Shred = {}, Rebel = {}, Dancer = {}, Prophet = {}, Doll = {}, All = {},
                }

                local bossAddrSet = {}
                local barr = ucat.BossAbilityUpgrades
                if barr then
                    ForEachArrayObj(barr, function(def)
                        local objName = def:GetFName():ToString()
                        local fullPath = def:GetFullName()
                        local shortNoPrefix = objName:gsub("^PlayerUpgrade_[A-Za-z]+_", "")
                        local tagStr = GetTagString(def.UpgradeIdTag)
                        local dispName = GetSafeTextString(def.DisplayName, shortNoPrefix)
                        local descStr = GetSafeTextString(def.Description, "")

                        local idol = "Charlie"
                        for _, candidate in ipairs({ "Shred", "Rebel", "Dancer", "Prophet", "Doll", "Charlie" }) do
                            if fullPath:find("/Upgrades/" .. candidate .. "/", 1, true)
                                or objName:find("_" .. candidate .. "_", 1, true) then
                                idol = candidate
                                break
                            end
                        end

                        pcall(function() bossAddrSet[tostring(def:GetAddress())] = true end)
                        for _, key in ipairs({ tagStr, objName, shortNoPrefix, dispName }) do
                            local nk = NormalizeId(key)
                            if nk ~= "" then CachedBossAbilityMap[nk] = def end
                        end

                        table.insert(OrderedCatalogs.BossAbilities, {
                            Name = dispName,
                            ShortId = shortNoPrefix,
                            Idol = idol,
                            Description = descStr,
                            Def = def,
                        })
                    end)
                end

                ForEachArrayObj(arr, function(def)
                    local tagStr = GetTagString(def.UpgradeIdTag)
                    local objName = def:GetFName():ToString()
                    local fullPath = def:GetFullName()
                    local shortNoPrefix = objName:gsub("^PlayerUpgrade_[A-Za-z]+_", "")
                    local shortWithIdol = objName:gsub("^PlayerUpgrade_", "")
                    local shortTag = tagStr:match("([^%.]+)$") or ""
                    local dispName = GetSafeTextString(def.DisplayName, shortNoPrefix)
                    local descStr = GetSafeTextString(def.Description, "")

                    for _, key in ipairs({ tagStr, shortTag, objName, shortWithIdol, shortNoPrefix, dispName }) do
                        local nk = NormalizeId(key)
                        if nk ~= "" then CachedUpgradeMap[nk] = def end
                    end

                    -- Group non-boss-slot upgrades into Idol skill trees for Tab 4
                    local isBoss = false
                    pcall(function() isBoss = (bossAddrSet[tostring(def:GetAddress())] == true) end)
                    if not isBoss then
                        local idol = "Charlie"
                        for _, candidate in ipairs({ "Shred", "Rebel", "Dancer", "Prophet", "Doll", "Charlie" }) do
                            if fullPath:find("/Upgrades/" .. candidate .. "/", 1, true)
                                or objName:find("_" .. candidate .. "_", 1, true) then
                                idol = candidate
                                break
                            end
                        end

                        local entry = {
                            Name = dispName,
                            Idol = idol,
                            Description = descStr,
                            Def = def,
                        }
                        if OrderedCatalogs.UpgradesByIdol[idol] then
                            table.insert(OrderedCatalogs.UpgradesByIdol[idol], entry)
                        end
                        table.insert(OrderedCatalogs.UpgradesByIdol.All, entry)
                    end
                end)
            end)
        end
    end
end

local SavedPlayer1Dances = nil
local SavedPlayer1BossSlots = nil

local function ResolvePlaythroughData(p1Controller, p2Controller)
    if IsLiveWorldObject(p2Controller) then
        local ok2, d2 = pcall(function() return p2Controller:GetPlaythroughPlayerData() end)
        if ok2 and IsValidObj(d2) then
            return d2, false
        end
    end
    if IsLiveWorldObject(p1Controller) then
        local ok1, d1 = pcall(function() return p1Controller:GetPlaythroughPlayerData() end)
        if ok1 and IsValidObj(d1) then
            return d1, true
        end
    end
    local ppd = FindFirstOf("PagodaPlaythroughPlayerData")
    if IsValidObj(ppd) then
        return ppd, true
    end
    return nil, false
end

local function SnapshotPlayer1Cosmetics(p1Controller)
    local saved = { slots = {}, dances = {} }
    pcall(function()
        if not (IsLiveWorldObject(p1Controller) and IsLiveWorldObject(p1Controller.Pawn)) then return end
        local p1Cos = p1Controller.Pawn.CosmeticComponent
        if not IsValidObj(p1Cos) then return end

        for s = 1, 5 do
            local okC, def = pcall(function() return p1Cos:GetEquippedAssetAtSlot(s) end)
            if okC and IsValidObj(def) then
                saved.slots[s] = def
            end
        end

        for d = 0, 3 do
            local okD, dDef = pcall(function() return p1Cos:GetDanceMoveAtSlot(d) end)
            if okD and IsValidObj(dDef) then
                saved.dances[d] = dDef
            end
        end
    end)
    return saved
end

local function RestorePlayer1DataIfDisconnected(p1Controller)
    pcall(function()
        if not SavedPlayer1Dances then return end
        local ppd = ResolvePlaythroughData(p1Controller, nil)
        if not IsValidObj(ppd) then return end
        for slotIdx, dDef in pairs(SavedPlayer1Dances or {}) do
            if IsValidObj(dDef) then
                local tagStruct = MakeTagStruct(dDef.CosmeticIdTag)
                if tagStruct then
                    pcall(function() ppd:EquipDanceMoveToSlot(tagStruct, slotIdx) end)
                end
            end
        end
        SavedPlayer1Dances = nil

        if SavedPlayer1BossSlots and IsLiveWorldObject(p1Controller) then
            local p1Upg = nil
            pcall(function() p1Upg = p1Controller:GetPlayerUpgradeComponent() end)
            if not IsValidObj(p1Upg) and IsLiveWorldObject(p1Controller.Pawn) then
                p1Upg = p1Controller.Pawn.PlayerUpgrades
            end
            if IsValidObj(p1Upg) then
                for slotIdx, bDef in pairs(SavedPlayer1BossSlots) do
                    if IsValidObj(bDef) then
                        pcall(function() p1Upg:EquipOrSwapBossAbilityAtSlot(bDef, slotIdx) end)
                    end
                end
            end
            SavedPlayer1BossSlots = nil
        end
    end)
end

local function WithTemporaryCosmeticAccess(defs, actionFn)
    if Config.UnlockAllCosmeticsForPlayer2 == false then
        actionFn()
        return
    end

    local saved = {}
    for _, def in ipairs(defs or {}) do
        if IsValidObj(def) then
            local entry = { def = def, hasAllow = false }
            pcall(function()
                local origU = def.UnlockDefinition
                if IsValidObj(origU) then
                    entry.origUnlock = origU
                    def.UnlockDefinition = CreateInvalidObject()
                end
            end)
            pcall(function()
                local origA = def.bAllowIfProgressionDisabled
                if type(origA) == "boolean" then
                    entry.hasAllow = true
                    entry.origAllow = origA
                    def.bAllowIfProgressionDisabled = true
                end
            end)
            table.insert(saved, entry)
        end
    end

    pcall(actionFn)

    for _, entry in ipairs(saved) do
        if IsValidObj(entry.def) then
            if entry.origUnlock and IsValidObj(entry.origUnlock) then
                pcall(function() entry.def.UnlockDefinition = entry.origUnlock end)
            end
            if entry.hasAllow then
                pcall(function() entry.def.bAllowIfProgressionDisabled = entry.origAllow end)
            end
        end
    end
end

local function FindPrimaryCosmeticSubsystem()
    local best = nil
    pcall(function()
        local subs = FindAllOf("PagodaCosmeticLocalPlayerSubsystem")
        if subs then
            for _, s in pairs(subs) do
                if IsValidObj(s) then
                    if not best then best = s end
                    local okP, d = pcall(function() return s:GetPlaythroughData() end)
                    if okP and IsValidObj(d) then
                        best = s
                        break
                    end
                end
            end
        end
    end)
    return best
end

-- Seed P2CustomState from Preset tables once, then preserve custom per-slot choices
local function LoadOutfitPresetIntoState(presetIdx)
    BuildCustomizationCatalogs()
    if not CachedCosmeticMap then return nil end

    local preset = nil
    if Config.Player2CustomOutfit and Config.Player2CustomOutfit.Enabled then
        preset = Config.Player2CustomOutfit
    elseif Config.OutfitPresets and #Config.OutfitPresets > 0 then
        local idx = ((presetIdx - 1) % #Config.OutfitPresets) + 1
        CurrentOutfitPresetIdx = idx
        preset = Config.OutfitPresets[idx]
    end
    if not preset then return nil end

    local spec = {
        [1] = preset.BodyType or "Default",
        [2] = preset.Jacket or "Default",
        [3] = preset.Glasses or "Default",
        [4] = preset.Drumsticks or "Default",
        [5] = preset.Hair or "Default",
    }
    for slot = 1, 5 do
        local key = NormalizeId(spec[slot])
        local def = CachedCosmeticMap[slot] and CachedCosmeticMap[slot][key]
        if not IsValidObj(def) and CachedCosmeticMap[slot] then
            def = CachedCosmeticMap[slot]["default"]
        end
        if IsValidObj(def) then
            P2CustomState.CosmeticSlots[slot] = def
        end
    end
    P2CustomState.CustomPieceOverride = false
    return preset.Name or "Custom Outfit"
end

local function LoadLoadoutPresetIntoState(presetIdx, p1Controller)
    BuildCustomizationCatalogs()
    local loadout = nil
    if Config.LoadoutPresets and #Config.LoadoutPresets > 0 then
        local idx = ((presetIdx - 1) % #Config.LoadoutPresets) + 1
        CurrentLoadoutPresetIdx = idx
        loadout = Config.LoadoutPresets[idx]
    end

    local danceKeys = (Config.Player2CustomDances and Config.Player2CustomDances.Enabled and Config.Player2CustomDances.Slots)
        or (loadout and loadout.Dances)
        or { "Moonwalk", "Headspin", "AbsoluteDisco", "AirChair" }

    if CachedDanceMap then
        for sIdx = 0, 3 do
            local key = danceKeys[sIdx + 1]
            local def = key and CachedDanceMap[NormalizeId(key)]
            if IsValidObj(def) then
                P2CustomState.DanceSlots[sIdx] = def
            end
        end
    end

    P2CustomState.BossAbilitySlots = {}
    P2CustomState.ActiveUpgrades = {}

    local useCustomSkills = Config.Player2CustomSkills and Config.Player2CustomSkills.Enabled
    local mirrorP1 = (not useCustomSkills) and (not loadout or loadout.MirrorPlayer1Skills == true)

    if mirrorP1 and IsLiveWorldObject(p1Controller) then
        pcall(function()
            local p1Data = p1Controller:GetPlaythroughPlayerData()
            local ucat = FindFirstOf("PagodaPlayerUpgradeCatalogSubsystem")
            if IsValidObj(p1Data) and IsValidObj(ucat) and ucat.SortedUpgrades then
                ForEachArrayObj(ucat.SortedUpgrades, function(def)
                    local tagStruct = MakeTagStruct(def.UpgradeIdTag)
                    if tagStruct then
                        local okEq, eq = pcall(function() return p1Data:IsUpgradeEquipped(tagStruct) end)
                        if okEq and eq then
                            P2CustomState.ActiveUpgrades[GetTagString(def.UpgradeIdTag)] = def
                        end
                    end
                end)
            end
            local p1Upg = p1Controller:GetPlayerUpgradeComponent()
            if not IsValidObj(p1Upg) and IsLiveWorldObject(p1Controller.Pawn) then
                p1Upg = p1Controller.Pawn.PlayerUpgrades
            end
            if IsValidObj(p1Upg) then
                for s = 0, 3 do
                    local okB, bDef = pcall(function() return p1Upg:GetPlayerUpgradeAtSlot(s) end)
                    if okB and IsValidObj(bDef) then
                        P2CustomState.BossAbilitySlots[s] = bDef
                    end
                end
            end
        end)
    else
        local uKeys = (useCustomSkills and Config.Player2CustomSkills.Upgrades) or (loadout and loadout.Upgrades) or {}
        local bKeys = (useCustomSkills and Config.Player2CustomSkills.BossAbilities) or (loadout and loadout.BossAbilities) or {}
        if CachedUpgradeMap then
            for _, uk in ipairs(uKeys) do
                local def = CachedUpgradeMap[NormalizeId(uk)]
                if IsValidObj(def) then
                    P2CustomState.ActiveUpgrades[GetTagString(def.UpgradeIdTag)] = def
                end
            end
        end
        if CachedBossAbilityMap then
            for s = 0, 3 do
                local bk = bKeys[s + 1]
                local bDef = bk and CachedBossAbilityMap[NormalizeId(bk)]
                if IsValidObj(bDef) then
                    P2CustomState.BossAbilitySlots[s] = bDef
                end
            end
        end
    end

    return (loadout and loadout.Name) or "Custom Loadout"
end

local function EnsureP2CustomStateInitialized(p1Controller)
    BuildCustomizationCatalogs()
    if P2CustomState.Initialized then return end
    if not CachedCosmeticMap then return end

    LoadOutfitPresetIntoState(CurrentOutfitPresetIdx)
    LoadLoadoutPresetIntoState(CurrentLoadoutPresetIdx, p1Controller)
    P2CustomState.Initialized = true
end

local function SyncPlayer1ProgressToPlayer2(p1Controller, p2Controller)
    if Config.SyncPlayer1UnlocksToPlayer2 == false and not Config.UnlockAllSkillsForPlayer2 then
        return
    end
    BuildCustomizationCatalogs()

    pcall(function()
        local ppd, sharedWithP1 = ResolvePlaythroughData(p1Controller, p2Controller)
        if not IsValidObj(ppd) then return end
        if sharedWithP1 and not Config.UnlockAllSkillsForPlayer2 then
            return
        end

        local p1Data = IsLiveWorldObject(p1Controller) and p1Controller:GetPlaythroughPlayerData() or nil
        if not sharedWithP1 and IsValidObj(p1Data) then
            local p1Credits = p1Data:GetCredits() or 0
            local p2Credits = ppd:GetCredits() or 0
            if p1Credits > p2Credits then
                ppd:AddCredits(p1Credits - p2Credits, false)
            end
        end

        local ucat = FindFirstOf("PagodaPlayerUpgradeCatalogSubsystem")
        if IsValidObj(ucat) and ucat.SortedUpgrades then
            ForEachArrayObj(ucat.SortedUpgrades, function(def)
                local tagStruct = MakeTagStruct(def.UpgradeIdTag)
                if tagStruct then
                    local shouldOwn = (Config.UnlockAllSkillsForPlayer2 == true)
                    if not shouldOwn and IsValidObj(p1Data) then
                        local okOwn, owned = pcall(function() return p1Data:IsUpgradeOwned(tagStruct) end)
                        shouldOwn = (okOwn and owned == true)
                    end
                    if shouldOwn then
                        pcall(function() ppd:AddOwnedUpgrade(tagStruct) end)
                    end
                end
            end)
        end
    end)
end

local function ApplyPlayer2OutfitFromState(p1Controller, p2Controller, p2Pawn)
    EnsureP2CustomStateInitialized(p1Controller)
    if not (IsLiveWorldObject(p2Controller) and IsLiveWorldObject(p2Pawn)) then return end

    pcall(function()
        local ppd, sharedWithP1 = ResolvePlaythroughData(p1Controller, p2Controller)
        local cosmeticComp = p2Pawn.CosmeticComponent
        if not (IsValidObj(ppd) and IsValidObj(cosmeticComp)) then return end

        local p1Snap = sharedWithP1 and SnapshotPlayer1Cosmetics(p1Controller) or nil
        if p1Snap and SavedPlayer1Dances == nil then
            SavedPlayer1Dances = p1Snap.dances
        end

        local targetDefs = {}
        local resolvedSlots = {}
        for slot = 1, 5 do
            local def = P2CustomState.CosmeticSlots[slot]
            if IsValidObj(def) then
                table.insert(targetDefs, def)
                table.insert(resolvedSlots, def)
            end
        end

        for sIdx = 0, 3 do
            local dDef = P2CustomState.DanceSlots[sIdx]
            if IsValidObj(dDef) then
                table.insert(targetDefs, dDef)
            end
        end

        local cosSub = FindPrimaryCosmeticSubsystem()

        WithTemporaryCosmeticAccess(targetDefs, function()
            if IsValidObj(cosSub) then
                pcall(function() cosSub:InitializeUIItemWrappers() end)
                pcall(function() cosSub:ClearUIPreviewItems() end)
                for _, def in ipairs(resolvedSlots) do
                    pcall(function() cosSub:SetUIPreviewItem(def) end)
                end
                pcall(function() cosmeticComp.bUsePreviewItemSelections = true end)
            else
                for _, def in ipairs(resolvedSlots) do
                    pcall(function() ppd:EquipCosmetic(def) end)
                end
            end

            for sIdx = 0, 3 do
                local danceDef = P2CustomState.DanceSlots[sIdx]
                if IsValidObj(danceDef) then
                    local tagStruct = MakeTagStruct(danceDef.CosmeticIdTag)
                    if tagStruct then
                        pcall(function() ppd:EquipDanceMoveToSlot(tagStruct, sIdx) end)
                    end
                end
            end

            pcall(function() cosmeticComp.bUseBlockingLoadForInitialSetup = false end)
            cosmeticComp:SetupForPlaythroughData(ppd)

            for sIdx = 0, 3 do
                local danceDef = P2CustomState.DanceSlots[sIdx]
                if IsValidObj(danceDef) then
                    pcall(function() cosmeticComp:EquipOrSwapDanceMoveAtSlot(danceDef, sIdx) end)
                end
            end
        end)
    end)
end

local function WithUpgradeTemporarilyEnabled(def, fn)
    if not IsValidObj(def) then return end
    local enabledRefDef = CachedUpgradeMap and CachedUpgradeMap["feverrush"] or nil
    local enabledStateValue = 0
    if IsValidObj(enabledRefDef) then
        pcall(function() enabledStateValue = enabledRefDef.EnabledState end)
    end
    local origEnabled = nil
    pcall(function()
        origEnabled = def.EnabledState
        def.EnabledState = enabledStateValue
    end)
    pcall(fn)
    if origEnabled ~= nil then
        pcall(function() def.EnabledState = origEnabled end)
    end
end

local function GetUpgradeComponentForController(pc)
    if not IsLiveWorldObject(pc) then return nil end
    local comp = nil
    pcall(function() comp = pc:GetPlayerUpgradeComponent() end)
    if not IsValidObj(comp) and IsLiveWorldObject(pc.Pawn) then
        pcall(function() comp = pc.Pawn.PlayerUpgrades end)
    end
    return comp
end

local function EquipBossAbilityOnP2Component(p1Controller, p2Controller, bossDef, slotIdx)
    local p2Upg = GetUpgradeComponentForController(p2Controller)
    local p1Upg = GetUpgradeComponentForController(p1Controller)
    local ppd = ResolvePlaythroughData(p1Controller, p2Controller)
    local ucat = FindFirstOf("PagodaPlayerUpgradeCatalogSubsystem")
    if not (IsValidObj(p2Upg) and IsValidObj(bossDef)) then return end

    if SavedPlayer1BossSlots == nil and IsValidObj(p1Upg) then
        SavedPlayer1BossSlots = {}
        for s = 0, 3 do
            local okB, bDef = pcall(function() return p1Upg:GetPlayerUpgradeAtSlot(s) end)
            if okB and IsValidObj(bDef) then
                SavedPlayer1BossSlots[s] = bDef
            end
        end
    end

    local tagStruct = MakeTagStruct(bossDef.UpgradeIdTag)
    if not tagStruct then return end

    WithUpgradeTemporarilyEnabled(bossDef, function()
        local p1HadEq = false
        if IsValidObj(p1Upg) then
            pcall(function() p1HadEq = p1Upg:IsUpgradeEquipped(tagStruct) end)
        end

        if IsValidObj(ppd) then
            pcall(function() ppd:AddOwnedUpgrade(tagStruct) end)
            local eqOnPpd = false
            pcall(function() eqOnPpd = ppd:IsUpgradeEquipped(tagStruct) end)
            if not eqOnPpd and IsValidObj(ucat) then
                pcall(function() ucat:ToggleUpgradeEquippedState(bossDef) end)
            end
        end

        local origSlot = nil
        pcall(function()
            origSlot = bossDef.AutoAssignBossAbilityInputSlot
            bossDef.AutoAssignBossAbilityInputSlot = slotIdx
        end)
        pcall(function() p2Upg:HandleUpgradeEquippedStateChanged(tagStruct, false) end)
        pcall(function() p2Upg:HandleUpgradeEquippedStateChanged(tagStruct, true) end)
        pcall(function() p2Upg:EquipOrSwapBossAbilityAtSlot(bossDef, slotIdx) end)
        if origSlot ~= nil then
            pcall(function() bossDef.AutoAssignBossAbilityInputSlot = origSlot end)
        end

        if IsValidObj(p1Upg) and not p1HadEq then
            pcall(function() p1Upg:HandleUpgradeEquippedStateChanged(tagStruct, false) end)
        end
    end)
end

local function ApplyPlayer2DancesAndSkillsFromState(p1Controller, p2Controller, p2Pawn)
    EnsureP2CustomStateInitialized(p1Controller)
    if not (IsLiveWorldObject(p2Controller) and IsLiveWorldObject(p2Pawn)) then return end

    pcall(function()
        local ppd = ResolvePlaythroughData(p1Controller, p2Controller)
        local cosmeticComp = p2Pawn.CosmeticComponent

        -- 1. Equip 4 Dance Slots
        if IsValidObj(cosmeticComp) then
            local dDefs = {}
            for sIdx = 0, 3 do
                if IsValidObj(P2CustomState.DanceSlots[sIdx]) then
                    table.insert(dDefs, P2CustomState.DanceSlots[sIdx])
                end
            end
            WithTemporaryCosmeticAccess(dDefs, function()
                for sIdx = 0, 3 do
                    local dDef = P2CustomState.DanceSlots[sIdx]
                    if IsValidObj(dDef) then
                        local tagStruct = MakeTagStruct(dDef.CosmeticIdTag)
                        if IsValidObj(ppd) and tagStruct then
                            pcall(function() ppd:EquipDanceMoveToSlot(tagStruct, sIdx) end)
                        end
                        pcall(function() cosmeticComp:EquipOrSwapDanceMoveAtSlot(dDef, sIdx) end)
                    end
                end
            end)
        end

        -- 2. Sync Active Upgrades on P2's PagodaPlayerUpgradeComponent
        local p2Upg = GetUpgradeComponentForController(p2Controller)
        if not IsValidObj(p2Upg) then return end

        local ucat = FindFirstOf("PagodaPlayerUpgradeCatalogSubsystem")
        if IsValidObj(ucat) and ucat.SortedUpgrades then
            ForEachArrayObj(ucat.SortedUpgrades, function(def)
                local tagStr = GetTagString(def.UpgradeIdTag)
                local tagStruct = MakeTagStruct(def.UpgradeIdTag)
                if tagStruct and not P2CustomState.ActiveUpgrades[tagStr] then
                    local okEq, isEq = pcall(function() return p2Upg:IsUpgradeEquipped(tagStruct) end)
                    if okEq and isEq then
                        pcall(function() p2Upg:HandleUpgradeEquippedStateChanged(tagStruct, false) end)
                    end
                end
            end)
        end

        for _, def in pairs(P2CustomState.ActiveUpgrades) do
            if IsValidObj(def) then
                local tagStruct = MakeTagStruct(def.UpgradeIdTag)
                if tagStruct then
                    WithUpgradeTemporarilyEnabled(def, function()
                        pcall(function() p2Upg:HandleUpgradeEquippedStateChanged(tagStruct, true) end)
                    end)
                end
            end
        end

        -- 3. Equip 4 Boss Ability Slots
        for sIdx = 0, 3 do
            local bDef = P2CustomState.BossAbilitySlots[sIdx]
            if IsValidObj(bDef) then
                EquipBossAbilityOnP2Component(p1Controller, p2Controller, bDef, sIdx)
            end
        end
    end)
end

local function SafeLoadBlueprintClass(packagePath, className)
    local fullPath = string.format("%s.%s", packagePath, className)
    local cls = StaticFindObject(fullPath)
    if IsValidObj(cls) then return cls end

    pcall(function()
        local arh = StaticFindObject("/Script/AssetRegistry.Default__AssetRegistryHelpers")
        if IsValidObj(arh) then
            cls = arh:GetAsset({
                PackageName = UEHelpers.FindOrAddFName(packagePath),
                AssetName = UEHelpers.FindOrAddFName(className),
            })
        end
    end)
    if IsValidObj(cls) then return cls end
    return StaticFindObject(fullPath)
end

local function ResolveDesiredPlayer2Class(p1Controller)
    local desired = NormalizeId(CurrentP2Character)
    if desired == "auto" or desired == "" then
        return nil
    end

    local targetClass = nil
    pcall(function()
        if desired == "charlie" then
            targetClass = SafeLoadBlueprintClass("/Game/Pagoda/Characters/Player/BP_PagodaPlayerCharacter_Charlie", "BP_PagodaPlayerCharacter_Charlie_C")
            if not IsValidObj(targetClass) and IsLiveWorldObject(p1Controller) and IsLiveWorldObject(p1Controller.Pawn) then
                targetClass = p1Controller.Pawn:GetClass()
            end
        elseif desired == "chuckles" then
            targetClass = SafeLoadBlueprintClass("/Game/Pagoda/Characters/Player/BP_PagodaPlayerCharacter_Chuckles", "BP_PagodaPlayerCharacter_Chuckles_C")
        end
    end)
    return targetClass
end

local function EnsurePlayer2DesiredCharacterClass(p1Controller, p2Controller)
    if not (IsLiveWorldObject(p1Controller) and IsLiveWorldObject(p2Controller)) then
        return p2Controller and p2Controller.Pawn or nil
    end

    local targetClass = ResolveDesiredPlayer2Class(p1Controller)
    local p2Pawn = p2Controller.Pawn
    if not IsValidObj(targetClass) then
        return p2Pawn
    end

    -- Compare underlying UClass address via SameUObject so we NEVER needlessly destroy/respawn P2's pawn!
    if IsLiveWorldObject(p2Pawn) then
        local sameClass = false
        pcall(function() sameClass = SameUObject(p2Pawn:GetClass(), targetClass) end)
        if sameClass then
            return p2Pawn
        end
    end

    local swappedPawn = nil
    CharacterSwapInProgress = true
    pcall(function()
        local _, World = IsGameplayWorld()
        if not IsValidObj(World) then return end

        local refPawn = IsLiveWorldObject(p2Pawn) and p2Pawn or p1Controller.Pawn
        if not IsLiveWorldObject(refPawn) then return end

        local spawnLoc = refPawn:K2_GetActorLocation()
        if SameUObject(refPawn, p1Controller.Pawn) then
            spawnLoc.X = spawnLoc.X + 140.0
        end
        local spawnRot = refPawn:K2_GetActorRotation()

        local oldPawn = p2Pawn
        if IsLiveWorldObject(oldPawn) then
            pcall(function() p2Controller:UnPossess() end)
            DestroyActorSafely(oldPawn)
        end

        local newPawn = World:SpawnActor(targetClass, spawnLoc, spawnRot)
        if IsLiveWorldObject(newPawn) then
            p2Controller:Possess(newPawn)
            pcall(function() p2Controller:ClientRestart(newPawn) end)
            if IsLiveWorldObject(p2Controller.Pawn) and SameUObject(p2Controller.Pawn, newPawn) then
                swappedPawn = newPawn
                print(string.format("[Local Co-op] Player 2 character active: %s\n", newPawn:GetFullName()))
            else
                -- Never leave an unpossessed pawn in the world if Possess failed
                DestroyActorSafely(newPawn)
            end
        end
    end)

    ExecuteWithDelay(400, function()
        CharacterSwapInProgress = false
    end)

    EnforceSinglePlayer2Instance()
    return swappedPawn or p2Controller.Pawn
end

local function ApplyFullPlayer2Setup(p1Controller, p2Controller)
    if not IsLiveWorldObject(p2Controller) then return end

    local p2Pawn = EnsurePlayer2DesiredCharacterClass(p1Controller, p2Controller)
    if not IsLiveWorldObject(p2Pawn) then return end

    SyncPlayer1ProgressToPlayer2(p1Controller, p2Controller)
    ApplyPlayer2OutfitFromState(p1Controller, p2Controller, p2Pawn)
    ApplyPlayer2DancesAndSkillsFromState(p1Controller, p2Controller, p2Pawn)
    CustomizePlayer2Visuals(p2Pawn)

    ExecuteWithDelay(350, function()
        ExecuteInGameThread(function()
            if IsLiveWorldObject(p2Pawn) then
                CustomizePlayer2Visuals(p2Pawn)
            end
        end)
    end)
end

-- ============================================================================
-- MODULE 3: PAUSE MENU INPUT SOFT-LOCK FIX
-- ============================================================================

local function IsGamePausedNow()
    local pauseSub = FindFirstOf("PagodaGamePauseSubsystem")
    if IsValidObj(pauseSub) then
        local okP, paused = pcall(function() return pauseSub:IsPaused() end)
        return okP and paused == true
    end
    return false
end

local function RestoreInputForAllPlayers()
    pcall(function()
        CachePlayerControllers()
        local wbl = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")

        for idx = 1, 2 do
            local pc = PlayerControllerTable[idx]
            if IsLiveWorldObject(pc) then
                pcall(function() pc.bShowMouseCursor = false end)
                if IsValidObj(wbl) then
                    pcall(function() wbl:SetInputMode_GameOnly(pc) end)
                end
                if not InCutsceneFullscreen and not (idx == 2 and P2Menu.IsOpen()) then
                    pcall(function() pc:ResetIgnoreInputFlags() end)
                    if IsLiveWorldObject(pc.Pawn) then
                        pcall(function() pc.Pawn:EnableInput(pc) end)
                    end
                end
            end
        end

        if IsValidObj(wbl) then
            pcall(function() wbl:SetFocusToGameViewport() end)
        end
    end)
end

local function OpenPauseMenuOnPrimaryViewport(pauseMenuClass)
    local opened = false
    pcall(function()
        if P2Menu.IsOpen() then
            P2Menu.Close()
        end

        CachePlayerControllers()
        local p1 = PlayerControllerTable[1]
        if not IsLiveWorldObject(p1) then return end

        local pauseMenus = FindAllOf("WBP_PauseMenu_Main_C")
        if pauseMenus then
            for _, pm in pairs(pauseMenus) do
                if IsLiveWorldObject(pm) then
                    local okAct, isAct = pcall(function() return pm:IsActivated() end)
                    local owner = nil
                    pcall(function() owner = pm:GetOwningPlayer() end)
                    if okAct and isAct and GetControllerPlayerId(owner) == 0 then
                        opened = true
                        return
                    end
                end
            end
        end

        local pauseSub = FindFirstOf("PagodaGamePauseSubsystem")
        local wasAlreadyPaused = IsValidObj(pauseSub) and pauseSub:IsPaused()
        local bpflUI = StaticFindObject("/Game/Pagoda/UI/BPFL_UI.Default__BPFL_UI_C")

        local p1Layout = nil
        if IsValidObj(bpflUI) then
            pcall(function()
                local outTbl = {}
                bpflUI:GetUILayoutWidgetBase(p1, 0, p1, outTbl)
                if IsValidObj(outTbl.OutWidget) then
                    p1Layout = outTbl.OutWidget
                end
            end)
        end

        if not IsValidObj(p1Layout) then
            local layouts = FindAllOf("PagodaUILayoutWidget")
            if layouts then
                for _, l in pairs(layouts) do
                    if IsLiveWorldObject(l) then
                        local okVP, inVP = pcall(function() return l:IsInViewport() end)
                        local lOwner = nil
                        pcall(function() lOwner = l:GetOwningPlayer() end)
                        if okVP and inVP and GetControllerPlayerId(lOwner) == 0 then
                            p1Layout = l
                        end
                    end
                end
            end
        end

        if not wasAlreadyPaused and IsValidObj(p1Layout) and IsValidObj(bpflUI) then
            pcall(function() bpflUI:PushPauseMenuByWidget(p1Layout, p1) end)
        end

        local p1NowActive = false
        local refreshedMenus = FindAllOf("WBP_PauseMenu_Main_C")
        if refreshedMenus then
            for _, pm in pairs(refreshedMenus) do
                if IsLiveWorldObject(pm) then
                    local okAct, isAct = pcall(function() return pm:IsActivated() end)
                    local owner = nil
                    pcall(function() owner = pm:GetOwningPlayer() end)
                    if okAct and isAct and GetControllerPlayerId(owner) == 0 then
                        p1NowActive = true
                        break
                    end
                end
            end
        end

        if not p1NowActive and IsValidObj(p1Layout) then
            local okVP, inVP = pcall(function() return p1Layout:IsInViewport() end)
            if okVP and inVP then
                if not IsValidObj(pauseMenuClass) then
                    pauseMenuClass = SafeLoadBlueprintClass("/Game/Pagoda/UI/Game/WBP_PauseMenu_Main", "WBP_PauseMenu_Main_C")
                end
                if IsValidObj(pauseMenuClass) then
                    pcall(function()
                        if IsValidObj(p1Layout.SystemMenuStack) then
                            local w = p1Layout.SystemMenuStack:BP_AddWidget(pauseMenuClass)
                            if IsValidObj(w) then
                                pcall(function() w.bResumeGameOnDeactivation = true end)
                                p1NowActive = true
                            end
                        end
                    end)
                end
                if p1NowActive and IsValidObj(pauseSub) then
                    pcall(function() pauseSub:SetIsPaused(true) end)
                end
            end
        end

        opened = p1NowActive
    end)
    return opened
end

local function DeactivateOrphanPlayer2PauseMenus()
    local foundOrphan = false
    pcall(function()
        local pauseMenus = FindAllOf("WBP_PauseMenu_Main_C")
        if not pauseMenus then return end

        local p1HasActivePause = false
        for _, pm in pairs(pauseMenus) do
            if IsLiveWorldObject(pm) then
                local okAct, isAct = pcall(function() return pm:IsActivated() end)
                local owner = nil
                pcall(function() owner = pm:GetOwningPlayer() end)
                local pid = GetControllerPlayerId(owner)
                if okAct and isAct and pid == 0 then
                    p1HasActivePause = true
                end
            end
        end

        local pauseMenuClass = nil
        for _, pm in pairs(pauseMenus) do
            if IsLiveWorldObject(pm) then
                local okAct, isAct = pcall(function() return pm:IsActivated() end)
                local owner = nil
                pcall(function() owner = pm:GetOwningPlayer() end)
                local pid = GetControllerPlayerId(owner)

                if okAct and isAct and pid ~= nil and pid > 0 then
                    foundOrphan = true
                    pcall(function() pauseMenuClass = pm:GetClass() end)
                    pcall(function() pm.bResumeGameOnDeactivation = false end)
                    pcall(function() pm.bShowCountdownOnDeactivate = false end)
                    pcall(function() pm:DeactivateWidget() end)
                end
            end
        end

        if foundOrphan and not p1HasActivePause and not RedirectingPauseMenu then
            RedirectingPauseMenu = true
            OpenPauseMenuOnPrimaryViewport(pauseMenuClass)
            RedirectingPauseMenu = false
        end
    end)
    RedirectingPauseMenu = false
end

local function TryResumeActivePauseMenu()
    local resumed = false
    pcall(function()
        local pauseMenus = FindAllOf("WBP_PauseMenu_Main_C")
        if pauseMenus then
            for _, pm in pairs(pauseMenus) do
                if IsLiveWorldObject(pm) then
                    local okAct, isAct = pcall(function() return pm:IsActivated() end)
                    if okAct and isAct then
                        pcall(function() pm.bResumeGameOnDeactivation = true end)
                        pcall(function() pm.bShowCountdownOnDeactivate = false end)
                        pm:HandleResumeGame()
                        resumed = true
                    end
                end
            end
        end
        if resumed then
            ExecuteWithDelay(60, function()
                ExecuteInGameThread(function()
                    local pauseSub = FindFirstOf("PagodaGamePauseSubsystem")
                    if IsValidObj(pauseSub) and pauseSub:IsPaused() then
                        pauseSub:SetIsPaused(false)
                    end
                end)
            end)
        else
            local pauseSub = FindFirstOf("PagodaGamePauseSubsystem")
            if IsValidObj(pauseSub) and pauseSub:IsPaused() then
                pauseSub:SetIsPaused(false)
                resumed = true
            end
        end
    end)
    return resumed
end

-- ============================================================================
-- CORE CO-OP ACTIONS (SPAWN, REMOVE, TELEPORT, CUSTOMIZE, MODES)
-- ============================================================================

local InstallRuntimeHooks -- forward declaration

local function SpawnPlayer2()
    if SpawningPlayer2InProgress then return end
    if not CanTriggerAction("SpawnPlayer2", 0.45) then return end

    print("[Local Co-op] SpawnPlayer2 requested...\n")
    ExecuteInGameThread(function()
        if SpawningPlayer2InProgress then return end

        local inGameplay, World = IsGameplayWorld()
        if not inGameplay or not IsValidObj(World) then
            ShowMessage("Enter the Dive Bar or a Stage before connecting Player 2!", { R = 1.0, G = 0.4, B = 0.3, A = 1.0 })
            return
        end

        InstallRuntimeHooks()
        EnforceSinglePlayer2Instance()
        CachePlayerControllers()

        local P1Controller = PlayerControllerTable[1]
        if not (IsLiveWorldObject(P1Controller) and IsLiveWorldObject(P1Controller.Pawn)) then
            ShowMessage("Cannot spawn Player 2: Wait for Player 1 to spawn first!", { R = 1.0, G = 0.3, B = 0.3, A = 1.0 })
            return
        end

        -- Strict Singleton Rule: if Player 2 already exists with a live Pawn, NEVER create a second copy!
        if IsPlayer2Active() then
            local existingP2 = PlayerControllerTable[2]
            if IsLiveWorldObject(existingP2.Pawn) then
                local TargetLoc = P1Controller.Pawn:K2_GetActorLocation()
                TargetLoc.X = TargetLoc.X + 120.0
                local TargetRot = P1Controller.Pawn:K2_GetActorRotation()
                existingP2.Pawn:K2_SetActorLocationAndRotation(TargetLoc, TargetRot, false, {}, false)
                EnforceSinglePlayer2Instance()
                ShowMessage("Player 2 is already active — regrouped with Player 1!", { R = 1.0, G = 1.0, B = 0.3, A = 1.0 })
                return
            end
        end

        local GameplayStatics = GetGameplayStatics()
        if not IsValidObj(GameplayStatics) then return end

        SpawningPlayer2InProgress = true
        local okSpawn, errSpawn = pcall(function()
            local NewController = PlayerControllerTable[2]
            if not IsLiveWorldObject(NewController) then
                NewController = GameplayStatics:CreatePlayer(P1Controller, 1, true)
            elseif not IsLiveWorldObject(NewController.Pawn) then
                local gm = UEHelpers.GetGameModeBase()
                if IsValidObj(gm) then
                    pcall(function() gm:RestartPlayer(NewController) end)
                end
            end

            if IsLiveWorldObject(NewController) and GetControllerPlayerId(NewController) == 1 then
                PlayerControllerTable[2] = NewController
                print(string.format("[Local Co-op] Player 2 Controller active: %s\n", NewController:GetFullName()))

                if not IsLiveWorldObject(NewController.Pawn) then
                    local P1Pawn = P1Controller.Pawn
                    local SpawnLoc = P1Pawn:K2_GetActorLocation()
                    SpawnLoc.X = SpawnLoc.X + 150.0
                    local SpawnRot = P1Pawn:K2_GetActorRotation()
                    local SpawnedPawn = World:SpawnActor(P1Pawn:GetClass(), SpawnLoc, SpawnRot)
                    if IsLiveWorldObject(SpawnedPawn) then
                        NewController:Possess(SpawnedPawn)
                        pcall(function() NewController:ClientRestart(SpawnedPawn) end)
                        if not SameUObject(NewController.Pawn, SpawnedPawn) then
                            DestroyActorSafely(SpawnedPawn)
                        end
                    end
                else
                    pcall(function()
                        local TargetLoc = P1Controller.Pawn:K2_GetActorLocation()
                        TargetLoc.X = TargetLoc.X + 140.0
                        local TargetRot = P1Controller.Pawn:K2_GetActorRotation()
                        NewController.Pawn:K2_SetActorLocationAndRotation(TargetLoc, TargetRot, false, {}, false)
                    end)
                end

                EnforceSinglePlayer2Instance()
                SyncGamepadOffsetForPlayerCount(false)
                ApplyScreenModeInternal(CurrentScreenMode, true)

                ExecuteWithDelay(150, function()
                    ExecuteInGameThread(function()
                        pcall(function()
                            CachePlayerControllers()
                            if IsPlayer2Active() and IsLiveWorldObject(PlayerControllerTable[1]) then
                                ApplyFullPlayer2Setup(PlayerControllerTable[1], PlayerControllerTable[2])
                                EnforceSinglePlayer2Instance()
                                LocalizeAllPlayerUILayouts()
                            end
                        end)
                        SpawningPlayer2InProgress = false
                    end)
                end)

                ShowMessage(
                    string.format("Player 2 Connected (%s)! Press [Select] or [F2]/[F3] for P2 Menu!", CurrentP2Character),
                    { R = 0.2, G = 1.0, B = 0.4, A = 1.0 }
                )
            else
                SpawningPlayer2InProgress = false
                ShowMessage("Failed to spawn Player 2. Make sure you are inside an active level.", { R = 1.0, G = 0.3, B = 0.3, A = 1.0 })
            end
        end)

        if not okSpawn then
            SpawningPlayer2InProgress = false
            print("[Local Co-op] SpawnPlayer2 error: " .. tostring(errSpawn) .. "\n")
        end
    end)
end

local function RemovePlayer2()
    if not CanTriggerAction("RemovePlayer2", 0.40) then return end
    ExecuteInGameThread(function()
        if P2Menu.IsOpen() then
            P2Menu.Close()
        end
        P2Menu.OnWorldOrControllersChanged()

        CachePlayerControllers()
        if not IsPlayer2Active() then
            EnforceSinglePlayer2Instance()
            ShowMessage("Player 2 is not currently in the game.", { R = 1.0, G = 0.8, B = 0.2, A = 1.0 })
            return
        end

        local ControllerToRemove = PlayerControllerTable[2]
        local GameplayStatics = GetGameplayStatics()
        if IsValidObj(GameplayStatics) and IsLiveWorldObject(ControllerToRemove) then
            InCutsceneFullscreen = false
            SavedPreCutsceneMode = nil
            SpawningPlayer2InProgress = false

            if IsLiveWorldObject(ControllerToRemove.Pawn) then
                DestroyActorSafely(ControllerToRemove.Pawn)
            end
            MarkObjectDestroyed(ControllerToRemove)
            pcall(function() GameplayStatics:RemovePlayer(ControllerToRemove, true) end)
            PlayerControllerTable[2] = nil

            EnforceSinglePlayer2Instance()
            RestorePlayer1DataIfDisconnected(PlayerControllerTable[1])
            ClearNativeMultiplayerSavedFlagIfSolo()
            SyncGamepadOffsetForPlayerCount(false)
            LocalizeAllPlayerUILayouts()
            RestoreInputForAllPlayers()
            ShowMessage("Player 2 has left the game.", { R = 1.0, G = 0.5, B = 0.2, A = 1.0 })
        end
    end)
end

local function TeleportPlayer2()
    if not CanTriggerAction("TeleportPlayer2", 0.25) then return end
    ExecuteInGameThread(function()
        CachePlayerControllers()
        if not IsPlayer2Active() then
            ShowMessage("Player 2 is not currently active.", { R = 1.0, G = 0.8, B = 0.2, A = 1.0 })
            return
        end

        local P1Pawn = PlayerControllerTable[1] and PlayerControllerTable[1].Pawn
        local P2Pawn = PlayerControllerTable[2] and PlayerControllerTable[2].Pawn
        if IsLiveWorldObject(P1Pawn) and IsLiveWorldObject(P2Pawn) then
            local TargetLoc = P1Pawn:K2_GetActorLocation()
            TargetLoc.X = TargetLoc.X + 120.0
            local TargetRot = P1Pawn:K2_GetActorRotation()
            P2Pawn:K2_SetActorLocationAndRotation(TargetLoc, TargetRot, false, {}, false)
            ShowMessage("Player 2 teleported to Player 1!", { R = 0.4, G = 0.9, B = 1.0, A = 1.0 })
        end
    end)
end

local function CycleScreenMode()
    if not CanTriggerAction("CycleScreenMode", 0.25) then return end
    InCutsceneFullscreen = false
    SavedPreCutsceneMode = nil
    CurrentScreenMode = (CurrentScreenMode + 1) % 3
    ExecuteInGameThread(function()
        ApplyScreenMode(CurrentScreenMode)
    end)
end

local function ToggleGamepadOffset()
    if not CanTriggerAction("ToggleGamepadOffset", 0.25) then return end
    CurrentOffsetGamepad = not CurrentOffsetGamepad
    ExecuteInGameThread(function()
        SyncGamepadOffsetForPlayerCount(true)
    end)
end

local function ToggleAutoLeash()
    if not CanTriggerAction("ToggleAutoLeash", 0.25) then return end
    AutoLeashActive = not AutoLeashActive
    if AutoLeashActive then
        ShowMessage("Auto-Leashing: ENABLED (P2 stays in arena)", { R = 0.4, G = 1.0, B = 0.4, A = 1.0 })
    else
        ShowMessage("Auto-Leashing: DISABLED", { R = 1.0, G = 0.4, B = 0.4, A = 1.0 })
    end
end

local function CyclePlayer2OutfitPreset()
    if not CanTriggerAction("CycleOutfit", 0.25) then return end
    ExecuteInGameThread(function()
        CachePlayerControllers()
        if not IsPlayer2Active() or not IsLiveWorldObject(PlayerControllerTable[2].Pawn) then
            ShowMessage("Connect Player 2 first ([F6] or [L3+R3]) to customize outfits!", { R = 1.0, G = 0.8, B = 0.2, A = 1.0 })
            return
        end

        if Config.Player2CustomOutfit then Config.Player2CustomOutfit.Enabled = false end
        local count = (Config.OutfitPresets and #Config.OutfitPresets) or 1
        local nextIdx = (CurrentOutfitPresetIdx % count) + 1

        if NormalizeId(CurrentP2Character) == "chuckles" then
            CurrentP2Character = "Charlie"
            EnsurePlayer2DesiredCharacterClass(PlayerControllerTable[1], PlayerControllerTable[2])
        end

        EnsureP2CustomStateInitialized(PlayerControllerTable[1])
        local outfitName = LoadOutfitPresetIntoState(nextIdx) or ("Preset #" .. tostring(nextIdx))
        local p2 = PlayerControllerTable[2]
        ApplyPlayer2OutfitFromState(PlayerControllerTable[1], p2, p2.Pawn)
        CustomizePlayer2Visuals(p2.Pawn)
        ShowMessage(string.format("P2 Outfit: %s", outfitName), { R = 0.9, G = 0.5, B = 1.0, A = 1.0 })
    end)
end

local function CyclePlayer2LoadoutPreset()
    if not CanTriggerAction("CycleLoadout", 0.25) then return end
    ExecuteInGameThread(function()
        CachePlayerControllers()
        if not IsPlayer2Active() or not IsLiveWorldObject(PlayerControllerTable[2].Pawn) then
            ShowMessage("Connect Player 2 first ([F6] or [L3+R3]) to switch skills/dances!", { R = 1.0, G = 0.8, B = 0.2, A = 1.0 })
            return
        end

        if Config.Player2CustomSkills then Config.Player2CustomSkills.Enabled = false end
        if Config.Player2CustomDances then Config.Player2CustomDances.Enabled = false end

        local count = (Config.LoadoutPresets and #Config.LoadoutPresets) or 1
        local nextIdx = (CurrentLoadoutPresetIdx % count) + 1

        EnsureP2CustomStateInitialized(PlayerControllerTable[1])
        SyncPlayer1ProgressToPlayer2(PlayerControllerTable[1], PlayerControllerTable[2])
        local loadoutName = LoadLoadoutPresetIntoState(nextIdx, PlayerControllerTable[1]) or ("Loadout #" .. tostring(nextIdx))
        ApplyPlayer2DancesAndSkillsFromState(PlayerControllerTable[1], PlayerControllerTable[2], PlayerControllerTable[2].Pawn)
        ShowMessage(string.format("P2 Skills & Dances: %s", loadoutName), { R = 0.3, G = 1.0, B = 0.8, A = 1.0 })
    end)
end

local function SetPlayer2CharacterModel(modelName)
    CurrentP2Character = modelName
    CachePlayerControllers()
    if IsPlayer2Active() and IsLiveWorldObject(PlayerControllerTable[1]) then
        local wasMenuOpen = P2Menu.IsOpen()
        ApplyFullPlayer2Setup(PlayerControllerTable[1], PlayerControllerTable[2])
        EnforceSinglePlayer2Instance()
        if wasMenuOpen and IsLiveWorldObject(PlayerControllerTable[2]) and IsLiveWorldObject(PlayerControllerTable[2].Pawn) then
            pcall(function() PlayerControllerTable[2].Pawn:DisableInput(PlayerControllerTable[2]) end)
        end
        ShowMessage(string.format("P2 Character Model: %s", CurrentP2Character), { R = 1.0, G = 0.75, B = 0.2, A = 1.0 })
    else
        ShowMessage(string.format("P2 Default Character set to: %s", CurrentP2Character), { R = 1.0, G = 0.75, B = 0.2, A = 1.0 })
    end
end

local function SwapPlayer2Character()
    if SpawningPlayer2InProgress then return end
    if not CanTriggerAction("SwapP2Character", 0.45) then return end
    ExecuteInGameThread(function()
        local nextModel = (NormalizeId(CurrentP2Character) == "charlie") and "Chuckles" or "Charlie"
        SetPlayer2CharacterModel(nextModel)
    end)
end

local function CyclePlayer2TintMode()
    if not CanTriggerAction("CycleTintMode", 0.20) then return end
    ExecuteInGameThread(function()
        if CurrentTintMode == "FullBody" then
            CurrentTintMode = "AccentOnly"
        elseif CurrentTintMode == "AccentOnly" then
            CurrentTintMode = "Off"
        else
            CurrentTintMode = "FullBody"
        end

        CachePlayerControllers()
        if IsPlayer2Active() and IsLiveWorldObject(PlayerControllerTable[2].Pawn) then
            local p2 = PlayerControllerTable[2]
            ApplyPlayer2OutfitFromState(PlayerControllerTable[1], p2, p2.Pawn)
            CustomizePlayer2Visuals(p2.Pawn)
        end
        ShowMessage(string.format("P2 Visual Tint Mode: %s", CurrentTintMode), { R = 0.2, G = 0.95, B = 1.0, A = 1.0 })
    end)
end

local function OpenOrToggleP2MenuOutfits()
    if not CanTriggerAction("ToggleP2MenuOutfits", 0.25) then return end
    ExecuteInGameThread(function()
        CachePlayerControllers()
        P2Menu.Toggle(1)
    end)
end

local function OpenOrToggleP2MenuSkills()
    if not CanTriggerAction("ToggleP2MenuSkills", 0.25) then return end
    ExecuteInGameThread(function()
        CachePlayerControllers()
        P2Menu.Toggle(3)
    end)
end

-- ============================================================================
-- CUSTOM UI MENU API BRIDGE (`p2_menu.lua`)
-- ============================================================================

local CoopMenuAPI = {
    IsValidObj = IsValidObj,
    IsLiveWorldObject = IsLiveWorldObject,
    SameUObject = SameUObject,
    IsGameplayWorld = IsGameplayWorld,
    IsGamePaused = IsGamePausedNow,
    ShowMessage = ShowMessage,
    GetCurrentScreenMode = function() return CurrentScreenMode end,
    GetCurrentCharacterName = function() return CurrentP2Character end,
    GetCurrentTintMode = function() return CurrentTintMode end,
    GetCurrentTintPaletteIdx = function() return CurrentTintPaletteIdx end,
    GetCurrentOutfitPresetIdx = function() return CurrentOutfitPresetIdx end,
    GetCurrentLoadoutPresetIdx = function() return CurrentLoadoutPresetIdx end,
    HasCustomPieceOverride = function() return P2CustomState.CustomPieceOverride == true end,

    GetControllers = function()
        CachePlayerControllers()
        return PlayerControllerTable[1], PlayerControllerTable[2]
    end,

    EnsureP2ReadyForMenu = function()
        CachePlayerControllers()
        EnsureP2CustomStateInitialized(PlayerControllerTable[1])
    end,

    GetOrderedCatalogs = function()
        BuildCustomizationCatalogs()
        return OrderedCatalogs
    end,

    GetEquippedCosmeticAtSlot = function(slotNum)
        EnsureP2CustomStateInitialized(PlayerControllerTable[1])
        return P2CustomState.CosmeticSlots[slotNum]
    end,

    EquipCosmeticDef = function(slotNum, def)
        if not IsValidObj(def) then return end
        CachePlayerControllers()
        local p1, p2 = PlayerControllerTable[1], PlayerControllerTable[2]
        if not (IsLiveWorldObject(p2) and IsLiveWorldObject(p2.Pawn)) then return end

        EnsureP2CustomStateInitialized(p1)
        if NormalizeId(CurrentP2Character) == "chuckles" then
            CurrentP2Character = "Charlie"
            EnsurePlayer2DesiredCharacterClass(p1, p2)
            if P2Menu.IsOpen() and IsLiveWorldObject(p2.Pawn) then
                pcall(function() p2.Pawn:DisableInput(p2) end)
            end
        end

        local activePawn = p2.Pawn
        if not IsLiveWorldObject(activePawn) then return end

        P2CustomState.CosmeticSlots[slotNum] = def
        P2CustomState.CustomPieceOverride = true
        ApplyPlayer2OutfitFromState(p1, p2, activePawn)
        CustomizePlayer2Visuals(activePawn)
    end,

    ApplyOutfitPresetByIndex = function(idx)
        CachePlayerControllers()
        local p1, p2 = PlayerControllerTable[1], PlayerControllerTable[2]
        if not (IsLiveWorldObject(p2) and IsLiveWorldObject(p2.Pawn)) then return end

        if NormalizeId(CurrentP2Character) == "chuckles" then
            CurrentP2Character = "Charlie"
            EnsurePlayer2DesiredCharacterClass(p1, p2)
            if P2Menu.IsOpen() and IsLiveWorldObject(p2.Pawn) then
                pcall(function() p2.Pawn:DisableInput(p2) end)
            end
        end

        local activePawn = p2.Pawn
        if not IsLiveWorldObject(activePawn) then return end

        EnsureP2CustomStateInitialized(p1)
        LoadOutfitPresetIntoState(idx)
        ApplyPlayer2OutfitFromState(p1, p2, activePawn)
        CustomizePlayer2Visuals(activePawn)
    end,

    GetEquippedDanceNameAtSlot = function(slotIdx)
        EnsureP2CustomStateInitialized(PlayerControllerTable[1])
        local dDef = P2CustomState.DanceSlots[slotIdx]
        if IsValidObj(dDef) then
            return GetSafeTextString(dDef.DisplayName, dDef:GetFName():ToString())
        end
        return "Empty"
    end,

    FindEquippedDanceSlotForDef = function(def)
        if not IsValidObj(def) then return nil end
        EnsureP2CustomStateInitialized(PlayerControllerTable[1])
        for sIdx = 0, 3 do
            if IsValidObj(P2CustomState.DanceSlots[sIdx]) and SameUObject(P2CustomState.DanceSlots[sIdx], def) then
                return sIdx
            end
        end
        return nil
    end,

    EquipDanceAtSlot = function(slotIdx, danceDef)
        if not IsValidObj(danceDef) then return end
        CachePlayerControllers()
        local p1, p2 = PlayerControllerTable[1], PlayerControllerTable[2]
        if not (IsLiveWorldObject(p2) and IsLiveWorldObject(p2.Pawn)) then return end

        EnsureP2CustomStateInitialized(p1)
        P2CustomState.DanceSlots[slotIdx] = danceDef
        ApplyPlayer2DancesAndSkillsFromState(p1, p2, p2.Pawn)
    end,

    GetEquippedBossAbilityNameAtSlot = function(slotIdx)
        EnsureP2CustomStateInitialized(PlayerControllerTable[1])
        local bDef = P2CustomState.BossAbilitySlots[slotIdx]
        if IsValidObj(bDef) then
            return GetSafeTextString(bDef.DisplayName, bDef:GetFName():ToString())
        end
        return "Empty"
    end,

    FindEquippedBossSlotForDef = function(def)
        if not IsValidObj(def) then return nil end
        EnsureP2CustomStateInitialized(PlayerControllerTable[1])
        for sIdx = 0, 3 do
            if IsValidObj(P2CustomState.BossAbilitySlots[sIdx]) and SameUObject(P2CustomState.BossAbilitySlots[sIdx], def) then
                return sIdx
            end
        end
        return nil
    end,

    EquipBossAbilityAtSlot = function(slotIdx, bossDef)
        if not IsValidObj(bossDef) then return end
        CachePlayerControllers()
        local p1, p2 = PlayerControllerTable[1], PlayerControllerTable[2]
        if not (IsLiveWorldObject(p2) and IsLiveWorldObject(p2.Pawn)) then return end

        EnsureP2CustomStateInitialized(p1)
        -- If already equipped in another slot, swap cleanly so slots never duplicate unexpectedly
        for other = 0, 3 do
            if other ~= slotIdx and IsValidObj(P2CustomState.BossAbilitySlots[other])
                and SameUObject(P2CustomState.BossAbilitySlots[other], bossDef) then
                P2CustomState.BossAbilitySlots[other] = P2CustomState.BossAbilitySlots[slotIdx]
                if IsValidObj(P2CustomState.BossAbilitySlots[other]) then
                    EquipBossAbilityOnP2Component(p1, p2, P2CustomState.BossAbilitySlots[other], other)
                end
            end
        end
        P2CustomState.BossAbilitySlots[slotIdx] = bossDef
        EquipBossAbilityOnP2Component(p1, p2, bossDef, slotIdx)
    end,

    ApplySkillLoadoutByIndex = function(idx)
        CachePlayerControllers()
        local p1, p2 = PlayerControllerTable[1], PlayerControllerTable[2]
        if not (IsLiveWorldObject(p2) and IsLiveWorldObject(p2.Pawn)) then return end

        EnsureP2CustomStateInitialized(p1)
        SyncPlayer1ProgressToPlayer2(p1, p2)
        LoadLoadoutPresetIntoState(idx, p1)
        ApplyPlayer2DancesAndSkillsFromState(p1, p2, p2.Pawn)
    end,

    IsUpgradeEquippedOnP2 = function(def)
        if not IsValidObj(def) then return false end
        CachePlayerControllers()
        local p2 = PlayerControllerTable[2]
        local p2Upg = GetUpgradeComponentForController(p2)
        if IsValidObj(p2Upg) then
            local tagStruct = MakeTagStruct(def.UpgradeIdTag)
            if tagStruct then
                local okEq, eq = pcall(function() return p2Upg:IsUpgradeEquipped(tagStruct) end)
                if okEq then return eq == true end
            end
        end
        return P2CustomState.ActiveUpgrades[GetTagString(def.UpgradeIdTag)] ~= nil
    end,

    ToggleUpgradeDef = function(def)
        if not IsValidObj(def) then return end
        CachePlayerControllers()
        local p1, p2 = PlayerControllerTable[1], PlayerControllerTable[2]
        local p2Upg = GetUpgradeComponentForController(p2)
        if not IsValidObj(p2Upg) then return end

        local tagStr = GetTagString(def.UpgradeIdTag)
        local tagStruct = MakeTagStruct(def.UpgradeIdTag)
        if not tagStruct then return end

        local currentlyEq = false
        pcall(function() currentlyEq = (p2Upg:IsUpgradeEquipped(tagStruct) == true) end)
        local targetState = not currentlyEq

        WithUpgradeTemporarilyEnabled(def, function()
            pcall(function() p2Upg:HandleUpgradeEquippedStateChanged(tagStruct, targetState) end)
        end)

        if targetState then
            P2CustomState.ActiveUpgrades[tagStr] = def
        else
            P2CustomState.ActiveUpgrades[tagStr] = nil
        end
    end,

    SetCharacterModel = function(modelName)
        SetPlayer2CharacterModel(modelName)
    end,

    CycleTintMode = function()
        CyclePlayer2TintMode()
    end,

    SetTintPalette = function(paletteIdx)
        local palettes = Config.TintColorPalettes or {}
        local pal = palettes[paletteIdx]
        if not pal then return end
        CurrentTintPaletteIdx = paletteIdx
        Config.Player2TintColor = pal.Color
        if CurrentTintMode == "Off" then
            CurrentTintMode = "AccentOnly"
        end
        CachePlayerControllers()
        if IsPlayer2Active() and IsLiveWorldObject(PlayerControllerTable[2].Pawn) then
            CustomizePlayer2Visuals(PlayerControllerTable[2].Pawn)
        end
    end,

    CycleScreenMode = function()
        CycleScreenMode()
    end,

    TeleportPlayer2 = function()
        TeleportPlayer2()
    end,
}

P2Menu.Init(CoopMenuAPI, Config)

-- ============================================================================
-- MODULE 5: DIVE BAR STATION INTERACTION & GAMEPAD SHORTCUTS
-- ============================================================================

local function GetActorDistSq(a, b)
    if not (IsLiveWorldObject(a) and IsLiveWorldObject(b)) then return math.huge end
    local ok, d2 = pcall(function()
        local l1 = a:K2_GetActorLocation()
        local l2 = b:K2_GetActorLocation()
        local dx = l1.X - l2.X
        local dy = l1.Y - l2.Y
        local dz = l1.Z - l2.Z
        return dx * dx + dy * dy + dz * dz
    end)
    return ok and d2 or math.huge
end

-- Checks if Player 2 is standing right next to the Dive Bar Wardrobe or Skill Tree station
local function TryOpenDiveBarStationForPlayer2()
    if Config.InterceptDiveBarStationsForP2 == false or Config.EnableP2CustomMenu == false then
        return false
    end
    CachePlayerControllers()
    local p2 = PlayerControllerTable[2]
    if not (IsLiveWorldObject(p2) and IsLiveWorldObject(p2.Pawn)) then return false end

    local maxRangeSq = 420.0 * 420.0

    local cosStations = FindAllOf("BP_DiveBar_Interact_Cosmetics_C")
    if cosStations then
        for _, st in pairs(cosStations) do
            if IsLiveWorldObject(st) and GetActorDistSq(p2.Pawn, st) <= maxRangeSq then
                P2Menu.Open(1) -- OUTFITS tab
                return true
            end
        end
    end

    local skillStations = FindAllOf("BP_DiveBar_Interact_SkillTree_C")
    if skillStations then
        for _, st in pairs(skillStations) do
            if IsLiveWorldObject(st) and GetActorDistSq(p2.Pawn, st) <= maxRangeSq then
                P2Menu.Open(3) -- BOSS SKILLS tab
                return true
            end
        end
    end

    return false
end

local function DidPlayer2TriggerStation(stationActor)
    if not IsLiveWorldObject(stationActor) then return false end
    CachePlayerControllers()
    local p1, p2 = PlayerControllerTable[1], PlayerControllerTable[2]
    if not (IsLiveWorldObject(p2) and IsLiveWorldObject(p2.Pawn)) then return false end

    local now = os.clock()
    local p2RecentInput = (now - LastP2ControllerInputTime) <= 0.50
    local d2 = GetActorDistSq(p2.Pawn, stationActor)
    local d1 = (IsLiveWorldObject(p1) and IsLiveWorldObject(p1.Pawn)) and GetActorDistSq(p1.Pawn, stationActor) or math.huge

    return p2RecentInput and (d2 <= 480.0 * 480.0) and (d2 <= d1 + 40000.0)
end

local function IsControllerChordPressed(pc, chordKeys, nowClock)
    if type(chordKeys) ~= "table" or #chordKeys == 0 then return false end
    if not IsLiveWorldObject(pc) then return false end

    local pcKey = GetObjectKey(pc)
    local recent = RecentKeyPressTimes[pcKey]

    for _, keyName in ipairs(chordKeys) do
        local isDown = false
        local window = (keyName == "Gamepad_Special_Left" or keyName == "Gamepad_Special_Right") and 1.20 or 0.55
        if recent and recent[keyName] and (nowClock - recent[keyName]) <= window then
            isDown = true
        else
            local okDown, res = pcall(function()
                return pc:IsInputKeyDown({ KeyName = FName(keyName) })
            end)
            if okDown and res == true then
                isDown = true
            end
        end
        if not isDown then
            return false
        end
    end
    return true
end

local function EvaluateGamepadShortcutsForController(pc, justPressedKeyName)
    if Config.EnableGamepadShortcuts == false then return end
    if not IsLiveWorldObject(pc) then return end

    local now = os.clock()
    local pid = GetControllerPlayerId(pc)
    if pid == 1 then
        LastP2ControllerInputTime = now
    end

    if justPressedKeyName and justPressedKeyName ~= "" then
        local pcKey = GetObjectKey(pc)
        RecentKeyPressTimes[pcKey] = RecentKeyPressTimes[pcKey] or {}
        local prevKeyTime = RecentKeyPressTimes[pcKey][justPressedKeyName]
        RecentKeyPressTimes[pcKey][justPressedKeyName] = now

        -- 1. Player 2 Start Button: Deadlock-free Pause & Resume on Primary Viewport
        if justPressedKeyName == "Gamepad_Special_Right" and pid == 1 then
            if prevKeyTime and (now - prevKeyTime) < 0.25 then return end
            if P2Menu.IsOpen() then
                P2Menu.Close()
            end
            if IsGamePausedNow() then
                ExecuteWithDelay(30, function()
                    ExecuteInGameThread(TryResumeActivePauseMenu)
                end)
            else
                ExecuteWithDelay(40, function()
                    ExecuteInGameThread(function()
                        if not IsGameplayWorld() then return end
                        DeactivateOrphanPlayer2PauseMenus()
                        if not IsGamePausedNow() then
                            OpenPauseMenuOnPrimaryViewport(nil)
                        end
                    end)
                end)
            end
            LastGamepadChordTriggerTime = now
            return
        end

        -- While P2's Custom Menu is open, `p2_menu.lua` handles all P2 button navigation directly
        if P2Menu.IsOpen() and pid == 1 then
            return
        end

        -- 2. Player 2 Dive Bar Wardrobe / Skill Tree Proximity Interact
        if pid == 1 and not IsGamePausedNow()
            and (justPressedKeyName == "Gamepad_FaceButton_Left"
                or justPressedKeyName == "Gamepad_FaceButton_Top"
                or justPressedKeyName == "Gamepad_FaceButton_Bottom") then
            if TryOpenDiveBarStationForPlayer2() then
                LastGamepadChordTriggerTime = now
                return
            end
        end

        -- 3. Player 2 [Select / View] Button: Open Player 2's Custom Skins & Skills Studio Menu!
        local menuKey = Config.GamepadMenuToggleKey or "Gamepad_Special_Left"
        if pid == 1 and justPressedKeyName == menuKey and Config.EnableP2CustomMenu ~= false and not IsGamePausedNow() then
            -- Wait 160ms so Select+L3 / Select+R3 quick-chords still work if thumbstick is clicked simultaneously;
            -- otherwise open Player 2's full interactive Custom Menu!
            ExecuteWithDelay(160, function()
                ExecuteInGameThread(function()
                    if P2Menu.IsOpen() or IsGamePausedNow() or not IsGameplayWorld() then return end
                    if (os.clock() - LastGamepadChordTriggerTime) < 0.30 then return end
                    P2Menu.Open()
                end)
            end)
        end
    end

    if P2Menu.IsOpen() then return end

    local cooldown = Config.GamepadChordCooldown or 0.65
    if (now - LastGamepadChordTriggerTime) < cooldown then return end
    if IsGamePausedNow() then return end
    if not IsGameplayWorld() then return end

    if IsControllerChordPressed(pc, Config.GamepadOutfitCycleChord, now) then
        LastGamepadChordTriggerTime = now
        ExecuteWithDelay(50, CyclePlayer2OutfitPreset)
        return
    end

    if IsControllerChordPressed(pc, Config.GamepadLoadoutCycleChord, now) then
        LastGamepadChordTriggerTime = now
        ExecuteWithDelay(50, CyclePlayer2LoadoutPreset)
        return
    end

    if IsControllerChordPressed(pc, Config.GamepadJoinChord, now) then
        LastGamepadChordTriggerTime = now
        ExecuteWithDelay(50, SpawnPlayer2)
        return
    end
end

-- ============================================================================
-- ENGINE & BLUEPRINT HOOK INSTALLATION
-- ============================================================================

local function InitEngineSettings()
    pcall(function()
        EnforceSinglePlayer2Instance()
        CachePlayerControllers()
        ClearNativeMultiplayerSavedFlagIfSolo()
        SyncGamepadOffsetForPlayerCount(false)
        if IsPlayer2Active() then
            ApplyScreenModeInternal(CurrentScreenMode, true)
        end
        LocalizeAllPlayerUILayouts()
    end)
end

InstallRuntimeHooks = function()
    -- 1. Map / Controller Restart Lifecycle
    TryRegisterNativeHook("/Script/Engine.PlayerController:ClientRestart", function(Context)
        if SpawningPlayer2InProgress or CharacterSwapInProgress then return end
        ExecuteWithDelay(150, function()
            ExecuteInGameThread(function()
                if SpawningPlayer2InProgress or CharacterSwapInProgress then return end
                InCutsceneFullscreen = false
                SavedPreCutsceneMode = nil
                if not P2Menu.IsOpen() then
                    P2Menu.OnWorldOrControllersChanged()
                end
                InstallRuntimeHooks()
                InitEngineSettings()
                CachePlayerControllers()
                if IsPlayer2Active() and IsLiveWorldObject(PlayerControllerTable[1]) then
                    ApplyFullPlayer2Setup(PlayerControllerTable[1], PlayerControllerTable[2])
                    EnforceSinglePlayer2Instance()
                end
            end)
        end)
    end)

    -- 2. Async Cosmetic Application -> Re-apply Player 2 Full-Body Visuals
    local function OnCosmeticsAppliedPost(Context)
        if SpawningPlayer2InProgress then return end
        pcall(function()
            local comp = Context:get()
            if not IsLiveWorldObject(comp) then return end
            local owner = comp:GetOwner()
            if not IsLiveWorldObject(owner) then return end

            ExecuteInGameThread(function()
                if SpawningPlayer2InProgress then return end
                CachePlayerControllers()
                if IsPlayer2Active() and SameUObject(PlayerControllerTable[2].Pawn, owner) then
                    CustomizePlayer2Visuals(owner)
                end
            end)
        end)
    end
    TryRegisterScriptHook("/Script/Pagoda.PagodaPlayerCosmeticComponent:OnCosmeticsApplied", OnCosmeticsAppliedPost)
    TryRegisterScriptHook("/Game/Pagoda/Characters/Player/Components/BPC_PlayerCosmeticComponent.BPC_PlayerCosmeticComponent_C:OnCosmeticsApplied", OnCosmeticsAppliedPost)
    TryRegisterScriptHook("/Game/Pagoda/UI/Cosmetics/WBP_Cosmetics_Main.WBP_Cosmetics_Main_C:BP_OnDeactivated", function()
        ExecuteWithDelay(100, function()
            ExecuteInGameThread(function()
                CachePlayerControllers()
                if IsPlayer2Active() and IsLiveWorldObject(PlayerControllerTable[1]) and IsLiveWorldObject(PlayerControllerTable[2].Pawn) then
                    ApplyPlayer2OutfitFromState(PlayerControllerTable[1], PlayerControllerTable[2], PlayerControllerTable[2].Pawn)
                    CustomizePlayer2Visuals(PlayerControllerTable[2].Pawn)
                end
            end)
        end)
    end)

    -- 3. Dive Bar Wardrobe & Skill Tree Station Interception for Player 2
    TryRegisterScriptHook(
        "/Game/Pagoda/Levels/DiveBar/BP_DiveBar_Interact_Cosmetics.BP_DiveBar_Interact_Cosmetics_C:Interact",
        function(Context)
            if Config.InterceptDiveBarStationsForP2 == false then return end
            local station = nil
            pcall(function() station = Context:get() end)
            if DidPlayer2TriggerStation(station) then
                ExecuteWithDelay(35, function()
                    ExecuteInGameThread(function()
                        -- Close WBP_Cosmetics_Main_C if P2's Interact accidentally opened it on P1's screen
                        local menus = FindAllOf("WBP_Cosmetics_Main_C")
                        if menus then
                            for _, m in pairs(menus) do
                                if IsLiveWorldObject(m) then
                                    local okA, act = pcall(function() return m:IsActivated() end)
                                    if okA and act then pcall(function() m:DeactivateWidget() end) end
                                end
                            end
                        end
                        RestoreInputForAllPlayers()
                        P2Menu.Open(1)
                    end)
                end)
            end
        end
    )

    TryRegisterScriptHook(
        "/Game/Pagoda/Levels/DiveBar/BP_DiveBar_Interact_SkillTree.BP_DiveBar_Interact_SkillTree_C:Interact",
        function(Context)
            if Config.InterceptDiveBarStationsForP2 == false then return end
            local station = nil
            pcall(function() station = Context:get() end)
            if DidPlayer2TriggerStation(station) then
                ExecuteWithDelay(35, function()
                    ExecuteInGameThread(function()
                        local menus = FindAllOf("WBP_SkillTree_Main_C")
                        if menus then
                            for _, m in pairs(menus) do
                                if IsLiveWorldObject(m) then
                                    local okA, act = pcall(function() return m:IsActivated() end)
                                    if okA and act then pcall(function() m:DeactivateWidget() end) end
                                end
                            end
                        end
                        RestoreInputForAllPlayers()
                        P2Menu.Open(3)
                    end)
                end)
            end
        end
    )

    -- 4. Pause Menu Routing & Input Soft-Lock Fix
    TryRegisterScriptHook(
        "/Game/Pagoda/UI/BPFL_UI.BPFL_UI_C:PushToGameUIStack",
        function()
            ExecuteWithDelay(20, function()
                ExecuteInGameThread(function()
                    if Config.RoutePauseMenuToPrimaryViewport ~= false then
                        DeactivateOrphanPlayer2PauseMenus()
                    end
                    LocalizeAllPlayerUILayouts()
                end)
            end)
        end
    )

    TryRegisterNativeHook("/Script/Pagoda.PagodaGamePauseSubsystem:SetIsPaused", nil, function()
        ExecuteWithDelay(25, function()
            ExecuteInGameThread(function()
                if IsGamePausedNow() then
                    if P2Menu.IsOpen() then
                        P2Menu.Close()
                    end
                    if Config.RoutePauseMenuToPrimaryViewport ~= false then
                        DeactivateOrphanPlayer2PauseMenus()
                    end
                else
                    pcall(function()
                        local pauseMenus = FindAllOf("WBP_PauseMenu_Main_C")
                        if pauseMenus then
                            for _, pm in pairs(pauseMenus) do
                                if IsLiveWorldObject(pm) then
                                    local okAct, isAct = pcall(function() return pm:IsActivated() end)
                                    if okAct and isAct then
                                        pm.bResumeGameOnDeactivation = false
                                        pm.bShowCountdownOnDeactivate = false
                                        pm:DeactivateWidget()
                                    end
                                end
                            end
                        end
                    end)
                    RestoreInputForAllPlayers()
                end
            end)
        end)
    end)

    TryRegisterScriptHook("/Game/Pagoda/UI/Game/WBP_PauseMenu_Main.WBP_PauseMenu_Main_C:HandleCountdownComplete", function()
        ExecuteInGameThread(RestoreInputForAllPlayers)
    end)

    TryRegisterScriptHook("/Game/Pagoda/UI/Game/WBP_PauseMenu_Main.WBP_PauseMenu_Main_C:HandleResumeGame", function(Context)
        local pm = nil
        pcall(function() pm = Context:get() end)
        local hasCountdown = false
        if IsValidObj(pm) then
            pcall(function() hasCountdown = (pm.bShowCountdownOnDeactivate == true) end)
        end
        if not hasCountdown then
            ExecuteWithDelay(60, function()
                ExecuteInGameThread(function()
                    local pauseSub = FindFirstOf("PagodaGamePauseSubsystem")
                    if IsValidObj(pauseSub) and pauseSub:IsPaused() then
                        pauseSub:SetIsPaused(false)
                    end
                end)
            end)
        end
    end)

    -- 5. Automatic Cutscene / Cinematic Viewport Switching
    TryRegisterNativeHook("/Script/Engine.PlayerController:SetCinematicMode", nil, function(Context, bInCinematicMode)
        pcall(function()
            local enabled = bInCinematicMode and bInCinematicMode:get()
            ExecuteInGameThread(function()
                if enabled == true then
                    EnterCutsceneFullscreen("PlayerController:SetCinematicMode")
                elseif enabled == false then
                    ExitCutsceneFullscreen("PlayerController:SetCinematicMode(false)")
                end
            end)
        end)
    end)

    TryRegisterNativeHook("/Script/Engine.PlayerController:SetViewTargetWithBlend", nil, function(Context, NewViewTarget)
        pcall(function()
            local pc = Context:get()
            local vt = NewViewTarget and NewViewTarget:get()
            if not (IsLiveWorldObject(pc) and IsLiveWorldObject(vt)) then return end
            if GetControllerPlayerId(pc) ~= 0 then return end

            local vtName = vt:GetFullName()
            if vtName:find("CineCameraActor", 1, true)
                and not vtName:find("Level_MainMenu", 1, true)
                and not vtName:find("ModelRenderer", 1, true)
                and not vtName:find("ModelViewer", 1, true) then
                ExecuteInGameThread(function()
                    EnterCutsceneFullscreen("CineCameraActor")
                end)
            elseif vtName:find("PagodaPlayerCharacter", 1, true) and InCutsceneFullscreen then
                ExecuteInGameThread(function()
                    if not IsAnyCutsceneStillActive() then
                        ExitCutsceneFullscreen("ViewTarget->PlayerCharacter")
                    end
                end)
            end
        end)
    end)

    for _, enterPath in ipairs({
        "/Game/Pagoda/Gameplay/BP_LevelSequenceDirector_Base.BP_LevelSequenceDirector_Base_C:SetCinematicMode",
        "/Game/Pagoda/Gameplay/BP_LevelSequenceDirector_Base.BP_LevelSequenceDirector_Base_C:SetCinematicModeByTag",
        "/Game/Pagoda/Gameplay/GameplaySegments/GA_GS_LevelIntro_Base.GA_GS_LevelIntro_Base_C:K2_ActivateAbilityWithPagodaParams",
        "/Game/Pagoda/UI/BPFL_UI.BPFL_UI_C:PushCutsceneToUIStack",
        "/Game/Pagoda/UI/Cutscenes/WBP_CutsceneVideoContainer.WBP_CutsceneVideoContainer_C:BP_OnActivated",
        "/Game/Pagoda/UI/Cutscenes/BP_BossCardVideoPlayer.BP_BossCardVideoPlayer_C:PushCutsceneWidget",
    }) do
        TryRegisterScriptHook(enterPath, function()
            ExecuteInGameThread(function() EnterCutsceneFullscreen(enterPath) end)
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
        TryRegisterScriptHook(exitPath, function()
            ExecuteInGameThread(function()
                if not IsAnyCutsceneStillActive() then
                    ExitCutsceneFullscreen(exitPath)
                end
            end)
        end)
    end

    -- 6. Per-Player Viewport HUD & Menu Localization
    TryRegisterNativeHook("/Script/UMG.UserWidget:AddToViewport", nil, function(Context, ZOrder)
        if RehostingWidgetGuard or SpawningPlayer2InProgress or Config.LocalizePlayerViewports == false then return end
        pcall(function()
            local widget = Context:get()
            local z = (ZOrder and ZOrder:get()) or 0
            if IsLiveWorldObject(widget) and IsSplitScreenActive() then
                ExecuteInGameThread(function()
                    if SpawningPlayer2InProgress then return end
                    ConfineWidgetToOwningPlayerScreen(widget, z)
                end)
            end
        end)
    end)

    for _, layoutHook in ipairs({
        "/Script/Pagoda.PagodaActivatableWidget:OnPushToContainer",
        "/Script/Pagoda.PagodaActivatableWidget:OnAddNonInteractiveHUDElement",
        "/Game/Pagoda/UI/Game/UI_Layout_Game.UI_Layout_Game_C:Construct",
        "/Game/Pagoda/UI/Game/UI_Layout_Game.UI_Layout_Game_C:PushToStack",
        "/Game/Pagoda/UI/Game/UI_Layout_HubArea.UI_Layout_HubArea_C:OnPushToContainer",
    }) do
        TryRegisterScriptHook(layoutHook, function()
            if SpawningPlayer2InProgress then return end
            ExecuteInGameThread(function()
                if SpawningPlayer2InProgress then return end
                LocalizeAllPlayerUILayouts()
            end)
        end)
    end

    -- 7. Gamepad AnyKey Listener on Pagoda PlayerControllers
    TryRegisterScriptHook(
        "/Game/Pagoda/Characters/Player/BP_PagodaPlayerController.BP_PagodaPlayerController_C:InpActEvt_AnyKey_K2Node_InputKeyEvent_0",
        function(Context, KeyParam)
            pcall(function()
                local pc = Context:get()
                local ks = (KeyParam and KeyParam:get()) or KeyParam
                local keyName = (ks and ks.KeyName and ks.KeyName:ToString()) or ""
                if keyName:find("^Gamepad_") then
                    EvaluateGamepadShortcutsForController(pc, keyName)
                    if keyName == "Gamepad_LeftThumbstick"
                        or keyName == "Gamepad_RightThumbstick"
                        or keyName == "Gamepad_Special_Left" then
                        ExecuteWithDelay(160, function()
                            ExecuteInGameThread(function()
                                if IsLiveWorldObject(pc) then
                                    EvaluateGamepadShortcutsForController(pc, nil)
                                end
                            end)
                        end)
                    end
                end
            end)
        end
    )
end

pcall(function()
    NotifyOnNewObject("/Script/Pagoda.PagodaUILayoutWidget", function(obj)
        ExecuteInGameThread(function()
            InstallRuntimeHooks()
            RefreshLayoutWidgetLocalization(obj)
        end)
    end)
    NotifyOnNewObject("/Script/Pagoda.PagodaPlayerController", function()
        ExecuteInGameThread(InstallRuntimeHooks)
    end)
    NotifyOnNewObject("/Script/Engine.LevelSequenceActor", function()
        ExecuteInGameThread(InstallRuntimeHooks)
    end)
    NotifyOnNewObject("/Game/Pagoda/Levels/DiveBar/BP_DiveBar_Interact_Cosmetics.BP_DiveBar_Interact_Cosmetics_C", function()
        ExecuteInGameThread(InstallRuntimeHooks)
    end)
    NotifyOnNewObject("/Game/Pagoda/Levels/DiveBar/BP_DiveBar_Interact_SkillTree.BP_DiveBar_Interact_SkillTree_C", function()
        ExecuteInGameThread(InstallRuntimeHooks)
    end)
end)

-- ============================================================================
-- BACKGROUND WATCHDOG (SINGLETON GUARD, CUTSCENE RECOVERY & AUTO-LEASH)
-- ============================================================================

LoopAsync(1000, function()
    ExecuteInGameThread(function()
        pcall(function()
            if not SpawningPlayer2InProgress then
                EnforceSinglePlayer2Instance()
            end
            CachePlayerControllers()

            -- 1. Cutscene Fullscreen Safety Watchdog
            if InCutsceneFullscreen then
                if not IsGameplayWorld() or not IsPlayer2Active() then
                    ExitCutsceneFullscreen("Watchdog:WorldOrP2Changed")
                elseif not IsAnyCutsceneStillActive() then
                    CutsceneIdleChecks = CutsceneIdleChecks + 1
                    if CutsceneIdleChecks >= 2 then
                        ExitCutsceneFullscreen("Watchdog:CutsceneFinished")
                    end
                else
                    CutsceneIdleChecks = 0
                end
            end

            -- 2. Shared-Screen Auto-Leash
            local effectiveShared = (CurrentScreenMode == 2) and not InCutsceneFullscreen
            if AutoLeashActive and effectiveShared and IsPlayer2Active() then
                local P1Pawn = PlayerControllerTable[1] and PlayerControllerTable[1].Pawn
                local P2Pawn = PlayerControllerTable[2] and PlayerControllerTable[2].Pawn

                if IsLiveWorldObject(P1Pawn) and IsLiveWorldObject(P2Pawn) then
                    local Loc1 = P1Pawn:K2_GetActorLocation()
                    local Loc2 = P2Pawn:K2_GetActorLocation()

                    local DX = Loc1.X - Loc2.X
                    local DY = Loc1.Y - Loc2.Y
                    local DZ = Loc1.Z - Loc2.Z
                    local DistSquared = DX * DX + DY * DY + DZ * DZ
                    local MaxDist = Config.MaxDistance or 2500.0

                    if DistSquared > (MaxDist * MaxDist) or DZ > (Config.MaxZDifference or 600.0) then
                        local TargetLoc = P1Pawn:K2_GetActorLocation()
                        TargetLoc.X = TargetLoc.X + 100.0
                        local TargetRot = P1Pawn:K2_GetActorRotation()
                        P2Pawn:K2_SetActorLocationAndRotation(TargetLoc, TargetRot, false, {}, false)
                        print("[Local Co-op] Auto-leashed Player 2 back to arena.\n")
                    end
                end
            end
        end)
    end)
    return false
end)

-- ============================================================================
-- INITIALIZATION & KEYBINDINGS
-- ============================================================================

InstallRuntimeHooks()
InitEngineSettings()

-- Original Core Hotkeys (Preserved 100%)
RegisterKeyBind(Key.F5, ToggleGamepadOffset)
RegisterKeyBind(Key.F6, SpawnPlayer2)
RegisterKeyBind(Key.F7, RemovePlayer2)
RegisterKeyBind(Key.F8, TeleportPlayer2)
RegisterKeyBind(Key.F9, CycleScreenMode)
RegisterKeyBind(Key.F11, ToggleAutoLeash)

-- Original Ctrl Secondary Shortcuts (Preserved 100%)
RegisterKeyBind(Key.Y, { ModifierKey.CONTROL }, SpawnPlayer2)
RegisterKeyBind(Key.U, { ModifierKey.CONTROL }, RemovePlayer2)
RegisterKeyBind(Key.I, { ModifierKey.CONTROL }, TeleportPlayer2)
RegisterKeyBind(Key.P, { ModifierKey.CONTROL }, CycleScreenMode)

-- Player 2 Interactive Custom Menu & Quick-Cycle Shortcuts
RegisterKeyBind(Key.F2, OpenOrToggleP2MenuOutfits)
RegisterKeyBind(Key.F3, OpenOrToggleP2MenuSkills)
RegisterKeyBind(Key.F2, { ModifierKey.SHIFT }, CyclePlayer2OutfitPreset)
RegisterKeyBind(Key.F3, { ModifierKey.SHIFT }, CyclePlayer2LoadoutPreset)
RegisterKeyBind(Key.F4, SwapPlayer2Character)
RegisterKeyBind(Key.F4, { ModifierKey.SHIFT }, CyclePlayer2TintMode)

RegisterKeyBind(Key.OEM_FOUR, { ModifierKey.CONTROL }, OpenOrToggleP2MenuOutfits)   -- Ctrl + [
RegisterKeyBind(Key.OEM_SIX,  { ModifierKey.CONTROL }, OpenOrToggleP2MenuSkills)    -- Ctrl + ]
RegisterKeyBind(Key.OEM_FIVE, { ModifierKey.CONTROL }, SwapPlayer2Character)        -- Ctrl + \

-- Expose lightweight API handle for external mod interop
_G.__LocalCoopMod = {
    SpawnPlayer2 = SpawnPlayer2,
    RemovePlayer2 = RemovePlayer2,
    SwapPlayer2Character = SwapPlayer2Character,
    IsPlayer2Active = function() CachePlayerControllers(); return IsPlayer2Active() end,
    IsLiveWorldObject = IsLiveWorldObject,
    EnforceSinglePlayer2Instance = EnforceSinglePlayer2Instance,
    P2Menu = P2Menu,
    CoopMenuAPI = CoopMenuAPI,
    TryOpenDiveBarStationForPlayer2 = TryOpenDiveBarStationForPlayer2,
}

print("[Dead as Disco - Local Co-op Mod] v2.1 Loaded successfully!\n")
print("  [Gamepad L3+R3]  : Connect / Regroup Player 2 from Controller\n")
print("  [P2 Select/View] : Open Interactive P2 Skins & Skills Studio Menu (or Interact at Dive Bar Stations)\n")
print("  [F2] / [F3]      : Open P2 Custom Menu on Outfits [F2] or Boss Skills [F3]\n")
print("  [Shift+F2/F3]    : Quick-Cycle P2 Outfit / Skill Preset\n")
print("  [F4] / [Shift+F4]: Swap P2 Character (Charlie/Chuckles) / Cycle Tint Mode\n")
print("  [F5]             : Toggle Controller Setup (1 KB + 1 Pad vs 2 Pads)\n")
print("  [F6] / [Ctrl+Y]  : Spawn / Regroup Player 2 (Singleton-Locked)\n")
print("  [F7] / [Ctrl+U]  : Remove Player 2\n")
print("  [F8] / [Ctrl+I]  : Teleport Player 2 to Player 1\n")
print("  [F9] / [Ctrl+P]  : Cycle Screen Mode (Horizontal -> Vertical -> Shared)\n")
print("  [F11]            : Toggle Auto-Leashing on/off\n")
