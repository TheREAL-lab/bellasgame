# CLAUDE.md

Guidance for AI assistants working in this repository.

## What this is

**Squishy Island** — a 3D battle royale built in **Godot 4.7** (Forward+
renderer), written entirely in GDScript. One human (or two, over LAN) drops onto
an island with 100 AI bots, and the last squishy bouncing wins. It is a small
family project (a parent and step-daughter), so readability and playfulness
matter more than engineering ceremony.

It grew out of a hide-and-seek prototype. The characters, the procedural
world-building, the networking and the squash-and-stretch animation are
inherited from it; the hide-and-seek round flow is gone entirely.

Key property of the codebase: **there are no art assets.** Every character,
prop, weapon and decoration is generated from Godot primitives (`SphereMesh`,
`CylinderMesh`, `BoxMesh`) in code at runtime. There is no import pipeline and
no `.glb`/`.png` art. Preserve this: **do not add downloaded or binary art
assets** — build new visuals procedurally like everything else.

## Layout

```
project.godot          Engine config: autoloads, input map, display, rendering
export_presets.cfg     macOS export preset (tracked on purpose; no secrets in it)
icon.svg               The only real asset
scenes/
  Main.tscn            Root scene (main_scene): instances Island + all UI CanvasLayer
  Island.tscn          World: environment/sky, lights, NavigationRegion3D,
                       Players container, MultiplayerSpawner
  Player.tscn          CharacterBody3D + Visual(Squishy) + camera rig +
                       NavigationAgent3D + BattleAI + MultiplayerSynchronizer
scripts/
  SaveData.gd          AUTOLOAD. Coins, unlocks, perks; the only thing touching disk
  NetworkManager.gd    AUTOLOAD. Host/join, roster, player spawning
  MatchManager.gd      AUTOLOAD. Match state, alive tracking, placement, the storm
  Player.gd            class_name Player. Movement, camera, combat, hover, pickups
  BattleAI.gd          Server-only bot brain (loot / hunt / fight / retreat / flee)
  Squishy.gd           class_name Squishy. Character construction + animation
  Weapons.gd           class_name Weapons. Weapon table + procedural weapon models
  Loot.gd              Ground loot: weapons, spinny hats, coins
  Storm.gd             Draws the shrinking wall and the safe patch
  Island.gd            Procedural island, spawn points, loot spots, navmesh bake
  Main.gd              Menu, shop, lobby, battle HUD, results, headless smoke test
```

`*.gd.uid` files are Godot 4.4+ script UID sidecars — engine-generated, keep them
in sync (never hand-edit, never delete without deleting the script).

## Commands

There is no build system, package manager, test framework, or linter. Everything
goes through the Godot binary.

**Godot is not preinstalled in the Claude Code remote container, but it can be.**
`godotengine.org` is blocked by the agent proxy; GitHub release assets are not:

```bash
curl -sSL -o /tmp/godot.zip \
  https://github.com/godotengine/godot-builds/releases/download/4.7-stable/Godot_v4.7-stable_linux.x86_64.zip
unzip -o -q /tmp/godot.zip -d /tmp && install -m755 /tmp/Godot_v4.7-stable_linux.x86_64 /usr/local/bin/godot
```

Do this rather than reasoning blind — the smoke test catches real bugs, and
balance changes cannot be judged without running a match.

```bash
# Open in the editor / run the game
godot --path .

# Headless smoke test: plays a full match against 100 bots unattended (~6 min)
godot --headless --path . -- autotest

# Export the macOS app (writes to build/, which is gitignored)
godot --headless --path . --export-release "macOS" "build/Bella's Game.app"
```

### The smoke test is the only test

`Main._run_smoke_test()` runs when `--` `autotest` is passed as a user arg. It
hosts a match against the full hundred bots and plays it to a winner. What each
line is guarding:

- `shop buttons:` / `panels ok` — every `@onready` path in `Main.gd` resolved and
  the shop built. This is the canary for renaming a UI node in `Main.tscn`.
- `players spawned:` — should be 101 (you + 100 bots).
- `bots moving: N/100` — **the important one.** If this reads 0, bot navigation
  is broken. It exists because of a real regression: the `NavigationAgent3D`'s
  `path_height_offset` put waypoints further above the characters' feet than
  `path_desired_distance`, so agents never registered arriving at a waypoint and
  stood frozen forever. Those two properties live in `scenes/Player.tscn`
  (`path_desired_distance = 1.2`, `path_height_offset = 0.5`) and must stay in
  that relationship. Expect 55–80 rather than 100: bots standing still in a
  fight are legitimately not moving.
