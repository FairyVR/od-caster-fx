# Fairy Caster FX — design

Date: 2026-07-30
Author: Fairy-
Package: `fairy.casterfx`

## Goal

Raise Orion Drift competitive broadcast production value with two things:

1. **Static team logos** rendered over the in-game scoreboard crests, sourced from Orion
   Drift Competitive team profiles.
2. **Over-the-top VFX** — goal explosions, kickoff bursts, ball trail, impact rings —
   built on the new custom-mesh API rather than line draws.

A ball-following autocam was in the original request but is **out of scope**: Plutus
Autocaster's `AutoCast` mode already is one (orbit bias, velocity lead, raycast collision
and player avoidance, goal cam, kickoff orbit). Rebuilding it would duplicate working
code. This package is an overlay that renders *on top of* whatever camera is active,
Plutus included.

## Constraints discovered (all verified against `types/v2/base.d.lua`)

These shaped the design more than any preference did.

| Constraint | Consequence |
|---|---|
| **No outbound HTTP anywhere in the Luau API.** `Network.*` only connects to game servers; the only HTTP is the client's *inbound* API on `127.0.0.1:5420`. Zero matches for `Http`/`WebSocket`/`fetch` across the type surface. | The camera cannot fetch logos. A companion process must place them on disk. |
| **`LuauFile` is sandboxed to the calling package folder.** | Logos must live in `fairy.casterfx/logos/`, not in Downloads or a shared folder. |
| **`mesh.color` is only used when `texture` is nil** ("Solid color the mesh renders with when no texture is set"). | A textured sprite cannot be tinted per team. Team-coloured particles must be untextured geometry; sprites stay white. |
| **Texture alpha is cutout**, not blended. | No soft edges and no fade-out. Particles fade by *shrinking*. Sprites are hard-edged geometric shapes; a radial gradient would just get sliced at the threshold. |
| **`mesh.triangles` is 0-based** and winding is swapped relative to the usual CCW convention. | Every mesh here emits **both** windings, so a winding mistake cannot make geometry invisible. Asserted in the self-test. |
| **Transform changes need no `draw()`; colour/texture/geometry changes do.** | Animate hundreds of particles for free; pay `draw()` only when a pooled mesh's material actually changes. |
| **`TeamColor` exposes `teamName`, `primary`, `secondary`, `teamLogoIndex`, `teamRowId`.** | Logo selection is automatic from the live match — no manual picking in the normal case. |
| Scoreboard position is exposed nowhere, and differs per gamemode. | Placement is a live GUI editor saved per arena type. Hardcoded offsets would be guesses. |

## Architecture

An overlay script with `alwaysTick = true`. Seven files, each with one job:

| File | Responsibility | Depends on |
|---|---|---|
| `main.luau` | lifecycle, config defaults, arena selection, event routing, GUI | all |
| `match.luau` | live state for one gamemode slot: arena transform, team names/colours/scores, goal positions, ball, goal/kickoff events | `util` |
| `logos.luau` | logo quads: file scan, texture load, placement, `wanted.json` | `util` |
| `particles.luau` | pooled mesh particle engine + self-test | `util` |
| `effects.luau` | the actual VFX composed from the engine | `util`, `particles` |
| `util.luau` | maths, colour conversion, name sanitising, config seeding | — |
| `package.json` | manifest | — |

`match.luau` is a lean rewrite rather than a copy of Plutus's `arena`/`box`/`gamemodes`
trio: `require` is package-scoped so cross-package reuse is impossible anyway, and this
package needs only a fraction of that machinery. The arena classification and goal offsets
use the same values Plutus does, so offsets remain interchangeable between the two.

**Meshes only, never `WorldDraw` lines.** Other scripts call `WorldDraw.clear()` every
frame — Plutus does — which drops lines and points *even if permanent* but leaves meshes
alone. Any line draw added here would flicker or vanish.

### Data flow

```
SpectatorGamemodes.getGamemodeData() ─┐
getGameData().balls ─────────────────┴─> match:tick() ─> events[] ─> effects.*  ─> particles.spawn()
                                                      └> team names ─> logos.update() ─> logo quads
                                                                    └> logos.writeWanted() ─> wanted.json
                                                                                                  │
                                                                          get-logos.ps1 -Watch ───┘
                                                                                     ↓
                                                                     ODC API ──> logos/<STEM>.png
```

