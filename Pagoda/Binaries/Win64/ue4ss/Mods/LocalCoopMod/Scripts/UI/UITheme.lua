-- ============================================================================
-- UI THEME, NATIVE UE5 ROUNDED-BOX BUILDERS, HITCH-FREE ICONS & AUDIO
-- ============================================================================

local UObjectUtils = require("Utils.UObjectUtils")
local Logger = require("Utils.Logger")

local UITheme = {}

UITheme.Fonts = {
    Primary   = "/Game/Pagoda/UI/Fonts/Primary_Font.Primary_Font",
    Secondary = "/Game/Pagoda/UI/Fonts/Secondary_Font.Secondary_Font",
    Body      = "/Game/Pagoda/UI/Fonts/BodyText_Font.BodyText_Font",
}

UITheme.NativeTextures = {
    HalftoneBL     = "/Game/Pagoda/UI/Art/SkillTree/bg_halftone_BL.bg_halftone_BL",
    HalftoneTL     = "/Game/Pagoda/UI/Art/SkillTree/bg_halftone_TL.bg_halftone_TL",
    HalftoneCircle = "/Game/Pagoda/UI/Art/TUTORIAL/halftone_gradient_circle_01.halftone_gradient_circle_01",
    HalftoneRadial = "/Game/Pagoda/UI/Art/Playtest/halftone_gradient_radial.halftone_gradient_radial",
    Divider        = "/Game/Pagoda/UI/Art/General/popup_divider.popup_divider",
    Shard          = "/Game/Pagoda/UI/Art/General/shard01.shard01",
    Checkmark      = "/Game/Pagoda/UI/Art/Cosmetics/checkmark.checkmark",
    CounterRing    = "/Game/Pagoda/UI/Art/HUD/counterRing_inner.counterRing_inner",
    CounterRingMMS = "/Game/Pagoda/UI/Art/HUD/counterRing_inner_mms.counterRing_inner_mms",
    TargeterMain   = "/Game/Pagoda/UI/Art/HUD/targeter_main.targeter_main",
    TargeterShard  = "/Game/Pagoda/UI/Art/HUD/targeter_shard.targeter_shard",
    BeatBg         = "/Game/Pagoda/UI/Art/HUD/beatIndicatorA_bg.beatIndicatorA_bg",
    HeartFull      = "/Game/Pagoda/UI/Art/HUD/Heart_full.Heart_full",
    TabChar        = "/Game/Pagoda/UI/Art/Cosmetics/icon_jacket.icon_jacket",
    TabMoves       = "/Game/Pagoda/UI/Art/SkillTree/icon_shred.icon_shred",
    TabDances      = "/Game/Pagoda/UI/Art/Cosmetics/icon_danceMove.icon_danceMove",
    TabUpgrades    = "/Game/Pagoda/UI/Art/SkillTree/icon_charlie.icon_charlie",
    TabCoop        = "/Game/Pagoda/UI/Art/SettingMenu/icon_gameplay.icon_gameplay",
}

UITheme.Colors = {
    Transparent     = { R = 0.000, G = 0.000, B = 0.000, A = 0.00 },
    PanelBackdrop   = { R = 0.048, G = 0.022, B = 0.095, A = 0.95 },
    RailBackdrop    = { R = 0.030, G = 0.014, B = 0.064, A = 0.98 },
    SurfaceCard     = { R = 0.092, G = 0.046, B = 0.172, A = 0.88 },
    SurfaceRaised   = { R = 0.135, G = 0.068, B = 0.245, A = 0.94 },
    SurfaceSelected = { R = 0.215, G = 0.072, B = 0.335, A = 0.98 },
    SurfaceEquipped = { R = 0.042, G = 0.165, B = 0.155, A = 0.92 },
    SurfaceConflict = { R = 0.215, G = 0.120, B = 0.038, A = 0.90 },
    TrackDark       = { R = 0.055, G = 0.028, B = 0.115, A = 0.96 },

    MarqueePink     = { R = 1.000, G = 0.120, B = 0.560, A = 0.96 },
    HairlineSubtle  = { R = 0.860, G = 0.580, B = 1.000, A = 0.14 },
    HairlineBright  = { R = 1.000, G = 0.300, B = 0.720, A = 0.34 },
    DividerLine     = { R = 0.900, G = 0.450, B = 1.000, A = 0.14 },

    Cyan            = { R = 0.000, G = 0.930, B = 1.000, A = 1.00 },
    CyanSoft        = { R = 0.000, G = 0.930, B = 1.000, A = 0.20 },
    Magenta         = { R = 1.000, G = 0.120, B = 0.560, A = 1.00 },
    MagentaSoft     = { R = 1.000, G = 0.120, B = 0.560, A = 0.24 },
    Gold            = { R = 1.000, G = 0.850, B = 0.140, A = 1.00 },
    GoldSoft        = { R = 1.000, G = 0.850, B = 0.140, A = 0.22 },
    Emerald         = { R = 0.140, G = 0.960, B = 0.640, A = 1.00 },
    EmeraldSoft     = { R = 0.140, G = 0.960, B = 0.640, A = 0.22 },
    Amber           = { R = 1.000, G = 0.540, B = 0.140, A = 1.00 },
    AmberSoft       = { R = 1.000, G = 0.540, B = 0.140, A = 0.24 },
    Crimson         = { R = 1.000, G = 0.220, B = 0.340, A = 1.00 },
    CrimsonSoft     = { R = 1.000, G = 0.220, B = 0.340, A = 0.24 },
    Violet          = { R = 0.760, G = 0.420, B = 1.000, A = 1.00 },
    VioletSoft      = { R = 0.760, G = 0.420, B = 1.000, A = 0.24 },

    TextPrimary     = { R = 0.990, G = 0.985, B = 1.000, A = 1.00 },
    TextSecondary   = { R = 0.820, G = 0.760, B = 0.920, A = 1.00 },
    TextMuted       = { R = 0.580, G = 0.510, B = 0.720, A = 1.00 },
    TextDark        = { R = 0.055, G = 0.020, B = 0.100, A = 1.00 },
}

