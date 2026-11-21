-- Per-player profile state and p2_profile.json persistence (with one-time legacy migration).

local UObjectUtils = require("Utils.UObjectUtils")
local Logger = require("Utils.Logger")
local Json = require("Utils.Json")
local CatalogService = require("State.CatalogService")

local ProfileStore = {}

local Config = {}
local Callbacks = {}

local PROFILE_FILENAME = "p2_profile.json"
local LEGACY_FILENAME = "saved_p2_customization.json"
local PROFILE_SCHEMA_VERSION = 3

local function GetProfilePath()
    return UObjectUtils.GetModRootDir() .. PROFILE_FILENAME
end

local function GetLegacyPath()
    return UObjectUtils.GetModRootDir() .. LEGACY_FILENAME
end

local function CreateEmptyStore()
    return {
        Initialized = false,
        CharacterKey = "Default",
        OutfitPresetIndex = 2,
        LoadoutPresetIndex = 2,
        CustomPieceOverride = false,
        CustomSkillsOverride = false,
        CosmeticSlots = {},        -- [1..5] -> UPagodaPlayerCosmeticDefinition
        CosmeticSlotNames = {},    -- [1..5] -> canonical asset FName (survives GC)
        DanceSlots = {},           -- [0..3] -> UPagodaPlayerCosmeticDefinition (Slot 6)
        DanceSlotNames = {},       -- [0..3] -> canonical asset FName (survives GC)
        BossAbilitySlots = {},     -- [0..3] -> UPagodaPlayerUpgradeDefinition
        BossAbilitySlotNames = {}, -- [0..3] -> canonical asset FName (survives GC)
        ActiveUpgrades = {},       -- [tagStr] -> UPagodaPlayerUpgradeDefinition
        ActiveUpgradeNames = {},   -- [tagStr] -> canonical asset FName (survives GC)
        PendingUpgradeNames = {},  -- array of upgrade names not yet resolved from disk
    }
end

local function GetObjFName(def)
    if not UObjectUtils.IsValid(def) then return nil end
    local name = nil
    pcall(function() name = def:GetFName():ToString() end)
    return (type(name) == "string" and name ~= "") and name or nil
end

local function PickBool(prefVal, fallbackVal)
    if prefVal ~= nil then return prefVal == true end
    return fallbackVal == true
end

local Players = {
    [0] = CreateEmptyStore(),
    [1] = CreateEmptyStore(),
}

local function UpgradeProfileSchemaIfNeeded(data, targetPath)
    if type(data) ~= "table" then return data end
    local dirty = false
    if tonumber(data.ProfileSchemaVersion) ~= PROFILE_SCHEMA_VERSION then
        data.ProfileSchemaVersion = PROFILE_SCHEMA_VERSION
        data.ScreenMode = 0
        data.LastSplitScreenMode = 0
        data.DynamicSharedCameraEnabled = true
        dirty = true
    end
    -- Sanitize legacy FeverRush entries out of BossAbilitySlots (FeverRush is UpgradeType==1 ActiveSkill).
    if type(data.BossAbilitySlots) == "table" then
        local fallbackBosses = {
            ["0"] = "PlayerUpgrade_Dancer_VermillionDance",
            ["1"] = "PlayerUpgrade_Doll_Singularity",
            ["2"] = "PlayerUpgrade_Shred_ChainLightning",
            ["3"] = "PlayerUpgrade_Prophet_BlockAndRetaliate",
        }
        for k, v in pairs(data.BossAbilitySlots) do
            if type(v) == "string" and string.find(string.lower(v), "feverrush", 1, true) then
                data.BossAbilitySlots[k] = fallbackBosses[tostring(k)] or "PlayerUpgrade_Prophet_BlockAndRetaliate"
                dirty = true
            end
        end
    end
    -- Normalize CustomFOV to one of the discrete Wide (100) / Wider (112) presets
    if type(data.CustomFOV) == "number" then
        if data.CustomFOV >= 106.0 and data.CustomFOV ~= 112.0 then
            data.CustomFOV = 112.0
            dirty = true
        elseif data.CustomFOV < 106.0 and data.CustomFOV ~= 100.0 then
            data.CustomFOV = 100.0
            dirty = true
        end
    end
    if dirty and type(targetPath) == "string" and targetPath ~= "" then
        Json.WriteFile(targetPath, data)
    end
    return data
end

