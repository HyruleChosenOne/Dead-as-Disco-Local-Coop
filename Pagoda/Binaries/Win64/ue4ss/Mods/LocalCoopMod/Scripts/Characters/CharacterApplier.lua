-- Discovers Vanilla Charlie, CSM (.utoc/.pak), and optional experimental models,
-- and applies mesh, material, PostProcessAnimBP, and tint state to P2's pawn only.
-- Always disables any CSM PostProcessAnimBP before swapping skeletons back to Charlie
-- to avoid skeleton mismatch crashes.

local UObjectUtils = require("Utils.UObjectUtils")
local Logger = require("Utils.Logger")
local Scheduler = require("Core.Scheduler")
local SessionManager = require("Core.SessionManager")
local ProfileStore = require("State.ProfileStore")
local PlayerStateIsolation = require("State.PlayerStateIsolation")
local PakScanner = require("Characters.PakScanner")

local CharacterApplier = {}

local Config = {}
local Callbacks = {}

CharacterApplier.List = {}
CharacterApplier.ByKey = {}
CharacterApplier.CurrentTintMode = "AccentOnly"
CharacterApplier.CurrentTintPaletteIdx = 1

local OriginalP2Mesh = nil
local OriginalP2AnimClass = nil
local CachedHumanoidSkel = nil
local CachedSKMClass = nil
local CachedSMClass = nil
local CachedMIDClass = nil
local CachedWCClass = nil
local CachedProbeClass = nil
local ApplyingGuardUntil = 0.0
local LastSwitchAt = 0.0
local LastAppliedKey = nil
local LastAppliedPawnKey = nil
local LastAttachmentsHiddenPawnKey = nil
local LastAttachmentsHiddenState = nil
local LoadRetryCounts = {}
local MAX_ASSET_LOAD_RETRIES = 4

-- Verified SKEL_Humanoid boss & enemy meshes from Pagoda-Windows.utoc (crash-checked by GetSkeleton)
local EXPERIMENTAL_IN_GAME_MODELS = {
    -- Bosses
    { Key = "exp:DancerLife",  Name = "La Pantera (Dahlia - Life)",  Category = "Boss",  Badge = "BOSS",  MeshPath = "/Game/Pagoda/Characters/Enemies/Dancer/Meshes/SK_AI_Dancer_Life.SK_AI_Dancer_Life" },
    { Key = "exp:DancerDeath", Name = "La Pantera (Dahlia - Death)", Category = "Boss",  Badge = "BOSS",  MeshPath = "/Game/Pagoda/Characters/Enemies/Dancer/Meshes/SK_AI_Dancer_Death.SK_AI_Dancer_Death" },
    { Key = "exp:Doll",        Name = "Arora (Doll)",                Category = "Boss",  Badge = "BOSS",  MeshPath = "/Game/Pagoda/Characters/Enemies/Doll/Meshes/SK_AI_Doll.SK_AI_Doll" },
    { Key = "exp:Rebel",       Name = "Rebel",                       Category = "Boss",  Badge = "BOSS",  MeshPath = "/Game/Pagoda/Characters/Enemies/Rebel/Meshes/SK_AI_Rebel.SK_AI_Rebel" },
    { Key = "exp:Shred",       Name = "Shred",                       Category = "Boss",  Badge = "BOSS",  MeshPath = "/Game/Pagoda/Characters/Enemies/Shred/Meshes/SK_AI_Shred.SK_AI_Shred" },
    -- Basic & Elite Enemies
    { Key = "exp:StanMale",    Name = "Stan (Male Grunt)",           Category = "Enemy", Badge = "ENEMY", MeshPath = "/Game/Pagoda/Characters/Enemies/Grunt/Meshes/SK_AI_Stan_01.SK_AI_Stan_01" },
    { Key = "exp:StanFemale",  Name = "Stan (Female Grunt)",         Category = "Enemy", Badge = "ENEMY", MeshPath = "/Game/Pagoda/Characters/Enemies/Grunt/Meshes/SK_AI_Stan_Female_01.SK_AI_Stan_Female_01" },
    { Key = "exp:Bouncer",     Name = "Bouncer",                     Category = "Enemy", Badge = "ENEMY", MeshPath = "/Game/Pagoda/Characters/Enemies/BOUNCER/Meshes/SK_AI_Bouncer.SK_AI_Bouncer" },
    { Key = "exp:Mosher",      Name = "Mosher",                      Category = "Enemy", Badge = "ENEMY", MeshPath = "/Game/Pagoda/Characters/Enemies/Mosher/Meshes/SK_AI_Mosher.SK_AI_Mosher" },
    { Key = "exp:Security",    Name = "Private Security",            Category = "Enemy", Badge = "ENEMY", MeshPath = "/Game/Pagoda/Characters/Enemies/Private_Security/Meshes/SK_AI_Private_Security.SK_AI_Private_Security" },
    { Key = "exp:Fanatic",     Name = "Fanatic",                     Category = "Enemy", Badge = "ENEMY", MeshPath = "/Game/Pagoda/Characters/Enemies/Fanatic/Meshes/SK_AI_Fanatic.SK_AI_Fanatic" },
    { Key = "exp:Echo",        Name = "Echo",                        Category = "Enemy", Badge = "ENEMY", MeshPath = "/Game/Pagoda/Characters/Enemies/Echo/Meshes/SK_AI_Echo.SK_AI_Echo" },
    { Key = "exp:EchoElite",   Name = "Echo Elite",                  Category = "Enemy", Badge = "ENEMY", MeshPath = "/Game/Pagoda/Characters/Enemies/Echo/Meshes/SK_AI_Echo_Elite.SK_AI_Echo_Elite" },
    { Key = "exp:DollBot",     Name = "Doll Bot",                    Category = "Enemy", Badge = "ENEMY", MeshPath = "/Game/Pagoda/Characters/Enemies/DollClone/Meshes/SK_AI_Doll_Bot.SK_AI_Doll_Bot" },
    { Key = "exp:Stix",        Name = "Stix",                        Category = "Enemy", Badge = "ENEMY", MeshPath = "/Game/Pagoda/Characters/Enemies/Stix/Meshes/SK_AI_Stix.SK_AI_Stix" },
}