UITheme.IdolStyles = {
    Dancer  = { Label = "Dahlia",  Full = "DAHLIA - BURN",       Color = UITheme.Colors.Magenta, Soft = UITheme.Colors.MagentaSoft },
    Shred   = { Label = "Shred",   Full = "SHRED - LIGHTNING",   Color = UITheme.Colors.Cyan,    Soft = UITheme.Colors.CyanSoft },
    Rebel   = { Label = "Rebel",   Full = "REBEL - HEAVY BAXE",  Color = UITheme.Colors.Amber,   Soft = UITheme.Colors.AmberSoft },
    Prophet = { Label = "Prophet", Full = "PROPHET - COUNTER",   Color = UITheme.Colors.Gold,    Soft = UITheme.Colors.GoldSoft },
    Doll    = { Label = "Arora",   Full = "ARORA - COSMIC",      Color = UITheme.Colors.Violet,  Soft = UITheme.Colors.VioletSoft },
    Charlie = { Label = "Charlie", Full = "CHARLIE - CORE",      Color = UITheme.Colors.Emerald, Soft = UITheme.Colors.EmeraldSoft },
}

function UITheme.GetIdolStyle(idolKey)
    local k = tostring(idolKey or "Charlie")
    if UITheme.IdolStyles[k] then return UITheme.IdolStyles[k] end
    return {
        Label = k,
        Full = k:upper() .. " - TREE",
        Color = UITheme.Colors.Cyan,
        Soft = UITheme.Colors.CyanSoft,
    }
end

function UITheme.CleanRichText(raw)
    if type(raw) ~= "string" or raw == "" then return "" end
    local s = raw
    s = s:gsub("<HB>", ""):gsub("</HB>", "")
    s = s:gsub("<B>", ""):gsub("</B>", "")
    s = s:gsub("<I>", ""):gsub("</I>", "")
    s = s:gsub("</>", "")
    s = s:gsub("{ChainCount}", "3")
    s = s:gsub("{ChainPerfectAmount}", "4")
    s = s:gsub("{FeverAmount}", "1")
    s = s:gsub("{PerfectDamageBonus}", "50")
    s = s:gsub("{BlackholeDuration}", "8")
    s = s:gsub("{BlackholeDurationPerfect}", "12")
    s = s:gsub("{BeatDuration}", "8")
    s = s:gsub("{PerfectBeatDuration}", "12")
    s = s:gsub("{amount}", "1")
    s = s:gsub("{duration}", "8")
    s = s:gsub("[\r\n]+", " ")
    return s
end

local function MakeSlateColor(c)
    return {
        SpecifiedColor = { R = c.R or 1, G = c.G or 1, B = c.B or 1, A = c.A or 1 },
        ColorUseRule = 0,
    }
end

function UITheme.SetText(txtWidget, str)
    if not UObjectUtils.IsValid(txtWidget) then return end
    pcall(function() txtWidget:SetText(FText(tostring(str or ""))) end)
end

function UITheme.SetTextColor(txtWidget, color)
    if not (UObjectUtils.IsValid(txtWidget) and color) then return end
    pcall(function() txtWidget:SetColorAndOpacity(MakeSlateColor(color)) end)
end

function UITheme.SetFill(borderWidget, color)
    if not (UObjectUtils.IsValid(borderWidget) and color) then return end
    pcall(function()
        borderWidget:SetBrushColor({ R = color.R or 1, G = color.G or 1, B = color.B or 1, A = color.A or 1 })
    end)
end

function UITheme.StyleRoundedCard(borderWidget, fillColor, radius, outlineColor, outlineWidth)
    if not UObjectUtils.IsValid(borderWidget) then return end
    UITheme.SetFill(borderWidget, fillColor or UITheme.Colors.SurfaceCard)

    pcall(function()
        local r = radius or 6.0
        local bg = borderWidget.Background
        if bg then
            bg.DrawAs = 4 -- RoundedBox
            bg.TintColor = MakeSlateColor({ R = 1.0, G = 1.0, B = 1.0, A = 1.0 })
            if bg.OutlineSettings then
                bg.OutlineSettings.CornerRadii = { X = r, Y = r, Z = r, W = r }
                bg.OutlineSettings.RoundingType = 0
                bg.OutlineSettings.Width = outlineWidth or 0.0
                if outlineColor and (outlineWidth or 0.0) > 0.0 then
                    bg.OutlineSettings.Color = MakeSlateColor(outlineColor)
                else
                    bg.OutlineSettings.Color = MakeSlateColor(UITheme.Colors.Transparent)
                end
            end
            borderWidget:SetBrush(bg)
        end
    end)
end

function UITheme.StyleDiscoFrame(borderWidget, fillColor, outlineColor, outlineWidth, radius)
    UITheme.StyleRoundedCard(
        borderWidget,
        fillColor or UITheme.Colors.SurfaceCard,
        radius or 3.0,
        outlineColor or UITheme.Colors.HairlineBright,
        outlineWidth or 1.4
    )
end

