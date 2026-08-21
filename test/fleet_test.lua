-- End-to-end run of the real fleet scripts against the mock world.

package.path = "test/?.lua;" .. package.path
local sim = require("ccsim")

sim.verbose = os.getenv("VERBOSE") == "1"

--------------------------------------------------------------------------
-- The world
--------------------------------------------------------------------------

-- Area to clear: 9 x 6 x 9 = 81 columns, 486 blocks.
local BOX = { minX = 100, maxX = 108, minY = 59, maxY = 64, minZ = 200, maxZ = 208 }

local FLOOR_HOLE = { x = 102, y = 58, z = 202 }

-- A spread of block types, so turtles run out of inventory slots and have
-- to make real trips back to the chest.
local TERRAIN = {
  "minecraft:stone", "minecraft:dirt", "minecraft:gravel", "minecraft:andesite",
  "minecraft:diorite", "minecraft:granite", "minecraft:deepslate", "minecraft:tuff",
  "minecraft:iron_ore", "minecraft:copper_ore", "minecraft:coal_ore",
  "minecraft:redstone_ore", "minecraft:clay", "minecraft:sand",
  "minecraft:cobblestone", "minecraft:calcite", "minecraft:basalt",
  "minecraft:sandstone", "minecraft:mossy_cobblestone", "minecraft:gold_ore",
}

