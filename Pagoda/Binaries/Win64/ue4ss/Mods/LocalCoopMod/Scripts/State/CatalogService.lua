-- Indexes cosmetics, dances, boss abilities, and idol upgrades from the native
-- catalog subsystems plus cooked upgrade DataAssets not yet unlocked in P1's save.

local UObjectUtils = require("Utils.UObjectUtils")
local Logger = require("Utils.Logger")

local CatalogService = {}

local LastCosmeticCount = 0
local LastUpgradeCount = 0
local SupplementalUpgradesScanned = false
local LastLoggedSummary = nil

CatalogService.Lookup = {
    CosmeticsBySlot = nil, -- [1..5][normKey] -> Def
    Dances = nil,          -- [normKey] -> Def
    Upgrades = nil,        -- [normKey] -> Def
    BossAbilities = nil,   -- [normKey] -> Def
}

CatalogService.Ordered = {
    CosmeticsBySlot = { [1] = {}, [2] = {}, [3] = {}, [4] = {}, [5] = {} },
    Dances = {},
    BossAbilities = {},
    UpgradesByIdol = { All = {} },
    AllUpgrades = {},
    IdolOrder = {},
}

local KNOWN_IDOL_PRIORITY = {
    Dancer  = 1,
    Shred   = 2,
    Rebel   = 3,
    Prophet = 4,
    Doll    = 5,
    Charlie = 6,
}

-- Core 4-slot directional boss / marquee moves (UpgradeType == 2 BossAbility)
-- Note: FeverRush has UpgradeType == 1 (ActiveSkill), so it belongs in Charlie's active skills, not the 4 directional Boss slots.
local KNOWN_BOSS_ABILITY_NAMES = {
    vermilliondance = true,
    chainlightning = true,
    lightningstrike = true,
    dropthebaxe = true,
    blockandretaliate = true,
    singularity = true,
}

CatalogService.NativeTagSet = {}
CatalogService.NativePassiveDefs = {}
CatalogService.NativeBossDefs = {}

