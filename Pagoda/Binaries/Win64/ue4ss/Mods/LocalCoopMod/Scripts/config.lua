-- Dead as Disco - Local Co-op Mod (v1.0 Experimental) configuration

local Config = {
    Logging = {
        DebugLogging = false,
        MaxRecentLogs = 100,
    },

    Session = {
        AutoLeashEnabled = true,
        MaxLeashDistance = 2500.0,
        MaxLeashZDiff = 600.0,
    },

    Viewport = {
        -- 0 = Horizontal Split-Screen, 1 = Vertical Split-Screen, 2 = Shared Arena Camera
        ScreenMode = 0,
        AutoFullscreenOnCutscene = true,
        CutsceneViewportMode = 2,
        ShowCutsceneSwitchNotification = false,
        UniversalPauseFullscreen = true,
        UseScaleToFitInSplitScreen = true,
        CustomFOVEnabled = false,
        CustomFOV = 100.0,
        EnableDynamicSharedCamera = true,
        SharedCameraBaseArm = 680.0,
        SharedCameraMaxArm = 1240.0,
    },

    HUD = {
        EnableNativeP2HUD = true,
        HorizontalSplitScale = 1.0,
        VerticalSplitScale = 0.92,
        SplitScreenMenuScale = 0.95,
        SharedScreenScale = 0.78,       -- 0.60 .. 1.10 (adjustable in P2 Menu -> Settings)
        SharedScreenAnchorX = 0.020,
        SharedScreenAnchorY = 0.960,
        ShowDiveBarJoinPrompt = true,
        JoinPromptAnchorX = 0.022,
        JoinPromptAnchorY = 0.952,
        ShowPlayerBadges = true,
        ShowP1Badge = true,
        ShowP2Badge = true,
        HideSharedHUDInMenus = true,
        ShowSharedPlayerCircles = true,
        SharedCircleSize = 118.0,
        P1CircleColor = { R = 0.00, G = 0.94, B = 1.00, A = 0.92 },
        P2CircleColor = { R = 1.00, G = 0.14, B = 0.62, A = 0.92 },
        HideP2DiveBarCredits = true,
        SharedViewportZOrder = 50,
    },

    Input = {
        -- true  = 1 KB/Mouse (P1) + 1 Controller (P2)
        -- false = 2 Controllers (Pad 1 = P1, Pad 2 = P2)
        OffsetGamepad = true,
        AutoOffsetGamepadOnKeyboard = true,
        EnableGamepadShortcuts = true,
        GamepadJoinChord = { "Gamepad_LeftThumbstick", "Gamepad_RightThumbstick" },
        GamepadJoinHoldSeconds = 0.12,
        EnablePauseMenuP2Gamepad = true,
        GamepadMenuToggleKey = "Gamepad_Special_Left",
        GamepadChordCooldown = 0.65,
        RoutePauseMenuToPrimaryViewport = true,
        InterceptDiveBarStationsForP2 = true,
    },

    Revive = {
        Enabled = true,
        ReviveHoldDuration = 0.85,
        ReviveProximityDuration = 1.65,     -- Set 0 for hold-only revives
        ReviveRadius = 260.0,
        ReviveCircleVisualScale = 0.92,
        ReviveCircleOpacity = 0.72,
        ReviveGracePeriod = 2.5,
        ReviveDecayRate = 0.12,
        ReviveHealthPercent = 0.60,
        ReviveInvulnerabilityDuration = 2.5,
        ReviveHoldGamepadKeys = { "Gamepad_FaceButton_Left", "Gamepad_FaceButton_Bottom" },
        ReviveHoldKeyboardKeys = { "E", "F" },
        ShowReviveUI = true,
        ShowWorldReviveCircle = true,
        ShowProjectedReviveRing = true,
        PlayReviveStandUpDance = true,
        EnableReviveAudioFX = true,
        RedirectEnemyAggro = true,
    },

    P2Menu = {
        Enabled = true,
        RestrictToDiveBar = false,
        AllowKeyboardNavigation = false,    -- Keep false so P2 Menu ignores P1 keyboard input
        EnableMenuAudio = true,
        ShowMouseCursor = false,
        OpenTransitionDuration = 0.14,
    },

    Notifications = {
        Enabled = true,
        SuppressDuringCombat = true,
        Duration = 2.6,
    },

    Experimental = {
        Enabled = false,
    },

    Characters = {
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
                BossAbilities = { "VermillionDance", "Singularity", "ChainLightning", "BlockAndRetaliate" },
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
                BossAbilities = { "ChainLightning", "LightningStrike", "DropTheBaxe", "VermillionDance" },
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
                BossAbilities = { "DropTheBaxe", "BlockAndRetaliate", "ChainLightning", "Singularity" },
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
                BossAbilities = { "BlockAndRetaliate", "Singularity", "DropTheBaxe", "VermillionDance" },
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
