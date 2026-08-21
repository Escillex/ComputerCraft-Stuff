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
  check(table.concat(coord.log, "\n"):find("chest found", 1, true) ~= nil,
    "it found its way over to the chest")
  check(broken == 0, ("the wall was left standing (%d of %d blocks broken)")
    :format(broken, #wall))
  check(cleared(sim, box) == 0,
    ("it still cleared the marked area (%d blocks left)"):format(cleared(sim, box)))
  print(("        %d moves, %d digs"):format(w.moves, w.digs))
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
