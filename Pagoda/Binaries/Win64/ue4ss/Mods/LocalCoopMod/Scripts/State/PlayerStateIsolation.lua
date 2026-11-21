-- P1/P2 PlaythroughData and upgrade isolation.
--
-- UPagodaPlayerUpgradeComponent::GetPlaythroughData() resolves LocalPlayer[0]'s
-- PlayerState->PlaythroughData (+0x3D0), and UPagodaPlayerUpgradeCatalogSubsystem
-- reads LocalPlayer[0]->PlaythroughData (+0x2C8). To keep P2's skills and cosmetics
-- independent without mutating P1's save data, P2 gets a GameInstance-rooted
-- DedicatedP2PPD, and every synchronous P2 upgrade/cosmetic call runs inside
-- WithScopedP2PPD, which temporarily points P1's pointers to DedicatedP2PPD and
-- restores them on the same frame.

local UObjectUtils = require("Utils.UObjectUtils")
local Logger = require("Utils.Logger")
local Scheduler = require("Core.Scheduler")
local SessionManager = require("Core.SessionManager")
local CatalogService = require("State.CatalogService")
local ProfileStore = require("State.ProfileStore")

local PlayerStateIsolation = {}

local Config = {}

local DedicatedP2PPD = nil
local DedicatedP2AltPPD = nil
local DedicatedP2BulkUnlockedKey = nil

-- Synchronous re-entrancy depth + active redirect backup for WithScopedP2PPD
local ScopedRedirectDepth = 0
local ActiveRedirectState = nil

-- Per-component ledger of upgrade tags WE applied to P2
local AppliedP2UpgradeTags = {} -- [p2UpgKey] = { [tagStr] = tagStruct }

PlayerStateIsolation.Status = {
    Verified = false,
    LP_PPD_Isolated = false,
    PawnIsolated = false,
    ASCIsolated = false,
    UpgCompIsolated = false,
    LastBindMode = "Unbound",
    LastAuditTime = 0.0,
    ScopedSwapCount = 0,
    StrayDelegateBlockedCount = 0,
    BleedDetectedCount = 0,
    LastError = nil,
}

function PlayerStateIsolation.Init(config)
    Config = config or {}
    UObjectUtils.EnsurePlaythroughDataBridges()
    UObjectUtils.EnsureUpgradeDefinitionBridges()
end

function PlayerStateIsolation.OnWorldChanged()
    AppliedP2UpgradeTags = {}
    if ScopedRedirectDepth == 0 then
        ActiveRedirectState = nil
    end
end

function PlayerStateIsolation.IsInScopedP2Write()
    return ScopedRedirectDepth > 0
end

function PlayerStateIsolation.IsDedicatedP2PPD(obj)
    if not UObjectUtils.IsValid(obj) then return false end
    return (UObjectUtils.IsValid(DedicatedP2PPD) and UObjectUtils.Same(obj, DedicatedP2PPD))
        or (UObjectUtils.IsValid(DedicatedP2AltPPD) and UObjectUtils.Same(obj, DedicatedP2AltPPD))
end

-- ============================================================================
-- STRICT COMPONENT & PLAYTHROUGH-DATA ACCESSORS
-- ============================================================================

function PlayerStateIsolation.GetP1PlaythroughData(p1Ctrl)
    local p1Data = nil
    if UObjectUtils.IsLive(p1Ctrl) then
        pcall(function() p1Data = p1Ctrl:GetPlaythroughPlayerData() end)
    end
    if not UObjectUtils.IsValid(p1Data) then
        pcall(function()
            local saveSub = FindFirstOf("PagodaSaveGameSubsystem")
            if UObjectUtils.IsValid(saveSub) and UObjectUtils.IsValid(saveSub.PlaythroughPlayerData) then
                p1Data = saveSub.PlaythroughPlayerData
            end
        end)
    end
    return UObjectUtils.IsValid(p1Data) and p1Data or nil
end

function PlayerStateIsolation.GetUpgradeComponent(pc)
    if not UObjectUtils.IsLive(pc) then return nil end
    local pawn = nil
    pcall(function() pawn = pc.Pawn end)
    local comp = nil

    if UObjectUtils.IsLive(pawn) then
        pcall(function() comp = pawn.PlayerUpgradeComponent end)
        if not UObjectUtils.IsValid(comp) then
            pcall(function() comp = pawn.PlayerUpgrades end)
        end
        if UObjectUtils.IsValid(comp) then
            local owner = nil
            pcall(function() owner = comp:GetOwner() end)
            if UObjectUtils.IsValid(owner) and not UObjectUtils.Same(owner, pawn) then
                comp = nil
            end
        end
    end

    if not UObjectUtils.IsValid(comp) then
        pcall(function() comp = pc:GetPlayerUpgradeComponent() end)
        if UObjectUtils.IsValid(comp) and UObjectUtils.IsLive(pawn) then
            local owner = nil
            pcall(function() owner = comp:GetOwner() end)
            if UObjectUtils.IsValid(owner) and not UObjectUtils.Same(owner, pawn) then
                return nil
            end
        end
    end

    return UObjectUtils.IsValid(comp) and comp or nil
end

function PlayerStateIsolation.GetCosmeticComponent(pawn)
    if not UObjectUtils.IsLive(pawn) then return nil end
    local comp = nil
    pcall(function() comp = pawn.CosmeticComponent or pawn.PlayerCosmeticComponent end)
    return UObjectUtils.IsValid(comp) and comp or nil
end

function PlayerStateIsolation.GetVerifiedP2UpgradeComponent(p1Ctrl, p2Ctrl)
    if not (UObjectUtils.IsLive(p2Ctrl) and UObjectUtils.IsLive(p2Ctrl.Pawn)) then return nil, nil end
    local p2Pawn = p2Ctrl.Pawn
    local p1Pawn = UObjectUtils.IsLive(p1Ctrl) and p1Ctrl.Pawn or nil
    if UObjectUtils.IsLive(p1Pawn) and UObjectUtils.Same(p1Pawn, p2Pawn) then
        Logger.Error("Isolation", "P2 Pawn aliased P1 Pawn; blocking upgrade component access.")
        return nil, nil
    end

    local p2Upg = PlayerStateIsolation.GetUpgradeComponent(p2Ctrl)
    local p1Upg = UObjectUtils.IsLive(p1Ctrl) and PlayerStateIsolation.GetUpgradeComponent(p1Ctrl) or nil
    if not UObjectUtils.IsValid(p2Upg) then return nil, p1Upg end
    if UObjectUtils.IsValid(p1Upg) and UObjectUtils.Same(p1Upg, p2Upg) then
        Logger.Error("Isolation", "P2 UpgradeComponent aliased P1 UpgradeComponent; blocked.")
        return nil, p1Upg
    end
    return p2Upg, p1Upg
end

-- ============================================================================
-- DEDICATED P2 PLAYTHROUGH DATA & SYNCHRONOUS SCOPED REDIRECT
-- ============================================================================

local function WritePlayerStatePPD(playerState, targetPPD)
    if not (UObjectUtils.IsLive(playerState) and UObjectUtils.IsValid(targetPPD)) then return false end
    UObjectUtils.EnsurePlaythroughDataBridges()
    local okAlias = pcall(function() playerState.Mod_PlaythroughData = targetPPD end)
    local okNative = pcall(function() playerState.PlaythroughData = targetPPD end)
    return okAlias or okNative
end

