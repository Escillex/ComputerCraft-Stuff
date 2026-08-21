-- flatten.lua
-- Fleet worker. Clears the marked region one column at a time, taking work
-- from the coordinator and reporting where it is as it goes.
--
--   flatten          join the fleet and start working
--   flatten mark1    record one corner of the area at this turtle's position
--   flatten mark2    record the opposite corner
--   flatten status   print what this turtle currently knows

local function loadModule(name)
  local dir = fs.getDir(shell.getRunningProgram())
  local path = fs.combine(dir, name .. ".lua")
  if not fs.exists(path) then
    error(name .. ".lua is missing - run 'update all' first", 0)
  end
  local file = fs.open(path, "r")
  local source = file.readAll()
  file.close()
  local chunk, err = load(source, "@" .. path, "t", _ENV)
  if not chunk then error(err, 0) end
  return chunk()
end

local common = loadModule("common")

local STATE_FILE = "flatten.state"
local FUEL_MARGIN = 150       -- fuel kept in hand on top of the trip home
local STEP_ATTEMPTS = 32      -- tries before a step is called blocked
local STEP_WAITS = 10         -- of those, how long to wait on another turtle

local pos, facing             -- absolute world position and facing index
local box, depot, coordId, coordPos
local myCell
local state = "starting"

--------------------------------------------------------------------------
-- Talking to the coordinator
--------------------------------------------------------------------------

local function findCoordinator()
  print("looking for the coordinator...")
  for _ = 1, 10 do
    local id = rednet.lookup(common.PROTOCOL, common.HOSTNAME)
    if id then return id end
    sleep(2)
  end
  return nil
end

-- Ask and wait for the matching reply. common.request tags every request
-- with a nonce, so a late or unrelated message can never be mistaken for
-- the answer to this one.
local function ask(msg, timeout)
  return common.request(coordId, msg, timeout)
end

local function tell(msg)
  msg.from = os.getComputerID()
  rednet.send(coordId, msg, common.PROTOCOL)
end

local function saveLocal()
  common.saveState(STATE_FILE, { pos = pos, facing = facing, depot = depot })
end

--------------------------------------------------------------------------
-- Fuel
--------------------------------------------------------------------------

local function fuel()
  local level = turtle.getFuelLevel()
  return level == "unlimited" and math.huge or level
end

local function refuelFromInventory(target)
  if fuel() >= target then return true end
  for slot = 1, 16 do
    turtle.select(slot)
    if turtle.refuel(0) then turtle.refuel() end
    if fuel() >= target then break end
  end
  turtle.select(1)
  return fuel() >= target
end

--------------------------------------------------------------------------
-- Movement
--------------------------------------------------------------------------

local INSPECT = { forward = turtle.inspect, up = turtle.inspectUp, down = turtle.inspectDown }
local DIG     = { forward = turtle.dig,     up = turtle.digUp,     down = turtle.digDown }
local MOVE    = { forward = turtle.forward, up = turtle.up,        down = turtle.down }
local ATTACK  = { forward = turtle.attack,  up = turtle.attackUp,  down = turtle.attackDown }

-- Move one block, clearing the way if what is there is safe to break.
-- Anything protected (another turtle, a chest) is waited out, never dug.
local function stepDir(dir)
  local waited = 0
  for _ = 1, STEP_ATTEMPTS do
    if MOVE[dir]() then return true end

    local present, info = INSPECT[dir]()
    if not present then
      -- Nothing solid there, so something alive is standing in the way.
      ATTACK[dir]()
      sleep(0.4)
    elseif common.isTurtleBlock(info.name) then
      -- Give way, but not forever: reporting back quickly lets the
      -- coordinator send this turtle somewhere useful instead.
      waited = waited + 1
      if waited > STEP_WAITS then return false, info.name end
      sleep(1)
    elseif common.isProtected(info.name) then
      -- A chest or a computer is never going to move, so say so at once
      -- and let the caller go round it.
      return false, info.name
    elseif not DIG[dir]() then
      -- Bedrock, or a block this turtle's tool cannot break.
      return false, info.name
    end
  end

  local present, info = INSPECT[dir]()
  return false, present and info.name or "something in the way"