function UITheme.ApplyNativeSkew(widget, shearX)
    if not UObjectUtils.IsValid(widget) then return end
    pcall(function()
        widget:SetRenderTransformPivot({ X = 0.5, Y = 0.5 })
        widget:SetRenderShear({ X = shearX or -7.0, Y = 0.0 })
    end)
end

function UITheme.SetOutlineColor(borderWidget, outlineColor, outlineWidth)
    if not (UObjectUtils.IsValid(borderWidget) and outlineColor) then return end
    pcall(function()
        local bg = borderWidget.Background
        if bg and bg.OutlineSettings then
            bg.OutlineSettings.Width = outlineWidth or 1.0
            bg.OutlineSettings.Color = MakeSlateColor(outlineColor)
            borderWidget:SetBrush(bg)
        end
    end)
end

local CachedFonts = {}
local CachedUMGClasses = nil

function UITheme.StyleText(txtWidget, size, fontPath, color, autoWrap, justify)
    if not UObjectUtils.IsValid(txtWidget) then return end
    pcall(function()
        local fKey = fontPath or UITheme.Fonts.Body
        local fObj = CachedFonts[fKey]
        if not UObjectUtils.IsValid(fObj) then
            fObj = fontPath and StaticFindObject(fontPath) or nil
            if not UObjectUtils.IsValid(fObj) then
                fObj = StaticFindObject(UITheme.Fonts.Body)
            end
            if UObjectUtils.IsValid(fObj) then
                CachedFonts[fKey] = fObj
            end
        end
        if UObjectUtils.IsValid(fObj) then
            txtWidget.Font.FontObject = fObj
        end
        txtWidget.Font.Size = size or 11
        txtWidget:SetFont(txtWidget.Font)
    end)
    pcall(function()
        txtWidget:SetShadowOffset({ X = 1.5, Y = 1.5 })
        txtWidget:SetShadowColorAndOpacity({ R = 0.02, G = 0.0, B = 0.05, A = 0.85 })
    end)
    if autoWrap then
        pcall(function() txtWidget:SetAutoWrapText(true) end)
    end
    if justify ~= nil then
        pcall(function() txtWidget:SetJustification(justify) end)
    end
    if color then UITheme.SetTextColor(txtWidget, color) end
end

function UITheme.StripButtonChrome(btn)
    if not UObjectUtils.IsValid(btn) then return end
    pcall(function()
        btn.IsFocusable = false
        btn:SetBackgroundColor({ R = 1.0, G = 1.0, B = 1.0, A = 0.0 })
        local st = btn.WidgetStyle
        if st then
            if st.Normal then st.Normal.DrawAs = 0 end
            if st.Hovered then st.Hovered.DrawAs = 0 end
            if st.Pressed then st.Pressed.DrawAs = 0 end
            if st.Disabled then st.Disabled.DrawAs = 0 end
            st.NormalPadding = { Left = 0, Top = 0, Right = 0, Bottom = 0 }
            st.PressedPadding = { Left = 0, Top = 0, Right = 0, Bottom = 0 }
            btn:SetStyle(st)
        end
    end)
end

function UITheme.Truncate(str, maxLen)
    local s = tostring(str or "")
    local limit = maxLen or 32
    if #s <= limit then return s end
    if limit <= 3 then return s:sub(1, limit) end
    return s:sub(1, limit - 2) .. ".."
end

function UITheme.GetUMGClasses()
    if CachedUMGClasses and UObjectUtils.IsValid(CachedUMGClasses.WBL) and UObjectUtils.IsValid(CachedUMGClasses.Widget) then
        return CachedUMGClasses
    end
    local c = {
        WBL      = UObjectUtils.GetWidgetBlueprintLibrary(),
        Widget   = StaticFindObject("/Script/UMG.UserWidget"),
        Canvas   = StaticFindObject("/Script/UMG.CanvasPanel"),
        Overlay  = StaticFindObject("/Script/UMG.Overlay"),
        Border   = StaticFindObject("/Script/UMG.Border"),
        VBox     = StaticFindObject("/Script/UMG.VerticalBox"),
        HBox     = StaticFindObject("/Script/UMG.HorizontalBox"),
        Text     = StaticFindObject("/Script/UMG.TextBlock"),
        Button   = StaticFindObject("/Script/UMG.Button"),
        SizeBox  = StaticFindObject("/Script/UMG.SizeBox"),
        ScaleBox = StaticFindObject("/Script/UMG.ScaleBox"),
        Image    = StaticFindObject("/Script/UMG.Image"),
    }
    if UObjectUtils.IsValid(c.WBL) and UObjectUtils.IsValid(c.Widget) and UObjectUtils.IsValid(c.Canvas)
        and UObjectUtils.IsValid(c.Border) and UObjectUtils.IsValid(c.VBox)
        and UObjectUtils.IsValid(c.HBox) and UObjectUtils.IsValid(c.Text)
        and UObjectUtils.IsValid(c.Button) and UObjectUtils.IsValid(c.SizeBox) then
        CachedUMGClasses = c
        return c
    end
    Logger.Missing("UITheme", "UMG Core Classes", "GetUMGClasses")
    return nil
end

-- ============================================================================
-- HITCH-FREE LAZY ICON RESOLVER (MAX 2 BLOCKING LOADS PER FRAME)
-- ============================================================================

local ICON_PROP_CANDIDATES = {
    "IconImage", "Icon", "IconTexture", "AbilityIcon", "UpgradeIcon",
    "CosmeticIcon", "DanceIcon", "IconBrush", "Thumbnail", "ThumbnailImage",
    "PreviewImage", "BadgeIcon",
}

