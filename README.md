# bellasgame

A 3D hide-and-seek game built in Godot 4, made together with my step-daughter Bella.

## The game

Five squishy characters — Bella, me, and three computer players — share a bright
walled playground full of mushrooms, trees, bushes, rocks, candy canes, lamp
posts, a pond, balloons and a rainbow over the back wall.

Everybody is a **different** squishy: a bunny with tall ears and a puff tail, a
kitty with pointed ears and a curling tail, a round bear with a snout, a wide
froggy with eyes on top of its head, a little chick with a beak and a head tuft,
and a puppy with floppy ears. Nobody shares a shape or a colour.

- Every round, one player is picked at random to be **IT**.
- IT waits in the middle while everyone else gets 10 seconds to scatter and hide.
- Then IT has 90 seconds to find and tag everyone.
- Tagged players pop into a floating ghost and cheer on whoever's left.
- Wins are tallied across rounds, and the same player won't be IT twice in a row.

Little touches that make it fun: characters squash and stretch as they run and
jump, their ears flop, they blink, IT glows red, the screen edges blush red when
IT is sneaking up behind you, and a big countdown ticks down the last ten
seconds of hiding time.

## How to play

**Move** with `W A S D` · **Look** with the mouse · **Jump** with `Space` ·
`Esc` frees the mouse cursor.

1. Open the project in Godot 4 (built and tested on Godot 4.7) and press Play.
2. One person types a name and clicks **Play / Host Game**. The lobby shows an
   address like `192.168.1.42`.
3. The other person types that address and clicks **Join**.
4. The host clicks **Start the round!**

You can also play solo against the three computer players — just host and start.

## How the computer players think

They aren't on rails. As hiders they pick cover, and bolt for somewhere safer if
IT gets within five metres. As IT they sweep the playground, and only chase what
they can actually see — there's a vision cone and a line-of-sight check, so you
really can break their line of sight by ducking behind a mushroom. Each one gets
a randomised boldness and hop frequency so the three don't move as a block.

## Project layout

| File | What it does |
| --- | --- |
| `scripts/NetworkManager.gd` | Hosting, joining, and spawning players so identity replicates to every peer |
| `scripts/GameManager.gd` | Round state machine, role picking, tag detection, scores |
| `scripts/Player.gd` | Movement, camera, and role/tag reactions — shared by humans and bots |
| `scripts/AIController.gd` | Computer-player brain (hide, flee, search, chase) |
| `scripts/Squishy.gd` | Builds each species out of primitives and does all the squash-and-stretch |
| `scripts/Arena.gd` | Builds the playground, spawn points, decorations, and AI navigation |
| `scripts/Main.gd` | Menu, lobby, HUD, and scoreboard |

The playground and the characters are generated in code rather than modelled, so
colours, props and proportions can be tweaked by editing a table at the top of
`Arena.gd` or the constants in `Squishy.gd`.

## Checking it still works

There's a headless smoke test that hosts a game against the bots and plays a
round unattended — useful after making changes:

```bash
/Users/natashavanegas/Downloads/Godot.app/Contents/MacOS/Godot --headless --path . -- autotest
```

It prints the players spawned, who got picked as IT, **how many bots are
actually walking**, and how many hiders were caught. Setting `SHOT_DIR=/some/folder`
and dropping `--headless` also saves screenshots of the hiding and seeking phases.

The "bots moving" line exists because of a real bug: the navigation waypoints
sat half a metre above the characters' feet, which was further than the agents'
`path_desired_distance`, so they never registered arriving at a waypoint and
stood still forever. If that count ever reads 0, the same class of bug is back.

Everything here is generated from primitives in code — no downloaded art. That
keeps the repo tiny, means there's no asset pipeline to break, and lets every
colour and proportion be changed by editing a number.

## Ideas for next time

- Sound effects and music
- Power-ups (a short speed boost, or a peek at where IT is)
- More playgrounds to choose from
- Letting players pick their own colour in the lobby
