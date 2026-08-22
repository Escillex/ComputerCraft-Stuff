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
print("\n=== updating in the middle of a job ===")
--------------------------------------------------------------------------
do
  -- Stopping a job, updating every computer and carrying on is the normal
  -- way to pick up a fix. The state file on disk was written by the version
  -- being replaced, so it has to be readable by the one taking over or the
  -- fleet goes back over ground it has already cleared.
  local sim = freshSim()
  local box = { minX = 100, maxX = 103, minY = 62, maxY = 64, minZ = 200, maxZ = 203 }
  local coordPos = buildWorld(sim, box)

  -- Exactly what an older coordinator left behind: a table per column, and
  -- no marks string. Two of the sixteen columns were finished, and one was
  -- being worked when the plug was pulled.
  local older = ([[{
    corners = { { x = %d, y = %d, z = %d, }, { x = %d, y = %d, z = %d, }, },
    box = { minX = %d, maxX = %d, minY = %d, maxY = %d, minZ = %d, maxZ = %d, },
    running = false,
    cells = {
      ["%d,%d"] = { x = %d, z = %d, state = "done", attempts = 0, },
      ["%d,%d"] = { x = %d, z = %d, state = "done", attempts = 0, },
      ["%d,%d"] = { x = %d, z = %d, state = "claimed", attempts = 0, },
    },
  }]]):format(
    box.minX, box.maxY, box.minZ, box.maxX, box.minY, box.maxZ,
    box.minX, box.maxX, box.minY, box.maxY, box.minZ, box.maxZ,
    box.minX, box.minZ, box.minX, box.minZ,
    box.minX, box.minZ + 1, box.minX, box.minZ + 1,
    box.maxX, box.maxZ, box.maxX, box.maxZ)

  local coord = sim.addMachine({ id = 1, name = "coord", pos = coordPos, console = {},
    adjacentChest = { list = function() return {} end } })
  coord.files["coordinator.state"] = older
  sim.boot(coord, "coordinator", {})
  sim.run(5)

  table.insert(coord.console, "status")
  sim.run(sim.now() + 10)

  local log = table.concat(coord.log, "\n")
  check(log:find("area: 4 x 3 x 4", 1, true) ~= nil, "it read the area off the old file")
  local done = tonumber(log:match("columns: (%d+) done"))
  check(done == 2, ("and the columns already finished (%s of them)"):format(tostring(done)))
  local togo = tonumber(log:match("(%d+) to go"))
  check(togo == 14,
    ("the one being worked went back in the pool (%s to go)"):format(tostring(togo)))

  for _, line in ipairs(coord.log) do
    if line:find("^columns:") then print("        " .. line) end
  end
end

