local UEHelpers = require("UEHelpers")

local P2Menu = {}

-- ============================================================================
-- MODULE STATE
-- ============================================================================

local API = nil
local Config = nil

local VISIBLE_ROWS = 8

local MenuState = {
    IsOpen = false,
    TabIndex = 1,          -- 1=Outfits, 2=Dances, 3=BossSkills, 4=Upgrades, 5=Character
    SubIndex = 1,          -- Sub-category / target slot within current tab
    SelectedIndex = 1,     -- 1-based index into CurrentItems
    WindowStart = 1,       -- 1-based scroll window start
    CurrentItems = {},
    SubCategories = {},
    MenuOpenedAt = 0.0,
    LastActivateTime = 0.0,
}

-- Cached UMG widget references (pooled once per World/Controller)
local UI = {
    MenuWidget = nil,
    OwnerPC = nil,
    World = nil,
    PanelSlot = nil,
    OuterBorder = nil,
    InnerBorder = nil,
    TitleText = nil,
    SubtitleText = nil,
    CloseBtn = nil,
    CloseBorder = nil,
    CloseText = nil,
    TabButtons = {},
    TabBorders = {},
    TabTexts = {},
    SubPrevBtn = nil,
    SubPrevBorder = nil,
    SubPrevText = nil,
    SubNextBtn = nil,
    SubNextBorder = nil,
    SubNextText = nil,
    SubTitleText = nil,
    RowButtons = {},
    RowBorders = {},
    RowNameTexts = {},
    RowBadgeTexts = {},
    PageInfoText = nil,
    -- Enhanced Skill / Cosmetic Details Showcase Card
    DetailBorder = nil,
    DetailIdolBadgeText = nil,
    DetailTitleText = nil,
    DetailMetaBadgeText = nil,
    DetailDescText = nil,
    FooterHintText = nil,
    EquipBtn = nil,
    EquipBorder = nil,
    EquipText = nil,
}

-- Edge-detection & repeat state for controller/keyboard/mouse polling
local PrevKeyStates = {}
local KeyHoldNextRepeat = {}
local PrevButtonPressed = {}

local TAB_DEFS = {
    { Id = "outfits",   Label = "1. OUTFITS" },
    { Id = "dances",    Label = "2. DANCES" },
    { Id = "boss",      Label = "3. BOSS SKILLS" },
    { Id = "upgrades",  Label = "4. UPGRADES" },
    { Id = "character", Label = "5. CHARACTER" },
}

-- ============================================================================
-- COLOR PALETTES (DEAD AS DISCO THEMATIC COLORS)
-- ============================================================================

local PALETTE = {
    -- Disco Brand Colors
    Magenta       = { R = 1.00, G = 0.10, B = 0.65, A = 1.00 },
    MagentaGlow   = { R = 0.90, G = 0.08, B = 0.55, A = 0.35 },
    Cyan          = { R = 0.00, G = 0.94, B = 1.00, A = 1.00 },
    CyanSelected  = { R = 0.02, G = 0.28, B = 0.36, A = 0.92 },
    Gold          = { R = 1.00, G = 0.85, B = 0.15, A = 1.00 },
    Emerald       = { R = 0.20, G = 1.00, B = 0.55, A = 1.00 },
    Orange        = { R = 1.00, G = 0.35, B = 0.12, A = 1.00 },
    Violet        = { R = 0.68, G = 0.30, B = 1.00, A = 1.00 },

    -- Background Obsidian
    DarkGlass     = { R = 0.035, G = 0.025, B = 0.065, A = 0.95 },
    DarkCard      = { R = 0.065, G = 0.050, B = 0.120, A = 0.88 },
    CardBorder    = { R = 0.16,  G = 0.13,  B = 0.28,  A = 0.90 },
    TextWhite     = { R = 0.95,  G = 0.96,  B = 1.00,  A = 1.00 },
    TextMuted     = { R = 0.68,  G = 0.72,  B = 0.85,  A = 0.90 },
    TextHint      = { R = 0.55,  G = 0.62,  B = 0.76,  A = 0.85 },
}

-- ============================================================================
-- SAFE UMG HELPERS
-- ============================================================================

local function IsValid(obj)
    return API and API.IsValidObj(obj)
end

local function CleanDescriptionTags(raw)
    if type(raw) ~= "string" or raw == "" then return "" end
    local s = raw
    -- Clean Unreal Engine / Pagoda RichText tags into clean human-readable text
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

local function SetWidgetText(txtWidget, str)
    if not IsValid(txtWidget) then return end
    local safeStr = tostring(str or "")
    pcall(function()
        txtWidget:SetText(FText(safeStr))
    end)
end

local function SetTextColor(txtWidget, color)
    if not IsValid(txtWidget) or not color then return end
    pcall(function()
        txtWidget:SetColorAndOpacity({
            SpecifiedColor = { R = color.R or 1.0, G = color.G or 1.0, B = color.B or 1.0, A = color.A or 1.0 },
            ColorUseRule = 0,
        })
    end)
end

local function SetBorderColor(borderWidget, color)
    if not IsValid(borderWidget) or not color then return end
    pcall(function()
        borderWidget:SetBrushColor({ R = color.R or 1.0, G = color.G or 1.0, B = color.B or 1.0, A = color.A or 1.0 })
    end)
end

local function StyleTextBlock(txtWidget, fontSize, fontObjPath, color, autoWrap)
    if not IsValid(txtWidget) then return end
    pcall(function()
        local fObj = nil
        if fontObjPath then
            fObj = StaticFindObject(fontObjPath)
        end
        if not IsValid(fObj) then
            fObj = StaticFindObject("/Game/Pagoda/UI/Fonts/BodyText_Font.BodyText_Font")
        end
        if IsValid(fObj) then
            txtWidget.Font.FontObject = fObj
        end
        txtWidget.Font.Size = fontSize or 12
        txtWidget:SetFont(txtWidget.Font)
    end)
    pcall(function()
        txtWidget:SetShadowOffset({ X = 1.2, Y = 1.2 })
        txtWidget:SetShadowColorAndOpacity({ R = 0.0, G = 0.0, B = 0.0, A = 0.90 })
    end)
    if autoWrap then
        pcall(function() txtWidget:SetAutoWrapText(true) end)
    end
    if color then
        SetTextColor(txtWidget, color)
    end
end

local function MakeInvisibleButton(wt, btnClass, borderClass, padL, padT, padR, padB)
    local btn = StaticConstructObject(btnClass, wt)
    local border = StaticConstructObject(borderClass, wt)
    pcall(function()
        btn.IsFocusable = false
        btn:SetBackgroundColor({ R = 1.0, G = 1.0, B = 1.0, A = 0.0 })
        border:SetPadding({ Left = padL or 8, Top = padT or 4, Right = padR or 8, Bottom = padB or 4 })
        btn:AddChild(border)
    end)
    return btn, border
end

-- Docks the Studio Menu strictly to the LEFT side so Player 2 in the center remains 100% visible!
local function UpdatePanelAnchorsForScreenMode()
    if not IsValid(UI.PanelSlot) then return end
    local mode = API.GetCurrentScreenMode()

    -- Default: Horizontal Split-Screen (Mode 0) or Wide aspect:
    -- Dock on LEFT (MinX=0.02 to MaxX=0.44), leaving 0.45..0.98 wide open for Player 2's character model!
    local minX, minY, maxX, maxY = 0.02, 0.02, 0.44, 0.98

    if mode == 1 then
        -- Vertical Split-Screen (Mode 1, 8:9 tall column):
        -- Dock on left 62% of Player 2's column, keeping Player 2 visible on the right half
        minX, minY, maxX, maxY = 0.02, 0.02, 0.62, 0.98
    elseif mode == 2 then
        -- Shared Single Screen (Mode 2, 16:9 full screen):
        -- Dock as a clean left sidebar (MinX=0.02 to MaxX=0.38)
        minX, minY, maxX, maxY = 0.02, 0.04, 0.38, 0.96
    end

    pcall(function()
        UI.PanelSlot:SetAnchors({
            Minimum = { X = minX, Y = minY },
            Maximum = { X = maxX, Y = maxY },
        })
        UI.PanelSlot:SetOffsets({ Left = 0.0, Top = 0.0, Right = 0.0, Bottom = 0.0 })
    end)
