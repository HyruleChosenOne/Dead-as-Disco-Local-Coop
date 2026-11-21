-- Balances enemy AI targeting across P1 and P2, redirects aggro off downed
-- players, and keeps both pawns registered with UE5 AI perception.

local UObjectUtils = require("Utils.UObjectUtils")
local Logger = require("Utils.Logger")
local SessionManager = require("Core.SessionManager")

local EnemyAIDirector = {}

local Config = {}
local IsDownedFn = nil
local IsInvulnerableFn = nil

local CachedStimuliClass = nil
local CachedAvoidTags = nil
local LastBalanceAt = 0.0
local LastDownedSweepAt = 0.0
local LastEnemyRetargetAt = {} -- [compKey] = timestamp
local PerceptionRegisteredKey = { [0] = nil, [1] = nil }

local AI_TARGET_BB_KEYS = {
    "TargetActor", "Target", "PlayerTarget", "TargetPlayer",
    "CombatTarget", "AttackTarget", "EnemyTarget", "TargetPawn",
    "AggroTarget", "PendingAttackPlayerTarget",
}
local CachedBBFNames = {}

local function GetBBFName(keyStr)
    local fn = CachedBBFNames[keyStr]
    if not fn then
        fn = FName(keyStr)
        CachedBBFNames[keyStr] = fn
    end
    return fn
end

function EnemyAIDirector.Init(config, callbacks)
    Config = config or {}
    if callbacks then
        if type(callbacks.IsPlayerDowned) == "function" then IsDownedFn = callbacks.IsPlayerDowned end
        if type(callbacks.IsPlayerInvulnerable) == "function" then IsInvulnerableFn = callbacks.IsPlayerInvulnerable end
    end
end

function EnemyAIDirector.Reset()
    LastBalanceAt = 0.0
    LastDownedSweepAt = 0.0
    LastEnemyRetargetAt = {}
    PerceptionRegisteredKey = { [0] = nil, [1] = nil }
    CachedAvoidTags = nil
end

