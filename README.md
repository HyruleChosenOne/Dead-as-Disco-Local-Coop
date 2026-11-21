<p align="center">
  <img src="assets/header_logo.png" alt="Dead as Disco - Local Co-op" width="540" />
</p>

<h1 align="center">Dead as Disco - Local Co-op Mod (v1.0 Experimental)</h1>

<p align="center">
  2-player local co-op mod for <strong>Dead as Disco</strong> built on RE-UE4SS. Play together across the Dive Bar and combat stages with Custom Character (CSM) support, a co-op revive system, co-op enemy AI targeting, isolated Player 2 builds, native Player 2 HUD widgets, and Split-Screen or Shared Arena camera modes.
</p>

---

## Features

### 2-Player Local Co-op
- **Drop-In / Drop-Out:** Connect Player 2 in the Dive Bar or during a stage by holding **`L3 + R3`** on a controller or pressing **`F6`** on keyboard. Disconnect anytime via **P2 Menu -> Settings**.
- **Controller Setups:** Defaults to **1 Keyboard & Mouse (P1) + 1 Controller (P2)**, with a **2 Controllers** toggle inside settings.

### Custom Character (CSM) & Wardrobe Support
- **Character Slot Mods (CSMs):** Scans `Pagoda/Content/Paks/~mods` (`.utoc`, `.pak`, and `info.json`) so Player 2 can play as custom modded characters.
- **Charlie Wardrobe:** Mix and match individual Jackets, Hair, Glasses, Drumsticks, and Body Types for Player 2, or pick from 14 outfit presets.

### Co-op Revive System & Enemy AI Targeting
- **Downed State & Revive Ring:** Taking fatal damage while your teammate is standing puts you on the ground inside a revive ring instead of ending the stage.
- **Team Recovery:** Stand inside the ring to revive your teammate, or hold **`X` / `A`** on controller / **`E` / `F`** on keyboard to speed up recovery. Revived players kip up into a disco dance with restored health and brief invulnerability.
- **Co-op Aggro Director:** Balances enemy targeting across both players during combat and redirects enemies off downed players onto the standing teammate.
- **Team Wipe:** Game Over triggers only if both players are downed simultaneously.

### Independent Player 2 Builds & Saved Profile
- **Isolated Loadouts:** Equip Player 2 with separate 4-slot Boss Abilities, Idol Skill Tree upgrades across all 6 Idols (Charlie, Dahlia, Arora, Prophet, Rebel, and Shred), and 4 D-Pad Dance Moves without altering Player 1's save or loadout.
- **Automatic Saving:** Player 2's character, outfit, skills, dances, HUD scale, and camera preferences persist automatically in `p2_profile.json`.

### Native Player 2 HUD & Screen Modes
- **Native Player 2 Interface:** Displays Player 2's Hearts, Execution Tokens, Fever Bar, Combo Multiplier, and Boss Ability slots.
- **3 Camera & Screen Modes (`F9`):**
  - **Horizontal Split-Screen:** Top and bottom viewports with independent cameras.
  - **Vertical Split-Screen:** Left and right viewports.
  - **Shared Arena Camera:** Single shared combat view with `PLAYER 1` and `PLAYER 2` HUD tags and Cyan (P1) / Pink (P2) floor rings.

### In-Game Player 2 Menu (Dive Bar & Mid-Match)
- **Dive Bar Menu:** Press **`Select / View`** on Player 2's controller (or **`F2`**) in the Dive Bar to browse all 5 tabs (`CHARACTER`, `MOVES`, `DANCES`, `UPGRADES`, `SETTINGS`) with 360-degree Right-Stick preview rotation.
- **Mid-Match Pause Menu:** Opening the Player 2 Menu during a stage pauses gameplay and the music track so Player 2 can swap character models, attacks, or camera settings mid-run.

### Experimental Features (Optional Toggle)
Enable **Experimental Features** inside **P2 Menu -> Settings** to unlock:
- **6 Neon Rim Tints** for Player 2 (`Neon Cyan`, `Disco Magenta`, `Electric Gold`, `Crimson Flame`, `Emerald Mint`, `Royal Violet`).
- **15 Playable Boss & Enemy Models** for Player 2 (*La Pantera*, *Arora*, *Rebel*, *Shred*, *Bouncer*, *Mosher*, *Fanatic*, *Echo*, *Stix*, and more).
- **Live Diagnostics** sub-tab under Settings.

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
  - For an all-in-one archive with RE-UE4SS runtime files already bundled, download `Dead_as_Disco_Local_Coop_v1.0_Experimental_With_UE4SS_Prerequisites.zip` on [Nexus Mods](https://www.nexusmods.com/deadasdisco/mods/1567).

### Mod-Only Install
1. Download **`Dead_as_Disco_Local_Coop_v1.0_Experimental.zip`** from **[Releases](../../releases)** (or Nexus Mods).
2. Extract directly into your **Dead as Disco** game folder (where the `Pagoda` folder is located) so `LocalCoopMod` lands in `Pagoda\Binaries\Win64\ue4ss\Mods\LocalCoopMod\`.
3. Confirm `LocalCoopMod : 1` is enabled in `Pagoda\Binaries\Win64\ue4ss\Mods\mods.txt`.
4. Launch the game, enter the **Dive Bar**, and hold **`L3 + R3`** (or press **`F6`**) to connect Player 2.

---

## Recent Updates

- **Revive & In-Game HUD Polish:** Confined projected revive callouts within the rescuer's viewport half during split-screen, added smoothed screen tracking and off-screen distance prompts, made hold prompts input-aware, increased bar and medallion readability, and hid the revive overlay while paused or in menus. Aligned `PLAYER 1` / `PLAYER 2` HUD badges and matched toast outlines to notification severity.
- **P2 Menu Adjustments:** Refined active tab outline contrast, row height and border hierarchy, `LT` / `RT` pill styling, sub-tab truncation limits, and distinct equipped-state styling on the footer action button.
- **Stability & State Isolation Fixes:**
  - Fixed world-cache races in `UObjectUtils` and cleared destroyed-object caches across level transitions to prevent recycled UObject address collisions.
  - Fixed stuck `Spawning` / `Despawning` session states when interrupted by level loads and fixed cutscene watchdog handling in Shared Arena Camera mode.
  - Fixed GC-invalidated caches for revive montages, native UI textures, FMOD events, and player floor marker assets.
  - Fixed same-frame `Scheduler.Defer` tag collisions on cosmetics and viewport confinement hooks, capped missing-hook and broken-CSM retries, paused revive/i-frame timers during game pause, and corrected legacy boss-slot fallback asset names in `ProfileStore`.

---

## Repository Layout

- `Pagoda/Binaries/Win64/ue4ss/Mods/LocalCoopMod/` - Mod source files (`Scripts/`), `enabled.txt`, and `README.md`
- `assets/` - Header logo (`header_logo.png`)
- `legacy/v2.2/` - Archived legacy `v2.2` version of the mod

---

## Credits

- **[HyruleChosenOne](https://github.com/HyruleChosenOne) / [HyliaChosenOne](https://www.nexusmods.com/deadasdisco/mods/1567)** - Mod Creator & Maintainer
- **[RE-UE4SS Team](https://github.com/UE4SS-RE/RE-UE4SS)** - Unreal Engine Scripting System
- **Brain Jar Games, Inc.** - Creators and developers of *Dead as Disco*
- **Dead as Disco Modding & CSM Community** - Character Slot Mod creators, templates, and testers
- **Antigravity AI** - Co-development & UI/gameplay scripting
