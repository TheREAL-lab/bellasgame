# Natasha's Idea

A 3D battle royale built in Godot 4, made together with my step-daughter Bella.

## The game

You drop onto a bright island with a hundred computer squishies. Everybody lands
with nothing but a foam bonker. Somewhere out there are better weapons, spinny
hats, and piles of coins — and a purple wall that keeps closing in.

Last squishy bouncing wins.

- **Land with nothing.** A foam bonker and good intentions.
- **Go shopping.** Weapons are scattered across the island and heaped in the
  camps: a lollipop hammer, a bubble blaster, a popcorn popper, a sprinkle
  rifle, a star zapper, and — if you're very lucky — the rainbow cannon.
- **Take what you knock loose.** Anyone you knock out drops what they were
  carrying. Walk over something better and you'll pick it up automatically; press
  `E` if you'd rather have the one you're standing on.
- **Find a spinny hat.** Hold jump and the propeller lifts you; let go and you
  drift down gently instead of dropping. Not quite flying, but close enough to
  get somewhere you shouldn't be able to reach.
- **Outrun the storm.** Every so often the wall closes to a new circle somewhere
  random on the island. The blue patch on the ground shows where it's heading.
  Get caught outside and it nibbles your health away — slowly at first, then not
  slowly at all.

Tagged... sorry, *knocked out* squishies pop into floating ghosts and drift about
watching the rest of it.

## Coins and the shop

You earn coins for how far you get, for every squishy you knock out, and for the
piles you find lying around the island. Winning pays best, but simply surviving
longer than most of the island pays too — hiding in a bush until second place is
a completely legitimate way to play.

Spend them in the shop between matches:

- **New squishies** — the bunny, kitty and bear are free; the froggy, chick and
  puppy cost coins.
- **New colours** — six of them, and no two players are ever the same squishy in
  the same colour.
- **Little advantages** — a bit more health, a better starting bonker, or a
  bigger propeller. Deliberately mild: you can't buy a win.

Coins are saved on your own machine, so your squishy and your wallet follow you
between matches.

## How to play

**Move** with `W A S D` · **Look** with the mouse · **Jump** with `Space` (hold
it with a spinny hat) · **Bonk/shoot** with the left mouse button · **Grab** with
`E` · `Esc` frees the mouse cursor.

1. Open the project in Godot 4 (built and tested on Godot 4.7) and press Play.
2. Type a name and click **Play / Host Game**, then **Drop in!**

**If the very first open says no main scene has been picked**, or the Output
panel complains that `Player` or `Squishy` isn't declared: that's a fresh clone
with no import cache yet. Godot keeps its list of script class names inside
`.godot/`, which isn't checked in, so on the first open the scripts can fail to
parse and the main scene can't load. Quit Godot and run this once in the project
folder, then open it again:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --import
```

It only ever happens once, on a machine that has never opened the project.

**About that hundred.** The menu has a **Computer squishies** button that cycles
25 / 50 / 100, and it starts at 50 on purpose — a hundred squishies is the real
game but it is a lot to draw at once. If the fans get loud or it starts to feel
sticky, click it down to 25. The game also watches its own frame rate and quietly
turns off shadows and drops detail if things get heavy, so it should never grind
to a halt. It cannot hurt the computer — the worst that happens is a warm laptop
and a noisy fan, and quitting fixes it instantly.

To play together on the same wifi, one person hosts and reads out the address in
the lobby; the other types it in and clicks **Join**. You both drop onto the same
island, and you're both fighting the same hundred bots — and each other.

## How the computer players think

They aren't on rails. A bot still holding its foam bonker would rather go and
find a real weapon than pick a fight it can't win. A bot that's badly hurt runs
away. Bold ones go looking for trouble, timid ones keep out of it, and all of
them run from the storm.

They only chase what they can actually see — there's a vision cone and a
line-of-sight check, so you really can break their line of sight by ducking
behind a mushroom. Hiding behind another squishy does not work.

## Project layout

| File | What it does |
| --- | --- |
| `scripts/SaveData.gd` | Coins, unlocks and perks — the only thing that touches disk |
| `scripts/NetworkManager.gd` | Hosting, joining, and spawning all 101 players |
| `scripts/MatchManager.gd` | Match state, who's alive, placement, and the storm |
| `scripts/Player.gd` | Movement, camera, combat, hovering, pickups — you *and* the bots |
| `scripts/BattleAI.gd` | Computer-player brain (loot, hunt, fight, retreat, flee) |
| `scripts/Weapons.gd` | Every weapon in the game, as one table |
| `scripts/Loot.gd` | Weapons, hats and coins lying on the ground |
| `scripts/Storm.gd` | Draws the closing wall and the safe patch |
| `scripts/Squishy.gd` | Builds each species out of primitives and does the squashing |
| `scripts/Island.gd` | Builds the island, the camps, the loot spots and the navigation |
| `scripts/Main.gd` | Menu, shop, lobby, HUD and the results screen |

The island, the characters and the weapons are all generated in code rather than
modelled, so colours, props and proportions can be tweaked by editing a number.
Want a new weapon? Add a row to the table at the top of `Weapons.gd` and it turns
up in the world on its own.

## Checking it still works

There's a headless smoke test that plays a whole match against the hundred bots
unattended — useful after making changes. It takes about six minutes:

```bash
godot --headless --path . -- autotest
```

It prints how many players spawned, **how many bots are actually walking**, how
many have found weapons and hats, the frame cost, whether anybody has fallen off
the island, and who eventually won.

The "bots moving" line exists because of a real bug: the navigation waypoints sat
half a metre above the characters' feet, which was further than the agents'
`path_desired_distance`, so they never registered arriving at a waypoint and
stood still forever. If that count ever reads 0, the same class of bug is back.

Everything here is generated from primitives in code — no downloaded art. That
keeps the repo tiny, means there's no asset pipeline to break, and lets every
colour and proportion be changed by editing a number.

## Ideas for next time

- Sound effects and music
- Vehicles, or something to ride
- More islands to choose from
- Squads, so you and a friend are on the same side against the bots
- A weapon that isn't a weapon — something silly that just moves people about
