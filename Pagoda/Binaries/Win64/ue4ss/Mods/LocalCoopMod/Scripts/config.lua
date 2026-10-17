local Config = {
    -- Default screen layout:
    -- 0 = Horizontal Split-Screen (Top & Bottom)
    -- 1 = Vertical Split-Screen (Left & Right)
    -- 2 = Shared Single Screen (Both players on Player 1's camera)
    ScreenMode = 0,

    -- Controller routing:
    -- true  = 1 Keyboard/Mouse (Player 1) + 1 Controller (Player 2)
    -- false = 2 Controllers (Controller 1 = Player 1, Controller 2 = Player 2)
    OffsetGamepad = true,

    -- Auto-Leashing (especially helpful in Shared Screen mode):
    -- Automatically teleports Player 2 back to Player 1 if they fall off or wander too far.
    AutoLeashEnabled = true,
    MaxDistance = 2500.0,
    MaxZDifference = 600.0,

    -- Player 2 appearance customization:
    -- Visual tint applied to Player 2's materials (R, G, B, A) so both players are easily distinguishable.
    -- Default is a vibrant Neon Cyan / Disco Teal.
    Player2TintColor = { R = 0.0, G = 1.0, B = 0.9, A = 1.0 },
    EnablePlayer2VisualTint = true,

    -- On-screen message display duration in seconds
    MessageDuration = 4.0
}

return Config

