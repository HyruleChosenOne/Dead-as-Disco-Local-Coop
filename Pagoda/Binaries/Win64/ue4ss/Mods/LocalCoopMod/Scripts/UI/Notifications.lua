-- Top-center toast notification banner for co-op status changes.

local UObjectUtils = require("Utils.UObjectUtils")
local Logger = require("Utils.Logger")
local SessionManager = require("Core.SessionManager")
local ViewportController = require("Camera.ViewportController")
local InputRouting = require("Input.InputRouting")
local UITheme = require("UI.UITheme")

local Notifications = {}

local Config = {}
local IsP2MenuOpenFn = nil
local UI = {
    Widget = nil,
    Card = nil,
    OwnerPC = nil,
    World = nil,
    AccentBar = nil,
    BadgePill = nil,
    BadgeText = nil,
    MsgText = nil,
    Visible = false,
}

local HideAtTime = 0.0

local SEVERITY = {
    Success = { Label = "CO-OP",  Accent = UITheme.Colors.Emerald, Soft = UITheme.Colors.EmeraldSoft },
    Info    = { Label = "CO-OP",  Accent = UITheme.Colors.Cyan,    Soft = UITheme.Colors.CyanSoft },
    Warning = { Label = "NOTICE", Accent = UITheme.Colors.Gold,    Soft = UITheme.Colors.GoldSoft },
    Error   = { Label = "ALERT",  Accent = UITheme.Colors.Crimson, Soft = UITheme.Colors.CrimsonSoft },
}

function Notifications.Init(config, callbacks)
    Config = config or {}
    if callbacks and type(callbacks.IsP2MenuOpen) == "function" then
        IsP2MenuOpenFn = callbacks.IsP2MenuOpen
    end
    ViewportController.RegisterModWidget("Notifications", function() return UI.Widget end)
end

function Notifications.Destroy()
    if UObjectUtils.IsValid(UI.Widget) then
        pcall(function() UI.Widget:RemoveFromParent() end)
    end
    UI.Widget = nil
    UI.Card = nil
    UI.OwnerPC = nil
    UI.World = nil
    UI.AccentBar = nil
    UI.BadgePill = nil
    UI.BadgeText = nil
    UI.MsgText = nil
    UI.Visible = false
end