-- Reads UPagodaAIAggroSubsystem::DefaultAvoidAttacksOnTarget so ReviveSystem can
-- apply the exact native GameplayTags that make C++ CanAttackPlayer / Aggro ignore a downed pawn.
function EnemyAIDirector.GetAvoidAttackTagStrings()
    if CachedAvoidTags ~= nil then return CachedAvoidTags end
    local list = {}
    local seen = {}
    pcall(function()
        local sub = FindFirstOf("PagodaAIAggroSubsystem")
        if not UObjectUtils.IsValid(sub) then return end
        local cont = sub.DefaultAvoidAttacksOnTarget
        if not cont then return end
        local tags = cont.GameplayTags
        if not tags then return end
        local okFE = pcall(function()
            tags:ForEach(function(_, elem)
                local val = (type(elem) == "userdata" and elem.get) and elem:get() or elem
                local s = UObjectUtils.GetTagString(val)
                if s ~= "" and not seen[s] and not s:find("Death", 1, true) then
                    seen[s] = true
                    list[#list + 1] = s
                end
            end)
        end)
        if not okFE then
            local len = #tags
            for i = 1, len do
                local s = UObjectUtils.GetTagString(tags[i])
                if s ~= "" and not seen[s] and not s:find("Death", 1, true) then
                    seen[s] = true
                    list[#list + 1] = s
                end
            end
        end
    end)
    if #list > 0 then
        CachedAvoidTags = list
        Logger.Info("EnemyAI", "Resolved DefaultAvoidAttacksOnTarget tags: %s", table.concat(list, ", "))
    end
    return list
end

function EnemyAIDirector.SetPawnAIPerception(pawn, enable)
    if not UObjectUtils.IsLive(pawn) then return end
    pcall(function()
        if not UObjectUtils.IsValid(CachedStimuliClass) then
            CachedStimuliClass = StaticFindObject("/Script/AIModule.AIPerceptionStimuliSourceComponent")
        end
        if not UObjectUtils.IsValid(CachedStimuliClass) then return end
        local comps = pawn:K2_GetComponentsByClass(CachedStimuliClass)
        UObjectUtils.ForEachObj(comps, function(comp)
            if enable then
                pcall(function() comp:RegisterWithPerceptionSystem() end)
            else
                pcall(function() comp:UnregisterFromPerceptionSystem() end)
            end
        end)
    end)
end

local function SetAIControllerTarget(aiCtrl, targetPawn, onlyIfMatchingPawn)
    if not (UObjectUtils.IsLive(aiCtrl) and UObjectUtils.IsLive(targetPawn)) then return end
    pcall(function()
        local foc = aiCtrl:GetFocusActor()
        local shouldChangeFocus = (onlyIfMatchingPawn == nil)
            or (not UObjectUtils.IsLive(foc))
            or UObjectUtils.Same(foc, onlyIfMatchingPawn)
        if shouldChangeFocus and not (UObjectUtils.IsLive(foc) and UObjectUtils.Same(foc, targetPawn)) then
            pcall(function() aiCtrl:K2_ClearFocus() end)
            pcall(function() aiCtrl:K2_SetFocus(targetPawn) end)
        end

        local bb = aiCtrl.Blackboard
        if UObjectUtils.IsValid(bb) then
            for _, kStr in ipairs(AI_TARGET_BB_KEYS) do
                local fn = GetBBFName(kStr)
                local okVal, val = pcall(function() return bb:GetValueAsObject(fn) end)
                if okVal and UObjectUtils.IsLive(val) then
                    local matches = (onlyIfMatchingPawn == nil) or UObjectUtils.Same(val, onlyIfMatchingPawn)
                    if matches and not UObjectUtils.Same(val, targetPawn) then
                        pcall(function() bb:SetValueAsObject(fn, targetPawn) end)
                    end
                end
            end
        end
    end)
end

local function RedirectSingleEnemyComponent(comp, targetPawn, downedPawn)
    if not (UObjectUtils.IsValid(comp) and UObjectUtils.IsLive(targetPawn)) then return end
    local forcingOffDowned = UObjectUtils.IsLive(downedPawn)

    pcall(function()
        local at = comp.AggroTarget
        if not (UObjectUtils.IsLive(at) and UObjectUtils.Same(at, targetPawn)) then
            comp.AggroTarget = targetPawn
        end
    end)

    pcall(function()
        local pt = comp.PendingAttackPlayerTarget
        if forcingOffDowned and ((not UObjectUtils.IsLive(pt)) or UObjectUtils.Same(pt, downedPawn)) then
            local wasTargetingDowned = UObjectUtils.IsLive(pt) and UObjectUtils.Same(pt, downedPawn)
            comp.PendingAttackPlayerTarget = targetPawn
            if wasTargetingDowned then
                pcall(function()
                    if comp.bAttackWarmUp == true then
                        comp.bAttackWarmUp = false
                    end
                    if type(comp.NotifyAttackEnded) == "function" then
                        comp:NotifyAttackEnded(true)
                    end
                end)
            end
        end
    end)

    -- Clear any danger warning already posted on the downed pawn's indicator component
    if forcingOffDowned then
        pcall(function()
            local enemyOwner = comp:GetOwner()
            if UObjectUtils.IsLive(enemyOwner) then
                if UObjectUtils.IsValid(downedPawn.DangerIndicatorComponent) then
                    downedPawn.DangerIndicatorComponent:RemoveAsAttackSource(enemyOwner)
                end
                if type(comp.SetSignalAttackTarget) == "function" then
                    pcall(function()
                        local sig = comp.SignalAttackTarget
                        if UObjectUtils.IsLive(sig) and UObjectUtils.Same(sig, downedPawn) then
                            comp:SetSignalAttackTarget(targetPawn)
                        end
                    end)
                end
            end
        end)
    end

    pcall(function()
        local cAI = comp.CachedAIController
        if UObjectUtils.IsLive(cAI) then
            SetAIControllerTarget(cAI, targetPawn, forcingOffDowned and downedPawn or nil)
        else
            local enemyOwner = comp:GetOwner()
            if UObjectUtils.IsLive(enemyOwner) and UObjectUtils.IsLive(enemyOwner.Controller) then
                SetAIControllerTarget(enemyOwner.Controller, targetPawn, forcingOffDowned and downedPawn or nil)
            end
        end
    end)
end

-- Called synchronously right after PagodaAIAggroSubsystem:OnUpdateMoveTargetPlayers
-- so C++ aggro reassignment can never snap enemies back onto a downed player.
function EnemyAIDirector.OnAggroSubsystemUpdated()
    if not SessionManager.IsP2Active() or not SessionManager.IsSafeForGameplayHooks() then return end
    local p1Downed = IsDownedFn and IsDownedFn(0) or false
    local p2Downed = IsDownedFn and IsDownedFn(1) or false
    if p1Downed == p2Downed then return end

    local p1Pawn, p2Pawn = SessionManager.GetP1Pawn(), SessionManager.GetP2Pawn()
    if not (p1Pawn and p2Pawn) then return end

    if p1Downed then
        EnemyAIDirector.RedirectAllEnemiesOffDowned(p1Pawn, p2Pawn)
    else
        EnemyAIDirector.RedirectAllEnemiesOffDowned(p2Pawn, p1Pawn)
    end
end

function EnemyAIDirector.RedirectAllEnemiesOffDowned(downedPawn, rescuerPawn)
    local revCfg = Config.Revive or {}
    EnemyAIDirector.SetPawnAIPerception(downedPawn, false)
    if revCfg.RedirectEnemyAggro == false then return end
    if not (UObjectUtils.IsLive(downedPawn) and UObjectUtils.IsLive(rescuerPawn)) then return end

    pcall(function()
        local pagAI = FindAllOf("PagodaAIComponent")
        if pagAI then
            for _, comp in pairs(pagAI) do
                if UObjectUtils.IsValid(comp) then
                    RedirectSingleEnemyComponent(comp, rescuerPawn, downedPawn)
                end
            end
        end
    end)

    pcall(function()
        local aiCtrls = FindAllOf("AIController")
        if aiCtrls then
            for _, ai in pairs(aiCtrls) do
                if UObjectUtils.IsLive(ai) then
                    SetAIControllerTarget(ai, rescuerPawn, downedPawn)
                end
            end
        end
    end)
end

function EnemyAIDirector.OnPlayerRevived(pid, pawn)
    if not UObjectUtils.IsLive(pawn) then return end
    EnemyAIDirector.SetPawnAIPerception(pawn, true)
    PerceptionRegisteredKey[pid] = UObjectUtils.GetKey(pawn)
    -- Allow immediate enemy re-evaluation once the player is back up
    LastEnemyRetargetAt = {}
    LastBalanceAt = 0.0
    Logger.Debug("EnemyAI", "Player %d revived -> restored to enemy AI target pool.", pid + 1)
end

local function IsEnemyMidAttack(comp)
    local busy = false
    pcall(function()
        if comp.bAttackWarmUp == true or comp.bWaitingForAttackEnd == true then
            busy = true
            return
        end
        if type(comp.IsInAttackWarmup) == "function" and comp:IsInAttackWarmup() == true then
            busy = true
            return
        end
        -- Note: IsWaitingGorAttackEnd matches the actual UFunction name in Pagoda.
        if type(comp.IsWaitingGorAttackEnd) == "function" and comp:IsWaitingGorAttackEnd() == true then
            busy = true
            return
        end
    end)
    return busy
end

local function BalanceEnemiesBetweenPlayers(p1Pawn, p2Pawn, now)
    local pagAI = nil
    pcall(function() pagAI = FindAllOf("PagodaAIComponent") end)
    if not pagAI then return end

    local enemies = {}
    local p1Count, p2Count = 0, 0

    for _, comp in pairs(pagAI) do
        if UObjectUtils.IsValid(comp) then
            local excluded = false
            pcall(function() excluded = (comp.bExcludeFromAggroSystem == true) end)
            local owner = nil
            pcall(function() owner = comp:GetOwner() end)
            if (not excluded) and UObjectUtils.IsLive(owner) then
                local curT = nil
                pcall(function() curT = comp.AggroTarget end)
                local targetIdx = nil
                if UObjectUtils.IsLive(curT) then
                    if UObjectUtils.Same(curT, p1Pawn) then
                        targetIdx = 0
                        p1Count = p1Count + 1
                    elseif UObjectUtils.Same(curT, p2Pawn) then
                        targetIdx = 1
                        p2Count = p2Count + 1
                    end
                end
                enemies[#enemies + 1] = {
                    Comp = comp,
                    Key = UObjectUtils.GetKey(comp),
                    Owner = owner,
                    CurIdx = targetIdx,
                    Busy = IsEnemyMidAttack(comp),
                }
            end
        end
    end

    if #enemies == 0 then return end

    for key, ts in pairs(LastEnemyRetargetAt) do
        if (now - ts) > 30.0 then
            LastEnemyRetargetAt[key] = nil
        end
    end

    -- Score and balance non-busy enemies smoothly between Player 1 and Player 2
    for _, e in ipairs(enemies) do
        if not e.Busy then
            local lastSw = e.Key and LastEnemyRetargetAt[e.Key] or 0.0
            local canSwitch = (e.CurIdx == nil) or ((now - lastSw) >= 2.2)
            if canSwitch then
                local d1Sq = UObjectUtils.GetDistanceSq(e.Owner, p1Pawn)
                local d2Sq = UObjectUtils.GetDistanceSq(e.Owner, p2Pawn)
                local d1 = (d1Sq < math.huge) and math.sqrt(d1Sq) or 99999.0
                local d2 = (d2Sq < math.huge) and math.sqrt(d2Sq) or 99999.0

                local desiredIdx = e.CurIdx
                if desiredIdx == nil then
                    -- Unassigned enemy: pick closer player, breaking close ties by lower enemy count
                    if math.abs(d1 - d2) < 180.0 then
                        desiredIdx = (p2Count <= p1Count) and 1 or 0
                    else
                        desiredIdx = (d2 < d1) and 1 or 0
                    end
                elseif desiredIdx == 0 then
                    -- Switch from P1 -> P2 if clearly closer to P2, or if P1 is overloaded and P2 is reasonably near
                    if d2 < (d1 * 0.78 - 80.0) then
                        desiredIdx = 1
                    elseif (p1Count > p2Count + 1) and d2 < math.max(950.0, d1 * 1.35) then
                        desiredIdx = 1
                    end
                elseif desiredIdx == 1 then
                    -- Switch from P2 -> P1 if clearly closer to P1, or if P2 is overloaded and P1 is reasonably near
                    if d1 < (d2 * 0.78 - 80.0) then
                        desiredIdx = 0
                    elseif (p2Count > p1Count + 1) and d1 < math.max(950.0, d2 * 1.35) then
                        desiredIdx = 0
                    end
                end

                if desiredIdx ~= nil and desiredIdx ~= e.CurIdx then
                    local newTarget = (desiredIdx == 1) and p2Pawn or p1Pawn
                    RedirectSingleEnemyComponent(e.Comp, newTarget, nil)
                    if e.CurIdx == 0 then p1Count = math.max(0, p1Count - 1)
                    elseif e.CurIdx == 1 then p2Count = math.max(0, p2Count - 1) end
                    if desiredIdx == 0 then p1Count = p1Count + 1 else p2Count = p2Count + 1 end
                    if e.Key then LastEnemyRetargetAt[e.Key] = now end
                end
            end
        end
    end
end

local function EnsurePerceptionRegistered(pid, pawn)
    local pKey = UObjectUtils.GetKey(pawn)
    if pKey and PerceptionRegisteredKey[pid] ~= pKey then
        PerceptionRegisteredKey[pid] = pKey
        EnemyAIDirector.SetPawnAIPerception(pawn, true)
    end
end

function EnemyAIDirector.Tick(now)
    now = now or os.clock()
    if not SessionManager.IsP2Active() or not SessionManager.IsSafeForGameplayHooks() then return end
    local p1 = SessionManager.GetP1()
    if not p1 or UObjectUtils.IsInDiveBar(p1) or SessionManager.State.IsInCutscene then return end

    local p1Pawn, p2Pawn = SessionManager.GetP1Pawn(), SessionManager.GetP2Pawn()
    if not (p1Pawn and p2Pawn) then return end

    local p1Downed = IsDownedFn and IsDownedFn(0) or false
    local p2Downed = IsDownedFn and IsDownedFn(1) or false

    if p1Downed and not p2Downed then
        if (now - LastDownedSweepAt) >= 0.18 then
            LastDownedSweepAt = now
            EnemyAIDirector.RedirectAllEnemiesOffDowned(p1Pawn, p2Pawn)
        end
        return
    elseif p2Downed and not p1Downed then
        if (now - LastDownedSweepAt) >= 0.18 then
            LastDownedSweepAt = now
            EnemyAIDirector.RedirectAllEnemiesOffDowned(p2Pawn, p1Pawn)
        end
        return
    elseif p1Downed and p2Downed then
        return
    end

    EnsurePerceptionRegistered(0, p1Pawn)
    EnsurePerceptionRegistered(1, p2Pawn)

    -- Skip rebalancing while either player is in post-revive invulnerability.
    local p1Invuln = IsInvulnerableFn and IsInvulnerableFn(0) or false
    local p2Invuln = IsInvulnerableFn and IsInvulnerableFn(1) or false
    if p1Invuln or p2Invuln then return end

    if (now - LastBalanceAt) >= 0.65 then
        LastBalanceAt = now
        BalanceEnemiesBetweenPlayers(p1Pawn, p2Pawn, now)
    end
end

return EnemyAIDirector
