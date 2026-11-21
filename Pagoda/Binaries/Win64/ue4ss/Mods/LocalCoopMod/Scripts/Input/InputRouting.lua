-- ============================================================================
-- INPUT ROUTING, STRICT L3+R3 JOIN, PAUSE MENU GAMEPAD BRIDGE & STATIONS
-- ============================================================================
-- * Routes controller 0 vs 1 cleanly (1 KB+M + 1 Pad vs 2 Pads).
-- * Strict Simultaneous L3+R3 (or F6) for P2 join — zero accidental sprint +
--   lock-on triggers and no unintended mid-combat regrouping.
-- * Full Pause Menu Gamepad Bridge so gamepads — even when assigned to Player 2
--   in 1 KB+M + 1 Pad OR 2-Pad mode — can navigate, confirm, adjust settings,
--   switch tabs, back out, and resume Dead as Disco's native Pause Menu.
-- * Uses APagodaPlayerController:SetDisableAllInputsReason(FGameplayTag, bool)
--   to lock P2's gameplay inputs cleanly during P2 Menu or Downed state.
-- ============================================================================

local UObjectUtils = require("Utils.UObjectUtils")
local Logger = require("Utils.Logger")
local Scheduler = require("Core.Scheduler")
local SessionManager = require("Core.SessionManager")
local ViewportController = require("Camera.ViewportController")

local InputRouting = {}

local Config = {}
local Callbacks = {}

InputRouting.OffsetGamepad = true
InputRouting.LastP2InputTime = 0.0

local ActiveInputLocks = { [0] = {}, [1] = {} }
local RecentKeys = {}
local LastChordTime = 0.0
local RedirectingPause = false
local PauseOpenedAt = 0.0
local WasPausedLastTick = false
local PrevPauseEscDown = false
local PrevPauseStartDown = false
local LastManualOffsetToggle = 0.0
local LastP2GamepadWhileUnOffset = 0.0
local LastFocusedSubWidgetKey = nil
local LastResumeRequestedAt = 0.0
local LastPauseBackAt = 0.0
local CachedPauseSub = nil
local WasNativeMenuOpen = false
local LastNativeMenuTopKey = nil
local MenuOffsetSuppressed = false
local CachedOrderedLayouts = nil
local CachedOrderedP1Count = 0
local CachedLayoutsAt = -1.0
local CachedNativeMenuOpen = false
local CachedNativeMenuOpenAt = -1.0

-- Strict simultaneous L3+R3 join state (no RecentKeys tolerance)
local JoinHoldStart = nil
local JoinTriggeredWhileHeld = false
local LastReportedJoinProgress = 0.0

-- Pause Menu Gamepad Bridge state (for P2 gamepad control)
local PausePrevInputs = {}
local PauseHoldRepeat = {}
local PauseActiveWidgetKey = nil
local PauseFocusedIndex = 1
local LastPauseNavTime = 0.0

local KB_DETECT_KEYS = {
    "W", "A", "S", "D", "SpaceBar", "LeftShift", "E", "Q",
    "LeftMouseButton", "RightMouseButton", "Up", "Down", "Left", "Right",
}
local CachedKeyStructs = {}

local function GetKeyStruct(kn)
    local ks = CachedKeyStructs[kn]
    if not ks then
        ks = { KeyName = FName(kn) }
        CachedKeyStructs[kn] = ks
    end
    return ks
end

function InputRouting.Init(config, callbacks)
    Config = config or {}
    Callbacks = callbacks or {}
    local inCfg = Config.Input or {}
    InputRouting.OffsetGamepad = (inCfg.OffsetGamepad ~= false)
end

-- ============================================================================
-- NATIVE PER-PLAYER INPUT LOCKS (NO P1 IMPACT, HARDWARE READS STAY INTACT)
-- ============================================================================

function InputRouting.HasAnyInputLock(pid)
    local map = ActiveInputLocks[pid]
    if not map then return false end
    for _, v in pairs(map) do
        if v then return true end
    end
    return false
end

function InputRouting.SetPlayerInputLock(pc, reasonTagStr, locked)
    if not UObjectUtils.IsLive(pc) then return false end
    local pid = SessionManager.GetPlayerIndex(pc)
    local lockMap = (pid ~= nil) and ActiveInputLocks[pid] or nil
    local wasLocked = (lockMap ~= nil) and InputRouting.HasAnyInputLock(pid) or false
    local prevReason = (lockMap ~= nil) and (lockMap[reasonTagStr] == true) or false
    if lockMap then
        lockMap[reasonTagStr] = locked and true or nil
    end

    local stillLocked = (lockMap ~= nil) and InputRouting.HasAnyInputLock(pid) or (locked == true)
    local tagStruct = UObjectUtils.MakeTagFromString(reasonTagStr)
    local okNative = (prevReason ~= (locked == true)) and false or true

    if tagStruct and (prevReason ~= (locked == true) or not wasLocked) then
        local okCall, errCall = pcall(function()
            pc:SetDisableAllInputsReason(tagStruct, locked == true)
        end)
        if okCall then
            okNative = true
        else
            Logger.Missing("InputRouting", "PagodaPlayerController:SetDisableAllInputsReason", tostring(errCall))
        end
    end

    pcall(function()
        if stillLocked then
            -- Guard against uint8 IgnoreMoveInput/IgnoreLookInput counter wrap-around
            local moveIgnored = false
            pcall(function() moveIgnored = (pc:IsMoveInputIgnored() == true) end)
            if (not wasLocked) or (not moveIgnored) then
                pc:SetIgnoreMoveInput(true)
            end
            local lookIgnored = false
            pcall(function() lookIgnored = (pc:IsLookInputIgnored() == true) end)
            if (not wasLocked) or (not lookIgnored) then
                pc:SetIgnoreLookInput(true)
            end
            if UObjectUtils.IsLive(pc.Pawn) and UObjectUtils.IsValid(pc.Pawn.CharacterMovement) then
                pc.Pawn.CharacterMovement:StopMovementImmediately()
            end
        elseif wasLocked or not okNative then
            pc:ResetIgnoreInputFlags()
            if UObjectUtils.IsLive(pc.Pawn) then pc.Pawn:EnableInput(pc) end
        end
    end)
    return okNative
end

