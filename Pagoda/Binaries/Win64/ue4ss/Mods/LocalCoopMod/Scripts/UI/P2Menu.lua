-- 5-tab Player 2 customization and settings menu (Dive Bar full mode / mid-match paused mode).
-- Polls P2's controller exclusively while locking P2 gameplay input so P1 stays uninterrupted.

local UObjectUtils = require("Utils.UObjectUtils")
local Logger = require("Utils.Logger")
local Scheduler = require("Core.Scheduler")
local HookRegistry = require("Core.HookRegistry")
local SessionManager = require("Core.SessionManager")
local CatalogService = require("State.CatalogService")
local ProfileStore = require("State.ProfileStore")
local PlayerStateIsolation = require("State.PlayerStateIsolation")
local CharacterApplier = require("Characters.CharacterApplier")
local ViewportController = require("Camera.ViewportController")
local VanillaHUD = require("UI.VanillaHUD")
local InputRouting = require("Input.InputRouting")
local UITheme = require("UI.UITheme")

local P2Menu = {}

local Config = {}
local Callbacks = {}

local VISIBLE_ROWS = 8
local MAX_SUB_PILLS = 8
local LIMITED_TABS = { 1, 2, 5 }

local TAB_DEFS = {
    { Id = "character", Label = "CHARACTER", LimitedLabel = "MODELS",   Title = "CHARACTER CUSTOMIZATION", Accent = UITheme.Colors.Magenta, IconKey = "TabChar" },
    { Id = "moves",     Label = "MOVES",     LimitedLabel = "ATTACKS",  Title = "BOSS SKILLS & BUILDS",    Accent = UITheme.Colors.Cyan,    IconKey = "TabMoves" },
    { Id = "dances",    Label = "DANCES",    LimitedLabel = "DANCES",   Title = "D-PAD DANCE WHEEL",       Accent = UITheme.Colors.Gold,    IconKey = "TabDances" },
    { Id = "upgrades",  Label = "UPGRADES",  LimitedLabel = "UPGRADES", Title = "IDOL UPGRADES",           Accent = UITheme.Colors.Violet,  IconKey = "TabUpgrades" },
    { Id = "settings",  Label = "SETTINGS",  LimitedLabel = "SETTINGS", Title = "SETTINGS",                Accent = UITheme.Colors.Emerald, IconKey = "TabCoop" },
}

local CHARACTER_SUBS = {
    { Kind = "models",  Pill = "MODELS",  Label = "Character Models (Vanilla + CSM)" },
    { Kind = "presets", Pill = "OUTFITS", Label = "Outfit Presets" },
    { Kind = "slot",    Pill = "JACKETS", Label = "Jackets & Tops",          Slots = { 2 } },
    { Kind = "multi",   Pill = "HEAD",    Label = "Hair, Headgear & Glasses",Slots = { 5, 3 } },
    { Kind = "multi",   Pill = "GEAR",    Label = "Drumsticks & Body Type",  Slots = { 4, 1 } },
    { Kind = "tint",    Pill = "TINT",    Label = "P2 Rim Tint & Colors" },
}

local SLOT_DISCO_ACCENTS = {
    UITheme.Colors.Magenta,
    UITheme.Colors.Cyan,
    UITheme.Colors.Gold,
    UITheme.Colors.Emerald,
    UITheme.Colors.Violet,
}

local SLOT_SHORT_TAGS = {
    [1] = "BODY",
    [2] = "JACKET",
    [3] = "GLASSES",
    [4] = "STICKS",
    [5] = "HAIR",
}

local State = {
    IsOpen = false,
    IsClosing = false,
    IsLimitedMatchMode = false,
    PausedGameForMenu = false,
    PausedSongComps = {},
    AnimProgress = 0.0,
    TabIndex = 1,
    SubIndex = 1,
    SelectedIndex = 1,
    WindowStart = 1,
    Items = {},
    SubLabels = {},
    OpenedAt = 0.0,
    LastActivateAt = 0.0,
}

local UI = {
    Widget = nil,
    ModalBorder = nil,
    OwnerPC = nil,
    World = nil,
    PanelSlot = nil,
    AttachedHost = nil,

    NavBoxes = {},
    NavButtons = {},
    NavCards = {},
    NavBars = {},
    NavTexts = {},
    IsoPill = nil,
    IsoText = nil,

    SectionTitle = nil,
    CountText = nil,
    CloseBtn = nil,

    SlotGridWrap = nil,
    SlotButtons = {},
    SlotCardBoxes = {},
    SlotCards = {},
    SlotHeaders = {},
    SlotNames = {},
    SlotIconBoxes = {},
    SlotIcons = {},

    FilterBarWrap = nil,
    SubPrevBtn = nil,
    SubNextBtn = nil,
    SubPrevText = nil,
    SubNextText = nil,
    SubPillWraps = {},
    SubPillButtons = {},
    SubPillCards = {},
    SubPillTexts = {},

    RowBoxes = {},
    RowButtons = {},
    RowCards = {},
    RowBars = {},
    RowIconBoxes = {},
    RowIcons = {},
    RowNames = {},
    RowPillBgs = {},
    RowPillTexts = {},

    ScrollWrap = nil,
    ScrollUpBtn = nil,
    ScrollUpCard = nil,
    ScrollUpIcon = nil,
    ScrollUpText = nil,
    ScrollDownBtn = nil,
    ScrollDownCard = nil,
    ScrollDownIcon = nil,
    ScrollDownText = nil,
    ScrollThumbCard = nil,
    ScrollBeforeSlot = nil,
    ScrollThumbSlot = nil,
    ScrollAfterSlot = nil,

    DetailIconBox = nil,
    DetailIcon = nil,
    DetailPill = nil,
    DetailPillText = nil,
    DetailTitle = nil,
    DetailMeta = nil,
    DetailDesc = nil,

    EquipBtn = nil,
    EquipCard = nil,
    EquipText = nil,
    LegendText = nil,
}

local PrevInputs = {}
local HoldNextRepeat = {}
local PrevButtons = {}
local CachedKeyStructs = {}
local IconWarmupQueued = false

local function GetKeyStruct(kn)
    local ks = CachedKeyStructs[kn]
    if not ks then
        ks = { KeyName = FName(kn) }
        CachedKeyStructs[kn] = ks
    end
    return ks
end

function P2Menu.Init(config, callbacks)
    Config = config or {}
    Callbacks = callbacks or {}
    ViewportController.RegisterModWidget("P2Menu", function() return UI.Widget end)
end

function P2Menu.IsOpen()
    return State.IsOpen == true
end

function P2Menu.IsPausedByP2Menu()
    return State.IsOpen == true and State.PausedGameForMenu == true
end

-- ============================================================================
-- RESPONSIVE ANCHORS & SMOOTH OPEN / CLOSE TRANSITION
-- ============================================================================

local function UpdatePanelAnchors()
    if not UObjectUtils.IsValid(UI.PanelSlot) then return end
    local minX, minY, maxX, maxY
    if State.IsLimitedMatchMode then
        minX, minY, maxX, maxY = 0.140, 0.060, 0.860, 0.940
    else
        local mode = ViewportController.GetEffectiveScreenMode()
        minX, minY, maxX, maxY = 0.015, 0.020, 0.620, 0.980
        if mode == 1 then
            minX, minY, maxX, maxY = 0.020, 0.020, 0.980, 0.720
        elseif mode == 2 then
            minX, minY, maxX, maxY = 0.020, 0.040, 0.580, 0.960
        end
    end
    pcall(function()
        UI.PanelSlot:SetAnchors({ Minimum = { X = minX, Y = minY }, Maximum = { X = maxX, Y = maxY } })
        UI.PanelSlot:SetOffsets({ Left = 0, Top = 0, Right = 0, Bottom = 0 })
    end)
end

local function ApplyTransitionVisuals(alpha)
    if not UObjectUtils.IsValid(UI.ModalBorder) then return end
    local a = math.max(0.0, math.min(1.0, alpha or 1.0))
    local ease = 1.0 - ((1.0 - a) * (1.0 - a))
    local sc = 0.92 + 0.08 * ease
    pcall(function()
        UI.ModalBorder:SetRenderTransformPivot({ X = 0.5, Y = 0.5 })
        UI.ModalBorder:SetRenderScale({ X = sc, Y = sc })
        UI.ModalBorder:SetRenderOpacity(ease)
    end)
end

local function FinishCloseCleanup()
    State.IsClosing = false
    State.AnimProgress = 0.0
    if UObjectUtils.IsValid(UI.Widget) then
        pcall(function() UI.Widget:SetVisibility(1) end)
        pcall(function() UI.Widget:RemoveFromParent() end)
    end
end

function P2Menu.TickTransition(dt)
    if not (State.IsOpen or State.IsClosing) then return end
    local menuCfg = Config.P2Menu or {}
    local dur = math.max(0.02, tonumber(menuCfg.OpenTransitionDuration) or 0.14)
    local step = ((dt and dt > 0) and dt or 0.016) / dur

    if State.IsOpen and not State.IsClosing then
        if State.AnimProgress < 1.0 then
            State.AnimProgress = math.min(1.0, State.AnimProgress + step)
            ApplyTransitionVisuals(State.AnimProgress)
        end
    elseif State.IsClosing then
        State.AnimProgress = math.max(0.0, State.AnimProgress - step)
        ApplyTransitionVisuals(State.AnimProgress)
        if State.AnimProgress <= 0.0 then
            FinishCloseCleanup()
        end
    end
end

function P2Menu.DestroyWidget()
    if UObjectUtils.IsValid(UI.Widget) then
        pcall(function() UI.Widget:RemoveFromParent() end)
    end
    UI.Widget = nil
    UI.ModalBorder = nil
    UI.OwnerPC = nil
    UI.World = nil
    UI.PanelSlot = nil
    UI.AttachedHost = nil
    UI.NavBoxes, UI.NavButtons, UI.NavCards, UI.NavBars, UI.NavTexts = {}, {}, {}, {}, {}
    UI.SlotButtons, UI.SlotCardBoxes, UI.SlotCards, UI.SlotHeaders, UI.SlotNames = {}, {}, {}, {}, {}
    UI.SlotIconBoxes, UI.SlotIcons = {}, {}
    UI.SubPillWraps, UI.SubPillButtons, UI.SubPillCards, UI.SubPillTexts = {}, {}, {}, {}
    UI.RowBoxes, UI.RowButtons, UI.RowCards, UI.RowBars, UI.RowNames, UI.RowPillBgs, UI.RowPillTexts = {}, {}, {}, {}, {}, {}, {}
    UI.RowIconBoxes, UI.RowIcons = {}, {}
    UI.ScrollWrap, UI.ScrollThumbCard = nil, nil
    UI.ScrollUpBtn, UI.ScrollUpCard, UI.ScrollUpIcon, UI.ScrollUpText = nil, nil, nil, nil
    UI.ScrollDownBtn, UI.ScrollDownCard, UI.ScrollDownIcon, UI.ScrollDownText = nil, nil, nil, nil
    UI.ScrollBeforeSlot, UI.ScrollThumbSlot, UI.ScrollAfterSlot = nil, nil, nil
    UI.DetailIconBox, UI.DetailIcon, UI.LegendText = nil, nil, nil
    PrevButtons = {}
end

-- ============================================================================
-- WIDGET TREE CONSTRUCTION (860x560 SPACIOUS OVERFLOW-FREE DESIGN)
-- ============================================================================