## Logo workflow

`STEM` is the team name uppercased, with every UTF-8 byte outside `A-Z0-9` replaced by
`_`. `Util.sanitizeTeamName` (Luau) and `Get-Stem` (PowerShell) must stay byte-identical;
both walk UTF-8 bytes for that reason. `-FREE CODY` → `_FREE_CODY.png`.

Resolution order per side: manual GUI override → `logos/<STEM>.png` → hidden, with the
reason shown in the GUI (`missing SHOT.png`, `no team name`, …).

Two ways to get files there:

- `.\get-logos.ps1 "TEAM A" "TEAM B"` — fetch now. Matching is exact, then by stem, then
  substring; ambiguous substrings list candidates rather than guessing.
- `.\get-logos.ps1 -Watch` — polls `wanted.json`, which the camera writes with the team
  names it detected in the live match. Nothing to type during a broadcast.

The index is paginated at `limit=50` (server-capped) and cached for 12 hours in
`.odc-teams-cache.json`. Images are re-encoded to square 512×512 PNGs so the Luau side
only ever loads `.png`, whatever the CDN served.

## VFX design

Pooled meshes, capped by `maxMeshes` (default 420). A pool entry caches its current
colour and texture and skips `draw()` when a new particle wants the same material — so
repeat goals by the same team cost zero redraws. When a burst exceeds the budget the
engine recycles its own oldest particles rather than dropping the new ones.

Four shapes, all double-sided: `quad` (billboarded sprite), `shard` (tapered spike, used
for debris and velocity-aligned streaks), `ring` (annulus shockwave), `disc`.

Facing modes: `billboard` (camera-facing, with roll spin), `velocity`, `spin`, `fixed`.

Everything shrinks out over the last 25% of its life, because alpha cannot fade.

Effects: goal explosion (core pop, three staggered mouth-plane rings, one floor ring, 140
bouncing debris shards, 70 sparks, 45 flares, 22 stars, two decaying point lights),
kickoff burst, speed-scaled ball trail tinted by possession, and impact rings triggered by
a single-frame ball velocity delta over a threshold.

All counts scale with one `intensity` slider; each effect has an on/off toggle.

## Verification

**Verified by running it:** `get-logos.ps1` against the live ODC API (769 teams indexed,
logos downloaded and re-encoded, stem sanitising checked against a symbol-bearing team
name), `make-sprites.ps1` (three valid 256×256 ARGB PNGs), and a bracket/keyword balance
check over all six Luau files.

**Not verified:** everything that needs the game running. The Luau has never been parsed
by the real interpreter, no mesh has been drawn, and the light intensity units are a
guess. Specifically unknown until tested in-game:

- default logo slot positions — they are *deliberately* placeholder, meant to be visible
  enough to find and drag into place;
- UV orientation (hence `flipU` / `flipV` toggles per slot);
- point light intensity scale (hence the `lightIntensity` calibration slider);
- whether 420 pooled meshes is comfortable or heavy.

`Particles.selfTest()`, wired to a button in the Debug tab, asserts the invariants that
are impossible to eyeball: 0-based triangle indices, index range, normal/UV counts matching
vertex counts, and pool acquire/release accounting.

`SpectatorDebug.goalExplosions` exists as a manual trigger, and the VFX tab has
**Test goal explosion** / **Test kickoff** buttons, so nothing requires an actual match.

## Install

Copy `fairy.casterfx/` into `…/Another-Axiom/A2/Cameras/Behaviors/`. On this machine
Documents is OneDrive-redirected, so that is
`C:\Users\tibba\OneDrive\Documents\Another-Axiom\A2\Cameras\Behaviors\`.

Scripts hot-reload on save. `F2` to activate or bind, `F3` for this camera's panel,
`F4` for Camera Logs.

## Deliberately not built

- An autocam (Plutus has one).
- A general particle *editor* with curves, sub-emitters, and atlases. The engine is
  reusable, but the full library Brick_Rage12 described is its own project.
- Player outlines or highlights, ball outlines, speech bubbles — separate asks from the
  same conversation.
- Caster Bridge integration. The ODC API turned out to be a cleaner logo source than
  bridging, and `wanted.json` covers the handshake.
