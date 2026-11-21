-- ============================================================================
-- CO-OP REVIVE STATE MACHINE & GROUNDED -> DANCE RECOVERY
-- ============================================================================
-- Explicit Per-Player States:
--   "Alive" | "Downed" | "BeingRevived" | "Invulnerable" | "Wiped"
--
-- Features:
--   1. Real Downed-on-Ground Animation:
--        * Plays cooked AM_Player_KnockBwd_Land_Bwd and pauses flat on floor
--          (with AM_Player_GetUp_Bwd @ 0.03s ground hold fallback).
--   2. Stand-Up Disco Dance on Revive:
--        * Kips up via AM_Player_Knockdown_GetUp_Quick_Bwd -> celebrates with
--          a random/rotating AM_Player_Dance_* montage (input-cancellable!).
--   3. Dynamic Revive Circle (via UI.ReviveOverlay):
--        * 3D floor boundary ring + spinning expanding progress ring around the
--          downed player, plus a projected native circular medallion HUD.
--   4. Guaranteed 3-Tier HP Restoration + Anti-Re-Down Guard (never stuck at 1 HP).
--   5. Native FMOD Audio Cues + Simultaneous Double-Down Wipe (GE_Die).
-- ============================================================================

local UEHelpers = require("UEHelpers")
local UObjectUtils = require("Utils.UObjectUtils")
local Logger = require("Utils.Logger")
local Scheduler = require("Core.Scheduler")
local SessionManager = require("Core.SessionManager")
local InputRouting = require("Input.InputRouting")
local ReviveOverlay = require("UI.ReviveOverlay")
local UITheme = require("UI.UITheme")

local ReviveSystem = {}

local Config = {}
local Callbacks = {}

local GAS_ASSET_SPECS = {
    DeathImmune     = { Pkg = "/Game/Pagoda/Characters/Common/Effects/GE_DeathImmune",              Cls = "GE_DeathImmune_C" },
    DBNO            = { Pkg = "/Game/Pagoda/Characters/Common/Effects/GE_DBNO",                     Cls = "GE_DBNO_C" },
    Die             = { Pkg = "/Game/Pagoda/Characters/Common/Effects/GE_Die",                      Cls = "GE_Die_C" },
    DamageImmune    = { Pkg = "/Game/Pagoda/Characters/Common/Effects/GE_DamageImmune",             Cls = "GE_DamageImmune_C" },
    MovementDisable = { Pkg = "/Game/Pagoda/Characters/Common/Effects/GE_Movement_Disable",         Cls = "GE_Movement_Disable_C" },
    InvalidTarget   = { Pkg = "/Game/Pagoda/Characters/Common/Effects/GE_InvalidTarget",            Cls = "GE_InvalidTarget_C" },
    InvalidAOETgt   = { Pkg = "/Game/Pagoda/Characters/Common/Effects/GE_InvalidAOETarget",         Cls = "GE_InvalidAOETarget_C" },
    EnemiesBreakOff = { Pkg = "/Game/Pagoda/Characters/Common/Effects/GE_EnemiesBreakOff",          Cls = "GE_EnemiesBreakOff_C" },
    HealSetByCaller = { Pkg = "/Game/Pagoda/Characters/Common/Effects/GE_Healing_SetByCaller",      Cls = "GE_Healing_SetByCaller_C" },
    RestoreFullHP   = { Pkg = "/Game/Pagoda/Characters/Common/Effects/GE_Periodic_RestoreToFullHP", Cls = "GE_Periodic_RestoreToFullHP_C" },
    HealthRegen     = { Pkg = "/Game/Pagoda/Characters/Player/Abilities/DataMods/GE_Player_HealthRegen", Cls = "GE_Player_HealthRegen_C" },
    DmgSetByCaller  = { Pkg = "/Game/Pagoda/Characters/Common/Effects/GE_Damage_SetByCaller",       Cls = "GE_Damage_SetByCaller_C" },
    RevivingAbility = { Pkg = "/Game/Pagoda/Characters/Player/Abilities/Revive/GA_Reviving",        Cls = "GA_Reviving_C" },
}

local ANIM_MONTAGE_PATHS = {
    Knockdown  = "/Game/Pagoda/Characters/Player/Animations/Hit_Reactions/AM_Player_KnockBwd_Land_Bwd.AM_Player_KnockBwd_Land_Bwd",
    GroundPose = "/Game/Pagoda/Characters/Player/Animations/Hit_Reactions/AM_Player_GetUp_Bwd.AM_Player_GetUp_Bwd",
    QuickGetUp = "/Game/Pagoda/Characters/Player/Animations/Hit_Reactions/AM_Player_Knockdown_GetUp_Quick_Bwd.AM_Player_Knockdown_GetUp_Quick_Bwd",
}

-- Flat supine floor poses played via EAnimationMode::AnimationSingleNode (Mode 1),
-- bypassing ABP_Player MotionMatching so downed characters lie genuinely flat on the ground.
local GROUND_ANIM_SEQUENCES = {
    Primary     = "/Game/Pagoda/Characters/Player/Animations/Hit_Reactions/A_Player_GetUp_Bwd.A_Player_GetUp_Bwd",
    PrimaryPos  = 0.02,
    Fallback    = "/Game/Pagoda/Characters/Player/Animations/Cinematics/A_Player_Cinematic_FTUE_Intro_Revival.A_Player_Cinematic_FTUE_Intro_Revival",
    FallbackPos = 0.05,
}

local REVIVE_DANCE_PATHS = {
    "/Game/Pagoda/Characters/Player/Animations/Dance_Moves/AM_Player_Dance_AbsoluteDisco.AM_Player_Dance_AbsoluteDisco",
    "/Game/Pagoda/Characters/Player/Animations/Dance_Moves/AM_Player_Dance_Groovy.AM_Player_Dance_Groovy",
    "/Game/Pagoda/Characters/Player/Animations/Dance_Moves/AM_Player_Dance_Disco.AM_Player_Dance_Disco",
    "/Game/Pagoda/Characters/Player/Animations/Dance_Moves/AM_Player_Dance_Shuffle.AM_Player_Dance_Shuffle",
    "/Game/Pagoda/Characters/Player/Animations/Dance_Moves/AM_Player_Dance_Point.AM_Player_Dance_Point",
}

local CachedAssets = {}
local CachedMontages = {}
local AssetsCheckedThisWorld = false
local GrantedRevivePawns = {}
local LastDeaggroAt = 0.0
local CachedKeyStructs = {}
local LastTickTime = 0.0
local DanceCycleIndex = 0