for x = BOX.minX, BOX.maxX do
  for z = BOX.minZ, BOX.maxZ do
    for y = BOX.minY, BOX.maxY do
      local pick = ((x * 7 + y * 13 + z * 31) % #TERRAIN) + 1
      sim.setBlock(x, y, z, TERRAIN[pick])
    end
    -- Bedrock under a solid floor, with one cave opening the turtles
    -- should patch on their way out.
    if not (x == FLOOR_HOLE.x and z == FLOOR_HOLE.z) then
      sim.setBlock(x, BOX.minY - 1, z, "minecraft:stone")
    end
    sim.setBlock(x, BOX.minY - 2, z, "minecraft:bedrock")
  end
end

-- Coordinator and its resupply chest, well clear of the dig site.
local COORD_POS = { x = 110, y = 64, z = 202 }
local CHEST_POS = { x = 111, y = 64, z = 202 }
sim.setBlock(COORD_POS.x, COORD_POS.y, COORD_POS.z, "computercraft:computer_normal")
local chest = sim.addChest(CHEST_POS.x, CHEST_POS.y, CHEST_POS.z)
chest.size = 54
for _ = 1, 6 do
  chest.slots[#chest.slots + 1] = { name = "minecraft:coal", count = 64 }
end

--------------------------------------------------------------------------
-- Machines
--------------------------------------------------------------------------

local coordinator = sim.addMachine({
  id = 1, name = "coord", pos = COORD_POS,
  console = {}, adjacentChest = { list = function() return {} end },
})
sim.boot(coordinator, "coordinator", {})
sim.run(5)

-- A turtle marks the two opposite corners of the volume.
local marker = sim.addMachine({
  id = 2, name = "marker",
  isTurtle = true, pos = { x = BOX.minX, y = BOX.maxY, z = BOX.minZ }, facing = 1,
})
-- Stand the marker in the corner block itself (it is about to be dug out).
sim.setBlock(BOX.minX, BOX.maxY, BOX.minZ, nil)
sim.boot(marker, "flatten", { "mark1" })
sim.run(30)

marker.pos = { x = BOX.maxX, y = BOX.minY, z = BOX.maxZ }
sim.setBlock(BOX.maxX, BOX.minY, BOX.maxZ, nil)
sim.boot(marker, "flatten", { "mark2" })
sim.run(60)
marker.alive = false
marker.present = false   -- the player picks the marker turtle back up

-- Three workers, parked in the open air between the coordinator and the site.
local workers = {}
for i = 1, 3 do
  local w = sim.addMachine({
    id = 10 + i, name = "t" .. (10 + i), isTurtle = true,
    pos = { x = 109, y = 64, z = 200 + i },
    facing = 3,
    slots = { [1] = { name = "minecraft:coal", count = 16 } },
    fuel = 0,
  })
  workers[#workers + 1] = w
  sim.boot(w, "flatten", {})
end

table.insert(coordinator.console, "start")

--------------------------------------------------------------------------
-- Run
--------------------------------------------------------------------------

local function allWorkersIdle()
  for _, w in ipairs(workers) do
    if w.alive then return false end
  end
  return true
end

sim.run(20000, allWorkersIdle)
-- Give every worker time to notice the job is over and stand down.
sim.run(sim.now() + 300, allWorkersIdle)

table.insert(coordinator.console, "status")
table.insert(coordinator.console, "list")
sim.run(sim.now() + 20)

--------------------------------------------------------------------------
-- Checks
--------------------------------------------------------------------------

local failures = {}
local function check(ok, message)
  if ok then
    print("  PASS  " .. message)
  else
    print("  FAIL  " .. message)
    failures[#failures + 1] = message
  end
end

print("\n=== results (sim clock " .. math.floor(sim.now()) .. "s) ===")

for _, m in ipairs(sim.machines()) do
  check(not m.crash, ("%s did not crash%s"):format(m.name, m.crash and (": " .. tostring(m.crash)) or ""))
end

check(#sim.violations() == 0, "nothing dug a turtle or the chest")
for _, v in ipairs(sim.violations()) do print("        " .. v) end

local leftover = {}
for x = BOX.minX, BOX.maxX do
  for y = BOX.minY, BOX.maxY do
    for z = BOX.minZ, BOX.maxZ do
      if sim.getBlock(x, y, z) then
        leftover[#leftover + 1] = ("%d,%d,%d=%s"):format(x, y, z, sim.getBlock(x, y, z))
      end
    end
  end
end
check(#leftover == 0, ("every block in the area is cleared (%d left)"):format(#leftover))
for i = 1, math.min(#leftover, 10) do print("        " .. leftover[i]) end

check(sim.getBlock(FLOOR_HOLE.x, FLOOR_HOLE.y, FLOOR_HOLE.z) ~= nil,
  "the hole in the floor was patched")

check(sim.getBlock(CHEST_POS.x, CHEST_POS.y, CHEST_POS.z) == "minecraft:chest",
  "the resupply chest is still standing")
check(sim.getBlock(COORD_POS.x, COORD_POS.y, COORD_POS.z) == "computercraft:computer_normal",
  "the coordinator is still standing")

local mined = 0
for _, slot in ipairs(chest.slots) do
  if slot.name ~= "minecraft:coal" then mined = mined + slot.count end
end
check(mined > 0, ("mined blocks reached the chest (%d items)"):format(mined))

local stillRunning = {}
for _, w in ipairs(workers) do
  if w.alive then stillRunning[#stillRunning + 1] = w.name end
end
check(#stillRunning == 0,
  "every worker stood down once the job finished" ..
  (#stillRunning > 0 and (" (still going: " .. table.concat(stillRunning, ", ") .. ")") or ""))

local totalMoves, totalDigs, totalBumps = 0, 0, 0
for _, w in ipairs(workers) do
  totalMoves = totalMoves + w.moves
  totalDigs = totalDigs + w.digs
  totalBumps = totalBumps + w.bumps
end
check(totalBumps < 120,
  ("they mostly kept out of each other's way (%d collisions)"):format(totalBumps))
print(("\n  %d moves, %d digs, %d collisions across %d turtles")
  :format(totalMoves, totalDigs, totalBumps, #workers))

local log = coordinator.log
print("\n  last coordinator output:")
for i = math.max(1, #log - 14), #log do print("        " .. log[i]) end

if #failures > 0 then
  print(("\n%d CHECK(S) FAILED"):format(#failures))
  os.exit(1)
end
print("\nALL CHECKS PASSED")

print(("\n  coordinator wrote its state file %d times, %d bytes total")
  :format(sim.writes or 0, sim.bytesWritten or 0))
