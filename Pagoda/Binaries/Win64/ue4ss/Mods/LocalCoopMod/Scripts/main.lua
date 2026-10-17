local UEHelpers = require("UEHelpers")
local Config = require("config")

print("[Dead as Disco - Local Co-op Mod] Initializing...\n")

local GetGameplayStatics = UEHelpers.GetGameplayStatics
local GetGameMapsSettings = UEHelpers.GetGameMapsSettings
local GetKismetSystemLibrary = UEHelpers.GetKismetSystemLibrary

local PlayerControllerTable = {}
local CurrentScreenMode = Config.ScreenMode or 0
local CurrentOffsetGamepad = Config.OffsetGamepad
local AutoLeashActive = Config.AutoLeashEnabled

-- Helper to safely show on-screen text and log
local function ShowMessage(Message, Color)
    print(string.format("[Local Co-op] %s\n", Message))
    pcall(function()
        local Kismet = GetKismetSystemLibrary()
        local World = UEHelpers.GetWorld()
        if Kismet and Kismet:IsValid() and World and World:IsValid() then
            local TextColor = Color or { R = 0.2, G = 0.9, B = 1.0, A = 1.0 }
            Kismet:PrintString(World, "[Local Co-op] " .. Message, true, false, TextColor, Config.MessageDuration, FName("LocalCoopMsg"))
        end
    end)
end

-- Refresh cached PlayerControllers
local function CachePlayerControllers()
    PlayerControllerTable = {}
    local AllControllers = FindAllOf("PlayerController") or FindAllOf("Controller")
    if AllControllers then
        for _, Controller in pairs(AllControllers) do
            if Controller:IsValid() and Controller.Player and Controller.Player:IsValid() and not Controller:HasAnyInternalFlags(EInternalObjectFlags.PendingKill) then
                local Id = Controller.Player.ControllerId
                if Id ~= nil then
                    PlayerControllerTable[Id + 1] = Controller
                end
            end
        end
    end
end

-- Apply screen mode settings to Unreal Engine
local function ApplyScreenMode(mode)
    pcall(function()
        local MapsSettings = GetGameMapsSettings()
        if not (MapsSettings and MapsSettings:IsValid()) then return end

        if mode == 0 then
            -- Horizontal Split (Top & Bottom)
            MapsSettings.bUseSplitscreen = true
            MapsSettings.TwoPlayerSplitscreenLayout = 0
            ShowMessage("Screen Mode: Split-Screen (Horizontal)", { R = 0.4, G = 1.0, B = 0.4, A = 1.0 })
        elseif mode == 1 then
            -- Vertical Split (Left & Right)
            MapsSettings.bUseSplitscreen = true
            MapsSettings.TwoPlayerSplitscreenLayout = 1
            ShowMessage("Screen Mode: Split-Screen (Vertical)", { R = 0.4, G = 1.0, B = 0.4, A = 1.0 })
        elseif mode == 2 then
            -- Shared Screen (Single Fullscreen Camera)
            MapsSettings.bUseSplitscreen = false
            ShowMessage("Screen Mode: Shared Single-Screen (Arena Camera)", { R = 1.0, G = 0.8, B = 0.2, A = 1.0 })
        end
    end)
end

-- Apply Gamepad offset setting
local function ApplyGamepadOffset(offset)
    pcall(function()
        local MapsSettings = GetGameMapsSettings()
        if MapsSettings and MapsSettings:IsValid() then
            MapsSettings.bOffsetPlayerGamepadIds = offset
            if offset then
                ShowMessage("Gamepad Setup: 1 Keyboard/Mouse (P1) + 1 Controller (P2)", { R = 0.3, G = 0.8, B = 1.0, A = 1.0 })
            else
                ShowMessage("Gamepad Setup: 2 Controllers (P1 = Controller 1, P2 = Controller 2)", { R = 0.3, G = 0.8, B = 1.0, A = 1.0 })
            end
        end
    end)
end