local SKILL_ICON_FALLBACKS = {
    -- Rebel
    PlayerUpgrade_Rebel_BasicAttackBreakShield = "BasicAttackShield",
    PlayerUpgrade_Rebel_DropTheBaxe = "Baxe",
    PlayerUpgrade_Rebel_DropTheBaxe_AoeSize = "Baxe2",
    PlayerUpgrade_Rebel_DropTheBaxe_ExtraPerfectDamage = "Baxe3",
    PlayerUpgrade_Rebel_DropTheBaxe_FeverGainBoost = "Baxe4",
    PlayerUpgrade_Rebel_DropTheBaxe_Upgrade_01 = "Baxe2",
    PlayerUpgrade_Rebel_FeverOnPowerupPickup = "PowerupFeverBar",
    PlayerUpgrade_Rebel_HazardDamageReduction = "HazardProof",
    PlayerUpgrade_Rebel_HealthUp_01 = "HealthUp",
    PlayerUpgrade_Rebel_HellishPact_01 = "Skull",
    PlayerUpgrade_Rebel_MaxFeverUp_01 = "FeverUp",
    PlayerUpgrade_Rebel_StrongAttack_AddKnockbackDistance = "StrongAttackKnockback",
    PlayerUpgrade_Rebel_StrongAttack_FasterChargeUp = "StrongAttackSpeed",
    PlayerUpgrade_Rebel_StrongAttack_FollowUp = "StrongAttackFollow",
    PlayerUpgrade_Rebel_StrongAttack_HitReactImmune = "StrongWilled",
    PlayerUpgrade_Rebel_StrongAttack_IncreaseDamage = "StrongAttackDamageUp",
    PlayerUpgrade_Rebel_StrongAttack_ReduceIncomingDamage = "StrongAttackDamageReduction",
    PlayerUpgrade_Rebel_StrongAttack_VehicleImmunityDuringCharge = "StrongWilled",

    -- Prophet
    PlayerUpgrade_Prophet_BlockAndRetaliate = "IdolAbility_Prophet",
    PlayerUpgrade_Prophet_Block_ReducedFeverCost = "IdolAbility_Prophet",
    PlayerUpgrade_Prophet_Block_SuperArmor = "IdolAbility_Prophet",
    PlayerUpgrade_Prophet_FeverUpgrade = "FeverUp",
    PlayerUpgrade_Prophet_HealthUp = "HealthUp",
    PlayerUpgrade_Prophet_SprintStartArmor = "SonicSpeed",

    -- Shred
    PlayerUpgrade_Shred_AmpedIfShockedTargets = "DamageUp",
    PlayerUpgrade_Shred_ChainLightning = "Shock-and-Awe",
    PlayerUpgrade_Shred_ChainLightning_Upgrade01 = "AmplifiedShock",
    PlayerUpgrade_Shred_Drummerang_FollowUp = "Drummerang",
    PlayerUpgrade_Shred_ExtraFeverOnShockedTargets = "FeverUp",
    PlayerUpgrade_Shred_FeverDrainExtraOnPerfect = "PerfectFever",
    PlayerUpgrade_Shred_LightningStrike = "LightningStrike",
    PlayerUpgrade_Shred_LightningStrike_FeverOnPerfect = "Thunderstruck",
    PlayerUpgrade_Shred_LightningStrike_IncreaseWidth = "Thunderstruck",
    PlayerUpgrade_Shred_LightningStrike_ShockAoe = "AmplifiedShock",
    PlayerUpgrade_Shred_LightningStrike_Upgrade01 = "Thunderstruck",
    PlayerUpgrade_Shred_LongerShocked = "AmplifiedShock",
    PlayerUpgrade_Shred_MaxFeverUp_01 = "FeverUp",
    PlayerUpgrade_Shred_MaxHealthUp_01 = "HealthUp",
    PlayerUpgrade_Shred_PerfectCounter_AddAOE = "AoE",
    PlayerUpgrade_Shred_PerfectInputFeverGainUp = "PerfectFever",
    PlayerUpgrade_Shred_PerfectLightning = "AmplifiedShock",
    PlayerUpgrade_Shred_PrototypeLightningStrikeMoveTargeting = "LightningStrike",
    PlayerUpgrade_Shred_StrongAttack_AddShocked = "Shock-and-Awe",
    PlayerUpgrade_Shred_Windmill_AddShocked = "WindmillLightning",

    -- Dancer (Dahlia)
    PlayerUpgrade_Dancer_VermillionDance = "VermillionDance",
    PlayerUpgrade_Dancer_VDance_BurningStrikeOnFollowup = "BurningStrikes",
    PlayerUpgrade_Dancer_VDance_EmpoweredFollowup = "Enflame",
    PlayerUpgrade_Dancer_PyroetteAoeOnHit = "AoE",
    PlayerUpgrade_Dancer_PyroetteDurationUp = "FanTheFlames",
    PlayerUpgrade_Dancer_BurnDurationUp = "HeatOfPassion",
    PlayerUpgrade_Dancer_FlashbackExtraDamage = "DissonantFlashback",
    PlayerUpgrade_Dancer_AoeBurnOnStrongDrummerang = "Enflame",
    PlayerUpgrade_Dancer_PerfectDodgeFeverRegen = "DanceFever",
    PlayerUpgrade_Dancer_MaxFeverUp_01 = "FeverUp",

    -- Doll (Arora)
    PlayerUpgrade_Doll_Singularity = "Singularity1",
    PlayerUpgrade_Doll_Singularity_ExtraDurationOnPerfect = "Singularity2",
    PlayerUpgrade_Doll_Singularity_SizeIncrease = "Singularity3",
    PlayerUpgrade_Doll_Singularity_SpeedIncrease = "Singularity4",
    PlayerUpgrade_Doll_Singularity_Upgrade_01 = "Singularity2",
    PlayerUpgrade_Doll_Windmill_AddSingularity = "WindmillMagnet",
    PlayerUpgrade_Doll_StrongRangedAttack = "DoubleRanged",
    PlayerUpgrade_Doll_RangedFloatOnPerfectHit = "AntiGrav",
    PlayerUpgrade_Doll_StunningStrike_Float = "AntiGrav",
    PlayerUpgrade_Doll_AerialTakedown_AddPull = "AerialTakedown",
    PlayerUpgrade_Doll_ConeBlastHitReactImmunity = "StrongWilled",
    PlayerUpgrade_Doll_DanceMove_HealOnLowHealth = "DanceMove",
    PlayerUpgrade_Doll_HealthUp_01 = "HealthUp",
    PlayerUpgrade_Doll_MaxFeverUp_01 = "FeverUp",
    PlayerUpgrade_Doll_HellishPact = "Skull",

    -- Charlie
    PlayerUpgrade_Charlie_FeverRush = "FeverRush",
    PlayerUpgrade_Charlie_FeverRush_HitReactImmune = "StrongWilled",
    PlayerUpgrade_Charlie_Drummerang = "Drummerang",
    PlayerUpgrade_Charlie_Drummerang_ExtraStock_01 = "TripleDrummerang",
    PlayerUpgrade_Charlie_Drummerang_ExtraStock_02 = "TripleDrummerang",
    PlayerUpgrade_Charlie_Windmill = "Windmill",
    PlayerUpgrade_Charlie_Windmill_IncreaseDuration = "WindmillLightning",
    PlayerUpgrade_Charlie_DanceMove = "DanceMove",
    PlayerUpgrade_Charlie_DanceMove_Energized = "DanceWithMe",
    PlayerUpgrade_Charlie_DanceMove_FeverGainOncePerSong = "DanceWithYourHeart",
    PlayerUpgrade_Charlie_StrongAttack = "StrongAttackDamageUp",
    PlayerUpgrade_Charlie_Sprint = "SonicSpeed",
    PlayerUpgrade_Charlie_StayinAlive = "HazardProof",
    PlayerUpgrade_Charlie_HealthUp_01 = "HealthUp",
    PlayerUpgrade_Charlie_HealthUp_02 = "HealthUp",
    PlayerUpgrade_Charlie_HealthUp_03 = "HealthUp",
    PlayerUpgrade_Charlie_MaxFeverUp_01 = "FeverUp",
    PlayerUpgrade_Charlie_MaxFeverUp_02 = "FeverUp",
    PlayerUpgrade_Charlie_MaxFeverUp_03 = "FeverUp",
    PlayerUpgrade_Charlie_PerfectHitExtraDamageAndFever = "OnBeat",
    PlayerUpgrade_Charlie_SlowerFeverDrain = "PowerupFeverBar",
    PlayerUpgrade_Charlie_ExtraTakedownToken_01 = "AerialTakedown",
    PlayerUpgrade_Charlie_FasterTakedownTokenProgress_01 = "AerialTakedown",
    PlayerUpgrade_Charlie_HealOnConsecutiveTakedowns = "AerialTakedown",
}

