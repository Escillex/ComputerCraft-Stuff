# Turtle Fleet Flatten — Design

## Purpose

A fresh rewrite of the ComCraft turtle system: one or more CC:Tweaked mining
turtles flatten a rectangular region together. The previous implementation
(deleted this session) explored the same general approach — GPS absolute
coordinates, rednet fleet coordination, chest-based resupply — but never
survived a full clean run; its bugs (GPS deadlocks, opposite-cardinal digging,
rednet message races, silent turtle drift) were patched reactively one at a
time as they surfaced live. This rewrite keeps the approach but is built to
close off those bug *classes* structurally, and to minimize what a human has
to type or configure.

## Components

| File | Runs on | Role |
|---|---|---|
| `coordinator.lua` | stationary computer, wired/wireless modem, placed against the resupply chest | Owns area bounds, cell queue, occupancy state, turtle registry, depot token |
| `flatten.lua` | each turtle | Worker state machine: claim → move → mine → report; also `mark1`/`mark2` |
| `common.lua` | both | Protocol constants and shared helpers, so the two sides cannot drift apart |
| `startup.lua` | each turtle | Boots straight into fleet-worker mode with zero arguments |
| `reset.lua` | any computer/turtle | Wipes the writable filesystem clean (see below) |
| `update.lua` | any computer/turtle | Fetches each target under the exact filename it must have, plus its dependencies |

## Setup / operator flow

The whole point of this rewrite is that the human-facing surface is almost
nothing:

1. Place the coordinator computer against the resupply chest. No side/slot
   argument — `peripheral.find("inventory")` auto-detects it.
2. Walk any turtle to one corner of the area, run `flatten mark1` (no args).
   Walk to the opposite corner, run `flatten mark2`. GPS captures each
   position; no coordinates are typed.
3. Turtles join the fleet by running `startup` (or booting, since
   `startup.lua` runs automatically) — zero arguments. They register with
   the coordinator over rednet and start requesting cells. Turtles can join
   before or after the job starts; fleet size is never declared upfront.
4. `coordinator start` begins the job once at least one turtle has joined
   and both corners are marked.

Operator commands on the coordinator: `mark1`/`mark2` are actually run on a
turtle, not the coordinator — the coordinator only needs `start`, `stop`,
`list`, `locate <id>`.

## Coordination model

**Cell** = one X,Z column spanning the full Y range of the marked box (top
to bottom). This is the unit of work claimed, mined, and reported.

**Central, occupancy-aware coordinator.** The coordinator is the single
source of truth for:
- the cell queue (free / claimed / done)
- each turtle's current position and state (from heartbeats — see below)

When a turtle requests a cell, the coordinator only grants one that is not
adjacent (4-directionally) to another turtle's currently-claimed cell. This
makes turtle-to-turtle collisions structurally rare instead of something
each worker has to detect and react to after the fact.

**Worker state machine** (`flatten.lua`): `idle → claim → move → mine →
report → idle`, with `refuel`, `resupply`, and `blocked` reachable from any
of those states. A turtle blocked persistently on entering its cell
reverifies its GPS position, gives the cell back, and reports why rather
than looping. A turtle never digs another turtle, a computer, or a chest.

Two distinctions found during testing turned out to matter more than
anything else, because without them the fleet deadlocks rather than
degrades:

- **Waiting vs routing around.** Another turtle will move, so a turtle
  waits a few seconds for one. A chest or computer never will, so the
  turtle gives up on that step immediately and routes over it. Waiting on
  scenery was what jammed the whole fleet against the chest.
- **Traffic vs obstacles.** A cell handed back because another turtle was
  in the way is put straight back in the pool. Only a cell blocked by
  something real counts against its three strikes. Without the split,
  ordinary congestion permanently wrote off most of the area.

## Locating turtles

Every worker sends a position heartbeat to the coordinator on a fixed
interval, independent of claim/report traffic — this is what let turtles go
silently untracked between actions in the old system. The coordinator keeps
this in the same registry used for occupancy checks; there's no separate
tracking subsystem.

- `coordinator list` — id, last known GPS position, last-seen time, current
  state (idle/mining/blocked/missing), for every turtle that has ever
  joined.
