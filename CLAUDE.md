# CLAUDE.md

Guidance for AI assistants working in this repository.

## What this is

**Bella's Game** — a 3D multiplayer hide-and-seek game built in **Godot 4.7**
(Forward+ renderer), written entirely in GDScript. It is a small family project
(a parent and step-daughter), so readability and playfulness matter more than
engineering ceremony.

Key property of the codebase: **there are no art assets.** Every character,
prop, and decoration is generated from Godot primitives (`SphereMesh`,
`CylinderMesh`, `BoxMesh`) in code at runtime. There is no import pipeline, no
`.glb`/`.png` art, and the whole repo is ~2,900 lines across 7 scripts and 3
scenes. Preserve this: **do not add downloaded or binary art assets** — build
new visuals procedurally like everything else.

## Layout

```
project.godot          Engine config: autoloads, input map, display, rendering
export_presets.cfg     macOS export preset (tracked on purpose; no secrets in it)
icon.svg               The only real asset
scenes/
  Main.tscn            Root scene (main_scene): instances Arena + all UI CanvasLayer
  Arena.tscn           World: environment/sky, lights, NavigationRegion3D,
                       Players container, MultiplayerSpawner
  Player.tscn          CharacterBody3D + Visual(Squishy) + camera rig +
                       NavigationAgent3D + AIController + MultiplayerSynchronizer
scripts/
  NetworkManager.gd    AUTOLOAD. Host/join, roster, player spawning
  GameManager.gd       AUTOLOAD. Round state machine, roles, tagging, scores
  Player.gd            Movement, camera, role/tag reactions (humans AND bots)
  AIController.gd      Server-only bot brain (hide / flee / patrol / chase)
  Squishy.gd           Procedural character construction + squash-stretch animation
  Arena.gd             Procedural playfield, spawn points, navmesh bake
  Main.gd              Menu, lobby, HUD, scoreboard, headless smoke test
```

`*.gd.uid` files are Godot 4.4+ script UID sidecars — engine-generated, keep them
in sync (never hand-edit, never delete without deleting the script).

## Commands

There is no build system, package manager, test framework, or linter. Everything
goes through the Godot binary. Substitute your own path — on the author's machine
it is `/Users/natashavanegas/Downloads/Godot.app/Contents/MacOS/Godot`.

```bash
# Open in the editor
godot --path .

# Run the game
godot --path .

# Headless smoke test: hosts a game against the bots and plays a round unattended
godot --headless --path . -- autotest

# Same, with screenshots of the hiding and seeking phases
SHOT_DIR=/some/folder godot --path . -- autotest

# Export the macOS app (writes to build/, which is gitignored)
godot --headless --path . --export-release "macOS" "build/Bella's Game.app"
```

**Note:** Godot is *not* installed in the Claude Code remote container. Changes
made here cannot be run or verified by executing the game — reason carefully
about correctness, and say plainly in your summary that the change is unverified
rather than implying it was tested.

### The smoke test is the only test

`Main._run_smoke_test()` (`scripts/Main.gd:57`) is the whole verification story.
It runs when `--` `autotest` is passed as a user arg, and prints:

- `[test] players spawned:` — should be 4 (host + 3 bots)
- `[test] state= hunter= hiders=` — role assignment worked
- `[test] bots moving: N/3` — **the important one.** If this reads 0, bot
  navigation is broken. This line exists because of a real regression: the
  `NavigationAgent3D`'s `path_height_offset` put waypoints further above the
  characters' feet than `path_desired_distance`, so agents never registered
  arriving at a waypoint and stood frozen forever. Those two properties live in
  `scenes/Player.tscn` (`path_desired_distance = 1.2`, `path_height_offset = 0.5`)
  and must stay in that relationship.
- `positions ok=` — nobody fell through the floor or escaped the arena
- `remaining= tagged= state=` — tagging is actually resolving

If you touch navigation, authority, spawning, or the round flow, run this and
report the numbers.

## Architecture

### Autoloads and singletons

`NetworkManager` and `GameManager` are autoloads (see `[autoload]` in
`project.godot`), so scripts reference them by bare name with no `get_node`.
They are plain `Node`s, not classes — don't add `class_name` to them.

### Authority model — server-authoritative, clients render

This is the single most important convention. Get it wrong and things desync or
silently do nothing.

- **The server (peer 1) owns:** round timing, role selection, tag detection,
  scores, the roster, and *all* bot movement.
- **Each human player's own peer owns:** its own `Player` body's movement.
  `Player.gd:168` gates `_move()` behind `is_multiplayer_authority()`.
- **Bots are authority-1** — set in `Arena._spawn_player_node()`:
  `player.set_multiplayer_authority(1 if data.bot else int(data.id))`.
- **Visuals run on every peer.** `visual.animate(...)` in `_physics_process` is
  deliberately outside the authority check so remote players animate too.
