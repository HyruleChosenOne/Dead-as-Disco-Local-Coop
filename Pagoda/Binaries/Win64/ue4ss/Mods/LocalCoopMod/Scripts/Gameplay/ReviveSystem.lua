-- Per-player revive state machine: Alive, Downed, BeingRevived, Invulnerable, Wiped.
-- Intercepts lethal damage via GE_DeathImmune, plays a grounded death animation while
-- waiting for revive, restores HP on recovery with brief i-frames, and triggers a
-- standard team wipe if both players go down simultaneously.

local UEHelpers = require("UEHelpers")
local UObjectUtils = require("Utils.UObjectUtils")
local Logger = require("Utils.Logger")
local Scheduler = require("Core.Scheduler")
local SessionManager = require("Core.SessionManager")
local InputRouting = require("Input.InputRouting")
local ReviveOverlay = require("UI.ReviveOverlay")
local EnemyAIDirector = require("Gameplay.EnemyAIDirector")
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
    DeathBackM = "/Game/Pagoda/Characters/Enemies/Grunt/Animations/AM_AI_Grunt_Death_Back_CC.AM_AI_Grunt_Death_Back_CC",
    DeathGutM  = "/Game/Pagoda/Characters/Enemies/Grunt/Animations/AM_AI_Grunt_Death_Gut_CD.AM_AI_Grunt_Death_Gut_CD",
}

-- Cooked SKEL_Humanoid fall-to-ground death AnimSequences played via
-- PlaySlotAnimationAsDynamicMontage on the player's montage slot so both
-- vanilla Charlie and retargeted CSMs lie flat until revived.
local DEATH_ANIM_SEQUENCE_PATHS = {
    "/Game/Pagoda/Characters/Enemies/Grunt/Animations/A_AI_Grunt_Death_Back_CC.A_AI_Grunt_Death_Back_CC",
    "/Game/Pagoda/Characters/Enemies/Grunt/Animations/A_AI_Grunt_Death_Gut_CD.A_AI_Grunt_Death_Gut_CD",
    "/Game/Pagoda/Characters/Enemies/Grunt/Animations/A_AI_Grunt_Death_Gut_CC.A_AI_Grunt_Death_Gut_CC",
    "/Game/Pagoda/Characters/Player/Animations/Hit_Reactions/A_Player_KnockBwd_Land_Bwd.A_Player_KnockBwd_Land_Bwd",
}

local CachedPlayerSlotName = nil
local DeathAnimCycleIndex = 0

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
local LastAlivePollAt = 0.0
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
        DownedAvoidTags = {},
        InvulnGEHandle = nil,
        InvulnBreakOffHandle = nil,
        TempHealGEHandle = nil,
        TempRegenGEHandle = nil,
        TempHealTargetHp = 0.0,
        TempHealExpireAt = 0.0,
        DownedPawn = nil,
        DownedMontage = nil,
        DownedSeqAsset = nil,
        DownedHoldPos = 0.60,
        DownedAnimLocked = false,
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
    if cached == false then return nil end
    if cached ~= nil and UObjectUtils.IsValid(cached) then
        return cached
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

local function ResolvePlayerMontageSlotName()
    if CachedPlayerSlotName ~= nil then return CachedPlayerSlotName end
    local slotName = FName("DefaultSlot")
    pcall(function()
        local refMontage = LoadMontage(ANIM_MONTAGE_PATHS.Knockdown) or LoadMontage(ANIM_MONTAGE_PATHS.QuickGetUp)
        if UObjectUtils.IsValid(refMontage) and refMontage.SlotAnimTracks then
            local track = refMontage.SlotAnimTracks[1]
            if track and track.SlotName then
                local s = track.SlotName:ToString()
                if type(s) == "string" and s ~= "" and s ~= "None" then
                    slotName = track.SlotName
                end
            end
        end
    end)
    CachedPlayerSlotName = slotName
    return slotName
end

local function GetAnimLengthSafe(animObj)
    if not UObjectUtils.IsValid(animObj) then return 0.0 end
    local len = 0.0
    pcall(function()
        if type(animObj.GetPlayLength) == "function" then
            len = tonumber(animObj:GetPlayLength()) or 0.0
        end
    end)
    if len <= 0.05 then
        pcall(function() len = tonumber(animObj.SequenceLength) or 0.0 end)
    end
    return len