local function CreatePlayerState()
    return {
        State = "Alive",
        DownedAt = 0.0,
        DownedHealth = 1.0,
        InvulnUntil = 0.0,
        ReviveProgress = 0.0,
        OutOfRangeTime = 0.0,
        DeathImmuneHandle = nil,
        DeathImmuneAscKey = nil,
        DownedGEHandles = {},
        InvulnGEHandle = nil,
        InvulnBreakOffHandle = nil,
        TempHealGEHandle = nil,
        TempRegenGEHandle = nil,
        TempHealTargetHp = 0.0,
        TempHealExpireAt = 0.0,
        DownedPawn = nil,
        DownedMontage = nil,
        DownedHoldPos = 0.68,
        DownedAnimLocked = false,
        DownedSingleNodeActive = false,
        SavedAnimClass = nil,
        DownedSeqAsset = nil,
        DownedSeqPos = 0.02,
        ReviveDanceMontage = nil,
        ReviveDanceStartAt = 0.0,
        ReviveDanceEndAt = 0.0,
        Health = 100.0,
        MaxHealth = 100.0,
    }
end

ReviveSystem.Players = {
    [0] = CreatePlayerState(),
    [1] = CreatePlayerState(),
}

local AI_TARGET_BB_KEYS = {
    "TargetActor", "Target", "PlayerTarget", "TargetPlayer",
    "CombatTarget", "AttackTarget", "EnemyTarget", "TargetPawn",
    "AggroTarget", "PendingAttackPlayerTarget",
}

local CANCEL_GAMEPAD_KEYS = {
    "Gamepad_FaceButton_Bottom", "Gamepad_FaceButton_Right",
    "Gamepad_FaceButton_Left", "Gamepad_FaceButton_Top",
    "Gamepad_RightShoulder", "Gamepad_RightTrigger",
}
local CANCEL_KB_KEYS = {
    "W", "A", "S", "D", "SpaceBar", "LeftShift", "LeftMouseButton", "RightMouseButton",
}

local function GetKeyStruct(kn)
    local ks = CachedKeyStructs[kn]
    if not ks then
        ks = { KeyName = FName(kn) }
        CachedKeyStructs[kn] = ks
    end
    return ks
end

function ReviveSystem.Init(config, callbacks)
    Config = config or {}
    Callbacks = callbacks or {}
end

function ReviveSystem.DestroyHUD()
    ReviveOverlay.Destroy()
end

function ReviveSystem.HideHUD()
    ReviveOverlay.Hide()
end

-- ============================================================================
-- ASSET LOADING & ANIMATION MONTAGE HELPERS
-- ============================================================================

local function EnsureAssetsCached()
    if AssetsCheckedThisWorld then
        return CachedAssets
    end
    AssetsCheckedThisWorld = true
    for key, spec in pairs(GAS_ASSET_SPECS) do
        if not UObjectUtils.IsValid(CachedAssets[key]) then
            CachedAssets[key] = UObjectUtils.LoadClass(spec.Pkg, spec.Cls)
        end
    end
    return CachedAssets
end

local function LoadMontage(path)
    if not path then return nil end
    local cached = CachedMontages[path]
    if cached ~= nil then
        return UObjectUtils.IsValid(cached) and cached or nil
    end
    local obj = UObjectUtils.LoadObject(path)
    CachedMontages[path] = UObjectUtils.IsValid(obj) and obj or false
    return UObjectUtils.IsValid(obj) and obj or nil
end

local function GetPawnAnimInstance(pawn)
    if not UObjectUtils.IsLive(pawn) then return nil end
    local animInst = nil
    pcall(function()
        if UObjectUtils.IsValid(pawn.Mesh) then
            animInst = pawn.Mesh:GetAnimInstance()
        end
    end)
    return UObjectUtils.IsValid(animInst) and animInst or nil
end

local function PlayMontageClean(pawn, montage, rate, startPos)
    if not (UObjectUtils.IsLive(pawn) and UObjectUtils.IsValid(montage)) then return false end
    local animInst = GetPawnAnimInstance(pawn)
    if UObjectUtils.IsValid(animInst) then
        local ok, len = pcall(function()
            return animInst:Montage_Play(montage, rate or 1.0, 0, startPos or 0.0, true)
        end)
        if ok and (type(len) ~= "number" or len > 0.0) then
            return true
        end
    end
    local okPawn, lenPawn = pcall(function()
        return pawn:PlayAnimMontage(montage, rate or 1.0, FName("None"))
    end)
    return okPawn and (type(lenPawn) ~= "number" or lenPawn > 0.0)
end

local function StopPawnMontage(pawn, montage, blendOut)
    if not UObjectUtils.IsLive(pawn) then return end
    local animInst = GetPawnAnimInstance(pawn)
    if UObjectUtils.IsValid(animInst) and UObjectUtils.IsValid(montage) then
        pcall(function() animInst:Montage_Stop(blendOut or 0.15, montage) end)
    end
    if not montage then
        pcall(function() pawn:StopAnimMontage(nil) end)
    end
end

local function LockPawnFlatOnGround(st, pawn)
    if not UObjectUtils.IsLive(pawn) then return false end
    local mc = nil
    pcall(function() mc = pawn.Mesh end)
    if not UObjectUtils.IsValid(mc) then return false end

    local seq = LoadMontage(GROUND_ANIM_SEQUENCES.Primary)
    local pos = GROUND_ANIM_SEQUENCES.PrimaryPos
    if not UObjectUtils.IsValid(seq) then
        seq = LoadMontage(GROUND_ANIM_SEQUENCES.Fallback)
        pos = GROUND_ANIM_SEQUENCES.FallbackPos
    end
    if not UObjectUtils.IsValid(seq) then return false end

    if not UObjectUtils.IsValid(st.SavedAnimClass) then
        pcall(function()
            local ac = mc.AnimClass
            if UObjectUtils.IsValid(ac) then st.SavedAnimClass = ac end
        end)
    end

    StopPawnMontage(pawn, nil, 0.0)
    st.DownedMontage = nil
    st.DownedSeqAsset = seq
    st.DownedSeqPos = pos

    pcall(function()
        if pawn.CharacterMovement then
            pawn.CharacterMovement:StopMovementImmediately()
        end
    end)

    pcall(function() mc:SetAnimationMode(1) end) -- EAnimationMode::AnimationSingleNode
    local okOverride = pcall(function() mc:OverrideAnimationData(seq, false, false, pos, 0.0) end)
    if not okOverride then
        pcall(function()
            mc:PlayAnimation(seq, false)
            mc:SetPosition(pos, false)
            mc:Stop()
        end)
    end

    st.DownedSingleNodeActive = true
    st.DownedAnimLocked = true
    return true
end

local function RestorePawnAnimBlueprint(st, pawn)
    if not UObjectUtils.IsLive(pawn) then return end
    local mc = nil
    pcall(function() mc = pawn.Mesh end)
    if not UObjectUtils.IsValid(mc) then
        st.DownedSingleNodeActive = false
        st.DownedAnimLocked = false
        return
    end

    local curMode = 0
    pcall(function() curMode = tonumber(mc:GetAnimationMode()) or 0 end)
    if st.DownedSingleNodeActive or curMode ~= 0 then
        pcall(function() mc:SetAnimationMode(0) end) -- EAnimationMode::AnimationBlueprint
        local animInst = GetPawnAnimInstance(pawn)
        if not UObjectUtils.IsValid(animInst) and UObjectUtils.IsValid(st.SavedAnimClass) then
            pcall(function() mc:SetAnimInstanceClass(st.SavedAnimClass) end)
        end
    end
    st.DownedSingleNodeActive = false
    st.DownedAnimLocked = false
    st.DownedSeqAsset = nil