local function ReadRawProfileWithMigration()
    local mainPath = GetProfilePath()
    local data, readPath = Json.ReadFile(mainPath)
    if type(data) == "table" then
        return UpgradeProfileSchemaIfNeeded(data, mainPath), readPath, false
    end

    local legacyPath = GetLegacyPath()
    local legacyData = Json.ReadFile(legacyPath)
    if type(legacyData) == "table" then
        Logger.Info("ProfileStore", "Migrating legacy profile '%s' -> '%s'", legacyPath, mainPath)
        UpgradeProfileSchemaIfNeeded(legacyData, mainPath)
        return legacyData, mainPath, true
    end
    return nil, nil, false
end

local function ExtractStartupPrefs(data)
    return {
        TintMode = data.TintMode,
        TintPaletteIndex = data.TintPaletteIndex,
        ScreenMode = data.ScreenMode,
        LastSplitScreenMode = data.LastSplitScreenMode,
        HUDSharedScale = data.HUDSharedScale,
        ShowSharedPlayerCircles = data.ShowSharedPlayerCircles,
        ExperimentalEnabled = data.ExperimentalEnabled,
        CustomFOVEnabled = data.CustomFOVEnabled,
        CustomFOV = data.CustomFOV,
        DynamicSharedCameraEnabled = data.DynamicSharedCameraEnabled,
    }
end

function ProfileStore.Init(config, callbacks)
    Config = config or {}
    Callbacks = callbacks or {}

    local loadCfg = Config.Loadouts or {}
    Players[1].OutfitPresetIndex = loadCfg.DefaultOutfitPresetIndex or 2
    Players[1].LoadoutPresetIndex = loadCfg.DefaultLoadoutPresetIndex or 2

    local data = ReadRawProfileWithMigration()
    if type(data) == "table" and Callbacks.OnProfileLoaded then
        UObjectUtils.SafeCall("ProfileStore.StartupPrefs", Callbacks.OnProfileLoaded, ExtractStartupPrefs(data))
    end
end

function ProfileStore.GetP2()
    return Players[1]
end

function ProfileStore.GetP1Snapshot()
    return Players[0]
end

function ProfileStore.SetP2Cosmetic(slot, def)
    local p2 = Players[1]
    p2.CosmeticSlots[slot] = def
    if def == nil then
        p2.CosmeticSlotNames[slot] = nil
    else
        local fname = GetObjFName(def)
        if fname then p2.CosmeticSlotNames[slot] = fname end
    end
end

function ProfileStore.SetP2Dance(slotIdx, def)
    local p2 = Players[1]
    p2.DanceSlots[slotIdx] = def
    if def == nil then
        p2.DanceSlotNames[slotIdx] = nil
    else
        local fname = GetObjFName(def)
        if fname then p2.DanceSlotNames[slotIdx] = fname end
    end
end

function ProfileStore.SetP2BossAbility(slotIdx, def)
    local p2 = Players[1]
    p2.BossAbilitySlots[slotIdx] = def
    if def == nil then
        p2.BossAbilitySlotNames[slotIdx] = nil
    else
        local fname = GetObjFName(def)
        if fname then p2.BossAbilitySlotNames[slotIdx] = fname end
    end
end

function ProfileStore.SetP2Upgrade(tagStr, def, enabled)
    if type(tagStr) ~= "string" or tagStr == "" then return end
    local p2 = Players[1]
    if enabled then
        p2.ActiveUpgrades[tagStr] = def
        local fname = GetObjFName(def)
        if fname then p2.ActiveUpgradeNames[tagStr] = fname end
    else
        p2.ActiveUpgrades[tagStr] = nil
        p2.ActiveUpgradeNames[tagStr] = nil
    end
end

function ProfileStore.SyncCanonicalNamesFromLive()
    local p2 = Players[1]
    for slot = 1, 5 do
        local fn = GetObjFName(p2.CosmeticSlots[slot])
        if fn then p2.CosmeticSlotNames[slot] = fn end
    end
    for sIdx = 0, 3 do
        local dn = GetObjFName(p2.DanceSlots[sIdx])
        if dn then p2.DanceSlotNames[sIdx] = dn end
        local bn = GetObjFName(p2.BossAbilitySlots[sIdx])
        if bn then p2.BossAbilitySlotNames[sIdx] = bn end
    end
    for tagStr, def in pairs(p2.ActiveUpgrades) do
        local un = GetObjFName(def)
        if un then p2.ActiveUpgradeNames[tagStr] = un end
    end
end