-- Initialize Engine settings on startup
local function InitEngineSettings()
    pcall(function()
        local MapsSettings = GetGameMapsSettings()
        if MapsSettings and MapsSettings:IsValid() then
            MapsSettings.bOffsetPlayerGamepadIds = CurrentOffsetGamepad
            ApplyScreenMode(CurrentScreenMode)
        end
    end)
end

-- Apply visual distinction to Player 2
local function CustomizePlayer2Visuals(P2Pawn)
    if not (Config.EnablePlayer2VisualTint and P2Pawn and P2Pawn:IsValid()) then return end
    pcall(function()
        local Mesh = P2Pawn.Mesh or P2Pawn.SkeletalMeshComponent or P2Pawn:GetComponentByClass(StaticFindObject("/Script/Engine.SkeletalMeshComponent"))
        if Mesh and Mesh:IsValid() then
            -- Enable custom depth highlight/outline if available
            Mesh.bRenderCustomDepth = true
            Mesh.CustomDepthStencilValue = 250

            -- Try setting color parameters on materials (common UE naming conventions)
            local TintColor = Config.Player2TintColor or { R = 0.0, G = 1.0, B = 0.9, A = 1.0 }
            local ColorParams = { "Color", "BaseColor", "BaseColorTint", "Tint", "EmissiveColor", "BodyColor", "SkinColor" }
            for _, ParamName in ipairs(ColorParams) do
                Mesh:SetVectorParameterValueOnMaterials(FName(ParamName), TintColor)
            end
        end
    end)
end

-- Spawn / Add Player 2
local function SpawnPlayer2()
    print("[Local Co-op] SpawnPlayer2 requested...\n")
    CachePlayerControllers()

    if #PlayerControllerTable >= 2 and PlayerControllerTable[2] and PlayerControllerTable[2]:IsValid() then
        -- Player 2 already exists; check if pawn is alive or needs respawn
        local P2Pawn = PlayerControllerTable[2].Pawn
        if P2Pawn and P2Pawn:IsValid() then
            ShowMessage("Player 2 is already active! Teleporting to Player 1...", { R = 1.0, G = 1.0, B = 0.3, A = 1.0 })
            -- Teleport to P1
            ExecuteInGameThread(function()
                local P1Pawn = PlayerControllerTable[1].Pawn
                if P1Pawn and P1Pawn:IsValid() then
                    local TargetLoc = P1Pawn:K2_GetActorLocation()
                    TargetLoc.X = TargetLoc.X + 120.0
                    local TargetRot = P1Pawn:K2_GetActorRotation()
                    local HitResult = {}
                    P2Pawn:K2_SetActorLocationAndRotation(TargetLoc, TargetRot, false, HitResult, false)
                end
            end)
            return
        end
    end

    ExecuteInGameThread(function()
        CachePlayerControllers()
        local P1Controller = PlayerControllerTable[1]
        if not (P1Controller and P1Controller:IsValid()) then
            ShowMessage("Cannot spawn Player 2: Start a level or arena first!", { R = 1.0, G = 0.3, B = 0.3, A = 1.0 })
            return
        end

        local GameplayStatics = GetGameplayStatics()
        if not (GameplayStatics and GameplayStatics:IsValid()) then
            print("[Local Co-op] GameplayStatics not available!\n")
            return
        end

        -- Create local player 2 (ControllerId = 1)
        local NewController = GameplayStatics:CreatePlayer(P1Controller, 1, true)
        if NewController and NewController:IsValid() then
            PlayerControllerTable[2] = NewController
            print(string.format("[Local Co-op] Controller 2 created: %s\n", NewController:GetFullName()))

            -- Verify if the pawn was spawned by the game mode
            local P2Pawn = NewController.Pawn
            if not (P2Pawn and P2Pawn:IsValid()) then
                -- Spawn a pawn matching Player 1's character
                local P1Pawn = P1Controller.Pawn
                if P1Pawn and P1Pawn:IsValid() then
                    local World = UEHelpers.GetWorld()
                    local PawnClass = P1Pawn:GetClass()
                    local SpawnLoc = P1Pawn:K2_GetActorLocation()
                    SpawnLoc.X = SpawnLoc.X + 150.0
                    local SpawnRot = P1Pawn:K2_GetActorRotation()

                    print(string.format("[Local Co-op] Spawning character clone of %s\n", PawnClass:GetFullName()))
                    local SpawnedPawn = World:SpawnActor(PawnClass, SpawnLoc, SpawnRot)
                    if SpawnedPawn and SpawnedPawn:IsValid() then
                        NewController:Possess(SpawnedPawn)
                        P2Pawn = SpawnedPawn
                        print("[Local Co-op] Possessed cloned character successfully!\n")
                    end
                end
            end

            -- Apply cosmetic tint to Player 2
            if P2Pawn and P2Pawn:IsValid() then
                CustomizePlayer2Visuals(P2Pawn)
            end

            ShowMessage("Player 2 Joined! Let's Dance!", { R = 0.2, G = 1.0, B = 0.4, A = 1.0 })
        else
            ShowMessage("Failed to spawn Player 2. Make sure you are inside an active game level.", { R = 1.0, G = 0.3, B = 0.3, A = 1.0 })
        end
    end)
