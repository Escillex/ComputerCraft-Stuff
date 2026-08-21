-- flatten.lua
--
-- flatten <x1> <y1> <z1> <x2> <y2> <z2> [homeX homeY homeZ homeDir]   (absolute, needs GPS)
-- flatten <n1> <n2> <n3> <dir1> <dir2> <dir3> [homeBack homeDir homeExtra]  (relative, no GPS needed)
-- flatten fleet   (registers with a coordinator, see coordinator.lua)
-- flatten         (prompts for whichever mode applies)
--
-- Absolute mode: corners are real F3 coordinates, like WorldEdit //pos1
-- //pos2. Auto-detected from 6 numeric args vs 3 numbers + 3 direction
-- words. homeDir is a compass word (north/south/east/west/up/down).
--
-- Relative mode: each number is tagged forward/back/left/right/up/down (or
-- f/b/l/r/u/d) relative to the turtle's facing when started. Must cover all
-- three axes once. `flatten 100 20 50 forward up right` = 100 forward, 20
-- up, 50 right of the start tile.
--
-- Digs the box, lays one layer of fill blocks past the bottom edge.
--
-- Resupply chest: 1 block behind the start by default, same height. In
-- absolute mode [homeX homeY homeZ homeDir] gives the park spot's real
-- coordinates + compass direction to the chest. In relative mode
-- [homeBack homeDir homeExtra] gives distance behind start, direction, and
-- extra offset (default down/1/0). Chest is always one block from the park
-- spot in homeDir. Refuses to start if the chest would land inside the box.
--
-- Setup: chest/barrel/vault one block from the park spot, in homeDir.
-- Stock with dirt/cobblestone (fill) and coal/charcoal (fuel), mixed ok.

----------------------------------------------------------------------
-- Config
----------------------------------------------------------------------

-- dirt used ahead of cobblestone whenever both are available
local FILL_PRIORITY = { "minecraft:dirt", "minecraft:cobblestone" }
local FILL_ITEMS = {}
for _, name in ipairs(FILL_PRIORITY) do FILL_ITEMS[name] = true end

local FUEL_LOW = 5        -- trip to chest below this
local FUEL_TARGET = 1000  -- top up to this
local FILL_LOW = 8        -- trip to chest below this
local FILL_TARGET = 64    -- top up to this
local FILL_KEEP_MAX = 128 -- cap on hoarded fill material from ordinary mining; excess dumps as junk
local DIG_RETRY_LIMIT = 20
local DEBUG = true

local function log(fmt, ...)
  if DEBUG then
    print(("[flatten] " .. fmt):format(...))
  end
end

----------------------------------------------------------------------
-- State: dead-reckoned position/facing relative to the start tile
----------------------------------------------------------------------

local pos = { x = 0, y = 0, z = 0 }
local facing = 0 -- 0..3, 0 = original facing
local DIRS = {
  [0] = { x = 0, z = 1 },
  [1] = { x = 1, z = 0 },
  [2] = { x = 0, z = -1 },
  [3] = { x = -1, z = 0 },
}

-- facing field only used for the horizontal entries (turn target for chestSide etc.)
local AXIS_DIR = {
  forward = { axis = "z", sign = 1, facing = 0 },
  f = { axis = "z", sign = 1, facing = 0 },
  back = { axis = "z", sign = -1, facing = 2 },
  backward = { axis = "z", sign = -1, facing = 2 },
  b = { axis = "z", sign = -1, facing = 2 },
  right = { axis = "x", sign = 1, facing = 1 },
  r = { axis = "x", sign = 1, facing = 1 },
  left = { axis = "x", sign = -1, facing = 3 },
  l = { axis = "x", sign = -1, facing = 3 },
  up = { axis = "y", sign = 1 },
  u = { axis = "y", sign = 1 },
  down = { axis = "y", sign = -1 },
  d = { axis = "y", sign = -1 },
}

----------------------------------------------------------------------
-- GPS (optional). Falls back to dead-reckoning-only if unavailable.
----------------------------------------------------------------------

local GPS_TIMEOUT = 2

local function gpsLocate()
  if not gps then return nil end
  local ok, x, y, z = pcall(gps.locate, GPS_TIMEOUT)
  if not ok or not x then return nil end
  return { x = x, y = y, z = z }
end

-- matches how internal facing rotates via turnRight
local function rotateWorldVectorCW(v)
  return { x = v.z, z = -v.x }
end

-- Moves forward+back to measure which world direction is facing 0, via two
-- GPS fixes. Tries all 4 sides (never digs) in case boxed in on the
-- original facing, e.g. sitting in a tunnel. Always restores exact facing.
local function measureGpsFacing()
  local before = gpsLocate()
  if not before then return nil end

  for turnsFromStart = 0, 3 do
    if not turtle.detect() and turtle.forward() then
      local after = gpsLocate()
      for _ = 1, 5 do
        if turtle.back() then break end
      end
      for _ = 1, (4 - turnsFromStart) % 4 do turtle.turnRight() end
      if not after then return nil end
      local v = { x = after.x - before.x, z = after.z - before.z }
      if math.abs(v.x) + math.abs(v.z) ~= 1 then return nil end
      for _ = 1, (4 - turnsFromStart) % 4 do v = rotateWorldVectorCW(v) end
      return v
    end
    turtle.turnRight()
  end
  return nil
end

local function gpsFix()
  local pos1 = gpsLocate()
  if not pos1 then return nil, nil end
  local facingVec = measureGpsFacing()
  if not facingVec then return nil, nil end
  local finalPos = gpsLocate() or pos1
  return finalPos, facingVec
end

local function worldDeltaToRelative(dx, dz, originVec)
  local relX = originVec.z * dx - originVec.x * dz
  local relZ = originVec.x * dx + originVec.z * dz
  return relX, relZ
end

local function relativeToWorldDelta(relX, relZ, originVec)
  local dx = originVec.z * relX + originVec.x * relZ
  local dz = -originVec.x * relX + originVec.z * relZ
  return dx, dz