end

local function PlayDeathDynamicMontage(animInst, seq, startPos, blendIn)
    if not (UObjectUtils.IsValid(animInst) and UObjectUtils.IsValid(seq)) then return nil, 0.0 end
    local slotName = ResolvePlayerMontageSlotName()
    local len = GetAnimLengthSafe(seq)
    local dyn = nil
    pcall(function()
        -- LoopCount=999 with BlendOutTime=0.02 prevents early blend-out back to standing idle
        -- before MaintainDownedAnimation freezes it cleanly at the final lying-flat frame.
        dyn = animInst:PlaySlotAnimationAsDynamicMontage(
            seq, slotName, blendIn or 0.12, 0.02, 1.0, 999, -1.0, startPos or 0.0
        )
    end)
    if UObjectUtils.IsValid(dyn) then
        local dLen = GetAnimLengthSafe(dyn)
        if dLen > 0.10 then len = dLen end
        return dyn, len
    end
    return nil, 0.0
end

local function StartDownedAnimation(st, pawn)
    if not UObjectUtils.IsLive(pawn) then return end
    pcall(function()
        if pawn.CharacterMovement then
            pawn.CharacterMovement:StopMovementImmediately()
        end
    end)

    local animInst = GetPawnAnimInstance(pawn)
    StopPawnMontage(pawn, nil, 0.06)
    st.DownedMontage = nil
    st.DownedSeqAsset = nil
    st.DownedAnimLocked = false

    -- Play a cooked SKEL_Humanoid death sequence as a dynamic montage on the player's slot.
    if UObjectUtils.IsValid(animInst) then
        local total = #DEATH_ANIM_SEQUENCE_PATHS
        for attempt = 1, total do
            DeathAnimCycleIndex = (DeathAnimCycleIndex % total) + 1
            local seqPath = DEATH_ANIM_SEQUENCE_PATHS[DeathAnimCycleIndex]
            local seq = LoadMontage(seqPath)
            if UObjectUtils.IsValid(seq) then
                local dyn, len = PlayDeathDynamicMontage(animInst, seq, 0.0, 0.12)
                if UObjectUtils.IsValid(dyn) and len > 0.25 then
                    st.DownedSeqAsset = seq
                    st.DownedMontage = dyn
                    st.DownedHoldPos = math.max(0.15, len - 0.14)
                    st.DownedAnimLocked = false
                    return
                end
            end
        end
    end

    -- 2. Fallback: play pre-authored death/knockdown AnimMontage directly
    for _, key in ipairs({ "DeathBackM", "DeathGutM", "Knockdown" }) do
        local m = LoadMontage(ANIM_MONTAGE_PATHS[key])
        if UObjectUtils.IsValid(m) and PlayMontageClean(pawn, m, 1.0, 0.0) then
            local len = GetAnimLengthSafe(m)
            st.DownedMontage = m
            st.DownedHoldPos = (len > 0.25) and math.max(0.15, len - 0.14) or 0.55
            st.DownedAnimLocked = false
            return
        end
    end
end