function InputRouting.ClearAllLocksForPlayer(pid, pc)
    local map = ActiveInputLocks[pid]
    if not map then return end
    local reasons = {}
    for k, v in pairs(map) do
        if v then reasons[#reasons + 1] = k end
    end
    for _, reason in ipairs(reasons) do
        if UObjectUtils.IsLive(pc) then
            InputRouting.SetPlayerInputLock(pc, reason, false)
        else
            map[reason] = nil
        end
    end
end

function InputRouting.ResetAllLocks()
    ActiveInputLocks = { [0] = {}, [1] = {} }
end

-- ============================================================================
-- GAMEPAD OFFSET ROUTING (1 KB+M + 1 PAD vs 2 PADS)
-- ============================================================================

function InputRouting.ApplyGamepadOffsetBeforeSpawn()
    pcall(function()
        local maps = UObjectUtils.GetGameMapsSettings()
        if maps then
            maps.bOffsetPlayerGamepadIds = (InputRouting.OffsetGamepad == true)
        end
    end)
end

function InputRouting.SyncGamepadOffset(announce)
    pcall(function()
        local maps = UObjectUtils.GetGameMapsSettings()
        if not maps then return end
        local p2MenuOpen = Callbacks.IsP2MenuOpen and Callbacks.IsP2MenuOpen() or false
        local nativeMenuOpen = InputRouting.IsAnyNativeMenuOpen()

        -- In native menus (Main Menu, Pause, Settings, Song Select, Dive Bar stations),
        -- route Gamepad 0 natively through CommonUI/Slate alongside KB+M & mouse cursor.
        if nativeMenuOpen and not p2MenuOpen then
            maps.bOffsetPlayerGamepadIds = false
            MenuOffsetSuppressed = true
        else
            MenuOffsetSuppressed = false
            local effective = SessionManager.IsP2Active() and (InputRouting.OffsetGamepad == true) or false
            maps.bOffsetPlayerGamepadIds = effective
        end

        if announce and Callbacks.Notify then
            Callbacks.Notify(
                InputRouting.OffsetGamepad
                    and "Controllers: 1 KB/Mouse (P1) + 1 Gamepad (P2)"
                    or  "Controllers: 2 Gamepads (Pad 1 = P1, Pad 2 = P2)",
                "Info"
            )
        end
    end)
end

function InputRouting.ToggleGamepadOffset()
    if not UObjectUtils.CanTrigger("ToggleGamepadOffset", 0.25) then return end
    LastManualOffsetToggle = os.clock()
    InputRouting.OffsetGamepad = not InputRouting.OffsetGamepad
    Scheduler.RunOnGameThread("SyncGamepadOffset", function()
        InputRouting.SyncGamepadOffset(true)
    end)
end

function InputRouting.TickAutoGamepadRouting(now)
    local inCfg = Config.Input or {}
    if inCfg.AutoOffsetGamepadOnKeyboard == false then return end
    if InputRouting.OffsetGamepad == true then return end
    if InputRouting.IsGamePaused() or not SessionManager.IsSafeForGameplayHooks() then return end
    if (now - LastManualOffsetToggle) < 4.0 then return end
    if LastP2GamepadWhileUnOffset > 0.0 and (now - LastP2GamepadWhileUnOffset) < 15.0 then return end

    local p1 = SessionManager.GetP1()
    if not p1 then return end

    local kbOrMouseActive = false
    pcall(function()
        local okM, rx, ry = pcall(function() return p1:GetInputMouseDelta() end)
        if okM and type(rx) == "number" and type(ry) == "number" and (math.abs(rx) + math.abs(ry)) > 0.35 then
            kbOrMouseActive = true
            return
        end
        for _, kn in ipairs(KB_DETECT_KEYS) do
            local okK, down = pcall(function() return p1:IsInputKeyDown(GetKeyStruct(kn)) end)
            if okK and down == true then
                kbOrMouseActive = true
                return
            end
        end
    end)

    if kbOrMouseActive then
        InputRouting.OffsetGamepad = true
        InputRouting.SyncGamepadOffset(false)
        Logger.Info("InputRouting", "Keyboard/Mouse active with single pad -> defaulted gamepad to Player 2.")
    end
end

-- ============================================================================
-- STRICT SIMULTANEOUS L3 + R3 P2 JOIN (ZERO ACCIDENTAL SPRINT/LOCK-ON JOINS)
-- ============================================================================

local function ReportJoinProgress(frac)
    if math.abs(frac - LastReportedJoinProgress) > 0.01 then
        LastReportedJoinProgress = frac
        if type(Callbacks.OnJoinHoldProgress) == "function" then
            UObjectUtils.SafeCall("Input.JoinProgress", Callbacks.OnJoinHoldProgress, frac)
        end
    end
end

function InputRouting.TickJoinChord(now)
    local inCfg = Config.Input or {}
    if inCfg.EnableGamepadShortcuts == false then
        JoinHoldStart = nil
        JoinTriggeredWhileHeld = false
        ReportJoinProgress(0.0)
        return
    end

    -- Once P2 is connected, L3+R3 will NEVER trigger accidental combat regrouping
    -- (use P2 Menu -> Settings to regroup).
    if SessionManager.IsP2Active()
        or InputRouting.IsGamePaused()
        or not SessionManager.IsSafeForGameplayHooks()
        or SessionManager.State.IsInCutscene
        or (Callbacks.IsP2MenuOpen and Callbacks.IsP2MenuOpen())
        or not UObjectUtils.IsGameplayWorld() then
        JoinHoldStart = nil
        JoinTriggeredWhileHeld = false
        ReportJoinProgress(0.0)
        return
    end

    local keys = inCfg.GamepadJoinChord or { "Gamepad_LeftThumbstick", "Gamepad_RightThumbstick" }
    local chordDown = false
    for pid = 0, 1 do
        local pc = SessionManager.GetController(pid)
        if pc then
            local allDown = true
            for _, kn in ipairs(keys) do
                local ok, down = pcall(function() return pc:IsInputKeyDown(GetKeyStruct(kn)) end)
                if not (ok and down == true) then
                    allDown = false
                    break
                end
            end
            if allDown then
                chordDown = true
                break
            end
        end
    end

    if chordDown then
        if not JoinTriggeredWhileHeld then
            JoinHoldStart = JoinHoldStart or now
            local holdReq = math.max(0.04, tonumber(inCfg.GamepadJoinHoldSeconds) or 0.12)
            local frac = math.min(1.0, (now - JoinHoldStart) / holdReq)
            ReportJoinProgress(frac)

            if (now - JoinHoldStart) >= holdReq and (now - LastChordTime) >= (inCfg.GamepadChordCooldown or 0.65) then
                JoinTriggeredWhileHeld = true
                LastChordTime = now
                ReportJoinProgress(0.0)
                Logger.Info("InputRouting", "Simultaneous L3+R3 detected -> connecting Player 2.")
                Scheduler.Delay(20, "Chord.JoinStrict", SessionManager.SpawnOrRegroupP2)
            end
        end
    else
        JoinHoldStart = nil
        JoinTriggeredWhileHeld = false
        ReportJoinProgress(0.0)
    end
end

-- ============================================================================
-- PAUSE MENU SAFETY & FULL GAMEPAD PAUSE MENU BRIDGE
-- ============================================================================

function InputRouting.IsGamePaused()
    if not UObjectUtils.IsValid(CachedPauseSub) then
        pcall(function() CachedPauseSub = FindFirstOf("PagodaGamePauseSubsystem") end)
    end
    if UObjectUtils.IsValid(CachedPauseSub) then
        local ok, p = pcall(function() return CachedPauseSub:IsPaused() end)
        return ok and p == true
    end
    return false
end

function InputRouting.RestoreInputForAllPlayers()
    if InputRouting.IsAnyNativeMenuOpen() or not UObjectUtils.IsGameplayWorld() then return end
    local p2MenuOpen = Callbacks.IsP2MenuOpen and Callbacks.IsP2MenuOpen() or false
    local pausedByP2Menu = Callbacks.IsPausedByP2Menu and Callbacks.IsPausedByP2Menu() or false
    if pausedByP2Menu then return end

    pcall(function()
        SessionManager.RefreshControllers()
        local wbl = UObjectUtils.GetWidgetBlueprintLibrary()

        for pid = 0, 1 do
            local pc = SessionManager.GetController(pid)
            if pc then
                pcall(function() pc.bShowMouseCursor = false end)
                if wbl then pcall(function() wbl:SetInputMode_GameOnly(pc) end) end
                local isLocked = InputRouting.HasAnyInputLock(pid) or (pid == 1 and p2MenuOpen)
                if not ViewportController.InCutsceneFullscreen and not isLocked then
                    pcall(function() pc:ResetIgnoreInputFlags() end)
                    local pawn = SessionManager.GetPawn(pid)
                    if pawn then pcall(function() pawn:EnableInput(pc) end) end
                end
            end
        end

        if wbl then pcall(function() wbl:SetFocusToGameViewport() end) end
    end)
end

local function FindActivePauseMenus()
    local p1Menu, p2Menu = nil, nil
    pcall(function()
        local menus = FindAllOf("WBP_PauseMenu_Main_C")
        if not menus then return end
        for _, pm in pairs(menus) do
            if UObjectUtils.IsLive(pm) then
                local okA, act = pcall(function() return pm:IsActivated() end)
                local okV, vis = pcall(function() return pm:IsVisible() end)
                local okVP, inVP = pcall(function() return pm:IsInViewport() end)
                if (okA and act) or ((okV and vis) and (okVP and inVP)) then
                    local own = nil
                    pcall(function() own = pm:GetOwningPlayer() end)
                    local pid = SessionManager.GetPlayerIndex(own)
                    if pid == 0 then
                        p1Menu = pm
                    elseif pid ~= nil and pid > 0 then
                        p2Menu = pm
                    elseif not p1Menu then
                        p1Menu = pm
                    end
                end
            end
        end
    end)
    return p1Menu, p2Menu
end

function InputRouting.InvalidateMenuCache()
    CachedLayoutsAt = -1.0
    CachedNativeMenuOpenAt = -1.0
end

local function GetOrderedLayouts()
    local now = os.clock()
    if CachedOrderedLayouts and (now - CachedLayoutsAt) < 0.35 then
        local allValid = true
        for i = 1, #CachedOrderedLayouts do
            if not UObjectUtils.IsLive(CachedOrderedLayouts[i]) then
                allValid = false
                break
            end
        end
        if allValid then
            return CachedOrderedLayouts, CachedOrderedP1Count
        end
    end

    local ordered, otherLayouts = {}, {}
    pcall(function()
        local layouts = FindAllOf("PagodaUILayoutWidget")
        if not layouts then return end
        for _, lay in pairs(layouts) do
            if UObjectUtils.IsLive(lay) then
                local own = nil
                pcall(function() own = lay:GetOwningPlayer() end)
                if SessionManager.GetPlayerIndex(own) == 0 then
                    ordered[#ordered + 1] = lay
                else
                    otherLayouts[#otherLayouts + 1] = lay
                end
            end
        end
    end)
    local p1Count = #ordered
    for i = 1, #otherLayouts do
        ordered[#ordered + 1] = otherLayouts[i]
    end
    CachedOrderedLayouts = ordered
    CachedOrderedP1Count = p1Count
    CachedLayoutsAt = now
    return ordered, p1Count
end

local function FindTopActiveStackWidget()
    local layouts, p1Count = GetOrderedLayouts()
    local fallbackW = nil
    pcall(function()
        for i, lay in ipairs(layouts) do
            if UObjectUtils.IsLive(lay) then
                for _, stackName in ipairs({ "ModalStack", "SystemMenuStack", "GameMenuStack" }) do
                    local st = nil
                    pcall(function() st = lay[stackName] end)
                    if UObjectUtils.IsValid(st) then
                        local activeW = nil
                        pcall(function() activeW = st:GetActiveWidget() end)
                        if UObjectUtils.IsLive(activeW) and InputRouting.IsWidgetVisiblyActive(activeW) then
                            if i <= p1Count then
                                fallbackW = activeW
                                return
                            elseif not fallbackW then
                                fallbackW = activeW
                            end
                        end
                    end
                end
            end
        end
    end)
    return fallbackW
end

function InputRouting.HasAnyActiveMenuOnStack()
    local hasMenu, isSubMenu, topW = false, false, nil
    local layouts, _ = GetOrderedLayouts()
    pcall(function()
        for _, lay in ipairs(layouts) do
            if UObjectUtils.IsLive(lay) then
                for _, stackName in ipairs({ "ModalStack", "SystemMenuStack", "GameMenuStack" }) do
                    local st = nil
                    pcall(function() st = lay[stackName] end)
                    if UObjectUtils.IsValid(st) then
                        local activeW = nil
                        pcall(function() activeW = st:GetActiveWidget() end)
                        if UObjectUtils.IsLive(activeW) and InputRouting.IsWidgetVisiblyActive(activeW) then
                            hasMenu = true
                            if not topW then topW = activeW end
                            local wName = ""
                            pcall(function() wName = activeW:GetFullName() end)
                            if not wName:find("WBP_PauseMenu_Main", 1, true) then
                                isSubMenu = true
                            end
                        end
                    end
                end
            end
        end
    end)
    return hasMenu, isSubMenu, topW
end

local NATIVE_MENU_WIDGETS = {
    "WBP_MainMenu_V2_C",
    "WBP_PauseMenu_Main_C",
    "WBP_PagodaSettings_V2_Main_C",
    "WBP_SongList_Main_C",
    "WBP_SongList_JukeBox_C",
    "WBP_InfiniteDiscoMenu_C",
    "WBP_InfiniteDisco_ModeSelect_C",
    "WBP_InfiniteDisco_ArenaSwap_Main_C",
    "WBP_LevelSelect_Projected_Main_C",
    "WBP_TowerPlayerDataModPicker_C",
    "WBP_Cosmetics_Main_C",
    "WBP_SkillTree_Main_C",
    "WBP_MoveList_Main_C",
    "WBP_Collectibles_Main_C",
    "WBP_Drumkit_Main_C",
    "WBP_LevelEndScreen_C",
}

function InputRouting.IsWidgetVisiblyActive(w)
    if not UObjectUtils.IsLive(w) then return false end
    local vis = 0
    pcall(function()
        local v = w:GetVisibility()
        if type(v) == "number" then vis = v end
    end)
    if vis == 1 or vis == 2 then return false end -- 1 = Collapsed, 2 = Hidden

    local op = 1.0
    pcall(function()
        local ro = w:GetRenderOpacity()
        if type(ro) == "number" then op = ro end
    end)
    if op <= 0.05 then return false end

    -- All Pagoda menus inherit from UCommonActivatableWidget (IsActivated).
    -- Pooled deactivated widgets remain inside the layout's viewport tree (IsInViewport() == true),
    -- so if IsActivated exists on the widget, we MUST require IsActivated() == true!
    local hasIsActivated = false
    local isAct = false
    pcall(function()
        if type(w.IsActivated) == "function" then
            hasIsActivated = true
            isAct = (w:IsActivated() == true)
        end
    end)
    if hasIsActivated then
        return isAct
    end

    local inVP, isVis = false, true
    pcall(function() inVP = (type(w.IsInViewport) == "function" and w:IsInViewport() == true) end)
    pcall(function()
        if type(w.IsVisible) == "function" then
            isVis = (w:IsVisible() == true)
        end
    end)
    return inVP and isVis
end

function InputRouting.IsAnyNativeMenuOpen()
    if not UObjectUtils.IsGameplayWorld() then return true end
    local pausedByP2Menu = Callbacks.IsPausedByP2Menu and Callbacks.IsPausedByP2Menu() or false
    if InputRouting.IsGamePaused() and not pausedByP2Menu then return true end

    local now = os.clock()
    if (now - CachedNativeMenuOpenAt) < 0.18 then
        return CachedNativeMenuOpen
    end

    if InputRouting.HasAnyActiveMenuOnStack() then
        CachedNativeMenuOpen = true
        CachedNativeMenuOpenAt = now
        return true
    end

    local found = false
    pcall(function()
        for _, clsName in ipairs(NATIVE_MENU_WIDGETS) do
            local list = FindAllOf(clsName)
            if list then
                for _, w in pairs(list) do
                    if InputRouting.IsWidgetVisiblyActive(w) then
                        found = true
                        return
                    end
                end
            end
        end
    end)
    CachedNativeMenuOpen = found
    CachedNativeMenuOpenAt = now
    return found
end
local function IsWidgetVisibleAndEnabled(w)
    if not UObjectUtils.IsLive(w) then return false end
    local vis = 0
    local okV, v = pcall(function() return w:GetVisibility() end)
    if okV and type(v) == "number" then vis = v end
    if vis == 1 or vis == 2 then return false end -- 1 = Collapsed, 2 = Hidden
    local enabled = true
    pcall(function() if w:GetIsEnabled() == false then enabled = false end end)
    return enabled
end

local function ClassifyInteractiveWidget(w)
    local clsName = ""
    pcall(function() clsName = w:GetClass():GetFName():ToString() end)

    local isCommonBtn = false
    if clsName:find("CommonButton", 1, true)
        or clsName:find("CUI_Button", 1, true)
        or clsName:find("C_UI_MenuButton", 1, true)
        or clsName:find("MenuButton", 1, true)
        or clsName:find("MainMenuButton", 1, true)
        or clsName:find("PauseMenuButton", 1, true)
        or clsName:find("ButtonBase", 1, true) then
        isCommonBtn = true
    else
        pcall(function()
            if type(w.HandleButtonClicked) == "function"
                or type(w.TriggerClick) == "function"
                or w.OnButtonBaseClicked ~= nil then
                isCommonBtn = true
            end
        end)
    end

    if isCommonBtn then
        -- Do NOT filter out CommonButtonBase on w.IsFocusable == false:
        -- CommonUI buttons inherit UUserWidget.IsFocusable == false while Slate SCommonButton holds focus.
        local interactive = true
        pcall(function() if w:GetIsEnabled() == false then interactive = false end end)
        pcall(function()
            if type(w.IsInteractionEnabled) == "function" and w:IsInteractionEnabled() == false then
                interactive = false
            end
        end)
        local isNav = (clsName:find("NavButton", 1, true) ~= nil) or (clsName:find("TabButton", 1, true) ~= nil)
        return "CommonButton", interactive, isNav
    end

    if clsName == "Button" then
        local interactive = true
        pcall(function() if w:GetIsEnabled() == false then interactive = false end end)
        return "UMGButton", interactive, false
    end

    if clsName:find("CommonRotator", 1, true) then
        return "Rotator", true, false
    end

    if clsName == "Slider" or clsName == "AnalogSlider" then
        return "Slider", true, false
    end

    return nil, false, false
end

local function FindSubRotatorOrSlider(root)
    local visited = {}
    local rot, slider = nil, nil
    local function scan(node, depth)
        if (rot and slider) or depth > 6 or not IsWidgetVisibleAndEnabled(node) then return end
        local key = UObjectUtils.GetKey(node)
        if not key or visited[key] then return end
        visited[key] = true

        local kind = ClassifyInteractiveWidget(node)
        if kind == "Rotator" and not rot then rot = node; return end
        if kind == "Slider" and not slider then slider = node; return end

        local wt = nil
        pcall(function() wt = node.WidgetTree end)
        if UObjectUtils.IsValid(wt) and UObjectUtils.IsLive(wt.RootWidget) then
            scan(wt.RootWidget, depth + 1)
        end
        pcall(function()
            if type(node.GetContent) == "function" then
                local c = node:GetContent()
                if UObjectUtils.IsLive(c) then scan(c, depth + 1) end
            end
        end)
        pcall(function()
            if type(node.GetChildrenCount) == "function" and type(node.GetChildAt) == "function" then
                local n = node:GetChildrenCount()
                for i = 0, n - 1 do
                    scan(node:GetChildAt(i), depth + 1)
                    if rot and slider then break end
                end
            end
        end)
    end
    scan(root, 0)
    return rot, slider
end

local function CollectInteractiveWidgets(rootWidget)
    local buttons = {}
    local navButtons = {}
    local visited = {}

    local function walk(w, depth, inNavBar)
        if depth > 14 or not IsWidgetVisibleAndEnabled(w) then return end
        local key = UObjectUtils.GetKey(w)
        if not key or visited[key] then return end
        visited[key] = true

        local clsName = ""
        pcall(function() clsName = w:GetClass():GetFName():ToString() end)
        local nowInNav = inNavBar or (clsName:find("NavBar", 1, true) ~= nil)

        local kind, interactive, isNavBtn = ClassifyInteractiveWidget(w)
        if kind == "CommonButton" or kind == "UMGButton" then
            if interactive then
                local entry = { Widget = w, Key = key, Kind = kind }
                if isNavBtn or nowInNav then
                    navButtons[#navButtons + 1] = entry
                else
                    buttons[#buttons + 1] = entry
                end
            end
            return -- Never recurse into internal UButton inside CommonButton/UMGButton
        end

        -- Switchers & Activatable Stacks: descend ONLY into the active child
        local handledContainer = false
        pcall(function()
            if type(w.GetActiveWidget) == "function" then
                handledContainer = true
                local act = w:GetActiveWidget()
                if UObjectUtils.IsLive(act) then
                    walk(act, depth + 1, nowInNav)
                end
            end
        end)
        if handledContainer then return end

        -- ListView / TileView displayed entries
        pcall(function()
            if type(w.GetDisplayedEntryWidgets) == "function" then
                local entries = w:GetDisplayedEntryWidgets()
                if entries then
                    UObjectUtils.ForEachObj(entries, function(itemW)
                        walk(itemW, depth + 1, nowInNav)
                    end)
                end
            end
        end)

        -- PanelWidget children
        local childCount = nil
        pcall(function()
            if type(w.GetChildrenCount) == "function" then
                childCount = w:GetChildrenCount()
            end
        end)
        if type(childCount) == "number" and childCount > 0 then
            for i = 0, childCount - 1 do
                local ch = nil
                pcall(function() ch = w:GetChildAt(i) end)
                if UObjectUtils.IsLive(ch) then
                    walk(ch, depth + 1, nowInNav)
                end
            end
            return
        end

        -- ContentWidget (Border / SizeBox / ScaleBox / ButtonBase)
        local content = nil
        pcall(function()
            if type(w.GetContent) == "function" then
                content = w:GetContent()
            end
        end)
        if UObjectUtils.IsLive(content) then
            walk(content, depth + 1, nowInNav)
        end

        -- Embedded UserWidget WidgetTree
        local wt = nil
        pcall(function() wt = w.WidgetTree end)
        if UObjectUtils.IsValid(wt) and UObjectUtils.IsLive(wt.RootWidget) then
            walk(wt.RootWidget, depth + 1, nowInNav)
        end
    end

    if UObjectUtils.IsLive(rootWidget) then
        walk(rootWidget, 0, false)
    end
    if #buttons == 0 and #navButtons > 0 then
        buttons = navButtons
    end
    return buttons, navButtons
end

local function ResolveFocusTarget(rootWidget)
    if not UObjectUtils.IsLive(rootWidget) then return nil end
    local target = nil
    pcall(function()
        if type(rootWidget.BP_GetDesiredFocusTarget) == "function" then
            target = rootWidget:BP_GetDesiredFocusTarget()
        end
    end)
    if not UObjectUtils.IsLive(target) then
        pcall(function()
            if type(rootWidget.GetDesiredFocusTarget) == "function" then
                target = rootWidget:GetDesiredFocusTarget()
            end
        end)
    end
    if UObjectUtils.IsLive(target) and not UObjectUtils.Same(target, rootWidget) then
        return target
    end
    local buttons = CollectInteractiveWidgets(rootWidget)
    if #buttons > 0 then
        return buttons[1].Widget
    end
    return rootWidget
end

local function FocusWidgetForAllPlayers(widget, containerWidget)
    if not UObjectUtils.IsLive(widget) then return end
    SessionManager.RefreshControllers()
    local p1 = SessionManager.GetP1()
    local wbl = UObjectUtils.GetWidgetBlueprintLibrary()
    -- Centralized menus belong strictly to Player 1 (LocalPlayer[0]).
    -- Never call SetUserFocus(p2) or SetInputMode_GameAndUIEx(p2) here or P2 steals Slate focus from P1!
    if wbl and p1 then
        pcall(function() wbl:SetInputMode_GameAndUIEx(p1, widget, 0, false) end)
    end
    if p1 then pcall(function() widget:SetUserFocus(p1) end) end
    pcall(function() widget:SetKeyboardFocus() end)
    if UObjectUtils.IsLive(containerWidget) and not UObjectUtils.Same(containerWidget, widget) then
        pcall(function()
            if type(containerWidget.RequestRefreshFocus) == "function" then
                containerWidget:RequestRefreshFocus()
            end
        end)
    end
end

function InputRouting.OpenPauseMenuOnP1(pauseMenuClass)
    local opened = false
    pcall(function()
        if Callbacks.CloseP2MenuIfOpen then UObjectUtils.SafeCall("Pause.CloseP2Menu", Callbacks.CloseP2MenuIfOpen) end
        SessionManager.RefreshControllers()
        local p1 = SessionManager.GetP1()
        if not p1 then return end

        local existingP1, _ = FindActivePauseMenus()
        if UObjectUtils.IsLive(existingP1) then opened = true; return end

        local pauseSub = FindFirstOf("PagodaGamePauseSubsystem")
        local bpfl = StaticFindObject("/Game/Pagoda/UI/BPFL_UI.Default__BPFL_UI_C")

        local p1Layout = nil
        if UObjectUtils.IsValid(bpfl) then
            pcall(function()
                local out = {}
                bpfl:GetUILayoutWidgetBase(p1, 0, p1, out)
                if UObjectUtils.IsValid(out.OutWidget) then p1Layout = out.OutWidget end
            end)
        end
        if not UObjectUtils.IsValid(p1Layout) then
            local layouts = FindAllOf("PagodaUILayoutWidget")
            if layouts then
                for _, l in pairs(layouts) do
                    if UObjectUtils.IsLive(l) then
                        local okVP, inVP = pcall(function() return l:IsInViewport() end)
                        local own = nil
                        pcall(function() own = l:GetOwningPlayer() end)
                        if okVP and inVP and SessionManager.GetPlayerIndex(own) == 0 then p1Layout = l end
                    end
                end
            end
        end

        local clearedPause = false
        if UObjectUtils.IsValid(p1Layout) and UObjectUtils.IsValid(bpfl) then
            if UObjectUtils.IsValid(pauseSub) and pauseSub:IsPaused() then
                pcall(function() pauseSub:SetIsPaused(false) end)
                clearedPause = true
            end
            pcall(function() bpfl:PushPauseMenuByWidget(p1Layout, p1) end)
        end

        local newP1, _ = FindActivePauseMenus()
        if UObjectUtils.IsLive(newP1) then
            if clearedPause and UObjectUtils.IsValid(pauseSub) and not pauseSub:IsPaused() then
                pcall(function() pauseSub:SetIsPaused(true) end)
            end
            opened = true
            return
        end

        if UObjectUtils.IsValid(p1Layout) then
            if not UObjectUtils.IsValid(pauseMenuClass) then
                pauseMenuClass = UObjectUtils.LoadClass("/Game/Pagoda/UI/Game/WBP_PauseMenu_Main", "WBP_PauseMenu_Main_C")
            end
            if UObjectUtils.IsValid(pauseMenuClass) then
                local stack = UObjectUtils.IsValid(p1Layout.SystemMenuStack) and p1Layout.SystemMenuStack
                    or (UObjectUtils.IsValid(p1Layout.GameMenuStack) and p1Layout.GameMenuStack or nil)
                if UObjectUtils.IsValid(stack) then
                    pcall(function()
                        local w = stack:BP_AddWidget(pauseMenuClass)
                        if UObjectUtils.IsValid(w) then
                            pcall(function() w.bResumeGameOnDeactivation = true end)
                            pcall(function() w:ActivateWidget() end)
                            opened = true
                        end
                    end)
                end
            end
            if (opened or clearedPause) and UObjectUtils.IsValid(pauseSub) then
                pcall(function() pauseSub:SetIsPaused(true) end)
            end
        elseif clearedPause and UObjectUtils.IsValid(pauseSub) then
            pcall(function() pauseSub:SetIsPaused(true) end)
        end
    end)
    return opened
end

function InputRouting.EnsurePauseMenuFocused()
    pcall(function()
        SessionManager.RefreshControllers()
        local p1, p2 = SessionManager.GetP1(), SessionManager.GetP2()
        local p1Menu, p2Menu = FindActivePauseMenus()
        local topStack = FindTopActiveStackWidget()
        local topW = UObjectUtils.IsLive(topStack) and topStack
            or (UObjectUtils.IsLive(p1Menu) and p1Menu or (UObjectUtils.IsLive(p2Menu) and p2Menu or nil))

        if UObjectUtils.IsLive(topW) and p1 then
            pcall(function() p1.bShowMouseCursor = true end)
            local focusTarget = ResolveFocusTarget(topW)
            FocusWidgetForAllPlayers(focusTarget or topW, topW)
            LastFocusedSubWidgetKey = UObjectUtils.GetKey(topW)
        end
    end)
end

local function ClickButtonCleanly(btnWidget)
    if not UObjectUtils.IsLive(btnWidget) then return false end
    local invoked = false
    pcall(function()
        if type(btnWidget.HandleButtonClicked) == "function" then
            btnWidget:HandleButtonClicked()
            invoked = true
        end
    end)
    if invoked then return true end

    pcall(function()
        if type(btnWidget.TriggerClick) == "function" then
            btnWidget:TriggerClick()
            invoked = true
        end
    end)
    if invoked then return true end

    pcall(function()
        if btnWidget.OnButtonBaseClicked then
            btnWidget.OnButtonBaseClicked:Broadcast(btnWidget)
            invoked = true
        end
    end)
    if invoked then return true end

    pcall(function()
        if type(btnWidget.BP_OnClicked) == "function" then
            btnWidget:BP_OnClicked()
            invoked = true
        end
    end)
    if invoked then return true end

    pcall(function()
        if btnWidget.OnClicked then
            btnWidget.OnClicked:Broadcast()
            invoked = true
        end
    end)
    return invoked
end

local function EvalPauseEdge(keyId, isDown, now, allowRepeat)
    local was = (PausePrevInputs[keyId] == true)
    PausePrevInputs[keyId] = (isDown == true)
    if isDown and not was then
        if allowRepeat then PauseHoldRepeat[keyId] = now + 0.30 end
        return true
    elseif isDown and was and allowRepeat then
        if now >= (PauseHoldRepeat[keyId] or (now + 0.30)) then
            PauseHoldRepeat[keyId] = now + 0.11
            return true
        end
    else
        PauseHoldRepeat[keyId] = nil
    end
    return false
end

local function IsPausePadKeyDown(p1, p2, keyName)
    local ks = GetKeyStruct(keyName)
    local down = false
    if UObjectUtils.IsLive(p2) then
        pcall(function() down = (p2:IsInputKeyDown(ks) == true) end)
    end
    -- In 1 KB/M + 1 Pad mode (OffsetGamepad == true), only one physical gamepad exists;
    -- if bOffsetPlayerGamepadIds = false routed it to p1, read p1 as well so it works 100% of the time!
    if (not down) and InputRouting.OffsetGamepad == true and UObjectUtils.IsLive(p1) then
        pcall(function() down = (p1:IsInputKeyDown(ks) == true) end)
    end
    return down
end

local function GetPausePadAnalog(p1, p2, keyName)
    local ks = GetKeyStruct(keyName)
    local v2, v1 = 0.0, 0.0
    if UObjectUtils.IsLive(p2) then
        pcall(function() v2 = tonumber(p2:GetInputAnalogKeyState(ks)) or 0.0 end)
    end
    if InputRouting.OffsetGamepad == true and UObjectUtils.IsLive(p1) then
        pcall(function() v1 = tonumber(p1:GetInputAnalogKeyState(ks)) or 0.0 end)
    end
    return (math.abs(v2) >= math.abs(v1)) and v2 or v1
end

local function PauseKeyEdge(p1, p2, keyName, now, allowRepeat)
    local down = IsPausePadKeyDown(p1, p2, keyName)
    return EvalPauseEdge("P:" .. keyName, down, now, allowRepeat)
end

local function SeedPauseButtonStates(p1, p2)
    PausePrevInputs = {}
    PauseHoldRepeat = {}
    for _, kn in ipairs({
        "Gamepad_Special_Right", "Gamepad_FaceButton_Bottom", "Gamepad_FaceButton_Right",
        "Gamepad_DPad_Up", "Gamepad_DPad_Down", "Gamepad_DPad_Left", "Gamepad_DPad_Right",
        "Gamepad_LeftShoulder", "Gamepad_RightShoulder",
    }) do
        local down = IsPausePadKeyDown(p1, p2, kn)
        PausePrevInputs["P:" .. kn] = (down == true)
    end
    PausePrevInputs["P:StickUp"] = true
    PausePrevInputs["P:StickDown"] = true
    PausePrevInputs["P:StickLeft"] = true
    PausePrevInputs["P:StickRight"] = true
end

local function BackOutSubMenu(topW)
    if not UObjectUtils.IsLive(topW) then return false end
    local now = os.clock()
    if (now - LastPauseBackAt) < 0.30 then return false end
    LastPauseBackAt = now

    local handled = false
    pcall(function()
        if type(topW.BP_OnHandleBackAction) == "function" then
            topW:BP_OnHandleBackAction()
            handled = true
        end
    end)
    Scheduler.Delay(45, "Pause.SubMenuBackCheck", function()
        if UObjectUtils.IsLive(topW) then
            local act = false
            pcall(function() act = (topW:IsActivated() == true) end)
            if act then
                pcall(function() topW:DeactivateWidget() end)
            end
        end
        InputRouting.EnsurePauseMenuFocused()
    end)
    return handled
end

local function TickPauseGamepadBridge(now, topW, isInSubMenu)
    local inCfg = Config.Input or {}
    if inCfg.EnablePauseMenuP2Gamepad == false then return end

    local p1 = SessionManager.GetP1()
    local p2 = SessionManager.GetP2()
    if not (p1 and p2 and UObjectUtils.IsLive(topW)) then return end

    -- Track screen changes (e.g. Main Pause -> Settings -> Keybinds -> Confirmation)
    local wKey = UObjectUtils.GetKey(topW)
    if wKey ~= PauseActiveWidgetKey then
        PauseActiveWidgetKey = wKey
        PauseFocusedIndex = 1
        LastPauseNavTime = now
        SeedPauseButtonStates(p1, p2)

        local clsName = ""
        pcall(function() clsName = topW:GetClass():GetFName():ToString() end)
        local bInit, nInit = CollectInteractiveWidgets(topW)
        Logger.Info("InputRouting", "Centralized Pause Bridge bound to '%s' (%d buttons, %d nav tabs).",
            clsName, #bInit, #nInit)
    end

    if (now - PauseOpenedAt) < 0.22 then
        SeedPauseButtonStates(p1, p2)
        return
    end

    local lx = GetPausePadAnalog(p1, p2, "Gamepad_LeftX")
    local ly = GetPausePadAnalog(p1, p2, "Gamepad_LeftY")
    local stickUp    = (ly > 0.55)  and (math.abs(ly) > math.abs(lx) * 1.4)
    local stickDown  = (ly < -0.55) and (math.abs(ly) > math.abs(lx) * 1.4)
    local stickLeft  = (lx < -0.55) and (math.abs(lx) > math.abs(ly) * 1.4)
    local stickRight = (lx > 0.55)  and (math.abs(lx) > math.abs(ly) * 1.4)

    -- 1. Back / Resume (B or Start)
    if PauseKeyEdge(p1, p2, "Gamepad_FaceButton_Right", now, false) then
        if isInSubMenu then
            BackOutSubMenu(topW)
        elseif (now - LastResumeRequestedAt) >= 0.45 then
            LastResumeRequestedAt = now
            InputRouting.TryResumePauseMenu()
            Scheduler.Delay(90, "Pause.RestoreInputAfterB", InputRouting.RestoreInputForAllPlayers)
        end
        return
    end
    if PauseKeyEdge(p1, p2, "Gamepad_Special_Right", now, false) then
        if isInSubMenu then
            BackOutSubMenu(topW)
        elseif (now - LastResumeRequestedAt) >= 0.45 then
            LastResumeRequestedAt = now
            InputRouting.TryResumePauseMenu()
            Scheduler.Delay(90, "Pause.RestoreInputAfterStart", InputRouting.RestoreInputForAllPlayers)
        end
        return
    end

    local buttons, navButtons = CollectInteractiveWidgets(topW)

    -- 2. LB / RB Tab switching (Settings / Pagoda NavBar)
    if #navButtons > 1 then
        local lb = PauseKeyEdge(p1, p2, "Gamepad_LeftShoulder", now, false)
        local rb = PauseKeyEdge(p1, p2, "Gamepad_RightShoulder", now, false)
        if lb or rb then
            local curNavIdx = 1
            for i, entry in ipairs(navButtons) do
                local sel = false
                pcall(function()
                    if type(entry.Widget.GetSelected) == "function" and entry.Widget:GetSelected() then
                        sel = true
                    elseif type(entry.Widget.HasUserFocus) == "function" and (entry.Widget:HasUserFocus(p1) or entry.Widget:HasUserFocus(p2)) then
                        sel = true
                    end
                end)
                if sel then curNavIdx = i; break end
            end
            local nextIdx = ((curNavIdx - 1 + (rb and 1 or -1)) % #navButtons) + 1
            ClickButtonCleanly(navButtons[nextIdx].Widget)
            Scheduler.Delay(60, "Pause.NavFocus", InputRouting.EnsurePauseMenuFocused)
            return
        end
    end

    if #buttons == 0 then return end

    -- Sync current index from Slate focus when idle, preserving recent bridge moves
    local curIdx = math.max(1, math.min(#buttons, PauseFocusedIndex or 1))
    if (now - LastPauseNavTime) > 0.18 then
        for i, entry in ipairs(buttons) do
            local focused = false
            pcall(function()
                local w = entry.Widget
                if w:HasUserFocus(p1) or w:HasUserFocus(p2) or w:HasKeyboardFocus() then
                    focused = true
                end
            end)
            if focused then
                curIdx = i
                break
            end
        end
    end
    PauseFocusedIndex = curIdx
    local curEntry = buttons[curIdx]

    -- 3. Up / Down navigation
    local moveUp   = PauseKeyEdge(p1, p2, "Gamepad_DPad_Up", now, true) or EvalPauseEdge("P:StickUp", stickUp, now, true)
    local moveDown = PauseKeyEdge(p1, p2, "Gamepad_DPad_Down", now, true) or EvalPauseEdge("P:StickDown", stickDown, now, true)
    if moveUp or moveDown then
        local delta = moveDown and 1 or -1
        local nextIdx = ((curIdx - 1 + delta) % #buttons) + 1
        PauseFocusedIndex = nextIdx
        LastPauseNavTime = now
        FocusWidgetForAllPlayers(buttons[nextIdx].Widget, topW)
        return
    end

    -- 4. Left / Right (rotator/slider adjustment or horizontal button step)
    local moveLeft  = PauseKeyEdge(p1, p2, "Gamepad_DPad_Left", now, true)  or EvalPauseEdge("P:StickLeft", stickLeft, now, true)
    local moveRight = PauseKeyEdge(p1, p2, "Gamepad_DPad_Right", now, true) or EvalPauseEdge("P:StickRight", stickRight, now, true)
    if moveLeft or moveRight then
        local rot, slider = FindSubRotatorOrSlider(curEntry.Widget)
        if UObjectUtils.IsLive(rot) then
            pcall(function()
                if moveLeft and type(rot.ShiftTextLeft) == "function" then
                    rot:ShiftTextLeft()
                elseif moveRight and type(rot.ShiftTextRight) == "function" then
                    rot:ShiftTextRight()
                end
            end)
            return
        elseif UObjectUtils.IsLive(slider) then
            pcall(function()
                local cur = slider:GetValue() or 0.5
                local mn = slider.MinValue or 0.0
                local mx = slider.MaxValue or 1.0
                local step = (slider.StepSize and slider.StepSize > 0.001) and slider.StepSize or ((mx - mn) * 0.05)
                local nv = math.max(mn, math.min(mx, cur + (moveRight and step or -step)))
                slider:SetValue(nv)
                if slider.OnValueChanged then
                    pcall(function() slider.OnValueChanged:Broadcast(nv) end)
                end
            end)
            return
        elseif #buttons > 1 then
            local nextIdx = ((curIdx - 1 + (moveRight and 1 or -1)) % #buttons) + 1
            PauseFocusedIndex = nextIdx
            LastPauseNavTime = now
            FocusWidgetForAllPlayers(buttons[nextIdx].Widget, topW)
            return
        end
    end

    -- 5. Confirm (A button)
    if PauseKeyEdge(p1, p2, "Gamepad_FaceButton_Bottom", now, false) then
        if curEntry and UObjectUtils.IsLive(curEntry.Widget) then
            FocusWidgetForAllPlayers(curEntry.Widget, topW)
            ClickButtonCleanly(curEntry.Widget)
            Scheduler.Delay(75, "Pause.PostClickFocus", InputRouting.EnsurePauseMenuFocused)
        end
        return
    end
end

local function EnsureNativeMenuInputMode(p1, focusWidget)
    if not UObjectUtils.IsLive(p1) then return end
    pcall(function() p1.bShowMouseCursor = true end)
    local wbl = UObjectUtils.GetWidgetBlueprintLibrary()
    if wbl then
        local target = UObjectUtils.IsLive(focusWidget) and focusWidget or nil
        pcall(function() wbl:SetInputMode_GameAndUIEx(p1, target, 0, false) end)
    end
end

function InputRouting.ResetMenuState()
    WasNativeMenuOpen = false
    WasPausedLastTick = false
    MenuOffsetSuppressed = false
    LastNativeMenuTopKey = nil
    PauseActiveWidgetKey = nil
    LastFocusedSubWidgetKey = nil
    PausePrevInputs = {}
    PauseHoldRepeat = {}
    pcall(function()
        local maps = UObjectUtils.GetGameMapsSettings()
        if maps and not UObjectUtils.IsGameplayWorld() then
            maps.bOffsetPlayerGamepadIds = false
        end
    end)
end

function InputRouting.TickPauseSafety(now)
    local inCfg = Config.Input or {}
    local pausedByP2Menu = Callbacks.IsPausedByP2Menu and Callbacks.IsPausedByP2Menu() or false
    local p2MenuOpen = Callbacks.IsP2MenuOpen and Callbacks.IsP2MenuOpen() or false
    local nativeMenuOpen = (not pausedByP2Menu) and InputRouting.IsAnyNativeMenuOpen()
    local p1, p2 = SessionManager.GetP1(), SessionManager.GetP2()

    -- 1. Universal Menu Lock & Routing Guard (keeps P2 frozen in ALL menus + keeps cursor/gamepad universal)
    if nativeMenuOpen and not p2MenuOpen then
        local lockMap = ActiveInputLocks[1]
        if p2 and not (lockMap and lockMap["LocalCoop.InGameMenu"]) then
            InputRouting.SetPlayerInputLock(p2, "LocalCoop.InGameMenu", true)
        elseif p2 then
            pcall(function()
                if UObjectUtils.IsLive(p2.Pawn) and UObjectUtils.IsValid(p2.Pawn.CharacterMovement) then
                    p2.Pawn.CharacterMovement:StopMovementImmediately()
                end
            end)
        end
        if not WasNativeMenuOpen then
            WasNativeMenuOpen = true
            Scheduler.CancelByTag("Menu.PostExitRestore")
            Scheduler.CancelByTag("Pause.PostExitRestore")
            if p2 then pcall(function() p2:FlushPressedKeys() end) end
            InputRouting.SyncGamepadOffset(false)
            if p1 then
                local topStackW = FindTopActiveStackWidget()
                EnsureNativeMenuInputMode(p1, topStackW)
                LastNativeMenuTopKey = UObjectUtils.GetKey(topStackW)
            end
        else
            pcall(function()
                local maps = UObjectUtils.GetGameMapsSettings()
                if maps and maps.bOffsetPlayerGamepadIds ~= false then
                    maps.bOffsetPlayerGamepadIds = false
                end
            end)
            if p1 then
                pcall(function() p1.bShowMouseCursor = true end)
                local topStackW = FindTopActiveStackWidget()
                local curKey = UObjectUtils.GetKey(topStackW)
                if curKey ~= LastNativeMenuTopKey then
                    LastNativeMenuTopKey = curKey
                    EnsureNativeMenuInputMode(p1, topStackW)
                end
            end
        end
    elseif WasNativeMenuOpen then
        WasNativeMenuOpen = false
        MenuOffsetSuppressed = false
        LastNativeMenuTopKey = nil
        if p2 then
            InputRouting.SetPlayerInputLock(p2, "LocalCoop.InGameMenu", false)
        end
        InputRouting.SyncGamepadOffset(false)
        if UObjectUtils.IsGameplayWorld() and not pausedByP2Menu then
            Scheduler.ReplaceDelay(120, "Menu.PostExitRestore", function()
                local p2PausedNow = Callbacks.IsPausedByP2Menu and Callbacks.IsPausedByP2Menu() or false
                if UObjectUtils.IsGameplayWorld() and not p2PausedNow and not InputRouting.IsAnyNativeMenuOpen() then
                    InputRouting.RestoreInputForAllPlayers()
                end
            end, true)
        end
    end

    if pausedByP2Menu then
        WasPausedLastTick = false
        PrevPauseEscDown = false
        PrevPauseStartDown = false
        return
    end

    local paused = InputRouting.IsGamePaused()
    if not paused then
        if WasPausedLastTick then
            WasPausedLastTick = false
            LastFocusedSubWidgetKey = nil
            PauseActiveWidgetKey = nil
            PausePrevInputs = {}
            PauseHoldRepeat = {}
            InputRouting.SyncGamepadOffset(false)
            ViewportController.ExitPauseFullscreen()
            if InputRouting.IsAnyNativeMenuOpen() then
                if p1 then EnsureNativeMenuInputMode(p1, FindTopActiveStackWidget()) end
            else
                Scheduler.ReplaceDelay(150, "Pause.PostExitRestore", function()
                    local p2PausedNow = Callbacks.IsPausedByP2Menu and Callbacks.IsPausedByP2Menu() or false
                    if UObjectUtils.IsGameplayWorld() and not p2PausedNow and not InputRouting.IsGamePaused() and not InputRouting.IsAnyNativeMenuOpen() then
                        InputRouting.RestoreInputForAllPlayers()
                    end
                end, true)
            end
        elseif nativeMenuOpen then
            -- Allow P2's gamepad (in both 1 KB/M + 1 Pad and 2-Pad modes) to drive open non-pause native menus
            local _, isInSub, stackTop = InputRouting.HasAnyActiveMenuOnStack()
            if UObjectUtils.IsLive(stackTop) then
                TickPauseGamepadBridge(now, stackTop, isInSub)
            end
        end
        PrevPauseEscDown = false
        PrevPauseStartDown = false
        return
    end

    if not WasPausedLastTick then
        WasPausedLastTick = true
        PauseOpenedAt = now
        PrevPauseEscDown = true
        PrevPauseStartDown = true
        LastFocusedSubWidgetKey = nil
        PauseActiveWidgetKey = nil
        PauseFocusedIndex = 1
        SeedPauseButtonStates(p1, p2)

        ViewportController.EnterPauseFullscreen()
        if inCfg.RoutePauseMenuToPrimaryViewport ~= false then
            InputRouting.DeactivateOrphanP2PauseMenus()
        end
        Scheduler.Delay(70, "Pause.FocusEnsure", InputRouting.EnsurePauseMenuFocused)
        return
    end

    local p1Menu, p2Menu = FindActivePauseMenus()
    if inCfg.RoutePauseMenuToPrimaryViewport ~= false and UObjectUtils.IsLive(p2Menu) then
        InputRouting.DeactivateOrphanP2PauseMenus()
        p1Menu, p2Menu = FindActivePauseMenus()
    end

    local topW = FindTopActiveStackWidget()
    local topKey = UObjectUtils.GetKey(topW)
    if topKey and topKey ~= LastFocusedSubWidgetKey then
        InputRouting.EnsurePauseMenuFocused()
    end

    local hasPauseWidget = UObjectUtils.IsLive(p1Menu) or UObjectUtils.IsLive(p2Menu)
    local hasStackMenu, isInSubMenu, stackTop = InputRouting.HasAnyActiveMenuOnStack()
    local activeTarget = topW or stackTop or p1Menu or p2Menu

    if (now - PauseOpenedAt) > 0.65 and not hasPauseWidget and not hasStackMenu then
        Logger.Warn("InputRouting", "Detected orphan pause with no active menu -> auto-resuming.")
        local sub = FindFirstOf("PagodaGamePauseSubsystem")
        if UObjectUtils.IsValid(sub) then pcall(function() sub:SetIsPaused(false) end) end
        ViewportController.ExitPauseFullscreen()
        if not InputRouting.IsAnyNativeMenuOpen() then
            InputRouting.RestoreInputForAllPlayers()
        end
        WasPausedLastTick = false
        return
    end

    -- Bridge P2's gamepad (in both 1 KB/M + 1 Pad and 2-Pad modes) onto P1's centralized Pause Menu
    if UObjectUtils.IsLive(activeTarget) then
        TickPauseGamepadBridge(now, activeTarget, isInSubMenu)
    end

    if (now - PauseOpenedAt) < 0.45 or isInSubMenu then
        PrevPauseEscDown = false
        PrevPauseStartDown = false
        return
    end

    -- Failsafe Escape & P1 Start on root Pause screen
    local escDown = false
    if p1 then pcall(function() escDown = (p1:IsInputKeyDown(GetKeyStruct("Escape")) == true) end) end
    local escJust = escDown and not PrevPauseEscDown
    PrevPauseEscDown = escDown

    local startJust = false
    if p1 and (not SessionManager.IsP2Active() or InputRouting.OffsetGamepad == true) then
        local startDown = false
        pcall(function() startDown = (p1:IsInputKeyDown(GetKeyStruct("Gamepad_Special_Right")) == true) end)
        startJust = startDown and not PrevPauseStartDown
        PrevPauseStartDown = startDown
    else
        PrevPauseStartDown = false
    end

    if (escJust or startJust) and (now - LastResumeRequestedAt) >= 0.45 then
        LastResumeRequestedAt = now
        InputRouting.TryResumePauseMenu()
        Scheduler.Delay(90, "Pause.RestoreInputAfterResume", function()
            if not InputRouting.IsAnyNativeMenuOpen() then
                InputRouting.RestoreInputForAllPlayers()
            end
        end)
    end
end

function InputRouting.DeactivateOrphanP2PauseMenus()
    if RedirectingPause or not InputRouting.IsGamePaused() then return end
    InputRouting.InvalidateMenuCache()
    pcall(function()
        ViewportController.SuppressP2LayoutsForPause(true)
        local p1Menu, p2Menu = FindActivePauseMenus()
        if not UObjectUtils.IsLive(p2Menu) then return end

        local function CollapseAndDeactivateP2Menu(menuW)
            pcall(function() menuW.bResumeGameOnDeactivation = false end)
            pcall(function() menuW.bShowCountdownOnDeactivate = false end)
            pcall(function() menuW:SetVisibility(1) end)
            pcall(function() menuW:DeactivateWidget() end)
        end

        if UObjectUtils.IsLive(p1Menu) then
            CollapseAndDeactivateP2Menu(p2Menu)
            InputRouting.EnsurePauseMenuFocused()
            return
        end

        RedirectingPause = true
        local pauseCls = nil
        pcall(function() pauseCls = p2Menu:GetClass() end)
        local openedOnP1 = InputRouting.OpenPauseMenuOnP1(pauseCls)
        if openedOnP1 then
            CollapseAndDeactivateP2Menu(p2Menu)
        end
        RedirectingPause = false
        InputRouting.EnsurePauseMenuFocused()
    end)
    RedirectingPause = false
end

function InputRouting.TryResumePauseMenu()
    local resumed = false
    pcall(function()
        local menus = FindAllOf("WBP_PauseMenu_Main_C")
        if menus then
            for _, pm in pairs(menus) do
                if UObjectUtils.IsLive(pm) then
                    local okA, act = pcall(function() return pm:IsActivated() end)
                    if okA and act then
                        pcall(function() pm.bResumeGameOnDeactivation = true end)
                        pcall(function() pm.bShowCountdownOnDeactivate = false end)
                        pm:HandleResumeGame()
                        resumed = true
                    end
                end
            end
        end
        if resumed then
            Scheduler.Delay(60, "Pause.EnsureUnpaused", function()
                local sub = FindFirstOf("PagodaGamePauseSubsystem")
                if UObjectUtils.IsValid(sub) and sub:IsPaused() then
                    pcall(function() sub:SetIsPaused(false) end)
                end
            end)
        else
            local sub = FindFirstOf("PagodaGamePauseSubsystem")
            if UObjectUtils.IsValid(sub) and sub:IsPaused() then
                pcall(function() sub:SetIsPaused(false) end)
                resumed = true
            end
        end
    end)
    return resumed
end

-- ============================================================================
-- DIVE BAR STATION INTERCEPTION & P2 GAMEPAD CHORDS (5-TAB INDICES!)
-- ============================================================================

function InputRouting.TryOpenDiveBarStationForP2()
    local inCfg = Config.Input or {}
    local menuCfg = Config.P2Menu or {}
    if inCfg.InterceptDiveBarStationsForP2 == false or menuCfg.Enabled == false then return false end
    SessionManager.RefreshControllers()
    local p2Pawn = SessionManager.GetP2Pawn()
    if not p2Pawn then return false end

    local maxSq = 420.0 * 420.0
    local cosSt = FindAllOf("BP_DiveBar_Interact_Cosmetics_C")
    if cosSt then
        for _, st in pairs(cosSt) do
            if UObjectUtils.IsLive(st) and UObjectUtils.GetDistanceSq(p2Pawn, st) <= maxSq then
                if Callbacks.OpenP2Menu then Callbacks.OpenP2Menu(1, 2) end -- Tab 1 (Character), Sub 2 (Outfits)
                return true
            end
        end
    end
    local skSt = FindAllOf("BP_DiveBar_Interact_SkillTree_C")
    if skSt then
        for _, st in pairs(skSt) do
            if UObjectUtils.IsLive(st) and UObjectUtils.GetDistanceSq(p2Pawn, st) <= maxSq then
                if Callbacks.OpenP2Menu then Callbacks.OpenP2Menu(2, 1) end -- Tab 2 (Boss Skills)
                return true
            end
        end
    end
    return false
end

function InputRouting.DidP2TriggerStation(stationActor)
    if not UObjectUtils.IsLive(stationActor) then return false end
    SessionManager.RefreshControllers()
    local p1Pawn, p2Pawn = SessionManager.GetP1Pawn(), SessionManager.GetP2Pawn()
    if not p2Pawn then return false end
    local recent = (os.clock() - InputRouting.LastP2InputTime) <= 0.50
    local d2 = UObjectUtils.GetDistanceSq(p2Pawn, stationActor)
    local d1 = p1Pawn and UObjectUtils.GetDistanceSq(p1Pawn, stationActor) or math.huge
    return recent and (d2 <= 480.0 * 480.0) and (d2 <= d1 + 40000.0)
end

local function IsChordDown(pc, keys, now)
    if type(keys) ~= "table" or #keys == 0 or not UObjectUtils.IsLive(pc) then return false end
    local k = UObjectUtils.GetKey(pc)
    local rec = k and RecentKeys[k] or nil
    for _, keyName in ipairs(keys) do
        local down = false
        local win = (keyName == "Gamepad_Special_Left" or keyName == "Gamepad_Special_Right") and 1.15 or 0.55
        if rec and rec[keyName] and (now - rec[keyName]) <= win then
            down = true
        else
            local ok, r = pcall(function() return pc:IsInputKeyDown(GetKeyStruct(keyName)) end)
            if ok and r == true then down = true end
        end
        if not down then return false end
    end
    return true
end

function InputRouting.OnGamepadKey(pc, keyName)
    local inCfg = Config.Input or {}
    local menuCfg = Config.P2Menu or {}
    if inCfg.EnableGamepadShortcuts == false or not UObjectUtils.IsLive(pc) then return end

    local now = os.clock()
    local pid = SessionManager.GetPlayerIndex(pc)
    if pid == 1 then
        InputRouting.LastP2InputTime = now
        if InputRouting.OffsetGamepad == false then
            LastP2GamepadWhileUnOffset = now
        end
    end

    local p2MenuOpen = Callbacks.IsP2MenuOpen and Callbacks.IsP2MenuOpen() or false

    if keyName and keyName ~= "" then
        local pcKey = UObjectUtils.GetKey(pc)
        if pcKey then
            RecentKeys[pcKey] = RecentKeys[pcKey] or {}
            local prev = RecentKeys[pcKey][keyName]
            RecentKeys[pcKey][keyName] = now

            if keyName == "Gamepad_Special_Right" and pid == 1 then
                if prev and (now - prev) < 0.25 then return end
                local wasPausedByP2 = Callbacks.IsPausedByP2Menu and Callbacks.IsPausedByP2Menu() or false
                if Callbacks.CloseP2MenuIfOpen then UObjectUtils.SafeCall("Start.CloseMenu", Callbacks.CloseP2MenuIfOpen) end
                if wasPausedByP2 then
                    LastChordTime = now
                    return
                end
                if not InputRouting.IsGamePaused() then
                    Scheduler.Delay(35, "Pause.OpenOnP1", function()
                        if not UObjectUtils.IsGameplayWorld() then return end
                        if inCfg.RoutePauseMenuToPrimaryViewport ~= false then
                            InputRouting.DeactivateOrphanP2PauseMenus()
                        end
                        if not InputRouting.IsGamePaused() then
                            InputRouting.OpenPauseMenuOnP1(nil)
                        end
                    end)
                elseif inCfg.EnablePauseMenuP2Gamepad == false then
                    local _, isInSub, topW = InputRouting.HasAnyActiveMenuOnStack()
                    if isInSub and UObjectUtils.IsLive(topW) then
                        Scheduler.Delay(25, "Pause.BackSub", function() BackOutSubMenu(topW) end)
                    elseif (now - LastResumeRequestedAt) >= 0.45 then
                        LastResumeRequestedAt = now
                        Scheduler.Delay(30, "Pause.Resume", InputRouting.TryResumePauseMenu)
                    end
                end
                LastChordTime = now
                return
            end
        end

        -- When P2 Menu is open, single authoritative polling loop inside P2Menu owns P2 input
        if p2MenuOpen and pid == 1 then
            return
        end

        if pid == 1 and not InputRouting.IsGamePaused()
            and (keyName == "Gamepad_FaceButton_Left"
                or keyName == "Gamepad_FaceButton_Top"
                or keyName == "Gamepad_FaceButton_Bottom") then
            if InputRouting.TryOpenDiveBarStationForP2() then
                LastChordTime = now
                return
            end
        end

        local menuKey = inCfg.GamepadMenuToggleKey or "Gamepad_Special_Left"
        if pid == 1 and keyName == menuKey and menuCfg.Enabled ~= false and not InputRouting.IsGamePaused() then
            Scheduler.Delay(160, "Input.OpenP2Menu", function()
                local openNow = Callbacks.IsP2MenuOpen and Callbacks.IsP2MenuOpen() or false
                if openNow or InputRouting.IsGamePaused() or not UObjectUtils.IsGameplayWorld() then return end
                if (os.clock() - LastChordTime) < 0.30 then return end
                if Callbacks.OpenP2Menu then Callbacks.OpenP2Menu() end
            end, true)
        end
    end

    if p2MenuOpen then return end
    -- NOTE: GamepadJoinChord (L3+R3) is handled strictly by simultaneous polling
    -- in TickJoinChord(now). Model/Loadout hot-swap chords were removed cleanly.
end

return InputRouting
