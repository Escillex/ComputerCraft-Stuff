-- Scenario tests: one turtle on its own, a turtle vanishing mid-job, and
-- the reset utility.

package.path = "test/?.lua;" .. package.path

local failures = {}
local function check(ok, message)
  print((ok and "  PASS  " or "  FAIL  ") .. message)
  if not ok then failures[#failures + 1] = message end
end

-- Reload the simulator fresh for each scenario.
local function freshSim()
  package.loaded.ccsim = nil
  local sim = require("ccsim")
  sim.verbose = os.getenv("VERBOSE") == "1"
  return sim
end

--------------------------------------------------------------------------
-- A world with a coordinator, a chest and a small area to clear
--------------------------------------------------------------------------

local function buildWorld(sim, box)
  local TERRAIN = {
    "minecraft:stone", "minecraft:dirt", "minecraft:gravel", "minecraft:andesite",
    "minecraft:diorite", "minecraft:granite", "minecraft:deepslate", "minecraft:tuff",
    "minecraft:iron_ore", "minecraft:copper_ore", "minecraft:coal_ore",
    "minecraft:clay", "minecraft:sand", "minecraft:cobblestone",
  }
  for x = box.minX, box.maxX do
    for z = box.minZ, box.maxZ do
      for y = box.minY, box.maxY do
        sim.setBlock(x, y, z, TERRAIN[((x * 7 + y * 13 + z * 31) % #TERRAIN) + 1])
      end
      sim.setBlock(x, box.minY - 1, z, "minecraft:stone")
    end
  end

  local coordPos = { x = box.maxX + 2, y = box.maxY, z = box.minZ + 1 }
  sim.setBlock(coordPos.x, coordPos.y, coordPos.z, "computercraft:computer_normal")
  local chest = sim.addChest(coordPos.x + 1, coordPos.y, coordPos.z)
  chest.size = 54
  for _ = 1, 6 do
    chest.slots[#chest.slots + 1] = { name = "minecraft:coal", count = 64 }
  end
  return coordPos, chest
end

local function markCorners(sim, box)
  local marker = sim.addMachine({ id = 2, name = "marker", isTurtle = true,
    pos = { x = box.minX, y = box.maxY, z = box.minZ }, facing = 1 })
  sim.setBlock(box.minX, box.maxY, box.minZ, nil)
  sim.boot(marker, "flatten", { "mark1" })
  sim.run(sim.now() + 30)

  marker.pos = { x = box.maxX, y = box.minY, z = box.maxZ }
  sim.setBlock(box.maxX, box.minY, box.maxZ, nil)
  sim.boot(marker, "flatten", { "mark2" })
  sim.run(sim.now() + 60)
  marker.alive = false
  marker.present = false  -- the player picks the marker turtle back up
end

local function cleared(sim, box)
  local left = 0
  for x = box.minX, box.maxX do
    for y = box.minY, box.maxY do
      for z = box.minZ, box.maxZ do
        if sim.getBlock(x, y, z) then left = left + 1 end
      end
    end
  end
  return left
end

--------------------------------------------------------------------------
print("\n=== one turtle working alone ===")
--------------------------------------------------------------------------
do
  local sim = freshSim()
  local box = { minX = 100, maxX = 104, minY = 61, maxY = 64, minZ = 200, maxZ = 204 }
  local coordPos = buildWorld(sim, box)

  local coord = sim.addMachine({ id = 1, name = "coord", pos = coordPos, console = {},
    adjacentChest = { list = function() return {} end } })
  sim.boot(coord, "coordinator", {})
  sim.run(5)
  markCorners(sim, box)

  local solo = sim.addMachine({ id = 20, name = "solo", isTurtle = true,
    pos = { x = box.maxX + 1, y = box.maxY, z = box.minZ }, facing = 3,
    slots = { [1] = { name = "minecraft:coal", count = 16 } }, fuel = 0 })
  sim.boot(solo, "flatten", {})
  table.insert(coord.console, "start")

  sim.run(20000, function() return not solo.alive end)

  check(not solo.crash, "the lone turtle did not crash" ..
    (solo.crash and (": " .. tostring(solo.crash)) or ""))
  check(cleared(sim, box) == 0,
    ("one turtle cleared the whole area (%d blocks left)"):format(cleared(sim, box)))
  check(#sim.violations() == 0, "it dug nothing it should not have")
  check(not solo.alive, "it stood down when the job was done")
  print(("        %d moves, %d digs, finished at %ds")
    :format(solo.moves, solo.digs, math.floor(sim.now())))
end

--------------------------------------------------------------------------
print("\n=== a turtle vanishes mid-job ===")
--------------------------------------------------------------------------
do
  local sim = freshSim()
  local box = { minX = 100, maxX = 106, minY = 61, maxY = 64, minZ = 200, maxZ = 206 }
  local coordPos = buildWorld(sim, box)

  local coord = sim.addMachine({ id = 1, name = "coord", pos = coordPos, console = {},
    adjacentChest = { list = function() return {} end } })
  sim.boot(coord, "coordinator", {})
  sim.run(5)
  markCorners(sim, box)

  local crew = {}
  for i = 1, 3 do
    local w = sim.addMachine({ id = 30 + i, name = "t" .. (30 + i), isTurtle = true,
      pos = { x = box.maxX + 1, y = box.maxY, z = box.minZ + i }, facing = 3,
      slots = { [1] = { name = "minecraft:coal", count = 16 } }, fuel = 0 })
    crew[i] = w
    sim.boot(w, "flatten", {})
  end
  table.insert(coord.console, "start")

  -- Let them get going, then pull the plug on one (chunk unload, broken
  -- turtle, ran out of world - the coordinator cannot tell the difference).
  sim.run(sim.now() + 60)
  local victim = crew[2]
  local vanishedAt = { x = victim.pos.x, y = victim.pos.y, z = victim.pos.z }
  victim.alive = false
  print(("        turtle %d vanished at %d,%d,%d")
    :format(victim.id, vanishedAt.x, vanishedAt.y, vanishedAt.z))

  sim.run(20000, function() return not crew[1].alive and not crew[3].alive end)

  table.insert(coord.console, "locate " .. victim.id)
  table.insert(coord.console, "status")
  sim.run(sim.now() + 30)

  local log = table.concat(coord.log, "\n")
  check(log:find("turtle " .. victim.id .. " has gone quiet", 1, true) ~= nil,
    "the coordinator noticed the turtle had gone quiet")
  check(log:find("missing", 1, true) ~= nil,
    "locate still reports the missing turtle's last known position")
  -- The dead turtle is still a solid block, so the column it is sitting in
  -- cannot be finished. Everything else should be, and the job must not
  -- hang waiting on it.
  local height = box.maxY - box.minY + 1
  local left = cleared(sim, box)
  check(left <= height,
    ("only the stranded turtle's own column is left (%d blocks)"):format(left))
  check(log:find("job finished", 1, true) ~= nil,
    "the job finished instead of hanging on the unreachable column")
  check(#sim.violations() == 0, "nothing dug the abandoned turtle")

  for _, line in ipairs(coord.log) do
    if line:find("^turtle " .. victim.id) or line:find("state:") or line:find("position:") then
      print("        " .. line)
    end
  end
end

--------------------------------------------------------------------------
print("\n=== it goes over somebody's build, not through it ===")
--------------------------------------------------------------------------
do
  local sim = freshSim()
  local box = { minX = 100, maxX = 104, minY = 61, maxY = 64, minZ = 200, maxZ = 204 }
  local coordPos = buildWorld(sim, box)

  -- A wall right across the route between the dig site and the chest,
  -- stretching far enough either way that going round is not an option.
  local wall = {}
  for z = box.minZ - 20, box.maxZ + 20 do
    for y = box.minY, box.maxY + 3 do
      sim.setBlock(box.maxX + 1, y, z, "minecraft:stone_bricks")
      wall[#wall + 1] = { x = box.maxX + 1, y = y, z = z }
    end
  end

  local coord = sim.addMachine({ id = 1, name = "coord", pos = coordPos, console = {},
    adjacentChest = { list = function() return {} end } })
  sim.boot(coord, "coordinator", {})
  sim.run(5)
  markCorners(sim, box)

  -- Barely any fuel, so it has to go and find the chest before it can do
  -- anything else. Without this it finishes the whole area on one tank and
  -- never crosses the wall at all.
  local w = sim.addMachine({ id = 40, name = "walled", isTurtle = true,
    pos = { x = box.minX, y = box.maxY + 1, z = box.minZ }, facing = 1,
    slots = { [1] = { name = "minecraft:coal", count = 3 } }, fuel = 0 })
  sim.boot(w, "flatten", {})
  table.insert(coord.console, "start")
  sim.run(20000, function() return not w.alive end)

  local broken = 0
  for _, b in ipairs(wall) do
    if not sim.getBlock(b.x, b.y, b.z) then broken = broken + 1 end
  end

  check(not w.crash, "it did not crash" .. (w.crash and (": " .. tostring(w.crash)) or ""))
  -- It only counts as going round if it actually got to the chest.
  check(table.concat(coord.log, "\n"):find("resupply store found at", 1, true) ~= nil,
    "it found its way over to the chest")
  check(broken == 0, ("the wall was left standing (%d of %d blocks broken)")
    :format(broken, #wall))
  check(cleared(sim, box) == 0,
    ("it still cleared the marked area (%d blocks left)"):format(cleared(sim, box)))
  print(("        %d moves, %d digs"):format(w.moves, w.digs))
end

--------------------------------------------------------------------------
print("\n=== a modded store this code has never heard of ===")
--------------------------------------------------------------------------
do
  local sim = freshSim()
  local box = { minX = 100, maxX = 103, minY = 62, maxY = 64, minZ = 200, maxZ = 203 }
  local coordPos, chest = buildWorld(sim, box)

  -- Not a chest, a barrel or a shulker: a block whose name matches nothing
  -- this code knows. All the turtle has to go on is what the coordinator
  -- says is attached to it.
  local VAULT = "somemod:steel_vault"
  sim.setBlock(coordPos.x + 1, coordPos.y, coordPos.z, VAULT)

  local coord = sim.addMachine({ id = 1, name = "coord", pos = coordPos, console = {},
    adjacentChest = { list = function() return {} end }, storeType = VAULT })
  sim.boot(coord, "coordinator", {})
  sim.run(5)
  markCorners(sim, box)

  -- Send it out already full, so its very first act has to be emptying
  -- itself into the vault.
  local loaded = { [1] = { name = "minecraft:coal", count = 8 } }
  for slot = 2, 16 do
    loaded[slot] = { name = "minecraft:cobblestone_" .. slot, count = 64 }
  end

  local w = sim.addMachine({ id = 80, name = "modded", isTurtle = true,
    pos = { x = box.maxX + 1, y = box.maxY + 1, z = box.minZ }, facing = 3,
    slots = loaded, fuel = 0 })
  sim.boot(w, "flatten", {})
  table.insert(coord.console, "start")
  sim.run(20000, function() return not w.alive end)

  local log = table.concat(coord.log, "\n")
  check(log:find(VAULT, 1, true) ~= nil,
    "the coordinator named the block it found attached")
  check(log:find("resupply store found at", 1, true) ~= nil,
    "the turtle recognised the vault as the place to resupply")
  check(sim.getBlock(coordPos.x + 1, coordPos.y, coordPos.z) == VAULT,
    "and did not break it")

  local delivered = 0
  for _, slot in ipairs(chest.slots) do
    if slot.name ~= "minecraft:coal" then delivered = delivered + slot.count end
  end
  check(delivered > 0, ("it put mined blocks into the vault (%d items)"):format(delivered))
  check(cleared(sim, box) == 0, "and cleared the area")

  for _, line in ipairs(coord.log) do
    if line:find("resupply store") then
      print("        " .. line)
    end
  end
end

--------------------------------------------------------------------------
print("\n=== a Create item vault, which is a multiblock ===")
--------------------------------------------------------------------------
do
  local sim = freshSim()
  local box = { minX = 100, maxX = 103, minY = 62, maxY = 64, minZ = 200, maxZ = 203 }
  local coordPos, chest = buildWorld(sim, box)

  -- A 2x2x2 vault butted up against the coordinator. Every block of it is
  -- part of one structure: breaking any one takes the whole thing apart,
  -- and the block two out from the coordinator - where the old probe used
  -- to stand - is more vault rather than somewhere to stand.
  local VAULT = "create:item_vault"
  local vaultBlocks = {}
  for dx = 1, 2 do
    for dy = 0, 1 do
      for dz = 0, 1 do
        local p = { x = coordPos.x + dx, y = coordPos.y + dy, z = coordPos.z + dz }
        sim.setBlock(p.x, p.y, p.z, VAULT)
        vaultBlocks[#vaultBlocks + 1] = p
      end
    end
  end
  -- The whole multiblock is one inventory, so every block feeds the chest
  -- the scenario is tracking.
  for _, p in ipairs(vaultBlocks) do sim.linkChest(p.x, p.y, p.z, chest) end

  local coord = sim.addMachine({ id = 1, name = "coord", pos = coordPos, console = {},
    adjacentChest = { list = function() return {} end }, storeType = VAULT })
  sim.boot(coord, "coordinator", {})
  sim.run(5)
  markCorners(sim, box)

  local loaded = { [1] = { name = "minecraft:coal", count = 8 } }
  for slot = 2, 16 do
    loaded[slot] = { name = "minecraft:rubble_" .. slot, count = 64 }
  end
  local w = sim.addMachine({ id = 90, name = "vaulted", isTurtle = true,
    pos = { x = box.minX, y = box.maxY + 1, z = box.minZ }, facing = 1,
    slots = loaded, fuel = 0 })
  sim.boot(w, "flatten", {})
  table.insert(coord.console, "start")
  sim.run(20000, function() return not w.alive end)

  local log = table.concat(coord.log, "\n")
  check(log:find("resupply store found at", 1, true) ~= nil,
    "the turtle found the vault despite it being several blocks across")

  local brokenVault = 0
  for _, p in ipairs(vaultBlocks) do
    if sim.getBlock(p.x, p.y, p.z) ~= VAULT then brokenVault = brokenVault + 1 end
  end
  check(brokenVault == 0,
    ("every block of the multiblock is intact (%d of %d broken)")
      :format(brokenVault, #vaultBlocks))

  local delivered = 0
  for _, slot in ipairs(chest.slots) do
    if slot.name ~= "minecraft:coal" then delivered = delivered + slot.count end
  end
  check(delivered > 0, ("it emptied itself into the vault (%d items)"):format(delivered))
  check(cleared(sim, box) == 0, "and cleared the area")

  for _, line in ipairs(coord.log) do
    if line:find("resupply store") then print("        " .. line) end
  end
end

--------------------------------------------------------------------------
print("\n=== a turtle carrying a note from an older version ===")
--------------------------------------------------------------------------
do
  local sim = freshSim()
  local box = { minX = 100, maxX = 103, minY = 62, maxY = 64, minZ = 200, maxZ = 203 }
  local coordPos = buildWorld(sim, box)

  local coord = sim.addMachine({ id = 1, name = "coord", pos = coordPos, console = {},
    adjacentChest = { list = function() return {} end } })
  sim.boot(coord, "coordinator", {})
  sim.run(5)
  markCorners(sim, box)

  local w = sim.addMachine({ id = 100, name = "upgraded", isTurtle = true,
    pos = { x = box.maxX + 1, y = box.maxY + 1, z = box.minZ }, facing = 3,
    slots = { [1] = { name = "minecraft:coal", count = 8 } }, fuel = 0 })
  sim.boot(w, "flatten", {})

  -- Exactly what an older build left behind: the store's position under its
  -- old name, and no dir. Reading it must not produce a depot with two
  -- names for one table, because writing that back out is refused.
  w.files["flatten.state"] = [[{
    pos = { x = 105, y = 64, z = 200, },
    facing = 3,
    depot = {
      chest = { x = ]] .. (coordPos.x + 1) .. [[, y = ]] .. coordPos.y ..
      [[, z = ]] .. coordPos.z .. [[, },
      dock = { x = ]] .. (coordPos.x + 2) .. [[, y = ]] .. coordPos.y ..
      [[, z = ]] .. coordPos.z .. [[, },
      facing = 3,
    },
  }]]

  table.insert(coord.console, "start")
  sim.run(20000, function() return not w.alive end)

  check(not w.crash, "it started up on an old note without falling over" ..
    (w.crash and (": " .. tostring(w.crash)) or ""))

  local said = table.concat(w.log, "\n")
  check(said:find("repeated entries", 1, true) == nil,
    "and could still write its own note back out")
  check(cleared(sim, box) == 0,
    ("it got on with the job (%d blocks left)"):format(cleared(sim, box)))
end

--------------------------------------------------------------------------
print("\n=== the coordinator is restarted mid-job ===")
--------------------------------------------------------------------------
do
  local sim = freshSim()
  local box = { minX = 100, maxX = 109, minY = 60, maxY = 64, minZ = 200, maxZ = 209 }
  local coordPos = buildWorld(sim, box)

  local coord = sim.addMachine({ id = 1, name = "coord", pos = coordPos, console = {},
    adjacentChest = { list = function() return {} end } })
  sim.boot(coord, "coordinator", {})
  sim.run(5)
  markCorners(sim, box)

  local w = sim.addMachine({ id = 110, name = "worker", isTurtle = true,
    pos = { x = box.maxX + 1, y = box.maxY + 1, z = box.minZ }, facing = 3,
    slots = { [1] = { name = "minecraft:coal", count = 16 } }, fuel = 0 })
  sim.boot(w, "flatten", {})
  table.insert(coord.console, "start")

  -- Stop handing out work partway, which pauses the job at a known point
  -- rather than at whatever the clock happens to say.
  sim.run(sim.now() + 4)
  table.insert(coord.console, "stop")
  sim.run(sim.now() + 25)

  table.insert(coord.console, "status")
  sim.run(sim.now() + 10)
  local before_log = table.concat(coord.log, "\n")
  local doneBefore = tonumber(before_log:match("columns: (%d+) done")) or 0
  local togoBefore = tonumber(before_log:match("(%d+) to go")) or 0
  check(doneBefore > 0 and togoBefore > 0,
    ("the job was genuinely part-done when we pulled the plug (%d done, %d to go)")
      :format(doneBefore, togoBefore))

  -- Pull the coordinator down and bring it straight back up. Its state file
  -- is the only thing carried across.
  coord.alive = false
  local carried = coord.files["coordinator.state"]
  check(carried ~= nil and carried:find("marks", 1, true) ~= nil,
    "it had written the compact record of which columns are done")

  local restarted = sim.addMachine({ id = 1, name = "coord2", pos = coordPos,
    console = {}, adjacentChest = { list = function() return {} end } })
  restarted.files["coordinator.state"] = carried
  sim.boot(restarted, "coordinator", {})
  sim.run(sim.now() + 10)
  table.insert(restarted.console, "status")
  sim.run(sim.now() + 10)

  local log = table.concat(restarted.log, "\n")
  local doneAfter = tonumber(log:match("columns: (%d+) done")) or 0
  check(doneAfter == doneBefore,
    ("it remembered exactly the finished columns (%d before, %d after)")
      :format(doneBefore, doneAfter))
  check(log:find("area: 10 x 5 x 10", 1, true) ~= nil, "and remembered the area")

  -- And it can carry on: the rest of the area gets cleared without redoing
  -- what was already done.
  table.insert(restarted.console, "start")
  sim.run(20000, function() return not w.alive end)
  check(cleared(sim, box) == 0,
    ("it finished the job after the restart (%d blocks left)"):format(cleared(sim, box)))
  print(("        %d columns already done at restart, %d to go")
    :format(doneBefore, togoBefore))
end

--------------------------------------------------------------------------
print("\n=== a tall area with the store down at ground level ===")
--------------------------------------------------------------------------
do
  -- The shape of a real job: the marked area reaches many blocks above the
  -- coordinator, while the store sits on the ground beside it. Coming down
  -- from the top of the area to the roof of the store is a long way, and a
  -- descent that gives up short of it never finds the store at all.
  local sim = freshSim()
  local box = { minX = 100, maxX = 104, minY = 63, maxY = 81, minZ = 200, maxZ = 204 }
  local coordPos, chest = buildWorld(sim, box)

  -- Clear away the default chest and computer, which buildWorld puts level
  -- with the top of the area, and rebuild them on the ground instead. Left
  -- where they were they would sit in the column the turtle descends.
  sim.setBlock(coordPos.x, coordPos.y, coordPos.z, nil)
  sim.setBlock(coordPos.x + 1, coordPos.y, coordPos.z, nil)

  -- The coordinator and its store on the ground, well below the top of the
  -- area, the store three blocks tall as a Create vault would be. Nothing
  -- above it but sky.
  coordPos.y = 63
  sim.setBlock(coordPos.x, coordPos.y, coordPos.z, "computercraft:computer_normal")

  -- A Create item vault as they actually come: three tall, three across,
  -- and as long as you like. Three wide is what makes standing beside it
  -- and looking sideways hopeless - two blocks out from the coordinator is
  -- still inside the structure - so the roof is the only way in.
  local VAULT = "create:item_vault"
  local vaultBlocks = {}
  for dx = 1, 4 do
    for dy = 0, 2 do
      for dz = -1, 1 do
        local p = { x = coordPos.x + dx, y = coordPos.y + dy, z = coordPos.z + dz }
        sim.setBlock(p.x, p.y, p.z, VAULT)
        sim.linkChest(p.x, p.y, p.z, chest)
        vaultBlocks[#vaultBlocks + 1] = p
      end
    end
  end

  local coord = sim.addMachine({ id = 1, name = "coord", pos = coordPos, console = {},
    adjacentChest = { list = function() return {} end }, storeType = VAULT })
  sim.boot(coord, "coordinator", {})
  sim.run(5)
  markCorners(sim, box)

  local loaded = { [1] = { name = "minecraft:coal", count = 12 } }
  for slot = 2, 16 do
    loaded[slot] = { name = "minecraft:spoil_" .. slot, count = 64 }
  end
  local w = sim.addMachine({ id = 120, name = "tall", isTurtle = true,
    pos = { x = box.maxX + 1, y = box.maxY, z = box.minZ }, facing = 3,
    slots = loaded, fuel = 0 })
  sim.boot(w, "flatten", {})
  table.insert(coord.console, "start")
  sim.run(20000, function() return not w.alive end)

  local log = table.concat(coord.log, "\n")
  check(log:find("resupply store found at", 1, true) ~= nil,
    ("it reached down %d blocks to find the store"):format(box.maxY - coordPos.y))

  local delivered = 0
  for _, slot in ipairs(chest.slots) do
    if slot.name ~= "minecraft:coal" then delivered = delivered + slot.count end
  end
  check(delivered > 0, ("it emptied itself into the store (%d items)"):format(delivered))

  local broken = 0
  for _, p in ipairs(vaultBlocks) do
    if sim.getBlock(p.x, p.y, p.z) ~= VAULT then broken = broken + 1 end
  end
  check(broken == 0, ("the store is intact (%d of %d broken)"):format(broken, #vaultBlocks))

  for _, line in ipairs(coord.log) do
    if line:find("resupply store found") then print("        " .. line) end
  end
end

--------------------------------------------------------------------------
print("\n=== a docking spot that has stopped working ===")
--------------------------------------------------------------------------
do
  -- A turtle carrying a note that says the way in is beside the store, from
  -- back when that was how it was found. Against a vault three blocks wide
  -- that spot is inside the structure, so it can never be stood on. The
  -- turtle has to notice, throw the note away and go and look again rather
  -- than reporting the same failure forever.
  local sim = freshSim()
  local box = { minX = 100, maxX = 104, minY = 63, maxY = 70, minZ = 200, maxZ = 204 }
  local coordPos, chest = buildWorld(sim, box)

  sim.setBlock(coordPos.x, coordPos.y, coordPos.z, nil)
  sim.setBlock(coordPos.x + 1, coordPos.y, coordPos.z, nil)
  coordPos.y = 63
  sim.setBlock(coordPos.x, coordPos.y, coordPos.z, "computercraft:computer_normal")

  local VAULT = "create:item_vault"
  for dx = 1, 3 do
    for dy = 0, 2 do
      for dz = -1, 1 do
        local p = { x = coordPos.x + dx, y = coordPos.y + dy, z = coordPos.z + dz }
        sim.setBlock(p.x, p.y, p.z, VAULT)
        sim.linkChest(p.x, p.y, p.z, chest)
      end
    end
  end

  local coord = sim.addMachine({ id = 1, name = "coord", pos = coordPos, console = {},
    adjacentChest = { list = function() return {} end }, storeType = VAULT })
  sim.boot(coord, "coordinator", {})
  sim.run(5)
  markCorners(sim, box)

  local loaded = { [1] = { name = "minecraft:coal", count = 12 } }
  for slot = 2, 16 do
    loaded[slot] = { name = "minecraft:spoil_" .. slot, count = 64 }
  end
  local w = sim.addMachine({ id = 130, name = "stale", isTurtle = true,
    pos = { x = box.maxX + 1, y = box.maxY, z = box.minZ }, facing = 3,
    slots = loaded, fuel = 0 })
  sim.boot(w, "flatten", {})

  -- The dock two blocks out from the coordinator: solidly inside the vault.
  w.files["flatten.state"] = ([[{
    pos = { x = %d, y = %d, z = %d, },
    facing = 3,
    depot = {
      store = { x = %d, y = %d, z = %d, },
      dock = { x = %d, y = %d, z = %d, },
      dir = "forward",
      facing = 3,
    },
  }]]):format(box.maxX + 1, box.maxY, box.minZ,
              coordPos.x + 1, coordPos.y, coordPos.z,
              coordPos.x + 2, coordPos.y, coordPos.z)

  table.insert(coord.console, "start")
  sim.run(20000, function() return not w.alive end)

  local said = table.concat(w.log, "\n")
  check(said:find("will look again", 1, true) ~= nil,
    "it worked out its note was no good")
  check(table.concat(coord.log, "\n"):find("resupply store found at", 1, true) ~= nil,
    "and found a way in that works")

  local delivered = 0
  for _, slot in ipairs(chest.slots) do
    if slot.name ~= "minecraft:coal" then delivered = delivered + slot.count end
  end
  check(delivered > 0, ("it got its load into the store (%d items)"):format(delivered))
  check(cleared(sim, box) == 0, "and finished the job")
end

--------------------------------------------------------------------------
print("\n=== more turtles than there is work for ===")
--------------------------------------------------------------------------
do
  -- A tiny area and five turtles, so almost all of them are idle almost
  -- all of the time: the state a job ends up in as the last few columns
  -- go. Idle turtles must get out of the way rather than stand in the
  -- middle of the site jostling the ones still working.
  local sim = freshSim()
  local box = { minX = 100, maxX = 102, minY = 62, maxY = 64, minZ = 200, maxZ = 202 }
  local coordPos = buildWorld(sim, box)

  local coord = sim.addMachine({ id = 1, name = "coord", pos = coordPos, console = {},
    adjacentChest = { list = function() return {} end } })
  sim.boot(coord, "coordinator", {})
  sim.run(5)
  markCorners(sim, box)

  local crew = {}
  for i = 1, 5 do
    local w = sim.addMachine({ id = 70 + i, name = "t" .. (70 + i), isTurtle = true,
      pos = { x = box.maxX + 1, y = box.maxY + 1, z = box.minZ + i - 1 }, facing = 3,
      slots = { [1] = { name = "minecraft:coal", count = 16 } }, fuel = 0 })
    crew[i] = w
    sim.boot(w, "flatten", {})
  end
  table.insert(coord.console, "start")

  local function allDone()
    for _, w in ipairs(crew) do if w.alive then return false end end
    return true
  end
  sim.run(20000, allDone)

  check(allDone(), "every turtle finished rather than jamming")
  check(cleared(sim, box) == 0,
    ("the area was cleared (%d blocks left)"):format(cleared(sim, box)))

  local moves, bumps, crashes = 0, 0, {}
  for _, w in ipairs(crew) do
    moves = moves + w.moves
    bumps = bumps + w.bumps
    if w.crash then crashes[#crashes + 1] = w.name .. ": " .. tostring(w.crash) end
  end
  check(#crashes == 0, "none of them crashed " .. table.concat(crashes, "; "))

  -- The real measure: how often one turtle walked into another. Idle
  -- turtles standing about on the site is what drives this up.
  check(bumps < 40, ("they kept out of each other's way (%d collisions)"):format(bumps))
  print(("        finished at %ds, %d moves, %d collisions across 5 turtles")
    :format(math.floor(sim.now()), moves, bumps))
end

--------------------------------------------------------------------------
print("\n=== trouble is reported on the coordinator, not just the turtle ===")
--------------------------------------------------------------------------
do
  local sim = freshSim()
  local box = { minX = 100, maxX = 104, minY = 61, maxY = 64, minZ = 200, maxZ = 204 }
  local coordPos = buildWorld(sim, box)

  -- Take the container away entirely: the coordinator has nothing attached
  -- and there is nothing for a turtle to find, so it should give up on
  -- resupplying and say so where a person will actually see it.
  sim.setBlock(coordPos.x + 1, coordPos.y, coordPos.z, nil)

  local coord = sim.addMachine({ id = 1, name = "coord", pos = coordPos, console = {} })
  sim.boot(coord, "coordinator", {})
  sim.run(5)
  markCorners(sim, box)

  local w = sim.addMachine({ id = 60, name = "stuck", isTurtle = true,
    pos = { x = box.minX, y = box.maxY + 1, z = box.minZ }, facing = 1,
    slots = { [1] = { name = "minecraft:coal", count = 3 } }, fuel = 0 })
  sim.boot(w, "flatten", {})
  table.insert(coord.console, "start")
  sim.run(sim.now() + 600)

  table.insert(coord.console, "list")
  sim.run(sim.now() + 20)

  local log = table.concat(coord.log, "\n")
  check(log:find("turtle 60:", 1, true) ~= nil,
    "the coordinator printed the turtle's complaint")
  check(log:find("store", 1, true) ~= nil, "it said what the problem was")
  check(log:find("it is at x=", 1, true) ~= nil, "it said where the turtle was")

  for _, line in ipairs(coord.log) do
    if line:find("turtle 60:") or line:find("it is at") or line:find("%^ ") then
      print("        " .. line)
    end
  end
end

--------------------------------------------------------------------------
print("\n=== reset.lua wipes everything but rom ===")
--------------------------------------------------------------------------
do
  local sim = freshSim()
  local m = sim.addMachine({ id = 50, name = "wipe", pos = { x = 0, y = 0, z = 0 } })
  sim.boot(m, "reset", {})
  m.files["flatten.state"] = "leftover"
  m.files["notes.txt"] = "keep me? no"
  sim.run(30)

  local remaining = {}
  for name in pairs(m.files) do remaining[#remaining + 1] = name end
  table.sort(remaining)

  check(#remaining == 0,
    "every writable file was deleted (left: " .. table.concat(remaining, ", ") .. ")")
  check(table.concat(m.log, "\n"):find("keeping rom", 1, true) ~= nil,
    "rom was left alone")
  check(table.concat(m.log, "\n"):find("wget", 1, true) ~= nil,
    "it printed how to bootstrap the computer again")
end

--------------------------------------------------------------------------
if #failures > 0 then
  print(("\n%d CHECK(S) FAILED"):format(#failures))
  for _, f in ipairs(failures) do print("  - " .. f) end
  os.exit(1)
end
print("\nALL SCENARIOS PASSED")
