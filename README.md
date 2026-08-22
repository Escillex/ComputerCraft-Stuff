# ComCraft

Mining turtles that clear out a rectangular area together, for
CC:Tweaked. One computer hands out the work; any number of turtles do it.

There are no coordinates to type. You walk a turtle to two opposite
corners, and everything else is worked out from GPS.

## What you need

- A working **GPS satellite cluster** covering the dig site. Nothing here
  works without it.
- A **computer** with a wireless modem for the coordinator.
- A **container** placed against that computer, with some coal in it. Any
  block that accepts items works - a chest, a barrel, or a modded store
  such as a vault. The coordinator prints what it found on startup.
- One or more **mining turtles** with wireless modems, and a little coal
  to get started.

## Setting up a computer or turtle

Bootstrap `update` once, then let it fetch the rest:

```
wget https://raw.githubusercontent.com/Escillex/ComputerCraft-Stuff/main/update.lua update
update all
```

## Running a job

1. Put the coordinator computer down next to the container and run
   `coordinator`. It finds the container by itself and prints what it is.
2. Walk a turtle to one corner of the volume you want gone and run
   `flatten mark1`. Walk it to the **opposite corner, including height** -
   top corner at one end, bottom corner at the other - and run
   `flatten mark2`. The coordinator prints the size it worked out, so you
   can see straight away if you have marked a box one block tall.
3. Put your turtles down anywhere nearby. Each one just runs `flatten`
   (or boots into it, if `startup.lua` is installed). They can join before
   or after the job starts, and you can add more at any time.
4. On the coordinator, type `start`.

The first thing the fleet does is find the store. No column is handed out
until somebody has been and found it, so turtles always know where they are
heading before they start filling up. **One** turtle is sent to look and the
coordinator names which; the rest wait. If it sits there still looking, the
store is not somewhere a turtle can reach.

## What it will and will not break

**The marked area is the only thing turtles will ever break.** Not a block
above it, not a block beside it, not a block under it. On the way to the
site they go **over** your buildings and terrain, never through them, and
they will climb a long way to find a route rather than make one.

A turtle that cannot reach somewhere without breaking something outside the
area does not go. It reports the column as blocked and moves on, so leave
your turtles and your store somewhere they can actually be reached from.

Nothing is laid outside it either, unless you ask. `floor on` when
**clearing** will cap a column that bottoms out over a cave, laying a block
one below the area so you get a floor rather than a hole - it only ever
fills thin air and never replaces anything, and it is what the stack of
dirt turtles hold back is for. It is **off by default**, because that block
goes outside what you marked.

**Filling never does this**: it fills the area down to its own bottom and
leaves whatever is underneath as it found it.

If a turtle cannot find a way round, it says so and carries on mining
rather than tunnelling.

## Checking what version is installed

Every program prints its version on startup, and `update all` prints the
version it just put on disk along with each stale file it deleted. The
coordinator refuses to talk to a turtle running a different version, so a
computer still quietly running an old copy shows up immediately:

```
flatten 2026-08-22ze (turtle 7)
```

If a turtle reports a different version from the coordinator, run
`update all` on it again.

`update` looks up the current commit and fetches every file by its hash.
GitHub serves raw files through a cache that hands back a copy several
minutes old after a push - and it takes no notice of query strings, so the
usual timestamp trick does nothing at all. A hash only ever means one
thing, so a file asked for by hash is the file that was pushed. It prints
which commit it is fetching.

## Updating in the middle of a job

Progress is kept, so a job can be stopped, everything updated, and the same
job carried on:

1. `stop` on the coordinator. Turtles finish the column they are on and
   then wait.
2. On each turtle, hold **Ctrl+T** to stop it. If `startup.lua` is
   installed it will try to start again after ten seconds, so hold Ctrl+T
   once more while it is waiting. Then `update all`. (Version mismatch is
   one of the things it will not keep retrying at ten seconds - see below.)
3. On the coordinator, `exit`, then `update all`, then `coordinator`.
4. `start`.

It picks up where it left off - the columns already cleared are remembered,
and the one that was being dug when you stopped goes back in the pool. The
area and the store's position are remembered too, so there is no need to
mark the corners again.

Every computer has to be on the same version before the job will run, which
is what the version line on startup is for.

### A turtle that will not start