local EXCLUDED_MAT_KEYWORDS = {
    "eyes", "eyelash", "teeth", "tongue", "mouth", "clearcoatblack", "skull",
    "m_fpv4toon", "m_outline",
}

local EXCLUDED_COMP_KEYWORDS = {
    "widget", "niagara", "trail", "afterimage", "dangerindicator",
    "interactionindicator", "pyroette", "indicator", "vfx", "fx_",
}

local ACCENT_VECTOR_PARAMS = {
    "Fresnel Color", "Inner Outline Color", "EmissionFresnelColor",
    "Emissive Tint", "Inner Color", "Outer Color", "EmissiveColor",
}

local SURFACE_VECTOR_PARAMS = {
    "Color Tint", "Base Color", "Color01", "Color02",
    "Tint", "Color", "BaseColor", "BaseColorTint", "BodyColor",
}

local HAIR_VECTOR_PARAMS = { "Hair Root", "Hair Tip" }

function CharacterApplier.Init(config, callbacks)
    Config = config or {}
    Callbacks = callbacks or {}
    local charCfg = Config.Characters or {}
    CharacterApplier.CurrentTintMode = charCfg.TintMode or "AccentOnly"
    CharacterApplier.CurrentTintPaletteIdx = 1
end

function CharacterApplier.OnWorldChanged()
    LastAppliedPawnKey = nil
    LastAttachmentsHiddenPawnKey = nil
    LastAttachmentsHiddenState = nil
    LoadRetryCounts = {}
end

function CharacterApplier.IsExperimentalEnabled()
    return (Config.Experimental and Config.Experimental.Enabled == true)
end

function CharacterApplier.IsEntryExperimental(entry)
    return entry ~= nil and entry.IsExperimental == true
end

local function GetExpectedHumanoidSkeleton()
    if UObjectUtils.IsValid(CachedHumanoidSkel) then return CachedHumanoidSkel end
    if UObjectUtils.IsValid(OriginalP2Mesh) then
        pcall(function()
            local sk = OriginalP2Mesh:GetSkeleton()
            if UObjectUtils.IsValid(sk) then CachedHumanoidSkel = sk end
        end)
    end
    if not UObjectUtils.IsValid(CachedHumanoidSkel) then
        local sk = UObjectUtils.LoadObject("/Game/Pagoda/Characters/Common/Skeletons/SKEL_Humanoid.SKEL_Humanoid")
        if UObjectUtils.IsValid(sk) then CachedHumanoidSkel = sk end
    end
    return UObjectUtils.IsValid(CachedHumanoidSkel) and CachedHumanoidSkel or nil
end

local function IsSkeletonCompatibleWithCharlie(targetMesh, entry)
    if not UObjectUtils.IsValid(targetMesh) then return false end
    -- CSM character mods (.utoc/.pak) bring their own custom humanoid USkeleton (e.g. SK_SnowMiku_Skeleton) + PostProcessAnimBP
    if entry and (entry.Source == "CSM" or entry.IsPak == true or not entry.IsExperimental) then
        return true
    end
    local expected = GetExpectedHumanoidSkeleton()
    if not UObjectUtils.IsValid(expected) then return true end
    local cand = nil
    pcall(function() cand = targetMesh:GetSkeleton() end)
    if not UObjectUtils.IsValid(cand) then return false end
    return UObjectUtils.Same(cand, expected)
end

function CharacterApplier.GetMeshAsset(meshComp)
    if not UObjectUtils.IsValid(meshComp) then return nil end
    local asset = nil
    pcall(function() asset = meshComp:GetSkeletalMeshAsset() end)
    if UObjectUtils.IsValid(asset) then return asset end
    pcall(function() asset = meshComp:GetSkinnedAsset() end)
    if UObjectUtils.IsValid(asset) then return asset end
    pcall(function() asset = meshComp.SkeletalMesh end)
    if UObjectUtils.IsValid(asset) then return asset end
    pcall(function() asset = meshComp.SkinnedAsset end)
    return UObjectUtils.IsValid(asset) and asset or nil
end

local function FormatCleanName(rawName)
    if type(rawName) ~= "string" or rawName == "" then return "Custom Character" end
    local s = rawName
    s = s:gsub("^SKM_", ""):gsub("^SK_", ""):gsub("^Mesh_", ""):gsub("^Chr_", ""):gsub("^CH_", "")
    s = s:gsub("_Mesh$", ""):gsub("_Skeleton$", ""):gsub("_Base$", "")
    s = s:gsub("_", " "):gsub("(%l)(%u)", "%1 %2"):gsub("%s+", " "):match("^%s*(.-)%s*$")
    return (s and s ~= "") and s or rawName
end

local function IsNonCharacterMesh(meshName, fullPath)
    local low = (meshName or ""):lower()
    local lowPath = (fullPath or ""):lower()
    for _, tok in ipairs({
        "jacket", "glasses", "visor", "hair", "headgear", "hat", "helmet",
        "drumstick", "stick", "weapon", "guitar", "baxe", "prop", "vfx",
        "debris", "chair", "table", "door", "speaker", "stage", "crowd",
        "cine", "camera", "light", "1p_", "arms", "shadow", "physics",
        "collision", "dummy", "preview", "icon", "ui_", "ragdoll",
    }) do
        if low:find(tok, 1, true) then return true end
    end
    if lowPath:find("/weapons/", 1, true) or lowPath:find("/props/", 1, true)
        or lowPath:find("/environment/", 1, true) or lowPath:find("/vfx/", 1, true) then
        return true
    end
    return false
end