end

local function moveForward()
  local ok, why = stepDir("forward")
  if not ok then return false, why end
  local f = common.FACINGS[facing]
  pos.x, pos.z = pos.x + f.dx, pos.z + f.dz
  return true
end

local function moveUp()
  local ok, why = stepDir("up")
  if not ok then return false, why end
  pos.y = pos.y + 1
  return true
end

local function moveDown()
  local ok, why = stepDir("down")
  if not ok then return false, why end
  pos.y = pos.y - 1
  return true
end

local function turnTo(target)
  while facing ~= target do
    if (target - facing) % 4 == 1 then
      turtle.turnRight()
      facing = (facing + 1) % 4
    else
      turtle.turnLeft()
      facing = (facing - 1) % 4
    end
  end
end

local function goToY(y)
  while pos.y < y do
    local ok, why = moveUp()
    if not ok then return false, why end
  end
  while pos.y > y do
    local ok, why = moveDown()
    if not ok then return false, why end
  end
  return true
end

-- Walk to an X/Z position, one axis at a time. If something refuses to
-- move out of the way, climb over it rather than giving up immediately.
local function goToXZ(x, z)
  local detours = 0
  while pos.x ~= x or pos.z ~= z do
    if pos.x ~= x then
      turnTo(pos.x < x and 1 or 3)
    else
      turnTo(pos.z < z and 2 or 0)
    end

    local ok, why = moveForward()
    if not ok then
      if detours >= 6 then return false, why end
      detours = detours + 1
      local climbed, climbWhy = moveUp()
      if not climbed then return false, climbWhy end
    end
  end
  return true
end

-- Travel to a position, doing the horizontal leg at travelY so turtles do
-- not wander through each other's columns at odd heights.
local function goTo(x, y, z, travelY)
  if travelY then
    local ok, why = goToY(travelY)
    if not ok then return false, why end
  end
  local ok, why = goToXZ(x, z)
  if not ok then return false, why end
  return goToY(y)
end

--------------------------------------------------------------------------
-- Position and facing
--------------------------------------------------------------------------

local function gpsPos(timeout)
  local x, y, z = gps.locate(timeout or 3)
  if not x then return nil end
  return { x = common.round(x), y = common.round(y), z = common.round(z) }
end

-- Work out which way the turtle is pointing by moving one block and
-- comparing GPS fixes. Steps into open air if it can; only digs when
-- boxed in on all four sides.
local function measureFacing()
  local start = gpsPos()
  if not start then return false, "no GPS signal - is the satellite cluster running?" end
  pos = start

  local function tryStep(allowDig)
    for _ = 1, 4 do
      if not turtle.detect() then
        if turtle.forward() then return true end
      elseif allowDig then
        local _, info = turtle.inspect()
        if not common.isProtected(info.name) and turtle.dig() then
          if turtle.forward() then return true end
        end
      end
      turtle.turnRight()
    end
    return false
  end

  if not (tryStep(false) or tryStep(true)) then
    return false, "boxed in - cannot move to work out which way I face"
  end

  local after = gpsPos()
  if not after then return false, "lost the GPS signal mid-measurement" end

  local f = common.facingFromDelta(after.x - start.x, after.z - start.z)
  if not f then return false, "GPS fix did not move exactly one block" end

  facing = f
  pos = after
  return true
end

local function syncPosition()
  local p = gpsPos(2)
  if p then pos = p end
end

--------------------------------------------------------------------------
-- Inventory
--------------------------------------------------------------------------

local function inventoryFull()
  for slot = 1, 16 do
    if turtle.getItemCount(slot) == 0 then return false end
  end
  return true
end