--------------------------------------------------------------------------
print("\n=== a long walk back to a distant store ===")
--------------------------------------------------------------------------
do
  -- The store a long way from the dig, so every resupply is expensive and
  -- a turtle that tops up with a few hundred fuel strands itself. Holes in
  -- the floor throughout, so it also has to still have something to patch
  -- with after it has emptied itself into the store.
  local sim = freshSim()
  local box = { minX = 100, maxX = 106, minY = 55, maxY = 70, minZ = 200, maxZ = 206 }
  local coordPos, chest = buildWorld(sim, box)

  -- Move the whole depot sixty blocks away.
  sim.setBlock(coordPos.x, coordPos.y, coordPos.z, nil)
  sim.setBlock(coordPos.x + 1, coordPos.y, coordPos.z, nil)
  coordPos.x = coordPos.x + 60
  sim.setBlock(coordPos.x, coordPos.y, coordPos.z, "computercraft:computer_normal")
  sim.setBlock(coordPos.x + 1, coordPos.y, coordPos.z, "minecraft:chest")
  sim.linkChest(coordPos.x + 1, coordPos.y, coordPos.z, chest)

  -- Cave under every column, so a floor gets patched on every single one.
  local holes = {}
  for x = box.minX, box.maxX do
    for z = box.minZ, box.maxZ do
      sim.setBlock(x, box.minY - 1, z, nil)
      holes[#holes + 1] = { x = x, z = z }
    end
  end
  -- Dirt in the store, which is where a turtle that has just emptied
  -- itself has to get its patching material from.
  for _ = 1, 4 do
    chest.slots[#chest.slots + 1] = { name = "minecraft:dirt", count = 64 }
  end

  local coord = sim.addMachine({ id = 1, name = "coord", pos = coordPos, console = {},
    adjacentChest = { list = function() return {} end } })
  sim.boot(coord, "coordinator", {})
  sim.run(5)
  markCorners(sim, box)

  local w = sim.addMachine({ id = 140, name = "hauler", isTurtle = true,
    pos = { x = box.maxX + 1, y = box.maxY, z = box.minZ }, facing = 3,
    slots = { [1] = { name = "minecraft:coal", count = 8 } }, fuel = 0 })
  sim.boot(w, "flatten", {})
  table.insert(coord.console, "start")
  sim.run(40000, function() return not w.alive end)

  check(not w.crash, "it did not crash" .. (w.crash and (": " .. tostring(w.crash)) or ""))
  check((w.ranDry or 0) == 0,
    ("it never ran the tank dry (%d stalled moves)"):format(w.ranDry or 0))
  check(cleared(sim, box) == 0,
    ("it cleared the whole area (%d blocks left)"):format(cleared(sim, box)))

  local unpatched = 0
  for _, h in ipairs(holes) do
    if not sim.getBlock(h.x, box.minY - 1, h.z) then unpatched = unpatched + 1 end
  end
  check(unpatched == 0,
    ("every hole in the floor was patched (%d of %d left open)")
      :format(unpatched, #holes))
  print(("        lowest fuel reached: %d"):format(w.lowestFuel or -1))
end

--------------------------------------------------------------------------
print("\n=== a thin area with a build standing over it ===")
--------------------------------------------------------------------------
do
  -- Marking two corners at the same height gives an area one block tall.
  -- Anything built above it is not part of the job and must survive, even
  -- though a turtle coming from above would find it quicker to punch
  -- straight down through it.
  local sim = freshSim()
  local box = { minX = 100, maxX = 103, minY = 64, maxY = 64, minZ = 200, maxZ = 203 }

  for x = box.minX, box.maxX do
    for z = box.minZ, box.maxZ do
      sim.setBlock(x, 64, z, "minecraft:dirt")
      sim.setBlock(x, 63, z, "minecraft:stone")
    end
  end

  -- Somebody's floor, five blocks up, directly over the whole area.
  local roof = {}
  for x = box.minX, box.maxX do
    for z = box.minZ, box.maxZ do
      sim.setBlock(x, 69, z, "minecraft:oak_planks")
      roof[#roof + 1] = { x = x, y = 69, z = z }
    end
  end

  local coordPos = { x = box.maxX + 2, y = 64, z = box.minZ + 1 }
  sim.setBlock(coordPos.x, coordPos.y, coordPos.z, "computercraft:computer_normal")
  local chest = sim.addChest(coordPos.x + 1, coordPos.y, coordPos.z)
  chest.size = 54
  for _ = 1, 4 do
    chest.slots[#chest.slots + 1] = { name = "minecraft:coal", count = 64 }
  end

  local coord = sim.addMachine({ id = 1, name = "coord", pos = coordPos, console = {},
    adjacentChest = { list = function() return {} end } })
  sim.boot(coord, "coordinator", {})
  sim.run(5)
  markCorners(sim, box)

  -- Deliberately started above the roof, the worst case: the short way in
  -- is straight through it.
  local w = sim.addMachine({ id = 150, name = "roofed", isTurtle = true,
    pos = { x = box.minX, y = 72, z = box.minZ }, facing = 1,
    slots = { [1] = { name = "minecraft:coal", count = 8 } }, fuel = 0 })
  sim.boot(w, "flatten", {})
  table.insert(coord.console, "start")
  sim.run(20000, function() return not w.alive end)

  local broken = 0
  for _, b in ipairs(roof) do
    if not sim.getBlock(b.x, b.y, b.z) then broken = broken + 1 end
  end
  check(broken == 0,
    ("the build above the area was left alone (%d of %d broken)")
      :format(broken, #roof))
  check(#sim.violations() == 0, "and nothing protected was dug")
end

--------------------------------------------------------------------------
print("\n=== boxed in on every side by somebody's build ===")
--------------------------------------------------------------------------
do
  -- The whole guarantee in one go. The marked area is wrapped in blocks
  -- that are not part of the job: a floor under it, a roof over half of it,
  -- and a wall right the way round between it and the store. Every one of
  -- them has to still be there at the end, and the area still cleared -
  -- which means going over the wall rather than through it.
  local sim = freshSim()
  local box = { minX = 100, maxX = 103, minY = 62, maxY = 65, minZ = 200, maxZ = 203 }
  local HEADROOM = box.maxY + 1        -- the one layer turtles may break

  for x = box.minX, box.maxX do
    for z = box.minZ, box.maxZ do
      for y = box.minY, box.maxY do
        sim.setBlock(x, y, z, "minecraft:stone")
      end
    end
  end

  local sacred = {}
  local function keep(x, y, z, name)
    sim.setBlock(x, y, z, name)
    sacred[#sacred + 1] = { x = x, y = y, z = z, name = name }
  end

  -- Under it.
  for x = box.minX, box.maxX do
    for z = box.minZ, box.maxZ do keep(x, box.minY - 1, z, "minecraft:bedrock") end
  end

  -- Over half of it, starting at the very first block above the area - the
  -- layer that used to be fair game for dropping in through. The other half
  -- is open sky, which is how they get in and out.
  for x = box.minX, box.minX + 1 do
    for z = box.minZ, box.maxZ do
      for y = HEADROOM, HEADROOM + 3 do keep(x, y, z, "minecraft:oak_planks") end
    end
  end

  -- All the way round, tall enough that going over means climbing well
  -- clear of it.
  for y = box.minY - 2, box.maxY + 5 do
    for x = box.minX - 1, box.maxX + 1 do
      keep(x, y, box.minZ - 1, "minecraft:stone_bricks")
      keep(x, y, box.maxZ + 1, "minecraft:stone_bricks")
    end
    for z = box.minZ, box.maxZ do
      keep(box.minX - 1, y, z, "minecraft:stone_bricks")
      keep(box.maxX + 1, y, z, "minecraft:stone_bricks")
    end
  end

  -- Store and coordinator outside the wall entirely.
  local coordPos = { x = box.maxX + 8, y = box.minY, z = box.minZ + 1 }
  sim.setBlock(coordPos.x, coordPos.y, coordPos.z, "computercraft:computer_normal")
  local chest = sim.addChest(coordPos.x + 1, coordPos.y, coordPos.z)
  chest.size = 54
  for _ = 1, 4 do
    chest.slots[#chest.slots + 1] = { name = "minecraft:coal", count = 64 }
  end
  for _ = 1, 2 do
    chest.slots[#chest.slots + 1] = { name = "minecraft:dirt", count = 64 }
  end

  local coord = sim.addMachine({ id = 1, name = "coord", pos = coordPos, console = {},
    adjacentChest = { list = function() return {} end } })
  sim.boot(coord, "coordinator", {})
  sim.run(5)

  -- Mark from inside, since that is where the corners are.
  local mk = sim.addMachine({ id = 2, name = "mk", isTurtle = true,
    pos = { x = box.minX, y = box.maxY, z = box.minZ }, facing = 1 })
  sim.setBlock(box.minX, box.maxY, box.minZ, nil)
  sim.boot(mk, "flatten", { "mark1" })
  sim.run(sim.now() + 30)
  mk.pos = { x = box.maxX, y = box.minY, z = box.maxZ }
  sim.setBlock(box.maxX, box.minY, box.maxZ, nil)
  sim.boot(mk, "flatten", { "mark2" })
  sim.run(sim.now() + 60)
  mk.alive, mk.present = false, false

  -- Started under the open half, where it can climb out.
  local w = sim.addMachine({ id = 160, name = "boxed", isTurtle = true,
    pos = { x = box.maxX, y = HEADROOM, z = box.maxZ }, facing = 3,
    slots = { [1] = { name = "minecraft:coal", count = 8 } }, fuel = 0 })
  sim.boot(w, "flatten", {})
  table.insert(coord.console, "start")
  sim.run(40000, function() return not w.alive end)

  local damaged = {}
  for _, b in ipairs(sacred) do
    if sim.getBlock(b.x, b.y, b.z) ~= b.name then
      damaged[#damaged + 1] = ("%d,%d,%d"):format(b.x, b.y, b.z)
    end
  end
  check(#damaged == 0,
    ("nothing outside the area was touched (%d of %d blocks damaged)")
      :format(#damaged, #sacred))
  for i = 1, math.min(#damaged, 5) do print("        broke " .. damaged[i]) end

  check(cleared(sim, box) == 0,
    ("and the area was still cleared (%d blocks left)"):format(cleared(sim, box)))
  check(table.concat(coord.log, "\n"):find("resupply store found at", 1, true) ~= nil,
    "having got over the wall to the store and back")
  print(("        %d guarded blocks, %d moves"):format(#sacred, w.moves))
end

--------------------------------------------------------------------------
print("\n=== the way to the store is walled off high ===")
--------------------------------------------------------------------------
do
  -- A wall between the dig and the store that reaches well above the
  -- height a turtle would normally travel at. Since nothing outside the
  -- area may be broken, the only way through is over - which means trying
  -- again higher rather than giving up at the first altitude that fails.
  local sim = freshSim()
  local box = { minX = 100, maxX = 103, minY = 60, maxY = 64, minZ = 200, maxZ = 203 }
  local coordPos, chest = buildWorld(sim, box)

  local wall = {}
  for z = box.minZ - 15, box.maxZ + 15 do
    for y = box.minY - 5, box.maxY + 22 do
      sim.setBlock(box.maxX + 1, y, z, "minecraft:obsidian")
      wall[#wall + 1] = { x = box.maxX + 1, y = y, z = z }
    end
  end

  local coord = sim.addMachine({ id = 1, name = "coord", pos = coordPos, console = {},
    adjacentChest = { list = function() return {} end } })
  sim.boot(coord, "coordinator", {})
  sim.run(5)
  markCorners(sim, box)

  -- Barely any fuel, so it has to reach the store early or not at all.
  local w = sim.addMachine({ id = 170, name = "walled2", isTurtle = true,
    pos = { x = box.minX, y = box.maxY + 1, z = box.minZ }, facing = 1,
    slots = { [1] = { name = "minecraft:coal", count = 3 } }, fuel = 0 })
  sim.boot(w, "flatten", {})
  table.insert(coord.console, "start")
  sim.run(40000, function() return not w.alive end)

  check(table.concat(coord.log, "\n"):find("resupply store found at", 1, true) ~= nil,
    ("it climbed over a wall %d blocks above the area to reach the store")
      :format(box.maxY + 22 - box.maxY))
  local broken = 0
  for _, b in ipairs(wall) do
    if sim.getBlock(b.x, b.y, b.z) ~= "minecraft:obsidian" then broken = broken + 1 end
  end
  check(broken == 0, ("without touching it (%d of %d broken)"):format(broken, #wall))
  check(cleared(sim, box) == 0,
    ("and cleared the area (%d blocks left)"):format(cleared(sim, box)))
end

--------------------------------------------------------------------------
print("\n=== the store is found before any digging starts ===")
--------------------------------------------------------------------------
do
  -- Turtles should know where they are heading before they start filling
  -- themselves up, so no column goes out until somebody has been and found
  -- the store.
  local sim = freshSim()
  local box = { minX = 100, maxX = 104, minY = 61, maxY = 64, minZ = 200, maxZ = 204 }
  local coordPos = buildWorld(sim, box)

  local coord = sim.addMachine({ id = 1, name = "coord", pos = coordPos, console = {},
    adjacentChest = { list = function() return {} end } })
  sim.boot(coord, "coordinator", {})
  sim.run(5)
  markCorners(sim, box)

  -- Take the store away, so it cannot be found however hard they look.
  local storePos = { x = coordPos.x + 1, y = coordPos.y, z = coordPos.z }
  sim.setBlock(storePos.x, storePos.y, storePos.z, nil)

  local crew = {}
  for i = 1, 3 do
    local w = sim.addMachine({ id = 180 + i, name = "t" .. (180 + i), isTurtle = true,
      pos = { x = box.maxX + 1, y = box.maxY, z = box.minZ + i }, facing = 3,
      slots = { [1] = { name = "minecraft:coal", count = 16 } }, fuel = 0 })
    crew[i] = w
    sim.boot(w, "flatten", {})
  end
  table.insert(coord.console, "start")
  sim.run(sim.now() + 400)

  -- Not "no block was broken": a turtle walking through the area on its way
  -- somewhere else will legitimately break one, and that is inside the job.
  -- What must not happen is any column being handed out.
  table.insert(coord.console, "status")
  sim.run(sim.now() + 10)
  local before = table.concat(coord.log, "\n")
  local doneBlind = tonumber(before:match("columns: (%d+) done"))
  check(doneBlind == 0,
    ("no column was given out while the store was unknown (%s done)")
      :format(tostring(doneBlind)))
  check(before:find("no store found yet", 1, true) ~= nil,
    "and start said that was why")

  -- Put it back, and the job should get going by itself.
  sim.setBlock(storePos.x, storePos.y, storePos.z, "minecraft:chest")
  sim.run(20000, function()
    for _, w in ipairs(crew) do if w.alive then return false end end
    return true
  end)

  check(table.concat(coord.log, "\n"):find("resupply store found at", 1, true) ~= nil,
    "once it was there they found it")
  check(cleared(sim, box) == 0,
    ("and got the job done (%d blocks left)"):format(cleared(sim, box)))
end

--------------------------------------------------------------------------
print("\n=== only one turtle goes looking for the store ===")
--------------------------------------------------------------------------
do
  -- Three turtles, no store to be found. Exactly one should be sent to look
  -- for it; the other two wait rather than all trooping off to the same
  -- block. The one that goes is named on the coordinator.
  local sim = freshSim()
  local box = { minX = 100, maxX = 103, minY = 62, maxY = 64, minZ = 200, maxZ = 203 }
  local coordPos = buildWorld(sim, box)
  sim.setBlock(coordPos.x + 1, coordPos.y, coordPos.z, nil)   -- take the store away

  local coord = sim.addMachine({ id = 1, name = "coord", pos = coordPos, console = {},
    adjacentChest = { list = function() return {} end } })
  sim.boot(coord, "coordinator", {})
  sim.run(5)
  markCorners(sim, box)

  local crew = {}
  for i = 1, 3 do
    local w = sim.addMachine({ id = 190 + i, name = "t" .. (190 + i), isTurtle = true,
      pos = { x = box.maxX + 1, y = box.maxY, z = box.minZ + i - 1 }, facing = 3,
      slots = { [1] = { name = "minecraft:coal", count = 16 } }, fuel = 0 })
    crew[i] = w
    sim.boot(w, "flatten", {})
  end
  table.insert(coord.console, "start")
  sim.run(sim.now() + 60)

  -- Only the one sent should have gone near the coordinator; the rest stay
  -- parked over the area.
  local searchers = 0
  for _, w in ipairs(crew) do
    for _, line in ipairs(w.log) do
      if line:find("looking for the resupply store", 1, true) then
        searchers = searchers + 1
        break
      end
    end
  end
  check(searchers == 1,
    ("exactly one turtle went looking (%d did)"):format(searchers))

  local log = table.concat(coord.log, "\n")
  check(log:match("turtle (%d+) is going to find the store") ~= nil,
    "and the coordinator named which one")
  for _, line in ipairs(coord.log) do
    if line:find("going to find the store") then print("        " .. line) end
  end
end

--------------------------------------------------------------------------
print("\n=== a turtle that cannot start says so on the coordinator ===")
--------------------------------------------------------------------------
do
  -- Walled in on all six sides. It cannot work out which way it is facing
  -- without breaking something, and it will not do that - so it has to give
  -- up. Nobody is watching its screen, so the reason has to reach the
  -- coordinator.
  local sim = freshSim()
  local box = { minX = 100, maxX = 103, minY = 62, maxY = 64, minZ = 200, maxZ = 203 }
  local coordPos = buildWorld(sim, box)

  local coord = sim.addMachine({ id = 1, name = "coord", pos = coordPos, console = {},
    adjacentChest = { list = function() return {} end } })
  sim.boot(coord, "coordinator", {})
  sim.run(5)
  markCorners(sim, box)

  local at = { x = box.maxX + 6, y = box.maxY, z = box.maxZ + 6 }
  for _, d in ipairs({ { 1, 0, 0 }, { -1, 0, 0 }, { 0, 1, 0 }, { 0, -1, 0 },
                       { 0, 0, 1 }, { 0, 0, -1 } }) do
    sim.setBlock(at.x + d[1], at.y + d[2], at.z + d[3], "minecraft:obsidian")
  end

  local w = sim.addMachine({ id = 200, name = "stuck2", isTurtle = true,
    pos = at, facing = 1,
    slots = { [1] = { name = "minecraft:coal", count = 8 } }, fuel = 0 })
  sim.boot(w, "flatten", {})
  table.insert(coord.console, "start")
  sim.run(sim.now() + 120)

  local log = table.concat(coord.log, "\n")
  check(log:find("turtle 200:", 1, true) ~= nil,
    "the coordinator heard about it")
  check(log:find("walled in", 1, true) ~= nil,
    "and was told what was wrong")
  check(sim.getBlock(at.x + 1, at.y, at.z) == "minecraft:obsidian",
    "and it broke nothing getting its bearings")
  for _, line in ipairs(coord.log) do
    if line:find("turtle 200:") then print("        " .. line) end
  end
end

--------------------------------------------------------------------------
print("\n=== something alive standing in the way ===")
--------------------------------------------------------------------------
do
  -- A colonist, a cow, or you, stood in a turtle's path. It should wait a
  -- good while before laying a finger on it: most things in the way are
  -- passing through, and a few seconds of digging is not worth killing
  -- somebody's citizen over.
  local sim = freshSim()
  -- Big enough that it is certainly still working when we hem it in.
  local box = { minX = 100, maxX = 111, minY = 56, maxY = 70, minZ = 200, maxZ = 211 }
  local coordPos = buildWorld(sim, box)

  local coord = sim.addMachine({ id = 1, name = "coord", pos = coordPos, console = {},
    adjacentChest = { list = function() return {} end } })
  sim.boot(coord, "coordinator", {})
  sim.run(5)
  markCorners(sim, box)

  local w = sim.addMachine({ id = 210, name = "polite", isTurtle = true,
    pos = { x = box.maxX + 1, y = box.maxY, z = box.minZ }, facing = 3,
    slots = { [1] = { name = "minecraft:coal", count = 16 } }, fuel = 0 })
  sim.boot(w, "flatten", {})
  table.insert(coord.console, "start")
  -- Digging and walking cost no simulated time, so wait on progress rather
  -- than the clock: stop the moment it has done some real work.
  sim.run(20000, function() return w.moves > 60 end)
  check(w.alive, "the turtle was still working when we hemmed it in")

  -- Ring it with living things, so whichever way it turns it meets one and
  -- the timing is not down to which way it happened to be facing.
  local here = { x = w.pos.x, y = w.pos.y, z = w.pos.z }
  local victims = {}
  for _, d in ipairs({ { 1, 0, 0 }, { -1, 0, 0 }, { 0, 0, 1 }, { 0, 0, -1 },
                       { 0, 1, 0 }, { 0, -1, 0 } }) do
    victims[#victims + 1] =
      sim.addCreature(here.x + d[1], here.y + d[2], here.z + d[3])
  end

  local function hits()
    local n = 0
    for _, v in ipairs(victims) do n = n + v.hits end
    return n
  end

  local startedAt = sim.now()
  sim.run(startedAt + 8)
  local early = hits()
  sim.run(startedAt + 90)


  check(early == 0,
    ("nothing was hit in the first eight seconds of being blocked (%d hits)")
      :format(early))
  print(("        hits after ninety seconds hemmed in: %d"):format(hits()))
end

--------------------------------------------------------------------------
print("\n=== picking up columns that got written off ===")
--------------------------------------------------------------------------
do
  -- A pillar of bedrock in the middle of the area: unbreakable, so those
  -- columns get written off and the job finishes with holes. Take it away
  -- and 'retry' should put them back rather than making you clear the area
  -- and dig the whole thing again.
  local sim = freshSim()
  local box = { minX = 100, maxX = 104, minY = 62, maxY = 64, minZ = 200, maxZ = 204 }
  local coordPos = buildWorld(sim, box)

  local stuck = { x = 102, z = 202 }
  for y = box.minY, box.maxY do
    sim.setBlock(stuck.x, y, stuck.z, "minecraft:bedrock")
  end

  local coord = sim.addMachine({ id = 1, name = "coord", pos = coordPos, console = {},
    adjacentChest = { list = function() return {} end } })
  sim.boot(coord, "coordinator", {})
  sim.run(5)
  markCorners(sim, box)

  local w = sim.addMachine({ id = 220, name = "retrier", isTurtle = true,
    pos = { x = box.maxX + 1, y = box.maxY, z = box.minZ }, facing = 3,
    slots = { [1] = { name = "minecraft:coal", count = 16 } }, fuel = 0 })
  sim.boot(w, "flatten", {})
  table.insert(coord.console, "start")
  sim.run(20000, function() return not w.alive end)

  table.insert(coord.console, "status")
  sim.run(sim.now() + 10)
  local writtenOff = tonumber(table.concat(coord.log, "\n"):match("(%d+) written off"))
  check((writtenOff or 0) > 0,
    ("the bedrock column was written off (%s)"):format(tostring(writtenOff)))

  -- Take the obstruction away and ask for another go.
  for y = box.minY, box.maxY do sim.setBlock(stuck.x, y, stuck.z, nil) end
  table.insert(coord.console, "retry")
  table.insert(coord.console, "start")
  sim.run(sim.now() + 20)

  local after = table.concat(coord.log, "\n")
  check(after:match("(%d+) column%(s%) back in the pool") ~= nil,
    "retry put them back")

  local w2 = sim.addMachine({ id = 221, name = "retrier2", isTurtle = true,
    pos = { x = box.maxX + 1, y = box.maxY, z = box.minZ }, facing = 3,
    slots = { [1] = { name = "minecraft:coal", count = 16 } }, fuel = 0 })
  sim.boot(w2, "flatten", {})
  sim.run(20000, function() return not w2.alive end)

  check(cleared(sim, box) == 0,
    ("and the area finished properly (%d blocks left)"):format(cleared(sim, box)))
end

--------------------------------------------------------------------------
print("\n=== filling an area solid ===")
--------------------------------------------------------------------------
do
  -- A pitted, half-empty lump of ground turned into solid cobblestone.
  local sim = freshSim()
  local box = { minX = 100, maxX = 104, minY = 61, maxY = 64, minZ = 200, maxZ = 204 }
  local coordPos, chest = buildWorld(sim, box)

  -- Hollow a good deal of it out, so filling has real gaps to close as well
  -- as existing blocks to replace.
  for x = box.minX, box.maxX do
    for z = box.minZ, box.maxZ do
      for y = box.minY, box.maxY do
        if (x + y + z) % 3 ~= 0 then sim.setBlock(x, y, z, nil) end
      end
    end
  end

  -- Punch holes in the ground under the area. Clearing would cap these;
  -- filling must leave them exactly as they are.
  local floorWas = {}
  for x = box.minX, box.maxX do
    for z = box.minZ, box.maxZ do
      if (x + z) % 2 == 0 then sim.setBlock(x, box.minY - 1, z, nil) end
      floorWas[x .. "," .. z] = sim.getBlock(x, box.minY - 1, z)
    end
  end

  local MATERIAL = "minecraft:cobblestone"
  for _ = 1, 12 do
    chest.slots[#chest.slots + 1] = { name = MATERIAL, count = 64 }
  end

  local coord = sim.addMachine({ id = 1, name = "coord", pos = coordPos, console = {},
    adjacentChest = { list = function() return {} end } })
  sim.boot(coord, "coordinator", {})
  sim.run(5)
  markCorners(sim, box)

  local w = sim.addMachine({ id = 230, name = "filler", isTurtle = true,
    pos = { x = box.maxX + 1, y = box.maxY, z = box.minZ }, facing = 3,
    slots = { [1] = { name = "minecraft:coal", count = 16 } }, fuel = 0 })
  sim.boot(w, "flatten", {})

  table.insert(coord.console, "mode fill")
  table.insert(coord.console, "material " .. MATERIAL)
  table.insert(coord.console, "start")
  sim.run(40000, function() return not w.alive end)

  check(not w.crash, "it did not crash" .. (w.crash and (": " .. tostring(w.crash)) or ""))

  local wrong, air = 0, 0
  for x = box.minX, box.maxX do
    for y = box.minY, box.maxY do
      for z = box.minZ, box.maxZ do
        local b = sim.getBlock(x, y, z)
        if b == nil then air = air + 1
        elseif b ~= MATERIAL then wrong = wrong + 1 end
      end
    end
  end
  check(air == 0, ("no gaps left in the area (%d empty)"):format(air))
  check(wrong == 0, ("and all of it is the right block (%d wrong)"):format(wrong))
  check(#sim.violations() == 0, "nothing protected was dug")

  -- Clearing caps a hole in the floor under the area; filling has no floor
  -- to lay, because it fills the area itself right down to its own bottom.
  -- Anything below is not part of the job and must be left as it was.
  local under = 0
  for x = box.minX, box.maxX do
    for z = box.minZ, box.maxZ do
      if sim.getBlock(x, box.minY - 1, z) ~= floorWas[x .. "," .. z] then
        under = under + 1
      end
    end
  end
  check(under == 0,
    ("and it laid nothing below the area (%d blocks changed)"):format(under))
  print(("        %d blocks placed, %d moves"):format(
    (box.maxX - box.minX + 1) * (box.maxY - box.minY + 1) * (box.maxZ - box.minZ + 1),
    w.moves))
end

--------------------------------------------------------------------------
print("\n=== filling with something built over the area ===")
--------------------------------------------------------------------------
do
  -- Nothing outside the area may be broken, so with a ceiling resting on it
  -- a turtle has to cross the area at its own top - straight through
  -- columns already finished, taking their top block out on the way past.
  -- That leaves holes nobody asked for, so it has to refuse and say why
  -- rather than fill badly and report success.
  local sim = freshSim()
  local box = { minX = 100, maxX = 104, minY = 61, maxY = 64, minZ = 200, maxZ = 204 }
  local coordPos, chest = buildWorld(sim, box)

  local roof = {}
  for x = box.minX, box.maxX do
    for z = box.minZ, box.maxZ do
      sim.setBlock(x, box.maxY + 1, z, "minecraft:obsidian")
      roof[#roof + 1] = { x = x, z = z }
    end
  end

  local MATERIAL = "minecraft:cobblestone"
  for _ = 1, 12 do
    chest.slots[#chest.slots + 1] = { name = MATERIAL, count = 64 }
  end

  local coord = sim.addMachine({ id = 1, name = "coord", pos = coordPos, console = {},
    adjacentChest = { list = function() return {} end } })
  sim.boot(coord, "coordinator", {})
  sim.run(5)
  markCorners(sim, box)

  sim.setBlock(box.maxX, box.maxY, box.maxZ, nil)
  local w = sim.addMachine({ id = 240, name = "roofedfill", isTurtle = true,
    pos = { x = box.maxX, y = box.maxY, z = box.maxZ }, facing = 3,
    slots = { [1] = { name = "minecraft:coal", count = 16 } }, fuel = 0 })
  sim.boot(w, "flatten", {})

  table.insert(coord.console, "mode fill")
  table.insert(coord.console, "material " .. MATERIAL)
  table.insert(coord.console, "start")
  sim.run(40000, function() return not w.alive end)

  local air, wrong, gaps = 0, 0, {}
  for x = box.minX, box.maxX do
    for y = box.minY, box.maxY do
      for z = box.minZ, box.maxZ do
        local b = sim.getBlock(x, y, z)
        if b == nil then
          air = air + 1
          if #gaps < 8 then gaps[#gaps + 1] = ("%d,%d,%d"):format(x, y, z) end
        elseif b ~= MATERIAL then
          wrong = wrong + 1
        end
      end
    end
  end
  if #gaps > 0 then print("        gaps: " .. table.concat(gaps, "  ")) end
  check(air == 0, ("it filled every block with no sky above (%d empty)"):format(air))
  check(wrong == 0, ("and all of it is the right block (%d wrong)"):format(wrong))

  local broken = 0
  for _, r in ipairs(roof) do
    if sim.getBlock(r.x, box.maxY + 1, r.z) ~= "minecraft:obsidian" then
      broken = broken + 1
    end
  end
  check(broken == 0, ("and did not touch the roof (%d of %d)"):format(broken, #roof))
end

--------------------------------------------------------------------------
print("\n=== filling with the store off a different side ===")
--------------------------------------------------------------------------
do
  -- Same job, store to the south instead of the east, and a ceiling on the
  -- area so the road is the only way across. The road should follow the
  -- store: the row nearest it, not whichever edge happened to suit last
  -- time. If it picks the wrong edge the turtles fill their way into
  -- corners they cannot get out of.
  local sim = freshSim()
  local box = { minX = 100, maxX = 104, minY = 61, maxY = 64, minZ = 200, maxZ = 204 }

  for x = box.minX, box.maxX do
    for z = box.minZ, box.maxZ do
      for y = box.minY, box.maxY do sim.setBlock(x, y, z, "minecraft:stone") end
      sim.setBlock(x, box.maxY + 1, z, "minecraft:obsidian")   -- ceiling
    end
  end

  -- Coordinator and store south of the area, past maxZ.
  local coordPos = { x = box.minX + 2, y = box.maxY, z = box.maxZ + 2 }
  sim.setBlock(coordPos.x, coordPos.y, coordPos.z, "computercraft:computer_normal")
  local chest = sim.addChest(coordPos.x + 1, coordPos.y, coordPos.z)
  chest.size = 54
  local MATERIAL = "minecraft:cobblestone"
  for _ = 1, 4 do chest.slots[#chest.slots + 1] = { name = "minecraft:coal", count = 64 } end
  for _ = 1, 12 do chest.slots[#chest.slots + 1] = { name = MATERIAL, count = 64 } end

  local coord = sim.addMachine({ id = 1, name = "coord", pos = coordPos, console = {},
    adjacentChest = { list = function() return {} end } })
  sim.boot(coord, "coordinator", {})
  sim.run(5)
  markCorners(sim, box)

  sim.setBlock(box.maxX, box.maxY, box.maxZ, nil)
  local w = sim.addMachine({ id = 250, name = "southfill", isTurtle = true,
    pos = { x = box.maxX, y = box.maxY, z = box.maxZ }, facing = 0,
    slots = { [1] = { name = "minecraft:coal", count = 16 } }, fuel = 0 })
  sim.boot(w, "flatten", {})

  table.insert(coord.console, "mode fill")
  table.insert(coord.console, "material " .. MATERIAL)
  table.insert(coord.console, "start")
  sim.run(40000, function() return not w.alive end)

  -- Asked once the store has been found, since the road is worked out from
  -- where it is.
  table.insert(coord.console, "status")
  sim.run(sim.now() + 10)
  local road = table.concat(coord.log, "\n"):match("road: (%S+=%-?%d+)")
  check(road == ("z=" .. box.maxZ),
    ("the road follows the store to the south side (%s)"):format(tostring(road)))

  local air, wrong = 0, 0
  for x = box.minX, box.maxX do
    for y = box.minY, box.maxY do
      for z = box.minZ, box.maxZ do
        local b = sim.getBlock(x, y, z)
        if b == nil then air = air + 1
        elseif b ~= MATERIAL then wrong = wrong + 1 end
      end
    end
  end
  check(air == 0, ("it filled every block (%d empty)"):format(air))
  check(wrong == 0, ("all of it the right block (%d wrong)"):format(wrong))
end

--------------------------------------------------------------------------
print("\n=== filling an area walled in on three sides ===")
--------------------------------------------------------------------------
do
  -- Solid all the way round bar the side the store is on, and a ceiling on
  -- top: the turtles can only get in and out past the store, which is also
  -- the only ground they have to stand on to seal the road. None of the
  -- wall may be broken.
  local sim = freshSim()
  local box = { minX = 100, maxX = 104, minY = 61, maxY = 64, minZ = 200, maxZ = 204 }

  for x = box.minX, box.maxX do
    for z = box.minZ, box.maxZ do
      for y = box.minY, box.maxY do sim.setBlock(x, y, z, "minecraft:stone") end
      sim.setBlock(x, box.maxY + 1, z, "minecraft:obsidian")
    end
  end

  -- Walls north, east and west, floor to well above. South is left open,
  -- because that is where the store is.
  local wall = {}
  local function bricks(x, z)
    for y = box.minY - 1, box.maxY + 2 do
      sim.setBlock(x, y, z, "minecraft:obsidian")
      wall[#wall + 1] = { x = x, y = y, z = z }
    end
  end
  for x = box.minX - 1, box.maxX + 1 do bricks(x, box.minZ - 1) end
  for z = box.minZ - 1, box.maxZ do
    bricks(box.minX - 1, z)
    bricks(box.maxX + 1, z)
  end

  local coordPos = { x = box.minX + 2, y = box.maxY, z = box.maxZ + 2 }
  sim.setBlock(coordPos.x, coordPos.y, coordPos.z, "computercraft:computer_normal")
  local chest = sim.addChest(coordPos.x + 1, coordPos.y, coordPos.z)
  chest.size = 54
  local MATERIAL = "minecraft:cobblestone"
  for _ = 1, 4 do chest.slots[#chest.slots + 1] = { name = "minecraft:coal", count = 64 } end
  for _ = 1, 12 do chest.slots[#chest.slots + 1] = { name = MATERIAL, count = 64 } end

  local coord = sim.addMachine({ id = 1, name = "coord", pos = coordPos, console = {},
    adjacentChest = { list = function() return {} end } })
  sim.boot(coord, "coordinator", {})
  sim.run(5)
  markCorners(sim, box)

  sim.setBlock(box.maxX, box.maxY, box.maxZ, nil)
  local w = sim.addMachine({ id = 260, name = "walledfill", isTurtle = true,
    pos = { x = box.maxX, y = box.maxY, z = box.maxZ }, facing = 0,
    slots = { [1] = { name = "minecraft:coal", count = 16 } }, fuel = 0 })
  sim.boot(w, "flatten", {})

  table.insert(coord.console, "mode fill")
  table.insert(coord.console, "material " .. MATERIAL)
  table.insert(coord.console, "start")
  sim.run(40000, function() return not w.alive end)

  local air, wrong = 0, 0
  for x = box.minX, box.maxX do
    for y = box.minY, box.maxY do
      for z = box.minZ, box.maxZ do
        local b = sim.getBlock(x, y, z)
        if b == nil then air = air + 1
        elseif b ~= MATERIAL then wrong = wrong + 1 end
      end
    end
  end
  local gaps = {}
  for x = box.minX, box.maxX do
    for y = box.minY, box.maxY do
      for z = box.minZ, box.maxZ do
        if sim.getBlock(x, y, z) == nil then gaps[#gaps+1] = ("%d,%d,%d"):format(x,y,z) end
      end
    end
  end
  if #gaps > 0 then print("        gaps: " .. table.concat(gaps, "  ") .. "  (mouth z=" .. MOUTH_Z .. ", road x=" .. box.maxX .. ")") end
  check(air == 0, ("it filled every block (%d empty)"):format(air))
  check(wrong == 0, ("all of it the right block (%d wrong)"):format(wrong))

  local broken = 0
  for _, b in ipairs(wall) do
    if sim.getBlock(b.x, b.y, b.z) ~= "minecraft:obsidian" then broken = broken + 1 end
  end
  check(broken == 0, ("and the wall is untouched (%d of %d)"):format(broken, #wall))
end

--------------------------------------------------------------------------
print("\n=== an area sealed in on every side ===")
--------------------------------------------------------------------------
do
  -- Bricked up all four sides and roofed. Turtles cannot get in without
  -- breaking something that is not theirs to break, so they should not get
  -- in - and must not quietly leave a half-filled area behind reporting
  -- success. Either it is finished or the coordinator says what was beaten.
  local sim = freshSim()
  local box = { minX = 100, maxX = 103, minY = 62, maxY = 64, minZ = 200, maxZ = 203 }

  for x = box.minX, box.maxX do
    for z = box.minZ, box.maxZ do
      for y = box.minY, box.maxY do sim.setBlock(x, y, z, "minecraft:stone") end
      sim.setBlock(x, box.maxY + 1, z, "minecraft:obsidian")
    end
  end
  for x = box.minX - 1, box.maxX + 1 do
    for z = box.minZ - 1, box.maxZ + 1 do
      for y = box.minY - 1, box.maxY + 2 do
        if x < box.minX or x > box.maxX or z < box.minZ or z > box.maxZ then
          sim.setBlock(x, y, z, "minecraft:obsidian")
        end
      end
    end
  end

  local coordPos = { x = box.maxX + 4, y = box.maxY, z = box.minZ + 1 }
  sim.setBlock(coordPos.x, coordPos.y, coordPos.z, "computercraft:computer_normal")
  local chest = sim.addChest(coordPos.x + 1, coordPos.y, coordPos.z)
  chest.size = 54
  local MATERIAL = "minecraft:cobblestone"
  for _ = 1, 4 do chest.slots[#chest.slots + 1] = { name = "minecraft:coal", count = 64 } end
  for _ = 1, 8 do chest.slots[#chest.slots + 1] = { name = MATERIAL, count = 64 } end

  local coord = sim.addMachine({ id = 1, name = "coord", pos = coordPos, console = {},
    adjacentChest = { list = function() return {} end } })
  sim.boot(coord, "coordinator", {})
  sim.run(5)
  markCorners(sim, box)

  -- Left outside, where a turtle would actually be put.
  local w = sim.addMachine({ id = 270, name = "sealed", isTurtle = true,
    pos = { x = coordPos.x - 1, y = box.maxY, z = box.minZ }, facing = 3,
    slots = { [1] = { name = "minecraft:coal", count = 16 } }, fuel = 0 })
  sim.boot(w, "flatten", {})

  table.insert(coord.console, "mode fill")
  table.insert(coord.console, "material " .. MATERIAL)
  table.insert(coord.console, "start")
  sim.run(40000, function() return not w.alive end)
  table.insert(coord.console, "status")
  sim.run(sim.now() + 10)

  local air = 0
  for x = box.minX, box.maxX do
    for y = box.minY, box.maxY do
      for z = box.minZ, box.maxZ do
        if sim.getBlock(x, y, z) == nil then air = air + 1 end
      end
    end
  end

  local log = table.concat(coord.log, "\n")
  local writtenOff = tonumber(log:match("(%d+) written off")) or 0
  check(air == 0 or writtenOff > 0,
    ("it did not quietly leave holes (%d empty, %d written off)")
      :format(air, writtenOff))
  check(log:find("beaten us", 1, true) ~= nil or air == 0,
    "and said so when it finished")
end

--------------------------------------------------------------------------
print("\n=== filling with only one way in and out ===")
--------------------------------------------------------------------------
do
  -- A ceiling on the area and the whole strip beside the road bricked up
  -- bar a single square - the way to the store. The road cannot be
  -- approached from alongside because there is no alongside; it has to be
  -- entered at that one square and walked up from there, filling itself
  -- behind as it retreats back towards it.
  local sim = freshSim()
  local box = { minX = 100, maxX = 104, minY = 61, maxY = 64, minZ = 200, maxZ = 204 }
  local MOUTH_Z = box.minZ + 1

  for x = box.minX, box.maxX do
    for z = box.minZ, box.maxZ do
      for y = box.minY, box.maxY do sim.setBlock(x, y, z, "minecraft:stone") end
      sim.setBlock(x, box.maxY + 1, z, "minecraft:obsidian")
    end
  end

  -- The strip beside the road, solid except the one square by the store.
  local wall = {}
  for z = box.minZ - 1, box.maxZ + 1 do
    if z ~= MOUTH_Z then
      for y = box.minY - 1, box.maxY + 2 do
        sim.setBlock(box.maxX + 1, y, z, "minecraft:obsidian")
        wall[#wall + 1] = { x = box.maxX + 1, y = y, z = z }
      end
    end
  end

  local coordPos = { x = box.maxX + 3, y = box.maxY, z = MOUTH_Z }
  sim.setBlock(coordPos.x, coordPos.y, coordPos.z, "computercraft:computer_normal")
  local chest = sim.addChest(coordPos.x + 1, coordPos.y, coordPos.z)
  chest.size = 54
  local MATERIAL = "minecraft:cobblestone"
  for _ = 1, 4 do chest.slots[#chest.slots + 1] = { name = "minecraft:coal", count = 64 } end
  for _ = 1, 12 do chest.slots[#chest.slots + 1] = { name = MATERIAL, count = 64 } end

  local coord = sim.addMachine({ id = 1, name = "coord", pos = coordPos, console = {},
    adjacentChest = { list = function() return {} end } })
  sim.boot(coord, "coordinator", {})
  sim.run(5)
  markCorners(sim, box)

  sim.setBlock(box.maxX, box.maxY, MOUTH_Z, nil)
  local w = sim.addMachine({ id = 280, name = "onewayin", isTurtle = true,
    pos = { x = box.maxX, y = box.maxY, z = MOUTH_Z }, facing = 1,
    slots = { [1] = { name = "minecraft:coal", count = 16 } }, fuel = 0 })
  sim.boot(w, "flatten", {})

  table.insert(coord.console, "mode fill")
  table.insert(coord.console, "material " .. MATERIAL)
  table.insert(coord.console, "start")
  sim.run(40000, function() return not w.alive end)

  local air, wrong = 0, 0
  for x = box.minX, box.maxX do
    for y = box.minY, box.maxY do
      for z = box.minZ, box.maxZ do
        local b = sim.getBlock(x, y, z)
        if b == nil then air = air + 1
        elseif b ~= MATERIAL then wrong = wrong + 1 end
      end
    end
  end
  local gaps = {}
  for x = box.minX, box.maxX do
    for y = box.minY, box.maxY do
      for z = box.minZ, box.maxZ do
        if sim.getBlock(x, y, z) == nil then gaps[#gaps+1] = ("%d,%d,%d"):format(x,y,z) end
      end
    end
  end
  if #gaps > 0 then print("        gaps: " .. table.concat(gaps, "  ") .. "  (mouth z=" .. MOUTH_Z .. ", road x=" .. box.maxX .. ")") end
  check(air == 0, ("it filled every block (%d empty)"):format(air))
  check(wrong == 0, ("all of it the right block (%d wrong)"):format(wrong))

  local broken = 0
  for _, b in ipairs(wall) do
    if sim.getBlock(b.x, b.y, b.z) ~= "minecraft:obsidian" then broken = broken + 1 end
  end
  check(broken == 0, ("and the wall is untouched (%d of %d)"):format(broken, #wall))
end

--------------------------------------------------------------------------
print("\n=== turning the floor off ===")
--------------------------------------------------------------------------
do
  -- Capping a hole under a cleared column is the one thing a turtle does
  -- outside the marked area. It is on by default because a floor is
  -- usually what you want, but it can be switched off, and then nothing at
  -- all is laid outside what was marked.
  local sim = freshSim()
  local box = { minX = 100, maxX = 103, minY = 62, maxY = 64, minZ = 200, maxZ = 203 }
  local coordPos = buildWorld(sim, box)

  -- Open ground under every column.
  local holes = {}
  for x = box.minX, box.maxX do
    for z = box.minZ, box.maxZ do
      sim.setBlock(x, box.minY - 1, z, nil)
      holes[#holes + 1] = { x = x, z = z }
    end
  end

  local coord = sim.addMachine({ id = 1, name = "coord", pos = coordPos, console = {},
    adjacentChest = { list = function() return {} end } })
  sim.boot(coord, "coordinator", {})
  sim.run(5)
  markCorners(sim, box)

  local w = sim.addMachine({ id = 290, name = "nofloor", isTurtle = true,
    pos = { x = box.maxX + 1, y = box.maxY, z = box.minZ }, facing = 3,
    slots = { [1] = { name = "minecraft:coal", count = 16 } }, fuel = 0 })
  sim.boot(w, "flatten", {})

  table.insert(coord.console, "floor off")
  table.insert(coord.console, "start")
  sim.run(20000, function() return not w.alive end)

  local capped = 0
  for _, h in ipairs(holes) do
    if sim.getBlock(h.x, box.minY - 1, h.z) ~= nil then capped = capped + 1 end
  end
  check(capped == 0,
    ("nothing was laid under the area (%d of %d holes capped)")
      :format(capped, #holes))
  check(cleared(sim, box) == 0,
    ("and the area was still cleared (%d blocks left)"):format(cleared(sim, box)))
end

--------------------------------------------------------------------------
print("\n=== three turtles filling at once ===")
--------------------------------------------------------------------------
do
  -- Filling has only ever been tried one turtle at a time. Several of them
  -- have to keep out of each other's way while each is laying solid ground
  -- behind itself, and only one of them may ever be on the road.
  local sim = freshSim()
  local box = { minX = 100, maxX = 107, minY = 60, maxY = 64, minZ = 200, maxZ = 207 }
  local coordPos, chest = buildWorld(sim, box)

  local MATERIAL = "minecraft:cobblestone"
  for _ = 1, 30 do chest.slots[#chest.slots + 1] = { name = MATERIAL, count = 64 } end
  for _ = 1, 8 do chest.slots[#chest.slots + 1] = { name = "minecraft:coal", count = 64 } end

  local coord = sim.addMachine({ id = 1, name = "coord", pos = coordPos, console = {},
    adjacentChest = { list = function() return {} end } })
  sim.boot(coord, "coordinator", {})
  sim.run(5)
  markCorners(sim, box)

  local crew = {}
  for i = 1, 3 do
    local w = sim.addMachine({ id = 300 + i, name = "f" .. (300 + i), isTurtle = true,
      pos = { x = box.maxX + 1, y = box.maxY, z = box.minZ + i - 1 }, facing = 3,
      slots = { [1] = { name = "minecraft:coal", count = 16 } }, fuel = 0 })
    crew[i] = w
    sim.boot(w, "flatten", {})
  end

  table.insert(coord.console, "mode fill")
  table.insert(coord.console, "material " .. MATERIAL)
  table.insert(coord.console, "start")
  sim.run(60000, function()
    for _, w in ipairs(crew) do if w.alive then return false end end
    return true
  end)

  for _, w in ipairs(crew) do
    check(not w.crash, w.name .. " did not crash"
      .. (w.crash and (": " .. tostring(w.crash)) or ""))
  end

  local air, wrong = 0, 0
  for x = box.minX, box.maxX do
    for y = box.minY, box.maxY do
      for z = box.minZ, box.maxZ do
        local b = sim.getBlock(x, y, z)
        if b == nil then air = air + 1
        elseif b ~= MATERIAL then wrong = wrong + 1 end
      end
    end
  end
  check(air == 0, ("they filled every block (%d empty)"):format(air))
  check(wrong == 0, ("all of it the right block (%d wrong)"):format(wrong))

  local bumps = 0
  for _, w in ipairs(crew) do bumps = bumps + w.bumps end
  print(("        %d collisions between them"):format(bumps))
end

--------------------------------------------------------------------------
print("\n=== a fleet far too big for the job ===")
--------------------------------------------------------------------------
do
  -- Eight turtles on an area that has room for one or two. The ones there
  -- is no work for should be told so and clear off out of the area, rather
  -- than hovering over it getting in the way of the ones that are working.
  local sim = freshSim()
  local box = { minX = 100, maxX = 102, minY = 62, maxY = 64, minZ = 200, maxZ = 202 }
  local coordPos = buildWorld(sim, box)

  local coord = sim.addMachine({ id = 1, name = "coord", pos = coordPos, console = {},
    adjacentChest = { list = function() return {} end } })
  sim.boot(coord, "coordinator", {})
  sim.run(5)
  markCorners(sim, box)

  local crew = {}
  for i = 1, 8 do
    local w = sim.addMachine({ id = 310 + i, name = "t" .. (310 + i), isTurtle = true,
      pos = { x = box.maxX + 1, y = box.maxY, z = box.minZ + ((i - 1) % 3) },
      facing = 3,
      slots = { [1] = { name = "minecraft:coal", count = 16 } }, fuel = 0 })
    crew[i] = w
    sim.boot(w, "flatten", {})
  end
  table.insert(coord.console, "start")

  -- Catch them mid-job and see where the idle ones are standing.
  sim.run(20000, function()
    local working = 0
    for _, w in ipairs(crew) do if w.digs > 0 then working = working + 1 end end
    return working >= 2
  end)
  sim.run(sim.now() + 60)

  local inside = 0
  for _, w in ipairs(crew) do
    if w.alive
       and w.pos.x >= box.minX and w.pos.x <= box.maxX
       and w.pos.z >= box.minZ and w.pos.z <= box.maxZ then
      inside = inside + 1
    end
  end
  check(inside <= 2,
    ("the spare turtles got out of the area (%d still over it)"):format(inside))

  local toldOff = 0
  for _, w in ipairs(crew) do
    for _, line in ipairs(w.log) do
      if line:find("standing clear", 1, true) then toldOff = toldOff + 1 break end
    end
  end
  check(toldOff > 0, ("and were told why (%d stood down)"):format(toldOff))

  sim.run(60000, function()
    for _, w in ipairs(crew) do if w.alive then return false end end
    return true
  end)
  check(cleared(sim, box) == 0,
    ("and the job still finished (%d blocks left)"):format(cleared(sim, box)))
end

--------------------------------------------------------------------------
print("\n=== too big a fleet, under a ceiling ===")
--------------------------------------------------------------------------
do
  -- Same crowd, but with something built over the area. There is no above
  -- to stand down into, so a turtle that goes looking for one spends the
  -- rest of the job trying to climb into a ceiling. They have to leave
  -- sideways, at the height the job is worked at.
  local sim = freshSim()
  local box = { minX = 100, maxX = 102, minY = 62, maxY = 64, minZ = 200, maxZ = 202 }
  local coordPos = buildWorld(sim, box)

  for x = box.minX, box.maxX do
    for z = box.minZ, box.maxZ do
      for y = box.maxY + 1, box.maxY + 4 do
        sim.setBlock(x, y, z, "minecraft:obsidian")
      end
    end
  end

  local coord = sim.addMachine({ id = 1, name = "coord", pos = coordPos, console = {},
    adjacentChest = { list = function() return {} end } })
  sim.boot(coord, "coordinator", {})
  sim.run(5)
  markCorners(sim, box)

  local crew = {}
  for i = 1, 6 do
    local w = sim.addMachine({ id = 320 + i, name = "r" .. (320 + i), isTurtle = true,
      pos = { x = box.maxX + 1, y = box.maxY, z = box.minZ + ((i - 1) % 3) },
      facing = 3,
      slots = { [1] = { name = "minecraft:coal", count = 16 } }, fuel = 0 })
    crew[i] = w
    sim.boot(w, "flatten", {})
  end
  table.insert(coord.console, "start")

  sim.run(20000, function()
    local working = 0
    for _, w in ipairs(crew) do if w.digs > 0 then working = working + 1 end end
    return working >= 2
  end)
  sim.run(sim.now() + 90)

  local stuckHigh, inside = 0, 0
  for _, w in ipairs(crew) do
    if w.alive then
      if w.pos.y > box.maxY then stuckHigh = stuckHigh + 1 end
      if w.pos.x >= box.minX and w.pos.x <= box.maxX
         and w.pos.z >= box.minZ and w.pos.z <= box.maxZ then
        inside = inside + 1
      end
    end
  end
  check(stuckHigh == 0,
    ("none of them tried to wait above the ceiling (%d did)"):format(stuckHigh))
  check(inside <= 2,
    ("the spare ones left the area (%d still over it)"):format(inside))

  sim.run(60000, function()
    for _, w in ipairs(crew) do if w.alive then return false end end
    return true
  end)
  table.insert(coord.console, "status")
  sim.run(sim.now() + 10)
  for _, l in ipairs(coord.log) do if l:find("skipped") then print("        | " .. l) end end
  check(cleared(sim, box) == 0,
    ("and the job finished (%d blocks left)"):format(cleared(sim, box)))

  local broken = 0
  for x = box.minX, box.maxX do
    for z = box.minZ, box.maxZ do
      for y = box.maxY + 1, box.maxY + 4 do
        if sim.getBlock(x, y, z) ~= "minecraft:obsidian" then broken = broken + 1 end
      end
    end
  end
  check(broken == 0, ("and the ceiling is untouched (%d broken)"):format(broken))
end

--------------------------------------------------------------------------
print("\n=== clearing a decent-sized area under a ceiling ===")
--------------------------------------------------------------------------
do
  -- Clearing needs no road: it opens the area up as it goes, so a finished
  -- column is air you can walk through. But it is worked under the same
  -- ceiling and by the same movement, so it wants checking at a size where
  -- turtles have to travel across their own work to get anywhere.
  local sim = freshSim()
  local box = { minX = 100, maxX = 107, minY = 58, maxY = 64, minZ = 200, maxZ = 207 }
  local coordPos, chest = buildWorld(sim, box)

  local roof = {}
  for x = box.minX, box.maxX do
    for z = box.minZ, box.maxZ do
      for y = box.maxY + 1, box.maxY + 3 do
        sim.setBlock(x, y, z, "minecraft:obsidian")
        roof[#roof + 1] = { x = x, y = y, z = z }
      end
    end
  end

  local coord = sim.addMachine({ id = 1, name = "coord", pos = coordPos, console = {},
    adjacentChest = { list = function() return {} end } })
  sim.boot(coord, "coordinator", {})
  sim.run(5)
  markCorners(sim, box)

  local crew = {}
  for i = 1, 2 do
    local w = sim.addMachine({ id = 330 + i, name = "c" .. (330 + i), isTurtle = true,
      pos = { x = box.maxX + 1, y = box.maxY, z = box.minZ + i - 1 }, facing = 3,
      slots = { [1] = { name = "minecraft:coal", count = 16 } }, fuel = 0 })
    crew[i] = w
    sim.boot(w, "flatten", {})
  end
  table.insert(coord.console, "start")
  sim.run(60000, function()
    for _, w in ipairs(crew) do if w.alive then return false end end
    return true
  end)

  for _, w in ipairs(crew) do
    check(not w.crash, w.name .. " did not crash"
      .. (w.crash and (": " .. tostring(w.crash)) or ""))
  end
  check(cleared(sim, box) == 0,
    ("they cleared all %d columns under it (%d blocks left)")
      :format((box.maxX - box.minX + 1) * (box.maxZ - box.minZ + 1), cleared(sim, box)))

  local broken = 0
  for _, r in ipairs(roof) do
    if sim.getBlock(r.x, r.y, r.z) ~= "minecraft:obsidian" then broken = broken + 1 end
  end
  check(broken == 0, ("and the ceiling is untouched (%d of %d)"):format(broken, #roof))
end

--------------------------------------------------------------------------
print("\n=== clearing an area with lava in it ===")
--------------------------------------------------------------------------
do
  -- Lava is not something a turtle can dig, and it cannot even see it -
  -- detect returns false, so it swims through and leaves the lot behind.
  -- The sources have to be plugged with a block instead. Flows are left
  -- alone deliberately: plug one and it refills from whatever is feeding
  -- it, while pulling the sources drains them for nothing.
  local sim = freshSim()
  local box = { minX = 100, maxX = 104, minY = 61, maxY = 64, minZ = 200, maxZ = 204 }
  local coordPos, chest = buildWorld(sim, box)

  local sources, flows = {}, {}
  for x = box.minX, box.maxX do
    for z = box.minZ, box.maxZ do
      if (x + z) % 3 == 0 then
        -- A source part way down the column, with a flow above it.
        sim.setBlock(x, box.minY + 1, z, nil)
        sim.setFluid(x, box.minY + 1, z, "minecraft:lava", 0)
        sources[#sources + 1] = { x = x, y = box.minY + 1, z = z }

        sim.setBlock(x, box.minY + 2, z, nil)
        sim.setFluid(x, box.minY + 2, z, "minecraft:lava", 2)
        flows[#flows + 1] = { x = x, y = box.minY + 2, z = z }
      end
    end
  end

  -- Dirt in the store, since plugging costs a block per source.
  for _ = 1, 4 do
    chest.slots[#chest.slots + 1] = { name = "minecraft:dirt", count = 64 }
  end

  local coord = sim.addMachine({ id = 1, name = "coord", pos = coordPos, console = {},
    adjacentChest = { list = function() return {} end } })
  sim.boot(coord, "coordinator", {})
  sim.run(5)
  markCorners(sim, box)

  local w = sim.addMachine({ id = 410, name = "lava", isTurtle = true,
    pos = { x = box.maxX + 1, y = box.maxY, z = box.minZ }, facing = 3,
    slots = { [1] = { name = "minecraft:coal", count = 16 } }, fuel = 0 })
  sim.boot(w, "flatten", {})
  table.insert(coord.console, "start")
  sim.run(40000, function() return not w.alive end)

  check(not w.crash, "it did not crash" .. (w.crash and (": " .. tostring(w.crash)) or ""))

  local sourcesLeft = 0
  for _, f in ipairs(sources) do
    if sim.getFluid(f.x, f.y, f.z) then sourcesLeft = sourcesLeft + 1 end
  end
  check(sourcesLeft == 0,
    ("every lava source was plugged (%d of %d left)"):format(sourcesLeft, #sources))

  check(cleared(sim, box) == 0,
    ("and the area came out empty (%d blocks left)"):format(cleared(sim, box)))
  print(("        %d sources, %d flows"):format(#sources, #flows))
end

--------------------------------------------------------------------------
print("\n=== draining a lava pool without digging the place up ===")
--------------------------------------------------------------------------
do
  -- A pool of lava sitting in a hollow. Draining takes the lava out and
  -- leaves everything else exactly where it is - no excavating, no floor
  -- laid, nothing but the fluid gone.
  local sim = freshSim()
  local box = { minX = 100, maxX = 105, minY = 60, maxY = 64, minZ = 200, maxZ = 205 }
  local coordPos, chest = buildWorld(sim, box)

  -- Hollow the area out and pour lava into the bottom of it.
  local stone, pool = {}, {}
  for x = box.minX, box.maxX do
    for z = box.minZ, box.maxZ do
      for y = box.minY, box.maxY do sim.setBlock(x, y, z, nil) end
      -- A rim of stone round the edge that must not be touched.
      if x == box.minX or x == box.maxX or z == box.minZ or z == box.maxZ then
        for y = box.minY, box.maxY do sim.setBlock(x, y, z, "minecraft:stone") end
      else
        sim.setFluid(x, box.minY, z, "minecraft:lava", 0)
        pool[#pool + 1] = { x = x, y = box.minY, z = z }
        sim.setFluid(x, box.minY + 1, z, "minecraft:lava", 3)
      end
    end
  end

  for _ = 1, 4 do
    chest.slots[#chest.slots + 1] = { name = "minecraft:dirt", count = 64 }
  end

  local coord = sim.addMachine({ id = 1, name = "coord", pos = coordPos, console = {},
    adjacentChest = { list = function() return {} end } })
  sim.boot(coord, "coordinator", {})
  sim.run(5)
  markCorners(sim, box)

  -- Snapshot the rim now, after marking: standing the marker turtle in the
  -- corners takes those two blocks out, and that is the harness doing it.
  for x = box.minX, box.maxX do
    for z = box.minZ, box.maxZ do
      for y = box.minY, box.maxY do
        if sim.getBlock(x, y, z) == "minecraft:stone" then
          stone[#stone + 1] = { x = x, y = y, z = z }
        end
      end
    end
  end

  local w = sim.addMachine({ id = 420, name = "drainer", isTurtle = true,
    pos = { x = box.maxX + 1, y = box.maxY, z = box.minZ }, facing = 3,
    slots = { [1] = { name = "minecraft:coal", count = 16 } }, fuel = 0 })
  sim.boot(w, "flatten", {})

  table.insert(coord.console, "mode drain")
  table.insert(coord.console, "start")
  sim.run(40000, function() return not w.alive end)

  check(not w.crash, "it did not crash" .. (w.crash and (": " .. tostring(w.crash)) or ""))

  local left = 0
  for _, f in ipairs(pool) do
    if sim.getFluid(f.x, f.y, f.z) then left = left + 1 end
  end
  check(left == 0, ("the pool was drained (%d of %d sources left)"):format(left, #pool))

  local disturbed = 0
  for _, b in ipairs(stone) do
    if sim.getBlock(b.x, b.y, b.z) ~= "minecraft:stone" then disturbed = disturbed + 1 end
  end
  check(disturbed == 0,
    ("and the ground round it is untouched (%d of %d dug)"):format(disturbed, #stone))

  local plugsLeft = 0
  for _, f in ipairs(pool) do
    if sim.getBlock(f.x, f.y, f.z) then plugsLeft = plugsLeft + 1 end
  end
  check(plugsLeft == 0,
    ("and it took its plugs back out (%d left behind)"):format(plugsLeft))

  local log = table.concat(coord.log, "\n")
  print("        " .. (log:match("pass %d+ plugged %d+[^\n]*") or "(one pass)"))
end

--------------------------------------------------------------------------
print("\n=== filling with dirt without stripping the grass ===")
--------------------------------------------------------------------------
do
  -- Naming more than one block: the first is what gets laid into empty
  -- space, the rest count as good enough where they already are. Filling a
  -- plot with dirt has no business taking the grass off the top of it.
  local sim = freshSim()
  local box = { minX = 100, maxX = 104, minY = 61, maxY = 64, minZ = 200, maxZ = 204 }
  local coordPos, chest = buildWorld(sim, box)

  for x = box.minX, box.maxX do
    for z = box.minZ, box.maxZ do
      sim.setBlock(x, box.maxY, z, "minecraft:grass_block")
      for y = box.minY, box.maxY - 1 do
        if (x + y + z) % 2 == 0 then sim.setBlock(x, y, z, nil)
        else sim.setBlock(x, y, z, "minecraft:andesite") end
      end
    end
  end

  for _ = 1, 12 do
    chest.slots[#chest.slots + 1] = { name = "minecraft:dirt", count = 64 }
  end

  local coord = sim.addMachine({ id = 1, name = "coord", pos = coordPos, console = {},
    adjacentChest = { list = function() return {} end } })
  sim.boot(coord, "coordinator", {})
  sim.run(5)
  markCorners(sim, box)

  -- Counted after marking: standing the marker turtle in a corner takes
  -- that block out, and that is the harness rather than the job.
  local grass = {}
  for x = box.minX, box.maxX do
    for z = box.minZ, box.maxZ do
      if sim.getBlock(x, box.maxY, z) == "minecraft:grass_block" then
        grass[#grass + 1] = { x = x, z = z }
      end
    end
  end

  local w = sim.addMachine({ id = 430, name = "grassy", isTurtle = true,
    pos = { x = box.maxX + 1, y = box.maxY, z = box.minZ }, facing = 3,
    slots = { [1] = { name = "minecraft:coal", count = 16 } }, fuel = 0 })
  sim.boot(w, "flatten", {})

  table.insert(coord.console, "mode fill")
  table.insert(coord.console, "material minecraft:dirt minecraft:grass_block")
  table.insert(coord.console, "start")
  sim.run(40000, function() return not w.alive end)

  check(not w.crash, "it did not crash" .. (w.crash and (": " .. tostring(w.crash)) or ""))

  local lost = 0
  for _, g in ipairs(grass) do
    if sim.getBlock(g.x, box.maxY, g.z) ~= "minecraft:grass_block" then lost = lost + 1 end
  end
  check(lost == 0, ("the grass is still on top (%d of %d gone)"):format(lost, #grass))

  local air, wrong = 0, 0
  for x = box.minX, box.maxX do
    for y = box.minY, box.maxY - 1 do
      for z = box.minZ, box.maxZ do
        local b = sim.getBlock(x, y, z)
        if b == nil then air = air + 1
        elseif b ~= "minecraft:dirt" then wrong = wrong + 1 end
      end
    end
  end
  check(air == 0, ("and everything under it is solid (%d empty)"):format(air))
  check(wrong == 0, ("all of it dirt (%d wrong)"):format(wrong))
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