local IconCache = {}
local IconFailCount = {}
local IconLoadsThisTick = 0
local IconLoadWindowAt = 0.0
local MAX_BLOCKING_ICON_LOADS_PER_FRAME = 2

local function CanPerformBlockingIconLoad()
    local now = os.clock()
    if (now - IconLoadWindowAt) > 0.015 then
        IconLoadWindowAt = now
        IconLoadsThisTick = 0
    end
    return IconLoadsThisTick < MAX_BLOCKING_ICON_LOADS_PER_FRAME
end

local function ConsumeBlockingIconBudget()
    IconLoadsThisTick = IconLoadsThisTick + 1
end

local function ClassifyVisualAsset(obj)
    if not UObjectUtils.IsValid(obj) then return nil end
    local clsName = ""
    pcall(function() clsName = obj:GetClass():GetFName():ToString() end)
    if clsName:find("Texture", 1, true) then
        return { Kind = "Texture", Asset = obj }
    elseif clsName:find("Material", 1, true) then
        return { Kind = "Material", Asset = obj }
    end
    return nil
end

local function LoadTextureByPath(assetPath)
    if type(assetPath) ~= "string" or assetPath == "" then return nil, false end
    local obj = nil
    pcall(function() obj = StaticFindObject(assetPath) end)
    if UObjectUtils.IsValid(obj) then return ClassifyVisualAsset(obj), false end

    if not CanPerformBlockingIconLoad() then
        return nil, true -- Deferred due to per-frame budget
    end
    ConsumeBlockingIconBudget()

    local dot = assetPath:match("%.([^%.]+)$")
    local pkg = assetPath:match("^([^%.]+)%.") or assetPath
    if type(LoadAsset) == "function" then
        pcall(function() LoadAsset(pkg) end)
        pcall(function() LoadAsset(assetPath) end)
    end
    pcall(function() obj = StaticFindObject(assetPath) end)
    if UObjectUtils.IsValid(obj) then return ClassifyVisualAsset(obj), false end
    if dot then
        pcall(function() obj = StaticFindObject(pkg .. "." .. dot) end)
        if UObjectUtils.IsValid(obj) then return ClassifyVisualAsset(obj), false end
    end
    return nil, false
