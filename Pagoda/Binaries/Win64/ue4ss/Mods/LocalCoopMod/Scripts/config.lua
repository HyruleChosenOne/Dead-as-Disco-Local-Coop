-- ============================================================================
-- DEAD AS DISCO - LOCAL CO-OP MOD (v1.0 Experimental) CONFIGURATION
-- ============================================================================
-- Organized configuration for Session, Viewport/Camera, Native Vanilla HUD,
-- Input Routing, Revive State Machine, Player 2 Menu, Notifications,
-- Character/Cosmetic Styling (Vanilla + CSM), and Isolated Loadouts.
-- ============================================================================

local Config = {
    Logging = {
        DebugLogging = false,   -- Verbose trace logging to UE4SS.log
        MaxRecentLogs = 100,    -- Ring buffer size for live diagnostics
    },

    Session = {
        AutoLeashEnabled = true,        -- Automatically pulls P2 near P1 if far away in Arena Camera
        MaxLeashDistance = 2500.0,
        MaxLeashZDiff = 600.0,
    },

    Viewport = {
        -- 0 = Horizontal Split-Screen (Top / Bottom)
        -- 1 = Vertical Split-Screen (Left / Right)
        -- 2 = Arena / Shared Camera (Dynamic midpoint in combat; Dive Bar uses Split-Screen)
        ScreenMode = 0,
        AutoFullscreenOnCutscene = true,
        CutsceneViewportMode = 2,
        ShowCutsceneSwitchNotification = false,
        UniversalPauseFullscreen = true,
        UseScaleToFitInSplitScreen = true,
        CustomFOVEnabled = false,
        CustomFOV = 90.0,
        EnableDynamicSharedCamera = true,
        SharedCameraBaseArm = 680.0,
        SharedCameraMaxArm = 1380.0,
    },

    HUD = {
        EnableNativeP2HUD = true,
        HorizontalSplitScale = 1.0,
        VerticalSplitScale = 0.92,
        SplitScreenMenuScale = 0.95,
        SharedScreenScale = 0.78,       -- Adjustable in P2 Menu Tab 5 (0.60 .. 1.10)
        SharedScreenAnchorX = 0.020,    -- Bottom-Left in Arena / Shared Camera (avoids P1 HUD overlap)
        SharedScreenAnchorY = 0.960,
        ShowDiveBarJoinPrompt = true,   -- Shows dynamic "Connect Player 2 [F6 / L3+R3]" card in Dive Bar
        JoinPromptAnchorX = 0.022,
        JoinPromptAnchorY = 0.952,
        ShowPlayerBadges = true,
        ShowP1Badge = true,             -- Shows clean "PLAYER 1" tag above P1's hearts during combat in Arena mode
        ShowP2Badge = true,             -- Sleek "PLAYER 2" arcade tag above P2's bottom-left HUD cluster
        HideSharedHUDInMenus = true,    -- Hide P2 shared-screen HUD during Song Select / Mode Select / Menus
        ShowSharedPlayerCircles = true, -- Compact Cyan (P1) / Pink (P2) ground circles in Shared/Arena Screen mode
        SharedCircleSize = 118.0,       -- Diameter in Unreal Units for shared-screen player rings
        P1CircleColor = { R = 0.00, G = 0.94, B = 1.00, A = 0.92 }, -- Cyan ring under Player 1
        P2CircleColor = { R = 1.00, G = 0.14, B = 0.62, A = 0.92 }, -- Pink ring under Player 2
        HideP2DiveBarCredits = true,
        SharedViewportZOrder = 50,
    },

    Input = {
        -- true  = 1 Keyboard/Mouse (P1) + 1 Controller (P2)
        -- false = 2 Controllers (Controller 1 = P1, Controller 2 = P2)
        OffsetGamepad = true,
        AutoOffsetGamepadOnKeyboard = true,
        EnableGamepadShortcuts = true,
        GamepadJoinChord = { "Gamepad_LeftThumbstick", "Gamepad_RightThumbstick" },
        GamepadJoinHoldSeconds = 0.12,  -- Requires L3+R3 held together (prevents accidental sprint+lock-on triggers)
        EnablePauseMenuP2Gamepad = true,-- Lets P2's gamepad navigate, confirm, back & resume in Pause Menu
        GamepadMenuToggleKey = "Gamepad_Special_Left", -- Select / View / Share
        GamepadChordCooldown = 0.65,
        RoutePauseMenuToPrimaryViewport = true,
        InterceptDiveBarStationsForP2 = true,
    },

    Revive = {
        Enabled = true,
        ReviveDuration = 0.85,              -- Fast hold duration (seconds) when pressing E/F or X/A
        ReviveHoldDuration = 0.85,
        ReviveProximityDuration = 1.65,     -- Natural proximity assist while fighting near downed teammate (0 = hold only)
        ReviveRadius = 210.0,               -- Compact, well-fitted combat revive radius in UU
        ReviveCircleVisualScale = 0.84,     -- Visual floor ring scale factor
        ReviveCircleOpacity = 0.50,         -- Semi-transparent floor ring opacity
        ReviveGracePeriod = 2.5,            -- Seconds before progress gently decays after leaving radius
        ReviveDecayRate = 0.12,             -- Gentle decay per second after grace period expires
        ReviveHealthPercent = 0.60,         -- Restored % of MaxHealth on recovery (verified post-heal)
        ReviveInvulnerabilityDuration = 2.5,-- Post-revive i-frames (seconds)
        ReviveHoldGamepadKeys = { "Gamepad_FaceButton_Left", "Gamepad_FaceButton_Bottom" },
        ReviveHoldKeyboardKeys = { "E", "F" },
        ShowReviveUI = true,
        ShowWorldReviveCircle = true,   -- Spawns 3D floor boundary ring + expanding inner circle around downed player
        ShowProjectedReviveRing = true, -- Projects native circular radial progress medallion onto downed player
        PlayReviveStandUpDance = true,  -- Downed player kips up into a disco dance upon revive (input-cancellable)
        EnableReviveAudioFX = true,
        RedirectEnemyAggro = true,
    },

    P2Menu = {
        Enabled = true,
        RestrictToDiveBar = false,          -- Set true to lock P2 Menu to Dive Bar hub only
        AllowKeyboardNavigation = false,    -- Keep false so P2 Menu NEVER reacts to P1 keyboard
        EnableMenuAudio = true,
        ShowMouseCursor = false,            -- Keep false so P1 mouse combat is uninterrupted
        OpenTransitionDuration = 0.14,
    },

    Notifications = {
        Enabled = true,
        SuppressDuringCombat = true,    -- Hides non-critical gameplay toasts (like "Player 2 Revived") during stages
        OnlyShowJoinLeave = false,
        Duration = 2.6,
    },

    Experimental = {
        Enabled = false, -- Unlocks character rim tints, playable SKEL_Humanoid boss/enemy models & diagnostics
    },

    Characters = {
        ScanLiveSceneCharacters = false,
        ShowTemplateModCharacters = false,
        EnableTint = true,
        TintMode = "AccentOnly",            -- "AccentOnly" | "FullBody" | "Off"
        TintColor = { R = 0.00, G = 1.00, B = 0.90, A = 1.00 },
        EnableCustomDepth = true,
        StencilValue = 250,
        TintHair = true,
        TintDrumsticks = true,
        TintColorPalettes = {
            { Name = "Neon Cyan",     Color = { R = 0.00, G = 1.00, B = 0.90, A = 1.0 } },
            { Name = "Disco Magenta", Color = { R = 1.00, G = 0.15, B = 0.75, A = 1.0 } },
            { Name = "Electric Gold", Color = { R = 1.00, G = 0.82, B = 0.10, A = 1.0 } },
            { Name = "Crimson Flame", Color = { R = 1.00, G = 0.22, B = 0.18, A = 1.0 } },
            { Name = "Emerald Mint",  Color = { R = 0.15, G = 1.00, B = 0.45, A = 1.0 } },
            { Name = "Royal Violet",  Color = { R = 0.58, G = 0.28, B = 1.00, A = 1.0 } },
        },
    },

    Loadouts = {
        ProtectP1Achievements = true,
        UnlockAllCosmeticsForP2 = true,
        UnlockAllSkillsForP2 = true,
        DefaultOutfitPresetIndex = 2,
        DefaultLoadoutPresetIndex = 2,

        OutfitPresets = {
            { Name = "Classic Charlie",     BodyType = "Default", Jacket = "Default",             Glasses = "Default",             Hair = "Default",               Drumsticks = "Default" },
            { Name = "Rocker Flames",       BodyType = "Default", Jacket = "RockerFlames",        Glasses = "Rocker_Flames",       Hair = "RockerFlames",          Drumsticks = "Rocker_Fire" },
            { Name = "La Pantera (Dahlia)", BodyType = "Slim",    Jacket = "Dancer",              Glasses = "Dancer",              Hair = "Dancer",                Drumsticks = "Dancer" },
            { Name = "Rebel Punk",          BodyType = "Default", Jacket = "Rebel",               Glasses = "Rebel",               Hair = "Rebel",                 Drumsticks = "Rebel" },
            { Name = "Street Prophet",      BodyType = "Default", Jacket = "Prophet",             Glasses = "Prophet",             Hair = "Prophet",               Drumsticks = "Prophet" },
            { Name = "Shredder",            BodyType = "Default", Jacket = "Shred",               Glasses = "Shred",               Hair = "Shred",                 Drumsticks = "Shred" },
            { Name = "Arora Doll",          BodyType = "Slim",    Jacket = "Arora",               Glasses = "Doll",                Hair = "Arora",                 Drumsticks = "Doll" },
            { Name = "DED Tour",            BodyType = "Default", Jacket = "RockerDED",           Glasses = "Rocker_DED",          Hair = "RockerDED",             Drumsticks = "Rocker_DED" },
            { Name = "Beach Vibe",          BodyType = "Default", Jacket = "Beach_SummerHeadset", Glasses = "Summer_HeadsetStyle", Hair = "Summer_Headset",        Drumsticks = "Beach_1" },
            { Name = "Casual Groove",       BodyType = "Default", Jacket = "Casual",              Glasses = "Casual",              Hair = "Casual",                Drumsticks = "Default" },
            { Name = "Disco White",         BodyType = "Default", Jacket = "White",               Glasses = "White",               Hair = "White",                 Drumsticks = "White" },
            { Name = "Midnight Black",      BodyType = "Default", Jacket = "Black",               Glasses = "Black",               Hair = "Black",                 Drumsticks = "Black" },
            { Name = "Pumpkin King",        BodyType = "Default", Jacket = "Rocker",              Glasses = "Rocker",              Hair = "Halloween_PumpkinHead", Drumsticks = "Rocker_Fire" },
            { Name = "Vice Vacation",       BodyType = "Default", Jacket = "Beach_SummerHat",     Glasses = "Summer_HatStyle",     Hair = "Summer_Hat",            Drumsticks = "Beach_2" },
        },

        LoadoutPresets = {
            {
                Name = "La Pantera (Dahlia Burn)",
                MirrorPlayer1Skills = false,
                BossAbilities = { "VermillionDance", "Singularity", "ChainLightning", "FeverRush" },
                Upgrades = {
                    "DanceMove", "Drummerang", "Sprint", "StrongAttack", "Windmill", "FeverRush",
                    "VermillionDance", "PyroetteAoeOnHit", "PyroetteDurationUp", "BurnDurationUp",
                    "VDance_BurningStrikeOnFollowup", "VDance_EmpoweredFollowup",
                    "FlashbackExtraDamage", "PerfectDodgeFeverRegen", "AoeBurnOnStrongDrummerang",
                },
                Dances = { "SalsaFan", "HonestHips", "BadBoyBoogie", "JazzSplit" },
            },
            {
                Name = "Shredder Lightning",
                MirrorPlayer1Skills = false,
                BossAbilities = { "ChainLightning", "LightningStrike", "DropTheBaxe", "FeverRush" },
                Upgrades = {
                    "DanceMove", "Drummerang", "Sprint", "StrongAttack", "Windmill", "FeverRush",
                    "ChainLightning", "ChainLightning_Upgrade01", "LightningStrike", "Drummerang_FollowUp",
                    "PerfectLightning", "Shred_MaxHealthUp_01", "PerfectHitExtraDamageAndFever",
                },
                Dances = { "SeekAndDestroy", "FlipMetal", "Headspin", "DiscoPoint" },
            },
            {
                Name = "Rebel Heavy Baxe",
                MirrorPlayer1Skills = false,
                BossAbilities = { "DropTheBaxe", "BlockAndRetaliate", "ChainLightning", "FeverRush" },
                Upgrades = {
                    "DanceMove", "Drummerang", "Sprint", "StrongAttack", "Windmill", "FeverRush",
                    "DropTheBaxe", "DropTheBaxe_ExtraPerfectDamage", "DropTheBaxe_Upgrade_01",
                    "StrongAttack_HitReactImmune", "Rebel_HealthUp_01", "ExtraTakedownToken_01",
                },
                Dances = { "BadBoyBoogie", "Freeze", "AirChair", "Shrug" },
            },
            {
                Name = "Prophet Counter Tank",
                MirrorPlayer1Skills = false,
                BossAbilities = { "BlockAndRetaliate", "Singularity", "DropTheBaxe", "FeverRush" },
                Upgrades = {
                    "DanceMove", "Drummerang", "Sprint", "StrongAttack", "Windmill", "FeverRush",
                    "BlockAndRetaliate", "Block_ReducedFeverCost", "Block_SuperArmor",
                    "SprintStartArmor", "Prophet_HealthUp", "FeverRush_HitReactImmune",
                },
                Dances = { "Groovy", "Shuffle", "Bump", "Wave" },
            },
            {
                Name = "Arora Cosmic Doll",
                MirrorPlayer1Skills = false,
                BossAbilities = { "Singularity", "VermillionDance", "ChainLightning", "BlockAndRetaliate" },
                Upgrades = {
                    "DanceMove", "Drummerang", "Sprint", "StrongAttack", "Windmill", "FeverRush",
                    "Singularity", "Singularity_ExtraDurationOnPerfect", "Singularity_Upgrade_01",
                    "StrongRangedAttack", "Doll_HealthUp_01", "FasterTakedownTokenProgress_01",
                },
                Dances = { "AbsoluteDisco", "Kiss", "Moonwalk", "Halloween01" },
            },
            {
                Name = "Mirror Player 1 + Groove Pack",
                MirrorPlayer1Skills = true,
                Dances = { "Moonwalk", "Headspin", "AbsoluteDisco", "AirChair" },
            },
        },
    },
}

return Config