-- Complete verified manifest of cooked PlayerUpgrade_* assets from Pagoda-Windows.utoc
-- (excluding *_EmptyTemplate placeholders) so uncollected Idol moves/upgrades are
-- always present in Player 2's catalog and apply cleanly.
local COOKED_UPGRADE_PATHS = {
    -- CHARLIE
    "/Game/Pagoda/Characters/Player/Upgrades/CHARLIE/PlayerUpgrade_Charlie_DanceMove",
    "/Game/Pagoda/Characters/Player/Upgrades/CHARLIE/PlayerUpgrade_Charlie_DanceMove_Energized",
    "/Game/Pagoda/Characters/Player/Upgrades/CHARLIE/PlayerUpgrade_Charlie_DanceMove_FeverGainOncePerSong",
    "/Game/Pagoda/Characters/Player/Upgrades/CHARLIE/PlayerUpgrade_Charlie_Drummerang",
    "/Game/Pagoda/Characters/Player/Upgrades/CHARLIE/PlayerUpgrade_Charlie_Drummerang_ExtraStock_01",
    "/Game/Pagoda/Characters/Player/Upgrades/CHARLIE/PlayerUpgrade_Charlie_Drummerang_ExtraStock_02",
    "/Game/Pagoda/Characters/Player/Upgrades/CHARLIE/PlayerUpgrade_Charlie_ExtraTakedownToken_01",
    "/Game/Pagoda/Characters/Player/Upgrades/CHARLIE/PlayerUpgrade_Charlie_FasterTakedownTokenProgress_01",
    "/Game/Pagoda/Characters/Player/Upgrades/CHARLIE/PlayerUpgrade_Charlie_FeverRush",
    "/Game/Pagoda/Characters/Player/Upgrades/CHARLIE/PlayerUpgrade_Charlie_FeverRush_HitReactImmune",
    "/Game/Pagoda/Characters/Player/Upgrades/CHARLIE/PlayerUpgrade_Charlie_HealOnConsecutiveTakedowns",
    "/Game/Pagoda/Characters/Player/Upgrades/CHARLIE/PlayerUpgrade_Charlie_HealthUp_01",
    "/Game/Pagoda/Characters/Player/Upgrades/CHARLIE/PlayerUpgrade_Charlie_HealthUp_02",
    "/Game/Pagoda/Characters/Player/Upgrades/CHARLIE/PlayerUpgrade_Charlie_HealthUp_03",
    "/Game/Pagoda/Characters/Player/Upgrades/CHARLIE/PlayerUpgrade_Charlie_MaxFeverUp_01",
    "/Game/Pagoda/Characters/Player/Upgrades/CHARLIE/PlayerUpgrade_Charlie_MaxFeverUp_02",
    "/Game/Pagoda/Characters/Player/Upgrades/CHARLIE/PlayerUpgrade_Charlie_MaxFeverUp_03",
    "/Game/Pagoda/Characters/Player/Upgrades/CHARLIE/PlayerUpgrade_Charlie_PerfectHitExtraDamageAndFever",
    "/Game/Pagoda/Characters/Player/Upgrades/CHARLIE/PlayerUpgrade_Charlie_SlowerFeverDrain",
    "/Game/Pagoda/Characters/Player/Upgrades/CHARLIE/PlayerUpgrade_Charlie_Sprint",
    "/Game/Pagoda/Characters/Player/Upgrades/CHARLIE/PlayerUpgrade_Charlie_StayinAlive",
    "/Game/Pagoda/Characters/Player/Upgrades/CHARLIE/PlayerUpgrade_Charlie_StrongAttack",
    "/Game/Pagoda/Characters/Player/Upgrades/CHARLIE/PlayerUpgrade_Charlie_Windmill",
    "/Game/Pagoda/Characters/Player/Upgrades/CHARLIE/PlayerUpgrade_Charlie_Windmill_IncreaseDuration",

    -- DANCER (DAHLIA)
    "/Game/Pagoda/Characters/Player/Upgrades/Dancer/PlayerUpgrade_Dancer_AoeBurnOnStrongDrummerang",
    "/Game/Pagoda/Characters/Player/Upgrades/Dancer/PlayerUpgrade_Dancer_BurnDurationUp",
    "/Game/Pagoda/Characters/Player/Upgrades/Dancer/PlayerUpgrade_Dancer_FlashbackExtraDamage",
    "/Game/Pagoda/Characters/Player/Upgrades/Dancer/PlayerUpgrade_Dancer_MaxFeverUp_01",
    "/Game/Pagoda/Characters/Player/Upgrades/Dancer/PlayerUpgrade_Dancer_PerfectDodgeFeverRegen",
    "/Game/Pagoda/Characters/Player/Upgrades/Dancer/PlayerUpgrade_Dancer_PyroetteAoeOnHit",
    "/Game/Pagoda/Characters/Player/Upgrades/Dancer/PlayerUpgrade_Dancer_PyroetteDurationUp",
    "/Game/Pagoda/Characters/Player/Upgrades/Dancer/PlayerUpgrade_Dancer_VDance_BurningStrikeOnFollowup",
    "/Game/Pagoda/Characters/Player/Upgrades/Dancer/PlayerUpgrade_Dancer_VDance_EmpoweredFollowup",
    "/Game/Pagoda/Characters/Player/Upgrades/Dancer/PlayerUpgrade_Dancer_VermillionDance",

    -- DOLL (ARORA)
    "/Game/Pagoda/Characters/Player/Upgrades/Doll/PlayerUpgrade_Doll_AerialTakedown_AddPull",
    "/Game/Pagoda/Characters/Player/Upgrades/Doll/PlayerUpgrade_Doll_ConeBlastHitReactImmunity",
    "/Game/Pagoda/Characters/Player/Upgrades/Doll/PlayerUpgrade_Doll_DanceMove_HealOnLowHealth",
    "/Game/Pagoda/Characters/Player/Upgrades/Doll/PlayerUpgrade_Doll_HealthUp_01",
    "/Game/Pagoda/Characters/Player/Upgrades/Doll/PlayerUpgrade_Doll_HellishPact",
    "/Game/Pagoda/Characters/Player/Upgrades/Doll/PlayerUpgrade_Doll_MaxFeverUp_01",
    "/Game/Pagoda/Characters/Player/Upgrades/Doll/PlayerUpgrade_Doll_RangedFloatOnPerfectHit",
    "/Game/Pagoda/Characters/Player/Upgrades/Doll/PlayerUpgrade_Doll_Singularity",
    "/Game/Pagoda/Characters/Player/Upgrades/Doll/PlayerUpgrade_Doll_Singularity_ExtraDurationOnPerfect",
    "/Game/Pagoda/Characters/Player/Upgrades/Doll/PlayerUpgrade_Doll_Singularity_SizeIncrease",
    "/Game/Pagoda/Characters/Player/Upgrades/Doll/PlayerUpgrade_Doll_Singularity_SpeedIncrease",
    "/Game/Pagoda/Characters/Player/Upgrades/Doll/PlayerUpgrade_Doll_Singularity_Upgrade_01",
    "/Game/Pagoda/Characters/Player/Upgrades/Doll/PlayerUpgrade_Doll_StrongRangedAttack",
    "/Game/Pagoda/Characters/Player/Upgrades/Doll/PlayerUpgrade_Doll_StunningStrike_Float",
    "/Game/Pagoda/Characters/Player/Upgrades/Doll/PlayerUpgrade_Doll_Windmill_AddSingularity",

    -- PROPHET
    "/Game/Pagoda/Characters/Player/Upgrades/Prophet/PlayerUpgrade_Prophet_BlockAndRetaliate",
    "/Game/Pagoda/Characters/Player/Upgrades/Prophet/PlayerUpgrade_Prophet_Block_ReducedFeverCost",
    "/Game/Pagoda/Characters/Player/Upgrades/Prophet/PlayerUpgrade_Prophet_Block_SuperArmor",
    "/Game/Pagoda/Characters/Player/Upgrades/Prophet/PlayerUpgrade_Prophet_FeverUpgrade",
    "/Game/Pagoda/Characters/Player/Upgrades/Prophet/PlayerUpgrade_Prophet_HealthUp",
    "/Game/Pagoda/Characters/Player/Upgrades/Prophet/PlayerUpgrade_Prophet_SprintStartArmor",

    -- REBEL
    "/Game/Pagoda/Characters/Player/Upgrades/Rebel/PlayerUpgrade_Rebel_BasicAttackBreakShield",
    "/Game/Pagoda/Characters/Player/Upgrades/Rebel/PlayerUpgrade_Rebel_DropTheBaxe",
    "/Game/Pagoda/Characters/Player/Upgrades/Rebel/PlayerUpgrade_Rebel_DropTheBaxe_AoeSize",
    "/Game/Pagoda/Characters/Player/Upgrades/Rebel/PlayerUpgrade_Rebel_DropTheBaxe_ExtraPerfectDamage",
    "/Game/Pagoda/Characters/Player/Upgrades/Rebel/PlayerUpgrade_Rebel_DropTheBaxe_FeverGainBoost",
    "/Game/Pagoda/Characters/Player/Upgrades/Rebel/PlayerUpgrade_Rebel_DropTheBaxe_Upgrade_01",
    "/Game/Pagoda/Characters/Player/Upgrades/Rebel/PlayerUpgrade_Rebel_FeverOnPowerupPickup",
    "/Game/Pagoda/Characters/Player/Upgrades/Rebel/PlayerUpgrade_Rebel_HazardDamageReduction",
    "/Game/Pagoda/Characters/Player/Upgrades/Rebel/PlayerUpgrade_Rebel_HealthUp_01",
    "/Game/Pagoda/Characters/Player/Upgrades/Rebel/PlayerUpgrade_Rebel_HellishPact_01",
    "/Game/Pagoda/Characters/Player/Upgrades/Rebel/PlayerUpgrade_Rebel_MaxFeverUp_01",
    "/Game/Pagoda/Characters/Player/Upgrades/Rebel/PlayerUpgrade_Rebel_StrongAttack_AddKnockbackDistance",
    "/Game/Pagoda/Characters/Player/Upgrades/Rebel/PlayerUpgrade_Rebel_StrongAttack_FasterChargeUp",
    "/Game/Pagoda/Characters/Player/Upgrades/Rebel/PlayerUpgrade_Rebel_StrongAttack_FollowUp",
    "/Game/Pagoda/Characters/Player/Upgrades/Rebel/PlayerUpgrade_Rebel_StrongAttack_HitReactImmune",
    "/Game/Pagoda/Characters/Player/Upgrades/Rebel/PlayerUpgrade_Rebel_StrongAttack_IncreaseDamage",
    "/Game/Pagoda/Characters/Player/Upgrades/Rebel/PlayerUpgrade_Rebel_StrongAttack_ReduceIncomingDamage",
    "/Game/Pagoda/Characters/Player/Upgrades/Rebel/PlayerUpgrade_Rebel_StrongAttack_VehicleImmunityDuringCharge",

    -- SHRED
    "/Game/Pagoda/Characters/Player/Upgrades/Shred/PlayerUpgrade_Shred_AmpedIfShockedTargets",
    "/Game/Pagoda/Characters/Player/Upgrades/Shred/PlayerUpgrade_Shred_ChainLightning",
    "/Game/Pagoda/Characters/Player/Upgrades/Shred/PlayerUpgrade_Shred_ChainLightning_Upgrade01",
    "/Game/Pagoda/Characters/Player/Upgrades/Shred/PlayerUpgrade_Shred_Drummerang_FollowUp",
    "/Game/Pagoda/Characters/Player/Upgrades/Shred/PlayerUpgrade_Shred_ExtraFeverOnShockedTargets",
    "/Game/Pagoda/Characters/Player/Upgrades/Shred/PlayerUpgrade_Shred_FeverDrainExtraOnPerfect",
    "/Game/Pagoda/Characters/Player/Upgrades/Shred/PlayerUpgrade_Shred_LightningStrike",
    "/Game/Pagoda/Characters/Player/Upgrades/Shred/PlayerUpgrade_Shred_LightningStrike_FeverOnPerfect",
    "/Game/Pagoda/Characters/Player/Upgrades/Shred/PlayerUpgrade_Shred_LightningStrike_IncreaseWidth",
    "/Game/Pagoda/Characters/Player/Upgrades/Shred/PlayerUpgrade_Shred_LightningStrike_ShockAoe",
    "/Game/Pagoda/Characters/Player/Upgrades/Shred/PlayerUpgrade_Shred_LightningStrike_Upgrade01",
    "/Game/Pagoda/Characters/Player/Upgrades/Shred/PlayerUpgrade_Shred_LongerShocked",
    "/Game/Pagoda/Characters/Player/Upgrades/Shred/PlayerUpgrade_Shred_MaxFeverUp_01",
    "/Game/Pagoda/Characters/Player/Upgrades/Shred/PlayerUpgrade_Shred_MaxHealthUp_01",
    "/Game/Pagoda/Characters/Player/Upgrades/Shred/PlayerUpgrade_Shred_PerfectCounter_AddAOE",
    "/Game/Pagoda/Characters/Player/Upgrades/Shred/PlayerUpgrade_Shred_PerfectInputFeverGainUp",
    "/Game/Pagoda/Characters/Player/Upgrades/Shred/PlayerUpgrade_Shred_PerfectLightning",
    "/Game/Pagoda/Characters/Player/Upgrades/Shred/PlayerUpgrade_Shred_StrongAttack_AddShocked",
    "/Game/Pagoda/Characters/Player/Upgrades/Shred/PlayerUpgrade_Shred_Windmill_AddShocked",
}

