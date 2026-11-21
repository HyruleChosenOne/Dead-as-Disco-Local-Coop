-- UObject liveness checks, reflection helpers, asset loading, and UE 5.7 property bridges.

local UEHelpers = require("UEHelpers")
local Logger = require("Utils.Logger")

local UObjectUtils = {}

local CachedGameplayStatics = nil
local CachedGameMapsSettings = nil
local CachedAbilitySystemLib = nil
local CachedKismetSystemLib = nil
local CachedWidgetBPLib = nil
local CachedAssetRegistryHelpers = nil
local CachedWorld = nil
local CachedWorldAt = -1.0
local CachedIsGameplay = false
local CachedIsGameplayAt = -1.0
local CachedIsGameplayWorldKey = nil
local CachedIsDiveBar = false
local CachedDiveBarAt = -1.0
local CachedDiveBarWorldKey = nil
local CachedTagStructs = {}
local DestroyedObjectKeys = {}
local VerifiedNameKeys = {}
local ActionCooldowns = {}
local RegisteredCustomProps = {}
local ResolvedModRootDir = nil

-- ============================================================================
-- DETERMINISTIC MOD ROOT PATH RESOLUTION
-- ============================================================================

function UObjectUtils.GetModRootDir()
    if ResolvedModRootDir then return ResolvedModRootDir end
    local src = ""
    pcall(function()
        local info = debug.getinfo(1, "S")
        src = (info and info.source) or ""
    end)
    if src:sub(1, 1) == "@" then src = src:sub(2) end
    src = src:gsub("\\", "/")
    local root = src:match("^(.*)/Scripts/Utils/UObjectUtils%.lua$")
        or src:match("^(.*)/Scripts/")
    if root and root ~= "" then
        ResolvedModRootDir = root .. "/"
    else
        ResolvedModRootDir = "Pagoda/Binaries/Win64/ue4ss/Mods/LocalCoopMod/"
        Logger.Warn("UObjectUtils", "Could not derive mod root via debug.getinfo; using fallback '%s'", ResolvedModRootDir)
    end
    return ResolvedModRootDir
end

-- ============================================================================
-- UOBJECT VALIDITY, LIVENESS & IDENTITY
-- ============================================================================

function UObjectUtils.IsValid(obj)
    if obj == nil then return false end
    local ok, valid = pcall(function()
        return type(obj) == "userdata" and obj.IsValid ~= nil and obj:IsValid()
    end)
    return ok and valid == true
end

function UObjectUtils.GetKey(obj)
    if not UObjectUtils.IsValid(obj) then return nil end
    local okA, addr = pcall(function() return obj:GetAddress() end)
    if okA and addr ~= nil and addr ~= 0 then
        return tostring(addr)
    end
    local okN, fn = pcall(function() return obj:GetFullName() end)
    if okN and type(fn) == "string" and fn ~= "" then
        return fn
    end
    return tostring(obj)
end

function UObjectUtils.Same(a, b)
    if not (UObjectUtils.IsValid(a) and UObjectUtils.IsValid(b)) then return false end
    local ok, eq = pcall(function()
        if a.GetAddress and b.GetAddress then
            return a:GetAddress() == b:GetAddress()
        end
        return a:GetFullName() == b:GetFullName()
    end)
    return ok and eq == true
end

function UObjectUtils.MarkDestroyed(obj)
    local k = UObjectUtils.GetKey(obj)
    if k then
        DestroyedObjectKeys[k] = os.clock()
        VerifiedNameKeys[k] = nil
    end
end

function UObjectUtils.PruneDestroyedCache()
    local now = os.clock()
    for k, ts in pairs(DestroyedObjectKeys) do
        if (now - ts) > 30.0 then
            DestroyedObjectKeys[k] = nil
        end
    end
    for k, ts in pairs(VerifiedNameKeys) do
        if (now - ts) > 120.0 then
            VerifiedNameKeys[k] = nil
        end
    end
end