end

-- Remove Player 2
local function RemovePlayer2()
    CachePlayerControllers()
    if #PlayerControllerTable < 2 or not PlayerControllerTable[2] or not PlayerControllerTable[2]:IsValid() then
        ShowMessage("Player 2 is not currently in the game.", { R = 1.0, G = 0.8, B = 0.2, A = 1.0 })
        return
    end

    local ControllerToRemove = PlayerControllerTable[2]
    ExecuteInGameThread(function()
        local GameplayStatics = GetGameplayStatics()
        if GameplayStatics and GameplayStatics:IsValid() and ControllerToRemove:IsValid() then
            GameplayStatics:RemovePlayer(ControllerToRemove, true)
            PlayerControllerTable[2] = nil
            ShowMessage("Player 2 has left the game.", { R = 1.0, G = 0.5, B = 0.2, A = 1.0 })
        end
    end)
end

-- Teleport Player 2 to Player 1
local function TeleportPlayer2()
    CachePlayerControllers()
    if #PlayerControllerTable < 2 or not PlayerControllerTable[2] or not PlayerControllerTable[2]:IsValid() then
        ShowMessage("Player 2 is not currently active.", { R = 1.0, G = 0.8, B = 0.2, A = 1.0 })
        return
    end

    ExecuteInGameThread(function()
        local P1Pawn = PlayerControllerTable[1] and PlayerControllerTable[1].Pawn
        local P2Pawn = PlayerControllerTable[2] and PlayerControllerTable[2].Pawn

        if P1Pawn and P1Pawn:IsValid() and P2Pawn and P2Pawn:IsValid() then
            local TargetLoc = P1Pawn:K2_GetActorLocation()
            TargetLoc.X = TargetLoc.X + 120.0
            local TargetRot = P1Pawn:K2_GetActorRotation()
            local HitResult = {}
            P2Pawn:K2_SetActorLocationAndRotation(TargetLoc, TargetRot, false, HitResult, false)
            ShowMessage("Player 2 teleported to Player 1!", { R = 0.4, G = 0.9, B = 1.0, A = 1.0 })
        end
    end)
end

-- Cycle Screen Modes (Horizontal -> Vertical -> Shared)
local function CycleScreenMode()
    CurrentScreenMode = (CurrentScreenMode + 1) % 3
    ApplyScreenMode(CurrentScreenMode)
end

-- Toggle Gamepad Offset
local function ToggleGamepadOffset()
    CurrentOffsetGamepad = not CurrentOffsetGamepad
    ApplyGamepadOffset(CurrentOffsetGamepad)
end