function ProfileStore.RehydrateFromCatalog()
    CatalogService.Refresh(not CatalogService.IsReady())
    if not CatalogService.IsReady() then return 0 end

    local p2 = Players[1]
    local fixed = 0

    for slot = 1, 5 do
        if not UObjectUtils.IsValid(p2.CosmeticSlots[slot]) then
            local name = p2.CosmeticSlotNames[slot]
            if type(name) == "string" and name ~= "" then
                local def = CatalogService.FindCosmetic(slot, name)
                if UObjectUtils.IsValid(def) then
                    p2.CosmeticSlots[slot] = def
                    fixed = fixed + 1
                end
            end
        else
            local fn = GetObjFName(p2.CosmeticSlots[slot])
            if fn then p2.CosmeticSlotNames[slot] = fn end
        end
    end

    for sIdx = 0, 3 do
        if not UObjectUtils.IsValid(p2.DanceSlots[sIdx]) then
            local name = p2.DanceSlotNames[sIdx]
            if type(name) == "string" and name ~= "" then
                local dDef = CatalogService.FindDance(name)
                if UObjectUtils.IsValid(dDef) then
                    p2.DanceSlots[sIdx] = dDef
                    fixed = fixed + 1
                end
            end
        else
            local dn = GetObjFName(p2.DanceSlots[sIdx])
            if dn then p2.DanceSlotNames[sIdx] = dn end
        end

        if not UObjectUtils.IsValid(p2.BossAbilitySlots[sIdx]) then
            local name = p2.BossAbilitySlotNames[sIdx]
            if type(name) == "string" and name ~= "" then
                local bDef = CatalogService.FindBossAbility(name)
                if UObjectUtils.IsValid(bDef) then
                    p2.BossAbilitySlots[sIdx] = bDef
                    fixed = fixed + 1
                end
            end
        else
            local bn = GetObjFName(p2.BossAbilitySlots[sIdx])
            if bn then p2.BossAbilitySlotNames[sIdx] = bn end
        end
    end

    for tagStr, name in pairs(p2.ActiveUpgradeNames) do
        if not UObjectUtils.IsValid(p2.ActiveUpgrades[tagStr]) and type(name) == "string" and name ~= "" then
            local uDef = CatalogService.FindUpgrade(name)
            if UObjectUtils.IsValid(uDef) then
                p2.ActiveUpgrades[tagStr] = uDef
                fixed = fixed + 1
            end
        end
    end

    if #p2.PendingUpgradeNames > 0 then
        local remaining = {}
        for _, name in ipairs(p2.PendingUpgradeNames) do
            local uDef = CatalogService.FindUpgrade(name)
            if UObjectUtils.IsValid(uDef) then
                local ts = UObjectUtils.GetTagString(uDef.UpgradeIdTag)
                if ts ~= "" then
                    p2.ActiveUpgrades[ts] = uDef
                    p2.ActiveUpgradeNames[ts] = GetObjFName(uDef) or name
                    fixed = fixed + 1
                else
                    remaining[#remaining + 1] = name
                end
            else
                remaining[#remaining + 1] = name
            end
        end
        p2.PendingUpgradeNames = remaining
    end

    if fixed > 0 then
        Logger.Info("ProfileStore", "Rehydrated %d GC'd Player 2 asset reference(s) from catalog.", fixed)
    end
    return fixed
end

function ProfileStore.ApplyOutfitPresetToStore(presetIdx)
    CatalogService.Refresh()
    if not CatalogService.IsReady() then return nil end

    local loadCfg = Config.Loadouts or {}
    local presets = loadCfg.OutfitPresets or {}
    if #presets == 0 then return nil end

    local p2 = Players[1]
    local idx = ((presetIdx - 1) % #presets) + 1
    p2.OutfitPresetIndex = idx
    local preset = presets[idx]
    if not preset then return nil end

    local spec = {
        [1] = preset.BodyType or "Default",
        [2] = preset.Jacket or "Default",
        [3] = preset.Glasses or "Default",
        [4] = preset.Drumsticks or "Default",
        [5] = preset.Hair or "Default",
    }
    for slot = 1, 5 do
        local def = CatalogService.FindCosmetic(slot, spec[slot])
        if not UObjectUtils.IsValid(def) then
            def = CatalogService.FindCosmetic(slot, "default")
        end
        if UObjectUtils.IsValid(def) then
            ProfileStore.SetP2Cosmetic(slot, def)
        end
    end
    p2.CustomPieceOverride = false
    return preset.Name or ("Preset #" .. tostring(p2.OutfitPresetIndex))
end

function ProfileStore.ApplyLoadoutPresetToStore(presetIdx, p1SnapshotProvider)
    CatalogService.Refresh()
    local loadCfg = Config.Loadouts or {}
    local presets = loadCfg.LoadoutPresets or {}

    local p2 = Players[1]
    local loadout = nil
    if #presets > 0 then
        local idx = ((presetIdx - 1) % #presets) + 1
        p2.LoadoutPresetIndex = idx
        loadout = presets[idx]
    end

    local danceKeys = (loadout and loadout.Dances)
        or { "SalsaFan", "HonestHips", "BadBoyBoogie", "AbsoluteDisco" }

    for sIdx = 0, 3 do
        local def = danceKeys[sIdx + 1] and CatalogService.FindDance(danceKeys[sIdx + 1])
        if UObjectUtils.IsValid(def) then
            ProfileStore.SetP2Dance(sIdx, def)
        end
    end

    if p2.CustomSkillsOverride then
        return (loadout and loadout.Name) or "Custom Loadout"
    end

    p2.BossAbilitySlots = {}
    p2.BossAbilitySlotNames = {}
    p2.ActiveUpgrades = {}
    p2.ActiveUpgradeNames = {}
    p2.PendingUpgradeNames = {}

    local mirrorP1 = (not loadout or loadout.MirrorPlayer1Skills == true)
    if mirrorP1 and type(p1SnapshotProvider) == "function" then
        local snap = p1SnapshotProvider()
        if snap then
            for tagStr, def in pairs(snap.ActiveUpgrades or {}) do
                if UObjectUtils.IsValid(def) then
                    ProfileStore.SetP2Upgrade(tagStr, def, true)
                end
            end
            for s = 0, 3 do
                if UObjectUtils.IsValid(snap.BossAbilitySlots and snap.BossAbilitySlots[s]) then
                    ProfileStore.SetP2BossAbility(s, snap.BossAbilitySlots[s])
                end
            end
        end
    else
        local uKeys = (loadout and loadout.Upgrades) or {}
        local bKeys = (loadout and loadout.BossAbilities) or {}
        for _, uk in ipairs(uKeys) do
            local def = CatalogService.FindUpgrade(uk)
            if UObjectUtils.IsValid(def) then
                local ts = UObjectUtils.GetTagString(def.UpgradeIdTag)
                if ts ~= "" then
                    ProfileStore.SetP2Upgrade(ts, def, true)
                end
            end
        end
        for s = 0, 3 do
            local bDef = bKeys[s + 1] and CatalogService.FindBossAbility(bKeys[s + 1])
            if UObjectUtils.IsValid(bDef) then
                ProfileStore.SetP2BossAbility(s, bDef)
            end
        end
    end

    return (loadout and loadout.Name) or "Custom Loadout"
end

function ProfileStore.SaveP2Profile(extraFields)
    local p2 = Players[1]
    local profilePath = GetProfilePath()

    if not p2.Initialized then
        local existing = ReadRawProfileWithMigration()
        if type(existing) ~= "table" then existing = {} end
        existing.ProfileSchemaVersion = PROFILE_SCHEMA_VERSION
        if extraFields then
            for _, fieldName in ipairs({
                "TintMode", "TintPaletteIndex", "ScreenMode", "LastSplitScreenMode",
                "HUDSharedScale", "ShowSharedPlayerCircles", "ExperimentalEnabled",
                "CustomFOVEnabled", "CustomFOV", "DynamicSharedCameraEnabled",
            }) do
                if extraFields[fieldName] ~= nil then
                    existing[fieldName] = extraFields[fieldName]
                end
            end
        end
        return Json.WriteFile(profilePath, existing)
    end

    ProfileStore.SyncCanonicalNamesFromLive()

    local cosmeticNames, danceNames, bossNames, upgNames, upgSeen = {}, {}, {}, {}, {}
    for slot = 1, 5 do
        local name = GetObjFName(p2.CosmeticSlots[slot]) or p2.CosmeticSlotNames[slot]
        if type(name) == "string" and name ~= "" then
            cosmeticNames[tostring(slot)] = name
        end
    end
    for sIdx = 0, 3 do
        local dName = GetObjFName(p2.DanceSlots[sIdx]) or p2.DanceSlotNames[sIdx]
        if type(dName) == "string" and dName ~= "" then
            danceNames[tostring(sIdx)] = dName
        end
        local bName = GetObjFName(p2.BossAbilitySlots[sIdx]) or p2.BossAbilitySlotNames[sIdx]
        if type(bName) == "string" and bName ~= "" then
            bossNames[tostring(sIdx)] = bName
        end
    end
    for tagStr, def in pairs(p2.ActiveUpgrades) do
        local uName = GetObjFName(def) or p2.ActiveUpgradeNames[tagStr]
        if type(uName) == "string" and uName ~= "" and not upgSeen[uName] then
            upgSeen[uName] = true
            upgNames[#upgNames + 1] = uName
        end
    end
    for tagStr, uName in pairs(p2.ActiveUpgradeNames) do
        if type(uName) == "string" and uName ~= "" and not upgSeen[uName] then
            upgSeen[uName] = true
            upgNames[#upgNames + 1] = uName
        end
    end
    for _, uName in ipairs(p2.PendingUpgradeNames or {}) do
        if type(uName) == "string" and uName ~= "" and not upgSeen[uName] then
            upgSeen[uName] = true
            upgNames[#upgNames + 1] = uName
        end
    end
    table.sort(upgNames)

    local vpCfg = Config.Viewport or {}
    local hudCfg = Config.HUD or {}
    local charCfg = Config.Characters or {}
    local expCfg = Config.Experimental or {}

    local payload = {
        ProfileSchemaVersion = PROFILE_SCHEMA_VERSION,
        OutfitPresetIndex = p2.OutfitPresetIndex or 2,
        LoadoutPresetIndex = p2.LoadoutPresetIndex or 2,
        CustomPieceOverride = (p2.CustomPieceOverride == true),
        CustomSkillsOverride = (p2.CustomSkillsOverride == true),
        CustomCharacterKey = p2.CharacterKey or "Default",
        CosmeticSlots = cosmeticNames,
        DanceSlots = danceNames,
        BossAbilitySlots = bossNames,
        ActiveUpgrades = upgNames,
        TintMode = (extraFields and extraFields.TintMode) or charCfg.TintMode or "AccentOnly",
        TintPaletteIndex = (extraFields and extraFields.TintPaletteIndex) or 1,
        ScreenMode = (extraFields and extraFields.ScreenMode ~= nil) and extraFields.ScreenMode or (vpCfg.ScreenMode or 0),
        LastSplitScreenMode = (extraFields and extraFields.LastSplitScreenMode == 1) and 1 or 0,
        HUDSharedScale = (extraFields and tonumber(extraFields.HUDSharedScale)) or hudCfg.SharedScreenScale or 0.78,
        ShowSharedPlayerCircles = PickBool(extraFields and extraFields.ShowSharedPlayerCircles, hudCfg.ShowSharedPlayerCircles ~= false),
        ExperimentalEnabled = PickBool(extraFields and extraFields.ExperimentalEnabled, expCfg.Enabled == true),
        CustomFOVEnabled = PickBool(extraFields and extraFields.CustomFOVEnabled, vpCfg.CustomFOVEnabled == true),
        CustomFOV = (extraFields and tonumber(extraFields.CustomFOV)) or vpCfg.CustomFOV or 90.0,
        DynamicSharedCameraEnabled = PickBool(extraFields and extraFields.DynamicSharedCameraEnabled, vpCfg.EnableDynamicSharedCamera ~= false),
    }

    local okWrite = Json.WriteFile(profilePath, payload)
    if okWrite then
        Logger.Debug("ProfileStore", "Saved P2 profile (char=%s, upgrades=%d).",
            tostring(payload.CustomCharacterKey), #upgNames)
    end
    return okWrite
end

function ProfileStore.LoadP2Profile()
    CatalogService.Refresh(not CatalogService.IsReady())
    local data = ReadRawProfileWithMigration()
    if type(data) ~= "table" then return nil end

    local p2 = Players[1]
    if type(data.OutfitPresetIndex) == "number" then p2.OutfitPresetIndex = data.OutfitPresetIndex end
    if type(data.LoadoutPresetIndex) == "number" then p2.LoadoutPresetIndex = data.LoadoutPresetIndex end
    if type(data.CustomCharacterKey) == "string" and data.CustomCharacterKey ~= "" then
        p2.CharacterKey = data.CustomCharacterKey
    end

    if type(data.CosmeticSlots) == "table" then
        for slot = 1, 5 do
            local name = data.CosmeticSlots[tostring(slot)]
            if type(name) == "string" and name ~= "" then
                p2.CosmeticSlotNames[slot] = name
                local def = CatalogService.FindCosmetic(slot, name)
                if UObjectUtils.IsValid(def) then
                    ProfileStore.SetP2Cosmetic(slot, def)
                end
            end
        end
        p2.CustomPieceOverride = (data.CustomPieceOverride == true)
    end

    if type(data.DanceSlots) == "table" then
        for sIdx = 0, 3 do
            local name = data.DanceSlots[tostring(sIdx)]
            if type(name) == "string" and name ~= "" then
                p2.DanceSlotNames[sIdx] = name
                local dDef = CatalogService.FindDance(name)
                if UObjectUtils.IsValid(dDef) then
                    ProfileStore.SetP2Dance(sIdx, dDef)
                end
            end
        end
    end

    if type(data.BossAbilitySlots) == "table" then
        local anyBoss = false
        for sIdx = 0, 3 do
            local name = data.BossAbilitySlots[tostring(sIdx)]
            if type(name) == "string" and name ~= "" then
                p2.BossAbilitySlotNames[sIdx] = name
                local bDef = CatalogService.FindBossAbility(name)
                if UObjectUtils.IsValid(bDef) then
                    p2.BossAbilitySlotNames[sIdx] = GetObjFName(bDef) or name
                    ProfileStore.SetP2BossAbility(sIdx, bDef)
                    anyBoss = true
                end
            end
        end
        if anyBoss or data.CustomSkillsOverride == true then p2.CustomSkillsOverride = true end
    end

    if type(data.ActiveUpgrades) == "table" then
        local anyUpg = false
        local loadedUpgs = {}
        local loadedNames = {}
        local pendingNames = {}
        for _, name in ipairs(data.ActiveUpgrades) do
            if type(name) == "string" and name ~= "" then
                anyUpg = true
                local uDef = CatalogService.FindUpgrade(name)
                if UObjectUtils.IsValid(uDef) then
                    local ts = UObjectUtils.GetTagString(uDef.UpgradeIdTag)
                    if ts ~= "" then
                        loadedUpgs[ts] = uDef
                        loadedNames[ts] = GetObjFName(uDef) or name
                    else
                        pendingNames[#pendingNames + 1] = name
                    end
                else
                    pendingNames[#pendingNames + 1] = name
                end
            end
        end
        if anyUpg then
            p2.ActiveUpgrades = loadedUpgs
            p2.ActiveUpgradeNames = loadedNames
            p2.PendingUpgradeNames = pendingNames
            p2.CustomSkillsOverride = true
        end
    end

    local extras = ExtractStartupPrefs(data)
    Logger.Info("ProfileStore", "Loaded P2 profile from '%s' (char=%s).",
        GetProfilePath(), tostring(p2.CharacterKey))
    if Callbacks.OnProfileLoaded then
        UObjectUtils.SafeCall("ProfileStore.OnProfileLoaded", Callbacks.OnProfileLoaded, extras)
    end
    return extras
end

function ProfileStore.EnsureP2Initialized(p1SnapshotProvider)
    CatalogService.Refresh()
    local p2 = Players[1]
    if p2.Initialized then return true end
    if not CatalogService.IsReady() then return false end

    ProfileStore.ApplyOutfitPresetToStore(p2.OutfitPresetIndex)
    ProfileStore.ApplyLoadoutPresetToStore(p2.LoadoutPresetIndex, p1SnapshotProvider)
    p2.Initialized = true
    ProfileStore.LoadP2Profile()
    return true
end

function ProfileStore.FindP2DanceSlot(def)
    if not UObjectUtils.IsValid(def) then return nil end
    local slots = Players[1].DanceSlots
    for s = 0, 3 do
        if UObjectUtils.IsValid(slots[s]) and UObjectUtils.Same(slots[s], def) then
            return s
        end
    end
    return nil
end

function ProfileStore.FindP2BossSlot(def)
    if not UObjectUtils.IsValid(def) then return nil end
    local slots = Players[1].BossAbilitySlots
    for s = 0, 3 do
        if UObjectUtils.IsValid(slots[s]) and UObjectUtils.Same(slots[s], def) then
            return s
        end
    end
    return nil
end

function ProfileStore.GetSlotDisplayName(def)
    if not UObjectUtils.IsValid(def) then return "Empty" end
    local fallback = "Item"
    pcall(function() fallback = def:GetFName():ToString() end)
    return UObjectUtils.GetTextString(def.DisplayName, fallback)
end

return ProfileStore