end

local function TryResolveSoftOrObject(val)
    if val == nil then return nil, false end

    local direct = ClassifyVisualAsset(val)
    if direct then return direct, false end

    local okSoft, softObj = pcall(function()
        if val.Get then return val:Get() end
        return nil
    end)
    if okSoft and UObjectUtils.IsValid(softObj) then
        local res = ClassifyVisualAsset(softObj)
        if res then return res, false end
    end

    local okRes, resObj = pcall(function() return val.ResourceObject end)
    if okRes and UObjectUtils.IsValid(resObj) then
        local vis = ClassifyVisualAsset(resObj)
        if vis then return vis, false end
        return { Kind = "Brush", Asset = val }, false
    end

    local ksl = UObjectUtils.GetKismetSystemLibrary()
    if ksl then
        if not CanPerformBlockingIconLoad() then
            return nil, true
        end
        ConsumeBlockingIconBudget()

        local okBlk, blkObj = pcall(function() return ksl:LoadAsset_Blocking(val) end)
        if okBlk and UObjectUtils.IsValid(blkObj) then
            local res = ClassifyVisualAsset(blkObj)
            if res then return res, false end
        end

        local pathStr = nil
        local okStr, s = pcall(function() return ksl:Conv_SoftObjectReferenceToString(val) end)
        if okStr and s ~= nil then
            pcall(function()
                pathStr = (type(s) == "string") and s or (s.ToString and s:ToString() or tostring(s))
            end)
        end
        if type(pathStr) == "string" and pathStr:find("/Game/", 1, true) then
            local clean = pathStr:match("(/Game/[^%s'\"`]+)")
            local res, budgetHit = LoadTextureByPath(clean)
            return res, budgetHit
        end
    end

    return nil, false
end

local function ResolveFallbackTextureByName(def)
    local objName = ""
    pcall(function() objName = def:GetFName():ToString() end)
    if objName == "" then return nil, false end

    local iconFile = SKILL_ICON_FALLBACKS[objName]
    if not iconFile then
        if objName:find("^PlayerUpgrade_") then
            local short = objName:gsub("^PlayerUpgrade_[A-Za-z]+_", "")
            if objName:find("Windmill", 1, true) then iconFile = "Windmill"
            elseif objName:find("Drummerang", 1, true) then iconFile = "Drummerang"
            elseif objName:find("HealthUp", 1, true) then iconFile = "HealthUp"
            elseif objName:find("Fever", 1, true) then iconFile = "FeverUp"
            elseif objName:find("StrongAttack", 1, true) then iconFile = "StrongAttackDamageUp"
            elseif objName:find("Burn", 1, true) then iconFile = "BurningStrikes"
            elseif objName:find("Shock", 1, true) then iconFile = "AmplifiedShock"
            elseif objName:find("Lightning", 1, true) then iconFile = "LightningStrike"
            elseif objName:find("DanceMove", 1, true) then iconFile = "DanceMove"
            elseif objName:find("Counter", 1, true) then iconFile = "OnBeat"
            elseif objName:find("Dodge", 1, true) then iconFile = "DanceFever"
            elseif objName:find("BasicAttack", 1, true) then iconFile = "BasicAttackShield"
            elseif objName:find("Sprint", 1, true) then iconFile = "SonicSpeed"
            else iconFile = short end
        elseif objName:find("^PlayerCosmetic_Dance_") then
            local short = objName:gsub("^PlayerCosmetic_Dance_", "")
            if short == "Halloween01" then short = "Halloween1"
            elseif short == "Halloween02" then short = "Halloween2" end
            local dPath = string.format("/Game/Pagoda/UI/Art/Cosmetics/Icons/Dance_%s.Dance_%s", short, short)
            return LoadTextureByPath(dPath)
        end
    end

    if iconFile then
        local sPath = string.format("/Game/Pagoda/UI/Art/SkillTree/Icons/%s.%s", iconFile, iconFile)
        return LoadTextureByPath(sPath)
    end
    return nil, false
end

-- Returns iconInfo, needsDeferredRefresh
function UITheme.ResolveDefinitionIcon(def)
    if not UObjectUtils.IsValid(def) then return nil, false end
    local key = UObjectUtils.GetKey(def)
    if key and IconCache[key] then
        local cached = IconCache[key]
        if cached.Kind == "Brush" or UObjectUtils.IsValid(cached.Asset) then
            return cached, false
        end
        IconCache[key] = nil
    end
    if key and (IconFailCount[key] or 0) >= 2 then
        return nil, false
    end

    local resolved, budgetDeferred = nil, false

    for _, fnName in ipairs({ "GetIconImage", "GetItemTexture" }) do
        if not resolved then
            local ok, val = pcall(function() return def[fnName](def) end)
            if ok and val ~= nil then
                local r, bh = TryResolveSoftOrObject(val)
                resolved = r
                budgetDeferred = budgetDeferred or bh
                if budgetDeferred and not resolved then break end
            end
        end
    end

    if not resolved and not budgetDeferred then
        for _, propName in ipairs(ICON_PROP_CANDIDATES) do
            local ok, val = pcall(function() return def[propName] end)
            if ok and val ~= nil then
                local r, bh = TryResolveSoftOrObject(val)
                resolved = r
                budgetDeferred = budgetDeferred or bh
                if resolved or budgetDeferred then break end
            end
        end
    end

    if not resolved and not budgetDeferred then
        resolved, budgetDeferred = ResolveFallbackTextureByName(def)
    end

    if resolved then
        if key then
            IconCache[key] = resolved
            IconFailCount[key] = nil
        end
        return resolved, false
    end

    if budgetDeferred then
        return nil, true
    end

    if key then
        IconFailCount[key] = (IconFailCount[key] or 0) + 1
    end
    return nil, false