function UObjectUtils.IsLive(obj)
    if not UObjectUtils.IsValid(obj) then return false end

    local key = UObjectUtils.GetKey(obj)
    if not key then return false end
    local dTs = DestroyedObjectKeys[key]
    if dTs then
        if (os.clock() - dTs) <= 30.0 then return false end
        DestroyedObjectKeys[key] = nil
    end

    local okFlags, deadFlag = pcall(function()
        local flags = 0
        if EInternalObjectFlags then
            if EInternalObjectFlags.PendingKill then flags = flags | EInternalObjectFlags.PendingKill end
            if EInternalObjectFlags.Garbage then flags = flags | EInternalObjectFlags.Garbage end
            if EInternalObjectFlags.Unreachable then flags = flags | EInternalObjectFlags.Unreachable end
        end
        if flags ~= 0 and obj.HasAnyInternalFlags then
            return obj:HasAnyInternalFlags(flags)
        end
        return false
    end)
    if okFlags and deadFlag == true then
        VerifiedNameKeys[key] = nil
        return false
    end

    local okDestProp, destroyingProp = pcall(function() return obj.bActorIsBeingDestroyed end)
    if okDestProp and destroyingProp == true then
        VerifiedNameKeys[key] = nil
        return false
    end

    local okActFn, destroyingFn = pcall(function()
        if type(obj.IsActorBeingDestroyed) == "function" then
            return obj:IsActorBeingDestroyed()
        end
        return false
    end)
    if okActFn and destroyingFn == true then
        VerifiedNameKeys[key] = nil
        return false
    end

    if VerifiedNameKeys[key] ~= nil then
        return true
    end

    local okName, fullName = pcall(function() return obj:GetFullName() end)
    if not okName or type(fullName) ~= "string" or fullName == "" then
        return false
    end
    if fullName:find("Default__", 1, true)
        or fullName:find("TRASHCLASS", 1, true)
        or fullName:find("Transient.REINST", 1, true) then
        return false
    end

    VerifiedNameKeys[key] = os.clock()
    return true
end

-- ============================================================================
-- GUARDED EXECUTION, ARRAYS, TAGS & STRINGS
-- ============================================================================

function UObjectUtils.SafeCall(tag, fn, ...)
    if type(fn) ~= "function" then return false, nil end
    local ok, a, b, c = pcall(fn, ...)
    if not ok then
        Logger.Warn("Guard:" .. tostring(tag or "Call"), "%s", tostring(a))
        return false, nil
    end
    return true, a, b, c
end

function UObjectUtils.ForEachObj(arr, callback)
    if not arr or type(callback) ~= "function" then return end
    local okForEach = pcall(function()
        arr:ForEach(function(_, elem)
            local val = elem
            if type(elem) == "userdata" and elem.get then
                pcall(function() val = elem:get() end)
            end
            if UObjectUtils.IsValid(val) then
                local okCb, errCb = pcall(callback, val)
                if not okCb then
                    Logger.Warn("ForEachObj", "Callback error: %s", tostring(errCb))
                end
            end
        end)
    end)
    if okForEach then return end

    pcall(function()
        local len = #arr
        for i = 1, len do
            local val = arr[i]
            if UObjectUtils.IsValid(val) then
                local okCb, errCb = pcall(callback, val)
                if not okCb then
                    Logger.Warn("ForEachObj", "Indexed callback error: %s", tostring(errCb))
                end
            end
        end
    end)
end

function UObjectUtils.CanTrigger(actionKey, cooldownSec)
    local now = os.clock()
    local last = ActionCooldowns[actionKey]
    if last ~= nil and (now - last) < (cooldownSec or 0.25) then
        return false
    end
    ActionCooldowns[actionKey] = now
    return true
end

function UObjectUtils.NormalizeId(str)
    if type(str) ~= "string" then return "" end
    return str:lower():gsub("[^%w]", "")
end

function UObjectUtils.MakeTagStruct(tagUserdata)
    if not tagUserdata then return nil end
    local ok, tagName = pcall(function() return tagUserdata.TagName end)
    if ok and tagName ~= nil then
        return { TagName = tagName }
    end
    return nil
end

function UObjectUtils.MakeTagFromString(str)
    if type(str) ~= "string" or str == "" then return nil end
    local cached = CachedTagStructs[str]
    if cached then return cached end
    local ts = { TagName = UEHelpers.FindOrAddFName(str) }
    CachedTagStructs[str] = ts
    return ts
end

function UObjectUtils.GetTagString(tagUserdata)
    if not tagUserdata then return "" end
    local ok, s = pcall(function() return tagUserdata.TagName:ToString() end)
    return (ok and type(s) == "string") and s or ""
end

function UObjectUtils.GetTextString(fTextProp, fallback)
    if fTextProp == nil then return fallback or "" end
    local ok, s = pcall(function()
        if type(fTextProp) == "string" then return fTextProp end
        if fTextProp.ToString then return fTextProp:ToString() end
        return tostring(fTextProp)
    end)
    if ok and type(s) == "string" and s ~= "" and not s:find("^userdata:") and not s:find("^FText:") then
        return s
    end
    return fallback or ""
