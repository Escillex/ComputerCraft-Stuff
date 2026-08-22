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
so a turtle looks: it stands two blocks out along each horizontal axis in
turn and looks back at the coordinator. Doing this on first need rather
than at startup is what stops a fleet booted together from all walking to
the same block at once; the coordinator caches the answer and hands it to
everyone else with their token.

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

## Not built yet: filling under a ceiling, by leaving a spine

Filling needs open sky over the area and refuses without it. Sealing a
column works with no headroom - back out sideways and place behind - but
travel does not: with a ceiling on the area a turtle has to cross it at its
own top, and crossing a finished column takes its top block out on the way
past. It left twelve holes, all in the top layer, while reporting every
column done.

Routing round finished columns would need the coordinator to send turtles a
map of what is done, and then real pathfinding over it. There is a simpler
way that makes the route true by construction instead of finding it:

**Leave one row open as a spine, and fill each row from its far end
inward.** Any column is then reached by going along the spine to its row,
then along the part of that row not yet filled - which is always the half
nearest the spine, because rows fill outside-in. Nothing ever needs to
cross a finished column. When every other row is solid, one turtle fills
the spine itself, working from the far end back and retreating along the
part still open, which is the ordinary sealing problem in one dimension.

What it needs:

- the coordinator ordering columns by row, far-to-near within a row, and
  holding the spine back until everything else is done
- the spine chosen as the row the store approaches from, so the last turtle
  finishes next to it
- turtles routing spine-then-row rather than the current greedy
  along-x-then-along-z, which is what walks into finished columns
- the last row handled by one turtle, since two would strand each other

Worth doing before this is trusted on an area with anything built over it.

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

**Before any of this can be designed, run `flatten look` at a lava source
and at a flow a few blocks away.** It prints the block name, the whole
state table and the tags. Two things decide the design and neither can be
settled from outside the game:

- whether CC reports a fluid from `turtle.inspect` at all (`detect` is
  known to ignore liquids)
- whether `state.level` is exposed, which is what separates a source
  (level 0) from a flow (1-7) in modern Minecraft

The one bug report on the subject is from 1.12.2, when flowing lava was a
separate block entirely, so it says nothing about 1.21.

If levels are exposed, a turtle can plug only sources and let the rest
drain. If they are not, plugging everything still gets there in the end,
just with more passes.

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