- `coordinator locate <id>` — same, filtered to one turtle.

If a turtle misses several heartbeats in a row, the coordinator marks it
`missing`, frees any cell it had claimed, and keeps its last known position
in the registry so `locate` still answers the question for a dead or
disconnected turtle instead of dropping it.

## Fuel & resupply

The resupply chest holds fuel and receives everything mined. Turtles refuel
proactively — checking the tank against the cost of the trip home before it
becomes a blocker, not reactively after stalling. Gaps below the floor are
patched with mined blocks (dirt first); that logic lives inside a single
turtle's mining routine and is not part of the coordination protocol.

**One turtle at the chest at a time.** The dock is a single block with a
single approach, so the coordinator hands out a depot token; a turtle only
travels there once it holds one, and releases it after climbing clear of
the dock. A turtle that goes quiet loses the token immediately.

**Finding the chest is lazy, and happens under the same token.** The
coordinator knows where it is standing but not which side its chest is on,
so a turtle looks. Doing this on first need rather than at startup is what
stops a fleet booted together from all walking to the same block at once;
the coordinator caches the answer and hands it to everyone else with their
token.

**The search is bounded to a 5x5x5 cube round the coordinator.** Squares
are tried nearest first - the block on top of the coordinator, then the
ones against its sides and underneath, then the shell beyond those - and
the first storage-shaped block found is the one used. Outside that cube
there is no searching at all: the turtle says there is no store and stops.

The bound is the requirement, not an optimisation. An unbounded search is
how a turtle walks over the horizon and is never found again, and it is
what the earlier version did. The cube is also the right shape for the
question, because the coordinator only knows a store is there by having one
attached to it - so the store is a neighbour by definition, and the cube is
generosity for multiblocks rather than a place a store might really be.

Measured, on the same job:

| store | old ring walk | 5x5x5 cube |
|---|---|---|
| chest against the coordinator | 179 moves | 133 |
| Create item vault, 3x3x3 | 179 moves | 101 |
| nothing there at all | never stopped | 123 of 124 squares, then stops |

Two things this needs that were not obvious:

- **Get to the coordinator first, then walk the cube.** There may be a wall
  between the turtle and the coordinator, and nothing outside the area may
  be broken, so the only way past is over the top - a climb worth making
  once. Walking the cube afterwards is local, and capped just above the cube
  so that a square which cannot be entered (the inside of a wall, a block of
  the store itself) is answered by giving up on it rather than by a
  thirty-block detour over the top. Most of the hundred and twenty-four are
  solid.
- **Stop while there is still fuel to get back.** The walk only ever runs to
  the end when there is nothing to find, and a turtle with nothing to find
  has nowhere to refuel either. Spending the tank proving it means that
  putting a chest down no longer fixes it.

## reset.lua

A standalone utility, not part of the fleet protocol. Run on any turtle or
computer to wipe it back to a blank slate before re-provisioning:

- Iterates the writable root filesystem (`fs.list("")`), deleting every
  entry — including itself — except the `rom` mount, which CC:Tweaked
  already protects as read-only and which `reset.lua` explicitly skips by
  name as a second safeguard.
- No confirmation prompt, no rednet interaction — it's a deliberate, manual
  wipe tool, not something the coordinator triggers remotely.

## Testing

The previous implementation was debugged a bug at a time against a live
world and never had a clean run, so this one is checked against a stand-in
for the CC:Tweaked API (`test/ccsim.lua`) — a real voxel world, real
turtles that consume fuel and occupy blocks, real rednet, and CC's event
model — before it goes anywhere near Minecraft. `sh test/run.sh` covers:

- a three-turtle job clearing a 9x6x9 area, checking every block is gone,
  the floor hole is patched, mined blocks reach the chest, nothing
  protected was dug, and every worker stands down at the end;
- one turtle doing the same job alone;
- a turtle vanishing mid-job: the coordinator must notice, free its
  column, still report its last known position, and the survivors must
  finish rather than hang;
- `reset.lua` leaving `rom` alone and nothing else;
- `update.lua` saving each file under the exact name the others load it
  by, pulling dependencies, and not destroying a working copy when a
  download fails.

Live rollout: single turtle first, then add a second and watch `list`.

