# Dead as Disco - Local Co-op Mod (`v1.0 Experimental`)

2-player local co-op mod for **Dead as Disco** built on RE-UE4SS. Supports the Dive Bar hub and combat stages with Custom Character (CSM) loading, a co-op revive system, isolated Player 2 builds, native Player 2 HUD widgets, co-op enemy AI targeting, and Split-Screen or Shared Arena camera modes.

---

## Features

- **2-Player Local Co-op:** Connect Player 2 in the Dive Bar or during a stage by holding **`L3 + R3`** on a controller or pressing **`F6`**. Supports **1 Keyboard/Mouse (P1) + 1 Controller (P2)** or **2 Controllers**.
- **Custom Character (CSM) & Wardrobe Support:** Scans `Pagoda/Content/Paks/~mods` (`.utoc`, `.pak`, and `info.json`) so Player 2 can use installed Character Slot Mods, or equip modular Charlie clothing pieces and 14 outfit presets.
- **Co-op Revive System:** Taking fatal damage while your teammate is alive puts you on the ground inside a revive ring. Stand inside the ring (or hold **`X` / `A`** on controller or **`E` / `F`** on keyboard for a faster revive) to get back up with a disco dance, restored health, and brief invulnerability. Game Over only triggers if both players are downed at the same time.
- **Co-op Enemy AI Targeting:** Balances enemy aggro across both players during combat and redirects enemies off a downed player onto the standing teammate until recovery.
- **Independent Player 2 Builds:** Equip Player 2 with separate 4-slot Boss Abilities, Idol Skill Tree upgrades across all 6 Idols, and 4 D-Pad Dance Moves. Choices persist automatically in `p2_profile.json` without modifying Player 1's save or loadout.
- **Native Player 2 HUD & 3 Camera Modes:** Displays Player 2's Hearts, Execution Tokens, Fever Bar, Combo Multiplier, and Boss Ability bar across **Horizontal Split-Screen**, **Vertical Split-Screen**, and **Shared Arena Camera** (with `PLAYER 1` / `PLAYER 2` HUD tags and Cyan / Pink floor rings).
- **In-Game Player 2 Menu:** Full 5-tab customization menu in the Dive Bar (with 360-degree Right-Stick preview rotation), or a paused mid-match menu during stages for swapping models, attacks, and camera settings.
- **Experimental Features Toggle:** Optional setting in **P2 Menu -> Settings** that enables 6 neon rim tints, 15 playable Boss and Enemy humanoid models, and live diagnostics.

---

## Controls

| Action | Gamepad | Keyboard |
| :--- | :--- | :--- |
| **Connect Player 2** | Hold `L3 + R3` | `F6` |
| **Open / Close P2 Menu** | P2 `Select / View` | `F2` |
| **Cycle Screen / Camera Mode** | P2 Menu -> `Settings` | `F9` |
| **Revive Downed Teammate** | Stand in ring (hold `X` / `A` to speed up) | Stand in ring (hold `E` / `F` to speed up) |
| **Pause & Game Menus** | `Start`, `D-Pad / Stick`, `A`, `B` | `Esc`, Mouse & Keyboard |

---

## Installation

### Prerequisites
- **[RE-UE4SS](https://github.com/UE4SS-RE/RE-UE4SS)** (`v3.0.1 Beta` or newer for Unreal Engine 5.7) installed in `Dead as Disco\Pagoda\Binaries\Win64\`.
  - If you downloaded the All-in-One archive (`Dead_as_Disco_Local_Coop_v1.0_Experimental_With_UE4SS_Prerequisites.zip`), RE-UE4SS and its required runtime files are already bundled.

### Install Steps
1. Extract the release archive directly into your **Dead as Disco** game directory (e.g., `...\steamapps\common\Dead as Disco\`, where the `Pagoda` folder is located).
2. Confirm `Pagoda\Binaries\Win64\ue4ss\Mods\LocalCoopMod\` exists and `LocalCoopMod : 1` is enabled in `mods.txt`.
3. Launch the game, enter the Dive Bar, and hold **`L3 + R3`** (or press **`F6`**) to connect Player 2.

---

## Configuration

Settings for revive timing, HUD scaling, default screen mode, and presets can be changed in-game via **P2 Menu -> Settings** or edited directly in:
`Pagoda\Binaries\Win64\ue4ss\Mods\LocalCoopMod\Scripts\config.lua`

---

## Recent Updates

- **Revive & HUD Polish:** Added split-screen safe viewport bounds and smoothed screen projection to the revive callout so it no longer clips edges or crosses split seams; added off-screen distance text, input-aware hold prompts, higher-contrast bar/medallion sizing, and automatic hiding while paused or in menus. Aligned `PLAYER 1` / `PLAYER 2` arena HUD badges and matched toast border colors to notification severity.
- **P2 Menu Refinements:** Improved active tab outline contrast, row spacing, selected/equipped border hierarchy, `LT` / `RT` button alignment, sub-pill truncation limits (so `DIAGNOSTICS` displays cleanly), and equipped-state styling on the footer action button.
- **Stability & State Isolation Fixes:**
  - Fixed world-cache race conditions in `UObjectUtils` and cleared destroyed-object caches on level transitions to prevent recycled UObject address collisions.
  - Fixed session spawn/despawn phase recovery if a level transition interrupts Player 2 spawn, and prevented cutscene state from stalling in Arena Camera mode.
  - Fixed GC-invalidated cache lookups for montages, native UI textures, FMOD cues, and floor ring assets across repeated stage loads.
  - Fixed `Scheduler.Defer` tag collisions on simultaneous P1/P2 cosmetics and viewport widget hooks, capped missing-hook and broken-CSM retries, froze revive/i-frame timers while paused, and fixed legacy fallback boss-slot asset names in `ProfileStore`.

---

## Credits

- **HyruleChosenOne / HyliaChosenOne** - Mod Creator & Maintainer
- **RE-UE4SS Team** - Unreal Engine Scripting System
- **Brain Jar Games, Inc.** - Creators and developers of *Dead as Disco*
- **Dead as Disco Modding & CSM Community** - Character Slot Mod creators & testers
- **Antigravity AI** - Co-development & UI/gameplay scripting