local function EnsureBuilt(ownerPC)
    local inGameplay, world = UObjectUtils.IsGameplayWorld()
    if not (inGameplay and UObjectUtils.IsValid(world) and UObjectUtils.IsLive(ownerPC)) then return false end
    if UObjectUtils.IsValid(UI.Widget) and UObjectUtils.Same(UI.OwnerPC, ownerPC) and UObjectUtils.Same(UI.World, world) then
        UpdatePanelAnchors()
        return true
    end

    P2Menu.DestroyWidget()
    local cls = UITheme.GetUMGClasses()
    if not cls then return false end

    local ok, built = pcall(function()
        local uw = cls.WBL:Create(world, cls.Widget, ownerPC)
        if not (UObjectUtils.IsValid(uw) and UObjectUtils.IsValid(uw.WidgetTree)) then return false end
        local wt = uw.WidgetTree
        local root = StaticConstructObject(cls.Canvas, wt)
        wt.RootWidget = root

        local designBox = StaticConstructObject(cls.SizeBox, wt)
        pcall(function()
            designBox:SetWidthOverride(860.0)
            designBox:SetHeightOverride(560.0)
        end)

        local canvasChild = designBox
        if UObjectUtils.IsValid(cls.ScaleBox) then
            local scaleBox = StaticConstructObject(cls.ScaleBox, wt)
            pcall(function() scaleBox:SetStretch(2) end)          -- ScaleToFit
            pcall(function() scaleBox:SetStretchDirection(0) end) -- Both
            scaleBox:AddChild(designBox)
            canvasChild = scaleBox
        end

        local modal = StaticConstructObject(cls.Border, wt)
        UITheme.StyleDiscoFrame(modal, UITheme.Colors.PanelBackdrop, UITheme.Colors.MarqueePink, 2.5, 4.0)
        modal:SetPadding({ Left = 0, Top = 0, Right = 0, Bottom = 0 })
        designBox:AddChild(modal)
        UI.ModalBorder = modal

        local panelSlot = root:AddChildToCanvas(canvasChild)
        UI.PanelSlot = panelSlot
        UpdatePanelAnchors()
        pcall(function() panelSlot:SetZOrder(60) end)

        local rootV = StaticConstructObject(cls.VBox, wt)
        local halftoneTex = UITheme.GetNativeTexture("HalftoneBL")
        if UObjectUtils.IsValid(cls.Overlay) and UObjectUtils.IsValid(cls.Image) and UObjectUtils.IsValid(halftoneTex) then
            local modalOv = StaticConstructObject(cls.Overlay, wt)
            modal:SetContent(modalOv)

            local htImg = StaticConstructObject(cls.Image, wt)
            pcall(function()
                htImg:SetBrushFromTexture(halftoneTex, false)
                htImg:SetColorAndOpacity({ R = 0.85, G = 0.14, B = 0.65, A = 0.16 })
            end)
            local htSlot = modalOv:AddChildToOverlay(htImg)
            pcall(function() htSlot:SetHorizontalAlignment(0); htSlot:SetVerticalAlignment(0) end)

            local rvSlot = modalOv:AddChildToOverlay(rootV)
            pcall(function() rvSlot:SetHorizontalAlignment(0); rvSlot:SetVerticalAlignment(0) end)
        else
            modal:SetContent(rootV)
        end

        local stripBox = StaticConstructObject(cls.SizeBox, wt)
        pcall(function() stripBox:SetHeightOverride(4.0) end)
        local stripH = StaticConstructObject(cls.HBox, wt)
        stripBox:AddChild(stripH)
        for _, col in ipairs({ UITheme.Colors.Magenta, UITheme.Colors.Gold, UITheme.Colors.Cyan }) do
            local seg = StaticConstructObject(cls.Border, wt)
            UITheme.SetFill(seg, col)
            seg:SetPadding({ Left = 0, Top = 0, Right = 0, Bottom = 0 })
            local segS = stripH:AddChildToHorizontalBox(seg)
            pcall(function() segS:SetSize({ Value = 1.0, SizeRule = 1 }) end)
        end
        rootV:AddChildToVerticalBox(stripBox)

        local splitH = StaticConstructObject(cls.HBox, wt)
        local shSlot = rootV:AddChildToVerticalBox(splitH)
        pcall(function() shSlot:SetSize({ Value = 1.0, SizeRule = 1 }) end)

        -- Left Navigation Rail
        local railWrap = StaticConstructObject(cls.SizeBox, wt)
        pcall(function() railWrap:SetWidthOverride(184.0) end)
        splitH:AddChildToHorizontalBox(railWrap)

        local rail = StaticConstructObject(cls.Border, wt)
        UITheme.StyleDiscoFrame(rail, UITheme.Colors.RailBackdrop, UITheme.Colors.HairlineSubtle, 1.0, 3.0)
        rail:SetPadding({ Left = 11, Top = 12, Right = 11, Bottom = 10 })
        railWrap:AddChild(rail)

        local railV = StaticConstructObject(cls.VBox, wt)
        rail:SetContent(railV)

        local brandHdrH = StaticConstructObject(cls.HBox, wt)
        UITheme.ApplyNativeSkew(brandHdrH, -6.0)
        local bhSlot = railV:AddChildToVerticalBox(brandHdrH)
        pcall(function() bhSlot:SetPadding({ Left = 0, Top = 0, Right = 0, Bottom = 1 }) end)

        local shardTex = UITheme.GetNativeTexture("Shard")
        if UObjectUtils.IsValid(shardTex) and UObjectUtils.IsValid(cls.Image) then
            local shBox = StaticConstructObject(cls.SizeBox, wt)
            pcall(function() shBox:SetWidthOverride(13.0); shBox:SetHeightOverride(13.0) end)
            local shImg = StaticConstructObject(cls.Image, wt)
            pcall(function() shImg:SetBrushFromTexture(shardTex, false); shImg:SetColorAndOpacity(UITheme.Colors.Magenta) end)
            shBox:AddChild(shImg)
            local shS = brandHdrH:AddChildToHorizontalBox(shBox)
            pcall(function() shS:SetVerticalAlignment(2); shS:SetPadding({ Left = 0, Top = 0, Right = 5, Bottom = 0 }) end)
        end

        local brandTxt = StaticConstructObject(cls.Text, wt)
        UITheme.StyleText(brandTxt, 13, UITheme.Fonts.Primary, UITheme.Colors.Gold, false)
        UITheme.SetText(brandTxt, "PLAYER 2")
        local btS1 = brandHdrH:AddChildToHorizontalBox(brandTxt)
        pcall(function() btS1:SetVerticalAlignment(2) end)

        local brandTxt2 = StaticConstructObject(cls.Text, wt)
        UITheme.StyleText(brandTxt2, 13, UITheme.Fonts.Primary, UITheme.Colors.TextPrimary, false)
        UITheme.SetText(brandTxt2, "MENU")
        UITheme.ApplyNativeSkew(brandTxt2, -6.0)
        local btS2 = railV:AddChildToVerticalBox(brandTxt2)
        pcall(function() btS2:SetPadding({ Left = 0, Top = 0, Right = 0, Bottom = 2 }) end)

        local subBrand = StaticConstructObject(cls.Text, wt)
        UITheme.StyleText(subBrand, 8, UITheme.Fonts.Secondary, UITheme.Colors.Magenta, false)
        UITheme.SetText(subBrand, "DEAD AS DISCO CO-OP")
        local sbS = railV:AddChildToVerticalBox(subBrand)
        pcall(function() sbS:SetPadding({ Left = 0, Top = 0, Right = 0, Bottom = 8 }) end)

        local railDiv = UITheme.MakeDivider(wt, cls)
        local rdS = railV:AddChildToVerticalBox(railDiv)
        pcall(function() rdS:SetPadding({ Left = 0, Top = 0, Right = 0, Bottom = 8 }) end)

        local navListV = StaticConstructObject(cls.VBox, wt)
        local nlS = railV:AddChildToVerticalBox(navListV)
        pcall(function() nlS:SetSize({ Value = 1.0, SizeRule = 1 }) end)

        for i, tDef in ipairs(TAB_DEFS) do
            local nBox = StaticConstructObject(cls.SizeBox, wt)
            pcall(function() nBox:SetHeightOverride(35.0) end)

            local nBtn, nCard = UITheme.MakeCleanButtonCard(
                wt, cls, UITheme.Colors.Transparent, 3.0, UITheme.Colors.Transparent, 0.0, 6, 4, 8, 4
            )
            nBox:AddChild(nBtn)

            local nH = StaticConstructObject(cls.HBox, wt)
            nCard:SetContent(nH)

            local barBox, bar = UITheme.MakeAccentBar(wt, cls, 3.5, UITheme.Colors.Transparent)
            local bS = nH:AddChildToHorizontalBox(barBox)
            pcall(function() bS:SetPadding({ Left = 0, Top = 2, Right = 7, Bottom = 2 }) end)

            local tabTex = tDef.IconKey and UITheme.GetNativeTexture(tDef.IconKey) or nil
            if UObjectUtils.IsValid(tabTex) and UObjectUtils.IsValid(cls.Image) then
                local tiBox = StaticConstructObject(cls.SizeBox, wt)
                pcall(function() tiBox:SetWidthOverride(16.0); tiBox:SetHeightOverride(16.0) end)
                local tiImg = StaticConstructObject(cls.Image, wt)
                pcall(function() tiImg:SetBrushFromTexture(tabTex, false); tiImg:SetColorAndOpacity(tDef.Accent or UITheme.Colors.TextSecondary) end)
                tiBox:AddChild(tiImg)
                local tiS = nH:AddChildToHorizontalBox(tiBox)
                pcall(function() tiS:SetVerticalAlignment(2); tiS:SetPadding({ Left = 0, Top = 0, Right = 6, Bottom = 0 }) end)
            end

            local nTxt = StaticConstructObject(cls.Text, wt)
            UITheme.StyleText(nTxt, 10, UITheme.Fonts.Secondary, UITheme.Colors.TextSecondary, false)
            UITheme.SetText(nTxt, tDef.Label)
            local tS = nH:AddChildToHorizontalBox(nTxt)
            pcall(function() tS:SetSize({ Value = 1.0, SizeRule = 1 }); tS:SetVerticalAlignment(2) end)

            local vSlot = navListV:AddChildToVerticalBox(nBox)
            pcall(function() vSlot:SetPadding({ Left = 0, Top = 0, Right = 0, Bottom = 4 }) end)

            UI.NavBoxes[i] = nBox
            UI.NavButtons[i] = nBtn
            UI.NavCards[i] = nCard
            UI.NavBars[i] = bar
            UI.NavTexts[i] = nTxt
        end

        local lbCue = StaticConstructObject(cls.Text, wt)
        UITheme.StyleText(lbCue, 8, UITheme.Fonts.Secondary, UITheme.Colors.TextMuted, false, 1)
        UITheme.SetText(lbCue, "LB / RB  TABS")
        local lbS = railV:AddChildToVerticalBox(lbCue)
        pcall(function() lbS:SetPadding({ Left = 0, Top = 4, Right = 0, Bottom = 5 }) end)

        local isoPill, isoTxt = UITheme.MakePillBadge(wt, cls, "PAUSED | MATCH", UITheme.Colors.GoldSoft, UITheme.Colors.Gold, 8)
        railV:AddChildToVerticalBox(isoPill)
        pcall(function() isoPill:SetVisibility(1) end) -- Hidden unless in-match paused mode
        UI.IsoPill = isoPill
        UI.IsoText = isoTxt

        -- Right Workspace
        local workPad = StaticConstructObject(cls.Border, wt)
        UITheme.SetFill(workPad, UITheme.Colors.Transparent)
        workPad:SetPadding({ Left = 14, Top = 10, Right = 14, Bottom = 10 })
        local workSlot = splitH:AddChildToHorizontalBox(workPad)
        pcall(function() workSlot:SetSize({ Value = 1.0, SizeRule = 1 }) end)

        local workV = StaticConstructObject(cls.VBox, wt)
        workPad:SetContent(workV)

        -- Header
        local hdrBox = StaticConstructObject(cls.SizeBox, wt)
        pcall(function() hdrBox:SetHeightOverride(26.0) end)
        local hdrSlot = workV:AddChildToVerticalBox(hdrBox)
        pcall(function() hdrSlot:SetPadding({ Left = 0, Top = 0, Right = 0, Bottom = 5 }) end)

        local hdrH = StaticConstructObject(cls.HBox, wt)
        hdrBox:AddChild(hdrH)

        local secTitle = StaticConstructObject(cls.Text, wt)
        UITheme.StyleText(secTitle, 14, UITheme.Fonts.Primary, UITheme.Colors.Gold, false)
        UITheme.ApplyNativeSkew(secTitle, -5.0)
        UITheme.SetText(secTitle, "CHARACTERS")
        local stS = hdrH:AddChildToHorizontalBox(secTitle)
        pcall(function() stS:SetSize({ Value = 1.0, SizeRule = 1 }); stS:SetVerticalAlignment(2) end)
        UI.SectionTitle = secTitle

        local cntTxt = StaticConstructObject(cls.Text, wt)
        UITheme.StyleText(cntTxt, 9, UITheme.Fonts.Secondary, UITheme.Colors.TextMuted, false)
        UITheme.SetText(cntTxt, "1 / 1")
        local cnS = hdrH:AddChildToHorizontalBox(cntTxt)
        pcall(function() cnS:SetVerticalAlignment(2); cnS:SetPadding({ Left = 0, Top = 0, Right = 10, Bottom = 0 }) end)
        UI.CountText = cntTxt

        local closeBtn, closeCard = UITheme.MakeCleanButtonCard(
            wt, cls, UITheme.Colors.SurfaceCard, 3.0, UITheme.Colors.HairlineSubtle, 1.0, 9, 3, 9, 3
        )
        local closeTxt = StaticConstructObject(cls.Text, wt)
        UITheme.StyleText(closeTxt, 8, UITheme.Fonts.Secondary, UITheme.Colors.TextSecondary, false)
        UITheme.SetText(closeTxt, "B  CLOSE")
        closeCard:SetContent(closeTxt)
        local clS = hdrH:AddChildToHorizontalBox(closeBtn)
        pcall(function() clS:SetVerticalAlignment(2) end)
        UI.CloseBtn = closeBtn

        -- Visual 4-Direction Equip Diamond (Tabs 2 & 3)
        local sgBox = StaticConstructObject(cls.SizeBox, wt)
        pcall(function() sgBox:SetHeightOverride(86.0) end)
        local sgSlot = workV:AddChildToVerticalBox(sgBox)
        pcall(function() sgSlot:SetPadding({ Left = 0, Top = 0, Right = 0, Bottom = 5 }) end)
        UI.SlotGridWrap = sgBox

        local diamondV = StaticConstructObject(cls.VBox, wt)
        sgBox:AddChild(diamondV)

        local function BuildDiamondNode(nodeIdx)
            local nBtn, nCard = UITheme.MakeCleanButtonCard(
                wt, cls, UITheme.Colors.SurfaceCard, 6.0, UITheme.Colors.HairlineSubtle, 1.0, 6, 3, 6, 3
            )
            local nH = StaticConstructObject(cls.HBox, wt)
            nCard:SetContent(nH)

            local iconBox, iconImg = nil, nil
            if UObjectUtils.IsValid(cls.Image) then
                iconBox = StaticConstructObject(cls.SizeBox, wt)
                pcall(function() iconBox:SetWidthOverride(24.0); iconBox:SetHeightOverride(24.0) end)
                iconImg = StaticConstructObject(cls.Image, wt)
                iconBox:AddChild(iconImg)
                pcall(function() iconBox:SetVisibility(1) end)
                local iS = nH:AddChildToHorizontalBox(iconBox)
                pcall(function() iS:SetVerticalAlignment(2); iS:SetPadding({ Left = 0, Top = 0, Right = 5, Bottom = 0 }) end)
            end

            local txtV = StaticConstructObject(cls.VBox, wt)
            local tvS = nH:AddChildToHorizontalBox(txtV)
            pcall(function() tvS:SetSize({ Value = 1.0, SizeRule = 1 }); tvS:SetVerticalAlignment(2) end)

            local sHdr = StaticConstructObject(cls.Text, wt)
            UITheme.StyleText(sHdr, 7, UITheme.Fonts.Secondary, UITheme.Colors.TextMuted, false)
            txtV:AddChildToVerticalBox(sHdr)

            local sName = StaticConstructObject(cls.Text, wt)
            UITheme.StyleText(sName, 8, UITheme.Fonts.Body, UITheme.Colors.TextPrimary, false)
            txtV:AddChildToVerticalBox(sName)

            UI.SlotButtons[nodeIdx] = nBtn
            UI.SlotCardBoxes[nodeIdx] = nBtn
            UI.SlotCards[nodeIdx] = nCard
            UI.SlotHeaders[nodeIdx] = sHdr
            UI.SlotNames[nodeIdx] = sName
            UI.SlotIconBoxes[nodeIdx] = iconBox
            UI.SlotIcons[nodeIdx] = iconImg
            return nBtn
        end

        local function AddSpacer(hbox, weight)
            local sp = StaticConstructObject(cls.Border, wt)
            UITheme.SetFill(sp, UITheme.Colors.Transparent)
            sp:SetPadding({ Left = 0, Top = 0, Right = 0, Bottom = 0 })
            local spS = hbox:AddChildToHorizontalBox(sp)
            pcall(function() spS:SetSize({ Value = weight or 0.5, SizeRule = 1 }) end)
        end

        local rowTop = StaticConstructObject(cls.HBox, wt)
        local rtS = diamondV:AddChildToVerticalBox(rowTop)
        pcall(function() rtS:SetSize({ Value = 1.0, SizeRule = 1 }); rtS:SetPadding({ Left = 0, Top = 0, Right = 0, Bottom = 2 }) end)
        AddSpacer(rowTop, 0.55)
        local topNode = BuildDiamondNode(1)
        local tnS = rowTop:AddChildToHorizontalBox(topNode)
        pcall(function() tnS:SetSize({ Value = 1.30, SizeRule = 1 }) end)
        AddSpacer(rowTop, 0.55)

        local rowMid = StaticConstructObject(cls.HBox, wt)
        local rmS = diamondV:AddChildToVerticalBox(rowMid)
        pcall(function() rmS:SetSize({ Value = 1.0, SizeRule = 1 }); rmS:SetPadding({ Left = 0, Top = 0, Right = 0, Bottom = 2 }) end)
        local leftNode = BuildDiamondNode(4)
        local lnS = rowMid:AddChildToHorizontalBox(leftNode)
        pcall(function() lnS:SetSize({ Value = 1.15, SizeRule = 1 }); lnS:SetPadding({ Left = 0, Top = 0, Right = 3, Bottom = 0 }) end)
        local hubNode = BuildDiamondNode(5)
        local hnS = rowMid:AddChildToHorizontalBox(hubNode)
        pcall(function() hnS:SetSize({ Value = 0.85, SizeRule = 1 }); hnS:SetPadding({ Left = 2, Top = 0, Right = 2, Bottom = 0 }) end)
        local rightNode = BuildDiamondNode(2)
        local rnSlot = rowMid:AddChildToHorizontalBox(rightNode)
        pcall(function() rnSlot:SetSize({ Value = 1.15, SizeRule = 1 }); rnSlot:SetPadding({ Left = 3, Top = 0, Right = 0, Bottom = 0 }) end)

        local rowBot = StaticConstructObject(cls.HBox, wt)
        local rbSlot = diamondV:AddChildToVerticalBox(rowBot)
        pcall(function() rbSlot:SetSize({ Value = 1.0, SizeRule = 1 }) end)
        AddSpacer(rowBot, 0.55)
        local botNode = BuildDiamondNode(3)
        local bnS = rowBot:AddChildToHorizontalBox(botNode)
        pcall(function() bnS:SetSize({ Value = 1.30, SizeRule = 1 }) end)
        AddSpacer(rowBot, 0.55)

        -- Sub-Category Pill Strip (Tabs 1, 4, 5)
        local fBox = StaticConstructObject(cls.SizeBox, wt)
        pcall(function() fBox:SetHeightOverride(30.0) end)
        local fSlot = workV:AddChildToVerticalBox(fBox)
        pcall(function() fSlot:SetPadding({ Left = 0, Top = 0, Right = 0, Bottom = 5 }) end)
        UI.FilterBarWrap = fBox

        local filterCard = StaticConstructObject(cls.Border, wt)
        UITheme.StyleDiscoFrame(filterCard, UITheme.Colors.SurfaceCard, UITheme.Colors.HairlineSubtle, 1.0, 3.0)
        filterCard:SetPadding({ Left = 4, Top = 3, Right = 4, Bottom = 3 })
        fBox:AddChild(filterCard)

        local filtH = StaticConstructObject(cls.HBox, wt)
        filterCard:SetContent(filtH)

        local prevBtn, prevCard = UITheme.MakeCleanButtonCard(
            wt, cls, UITheme.Colors.SurfaceRaised, 3.0, UITheme.Colors.HairlineSubtle, 0.8, 6, 2, 6, 2
        )
        local prevTxt = StaticConstructObject(cls.Text, wt)
        UITheme.StyleText(prevTxt, 7, UITheme.Fonts.Secondary, UITheme.Colors.Cyan, false)
        UITheme.SetText(prevTxt, "LT")
        prevCard:SetContent(prevTxt)
        local prS = filtH:AddChildToHorizontalBox(prevBtn)
        pcall(function() prS:SetVerticalAlignment(2); prS:SetPadding({ Left = 0, Top = 0, Right = 4, Bottom = 0 }) end)
        UI.SubPrevBtn = prevBtn
        UI.SubPrevText = prevTxt

        for p = 1, MAX_SUB_PILLS do
            local pBtn, pCard = UITheme.MakeCleanButtonCard(
                wt, cls, UITheme.Colors.Transparent, 3.0, UITheme.Colors.Transparent, 1.0, 4, 2, 4, 2
            )
            local pTxt = StaticConstructObject(cls.Text, wt)
            UITheme.StyleText(pTxt, 8, UITheme.Fonts.Secondary, UITheme.Colors.TextSecondary, false, 1)
            UITheme.SetText(pTxt, "")
            pCard:SetContent(pTxt)

            local pSlot = filtH:AddChildToHorizontalBox(pBtn)
            pcall(function()
                pSlot:SetSize({ Value = 1.0, SizeRule = 1 })
                pSlot:SetVerticalAlignment(2)
                pSlot:SetPadding({ Left = 1.5, Top = 0, Right = 1.5, Bottom = 0 })
            end)

            UI.SubPillWraps[p] = pBtn
            UI.SubPillButtons[p] = pBtn
            UI.SubPillCards[p] = pCard
            UI.SubPillTexts[p] = pTxt
        end

        local nextBtn, nextCard = UITheme.MakeCleanButtonCard(
            wt, cls, UITheme.Colors.SurfaceRaised, 3.0, UITheme.Colors.HairlineSubtle, 0.8, 6, 2, 6, 2
        )
        local nextTxt = StaticConstructObject(cls.Text, wt)
        UITheme.StyleText(nextTxt, 7, UITheme.Fonts.Secondary, UITheme.Colors.Cyan, false)
        UITheme.SetText(nextTxt, "RT")
        nextCard:SetContent(nextTxt)
        local nxS = filtH:AddChildToHorizontalBox(nextBtn)
        pcall(function() nxS:SetVerticalAlignment(2); nxS:SetPadding({ Left = 4, Top = 0, Right = 0, Bottom = 0 }) end)
        UI.SubNextBtn = nextBtn
        UI.SubNextText = nextTxt

        -- Item List Cards + Vertical Scrollbar Rail with Up / Down Arrows
        local listRowH = StaticConstructObject(cls.HBox, wt)
        local listRowSlot = workV:AddChildToVerticalBox(listRowH)
        pcall(function() listRowSlot:SetSize({ Value = 1.0, SizeRule = 1 }); listRowSlot:SetPadding({ Left = 0, Top = 0, Right = 0, Bottom = 5 }) end)

        local listV = StaticConstructObject(cls.VBox, wt)
        local listSlot = listRowH:AddChildToHorizontalBox(listV)
        pcall(function() listSlot:SetSize({ Value = 1.0, SizeRule = 1 }); listSlot:SetVerticalAlignment(0) end)

        for r = 1, VISIBLE_ROWS do
            local rBox = StaticConstructObject(cls.SizeBox, wt)
            pcall(function() rBox:SetHeightOverride(33.0) end)

            local rBtn, rCard = UITheme.MakeCleanButtonCard(
                wt, cls, UITheme.Colors.SurfaceCard, 3.0, UITheme.Colors.HairlineSubtle, 1.0, 9, 3, 10, 3
            )
            rBox:AddChild(rBtn)

            local rH = StaticConstructObject(cls.HBox, wt)
            rCard:SetContent(rH)

            local barBox, rBar = UITheme.MakeAccentBar(wt, cls, 3.5, UITheme.Colors.Transparent)
            local rbS = rH:AddChildToHorizontalBox(barBox)
            pcall(function() rbS:SetPadding({ Left = 0, Top = 2, Right = 8, Bottom = 2 }) end)

            local rIconBox, rIcon = nil, nil
            if UObjectUtils.IsValid(cls.Image) then
                rIconBox = StaticConstructObject(cls.SizeBox, wt)
                pcall(function() rIconBox:SetWidthOverride(22.0); rIconBox:SetHeightOverride(22.0) end)
                rIcon = StaticConstructObject(cls.Image, wt)
                rIconBox:AddChild(rIcon)
                pcall(function() rIconBox:SetVisibility(1) end)
                local riS = rH:AddChildToHorizontalBox(rIconBox)
                pcall(function() riS:SetVerticalAlignment(2); riS:SetPadding({ Left = 0, Top = 0, Right = 8, Bottom = 0 }) end)
            end

            local rName = StaticConstructObject(cls.Text, wt)
            UITheme.StyleText(rName, 10, UITheme.Fonts.Body, UITheme.Colors.TextPrimary, false)
            local rnS = rH:AddChildToHorizontalBox(rName)
            pcall(function() rnS:SetSize({ Value = 1.0, SizeRule = 1 }); rnS:SetVerticalAlignment(2) end)

            local pillBg, pillTxt = UITheme.MakePillBadge(wt, cls, "", UITheme.Colors.Transparent, UITheme.Colors.TextMuted, 8)
            local pS = rH:AddChildToHorizontalBox(pillBg)
            pcall(function() pS:SetVerticalAlignment(2) end)

            local rvS = listV:AddChildToVerticalBox(rBox)
            pcall(function() rvS:SetPadding({ Left = 0, Top = 0, Right = 0, Bottom = (r < VISIBLE_ROWS) and 3 or 0 }) end)

            UI.RowBoxes[r] = rBox
            UI.RowButtons[r] = rBtn
            UI.RowCards[r] = rCard
            UI.RowBars[r] = rBar
            UI.RowIconBoxes[r] = rIconBox
            UI.RowIcons[r] = rIcon
            UI.RowNames[r] = rName
            UI.RowPillBgs[r] = pillBg
            UI.RowPillTexts[r] = pillTxt
        end

        -- Vertical Scrollbar Column with Up / Down Arrows
        local vScrollWrap = StaticConstructObject(cls.SizeBox, wt)
        pcall(function() vScrollWrap:SetWidthOverride(22.0) end)
        local vsSlot = listRowH:AddChildToHorizontalBox(vScrollWrap)
        pcall(function() vsSlot:SetVerticalAlignment(0); vsSlot:SetPadding({ Left = 7, Top = 0, Right = 0, Bottom = 0 }) end)
        UI.ScrollWrap = vScrollWrap

        local vScrollV = StaticConstructObject(cls.VBox, wt)
        vScrollWrap:AddChild(vScrollV)

        local shardTexArrow = UITheme.GetNativeTexture("Shard")
        local function BuildScrollArrowBtn(isUp)
            local aBox = StaticConstructObject(cls.SizeBox, wt)
            pcall(function() aBox:SetHeightOverride(20.0); aBox:SetWidthOverride(22.0) end)
            local aBtn, aCard = UITheme.MakeCleanButtonCard(
                wt, cls, UITheme.Colors.SurfaceCard, 3.0, UITheme.Colors.HairlineSubtle, 1.0, 2, 2, 2, 2
            )
            aBox:AddChild(aBtn)

            local iconImg, arrowTxt = nil, nil
            if UObjectUtils.IsValid(shardTexArrow) and UObjectUtils.IsValid(cls.Image) then
                local iBox = StaticConstructObject(cls.SizeBox, wt)
                pcall(function() iBox:SetWidthOverride(10.0); iBox:SetHeightOverride(10.0) end)
                iconImg = StaticConstructObject(cls.Image, wt)
                pcall(function()
                    iconImg:SetBrushFromTexture(shardTexArrow, false)
                    iconImg:SetColorAndOpacity(UITheme.Colors.Cyan)
                    iconImg:SetRenderTransformPivot({ X = 0.5, Y = 0.5 })
                    iconImg:SetRenderTransformAngle(isUp and 0.0 or 180.0)
                end)
                iBox:AddChild(iconImg)
                if UObjectUtils.IsValid(cls.Overlay) then
                    local aOv = StaticConstructObject(cls.Overlay, wt)
                    aCard:SetContent(aOv)
                    local s = aOv:AddChildToOverlay(iBox)
                    pcall(function() s:SetHorizontalAlignment(2); s:SetVerticalAlignment(2) end)
                else
                    aCard:SetContent(iBox)
                end
            else
                arrowTxt = StaticConstructObject(cls.Text, wt)
                UITheme.StyleText(arrowTxt, 9, UITheme.Fonts.Secondary, UITheme.Colors.Cyan, false, 1)
                UITheme.SetText(arrowTxt, isUp and "^" or "v")
                aCard:SetContent(arrowTxt)
            end
            return aBox, aBtn, aCard, iconImg, arrowTxt
        end

        local upBox, upBtn, upCard, upIcon, upTxt = BuildScrollArrowBtn(true)
        local upSlot = vScrollV:AddChildToVerticalBox(upBox)
        pcall(function() upSlot:SetHorizontalAlignment(2); upSlot:SetPadding({ Left = 0, Top = 0, Right = 0, Bottom = 3 }) end)
        UI.ScrollUpBtn = upBtn
        UI.ScrollUpCard = upCard
        UI.ScrollUpIcon = upIcon
        UI.ScrollUpText = upTxt

        local trackOuter = StaticConstructObject(cls.Border, wt)
        UITheme.SetFill(trackOuter, UITheme.Colors.Transparent)
        trackOuter:SetPadding({ Left = 6, Top = 0, Right = 6, Bottom = 0 })
        local trkOutSlot = vScrollV:AddChildToVerticalBox(trackOuter)
        pcall(function() trkOutSlot:SetSize({ Value = 1.0, SizeRule = 1 }); trkOutSlot:SetHorizontalAlignment(0) end)

        local scrollTrack = StaticConstructObject(cls.Border, wt)
        UITheme.StyleDiscoFrame(scrollTrack, UITheme.Colors.TrackDark, UITheme.Colors.HairlineSubtle, 0.9, 2.0)
        scrollTrack:SetPadding({ Left = 1, Top = 1, Right = 1, Bottom = 1 })
        trackOuter:SetContent(scrollTrack)

        local scrollV = StaticConstructObject(cls.VBox, wt)
        scrollTrack:SetContent(scrollV)

        local sBefore = StaticConstructObject(cls.Border, wt)
        UITheme.SetFill(sBefore, UITheme.Colors.Transparent)
        sBefore:SetPadding({ Left = 0, Top = 0, Right = 0, Bottom = 0 })
        UI.ScrollBeforeSlot = scrollV:AddChildToVerticalBox(sBefore)

        local sThumb = StaticConstructObject(cls.Border, wt)
        UITheme.StyleRoundedCard(sThumb, UITheme.Colors.Cyan, 2.0, nil, 0.0)
        sThumb:SetPadding({ Left = 0, Top = 0, Right = 0, Bottom = 0 })
        UI.ScrollThumbSlot = scrollV:AddChildToVerticalBox(sThumb)
        UI.ScrollThumbCard = sThumb

        local sAfter = StaticConstructObject(cls.Border, wt)
        UITheme.SetFill(sAfter, UITheme.Colors.Transparent)
        sAfter:SetPadding({ Left = 0, Top = 0, Right = 0, Bottom = 0 })
        UI.ScrollAfterSlot = scrollV:AddChildToVerticalBox(sAfter)

        local dnBox, dnBtn, dnCard, dnIcon, dnTxt = BuildScrollArrowBtn(false)
        local dnSlot = vScrollV:AddChildToVerticalBox(dnBox)
        pcall(function() dnSlot:SetHorizontalAlignment(2); dnSlot:SetPadding({ Left = 0, Top = 3, Right = 0, Bottom = 0 }) end)
        UI.ScrollDownBtn = dnBtn
        UI.ScrollDownCard = dnCard
        UI.ScrollDownIcon = dnIcon
        UI.ScrollDownText = dnTxt

        -- Inspector Card (ClipToBounds keeps long descriptions contained)
        local inspBox = StaticConstructObject(cls.SizeBox, wt)
        pcall(function() inspBox:SetHeightOverride(82.0) end)
        local inSlot = workV:AddChildToVerticalBox(inspBox)
        pcall(function() inSlot:SetPadding({ Left = 0, Top = 0, Right = 0, Bottom = 5 }) end)

        local insp = StaticConstructObject(cls.Border, wt)
        UITheme.StyleDiscoFrame(insp, UITheme.Colors.SurfaceCard, UITheme.Colors.HairlineSubtle, 1.2, 3.0)
        insp:SetPadding({ Left = 11, Top = 7, Right = 11, Bottom = 7 })
        pcall(function() insp:SetClipping(1) end) -- ClipToBounds
        inspBox:AddChild(insp)

        local inspOuterH = StaticConstructObject(cls.HBox, wt)
        insp:SetContent(inspOuterH)

        if UObjectUtils.IsValid(cls.Image) then
            local dIconBox = StaticConstructObject(cls.SizeBox, wt)
            pcall(function() dIconBox:SetWidthOverride(42.0); dIconBox:SetHeightOverride(42.0) end)
            local dIcon = StaticConstructObject(cls.Image, wt)
            dIconBox:AddChild(dIcon)
            pcall(function() dIconBox:SetVisibility(1) end)
            local diS = inspOuterH:AddChildToHorizontalBox(dIconBox)
            pcall(function() diS:SetVerticalAlignment(2); diS:SetPadding({ Left = 0, Top = 0, Right = 10, Bottom = 0 }) end)
            UI.DetailIconBox = dIconBox
            UI.DetailIcon = dIcon
        end

        local inspV = StaticConstructObject(cls.VBox, wt)
        local ivS = inspOuterH:AddChildToHorizontalBox(inspV)
        pcall(function() ivS:SetSize({ Value = 1.0, SizeRule = 1 }); ivS:SetVerticalAlignment(2) end)

        local inspTopH = StaticConstructObject(cls.HBox, wt)
        local itSlot = inspV:AddChildToVerticalBox(inspTopH)
        pcall(function() itSlot:SetPadding({ Left = 0, Top = 0, Right = 0, Bottom = 3 }) end)

        local dPill, dPillTxt = UITheme.MakePillBadge(wt, cls, "INFO", UITheme.Colors.CyanSoft, UITheme.Colors.Cyan, 7)
        local dpS = inspTopH:AddChildToHorizontalBox(dPill)
        pcall(function() dpS:SetVerticalAlignment(2); dpS:SetPadding({ Left = 0, Top = 0, Right = 8, Bottom = 0 }) end)
        UI.DetailPill = dPill
        UI.DetailPillText = dPillTxt

        local dTitle = StaticConstructObject(cls.Text, wt)
        UITheme.StyleText(dTitle, 10, UITheme.Fonts.Secondary, UITheme.Colors.TextPrimary, false)
        local dtS = inspTopH:AddChildToHorizontalBox(dTitle)
        pcall(function() dtS:SetSize({ Value = 1.0, SizeRule = 1 }); dtS:SetVerticalAlignment(2) end)
        UI.DetailTitle = dTitle

        local dMeta = StaticConstructObject(cls.Text, wt)
        UITheme.StyleText(dMeta, 8, UITheme.Fonts.Secondary, UITheme.Colors.Gold, false)
        local dmS = inspV:AddChildToVerticalBox(dMeta)
        pcall(function() dmS:SetPadding({ Left = 0, Top = 0, Right = 0, Bottom = 2 }) end)
        UI.DetailMeta = dMeta

        local dDesc = StaticConstructObject(cls.Text, wt)
        UITheme.StyleText(dDesc, 9, UITheme.Fonts.Body, UITheme.Colors.TextSecondary, true)
        inspV:AddChildToVerticalBox(dDesc)
        UI.DetailDesc = dDesc

        -- Footer
        local footBox = StaticConstructObject(cls.SizeBox, wt)
        pcall(function() footBox:SetHeightOverride(28.0) end)
        workV:AddChildToVerticalBox(footBox)

        local footH = StaticConstructObject(cls.HBox, wt)
        footBox:AddChild(footH)

        local legend = StaticConstructObject(cls.Text, wt)
        UITheme.StyleText(legend, 8, UITheme.Fonts.Secondary, UITheme.Colors.TextMuted, false)
        UITheme.SetText(legend, "A  SELECT   |   D-PAD L/R / LT/RT  SUB   |   R-STICK  SPIN")
        local legS = footH:AddChildToHorizontalBox(legend)
        pcall(function() legS:SetSize({ Value = 1.0, SizeRule = 1 }); legS:SetVerticalAlignment(2) end)
        UI.LegendText = legend

        local eqWrap = StaticConstructObject(cls.SizeBox, wt)
        pcall(function() eqWrap:SetMinDesiredWidth(104.0) end)
        local eqBtn, eqCard = UITheme.MakeCleanButtonCard(
            wt, cls, UITheme.Colors.Gold, 3.0, UITheme.Colors.TextDark, 1.2, 12, 4, 12, 4
        )
        UITheme.ApplyNativeSkew(eqWrap, -8.0)
        eqWrap:AddChild(eqBtn)
        local eqTxt = StaticConstructObject(cls.Text, wt)
        UITheme.StyleText(eqTxt, 9, UITheme.Fonts.Secondary, UITheme.Colors.TextDark, false, 1)
        UITheme.SetText(eqTxt, "EQUIP  [A]")
        eqCard:SetContent(eqTxt)
        footH:AddChildToHorizontalBox(eqWrap)
        UI.EquipBtn = eqBtn
        UI.EquipCard = eqCard
        UI.EquipText = eqTxt

        UI.Widget = uw
        UI.OwnerPC = ownerPC
        UI.World = world
        return true
    end)

    return ok == true and built == true and UObjectUtils.IsValid(UI.Widget)