-- Toggle Auto-Leash
local function ToggleAutoLeash()
    AutoLeashActive = not AutoLeashActive
    if AutoLeashActive then
        ShowMessage("Auto-Leashing: ENABLED (P2 will stay on-screen)", { R = 0.4, G = 1.0, B = 0.4, A = 1.0 })
    else
        ShowMessage("Auto-Leashing: DISABLED", { R = 1.0, G = 0.4, B = 0.4, A = 1.0 })
    end
end

-- Background Leash / Safety Routine for Shared Screen
LoopAsync(1500, function()
    if not AutoLeashActive then return false end
    if CurrentScreenMode ~= 2 then return false end -- Only active in Shared Screen mode

    pcall(function()
        CachePlayerControllers()
        if #PlayerControllerTable >= 2 and PlayerControllerTable[1] and PlayerControllerTable[2] then
            local P1Pawn = PlayerControllerTable[1].Pawn
            local P2Pawn = PlayerControllerTable[2].Pawn

            if P1Pawn and P1Pawn:IsValid() and P2Pawn and P2Pawn:IsValid() then
                local Loc1 = P1Pawn:K2_GetActorLocation()
                local Loc2 = P2Pawn:K2_GetActorLocation()

                local DX = Loc1.X - Loc2.X
                local DY = Loc1.Y - Loc2.Y
                local DZ = Loc1.Z - Loc2.Z
                local DistSquared = DX * DX + DY * DY + DZ * DZ
                local MaxDist = Config.MaxDistance or 2500.0

                -- If Player 2 fell down or wandered too far
                if DistSquared > (MaxDist * MaxDist) or DZ > (Config.MaxZDifference or 600.0) then
                    ExecuteInGameThread(function()
                        if P1Pawn:IsValid() and P2Pawn:IsValid() then
                            local TargetLoc = P1Pawn:K2_GetActorLocation()
                            TargetLoc.X = TargetLoc.X + 100.0
                            local TargetRot = P1Pawn:K2_GetActorRotation()
                            local HitResult = {}
                            P2Pawn:K2_SetActorLocationAndRotation(TargetLoc, TargetRot, false, HitResult, false)
                            print("[Local Co-op] Auto-leashed Player 2 back to arena.\n")
                        end
                    end)
                end
            end
        end
    end)
    return false
end)

-- Register Hook on Map Load to re-initialize settings
RegisterHook("/Script/Engine.PlayerController:ClientRestart", function(self)
    ExecuteInGameThread(function()
        InitEngineSettings()
    end)
end)

-- Initialize engine settings at startup
InitEngineSettings()

-- Keybindings:
RegisterKeyBind(Key.F5, ToggleGamepadOffset)
RegisterKeyBind(Key.F6, SpawnPlayer2)
RegisterKeyBind(Key.F7, RemovePlayer2)
RegisterKeyBind(Key.F8, TeleportPlayer2)
RegisterKeyBind(Key.F9, CycleScreenMode)
RegisterKeyBind(Key.F11, ToggleAutoLeash)

-- Ctrl Shortcuts (Secondary / Alternative)
RegisterKeyBind(Key.Y, { ModifierKey.CONTROL }, SpawnPlayer2)
RegisterKeyBind(Key.U, { ModifierKey.CONTROL }, RemovePlayer2)
RegisterKeyBind(Key.I, { ModifierKey.CONTROL }, TeleportPlayer2)
RegisterKeyBind(Key.P, { ModifierKey.CONTROL }, CycleScreenMode)

print("[Dead as Disco - Local Co-op Mod] Loaded successfully!\n")
print("  [F5]             : Toggle Controller Setup (1 KB + 1 Controller vs 2 Controllers)\n")
print("  [F6] or [Ctrl+Y] : Spawn / Revive Player 2\n")
print("  [F7] or [Ctrl+U] : Remove Player 2\n")
print("  [F8] or [Ctrl+I] : Teleport Player 2 to Player 1\n")
print("  [F9] or [Ctrl+P] : Cycle Screen Mode (Horizontal -> Vertical -> Shared)\n")
print("  [F11]            : Toggle Auto-Leashing on/off\n")

