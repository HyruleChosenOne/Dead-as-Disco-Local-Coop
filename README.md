# Dead as Disco - Local Co-op Mod

Bring a friend into the rhythm arena! This mod adds full local multiplayer co-op support to **Dead as Disco** via the Unreal Engine 5 scripting system.

---

## 🎮 Quick Start & Controls

Once in any level, arena, or match:

| Action | Primary Key | Alternate Key | Description |
| :--- | :--- | :--- | :--- |
| **Toggle Controller Setup** | `F5` | — | Switch between **1 Keyboard + 1 Controller** and **2 Controllers**. |
| **Spawn / Revive Player 2** | `F6` | `Ctrl + Y` | Spawns Player 2 immediately (or revives/teleports if already spawned). |
| **Remove Player 2** | `F7` | `Ctrl + U` | Despawns Player 2 and returns to single player. |
| **Teleport to Player 1** | `F8` | `Ctrl + I` | Teleports Player 2 right next to Player 1 if separated. |
| **Cycle Screen Mode** | `F9` | `Ctrl + P` | Cycles between: **Horizontal Split**, **Vertical Split**, and **Shared Screen**. |
| **Toggle Auto-Leash** | `F11` | — | Toggles safety tethering in Shared Screen mode to keep P2 in frame. |

---

## 🕹️ Controller Setups Supported

### Setup A: 1 Keyboard/Mouse + 1 Gamepad (Default)
- **Player 1**: Keyboard & Mouse
- **Player 2**: Controller 1 (Xbox / PlayStation / Steam Deck / Generic)
- *If Gamepad 1 controls Player 1 instead, press `F5` to swap routing.*

### Setup B: 2 Gamepads
- **Player 1**: Controller 1
- **Player 2**: Controller 2
- *Press `F5` to set routing to 2 Controllers.*

---

## 🖥️ Screen Modes

Press `F9` (or `Ctrl + P`) at any time to switch modes on the fly:

1. **Horizontal Split-Screen (Default)**: Top and Bottom halves. Each player gets their own camera.
2. **Vertical Split-Screen**: Left and Right halves. Great for ultra-wide monitors.
3. **Shared Single-Screen (Arena Mode)**: Both players fight on one unified fullscreen camera view! With **Auto-Leash** enabled (`F11`), if Player 2 gets knocked far off the platform or arena, they are automatically tethered back near Player 1.

---

## 🎨 Visual Differentiation
Player 2 is given an eye-catching neon cyan/teal material tint and depth outline so you never lose track of who is who during high-octane beat combos!

You can customize the color tint or leashing distance in:
`Pagoda\Binaries\Win64\ue4ss\Mods\LocalCoopMod\Scripts\config.lua`

---

## 🛠️ In-Game Console (Bonus)
The mod framework also enables the developer console (`~` or `Tilde`). You can use Unreal console commands such as:
- `CreatePlayer 1`
- `r.SetRes 2560x1440f`