- Server-only functions early-return with `if not multiplayer.is_server(): return`.
  Follow that pattern rather than inventing a new guard.

Replication of position/rotation is done by the `MultiplayerSynchronizer` in
`Player.tscn` (`.:position` and `Visual:rotation`). Anything else that must be
seen by all peers goes through an explicit `@rpc`.

### Spawning goes through the MultiplayerSpawner's custom spawn function

`NetworkManager._spawn_player()` calls
`spawner.spawn({"id":…, "name":…, "bot":…, "slot":…})`, and
`Arena._spawn_player_node()` runs that dictionary through on **every** peer.
This is why identity (id, name, bot flag, cosmetic slot, authority) is correct
everywhere instead of only on the server. Never instantiate `Player.tscn`
directly for a networked player. Anything else that must look the same on every
peer from the moment a player appears belongs in this dictionary.

The spawner and the arena find each other by group, not by path:
`arena_root`, `player_spawner`, `players_container` (added in `Arena._ready()`).
`get_tree().get_first_node_in_group("arena_root")` is the idiom used throughout.

### Player IDs

- Host is always `1`.
- Joining peers get Godot's own (effectively random, positive) peer IDs.
- **Bots use negative IDs**: `AI_ID_BASE = -1`, so `-1, -2, -3`. Code
  distinguishes bots with `id < 0` in places (e.g. the lobby's "(computer)"
  suffix in `Main._refresh_player_list()`), so keep bot IDs negative.

### Cosmetic slots

Appearance is **not** derived from the peer ID. `NetworkManager._claim_slot()`
hands out the lowest free slot (`player_slots`, id → slot) as each player is
spawned, and the slot rides along in the spawn dictionary so every peer agrees.
Host takes 0, the three bots 1–3, joiners 4 upward; a leaver's slot is freed and
reused so the low slots stay dense.

Slot drives species (`_species_index()` — `slot % 6`) and colour
(`Player._my_color()`). The colour index is staggered by
`(slot + slot / 6) % 6`, so species repeats every six slots but the colour
shifts a step each wrap: 36 distinct combinations, comfortably more than a full
lobby, and no two players are ever the same squishy in the same colour.
`_slot()` keeps a peer-ID fallback for the case where a `Player` runs outside
the spawner (opening `Player.tscn` in the editor) — networked play always has a
real slot.

This is also what `Player._take_lobby_position()` indexes into
`arena.hider_spawns`, so joining peers spread out deterministically instead of
by arbitrary ID.

### Round flow (`GameManager`)

`State.LOBBY → HIDING → SEEKING → ROUND_OVER`, driven by `start_round()` on the
server and pushed to everyone with `_broadcast_state.rpc(...)`.

- `HIDE_TIME = 10.0`, `SEEK_TIME = 90.0`, `TAG_RADIUS = 1.6`
- The hunter is picked at random from `_known_players`, excluding `_last_hunter`
  when possible, so nobody is IT twice in a row.
- Tagging is pure server-side proximity (`_check_tags()` in `_process`), not an
  input action — the `tag_action` (F) binding exists in the input map but is
  currently unused.
- Scoring: hunter catching everyone scores the hunter; timer expiring scores
  every untagged hider.
- `spawn_point_for(id)` is deterministic (hunter in the middle, hiders around a
  ring) so every peer agrees on start positions.

`Player._can_move()` encodes the ritual: nobody moves in LOBBY/ROUND_OVER, the
hunter is frozen during HIDING, tagged players can't move at all.

### Bot AI (`AIController.gd`, server-only)

Not scripted paths — bots use `NavigationAgent3D` against the baked navmesh:

- **As hider:** wander between `arena.hiding_spots`; if the hunter comes within
  `PANIC_RANGE` (5 m), flee to cover scored by *far from hunter, near to me*.
- **As hunter:** patrol cover points, and chase only what it can actually see —
  `_can_see()` checks range (`SIGHT_RANGE` 14 m), a `SIGHT_ANGLE` 75° vision
  cone, and a raycast with `collision_mask = 1` so **only scenery blocks sight,
  never other players**. Breaking line of sight genuinely works.
- Per-bot randomised `_boldness`, `_jumpiness`, `_reaction_delay` so the three
  don't move as a block.

### Collision layers

- **Layer 1** — world/scenery (ground, walls, prop colliders). This is what
  blocks both movement and the AI's line-of-sight raycast.
- **Layer 2** — players. `Player.tscn` is `collision_layer = 2, collision_mask = 1`.
  Tagged players are removed from layer 2 (`set_collision_layer_value(2, false)`)
  so ghosts don't body-block the living.

If you add scenery that should *not* block AI vision or navigation, add it as a
plain `MeshInstance3D` outside `NavigationRegion3D` — that's what the mushroom
caps, tree canopies, pond, lamps, rainbow and clouds already do.