end

-- ============================================================================
-- ENGINE SINGLETON ACCESSORS & WORLD QUERIES
-- ============================================================================

function UObjectUtils.GetGameplayStatics()
    if UObjectUtils.IsValid(CachedGameplayStatics) then return CachedGameplayStatics end
    pcall(function() CachedGameplayStatics = UEHelpers.GetGameplayStatics() end)
    if not UObjectUtils.IsValid(CachedGameplayStatics) then
        pcall(function() CachedGameplayStatics = StaticFindObject("/Script/Engine.Default__GameplayStatics") end)
    end
    if not UObjectUtils.IsValid(CachedGameplayStatics) then
        Logger.Missing("UObjectUtils", "GameplayStatics", "GetGameplayStatics")
        return nil
    end
    return CachedGameplayStatics
end

function UObjectUtils.GetGameMapsSettings()
    if UObjectUtils.IsValid(CachedGameMapsSettings) then return CachedGameMapsSettings end
    pcall(function() CachedGameMapsSettings = UEHelpers.GetGameMapsSettings() end)
    if not UObjectUtils.IsValid(CachedGameMapsSettings) then
        pcall(function() CachedGameMapsSettings = StaticFindObject("/Script/EngineSettings.Default__GameMapsSettings") end)
    end
    if not UObjectUtils.IsValid(CachedGameMapsSettings) then
        Logger.Missing("UObjectUtils", "GameMapsSettings", "GetGameMapsSettings")
        return nil
    end
    return CachedGameMapsSettings
end

function UObjectUtils.GetAbilitySystemLibrary()
    if UObjectUtils.IsValid(CachedAbilitySystemLib) then return CachedAbilitySystemLib end
    pcall(function()
        CachedAbilitySystemLib = StaticFindObject("/Script/GameplayAbilities.Default__AbilitySystemBlueprintLibrary")
    end)
    if not UObjectUtils.IsValid(CachedAbilitySystemLib) then
        Logger.Missing("UObjectUtils", "AbilitySystemBlueprintLibrary", "GetAbilitySystemLibrary")
        return nil
    end
    return CachedAbilitySystemLib
end

function UObjectUtils.GetKismetSystemLibrary()
    if UObjectUtils.IsValid(CachedKismetSystemLib) then return CachedKismetSystemLib end
    pcall(function()
        CachedKismetSystemLib = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
    end)
    if not UObjectUtils.IsValid(CachedKismetSystemLib) then
        Logger.Missing("UObjectUtils", "KismetSystemLibrary", "GetKismetSystemLibrary")
        return nil
    end
    return CachedKismetSystemLib
end

function UObjectUtils.GetWidgetBlueprintLibrary()
    if UObjectUtils.IsValid(CachedWidgetBPLib) then return CachedWidgetBPLib end
    pcall(function()
        CachedWidgetBPLib = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
    end)
    if not UObjectUtils.IsValid(CachedWidgetBPLib) then
        Logger.Missing("UObjectUtils", "WidgetBlueprintLibrary", "GetWidgetBlueprintLibrary")
        return nil
    end
    return CachedWidgetBPLib
end

local function GetAssetRegistryHelpers()
    if UObjectUtils.IsValid(CachedAssetRegistryHelpers) then return CachedAssetRegistryHelpers end
    pcall(function()
        CachedAssetRegistryHelpers = StaticFindObject("/Script/AssetRegistry.Default__AssetRegistryHelpers")
    end)
    return UObjectUtils.IsValid(CachedAssetRegistryHelpers) and CachedAssetRegistryHelpers or nil
end

function UObjectUtils.InvalidateWorldCache()
    CachedWorld = nil
    CachedWorldAt = -1.0
    CachedIsGameplay = false
    CachedIsGameplayAt = -1.0
    CachedIsGameplayWorldKey = nil
    CachedIsDiveBar = false
    CachedDiveBarAt = -1.0
    CachedDiveBarWorldKey = nil
    -- Clear destroyed/name caches on level change so recycled UObject addresses aren't falsely flagged.
    DestroyedObjectKeys = {}
    VerifiedNameKeys = {}
end