end

function UITheme.ApplyIconToImage(imgWidget, iconInfo)
    if not UObjectUtils.IsValid(imgWidget) then return false end
    if not iconInfo or iconInfo.Kind == "None" then return false end
    pcall(function() imgWidget:SetColorAndOpacity({ R = 1.0, G = 1.0, B = 1.0, A = 1.0 }) end)
    local ok = false
    if iconInfo.Kind == "Texture" and UObjectUtils.IsValid(iconInfo.Asset) then
        ok = pcall(function() imgWidget:SetBrushFromTexture(iconInfo.Asset, false) end)
    elseif iconInfo.Kind == "Material" and UObjectUtils.IsValid(iconInfo.Asset) then
        ok = pcall(function() imgWidget:SetBrushFromMaterial(iconInfo.Asset) end)
    elseif iconInfo.Kind == "Brush" and iconInfo.Asset ~= nil then
        ok = pcall(function() imgWidget:SetBrush(iconInfo.Asset) end)
    end
    return ok == true
end

local NativeTexCache = {}
function UITheme.GetNativeTexture(key)
    local cached = NativeTexCache[key]
    if cached ~= nil then
        return UObjectUtils.IsValid(cached) and cached or nil
    end
    local path = UITheme.NativeTextures[key]
    if not path then return nil end
    local obj = nil
    pcall(function() obj = StaticFindObject(path) end)
    if not UObjectUtils.IsValid(obj) and type(LoadAsset) == "function" then
        local pkg = path:match("^([^%.]+)%.") or path
        pcall(function() LoadAsset(pkg) end)
        pcall(function() LoadAsset(path) end)
        pcall(function() obj = StaticFindObject(path) end)
    end
    NativeTexCache[key] = UObjectUtils.IsValid(obj) and obj or false
    return UObjectUtils.IsValid(obj) and obj or nil
end

function UITheme.MakeCleanButtonCard(wt, cls, fillColor, radius, outlineColor, outlineWidth, padL, padT, padR, padB)
    local btn = StaticConstructObject(cls.Button, wt)
    UITheme.StripButtonChrome(btn)

    local card = StaticConstructObject(cls.Border, wt)
    UITheme.StyleRoundedCard(card, fillColor, radius or 3.0, outlineColor, outlineWidth)
    card:SetPadding({ Left = padL or 10, Top = padT or 6, Right = padR or 10, Bottom = padB or 6 })
    btn:AddChild(card)
    return btn, card
end

function UITheme.MakePillBadge(wt, cls, text, bgColor, textColor, fontSize)
    local pill = StaticConstructObject(cls.Border, wt)
    UITheme.StyleRoundedCard(pill, bgColor or UITheme.Colors.CyanSoft, 3.0, nil, 0.0)
    pill:SetPadding({ Left = 7, Top = 2, Right = 7, Bottom = 2 })

    local lbl = StaticConstructObject(cls.Text, wt)
    UITheme.StyleText(lbl, fontSize or 8, UITheme.Fonts.Secondary, textColor or UITheme.Colors.Cyan, false, 1)
    UITheme.SetText(lbl, text or "")
    pill:SetContent(lbl)
    return pill, lbl
end

function UITheme.MakeDivider(wt, cls)
    local sb = StaticConstructObject(cls.SizeBox, wt)
    pcall(function() sb:SetHeightOverride(4.0) end)
    local divTex = UITheme.GetNativeTexture("Divider")
    if UObjectUtils.IsValid(divTex) and UObjectUtils.IsValid(cls.Image) then
        local img = StaticConstructObject(cls.Image, wt)
        pcall(function()
            img:SetBrushFromTexture(divTex, false)
            img:SetColorAndOpacity({ R = 1.0, G = 0.24, B = 0.68, A = 0.55 })
        end)
        sb:AddChild(img)
    else
        pcall(function() sb:SetHeightOverride(1.0) end)
        local line = StaticConstructObject(cls.Border, wt)
        UITheme.SetFill(line, UITheme.Colors.DividerLine)
        line:SetPadding({ Left = 0, Top = 0, Right = 0, Bottom = 0 })
        sb:AddChild(line)
    end
    return sb
end

function UITheme.MakeAccentBar(wt, cls, width, color)
    local sb = StaticConstructObject(cls.SizeBox, wt)
    pcall(function() sb:SetWidthOverride(width or 3.0) end)
    local bar = StaticConstructObject(cls.Border, wt)
    UITheme.StyleRoundedCard(bar, color or UITheme.Colors.Cyan, 2.0, nil, 0.0)
    bar:SetPadding({ Left = 0, Top = 0, Right = 0, Bottom = 0 })
    sb:AddChild(bar)
    return sb, bar
end

-- ============================================================================
-- NATIVE FMOD UI / GAMEPLAY AUDIO CUES (WITH SOUNDBASE FALLBACK)
-- ============================================================================