local function EnsureBuilt(ownerPC)
    local inGameplay, world = UObjectUtils.IsGameplayWorld()
    if not (inGameplay and UObjectUtils.IsValid(world) and UObjectUtils.IsLive(ownerPC)) then return false end
    if UObjectUtils.IsValid(UI.Widget) and UObjectUtils.Same(UI.OwnerPC, ownerPC) and UObjectUtils.Same(UI.World, world) then
        return true
    end

    Notifications.Destroy()
    local cls = UITheme.GetUMGClasses()
    if not cls then return false end

    local ok, built = pcall(function()
        local uw = cls.WBL:Create(world, cls.Widget, ownerPC)
        if not (UObjectUtils.IsValid(uw) and UObjectUtils.IsValid(uw.WidgetTree)) then return false end
        local wt = uw.WidgetTree
        local root = StaticConstructObject(cls.Canvas, wt)
        wt.RootWidget = root

        local card = StaticConstructObject(cls.Border, wt)
        UITheme.StyleDiscoFrame(card, UITheme.Colors.PanelBackdrop, UITheme.Colors.MarqueePink, 2.0, 3.0)
        card:SetPadding({ Left = 10, Top = 8, Right = 16, Bottom = 8 })
        UITheme.ApplyNativeSkew(card, -7.0)

        local slot = root:AddChildToCanvas(card)
        slot:SetAnchors({ Minimum = { X = 0.5, Y = 0.028 }, Maximum = { X = 0.5, Y = 0.028 } })
        pcall(function() slot:SetAlignment({ X = 0.5, Y = 0.0 }) end)
        pcall(function() slot:SetAutoSize(true) end)

        local hbox = StaticConstructObject(cls.HBox, wt)
        card:SetContent(hbox)

        local barBox, accentBar = UITheme.MakeAccentBar(wt, cls, 4.0, UITheme.Colors.Cyan)
        local bSlot = hbox:AddChildToHorizontalBox(barBox)
        pcall(function() bSlot:SetPadding({ Left = 0, Top = 1, Right = 9, Bottom = 1 }) end)

        local shardTex = UITheme.GetNativeTexture("Shard")
        if UObjectUtils.IsValid(shardTex) and UObjectUtils.IsValid(cls.Image) then
            local shBox = StaticConstructObject(cls.SizeBox, wt)
            pcall(function() shBox:SetWidthOverride(12.0); shBox:SetHeightOverride(12.0) end)
            local shImg = StaticConstructObject(cls.Image, wt)
            pcall(function() shImg:SetBrushFromTexture(shardTex, false); shImg:SetColorAndOpacity(UITheme.Colors.Gold) end)
            shBox:AddChild(shImg)
            local shS = hbox:AddChildToHorizontalBox(shBox)
            pcall(function() shS:SetVerticalAlignment(2); shS:SetPadding({ Left = 0, Top = 0, Right = 7, Bottom = 0 }) end)
        end

        local pill, pillTxt = UITheme.MakePillBadge(wt, cls, "CO-OP", UITheme.Colors.CyanSoft, UITheme.Colors.Cyan, 8)
        local pSlot = hbox:AddChildToHorizontalBox(pill)
        pcall(function()
            pSlot:SetVerticalAlignment(2)
            pSlot:SetPadding({ Left = 0, Top = 0, Right = 10, Bottom = 0 })
        end)

        local msgTxt = StaticConstructObject(cls.Text, wt)
        UITheme.StyleText(msgTxt, 11, UITheme.Fonts.Body, UITheme.Colors.TextPrimary, false)
        UITheme.SetText(msgTxt, "")
        local mSlot = hbox:AddChildToHorizontalBox(msgTxt)
        pcall(function() mSlot:SetVerticalAlignment(2) end)

        ViewportController.RehostingGuard = true
        uw:AddToViewport(9960)
        ViewportController.RehostingGuard = false
        pcall(function() uw:SetVisibility(2) end)

        UI.Widget = uw
        UI.Card = card
        UI.OwnerPC = ownerPC
        UI.World = world
        UI.AccentBar = accentBar
        UI.BadgePill = pill
        UI.BadgeText = pillTxt
        UI.MsgText = msgTxt
        UI.Visible = false
        return true
    end)
    ViewportController.RehostingGuard = false
    return ok and built
end

function Notifications.Show(message, severity)
    local msg = tostring(message or "")
    Logger.Info("Toast", "%s", msg)
    local nCfg = Config.Notifications or {}
    if nCfg.Enabled == false then return end

    local p1 = SessionManager.GetP1()
    if not p1 or SessionManager.State.IsInCutscene then return end

    if nCfg.SuppressDuringCombat ~= false then
        local inDiveBar = UObjectUtils.IsInDiveBar(p1)
        local inP2Menu = IsP2MenuOpenFn and IsP2MenuOpenFn() or false
        local inNativeMenu = InputRouting.IsAnyNativeMenuOpen()
        if not inDiveBar and not inP2Menu and not inNativeMenu and severity ~= "Error" then
            return
        end
    end
    if not EnsureBuilt(p1) then return end

    local st = SEVERITY[severity] or SEVERITY.Info
    UITheme.SetOutlineColor(UI.Card, st.Accent, 1.8)
    UITheme.SetFill(UI.AccentBar, st.Accent)
    UITheme.SetFill(UI.BadgePill, st.Soft)
    UITheme.SetTextColor(UI.BadgeText, st.Accent)
    UITheme.SetText(UI.BadgeText, st.Label)
    UITheme.SetText(UI.MsgText, UITheme.Truncate(msg, 72))

    pcall(function() UI.Widget:SetVisibility(3) end) -- SelfHitTestInvisible
    UI.Visible = true
    HideAtTime = os.clock() + (nCfg.Duration or 2.6)
end

function Notifications.Hide()
    if UObjectUtils.IsValid(UI.Widget) and UI.Visible then
        pcall(function() UI.Widget:SetVisibility(2) end)
    end
    UI.Visible = false
end

function Notifications.Tick(now)
    if not UI.Visible then return end
    if (not UObjectUtils.IsValid(UI.Widget)) or SessionManager.State.IsInCutscene or (now >= HideAtTime) then
        Notifications.Hide()
    end
end

return Notifications