local function ExtractIdolFromUpgrade(def)
    local objName = ""
    local fullPath = ""
    pcall(function() objName = def:GetFName():ToString() end)
    pcall(function() fullPath = def:GetFullName() end)

    local folderIdol = fullPath:match("/[Uu]pgrades/([^/]+)/")
    if folderIdol and folderIdol ~= "" then
        return folderIdol:sub(1, 1):upper() .. folderIdol:sub(2):lower()
    end
    local token = objName:match("^PlayerUpgrade_([^_]+)_")
    if token and token ~= "" then
        return token:sub(1, 1):upper() .. token:sub(2):lower()
    end
    return "Charlie"
end

function CatalogService.OnWorldChanged()
    SupplementalUpgradesScanned = false
    LastCosmeticCount = 0
    LastUpgradeCount = 0
    LastLoggedSummary = nil
end

function CatalogService.IsReady()
    return CatalogService.Lookup.CosmeticsBySlot ~= nil
end

function CatalogService.GetAllUpgradeDefinitions()
    return CatalogService.Ordered.AllUpgrades or {}
end

local function AreCachedCosmeticsHealthy()
    local dances = CatalogService.Ordered.Dances
    if dances and #dances > 0 and not UObjectUtils.IsValid(dances[1].Def) then
        return false
    end
    local bySlot = CatalogService.Ordered.CosmeticsBySlot
    if bySlot then
        for slot = 1, 5 do
            local list = bySlot[slot]
            if list and #list > 0 and not UObjectUtils.IsValid(list[1].Def) then
                return false
            end
        end
    end
    return true