local function MaintainDownedAnimation(st, pawn, now)
    if not UObjectUtils.IsLive(pawn) then return end
    pcall(function()
        if pawn.CharacterMovement then
            pawn.CharacterMovement:StopMovementImmediately()
        end
    end)

    local animInst = GetPawnAnimInstance(pawn)
    if not UObjectUtils.IsValid(animInst) then return end

    local holdPos = tonumber(st.DownedHoldPos) or 0.55
    local elapsed = now - (st.DownedAt or now)

    local isPlaying = false
    local curPos = 0.0
    if UObjectUtils.IsValid(st.DownedMontage) then
        pcall(function() isPlaying = (animInst:Montage_IsPlaying(st.DownedMontage) == true) end)
        if isPlaying then
            pcall(function() curPos = tonumber(animInst:Montage_GetPosition(st.DownedMontage)) or 0.0 end)
        end
    end

    -- Phase 1: Let the character finish falling naturally to the floor
    if not st.DownedAnimLocked then
        if isPlaying and curPos < holdPos and elapsed < (holdPos + 0.35) then
            return
        end
        -- Character has reached the flat-on-the-ground pose -> freeze cleanly on the floor
        st.DownedAnimLocked = true
    end

    -- Phase 2: Hold the flat lying-on-ground pose steadily until revived
    if isPlaying and UObjectUtils.IsValid(st.DownedMontage) then
        pcall(function()
            if math.abs(curPos - holdPos) > 0.03 then
                animInst:Montage_SetPosition(st.DownedMontage, holdPos)
            end
            animInst:Montage_SetPlayRate(st.DownedMontage, 0.0)
            animInst:Montage_Pause(st.DownedMontage)
        end)
        return
    end

    -- Re-anchor directly at the lying-flat end frame if anything cleared the montage
    if UObjectUtils.IsValid(st.DownedSeqAsset) then
        local dyn = PlayDeathDynamicMontage(animInst, st.DownedSeqAsset, holdPos, 0.04)
        if UObjectUtils.IsValid(dyn) then
            st.DownedMontage = dyn
            pcall(function()
                animInst:Montage_SetPosition(dyn, holdPos)
                animInst:Montage_SetPlayRate(dyn, 0.0)
                animInst:Montage_Pause(dyn)
            end)
            return
        end
    end

    local fallbackM = UObjectUtils.IsValid(st.DownedMontage) and st.DownedMontage
        or LoadMontage(ANIM_MONTAGE_PATHS.DeathBackM)
        or LoadMontage(ANIM_MONTAGE_PATHS.Knockdown)
    if UObjectUtils.IsValid(fallbackM) then
        st.DownedMontage = fallbackM
        if PlayMontageClean(pawn, fallbackM, 1.0, holdPos) then
            pcall(function()
                animInst:Montage_SetPosition(fallbackM, holdPos)
                animInst:Montage_SetPlayRate(fallbackM, 0.0)
                animInst:Montage_Pause(fallbackM)
            end)
        end
    end
end

local function StopAllReviveMontages(st, pawn)
    if UObjectUtils.IsLive(pawn) then
        if UObjectUtils.IsValid(st.DownedMontage) then
            StopPawnMontage(pawn, st.DownedMontage, 0.14)
        end
        if UObjectUtils.IsValid(st.ReviveDanceMontage) then
            StopPawnMontage(pawn, st.ReviveDanceMontage, 0.18)
        end
    end
    st.DownedMontage = nil
    st.DownedSeqAsset = nil
    st.DownedAnimLocked = false
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
            if not SessionManager.IsP2Active() or SessionManager.State.IsInCutscene then return end
            if UObjectUtils.IsInDiveBar(SessionManager.GetP1()) then return end
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
-- ENEMY AI PERCEPTION & AGGRO REDIRECTION (DELEGATED TO EnemyAIDirector)
-- ============================================================================

local function SetDownedAIPerception(pawn, exclude)
    EnemyAIDirector.SetPawnAIPerception(pawn, not exclude)
end