## Known problems, not yet fixed

Found during the first real run on a 45 x 19 x 20 area. None of these are
worth interrupting a job for, but all three should be dealt with before the
next round of work on mining, and the first one before fill mode is built —
fill makes every one of them worse, because it hauls material in as well as
spoil out.

**Turtles refuel to almost nothing.** `useDepot` asks for
`tripCost(depot.dock) + FUEL_MARGIN * 4`, but the turtle is standing on the
dock when it runs, so the trip cost is zero and the target collapses to 600
— three per cent of a normal turtle's twenty thousand. With a nineteen
block column costing about forty moves that is seven columns a tank. It
should fill to about three quarters of `turtle.getFuelLevel`'s limit.

**The reserve for getting home is optimistic.** `needsDepot` budgets the
straight-line distance to the dock plus a flat margin, and no real route is
straight: they climb to the travel height, go round what they cannot break
and come back down. It should budget roughly double the straight line, plus
the cost of the column it is about to start, and a turtle handed a column
too far away to survive should hand it straight back rather than strand
itself part way down.

**One dock serialises the fleet.** Only one turtle uses the store at a
time, which is right for a single chest and wrong for a vault three blocks
across with faces going spare. The coordinator could hand out several
docking spots and let turtles use them in parallel. This is the ceiling on
how many turtles are worth running.

**Granting a column scans every column.** Fine at nine hundred, slow in the
tens of thousands.

## Version enforcement belongs on the coordinator

Found in the world, not the simulator. A turtle still on an older version
joined a current coordinator, was picked as the one to go and find the
store, and walked a hundred and fifty blocks east before going quiet. The
coordinator knew the versions differed - it was printing the mismatch under
`list` - and handed out the work anyway.

The version check existed, but only in `flatten.lua`: the turtle checked
itself. That is the wrong side of the wire. An old turtle checks with old
code, and the reason a version mismatch is dangerous is precisely that its
code is not the code you think it is - so a version that happens not to
enforce the check goes off and does whatever it used to do.

So the coordinator decides. A turtle whose version does not match is
refused every request, and never gets granted the depot token. Two things
this needs:

- **Every message carries the version, not just the hello.** Marking a
  corner never says hello first, so a rule of "no version means the wrong
  version" refuses the marker turtle unless everything is stamped.
- **`TROUBLE` is still accepted, and the registry entry is kept.** Where a
  stale turtle is and what it is complaining about are exactly what `list`
  and `locate` exist to answer, and a turtle you cannot find is what
  started all of this.

## Why filling depended on docking on the store's roof

Recorded earlier as "works from the roof, leaves 68 blocks unfilled from
beside it - not understood". It is understood now, and it was two things,
neither of which had anything to do with the roof.

**A turtle told to stand clear parked on the docking square.** `standDown`
took "outside the area" to mean "out of the way" and left the turtle where
it stood. The docking square is always outside the area, so a turtle that
had just left the store and was told to stand clear - which filling does
constantly, since only one turtle may be on the road - sat on the one
square the whole fleet needs. In a three-turtle job that was 110 failed
approaches and no resupply for anybody after the first trip.

**The road was joined by coming down before setting off.** `goToViaSpine`
dropped to road height as its first act. From a dock at ground level the
store and the coordinator stand between that square and the area, and
neither may be dug, so the turtle was walled in with its back to the store
and every column it was handed came back "blocked by minecraft:chest". A
single turtle with no traffic at all wrote off the entire area that way.

The roof dock hid both because `goTo` climbs to travel height and never
drops to it. A turtle leaving a roof dock is already above everything and
flies over the store rather than walking into it. Nothing about filling
wanted the roof; it wanted the altitude.

The first was fixed. The second was not: four attempts each traded the
roofed-fill case against the open-sky one, because the descent in the spine
route is doing two jobs at once - getting under a ceiling, and getting past
the store - and they want to happen at different points on the journey.
What made it moot was bounding the store search: the cube walk picks its
dock differently, and the layout that provoked it no longer arises in
anything that can be built. It is still there in the route, and it will
come back if a docking spot at road height with the store between it and
the area is ever chosen again.

## Filling under a ceiling: the spine