local function WriteLocalPlayerPPD(localPlayer, targetPPD)
    if not (UObjectUtils.IsValid(localPlayer) and UObjectUtils.IsValid(targetPPD)) then return false end
    UObjectUtils.EnsurePlaythroughDataBridges()
    local okAlias = pcall(function() localPlayer.Mod_LP_PlaythroughData = targetPPD end)
    local okNative = pcall(function() localPlayer.PlaythroughData = targetPPD end)
    return okAlias or okNative
end

local function PopulateDesiredOwnedUpgradesOnP2PPD(p2PPD)
    if not UObjectUtils.IsValid(p2PPD) then return end
    local loadCfg = Config.Loadouts or {}

    if loadCfg.UnlockAllSkillsForP2 ~= false and loadCfg.ProtectP1Achievements == false then
        local key = UObjectUtils.GetKey(p2PPD)
        if DedicatedP2BulkUnlockedKey ~= key then
            CatalogService.Refresh()
            local allDefs = CatalogService.GetAllUpgradeDefinitions()
            for _, def in ipairs(allDefs) do
                if UObjectUtils.IsValid(def) then
                    local ts = UObjectUtils.MakeTagStruct(def.UpgradeIdTag)
                    if ts then pcall(function() p2PPD:AddOwnedUpgrade(ts) end) end
                end
            end
            DedicatedP2BulkUnlockedKey = key
        end
        return
    end

    local p2 = ProfileStore.GetP2()
    for sIdx = 0, 3 do
        local bDef = p2.BossAbilitySlots[sIdx]
        if UObjectUtils.IsValid(bDef) then
            local ts = UObjectUtils.MakeTagStruct(bDef.UpgradeIdTag)
            if ts then pcall(function() p2PPD:AddOwnedUpgrade(ts) end) end
        end
    end
    for _, def in pairs(p2.ActiveUpgrades) do
        if UObjectUtils.IsValid(def) then
            local ts = UObjectUtils.MakeTagStruct(def.UpgradeIdTag)
            if ts then pcall(function() p2PPD:AddOwnedUpgrade(ts) end) end
        end
    end
end

function PlayerStateIsolation.EnsureDedicatedP2PPD(p1Ctrl, p2Ctrl)
    local p1Data = PlayerStateIsolation.GetP1PlaythroughData(p1Ctrl)
    local p2State = UObjectUtils.IsLive(p2Ctrl) and p2Ctrl.PlayerState or nil
    local p1LP = UObjectUtils.IsLive(p1Ctrl) and p1Ctrl.Player or nil
    local p2LP = UObjectUtils.IsLive(p2Ctrl) and p2Ctrl.Player or nil
    if UObjectUtils.IsValid(p2LP) and UObjectUtils.IsValid(p1LP) and UObjectUtils.Same(p2LP, p1LP) then
        p2LP = nil
    end

    local outer = nil
    pcall(function() outer = FindFirstOf("GameInstance") end)
    if not UObjectUtils.IsValid(outer) then
        outer = UObjectUtils.IsLive(p2State) and p2State or (UObjectUtils.IsLive(p1Ctrl) and p1Ctrl.PlayerState or nil)
    end

    if not UObjectUtils.IsValid(DedicatedP2PPD)
        or (UObjectUtils.IsValid(p1Data) and UObjectUtils.Same(DedicatedP2PPD, p1Data)) then
        pcall(function()
            local ppdClass = StaticFindObject("/Script/Pagoda.PagodaPlaythroughPlayerData")
            if not UObjectUtils.IsValid(ppdClass) then
                Logger.Missing("Isolation", "/Script/Pagoda.PagodaPlaythroughPlayerData", "EnsureDedicatedP2PPD")
                return
            end
            if UObjectUtils.IsValid(outer) then
                DedicatedP2PPD = StaticConstructObject(ppdClass, outer)
                if UObjectUtils.IsValid(DedicatedP2PPD) then
                    DedicatedP2PPD.bWasLoaded = true
                    DedicatedP2BulkUnlockedKey = nil
                    Logger.Debug("Isolation", "Created DedicatedP2PPD (%s)", tostring(UObjectUtils.GetKey(DedicatedP2PPD)))
                end
            end
        end)
    end

    if not UObjectUtils.IsValid(DedicatedP2AltPPD)
        or (UObjectUtils.IsValid(p1Data) and UObjectUtils.Same(DedicatedP2AltPPD, p1Data)) then
        pcall(function()
            local ppdClass = StaticFindObject("/Script/Pagoda.PagodaPlaythroughPlayerData")
            if UObjectUtils.IsValid(ppdClass) and UObjectUtils.IsValid(outer) then
                DedicatedP2AltPPD = StaticConstructObject(ppdClass, outer)
                if UObjectUtils.IsValid(DedicatedP2AltPPD) then
                    DedicatedP2AltPPD.bWasLoaded = true
                end
            end
        end)
    end

    PopulateDesiredOwnedUpgradesOnP2PPD(DedicatedP2PPD)

    if UObjectUtils.IsLive(p2State) and UObjectUtils.IsValid(DedicatedP2PPD) then
        local curP2Data = nil
        if UObjectUtils.IsLive(p2Ctrl) then
            pcall(function() curP2Data = p2Ctrl:GetPlaythroughPlayerData() end)
        end
        if not UObjectUtils.Same(curP2Data, DedicatedP2PPD) then
            WritePlayerStatePPD(p2State, DedicatedP2PPD)
        end
    end
    if UObjectUtils.IsValid(p2LP) and UObjectUtils.IsValid(DedicatedP2PPD) then
        WriteLocalPlayerPPD(p2LP, DedicatedP2PPD)
    end

    local verified = false
    if UObjectUtils.IsLive(p2Ctrl) and UObjectUtils.IsValid(DedicatedP2PPD) then
        local readBack = nil
        pcall(function() readBack = p2Ctrl:GetPlaythroughPlayerData() end)
        if UObjectUtils.IsValid(readBack)
            and UObjectUtils.Same(readBack, DedicatedP2PPD)
            and (not UObjectUtils.IsValid(p1Data) or not UObjectUtils.Same(readBack, p1Data)) then
            verified = true
        end
    end

    local lpIso = false
    if UObjectUtils.IsValid(p2LP) and UObjectUtils.IsValid(DedicatedP2PPD) then
        local lpRead = nil
        pcall(function() lpRead = p2LP.Mod_LP_PlaythroughData end)
        if not UObjectUtils.IsValid(lpRead) then
            pcall(function()
                local cdo = StaticFindObject("/Script/Pagoda.Default__PagodaPlaythroughPlayerData")
                if UObjectUtils.IsValid(cdo) then lpRead = cdo:GetFromLocalPlayer(p2LP) end
            end)
        end
        if UObjectUtils.IsValid(lpRead)
            and UObjectUtils.Same(lpRead, DedicatedP2PPD)
            and (not UObjectUtils.IsValid(p1Data) or not UObjectUtils.Same(lpRead, p1Data)) then
            lpIso = true
        end
    end

    PlayerStateIsolation.Status.Verified = verified
    PlayerStateIsolation.Status.LP_PPD_Isolated = lpIso
    PlayerStateIsolation.Status.LastBindMode = lpIso and "PS+LP" or (verified and "PS-Only" or "Unbound")
    PlayerStateIsolation.Status.LastAuditTime = os.clock()
    return DedicatedP2PPD, DedicatedP2AltPPD, verified
end

function PlayerStateIsolation.IsolatePlayer2State(p1Ctrl, p2Ctrl)
    if not UObjectUtils.IsLive(p2Ctrl) then return false end
    if SessionManager.GetPlayerIndex(p2Ctrl) ~= 1 then return false end
    local _, _, verified = PlayerStateIsolation.EnsureDedicatedP2PPD(p1Ctrl, p2Ctrl)
    return verified
