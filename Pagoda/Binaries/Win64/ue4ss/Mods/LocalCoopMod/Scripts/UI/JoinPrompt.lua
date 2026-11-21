-- Dive Bar drop-in prompt showing Player 2 join bindings and connection status.

local UObjectUtils = require("Utils.UObjectUtils")
local SessionManager = require("Core.SessionManager")
local ViewportController = require("Camera.ViewportController")
local InputRouting = require("Input.InputRouting")
local UITheme = require("UI.UITheme")

local JoinPrompt = {}

local Config = {}
local HoldProgress = 0.0
local IsConnecting = false
local ConnectingStatus = "CONNECTING PLAYER 2"
local ConnectedFlashUntil = 0.0
local LastVisualState = nil
local LastConnectingText = nil

local UI = {
    Widget = nil,
    OwnerPC = nil,
    World = nil,
    Card = nil,
    AccentBar = nil,
    TitleText = nil,
    SepText = nil,
    PadPill = nil,
    PadText = nil,
    KeyPill = nil,
    KeyText = nil,
    Visible = false,
}

function JoinPrompt.Init(config)
    Config = config or {}
    ViewportController.RegisterModWidget("JoinPrompt", function() return UI.Widget end)
end

function JoinPrompt.Destroy()
    if UObjectUtils.IsValid(UI.Widget) then
        pcall(function() UI.Widget:RemoveFromParent() end)
    end
    UI.Widget = nil
    UI.OwnerPC = nil
    UI.World = nil
    UI.Card = nil
    UI.AccentBar = nil
    UI.TitleText = nil
    UI.SepText = nil
    UI.PadPill = nil
    UI.PadText = nil
    UI.KeyPill = nil
    UI.KeyText = nil
    UI.Visible = false
    HoldProgress = 0.0
    IsConnecting = false
    ConnectedFlashUntil = 0.0
    LastVisualState = nil
    LastConnectingText = nil
end

function JoinPrompt.Hide()
    if UObjectUtils.IsValid(UI.Widget) and UI.Visible then
        pcall(function() UI.Widget:SetVisibility(2) end) -- Hidden
        UI.Visible = false
    end
end

function JoinPrompt.SetJoinProgress(frac)
    local nextFrac = math.max(0.0, math.min(1.0, tonumber(frac) or 0.0))
    HoldProgress = nextFrac
end

function JoinPrompt.ShowConnecting(statusText)
    IsConnecting = true
    ConnectedFlashUntil = 0.0
    ConnectingStatus = (type(statusText) == "string" and statusText ~= "")
        and statusText:gsub("%.+$", "")
        or "CONNECTING PLAYER 2"
    JoinPrompt.Tick(os.clock())
end

function JoinPrompt.FinishConnecting(success)
    IsConnecting = false
    HoldProgress = 0.0
    if success then
        ConnectedFlashUntil = os.clock() + 0.90
        JoinPrompt.Tick(os.clock())
    else
        ConnectedFlashUntil = 0.0
        JoinPrompt.Hide()
    end
end

local function ShouldShow(now)
    now = now or os.clock()
    local inGameplay, world = UObjectUtils.IsGameplayWorld()
    if not (inGameplay and UObjectUtils.IsValid(world)) then return false, nil, nil end

    local p1 = SessionManager.GetP1()
    if not UObjectUtils.IsLive(p1) then return false, nil, nil end

    if IsConnecting or now < ConnectedFlashUntil then
        return true, p1, world
    end

    local hudCfg = Config.HUD or {}
    if hudCfg.ShowDiveBarJoinPrompt == false then return false, nil, nil end
    if not UObjectUtils.IsInDiveBar(p1) then return false, nil, nil end
    if SessionManager.IsP2Active() then return false, nil, nil end
    if SessionManager.State.IsInCutscene or InputRouting.IsGamePaused() then return false, nil, nil end
    if InputRouting.IsAnyNativeMenuOpen() then return false, nil, nil end

    return true, p1, world
end

