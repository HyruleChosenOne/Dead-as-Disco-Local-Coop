-- ============================================================================
-- UOBJECT SAFETY, REFLECTION HELPERS, ASSET LOADING & UE 5.7 BRIDGES
-- ============================================================================
-- Strictly self-contained (requires ONLY UEHelpers & Utils.Logger).
-- Guarantees every UObject dereference validates IsValid / IsLive first and
-- logs clear warnings via Logger.Missing when expected objects/assets fail.
-- ============================================================================

local UEHelpers = require("UEHelpers")
local Logger = require("Utils.Logger")

local UObjectUtils = {}

local CachedGameplayStatics = nil
local CachedGameMapsSettings = nil
local CachedAbilitySystemLib = nil
local CachedKismetSystemLib = nil
local CachedWidgetBPLib = nil
local DestroyedObjectKeys = {}
local ActionCooldowns = {}
local RegisteredCustomProps = {}
local BridgeDetails = {}
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
    end
end

function UObjectUtils.IsMarkedDestroyed(obj)
    local k = UObjectUtils.GetKey(obj)
    if not k then return true end
    local ts = DestroyedObjectKeys[k]
    if not ts then return false end
    if (os.clock() - ts) > 30.0 then
        DestroyedObjectKeys[k] = nil
        return false
    end
    return true
end

function UObjectUtils.PruneDestroyedCache()
    local now = os.clock()
    for k, ts in pairs(DestroyedObjectKeys) do
        if (now - ts) > 30.0 then
            DestroyedObjectKeys[k] = nil
        end
    end
end

function UObjectUtils.IsLive(obj)
    if not UObjectUtils.IsValid(obj) then return false end
    if UObjectUtils.IsMarkedDestroyed(obj) then return false end

    local okName, fullName = pcall(function() return obj:GetFullName() end)
    if not okName or type(fullName) ~= "string" or fullName == "" then
        return false
    end
    if fullName:find("Default__", 1, true)
        or fullName:find("TRASHCLASS", 1, true)
        or fullName:find("Transient.REINST", 1, true) then
        return false
    end

    local okActFn, destroyingFn = pcall(function()
        if type(obj.IsActorBeingDestroyed) == "function" then
            return obj:IsActorBeingDestroyed()
        end
        return false
    end)
    if okActFn and destroyingFn == true then
        return false
    end

    local okDestProp, destroyingProp = pcall(function() return obj.bActorIsBeingDestroyed end)
    if okDestProp and destroyingProp == true then
        return false
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
        return false
    end

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
    return { TagName = UEHelpers.FindOrAddFName(str) }
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

function UObjectUtils.GetWorld()
    local w = nil
    pcall(function() w = UEHelpers.GetWorld() end)
    return UObjectUtils.IsValid(w) and w or nil
end

function UObjectUtils.IsGameplayWorld()
    local world = UObjectUtils.GetWorld()
    if not UObjectUtils.IsValid(world) then return false, nil end
    local ok, fullName = pcall(function() return world:GetFullName() end)
    if not ok or type(fullName) ~= "string" then return false, nil end
    if fullName:find("Level_MainMenu", 1, true)
        or fullName:find("L_Startup", 1, true)
        or fullName:find("Entry", 1, true)
        or fullName:find("Transition", 1, true) then
        return false, world
    end
    return true, world
end

function UObjectUtils.IsInDiveBar(primaryPC)
    local ok, res = pcall(function()
        local w = UObjectUtils.GetWorld()
        if UObjectUtils.IsLive(w) then
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
    return ok and res == true
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

-- ============================================================================
-- ASSET / CLASS LOADING (ZERO SILENT FAILURES)
-- ============================================================================

function UObjectUtils.LoadObject(objPath)
    if type(objPath) ~= "string" or objPath == "" then return nil end
    local obj = nil

    pcall(function() obj = StaticFindObject(objPath) end)
    if UObjectUtils.IsValid(obj) then return obj end

    local pkgName = objPath:match("^([^%.]+)")
    local assetName = objPath:match("%.([^%.]+)$") or (pkgName and pkgName:match("([^/]+)$"))
    local pkgPath = pkgName and pkgName:match("^(.*)/[^/]+$") or "/Game"

    if pkgName and assetName then
        pcall(function()
            local arh = StaticFindObject("/Script/AssetRegistry.Default__AssetRegistryHelpers")
            if UObjectUtils.IsValid(arh) then
                obj = arh:GetAsset({
                    PackageName = UEHelpers.FindOrAddFName(pkgName),
                    PackagePath = UEHelpers.FindOrAddFName(pkgPath),
                    AssetName = UEHelpers.FindOrAddFName(assetName),
                })
            end
        end)
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

    pcall(function()
        local arh = StaticFindObject("/Script/AssetRegistry.Default__AssetRegistryHelpers")
        if UObjectUtils.IsValid(arh) then
            local pkgPath = packagePath:match("^(.*)/[^/]+$") or "/Game"
            cls = arh:GetAsset({
                PackageName = UEHelpers.FindOrAddFName(packagePath),
                PackagePath = UEHelpers.FindOrAddFName(pkgPath),
                AssetName = UEHelpers.FindOrAddFName(className),
            })
        end
    end)
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

-- ============================================================================
-- UE 5.7 FObjectPtrProperty BRIDGES
-- ============================================================================
-- UE4SS 3.0.1 Beta does not expose FObjectPtrProperty size on UE 5.7.
-- Registers ObjectProperty bridges for APagodaPlayerState::PlaythroughData
-- (PlayerOnlyAttributeSet + 0x8 / 0x3D0) and UPagodaLocalPlayer::PlaythroughData
-- (PlayHistorySaveGame + 0x8 / 0x2C8). Never maps over TWeakObjectPtr!
-- ============================================================================

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
            BridgeDetails["Mod_PlaythroughData"] = "PlayerOnlyAttributeSet+0x8"
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
                BridgeDetails["Mod_PlaythroughData"] = "0x3D0"
                Logger.Debug("UObjectUtils", "Registered Mod_PlaythroughData bridge (0x3D0)")
            else
                BridgeDetails["Mod_PlaythroughData"] = "Failed"
                Logger.Error("UObjectUtils", "Failed to register Mod_PlaythroughData bridge!")
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
            BridgeDetails["Mod_LP_PlaythroughData"] = "PlayHistorySaveGame+0x8"
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
                BridgeDetails["Mod_LP_PlaythroughData"] = "0x2C8"
                Logger.Debug("UObjectUtils", "Registered Mod_LP_PlaythroughData bridge (0x2C8)")
            else
                BridgeDetails["Mod_LP_PlaythroughData"] = "Failed"
                Logger.Error("UObjectUtils", "Failed to register Mod_LP_PlaythroughData bridge!")
            end
        end
    end

    return RegisteredCustomProps["Mod_PlaythroughData"] == true
end

function UObjectUtils.GetBridgeStatus()
    return {
        PlayerState = RegisteredCustomProps["Mod_PlaythroughData"] == true,
        LocalPlayer = RegisteredCustomProps["Mod_LP_PlaythroughData"] == true,
        Details = BridgeDetails,
    }
end

return UObjectUtils