function UObjectUtils.GetWorld()
    local now = os.clock()
    if (now - CachedWorldAt) < 0.20 and UObjectUtils.IsValid(CachedWorld) then
        return CachedWorld
    end
    local w = nil
    pcall(function() w = UEHelpers.GetWorld() end)
    if UObjectUtils.IsValid(w) then
        CachedWorld = w
        CachedWorldAt = now
        return w
    end
    CachedWorld = nil
    CachedWorldAt = -1.0
    return nil
end

function UObjectUtils.IsGameplayWorld()
    local now = os.clock()
    local world = UObjectUtils.GetWorld()
    if not UObjectUtils.IsValid(world) then
        CachedIsGameplay = false
        CachedIsGameplayAt = -1.0
        CachedIsGameplayWorldKey = nil
        return false, nil
    end

    local wKey = UObjectUtils.GetKey(world)
    if CachedIsGameplayWorldKey == wKey and (now - CachedIsGameplayAt) < 0.20 then
        return CachedIsGameplay, world
    end

    local ok, fullName = pcall(function() return world:GetFullName() end)
    if not ok or type(fullName) ~= "string" then
        CachedIsGameplay = false
        CachedIsGameplayAt = now
        CachedIsGameplayWorldKey = wKey
        return false, nil
    end
    if fullName:find("Level_MainMenu", 1, true)
        or fullName:find("L_Startup", 1, true)
        or fullName:find("Entry", 1, true)
        or fullName:find("Transition", 1, true) then
        CachedIsGameplay = false
        CachedIsGameplayAt = now
        CachedIsGameplayWorldKey = wKey
        return false, world
    end
    CachedIsGameplay = true
    CachedIsGameplayAt = now
    CachedIsGameplayWorldKey = wKey
    return true, world
end

function UObjectUtils.IsInDiveBar(primaryPC)
    local now = os.clock()
    local w = UObjectUtils.GetWorld()
    local wKey = UObjectUtils.IsValid(w) and UObjectUtils.GetKey(w) or nil
    if wKey ~= nil and CachedDiveBarWorldKey == wKey and (now - CachedDiveBarAt) < 0.25 then
        return CachedIsDiveBar
    end
    local ok, res = pcall(function()
        if UObjectUtils.IsValid(w) then
            local fn = ""
            pcall(function() fn = w:GetFullName() end)
            if fn:find("DiveBar", 1, true) or fn:find("Hub", 1, true) then return true end
            local mn = ""
            pcall(function() mn = w:GetMapName() end)
            if mn:find("DiveBar", 1, true) or mn:find("Hub", 1, true) then return true end
        end
        if UObjectUtils.IsLive(primaryPC) then
            local cName = ""
            pcall(function() cName = primaryPC:GetClass():GetFName():ToString() end)
            if cName:find("DiveBar", 1, true) then return true end
        end
        return false
    end)
    CachedIsDiveBar = (ok and res == true)
    CachedDiveBarAt = now
    CachedDiveBarWorldKey = wKey
    return CachedIsDiveBar
end

function UObjectUtils.GetASC(actor)
    if not UObjectUtils.IsLive(actor) then return nil end
    local asc = nil

    -- 1. Native PagodaCharacter:GetPagodaASC()
    pcall(function()
        if actor.GetPagodaASC then
            asc = actor:GetPagodaASC()
        end
    end)
    if UObjectUtils.IsValid(asc) then return asc end

    -- 2. Official GAS AbilitySystemBlueprintLibrary:GetAbilitySystemComponent
    local asbl = UObjectUtils.GetAbilitySystemLibrary()
    if asbl then
        pcall(function() asc = asbl:GetAbilitySystemComponent(actor) end)
        if UObjectUtils.IsValid(asc) then return asc end
    end

    -- 3. PlayerState / Pawn direct property fallback
    pcall(function()
        if UObjectUtils.IsLive(actor.PlayerState) then
            asc = actor.PlayerState.AbilitySystemComponent or actor.PlayerState.PlayerAbilitySystemComponent
        end
    end)
    if UObjectUtils.IsValid(asc) then return asc end

    pcall(function() asc = actor.PlayerAbilitySystemComponent or actor.AbilitySystemComponent end)
    return UObjectUtils.IsValid(asc) and asc or nil
end

function UObjectUtils.GetDistanceSq(actorA, actorB)
    if not (UObjectUtils.IsLive(actorA) and UObjectUtils.IsLive(actorB)) then return math.huge end
    local ok, d2 = pcall(function()
        local l1 = actorA:K2_GetActorLocation()
        local l2 = actorB:K2_GetActorLocation()
        local dx = l1.X - l2.X
        local dy = l1.Y - l2.Y
        local dz = l1.Z - l2.Z
        return dx * dx + dy * dy + dz * dz
    end)
    return (ok and type(d2) == "number") and d2 or math.huge