end

local function AreCachedUpgradesHealthy()
    local all = CatalogService.Ordered.AllUpgrades
    if not all or #all == 0 then return false end
    local boss = CatalogService.Ordered.BossAbilities
    if boss then
        for i = 1, #boss do
            if not UObjectUtils.IsValid(boss[i].Def) then
                return false
            end
        end
    end
    for i = 1, #all do
        if not UObjectUtils.IsValid(all[i]) then
            return false
        end
    end
    return true
end

function CatalogService.Refresh(force)
    local inGameplay = UObjectUtils.IsGameplayWorld()
    local forceCosmetics = (force == true)
    local forceUpgrades = (force == true)

    if not forceCosmetics and CatalogService.Lookup.CosmeticsBySlot and not AreCachedCosmeticsHealthy() then
        forceCosmetics = true
        Logger.Debug("CatalogService", "Detected GC'd cosmetic definitions; refreshing cosmetics.")
    end
    if not forceUpgrades and CatalogService.Lookup.Upgrades and not AreCachedUpgradesHealthy() then
        forceUpgrades = true
        SupplementalUpgradesScanned = false
        Logger.Debug("CatalogService", "Detected GC'd upgrade definitions; refreshing upgrades.")
    end

    -- 1. Cosmetics & Dances Catalog Subsystem
    local cosSub = nil
    pcall(function() cosSub = FindFirstOf("PagodaPlayerCosmeticCatalogSubsystem") end)
    if UObjectUtils.IsValid(cosSub) then
        pcall(function()
            local arr = cosSub.SortedCosmetics
            local count = 0
            if arr then pcall(function() count = #arr end) end
            if count == 0 then return end

            if forceCosmetics or not CatalogService.Lookup.CosmeticsBySlot or count ~= LastCosmeticCount then
                LastCosmeticCount = count
                local cosMap = { [1] = {}, [2] = {}, [3] = {}, [4] = {}, [5] = {} }
                local danceMap = {}
                local ordCos = { [1] = {}, [2] = {}, [3] = {}, [4] = {}, [5] = {} }
                local ordDances = {}

                UObjectUtils.ForEachObj(arr, function(def)
                    local slot = def.CosmeticSlot
                    local tagStr = UObjectUtils.GetTagString(def.CosmeticIdTag)
                    local objName = ""
                    pcall(function() objName = def:GetFName():ToString() end)
                    if objName == "" or objName:lower():find("emptytemplate", 1, true) then return end

                    local shortTag = tagStr:match("([^%.]+)$") or ""
                    local shortAsset = objName:gsub("^PlayerCosmetic_Charlie_[A-Za-z]+_", ""):gsub("^PlayerCosmetic_Dance_", "")
                    local dispName = UObjectUtils.GetTextString(def.DisplayName, shortAsset ~= "" and shortAsset or objName)
                    local descStr = UObjectUtils.GetTextString(def.Description, "")

                    if slot == 6 then
                        for _, k in ipairs({ tagStr, shortTag, objName, shortAsset, dispName }) do
                            local nk = UObjectUtils.NormalizeId(k)
                            if nk ~= "" then danceMap[nk] = def end
                        end
                        ordDances[#ordDances + 1] = {
                            Name = dispName,
                            ShortId = shortAsset,
                            ObjName = objName,
                            TagStr = tagStr,
                            Description = descStr,
                            Def = def,
                        }
                    elseif cosMap[slot] then
                        for _, k in ipairs({ tagStr, shortTag, objName, shortAsset, dispName }) do
                            local nk = UObjectUtils.NormalizeId(k)
                            if nk ~= "" then cosMap[slot][nk] = def end
                        end

                        local nkShort = UObjectUtils.NormalizeId(shortAsset)
                        if nkShort:find("doll") then
                            cosMap[slot][nkShort:gsub("doll", "arora")] = def
                        elseif nkShort:find("arora") then
                            cosMap[slot][nkShort:gsub("arora", "doll")] = def
                        end
                        if nkShort:find("dancer") then
                            cosMap[slot][nkShort:gsub("dancer", "dahlia")] = def
                        end
                        if nkShort:find("beach") then
                            cosMap[slot][nkShort:gsub("beach_?", "")] = def
                        end
                        if nkShort:find("summer") then
                            cosMap[slot]["beach" .. nkShort:gsub("^beach", "")] = def
                        end
                        if nkShort:find("summerheadset") then
                            cosMap[slot]["summerheadset"] = def
                            cosMap[slot]["beachsummerheadset"] = def
                        end
                        if nkShort:find("summerhat") then
                            cosMap[slot]["summerhat"] = def
                            cosMap[slot]["beachsummerhat"] = def
                        end
                        if nkShort:find("pumpkinhead") then
                            cosMap[slot]["pumpkinhead"] = def
                            cosMap[slot]["halloweenpumpkinhead"] = def
                        end
                        if shortAsset == "Female" then cosMap[slot]["slim"] = def end
                        if shortAsset == "Doll" and slot == 3 then cosMap[slot]["arora"] = def end

                        ordCos[slot][#ordCos[slot] + 1] = {
                            Name = dispName,
                            ShortId = shortAsset,
                            ObjName = objName,
                            TagStr = tagStr,
                            Description = descStr,
                            Def = def,
                        }
                    end
                end)

                CatalogService.Lookup.CosmeticsBySlot = cosMap
                CatalogService.Lookup.Dances = danceMap
                CatalogService.Ordered.CosmeticsBySlot = ordCos
                CatalogService.Ordered.Dances = ordDances
                Logger.Debug("CatalogService", "Indexed %d cosmetics (%d dances).", count, #ordDances)
            end
        end)
    elseif inGameplay then
        Logger.Missing("CatalogService", "PagodaPlayerCosmeticCatalogSubsystem", "CatalogService.Refresh")
    end

    -- 2. Upgrades & Boss Abilities Catalog Subsystem + Full Cooked Asset Discovery
    local upgSub = nil
    pcall(function() upgSub = FindFirstOf("PagodaPlayerUpgradeCatalogSubsystem") end)
    if UObjectUtils.IsValid(upgSub) then
        pcall(function()
            local arr = upgSub.SortedUpgrades
            local count = 0
            if arr then pcall(function() count = #arr end) end
            if count == 0 then return end

            if forceUpgrades or not CatalogService.Lookup.Upgrades or count ~= LastUpgradeCount then
                LastUpgradeCount = count
                local upgMap = {}
                local bossMap = {}
                local ordBoss = {}
                local ordByIdol = { All = {} }
                local allUniqueDefs = {}
                local discoveredIdols = {}
                local bossAddrSet = {}
                local bossTagSet = {}
                local seenTags = {}
                local seenObjNames = {}
                local nativeTagSet = {}
                local nativePassiveDefs = {}
                local nativeBossDefs = {}
                local nativeCount, extraCount = 0, 0

                local function registerInSubsystemMap(def, tagStr)
                    if not (UObjectUtils.IsValid(def) and type(tagStr) == "string" and tagStr ~= "") then return end
                    pcall(function() def.bAllowIfProgressionDisabled = true end)
                    local ts = UObjectUtils.MakeTagStruct(def.UpgradeIdTag)
                    if ts then
                        pcall(function()
                            if upgSub.TagIdToUpgrades and upgSub.TagIdToUpgrades.Add then
                                upgSub.TagIdToUpgrades:Add(ts, def)
                            end
                        end)
                    end
                end

                local function ensureIdol(idol)
                    if not ordByIdol[idol] then
                        ordByIdol[idol] = {}
                        discoveredIdols[#discoveredIdols + 1] = idol
                    end
                end

                local function registerLookupKeys(map, def, idol, unambiguousList, fallbackList)
                    for _, k in ipairs(unambiguousList) do
                        local nk = UObjectUtils.NormalizeId(k)
                        if nk ~= "" then map[nk] = def end
                    end
                    for _, k in ipairs(fallbackList) do
                        local nk = UObjectUtils.NormalizeId(k)
                        if nk ~= "" and (map[nk] == nil or idol == "Charlie") then
                            map[nk] = def
                        end
                    end
                end

                local function addBossDef(def, isSupplemental)
                    if not UObjectUtils.IsValid(def) then return end
                    local objName = ""
                    pcall(function() objName = def:GetFName():ToString() end)
                    if objName == "" or objName:lower():find("emptytemplate", 1, true) then return end

                    local tagStr = UObjectUtils.GetTagString(def.UpgradeIdTag)
                    if tagStr == "" or bossTagSet[tagStr] then return end
                    bossTagSet[tagStr] = true
                    registerInSubsystemMap(def, tagStr)
                    if not isSupplemental then
                        nativeTagSet[tagStr] = true
                        nativeBossDefs[#nativeBossDefs + 1] = def
                    end

                    local shortNoPrefix = objName:gsub("^PlayerUpgrade_[A-Za-z]+_", "")
                    local shortWithIdol = objName:gsub("^PlayerUpgrade_", "")
                    local dispName = UObjectUtils.GetTextString(def.DisplayName, shortNoPrefix)
                    local descStr = UObjectUtils.GetTextString(def.Description, "")
                    local idol = ExtractIdolFromUpgrade(def)
                    ensureIdol(idol)

                    local addrKey = UObjectUtils.GetKey(def)
                    if addrKey then bossAddrSet[addrKey] = true end

                    registerLookupKeys(
                        bossMap, def, idol,
                        { tagStr, objName, shortWithIdol, shortNoPrefix, dispName },
                        {}
                    )
                    registerLookupKeys(
                        upgMap, def, idol,
                        { tagStr, objName, shortWithIdol },
                        { shortNoPrefix, dispName }
                    )

                    if not seenTags[tagStr] then
                        seenTags[tagStr] = true
                        seenObjNames[objName] = true
                        allUniqueDefs[#allUniqueDefs + 1] = def
                    end

                    ordBoss[#ordBoss + 1] = {
                        Name = dispName,
                        ShortId = shortNoPrefix,
                        ObjName = objName,
                        TagStr = tagStr,
                        Idol = idol,
                        Description = descStr,
                        Def = def,
                    }
                end

                local function addUpgradeDef(def, isSupplemental)
                    if not UObjectUtils.IsValid(def) then return end
                    local objName = ""
                    pcall(function() objName = def:GetFName():ToString() end)
                    if objName == "" or objName:lower():find("emptytemplate", 1, true) then return end
                    seenObjNames[objName] = true

                    local tagStr = UObjectUtils.GetTagString(def.UpgradeIdTag)
                    if tagStr == "" then return end
                    registerInSubsystemMap(def, tagStr)
                    if not isSupplemental then
                        nativeTagSet[tagStr] = true
                    end

                    local shortNoPrefix = objName:gsub("^PlayerUpgrade_[A-Za-z]+_", "")
                    local shortWithIdol = objName:gsub("^PlayerUpgrade_", "")
                    local shortTag = tagStr:match("([^%.]+)$") or ""
                    local dispName = UObjectUtils.GetTextString(def.DisplayName, shortNoPrefix)
                    local descStr = UObjectUtils.GetTextString(def.Description, "")
                    local idol = ExtractIdolFromUpgrade(def)
                    ensureIdol(idol)

                    registerLookupKeys(
                        upgMap, def, idol,
                        { tagStr, objName, shortWithIdol },
                        { shortTag, shortNoPrefix, dispName }
                    )

                    -- Check if supplemental asset is an unlisted playable Boss Move
                    local normShort = UObjectUtils.NormalizeId(shortNoPrefix)
                    local isBossFlag = false
                    pcall(function() isBossFlag = (def.bIsBossAbility == true or def.UpgradeType == 2) end)
                    if KNOWN_BOSS_ABILITY_NAMES[normShort] or isBossFlag then
                        addBossDef(def, isSupplemental)
                    end

                    local addrKey = UObjectUtils.GetKey(def)
                    local isBoss = bossTagSet[tagStr] or (addrKey and bossAddrSet[addrKey])
                    if not seenTags[tagStr] then
                        seenTags[tagStr] = true
                        allUniqueDefs[#allUniqueDefs + 1] = def
                        if isSupplemental then
                            extraCount = extraCount + 1
                        else
                            nativeCount = nativeCount + 1
                            if not isBoss then
                                nativePassiveDefs[#nativePassiveDefs + 1] = def
                            end
                        end

                        if not isBoss then
                            local entry = {
                                Name = dispName,
                                ObjName = objName,
                                TagStr = tagStr,
                                Idol = idol,
                                Description = descStr,
                                Def = def,
                            }
                            ordByIdol[idol][#ordByIdol[idol] + 1] = entry
                            ordByIdol.All[#ordByIdol.All + 1] = entry
                        end
                    end
                end

                local barr = upgSub.BossAbilityUpgrades
                if barr then
                    UObjectUtils.ForEachObj(barr, function(def) addBossDef(def, false) end)
                end

                UObjectUtils.ForEachObj(arr, function(def)
                    addUpgradeDef(def, false)
                end)

                -- Live in-memory instances + one-time cooked upgrade DataAsset discovery
                pcall(function()
                    local liveDefs = FindAllOf("PagodaPlayerUpgradeDefinition")
                    if liveDefs then
                        for _, def in pairs(liveDefs) do
                            addUpgradeDef(def, true)
                        end
                    end
                end)

                if not SupplementalUpgradesScanned or forceUpgrades then
                    SupplementalUpgradesScanned = true
                    for _, pkgPath in ipairs(COOKED_UPGRADE_PATHS) do
                        local assetName = pkgPath:match("([^/]+)$")
                        if assetName and not seenObjNames[assetName] then
                            local loaded = UObjectUtils.LoadObject(pkgPath .. "." .. assetName)
                            if UObjectUtils.IsValid(loaded) then
                                addUpgradeDef(loaded, true)
                            end
                        end
                    end
                end

                table.sort(discoveredIdols, function(a, b)
                    local pa = KNOWN_IDOL_PRIORITY[a] or 50
                    local pb = KNOWN_IDOL_PRIORITY[b] or 50
                    if pa ~= pb then return pa < pb end
                    return a < b
                end)

                CatalogService.Lookup.Upgrades = upgMap
                CatalogService.Lookup.BossAbilities = bossMap
                CatalogService.Ordered.BossAbilities = ordBoss
                CatalogService.Ordered.UpgradesByIdol = ordByIdol
                CatalogService.Ordered.AllUpgrades = allUniqueDefs
                CatalogService.Ordered.IdolOrder = discoveredIdols
                CatalogService.NativeTagSet = nativeTagSet
                CatalogService.NativePassiveDefs = nativePassiveDefs
                CatalogService.NativeBossDefs = nativeBossDefs

                local summary = string.format("%d:%d:%d:%d", nativeCount, extraCount, #ordBoss, #discoveredIdols)
                if summary ~= LastLoggedSummary then
                    LastLoggedSummary = summary
                    Logger.Info("CatalogService",
                        "Indexed %d native + %d supplemental upgrades (%d boss skills, %d idol trees).",
                        nativeCount, extraCount, #ordBoss, #discoveredIdols)
                else
                    Logger.Debug("CatalogService",
                        "Refreshed %d native + %d supplemental upgrades (%d boss skills, %d idol trees).",
                        nativeCount, extraCount, #ordBoss, #discoveredIdols)
                end
            end
        end)
    elseif inGameplay then
        Logger.Missing("CatalogService", "PagodaPlayerUpgradeCatalogSubsystem", "CatalogService.Refresh")
    end
end

function CatalogService.FindCosmetic(slot, key)
    local map = CatalogService.Lookup.CosmeticsBySlot
    if not (map and map[slot]) then return nil end
    local def = map[slot][UObjectUtils.NormalizeId(key)]
    if UObjectUtils.IsValid(def) then return def end
    return map[slot]["default"]
end

function CatalogService.FindDance(key)
    local map = CatalogService.Lookup.Dances
    if not map then return nil end
    local def = map[UObjectUtils.NormalizeId(key)]
    return UObjectUtils.IsValid(def) and def or nil
end

function CatalogService.FindUpgrade(key)
    local map = CatalogService.Lookup.Upgrades
    if not map then return nil end
    local def = map[UObjectUtils.NormalizeId(key)]
    return UObjectUtils.IsValid(def) and def or nil
end

function CatalogService.FindBossAbility(key)
    local map = CatalogService.Lookup.BossAbilities
    if not map then return nil end
    local def = map[UObjectUtils.NormalizeId(key)]
    return UObjectUtils.IsValid(def) and def or nil
end

return CatalogService