local FILL_BLOCKS = {
  "dirt", "cobblestone", "cobbled_deepslate", "stone", "deepslate",
  "netherrack", "gravel", "sand", "granite", "diorite", "andesite", "tuff",
}

-- Pick something dull to patch a hole in the floor with, preferring dirt.
local function selectFill()
  for _, wanted in ipairs(FILL_BLOCKS) do
    for slot = 1, 16 do
      local item = turtle.getItemDetail(slot)
      if item and item.name:lower():find(wanted, 1, true) then
        turtle.select(slot)
        return true
      end
    end
  end
  return false
end

--------------------------------------------------------------------------
-- Depot
--------------------------------------------------------------------------

-- The coordinator sits next to the resupply chest but cannot tell which
-- side it is on, so the first turtle that needs the depot walks the four
-- horizontal neighbours, looking back at the coordinator from two blocks
-- out, and reports what it finds.
local function probeDepot()
  if not coordPos then return nil end
  -- Fly over the coordinator rather than into it: it and its chest are both
  -- blocks this turtle refuses to break, so a route at their own height
  -- means standing around waiting for scenery to move.
  local travelY = math.max(box and box.maxY or coordPos.y, coordPos.y + 1)
  print("looking for the resupply chest next to the coordinator...")
  for dir = 0, 3 do
    local f = common.FACINGS[dir]
    local standX, standZ = coordPos.x + f.dx * 2, coordPos.z + f.dz * 2
    if goTo(standX, coordPos.y, standZ, travelY) then
      local inward = (dir + 2) % 4
      turnTo(inward)
      local present, info = turtle.inspect()
      if present and common.looksLikeDepot(info.name) then
        return {
          chest  = { x = coordPos.x + f.dx, y = coordPos.y, z = coordPos.z + f.dz },
          dock   = { x = standX, y = coordPos.y, z = standZ },
          facing = inward,
        }
      end
    end
  end
  return nil
end

local function dumpInventory()
  local blocked = false
  for slot = 1, 16 do
    if turtle.getItemCount(slot) > 0 then
      turtle.select(slot)
      turtle.drop()
      if turtle.getItemCount(slot) > 0 then blocked = true end
    end
  end
  turtle.select(1)
  return not blocked
end