end

-- ============================================================================
-- DYNAMIC UMG WIDGET TREE CONSTRUCTION
-- ============================================================================

local function DestroyMenuWidget()
    if IsValid(UI.MenuWidget) then
        pcall(function() UI.MenuWidget:RemoveFromParent() end)
    end
    UI.MenuWidget = nil
    UI.OwnerPC = nil
    UI.World = nil
    UI.PanelSlot = nil
    UI.OuterBorder = nil
    UI.InnerBorder = nil
    UI.TitleText = nil
    UI.SubtitleText = nil
    UI.CloseBtn = nil
    UI.CloseBorder = nil
    UI.CloseText = nil
    UI.TabButtons = {}
    UI.TabBorders = {}
    UI.TabTexts = {}
    UI.SubPrevBtn = nil
    UI.SubPrevBorder = nil
    UI.SubPrevText = nil
    UI.SubNextBtn = nil
    UI.SubNextBorder = nil
    UI.SubNextText = nil
    UI.SubTitleText = nil
    UI.RowButtons = {}
    UI.RowBorders = {}
    UI.RowNameTexts = {}
    UI.RowBadgeTexts = {}
    UI.PageInfoText = nil
    UI.DetailBorder = nil
    UI.DetailIdolBadgeText = nil
    UI.DetailTitleText = nil
    UI.DetailMetaBadgeText = nil
    UI.DetailDescText = nil
    UI.FooterHintText = nil
    UI.EquipBtn = nil
    UI.EquipBorder = nil
    UI.EquipText = nil
    PrevButtonPressed = {}
end