- `armed bots:` / `hatted:` — the loot loop. These should climb steeply over the
  match (roughly 30 → 70 armed). If they stay flat, the pickup sweep in
  `Loot._sweep()` or the loot table has broken.
- `frame avg / worst` — logic cost with a hundred bots thinking. Around 7 ms
  headless. **This measures CPU only; the container has no display, so render
  cost is never exercised by any of this.**
- `positions ok=` — nobody fell through the island or walked into the sea.
- `finished after Ns. winner=` — a match that never resolves is a real failure
  mode, so the test waits for a winner rather than assuming one turns up. A
  healthy match ends around 180–220 s.

If you touch navigation, authority, spawning, combat or the match flow, run this
and report the numbers.

## Architecture

### Autoloads and singletons

`SaveData`, `NetworkManager` and `MatchManager` are autoloads (see `[autoload]`
in `project.godot`), so scripts reference them by bare name with no `get_node`.
They are plain `Node`s — **don't add `class_name` to them.** `Player`, `Squishy`
and `Weapons` are the opposite: they are `class_name` scripts so the UI and the
AI can reach their constants (`Player.PALETTE`, `Squishy.SPECIES_NAMES`,
`Weapons.Kind`).

### Authority model — server-authoritative, clients render

This is the single most important convention. Get it wrong and things desync or
silently do nothing.

- **The server (peer 1) owns:** match timing, the storm, all damage and
  elimination decisions, placement, the roster, loot, and *all* bot movement.
- **Each human player's own peer owns:** its own `Player` body's movement.
  `Player._physics_process` gates `_move()` behind `is_multiplayer_authority()`.
- **Bots are authority-1** — set in `Island._spawn_player_node()`.
- **Visuals run on every peer.** `visual.animate(...)` is deliberately outside
  the authority check so remote players animate too.
- Server-only functions early-return with `if not multiplayer.is_server(): return`.

**Damage never originates on the shooter's machine.** A client presses fire,
`Player.try_attack()` sends `_request_attack.rpc_id(1, dir)`, and the server
checks the sender actually owns that body before resolving the shot. Everything
that can hurt somebody funnels through `Player.take_damage()`, which is
server-only, so there is exactly one place that decides whether a squishy is
still standing.

Position/rotation replicate through the `MultiplayerSynchronizer` in
`Player.tscn`. Anything else that must be seen by all peers goes through an
explicit `@rpc`.

### Spawning goes through the MultiplayerSpawner's custom spawn function

`NetworkManager._spawn_player()` calls `spawner.spawn({...})` and
`Island._spawn_player_node()` runs that dictionary through on **every** peer, so
identity is correct everywhere instead of only on the server. The dictionary
carries `id`, `name`, `bot`, `slot`, `species`, `color` and `perks`.

Never instantiate `Player.tscn` directly for a networked player. Anything that
must look the same on every peer from the moment a player appears belongs in
this dictionary.

**Perks and cosmetics ride in the spawn data on purpose.** `SaveData` is *this
machine's* wallet, so a `Player` node asking `SaveData` about itself would hand
every squishy on screen the local player's upgrades. The joining peer sends its
choices up in `NetworkManager._submit_profile()`.

The spawner and the island find each other by group, not by path: `arena_root`,
`player_spawner`, `players_container`, `loot`.
`get_tree().get_first_node_in_group("arena_root")` is the idiom used throughout.

### Player IDs and cosmetic slots

- Host is always `1`; joining peers get Godot's own (arbitrary, positive) IDs.
- **Bots use negative IDs**: `AI_ID_BASE = -1`, so `-1 … -100`. Code
  distinguishes bots with `id < 0`, so keep bot IDs negative.
- Appearance is **not** derived from the peer ID. `NetworkManager._claim_slot()`
  hands out the lowest free slot as each player spawns, and it rides in the spawn
  dictionary. A leaver's slot is freed and reused so low slots stay dense.
- Slot drives species (`slot % 6`) and colour, staggered by `(slot + slot / 6) % 6`
  so species repeats every six slots but the colour shifts a step each wrap: 36
  distinct combinations. A human who bought a look in the shop overrides both via
  `species_override` / `color_override`.

### Match flow (`MatchManager`)

`State.LOBBY → PLAYING → MATCH_OVER`. Placement is simply how many were still
standing when you went down, which is what a battle royale means by "you came
7th". The match ends when one player is left.