`startup.lua` restarts a turtle that falls over, but most of the reasons a
turtle will not start at all are ones only you can fix: no coal in it, no
area marked yet, no coordinator running, a version that does not match. So
it says the reason once and then waits longer each time the same thing is
still wrong - ten seconds, then twenty, up to five minutes - instead of
repeating itself every ten seconds until the reason has scrolled off the
screen:

```
could not find the coordinator - is coordinator.lua running?
trying again in 10s - Ctrl+T to stop
trying again in 20s - Ctrl+T to stop
```

Fix the cause and it picks itself up within five minutes at worst, or hold
Ctrl+T and run `flatten` yourself to get it going at once. If something
*different* goes wrong it says so and goes straight back to trying quickly.

## Filling an area instead of clearing it

The same fleet can fill the marked area solid instead of emptying it:

```
> mode fill
> material minecraft:cobblestone
> start
```

`mode clear` puts it back. Turtles pick the change up on their next column,
so there is nothing to restart. Keep the store stocked with the material -
turtles fetch it on the same trips they already make, and anything they dig
out that happens to be the same block goes straight back in, so filling
stone with stone costs almost nothing.

**More than one block can be named.** The first is what gets laid into
empty space; the rest count as good enough where they already are, and go
back exactly as they were if they come out:

```
> material minecraft:dirt minecraft:grass_block
```

That fills a plot with dirt and leaves the grass on top of it alone.

Filling replaces what is there rather than working round it, so it deals
with water and lava for nothing: a block laid into a fluid displaces it.

A finished column is solid, so turtles have to travel over ground nobody
has filled yet. Where there is sky over the area they go over the top of
their own work. Where something is built on it, one row is kept open as a
road and every other row is filled from its far end inwards - so the way to
any column is along the road and out along the open half of its own row.
The road goes last, walked in by a single turtle backing towards the store.

Nothing to set up: `status` shows which row is being kept open.

The store does have to be **outside** the area. Filling works inwards
towards it, so a store standing in the middle would be filled in along with
everything else. `start` refuses and says so.

## Coordinator commands

| | |
|---|---|
| `start` | begin handing out work |
| `stop` | stop handing out work |
| `list` | every turtle: state, position, when it was last heard from |
| `locate <id>` | where one turtle is (**even if it has gone quiet**) and the last problem it reported |
| `status` | area, progress, and where the chest is |
| `floor <on\|off>` | cap holes under a cleared area (off by default) |
| `retry` | put written-off columns back in the pool and have another go |
| `clear` | forget the area so you can mark a new one |
| `exit` | quit |

## Columns it could not finish

A column that defeats a turtle three times over - bedrock, something it
refuses to break, a spot it cannot reach - gets written off, and `status`
counts them. The job still finishes; it just finishes with holes.

Once whatever stopped them has gone, `retry` puts every written-off column
back in the pool and `start` sends the fleet round again. Everything
already dug stays dug.

## Draining an area

`mode drain` takes the lava and water out and leaves everything else where
it is:

```
> mode drain
> start
```

A draining turtle **breaks nothing at all** - not to reach a column, not on
its way to the store. So it can only get at fluid it can already swim to,
which is the fluid worth reaching: a pool, a flooded cave, a lava lake. It
goes down each column as far as open space allows, plugs any source it
finds, takes the plug straight back out, and moves on.

It sweeps the area again and again until a whole sweep turns nothing up,
since draining a source lets what it was feeding run away and that uncovers
more:

```
pass 1 plugged 16 - going round again
```

Keep dirt in the store: every source costs a block to plug, even though the
block comes straight back out.

## Lava and water

A turtle cannot see a fluid - `detect` returns false for lava and water -
so without help it swims through a column of lava, digs nothing, and leaves
the finished area full of it.

They are not dug but displaced: a block laid into one replaces it, and
breaking that block leaves the space properly empty. **Only sources get
plugged.** Pull a source and the flows it fed drain themselves; plug a flow
on its own and it refills from a source nobody has touched. A turtle tells
a source from a flow by looking at it.

Plugging costs a block per source, taken from the same stack of dirt used
to cap holes in the floor - so keep some in the store if the area is wet.
Lava that flows in from **outside** the marked area cannot be helped: those
sources are not part of the job, and nothing outside it gets touched.

## Losing a turtle

Turtles report their position every few seconds. If one stops reporting -
it fell in lava, the chunk unloaded, you built a wall round it - the
coordinator marks it `missing`, puts its column back in the pool so the
rest of the fleet finishes the job, and **keeps its last known position**.
`locate <id>` will still tell you where to go looking.