end

local function worldVectorToFacing(originVec, currentVec)
  local v = { x = originVec.x, z = originVec.z }
  for k = 0, 3 do
    if v.x == currentVec.x and v.z == currentVec.z then return k end
    v = rotateWorldVectorCW(v)
  end
  return 0
end

-- compass words for absolute/fleet mode, where forward/back/left/right
-- don't mean anything without a specific turtle's facing
local COMPASS_VECTORS = {
  north = { axis = "z", sign = -1 }, n = { axis = "z", sign = -1 },
  south = { axis = "z", sign = 1 }, s = { axis = "z", sign = 1 },
  east = { axis = "x", sign = 1 }, e = { axis = "x", sign = 1 },
  west = { axis = "x", sign = -1 }, w = { axis = "x", sign = -1 },
  up = { axis = "y", sign = 1 }, u = { axis = "y", sign = 1 },
  down = { axis = "y", sign = -1 }, d = { axis = "y", sign = -1 },
}
local FACING_TO_WORD = { [0] = "forward", [1] = "right", [2] = "back", [3] = "left" }

local function compassToAxisWord(word, facingVec)
  local c = COMPASS_VECTORS[tostring(word):lower()]
  if not c then return nil end
  if c.axis == "y" then
    return c.sign > 0 and "up" or "down"
  end
  local worldVec = { x = 0, z = 0 }
  if c.axis == "x" then worldVec.x = c.sign else worldVec.z = c.sign end
  return FACING_TO_WORD[worldVectorToFacing(facingVec, worldVec)]
end

local gpsOrigin = nil -- { pos = {x,y,z}, facingVec = {x,z} }, set once per job

local HOME = { x = 0, y = 0, z = -1 }
local HOME_CHEST_DIR = "down"

-- fleet mode: resupply requests/releases the chest lock from coordinatorId
local FLEET_PROTOCOL = "flatten_fleet"
local FLEET_MODE = false
local coordinatorId = nil

local forward, up, down, goTo, turnTo, faceAxisDir, maybeResupply

local function chestSide()
  local dir = AXIS_DIR[HOME_CHEST_DIR]
  if dir.axis == "y" then
    return dir.sign > 0 and "up" or "down"
  end
  turnTo(dir.facing)
  return "front"
end

local function chestWrap()
  local side = chestSide()
  local chest = peripheral.wrap(side)
  if not chest then
    error("No inventory found " .. HOME_CHEST_DIR .. " of the turtle's resupply position.")
  end
  return chest
end

local function chestSuck(count)
  local side = chestSide()
  if side == "up" then return turtle.suckUp(count) end
  if side == "down" then return turtle.suckDown(count) end
  return turtle.suck(count)
end

local function chestDrop(count)
  local side = chestSide()
  if side == "up" then return turtle.dropUp(count) end
  if side == "down" then return turtle.dropDown(count) end
  return turtle.drop(count)
end

local function chestPosition()
  local dir = AXIS_DIR[HOME_CHEST_DIR]
  local x, y, z = HOME.x, HOME.y, HOME.z
  if dir.axis == "x" then x = x + dir.sign
  elseif dir.axis == "y" then y = y + dir.sign
  else z = z + dir.sign end
  return x, y, z
end

local resupplying = false

----------------------------------------------------------------------
-- Job state persistence - written after every move, offered as a resume
-- point on next run, deleted when the job finishes.
----------------------------------------------------------------------

local STATE_FILE = "flatten_state"
local jobState = nil -- {x1,y1,z1,x2,y2,z2,nextIndex}

local function persist()
  if not jobState then return end
  local f = fs.open(STATE_FILE, "w")
  f.write(textutils.serialize({
    job = jobState,
    pos = { x = pos.x, y = pos.y, z = pos.z },
    facing = facing,
    home = { x = HOME.x, y = HOME.y, z = HOME.z },
    homeChestDir = HOME_CHEST_DIR,
    gpsOrigin = gpsOrigin,
  }))
  f.close()
end

local function loadState()
  if not fs.exists(STATE_FILE) then return nil end
  local f = fs.open(STATE_FILE, "r")
  local data = textutils.unserialize(f.readAll())
  f.close()
  return data
end

local function clearState()
  jobState = nil
  if fs.exists(STATE_FILE) then fs.delete(STATE_FILE) end
end

----------------------------------------------------------------------
-- Item helpers
----------------------------------------------------------------------

local function isFillItem(name) return name ~= nil and FILL_ITEMS[name] == true end

-- refuel(0) checks fuel-ness without consuming - works for any combustible item
local function isFuelSlot(slot)
  if turtle.getItemCount(slot) == 0 then return false end
  turtle.select(slot)
  return turtle.refuel(0)
end

local function countFillItems()
  local total = 0
  for slot = 1, 16 do
    local detail = turtle.getItemDetail(slot)
    if detail and isFillItem(detail.name) then
      total = total + detail.count
    end
  end
  return total
end

local function findEmptySlot()
  for slot = 1, 16 do
    if turtle.getItemCount(slot) == 0 then return slot end
  end
  return nil
end

local function findFillSlot()
  for _, name in ipairs(FILL_PRIORITY) do
    for slot = 1, 16 do
      local detail = turtle.getItemDetail(slot)
      if detail and detail.name == name then return slot end
    end
  end
  return nil
end

local function inventoryFull()
  return findEmptySlot() == nil
end

----------------------------------------------------------------------
-- Home chest
----------------------------------------------------------------------