-- Walk the chest looking for anything burnable. Non-fuel is held in the
-- turtle's own slots while we look and handed straight back afterwards, so
-- we never re-suck the same rubbish over and over.
local function takeFuel(target)
  if fuel() >= target then return true end
  local held = {}
  for slot = 1, 16 do
    if fuel() >= target then break end
    if turtle.getItemCount(slot) == 0 then
      turtle.select(slot)
      if not turtle.suck(64) then break end
      if turtle.refuel(0) then
        turtle.refuel()
      else
        held[#held + 1] = slot
      end
    end
  end
  for _, slot in ipairs(held) do
    turtle.select(slot)
    turtle.drop()
  end
  turtle.select(1)
  return fuel() >= target
end

local function tripCost(target)
  return math.abs(pos.x - target.x) + math.abs(pos.y - target.y) + math.abs(pos.z - target.z)
end

local function needsDepot()
  if inventoryFull() then return true end
  if depot then
    return fuel() < tripCost(depot.dock) + FUEL_MARGIN
  end
  -- The chest has not been found yet, so there is no trip to price up.
  -- Go looking while there is still plenty in the tank to get there.
  return fuel() < FUEL_MARGIN * 4
end

-- Only one turtle fits at the chest, so ask the coordinator for a turn
-- before setting off. Without this the whole fleet converges on one block
-- and spends its time waiting for the turtle in front to move.
local function claimDepot()
  state = "queuing for the depot"
  for _ = 1, 60 do
    local reply = ask({ type = common.WANT_DEPOT, pos = pos })
    if reply and reply.type == common.DEPOT_GRANT then return reply end
    sleep(2)
  end
  return nil
end

local function useDepot()
  local travelY = math.max(box and box.maxY or depot.dock.y, depot.dock.y + 1)
  local ok, why = goTo(depot.dock.x, depot.dock.y, depot.dock.z, travelY)
  if not ok then return false, why end
  turnTo(depot.facing)

  if not dumpInventory() then
    print("!! the resupply chest is FULL - empty it or I cannot keep mining")
  end
  if not takeFuel(tripCost(depot.dock) + FUEL_MARGIN * 4) then
    print("!! no fuel left in the resupply chest - put coal in it")
  end

  -- Climb off the dock before handing the chest on, so the next turtle in
  -- the queue is not walking into this one.
  return goToY(travelY)
end

-- Everything that happens at the chest, including the hunt for it, runs
-- under the coordinator's depot token. Looking for the chest is the one
-- job that would otherwise send the whole fleet to the same block at the
-- same moment, the first time they all start up together.
local function depotRun()
  local grant = claimDepot()
  if not grant then return false, "the depot never came free" end

  if not depot and grant.depot then
    depot = grant.depot
    saveLocal()
  end

  local ok, why
  if not depot then
    state = "finding depot"
    depot = probeDepot()
    if depot then
      print("depot found at " .. common.formatPos(depot.chest))
      tell({ type = common.DEPOT_FOUND, depot = depot })
      saveLocal()
    end
  end

  if depot then
    state = "resupplying"
    ok, why = useDepot()
  else
    ok, why = false, "no chest next to the coordinator"
  end

  tell({ type = common.DEPOT_RELEASE })
  return ok, why
end

--------------------------------------------------------------------------
-- Mining
--------------------------------------------------------------------------

-- Clear one column of the box from the top down, patch the floor beneath
-- it, then climb back to the travel plane. Returns "done", "full" when the
-- inventory needs emptying part-way, or "blocked" with a reason.
local function digCell(cell)
  state = "mining"

  local ok, why = goTo(cell.x, box.maxY, cell.z, box.maxY)
  if not ok then return "blocked", why end

  while pos.y > box.minY do
    if inventoryFull() then return "full" end
    local moved, reason = moveDown()
    if not moved then return "blocked", reason end
  end

  if not turtle.detectDown() and selectFill() then
    turtle.placeDown()
    turtle.select(1)
  end

  local climbed, climbWhy = goToY(box.maxY)
  if not climbed then return "blocked", climbWhy end
  return "done"
end

local function heartbeatLoop()
  while true do
    sleep(common.HEARTBEAT_INTERVAL)
    if coordId and pos then
      -- Fire and forget: this loop never reads from rednet, so it can
      -- never steal a reply the worker loop is waiting for.
      tell({
        type  = common.HEARTBEAT,
        pos   = pos,
        state = state,
        cell  = myCell,
        fuel  = turtle.getFuelLevel(),
      })
    end
  end
end

--------------------------------------------------------------------------
-- Worker
--------------------------------------------------------------------------

local function workerLoop()
  while true do
    if not myCell then
      syncPosition()
      saveLocal()
    end

    if needsDepot() then
      local ok, why = depotRun()
      if not ok then
        print("could not reach the depot: " .. tostring(why))
        sleep(5)
      end
    end

    if not myCell then
      state = "idle"
      local reply = ask({ type = common.WANT_CELL, pos = pos })

      if not reply then
        print("no answer from the coordinator - retrying")
        sleep(3)
      elseif reply.type == common.JOB_DONE then
        print("job finished - nothing left to clear")
        return
      elseif reply.type == common.NO_CELL then
        state = "waiting"
        sleep(3)
      elseif reply.type == common.CELL then
        myCell = reply.cell
        print(("cell %d,%d"):format(myCell.x, myCell.z))
      end
    end

    if myCell then
      local status, detail = digCell(myCell)
      if status == "done" then
        tell({ type = common.CELL_DONE, cell = myCell })
        myCell = nil
      elseif status == "full" then
        local ok = depotRun()
        if not ok then sleep(5) end
      else
        -- Being stopped by another turtle is traffic, not an obstacle: say
        -- so, and the coordinator will hand the column out again rather
        -- than writing it off.
        local traffic = tostring(detail):find("computercraft:") ~= nil
        if not traffic then
          print(("skipping cell %d,%d: %s"):format(myCell.x, myCell.z, tostring(detail)))
        end
        -- A wrong idea about where we are looks exactly like being stuck,
        -- so re-fix on GPS before giving the cell back.
        syncPosition()
        tell({
          type = common.CELL_SKIP, cell = myCell,
          reason = tostring(detail), transient = traffic,
        })
        myCell = nil
        sleep(traffic and 2 or 1)
      end
    end
  end
end

--------------------------------------------------------------------------
-- Commands
--------------------------------------------------------------------------

local function connect()
  if not common.openModem() then
    error("no modem attached - a turtle needs a wireless modem", 0)
  end
  coordId = findCoordinator()
  if not coordId then
    error("could not find the coordinator - is coordinator.lua running?", 0)
  end
end

local function cmdMark(which)
  connect()
  local p = gpsPos()
  if not p then error("no GPS signal here", 0) end

  local reply = ask({ type = common.MARK, which = which, pos = p })
  if not reply then
    print("the coordinator did not answer")
  elseif reply.type == common.ACK then
    print(("corner %d set at %s"):format(which, common.formatPos(p)))
    if reply.message then print(reply.message) end
  else
    print("rejected: " .. tostring(reply.message))
  end
end

local function cmdStatus()
  local saved = common.loadState(STATE_FILE)
  print("turtle id: " .. os.getComputerID())
  print("fuel: " .. tostring(turtle.getFuelLevel()))
  local p = gpsPos(2)
  print("position: " .. common.formatPos(p))
  if saved and saved.depot then
    print("depot: " .. common.formatPos(saved.depot.chest))
  else
    print("depot: not found yet")
  end
end

local function cmdWork()
  connect()

  -- Fuel first: everything below needs to be able to move, and a turtle
  -- that cannot move cannot even work out which way it is facing.
  if not refuelFromInventory(FUEL_MARGIN) then
    error("out of fuel - put coal in my inventory to get started", 0)
  end

  local ok, why = measureFacing()
  if not ok then error(why, 0) end

  local saved = common.loadState(STATE_FILE)
  if saved and saved.depot then depot = saved.depot end

  local welcome = ask({ type = common.HELLO, pos = pos, version = common.VERSION }, 10)
  if not welcome then error("the coordinator did not answer my hello", 0) end
  if welcome.type == common.NACK then error(tostring(welcome.message), 0) end
  if welcome.version ~= common.VERSION then
    error("version mismatch with the coordinator - run 'update all' on both", 0)
  end

  box = welcome.box
  depot = welcome.depot or depot
  coordPos = welcome.coordPos
  if not box then
    error("no area marked yet - run 'flatten mark1' and 'flatten mark2' on a turtle", 0)
  end

  print(("joined as turtle %d, facing %s at %s")
    :format(os.getComputerID(), common.FACINGS[facing].name, common.formatPos(pos)))

  -- The chest is found on the first trip to it rather than up front, so
  -- that a fleet starting together does not all walk to the same block at
  -- once. The heartbeat runs alongside the work throughout.
  parallel.waitForAny(workerLoop, heartbeatLoop)
  state = "finished"
end

local args = { ... }
local command = (args[1] or "work"):lower()

if command == "mark1" then
  cmdMark(1)
elseif command == "mark2" then
  cmdMark(2)
elseif command == "status" then
  cmdStatus()
elseif command == "work" then
  if not turtle then error("this only runs on a turtle", 0) end
  cmdWork()
else
  print("Usage: flatten [mark1|mark2|status]")
  print("  no argument joins the fleet and starts working")
end