local function EnsureMenuWidgetBuilt(p2Controller)
    local inGameplay, world = API.IsGameplayWorld()
    if not inGameplay or not IsValid(world) or not API.IsLiveWorldObject(p2Controller) then
        return false
    end

    if IsValid(UI.MenuWidget)
        and API.SameUObject(UI.OwnerPC, p2Controller)
        and API.SameUObject(UI.World, world) then
        UpdatePanelAnchorsForScreenMode()
        return true
    end

    DestroyMenuWidget()

    local okBuild, built = pcall(function()
        local wbl = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
        local uwClass = StaticFindObject("/Script/UMG.UserWidget")
        local canvasClass = StaticFindObject("/Script/UMG.CanvasPanel")
        local borderClass = StaticFindObject("/Script/UMG.Border")
        local vboxClass = StaticFindObject("/Script/UMG.VerticalBox")
        local hboxClass = StaticFindObject("/Script/UMG.HorizontalBox")
        local textClass = StaticFindObject("/Script/UMG.TextBlock")
        local btnClass = StaticFindObject("/Script/UMG.Button")

        if not (IsValid(wbl) and IsValid(uwClass) and IsValid(canvasClass)
            and IsValid(borderClass) and IsValid(vboxClass) and IsValid(hboxClass)
            and IsValid(textClass) and IsValid(btnClass)) then
            return false
        end

        local uw = wbl:Create(world, uwClass, p2Controller)
        if not IsValid(uw) then return false end
        local wt = uw.WidgetTree
        if not IsValid(wt) then return false end

        local rootCanvas = StaticConstructObject(canvasClass, wt)
        wt.RootWidget = rootCanvas

        -- Outer neon disco border (Hot Pink / Magenta outline)
        local outerBorder = StaticConstructObject(borderClass, wt)
        SetBorderColor(outerBorder, PALETTE.Magenta)
        outerBorder:SetPadding({ Left = 2, Top = 2, Right = 2, Bottom = 2 })

        local panelSlot = rootCanvas:AddChildToCanvas(outerBorder)
        UI.PanelSlot = panelSlot
        UI.OuterBorder = outerBorder
        UpdatePanelAnchorsForScreenMode()
        pcall(function() panelSlot:SetZOrder(60) end)

        -- Inner dark club obsidian translucent container
        local innerBorder = StaticConstructObject(borderClass, wt)
        SetBorderColor(innerBorder, PALETTE.DarkGlass)
        innerBorder:SetPadding({ Left = 12, Top = 8, Right = 12, Bottom = 8 })
        outerBorder:SetContent(innerBorder)
        UI.InnerBorder = innerBorder

        local mainVBox = StaticConstructObject(vboxClass, wt)
        innerBorder:SetContent(mainVBox)

        -- =====================================================================
        -- 1. HEADER BAR (Disco Brand Title + Close Action)
        -- =====================================================================
        local headerHBox = StaticConstructObject(hboxClass, wt)
        local headerSlot = mainVBox:AddChildToVerticalBox(headerHBox)
        pcall(function() headerSlot:SetPadding({ Left = 0, Top = 0, Right = 0, Bottom = 4 }) end)

        local titleVBox = StaticConstructObject(vboxClass, wt)
        local titleVBoxSlot = headerHBox:AddChildToHorizontalBox(titleVBox)
        pcall(function()
            titleVBoxSlot:SetSize({ Value = 1.0, SizeRule = 1 })
            titleVBoxSlot:SetVerticalAlignment(2)
        end)

        local titleTxt = StaticConstructObject(textClass, wt)
        StyleTextBlock(titleTxt, 15, "/Game/Pagoda/UI/Fonts/Primary_Font.Primary_Font", PALETTE.Magenta, false)
        SetWidgetText(titleTxt, "PLAYER 2 STUDIO  //  DEAD AS DISCO")
        titleVBox:AddChildToVerticalBox(titleTxt)
        UI.TitleText = titleTxt

        local subtitleTxt = StaticConstructObject(textClass, wt)
        StyleTextBlock(subtitleTxt, 10, "/Game/Pagoda/UI/Fonts/Secondary_Font.Secondary_Font", PALETTE.Cyan, false)
        SetWidgetText(subtitleTxt, "CUSTOM WARDROBE & BATTLE ABILITIES")
        titleVBox:AddChildToVerticalBox(subtitleTxt)
        UI.SubtitleText = subtitleTxt

        local closeBtn, closeBorder = MakeInvisibleButton(wt, btnClass, borderClass, 10, 3, 10, 3)
        SetBorderColor(closeBorder, { R = 0.70, G = 0.12, B = 0.28, A = 0.95 })
        local closeTxt = StaticConstructObject(textClass, wt)
        StyleTextBlock(closeTxt, 11, "/Game/Pagoda/UI/Fonts/Secondary_Font.Secondary_Font", PALETTE.TextWhite, false)
        SetWidgetText(closeTxt, "[ B / CLOSE ]")
        closeBorder:SetContent(closeTxt)
        local closeHSlot = headerHBox:AddChildToHorizontalBox(closeBtn)
        pcall(function() closeHSlot:SetVerticalAlignment(2) end)
        UI.CloseBtn = closeBtn
        UI.CloseBorder = closeBorder
        UI.CloseText = closeTxt

        -- =====================================================================
        -- 2. TAB BAR (LB / 5 Authentic Tabs / RB)
        -- =====================================================================
        local tabHBox = StaticConstructObject(hboxClass, wt)
        local tabVSlot = mainVBox:AddChildToVerticalBox(tabHBox)
        pcall(function() tabVSlot:SetPadding({ Left = 0, Top = 2, Right = 0, Bottom = 5 }) end)

        local lbHint = StaticConstructObject(textClass, wt)
        StyleTextBlock(lbHint, 11, "/Game/Pagoda/UI/Fonts/Secondary_Font.Secondary_Font", PALETTE.Cyan, false)
        SetWidgetText(lbHint, "[LB] ")
        local lbSlot = tabHBox:AddChildToHorizontalBox(lbHint)
        pcall(function() lbSlot:SetVerticalAlignment(2) end)

        for i, tDef in ipairs(TAB_DEFS) do
            local tBtn, tBorder = MakeInvisibleButton(wt, btnClass, borderClass, 6, 4, 6, 4)
            local tTxt = StaticConstructObject(textClass, wt)
            StyleTextBlock(tTxt, 11, "/Game/Pagoda/UI/Fonts/Secondary_Font.Secondary_Font", PALETTE.TextWhite, false)
            SetWidgetText(tTxt, tDef.Label)
            pcall(function() tTxt:SetJustification(1) end)
            tBorder:SetContent(tTxt)

            local thSlot = tabHBox:AddChildToHorizontalBox(tBtn)
            pcall(function()
                thSlot:SetSize({ Value = 1.0, SizeRule = 1 })
                thSlot:SetPadding({ Left = 2, Top = 0, Right = 2, Bottom = 0 })
            end)

            UI.TabButtons[i] = tBtn
            UI.TabBorders[i] = tBorder
            UI.TabTexts[i] = tTxt
        end

        local rbHint = StaticConstructObject(textClass, wt)
        StyleTextBlock(rbHint, 11, "/Game/Pagoda/UI/Fonts/Secondary_Font.Secondary_Font", PALETTE.Cyan, false)
        SetWidgetText(rbHint, " [RB]")
        local rbSlot = tabHBox:AddChildToHorizontalBox(rbHint)
        pcall(function() rbSlot:SetVerticalAlignment(2) end)

        -- =====================================================================
        -- 3. SUB-CATEGORY / SLOT SELECTOR BAR
        -- =====================================================================
        local subOuterBorder = StaticConstructObject(borderClass, wt)
        SetBorderColor(subOuterBorder, PALETTE.DarkCard)
        subOuterBorder:SetPadding({ Left = 6, Top = 3, Right = 6, Bottom = 3 })
        local subVSlot = mainVBox:AddChildToVerticalBox(subOuterBorder)
        pcall(function() subVSlot:SetPadding({ Left = 0, Top = 0, Right = 0, Bottom = 5 }) end)

        local subHBox = StaticConstructObject(hboxClass, wt)
        subOuterBorder:SetContent(subHBox)

        local prevBtn, prevBorder = MakeInvisibleButton(wt, btnClass, borderClass, 8, 2, 8, 2)
        SetBorderColor(prevBorder, PALETTE.CardBorder)
        local prevTxt = StaticConstructObject(textClass, wt)
        StyleTextBlock(prevTxt, 11, "/Game/Pagoda/UI/Fonts/Secondary_Font.Secondary_Font", PALETTE.Cyan, false)
        SetWidgetText(prevTxt, "< D-Pad [X]")
        prevBorder:SetContent(prevTxt)
        subHBox:AddChildToHorizontalBox(prevBtn)
        UI.SubPrevBtn = prevBtn
        UI.SubPrevBorder = prevBorder
        UI.SubPrevText = prevTxt

        local subTitleTxt = StaticConstructObject(textClass, wt)
        StyleTextBlock(subTitleTxt, 12, "/Game/Pagoda/UI/Fonts/Secondary_Font.Secondary_Font", PALETTE.Gold, false)
        pcall(function() subTitleTxt:SetJustification(1) end)
        SetWidgetText(subTitleTxt, "CATEGORY")
        local subCenterSlot = subHBox:AddChildToHorizontalBox(subTitleTxt)
        pcall(function()
            subCenterSlot:SetSize({ Value = 1.0, SizeRule = 1 })
            subCenterSlot:SetVerticalAlignment(2)
        end)
        UI.SubTitleText = subTitleTxt

        local nextBtn, nextBorder = MakeInvisibleButton(wt, btnClass, borderClass, 8, 2, 8, 2)
        SetBorderColor(nextBorder, PALETTE.CardBorder)
        local nextTxt = StaticConstructObject(textClass, wt)
        StyleTextBlock(nextTxt, 11, "/Game/Pagoda/UI/Fonts/Secondary_Font.Secondary_Font", PALETTE.Cyan, false)
        SetWidgetText(nextTxt, "[X] D-Pad >")
        nextBorder:SetContent(nextTxt)
        subHBox:AddChildToHorizontalBox(nextBtn)
        UI.SubNextBtn = nextBtn
        UI.SubNextBorder = nextBorder
        UI.SubNextText = nextTxt

        -- =====================================================================
        -- 4. ITEM LIST (8 POOLED HIGH-CONTRAST ROWS)
        -- =====================================================================
        local listVBox = StaticConstructObject(vboxClass, wt)
        local listVSlot = mainVBox:AddChildToVerticalBox(listVBox)
        pcall(function()
            listVSlot:SetSize({ Value = 1.0, SizeRule = 1 })
            listVSlot:SetPadding({ Left = 0, Top = 0, Right = 0, Bottom = 3 })
        end)

        for r = 1, VISIBLE_ROWS do
            local rBtn, rBorder = MakeInvisibleButton(wt, btnClass, borderClass, 8, 3, 8, 3)
            SetBorderColor(rBorder, PALETTE.DarkCard)

            local rHBox = StaticConstructObject(hboxClass, wt)
            rBorder:SetContent(rHBox)

            local rNameTxt = StaticConstructObject(textClass, wt)
            StyleTextBlock(rNameTxt, 12, "/Game/Pagoda/UI/Fonts/BodyText_Font.BodyText_Font", PALETTE.TextWhite, false)
            SetWidgetText(rNameTxt, "")
            local rNameSlot = rHBox:AddChildToHorizontalBox(rNameTxt)
            pcall(function()
                rNameSlot:SetSize({ Value = 1.0, SizeRule = 1 })
                rNameSlot:SetVerticalAlignment(2)
            end)

            local rBadgeTxt = StaticConstructObject(textClass, wt)
            StyleTextBlock(rBadgeTxt, 11, "/Game/Pagoda/UI/Fonts/Secondary_Font.Secondary_Font", PALETTE.Emerald, false)
            SetWidgetText(rBadgeTxt, "")
            local rBadgeSlot = rHBox:AddChildToHorizontalBox(rBadgeTxt)
            pcall(function() rBadgeSlot:SetVerticalAlignment(2) end)

            local rVSlot = listVBox:AddChildToVerticalBox(rBtn)
            pcall(function()
                rVSlot:SetPadding({ Left = 0, Top = 1, Right = 0, Bottom = 1 })
            end)

            UI.RowButtons[r] = rBtn
            UI.RowBorders[r] = rBorder
            UI.RowNameTexts[r] = rNameTxt
            UI.RowBadgeTexts[r] = rBadgeTxt
        end

        local pageTxt = StaticConstructObject(textClass, wt)
        StyleTextBlock(pageTxt, 10, "/Game/Pagoda/UI/Fonts/BodyText_Font.BodyText_Font", PALETTE.TextHint, false)
        SetWidgetText(pageTxt, "")
        local pageSlot = mainVBox:AddChildToVerticalBox(pageTxt)
        pcall(function() pageSlot:SetPadding({ Left = 2, Top = 0, Right = 2, Bottom = 3 }) end)
        UI.PageInfoText = pageTxt

        -- =====================================================================
        -- 5. ENHANCED SKILL / COSMETIC SHOWCASE CARD
        -- =====================================================================
        local detailBorder = StaticConstructObject(borderClass, wt)
        SetBorderColor(detailBorder, PALETTE.DarkCard)
        detailBorder:SetPadding({ Left = 10, Top = 6, Right = 10, Bottom = 6 })
        local detailVSlot = mainVBox:AddChildToVerticalBox(detailBorder)
        pcall(function() detailVSlot:SetPadding({ Left = 0, Top = 0, Right = 0, Bottom = 4 }) end)
        UI.DetailBorder = detailBorder

        local detailVBox = StaticConstructObject(vboxClass, wt)
        detailBorder:SetContent(detailVBox)

        -- Idol Badge Banner (e.g. [ SHRED // LIGHTNING ])
        local dIdol = StaticConstructObject(textClass, wt)
        StyleTextBlock(dIdol, 11, "/Game/Pagoda/UI/Fonts/Secondary_Font.Secondary_Font", PALETTE.Cyan, false)
        SetWidgetText(dIdol, "")
        detailVBox:AddChildToVerticalBox(dIdol)
        UI.DetailIdolBadgeText = dIdol

        -- Large Title (e.g. THUNDERSTRUCK)
        local dTitle = StaticConstructObject(textClass, wt)
        StyleTextBlock(dTitle, 13, "/Game/Pagoda/UI/Fonts/Primary_Font.Primary_Font", PALETTE.Gold, false)
        SetWidgetText(dTitle, "")
        detailVBox:AddChildToVerticalBox(dTitle)
        UI.DetailTitleText = dTitle

        -- Meta / Slot Tag (e.g. BOSS ABILITY • SLOT 1 • FEVER: 1 BAR)
        local dMeta = StaticConstructObject(textClass, wt)
        StyleTextBlock(dMeta, 10, "/Game/Pagoda/UI/Fonts/Secondary_Font.Secondary_Font", PALETTE.Magenta, false)
        SetWidgetText(dMeta, "")
        detailVBox:AddChildToVerticalBox(dMeta)
        UI.DetailMetaBadgeText = dMeta

        -- Rich Clean Formatted Description
        local dDesc = StaticConstructObject(textClass, wt)
        StyleTextBlock(dDesc, 11, "/Game/Pagoda/UI/Fonts/BodyText_Font.BodyText_Font", PALETTE.TextWhite, true)
        SetWidgetText(dDesc, "")
        local dDescSlot = detailVBox:AddChildToVerticalBox(dDesc)
        pcall(function() dDescSlot:SetPadding({ Left = 0, Top = 2, Right = 0, Bottom = 0 }) end)
        UI.DetailDescText = dDesc

        -- =====================================================================
        -- 6. FOOTER CONTROLS & ACTION BUTTON
        -- =====================================================================
        local footerHBox = StaticConstructObject(hboxClass, wt)
        local footerSlot = mainVBox:AddChildToVerticalBox(footerHBox)
        pcall(function() footerSlot:SetPadding({ Left = 0, Top = 2, Right = 0, Bottom = 0 }) end)

        local hintTxt = StaticConstructObject(textClass, wt)
        StyleTextBlock(hintTxt, 10, "/Game/Pagoda/UI/Fonts/BodyText_Font.BodyText_Font", PALETTE.TextHint, false)
        SetWidgetText(hintTxt, "[A] Equip  |  [X] Category/Slot  |  [Right Stick] Rotate P2  |  [B] Close")
        local hintSlot = footerHBox:AddChildToHorizontalBox(hintTxt)
        pcall(function()
            hintSlot:SetSize({ Value = 1.0, SizeRule = 1 })
            hintSlot:SetVerticalAlignment(2)
        end)
        UI.FooterHintText = hintTxt

        local eqBtn, eqBorder = MakeInvisibleButton(wt, btnClass, borderClass, 12, 3, 12, 3)
        SetBorderColor(eqBorder, PALETTE.Emerald)
        local eqTxt = StaticConstructObject(textClass, wt)
        StyleTextBlock(eqTxt, 11, "/Game/Pagoda/UI/Fonts/Secondary_Font.Secondary_Font", { R = 0.05, G = 0.20, B = 0.10, A = 1.0 }, false)
        SetWidgetText(eqTxt, "[ A / EQUIP ]")
        eqBorder:SetContent(eqTxt)
        local eqSlot = footerHBox:AddChildToHorizontalBox(eqBtn)
        pcall(function() eqSlot:SetVerticalAlignment(2) end)
        UI.EquipBtn = eqBtn
        UI.EquipBorder = eqBorder
        UI.EquipText = eqTxt

        UI.MenuWidget = uw
        UI.OwnerPC = p2Controller
        UI.World = world
        return true
    end)

    return okBuild and built == true and IsValid(UI.MenuWidget)
end

-- ============================================================================
-- DATA MODEL BUILDERS PER TAB
-- ============================================================================

local OUTFIT_SUBS = {
    { Kind = "presets", Label = "Full Outfit Presets", Slot = 0 },
    { Kind = "slot",    Label = "Jackets",             Slot = 2 },
    { Kind = "slot",    Label = "Hair & Headgear",     Slot = 5 },
    { Kind = "slot",    Label = "Glasses & Visors",    Slot = 3 },
    { Kind = "slot",    Label = "Drumsticks",          Slot = 4 },
    { Kind = "slot",    Label = "Body Type",           Slot = 1 },
}

local UPGRADE_SUBS = {
    { Idol = "Charlie", Label = "Charlie Core Skills" },
    { Idol = "Shred",   Label = "Shred (Lightning)" },
    { Idol = "Rebel",   Label = "Rebel (Heavy Baxe)" },
    { Idol = "Dancer",  Label = "Vermillion (Dancer)" },
    { Idol = "Prophet", Label = "Prophet (Counter)" },
    { Idol = "Doll",    Label = "Arora (Cosmic Doll)" },
    { Idol = "All",     Label = "All Upgrades" },
}

local IDOL_INFO = {
    Shred   = { Name = "SHRED // ELECTRIC LIGHTNING", Color = PALETTE.Cyan },
    Rebel   = { Name = "REBEL // HEAVY BAXE",         Color = PALETTE.Orange },
    Dancer  = { Name = "VERMILLION // DANCER",        Color = PALETTE.Magenta },
    Prophet = { Name = "PROPHET // COUNTER PUNCH",    Color = PALETTE.Gold },
    Doll    = { Name = "ARORA // COSMIC DOLL",        Color = PALETTE.Violet },
    Charlie = { Name = "CHARLIE // GROOVE CORE",      Color = PALETTE.Emerald },
}

local function RebuildItemsForActiveTab()
    local catalogs = API.GetOrderedCatalogs()
    local items = {}
    local subs = {}

    if MenuState.TabIndex == 1 then
        -- TAB 1: OUTFITS
        for _, s in ipairs(OUTFIT_SUBS) do
            table.insert(subs, s.Label)
        end
        if MenuState.SubIndex < 1 or MenuState.SubIndex > #OUTFIT_SUBS then
            MenuState.SubIndex = 1
        end
        local activeSub = OUTFIT_SUBS[MenuState.SubIndex]

        if activeSub.Kind == "presets" then
            local presets = Config.OutfitPresets or {}
            local curIdx = API.GetCurrentOutfitPresetIdx()
            for idx, p in ipairs(presets) do
                local isActive = (not API.HasCustomPieceOverride()) and (idx == curIdx)
                local desc = string.format(
                    "Jacket: %s  |  Hair: %s  |  Glasses: %s  |  Sticks: %s  |  Body: %s",
                    tostring(p.Jacket or "Default"),
                    tostring(p.Hair or "Default"),
                    tostring(p.Glasses or "Default"),
                    tostring(p.Drumsticks or "Default"),
                    tostring(p.BodyType or "Default")
                )
                table.insert(items, {
                    Name = p.Name or ("Preset #" .. tostring(idx)),
                    Badge = isActive and "[ ACTIVE ]" or "",
                    IsEquipped = isActive,
                    IdolBadge = "FULL OUTFIT PRESET",
                    IdolColor = PALETTE.Magenta,
                    MetaBadge = string.format("PRESET #%d  •  COMPLETE VISUAL ENSEMBLE", idx),
                    Description = desc,
                    OnActivate = function()
                        API.ApplyOutfitPresetByIndex(idx)
                    end,
                })
            end
        else
            local slotNum = activeSub.Slot
            local eqDef = API.GetEquippedCosmeticAtSlot(slotNum)
            local list = (catalogs.CosmeticsBySlot and catalogs.CosmeticsBySlot[slotNum]) or {}
            for _, entry in ipairs(list) do
                local isEq = IsValid(eqDef) and API.SameUObject(eqDef, entry.Def)
                local descClean = CleanDescriptionTags(entry.Description)
                if descClean == "" then
                    descClean = "Equip " .. entry.Name .. " on Player 2."
                end
                table.insert(items, {
                    Name = entry.Name,
                    Badge = isEq and "[ EQUIPPED ]" or "",
                    IsEquipped = isEq,
                    IdolBadge = "WARDROBE // " .. activeSub.Label:upper(),
                    IdolColor = PALETTE.Cyan,
                    MetaBadge = isEq and "[ CURRENTLY EQUIPPED ]" or "[ SELECTABLE ]",
                    Description = descClean,
                    OnActivate = function()
                        API.EquipCosmeticDef(slotNum, entry.Def)
                    end,
                })
            end
        end

    elseif MenuState.TabIndex == 2 then
        -- TAB 2: DANCES (4 D-Pad Slots)
        local slotLabels = { "Slot 1 (Up)", "Slot 2 (Right)", "Slot 3 (Down)", "Slot 4 (Left)" }
        for sIdx = 0, 3 do
            local curD = API.GetEquippedDanceNameAtSlot(sIdx)
            table.insert(subs, string.format("D-Pad %s: [%s]", slotLabels[sIdx + 1], curD))
        end
        if MenuState.SubIndex < 1 or MenuState.SubIndex > 4 then
            MenuState.SubIndex = 1
        end
        local targetSlot = MenuState.SubIndex - 1

        for _, entry in ipairs(catalogs.Dances or {}) do
            local equippedSlot = API.FindEquippedDanceSlotForDef(entry.Def)
            local isEqHere = (equippedSlot == targetSlot)
            local badge = ""
            if isEqHere then
                badge = string.format("[ SLOT %d ]", targetSlot + 1)
            elseif equippedSlot ~= nil then
                badge = string.format("(Slot %d)", equippedSlot + 1)
            end
            local descClean = CleanDescriptionTags(entry.Description)
            if descClean == "" then
                descClean = string.format("Assign '%s' to Player 2's Dance %s.", entry.Name, slotLabels[targetSlot + 1])
            end
            table.insert(items, {
                Name = entry.Name,
                Badge = badge,
                IsEquipped = isEqHere,
                IdolBadge = "DANCE MOVE // D-PAD " .. slotLabels[targetSlot + 1]:upper(),
                IdolColor = PALETTE.Gold,
                MetaBadge = isEqHere and string.format("ASSIGNED TO D-PAD SLOT %d", targetSlot + 1) or "UNASSIGNED",
                Description = descClean,
                OnActivate = function()
                    API.EquipDanceAtSlot(targetSlot, entry.Def)
                end,
            })
        end

    elseif MenuState.TabIndex == 3 then
        -- TAB 3: BOSS SKILLS & LOADOUT PRESETS
        for sIdx = 0, 3 do
            local curB = API.GetEquippedBossAbilityNameAtSlot(sIdx)
            table.insert(subs, string.format("Ability Slot %d: [%s]", sIdx + 1, curB))
        end
        table.insert(subs, "Full Skill & Dance Loadouts")

        if MenuState.SubIndex < 1 or MenuState.SubIndex > 5 then
            MenuState.SubIndex = 1
        end

        if MenuState.SubIndex <= 4 then
            local targetSlot = MenuState.SubIndex - 1
            for _, entry in ipairs(catalogs.BossAbilities or {}) do
                local eqSlot = API.FindEquippedBossSlotForDef(entry.Def)
                local isEqHere = (eqSlot == targetSlot)
                local badge = ""
                if isEqHere then
                    badge = string.format("[ SLOT %d ]", targetSlot + 1)
                elseif eqSlot ~= nil then
                    badge = string.format("(Slot %d)", eqSlot + 1)
                end

                -- Determine Idol tree for color branding
                local objName = entry.Def:GetFName():ToString()
                local idolKey = "Shred"
                for _, cand in ipairs({ "Shred", "Rebel", "Dancer", "Prophet", "Doll", "Charlie" }) do
                    if objName:find(cand, 1, true) then
                        idolKey = cand
                        break
                    end
                end
                local idolData = IDOL_INFO[idolKey] or IDOL_INFO.Shred
                local descClean = CleanDescriptionTags(entry.Description)
                if descClean == "" then
                    descClean = string.format("Equip Boss Ability '%s' into Ability Slot %d.", entry.Name, targetSlot + 1)
                end

                table.insert(items, {
                    Name = entry.Name,
                    Badge = badge,
                    IsEquipped = isEqHere,
                    IdolBadge = idolData.Name,
                    IdolColor = idolData.Color,
                    MetaBadge = string.format("IDOL BOSS ABILITY  •  TARGET SLOT %d", targetSlot + 1),
                    Description = descClean,
                    OnActivate = function()
                        API.EquipBossAbilityAtSlot(targetSlot, entry.Def)
                    end,
                })
            end
        else
            local presets = Config.LoadoutPresets or {}
            local curIdx = API.GetCurrentLoadoutPresetIdx()
            for idx, lp in ipairs(presets) do
                local isAct = (idx == curIdx)
                local bList = lp.BossAbilities and table.concat(lp.BossAbilities, ", ") or "Mirrors Player 1"
                local dList = lp.Dances and table.concat(lp.Dances, ", ") or "Default Pack"
                table.insert(items, {
                    Name = lp.Name or ("Loadout #" .. tostring(idx)),
                    Badge = isAct and "[ ACTIVE ]" or "",
                    IsEquipped = isAct,
                    IdolBadge = "CURATED BATTLE LOADOUT",
                    IdolColor = PALETTE.Magenta,
                    MetaBadge = isAct and "[ CURRENTLY ACTIVE ]" or "[ AVAILABLE LOADOUT ]",
                    Description = string.format("Boss Abilities: %s  |  Dances: %s", bList, dList),
                    OnActivate = function()
                        API.ApplySkillLoadoutByIndex(idx)
                    end,
                })
            end
        end

    elseif MenuState.TabIndex == 4 then
        -- TAB 4: PASSIVE & ACTIVE UPGRADES (SKILL TREES)
        for _, uSub in ipairs(UPGRADE_SUBS) do
            table.insert(subs, uSub.Label)
        end
        if MenuState.SubIndex < 1 or MenuState.SubIndex > #UPGRADE_SUBS then
            MenuState.SubIndex = 1
        end
        local idolKey = UPGRADE_SUBS[MenuState.SubIndex].Idol
        local uList = (catalogs.UpgradesByIdol and catalogs.UpgradesByIdol[idolKey]) or {}

        for _, entry in ipairs(uList) do
            local isOn = API.IsUpgradeEquippedOnP2(entry.Def)
            local idolData = IDOL_INFO[entry.Idol] or IDOL_INFO.Charlie
            local descClean = CleanDescriptionTags(entry.Description)
            if descClean == "" then
                descClean = "Toggle upgrade '" .. entry.Name .. "' for Player 2."
            end

            table.insert(items, {
                Name = entry.Name,
                Badge = isOn and "[ EQUIPPED ]" or "[ OFF ]",
                IsEquipped = isOn,
                IdolBadge = idolData.Name,
                IdolColor = idolData.Color,
                MetaBadge = isOn and "[ ACTIVATED ON PLAYER 2 ]" or "[ DISABLED ]",
                Description = descClean,
                OnActivate = function()
                    API.ToggleUpgradeDef(entry.Def)
                end,
            })
        end

    elseif MenuState.TabIndex == 5 then
        -- TAB 5: CHARACTER MODEL, TINT & CO-OP SETTINGS
        subs = { "Character Model, Shader Tint & Co-op Settings" }
        MenuState.SubIndex = 1

        local curChar = API.GetCurrentCharacterName()
        local curTint = API.GetCurrentTintMode()
        local curMode = API.GetCurrentScreenMode()
        local modeNames = { [0] = "Horizontal Split", [1] = "Vertical Split", [2] = "Shared Screen" }

        table.insert(items, {
            Name = "Character Model: Charlie (Supports All 55 Outfits)",
            Badge = (curChar:lower() == "charlie") and "[ ACTIVE ]" or "",
            IsEquipped = (curChar:lower() == "charlie"),
            IdolBadge = "CHARACTER MODEL SELECTION",
            IdolColor = PALETTE.Cyan,
            MetaBadge = "LEAD DRUMMER // CHARLIE DISCO",
            Description = "Play as Charlie Disco. Supports all 55 Jacket, Hair, Shades, Drumstick, and Body Type customization pieces.",
            OnActivate = function() API.SetCharacterModel("Charlie") end,
        })
        table.insert(items, {
            Name = "Character Model: Chuckles (Hidden Co-op Character)",
            Badge = (curChar:lower() == "chuckles") and "[ ACTIVE ]" or "",
            IsEquipped = (curChar:lower() == "chuckles"),
            IdolBadge = "CHARACTER MODEL SELECTION",
            IdolColor = PALETTE.Magenta,
            MetaBadge = "CO-OP EXCLUSIVE // CHUCKLES",
            Description = "Play as Chuckles, Dead as Disco's secret co-op character model with custom animations!",
            OnActivate = function() API.SetCharacterModel("Chuckles") end,
        })
        table.insert(items, {
            Name = "Visual Shader Tint Mode: " .. tostring(curTint),
            Badge = "[ CYCLE ]",
            IsEquipped = (curTint ~= "Off"),
            IdolBadge = "P2 SHADER TINT SETTINGS",
            IdolColor = PALETTE.Gold,
            MetaBadge = "CURRENT TINT: " .. tostring(curTint):upper(),
            Description = "Cycles Player 2's cel-shader rim between AccentOnly (Fresnel edge glow), FullBody, and Off.",
            OnActivate = function() API.CycleTintMode() end,
        })

        for pIdx, pal in ipairs(Config.TintColorPalettes or {}) do
            local isPal = (API.GetCurrentTintPaletteIdx() == pIdx)
            table.insert(items, {
                Name = "Tint Palette: " .. tostring(pal.Name),
                Badge = isPal and "[ SELECTED ]" or "",
                IsEquipped = isPal,
                IdolBadge = "COLOR PALETTE",
                IdolColor = pal.Color or PALETTE.Cyan,
                MetaBadge = "NEON COLOR SHADER",
                Description = "Sets Player 2's outline and surface shader tint to " .. tostring(pal.Name) .. ".",
                OnActivate = function() API.SetTintPalette(pIdx) end,
            })
        end

        table.insert(items, {
            Name = "Screen Layout: " .. tostring(modeNames[curMode] or "Split"),
            Badge = "[ SWITCH ]",
            IsEquipped = false,
            IdolBadge = "CO-OP VIEWPORT SETTINGS",
            IdolColor = PALETTE.Cyan,
            MetaBadge = "LAYOUT: " .. tostring(modeNames[curMode] or "Split"):upper(),
            Description = "Cycles between Horizontal Split-Screen (Top/Bottom), Vertical Split-Screen (Left/Right), and Shared Single Screen.",
            OnActivate = function() API.CycleScreenMode() end,
        })
        table.insert(items, {
            Name = "Teleport Player 2 Next to Player 1",
            Badge = "[ ACTION ]",
            IsEquipped = false,
            IdolBadge = "QUICK ACTIONS",
            IdolColor = PALETTE.Emerald,
            MetaBadge = "INSTANT REGROUP",
            Description = "Immediately teleports Player 2 directly beside Player 1 in the stage.",
            OnActivate = function() API.TeleportPlayer2() end,
        })
    end

    MenuState.SubCategories = subs
    MenuState.CurrentItems = items

    local count = #items
    if count == 0 then
        MenuState.SelectedIndex = 1
        MenuState.WindowStart = 1
    else
        if MenuState.SelectedIndex > count then MenuState.SelectedIndex = count end
        if MenuState.SelectedIndex < 1 then MenuState.SelectedIndex = 1 end
        if MenuState.SelectedIndex < MenuState.WindowStart then
            MenuState.WindowStart = MenuState.SelectedIndex
        elseif MenuState.SelectedIndex > (MenuState.WindowStart + VISIBLE_ROWS - 1) then
            MenuState.WindowStart = MenuState.SelectedIndex - VISIBLE_ROWS + 1
        end
        if MenuState.WindowStart < 1 then MenuState.WindowStart = 1 end
    end
end

-- ============================================================================
-- VISUAL RENDERING REFRESH
-- ============================================================================

local function RefreshMenuUI()
    if not MenuState.IsOpen or not IsValid(UI.MenuWidget) then return end

    UpdatePanelAnchorsForScreenMode()
    RebuildItemsForActiveTab()

    -- 1. Style Tab Pills
    for i = 1, #TAB_DEFS do
        local active = (i == MenuState.TabIndex)
        if active then
            SetBorderColor(UI.TabBorders[i], PALETTE.Magenta)
            SetTextColor(UI.TabTexts[i], PALETTE.TextWhite)
        else
            SetBorderColor(UI.TabBorders[i], PALETTE.CardBorder)
            SetTextColor(UI.TabTexts[i], PALETTE.TextMuted)
        end
    end

    -- 2. Sub-Category / Slot Header
    local subCount = #MenuState.SubCategories
    local subLabel = MenuState.SubCategories[MenuState.SubIndex] or ""
    if subCount > 1 then
        SetWidgetText(UI.SubTitleText, string.format("%s   (%d / %d)", subLabel, MenuState.SubIndex, subCount))
    else
        SetWidgetText(UI.SubTitleText, subLabel)
    end

    -- 3. Item Rows (8 Pooled Slots)
    local items = MenuState.CurrentItems
    local total = #items
    for r = 1, VISIBLE_ROWS do
        local itemIdx = MenuState.WindowStart + r - 1
        local item = items[itemIdx]
        local rowBtn = UI.RowButtons[r]
        local rowBorder = UI.RowBorders[r]
        local nameTxt = UI.RowNameTexts[r]
        local badgeTxt = UI.RowBadgeTexts[r]

        if item then
            pcall(function() rowBtn:SetVisibility(0) end) -- Visible
            local selected = (itemIdx == MenuState.SelectedIndex)
            local prefix = selected and ">>  " or "    "
            SetWidgetText(nameTxt, prefix .. tostring(item.Name))
            SetWidgetText(badgeTxt, tostring(item.Badge or ""))

            if selected then
                SetBorderColor(rowBorder, PALETTE.Cyan)
                SetTextColor(nameTxt, PALETTE.TextWhite)
            elseif item.IsEquipped then
                SetBorderColor(rowBorder, { R = 0.10, G = 0.40, B = 0.25, A = 0.90 })
                SetTextColor(nameTxt, { R = 0.85, G = 1.00, B = 0.92, A = 1.0 })
            else
                SetBorderColor(rowBorder, PALETTE.DarkCard)
                SetTextColor(nameTxt, PALETTE.TextMuted)
            end

            if item.IsEquipped then
                SetTextColor(badgeTxt, PALETTE.Emerald)
            else
                SetTextColor(badgeTxt, PALETTE.TextHint)
            end
        else
            pcall(function() rowBtn:SetVisibility(2) end) -- Hidden
            SetWidgetText(nameTxt, "")
            SetWidgetText(badgeTxt, "")
        end
    end

    -- 4. Scroll / Count Indicator & Enhanced Details Showcase Card
    if total > 0 then
        local winEnd = math.min(total, MenuState.WindowStart + VISIBLE_ROWS - 1)
        SetWidgetText(UI.PageInfoText, string.format("Item %d of %d   (Showing %d-%d)", MenuState.SelectedIndex, total, MenuState.WindowStart, winEnd))
        local curItem = items[MenuState.SelectedIndex]
        if curItem then
            SetWidgetText(UI.DetailIdolBadgeText, curItem.IdolBadge or "")
            SetTextColor(UI.DetailIdolBadgeText, curItem.IdolColor or PALETTE.Cyan)
            SetWidgetText(UI.DetailTitleText, curItem.Name or "")
            SetWidgetText(UI.DetailMetaBadgeText, curItem.MetaBadge or "")
            SetWidgetText(UI.DetailDescText, curItem.Description or "")
        end
    else
        SetWidgetText(UI.PageInfoText, "No items available in this category.")
        SetWidgetText(UI.DetailIdolBadgeText, "DEAD AS DISCO")
        SetTextColor(UI.DetailIdolBadgeText, PALETTE.Cyan)
        SetWidgetText(UI.DetailTitleText, "Catalog Loading")
        SetWidgetText(UI.DetailMetaBadgeText, "")
        SetWidgetText(UI.DetailDescText, "Enter gameplay with Player 2 active to browse items.")
    end
end

-- ============================================================================
-- PUBLIC NAVIGATION & LIFECYCLE API
-- ============================================================================

function P2Menu.IsOpen()
    return MenuState.IsOpen == true
end

local function SetPlayer2MenuInputLock(locked)
    pcall(function()
        local p1, p2 = API.GetControllers()
        if API.IsLiveWorldObject(p2) then
            local p2Pawn = p2.Pawn
            if locked then
                pcall(function() p2:SetIgnoreMoveInput(true) end)
                pcall(function() p2:SetIgnoreLookInput(true) end)
                if API.IsLiveWorldObject(p2Pawn) then
                    pcall(function() p2Pawn:DisableInput(p2) end)
                end
            else
                pcall(function() p2:ResetIgnoreInputFlags() end)
                if API.IsLiveWorldObject(p2Pawn) then
                    pcall(function() p2Pawn:EnableInput(p2) end)
                end
            end
        end

        if Config.ShowMouseCursorInP2Menu ~= false and API.IsLiveWorldObject(p1) then
            if locked then
                pcall(function() p1.bShowMouseCursor = true end)
            else
                local paused = API.IsGamePaused()
                if not paused then
                    pcall(function() p1.bShowMouseCursor = false end)
                end
            end
        end
    end)
end

function P2Menu.Open(initialTab)
    if Config.EnableP2CustomMenu == false then return false end
    if API.IsGamePaused() then return false end

    local p1, p2 = API.GetControllers()
    if not API.IsLiveWorldObject(p2) or not API.IsLiveWorldObject(p2.Pawn) then
        API.ShowMessage("Connect Player 2 first ([F6] or [L3+R3]) to open Player 2's Studio Menu!", { R = 1.0, G = 0.8, B = 0.2, A = 1.0 })
        return false
    end

    API.EnsureP2ReadyForMenu()

    if not EnsureMenuWidgetBuilt(p2) then
        return false
    end

    if type(initialTab) == "number" and initialTab >= 1 and initialTab <= #TAB_DEFS then
        MenuState.TabIndex = initialTab
        MenuState.SubIndex = 1
        MenuState.SelectedIndex = 1
        MenuState.WindowStart = 1
    end

    local inVP = false
    pcall(function() inVP = UI.MenuWidget:IsInViewport() end)
    if not inVP then
        local okAdd, added = pcall(function()
            return UI.MenuWidget:AddToPlayerScreen(60)
        end)
        if not (okAdd and added) then
            pcall(function() UI.MenuWidget:AddToViewport(60) end)
        end
    end
    pcall(function() UI.MenuWidget:SetVisibility(0) end)

    MenuState.IsOpen = true
    MenuState.MenuOpenedAt = os.clock()

    -- Prime PrevKeyStates so the opening trigger button doesn't immediately activate an action
    PrevKeyStates = {}
    KeyHoldNextRepeat = {}
    PrevButtonPressed = {}
    for _, k in ipairs({
        "Gamepad_Special_Left", "Gamepad_FaceButton_Bottom", "Gamepad_FaceButton_Right",
        "Gamepad_FaceButton_Left", "Gamepad_FaceButton_Top", "Gamepad_LeftShoulder", "Gamepad_RightShoulder",
        "Enter", "BackSpace",
    }) do
        PrevKeyStates["P2:" .. k] = true
        PrevKeyStates["P1:" .. k] = true
    end

    SetPlayer2MenuInputLock(true)
    RefreshMenuUI()
    return true
end

function P2Menu.Close()
    if not MenuState.IsOpen then return end
    MenuState.IsOpen = false

    if IsValid(UI.MenuWidget) then
        pcall(function() UI.MenuWidget:SetVisibility(1) end) -- Collapsed
        pcall(function() UI.MenuWidget:RemoveFromParent() end)
    end

    SetPlayer2MenuInputLock(false)
end

function P2Menu.Toggle(preferredTab)
    if MenuState.IsOpen then
        if preferredTab and MenuState.TabIndex ~= preferredTab then
            P2Menu.SelectTab(preferredTab)
            return true
        end
        P2Menu.Close()
        return false
    else
        return P2Menu.Open(preferredTab or MenuState.TabIndex or 1)
    end
end

function P2Menu.SelectTab(tabIdx)
    if tabIdx < 1 then tabIdx = #TAB_DEFS end
    if tabIdx > #TAB_DEFS then tabIdx = 1 end
    MenuState.TabIndex = tabIdx
    MenuState.SubIndex = 1
    MenuState.SelectedIndex = 1
    MenuState.WindowStart = 1
    RefreshMenuUI()
end

function P2Menu.SelectSubCategory(delta)
    local subCount = #MenuState.SubCategories
    if subCount <= 1 then return end
    MenuState.SubIndex = ((MenuState.SubIndex - 1 + delta) % subCount) + 1
    MenuState.SelectedIndex = 1
    MenuState.WindowStart = 1
    RefreshMenuUI()
end

function P2Menu.MoveCursor(delta)
    local total = #MenuState.CurrentItems
    if total <= 0 then return end
    MenuState.SelectedIndex = ((MenuState.SelectedIndex - 1 + delta) % total) + 1
    RefreshMenuUI()
end

function P2Menu.ActivateSelected()
    local now = os.clock()
    if (now - MenuState.LastActivateTime) < 0.22 then return false end
    MenuState.LastActivateTime = now

    local item = MenuState.CurrentItems[MenuState.SelectedIndex]
    if item and type(item.OnActivate) == "function" then
        pcall(item.OnActivate)
        RefreshMenuUI()
        return true
    end
    return false
end

function P2Menu.GetMenuWidget()
    return UI.MenuWidget
end

function P2Menu.GetSnapshot()
    local inVP = false
    if IsValid(UI.MenuWidget) then
        pcall(function() inVP = UI.MenuWidget:IsInViewport() end)
    end
    return {
        IsOpen = MenuState.IsOpen,
        InViewport = inVP,
        TabIndex = MenuState.TabIndex,
        SubIndex = MenuState.SubIndex,
        SelectedIndex = MenuState.SelectedIndex,
        ItemCount = #MenuState.CurrentItems,
        SubCategoryCount = #MenuState.SubCategories,
    }
end

function P2Menu.OnWorldOrControllersChanged()
    if MenuState.IsOpen then
        P2Menu.Close()
    end
    DestroyMenuWidget()
end

-- ============================================================================
-- INTERACTIVE INPUT POLLING & 360° CHARACTER ROTATION
-- ============================================================================

local function CheckKeyEdge(pc, statePrefix, keyName, now, allowRepeat)
    if not API.IsLiveWorldObject(pc) then return false end
    local stateKey = statePrefix .. ":" .. keyName
    local down = false
    pcall(function()
        down = (pc:IsInputKeyDown({ KeyName = FName(keyName) }) == true)
    end)

    local wasDown = (PrevKeyStates[stateKey] == true)
    PrevKeyStates[stateKey] = down

    if down and not wasDown then
        if allowRepeat then
            KeyHoldNextRepeat[stateKey] = now + 0.30
        end
        return true
    elseif down and wasDown and allowRepeat then
        local nextT = KeyHoldNextRepeat[stateKey] or (now + 0.30)
        if now >= nextT then
            KeyHoldNextRepeat[stateKey] = now + 0.11
            return true
        end
    else
        KeyHoldNextRepeat[stateKey] = nil
    end
    return false
end

local function CheckButtonClicked(btnKey, btnWidget)
    if not IsValid(btnWidget) then return false end
    local pressed = false
    pcall(function() pressed = (btnWidget:IsPressed() == true) end)
    local wasPressed = (PrevButtonPressed[btnKey] == true)
    PrevButtonPressed[btnKey] = pressed
    return pressed and not wasPressed
end

local function PollMenuInputTick()
    if not MenuState.IsOpen then return end

    local inGameplay = API.IsGameplayWorld()
    local p1, p2 = API.GetControllers()
    if not inGameplay or API.IsGamePaused() or not API.IsLiveWorldObject(p2) then
        P2Menu.Close()
        return
    end

    local now = os.clock()
    -- Brief settle window right after opening
    if (now - MenuState.MenuOpenedAt) < 0.12 then return end

    -- =========================================================================
    -- CHARACTER 360° ROTATION (Inspect outfit from all angles!)
    -- =========================================================================
    pcall(function()
        if API.IsLiveWorldObject(p2.Pawn) then
            local rotDelta = 0.0
            if p2:IsInputKeyDown({ KeyName = FName("Gamepad_RightStick_Left") }) then
                rotDelta = -3.2
            elseif p2:IsInputKeyDown({ KeyName = FName("Gamepad_RightStick_Right") }) then
                rotDelta = 3.2
            end
            if API.IsLiveWorldObject(p1) then
                if p1:IsInputKeyDown({ KeyName = FName("LeftBracket") }) then
                    rotDelta = -3.2
                elseif p1:IsInputKeyDown({ KeyName = FName("RightBracket") }) then
                    rotDelta = 3.2
                end
            end
            if rotDelta ~= 0.0 then
                local curRot = p2.Pawn:K2_GetActorRotation()
                curRot.Yaw = curRot.Yaw + rotDelta
                p2.Pawn:K2_SetActorRotation(curRot, false)
            end
        end
    end)

    -- =========================================================================
    -- 1. Player 2 Controller Navigation
    -- =========================================================================
    if CheckKeyEdge(p2, "P2", "Gamepad_FaceButton_Right", now, false)
        or CheckKeyEdge(p2, "P2", Config.GamepadMenuToggleKey or "Gamepad_Special_Left", now, false) then
        P2Menu.Close()
        return
    end

    if CheckKeyEdge(p2, "P2", "Gamepad_LeftShoulder", now, false) then
        P2Menu.SelectTab(MenuState.TabIndex - 1)
        return
    end
    if CheckKeyEdge(p2, "P2", "Gamepad_RightShoulder", now, false) then
        P2Menu.SelectTab(MenuState.TabIndex + 1)
        return
    end

    if CheckKeyEdge(p2, "P2", "Gamepad_DPad_Up", now, true)
        or CheckKeyEdge(p2, "P2", "Gamepad_LeftStick_Up", now, true) then
        P2Menu.MoveCursor(-1)
        return
    end
    if CheckKeyEdge(p2, "P2", "Gamepad_DPad_Down", now, true)
        or CheckKeyEdge(p2, "P2", "Gamepad_LeftStick_Down", now, true) then
        P2Menu.MoveCursor(1)
        return
    end

    if CheckKeyEdge(p2, "P2", "Gamepad_DPad_Left", now, true)
        or CheckKeyEdge(p2, "P2", "Gamepad_LeftStick_Left", now, true) then
        P2Menu.SelectSubCategory(-1)
        return
    end
    if CheckKeyEdge(p2, "P2", "Gamepad_DPad_Right", now, true)
        or CheckKeyEdge(p2, "P2", "Gamepad_LeftStick_Right", now, true)
        or CheckKeyEdge(p2, "P2", "Gamepad_FaceButton_Left", now, false) then
        P2Menu.SelectSubCategory(1)
        return
    end

    if CheckKeyEdge(p2, "P2", "Gamepad_FaceButton_Bottom", now, false) then
        P2Menu.ActivateSelected()
        return
    end

    -- =========================================================================
    -- 2. Non-WASD Keyboard Navigation (Player 1 WASD movement remains free!)
    -- =========================================================================
    if API.IsLiveWorldObject(p1) then
        if CheckKeyEdge(p1, "P1", "BackSpace", now, false) then
            P2Menu.Close()
            return
        end
        if CheckKeyEdge(p1, "P1", "PageUp", now, false) then
            P2Menu.SelectTab(MenuState.TabIndex - 1)
            return
        end
        if CheckKeyEdge(p1, "P1", "PageDown", now, false) then
            P2Menu.SelectTab(MenuState.TabIndex + 1)
            return
        end
        if CheckKeyEdge(p1, "P1", "Up", now, true) then
            P2Menu.MoveCursor(-1)
            return
        end
        if CheckKeyEdge(p1, "P1", "Down", now, true) then
            P2Menu.MoveCursor(1)
            return
        end
        if CheckKeyEdge(p1, "P1", "Left", now, true) then
            P2Menu.SelectSubCategory(-1)
            return
        end
        if CheckKeyEdge(p1, "P1", "Right", now, true) then
            P2Menu.SelectSubCategory(1)
            return
        end
        if CheckKeyEdge(p1, "P1", "Enter", now, false) then
            P2Menu.ActivateSelected()
            return
        end
    end

    -- =========================================================================
    -- 3. Mouse Hover & Click Handling on Pooled UMG Buttons
    -- =========================================================================
    if CheckButtonClicked("close", UI.CloseBtn) then
        P2Menu.Close()
        return
    end
    if CheckButtonClicked("subPrev", UI.SubPrevBtn) then
        P2Menu.SelectSubCategory(-1)
        return
    end
    if CheckButtonClicked("subNext", UI.SubNextBtn) then
        P2Menu.SelectSubCategory(1)
        return
    end
    if CheckButtonClicked("equip", UI.EquipBtn) then
        P2Menu.ActivateSelected()
        return
    end

    for t = 1, #TAB_DEFS do
        if CheckButtonClicked("tab" .. tostring(t), UI.TabButtons[t]) then
            P2Menu.SelectTab(t)
            return
        end
    end

    for r = 1, VISIBLE_ROWS do
        local itemIdx = MenuState.WindowStart + r - 1
        if MenuState.CurrentItems[itemIdx] and IsValid(UI.RowButtons[r]) then
            local hovered = false
            pcall(function() hovered = (UI.RowButtons[r]:IsHovered() == true) end)
            if hovered and MenuState.SelectedIndex ~= itemIdx then
                MenuState.SelectedIndex = itemIdx
                RefreshMenuUI()
            end
            if CheckButtonClicked("row" .. tostring(r), UI.RowButtons[r]) then
                MenuState.SelectedIndex = itemIdx
                P2Menu.ActivateSelected()
                return
            end
        end
    end
end

function P2Menu.Init(coopApi, configTbl)
    API = coopApi
    Config = configTbl

    LoopAsync(45, function()
        if MenuState.IsOpen then
            ExecuteInGameThread(function()
                pcall(PollMenuInputTick)
            end)
        end
        return false
    end)
end

return P2Menu