function CharacterApplier.CacheOriginalP2Visuals(p2Pawn)
    if UObjectUtils.IsValid(OriginalP2Mesh) then return end
    if not UObjectUtils.IsLive(p2Pawn) then return end
    pcall(function()
        local mc = p2Pawn.Mesh
        if UObjectUtils.IsValid(mc) then
            local m = CharacterApplier.GetMeshAsset(mc)
            if UObjectUtils.IsValid(m) then OriginalP2Mesh = m end
            local ac = mc.AnimClass
            if UObjectUtils.IsValid(ac) then OriginalP2AnimClass = ac end
        end
    end)
end

local function RestoreNativeMeshMaterials(mc, meshAsset)
    if not (UObjectUtils.IsValid(mc) and UObjectUtils.IsValid(meshAsset)) then return false end
    local restored = false
    pcall(function()
        local mats = meshAsset.Materials
        if not mats then return end
        local okFE = pcall(function()
            mats:ForEach(function(idx, elem)
                local sMat = elem
                if type(elem) == "userdata" and elem.get then pcall(function() sMat = elem:get() end) end
                if sMat then
                    local mi = nil
                    pcall(function() mi = sMat.MaterialInterface end)
                    if UObjectUtils.IsValid(mi) then
                        pcall(function() mc:SetMaterial(idx - 1, mi) end)
                        restored = true
                    end
                end
            end)
        end)
        if not okFE then
            local len = 0
            pcall(function() len = #mats end)
            for i = 1, len do
                local sMat = mats[i]
                if sMat then
                    local mi = nil
                    pcall(function() mi = sMat.MaterialInterface end)
                    if UObjectUtils.IsValid(mi) then
                        pcall(function() mc:SetMaterial(i - 1, mi) end)
                        restored = true
                    end
                end
            end
        end
    end)
    return restored
end

local function CleanStaleCharlieMaterials(mc, meshAsset)
    if not UObjectUtils.IsValid(mc) then return false end
    local needsRestore = false
    local staleName = ""

    pcall(function()
        local n = mc:GetNumMaterials()
        if type(n) ~= "number" or n <= 0 then return end
        for i = 0, n - 1 do
            local m = mc:GetMaterial(i)
            if UObjectUtils.IsValid(m) then
                local mn = ""
                pcall(function() mn = m:GetFullName():lower() end)
                if mn:find("charlie", 1, true)
                    or mn:find("mid_", 1, true)
                    or mn:find("discocharacterbase", 1, true)
                    or mn:find("worldgrid", 1, true)
                    or mn:find("defaultmaterial", 1, true) then
                    needsRestore = true
                    staleName = mn
                    return
                end
            else
                needsRestore = true
                staleName = "nil_slot_" .. tostring(i)
                return
            end
        end
    end)

    if not needsRestore then
        pcall(function()
            local ov = mc.OverrideMaterials
            if ov and #ov > 0 then
                for i = 1, #ov do
                    local om = ov[i]
                    if UObjectUtils.IsValid(om) then
                        local mn = ""
                        pcall(function() mn = om:GetFullName():lower() end)
                        if mn:find("charlie", 1, true) or mn:find("mid_", 1, true) then
                            needsRestore = true
                            staleName = mn
                            break
                        end
                    end
                end
            end
        end)
    end

    if needsRestore then
        local targetMesh = UObjectUtils.IsValid(meshAsset) and meshAsset or CharacterApplier.GetMeshAsset(mc)
        local ok = RestoreNativeMeshMaterials(mc, targetMesh)
        if ok then
            Logger.Debug("CharacterApplier", "Restored native CSM materials (cleared '%s').", staleName)
        end
        return ok
    end
    return false
end

local function ShouldKeepAttachedObjectVisible(obj)
    if not UObjectUtils.IsValid(obj) then return true end
    local fullLow = ""
    pcall(function() fullLow = obj:GetFullName():lower() end)
    -- Only keep non-equipment gameplay/VFX/camera helpers; hide all clothing, accessories, drumsticks & weapons on custom models/CSMs
    return fullLow:find("indicator", 1, true) ~= nil
        or fullLow:find("niagara", 1, true) ~= nil
        or fullLow:find("vfx", 1, true) ~= nil
        or fullLow:find("camera", 1, true) ~= nil
        or fullLow:find("springarm", 1, true) ~= nil
        or fullLow:find("widget", 1, true) ~= nil
end

function CharacterApplier.SetModularAttachmentsHidden(p2Pawn, hide)
    if not UObjectUtils.IsLive(p2Pawn) then return end
    local shouldHide = (hide == true)
    pcall(function()
        local rootMesh = p2Pawn.Mesh
        if not UObjectUtils.IsValid(CachedSKMClass) then
            pcall(function() CachedSKMClass = StaticFindObject("/Script/Engine.SkeletalMeshComponent") end)
        end
        if not UObjectUtils.IsValid(CachedSMClass) then
            pcall(function() CachedSMClass = StaticFindObject("/Script/Engine.StaticMeshComponent") end)
        end

        local function isMeshComp(comp)
            local okM, isM = pcall(function()
                return (UObjectUtils.IsValid(CachedSKMClass) and comp:IsA(CachedSKMClass))
                    or (UObjectUtils.IsValid(CachedSMClass) and comp:IsA(CachedSMClass))
            end)
            return okM and isM == true
        end

        local function applyHideState(comp)
            if not UObjectUtils.IsValid(comp) or UObjectUtils.Same(comp, rootMesh) then return end
            if not isMeshComp(comp) then return end
            if not ShouldKeepAttachedObjectVisible(comp) then
                -- Do NOT propagate to children so attached WidgetComponents / Niagara senses stay visible
                pcall(function() comp:SetHiddenInGame(shouldHide, false) end)
                pcall(function() comp:SetVisibility(not shouldHide, false) end)
            end
        end

        for _, compClass in ipairs({ CachedSKMClass, CachedSMClass }) do
            if UObjectUtils.IsValid(compClass) then
                local comps = p2Pawn:K2_GetComponentsByClass(compClass)
                if comps then
                    UObjectUtils.ForEachObj(comps, applyHideState)
                end
            end
        end

        if UObjectUtils.IsValid(rootMesh) then
            local numChild = 0
            pcall(function() numChild = tonumber(rootMesh:GetNumChildrenComponents()) or 0 end)
            for i = 0, numChild - 1 do
                local child = nil
                pcall(function() child = rootMesh:GetChildComponent(i) end)
                if UObjectUtils.IsValid(child) then
                    applyHideState(child)
                end
            end
        end

        -- Guarantee Player 2's Dodge/Evade Warning widget & Charlie Sense VFX remain unhidden
        for _, keepProp in ipairs({ "DangerIndicatorWidget", "InteractionIndicatorWidget", "RedCharlieSense", "YellowCharlieSense" }) do
            local kc = nil
            pcall(function() kc = p2Pawn[keepProp] end)
            if UObjectUtils.IsValid(kc) then
                pcall(function() kc:SetHiddenInGame(false, false) end)
            end
        end

        LastAttachmentsHiddenPawnKey = UObjectUtils.GetKey(p2Pawn)
        LastAttachmentsHiddenState = shouldHide
    end)
end

-- ============================================================================
-- P2 VISUAL TINT & INTERACTION PROBE ISOLATION
-- ============================================================================

local function ShouldSkipCompForTint(comp)
    if not UObjectUtils.IsLive(comp) then return true end
    local okW, isWidget = pcall(function()
        if not UObjectUtils.IsValid(CachedWCClass) then
            CachedWCClass = StaticFindObject("/Script/UMG.WidgetComponent")
        end
        return UObjectUtils.IsValid(CachedWCClass) and comp:IsA(CachedWCClass)
    end)
    if okW and isWidget then return true end

    local fn = ""
    pcall(function() fn = comp:GetFullName():lower() end)
    for _, kw in ipairs(EXCLUDED_COMP_KEYWORDS) do
        if fn:find(kw, 1, true) then return true end
    end
    local charCfg = Config.Characters or {}
    if fn:find("drumstick", 1, true) and charCfg.TintDrumsticks == false then return true end
    if fn:find("hair", 1, true) and charCfg.TintHair == false then return true end
    return false
end

local function ShouldSkipMatForTint(mat)
    if not UObjectUtils.IsValid(mat) then return true end
    local name = ""
    pcall(function() name = mat:GetFullName():lower() end)
    for _, kw in ipairs(EXCLUDED_MAT_KEYWORDS) do
        if name:find(kw, 1, true) then return true end
    end
    return false
end

function CharacterApplier.ApplyP2VisualStyling(p2Pawn)
    if not UObjectUtils.IsLive(p2Pawn) then return end
    local p1Pawn = SessionManager.GetP1Pawn()
    if p1Pawn and UObjectUtils.Same(p1Pawn, p2Pawn) then return end

    pcall(function()
        -- Prevent P2's single-player probe from hijacking P1's station prompts
        if not UObjectUtils.IsValid(CachedProbeClass) then
            CachedProbeClass = StaticFindObject("/Script/Pagoda.PagodaInteractionProbeComponent_Character")
        end
        local probeClass = CachedProbeClass
        if UObjectUtils.IsValid(probeClass) then
            local probes = p2Pawn:K2_GetComponentsByClass(probeClass)
            if probes then
                UObjectUtils.ForEachObj(probes, function(probe)
                    pcall(function() probe:SetComponentTickEnabled(false) end)
                    pcall(function() probe:SetActive(false, false) end)
                end)
            end
        end

        if not UObjectUtils.IsValid(CachedSKMClass) then
            CachedSKMClass = StaticFindObject("/Script/Engine.SkeletalMeshComponent")
        end
        if not UObjectUtils.IsValid(CachedMIDClass) then
            CachedMIDClass = StaticFindObject("/Script/Engine.MaterialInstanceDynamic")
        end
        local skmClass = CachedSKMClass
        local midClass = CachedMIDClass
        if not UObjectUtils.IsValid(skmClass) then return end
        local comps = p2Pawn:K2_GetComponentsByClass(skmClass)
        if not comps then return end

        local p2Store = ProfileStore.GetP2()
        local isModdedActive = (p2Store.CharacterKey ~= nil and p2Store.CharacterKey ~= "Default")
        local expEnabled = CharacterApplier.IsExperimentalEnabled()
        if isModdedActive or not expEnabled then
            UObjectUtils.ForEachObj(comps, function(mc)
                if not ShouldSkipCompForTint(mc) then
                    pcall(function() mc.bRenderCustomDepth = false end)
                end
            end)
            return
        end

        local charCfg = Config.Characters or {}
        local tintColor = charCfg.TintColor or { R = 0.0, G = 1.0, B = 0.9, A = 1.0 }
        local surfaceColor = {
            R = 0.35 + (tintColor.R or 0.0) * 0.65,
            G = 0.35 + (tintColor.G or 1.0) * 0.65,
            B = 0.35 + (tintColor.B or 0.9) * 0.65,
            A = tintColor.A or 1.0,
        }

        local applyDepth = (charCfg.EnableCustomDepth ~= false)
        local stencilVal = charCfg.StencilValue or 250
        local allowMatTint = (charCfg.EnableTint ~= false) and (CharacterApplier.CurrentTintMode ~= "Off")
        local fullBody = (CharacterApplier.CurrentTintMode == "FullBody")

        UObjectUtils.ForEachObj(comps, function(mc)
            if not ShouldSkipCompForTint(mc) then
                pcall(function()
                    mc.bRenderCustomDepth = applyDepth
                    if applyDepth then mc.CustomDepthStencilValue = stencilVal end
                end)

                if allowMatTint then
                    local numMats = 0
                    pcall(function() numMats = mc:GetNumMaterials() end)
                    for idx = 0, numMats - 1 do
                        pcall(function()
                            local mat = mc:GetMaterial(idx)
                            if UObjectUtils.IsValid(mat) and not ShouldSkipMatForTint(mat) then
                                local mid = mat
                                if not (UObjectUtils.IsValid(midClass) and mat:IsA(midClass)) then
                                    mid = mc:CreateDynamicMaterialInstance(idx, mat, FName("None"))
                                end
                                if UObjectUtils.IsValid(mid) then
                                    for _, pName in ipairs(ACCENT_VECTOR_PARAMS) do
                                        mid:SetVectorParameterValue(FName(pName), tintColor)
                                    end
                                    if fullBody then
                                        for _, pName in ipairs(SURFACE_VECTOR_PARAMS) do
                                            mid:SetVectorParameterValue(FName(pName), surfaceColor)
                                        end
                                        if charCfg.TintHair ~= false then
                                            for _, pName in ipairs(HAIR_VECTOR_PARAMS) do
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

-- ============================================================================
-- CHARACTER DISCOVERY (VANILLA + CSM .utoc/.pak + RUNTIME)
-- ============================================================================

local function RegisterEntry(entry, aliases)
    CharacterApplier.List[#CharacterApplier.List + 1] = entry
    CharacterApplier.ByKey[entry.Key] = entry
    CharacterApplier.ByKey[UObjectUtils.NormalizeId(entry.Key)] = entry
    for _, a in ipairs(aliases or {}) do
        if type(a) == "string" and a ~= "" then
            CharacterApplier.ByKey[UObjectUtils.NormalizeId(a)] = entry
        end
    end
end

function CharacterApplier.ScanAll()
    CharacterApplier.List = {}
    CharacterApplier.ByKey = {}
    LoadRetryCounts = {}

    local seenKeys, seenMeshAddrs = {}, {}

    pcall(function()
        SessionManager.RefreshControllers()
        local p1Pawn = SessionManager.GetP1Pawn()
        if p1Pawn and UObjectUtils.IsValid(p1Pawn.Mesh) then
            local m = CharacterApplier.GetMeshAsset(p1Pawn.Mesh)
            if UObjectUtils.IsValid(m) then
                if not UObjectUtils.IsValid(OriginalP2Mesh) then OriginalP2Mesh = m end
                local k = UObjectUtils.GetKey(m)
                if k then seenMeshAddrs[k] = true end
            end
        end
    end)

    RegisterEntry({
        Key = "Default",
        Name = "Charlie (Modular Wardrobe)",
        ShortName = "Charlie",
        Source = "Vanilla",
        Badge = "VANILLA",
        Container = "Base Game",
        Description = "Vanilla Charlie with full modular Outfits support.",
        Mesh = OriginalP2Mesh,
        AnimClass = OriginalP2AnimClass,
        IsDefault = true,
        IsModded = false,
    }, { "default", "charlie" })

    local okPak, pakChars = pcall(PakScanner.ScanCharacterMods, false)
    if okPak and type(pakChars) == "table" then
        for _, pc in ipairs(pakChars) do
            local key = "csm:" .. tostring(pc.Name)
            local nk = UObjectUtils.NormalizeId(key)
            if not seenKeys[nk] then
                seenKeys[nk] = true
                local clean = FormatCleanName(pc.Name)
                local stackSummary = {}
                if pc.CosmeticDefPath then stackSummary[#stackSummary + 1] = "PPCD" end
                if pc.MeshPath then stackSummary[#stackSummary + 1] = "Mesh" end
                if pc.AnimBPPath then stackSummary[#stackSummary + 1] = "AnimBP" end
                if pc.MaterialPaths and #pc.MaterialPaths > 0 then
                    stackSummary[#stackSummary + 1] = tostring(#pc.MaterialPaths) .. " Mat"
                end

                local metaParts = {}
                if pc.Author and pc.Author ~= "" then metaParts[#metaParts + 1] = "by " .. tostring(pc.Author) end
                if pc.Version and pc.Version ~= "" then metaParts[#metaParts + 1] = "v" .. tostring(pc.Version) end
                local metaPrefix = (#metaParts > 0) and (table.concat(metaParts, " ") .. " | ") or ""
                local descText = (pc.Description and pc.Description ~= "")
                    and (metaPrefix .. tostring(pc.Description))
                    or string.format("%sCSM from %s | Stack: %s.",
                        metaPrefix,
                        tostring(pc.Container or "~mods"),
                        #stackSummary > 0 and table.concat(stackSummary, " + ") or "Asset")

                RegisterEntry({
                    Key = key,
                    Name = clean,
                    ShortName = clean:sub(1, 14),
                    RawName = pc.Name,
                    Source = "CSM",
                    Badge = "CSM MOD",
                    Container = pc.Container or "~mods",
                    Author = pc.Author,
                    Version = pc.Version,
                    Description = descText,
                    CosmeticDefPath = pc.CosmeticDefPath,
                    MeshPath = pc.MeshPath,
                    AnimBPPath = pc.AnimBPPath,
                    MaterialPaths = pc.MaterialPaths,
                    Def = nil,
                    Mesh = nil,
                    PostProcessAnimClass = nil,
                    IsDefault = false,
                    IsModded = true,
                    IsPak = true,
                }, { "pak:" .. tostring(pc.Name), pc.Name, pc.RawFolderName or "", clean })
            end
        end
    else
        Logger.Warn("CharacterApplier", "PakScanner error: %s", tostring(pakChars))
    end

    pcall(function()
        local allMeshes = FindAllOf("SkeletalMesh")
        if not allMeshes then return end
        for _, m in pairs(allMeshes) do
            if UObjectUtils.IsValid(m) then
                local fullPath, meshName = "", ""
                pcall(function() fullPath = m:GetFullName() end)
                pcall(function() meshName = m:GetFName():ToString() end)
                local lowPath = fullPath:lower()
                if (lowPath:find("/moddedcharacters/", 1, true)
                    or lowPath:find("/customcharacters/", 1, true)
                    or lowPath:find("/csm/", 1, true))
                    and not IsNonCharacterMesh(meshName, fullPath) then
                    local mKey = UObjectUtils.GetKey(m)
                    local clean = FormatCleanName(meshName)
                    local normCsm = UObjectUtils.NormalizeId("csm:" .. clean)
                    if mKey and not seenMeshAddrs[mKey] and not seenKeys[normCsm] then
                        seenMeshAddrs[mKey] = true
                        seenKeys[normCsm] = true
                        RegisterEntry({
                            Key = "mem:" .. meshName,
                            Name = clean,
                            ShortName = clean:sub(1, 14),
                            Source = "CSM",
                            Badge = "CSM MEM",
                            Container = "Loaded Memory",
                            Description = string.format("Runtime-loaded custom modded mesh '%s'.", meshName),
                            Mesh = m,
                            IsDefault = false,
                            IsModded = true,
                            IsPak = false,
                        }, { meshName, clean })
                    end
                end
            end
        end
    end)

    for _, exp in ipairs(EXPERIMENTAL_IN_GAME_MODELS) do
        RegisterEntry({
            Key = exp.Key,
            Name = exp.Name,
            ShortName = exp.Name:sub(1, 16),
            Source = exp.Category,
            Badge = exp.Badge,
            Container = "In-Game Model",
            Description = string.format("Experimental playable %s character model (%s).", exp.Category:lower(), exp.Name),
            MeshPath = exp.MeshPath,
            Mesh = nil,
            PostProcessAnimClass = nil,
            IsDefault = false,
            IsModded = true,
            IsPak = false,
            IsExperimental = true,
        }, { exp.Name })
    end

    return CharacterApplier.List
end

function CharacterApplier.FindEntry(key)
    if not key or key == "" then return CharacterApplier.ByKey["Default"] end
    return CharacterApplier.ByKey[key] or CharacterApplier.ByKey[UObjectUtils.NormalizeId(key)]
end

function CharacterApplier.ResolveAssets(entry)
    if not entry then return end
    if entry.IsPak then
        if entry.CosmeticDefPath and not UObjectUtils.IsValid(entry.Def) then
            entry.Def = PakScanner.LoadObject(entry.CosmeticDefPath)
        end
        if entry.MeshPath and not UObjectUtils.IsValid(entry.Mesh) then
            entry.Mesh = PakScanner.LoadObject(entry.MeshPath)
        end
        if entry.AnimBPPath and not UObjectUtils.IsValid(entry.PostProcessAnimClass) then
            entry.PostProcessAnimClass = PakScanner.LoadObject(entry.AnimBPPath)
        end
    elseif entry.IsExperimental then
        if entry.MeshPath and not UObjectUtils.IsValid(entry.Mesh) then
            entry.Mesh = UObjectUtils.LoadObject(entry.MeshPath)
        end
    end
end

-- ============================================================================
-- VISUAL STACK APPLICATION ON P2 ONLY
-- ============================================================================

function CharacterApplier.ReassertMeshOnly(p2Pawn)
    if not (SessionManager.IsSafeForGameplayHooks() and UObjectUtils.IsLive(p2Pawn) and UObjectUtils.IsValid(p2Pawn.Mesh)) then
        return
    end
    local p1Pawn = SessionManager.GetP1Pawn()
    if p1Pawn and UObjectUtils.Same(p1Pawn, p2Pawn) then return end

    local key = ProfileStore.GetP2().CharacterKey
    if not key or key == "Default" then
        if os.clock() >= ApplyingGuardUntil then
            CharacterApplier.ApplyP2VisualStyling(p2Pawn)
        end
        return
    end

    CharacterApplier.SetModularAttachmentsHidden(p2Pawn, true)
    local entry = CharacterApplier.FindEntry(key)
    local targetMesh = entry and entry.Mesh or nil
    CleanStaleCharlieMaterials(p2Pawn.Mesh, targetMesh)
    pcall(function() p2Pawn.Mesh.bRenderCustomDepth = false end)
    if os.clock() < ApplyingGuardUntil then return end

    if not entry then
        CharacterApplier.ScanAll()
        entry = CharacterApplier.FindEntry(key)
        if not entry then return end
    end

    local pawnKey = UObjectUtils.GetKey(p2Pawn)
    if LastAppliedPawnKey ~= pawnKey or LastAppliedKey ~= entry.Key then
        SessionManager.RefreshControllers()
        CharacterApplier.ApplyToP2(SessionManager.GetP1(), SessionManager.GetP2(), p2Pawn, entry.Key)
        return
    end

    CharacterApplier.ResolveAssets(entry)
    if not UObjectUtils.IsValid(entry.Mesh) or not IsSkeletonCompatibleWithCharlie(entry.Mesh, entry) then return end

    local mc = p2Pawn.Mesh
    local curMesh = CharacterApplier.GetMeshAsset(mc)
    if not UObjectUtils.Same(curMesh, entry.Mesh) then
        ApplyingGuardUntil = os.clock() + 0.45
        pcall(function() mc:SetDisablePostProcessBlueprint(true) end)
        local applied = pcall(function() mc:SetSkinnedAssetAndUpdate(entry.Mesh, false) end)
        if not applied then
            pcall(function() mc:SetSkeletalMesh(entry.Mesh, false) end)
        end
        RestoreNativeMeshMaterials(mc, entry.Mesh)
        if UObjectUtils.IsValid(entry.PostProcessAnimClass) then
            pcall(function() mc:SetOverridePostProcessAnimBP(entry.PostProcessAnimClass, false) end)
            pcall(function() mc:SetDisablePostProcessBlueprint(false) end)
        end
        CharacterApplier.SetModularAttachmentsHidden(p2Pawn, true)
        CharacterApplier.ApplyP2VisualStyling(p2Pawn)
        Logger.Debug("CharacterApplier", "Reasserted CSM mesh '%s' on P2.", tostring(entry.Name))
    else
        CleanStaleCharlieMaterials(mc, entry.Mesh)
        CharacterApplier.SetModularAttachmentsHidden(p2Pawn, true)
    end
end

function CharacterApplier.ApplyToP2(p1Ctrl, p2Ctrl, p2Pawn, charKey)
    if not UObjectUtils.IsLive(p2Pawn) then return false, nil end
    local p1Pawn = SessionManager.GetP1Pawn()
    if p1Pawn and UObjectUtils.Same(p1Pawn, p2Pawn) then
        Logger.Error("CharacterApplier", "Blocked attempt to apply P2 character onto Player 1 pawn!")
        return false, nil
    end

    CharacterApplier.CacheOriginalP2Visuals(p2Pawn)
    if #CharacterApplier.List == 0 then
        CharacterApplier.ScanAll()
    end

    local p2Store = ProfileStore.GetP2()
    local wantedKey = charKey or p2Store.CharacterKey or "Default"
    local pawnKey = UObjectUtils.GetKey(p2Pawn)

    local now = os.clock()
    if charKey ~= nil and LastAppliedKey ~= wantedKey and (now - LastSwitchAt) < 0.40 then
        local pendingEntry = (wantedKey == "Default" or wantedKey == "")
            and CharacterApplier.ByKey["Default"]
            or CharacterApplier.FindEntry(wantedKey)
        if pendingEntry then
            p2Store.CharacterKey = pendingEntry.Key
        end
        Scheduler.ReplaceDelay(320, "CharacterApplier.DeferredSwitch", function()
            if not SessionManager.IsSafeForGameplayHooks() then return end
            SessionManager.RefreshControllers()
            local c1, c2, pawn2 = SessionManager.GetP1(), SessionManager.GetP2(), SessionManager.GetP2Pawn()
            if c2 and pawn2 then
                CharacterApplier.ApplyToP2(c1, c2, pawn2, wantedKey)
                if Callbacks.OnCharacterApplied then
                    UObjectUtils.SafeCall("CharacterApplier.DeferredApplied", Callbacks.OnCharacterApplied)
                end
            end
        end, true)
        return true, pendingEntry
    end
    LastSwitchAt = now

    if wantedKey == "Default" or wantedKey == "" then
        ApplyingGuardUntil = os.clock() + 0.80
        p2Store.CharacterKey = "Default"
        LastAppliedKey = "Default"
        LastAppliedPawnKey = pawnKey
        pcall(function()
            local mc = p2Pawn.Mesh
            if UObjectUtils.IsValid(mc) and UObjectUtils.IsValid(OriginalP2Mesh) then
                -- Disable CSM PostProcessAnimBP before swapping skeleton back to Charlie.
                pcall(function() mc:SetDisablePostProcessBlueprint(true) end)
                local cur = CharacterApplier.GetMeshAsset(mc)
                if not UObjectUtils.Same(cur, OriginalP2Mesh) then
                    local okSet = pcall(function() mc:SetSkinnedAssetAndUpdate(OriginalP2Mesh, false) end)
                    if not okSet then
                        pcall(function() mc:SetSkeletalMesh(OriginalP2Mesh, false) end)
                    end
                    RestoreNativeMeshMaterials(mc, OriginalP2Mesh)
                end
                if UObjectUtils.IsValid(OriginalP2AnimClass) then
                    local curAnim = nil
                    pcall(function() curAnim = mc.AnimClass end)
                    if not UObjectUtils.Same(curAnim, OriginalP2AnimClass) then
                        pcall(function() mc:SetAnimInstanceClass(OriginalP2AnimClass) end)
                    end
                end
            end
        end)
        CharacterApplier.SetModularAttachmentsHidden(p2Pawn, false)
        if charKey ~= nil and Callbacks.SaveProfile then
            UObjectUtils.SafeCall("CharacterApplier.SaveDefault", Callbacks.SaveProfile)
        end
        Scheduler.ReplaceDelay(160, "CharacterApplier.RevertOutfit", function()
            if not SessionManager.IsSafeForGameplayHooks() then return end
            if ProfileStore.GetP2().CharacterKey ~= "Default" then return end
            SessionManager.RefreshControllers()
            local c1, c2, pawn2 = SessionManager.GetP1(), SessionManager.GetP2(), SessionManager.GetP2Pawn()
            if c2 and pawn2 then
                CharacterApplier.SetModularAttachmentsHidden(pawn2, false)
                PlayerStateIsolation.ApplyOutfitToP2(c1, c2, pawn2)
                Scheduler.ReplaceDelay(240, "CharacterApplier.StyleAfterRevert", function()
                    if not SessionManager.IsSafeForGameplayHooks() then return end
                    local liveP2 = SessionManager.GetP2Pawn()
                    if liveP2 and ProfileStore.GetP2().CharacterKey == "Default" then
                        CharacterApplier.ApplyP2VisualStyling(liveP2)
                    end
                end, true)
            end
        end, true)
        return true, CharacterApplier.ByKey["Default"]
    end

    local entry = CharacterApplier.FindEntry(wantedKey)
    if not entry then
        CharacterApplier.ScanAll()
        entry = CharacterApplier.FindEntry(wantedKey)
    end
    if not entry or (entry.IsExperimental and not CharacterApplier.IsExperimentalEnabled()) then
        Logger.Warn("CharacterApplier", "Character '%s' unavailable or Experimental disabled -> defaulting to Vanilla Charlie.", tostring(wantedKey))
        p2Store.CharacterKey = "Default"
        if Callbacks.SaveProfile then UObjectUtils.SafeCall("CharacterApplier.SaveFallback", Callbacks.SaveProfile) end
        CharacterApplier.ApplyToP2(p1Ctrl, p2Ctrl, p2Pawn, "Default")
        return false, nil
    end

    CharacterApplier.ResolveAssets(entry)
    if not (UObjectUtils.IsValid(entry.Mesh) or UObjectUtils.IsValid(entry.Def)) then
        local retries = (LoadRetryCounts[entry.Key] or 0) + 1
        LoadRetryCounts[entry.Key] = retries
        if retries <= MAX_ASSET_LOAD_RETRIES then
            Logger.Warn("CharacterApplier", "Model '%s' assets still streaming (attempt %d/%d); retrying.",
                tostring(entry.Name), retries, MAX_ASSET_LOAD_RETRIES)
            p2Store.CharacterKey = entry.Key
            Scheduler.ReplaceDelay(450, "CharacterApplier.RetryCSMLoad", function()
                if not SessionManager.IsSafeForGameplayHooks() then return end
                SessionManager.RefreshControllers()
                local c1, c2, pawn2 = SessionManager.GetP1(), SessionManager.GetP2(), SessionManager.GetP2Pawn()
                if c2 and pawn2 and ProfileStore.GetP2().CharacterKey == entry.Key then
                    CharacterApplier.ApplyToP2(c1, c2, pawn2, entry.Key)
                end
            end, true)
        else
            Logger.Warn("CharacterApplier", "Giving up on '%s' after %d failed asset loads.",
                tostring(entry.Name), MAX_ASSET_LOAD_RETRIES)
        end
        return false, entry
    end
    LoadRetryCounts[entry.Key] = nil

    if UObjectUtils.IsValid(entry.Mesh) and not IsSkeletonCompatibleWithCharlie(entry.Mesh, entry) then
        Logger.Warn("CharacterApplier", "Refused incompatible skeleton on '%s' to prevent crash.", tostring(entry.Name))
        return false, nil
    end

    pcall(function()
        if UObjectUtils.IsValid(p2Pawn.Mesh) then
            p2Pawn.Mesh.bRenderCustomDepth = false
            pcall(function() p2Pawn.Mesh:SetDisablePostProcessBlueprint(true) end)
        end
    end)

    if LastAppliedKey == entry.Key and LastAppliedPawnKey == pawnKey and UObjectUtils.IsValid(p2Pawn.Mesh) then
        local curMesh = CharacterApplier.GetMeshAsset(p2Pawn.Mesh)
        if UObjectUtils.IsValid(entry.Mesh) and UObjectUtils.Same(curMesh, entry.Mesh) then
            CleanStaleCharlieMaterials(p2Pawn.Mesh, entry.Mesh)
            CharacterApplier.SetModularAttachmentsHidden(p2Pawn, true)
            return true, entry
        end
    end

    ApplyingGuardUntil = os.clock() + 0.90
    p2Store.CharacterKey = entry.Key
    LastAppliedKey = entry.Key
    LastAppliedPawnKey = pawnKey
    local lockedKey = entry.Key

    if UObjectUtils.IsLive(p2Ctrl) then
        PlayerStateIsolation.UnequipCosmeticsForCSM(p1Ctrl, p2Ctrl, p2Pawn, entry.Def)
    end

    local function ensureVisualStack()
        if not SessionManager.IsSafeForGameplayHooks() then return end
        local liveP2 = SessionManager.GetP2Pawn()
        if not (liveP2 and UObjectUtils.Same(liveP2, p2Pawn)) then return end
        if ProfileStore.GetP2().CharacterKey ~= lockedKey then return end
        if not UObjectUtils.IsValid(liveP2.Mesh) then return end

        local mc = liveP2.Mesh
        if UObjectUtils.IsValid(entry.Mesh) then
            local curMesh = CharacterApplier.GetMeshAsset(mc)
            if not UObjectUtils.Same(curMesh, entry.Mesh) then
                pcall(function() mc:SetDisablePostProcessBlueprint(true) end)
                local applied = pcall(function() mc:SetSkinnedAssetAndUpdate(entry.Mesh, false) end)
                if not applied then
                    pcall(function() mc:SetSkeletalMesh(entry.Mesh, false) end)
                end
                RestoreNativeMeshMaterials(mc, entry.Mesh)
                if UObjectUtils.IsValid(entry.PostProcessAnimClass) then
                    pcall(function() mc:SetOverridePostProcessAnimBP(entry.PostProcessAnimClass, false) end)
                    pcall(function() mc:SetDisablePostProcessBlueprint(false) end)
                end
            else
                CleanStaleCharlieMaterials(mc, entry.Mesh)
                if UObjectUtils.IsValid(entry.PostProcessAnimClass) then
                    pcall(function() mc:SetDisablePostProcessBlueprint(false) end)
                end
            end
        end

        CharacterApplier.SetModularAttachmentsHidden(liveP2, true)
        CharacterApplier.ApplyP2VisualStyling(liveP2)
    end

    ensureVisualStack()
    Scheduler.ReplaceDelay(120, "CharacterApplier.PostVerifyFast", ensureVisualStack, true)
    Scheduler.ReplaceDelay(300, "CharacterApplier.PostVerify", ensureVisualStack, true)
    Scheduler.ReplaceDelay(650, "CharacterApplier.PostVerifyLate", ensureVisualStack, true)

    if charKey ~= nil and Callbacks.SaveProfile then
        UObjectUtils.SafeCall("CharacterApplier.SaveCSM", Callbacks.SaveProfile)
    end
    Logger.Info("CharacterApplier", "Applied '%s' (%s) to Player 2.", tostring(entry.Name), tostring(entry.Source))
    return true, entry
end

function CharacterApplier.TickWatchdog()
    if os.clock() < ApplyingGuardUntil then return end
    if not SessionManager.IsSafeForGameplayHooks() or SessionManager.State.IsInCutscene then return end
    local key = ProfileStore.GetP2().CharacterKey
    if not key or key == "Default" then return end

    local p2Pawn = SessionManager.GetP2Pawn()
    if not (p2Pawn and UObjectUtils.IsValid(p2Pawn.Mesh)) then return end

    local entry = CharacterApplier.FindEntry(key)
    local pawnKey = UObjectUtils.GetKey(p2Pawn)
    if entry and UObjectUtils.IsValid(entry.Mesh)
        and LastAppliedPawnKey == pawnKey
        and LastAppliedKey == entry.Key
        and LastAttachmentsHiddenPawnKey == pawnKey
        and LastAttachmentsHiddenState == true then
        local curMesh = CharacterApplier.GetMeshAsset(p2Pawn.Mesh)
        if UObjectUtils.Same(curMesh, entry.Mesh) then
            -- Fast path: mesh & attachments already verified on this pawn; only check materials lightly
            CleanStaleCharlieMaterials(p2Pawn.Mesh, entry.Mesh)
            return
        end
    end

    CharacterApplier.ReassertMeshOnly(p2Pawn)
end

return CharacterApplier