-- suck() always pulls the chest's first non-empty slot, so a mismatched
-- stack is held (not dropped back) until this returns, forcing later pulls
-- to reach different items. Returns how many matching items were pulled.
local function pullMatching(matchFn, want)
  local chest = chestWrap()
  local pulled = 0
  local size = chest.size()
  local attempts = 0
  local held = {}
  while pulled < want and attempts < size do
    attempts = attempts + 1
    local slot = findEmptySlot()
    if not slot then
      log("pullMatching: no empty turtle slot left, giving up early")
      break
    end
    turtle.select(slot)
    local ok = chestSuck(64)
    if not ok then
      log("pullMatching: chest has nothing left to give")
      break
    end
    local n = turtle.getItemCount(slot)
    local detail = turtle.getItemDetail(slot)
    if matchFn(slot) then
      pulled = pulled + n
      log("pullMatching: kept %d x %s (slot %d, total pulled %d/%d)",
        n, detail and detail.name or "?", slot, pulled, want)
    else
      log("pullMatching: rejected %d x %s (slot %d, not a match)",
        n, detail and detail.name or "?", slot)
      held[#held + 1] = slot
    end
  end
  for _, slot in ipairs(held) do
    turtle.select(slot)
    chestDrop()
  end
  return pulled
end

local function matchFill(slot)
  local detail = turtle.getItemDetail(slot)
  return detail ~= nil and isFillItem(detail.name)
end

-- Returns false if any junk couldn't be dropped (chest full). Fill material
-- capped at FILL_KEEP_MAX so ordinary mining doesn't hoard cobblestone.
local function dumpJunk()
  local allDropped = true
  local fillKept = 0
  for slot = 1, 16 do
    if turtle.getItemCount(slot) > 0 then
      local detail = turtle.getItemDetail(slot)
      local isFill = isFillItem(detail.name)
      local keep
      if isFill then
        keep = fillKept < FILL_KEEP_MAX
        if keep then fillKept = fillKept + detail.count end
      else
        keep = isFuelSlot(slot)
      end
      if not keep then
        turtle.select(slot)
        local dropped = chestDrop()
        if dropped then
          log("dumpJunk: dropped %d x %s (slot %d)", detail.count, detail.name, slot)
        else
          log("dumpJunk: FAILED to drop %d x %s (slot %d) - chest full?", detail.count, detail.name, slot)
          allDropped = false
        end
      end
    end
  end
  return allDropped
end

local function refuelFromInventory()
  local before = turtle.getFuelLevel()
  for slot = 1, 16 do
    if turtle.getFuelLevel() ~= "unlimited" and turtle.getFuelLevel() >= FUEL_TARGET then break end
    if isFuelSlot(slot) then
      while turtle.getItemCount(slot) > 0
        and turtle.getFuelLevel() ~= "unlimited"
        and turtle.getFuelLevel() < FUEL_TARGET do
        turtle.refuel(1)
      end
    end
  end
  if turtle.getFuelLevel() ~= before then
    log("refuelFromInventory: fuel %s -> %s", tostring(before), tostring(turtle.getFuelLevel()))
  end
end

local function needsFuel()
  local level = turtle.getFuelLevel()
  return level ~= "unlimited" and level < FUEL_LOW
end

local function needsFill()
  return countFillItems() < FILL_LOW
end

----------------------------------------------------------------------
-- Liquid plugging + dig-through-obstacles
----------------------------------------------------------------------

local function plugLiquid(inspectFn, placeFn)
  local ok, data = inspectFn()
  if ok and (data.name == "minecraft:water" or data.name == "minecraft:lava") then
    local slot = findFillSlot()
    if slot then
      turtle.select(slot)
      placeFn()
    end
  end
end

local function clearAhead()
  plugLiquid(turtle.inspect, turtle.place)
  local tries = 0
  while turtle.detect() do
    tries = tries + 1
    if tries > DIG_RETRY_LIMIT then
      error("Stuck: could not clear the block ahead after " .. DIG_RETRY_LIMIT .. " tries.")
    end
    if not turtle.dig() then
      turtle.attack()
    end
    sleep(0.4)
  end
end

local function clearBelow()
  plugLiquid(turtle.inspectDown, turtle.placeDown)
  local tries = 0
  while turtle.detectDown() do
    tries = tries + 1
    if tries > DIG_RETRY_LIMIT then
      error("Stuck: could not clear the block below after " .. DIG_RETRY_LIMIT .. " tries.")
    end
    if not turtle.digDown() then
      turtle.attackDown()
    end
    sleep(0.4)
  end
end

local function clearAbove()
  plugLiquid(turtle.inspectUp, turtle.placeUp)
  local tries = 0
  while turtle.detectUp() do
    tries = tries + 1
    if tries > DIG_RETRY_LIMIT then
      error("Stuck: could not clear the block above after " .. DIG_RETRY_LIMIT .. " tries.")
    end
    if not turtle.digUp() then
      turtle.attackUp()
    end
    sleep(0.4)
  end
end

----------------------------------------------------------------------
-- Movement + navigation
----------------------------------------------------------------------

turnTo = function(target)
  while facing ~= target do
    turtle.turnRight()
    facing = (facing + 1) % 4
  end
end

faceAxisDir = function(dx, dz)
  for f, d in pairs(DIRS) do
    if d.x == dx and d.z == dz then
      turnTo(f)
      return
    end
  end
end

maybeResupply = function()
  if resupplying then return end
  if not (needsFuel() or needsFill() or inventoryFull()) then return end

  log("resupply triggered: fuel=%s needsFuel=%s fillCount=%d needsFill=%s inventoryFull=%s",
    tostring(turtle.getFuelLevel()), tostring(needsFuel()), countFillItems(),
    tostring(needsFill()), tostring(inventoryFull()))

  resupplying = true
  local sx, sy, sz, sf = pos.x, pos.y, pos.z, facing

  -- lock must be granted before navigating to the shared spot - two
  -- turtles can't occupy the same block, and obstruction-retry would
  -- attack() whatever's blocking
  if FLEET_MODE then
    log("fleet: requesting chest lock from coordinator...")
    rednet.send(coordinatorId, { type = "chest_request" }, FLEET_PROTOCOL)
    local _, msg = rednet.receive(FLEET_PROTOCOL)
    while not (type(msg) == "table" and msg.type == "chest_granted") do
      _, msg = rednet.receive(FLEET_PROTOCOL)
    end
    log("fleet: chest lock granted")
  end

  goTo(HOME.x, HOME.y, HOME.z)
  local dumped = dumpJunk()
  if not dumped and inventoryFull() then
    error("Resupply chest is full - couldn't deposit junk and the turtle's inventory is still full. " ..
      "Empty the chest and rerun; it will resume from where it left off.")
  end

  refuelFromInventory()
  while turtle.getFuelLevel() ~= "unlimited" and turtle.getFuelLevel() < FUEL_TARGET do
    local got = pullMatching(isFuelSlot, 64)
    if got == 0 then
      if needsFuel() then
        error("Out of fuel: the chest has none left, and the turtle is critically low. Restock it and rerun.")
      end
      log("chest is out of fuel, but current level (%s) is above the low-water mark - continuing", tostring(turtle.getFuelLevel()))
      break
    end
    refuelFromInventory()
  end

  if countFillItems() < FILL_TARGET then
    local got = pullMatching(matchFill, FILL_TARGET - countFillItems())
    log("pulled %d fill blocks from chest, now holding %d", got, countFillItems())
    if got == 0 and countFillItems() == 0 then
      error("Out of fill blocks: the chest has none left. Restock it with dirt/cobblestone and rerun.")
    end
  end

  -- fail here rather than strand the turtle mid-return if fuel's still short
  local tripCost = math.abs(sx - HOME.x) + math.abs(sy - HOME.y) + math.abs(sz - HOME.z)
  local level = turtle.getFuelLevel()
  if level ~= "unlimited" and level < tripCost then
    error(("Refueled to %d, but returning to the job at (%d,%d,%d) needs ~%d fuel. " ..
      "Restock the chest with more fuel and rerun - it will resume from where it left off.")
      :format(level, sx, sy, sz, tripCost))
  end

  log("resupply done: fuel=%s fillCount=%d, returning to job at (%d,%d,%d)",
    tostring(turtle.getFuelLevel()), countFillItems(), sx, sy, sz)
  goTo(sx, sy, sz)
  if FLEET_MODE then
    rednet.send(coordinatorId, { type = "chest_release" }, FLEET_PROTOCOL)
    log("fleet: chest lock released")
  end
  turnTo(sf)
  resupplying = false
end

-- fuel-related move failures: burn more fuel instead of digging/attacking
local function isFuelFailure(reason)
  return reason ~= nil and tostring(reason):lower():find("fuel") ~= nil
end

forward = function()
  maybeResupply()
  clearAhead()
  local tries, ok, reason = 0
  repeat
    ok, reason = turtle.forward()
    if not ok then
      tries = tries + 1
      if tries > DIG_RETRY_LIMIT then
        error("Could not move forward after " .. DIG_RETRY_LIMIT .. " attempts (" .. tostring(reason) .. ").")
      end
      log("forward blocked (%s), retrying %d/%d", tostring(reason), tries, DIG_RETRY_LIMIT)
      if isFuelFailure(reason) then
        refuelFromInventory()
      else
        clearAhead()
        turtle.attack()
      end
      sleep(0.2)
    end
  until ok
  local d = DIRS[facing]
  pos.x = pos.x + d.x
  pos.z = pos.z + d.z
  persist()
end

up = function()
  maybeResupply()
  clearAbove()
  local tries, ok, reason = 0
  repeat
    ok, reason = turtle.up()
    if not ok then
      tries = tries + 1
      if tries > DIG_RETRY_LIMIT then
        error("Could not move up after " .. DIG_RETRY_LIMIT .. " attempts (" .. tostring(reason) .. ").")
      end
      log("up blocked (%s), retrying %d/%d", tostring(reason), tries, DIG_RETRY_LIMIT)
      if isFuelFailure(reason) then
        refuelFromInventory()
      else
        clearAbove()
        turtle.attackUp()
      end
      sleep(0.2)
    end
  until ok
  pos.y = pos.y + 1
  persist()
end

down = function()
  maybeResupply()
  clearBelow()
  local tries, ok, reason = 0
  repeat
    ok, reason = turtle.down()
    if not ok then
      tries = tries + 1
      if tries > DIG_RETRY_LIMIT then
        error("Could not move down after " .. DIG_RETRY_LIMIT .. " attempts (" .. tostring(reason) .. ").")
      end
      log("down blocked (%s), retrying %d/%d", tostring(reason), tries, DIG_RETRY_LIMIT)
      if isFuelFailure(reason) then
        refuelFromInventory()
      else
        clearBelow()
        turtle.attackDown()
      end
      sleep(0.2)
    end
  until ok
  pos.y = pos.y - 1
  persist()
end

goTo = function(tx, ty, tz)
  while pos.y < ty do up() end
  while pos.y > ty do down() end

  if pos.x < tx then
    faceAxisDir(1, 0)
    while pos.x < tx do forward() end
  elseif pos.x > tx then
    faceAxisDir(-1, 0)
    while pos.x > tx do forward() end
  end

  if pos.z < tz then
    faceAxisDir(0, 1)
    while pos.z < tz do forward() end
  elseif pos.z > tz then
    faceAxisDir(0, -1)
    while pos.z > tz do forward() end
  end
end

----------------------------------------------------------------------
-- Dig + fill job
----------------------------------------------------------------------

-- x-major snake, z alternating
local function buildFootprint(minX, maxX, minZ, maxZ)
  local footprint = {}
  local dir = 1
  for x = minX, maxX do
    local zStart, zEnd, zStep
    if dir == 1 then
      zStart, zEnd, zStep = minZ, maxZ, 1
    else
      zStart, zEnd, zStep = maxZ, minZ, -1
    end
    for z = zStart, zEnd, zStep do
      footprint[#footprint + 1] = { x = x, z = z }
    end
    dir = -dir
  end
  return footprint
end

-- layers top to bottom, snake direction alternates per layer so the last
-- cell of one layer sits adjacent to the first cell of the next - one
-- "down" move between layers instead of climbing back to the top
local function buildCellList(minX, maxX, minZ, maxZ, minY, maxY)
  local footprint = buildFootprint(minX, maxX, minZ, maxZ)
  local cells = {}
  local reversed = false
  for y = maxY, minY, -1 do
    if reversed then
      for i = #footprint, 1, -1 do
        cells[#cells + 1] = { x = footprint[i].x, y = y, z = footprint[i].z }
      end
    else
      for i = 1, #footprint do
        cells[#cells + 1] = { x = footprint[i].x, y = y, z = footprint[i].z }
      end
    end
    reversed = not reversed
  end
  return cells
end

local function run(x1, y1, z1, x2, y2, z2, startIndex)
  local minX, maxX = math.min(x1, x2), math.max(x1, x2)
  local minY, maxY = math.min(y1, y2), math.max(y1, y2)
  local minZ, maxZ = math.min(z1, z2), math.max(z1, z2)
  local cells = buildCellList(minX, maxX, minZ, maxZ, minY, maxY)

  jobState = { x1 = x1, y1 = y1, z1 = z1, x2 = x2, y2 = y2, z2 = z2, nextIndex = startIndex or 1 }
  persist()

  log("job: %d cells (%d x %d footprint, %d layers), starting at cell %d",
    #cells, maxX - minX + 1, maxZ - minZ + 1, maxY - minY + 1, jobState.nextIndex)

  local lastLoggedY = nil
  for i = jobState.nextIndex, #cells do
    local c = cells[i]
    if c.y ~= lastLoggedY then
      log("layer y=%d, starting at cell %d/%d", c.y, i, #cells)
      lastLoggedY = c.y
    end

    goTo(c.x, c.y, c.z)

    -- bottom layer only: fill one block down, but only if empty/liquid, never solid ground
    if c.y == minY then
      local ok, data = turtle.inspectDown()
      if not ok or data.name == "minecraft:water" or data.name == "minecraft:lava" then
        local fillSlot = findFillSlot()
        if fillSlot then
          turtle.select(fillSlot)
          turtle.placeDown()
        end
      end
    end

    -- fleet mode: periodic position report, from free dead-reckoning math not a live GPS call
    if FLEET_MODE and gpsOrigin and i % 20 == 0 then
      local wdx, wdz = relativeToWorldDelta(pos.x, pos.z, gpsOrigin.facingVec)
      rednet.send(coordinatorId, {
        type = "pos",
        x = gpsOrigin.pos.x + wdx, y = gpsOrigin.pos.y + pos.y, z = gpsOrigin.pos.z + wdz,
        cell = i, total = #cells,
      }, FLEET_PROTOCOL)
    end

    jobState.nextIndex = i + 1
    persist()
  end

  if FLEET_MODE then
    rednet.send(coordinatorId, { type = "chest_request" }, FLEET_PROTOCOL)
    local _, msg = rednet.receive(FLEET_PROTOCOL)
    while not (type(msg) == "table" and msg.type == "chest_granted") do
      _, msg = rednet.receive(FLEET_PROTOCOL)
    end
  end
  goTo(HOME.x, HOME.y, HOME.z)
  turnTo(0)
  if not dumpJunk() then
    print("Note: the chest is full - some leftover junk is still in the turtle's inventory.")
  end
  if FLEET_MODE then
    rednet.send(coordinatorId, { type = "chest_release" }, FLEET_PROTOCOL)
  end
  clearState()
  print("Done.")
end

----------------------------------------------------------------------
-- Input
----------------------------------------------------------------------

local function readNumber(promptText)
  while true do
    io.write(promptText .. ": ")
    local input = read()
    local n = tonumber(input)
    if n and n >= 1 then return math.floor(n + 0.5) end
    print("Please enter a whole number of at least 1.")
  end
end

local function readNumberDefault(promptText, default)
  io.write(("%s (blank = %d): "):format(promptText, default))
  local input = read()
  if not input or input:match("^%s*$") then return default end
  local n = tonumber(input)
  if not n or n < 0 then
    print("Couldn't parse that, using default (" .. default .. ").")
    return default
  end
  return math.floor(n + 0.5)
end

local function readCoordTriple(promptText)
  while true do
    io.write(promptText .. " (x y z): ")
    local input = read()
    if input then
      local x, y, z = input:match("^%s*(%-?%d+)%s+(%-?%d+)%s+(%-?%d+)%s*$")
      if x then return tonumber(x), tonumber(y), tonumber(z) end
    end
    print("Enter three whole numbers separated by spaces, e.g. '366 63 -577'.")
  end
end

local function worldToRelative(gpsPos, gpsFacingVec, wx, wy, wz)
  local relX, relZ = worldDeltaToRelative(wx - gpsPos.x, wz - gpsPos.z, gpsFacingVec)
  return relX, wy - gpsPos.y, relZ
end

local function readDirection(promptText)
  while true do
    io.write(promptText .. " (forward/back, left/right, up/down): ")
    local input = read()
    if input and AXIS_DIR[input:lower()] then return input:lower() end
    print("Please enter one of: forward, back, left, right, up, down.")
  end
end

local function readDirectionDefault(promptText, default)
  io.write(("%s (forward/back, left/right, up/down; blank = %s): "):format(promptText, default))
  local input = read()
  if not input or input:match("^%s*$") then return default end
  input = input:lower()
  if AXIS_DIR[input] then return input end
  print("Please enter a valid direction - using default (" .. default .. ").")
  return default
end

local function readCompassDirectionDefault(promptText, gpsFacingVec, default)
  io.write(("%s (north/south/east/west/up/down; blank = %s): "):format(promptText, default))
  local input = read()
  if input and not input:match("^%s*$") then
    local word = compassToAxisWord(input, gpsFacingVec)
    if word then return word end
    print("Please enter a valid compass direction - using default (" .. default .. ").")
  end
  return compassToAxisWord(default, gpsFacingVec)
end

local function cornerFromSizes(n1, d1, n2, d2, n3, d3)
  local corner = { x = 0, y = 0, z = 0 }
  local seenAxis = {}
  for _, pair in ipairs({ { n1, d1 }, { n2, d2 }, { n3, d3 } }) do
    local n, word = pair[1], pair[2]
    local dir = AXIS_DIR[tostring(word):lower()]
    if not dir then
      error("Unknown direction '" .. tostring(word) .. "'. Use forward/back, left/right, up/down.")
    end
    if seenAxis[dir.axis] then
      error("'" .. word .. "' repeats an axis already covered by another direction.")
    end
    seenAxis[dir.axis] = true
    if not n or n < 1 then
      error("Size must be a whole number of at least 1 (got " .. tostring(n) .. ").")
    end
    corner[dir.axis] = dir.sign * (n - 1)
  end
  if not (seenAxis.x and seenAxis.y and seenAxis.z) then
    error("Must cover all three axes: one of forward/back, one of left/right, one of up/down.")
  end
  return corner.x, corner.y, corner.z
end

-- returns x1,y1,z1,x2,y2,z2 relative to current position, plus whether absolute mode was used
local function getBox(args, gpsPos, gpsFacingVec)
  if #args >= 6 then
    if tonumber(args[4]) and tonumber(args[5]) and tonumber(args[6]) then
      if not (gpsPos and gpsFacingVec) then
        error("Absolute coordinates given, but GPS isn't available right now (no modem/satellites, or " ..
          "blocked). Use the relative <size> <direction> form instead, or fix GPS and retry.")
      end
      local x1, y1, z1 = tonumber(args[1]), tonumber(args[2]), tonumber(args[3])
      local x2, y2, z2 = tonumber(args[4]), tonumber(args[5]), tonumber(args[6])
      local rx1, ry1, rz1 = worldToRelative(gpsPos, gpsFacingVec, x1, y1, z1)
      local rx2, ry2, rz2 = worldToRelative(gpsPos, gpsFacingVec, x2, y2, z2)
      return math.floor(rx1 + 0.5), math.floor(ry1 + 0.5), math.floor(rz1 + 0.5),
        math.floor(rx2 + 0.5), math.floor(ry2 + 0.5), math.floor(rz2 + 0.5), true
    end

    local n1, n2, n3 = tonumber(args[1]), tonumber(args[2]), tonumber(args[3])
    if not (n1 and n2 and n3) then
      error("The first three arguments must be numbers.")
    end
    n1, n2, n3 = math.floor(n1 + 0.5), math.floor(n2 + 0.5), math.floor(n3 + 0.5)
    local x2, y2, z2 = cornerFromSizes(n1, args[4], n2, args[5], n3, args[6])
    return 0, 0, 0, x2, y2, z2, false
  end

  if gpsPos and gpsFacingVec then
    io.write("GPS is available - enter absolute world coordinates for the two corners? (Y/n): ")
    local answer = read()
    if not answer or answer:match("^%s*$") or answer:lower():sub(1, 1) == "y" then
      print("Enter the two corner positions as real (F3) coordinates.")
      local x1, y1, z1 = readCoordTriple("Corner 1")
      local x2, y2, z2 = readCoordTriple("Corner 2")
      local rx1, ry1, rz1 = worldToRelative(gpsPos, gpsFacingVec, x1, y1, z1)
      local rx2, ry2, rz2 = worldToRelative(gpsPos, gpsFacingVec, x2, y2, z2)
      return math.floor(rx1 + 0.5), math.floor(ry1 + 0.5), math.floor(rz1 + 0.5),
        math.floor(rx2 + 0.5), math.floor(ry2 + 0.5), math.floor(rz2 + 0.5), true
    end
  end

  print("Enter the box size as three number+direction pairs, e.g. 100 forward, 20 up, 50 right.")
  local n1 = readNumber("Size 1")
  local d1 = readDirection("Direction 1")
  local n2 = readNumber("Size 2")
  local d2 = readDirection("Direction 2")
  local n3 = readNumber("Size 3")
  local d3 = readDirection("Direction 3")
  local x2, y2, z2 = cornerFromSizes(n1, d1, n2, d2, n3, d3)
  return 0, 0, 0, x2, y2, z2, false
end

local function scanForChest()
  local found = {}
  if peripheral.wrap("up") then found[#found + 1] = "up" end
  if peripheral.wrap("down") then found[#found + 1] = "down" end
  local startFacing = facing
  for _, dirWord in ipairs({ "forward", "right", "back", "left" }) do
    turnTo(AXIS_DIR[dirWord].facing)
    if peripheral.wrap("front") then found[#found + 1] = dirWord end
  end
  turnTo(startFacing)
  return found
end

local function getHome(args, gpsPos, gpsFacingVec, absoluteMode)
  if absoluteMode then
    if #args >= 10 and tonumber(args[7]) and tonumber(args[8]) and tonumber(args[9]) then
      local hx, hy, hz = tonumber(args[7]), tonumber(args[8]), tonumber(args[9])
      local dirWord = compassToAxisWord(args[10], gpsFacingVec)
      if not dirWord then
        error("Home direction (argument 10) must be a compass direction: north/south/east/west/up/down (or n/s/e/w/u/d).")
      end
      HOME_CHEST_DIR = dirWord
      local relX, relY, relZ = worldToRelative(gpsPos, gpsFacingVec, hx, hy, hz)
      return { x = math.floor(relX + 0.5), y = math.floor(relY + 0.5), z = math.floor(relZ + 0.5) }
    end

    local found = scanForChest()
    if #found == 1 then
      io.write(("Found an inventory directly %s - use that for resupply? (Y/n): "):format(found[1]))
      local answer = read()
      if not answer or answer:match("^%s*$") or answer:lower():sub(1, 1) == "y" then
        HOME_CHEST_DIR = found[1]
        return { x = 0, y = 0, z = 0 }
      end
    elseif #found > 1 then
      print("Found inventories in more than one direction (" .. table.concat(found, ", ") .. ") - specify manually:")
    end

    print("Resupply park spot: enter its real (F3) coordinates, and which direction the chest is from there.")
    local hx, hy, hz = readCoordTriple("Park spot")
    local dirWord = readCompassDirectionDefault("Chest direction", gpsFacingVec, "down")
    HOME_CHEST_DIR = dirWord
    local relX, relY, relZ = worldToRelative(gpsPos, gpsFacingVec, hx, hy, hz)
    return { x = math.floor(relX + 0.5), y = math.floor(relY + 0.5), z = math.floor(relZ + 0.5) }
  end

  local back, dirWord, extra
  if #args >= 9 then
    back, extra = tonumber(args[7]), tonumber(args[9])
    dirWord = tostring(args[8]):lower()
    if not back or back < 0 then
      error("Home back distance (argument 7) must be a number >= 0.")
    end
    if not AXIS_DIR[dirWord] then
      error("Home direction (argument 8) must be one of forward/back, left/right, up/down (or f/b/l/r/u/d).")
    end
    if not extra or extra < 0 then
      error("Home extra distance (argument 9) must be a number >= 0.")
    end
    back, extra = math.floor(back + 0.5), math.floor(extra + 0.5)
  else
    local found = scanForChest()
    if #found == 1 then
      io.write(("Found an inventory directly %s - use that for resupply? (Y/n): "):format(found[1]))
      local answer = read()
      if not answer or answer:match("^%s*$") or answer:lower():sub(1, 1) == "y" then
        HOME_CHEST_DIR = found[1]
        return { x = 0, y = 0, z = 0 }
      end
    elseif #found > 1 then
      print("Found inventories in more than one direction (" .. table.concat(found, ", ") .. ") - specify manually:")
    end

    print("Chest position: how far behind the start does the turtle park, which direction is the chest from there, and how much further that way?")
    back = readNumberDefault("Blocks behind", 1)
    dirWord = readDirectionDefault("Chest direction", "down")
    extra = readNumberDefault("Blocks further " .. dirWord, 0)
  end

  HOME_CHEST_DIR = dirWord
  local dir = AXIS_DIR[dirWord]
  local home = { x = 0, y = 0, z = -back }
  home[dir.axis] = home[dir.axis] + dir.sign * extra
  return home
end

-- park spot (HOME) can overlap the box (it's always within the launch
-- column anyway) - only the chest position itself needs checking
local function checkHomeClear(x1, y1, z1, x2, y2, z2)
  local minX, maxX = math.min(x1, x2), math.max(x1, x2)
  local minY, maxY = math.min(y1, y2), math.max(y1, y2)
  local minZ, maxZ = math.min(z1, z2), math.max(z1, z2)
  local cx, cy, cz = chestPosition()
  if cx >= minX and cx <= maxX and cy >= minY and cy <= maxY and cz >= minZ and cz <= maxZ then
    error(("The chest at (%d,%d,%d) is inside the box being dug (x %d..%d, y %d..%d, z %d..%d). " ..
      "Move the chest or pick a different homeport direction.")
      :format(cx, cy, cz, minX, maxX, minY, maxY, minZ, maxZ))
  end
end

----------------------------------------------------------------------
-- Fleet: background listener, runs in parallel with the dig job
----------------------------------------------------------------------

-- ping = live GPS report only. reset = live GPS + overwrites this
-- turtle's tracked pos/facing to match, only on explicit request. Safe
-- mid-job since goTo() re-checks pos against its target every step.
local function fleetListener()
  while true do
    local senderId, message = rednet.receive(FLEET_PROTOCOL)
    if type(message) == "table" then
      if message.type == "ping" then
        local p = gpsLocate()
        if p then
          rednet.send(senderId, { type = "pong", x = p.x, y = p.y, z = p.z }, FLEET_PROTOCOL)
          log("fleet: answered GPS ping with live position (%d,%d,%d)", p.x, p.y, p.z)
        else
          rednet.send(senderId, { type = "pong", error = "GPS unavailable right now" }, FLEET_PROTOCOL)
        end
      elseif message.type == "reset" then
        local oldX, oldY, oldZ, oldFacing = pos.x, pos.y, pos.z, facing
        if gpsOrigin then
          local livePos, liveFacingVec = gpsFix()
          if livePos and liveFacingVec then
            local relX, relZ = worldDeltaToRelative(
              livePos.x - gpsOrigin.pos.x, livePos.z - gpsOrigin.pos.z, gpsOrigin.facingVec)
            local relY = livePos.y - gpsOrigin.pos.y
            local newFacing = worldVectorToFacing(gpsOrigin.facingVec, liveFacingVec)
            pos.x, pos.y, pos.z = relX, relY, relZ
            facing = newFacing
            persist()
            log("fleet: reset by coordinator - (%d,%d,%d) facing %d -> (%d,%d,%d) facing %d",
              oldX, oldY, oldZ, oldFacing, relX, relY, relZ, newFacing)
            rednet.send(senderId, {
              type = "reset_ack", ok = true, livePos = livePos,
              oldRelative = { x = oldX, y = oldY, z = oldZ, facing = oldFacing },
              newRelative = { x = relX, y = relY, z = relZ, facing = newFacing },
            }, FLEET_PROTOCOL)
          else
            rednet.send(senderId, { type = "reset_ack", ok = false, error = "GPS fix failed right now" }, FLEET_PROTOCOL)
          end
        else
          rednet.send(senderId, { type = "reset_ack", ok = false, error = "no GPS origin for this job" }, FLEET_PROTOCOL)
        end
      end
    end
  end
end

----------------------------------------------------------------------
-- Main
----------------------------------------------------------------------

local function main(...)
  local args = { ... }

  local gpsPos, gpsFacingVec = gpsFix()
  if gpsPos then
    log("GPS fix: real-world (%d,%d,%d)", gpsPos.x, gpsPos.y, gpsPos.z)
  else
    log("GPS not available (no modem/satellites, or blocked) - using dead reckoning only")
  end

  local saved = loadState()
  if saved then
    io.write(("Found an interrupted job (corner1 %d,%d,%d -> corner2 %d,%d,%d). Resume? (y/n): ")
      :format(saved.job.x1, saved.job.y1, saved.job.z1, saved.job.x2, saved.job.y2, saved.job.z2))
    local answer = read()
    if answer and answer:lower():sub(1, 1) == "y" then
      if saved.gpsOrigin and gpsPos and gpsFacingVec then
        local relX, relZ = worldDeltaToRelative(
          gpsPos.x - saved.gpsOrigin.pos.x, gpsPos.z - saved.gpsOrigin.pos.z, saved.gpsOrigin.facingVec)
        local relY = gpsPos.y - saved.gpsOrigin.pos.y
        local newFacing = worldVectorToFacing(saved.gpsOrigin.facingVec, gpsFacingVec)
        log("GPS recalibration: saved pos (%d,%d,%d) facing %d -> corrected (%d,%d,%d) facing %d",
          saved.pos.x, saved.pos.y, saved.pos.z, saved.facing, relX, relY, relZ, newFacing)
        pos.x, pos.y, pos.z = relX, relY, relZ
        facing = newFacing
        gpsOrigin = saved.gpsOrigin
      else
        pos.x, pos.y, pos.z = saved.pos.x, saved.pos.y, saved.pos.z
        facing = saved.facing
      end
      if saved.home then
        HOME.x, HOME.y, HOME.z = saved.home.x, saved.home.y, saved.home.z
      end
      if saved.homeChestDir then
        HOME_CHEST_DIR = saved.homeChestDir
      end
      print("Resuming...")
      run(saved.job.x1, saved.job.y1, saved.job.z1, saved.job.x2, saved.job.y2, saved.job.z2, saved.job.nextIndex)
      return
    end
    fs.delete(STATE_FILE)
  end

  if args[1] and tostring(args[1]):lower() == "fleet" then
    if not (gpsPos and gpsFacingVec) then
      error("Fleet mode needs GPS (no modem/satellites, or blocked) - fix that and retry.")
    end
    if not rednet.isOpen() then
      local opened = nil
      for _, side in ipairs(peripheral.getNames()) do
        if peripheral.getType(side) == "modem" then
          rednet.open(side)
          opened = side
          break
        end
      end
      if not opened then
        error("Fleet mode needs a wireless/ender modem attached to the turtle.")
      end
    end
    print("Looking for fleet coordinator...")
    local foundId = rednet.lookup(FLEET_PROTOCOL, "coordinator")
    if not foundId then
      error("No fleet coordinator found (is coordinator.lua running and hosting?).")
    end
    coordinatorId = foundId
    FLEET_MODE = true
    rednet.send(coordinatorId, { type = "register" }, FLEET_PROTOCOL)
    local _, msg = rednet.receive(FLEET_PROTOCOL, 5)
    if not msg then
      error("Coordinator didn't respond to registration.")
    end
    if msg.type == "no_region" then
      error("Coordinator has no region left to assign - already enough turtles working this job.")
    end

    local r, c = msg.region, msg.chest
    local rx1, ry1, rz1 = worldToRelative(gpsPos, gpsFacingVec, r.x1, r.y1, r.z1)
    local rx2, ry2, rz2 = worldToRelative(gpsPos, gpsFacingVec, r.x2, r.y2, r.z2)
    local hx, hy, hz = worldToRelative(gpsPos, gpsFacingVec, c.x, c.y, c.z)
    local chestDirWord = compassToAxisWord(c.dir, gpsFacingVec)
    if not chestDirWord then
      error("Coordinator sent an invalid chest direction: '" .. tostring(c.dir) .. "'.")
    end
    HOME_CHEST_DIR = chestDirWord
    HOME.x, HOME.y, HOME.z = math.floor(hx + 0.5), math.floor(hy + 0.5), math.floor(hz + 0.5)
    gpsOrigin = { pos = gpsPos, facingVec = gpsFacingVec }

    local fx1, fy1, fz1 = math.floor(rx1 + 0.5), math.floor(ry1 + 0.5), math.floor(rz1 + 0.5)
    local fx2, fy2, fz2 = math.floor(rx2 + 0.5), math.floor(ry2 + 0.5), math.floor(rz2 + 0.5)

    -- resume the interrupted run of this exact region, if any - no prompt, reconnect autonomously
    local startIndex = 1
    if saved and saved.job.x1 == fx1 and saved.job.y1 == fy1 and saved.job.z1 == fz1
      and saved.job.x2 == fx2 and saved.job.y2 == fy2 and saved.job.z2 == fz2 then
      startIndex = saved.job.nextIndex
      print(("Fleet: matches a previously interrupted run of this region - resuming at cell %d."):format(startIndex))
    end

    print(("Fleet: assigned region relative (%d,%d,%d) to (%d,%d,%d), chest %s of park spot (%d,%d,%d)..."):format(
      fx1, fy1, fz1, fx2, fy2, fz2, HOME_CHEST_DIR, HOME.x, HOME.y, HOME.z))
    parallel.waitForAny(
      function() run(fx1, fy1, fz1, fx2, fy2, fz2, startIndex) end,
      fleetListener
    )
    return
  end

  if gpsPos and gpsFacingVec then
    gpsOrigin = { pos = gpsPos, facingVec = gpsFacingVec }
  end

  local x1, y1, z1, x2, y2, z2, absoluteMode = getBox(args, gpsPos, gpsFacingVec)
  local home = getHome(args, gpsPos, gpsFacingVec, absoluteMode)
  HOME.x, HOME.y, HOME.z = home.x, home.y, home.z
  checkHomeClear(x1, y1, z1, x2, y2, z2)
  print(("Flattening a box from here to relative (%d,%d,%d), chest %s of park spot (%d,%d,%d)..."):format(
    x2, y2, z2, HOME_CHEST_DIR, HOME.x, HOME.y, HOME.z))
  run(x1, y1, z1, x2, y2, z2)
end

main(...)