end

-- ============================================================================
-- DATA MODEL BUILDER (LAZY VISIBLE ICONS + FULL CO-OP / DIAGNOSTICS TAB)
-- ============================================================================

local function RebuildTabModel()
    CatalogService.Refresh()
    local ordered = CatalogService.Ordered
    local p2 = ProfileStore.GetP2()
    local items, subs = {}, {}
    local expOn = CharacterApplier.IsExperimentalEnabled()

    if State.TabIndex == 1 then
        local activeCharSubs = {}
        if State.IsLimitedMatchMode then
            activeCharSubs = { CHARACTER_SUBS[1] }
        else
            for _, cs in ipairs(CHARACTER_SUBS) do
                if cs.Kind ~= "tint" or expOn then
                    activeCharSubs[#activeCharSubs + 1] = cs
                end
            end
        end
        for _, cs in ipairs(activeCharSubs) do subs[#subs + 1] = cs.Pill end
        if State.SubIndex < 1 or State.SubIndex > #activeCharSubs then State.SubIndex = 1 end
        local sub = activeCharSubs[State.SubIndex]
        local isModChar = (p2.CharacterKey ~= nil and p2.CharacterKey ~= "Default")

        if sub.Kind == "models" then
            if #CharacterApplier.List == 0 then CharacterApplier.ScanAll() end
            items[#items + 1] = {
                Name = "Rescan Character Mods (Paks / ~mods)",
                PillText = "RESCAN",
                PillBg = UITheme.Colors.MagentaSoft,
                PillFg = UITheme.Colors.Magenta,
                ActionLabel = "SCAN  [A]",
                Tag = "PAK SCANNER",
                TagBg = UITheme.Colors.MagentaSoft,
                TagFg = UITheme.Colors.Magenta,
                Meta = "SCANS .UTOC, .PAK & INFO.JSON",
                Description = "Scans Pagoda/Content/Paks/~mods and LogicMods in-process to refresh all installed Character Slot Mods.",
                OnActivate = function()
                    local list = CharacterApplier.ScanAll()
                    if Callbacks.Notify then
                        Callbacks.Notify(string.format("Character Registry refreshed (%d found)", #list), "Info")
                    end
                end,
            }
            local curKey = p2.CharacterKey or "Default"
            for _, entry in ipairs(CharacterApplier.List) do
                local showEntry = (not entry.IsExperimental) or expOn
                if showEntry then
                    local isCur = (tostring(entry.Key) == tostring(curKey))
                    local isCSM = (entry.Source == "CSM")
                    local isExpBoss = (entry.Source == "Boss")
                    local isExpEnemy = (entry.Source == "Enemy")
                    local badgeTxt = isCur and "ACTIVE" or (entry.Badge or (isCSM and "CSM" or "VANILLA"))
                    local badgeBg = isCur and UITheme.Colors.EmeraldSoft
                        or (isCSM and UITheme.Colors.MagentaSoft
                        or (isExpBoss and UITheme.Colors.AmberSoft
                        or (isExpEnemy and UITheme.Colors.VioletSoft or UITheme.Colors.CyanSoft)))
                    local badgeFg = isCur and UITheme.Colors.Emerald
                        or (isCSM and UITheme.Colors.Magenta
                        or (isExpBoss and UITheme.Colors.Amber
                        or (isExpEnemy and UITheme.Colors.Violet or UITheme.Colors.Cyan)))
                    items[#items + 1] = {
                        Name = entry.Name,
                        PillText = badgeTxt,
                        PillBg = badgeBg,
                        PillFg = badgeFg,
                        IsEquipped = isCur,
                        ActionLabel = isCur and "EQUIPPED" or "APPLY  [A]",
                        Tag = entry.IsExperimental and ("EXP " .. (entry.Badge or "MODEL")) or (isCSM and "CSM MOD" or "VANILLA"),
                        TagBg = badgeBg,
                        TagFg = badgeFg,
                        Meta = "SOURCE: " .. tostring(entry.Container or "Base Game"):upper(),
                        Description = entry.Description,
                        OnActivate = function() if Callbacks.ApplyCharacter then Callbacks.ApplyCharacter(entry.Key) end end,
                    }
                end
            end

        elseif sub.Kind == "presets" then
            local presets = (Config.Loadouts and Config.Loadouts.OutfitPresets) or {}
            for idx, pr in ipairs(presets) do
                local isAct = (not isModChar) and (not p2.CustomPieceOverride) and (idx == p2.OutfitPresetIndex)
                items[#items + 1] = {
                    Name = pr.Name or ("Outfit #" .. idx),
                    PillText = isAct and "ACTIVE" or "",
                    PillBg = isAct and UITheme.Colors.EmeraldSoft or UITheme.Colors.Transparent,
                    PillFg = isAct and UITheme.Colors.Emerald or UITheme.Colors.TextMuted,
                    IsEquipped = isAct,
                    ActionLabel = "APPLY  [A]",
                    Tag = "OUTFIT PRESET",
                    TagBg = UITheme.Colors.EmeraldSoft,
                    TagFg = UITheme.Colors.Emerald,
                    Meta = isModChar and "SWITCHES CSM BACK TO CHARLIE + APPLIES PRESET" or "FULL CHARLIE WARDROBE PRESET",
                    Description = string.format("Jacket: %s | Hair: %s | Glasses: %s | Sticks: %s",
                        tostring(pr.Jacket), tostring(pr.Hair), tostring(pr.Glasses), tostring(pr.Drumsticks)),
                    OnActivate = function() if Callbacks.ApplyOutfitPreset then Callbacks.ApplyOutfitPreset(idx) end end,
                }
            end

        elseif sub.Kind == "slot" or sub.Kind == "multi" then
            local multiSlots = sub.Slots or {}
            local showPrefix = (#multiSlots > 1)
            for _, slotNum in ipairs(multiSlots) do
                local eqDef = p2.CosmeticSlots[slotNum]
                local slotTag = SLOT_SHORT_TAGS[slotNum] or "PIECE"
                for _, entry in ipairs((ordered.CosmeticsBySlot and ordered.CosmeticsBySlot[slotNum]) or {}) do
                    local isEq = UObjectUtils.IsValid(eqDef) and UObjectUtils.Same(eqDef, entry.Def)
                    local desc = UITheme.CleanRichText(entry.Description)
                    if desc == "" then desc = "Equip " .. entry.Name .. " strictly on Player 2." end
                    local dispName = showPrefix and ("[" .. slotTag .. "] " .. tostring(entry.Name)) or tostring(entry.Name)
                    items[#items + 1] = {
                        Name = dispName,
                        IconDef = entry.Def,
                        PillText = isEq and "EQUIPPED" or (showPrefix and slotTag or ""),
                        PillBg = isEq and UITheme.Colors.EmeraldSoft or (showPrefix and UITheme.Colors.CyanSoft or UITheme.Colors.Transparent),
                        PillFg = isEq and UITheme.Colors.Emerald or (showPrefix and UITheme.Colors.Cyan or UITheme.Colors.TextMuted),
                        IsEquipped = isEq,
                        ActionLabel = "EQUIP  [A]",
                        Tag = slotTag,
                        TagBg = UITheme.Colors.CyanSoft,
                        TagFg = UITheme.Colors.Cyan,
                        Meta = isEq and "EQUIPPED ON PLAYER 2"
                            or ((isModChar and slotNum ~= 4) and "SWITCHES CSM BACK TO CHARLIE" or "AVAILABLE FOR PLAYER 2"),
                        Description = desc,
                        OnActivate = function() if Callbacks.EquipCosmetic then Callbacks.EquipCosmetic(slotNum, entry.Def) end end,
                    }
                end
            end

        elseif sub.Kind == "tint" then
            items[#items + 1] = {
                Name = "P2 Rim Tint Mode: " .. tostring(CharacterApplier.CurrentTintMode),
                PillText = CharacterApplier.CurrentTintMode:upper(),
                PillBg = UITheme.Colors.GoldSoft,
                PillFg = UITheme.Colors.Gold,
                IsEquipped = (CharacterApplier.CurrentTintMode ~= "Off"),
                ActionLabel = "CYCLE  [A]",
                Tag = "VISUAL TINT",
                TagBg = UITheme.Colors.GoldSoft,
                TagFg = UITheme.Colors.Gold,
                Meta = isModChar and "APPLIES TO VANILLA CHARLIE (CSM PRESERVES SHADERS)" or "EXPERIMENTAL VISUAL HIGHLIGHT",
                Description = "Cycles Player 2 highlight mode between AccentOnly, FullBody, and Off.",
                OnActivate = function() if Callbacks.CycleTintMode then Callbacks.CycleTintMode() end end,
            }
            local palettes = (Config.Characters and Config.Characters.TintColorPalettes) or {}
            for pIdx, pal in ipairs(palettes) do
                local isPal = (CharacterApplier.CurrentTintPaletteIdx == pIdx)
                items[#items + 1] = {
                    Name = "Highlight Color: " .. tostring(pal.Name),
                    PillText = isPal and "ACTIVE" or "",
                    PillBg = isPal and UITheme.Colors.EmeraldSoft or UITheme.Colors.Transparent,
                    PillFg = isPal and UITheme.Colors.Emerald or UITheme.Colors.TextMuted,
                    IsEquipped = isPal,
                    ActionLabel = "APPLY  [A]",
                    Tag = "PALETTE",
                    TagBg = UITheme.Colors.CyanSoft,
                    TagFg = pal.Color or UITheme.Colors.Cyan,
                    Meta = isPal and "ACTIVE PLAYER 2 RIM COLOR" or "SELECT PLAYER 2 RIM COLOR",
                    Description = "Sets Player 2 visual highlight color to " .. tostring(pal.Name) .. ".",
                    OnActivate = function() if Callbacks.SetTintPalette then Callbacks.SetTintPalette(pIdx) end end,
                }
            end
        end

    elseif State.TabIndex == 2 then
        subs = { "Skill Presets", "Attack Slot 1", "Attack Slot 2", "Attack Slot 3", "Attack Slot 4" }
        if State.SubIndex < 1 or State.SubIndex > 5 then State.SubIndex = 1 end

        if State.SubIndex == 1 then
            local presets = (Config.Loadouts and Config.Loadouts.LoadoutPresets) or {}
            for idx, lp in ipairs(presets) do
                local isAct = (idx == p2.LoadoutPresetIndex)
                local bList = lp.BossAbilities and table.concat(lp.BossAbilities, ", ") or "Mirrors P1"
                local dList = lp.Dances and table.concat(lp.Dances, ", ") or "Groove Pack"
                local firstBossDef = lp.BossAbilities and lp.BossAbilities[1] and CatalogService.FindBossAbility(lp.BossAbilities[1]) or nil
                items[#items + 1] = {
                    Name = lp.Name or ("Loadout #" .. idx),
                    IconDef = firstBossDef,
                    PillText = isAct and "ACTIVE" or "PRESET",
                    PillBg = isAct and UITheme.Colors.EmeraldSoft or UITheme.Colors.GoldSoft,
                    PillFg = isAct and UITheme.Colors.Emerald or UITheme.Colors.Gold,
                    IsEquipped = isAct,
                    ActionLabel = "APPLY  [A]",
                    Tag = "LOADOUT PRESET",
                    TagBg = UITheme.Colors.GoldSoft,
                    TagFg = UITheme.Colors.Gold,
                    Meta = "PRESS D-PAD LEFT/RIGHT OR LT/RT TO PICK SLOT 1-4",
                    Description = string.format("Skills: %s | Dances: %s", bList, dList),
                    OnActivate = function() if Callbacks.ApplySkillPreset then Callbacks.ApplySkillPreset(idx) end end,
                }
            end
        else
            local targetSlot = State.SubIndex - 2
            for _, entry in ipairs(ordered.BossAbilities or {}) do
                local eqSlot = ProfileStore.FindP2BossSlot(entry.Def)
                local isHere = (eqSlot == targetSlot)
                local conflict = (eqSlot ~= nil and eqSlot ~= targetSlot)
                local idolStyle = UITheme.GetIdolStyle(entry.Idol)
                local desc = UITheme.CleanRichText(entry.Description)
                if desc == "" then desc = string.format("Equip '%s' strictly onto Player 2 Attack Slot %d.", entry.Name, targetSlot + 1) end

                items[#items + 1] = {
                    Name = entry.Name,
                    IconDef = entry.Def,
                    PillText = isHere and ("SLOT " .. (targetSlot + 1)) or (conflict and ("SWAP S" .. (eqSlot + 1)) or idolStyle.Label:upper()),
                    PillBg = isHere and UITheme.Colors.EmeraldSoft or (conflict and UITheme.Colors.AmberSoft or idolStyle.Soft),
                    PillFg = isHere and UITheme.Colors.Emerald or (conflict and UITheme.Colors.Amber or idolStyle.Color),
                    IsEquipped = isHere,
                    HasConflict = conflict,
                    ActionLabel = conflict and "SWAP  [A]" or "EQUIP  [A]",
                    Tag = idolStyle.Full,
                    TagBg = idolStyle.Soft,
                    TagFg = idolStyle.Color,
                    Meta = isHere and ("EQUIPPED IN P2 SLOT " .. (targetSlot + 1))
                        or (conflict and ("IN SLOT " .. (eqSlot + 1) .. " (SWAPS CLEANLY)") or ("TARGET: ATTACK SLOT " .. (targetSlot + 1))),
                    Description = desc,
                    OnActivate = function() if Callbacks.EquipBossSkill then Callbacks.EquipBossSkill(targetSlot, entry.Def) end end,
                }
            end
        end

    elseif State.TabIndex == 3 then
        subs = { "D-Pad Up (1)", "D-Pad Right (2)", "D-Pad Down (3)", "D-Pad Left (4)" }
        if State.SubIndex < 1 or State.SubIndex > 4 then State.SubIndex = 1 end
        local targetSlot = State.SubIndex - 1

        for _, entry in ipairs(ordered.Dances or {}) do
            local eqSlot = ProfileStore.FindP2DanceSlot(entry.Def)
            local isHere = (eqSlot == targetSlot)
            local conflict = (eqSlot ~= nil and eqSlot ~= targetSlot)
            local desc = UITheme.CleanRichText(entry.Description)
            if desc == "" then desc = string.format("Assign '%s' strictly to Player 2's %s.", entry.Name, subs[State.SubIndex]) end

            items[#items + 1] = {
                Name = entry.Name,
                IconDef = entry.Def,
                PillText = isHere and ("SLOT " .. (targetSlot + 1)) or (conflict and ("SWAP S" .. (eqSlot + 1)) or ""),
                PillBg = isHere and UITheme.Colors.EmeraldSoft or (conflict and UITheme.Colors.AmberSoft or UITheme.Colors.Transparent),
                PillFg = isHere and UITheme.Colors.Emerald or (conflict and UITheme.Colors.Amber or UITheme.Colors.TextMuted),
                IsEquipped = isHere,
                HasConflict = conflict,
                ActionLabel = conflict and "SWAP  [A]" or "ASSIGN  [A]",
                Tag = "DANCE",
                TagBg = UITheme.Colors.GoldSoft,
                TagFg = UITheme.Colors.Gold,
                Meta = isHere and "EQUIPPED IN TARGET SLOT"
                    or (conflict and ("IN SLOT " .. (eqSlot + 1) .. " (SWAPS CLEANLY)") or ("TARGET: " .. subs[State.SubIndex]:upper())),
                Description = desc,
                OnActivate = function() if Callbacks.EquipDance then Callbacks.EquipDance(targetSlot, entry.Def) end end,
            }
        end

    elseif State.TabIndex == 4 then
        local idolOrder = (ordered.IdolOrder and #ordered.IdolOrder > 0) and ordered.IdolOrder
            or { "Dancer", "Shred", "Rebel", "Prophet", "Doll", "Charlie" }
        local dynamicSubs = { { Idol = "All", Pill = "ALL" } }
        subs[#subs + 1] = "ALL"
        for _, key in ipairs(idolOrder) do
            if #dynamicSubs < MAX_SUB_PILLS then
                local st = UITheme.GetIdolStyle(key)
                local pill = UITheme.Truncate((st.Label or key):upper(), 7)
                dynamicSubs[#dynamicSubs + 1] = { Idol = key, Pill = pill }
                subs[#subs + 1] = pill
            end
        end

        if State.SubIndex < 1 or State.SubIndex > #dynamicSubs then State.SubIndex = 1 end
        local idolKey = dynamicSubs[State.SubIndex].Idol
        local p1, p2Ctrl = SessionManager.GetP1(), SessionManager.GetP2()

        local allOn = PlayerStateIsolation.AreAllUpgradesEnabledOnP2()
        items[#items + 1] = {
            Name = "Unlock All Upgrades (P2 Only)",
            PillText = allOn and "ALL ON" or "OFF",
            PillBg = allOn and UITheme.Colors.EmeraldSoft or UITheme.Colors.GoldSoft,
            PillFg = allOn and UITheme.Colors.Emerald or UITheme.Colors.Gold,
            IsEquipped = allOn,
            ActionLabel = allOn and "RESET  [A]" or "UNLOCK ALL  [A]",
            Tag = "UPGRADES",
            TagBg = UITheme.Colors.EmeraldSoft,
            TagFg = UITheme.Colors.Emerald,
            Meta = "UNLOCKS ALL IDOL SKILL TREE UPGRADES FOR PLAYER 2",
            Description = "Enables or resets all Idol skill tree upgrades for Player 2.",
            OnActivate = function()
                if Callbacks.ToggleUnlockAllUpgrades then Callbacks.ToggleUnlockAllUpgrades(not allOn) end
            end,
        }

        for _, entry in ipairs((ordered.UpgradesByIdol and ordered.UpgradesByIdol[idolKey]) or {}) do
            local isOn = PlayerStateIsolation.IsUpgradeEquippedOnP2(p1, p2Ctrl, entry.Def)
            local idolStyle = UITheme.GetIdolStyle(entry.Idol)
            local desc = UITheme.CleanRichText(entry.Description)
            if desc == "" then desc = "Toggle upgrade '" .. entry.Name .. "' strictly on Player 2." end

            items[#items + 1] = {
                Name = entry.Name,
                IconDef = entry.Def,
                PillText = isOn and "ON" or "OFF",
                PillBg = isOn and UITheme.Colors.EmeraldSoft or UITheme.Colors.TrackDark,
                PillFg = isOn and UITheme.Colors.Emerald or UITheme.Colors.TextMuted,
                IsEquipped = isOn,
                ActionLabel = isOn and "DISABLE  [A]" or "ENABLE  [A]",
                Tag = idolStyle.Full,
                TagBg = idolStyle.Soft,
                TagFg = idolStyle.Color,
                Meta = isOn and "ACTIVE ON PLAYER 2" or "INACTIVE ON PLAYER 2",
                Description = desc,
                OnActivate = function() if Callbacks.ToggleUpgrade then Callbacks.ToggleUpgrade(entry.Def) end end,
            }
        end

    elseif State.TabIndex == 5 then
        local showDiag = (not State.IsLimitedMatchMode) and expOn
        subs = showDiag and { "GENERAL", "DIAGNOSTICS" } or { "GENERAL" }
        if State.SubIndex < 1 or State.SubIndex > #subs then State.SubIndex = 1 end

        if State.SubIndex == 1 then
            local function AddCommonCameraAndHudSettings()
                items[#items + 1] = {
                    Name = "Screen / Camera Mode: " .. ViewportController.GetScreenModeLabel(),
                    PillText = ViewportController.GetScreenModeShortTag(),
                    PillBg = UITheme.Colors.CyanSoft,
                    PillFg = UITheme.Colors.Cyan,
                    ActionLabel = "CYCLE  [A]",
                    Tag = "CAMERA",
                    TagBg = UITheme.Colors.CyanSoft,
                    TagFg = UITheme.Colors.Cyan,
                    Meta = "HOTKEY: F9 (DIVE BAR USES SPLIT-SCREEN)",
                    Description = "Cycles Horizontal Split, Vertical Split, and Shared Arena Camera.",
                    OnActivate = function() ViewportController.CycleScreenMode(true) end,
                }

                local fovOn = ViewportController.CustomFOVEnabled
                local fovLabel = ViewportController.GetFOVModeLabel()
                local fovTag = ViewportController.GetFOVModeShortTag()
                items[#items + 1] = {
                    Name = "Camera FOV: " .. fovLabel,
                    PillText = fovTag,
                    PillBg = fovOn and UITheme.Colors.CyanSoft or UITheme.Colors.TrackDark,
                    PillFg = fovOn and UITheme.Colors.Cyan or UITheme.Colors.TextMuted,
                    IsEquipped = fovOn,
                    ActionLabel = "CYCLE  [A]",
                    Tag = "CAMERA FOV",
                    TagBg = UITheme.Colors.CyanSoft,
                    TagFg = UITheme.Colors.Cyan,
                    Meta = "OPTIONS: DEFAULT / WIDE / WIDER",
                    Description = "Cycles Camera FOV between Default, Wide, and Wider.",
                    OnActivate = function()
                        ViewportController.CycleFOVPreset()
                    end,
                }

                local hudScalePct = math.floor(VanillaHUD.GetSharedScale() * 100 + 0.5)
                items[#items + 1] = {
                    Name = "Arena P2 HUD Scale: " .. hudScalePct .. "%",
                    PillText = hudScalePct .. "%",
                    PillBg = UITheme.Colors.GoldSoft,
                    PillFg = UITheme.Colors.Gold,
                    ActionLabel = "STEP  [A]",
                    Tag = "VANILLA HUD",
                    TagBg = UITheme.Colors.GoldSoft,
                    TagFg = UITheme.Colors.Gold,
                    Meta = "RANGE 60% - 110% (SHARED/ARENA CAMERA)",
                    Description = "Adjusts the scale of Player 2's native HUD cluster in Shared/Arena Camera.",
                    OnActivate = function()
                        VanillaHUD.StepSharedScale(0.08)
                        if Callbacks.SaveProfile then UObjectUtils.SafeCall("Menu.SaveHUDScale", Callbacks.SaveProfile) end
                    end,
                }

                local hudCfgRef = Config.HUD or {}
                local circlesOn = (hudCfgRef.ShowSharedPlayerCircles ~= false)
                items[#items + 1] = {
                    Name = "Arena Floor Circles (P1 Cyan / P2 Pink)",
                    PillText = circlesOn and "ON" or "OFF",
                    PillBg = circlesOn and UITheme.Colors.CyanSoft or UITheme.Colors.TrackDark,
                    PillFg = circlesOn and UITheme.Colors.Cyan or UITheme.Colors.TextMuted,
                    IsEquipped = circlesOn,
                    ActionLabel = "TOGGLE  [A]",
                    Tag = "ARENA MARKERS",
                    TagBg = UITheme.Colors.CyanSoft,
                    TagFg = UITheme.Colors.Cyan,
                    Meta = circlesOn and "P1 CYAN + P2 PINK FLOOR RINGS ACTIVE IN-MATCH" or "FLOOR RINGS HIDDEN",
                    Description = "Displays compact Cyan (P1) and Pink (P2) rings beneath players during Shared/Arena combat.",
                    OnActivate = function()
                        if Config.HUD then
                            Config.HUD.ShowSharedPlayerCircles = not (Config.HUD.ShowSharedPlayerCircles ~= false)
                        end
                        if Callbacks.SaveProfile then UObjectUtils.SafeCall("Menu.SaveCircles", Callbacks.SaveProfile) end
                    end,
                }

                local dynCamOn = (ViewportController.DynamicSharedCameraEnabled ~= false)
                items[#items + 1] = {
                    Name = "Shared View Top-Down Camera",
                    PillText = dynCamOn and "ON" or "OFF",
                    PillBg = dynCamOn and UITheme.Colors.CyanSoft or UITheme.Colors.TrackDark,
                    PillFg = dynCamOn and UITheme.Colors.Cyan or UITheme.Colors.TextMuted,
                    IsEquipped = dynCamOn,
                    ActionLabel = "TOGGLE  [A]",
                    Tag = "SHARED CAMERA",
                    TagBg = UITheme.Colors.CyanSoft,
                    TagFg = UITheme.Colors.Cyan,
                    Meta = dynCamOn and "TOP-DOWN MIDPOINT CAMERA ACTIVE IN SHARED VIEW" or "FOLLOWS PLAYER 1 CAMERA",
                    Description = "Frames both Player 1 and Player 2 from an elevated top-down arena perspective in Shared View (on by default).",
                    OnActivate = function() ViewportController.ToggleDynamicSharedCamera() end,
                }
            end

            AddCommonCameraAndHudSettings()

            if not State.IsLimitedMatchMode then
                local leashOn = SessionManager.State.AutoLeashEnabled
                items[#items + 1] = {
                    Name = "Auto-Leash P2 in Shared View",
                    PillText = leashOn and "ON" or "OFF",
                    PillBg = leashOn and UITheme.Colors.CyanSoft or UITheme.Colors.TrackDark,
                    PillFg = leashOn and UITheme.Colors.Cyan or UITheme.Colors.TextMuted,
                    IsEquipped = leashOn,
                    ActionLabel = "TOGGLE  [A]",
                    Tag = "SHARED CAMERA",
                    TagBg = UITheme.Colors.CyanSoft,
                    TagFg = UITheme.Colors.Cyan,
                    Meta = "AUTO-WARPS P2 IF TOO FAR OFF-SCREEN",
                    Description = "Automatically regroups Player 2 if separated far off-screen in Shared/Arena View.",
                    OnActivate = function() SessionManager.ToggleAutoLeash() end,
                }

                items[#items + 1] = {
                    Name = "Controllers: " .. (InputRouting.OffsetGamepad and "1 KB/Mouse + 1 Pad" or "2 Gamepads"),
                    PillText = "SWAP",
                    PillBg = UITheme.Colors.GoldSoft,
                    PillFg = UITheme.Colors.Gold,
                    ActionLabel = "TOGGLE  [A]",
                    Tag = "INPUT",
                    TagBg = UITheme.Colors.GoldSoft,
                    TagFg = UITheme.Colors.Gold,
                    Meta = "1 KB+M + 1 PAD vs 2 GAMEPADS",
                    Description = "Switches gameplay controller assignment between 1 KB/Mouse (P1) + 1 Pad (P2) and 2 Gamepads.",
                    OnActivate = function() InputRouting.ToggleGamepadOffset() end,
                }

                items[#items + 1] = {
                    Name = "Experimental Features",
                    PillText = expOn and "ON" or "OFF",
                    PillBg = expOn and UITheme.Colors.AmberSoft or UITheme.Colors.TrackDark,
                    PillFg = expOn and UITheme.Colors.Amber or UITheme.Colors.TextMuted,
                    IsEquipped = expOn,
                    ActionLabel = "TOGGLE  [A]",
                    Tag = "EXPERIMENTAL",
                    TagBg = UITheme.Colors.AmberSoft,
                    TagFg = UITheme.Colors.Amber,
                    Meta = expOn and "TINTS, BOSS/ENEMY MODELS & DIAGNOSTICS UNLOCKED" or "ENABLE FOR TINTS, BOSS/ENEMY MODELS & DIAGNOSTICS",
                    Description = "Unlocks experimental features: Character Rim Tints, playable SKEL_Humanoid Boss/Enemy models, and Diagnostics.",
                    OnActivate = function()
                        if Callbacks.ToggleExperimental then Callbacks.ToggleExperimental() end
                    end,
                }
            end

            items[#items + 1] = {
                Name = "Regroup Player 2 Beside Player 1",
                PillText = "WARP",
                PillBg = UITheme.Colors.CyanSoft,
                PillFg = UITheme.Colors.Cyan,
                ActionLabel = "WARP  [A]",
                Tag = "SESSION",
                TagBg = UITheme.Colors.CyanSoft,
                TagFg = UITheme.Colors.Cyan,
                Meta = "TELEPORTS P2 TO P1",
                Description = "Teleports Player 2 directly next to Player 1.",
                OnActivate = function()
                    SessionManager.TeleportP2ToP1()
                    P2Menu.Close()
                end,
            }

            items[#items + 1] = {
                Name = "Leave Co-op (Disconnect Player 2)",
                PillText = "LEAVE",
                PillBg = UITheme.Colors.CrimsonSoft,
                PillFg = UITheme.Colors.Crimson,
                ActionLabel = "LEAVE  [A]",
                Tag = "DROP-OUT",
                TagBg = UITheme.Colors.CrimsonSoft,
                TagFg = UITheme.Colors.Crimson,
                Meta = "DISCONNECTS P2 & RESTORES SOLO",
                Description = "Cleanly disconnects Player 2, removes P2 HUD widgets, and restores solo gameplay.",
                OnActivate = function()
                    P2Menu.Close(true)
                    SessionManager.DespawnP2()
                end,
            }
        else
            -- Diagnostics sub-view
            local isoSt = PlayerStateIsolation.Status
            local hookSum = HookRegistry.GetHealthSummary()
            local hudSt = VanillaHUD.GetStatus()
            local schedSt = Scheduler.GetStats()
            local logSt = Logger.GetStats()

            items[#items + 1] = {
                Name = string.format("PPD Isolation: %s (%s)", isoSt.Verified and "VERIFIED" or "UNBOUND", isoSt.LastBindMode),
                PillText = isoSt.BleedDetectedCount == 0 and "CLEAN" or ("BLEED:" .. isoSt.BleedDetectedCount),
                PillBg = isoSt.BleedDetectedCount == 0 and UITheme.Colors.EmeraldSoft or UITheme.Colors.CrimsonSoft,
                PillFg = isoSt.BleedDetectedCount == 0 and UITheme.Colors.Emerald or UITheme.Colors.Crimson,
                IsEquipped = isoSt.Verified and isoSt.BleedDetectedCount == 0,
                Tag = "ISOLATION",
                TagBg = UITheme.Colors.EmeraldSoft,
                TagFg = UITheme.Colors.Emerald,
                Meta = string.format("Swaps=%d StrayBlocked=%d LP_Iso=%s ASC=%s",
                    isoSt.ScopedSwapCount, isoSt.StrayDelegateBlockedCount,
                    tostring(isoSt.LP_PPD_Isolated), tostring(isoSt.ASCIsolated)),
                Description = "Shows Player 1 vs Player 2 PlaythroughData & UpgradeComponent isolation proof.",
                OnActivate = function() PlayerStateIsolation.AuditIntegrity() end,
            }
            items[#items + 1] = {
                Name = string.format("Vanilla P2 HUD: %s (%d widgets)", hudSt.Mode, hudSt.SharedWidgetsMounted),
                PillText = hudSt.SharedVisible and "LIVE" or hudSt.Mode:upper(),
                PillBg = UITheme.Colors.CyanSoft,
                PillFg = UITheme.Colors.Cyan,
                Tag = "HUD STATUS",
                TagBg = UITheme.Colors.CyanSoft,
                TagFg = UITheme.Colors.Cyan,
                Meta = string.format("Scale=%.2f SplitFallback=%s", hudSt.SharedScale, tostring(hudSt.SplitFallbackMounted)),
                Description = "Select [A] to rebuild Player 2's native HUD bindings.",
                OnActivate = function() VanillaHUD.Rebuild() end,
            }
            items[#items + 1] = {
                Name = string.format("Hooks: %d/%d Active | %d Calls | %d Err",
                    hookSum.Registered, hookSum.Total, hookSum.Calls, hookSum.Errors),
                PillText = hookSum.Pending == 0 and "OK" or (hookSum.Pending .. " PEND"),
                PillBg = hookSum.Errors == 0 and UITheme.Colors.EmeraldSoft or UITheme.Colors.AmberSoft,
                PillFg = hookSum.Errors == 0 and UITheme.Colors.Emerald or UITheme.Colors.Amber,
                Tag = "HOOKS",
                TagBg = UITheme.Colors.GoldSoft,
                TagFg = UITheme.Colors.Gold,
                Meta = string.format("Scheduler=%s Gen=%d MissingWarnings=%d",
                    tostring(schedSt.Mode), schedSt.Generation, logSt.MissingCount),
                Description = (#hookSum.MissingList > 0)
                    and ("Unresolved: " .. table.concat(hookSum.MissingList, ", "))
                    or "All registered hooks resolved cleanly.",
                OnActivate = function() HookRegistry.ReportMissingHooks("DiagnosticsRefresh") end,
            }

            local p1Pawn, p2Pawn = SessionManager.GetP1Pawn(), SessionManager.GetP2Pawn()
            local revSys = _G.__LocalCoopMod and _G.__LocalCoopMod.ReviveSystem or nil
            if revSys and revSys.Players then
                local s1, s2 = revSys.Players[0], revSys.Players[1]
                local h1 = p1Pawn and revSys.GetHealth(p1Pawn) or 0.0
                local m1 = p1Pawn and revSys.GetMaxHealth(p1Pawn) or 0.0
                local h2 = p2Pawn and revSys.GetHealth(p2Pawn) or 0.0
                local m2 = p2Pawn and revSys.GetMaxHealth(p2Pawn) or 0.0
                items[#items + 1] = {
                    Name = string.format("Revive FSM: P1=%s (%.0f/%.0f) | P2=%s (%.0f/%.0f)",
                        tostring(s1 and s1.State), h1, m1, tostring(s2 and s2.State), h2, m2),
                    PillText = (s1 and s1.State == "Alive" and s2 and s2.State == "Alive") and "READY" or "ACTIVE",
                    PillBg = UITheme.Colors.EmeraldSoft,
                    PillFg = UITheme.Colors.Emerald,
                    Tag = "REVIVE FSM",
                    TagBg = UITheme.Colors.EmeraldSoft,
                    TagFg = UITheme.Colors.Emerald,
                    Meta = string.format("Catalog: %d Boss Skills | %d Total Upgrades",
                        #(ordered.BossAbilities or {}), #(ordered.AllUpgrades or {})),
                    Description = "Shows live Player 1 and Player 2 health & Revive state machine status.",
                }
            end

            local recent = Logger.GetRecent(6)
            for i = #recent, 1, -1 do
                local e = recent[i]
                items[#items + 1] = {
                    Name = string.format("[%s][%s] %s", e.Level, e.Tag, e.Message),
                    PillText = e.Level,
                    PillBg = (e.Level == "ERROR" or e.Level == "WARN") and UITheme.Colors.AmberSoft or UITheme.Colors.TrackDark,
                    PillFg = (e.Level == "ERROR" or e.Level == "WARN") and UITheme.Colors.Amber or UITheme.Colors.TextSecondary,
                    Tag = "LOG",
                    TagBg = UITheme.Colors.TrackDark,
                    TagFg = UITheme.Colors.TextSecondary,
                    Meta = string.format("t=%.1fs | Source=%s", e.Time, e.Tag),
                    Description = e.Message,
                }
            end
        end
    end

    State.SubLabels = subs
    State.Items = items

    local count = #items
    if count == 0 then
        State.SelectedIndex = 1
        State.WindowStart = 1
    else
        if State.SelectedIndex > count then State.SelectedIndex = count end
        if State.SelectedIndex < 1 then State.SelectedIndex = 1 end
        if State.SelectedIndex < State.WindowStart then
            State.WindowStart = State.SelectedIndex
        elseif State.SelectedIndex > (State.WindowStart + VISIBLE_ROWS - 1) then
            State.WindowStart = State.SelectedIndex - VISIBLE_ROWS + 1
        end
        if State.WindowStart < 1 then State.WindowStart = 1 end
    end
end

-- ============================================================================
-- VISUAL REFRESH (RESOLVES ICONS ONLY FOR VISIBLE ITEMS)
-- ============================================================================

local function RefreshUI()
    if not (State.IsOpen and UObjectUtils.IsValid(UI.Widget)) then return end
    UpdatePanelAnchors()
    RebuildTabModel()

    local tabDef = TAB_DEFS[State.TabIndex] or TAB_DEFS[1]
    local tabAccent = tabDef.Accent or UITheme.Colors.Cyan
    local p2 = ProfileStore.GetP2()
    local needsIconWarmup = false

    for i, tDef in ipairs(TAB_DEFS) do
        local allowed = (not State.IsLimitedMatchMode) or (i == 1 or i == 2 or i == 5)
        if UObjectUtils.IsValid(UI.NavBoxes[i]) then
            pcall(function() UI.NavBoxes[i]:SetVisibility(allowed and 0 or 1) end)
        end
        local lbl = (State.IsLimitedMatchMode and tDef.LimitedLabel) and tDef.LimitedLabel or tDef.Label
        UITheme.SetText(UI.NavTexts[i], lbl)

        local active = (i == State.TabIndex)
        UITheme.SetFill(UI.NavCards[i], active and UITheme.Colors.SurfaceSelected or UITheme.Colors.Transparent)
        UITheme.SetOutlineColor(UI.NavCards[i],
            active and (tDef.Accent or UITheme.Colors.Cyan) or UITheme.Colors.Transparent,
            active and 1.2 or 0.0)
        UITheme.SetFill(UI.NavBars[i], active and (tDef.Accent or UITheme.Colors.Cyan) or UITheme.Colors.Transparent)
        UITheme.SetTextColor(UI.NavTexts[i], active and UITheme.Colors.TextPrimary or UITheme.Colors.TextSecondary)
    end

    if UObjectUtils.IsValid(UI.IsoPill) then
        if State.IsLimitedMatchMode then
            pcall(function() UI.IsoPill:SetVisibility(0) end)
            UITheme.SetFill(UI.IsoPill, UITheme.Colors.GoldSoft)
            UITheme.SetTextColor(UI.IsoText, UITheme.Colors.Gold)
            UITheme.SetText(UI.IsoText, "PAUSED | MATCH")
        else
            pcall(function() UI.IsoPill:SetVisibility(1) end)
        end
    end

    local secHdr = (State.IsLimitedMatchMode and tabDef.LimitedLabel) and tabDef.LimitedLabel or tabDef.Title
    UITheme.SetText(UI.SectionTitle, secHdr)
    if UObjectUtils.IsValid(UI.LegendText) then
        UITheme.SetText(UI.LegendText,
            State.IsLimitedMatchMode
                and "A  SELECT   |   LB / RB  TABS   |   B / SELECT  RESUME"
                or  "A  SELECT   |   LT / RT  SUB   |   R-STICK  SPIN")
    end
    local total = #State.Items
    local canScrollUp = (total > VISIBLE_ROWS) and (State.WindowStart > 1)
    local canScrollDown = (total > VISIBLE_ROWS) and ((State.WindowStart + VISIBLE_ROWS - 1) < total)
    local scrollCue = ""
    if canScrollUp and canScrollDown then
        scrollCue = "  [UP/DN]"
    elseif canScrollDown then
        scrollCue = "  [MORE]"
    elseif canScrollUp then
        scrollCue = "  [TOP]"
    end
    UITheme.SetText(UI.CountText, total > 0 and (string.format("%d / %d", State.SelectedIndex, total) .. scrollCue) or "0 / 0")

    local showSlotGrid = (State.TabIndex == 2 or State.TabIndex == 3)
    local showFilterBar = (not showSlotGrid) and (#State.SubLabels > 1)
    if UObjectUtils.IsValid(UI.SlotGridWrap) then
        pcall(function() UI.SlotGridWrap:SetVisibility(showSlotGrid and 0 or 1) end)
    end
    if UObjectUtils.IsValid(UI.FilterBarWrap) then
        pcall(function() UI.FilterBarWrap:SetVisibility(showFilterBar and 0 or 1) end)
    end

    if showSlotGrid then
        local isDance = (State.TabIndex == 3)
        local dirLabels = { "UP", "RIGHT", "DOWN", "LEFT" }
        for nodeIdx = 1, 5 do
            local targeted = false
            local slotAccent = SLOT_DISCO_ACCENTS[nodeIdx] or tabAccent
            local hdrStr, valStr, slotDef = "", "", nil

            if nodeIdx <= 4 then
                local slotZero = nodeIdx - 1
                if isDance then
                    targeted = (State.SubIndex == nodeIdx)
                    hdrStr = dirLabels[nodeIdx] .. "  [D" .. nodeIdx .. "]"
                    slotDef = p2.DanceSlots[slotZero]
                    valStr = UITheme.Truncate(ProfileStore.GetSlotDisplayName(slotDef), 14)
                else
                    targeted = (State.SubIndex == (nodeIdx + 1))
                    hdrStr = dirLabels[nodeIdx] .. "  [ATK " .. nodeIdx .. "]"
                    slotDef = p2.BossAbilitySlots[slotZero]
                    valStr = UITheme.Truncate(ProfileStore.GetSlotDisplayName(slotDef), 14)
                end
            else
                if isDance then
                    hdrStr = "D-PAD"; valStr = "WHEEL"
                else
                    targeted = (State.SubIndex == 1)
                    hdrStr = "BUILDS"
                    valStr = "Preset #" .. tostring(p2.LoadoutPresetIndex or 1)
                end
            end

            UITheme.SetFill(UI.SlotCards[nodeIdx], targeted and UITheme.Colors.SurfaceSelected or UITheme.Colors.SurfaceCard)
            UITheme.SetOutlineColor(UI.SlotCards[nodeIdx],
                targeted and UITheme.Colors.Gold or (slotDef and slotAccent or UITheme.Colors.HairlineSubtle),
                targeted and 1.8 or 1.0)
            UITheme.SetText(UI.SlotHeaders[nodeIdx], hdrStr)
            UITheme.SetTextColor(UI.SlotHeaders[nodeIdx], targeted and UITheme.Colors.Gold or slotAccent)
            UITheme.SetText(UI.SlotNames[nodeIdx], valStr)
            UITheme.SetTextColor(UI.SlotNames[nodeIdx], targeted and UITheme.Colors.TextPrimary or UITheme.Colors.TextSecondary)

            if UObjectUtils.IsValid(UI.SlotIconBoxes[nodeIdx]) and UObjectUtils.IsValid(UI.SlotIcons[nodeIdx]) then
                local iconInfo, defNeeded = nil, false
                if slotDef then iconInfo, defNeeded = UITheme.ResolveDefinitionIcon(slotDef) end
                if defNeeded then needsIconWarmup = true end
                if iconInfo and UITheme.ApplyIconToImage(UI.SlotIcons[nodeIdx], iconInfo) then
                    pcall(function() UI.SlotIconBoxes[nodeIdx]:SetVisibility(0) end)
                else
                    pcall(function() UI.SlotIconBoxes[nodeIdx]:SetVisibility(1) end)
                end
            end
        end
    elseif showFilterBar then
        local subCount = #State.SubLabels
        local pillCharLimit = (subCount <= 3) and 12 or 9
        UITheme.SetTextColor(UI.SubPrevText, subCount > 1 and UITheme.Colors.Cyan or UITheme.Colors.TextMuted)
        UITheme.SetTextColor(UI.SubNextText, subCount > 1 and UITheme.Colors.Cyan or UITheme.Colors.TextMuted)
        for p = 1, MAX_SUB_PILLS do
            local lbl = State.SubLabels[p]
            if lbl and UObjectUtils.IsValid(UI.SubPillWraps[p]) then
                pcall(function() UI.SubPillWraps[p]:SetVisibility(0) end)
                local isActive = (p == State.SubIndex)
                UITheme.SetText(UI.SubPillTexts[p], UITheme.Truncate(lbl, pillCharLimit))
                if isActive then
                    UITheme.SetFill(UI.SubPillCards[p], tabAccent)
                    UITheme.SetOutlineColor(UI.SubPillCards[p], UITheme.Colors.Gold, 1.3)
                    UITheme.SetTextColor(UI.SubPillTexts[p], UITheme.Colors.TextDark)
                else
                    UITheme.SetFill(UI.SubPillCards[p], UITheme.Colors.SurfaceRaised)
                    UITheme.SetOutlineColor(UI.SubPillCards[p], UITheme.Colors.HairlineSubtle, 0.8)
                    UITheme.SetTextColor(UI.SubPillTexts[p], UITheme.Colors.TextSecondary)
                end
            elseif UObjectUtils.IsValid(UI.SubPillWraps[p]) then
                pcall(function() UI.SubPillWraps[p]:SetVisibility(1) end)
            end
        end
    end

    for r = 1, VISIBLE_ROWS do
        local idx = State.WindowStart + r - 1
        local item = State.Items[idx]
        if item then
            pcall(function() UI.RowBoxes[r]:SetVisibility(0) end)
            local sel = (idx == State.SelectedIndex)

            UITheme.SetText(UI.RowNames[r], UITheme.Truncate(item.Name or "", 44))
            if UObjectUtils.IsValid(UI.RowIconBoxes[r]) and UObjectUtils.IsValid(UI.RowIcons[r]) then
                local iconInfo, defNeeded = nil, false
                if item.IconDef then
                    iconInfo, defNeeded = UITheme.ResolveDefinitionIcon(item.IconDef)
                    if defNeeded then needsIconWarmup = true end
                end
                if iconInfo and UITheme.ApplyIconToImage(UI.RowIcons[r], iconInfo) then
                    pcall(function() UI.RowIconBoxes[r]:SetVisibility(0) end)
                else
                    pcall(function() UI.RowIconBoxes[r]:SetVisibility(1) end)
                end
            end

            if sel then
                UITheme.SetFill(UI.RowCards[r], UITheme.Colors.SurfaceSelected)
                UITheme.SetOutlineColor(UI.RowCards[r], UITheme.Colors.Gold, 1.8)
                UITheme.SetFill(UI.RowBars[r], tabAccent)
                UITheme.SetTextColor(UI.RowNames[r], UITheme.Colors.TextPrimary)
            elseif item.IsEquipped then
                UITheme.SetFill(UI.RowCards[r], UITheme.Colors.SurfaceEquipped)
                UITheme.SetOutlineColor(UI.RowCards[r], UITheme.Colors.EmeraldSoft, 1.1)
                UITheme.SetFill(UI.RowBars[r], UITheme.Colors.Emerald)
                UITheme.SetTextColor(UI.RowNames[r], UITheme.Colors.TextPrimary)
            elseif item.HasConflict then
                UITheme.SetFill(UI.RowCards[r], UITheme.Colors.SurfaceConflict)
                UITheme.SetOutlineColor(UI.RowCards[r], UITheme.Colors.AmberSoft, 1.0)
                UITheme.SetFill(UI.RowBars[r], UITheme.Colors.Amber)
                UITheme.SetTextColor(UI.RowNames[r], UITheme.Colors.TextSecondary)
            else
                UITheme.SetFill(UI.RowCards[r], UITheme.Colors.SurfaceCard)
                UITheme.SetOutlineColor(UI.RowCards[r], UITheme.Colors.HairlineSubtle, 1.0)
                UITheme.SetFill(UI.RowBars[r], UITheme.Colors.Transparent)
                UITheme.SetTextColor(UI.RowNames[r], UITheme.Colors.TextSecondary)
            end

            if item.PillText and item.PillText ~= "" then
                pcall(function() UI.RowPillBgs[r]:SetVisibility(0) end)
                UITheme.SetFill(UI.RowPillBgs[r], item.PillBg or UITheme.Colors.CyanSoft)
                UITheme.SetTextColor(UI.RowPillTexts[r], item.PillFg or UITheme.Colors.Cyan)
                UITheme.SetText(UI.RowPillTexts[r], item.PillText)
            else
                pcall(function() UI.RowPillBgs[r]:SetVisibility(1) end)
            end
        else
            pcall(function() UI.RowBoxes[r]:SetVisibility(2) end)
        end
    end

    local scrollable = (total > VISIBLE_ROWS)
    if UObjectUtils.IsValid(UI.ScrollWrap) then
        pcall(function() UI.ScrollWrap:SetRenderOpacity(scrollable and 1.0 or 0.35) end)
    end

    local function StyleScrollArrow(card, icon, txt, active)
        if active then
            UITheme.SetFill(card, UITheme.Colors.SurfaceRaised)
            UITheme.SetOutlineColor(card, tabAccent, 1.3)
            if UObjectUtils.IsValid(icon) then pcall(function() icon:SetColorAndOpacity(UITheme.Colors.Gold) end) end
            if UObjectUtils.IsValid(txt) then UITheme.SetTextColor(txt, UITheme.Colors.Gold) end
        else
            UITheme.SetFill(card, UITheme.Colors.TrackDark)
            UITheme.SetOutlineColor(card, UITheme.Colors.HairlineSubtle, 0.8)
            if UObjectUtils.IsValid(icon) then pcall(function() icon:SetColorAndOpacity(UITheme.Colors.TextMuted) end) end
            if UObjectUtils.IsValid(txt) then UITheme.SetTextColor(txt, UITheme.Colors.TextMuted) end
        end
    end
    StyleScrollArrow(UI.ScrollUpCard, UI.ScrollUpIcon, UI.ScrollUpText, canScrollUp)
    StyleScrollArrow(UI.ScrollDownCard, UI.ScrollDownIcon, UI.ScrollDownText, canScrollDown)

    if scrollable then
        UITheme.SetFill(UI.ScrollThumbCard, tabAccent)
        local thumbFrac = math.max(0.14, VISIBLE_ROWS / total)
        local maxWin = math.max(1, total - VISIBLE_ROWS)
        local posFrac = ((State.WindowStart - 1) / maxWin) * (1.0 - thumbFrac)
        local afterFrac = math.max(0.001, 1.0 - posFrac - thumbFrac)
        pcall(function() UI.ScrollBeforeSlot:SetSize({ Value = math.max(0.001, posFrac), SizeRule = 1 }) end)
        pcall(function() UI.ScrollThumbSlot:SetSize({ Value = thumbFrac, SizeRule = 1 }) end)
        pcall(function() UI.ScrollAfterSlot:SetSize({ Value = afterFrac, SizeRule = 1 }) end)
    else
        UITheme.SetFill(UI.ScrollThumbCard, UITheme.Colors.HairlineSubtle)
        pcall(function() UI.ScrollBeforeSlot:SetSize({ Value = 0.001, SizeRule = 1 }) end)
        pcall(function() UI.ScrollThumbSlot:SetSize({ Value = 1.0, SizeRule = 1 }) end)
        pcall(function() UI.ScrollAfterSlot:SetSize({ Value = 0.001, SizeRule = 1 }) end)
    end

    local cur = State.Items[State.SelectedIndex]
    if cur then
        if UObjectUtils.IsValid(UI.DetailIconBox) and UObjectUtils.IsValid(UI.DetailIcon) then
            local iconInfo, defNeeded = nil, false
            if cur.IconDef then
                iconInfo, defNeeded = UITheme.ResolveDefinitionIcon(cur.IconDef)
                if defNeeded then needsIconWarmup = true end
            end
            if iconInfo and UITheme.ApplyIconToImage(UI.DetailIcon, iconInfo) then
                pcall(function() UI.DetailIconBox:SetVisibility(0) end)
            else
                pcall(function() UI.DetailIconBox:SetVisibility(1) end)
            end
        end
        UITheme.SetFill(UI.DetailPill, cur.TagBg or UITheme.Colors.CyanSoft)
        UITheme.SetTextColor(UI.DetailPillText, cur.TagFg or UITheme.Colors.Cyan)
        UITheme.SetText(UI.DetailPillText, UITheme.Truncate(cur.Tag or tabDef.Title, 18))
        UITheme.SetText(UI.DetailTitle, UITheme.Truncate(cur.Name or "", 44))
        UITheme.SetText(UI.DetailMeta, UITheme.Truncate(cur.Meta or "", 68))
        UITheme.SetText(UI.DetailDesc, UITheme.Truncate(cur.Description or "", 148))
        local actionLbl = cur.ActionLabel or "EQUIP  [A]"
        if actionLbl == "EQUIPPED" then
            UITheme.SetFill(UI.EquipCard, UITheme.Colors.EmeraldSoft)
            UITheme.SetOutlineColor(UI.EquipCard, UITheme.Colors.Emerald, 1.2)
            UITheme.SetTextColor(UI.EquipText, UITheme.Colors.Emerald)
        else
            UITheme.SetFill(UI.EquipCard, UITheme.Colors.Gold)
            UITheme.SetOutlineColor(UI.EquipCard, UITheme.Colors.TextDark, 1.2)
            UITheme.SetTextColor(UI.EquipText, UITheme.Colors.TextDark)
        end
        UITheme.SetText(UI.EquipText, actionLbl)
    else
        UITheme.SetText(UI.DetailPillText, tabDef.Title)
        UITheme.SetText(UI.DetailMeta, "")
        UITheme.SetText(UI.DetailTitle, "No Items")
        UITheme.SetText(UI.DetailDesc, "Waiting for game catalogs to load.")
        UITheme.SetFill(UI.EquipCard, UITheme.Colors.Gold)
        UITheme.SetOutlineColor(UI.EquipCard, UITheme.Colors.TextDark, 1.2)
        UITheme.SetTextColor(UI.EquipText, UITheme.Colors.TextDark)
        UITheme.SetText(UI.EquipText, "EQUIP  [A]")
    end

    if needsIconWarmup and not IconWarmupQueued then
        IconWarmupQueued = true
        Scheduler.Defer("P2Menu.IconWarmup", function()
            IconWarmupQueued = false
            if State.IsOpen then RefreshUI() end
        end, true)
    end
end

function P2Menu.Refresh()
    if State.IsOpen then RefreshUI() end
end

-- ============================================================================
-- OPEN / CLOSE / SCREEN MODE & STRICT P2-ONLY INPUT HANDLING
-- ============================================================================

local function AttachWidgetForScreenMode(p1, p2)
    local isShared = (not ViewportController.IsSplitScreenActive()) or (State.IsLimitedMatchMode == true)
    local targetOwner = isShared and (UObjectUtils.IsLive(p1) and p1 or p2) or p2
    if not EnsureBuilt(targetOwner) then return false end

    local wantedHost = isShared and "Viewport" or "PlayerScreen"
    local inVP = false
    pcall(function() inVP = UI.Widget:IsInViewport() end)

    if inVP and UI.AttachedHost ~= wantedHost then
        ViewportController.RehostingGuard = true
        pcall(function() UI.Widget:RemoveFromParent() end)
        ViewportController.RehostingGuard = false
        inVP = false
    end

    if not inVP then
        ViewportController.RehostingGuard = true
        if isShared then
            pcall(function() UI.Widget:AddToViewport(9940) end)
        else
            local okAdd, added = pcall(function() return UI.Widget:AddToPlayerScreen(60) end)
            if not (okAdd and added) then
                pcall(function() UI.Widget:AddToViewport(9940) end)
            end
        end
        ViewportController.RehostingGuard = false
        UI.AttachedHost = wantedHost
    end

    UpdatePanelAnchors()
    local menuCfg = Config.P2Menu or {}
    local visMode = (menuCfg.ShowMouseCursor == true) and 0 or 3
    pcall(function() UI.Widget:SetVisibility(visMode) end)
    return true
end

function P2Menu.OnScreenModeChanged()
    if not State.IsOpen then return end
    SessionManager.RefreshControllers()
    local p1, p2 = SessionManager.GetP1(), SessionManager.GetP2()
    if p2 then
        AttachWidgetForScreenMode(p1, p2)
        RefreshUI()
    end
end

local function SetPauseAndMusicForMenu(shouldPause)
    if shouldPause then
        State.PausedGameForMenu = true
        State.PausedSongComps = {}
        pcall(function()
            local songComps = FindAllOf("PagodaSongPlayerComponent")
            if songComps then
                for _, sc in pairs(songComps) do
                    if UObjectUtils.IsValid(sc) then
                        local okP, playing = pcall(function() return sc:IsSongPlaying() end)
                        if okP and playing == true then
                            local okPause = pcall(function() sc:PauseSong() end)
                            if okPause then
                                State.PausedSongComps[#State.PausedSongComps + 1] = sc
                            end
                        end
                    end
                end
            end
        end)
        local pausedOk = false
        pcall(function()
            local sub = FindFirstOf("PagodaGamePauseSubsystem")
            if UObjectUtils.IsValid(sub) then
                sub:SetIsPaused(true)
                pausedOk = true
            end
        end)
        if not pausedOk then
            local gs, world = UObjectUtils.GetGameplayStatics(), UObjectUtils.GetWorld()
            if gs and world then pcall(function() gs:SetGamePaused(world, true) end) end
        end
    else
        local wasPaused = State.PausedGameForMenu
        State.PausedGameForMenu = false
        if not wasPaused then return end

        local pausedList = State.PausedSongComps or {}
        State.PausedSongComps = {}
        for _, sc in ipairs(pausedList) do
            if UObjectUtils.IsValid(sc) then
                pcall(function() sc:ResumeSong() end)
            end
        end

        pcall(function()
            local sub = FindFirstOf("PagodaGamePauseSubsystem")
            if UObjectUtils.IsValid(sub) and sub:IsPaused() then
                sub:SetIsPaused(false)
            end
        end)
        local gs, world = UObjectUtils.GetGameplayStatics(), UObjectUtils.GetWorld()
        if gs and world then
            pcall(function()
                if gs:IsGamePaused(world) then gs:SetGamePaused(world, false) end
            end)
        end

        Scheduler.Delay(90, "P2Menu.PostUnpauseSync", function()
            if not SessionManager.IsSafeForGameplayHooks() then return end
            SessionManager.RefreshControllers()
            local p2Pawn = SessionManager.GetP2Pawn()
            if p2Pawn then CharacterApplier.ReassertMeshOnly(p2Pawn) end
            if not InputRouting.IsAnyNativeMenuOpen() then
                InputRouting.RestoreInputForAllPlayers()
            end
            if Callbacks.SyncHUD then UObjectUtils.SafeCall("P2Menu.PostResumeHUD", Callbacks.SyncHUD) end
        end, true)
    end
end

function P2Menu.Open(initialTab, initialSub)
    local menuCfg = Config.P2Menu or {}
    if menuCfg.Enabled == false then return false end
    if InputRouting.IsAnyNativeMenuOpen() then return false end

    SessionManager.RefreshControllers()
    local p1, p2, p2Pawn = SessionManager.GetP1(), SessionManager.GetP2(), SessionManager.GetP2Pawn()
    if not (p2 and p2Pawn) then
        if Callbacks.Notify then
            Callbacks.Notify("Connect Player 2 first (F6 or L3+R3) to open Player 2 Menu", "Warning")
        end
        return false
    end

    local inDiveBar = UObjectUtils.IsInDiveBar(p1)
    if menuCfg.RestrictToDiveBar == true and not inDiveBar then
        if Callbacks.Notify then
            Callbacks.Notify("Player 2 Menu is restricted to the Dive Bar in config.", "Warning")
        end
        return false
    end

    ProfileStore.EnsureP2Initialized(function() return PlayerStateIsolation.CaptureP1Snapshot(p1) end)
    if #CharacterApplier.List == 0 then CharacterApplier.ScanAll() end

    State.IsLimitedMatchMode = (not inDiveBar)
    if type(initialTab) == "number" and initialTab >= 1 and initialTab <= #TAB_DEFS then
        State.TabIndex = initialTab
        State.SubIndex = (type(initialSub) == "number" and initialSub >= 1) and initialSub or 1
        State.SelectedIndex = 1
        State.WindowStart = 1
    end
    if State.IsLimitedMatchMode and State.TabIndex ~= 1 and State.TabIndex ~= 2 and State.TabIndex ~= 5 then
        State.TabIndex = 1
        State.SubIndex = 1
        State.SelectedIndex = 1
        State.WindowStart = 1
    elseif State.IsLimitedMatchMode and State.TabIndex == 1 then
        State.SubIndex = 1
    end

    if not AttachWidgetForScreenMode(p1, p2) then
        return false
    end

    State.IsOpen = true
    State.IsClosing = false
    State.AnimProgress = 0.0
    State.OpenedAt = os.clock()

    if State.IsLimitedMatchMode then
        SetPauseAndMusicForMenu(true)
    end

    ApplyTransitionVisuals(0.0)

    PrevInputs, HoldNextRepeat, PrevButtons = {}, {}, {}
    for _, k in ipairs({
        "Gamepad_Special_Left", "Gamepad_FaceButton_Bottom", "Gamepad_FaceButton_Right",
        "Gamepad_LeftShoulder", "Gamepad_RightShoulder", "Gamepad_LeftTrigger", "Gamepad_RightTrigger",
        "Gamepad_DPad_Up", "Gamepad_DPad_Down", "Gamepad_DPad_Left", "Gamepad_DPad_Right",
        "StickUp", "StickDown", "StickLeft", "StickRight",
        "Enter", "BackSpace", "Escape",
    }) do
        PrevInputs["P2:" .. k] = true
        PrevInputs["KB:" .. k] = true
    end

    InputRouting.SetPlayerInputLock(p2, "LocalCoop.P2MenuOpen", true)
    if Callbacks.SyncHUD then UObjectUtils.SafeCall("P2Menu.OpenHUD", Callbacks.SyncHUD) end
    RefreshUI()
    UITheme.PlayUISound("Open", menuCfg.EnableMenuAudio ~= false)
    return true
end

function P2Menu.Close(immediate)
    if not State.IsOpen and not State.IsClosing then return end
    local menuCfg = Config.P2Menu or {}
    State.IsOpen = false
    State.IsLimitedMatchMode = false
    IconWarmupQueued = false
    UITheme.PlayUISound("Close", menuCfg.EnableMenuAudio ~= false)

    local p2 = SessionManager.GetP2()
    if p2 then
        InputRouting.SetPlayerInputLock(p2, "LocalCoop.P2MenuOpen", false)
    end
    SetPauseAndMusicForMenu(false)
    if Callbacks.SaveProfile then UObjectUtils.SafeCall("P2Menu.Save", Callbacks.SaveProfile) end
    if Callbacks.SyncHUD then UObjectUtils.SafeCall("P2Menu.CloseHUD", Callbacks.SyncHUD) end

    if immediate then
        FinishCloseCleanup()
    else
        State.IsClosing = true
    end
end

function P2Menu.Toggle(tabIdx)
    if State.IsOpen then
        if tabIdx and State.TabIndex ~= tabIdx then
            P2Menu.SelectTab(tabIdx)
            return true
        end
        P2Menu.Close(false)
        return false
    end
    return P2Menu.Open(tabIdx or State.TabIndex or 1)
end

function P2Menu.StepTab(delta)
    if not State.IsLimitedMatchMode then
        P2Menu.SelectTab(State.TabIndex + delta)
        return
    end
    local pos = 1
    for idx, t in ipairs(LIMITED_TABS) do
        if t == State.TabIndex then pos = idx; break end
    end
    local nextPos = ((pos - 1 + delta) % #LIMITED_TABS) + 1
    P2Menu.SelectTab(LIMITED_TABS[nextPos])
end

function P2Menu.SelectTab(tabIdx)
    local menuCfg = Config.P2Menu or {}
    if State.IsLimitedMatchMode then
        if tabIdx ~= 1 and tabIdx ~= 2 and tabIdx ~= 5 then
            tabIdx = 1
        end
    else
        if tabIdx < 1 then tabIdx = #TAB_DEFS end
        if tabIdx > #TAB_DEFS then tabIdx = 1 end
    end
    State.TabIndex = tabIdx
    State.SubIndex = 1
    State.SelectedIndex = 1
    State.WindowStart = 1
    UITheme.PlayUISound("Tab", menuCfg.EnableMenuAudio ~= false)
    RefreshUI()
end

function P2Menu.SelectSub(subIdx)
    local menuCfg = Config.P2Menu or {}
    local n = #State.SubLabels
    if n <= 0 then return end
    if subIdx < 1 then subIdx = 1 end
    if subIdx > n then subIdx = n end
    State.SubIndex = subIdx
    State.SelectedIndex = 1
    State.WindowStart = 1
    UITheme.PlayUISound("Tab", menuCfg.EnableMenuAudio ~= false)
    RefreshUI()
end

function P2Menu.ChangeSub(delta)
    local menuCfg = Config.P2Menu or {}
    local n = #State.SubLabels
    if n <= 1 then return end
    State.SubIndex = ((State.SubIndex - 1 + delta) % n) + 1
    State.SelectedIndex = 1
    State.WindowStart = 1
    UITheme.PlayUISound("Tab", menuCfg.EnableMenuAudio ~= false)
    RefreshUI()
end

function P2Menu.MoveCursor(delta)
    local menuCfg = Config.P2Menu or {}
    local n = #State.Items
    if n <= 0 then return end
    State.SelectedIndex = ((State.SelectedIndex - 1 + delta) % n) + 1
    UITheme.PlayUISound("Hover", menuCfg.EnableMenuAudio ~= false)
    RefreshUI()
end

function P2Menu.ActivateSelected()
    local menuCfg = Config.P2Menu or {}
    local now = os.clock()
    if (now - State.LastActivateAt) < 0.22 then return false end
    State.LastActivateAt = now
    local item = State.Items[State.SelectedIndex]
    if item and type(item.OnActivate) == "function" then
        UITheme.PlayUISound("Confirm", menuCfg.EnableMenuAudio ~= false)
        UObjectUtils.SafeCall("P2Menu.Activate", item.OnActivate)
        if Callbacks.SaveProfile then UObjectUtils.SafeCall("P2Menu.Save", Callbacks.SaveProfile) end
        RefreshUI()
        return true
    end
    return false
end

function P2Menu.OnWorldChanged()
    if State.IsOpen or State.IsClosing then P2Menu.Close(true) end
    State.IsClosing = false
    State.PausedGameForMenu = false
    State.PausedSongComps = {}
    IconWarmupQueued = false
    P2Menu.DestroyWidget()
end

-- ============================================================================
-- SINGLE AUTHORITATIVE P2-ONLY INPUT POLLING (DEADZONE + AXIS DOMINANCE)
-- ============================================================================

local function EvalDigitalEdge(keyId, isDown, now, allowRepeat)
    local was = (PrevInputs[keyId] == true)
    PrevInputs[keyId] = (isDown == true)
    if isDown and not was then
        if allowRepeat then HoldNextRepeat[keyId] = now + 0.32 end
        return true
    elseif isDown and was and allowRepeat then
        if now >= (HoldNextRepeat[keyId] or (now + 0.32)) then
            HoldNextRepeat[keyId] = now + 0.11
            return true
        end
    else
        HoldNextRepeat[keyId] = nil
    end
    return false
end

local function KeyEdge(pc, prefix, keyName, now, allowRepeat)
    if not UObjectUtils.IsLive(pc) then return false end
    local down = false
    pcall(function() down = (pc:IsInputKeyDown(GetKeyStruct(keyName)) == true) end)
    return EvalDigitalEdge(prefix .. ":" .. keyName, down, now, allowRepeat)
end

local function ReadStickAxes(p2Ctrl)
    local lx, ly = 0.0, 0.0
    pcall(function()
        lx = tonumber(p2Ctrl:GetInputAnalogKeyState(GetKeyStruct("Gamepad_LeftX"))) or 0.0
        ly = tonumber(p2Ctrl:GetInputAnalogKeyState(GetKeyStruct("Gamepad_LeftY"))) or 0.0
    end)
    return lx, ly
end

local function BtnClicked(key, btn)
    if not UObjectUtils.IsValid(btn) then return false end
    local pressed = false
    pcall(function() pressed = (btn:IsPressed() == true) end)
    local was = (PrevButtons[key] == true)
    PrevButtons[key] = pressed
    return pressed and not was
end

function P2Menu.TickInput(now)
    if not State.IsOpen then return end

    local p1, p2 = SessionManager.GetP1(), SessionManager.GetP2()
    local menuCfg = Config.P2Menu or {}
    local inCfg = Config.Input or {}

    if not UObjectUtils.IsGameplayWorld()
        or (InputRouting.IsGamePaused() and not State.PausedGameForMenu)
        or InputRouting.HasAnyActiveMenuOnStack()
        or SessionManager.State.IsInCutscene
        or not p2
        or (menuCfg.RestrictToDiveBar == true and not UObjectUtils.IsInDiveBar(p1)) then
        P2Menu.Close(true)
        return
    end
    if (now - State.OpenedAt) < 0.15 then return end

    if State.PausedGameForMenu and p1 and KeyEdge(p1, "KB", "Escape", now, false) then
        P2Menu.Close(false)
        return
    end

    -- 360-degree Right Stick preview spin on P2's Pawn ONLY
    pcall(function()
        local p2Pawn = SessionManager.GetP2Pawn()
        if p2Pawn then
            local rx = 0.0
            pcall(function() rx = tonumber(p2:GetInputAnalogKeyState(GetKeyStruct("Gamepad_RightX"))) or 0.0 end)
            local spin = 0.0
            if math.abs(rx) > 0.35 then
                spin = rx * 3.8
            elseif p2:IsInputKeyDown(GetKeyStruct("Gamepad_RightStick_Left")) then
                spin = -3.4
            elseif p2:IsInputKeyDown(GetKeyStruct("Gamepad_RightStick_Right")) then
                spin = 3.4
            end
            if spin ~= 0.0 then
                local r = p2Pawn:K2_GetActorRotation()
                r.Yaw = r.Yaw + spin
                p2Pawn:K2_SetActorRotation(r, false)
            end
        end
    end)

    -- Poll P2's PlayerController exclusively.
    local toggleKey = inCfg.GamepadMenuToggleKey or "Gamepad_Special_Left"
    if KeyEdge(p2, "P2", "Gamepad_FaceButton_Right", now, false)
        or KeyEdge(p2, "P2", toggleKey, now, false) then
        P2Menu.Close(false)
        return
    end
    if KeyEdge(p2, "P2", "Gamepad_LeftShoulder", now, false) then
        P2Menu.StepTab(-1)
        return
    end
    if KeyEdge(p2, "P2", "Gamepad_RightShoulder", now, false) then
        P2Menu.StepTab(1)
        return
    end

    -- Deadzone (0.55) + 1.4x axis dominance on Left Stick so diagonals never misfire
    local lx, ly = ReadStickAxes(p2)
    local stickUp = (ly > 0.55) and (math.abs(ly) > math.abs(lx) * 1.4)
    local stickDown = (ly < -0.55) and (math.abs(ly) > math.abs(lx) * 1.4)
    local stickLeft = (lx < -0.55) and (math.abs(lx) > math.abs(ly) * 1.4)
    local stickRight = (lx > 0.55) and (math.abs(lx) > math.abs(ly) * 1.4)

    if KeyEdge(p2, "P2", "Gamepad_DPad_Up", now, true) or EvalDigitalEdge("P2:StickUp", stickUp, now, true) then
        P2Menu.MoveCursor(-1)
        return
    end
    if KeyEdge(p2, "P2", "Gamepad_DPad_Down", now, true) or EvalDigitalEdge("P2:StickDown", stickDown, now, true) then
        P2Menu.MoveCursor(1)
        return
    end
    if KeyEdge(p2, "P2", "Gamepad_DPad_Left", now, true)
        or KeyEdge(p2, "P2", "Gamepad_LeftTrigger", now, false)
        or EvalDigitalEdge("P2:StickLeft", stickLeft, now, true) then
        P2Menu.ChangeSub(-1)
        return
    end
    if KeyEdge(p2, "P2", "Gamepad_DPad_Right", now, true)
        or KeyEdge(p2, "P2", "Gamepad_RightTrigger", now, false)
        or EvalDigitalEdge("P2:StickRight", stickRight, now, true) then
        P2Menu.ChangeSub(1)
        return
    end
    if KeyEdge(p2, "P2", "Gamepad_FaceButton_Bottom", now, false) then
        P2Menu.ActivateSelected()
        return
    end

    -- Optional keyboard fallback ONLY when explicitly enabled (OFF by default -> zero P1 bleed)
    if menuCfg.AllowKeyboardNavigation == true and p1 then
        if KeyEdge(p1, "KB", "BackSpace", now, false) then P2Menu.Close(false); return end
        if KeyEdge(p1, "KB", "PageUp", now, false) then P2Menu.StepTab(-1); return end
        if KeyEdge(p1, "KB", "PageDown", now, false) then P2Menu.StepTab(1); return end
        if KeyEdge(p1, "KB", "Up", now, true) then P2Menu.MoveCursor(-1); return end
        if KeyEdge(p1, "KB", "Down", now, true) then P2Menu.MoveCursor(1); return end
        if KeyEdge(p1, "KB", "Left", now, true) then P2Menu.ChangeSub(-1); return end
        if KeyEdge(p1, "KB", "Right", now, true) then P2Menu.ChangeSub(1); return end
        if KeyEdge(p1, "KB", "Enter", now, false) then P2Menu.ActivateSelected(); return end
    end

    -- Optional mouse click support when enabled
    if menuCfg.ShowMouseCursor == true then
        if BtnClicked("close", UI.CloseBtn) then P2Menu.Close(false); return end
        if BtnClicked("prev", UI.SubPrevBtn) then P2Menu.ChangeSub(-1); return end
        if BtnClicked("next", UI.SubNextBtn) then P2Menu.ChangeSub(1); return end
        if BtnClicked("scrollUp", UI.ScrollUpBtn) then P2Menu.MoveCursor(-1); return end
        if BtnClicked("scrollDown", UI.ScrollDownBtn) then P2Menu.MoveCursor(1); return end
        if BtnClicked("equip", UI.EquipBtn) then P2Menu.ActivateSelected(); return end
        for i = 1, #TAB_DEFS do
            if BtnClicked("nav" .. i, UI.NavButtons[i]) then P2Menu.SelectTab(i); return end
        end
        if State.TabIndex == 2 or State.TabIndex == 3 then
            for nodeIdx = 1, 5 do
                if BtnClicked("diamond" .. nodeIdx, UI.SlotButtons[nodeIdx]) then
                    if State.TabIndex == 3 and nodeIdx <= 4 then
                        P2Menu.SelectSub(nodeIdx)
                    elseif State.TabIndex == 2 then
                        P2Menu.SelectSub(nodeIdx == 5 and 1 or (nodeIdx + 1))
                    end
                    return
                end
            end
        end
        for p = 1, MAX_SUB_PILLS do
            if State.SubLabels[p] and BtnClicked("subpill" .. p, UI.SubPillButtons[p]) then
                P2Menu.SelectSub(p)
                return
            end
        end
        for r = 1, VISIBLE_ROWS do
            local idx = State.WindowStart + r - 1
            if State.Items[idx] and UObjectUtils.IsValid(UI.RowButtons[r]) then
                local hov = false
                pcall(function() hov = (UI.RowButtons[r]:IsHovered() == true) end)
                if hov and State.SelectedIndex ~= idx then
                    State.SelectedIndex = idx
                    RefreshUI()
                end
                if BtnClicked("row" .. r, UI.RowButtons[r]) then
                    State.SelectedIndex = idx
                    P2Menu.ActivateSelected()
                    return
                end
            end
        end
    end
end

return P2Menu
