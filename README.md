# ComCraft

Mining turtles that clear, fill or drain a rectangular area together, for
CC:Tweaked. One computer hands out the work, any number of turtles do it.
No coordinates to type: you walk a turtle to two opposite corners and GPS
does the rest.

Needs a GPS cluster over the site, a computer with a wireless modem, a
container against that computer with coal in it, and turtles with modems.

## Install

On each computer and turtle:

```
wget https://raw.githubusercontent.com/Escillex/ComputerCraft-Stuff/main/update.lua update
update all
```

Everything must be on the same version. The coordinator refuses work to a
turtle that is not, and says so.

## Use

1. `coordinator` on the computer next to the container.
2. On a turtle: `flatten mark1` at one corner, `flatten mark2` at the
   opposite corner - including height.
3. `flatten` on each turtle (or just boot them, with `startup.lua`).
4. `start` on the coordinator.

Nothing outside the marked box is ever broken or placed.

## Coordinator commands

| | |
|---|---|
| `start` / `stop` | hand out work, or stop |
| `list` | every turtle: state, position, last heard from |
| `locate <id>` | where one turtle is, even if it has gone quiet |
| `status` | area, progress, where the store is |
| `mode <clear\|fill\|drain>` | what to do with the area |
| `material <id> [more]` | what to fill, cap or plug with |
| `floor <on\|off>` | cap holes under a cleared area (off by default) |
| `retry` | put written-off columns back in the pool |
| `clear` | forget the area |
| `recalibrate` | re-read position, store, versions |
| `exit` | quit |

## Modes

- **clear** - empty it out.
- **fill** - make it solid out of `material`. Naming more than one block
  leaves the extras where they are and puts them back - but a turtle has no
  silk touch, so grass comes up as dirt and you need some in the store.
- **drain** - take out lava and water, break nothing. Works on lava; water
  re-sources behind the turtle, so for water use `fill` then `clear`.

## Files

`coordinator.lua`, `flatten.lua` (`mark1`, `mark2`, `status`, `look`),
`common.lua`, `startup.lua`, `update.lua`, `reset.lua`.

`sh test/run.sh` runs everything against a stand-in for the CC API.
