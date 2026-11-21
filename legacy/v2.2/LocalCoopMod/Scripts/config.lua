local Config = {
    -- =========================================================================
    -- 1. SCREEN & CONTROLLER ROUTING
    -- =========================================================================

    -- Default screen layout when Player 2 is active:
    -- 0 = Horizontal Split-Screen (Top & Bottom)
    -- 1 = Vertical Split-Screen (Left & Right)
    -- 2 = Shared Single Screen (Both players on Player 1's camera)
    ScreenMode = 0,

    -- Controller routing when Player 2 is active:
    -- true  = 1 Keyboard/Mouse (Player 1) + 1 Controller (Player 2)
    -- false = 2 Controllers (Controller 1 = Player 1, Controller 2 = Player 2)
    -- Note: While playing solo (before Player 2 joins), gamepad routing stays normal
    -- so Controller 1 can play solo or press the Gamepad Join Shortcut.
    OffsetGamepad = true,

    -- =========================================================================
    -- 2. GAMEPAD SHORTCUTS & PLAYER 2 INTERACTIVE CUSTOM MENU
    -- =========================================================================

    -- Allows Player 2 to join/connect and open their custom menu from a controller:
    EnableGamepadShortcuts = true,

    -- Press L3 + R3 (Left Stick Click + Right Stick Click) together to Connect / Regroup P2:
    GamepadJoinChord = { "Gamepad_LeftThumbstick", "Gamepad_RightThumbstick" },

    -- Interactive Custom UI Menu for Player 2 (Outfits, Dances, Boss Skills, Upgrades, Character):
    --   - On Player 2's Controller: Press [Select / View] (Gamepad_Special_Left) to open/close
    --   - At Dive Bar Wardrobe / Skill Station: Press Interact on P2's controller to open directly
    --   - On Keyboard: Press [F2] for P2 Costumes Menu or [F3] for P2 Skills Menu
    EnableP2CustomMenu = true,
    GamepadMenuToggleKey = "Gamepad_Special_Left",
    InterceptDiveBarStationsForP2 = true,
    ShowMouseCursorInP2Menu = true,

    -- Optional quick-cycle chords while menu is closed (Hold Select + L3 / R3):
    GamepadOutfitCycleChord = { "Gamepad_Special_Left", "Gamepad_LeftThumbstick" },
    GamepadLoadoutCycleChord = { "Gamepad_Special_Left", "Gamepad_RightThumbstick" },

    -- Minimum seconds between gamepad chord activations:
    GamepadChordCooldown = 0.65,

    -- =========================================================================
    -- 3. SHARED-SCREEN AUTO-LEASHING
    -- =========================================================================

    -- Automatically teleports Player 2 back to Player 1 in Shared Screen mode
    -- if they fall off a platform or get separated too far.
    AutoLeashEnabled = true,
    MaxDistance = 2500.0,
    MaxZDifference = 600.0,

    -- =========================================================================
    -- 4. AUTOMATIC CUTSCENE / CINEMATIC VIEWPORT SWITCHING
    -- =========================================================================

    -- Automatically switches from Split-Screen to Fullscreen/Shared camera when
    -- a level sequence cinematic or video cutscene starts, then restores your
    -- previous Split-Screen mode (Horizontal or Vertical) as soon as it ends.
    AutoFullscreenOnCutscene = true,
    CutsceneViewportMode = 2,
    ShowCutsceneSwitchNotification = false,

    -- =========================================================================
    -- 5. PAUSE MENU ROUTING & INPUT SAFETY
    -- =========================================================================

    -- Routes Pause Menu ownership cleanly through Primary Viewport (Slate User 0)
    -- so pressing Start/Pause on Player 2 never deadlocks controller/keyboard focus,
    -- and restores GameOnly input to both controllers on unpause.
    RoutePauseMenuToPrimaryViewport = true,

    -- =========================================================================
    -- 6. PER-PLAYER VIEWPORT HUD & MENU LOCALIZATION
    -- =========================================================================

    -- Ensures player HUD layouts and menus use AddToPlayerScreen() per PlayerController
    -- and scales UI proportionally inside Horizontal (32:9) and Vertical (8:9) split halves.
    LocalizePlayerViewports = true,

    -- Dynamically switches Unreal's DPI UIScaleRule to ScaleToFit (4) while split-screen
    -- is active so 16:9 menus (Pause, Cosmetics, Skill Tree) and HUD bars never clip or overlap.
    UseScaleToFitInSplitScreen = true,

    -- Fine-tune per-viewport render scales when Split-Screen is active (1.0 = exact fit):
    HorizontalSplitHUDScale = 1.0,
    VerticalSplitHUDScale = 0.95,
    SplitScreenMenuScale = 0.95,

    -- Fallback viewport anchor bounds for widgets confined per player:
    ViewportAnchors = {
        Horizontal = {
            Player1 = { MinX = 0.0, MinY = 0.0, MaxX = 1.0, MaxY = 0.5 },
            Player2 = { MinX = 0.0, MinY = 0.5, MaxX = 1.0, MaxY = 1.0 },
        },
        Vertical = {
            Player1 = { MinX = 0.0, MinY = 0.0, MaxX = 0.5, MaxY = 1.0 },
            Player2 = { MinX = 0.5, MinY = 0.0, MaxX = 1.0, MaxY = 1.0 },
        },
    },

    -- =========================================================================
    -- 7. PLAYER 2 CHARACTER, VISUAL TINT, OUTFITS, DANCES & SKILLS
    -- =========================================================================

    -- Which character model Player 2 spawns as (toggleable live in P2 Menu or [F4]):
    -- "Charlie"  = Spawns Charlie so all 55 Jacket/Glasses/Hair/Drumstick cosmetics apply cleanly
    -- "Chuckles" = Spawns Dead as Disco's hidden co-op character Chuckles
    -- "Auto"     = Uses the GameMode's default Player 2 pawn class
    Player2Character = "Charlie",

    -- Full-model visual tint for Player 2 (applied across body, jacket, hair, glasses, drumsticks,
    -- and re-applied automatically whenever async cosmetics finish loading).
    -- TintMode options (cycleable in P2 Menu or [Shift + F4]):
    --   "FullBody"   = Tints outfit, hair, drumsticks, and rim/outline shaders across the whole model
    --   "AccentOnly" = Keeps natural outfit textures and tints only Fresnel/Outline rim + CustomDepth
    --   "Off"        = No material color tint (rely solely on Player 2's custom outfit / character)
    EnablePlayer2VisualTint = true,
    TintMode = "AccentOnly",
    Player2TintColor = { R = 0.0, G = 1.0, B = 0.9, A = 1.0 },
    EnablePlayer2CustomDepth = true,
    Player2StencilValue = 250,
    TintHair = true,
    TintDrumsticks = true,

    --Selectable Tint Color Palettes inside Player 2's Custom Menu:
    TintColorPalettes = {
        { Name = "Neon Cyan",     Color = { R = 0.00, G = 1.00, B = 0.90, A = 1.0 } },
        { Name = "Disco Magenta", Color = { R = 1.00, G = 0.15, B = 0.75, A = 1.0 } },
        { Name = "Electric Gold", Color = { R = 1.00, G = 0.82, B = 0.10, A = 1.0 } },
        { Name = "Crimson Flame", Color = { R = 1.00, G = 0.22, B = 0.18, A = 1.0 } },
        { Name = "Emerald Mint",  Color = { R = 0.15, G = 1.00, B = 0.45, A = 1.0 } },
        { Name = "Royal Violet",  Color = { R = 0.58, G = 0.28, B = 1.00, A = 1.0 } },
    },

    -- Progression, Cosmetic & Skill Sync:
    SyncPlayer1UnlocksToPlayer2 = true,
    UnlockAllCosmeticsForPlayer2 = true,
    UnlockAllSkillsForPlayer2 = false,

    -- Default Outfit Preset index from OutfitPresets below:
    DefaultOutfitPresetIndex = 2,

    -- Optional custom per-slot outfit override (set Enabled = true to override DefaultOutfitPresetIndex):
    Player2CustomOutfit = {
        Enabled = false,
        BodyType = "Default",
        Jacket = "Rebel",
        Glasses = "Rebel",
        Hair = "Rebel",
        Drumsticks = "Rebel",
    },

    -- Curated Outfit Presets (selectable in P2 Custom Menu or cycled with [Shift + F2]):
    OutfitPresets = {
        { Name = "Classic Charlie", BodyType = "Default", Jacket = "Default",               Glasses = "Default",                  Hair = "Default",               Drumsticks = "Default" },
        { Name = "Rocker Flames",   BodyType = "Default", Jacket = "RockerFlames",          Glasses = "Rocker_Flames",            Hair = "RockerFlames",          Drumsticks = "Rocker_Fire" },
        { Name = "Rebel Punk",      BodyType = "Default", Jacket = "Rebel",                 Glasses = "Rebel",                    Hair = "Rebel",                 Drumsticks = "Rebel" },
        { Name = "Vermillion",      BodyType = "Slim",    Jacket = "Dancer",                Glasses = "Dancer",                   Hair = "Dancer",                Drumsticks = "Dancer" },
        { Name = "Street Prophet",  BodyType = "Default", Jacket = "Prophet",               Glasses = "Prophet",                  Hair = "Prophet",               Drumsticks = "Prophet" },
        { Name = "Shredder",        BodyType = "Default", Jacket = "Shred",                 Glasses = "Shred",                    Hair = "Shred",                 Drumsticks = "Shred" },
        { Name = "Arora Doll",      BodyType = "Slim",    Jacket = "Arora",                 Glasses = "Doll",                     Hair = "Arora",                 Drumsticks = "Doll" },
        { Name = "DED Tour",        BodyType = "Default", Jacket = "RockerDED",             Glasses = "Rocker_DED",               Hair = "RockerDED",             Drumsticks = "Rocker_DED" },
        { Name = "Beach Vibe",      BodyType = "Default", Jacket = "Beach_SummerHeadset",   Glasses = "Summer_HeadsetStyle",      Hair = "Summer_Headset",        Drumsticks = "Beach_1" },
        { Name = "Casual Groove",   BodyType = "Default", Jacket = "Casual",                Glasses = "Casual",                   Hair = "Casual",                Drumsticks = "Default" },
        { Name = "Disco White",     BodyType = "Default", Jacket = "White",                 Glasses = "White",                    Hair = "White",                 Drumsticks = "White" },
        { Name = "Midnight Black",  BodyType = "Default", Jacket = "Black",                 Glasses = "Black",                    Hair = "Black",                 Drumsticks = "Black" },
        { Name = "Pumpkin King",    BodyType = "Default", Jacket = "Rocker",                Glasses = "Rocker",                   Hair = "Halloween_PumpkinHead", Drumsticks = "Rocker_Fire" },
        { Name = "Vice Vacation",   BodyType = "Default", Jacket = "Beach_SummerHat",       Glasses = "Summer_HatStyle",          Hair = "Summer_Hat",            Drumsticks = "Beach_2" },
    },

    -- Default Skill & Dance Loadout index from LoadoutPresets below:
    DefaultLoadoutPresetIndex = 1,

    -- Optional custom Dance Move override (4 D-Pad slots: 1..4):
    Player2CustomDances = {
        Enabled = false,
        Slots = { "Moonwalk", "Headspin", "AbsoluteDisco", "AirChair" },
    },

    -- Optional custom Skills & Boss Abilities override:
    Player2CustomSkills = {
        Enabled = false,
        BossAbilities = { "ChainLightning", "DropTheBaxe", "BlockAndRetaliate", "VermillionDance" },
        Upgrades = {
            "DanceMove", "Drummerang", "Sprint", "StrongAttack", "Windmill",
            "FeverRush", "PerfectHitExtraDamageAndFever", "HealthUp_01", "MaxFeverUp_01",
        },
    },

    -- Curated Skill & Dance Loadouts (selectable in P2 Custom Menu or cycled with [Shift + F3]):
    LoadoutPresets = {
        {
            Name = "Mirror Player 1 + Groove Pack",
            MirrorPlayer1Skills = true,
            Dances = { "Moonwalk", "Headspin", "AbsoluteDisco", "AirChair" },
        },
        {
            Name = "Shredder Lightning",
            MirrorPlayer1Skills = false,
            BossAbilities = { "ChainLightning", "FeverRush", "DropTheBaxe", "VermillionDance" },
            Upgrades = {
                "DanceMove", "Drummerang", "Sprint", "StrongAttack", "Windmill", "FeverRush",
                "ChainLightning", "ChainLightning_Upgrade01", "Drummerang_FollowUp",
                "PerfectLightning", "MaxHealthUp_01", "PerfectHitExtraDamageAndFever",
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
                "StrongAttack_HitReactImmune", "HealthUp_01", "ExtraTakedownToken_01",
            },
            Dances = { "BadBoyBoogie", "Freeze", "AirChair", "Shrug" },
        },
        {
            Name = "Vermillion Dancer",
            MirrorPlayer1Skills = false,
            BossAbilities = { "VermillionDance", "Singularity", "ChainLightning", "FeverRush" },
            Upgrades = {
                "DanceMove", "Drummerang", "Sprint", "StrongAttack", "Windmill", "FeverRush",
                "VermillionDance", "VDance_BurningStrikeOnFollowup", "VDance_EmpoweredFollowup",
                "PerfectDodgeFeverRegen", "AoeBurnOnStrongDrummerang", "SlowerFeverDrain",
            },
            Dances = { "SalsaFan", "JazzSplit", "HonestHips", "HeartHands" },
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
    },

    -- On-screen notification duration in seconds:
    MessageDuration = 4.0,
}

return Config