local FMOD_EVENT_PATHS = {
    Hover      = "/Game/FMOD/Events/SFX/UI/Cosmetics/SFX_UI_Cosmetic_Hover.SFX_UI_Cosmetic_Hover",
    Confirm    = "/Game/FMOD/Events/SFX/UI/Cosmetics/SFX_UI_Cosmetic_Equip.SFX_UI_Cosmetic_Equip",
    Tab        = "/Game/FMOD/Events/SFX/UI/Cosmetics/SFX_UI_Cosmetic_TabSelect.SFX_UI_Cosmetic_TabSelect",
    Back       = "/Game/FMOD/Events/SFX/UI/Cosmetics/SFX_UI_Cosmetic_Exit.SFX_UI_Cosmetic_Exit",
    Open       = "/Game/FMOD/Events/SFX/UI/Skill_Tree/SFX_UI_SkillTree_Open.SFX_UI_SkillTree_Open",
    Close      = "/Game/FMOD/Events/SFX/UI/Skill_Tree/SFX_UI_SkillTree_Close.SFX_UI_SkillTree_Close",
    Downed     = "/Game/FMOD/Events/SFX/UI/SFXE_UI_FeverBar_Empty.SFXE_UI_FeverBar_Empty",
    Revive     = "/Game/FMOD/Events/SFX/CIN/Intro_Cinematic/SFX_CIN_ZapRevive.SFX_CIN_ZapRevive",
    ReviveHeal = "/Game/FMOD/Events/SFX/ITEM/SFXE_ITEM_HealPack_Fat.SFXE_ITEM_HealPack_Fat",
    Join       = "/Game/FMOD/Events/SFX/UI/SFXE_UI_Perfect_PopUp.SFXE_UI_Perfect_PopUp",
}

local CachedFMODStatics = nil
local CachedFMODEvents = {}
local CachedUISounds = nil
local LastUISoundScan = 0.0

local SOUND_PATTERNS = {
    Hover   = { "ui_hover", "hover", "nav", "tick", "move", "focus" },
    Confirm = { "ui_confirm", "ui_select", "ui_click", "confirm", "accept", "equip" },
    Tab     = { "ui_tab", "tab", "switch", "page", "swipe" },
    Back    = { "ui_back", "ui_cancel", "ui_close", "cancel", "back" },
    Open    = { "ui_open", "menu_open", "ui_confirm", "ui_select" },
    Close   = { "ui_close", "ui_back", "ui_cancel", "menu_close" },
}

local SOUND_PITCH = {
    Hover = 1.08, Confirm = 1.00, Tab = 1.15, Back = 0.90, Open = 1.04, Close = 0.88,
}

local function TryPlayFMODEvent(kind, world)
    if not UObjectUtils.IsValid(world) then return false end
    if not UObjectUtils.IsValid(CachedFMODStatics) then
        pcall(function() CachedFMODStatics = StaticFindObject("/Script/FMODStudio.Default__FMODBlueprintStatics") end)
    end
    if not UObjectUtils.IsValid(CachedFMODStatics) then return false end

    local ev = CachedFMODEvents[kind]
    if ev == false then return false end
    if ev == nil then
        local path = FMOD_EVENT_PATHS[kind]
        if not path then
            CachedFMODEvents[kind] = false
            return false
        end
        pcall(function() ev = StaticFindObject(path) end)
        if not UObjectUtils.IsValid(ev) and type(LoadAsset) == "function" then
            local pkg = path:match("^([^%.]+)%.") or path
            pcall(function() LoadAsset(pkg) end)
            pcall(function() LoadAsset(path) end)
            pcall(function() ev = StaticFindObject(path) end)
        end
        CachedFMODEvents[kind] = UObjectUtils.IsValid(ev) and ev or false
        if not UObjectUtils.IsValid(ev) then return false end
    end

    local ok = pcall(function()
        CachedFMODStatics:PlayEvent2D(world, ev, true)
    end)
    return ok == true
end

local function DiscoverUISounds()
    local now = os.clock()
    if CachedUISounds and (now - LastUISoundScan) < 30.0 then return CachedUISounds end
    LastUISoundScan = now
    local found = {}
    pcall(function()
        local sounds = FindAllOf("SoundBase")
        if not sounds then return end
        for _, s in pairs(sounds) do
            if UObjectUtils.IsValid(s) then
                local fn = ""
                pcall(function() fn = s:GetFullName():lower() end)
                if (fn:find("/ui/", 1, true) or fn:find("ui_", 1, true) or fn:find("_ui", 1, true))
                    and not fn:find("music", 1, true)
                    and not fn:find("loop", 1, true)
                    and not fn:find("ambience", 1, true)
                    and not fn:find("voice", 1, true) then
                    for kind, pats in pairs(SOUND_PATTERNS) do
                        if not found[kind] then
                            for _, pat in ipairs(pats) do
                                if fn:find(pat, 1, true) then
                                    found[kind] = s
                                    break
                                end
                            end
                        end
                    end
                    if not found.Fallback then found.Fallback = s end
                end
            end
        end
    end)
    CachedUISounds = found
    return found
end

function UITheme.PlayUISound(kind, enabled)
    if enabled == false then return end
    pcall(function()
        local world = UObjectUtils.GetWorld()
        if not UObjectUtils.IsValid(world) then return end
        if TryPlayFMODEvent(kind, world) then return end

        local gs = UObjectUtils.GetGameplayStatics()
        if not UObjectUtils.IsValid(gs) then return end
        local sounds = DiscoverUISounds()
        local snd = (sounds and sounds[kind]) or (sounds and sounds.Fallback)
        if not UObjectUtils.IsValid(snd) then return end
        local vol = (kind == "Hover") and 0.42 or 0.62
        local pitch = SOUND_PITCH[kind] or 1.0
        gs:PlaySound2D(world, snd, vol, pitch, 0.0, nil, nil, true)
    end)
end

return UITheme