local function DeaggroEnemiesFromDowned(downedPawn, rescuerPawn)
    EnemyAIDirector.RedirectAllEnemiesOffDowned(downedPawn, rescuerPawn)
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
    for i = 1, #(st.DownedAvoidTags or {}) do
        SetLooseTag(asc, ctrl, st.DownedAvoidTags[i], false)
    end
    st.DownedAvoidTags = {}
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
    local hasPrevent = HasGameplayTag(asc, "Gameplay.Damage.PreventDeath")
    if st.DeathImmuneAscKey ~= ascKey or not hasPrevent then
        if UObjectUtils.IsValid(assets.DeathImmune) then
            st.DeathImmuneHandle = ApplySimpleGE(asc, assets.DeathImmune)
        end
        st.DeathImmuneAscKey = ascKey
        if not HasGameplayTag(asc, "Gameplay.Damage.PreventDeath") then
            SetLooseTag(asc, ctrl, "Gameplay.Damage.PreventDeath", true)
        end
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
    st.DownedAvoidTags = {}

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
        -- Apply PagodaAIAggroSubsystem's DefaultAvoidAttacksOnTarget tags so C++ aggro ignores downed player
        local avoidTags = EnemyAIDirector.GetAvoidAttackTagStrings()
        for _, tagStr in ipairs(avoidTags or {}) do
            if not HasGameplayTag(asc, tagStr) then
                SetLooseTag(asc, ctrl, tagStr, true)
                st.DownedAvoidTags[#st.DownedAvoidTags + 1] = tagStr
            end
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
    ReviveOverlay.SetState(pid, otherPid, pawn, 0.0, false, 0.0, false, tonumber(revCfg.ReviveRadius) or 260.0)

    local who = (pid == 0) and "Player 1" or "Player 2"
    Logger.Info("Revive", "%s entered Downed state (hp=%.1f/%.1f, rescuer=P%d).",
        who, st.DownedHealth or 0.0, ReviveSystem.GetMaxHealth(pawn), otherPid + 1)
end

local function CompleteRevive(pid, pawn, ctrl)
    if not (UObjectUtils.IsLive(pawn) and UObjectUtils.IsLive(ctrl)) then return end
    local st = ReviveSystem.Players[pid]
    if st.State ~= "Downed" and st.State ~= "BeingRevived" then return end

    local revCfg = Config.Revive or {}
    local assets = EnsureAssetsCached()
    local asc = UObjectUtils.GetASC(pawn)

    -- 1. Strip DBNO / MovementDisable / InvalidTarget / AvoidAttack GEs & tags BEFORE healing
    if UObjectUtils.IsValid(asc) then
        for i = 1, #(st.DownedGEHandles or {}) do
            RemoveGE(asc, st.DownedGEHandles[i])
        end
        for i = 1, #(st.DownedAvoidTags or {}) do
            SetLooseTag(asc, ctrl, st.DownedAvoidTags[i], false)
        end
        SetLooseTag(asc, ctrl, "Status.DBNO", false)
        SetLooseTag(asc, ctrl, "Gameplay.DamageImmunity", false)
    end
    st.DownedGEHandles = {}
    st.DownedAvoidTags = {}
    st.ReviveProgress = 0.0
    st.OutOfRangeTime = 0.0

    -- 2. Stop paused downed death montage smoothly before kipping up
    if UObjectUtils.IsValid(st.DownedMontage) then
        StopPawnMontage(pawn, st.DownedMontage, 0.14)
    end
    st.DownedMontage = nil
    st.DownedSeqAsset = nil
    st.DownedAnimLocked = false

    -- 3. Restore AI perception, inputs & walking state
    SetDownedAIPerception(pawn, false)
    EnemyAIDirector.OnPlayerRevived(pid, pawn)
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
    CachedMontages = {}
    LastTickTime = 0.0
    LastDeaggroAt = 0.0
    LastAlivePollAt = 0.0
    Scheduler.CancelByTag("Revive.StandUpDance.0")
    Scheduler.CancelByTag("Revive.StandUpDance.1")
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
    local rawDt = (LastTickTime > 0.0) and math.max(0.0, now - LastTickTime) or 0.05
    local dt = math.min(0.20, math.max(0.01, rawDt))
    LastTickTime = now

    if not SessionManager.IsSafeForGameplayHooks() then return end
    if InputRouting.IsGamePaused() then
        -- Keep wall-clock deadlines frozen while the game is paused.
        if rawDt > 0.0 then
            for pid = 0, 1 do
                local st = ReviveSystem.Players[pid]
                if st then
                    if st.InvulnUntil and st.InvulnUntil > 0.0 then st.InvulnUntil = st.InvulnUntil + rawDt end
                    if st.TempHealExpireAt and st.TempHealExpireAt > 0.0 then st.TempHealExpireAt = st.TempHealExpireAt + rawDt end
                    if st.ReviveDanceStartAt and st.ReviveDanceStartAt > 0.0 then st.ReviveDanceStartAt = st.ReviveDanceStartAt + rawDt end
                    if st.ReviveDanceEndAt and st.ReviveDanceEndAt > 0.0 then st.ReviveDanceEndAt = st.ReviveDanceEndAt + rawDt end
                    if (st.State == "Downed" or st.State == "BeingRevived") and st.DownedAt and st.DownedAt > 0.0 then
                        st.DownedAt = st.DownedAt + rawDt
                    end
                end
            end
        end
        return
    end

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
    local doAlivePoll = ((now - LastAlivePollAt) >= 0.25)
    if doAlivePoll then
        LastAlivePollAt = now
    end

    for pid = 0, 1 do
        local st = ReviveSystem.Players[pid]
        local pawn, ctrl = pawns[pid], ctrls[pid]
        if doAlivePoll or st.DeathImmuneAscKey == nil then
            ReviveSystem.ProtectPawn(pid, pawn, ctrl)
        end
        TickReviveDanceCancel(pid, st, pawn, ctrl, now)

        if st.TempHealGEHandle ~= nil or st.TempRegenGEHandle ~= nil then
            local asc = UObjectUtils.GetASC(pawn)
            local cur = ReviveSystem.GetHealth(pawn)
            if (st.TempHealTargetHp > 0 and cur >= st.TempHealTargetHp - 0.5) or (now >= st.TempHealExpireAt) then
                ClearTransientHealGEs(st, asc, pawn, st.TempHealTargetHp)
            end
        end

        if st.State == "Invulnerable" and now >= st.InvulnUntil then
            local asc = UObjectUtils.GetASC(pawn)
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
            EnemyAIDirector.OnPlayerRevived(pid, pawn)
        end

        if st.State == "Alive" and doAlivePoll then
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
    local dbnoCleared = UObjectUtils.IsValid(dAsc) and (not HasGameplayTag(dAsc, "Status.DBNO"))
    if elapsed >= 0.50 and (dbnoCleared or curHp > math.max(3.5, (st.DownedHealth or 1.0) + 2.5)) then
        CompleteRevive(downedPid, dPawn, dCtrl)
        return
    end

    if not InputRouting.HasAnyInputLock(downedPid) then
        InputRouting.SetPlayerInputLock(dCtrl, "LocalCoop.Downed", true)
    end
    MaintainDownedAnimation(st, dPawn, now)

    if (now - LastDeaggroAt) >= 0.20 then
        DeaggroEnemiesFromDowned(dPawn, rPawn)
        LastDeaggroAt = now
    end

    local radius = tonumber(revCfg.ReviveRadius) or 260.0
    local d2 = UObjectUtils.GetDistanceSq(dPawn, rPawn)
    -- Also check distance to downed pawn's pelvis bone (falling death animations shift the lying body back from capsule origin)
    pcall(function()
        if UObjectUtils.IsValid(dPawn.Mesh) then
            local pel = dPawn.Mesh:GetSocketLocation(FName("pelvis"))
            local rLoc = rPawn:K2_GetActorLocation()
            if pel and rLoc and (pel.X ~= 0.0 or pel.Y ~= 0.0 or pel.Z ~= 0.0) then
                local dx, dy, dz = pel.X - rLoc.X, pel.Y - rLoc.Y, pel.Z - rLoc.Z
                local p2 = dx * dx + dy * dy + dz * dz
                if p2 < d2 then d2 = p2 end
            end
        end
    end)
    local inRange = (d2 <= radius * radius)
    local distMeters = (d2 < math.huge) and (math.sqrt(d2) / 100.0) or 0.0
    local holding = inRange and IsRescuerHoldingRevive(rPid, rCtrl)

    local holdDur = math.max(0.25, tonumber(revCfg.ReviveHoldDuration or revCfg.ReviveDuration) or 0.85)
    local proxDur = tonumber(revCfg.ReviveProximityDuration) or 1.65
    local grace = tonumber(revCfg.ReviveGracePeriod) or 2.5
    local decay = tonumber(revCfg.ReviveDecayRate) or 0.12

    if inRange then
        st.OutOfRangeTime = 0.0
        local wasWaiting = (st.State == "Downed")
        if holding then
            st.State = "BeingRevived"
            st.ReviveProgress = math.min(1.0, (st.ReviveProgress or 0.0) + (dt / holdDur))
        elseif proxDur > 0.05 then
            st.State = "BeingRevived"
            st.ReviveProgress = math.min(1.0, (st.ReviveProgress or 0.0) + (dt / proxDur))
        else
            st.State = "Downed"
        end
        if wasWaiting and st.State == "BeingRevived" then
            Logger.Info("Revive", "Player %d reviving Player %d (dist=%.1fm, hold=%s).",
                rPid + 1, downedPid + 1, distMeters, tostring(holding))
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