end

function PlayerStateIsolation.IsolatePlayerStateObject(ps)
    if not UObjectUtils.IsLive(ps) then return false end
    SessionManager.RefreshControllers()
    local p1, p2 = SessionManager.GetP1(), SessionManager.GetP2()
    if p2 and UObjectUtils.Same(p2.PlayerState, ps) then
        return PlayerStateIsolation.IsolatePlayer2State(p1, p2)
    end
    return false
end

-- Runs fn(DedicatedP2PPD) while temporarily pointing P1's PlaythroughData slots
-- to DedicatedP2PPD so UPagodaPlayerUpgradeComponent::GetPlaythroughData() resolves P2.
-- Restores P1's pointers synchronously before returning.
function PlayerStateIsolation.WithScopedP2PPD(p1Ctrl, opName, fn)
    if type(fn) ~= "function" then return false end

    if ScopedRedirectDepth > 0 and ActiveRedirectState then
        ScopedRedirectDepth = ScopedRedirectDepth + 1
        local okNested, r1, r2 = pcall(fn, DedicatedP2PPD)
        ScopedRedirectDepth = ScopedRedirectDepth - 1
        if not okNested then
            Logger.Error("Isolation", "Scoped '%s' failed: %s", tostring(opName), tostring(r1))
            return false
        end
        return true, r1, r2
    end

    if not UObjectUtils.IsLive(p1Ctrl) then
        Logger.Warn("Isolation", "WithScopedP2PPD(%s) aborted: P1 controller invalid.", tostring(opName))
        return false
    end
    local p1State = nil
    pcall(function() p1State = p1Ctrl.PlayerState end)
    if not UObjectUtils.IsLive(p1State) then
        Logger.Warn("Isolation", "WithScopedP2PPD(%s) aborted: P1 PlayerState invalid.", tostring(opName))
        return false
    end

    -- Create DedicatedP2PPD before mutating P1's PlaythroughData pointer.
    PlayerStateIsolation.EnsureDedicatedP2PPD(p1Ctrl, SessionManager.GetP2())
    if not UObjectUtils.IsValid(DedicatedP2PPD) then
        Logger.Error("Isolation", "WithScopedP2PPD(%s) aborted: DedicatedP2PPD unavailable.", tostring(opName))
        return false
    end

    local origPS = PlayerStateIsolation.GetP1PlaythroughData(p1Ctrl)
    if not UObjectUtils.IsValid(origPS) or UObjectUtils.Same(origPS, DedicatedP2PPD) then
        Logger.Error("Isolation", "WithScopedP2PPD(%s) aborted: invalid or aliased P1 PPD.", tostring(opName))
        return false
    end

    local p1LP = nil
    local origLP = nil
    pcall(function()
        p1LP = p1Ctrl.Player
        if UObjectUtils.IsValid(p1LP) then
            origLP = p1LP.Mod_LP_PlaythroughData
        end
    end)

    ActiveRedirectState = {
        p1Ctrl = p1Ctrl,
        p1State = p1State,
        origPS = origPS,
        p1LP = p1LP,
        origLP = UObjectUtils.IsValid(origLP) and origLP or nil,
    }

    -- Swap synchronously to DedicatedP2PPD
    if not WritePlayerStatePPD(p1State, DedicatedP2PPD) then
        ActiveRedirectState = nil
        Logger.Error("Isolation", "WithScopedP2PPD(%s): failed to write temporary PPD redirect.", tostring(opName))
        return false
    end
    if ActiveRedirectState.origLP and UObjectUtils.IsValid(p1LP) then
        WriteLocalPlayerPPD(p1LP, DedicatedP2PPD)
    end

    ScopedRedirectDepth = 1
    PlayerStateIsolation.Status.ScopedSwapCount = PlayerStateIsolation.Status.ScopedSwapCount + 1

    local ok, r1, r2 = pcall(fn, DedicatedP2PPD)

    -- Unconditional immediate same-frame restore
    ScopedRedirectDepth = 0
    if UObjectUtils.IsLive(p1State) and UObjectUtils.IsValid(origPS) then
        WritePlayerStatePPD(p1State, origPS)
    end
    if UObjectUtils.IsValid(p1LP) and ActiveRedirectState.origLP then
        WriteLocalPlayerPPD(p1LP, ActiveRedirectState.origLP)
    end

    local verifyBack = nil
    pcall(function() verifyBack = p1Ctrl:GetPlaythroughPlayerData() end)
    if UObjectUtils.IsValid(origPS) and (not UObjectUtils.Same(verifyBack, origPS)) then
        Logger.Error("Isolation", "CRITICAL: Failed to restore P1 PPD after '%s'!", tostring(opName))
    end
    ActiveRedirectState = nil

    if not ok then
        PlayerStateIsolation.Status.LastError = tostring(r1)
        Logger.Error("Isolation", "Scoped operation '%s' threw error: %s", tostring(opName), tostring(r1))
        return false
    end
    return true, r1, r2
end

function PlayerStateIsolation.WrapP2Spawn(p1Ctrl, spawnFn)
    -- Populate P2's loadout before DedicatedP2PPD is read during BeginPlay.
    ProfileStore.EnsureP2Initialized(function() return PlayerStateIsolation.CaptureP1Snapshot(p1Ctrl) end)
    PlayerStateIsolation.EnsureDedicatedP2PPD(p1Ctrl, SessionManager.GetP2())
    return PlayerStateIsolation.WithScopedP2PPD(p1Ctrl, "SpawnP2", spawnFn)
end

-- ============================================================================
-- READ-ONLY P1 SNAPSHOT & ZERO-BLEED VERIFICATION (ZERO WRITE-BACK LOOPS)
-- ============================================================================

function PlayerStateIsolation.CaptureP1Snapshot(p1Ctrl)
    local snap = ProfileStore.GetP1Snapshot()
    snap.BossAbilitySlots = {}
    snap.ActiveUpgrades = {}
    if not UObjectUtils.IsLive(p1Ctrl) then return snap end

    pcall(function()
        local p1Upg = PlayerStateIsolation.GetUpgradeComponent(p1Ctrl)
        if not UObjectUtils.IsValid(p1Upg) then return end

        for s = 0, 3 do
            local okB, bDef = pcall(function() return p1Upg:GetPlayerUpgradeAtSlot(s) end)
            if okB and UObjectUtils.IsValid(bDef) then
                snap.BossAbilitySlots[s] = bDef
            end
        end

        CatalogService.Refresh()
        for _, def in ipairs(CatalogService.GetAllUpgradeDefinitions()) do
            if UObjectUtils.IsValid(def) then
                local ts = UObjectUtils.MakeTagStruct(def.UpgradeIdTag)
                if ts then
                    local okEq, eq = pcall(function() return p1Upg:IsUpgradeEquipped(ts) end)
                    if okEq and eq == true then
                        local str = UObjectUtils.GetTagString(def.UpgradeIdTag)
                        if str ~= "" then snap.ActiveUpgrades[str] = def end
                    end
                end
            end
        end
    end)

    return snap
end

