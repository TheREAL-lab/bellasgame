# bellasgame

A 3D hide-and-seek game built in Godot 4, made together with my step-daughter Bella.

## The idea

- 5 players total: Bella, me, and 3 AI-controlled squishbots.
- Multiplayer over LAN, so Bella and I can play together on our own devices.
- Each round, one random player (human or AI) is picked as the Hunter — everyone else hides.
- Hiders scatter for 8 seconds while the Hunter waits, then the Hunter has 90 seconds to tag everyone.
- Cute, squishy characters (they squash and stretch when they walk, jump, and get tagged) in bright candy colors.

## Project structure

- `project.godot` — engine config, input map (WASD + mouse + Space to jump), autoloads.
- `scripts/NetworkManager.gd` — hosting/joining over ENet, spawns human + AI players.
- `scripts/GameManager.gd` — server-authoritative round state machine (lobby → hiding → seeking → round over), role assignment, and tag detection.
- `scripts/Player.gd` — movement, camera, squish animations; shared by human and AI players.
- `scripts/AIController.gd` — bot brain: hiders path to a hiding spot and sit tight, the Hunter patrols and chases the nearest hider.
- `scripts/Arena.gd` — bakes AI navigation at runtime and lists hiding-spot positions.
- `scripts/Main.gd` — menu, lobby, HUD, and round-over screens.
- `scenes/Player.tscn`, `scenes/Arena.tscn`, `scenes/Main.tscn` — the corresponding scenes.

## How to run it

1. Open this folder in the Godot 4 editor (built and tested against Godot 4.7).
2. Press Play. One person clicks **Host Game**; the app shows a LAN IP to share.
3. The other person enters that IP and clicks **Join Game**.
4. Once both are in the lobby, the host clicks **Start Round!**.
5. Move with WASD, look around with the mouse, jump with Space.

You can also playtest solo against the 3 AI bots without a second player.

## Status

Core loop (hosting/joining, roles, hiding/seeking timers, tagging, AI bots, squishy look) is implemented and loads cleanly in Godot's headless mode. Not yet play-tested end-to-end in the editor — next step is opening it in Godot and trying a real round.