end

-- Asset & class loading

function UObjectUtils.LoadObject(objPath)
    if type(objPath) ~= "string" or objPath == "" then return nil end
    local obj = nil

    pcall(function() obj = StaticFindObject(objPath) end)
    if UObjectUtils.IsValid(obj) then return obj end

    local pkgName = objPath:match("^([^%.]+)")
    local assetName = objPath:match("%.([^%.]+)$") or (pkgName and pkgName:match("([^/]+)$"))
    local pkgPath = pkgName and pkgName:match("^(.*)/[^/]+$") or "/Game"

    if pkgName and assetName then
        local arh = GetAssetRegistryHelpers()
        if arh then
            pcall(function()
                obj = arh:GetAsset({
                    PackageName = UEHelpers.FindOrAddFName(pkgName),
                    PackagePath = UEHelpers.FindOrAddFName(pkgPath),
                    AssetName = UEHelpers.FindOrAddFName(assetName),
                })
            end)
        end
        if UObjectUtils.IsValid(obj) then return obj end
    end

    if type(LoadAsset) == "function" then
        pcall(function() obj = LoadAsset(objPath) end)
        if UObjectUtils.IsValid(obj) then return obj end
        if pkgName then
            pcall(function() obj = LoadAsset(pkgName) end)
            if UObjectUtils.IsValid(obj) then return obj end
        end
    end

    pcall(function() obj = StaticFindObject(objPath) end)
    if not UObjectUtils.IsValid(obj) then
        Logger.Missing("UObjectUtils", objPath, "LoadObject")
        return nil
    end
    return obj
end

function UObjectUtils.LoadClass(packagePath, className, silentIfMissing)
    local fullPath = string.format("%s.%s", packagePath, className)
    local cls = nil

    pcall(function() cls = StaticFindObject(fullPath) end)
    if UObjectUtils.IsValid(cls) then return cls end

    local arh = GetAssetRegistryHelpers()
    if arh then
        pcall(function()
            local pkgPath = packagePath:match("^(.*)/[^/]+$") or "/Game"
            cls = arh:GetAsset({
                PackageName = UEHelpers.FindOrAddFName(packagePath),
                PackagePath = UEHelpers.FindOrAddFName(pkgPath),
                AssetName = UEHelpers.FindOrAddFName(className),
            })
        end)
    end
    if UObjectUtils.IsValid(cls) then return cls end

    if type(LoadAsset) == "function" then
        pcall(function() LoadAsset(packagePath) end)
        pcall(function() LoadAsset(fullPath) end)
    end

    pcall(function() cls = StaticFindObject(fullPath) end)
    if not UObjectUtils.IsValid(cls) then
        if not silentIfMissing then
            Logger.Missing("UObjectUtils", fullPath, "LoadClass")
        end
        return nil
    end
    return cls
end

-- UE 5.7 FObjectPtrProperty bridges:
-- UE4SS 3.0.1 Beta does not expose FObjectPtrProperty size on UE 5.7, so we alias
-- APagodaPlayerState::PlaythroughData (PlayerOnlyAttributeSet + 0x8 / 0x3D0) and
-- UPagodaLocalPlayer::PlaythroughData (PlayHistorySaveGame + 0x8 / 0x2C8).
-- Never point these offsets over a TWeakObjectPtr field.