local function SnapshotP1UpgradeState(p1Ctrl, candidateDefs)
    local p1Upg = UObjectUtils.IsLive(p1Ctrl) and PlayerStateIsolation.GetUpgradeComponent(p1Ctrl) or nil
    if not UObjectUtils.IsValid(p1Upg) then return nil end

    local preBoss = {}
    for s = 0, 3 do
        pcall(function()
            local d = p1Upg:GetPlayerUpgradeAtSlot(s)
            if UObjectUtils.IsValid(d) then preBoss[s] = d end
        end)
    end

    local preTags = {}
    for _, def in ipairs(candidateDefs or {}) do
        if UObjectUtils.IsValid(def) then
            local ts = UObjectUtils.MakeTagStruct(def.UpgradeIdTag)
            local str = UObjectUtils.GetTagString(def.UpgradeIdTag)
            if ts and str ~= "" and preTags[str] == nil then
                local eq = false
                pcall(function() eq = (p1Upg:IsUpgradeEquipped(ts) == true) end)
                preTags[str] = { equipped = eq, tag = ts }
            end
        end
    end

    return { Upg = p1Upg, Boss = preBoss, Tags = preTags }
end

-- Read-only post-write verification; never writes back to P1.
local function VerifyP1ZeroBleed(preSnap, opName)
    if not (preSnap and UObjectUtils.IsValid(preSnap.Upg)) then return true end
    local p1Upg = preSnap.Upg
    local clean = true

    for s = 0, 3 do
        local beforeDef = preSnap.Boss[s]
        local afterDef = nil
        pcall(function() afterDef = p1Upg:GetPlayerUpgradeAtSlot(s) end)
        local changed = (UObjectUtils.IsValid(beforeDef) and not UObjectUtils.Same(beforeDef, afterDef))
            or (not UObjectUtils.IsValid(beforeDef) and UObjectUtils.IsValid(afterDef))
        if changed then
            clean = false
            PlayerStateIsolation.Status.BleedDetectedCount = PlayerStateIsolation.Status.BleedDetectedCount + 1
            Logger.Error("Isolation", "BLEED DETECTED after %s: P1 Boss Slot %d changed unexpectedly!",
                tostring(opName), s + 1)
        end
    end

    for tagStr, rec in pairs(preSnap.Tags) do
        local nowEq = false
        pcall(function() nowEq = (p1Upg:IsUpgradeEquipped(rec.tag) == true) end)
        if nowEq ~= rec.equipped then
            clean = false
            PlayerStateIsolation.Status.BleedDetectedCount = PlayerStateIsolation.Status.BleedDetectedCount + 1
            Logger.Error("Isolation", "BLEED DETECTED after %s: P1 Upgrade '%s' changed (%s -> %s)!",
                tostring(opName), tagStr, tostring(rec.equipped), tostring(nowEq))
        end
    end

    return clean
end