local function EnsureBuilt(ownerPC, world)
    if UObjectUtils.IsValid(UI.Widget) and UObjectUtils.Same(UI.OwnerPC, ownerPC) and UObjectUtils.Same(UI.World, world) then
        return true
    end

    JoinPrompt.Destroy()
    local cls = UITheme.GetUMGClasses()
    if not cls then return false end

    local hudCfg = Config.HUD or {}
    local ax = tonumber(hudCfg.JoinPromptAnchorX) or 0.022
    local ay = tonumber(hudCfg.JoinPromptAnchorY) or 0.952

    local ok, built = pcall(function()
        local uw = cls.WBL:Create(world, cls.Widget, ownerPC)
        if not (UObjectUtils.IsValid(uw) and UObjectUtils.IsValid(uw.WidgetTree)) then return false end
        local wt = uw.WidgetTree
        local root = StaticConstructObject(cls.Canvas, wt)
        wt.RootWidget = root

        local card = StaticConstructObject(cls.Border, wt)
        UITheme.StyleDiscoFrame(card, UITheme.Colors.PanelBackdrop, UITheme.Colors.Magenta, 2.0, 3.0)
        card:SetPadding({ Left = 11, Top = 8, Right = 14, Bottom = 8 })
        UITheme.ApplyNativeSkew(card, -7.0)

        local cSlot = root:AddChildToCanvas(card)
        cSlot:SetAnchors({ Minimum = { X = ax, Y = ay }, Maximum = { X = ax, Y = ay } })
        pcall(function() cSlot:SetAlignment({ X = 0.0, Y = 1.0 }) end)
        pcall(function() cSlot:SetAutoSize(true) end)

        local hbox = StaticConstructObject(cls.HBox, wt)
        card:SetContent(hbox)

        local barBox, accentBar = UITheme.MakeAccentBar(wt, cls, 4.0, UITheme.Colors.Magenta)
        local bSlot = hbox:AddChildToHorizontalBox(barBox)
        pcall(function() bSlot:SetPadding({ Left = 0, Top = 1, Right = 9, Bottom = 1 }) end)

        local shardTex = UITheme.GetNativeTexture("Shard")
        if UObjectUtils.IsValid(shardTex) and UObjectUtils.IsValid(cls.Image) then
            local shBox = StaticConstructObject(cls.SizeBox, wt)
            pcall(function() shBox:SetWidthOverride(13.0); shBox:SetHeightOverride(13.0) end)
            local shImg = StaticConstructObject(cls.Image, wt)
            pcall(function() shImg:SetBrushFromTexture(shardTex, false); shImg:SetColorAndOpacity(UITheme.Colors.Gold) end)
            shBox:AddChild(shImg)
            local shS = hbox:AddChildToHorizontalBox(shBox)
            pcall(function() shS:SetVerticalAlignment(2); shS:SetPadding({ Left = 0, Top = 0, Right = 7, Bottom = 0 }) end)
        end

        local titleTxt = StaticConstructObject(cls.Text, wt)
        UITheme.StyleText(titleTxt, 11, UITheme.Fonts.Primary, UITheme.Colors.Gold, false)
        UITheme.SetText(titleTxt, "CONNECT PLAYER 2")
        local tSlot = hbox:AddChildToHorizontalBox(titleTxt)
        pcall(function() tSlot:SetVerticalAlignment(2); tSlot:SetPadding({ Left = 0, Top = 0, Right = 10, Bottom = 0 }) end)

        local padPill, padTxt = UITheme.MakePillBadge(wt, cls, "L3 + R3", UITheme.Colors.CyanSoft, UITheme.Colors.Cyan, 9)
        UITheme.SetOutlineColor(padPill, UITheme.Colors.Cyan, 1.0)
        local pSlot = hbox:AddChildToHorizontalBox(padPill)
        pcall(function() pSlot:SetVerticalAlignment(2); pSlot:SetPadding({ Left = 0, Top = 0, Right = 6, Bottom = 0 }) end)

        local sepTxt = StaticConstructObject(cls.Text, wt)
        UITheme.StyleText(sepTxt, 8, UITheme.Fonts.Secondary, UITheme.Colors.TextMuted, false)
        UITheme.SetText(sepTxt, "OR")
        local sSlot = hbox:AddChildToHorizontalBox(sepTxt)
        pcall(function() sSlot:SetVerticalAlignment(2); sSlot:SetPadding({ Left = 0, Top = 0, Right = 6, Bottom = 0 }) end)

        local keyPill, keyTxt = UITheme.MakePillBadge(wt, cls, "F6", UITheme.Colors.MagentaSoft, UITheme.Colors.Magenta, 9)
        UITheme.SetOutlineColor(keyPill, UITheme.Colors.Magenta, 1.0)
        local kSlot = hbox:AddChildToHorizontalBox(keyPill)
        pcall(function() kSlot:SetVerticalAlignment(2) end)

        ViewportController.RehostingGuard = true
        uw:AddToViewport(45)
        ViewportController.RehostingGuard = false
        pcall(function() uw:SetVisibility(2) end)

        UI.Widget = uw
        UI.OwnerPC = ownerPC
        UI.World = world
        UI.Card = card
        UI.AccentBar = accentBar
        UI.TitleText = titleTxt
        UI.SepText = sepTxt
        UI.PadPill = padPill
        UI.PadText = padTxt
        UI.KeyPill = keyPill
        UI.KeyText = keyTxt
        UI.Visible = false
        return true
    end)

    ViewportController.RehostingGuard = false
    return ok == true and built == true