### Procedural world (`Arena.gd`)

`_ready()` order matters and is commented in place: ground → walls → props →
spawns → **navmesh bake** → decoration. Decoration is added *after* the bake and
*outside* `nav_region`, so it can never affect pathing.

The level is tuned by editing the `PROPS` constant table at the top of
`Arena.gd` (`type`, `pos`, `size`, `color`) — don't hand-place nodes in the
scene. Supported types: `mushroom`, `block`, `pillar`, `bush`, `tree`, `rock`,
`candy`. Each prop automatically contributes a `hiding_spots` entry just behind
it (away from arena centre), which is what the AI navigates between — so adding
a prop also adds AI cover.

Flowers use a single `MultiMesh` (260 instances, one draw call) with a fixed RNG
seed so the meadow looks the same every run.

### Characters (`Squishy.gd`)

Six species (`BUNNY, CAT, BEAR, FROG, CHICK, PUPPY`), each with its own body
proportions, ears, face layout, and extras (beak/snout/tail). `build()` is
idempotent via the `_built` guard.

Animation is procedural, driven from `Player._physics_process` via
`visual.animate(delta, speed_ratio, grounded)`:

- `_squash` is a spring (`pop(amount)` kicks it: `+` stretches tall for jumps,
  `−` squashes flat for landings), and width is derived as `1/sqrt(stretch)` to
  preserve volume.
- `_walk_phase` drives bounce, ear swing, foot shuffle, tail wag.
- Blinking is a random-interval `Tween`; `look_at_point()` makes IT's eyes track
  its prey.
- `set_hunter_glow()` / `set_ghost()` / `set_base_color()` are the state hooks
  `Player.gd` calls on role change and tagging.

### UI (`Main.gd`)

Four mutually-exclusive `Control` panels — Menu, Lobby, HUD, RoundOver — toggled
by `_show_only()`, which also grabs the mouse when the HUD comes up. All node
references are `@onready` with full paths into `Main.tscn`, so **renaming a UI
node in the scene breaks `Main.gd`** — update both together.

Nameplates hide for hiders during SEEKING (`Player._update_name_visibility()`),
otherwise floating labels would give away every hiding spot.

## Conventions

- **Tabs for indentation** (Godot standard), two blank lines between top-level
  functions.
- **Typed declarations** where practical: `var x: float = 0.0`, `func f(d: float) -> void:`.
  `:=` inference is used freely for locals.
- **`##` doc comments** at the top of every script and above anything non-obvious.
  The comment style here explains *why*, often referencing the bug or the play
  experience that motivated the code ("less floaty, more toy-like"; "otherwise a
  floating nameplate gives away every hiding spot"). Match that voice — warm and
  concrete, not formal.
- **`_leading_underscore`** for private members and internal state.
- **Tunable numbers are `const`s at the top of the script**, never inline magic
  numbers: `WALK_SPEED`, `HIDE_TIME`, `SIGHT_RANGE`, `ARENA_HALF`, `PALETTE`.
  A new tunable belongs up there.
- Signals over polling for cross-system communication (`state_changed`,
  `player_tagged`, `player_list_changed`, `scores_changed`, `round_finished`).
- Groups over hard node paths for cross-scene lookups.

## Gotchas

- **Hosting fails silently if the port is taken.** `host_game()` returns `false`
  (port `8910`); `Main._on_host_pressed()` must show that rather than opening an
  empty lobby. Usually it means a second copy of the game is already running.
- **Don't call `queue_free()` on a networked player from a client** — removal is
  server-driven via `_on_peer_disconnected`.
- **`GameManager._process` decrements `time_left` on every peer** but only the
  server checks tags and ends the round. Adding logic there needs the
  `is_server()` guard.
- **`start_round()` `await`s a real timer** between HIDING and SEEKING and
  re-checks `state` afterwards; don't remove that re-check or a round started
  during a stale await will stomp the current one.
- **Two players minimum.** `start_round()` bails below 2 known players — bots
  count, so solo hosting works.
- **Godot 4.7 APIs.** This targets a recent Godot; `NavigationServer3D.parse_source_geometry_data`
  / `bake_from_source_geometry_data` and `MultiplayerSpawner.spawn_function` are
  4.x-only. Don't "fix" them into 3.x forms.
- **`.godot/` is gitignored** — the import cache regenerates. Never commit it.

## Git workflow

- Default branch: `main`. Work on the assigned feature branch, and push with
  `git push -u origin <branch>`.
- Commit messages in this repo are short, imperative, and describe the player-
  visible change ("Fix frozen AI, give every player a different squishy, fill out
  the world").
- Keep `README.md` in step with behaviour changes — it's written for the family,
  in plain language, and doubles as the game's design doc.