## How the work is split

The area is divided into columns, one block square, running the full
height of the marked box. Turtles ask for one column at a time and the
coordinator never hands out a column next to one another turtle is
already working, so they keep out of each other's way instead of having
to untangle themselves afterwards.

A turtle will never dig another turtle, a computer, or a chest. If one is
in the way it waits, and if it is still there a moment later the turtle
reports back and gets sent somewhere more useful.

Anything **alive** in the way - a colonist on an errand, somebody's cow,
you - is waited on for a good ten seconds before the turtle so much as
touches it, and only something that has not moved at all in that time gets
hit. A few seconds of digging is not worth killing a citizen over.

Only one turtle uses the chest at a time, and it asks before it sets off
rather than on arrival - so only the one with its turn is ever walking
there or standing at it. The rest wait where they are, shown as `queuing
for the depot`. Mined blocks go in it; fuel comes out of it.

Put your turtles down **beside the store** when you start them. The first
thing the fleet does is find it, and a turtle standing near it looks all
round itself, then from each square a step away, then a block higher, up to
five levels - so a store beside it, under it, above it or one step off is
found on the spot. That is about a tenth of the walking of one that has to
go and search round the coordinator, and it says so when it has to:

```
nothing storage-shaped within reach - going to look round the
coordinator. put turtles beside the store to save them the walk.
```

Turtles find the container by walking round the coordinator and looking at
what is next to it. They know what to look for because the coordinator
tells them the block id of whatever is actually attached, so modded storage
works without this having heard of it - and never gets broken, wherever it
is standing.

They settle on **top** of the container and drop items down into it, which
is what makes a multiblock store work: a Create item vault is three blocks
tall and three across, so two blocks out from the coordinator is still
inside the structure and there is nowhere to stand beside it. Any block of
it takes the items, so the roof will do. **Leave the sky above your store
clear** - that is the way in. A single chest under a low roof is still
approached from the side instead.

Every block of such a store is protected, not just the one touching the
computer: breaking any one of them takes the whole structure apart. If a
docking spot ever stops working - the store was rebuilt, or moved - the
turtle throws the old one away and goes looking again rather than reporting
the same failure forever.

If the coordinator says

```
!! nothing next to me accepts items
```

then the block you have put there does not expose an inventory to
CC:Tweaked at all, and no container it cannot see can be used.

Towards the end of a job the last few columns are too close together to
share out, so most of the fleet has nothing to do. Rather than stand about
on the site getting in the way, an idle turtle waits above the area, each
one at its own height.

**Bring as many turtles as you like.** When there is no room for one it is
told so and clears off out of the area entirely, waiting on the side the
store is on and asking again now and then:

```
no room for me on this job - standing clear
```

They come back as the job opens up. Nothing needs sizing to the area, and
a turtle standing down is not one to go and rescue - `list` shows it as
`stood down`.

## When something goes wrong

Anything a turtle needs you for - the store is full, it has run out of
coal, it cannot find a way to the store, it is walled in and cannot even
work out which way it is facing - is printed **on the coordinator**, with
the turtle's id and where it is standing. Nobody is watching the screen of
a turtle at the bottom of a hole, and a turtle that cannot start is the one
least likely to be looked at.

The same note shows up against that turtle in `list`, and in full under
`locate <id>`, until it gets back to work.

## Files

| | |
|---|---|
| `coordinator.lua` | runs on the computer: the area, the work queue, the turtle registry |
| `flatten.lua` | runs on each turtle: `flatten`, `flatten mark1`, `flatten mark2`, `flatten status`, `flatten look` |

`flatten look` prints what the turtle can see of the blocks around it -
four lines on screen, since a turtle has no scrollback - and appends the
whole of it, states and tags and all, to `look.txt`. Read it with `edit
look.txt`, or `pastebin put look.txt` to get it off the machine.
| `common.lua` | the protocol and helpers both sides share |
| `startup.lua` | boots a turtle straight into work, and restarts it if it falls over |
| `update.lua` | `update all` |
| `reset.lua` | wipes a computer back to blank, `rom` aside. Nothing is left to re-download with, so it prints how to bootstrap again |

## Tests

The scripts can be run outside Minecraft against a stand-in for the
CC:Tweaked API - a real voxel world, real turtles, real rednet - which is
how the movement, digging and coordinator logic are checked:

```
sh test/run.sh
```