end

function JoinPrompt.Tick(now)
    now = now or os.clock()
    local show, p1, world = ShouldShow(now)
    if not show then
        HoldProgress = 0.0
        JoinPrompt.Hide()
        return
    end

    if not EnsureBuilt(p1, world) then return end

    if not UI.Visible then
        pcall(function() UI.Widget:SetVisibility(3) end) -- SelfHitTestInvisible
        UI.Visible = true
    end

    local function SetHotkeysVisible(vis)
        local vMode = vis and 0 or 1
        if UObjectUtils.IsValid(UI.PadPill) then pcall(function() UI.PadPill:SetVisibility(vMode) end) end
        if UObjectUtils.IsValid(UI.SepText) then pcall(function() UI.SepText:SetVisibility(vMode) end) end
        if UObjectUtils.IsValid(UI.KeyPill) then pcall(function() UI.KeyPill:SetVisibility(vMode) end) end
    end

    if now < ConnectedFlashUntil then
        if LastVisualState ~= "Connected" then
            LastVisualState = "Connected"
            LastConnectingText = nil
            SetHotkeysVisible(false)
            UITheme.SetText(UI.TitleText, "PLAYER 2 CONNECTED")
            UITheme.SetTextColor(UI.TitleText, UITheme.Colors.Emerald)
            UITheme.SetFill(UI.AccentBar, UITheme.Colors.Emerald)
            UITheme.SetOutlineColor(UI.Card, UITheme.Colors.Emerald, 2.0)
            pcall(function() UI.Card:SetRenderOpacity(1.0) end)
        end
    elseif IsConnecting then
        local dots = string.rep(".", (math.floor(now * 4.0) % 3) + 1)
        local text = ConnectingStatus .. dots
        if LastVisualState ~= "Connecting" then
            LastVisualState = "Connecting"
            SetHotkeysVisible(false)
            UITheme.SetTextColor(UI.TitleText, UITheme.Colors.Cyan)
            UITheme.SetFill(UI.AccentBar, UITheme.Colors.Cyan)
            UITheme.SetOutlineColor(UI.Card, UITheme.Colors.Cyan, 2.0)
            pcall(function() UI.Card:SetRenderOpacity(1.0) end)
        end
        if text ~= LastConnectingText then
            LastConnectingText = text
            UITheme.SetText(UI.TitleText, text)
        end
    elseif HoldProgress > 0.05 then
        if LastVisualState ~= "Hold" then
            LastVisualState = "Hold"
            LastConnectingText = nil
            SetHotkeysVisible(true)
            UITheme.SetText(UI.TitleText, "CONNECTING PLAYER 2...")
            UITheme.SetTextColor(UI.TitleText, UITheme.Colors.Emerald)
            UITheme.SetFill(UI.AccentBar, UITheme.Colors.Emerald)
            UITheme.SetOutlineColor(UI.Card, UITheme.Colors.Emerald, 2.0)
            UITheme.SetFill(UI.PadPill, UITheme.Colors.EmeraldSoft)
            UITheme.SetTextColor(UI.PadText, UITheme.Colors.Emerald)
            pcall(function() UI.Card:SetRenderOpacity(1.0) end)
        end
    else
        if LastVisualState ~= "Idle" then
            LastVisualState = "Idle"
            LastConnectingText = nil
            SetHotkeysVisible(true)
            UITheme.SetText(UI.TitleText, "CONNECT PLAYER 2")
            UITheme.SetTextColor(UI.TitleText, UITheme.Colors.Gold)
            UITheme.SetFill(UI.AccentBar, UITheme.Colors.Magenta)
            UITheme.SetOutlineColor(UI.Card, UITheme.Colors.Magenta, 1.6)
            UITheme.SetFill(UI.PadPill, UITheme.Colors.CyanSoft)
            UITheme.SetTextColor(UI.PadText, UITheme.Colors.Cyan)
        end
        local pulse = 0.86 + 0.14 * (0.5 + 0.5 * math.sin(now * 3.4))
        pcall(function() UI.Card:SetRenderOpacity(pulse) end)
    end
end

return JoinPrompt