Filling has to travel over ground nobody has filled, because a finished
column is solid and crossing one takes its top block out on the way past.
With sky over the area that is easy - go over the top. With something built
on it there is nowhere above to go, and the first attempt at this left
twelve holes in the top layer while reporting every column done.

The answer is to make the route true by construction rather than find it.
**One row is left open as a road, and every other row is filled from its far
end inwards.** Any column is then reached by going out to the road, along it
to that column's row, and out along the open half of that row - which is
open because rows fill outside-in. Nothing ever crosses a finished column.
The road itself is filled last, furthest end first, by a single turtle.

The road is the edge the store lies beyond, so that the last column filled
is the one next to it.

Three things this needs that were not obvious:

- **The road is filled as one long retreat, not one column at a time.**
  Fill a square, step to the next one along, seal the one just left from
  there. A turtle that goes away to resupply comes back in at the *mouth* -
  the square nearest the store, which is the last of all to be filled and so
  open until the end - and walks up the road from there. Everything between
  the mouth and its next square is nearer the store, so it is still open.
  The only clear ground the road ever needs is the single step outside its
  own mouth, which is the way to the store anyway. An earlier version came
  at the road from a lane running alongside it, which needed that whole
  strip clear and stepped back onto filled squares to get there.
- **The edge is the one the store is beyond, not the nearest-numbered
  one.** A store off the east side can sit at a z inside the area's own
  range; measuring each axis on its own then picks a north or south edge and
  sends everybody the wrong way home.
- **On the road, home means the mouth, not the store.** A road can run past
  its mouth and out the other side. A turtle down that end pointed straight
  at the store walks into whatever is beside the road instead of back along
  it, and leaves the square it was sealing open.
- **Which road to use is decided once, not guessed at.** A turtle that sets
  off over the top and meets a ceiling halfway is left standing on the roof
  of the job with no way down. So the road is used until a turtle has stood
  in a column and looked up, and from then on it knows.

Only one turtle works the road at a time: two would wall each other in.

## Not built yet: fluids, and a mode for draining them

Nothing deals with lava or water. A turtle walks through both without harm
and without noticing, so a column that opens into either is dug out and
then quietly refills, and the finished area is a lake. Water is the more
likely of the two; lava is the one that costs you a turtle's cargo if the
assumption about turtles surviving it is ever wrong.

A fluid cannot be dug, so the way to remove one is to place a block into it
and break the block, leaving air. Neighbouring fluid flows straight back,
which is why this has to be done repeatedly rather than once - and why
**sources come first**. Plug a source and the flows it fed drain on their
own; plug a flow and it refills from a source nobody has touched.

**Measured in the world, on 1.21.1:**

    front: minecraft:lava   state level = 0     <- a source
    front: minecraft:lava   state level = 2     <- a flow, one block away
    detect front=false                          <- for both

So `turtle.inspect` does report fluids, and the level tells a source from a
flow. `detect` does not see them at all, which is exactly why turtles swim
through lava at present without noticing it is there. Lava also carries
`minecraft:replaceable`, which is what lets a block be laid into it.

That settles the design: plug only the sources and let the flows drain
themselves.

**Drain mode** would be a third setting beside clear and fill: sweep the
area for fluid, plug what it finds, sweep again, and stop when a whole pass
turns up none. It terminates because every source removed stays removed.

## Out of scope

- Ore-only branch mining, quarry-to-bedrock — this rewrite is a region
  flatten only (per the job-type decision made this session).
- Any UI beyond the terminal commands listed above.

## Designed but not built: fill mode

Discussed and agreed, waiting on the fuel work above.

A second mode on the same fleet, filling the marked area solid instead of
clearing it. `mode clear` / `mode fill` and `material <block id>` on the
coordinator; both persist and ride along with each cell grant. Travel moves
one block above the box, since a finished column is solid. A turtle digs
its column from the top down, then climbs back out placing a block beneath
itself each step, ending one above the box. Material it digs is reused when
it matches, so replacing stone with stone costs almost nothing from the
store; depot runs keep material and dump only spoil.

Existing blocks are replaced rather than worked around: the turtle has to
pass down through the column regardless, so there is nothing to be saved by
leaving them.