end

local function StartDownedAnimation(st, pawn)
    if not UObjectUtils.IsLive(pawn) then return end
    StopPawnMontage(pawn, nil, 0.06)

    pcall(function()
        local mc = pawn.Mesh
        if UObjectUtils.IsValid(mc) and UObjectUtils.IsValid(mc.AnimClass) then
            st.SavedAnimClass = mc.AnimClass
        end
    end)

    local knock = LoadMontage(ANIM_MONTAGE_PATHS.Knockdown)
    if UObjectUtils.IsValid(knock) then
        st.DownedMontage = knock
        st.DownedAnimLocked = false
        st.DownedSingleNodeActive = false
        PlayMontageClean(pawn, knock, 1.35, 0.0)
    else
        LockPawnFlatOnGround(st, pawn)
    end
end

local function MaintainDownedAnimation(st, pawn, now)
    if not UObjectUtils.IsLive(pawn) then return end
    pcall(function()
        if pawn.CharacterMovement then
            pawn.CharacterMovement:StopMovementImmediately()
        end
    end)

    local elapsed = now - (st.DownedAt or now)
    if not st.DownedSingleNodeActive then
        local stillDropping = false
        if UObjectUtils.IsValid(st.DownedMontage) and elapsed < 0.34 then
            local animInst = GetPawnAnimInstance(pawn)
            if UObjectUtils.IsValid(animInst) then
                pcall(function() stillDropping = (animInst:Montage_IsPlaying(st.DownedMontage) == true) end)
            end
        end
        if stillDropping then
            return
        end
        if LockPawnFlatOnGround(st, pawn) then
            return
        end
    else
        local mc = nil
        pcall(function() mc = pawn.Mesh end)
        if UObjectUtils.IsValid(mc) then
            local mode = 1
            pcall(function() mode = tonumber(mc:GetAnimationMode()) or 0 end)
            if mode ~= 1 then
                LockPawnFlatOnGround(st, pawn)
            end
        end
        return
    end

    -- Fallback montage hold if UAnimSequence SingleNode failed
    local animInst = GetPawnAnimInstance(pawn)
    if not UObjectUtils.IsValid(animInst) then return end
    local ground = LoadMontage(ANIM_MONTAGE_PATHS.GroundPose)
    if UObjectUtils.IsValid(ground) then
        st.DownedMontage = ground
        st.DownedHoldPos = 0.02
        st.DownedAnimLocked = true
        local playing = false
        pcall(function() playing = (animInst:Montage_IsPlaying(ground) == true) end)
        if not playing then
            PlayMontageClean(pawn, ground, 1.0, 0.02)
        end
        pcall(function()
            animInst:Montage_SetPosition(ground, 0.02)
            animInst:Montage_Pause(ground)
        end)
    end
end

local function StopAllReviveMontages(st, pawn)
    if UObjectUtils.IsLive(pawn) then
        RestorePawnAnimBlueprint(st, pawn)
        if UObjectUtils.IsValid(st.DownedMontage) then
            StopPawnMontage(pawn, st.DownedMontage, 0.12)
        end
        if UObjectUtils.IsValid(st.ReviveDanceMontage) then
            StopPawnMontage(pawn, st.ReviveDanceMontage, 0.18)
        end
    end
    st.DownedMontage = nil
    st.DownedAnimLocked = false
    st.DownedSingleNodeActive = false
    st.DownedSeqAsset = nil
    st.ReviveDanceMontage = nil
    st.ReviveDanceStartAt = 0.0
    st.ReviveDanceEndAt = 0.0
end