function UObjectUtils.EnsurePlaythroughDataBridges()
    if type(RegisterCustomProperty) ~= "function" or type(PropertyTypes) ~= "table" then
        Logger.Warn("UObjectUtils", "RegisterCustomProperty/PropertyTypes unavailable; PPD bridge cannot be registered.")
        return false
    end

    if not RegisteredCustomProps["Mod_PlaythroughData"] then
        local okRel = pcall(function()
            RegisterCustomProperty({
                Name = "Mod_PlaythroughData",
                Type = PropertyTypes.ObjectProperty,
                BelongsToClass = "/Script/Pagoda.PagodaPlayerState",
                OffsetInternal = {
                    Property = "PlayerOnlyAttributeSet",
                    RelativeOffset = 0x8,
                },
            })
        end)
        if okRel then
            RegisteredCustomProps["Mod_PlaythroughData"] = true
            Logger.Debug("UObjectUtils", "Registered Mod_PlaythroughData bridge (PlayerOnlyAttributeSet+0x8)")
        else
            local okAbs = pcall(function()
                RegisterCustomProperty({
                    Name = "Mod_PlaythroughData",
                    Type = PropertyTypes.ObjectProperty,
                    BelongsToClass = "/Script/Pagoda.PagodaPlayerState",
                    OffsetInternal = 0x3D0,
                })
            end)
            if okAbs then
                RegisteredCustomProps["Mod_PlaythroughData"] = true
                Logger.Debug("UObjectUtils", "Registered Mod_PlaythroughData bridge (0x3D0)")
            else
                Logger.Error("UObjectUtils", "Failed to register Mod_PlaythroughData bridge.")
            end
        end
    end

    if not RegisteredCustomProps["Mod_LP_PlaythroughData"] then
        local okLpRel = pcall(function()
            RegisterCustomProperty({
                Name = "Mod_LP_PlaythroughData",
                Type = PropertyTypes.ObjectProperty,
                BelongsToClass = "/Script/Pagoda.PagodaLocalPlayer",
                OffsetInternal = {
                    Property = "PlayHistorySaveGame",
                    RelativeOffset = 0x8,
                },
            })
        end)
        if okLpRel then
            RegisteredCustomProps["Mod_LP_PlaythroughData"] = true
            Logger.Debug("UObjectUtils", "Registered Mod_LP_PlaythroughData bridge (PlayHistorySaveGame+0x8)")
        else
            local okLpAbs = pcall(function()
                RegisterCustomProperty({
                    Name = "Mod_LP_PlaythroughData",
                    Type = PropertyTypes.ObjectProperty,
                    BelongsToClass = "/Script/Pagoda.PagodaLocalPlayer",
                    OffsetInternal = 0x2C8,
                })
            end)
            if okLpAbs then
                RegisteredCustomProps["Mod_LP_PlaythroughData"] = true
                Logger.Debug("UObjectUtils", "Registered Mod_LP_PlaythroughData bridge (0x2C8)")
            else
                Logger.Error("UObjectUtils", "Failed to register Mod_LP_PlaythroughData bridge.")
            end
        end
    end

    return RegisteredCustomProps["Mod_PlaythroughData"] == true
end

local UPGRADE_DEF_WORD_OFFSETS = {
    [0]  = 0x3C,  -- UpgradeIdTag (8 bytes)
    [1]  = 0x44,  -- PlayerUpgradeProgressionTag (8 bytes)
    [2]  = 0x4C,  -- UpgradeType + flags (8 bytes)
    [3]  = 0x160, -- UpgradeGrants.GrantedGameplayEffects Data
    [4]  = 0x168, -- UpgradeGrants.GrantedGameplayEffects Num/Max
    [5]  = 0x170, -- UpgradeGrants.GAComponentPackages Data
    [6]  = 0x178, -- UpgradeGrants.GAComponentPackages Num/Max
    [7]  = 0x180, -- UpgradeGrants.InputActionHandlerClasses Data
    [8]  = 0x188, -- UpgradeGrants.InputActionHandlerClasses Num/Max
    [9]  = 0x190, -- AdditionalKeywordTags word 0
    [10] = 0x198, -- AdditionalKeywordTags word 1
    [11] = 0x1A0, -- AdditionalKeywordTags word 2
    [12] = 0x1A8, -- AdditionalKeywordTags word 3
}

function UObjectUtils.EnsureUpgradeDefinitionBridges()
    if type(RegisterCustomProperty) ~= "function" or type(PropertyTypes) ~= "table" or not PropertyTypes.Int64Property then
        return false
    end
    if RegisteredCustomProps["Mod_UpgDefWords"] then
        return true
    end
    local allOk = true
    for idx = 0, 12 do
        local propName = "Mod_UpgWord_" .. tostring(idx)
        local off = UPGRADE_DEF_WORD_OFFSETS[idx]
        local ok = pcall(function()
            RegisterCustomProperty({
                Name = propName,
                Type = PropertyTypes.Int64Property,
                BelongsToClass = "/Script/Pagoda.PagodaPlayerUpgradeDefinition",
                OffsetInternal = off,
            })
        end)
        if not ok then allOk = false end
    end
    if allOk then
        RegisteredCustomProps["Mod_UpgDefWords"] = true
    end
    return allOk
end

return UObjectUtils
