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

## Out of scope

- Ore-only branch mining, quarry-to-bedrock — this rewrite is a region
  flatten only (per the job-type decision made this session).
- Any UI beyond the terminal commands listed above.