local function FormatUpgradeSlotSummary(upgComp)
    if not UObjectUtils.IsValid(upgComp) then return "none" end
    local parts = {}
    for s = 0, 3 do
        local name = "-"
        pcall(function()
            local d = upgComp:GetPlayerUpgradeAtSlot(s)
            if UObjectUtils.IsValid(d) then
                name = d:GetFName():ToString():gsub("^PlayerUpgrade_[A-Za-z]+_", "")
            end
        end)
        parts[#parts + 1] = name
    end
    return table.concat(parts, ", ")
end

-- ============================================================================
-- ISOLATED COSMETIC, DANCE, BOSS SKILL & UPGRADE APPLICATION FOR P2
-- ============================================================================

local function WithTemporaryCosmeticAccess(defs, actionFn)
    local loadCfg = Config.Loadouts or {}
    if loadCfg.UnlockAllCosmeticsForP2 == false then
        pcall(actionFn)
        return
    end
    local saved = {}
    for _, def in ipairs(defs or {}) do
        if UObjectUtils.IsValid(def) then
            pcall(function()
                local orig = def.bAllowIfProgressionDisabled
                if type(orig) == "boolean" and orig == false then
                    def.bAllowIfProgressionDisabled = true
                    saved[#saved + 1] = { def = def, orig = orig }
                end
            end)
        end
    end
    local ok, err = pcall(actionFn)
    for i = 1, #saved do
        if UObjectUtils.IsValid(saved[i].def) then
            pcall(function() saved[i].def.bAllowIfProgressionDisabled = saved[i].orig end)
        end
    end
    if not ok then Logger.Warn("Isolation", "CosmeticAccess error: %s", tostring(err)) end
end

function PlayerStateIsolation.UnequipCosmeticsForCSM(p1Ctrl, p2Ctrl, p2Pawn, csmPPCDDef)
    ProfileStore.EnsureP2Initialized(function() return PlayerStateIsolation.CaptureP1Snapshot(p1Ctrl) end)
    if not (UObjectUtils.IsLive(p2Ctrl) and UObjectUtils.IsLive(p2Pawn)) then return false end

    local cosComp = PlayerStateIsolation.GetCosmeticComponent(p2Pawn)
    if not UObjectUtils.IsValid(cosComp) then
        Logger.Missing("Isolation", "CosmeticComponent on P2 Pawn", "UnequipCosmeticsForCSM")
        return false
    end

    local _, _, verified = PlayerStateIsolation.EnsureDedicatedP2PPD(p1Ctrl, p2Ctrl)
    if not verified then return false end

    return PlayerStateIsolation.WithScopedP2PPD(p1Ctrl, "UnequipCosmeticsForCSM", function(p2PPD)
        CatalogService.Refresh()
        local p2 = ProfileStore.GetP2()
        local defs = {}
        if UObjectUtils.IsValid(csmPPCDDef) then defs[#defs + 1] = csmPPCDDef end
        for sIdx = 0, 3 do
            if UObjectUtils.IsValid(p2.DanceSlots[sIdx]) then defs[#defs + 1] = p2.DanceSlots[sIdx] end
        end

        WithTemporaryCosmeticAccess(defs, function()
            -- Strip all 5 modular slots so custom/boss models do not wear Charlie's gear.
            if UObjectUtils.IsValid(DedicatedP2AltPPD) then
                for slot = 1, 5 do
                    pcall(function() DedicatedP2AltPPD:UnequipCosmetic(slot) end)
                    pcall(function() DedicatedP2AltPPD:ClearCosmetic(slot) end)
                end
            end
            for slot = 1, 5 do
                pcall(function() p2PPD:UnequipCosmetic(slot) end)
                pcall(function() p2PPD:ClearCosmetic(slot) end)
            end
            for sIdx = 0, 3 do
                local dDef = p2.DanceSlots[sIdx]
                if UObjectUtils.IsValid(dDef) then
                    local dTag = UObjectUtils.MakeTagStruct(dDef.CosmeticIdTag)
                    if dTag then
                        pcall(function() p2PPD:EquipDanceMoveToSlot(dTag, sIdx) end)
                        if UObjectUtils.IsValid(DedicatedP2AltPPD) then
                            pcall(function() DedicatedP2AltPPD:EquipDanceMoveToSlot(dTag, sIdx) end)
                        end
                    end
                end
            end

            pcall(function() cosComp.bUsePreviewItemSelections = false end)
            pcall(function() cosComp.bUseBlockingLoadForInitialSetup = false end)

            if UObjectUtils.IsValid(DedicatedP2AltPPD) then
                pcall(function() cosComp:SetupForPlaythroughData(DedicatedP2AltPPD) end)
            end
            if UObjectUtils.IsValid(csmPPCDDef) then
                pcall(function() p2PPD:EquipCosmetic(csmPPCDDef) end)
                pcall(function() cosComp:SetupForPlaythroughData(p2PPD) end)
                pcall(function() p2PPD:EquipCosmetic(csmPPCDDef) end)
            end
        end)
    end)
end

function PlayerStateIsolation.ApplyOutfitToP2(p1Ctrl, p2Ctrl, p2Pawn, extraPPCDDef)
    ProfileStore.EnsureP2Initialized(function() return PlayerStateIsolation.CaptureP1Snapshot(p1Ctrl) end)
    if not (UObjectUtils.IsLive(p2Ctrl) and UObjectUtils.IsLive(p2Pawn)) then return false end

    local cosComp = PlayerStateIsolation.GetCosmeticComponent(p2Pawn)
    if not UObjectUtils.IsValid(cosComp) then
        Logger.Missing("Isolation", "CosmeticComponent on P2 Pawn", "ApplyOutfitToP2")
        return false
    end

    if UObjectUtils.IsLive(p1Ctrl) and UObjectUtils.IsLive(p1Ctrl.Pawn) then
        local p1Cos = PlayerStateIsolation.GetCosmeticComponent(p1Ctrl.Pawn)
        if UObjectUtils.IsValid(p1Cos) and not UObjectUtils.Same(p1Cos, cosComp) then
            pcall(function() p1Cos.bUsePreviewItemSelections = false end)
        end
    end

    local _, _, verified = PlayerStateIsolation.EnsureDedicatedP2PPD(p1Ctrl, p2Ctrl)
    if not verified then return false end

    return PlayerStateIsolation.WithScopedP2PPD(p1Ctrl, "ApplyOutfitToP2", function(p2PPD)
        local p2 = ProfileStore.GetP2()
        local defs = {}
        for slot = 1, 5 do
            if UObjectUtils.IsValid(p2.CosmeticSlots[slot]) then defs[#defs + 1] = p2.CosmeticSlots[slot] end
        end
        for sIdx = 0, 3 do
            if UObjectUtils.IsValid(p2.DanceSlots[sIdx]) then defs[#defs + 1] = p2.DanceSlots[sIdx] end
        end
        if UObjectUtils.IsValid(extraPPCDDef) then defs[#defs + 1] = extraPPCDDef end

        WithTemporaryCosmeticAccess(defs, function()
            if UObjectUtils.IsValid(DedicatedP2AltPPD) then
                for slot = 1, 5 do pcall(function() DedicatedP2AltPPD:UnequipCosmetic(slot) end) end
            end
            for slot = 1, 5 do
                local def = p2.CosmeticSlots[slot]
                if UObjectUtils.IsValid(def) then
                    pcall(function() p2PPD:EquipCosmetic(def) end)
                end
            end
            if UObjectUtils.IsValid(extraPPCDDef) then
                pcall(function() p2PPD:EquipCosmetic(extraPPCDDef) end)
            end
            for sIdx = 0, 3 do
                local dDef = p2.DanceSlots[sIdx]
                if UObjectUtils.IsValid(dDef) then
                    local dTag = UObjectUtils.MakeTagStruct(dDef.CosmeticIdTag)
                    if dTag then pcall(function() p2PPD:EquipDanceMoveToSlot(dTag, sIdx) end) end
                end
            end

            pcall(function() cosComp.bUsePreviewItemSelections = false end)
            pcall(function() cosComp.bUseBlockingLoadForInitialSetup = false end)

            if UObjectUtils.IsValid(DedicatedP2AltPPD) then
                pcall(function() cosComp:SetupForPlaythroughData(DedicatedP2AltPPD) end)
            end
            pcall(function() cosComp:SetupForPlaythroughData(p2PPD) end)

            if UObjectUtils.IsValid(extraPPCDDef) then
                pcall(function() p2PPD:EquipCosmetic(extraPPCDDef) end)
            end
        end)
    end)
end

local function GrantOwnedOnP2PPD(p2PPD, tagStruct)
    if not (UObjectUtils.IsValid(p2PPD) and tagStruct) then return end
    local owned = false
    pcall(function() owned = (p2PPD:IsUpgradeOwned(tagStruct) == true) end)
    if not owned then
        pcall(function() p2PPD:AddOwnedUpgrade(tagStruct) end)
    end
end

local function ApplyUpgradeViaDonorBridge(p2Upg, p2PPD, targetDef, isBossSlotIdx)
    if not (UObjectUtils.IsValid(p2Upg) and UObjectUtils.IsValid(p2PPD) and UObjectUtils.IsValid(targetDef)) then
        return false
    end
    if not UObjectUtils.EnsureUpgradeDefinitionBridges() then return false end

    local donorPool = (isBossSlotIdx ~= nil) and (CatalogService.NativeBossDefs or {}) or (CatalogService.NativePassiveDefs or {})
    local donorDef = nil
    local p2 = ProfileStore.GetP2()
    for _, cand in ipairs(donorPool) do
        if UObjectUtils.IsValid(cand) and not UObjectUtils.Same(cand, targetDef) then
            local inUse = false
            if isBossSlotIdx ~= nil then
                for s = 0, 3 do
                    if UObjectUtils.IsValid(p2.BossAbilitySlots[s]) and UObjectUtils.Same(p2.BossAbilitySlots[s], cand) then
                        inUse = true
                        break
                    end
                    local liveSlot = nil
                    pcall(function() liveSlot = p2Upg:GetPlayerUpgradeAtSlot(s) end)
                    if UObjectUtils.IsValid(liveSlot) and UObjectUtils.Same(liveSlot, cand) then
                        inUse = true
                        break
                    end
                end
            end
            if not inUse then
                donorDef = cand
                break
            end
        end
    end
    if not UObjectUtils.IsValid(donorDef) and #donorPool > 0 then
        donorDef = donorPool[#donorPool]
    end
    if not UObjectUtils.IsValid(donorDef) then return false end

    local donorOrigTag = UObjectUtils.MakeTagStruct(donorDef.UpgradeIdTag)
    local targetTag = UObjectUtils.MakeTagStruct(targetDef.UpgradeIdTag)
    if not (donorOrigTag and targetTag) then return false end

    local donorWasEquipped = false
    pcall(function() donorWasEquipped = (p2Upg:IsUpgradeEquipped(donorOrigTag) == true) end)

    local savedWords = {}
    local okCopy = pcall(function()
        for idx = 0, 12 do
            local prop = "Mod_UpgWord_" .. tostring(idx)
            savedWords[idx] = donorDef[prop]
        end
        for idx = 0, 12 do
            local prop = "Mod_UpgWord_" .. tostring(idx)
            donorDef[prop] = targetDef[prop]
        end
    end)

    if okCopy then
        GrantOwnedOnP2PPD(p2PPD, targetTag)
        GrantOwnedOnP2PPD(p2PPD, donorOrigTag)
        if isBossSlotIdx ~= nil then
            pcall(function() p2Upg:EquipOrSwapBossAbilityAtSlot(donorDef, isBossSlotIdx) end)
        end
        pcall(function() p2Upg:HandleUpgradeEquippedStateChanged(donorOrigTag, true) end)
    end

    pcall(function()
        for idx = 0, 12 do
            local prop = "Mod_UpgWord_" .. tostring(idx)
            if savedWords[idx] ~= nil then
                donorDef[prop] = savedWords[idx]
            end
        end
    end)

    if donorWasEquipped and isBossSlotIdx == nil then
        local nowDonorEq = false
        pcall(function() nowDonorEq = (p2Upg:IsUpgradeEquipped(donorOrigTag) == true) end)
        if not nowDonorEq then
            pcall(function() p2Upg:HandleUpgradeEquippedStateChanged(donorOrigTag, true) end)
        end
    end

    local okVerify, verified = pcall(function() return p2Upg:IsUpgradeEquipped(targetTag) end)
    return okVerify and verified == true
end

-- Caller must hold WithScopedP2PPD.
local function SetUpgradeEquippedOnP2Comp(p2Upg, p2PPD, tagStruct, shouldBeEquipped, def)
    if not (UObjectUtils.IsValid(p2Upg) and UObjectUtils.IsValid(p2PPD) and tagStruct) then return end
    if UObjectUtils.IsValid(def) then
        pcall(function() def.bAllowIfProgressionDisabled = true end)
    end
    if shouldBeEquipped then
        GrantOwnedOnP2PPD(p2PPD, tagStruct)
    end
    local okCur, curEq = pcall(function() return p2Upg:IsUpgradeEquipped(tagStruct) end)
    if (not okCur) or ((curEq == true) ~= (shouldBeEquipped == true)) then
        pcall(function() p2Upg:HandleUpgradeEquippedStateChanged(tagStruct, shouldBeEquipped == true) end)
    end
    if shouldBeEquipped and UObjectUtils.IsValid(def) then
        local okAfter, afterEq = pcall(function() return p2Upg:IsUpgradeEquipped(tagStruct) end)
        if not (okAfter and afterEq == true) then
            ApplyUpgradeViaDonorBridge(p2Upg, p2PPD, def, nil)
        end
    end
end

-- Caller must hold WithScopedP2PPD.
-- Vacates slotIdx first because EquipOrSwapBossAbilityAtSlot refuses to overwrite
-- an occupied slot when the incoming ability is not already slotted.
local function EquipSingleBossOnP2(p2Upg, p2PPD, bossDef, slotIdx)
    if not (UObjectUtils.IsValid(p2Upg) and UObjectUtils.IsValid(p2PPD) and UObjectUtils.IsValid(bossDef)) then return end
    pcall(function() bossDef.bAllowIfProgressionDisabled = true end)
    local tagStruct = UObjectUtils.MakeTagStruct(bossDef.UpgradeIdTag)
    if not tagStruct then return end

    -- Vacate any existing ability occupying slotIdx.
    local oldAtSlot = nil
    pcall(function() oldAtSlot = p2Upg:GetPlayerUpgradeAtSlot(slotIdx) end)
    if UObjectUtils.IsValid(oldAtSlot) and not UObjectUtils.Same(oldAtSlot, bossDef) then
        local oldTag = UObjectUtils.MakeTagStruct(oldAtSlot.UpgradeIdTag)
        if oldTag then
            pcall(function() p2Upg:HandleUpgradeEquippedStateChanged(oldTag, false) end)
        end
    end

    -- Unequip bossDef if already slotted elsewhere so ApplyUpgradeToPawn rebinds it to slotIdx.
    local curAtTarget = nil
    pcall(function() curAtTarget = p2Upg:GetPlayerUpgradeAtSlot(slotIdx) end)
    local alreadyInTargetSlot = UObjectUtils.IsValid(curAtTarget) and UObjectUtils.Same(curAtTarget, bossDef)
    if not alreadyInTargetSlot then
        local okEq, isEq = pcall(function() return p2Upg:IsUpgradeEquipped(tagStruct) end)
        if okEq and isEq == true then
            pcall(function() p2Upg:HandleUpgradeEquippedStateChanged(tagStruct, false) end)
        end
    end

    -- 3. Grant ownership and bind slot on DedicatedP2PPD + p2Upg
    GrantOwnedOnP2PPD(p2PPD, tagStruct)
    pcall(function() p2Upg:EquipOrSwapBossAbilityAtSlot(bossDef, slotIdx) end)

    local postAtSlot = nil
    pcall(function() postAtSlot = p2Upg:GetPlayerUpgradeAtSlot(slotIdx) end)
    local okCur, curEq = pcall(function() return p2Upg:IsUpgradeEquipped(tagStruct) end)
    if not (okCur and curEq == true and UObjectUtils.IsValid(postAtSlot)) then
        pcall(function() p2Upg:HandleUpgradeEquippedStateChanged(tagStruct, true) end)
    end

    -- 4. Fallback donor bridge for supplemental Boss Abilities (e.g. LightningStrike) if TagIdToUpgrades didn't resolve
    local finalAtSlot = nil
    pcall(function() finalAtSlot = p2Upg:GetPlayerUpgradeAtSlot(slotIdx) end)
    if not UObjectUtils.IsValid(finalAtSlot) then
        ApplyUpgradeViaDonorBridge(p2Upg, p2PPD, bossDef, slotIdx)
    end
end

function PlayerStateIsolation.EquipBossAbilityOnP2(p1Ctrl, p2Ctrl, bossDef, slotIdx)
    if not UObjectUtils.IsValid(bossDef) then return false end
    local p2Upg, p1Upg = PlayerStateIsolation.GetVerifiedP2UpgradeComponent(p1Ctrl, p2Ctrl)
    if not UObjectUtils.IsValid(p2Upg) then return false end

    return PlayerStateIsolation.WithScopedP2PPD(p1Ctrl, "EquipBossAbilityOnP2", function(p2PPD)
        local p1Snap = SnapshotP1UpgradeState(p1Ctrl, { bossDef })
        EquipSingleBossOnP2(p2Upg, p2PPD, bossDef, slotIdx)
        VerifyP1ZeroBleed(p1Snap, "EquipBossAbilityOnP2")
        Logger.Info("Isolation", "EquipBossSlot[%d]: P2=[%s] | P1=[%s] | Mode=%s",
            slotIdx + 1, FormatUpgradeSlotSummary(p2Upg), FormatUpgradeSlotSummary(p1Upg),
            tostring(PlayerStateIsolation.Status.LastBindMode))
    end)
end

function PlayerStateIsolation.ToggleUpgradeOnP2(p1Ctrl, p2Ctrl, def)
    if not UObjectUtils.IsValid(def) then return false end
    ProfileStore.EnsureP2Initialized(function() return PlayerStateIsolation.CaptureP1Snapshot(p1Ctrl) end)

    local p2Upg = PlayerStateIsolation.GetVerifiedP2UpgradeComponent(p1Ctrl, p2Ctrl)
    if not UObjectUtils.IsValid(p2Upg) then return false end

    local tagStr = UObjectUtils.GetTagString(def.UpgradeIdTag)
    local tagStruct = UObjectUtils.MakeTagStruct(def.UpgradeIdTag)
    if not tagStruct or tagStr == "" then return false end

    return PlayerStateIsolation.WithScopedP2PPD(p1Ctrl, "ToggleUpgradeOnP2", function(p2PPD)
        local p2 = ProfileStore.GetP2()
        local upgKey = UObjectUtils.GetKey(p2Upg) or "p2"
        AppliedP2UpgradeTags[upgKey] = AppliedP2UpgradeTags[upgKey] or {}
        local nextState = (p2.ActiveUpgrades[tagStr] == nil)

        local p1Snap = SnapshotP1UpgradeState(p1Ctrl, { def })
        SetUpgradeEquippedOnP2Comp(p2Upg, p2PPD, tagStruct, nextState, def)
        VerifyP1ZeroBleed(p1Snap, "ToggleUpgradeOnP2")

        AppliedP2UpgradeTags[upgKey][tagStr] = nextState and tagStruct or nil
        p2.CustomSkillsOverride = true
        ProfileStore.SetP2Upgrade(tagStr, def, nextState)
    end)
end

function PlayerStateIsolation.AreAllUpgradesEnabledOnP2()
    local allList = CatalogService.Ordered.UpgradesByIdol and CatalogService.Ordered.UpgradesByIdol.All or {}
    if #allList == 0 then return false end
    local p2 = ProfileStore.GetP2()
    local activeCount = 0
    for _, entry in ipairs(allList) do
        if entry.TagStr and p2.ActiveUpgrades[entry.TagStr] ~= nil then
            activeCount = activeCount + 1
        end
    end
    return activeCount >= math.floor(#allList * 0.90)
end

function PlayerStateIsolation.SetAllUpgradesForP2(p1Ctrl, p2Ctrl, enableAll)
    ProfileStore.EnsureP2Initialized(function() return PlayerStateIsolation.CaptureP1Snapshot(p1Ctrl) end)
    local p2Pawn = UObjectUtils.IsLive(p2Ctrl) and p2Ctrl.Pawn or nil
    if not (UObjectUtils.IsLive(p2Ctrl) and UObjectUtils.IsLive(p2Pawn)) then return false end

    CatalogService.Refresh()
    local allList = CatalogService.Ordered.UpgradesByIdol and CatalogService.Ordered.UpgradesByIdol.All or {}
    local p2 = ProfileStore.GetP2()
    p2.CustomSkillsOverride = true

    if enableAll then
        for _, entry in ipairs(allList) do
            if UObjectUtils.IsValid(entry.Def) and entry.TagStr and entry.TagStr ~= "" then
                ProfileStore.SetP2Upgrade(entry.TagStr, entry.Def, true)
            end
        end
    else
        local keepBasics = {
            DanceMove = true, Drummerang = true, Sprint = true,
            StrongAttack = true, Windmill = true, FeverRush = true,
        }
        p2.ActiveUpgrades = {}
        p2.ActiveUpgradeNames = {}
        p2.PendingUpgradeNames = {}
        for _, entry in ipairs(allList) do
            if UObjectUtils.IsValid(entry.Def) and entry.TagStr then
                local short = entry.ObjName and entry.ObjName:gsub("^PlayerUpgrade_[A-Za-z]+_", "") or ""
                if keepBasics[short] then
                    ProfileStore.SetP2Upgrade(entry.TagStr, entry.Def, true)
                end
            end
        end
    end

    return PlayerStateIsolation.ApplyDancesAndSkillsToP2(p1Ctrl, p2Ctrl, p2Pawn)
end

function PlayerStateIsolation.ApplyDancesAndSkillsToP2(p1Ctrl, p2Ctrl, p2Pawn)
    ProfileStore.EnsureP2Initialized(function() return PlayerStateIsolation.CaptureP1Snapshot(p1Ctrl) end)
    if not (UObjectUtils.IsLive(p2Ctrl) and UObjectUtils.IsLive(p2Pawn)) then return false end

    local _, _, verified = PlayerStateIsolation.EnsureDedicatedP2PPD(p1Ctrl, p2Ctrl)
    if not verified then return false end

    return PlayerStateIsolation.WithScopedP2PPD(p1Ctrl, "ApplyDancesAndSkillsToP2", function(p2PPD)
        local p2 = ProfileStore.GetP2()

        -- 1. Equip 4 Dance Slots strictly on DedicatedP2PPD + P2's CosmeticComponent
        local cosComp = PlayerStateIsolation.GetCosmeticComponent(p2Pawn)
        if UObjectUtils.IsValid(cosComp) then
            local dDefs = {}
            for sIdx = 0, 3 do
                if UObjectUtils.IsValid(p2.DanceSlots[sIdx]) then dDefs[#dDefs + 1] = p2.DanceSlots[sIdx] end
            end
            WithTemporaryCosmeticAccess(dDefs, function()
                pcall(function() cosComp.bUsePreviewItemSelections = false end)
                for sIdx = 0, 3 do
                    local dDef = p2.DanceSlots[sIdx]
                    if UObjectUtils.IsValid(dDef) then
                        local dTag = UObjectUtils.MakeTagStruct(dDef.CosmeticIdTag)
                        if dTag then pcall(function() p2PPD:EquipDanceMoveToSlot(dTag, sIdx) end) end
                    end
                end
                if UObjectUtils.IsValid(DedicatedP2AltPPD) then
                    pcall(function() cosComp:SetupForPlaythroughData(DedicatedP2AltPPD) end)
                end
                pcall(function() cosComp:SetupForPlaythroughData(p2PPD) end)
            end)
        end

        -- 2. Apply exact P2 Upgrades & Boss Ability Slots strictly via P2's UpgradeComponent
        local p2Upg, p1Upg = PlayerStateIsolation.GetVerifiedP2UpgradeComponent(p1Ctrl, p2Ctrl)
        if not UObjectUtils.IsValid(p2Upg) then return end

        local upgKey = UObjectUtils.GetKey(p2Upg) or "p2"
        local appliedMap = {}
        AppliedP2UpgradeTags[upgKey] = appliedMap

        local wantedTags = {}
        local candidateDefs = {}
        for sIdx = 0, 3 do
            local bDef = p2.BossAbilitySlots[sIdx]
            if UObjectUtils.IsValid(bDef) then
                local ts = UObjectUtils.GetTagString(bDef.UpgradeIdTag)
                if ts ~= "" then
                    wantedTags[ts] = bDef
                    candidateDefs[#candidateDefs + 1] = bDef
                end
            end
        end
        for tagStr, def in pairs(p2.ActiveUpgrades) do
            if UObjectUtils.IsValid(def) and tagStr ~= "" then
                wantedTags[tagStr] = def
                candidateDefs[#candidateDefs + 1] = def
            end
        end

        local p1Snap = SnapshotP1UpgradeState(p1Ctrl, candidateDefs)

        CatalogService.Refresh()
        local bossTagSet = {}
        for _, entry in ipairs(CatalogService.Ordered.BossAbilities or {}) do
            if entry.TagStr and entry.TagStr ~= "" then
                bossTagSet[entry.TagStr] = true
            end
        end

        -- Step A0: Vacate any currently slotted boss abilities on p2Upg that do not match the exact target slot
        for sIdx = 0, 3 do
            local curSlotDef = nil
            pcall(function() curSlotDef = p2Upg:GetPlayerUpgradeAtSlot(sIdx) end)
            local wantSlotDef = p2.BossAbilitySlots[sIdx]
            if UObjectUtils.IsValid(curSlotDef) and (not UObjectUtils.IsValid(wantSlotDef) or not UObjectUtils.Same(curSlotDef, wantSlotDef)) then
                local oldTag = UObjectUtils.MakeTagStruct(curSlotDef.UpgradeIdTag)
                if oldTag then
                    pcall(function() p2Upg:HandleUpgradeEquippedStateChanged(oldTag, false) end)
                end
            end
        end

        -- Step A: Apply all passive / idol / active upgrades (skipping active boss ability tags
        -- when wanted so Step B binds exact slots 0..3 cleanly without clearing them)
        for _, def in ipairs(CatalogService.GetAllUpgradeDefinitions()) do
            if UObjectUtils.IsValid(def) then
                local tagStr = UObjectUtils.GetTagString(def.UpgradeIdTag)
                local tagStruct = UObjectUtils.MakeTagStruct(def.UpgradeIdTag)
                if tagStruct and tagStr ~= "" then
                    local isWanted = (wantedTags[tagStr] ~= nil)
                    if not (bossTagSet[tagStr] and isWanted) then
                        SetUpgradeEquippedOnP2Comp(p2Upg, p2PPD, tagStruct, isWanted, def)
                    end
                    if isWanted then appliedMap[tagStr] = tagStruct end
                end
            end
        end

        -- Step B: Bind P2's 4 Boss Ability Slots explicitly after passive sweep
        for sIdx = 0, 3 do
            local bDef = p2.BossAbilitySlots[sIdx]
            if UObjectUtils.IsValid(bDef) then
                local bTag = UObjectUtils.GetTagString(bDef.UpgradeIdTag)
                local bTs = UObjectUtils.MakeTagStruct(bDef.UpgradeIdTag)
                if bTag ~= "" and bTs then appliedMap[bTag] = bTs end
                EquipSingleBossOnP2(p2Upg, p2PPD, bDef, sIdx)
            end
        end

        VerifyP1ZeroBleed(p1Snap, "ApplyDancesAndSkillsToP2")
        Logger.Info("Isolation", "Applied skills to P2=[%s] | P1=[%s] | Mode=%s",
            FormatUpgradeSlotSummary(p2Upg), FormatUpgradeSlotSummary(p1Upg),
            tostring(PlayerStateIsolation.Status.LastBindMode))
    end)
end

function PlayerStateIsolation.IsUpgradeEquippedOnP2(p1Ctrl, p2Ctrl, def)
    if not UObjectUtils.IsValid(def) then return false end
    local tagStr = UObjectUtils.GetTagString(def.UpgradeIdTag)
    if tagStr ~= "" and ProfileStore.GetP2().ActiveUpgrades[tagStr] ~= nil then return true end
    local p2Upg = PlayerStateIsolation.GetVerifiedP2UpgradeComponent(p1Ctrl, p2Ctrl)
    if UObjectUtils.IsValid(p2Upg) then
        local upgKey = UObjectUtils.GetKey(p2Upg) or "p2"
        if AppliedP2UpgradeTags[upgKey] and AppliedP2UpgradeTags[upgKey][tagStr] ~= nil then
            return true
        end
    end
    return false
end

-- ============================================================================
-- EVENT-DRIVEN STRAY-DELEGATE RECONCILER & INTEGRITY AUDIT
-- ============================================================================

-- Reconciles stray P1_PPD delegate updates on P2's UpgradeComponent without touching P1.
function PlayerStateIsolation.OnHandleUpgradeStateChanged(comp, tagStruct)
    if ScopedRedirectDepth > 0 then return end
    if not SessionManager.IsP2Active() or not SessionManager.IsSafeForGameplayHooks() then return end
    if not (UObjectUtils.IsValid(comp) and tagStruct) then return end

    local owner = nil
    pcall(function() owner = comp:GetOwner() end)
    local p2Pawn = SessionManager.GetP2Pawn()
    if not (p2Pawn and UObjectUtils.IsLive(owner) and UObjectUtils.Same(owner, p2Pawn)) then return end

    local tagStr = UObjectUtils.GetTagString(tagStruct)
    if tagStr == "" then return end

    PlayerStateIsolation.Status.StrayDelegateBlockedCount = PlayerStateIsolation.Status.StrayDelegateBlockedCount + 1
    Logger.Debug("Isolation", "Intercepted stray delegate on P2 UpgradeComp (%s) -> scheduling P2-only reconcile", tagStr)

    local tagCopy = UObjectUtils.MakeTagFromString(tagStr)
    Scheduler.Defer("Isolation.ReconcileTag." .. tagStr, function()
        SessionManager.RefreshControllers()
        local p1Ctrl, p2Ctrl = SessionManager.GetP1(), SessionManager.GetP2()
        local p2Upg = PlayerStateIsolation.GetVerifiedP2UpgradeComponent(p1Ctrl, p2Ctrl)
        if not (p1Ctrl and UObjectUtils.IsValid(p2Upg) and tagCopy) then return end

        local p2 = ProfileStore.GetP2()
        local targetDef = p2.ActiveUpgrades[tagStr]
        local shouldHave = (targetDef ~= nil)
        if not shouldHave then
            for s = 0, 3 do
                local bDef = p2.BossAbilitySlots[s]
                if UObjectUtils.IsValid(bDef) and UObjectUtils.GetTagString(bDef.UpgradeIdTag) == tagStr then
                    shouldHave = true
                    targetDef = bDef
                    break
                end
            end
        end

        PlayerStateIsolation.WithScopedP2PPD(p1Ctrl, "ReconcileP2Tag", function(p2PPD)
            SetUpgradeEquippedOnP2Comp(p2Upg, p2PPD, tagCopy, shouldHave, targetDef)
        end)
    end, true)
end

-- Called when P1 edits skill tree / boss slots in Dive Bar; resyncs ONLY P2 if needed.
function PlayerStateIsolation.OnP1LoadoutEdited()
    if ScopedRedirectDepth > 0 then return end
    if not SessionManager.IsP2Active() or not SessionManager.IsSafeForGameplayHooks() then return end

    Scheduler.ReplaceDelay(250, "Isolation.ResyncP2AfterP1Edit", function()
        if ScopedRedirectDepth > 0 or not SessionManager.IsSafeForGameplayHooks() then return end
        SessionManager.RefreshControllers()
        local p1Ctrl, p2Ctrl, p2Pawn = SessionManager.GetP1(), SessionManager.GetP2(), SessionManager.GetP2Pawn()
        if p1Ctrl and p2Ctrl and p2Pawn then
            PlayerStateIsolation.ApplyDancesAndSkillsToP2(p1Ctrl, p2Ctrl, p2Pawn)
        end
    end, true)
end

function PlayerStateIsolation.AuditIntegrity()
    if not SessionManager.IsP2Active() or not SessionManager.IsSafeForGameplayHooks() then
        return true, "Solo"
    end

    local p1Ctrl, p2Ctrl = SessionManager.GetP1(), SessionManager.GetP2()
    local p1Pawn, p2Pawn = SessionManager.GetP1Pawn(), SessionManager.GetP2Pawn()
    if not (p2Ctrl and p2Pawn) then
        return false, "WaitingForP2"
    end

    local pawnOk = not (p1Pawn and UObjectUtils.Same(p1Pawn, p2Pawn))
    local ppdOk = PlayerStateIsolation.IsolatePlayer2State(p1Ctrl, p2Ctrl)

    local ascOk = true
    local asbl = UObjectUtils.GetAbilitySystemLibrary()
    if asbl and p1Pawn then
        pcall(function()
            local asc1 = asbl:GetAbilitySystemComponent(p1Pawn)
            local asc2 = asbl:GetAbilitySystemComponent(p2Pawn)
            if UObjectUtils.IsValid(asc1) and UObjectUtils.IsValid(asc2) and UObjectUtils.Same(asc1, asc2) then
                ascOk = false
                Logger.Error("Isolation", "P2 ASC aliased P1 ASC!")
            end
        end)
    end

    local upgOk = true
    local p2Upg, p1Upg = PlayerStateIsolation.GetVerifiedP2UpgradeComponent(p1Ctrl, p2Ctrl)
    if not UObjectUtils.IsValid(p2Upg) or (UObjectUtils.IsValid(p1Upg) and UObjectUtils.Same(p1Upg, p2Upg)) then
        upgOk = false
    end

    PlayerStateIsolation.Status.PawnIsolated = pawnOk
    PlayerStateIsolation.Status.ASCIsolated = ascOk
    PlayerStateIsolation.Status.UpgCompIsolated = upgOk

    local allOk = pawnOk and ppdOk and ascOk and upgOk
    return allOk, allOk and "Verified" or "Mismatch"
end

return PlayerStateIsolation