local function StartReviveStandUpDance(pid, st, pawn)
    local revCfg = Config.Revive or {}
    if not UObjectUtils.IsLive(pawn) or revCfg.PlayReviveStandUpDance == false then return end

    local quickGetUp = LoadMontage(ANIM_MONTAGE_PATHS.QuickGetUp) or LoadMontage(ANIM_MONTAGE_PATHS.GroundPose)
    if UObjectUtils.IsValid(quickGetUp) then
        if not PlayMontageClean(pawn, quickGetUp, 1.30, 0.0) then
            Scheduler.Defer("Revive.QuickGetUp." .. tostring(pid), function()
                local livePawn = SessionManager.GetPawn(pid)
                if UObjectUtils.IsLive(livePawn) then
                    PlayMontageClean(livePawn, quickGetUp, 1.30, 0.0)
                end
            end, true)
        end
    end

    DanceCycleIndex = (DanceCycleIndex % #REVIVE_DANCE_PATHS) + 1
    local dancePath = REVIVE_DANCE_PATHS[DanceCycleIndex]
    local danceMontage = LoadMontage(dancePath)
    if UObjectUtils.IsValid(danceMontage) then
        Scheduler.ReplaceDelay(360, "Revive.StandUpDance." .. tostring(pid), function()
            local livePawn = SessionManager.GetPawn(pid)
            local curSt = ReviveSystem.Players[pid]
            if not (UObjectUtils.IsLive(livePawn) and curSt) then return end
            if curSt.State ~= "Invulnerable" and curSt.State ~= "Alive" then return end
            if PlayMontageClean(livePawn, danceMontage, 1.08, 0.0) then
                local tNow = os.clock()
                curSt.ReviveDanceMontage = danceMontage
                curSt.ReviveDanceStartAt = tNow
                curSt.ReviveDanceEndAt = tNow + 1.65
            end
        end, true)
    end
end

local function ShouldCancelReviveDance(pid, ctrl)
    if not UObjectUtils.IsLive(ctrl) then return false end
    local sx, sy = 0.0, 0.0
    pcall(function()
        sx = tonumber(ctrl:GetInputAnalogKeyState(GetKeyStruct("Gamepad_LeftX"))) or 0.0
        sy = tonumber(ctrl:GetInputAnalogKeyState(GetKeyStruct("Gamepad_LeftY"))) or 0.0
    end)
    if (sx * sx + sy * sy) > (0.58 * 0.58) then return true end

    for _, kn in ipairs(CANCEL_GAMEPAD_KEYS) do
        local ok, down = pcall(function() return ctrl:IsInputKeyDown(GetKeyStruct(kn)) end)
        if ok and down == true then return true end
    end
    if pid == 0 then
        for _, kn in ipairs(CANCEL_KB_KEYS) do
            local ok, down = pcall(function() return ctrl:IsInputKeyDown(GetKeyStruct(kn)) end)
            if ok and down == true then return true end
        end
    end
    return false
end

local function TickReviveDanceCancel(pid, st, pawn, ctrl, now)
    if not UObjectUtils.IsValid(st.ReviveDanceMontage) then return end
    if now >= (st.ReviveDanceEndAt or 0.0) then
        StopPawnMontage(pawn, st.ReviveDanceMontage, 0.22)
        st.ReviveDanceMontage = nil
        st.ReviveDanceStartAt = 0.0
        st.ReviveDanceEndAt = 0.0
        return
    end
    if (now - (st.ReviveDanceStartAt or now)) >= 0.35 and ShouldCancelReviveDance(pid, ctrl) then
        StopPawnMontage(pawn, st.ReviveDanceMontage, 0.16)
        st.ReviveDanceMontage = nil
        st.ReviveDanceStartAt = 0.0
        st.ReviveDanceEndAt = 0.0
    end
end

-- ============================================================================
-- LOW-LEVEL GAS EFFECT & HEALTH RESTORATION HELPERS
-- ============================================================================

local function ApplySimpleGE(asc, geClass)
    if not (UObjectUtils.IsValid(asc) and UObjectUtils.IsValid(geClass)) then return nil end
    local ok, res = pcall(function()
        local ctx = asc:MakeEffectContext()
        return asc:BP_ApplyGameplayEffectToSelf(geClass, 1.0, ctx)
    end)
    if not ok then
        Logger.Warn("Revive", "ApplySimpleGE(%s) failed: %s", tostring(geClass), tostring(res))
        return nil
    end
    return res
end

local function RemoveGE(asc, handle)
    if not (UObjectUtils.IsValid(asc) and handle ~= nil) then return end
    pcall(function() asc:RemoveActiveGameplayEffect(handle, -1) end)
end

local function HasGameplayTag(asc, tagStr)
    if not UObjectUtils.IsValid(asc) then return false end
    local ts = UObjectUtils.MakeTagFromString(tagStr)
    if not ts then return false end
    local ok, has = pcall(function() return asc:HasMatchingGameplayTag(ts) end)
    return ok and has == true
end

local function SetLooseTag(asc, ctrl, tagStr, shouldHave)
    local ts = UObjectUtils.MakeTagFromString(tagStr)
    if UObjectUtils.IsValid(asc) and ts then
        pcall(function()
            if shouldHave then
                if not HasGameplayTag(asc, tagStr) then
                    asc:K2_AddLooseGameplayTag(ts, 1)
                end
            else
                for _ = 1, 6 do
                    asc:K2_RemoveLooseGameplayTag(ts, 1)
                end
            end
        end)
    end
    if UObjectUtils.IsLive(ctrl) and UObjectUtils.IsValid(ctrl.CheatManager) then
        pcall(function()
            if shouldHave then
                ctrl.CheatManager:AddTagToSelf(tagStr)
            else
                ctrl.CheatManager:RemoveTagFromSelf(tagStr)
            end
        end)
    end
end

local function ApplySetByCallerGE(asc, geClass, tagStr, magnitude)
    if not (UObjectUtils.IsValid(asc) and UObjectUtils.IsValid(geClass)) then return false end
    local asbl = UObjectUtils.GetAbilitySystemLibrary()
    local tagStruct = UObjectUtils.MakeTagFromString(tagStr)
    if not (asbl and tagStruct) then return false end

    local ok, errOrRes = pcall(function()
        local ctx = asc:MakeEffectContext()
        local spec = asc:MakeOutgoingSpec(geClass, 1.0, ctx)
        if not spec then return false end
        local assigned = asbl:AssignTagSetByCallerMagnitude(spec, tagStruct, magnitude)
        asc:BP_ApplyGameplayEffectSpecToSelf((assigned ~= nil) and assigned or spec)
        return true
    end)
    if not ok then
        Logger.Warn("Revive", "ApplySetByCallerGE(%s, %.1f) error: %s", tostring(tagStr), magnitude or 0.0, tostring(errOrRes))
        return false
    end
    return errOrRes == true
end

local function PlayReviveFX(pawn, isDownedEvent)
    local revCfg = Config.Revive or {}
    if revCfg.EnableReviveAudioFX == false then return end

    if isDownedEvent then
        UITheme.PlayUISound("Downed", true)
        return
    end

    UITheme.PlayUISound("Revive", true)
    UITheme.PlayUISound("ReviveHeal", true)
    local asc = UObjectUtils.GetASC(pawn)
    local cueTag = UObjectUtils.MakeTagFromString("GameplayCue.Death.Heal.Explode")
    if UObjectUtils.IsValid(asc) and cueTag then
        pcall(function()
            if type(asc.ExecuteGameplayCue) == "function" then
                asc:ExecuteGameplayCue(cueTag, asc:MakeEffectContext())
            end
        end)
    end
end

function ReviveSystem.GetHealth(pawn)
    local hp = nil
    pcall(function() if UObjectUtils.IsLive(pawn) then hp = pawn:GetHealth() end end)
    if type(hp) == "number" then return hp end
    pcall(function()
        if UObjectUtils.IsLive(pawn) and UObjectUtils.IsValid(pawn.HealthAttributeSet) and pawn.HealthAttributeSet.Health then
            hp = pawn.HealthAttributeSet.Health.CurrentValue
        end
    end)
    return (type(hp) == "number") and hp or 100.0
end

function ReviveSystem.GetMaxHealth(pawn)
    local maxHp = nil
    pcall(function() if UObjectUtils.IsLive(pawn) then maxHp = pawn:GetMaxHealth() end end)
    if type(maxHp) == "number" and maxHp > 0 then return maxHp end
    pcall(function()
        if UObjectUtils.IsLive(pawn) and UObjectUtils.IsValid(pawn.HealthAttributeSet) and pawn.HealthAttributeSet.MaxHealth then
            maxHp = pawn.HealthAttributeSet.MaxHealth.CurrentValue
        end
    end)
    return (type(maxHp) == "number" and maxHp > 0) and maxHp or 100.0
end

local function WriteDirectHealthAttribute(pawn, targetHp)
    if not UObjectUtils.IsLive(pawn) then return false end
    local wrote = false
    pcall(function()
        local has = pawn.HealthAttributeSet
        if UObjectUtils.IsValid(has) and has.Health then
            has.Health.BaseValue = targetHp
            has.Health.CurrentValue = targetHp
            wrote = true
        end
    end)
    if wrote then
        pcall(function()
            if type(pawn.OnHealthChanged) == "function" then
                pawn:OnHealthChanged()
            end
        end)
    end
    return wrote
end

local function RestoreHealthGuaranteed(st, pawn, asc, targetHp, maxHp)
    local assets = EnsureAssetsCached()
    local cur = ReviveSystem.GetHealth(pawn)
    if cur >= targetHp - 0.5 then return "AlreadyHealthy" end

    local delta = math.max(1.0, targetHp - cur)

    -- Tier 1: GE_Healing_SetByCaller with SetByCaller.Heal
    if UObjectUtils.IsValid(asc) and UObjectUtils.IsValid(assets.HealSetByCaller) then
        ApplySetByCallerGE(asc, assets.HealSetByCaller, "SetByCaller.Heal", delta)
        cur = ReviveSystem.GetHealth(pawn)
        if cur >= targetHp - 0.5 then return "GE_Healing_SetByCaller" end

        local asbl = UObjectUtils.GetAbilitySystemLibrary()
        if asbl then
            pcall(function()
                local ctx = asc:MakeEffectContext()
                local spec = asc:MakeOutgoingSpec(assets.HealSetByCaller, 1.0, ctx)
                if spec then
                    local fn = UEHelpers.FindOrAddFName("SetByCaller.Heal")
                    local assigned = asbl:AssignSetByCallerMagnitude(spec, fn, delta)
                    asc:BP_ApplyGameplayEffectSpecToSelf(assigned or spec)
                end
            end)
            cur = ReviveSystem.GetHealth(pawn)
            if cur >= targetHp - 0.5 then return "GE_Healing_NameSetByCaller" end
        end
    end

    -- Tier 2: Native GE_Periodic_RestoreToFullHP (transient)
    if UObjectUtils.IsValid(asc) and UObjectUtils.IsValid(assets.RestoreFullHP) then
        local h = ApplySimpleGE(asc, assets.RestoreFullHP)
        if h ~= nil then
            cur = ReviveSystem.GetHealth(pawn)
            if cur >= targetHp - 0.5 then
                RemoveGE(asc, h)
                if cur > targetHp + 0.5 then
                    WriteDirectHealthAttribute(pawn, math.min(maxHp, targetHp))
                end
                return "GE_Periodic_RestoreToFullHP"
            end
            st.TempHealGEHandle = h
            st.TempHealTargetHp = targetHp
            st.TempHealExpireAt = os.clock() + 1.15
        end
    end

    -- Tier 3: Direct HealthAttributeSet write + transient GE_Player_HealthRegen pulse
    WriteDirectHealthAttribute(pawn, targetHp)
    if UObjectUtils.IsValid(asc) and UObjectUtils.IsValid(assets.HealthRegen) then
        st.TempRegenGEHandle = ApplySimpleGE(asc, assets.HealthRegen)
        if st.TempHealExpireAt <= os.clock() then
            st.TempHealTargetHp = targetHp
            st.TempHealExpireAt = os.clock() + 0.55
        end
    end
    return "DirectAttribute+HealthRegenSync"
end

-- ============================================================================
-- ENEMY AI PERCEPTION & AGGRO REDIRECTION
-- ============================================================================

local function SetDownedAIPerception(pawn, exclude)
    if not UObjectUtils.IsLive(pawn) then return end
    pcall(function()
        local stimCls = StaticFindObject("/Script/AIModule.AIPerceptionStimuliSourceComponent")
        if UObjectUtils.IsValid(stimCls) then
            local comps = pawn:K2_GetComponentsByClass(stimCls)
            UObjectUtils.ForEachObj(comps, function(comp)
                if exclude then
                    pcall(function() comp:UnregisterFromPerceptionSystem() end)
                else
                    pcall(function() comp:RegisterWithPerceptionSystem() end)
                end
            end)
        end
    end)
end

local function DeaggroEnemiesFromDowned(downedPawn, rescuerPawn)
    local revCfg = Config.Revive or {}
    SetDownedAIPerception(downedPawn, true)
    if revCfg.RedirectEnemyAggro == false then return end
    if not (UObjectUtils.IsLive(downedPawn) and UObjectUtils.IsLive(rescuerPawn)) then return end

    pcall(function()
        local pagAI = FindAllOf("PagodaAIComponent")
        if pagAI then
            for _, comp in pairs(pagAI) do
                if UObjectUtils.IsValid(comp) then
                    local at = nil
                    pcall(function() at = comp.AggroTarget end)
                    if UObjectUtils.IsLive(at) and UObjectUtils.Same(at, downedPawn) then
                        pcall(function() comp.AggroTarget = rescuerPawn end)
                    end
                    local pt = nil
                    pcall(function() pt = comp.PendingAttackPlayerTarget end)
                    if UObjectUtils.IsLive(pt) and UObjectUtils.Same(pt, downedPawn) then
                        pcall(function() comp.PendingAttackPlayerTarget = rescuerPawn end)
                    end
                    local cAI = nil
                    pcall(function() cAI = comp.CachedAIController end)
                    if UObjectUtils.IsLive(cAI) then
                        local foc = nil
                        pcall(function() foc = cAI:GetFocusActor() end)
                        if UObjectUtils.IsLive(foc) and UObjectUtils.Same(foc, downedPawn) then
                            pcall(function() cAI:K2_ClearFocus() end)
                            pcall(function() cAI:K2_SetFocus(rescuerPawn) end)
                        end
                    end
                end
            end
        end
    end)

    pcall(function()
        local aiCtrls = FindAllOf("AIController")
        if aiCtrls then
            for _, ai in pairs(aiCtrls) do
                if UObjectUtils.IsLive(ai) then
                    local focus = nil
                    pcall(function() focus = ai:GetFocusActor() end)
                    if UObjectUtils.IsLive(focus) and UObjectUtils.Same(focus, downedPawn) then
                        pcall(function() ai:K2_ClearFocus() end)
                        pcall(function() ai:K2_SetFocus(rescuerPawn) end)
                    end

                    local bb = nil
                    pcall(function() bb = ai.Blackboard end)
                    if UObjectUtils.IsValid(bb) then
                        for _, kStr in ipairs(AI_TARGET_BB_KEYS) do
                            local fn = FName(kStr)
                            local okVal, val = pcall(function() return bb:GetValueAsObject(fn) end)
                            if okVal and UObjectUtils.IsLive(val) and UObjectUtils.Same(val, downedPawn) then
                                pcall(function() bb:SetValueAsObject(fn, rescuerPawn) end)
                            end
                        end
                    end
                end
            end
        end
    end)
end

-- ============================================================================
-- PER-PLAYER PROTECTION & FSM TRANSITIONS
-- ============================================================================

local function ClearTransientHealGEs(st, asc, pawn, capTargetHp)
    if st.TempHealGEHandle ~= nil then
        RemoveGE(asc, st.TempHealGEHandle)
        st.TempHealGEHandle = nil
    end
    if st.TempRegenGEHandle ~= nil then
        RemoveGE(asc, st.TempRegenGEHandle)
        st.TempRegenGEHandle = nil
    end
    if capTargetHp and capTargetHp > 0 and UObjectUtils.IsLive(pawn) then
        local cur = ReviveSystem.GetHealth(pawn)
        local maxHp = ReviveSystem.GetMaxHealth(pawn)
        if cur > math.min(maxHp, capTargetHp + 1.5) then
            WriteDirectHealthAttribute(pawn, math.min(maxHp, capTargetHp))
        end
    end
    st.TempHealTargetHp = 0.0
    st.TempHealExpireAt = 0.0
end

local function ClearPlayerGEs(st, asc, ctrl, pawn)
    if st.DeathImmuneHandle ~= nil then
        RemoveGE(asc, st.DeathImmuneHandle)
        st.DeathImmuneHandle = nil
        st.DeathImmuneAscKey = nil
    end
    for i = 1, #(st.DownedGEHandles or {}) do
        RemoveGE(asc, st.DownedGEHandles[i])
    end
    st.DownedGEHandles = {}
    if st.InvulnGEHandle ~= nil then
        RemoveGE(asc, st.InvulnGEHandle)
        st.InvulnGEHandle = nil
    end
    if st.InvulnBreakOffHandle ~= nil then
        RemoveGE(asc, st.InvulnBreakOffHandle)
        st.InvulnBreakOffHandle = nil
    end
    ClearTransientHealGEs(st, asc, pawn, nil)
    SetLooseTag(asc, ctrl, "Gameplay.Damage.PreventDeath", false)
    SetLooseTag(asc, ctrl, "Gameplay.DamageImmunity", false)
    SetLooseTag(asc, ctrl, "Status.DBNO", false)
end

function ReviveSystem.ProtectPawn(pid, pawn, ctrl)
    local revCfg = Config.Revive or {}
    if revCfg.Enabled == false or not UObjectUtils.IsLive(pawn) then return end
    local st = ReviveSystem.Players[pid]
    if not st or st.State == "Wiped" then return end

    local assets = EnsureAssetsCached()
    local asc = UObjectUtils.GetASC(pawn)
    if not UObjectUtils.IsValid(asc) then return end

    local ascKey = UObjectUtils.GetKey(asc)
    if st.DeathImmuneAscKey ~= ascKey then
        if UObjectUtils.IsValid(assets.DeathImmune) then
            st.DeathImmuneHandle = ApplySimpleGE(asc, assets.DeathImmune)
        end
        st.DeathImmuneAscKey = ascKey
    end
    if not HasGameplayTag(asc, "Gameplay.Damage.PreventDeath") then
        SetLooseTag(asc, ctrl, "Gameplay.Damage.PreventDeath", true)
    end

    local pKey = UObjectUtils.GetKey(pawn)
    if pKey and not GrantedRevivePawns[pKey] and UObjectUtils.IsValid(assets.RevivingAbility) then
        local okGive = pcall(function() asc:K2_GiveAbility(assets.RevivingAbility, 1, -1) end)
        if okGive then GrantedRevivePawns[pKey] = true end
    end
end

local function TriggerTeamWipe(pawns, ctrls)
    Logger.Info("Revive", "Both players downed simultaneously -> triggering Team Wipe / vanilla death!")
    ReviveOverlay.Destroy()

    local assets = EnsureAssetsCached()
    for pid = 0, 1 do
        local st = ReviveSystem.Players[pid]
        st.State = "Wiped"
        st.ReviveProgress = 0.0
        st.OutOfRangeTime = 0.0

        local ctrl = ctrls[pid] or SessionManager.GetController(pid)
        local pawn = pawns[pid] or SessionManager.GetPawn(pid) or st.DownedPawn
        if ctrl then
            InputRouting.SetPlayerInputLock(ctrl, "LocalCoop.Downed", false)
        end
        if UObjectUtils.IsLive(pawn) then
            local asc = UObjectUtils.GetASC(pawn)
            StopAllReviveMontages(st, pawn)
            ClearPlayerGEs(st, asc, ctrl, pawn)
            SetDownedAIPerception(pawn, false)
            pcall(function() if pawn.CharacterMovement then pawn.CharacterMovement:SetMovementMode(1) end end)

            local killed = false
            if UObjectUtils.IsValid(asc) and UObjectUtils.IsValid(assets.Die) then
                if ApplySimpleGE(asc, assets.Die) ~= nil then
                    killed = true
                end
            end
            if not killed and UObjectUtils.IsValid(asc) and UObjectUtils.IsValid(assets.DmgSetByCaller) then
                ApplySetByCallerGE(asc, assets.DmgSetByCaller, "SetByCaller.Damage", 99999.0)
            end
            if ReviveSystem.GetHealth(pawn) > 0.05 then
                WriteDirectHealthAttribute(pawn, 0.0)
            end
        end
    end
end

local function EnterDowned(pid, pawn, ctrl)
    if not (UObjectUtils.IsLive(pawn) and UObjectUtils.IsLive(ctrl)) then return end
    local st = ReviveSystem.Players[pid]
    if st.State == "Downed" or st.State == "BeingRevived" or st.State == "Wiped" then return end

    local assets = EnsureAssetsCached()
    local asc = UObjectUtils.GetASC(pawn)

    st.State = "Downed"
    st.DownedAt = os.clock()
    st.DownedHealth = ReviveSystem.GetHealth(pawn)
    st.ReviveProgress = 0.0
    st.OutOfRangeTime = 0.0
    st.DownedPawn = pawn
    st.DownedGEHandles = {}

    if UObjectUtils.IsValid(asc) then
        ClearTransientHealGEs(st, asc, pawn, nil)
        for _, geKey in ipairs({ "DBNO", "DamageImmune", "MovementDisable", "InvalidTarget", "InvalidAOETgt", "EnemiesBreakOff" }) do
            local geCls = assets[geKey]
            if UObjectUtils.IsValid(geCls) then
                local h = ApplySimpleGE(asc, geCls)
                if h ~= nil then st.DownedGEHandles[#st.DownedGEHandles + 1] = h end
            end
        end
        if not HasGameplayTag(asc, "Status.DBNO") then
            SetLooseTag(asc, ctrl, "Status.DBNO", true)
        end
    end

    InputRouting.SetPlayerInputLock(ctrl, "LocalCoop.Downed", true)
    StartDownedAnimation(st, pawn)
    PlayReviveFX(pawn, true)

    local otherPid = (pid == 0) and 1 or 0
    local rescuerPawn = SessionManager.GetPawn(otherPid)
    if rescuerPawn then
        DeaggroEnemiesFromDowned(pawn, rescuerPawn)
        LastDeaggroAt = os.clock()
    else
        SetDownedAIPerception(pawn, true)
    end

    local revCfg = Config.Revive or {}
    ReviveOverlay.SetState(pid, otherPid, pawn, 0.0, false, 0.0, false, tonumber(revCfg.ReviveRadius) or 210.0)

    local who = (pid == 0) and "Player 1" or "Player 2"
    Logger.Info("Revive", "%s entered Downed state (on ground, waiting for revive).", who)
end

local function CompleteRevive(pid, pawn, ctrl)
    if not (UObjectUtils.IsLive(pawn) and UObjectUtils.IsLive(ctrl)) then return end
    local st = ReviveSystem.Players[pid]
    if st.State ~= "Downed" and st.State ~= "BeingRevived" then return end

    local revCfg = Config.Revive or {}
    local assets = EnsureAssetsCached()
    local asc = UObjectUtils.GetASC(pawn)

    -- 1. Strip DBNO / MovementDisable / InvalidTarget GEs & tags BEFORE healing
    if UObjectUtils.IsValid(asc) then
        for i = 1, #(st.DownedGEHandles or {}) do
            RemoveGE(asc, st.DownedGEHandles[i])
        end
        SetLooseTag(asc, ctrl, "Status.DBNO", false)
        SetLooseTag(asc, ctrl, "Gameplay.DamageImmunity", false)
    end
    st.DownedGEHandles = {}
    st.ReviveProgress = 0.0
    st.OutOfRangeTime = 0.0

    -- 2. Restore AnimationBlueprint from SingleNode & stop any downed montage
    RestorePawnAnimBlueprint(st, pawn)
    if UObjectUtils.IsValid(st.DownedMontage) then
        StopPawnMontage(pawn, st.DownedMontage, 0.10)
    end
    st.DownedMontage = nil
    st.DownedAnimLocked = false

    -- 3. Restore AI perception, inputs & walking state
    SetDownedAIPerception(pawn, false)
    InputRouting.SetPlayerInputLock(ctrl, "LocalCoop.Downed", false)
    pcall(function() if pawn.CharacterMovement then pawn.CharacterMovement:SetMovementMode(1) end end)

    -- 4. Guaranteed 3-tier HP restoration (verified synchronously)
    local maxHp = ReviveSystem.GetMaxHealth(pawn)
    local pct = math.max(0.25, math.min(1.0, tonumber(revCfg.ReviveHealthPercent) or 0.60))
    local targetHp = math.max(4.0, math.ceil(maxHp * pct))
    local healMethod = RestoreHealthGuaranteed(st, pawn, asc, targetHp, maxHp)

    -- 5. Grant post-revive i-frames + brief EnemiesBreakOff + stand-up disco dance
    local invulnDur = tonumber(revCfg.ReviveInvulnerabilityDuration) or 2.5
    st.State = "Invulnerable"
    st.InvulnUntil = os.clock() + invulnDur
    if UObjectUtils.IsValid(asc) then
        if UObjectUtils.IsValid(assets.DamageImmune) then
            st.InvulnGEHandle = ApplySimpleGE(asc, assets.DamageImmune)
        end
        if UObjectUtils.IsValid(assets.EnemiesBreakOff) then
            st.InvulnBreakOffHandle = ApplySimpleGE(asc, assets.EnemiesBreakOff)
        end
    end

    ReviveSystem.ProtectPawn(pid, pawn, ctrl)
    ReviveOverlay.Destroy()
    PlayReviveFX(pawn, false)
    StartReviveStandUpDance(pid, st, pawn)

    if Callbacks.OnPlayerRevived then
        UObjectUtils.SafeCall("Revive.OnPlayerRevived", Callbacks.OnPlayerRevived, pid, pawn)
    end

    local who = (pid == 0) and "Player 1" or "Player 2"
    Logger.Info("Revive", "%s revived cleanly (hp=%.1f/%.1f, method=%s, iFrames=%.1fs).",
        who, ReviveSystem.GetHealth(pawn), maxHp, tostring(healMethod), invulnDur)
end

function ReviveSystem.EvaluatePlayer(pid, pawn, ctrl)
    local revCfg = Config.Revive or {}
    if revCfg.Enabled == false then return end
    if not (SessionManager.IsP2Active() and SessionManager.IsSafeForGameplayHooks()) then return end
    if not (UObjectUtils.IsLive(pawn) and UObjectUtils.IsLive(ctrl)) then return end
    if UObjectUtils.IsInDiveBar(SessionManager.GetP1()) or SessionManager.State.IsInCutscene then return end

    local st = ReviveSystem.Players[pid]
    if not st or st.State ~= "Alive" then return end

    local hp = ReviveSystem.GetHealth(pawn)
    local maxHp = ReviveSystem.GetMaxHealth(pawn)
    st.Health = hp
    st.MaxHealth = maxHp

    local thresh = (maxHp > 2.5) and 1.05 or 0.05
    local asc = UObjectUtils.GetASC(pawn)
    local hasDBNO = HasGameplayTag(asc, "Status.DBNO")
    if hp > thresh and not hasDBNO then return end

    local otherPid = (pid == 0) and 1 or 0
    local other = ReviveSystem.Players[otherPid]
    if other.State == "Wiped" then return end

    if other.State == "Downed" or other.State == "BeingRevived" then
        TriggerTeamWipe(
            { [0] = SessionManager.GetP1Pawn(), [1] = SessionManager.GetP2Pawn() },
            { [0] = SessionManager.GetP1(),     [1] = SessionManager.GetP2() }
        )
    else
        EnterDowned(pid, pawn, ctrl)
    end
end

function ReviveSystem.OnPawnEvent(victimPawn)
    if not SessionManager.IsP2Active() or not SessionManager.IsSafeForGameplayHooks() then return end
    if not UObjectUtils.IsLive(victimPawn) then return end
    local pid = SessionManager.ResolvePlayerIndex(victimPawn)
    if pid == 0 or pid == 1 then
        ReviveSystem.EvaluatePlayer(pid, victimPawn, SessionManager.GetController(pid))
    end
end

function ReviveSystem.Reset()
    AssetsCheckedThisWorld = false
    ReviveOverlay.Destroy()
    for pid = 0, 1 do
        local st = ReviveSystem.Players[pid]
        local ctrl = SessionManager.GetController(pid)
        local pawn = SessionManager.GetPawn(pid) or st.DownedPawn
        if ctrl then
            InputRouting.SetPlayerInputLock(ctrl, "LocalCoop.Downed", false)
        end
        if UObjectUtils.IsLive(pawn) then
            local asc = UObjectUtils.GetASC(pawn)
            StopAllReviveMontages(st, pawn)
            ClearPlayerGEs(st, asc, ctrl, pawn)
            SetDownedAIPerception(pawn, false)
            pcall(function() if pawn.CharacterMovement then pawn.CharacterMovement:SetMovementMode(1) end end)
        end
        ReviveSystem.Players[pid] = CreatePlayerState()
    end
    GrantedRevivePawns = {}
end

local function IsRescuerHoldingRevive(rescuerPid, rescuerCtrl)
    if not UObjectUtils.IsLive(rescuerCtrl) then return false end
    local revCfg = Config.Revive or {}
    for _, kn in ipairs(revCfg.ReviveHoldGamepadKeys or { "Gamepad_FaceButton_Left", "Gamepad_FaceButton_Bottom" }) do
        local ok, down = pcall(function() return rescuerCtrl:IsInputKeyDown(GetKeyStruct(kn)) end)
        if ok and down == true then return true end
    end
    if rescuerPid == 0 then
        for _, kn in ipairs(revCfg.ReviveHoldKeyboardKeys or { "E", "F" }) do
            local ok, down = pcall(function() return rescuerCtrl:IsInputKeyDown(GetKeyStruct(kn)) end)
            if ok and down == true then return true end
        end
    end
    return false
end

function ReviveSystem.Tick(now)
    now = now or os.clock()
    local dt = (LastTickTime > 0.0) and math.min(0.20, math.max(0.01, now - LastTickTime)) or 0.05
    LastTickTime = now

    if not SessionManager.IsSafeForGameplayHooks() then return end
    if InputRouting.IsGamePaused() then return end

    local p1, p2 = SessionManager.GetP1(), SessionManager.GetP2()
    local p1Pawn, p2Pawn = SessionManager.GetP1Pawn(), SessionManager.GetP2Pawn()
    local revCfg = Config.Revive or {}

    if SessionManager.IsLevelEndActive() then
        ReviveOverlay.Hide()
        return
    end

    if not (p1 and p2 and p1Pawn and p2Pawn)
        or revCfg.Enabled == false
        or UObjectUtils.IsInDiveBar(p1)
        or SessionManager.State.IsInCutscene then
        if ReviveSystem.Players[0].State ~= "Alive" or ReviveSystem.Players[1].State ~= "Alive" then
            ReviveSystem.Reset()
        end
        return
    end

    if ReviveSystem.Players[0].State == "Wiped" or ReviveSystem.Players[1].State == "Wiped" then
        return
    end

    local pawns = { [0] = p1Pawn, [1] = p2Pawn }
    local ctrls = { [0] = p1, [1] = p2 }

    -- 1. Maintain per-player protection, dance input-cancel, transient heal GEs & anti-re-down guard
    for pid = 0, 1 do
        local st = ReviveSystem.Players[pid]
        local pawn, ctrl = pawns[pid], ctrls[pid]
        ReviveSystem.ProtectPawn(pid, pawn, ctrl)
        TickReviveDanceCancel(pid, st, pawn, ctrl, now)

        local asc = UObjectUtils.GetASC(pawn)
        if st.TempHealGEHandle ~= nil or st.TempRegenGEHandle ~= nil then
            local cur = ReviveSystem.GetHealth(pawn)
            if (st.TempHealTargetHp > 0 and cur >= st.TempHealTargetHp - 0.5) or (now >= st.TempHealExpireAt) then
                ClearTransientHealGEs(st, asc, pawn, st.TempHealTargetHp)
            end
        end

        if st.State == "Invulnerable" and now >= st.InvulnUntil then
            ClearTransientHealGEs(st, asc, pawn, st.TempHealTargetHp)
            if st.InvulnBreakOffHandle ~= nil then
                RemoveGE(asc, st.InvulnBreakOffHandle)
                st.InvulnBreakOffHandle = nil
            end

            local cur = ReviveSystem.GetHealth(pawn)
            local maxHp = ReviveSystem.GetMaxHealth(pawn)
            if cur <= ((maxHp > 2.5) and 2.0 or 0.25) then
                local pct = math.max(0.25, math.min(1.0, tonumber(revCfg.ReviveHealthPercent) or 0.60))
                local safeHp = math.max(4.0, math.ceil(maxHp * pct))
                WriteDirectHealthAttribute(pawn, safeHp)
                Logger.Warn("Revive", "Player %d HP was critically low (%.1f) at i-frame end -> restored to %.1f.", pid + 1, cur, safeHp)
            end

            st.State = "Alive"
            st.InvulnUntil = 0.0
            if st.InvulnGEHandle ~= nil then
                RemoveGE(asc, st.InvulnGEHandle)
                st.InvulnGEHandle = nil
            end
            SetLooseTag(asc, ctrl, "Gameplay.DamageImmunity", false)
        end

        if st.State == "Alive" then
            ReviveSystem.EvaluatePlayer(pid, pawn, ctrl)
            if ReviveSystem.Players[0].State == "Wiped" then return end
        end
    end

    -- 2. Drive Downed floor pose & Dynamic Revive Circle interaction
    local downedPid = nil
    for pid = 0, 1 do
        local s = ReviveSystem.Players[pid].State
        if s == "Downed" or s == "BeingRevived" then
            downedPid = pid
            break
        end
    end

    if downedPid == nil then
        ReviveOverlay.Hide()
        return
    end

    local st = ReviveSystem.Players[downedPid]
    local rPid = (downedPid == 0) and 1 or 0
    local dPawn, dCtrl = pawns[downedPid], ctrls[downedPid]
    local rPawn, rCtrl = pawns[rPid], ctrls[rPid]
    local dAsc = UObjectUtils.GetASC(dPawn)

    local elapsed = now - (st.DownedAt or 0.0)
    local curHp = ReviveSystem.GetHealth(dPawn)
    if elapsed >= 0.50 and ((not HasGameplayTag(dAsc, "Status.DBNO")) or curHp > math.max(3.5, (st.DownedHealth or 1.0) + 2.5)) then
        CompleteRevive(downedPid, dPawn, dCtrl)
        return
    end

    if not InputRouting.HasAnyInputLock(downedPid) then
        InputRouting.SetPlayerInputLock(dCtrl, "LocalCoop.Downed", true)
    end
    MaintainDownedAnimation(st, dPawn, now)

    if (now - LastDeaggroAt) >= 0.85 then
        DeaggroEnemiesFromDowned(dPawn, rPawn)
        LastDeaggroAt = now
    end

    local radius = tonumber(revCfg.ReviveRadius) or 210.0
    local d2 = UObjectUtils.GetDistanceSq(dPawn, rPawn)
    local inRange = (d2 <= radius * radius)
    local distMeters = (d2 < math.huge) and (math.sqrt(d2) / 100.0) or 0.0
    local holding = inRange and IsRescuerHoldingRevive(rPid, rCtrl)

    local holdDur = math.max(0.25, tonumber(revCfg.ReviveHoldDuration or revCfg.ReviveDuration) or 0.85)
    local proxDur = tonumber(revCfg.ReviveProximityDuration) or 1.65
    local grace = tonumber(revCfg.ReviveGracePeriod) or 2.5
    local decay = tonumber(revCfg.ReviveDecayRate) or 0.12

    if inRange then
        st.OutOfRangeTime = 0.0
        if holding then
            st.State = "BeingRevived"
            st.ReviveProgress = math.min(1.0, (st.ReviveProgress or 0.0) + (dt / holdDur))
        elseif proxDur > 0.05 then
            st.State = "BeingRevived"
            st.ReviveProgress = math.min(1.0, (st.ReviveProgress or 0.0) + (dt / proxDur))
        else
            st.State = "Downed"
        end

        if st.ReviveProgress >= 1.0 then
            CompleteRevive(downedPid, dPawn, dCtrl)
            return
        end
    else
        st.State = "Downed"
        st.OutOfRangeTime = (st.OutOfRangeTime or 0.0) + dt
        if st.OutOfRangeTime >= grace then
            st.ReviveProgress = math.max(0.0, (st.ReviveProgress or 0.0) - (decay * dt))
        end
    end

    ReviveOverlay.SetState(downedPid, rPid, dPawn, st.ReviveProgress, inRange, distMeters, holding, radius)
end

return ReviveSystem