**The storm carries no per-frame replication.** Every peer is handed the phase's
start circle, end circle and duration once via `_set_phase.rpc(...)`, then
interpolates the radius itself from the phase clock — so a hundred bots running
from a wall costs nothing on the wire. Each phase holds (`wait`), then closes
(`shrink`) to a new circle placed at random but always *inside* the current one,
so running for the middle is never wrong, only slow. Damage outside is applied
server-side on a 0.5 s tick rather than every frame.

Tuning lives in `MatchManager.PHASES` and `MAX_HEALTH`.

### Combat and loot

- `Weapons.TABLE` is the single place weapons are defined — add a row and it
  appears in loot rolls, on the island and in bot hands. `WEIGHTS` controls tier
  rarity; tier 0 never drops because you already have one.
- Melee is a forgiving **cone** (about 50°), not a ray. Ranged is hitscan with a
  fading tracer; shotguns are several rays with spread.
- Tracers and swing visuals skip entirely beyond 55 m of the local player
  (`Player._too_far_to_bother`) — a hundred bots trading shots across an island
  is a lot of tracers nobody can see.
- **Loot is deliberately not physics.** 130-odd `Area3D`s testing themselves
  against 101 bodies every frame is a lot of collision pairs for something a
  distance check answers, so pickups are plain data with a mesh hanging off them
  and the server sweeps them 5×/second (`Loot._sweep`). Initial loot is seeded
  off the island so it is identical on every peer with no spawn packets; only
  *taking* something is replicated. Death drops are replicated with `Loot.drop`,
  and because RPCs arrive in order every peer appends the same index.
- Auto-pickup only takes a plain improvement (`Weapons.is_upgrade`), so walking
  over a worse gun never robs you of the good one. `E` forces a swap.

### Bot AI (`BattleAI.gd`, server-only)

The shape of this file is dictated by there being a hundred of them. Anything
expensive — target search, line-of-sight rays, asking the navigation server for
a path — happens on a staggered `_think()` tick (~0.28 s, offset per bot at
`activate()`); per frame a bot does little more than steer along the path it has.
Repaths are additionally rate-limited in `_go_to`.

Priority: **storm > retreat if hurt > fight if provoked > loot > hunt**. Two
rules in there are load-bearing for pacing, and both were added because the
match kept ending in under a minute:

- a bot still on its foam bonker goes shopping rather than picking a fight;
- a bot below ~35 % health runs away instead of trading to the death.

Sight is `SIGHT_RANGE` (20 m) plus an 80° cone plus a raycast with
`collision_mask = 1`, so **only scenery blocks sight, never other squishies** —
ducking behind a mushroom works, hiding behind a friend does not.

### Making 100 bots affordable

- Bots `queue_free()` their `CameraPivot` at spawn — a hundred `SpringArm3D`s
  doing shape casts every frame is the most expensive thing a bot can own, and it
  never looks through its camera. **Guard any camera access behind `is_bot`**;
  those `@onready` refs are invalid for bots.
- `Squishy._apply_detail_range()` puts `visibility_range_end` on everything
  hanging off the body, so past ~38 m a squishy is one sphere and the engine does
  the culling with no per-frame script. The body mesh itself keeps no range — it
  *is* the far-away version. Props and weapons do the same.
- `Player._update_lod()` skips animation entirely for distant bots, on a stagger.

### Collision layers

- **Layer 1** — world/scenery. Blocks movement, shots, and the AI's
  line-of-sight raycast.
- **Layer 2** — players. `Player.tscn` is `collision_layer = 2, collision_mask = 1`.
  Knocked-out players leave layer 2 so ghosts don't body-block the living.

Scenery that should *not* block vision or navigation goes in as a plain
`MeshInstance3D` outside `NavigationRegion3D` — that is what mushroom caps, tree
canopies, the sea and the clouds already do.

### Procedural island (`Island.gd`)

`_ready()` order matters and is commented in place: ground → boundary → camps →
props → spawns → **navmesh bake** → decoration → storm → loot. Decoration is
added after the bake and outside `nav_region`, so it can never affect pathing.

Everything is seeded off `ISLAND_SEED`, so the island is the same every match —
learning where the good loot lives is most of the fun — while still being
generated rather than hand-placed. Tune with `ISLAND_RADIUS`, `PROP_COUNT`,
`CAMP_COUNT`, `SPAWN_COUNT`/`SPAWN_GAP`. Build and bake together cost ~450 ms.

