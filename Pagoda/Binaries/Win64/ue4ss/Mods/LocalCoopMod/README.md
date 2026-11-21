# Dead as Disco — Local Co-op Mod (`v1.0 Experimental`)

Play **Dead as Disco** together in 2-player local co-op! Team up across the Dive Bar and every stage with custom character (CSM) support, a co-op revive mechanic, independent Player 2 builds, native Player 2 HUD, and Split-Screen or Shared Arena camera modes.

---

## Features

- **2-Player Local Co-op:** Connect Player 2 anytime in the Dive Bar or during a stage by holding **`L3 + R3`** on a controller or pressing **`F6`**. Play with **1 Keyboard/Mouse + 1 Controller** or **2 Controllers**.
- **Custom Character (CSM) & Wardrobe Support:** Automatically detects installed Character Slot Mods (`~mods`) so Player 2 can play as custom characters, or mix-and-match modular Charlie outfits and presets.
- **Co-op Revive System:** Taking fatal damage while your teammate is alive puts you on the ground inside a revive ring. Stand inside the ring (or hold **`X` / `A`** or **`E` / `F`** to revive faster) to get back up with a disco dance, restored health, and brief invulnerability. Game Over only happens if both players go down together.
- **Independent Player 2 Builds:** Equip Player 2 with their own 4 Boss Abilities, Idol Skill Tree Upgrades across all 6 Idols, and 4 D-Pad Dance Moves. All choices save automatically between sessions (`p2_profile.json`).
- **Native Player 2 HUD & 3 Camera Modes:** Displays Player 2's Hearts, Execution Tokens, Fever Bar, Multiplier, and Boss Abilities across **Horizontal Split-Screen**, **Vertical Split-Screen**, and **Shared Arena Camera** (with `PLAYER 1` / `PLAYER 2` tags and Cyan / Pink floor rings).
- **In-Game Player 2 Menu:** Customize everything across 5 tabs in the Dive Bar (with 360° character rotation), or open a streamlined mid-match pause menu during songs to swap models, attacks, and camera settings.
- **Experimental Features Toggle:** Enable inside **P2 Menu -> Settings** to unlock **6 Neon Rim Tints**, **15 Playable Boss & Enemy Models**, dynamic midpoint camera tracking, and auto-leash.

---

## Controls

| Action | Gamepad | Keyboard |
| :--- | :--- | :--- |
| **Connect Player 2** | Hold `L3 + R3` | `F6` |
| **Open / Close P2 Menu** | P2 `Select / View` | `F2` |
| **Cycle Screen / Camera Mode** | P2 Menu -> `Settings` | `F9` |
| **Revive Downed Teammate** | Stand in ring *(hold `X` / `A` to speed up)* | Stand in ring *(hold `E` / `F` to speed up)* |
| **Pause & Game Menus** | `Start`, `D-Pad / Stick`, `A`, `B` | `Esc`, Mouse Cursor & Keyboard |

---

## Configuration

Optional settings (revive timing, HUD scale, default screen mode, and presets) can be adjusted in-game via **P2 Menu -> Settings** or edited in:
`Pagoda\Binaries\Win64\ue4ss\Mods\LocalCoopMod\Scripts\config.lua`

---

## Credits

- **HyruleChosenOne / HyliaChosenOne** — Mod Creator & Maintainer
- **RE-UE4SS Team** — Unreal Engine Scripting System
- **Brain Jar Games, Inc.** — Creators and developers of *Dead as Disco*
- **Dead as Disco Modding & CSM Community** — Character Slot Mod creators & testers
- **Antigravity AI** — Co-development & UI/gameplay scripting
