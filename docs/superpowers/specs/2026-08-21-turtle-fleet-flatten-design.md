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
| `coordinator.lua` | stationary computer, wired/wireless modem, placed against the resupply chest | Owns area bounds, cell queue, occupancy state, turtle registry |
| `flatten.lua` | each turtle | Worker state machine: claim → move → mine → report; also `mark1`/`mark2` |
| `startup.lua` | each turtle | Boots straight into fleet-worker mode with zero arguments |
| `reset.lua` | any computer/turtle | Wipes the writable filesystem clean (see below) |
| `update.lua` | any computer/turtle | Unchanged mechanism; `FILES` table extended to include `reset` |

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
of those states. A turtle blocked persistently on entering its cell (e.g. by
world terrain, not another turtle) reverifies its GPS position, skips the
cell, and reports the skip to the coordinator rather than looping. A turtle
never digs another turtle or the resupply chest — it waits.

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

The resupply chest (auto-detected by the coordinator) holds fuel and any
fill material. Turtles refuel proactively — checking tank level and
topping up from carried or chested fuel before it becomes a blocker, not
reactively after stalling. Gaps below the target floor level are filled
using mined blocks (dirt-priority), same behavior as before; this logic
lives entirely inside a single turtle's mining routine and isn't part of
the coordination protocol.

## reset.lua

A standalone utility, not part of the fleet protocol. Run on any turtle or
computer to wipe it back to a blank slate before re-provisioning:

- Iterates the writable root filesystem (`fs.list("")`), deleting every
  entry — including itself — except the `rom` mount, which CC:Tweaked
  already protects as read-only and which `reset.lua` explicitly skips by
  name as a second safeguard.
- No confirmation prompt, no rednet interaction — it's a deliberate, manual
  wipe tool, not something the coordinator triggers remotely.

## Testing / rollout

1. Verify single-turtle correctness live first: `mark1`/`mark2`/`start`
   with exactly one turtle, confirm the box is flattened correctly.
2. Add a second turtle and verify concurrent claiming, occupancy-aware
   adjacency, and heartbeat-based `list`/`locate` before considering the
   system done.
3. Verify `reset.lua` leaves `rom` intact and the filesystem otherwise
   empty.

## Out of scope

- Ore-only branch mining, quarry-to-bedrock — this rewrite is a region
  flatten only (per the job-type decision made this session).
- Any UI beyond the terminal commands listed above.