Camps are block clusters that act as loot hotspots and the reason to run
somewhere specific. Half the scattered props also drop a loot spot behind them.

### Characters (`Squishy.gd`)

Six species (`BUNNY, CAT, BEAR, FROG, CHICK, PUPPY`), each with its own
proportions, ears, face and extras. `build()` is idempotent via `_built`.

Animation is procedural, driven from `Player._physics_process`: `_squash` is a
spring (`pop()` kicks it), width derives as `1/sqrt(stretch)` to preserve volume,
`_walk_phase` drives bounce/ears/feet/tail. `hold()`, `set_hat()`,
`spin_propeller()`, `swing()`, `recoil()`, `flash_hit()`, `set_ghost()` are the
hooks `Player.gd` calls.

There is no skeleton and no keyframes — a swing is the hold point being tweened
forward and back.

### UI (`Main.gd`)

Five mutually-exclusive `Control` panels — Menu, Shop, Lobby, HUD, Result —
toggled by `_show_only()`. All node references are `@onready` with full paths
into `Main.tscn`, so **renaming a UI node in the scene breaks `Main.gd`** —
update both together, and the smoke test's `_check_ui()` will tell you if you
forgot.

The shop is generated from `SaveData.PERKS`, `Player.PALETTE` and
`Squishy.SPECIES_NAMES` rather than laid out by hand, so adding a perk or a
colour makes a button appear on its own.

## Conventions

- **Tabs for indentation** (Godot standard), two blank lines between top-level
  functions.
- **Typed declarations** where practical. Note that `:=` inference *fails* on
  anything reached through an untyped reference (`parent.aim_origin()`,
  autoload calls) — write `var x: Vector3 = ...` there or it won't parse.
- **`##` doc comments** at the top of every script and above anything
  non-obvious. The comment style here explains *why*, usually naming the bug or
  the play experience that motivated the code ("less floaty, more toy-like";
  "without this every match opened with a hundred squishies sprinting into one
  brawl"). Match that voice — warm and concrete, not formal.
- **`_leading_underscore`** for private members and internal state.
- **Tunable numbers are `const`s at the top of the script**, never inline magic
  numbers. A new tunable belongs up there.
- Signals over polling for cross-system communication.
- Groups over hard node paths for cross-scene lookups.

## Gotchas

- **After deleting `.godot/`, run `godot --headless --import` before anything
  else.** The `class_name` registry lives in
  `.godot/global_script_class_cache.cfg`, and until it is rebuilt every script
  referencing `Player`, `Squishy` or `Weapons` fails to parse.
- **`agent_radius` must be a whole number of `cell_size` units** or Recast
  rounds it up and quietly fattens every bot. At `cell_size = 0.5` a radius of
  0.55 became 1.0 and bots refused to walk through any gap under two metres.
- **`godot --script` with a `SceneTree` script does not give you a real tree** —
  `parse_source_geometry_data` and anything else needing nodes in the tree will
  fail with "root node needs to be inside the SceneTree". Test scene-dependent
  things by running an actual scene.
- **Don't spawn players in rings.** Forty points on a circle of radius 42 sit six
  metres apart; the first version of this opened every match with three quarters
  of the cast knocked out inside thirty seconds. `_compute_spawns()` scatters
  with a minimum gap for that reason.
- **Hosting fails silently if the port is taken.** `host_game()` returns `false`
  (port `8910`); `Main._on_host_pressed()` must show that rather than opening an
  empty lobby.
- **Don't call `queue_free()` on a networked player from a client** — removal is
  server-driven via `_on_peer_disconnected`.
- **`MatchManager._process` runs on every peer** to interpolate the storm, but
  only the server applies damage or advances the phase. Adding logic there needs
  the `is_server()` guard.
- **Godot 4.7 APIs.** `NavigationServer3D.parse_source_geometry_data` /
  `bake_from_source_geometry_data`, `MultiplayerSpawner.spawn_function` and
  `visibility_range_end` are 4.x-only. Don't "fix" them into 3.x forms.
- **`.godot/` is gitignored** — the import cache regenerates. Never commit it.

## Git workflow

- Default branch: `main`. Work on the assigned feature branch, and push with
  `git push -u origin <branch>`.
- Commit messages in this repo are short, imperative, and describe the
  player-visible change.
- Keep `README.md` in step with behaviour changes — it's written for the family,
  in plain language, and doubles as the game's design doc.
