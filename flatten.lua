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
-- Why the last run stopped, left for startup.lua to read. A turtle that
-- cannot start usually cannot start for a reason a person has to deal
-- with, and startup needs to tell "the same thing is still wrong" from
-- "something else is wrong now".
local STOP_FILE = "flatten.stopped"
local FUEL_MARGIN = 150       -- fuel kept in hand on top of the trip home
local STEP_ATTEMPTS = 32      -- tries before a step is called blocked
local STEP_WAITS = 10         -- of those, how long to wait on another turtle
local STEP_PATIENCE = 20      -- seconds to give something living to move on

local pos, facing             -- absolute world position and facing index
local box, depot, coordId, coordPos
local depotTypes = {}   -- block ids the coordinator says its store is
local mode = "clear"    -- what the coordinator wants done with a column
local material          -- the block id to fill with, when filling
local spine             -- the row kept open as a road while filling
local skyOverhead       -- whether there is room to travel above the area
local floorPatch = false -- whether to cap a hole under a cleared column
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
-- Every message says which version said it, not just the hello. The
-- coordinator refuses work to a turtle on the wrong version, and marking a
-- corner never says hello first - so without this the marker turtle looks
-- exactly like a stale one.
local function ask(msg, timeout)
  msg.version = common.VERSION
  return common.request(coordId, msg, timeout)
end

local function tell(msg)
  msg.from = os.getComputerID()
  msg.version = common.VERSION
  rednet.send(coordId, msg, common.PROTOCOL)
end

-- The first block named is what gets laid into empty space. The rest count
-- as good enough where they already are, so a column made of them is left
-- alone and any that do come out go back as they were - filling a plot with
-- dirt has no business stripping the grass off it.
local function isMaterial(name)
  if not name or not material then return false end
  name = name:lower()
  for _, id in ipairs(material) do
    if name == id:lower() then return true end
  end
  return false
end

local function saveLocal()
  common.saveState(STATE_FILE, { pos = pos, facing = facing, depot = depot })
end

-- An older build called the store's position `chest` and always approached
-- it from the side. A note left on disk by one of those must not come back
-- as a depot with no position on it, because the position is what keeps
-- turtles from digging the thing up.
-- Built fresh rather than patched in place. Pointing `store` at the same
-- table as the old `chest` would leave two names for one table, and a table
-- that turns up twice is something CC flatly refuses to write to disk.
local function normaliseDepot(d)
  if type(d) ~= "table" then return nil end
  local store, dock = d.store or d.chest, d.dock
  if not store or not dock then return nil end
  return {
    store  = { x = store.x, y = store.y, z = store.z },
    dock   = { x = dock.x,  y = dock.y,  z = dock.z },
    dir    = d.dir or "forward",
    facing = d.facing,
  }
end

-- Anything a person would want to do something about goes to the
-- coordinator as well as this turtle's own screen - nobody is stood
-- watching a turtle at the bottom of a hole. Repeats of the same
-- complaint are held back so a stuck turtle does not bury the console.
local lastTrouble, lastTroubleAt = nil, -math.huge

local function trouble(message)
  print("!! " .. message)
  if not coordId then return end
  if message == lastTrouble and os.clock() - lastTroubleAt < 60 then return end
  lastTrouble, lastTroubleAt = message, os.clock()
  tell({ type = common.TROUBLE, message = message, pos = pos })
end

-- A turtle that cannot start is a turtle nobody is looking at. Say why on
-- the coordinator before giving up, so 'list' answers the question rather
-- than a walk out to wherever it is standing.
local function giveUp(message)
  trouble(message)
  local ok, file = pcall(fs.open, STOP_FILE, "w")
  if ok and file then
    file.write(message)
    file.close()
  end
  error(message, 0)
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

local function stepTarget(dir)
  if dir == "up" then return pos.x, pos.y + 1, pos.z end
  if dir == "down" then return pos.x, pos.y - 1, pos.z end
  local f = common.FACINGS[facing]
  return pos.x + f.dx, pos.y, pos.z + f.dz
end

-- The turtle only ever breaks blocks standing in the footprint that was
-- marked out, at or above its floor. That covers the area itself and the
-- room directly over it, so a turtle can drop in and climb out, while
-- everything around the site - the way to the chest included - is left
-- exactly as it was found.
local function samePlace(p, x, y, z)
  return p ~= nil and p.x == x and p.y == y and p.z == z
end

local function mayBreakAt(x, y, z)
  -- Draining takes the lava out and leaves everything else exactly where it
  -- is, so a turtle doing it breaks nothing whatsoever - not on the way to a
  -- column, not on the way to the store, not anywhere. That limits it to
  -- fluid it can already swim to, which is the fluid worth reaching.
  if mode == "drain" then return false end
  if not box then return false end
  -- The coordinator and its store are off limits wherever they stand, even
  -- inside the marked area. Their block ids are not something this script
  -- can be expected to recognise on sight - a modded store is just a block
  -- with an unfamiliar name - so go by where they are instead.
  if samePlace(coordPos, x, y, z) then return false end
  if depot and samePlace(depot.store, x, y, z) then return false end

  -- The marked area and nothing else. Not a block above it, not a block
  -- beside it. A turtle that cannot get where it is going without breaking
  -- something outside these six faces does not go, and says so.
  return x >= box.minX and x <= box.maxX
     and z >= box.minZ and z <= box.maxZ
     and y >= box.minY and y <= box.maxY
end

-- Never break anything of the same kind as the coordinator's store either,
-- so a second vault sitting in the dig area is left alone as well.
local function isProtectedBlock(name)
  if common.isProtected(name) then return true end
  if not name then return false end
  name = name:lower()
  for _, id in ipairs(depotTypes) do
    if name == id:lower() then return true end
  end
  return false
end

-- Move one block, clearing the way if what is there is safe to break.
-- Anything protected (another turtle, a chest) is waited out, never dug.
local function stepDir(dir)
  local waited, living = 0, 0
  local mayDig = mayBreakAt(stepTarget(dir))
  for _ = 1, STEP_ATTEMPTS do
    if MOVE[dir]() then return true end

    local present, info = INSPECT[dir]()
    if not present then
      -- Nothing solid there, so something alive is in the way. Wait for it.
      -- Most things that block a turtle are passing through - a colonist on
      -- an errand, somebody's cow, you - and swinging at them the moment
      -- they get in the way is a poor trade for a few seconds of digging.
      -- Only something that has not moved at all gets hit.
      living = living + 1
      if living > STEP_PATIENCE then ATTACK[dir]() end
      sleep(0.5)
    elseif common.isTurtleBlock(info.name) then
      -- Give way, but not forever: reporting back quickly lets the
      -- coordinator send this turtle somewhere useful instead.
      waited = waited + 1
      if waited > STEP_WAITS then return false, info.name end
      sleep(1)
    elseif isProtectedBlock(info.name) then
      -- A chest or a computer is never going to move, so say so at once
      -- and let the caller go round it.
      return false, info.name
    elseif not mayDig then
      -- Outside the marked area this is somebody's build, not spoil. Go
      -- round it rather than through it.
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

-- Walk to an X/Z position. Outside the marked area nothing gets broken, so
-- getting there is a matter of going round: try whichever axis still needs
-- progress, and climb over only when both are shut. Height gained that way
-- is given back as soon as there is floor to drop to, so the turtle does
-- not end up crawling home along the top of a mountain.
local function goToXZ(x, z, floorY, ceiling)
  local climbs, lastWhy = 0, "blocked"
  while pos.x ~= x or pos.z ~= z do
    local options = {}
    if pos.x ~= x then options[#options + 1] = pos.x < x and 1 or 3 end
    if pos.z ~= z then options[#options + 1] = pos.z < z and 2 or 0 end

    local moved = false
    for _, dir in ipairs(options) do
      turnTo(dir)
      local ok, why = moveForward()
      if ok then moved = true break end
      lastWhy = why or lastWhy
    end

    if not moved then
      -- Climbing over things is how a turtle gets anywhere without breaking
      -- what is in the way, but not when it is heading somewhere with a
      -- ceiling on it. Going up out of the area when something solid sits
      -- on top of it means never getting back down again.
      if climbs >= 32 or (ceiling and pos.y >= ceiling) then
        return false, lastWhy
      end
      climbs = climbs + 1
      local climbed, climbWhy = moveUp()
      if not climbed then
        -- What stopped the journey is whatever was in the way along it, not
        -- the ceiling that turned out to be over the detour. Blame the
        -- climb and a turtle standing in a doorway under a roof gets
        -- reported as solid rock, which writes the column off after three
        -- goes instead of handing it back as the traffic it was.
        return false, lastWhy ~= "blocked" and lastWhy or climbWhy
      end
    elseif climbs > 0 and pos.y > (floorY or pos.y) and not turtle.detectDown() then
      if moveDown() then climbs = climbs - 1 end
    end
  end
  return true
end

-- Travel to a position, doing the horizontal leg at travelY so turtles do
-- not wander through each other's columns at odd heights.
local function goTo(x, y, z, travelY, ceiling)
  if travelY then
    -- Climb to the travel height, never drop to it. Height gained is height
    -- gained over something in the way, and coming back down to a nominal
    -- height puts the turtle back on the wrong side of whatever it just
    -- got over.
    --
    -- The height is a preference either way: one that cannot get up there
    -- carries on from wherever it got to rather than giving up on the spot.
    goToY(math.max(travelY, pos.y))
  end
  local ok, why = goToXZ(x, z, travelY, ceiling)

  -- Coming back from the store a turtle is often a little above the height
  -- the job is worked at, and with something built over the area that is
  -- the underside of it. Dropping back down to the working height and
  -- trying again gets it in. Only after the first attempt, though: coming
  -- down before crossing anything would land it back at the foot of the
  -- wall it had just climbed.
  if not ok and travelY and pos.y > travelY then
    goToY(travelY)
    ok, why = goToXZ(x, z, travelY, ceiling)
  end

  if not ok then return false, why end

  local down, downWhy = goToY(y)
  if down then return true end

  -- Stranded on top of the job: it climbed clear of something on its way
  -- here, crossed over the area at that height, and has now found that what
  -- it crossed was the roof of the place it was trying to get into. Get
  -- back off the area, come down outside where there is no roof, and walk
  -- in from the side.
  if box and pos.y > box.maxY then
    local outward = (pos.x - box.minX < box.maxX - pos.x)
      and box.minX - 1 or box.maxX + 1
    local outOk, outWhy = goToXZ(outward, pos.z)
    if outOk then
      local dropped, dropWhy = goToY(y)
      if dropped then
        local backOk, backWhy = goToXZ(x, z, travelY, ceiling)
        if backOk then return goToY(y) end
        return false, backWhy
      end
      -- Report what is stopping it now, not the roof that turned the
      -- journey into a detour in the first place. Another turtle standing
      -- in the lane outside the area will move; blaming the ceiling instead
      -- writes the column off as solid rock after three goes.
      return false, dropWhy or downWhy
    end
    return false, outWhy or downWhy
  end

  return false, downWhy
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

  -- Nothing gets broken here. This runs before the coordinator has said
  -- where the job is, so there is no area to be inside of yet, and a turtle
  -- that helped itself to a block to get its bearings would be breaking
  -- something nobody asked it to touch. If it is walled in it climbs, and
  -- if it cannot climb either it says so and stops.
  local function tryStep()
    for _ = 1, 4 do
      if not turtle.detect() and turtle.forward() then return true end
      turtle.turnRight()
    end
    return false
  end

  local climbed = 0
  while not tryStep() do
    if climbed >= 8 or turtle.detectUp() or not turtle.up() then
      return false, "walled in - I need a clear block beside or above me to start"
    end
    climbed = climbed + 1
    pos.y = pos.y + 1
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

-- Whether a block sits right against the coordinator. The store is the
-- thing touching it, so anything further off is somebody else's chest and
-- none of our business.
-- How far from the coordinator its store is allowed to be: two blocks, so
-- a 5x5x5 cube centred on it. A chest against its side is in there, so is a
-- vault three blocks across, and so is one sat on its roof. Anything
-- further off is not the coordinator's store, and the point of the bound is
-- that a turtle which cannot find one says so instead of walking away over
-- the horizon looking.
local SEARCH_RADIUS = 2

-- Attempts between one walk of the cube and the next, once one has come
-- back empty. The answer only changes when somebody puts a store there.
local LOOK_AGAIN_EVERY = 20
local searchedFor = 0

local function nearCoordinator(x, y, z)
  if not coordPos then return false end
  return math.abs(x - coordPos.x) <= SEARCH_RADIUS
     and math.abs(y - coordPos.y) <= SEARCH_RADIUS
     and math.abs(z - coordPos.z) <= SEARCH_RADIUS
end

local DROP = { forward = turtle.drop, down = turtle.dropDown, up = turtle.dropUp }
local SUCK = { forward = turtle.suck, down = turtle.suckDown, up = turtle.suckUp }
local LOOK = { forward = turtle.inspect, down = turtle.inspectDown, up = turtle.inspectUp }

local function depotAtHand()
  if not coordPos then return nil end

  local present, info = turtle.inspectDown()
  if present and common.looksLikeDepot(info.name, depotTypes)
     and nearCoordinator(pos.x, pos.y - 1, pos.z) then
    return {
      store = { x = pos.x, y = pos.y - 1, z = pos.z },
      dock  = { x = pos.x, y = pos.y, z = pos.z },
      dir   = "down",
    }
  end

  -- Overhead as well. Climbing towards a store stops the moment the store
  -- itself is in the way, which leaves a turtle standing directly under the
  -- thing it is looking for.
  local above, what = turtle.inspectUp()
  if above and common.looksLikeDepot(what.name, depotTypes)
     and nearCoordinator(pos.x, pos.y + 1, pos.z) then
    return {
      store = { x = pos.x, y = pos.y + 1, z = pos.z },
      dock  = { x = pos.x, y = pos.y, z = pos.z },
      dir   = "up",
    }
  end

  for dir = 0, 3 do
    turnTo(dir)
    local f = common.FACINGS[dir]
    local sx, sz = pos.x + f.dx, pos.z + f.dz
    local there, what = turtle.inspect()
    if there and common.looksLikeDepot(what.name, depotTypes)
       and nearCoordinator(sx, pos.y, sz) then
      return {
        store  = { x = sx, y = pos.y, z = sz },
        dock   = { x = pos.x, y = pos.y, z = pos.z },
        dir    = "forward",
        facing = dir,
      }
    end
  end
  return nil
end

-- Every square within two of the coordinator, so a 5x5x5 cube centred on
-- it, nearest first: the block on top of it, then the ones against its
-- sides and underneath, then the shell beyond those. Sorted so that the
-- cheapest place to stand is always tried before the dearest.
local function cubeSquares()
  local squares = {}
  for dx = -SEARCH_RADIUS, SEARCH_RADIUS do
    for dy = -SEARCH_RADIUS, SEARCH_RADIUS do
      for dz = -SEARCH_RADIUS, SEARCH_RADIUS do
        if not (dx == 0 and dy == 0 and dz == 0) then
          squares[#squares + 1] = {
            x = coordPos.x + dx, y = coordPos.y + dy, z = coordPos.z + dz,
            far = math.abs(dx) + math.abs(dy) + math.abs(dz),
            -- Straight up before round the sides, and round the sides
            -- before underneath: a store gets put on top of a computer or
            -- against it far more often than beneath it.
            lie = (dy > 0 and 0) or (dy == 0 and 1) or 2,
          }
        end
      end
    end
  end
  table.sort(squares, function(a, b)
    if a.far ~= b.far then return a.far < b.far end
    if a.lie ~= b.lie then return a.lie < b.lie end
    if a.y ~= b.y then return a.y > b.y end
    if a.x ~= b.x then return a.x < b.x end
    return a.z < b.z
  end)
  return squares
end

-- The coordinator knows a store is attached to it but not which side, so
-- the first turtle that needs it goes and looks.
--
-- It looks inside a 5x5x5 cube round the coordinator and nowhere else. The
-- first storage-shaped block it sees is the one it uses, so a chest against
-- the coordinator costs a couple of moves; and when there is nothing there
-- at all the walk ends, because the cube is finite. What it must never do
-- is set off in some direction and keep going: a turtle that walks away
-- looking for a store is a turtle nobody finds again.
-- A turtle put down beside the store - which is the sensible place to put
-- one - is already standing where the walk below would have taken it. It
-- has usually taken a step by then, though: working out which way it faces
-- means moving, so the store it was stood next to is round a corner. Look
-- from here, then from each square one step off, before going anywhere.
local function depotWithinReach()
  local found = depotAtHand()
  if found then return found end

  for dir = 0, 3 do
    turnTo(dir)
    if not turtle.detect() and moveForward() then
      found = depotAtHand()
      if found then return found end
      -- Back where we started, opposite the way we came rather than
      -- opposite whichever way the looking left us pointing.
      turnTo((dir + 2) % 4)
      if not moveForward() then break end
    end
  end
  return nil
end

-- A store remembered from before - our own note, or one the coordinator is
-- still holding - is only worth anything if it is still beside this
-- coordinator. Bounding the search is no use on its own: a note pointing
-- somewhere else is walked to with no bound at all, which is how a turtle
-- ends up forty blocks away in state 'resupplying' having never searched
-- for anything. Notes outlive the thing they describe - the store gets
-- moved, the coordinator gets moved, the note was written by a version
-- that looked further afield than this one does.
local function forgetDistantDepot()
  -- Not knowing where the coordinator is - it has no GPS signal - is no
  -- reason to throw away a good note. Without a position there is nothing
  -- to measure against, so leave it alone.
  if not depot or not coordPos then return end
  local store = depot.store
  if nearCoordinator(store.x, store.y, store.z) then return end
  print(("the store I had noted (%s) is not next to the coordinator")
    :format(common.formatPos(store)))
  print("forgetting it and looking again")
  depot = nil
  saveLocal()
end

local function probeDepot()
  if not coordPos then return nil end

  local athand = depotWithinReach()
  if athand then
    print("the store is right here")
    return athand
  end

  print("looking for the resupply store within " .. SEARCH_RADIUS
    .. " blocks of the coordinator...")

  -- Get above the coordinator first, over whatever is between here and it:
  -- there may be a wall in the way, and since nothing outside the area may
  -- be broken the only way past is over the top. That climb is worth making
  -- once.
  local travelY = math.max(box and box.maxY or coordPos.y, coordPos.y + 1)
  goTo(coordPos.x, math.max(travelY, coordPos.y + 1), coordPos.z, travelY)

  -- From here on it is a walk round the coordinator, so it is kept to one:
  -- a ceiling just above the cube stops a square that cannot be reached -
  -- the inside of a wall, a block of the store itself - from being answered
  -- with a thirty-block detour over the top of it. There are a hundred and
  -- twenty-four of them and most will be solid.
  local roof = coordPos.y + SEARCH_RADIUS + 1
  local looked = 0

  for _, square in ipairs(cubeSquares()) do
    -- The walk is only ever finished in full when there is nothing to find,
    -- and a turtle with nothing to find has nowhere to refuel either. Stop
    -- while there is still enough in the tank to get back to work, so that
    -- putting a chest down actually fixes it.
    if fuel() < FUEL_MARGIN then
      print("running low on fuel - stopping the search short")
      break
    end

    if goTo(square.x, square.y, square.z, math.max(square.y, math.min(pos.y, roof)), roof) then
      looked = looked + 1
      local found = depotAtHand()
      if found then return found end
    end
  end

  print(("no storage found in the %d blocks round the coordinator (looked at %d)")
    :format((SEARCH_RADIUS * 2 + 1) ^ 3 - 1, looked))
  return nil
end

-- The slot holding the best thing to patch a floor with, dirt for choice.
local function fillSlot()
  for _, wanted in ipairs(FILL_BLOCKS) do
    for slot = 1, 16 do
      local item = turtle.getItemDetail(slot)
      if item and item.name:lower():find(wanted, 1, true) then return slot end
    end
  end
  return nil
end

-- Everything goes in the store except one stack to patch floors with. A
-- turtle that empties itself completely has nothing to fill the next hole
-- it opens, and leaves it gaping until it happens to dig some more dirt.
-- `keep` is a set of slot numbers, not one slot. Handing over everything
-- but a single slot is how a turtle that is filling with more than one
-- block loses all but the first of them.
local function dumpInventory(dir, keep)
  local drop = DROP[dir or "forward"]
  local blocked = false
  keep = keep or {}
  for slot = 1, 16 do
    if not keep[slot] and turtle.getItemCount(slot) > 0 then
      turtle.select(slot)
      drop()
      if turtle.getItemCount(slot) > 0 then blocked = true end
    end
  end
  turtle.select(1)
  return not blocked
end

-- Come away from the store with something to patch floors with. Same walk
-- as the fuel hunt: pull stacks out, keep the first useful one, hand the
-- rest straight back rather than sucking them round in circles.
local function takeFill(dir)
  if fillSlot() then return true end
  local suck, drop = SUCK[dir or "forward"], DROP[dir or "forward"]
  local held = {}
  for slot = 1, 16 do
    if turtle.getItemCount(slot) == 0 then
      turtle.select(slot)
      if not suck(64) then break end
      if fillSlot() == slot then return true end
      held[#held + 1] = slot
      if #held >= 8 then break end
    end
  end
  for _, slot in ipairs(held) do
    turtle.select(slot)
    drop()
  end
  turtle.select(1)
  return fillSlot() ~= nil
end

-- Walk the store looking for anything burnable. Non-fuel is held in the
-- turtle's own slots while we look and handed straight back afterwards, so
-- we never re-suck the same rubbish over and over.
local function takeFuel(target, dir)
  if fuel() >= target then return true end
  local suck, drop = SUCK[dir or "forward"], DROP[dir or "forward"]
  local held = {}
  for slot = 1, 16 do
    if fuel() >= target then break end
    if turtle.getItemCount(slot) == 0 then
      turtle.select(slot)
      if not suck(64) then break end
      if turtle.refuel(0) then
        turtle.refuel()
      else
        held[#held + 1] = slot
      end
    end
  end
  for _, slot in ipairs(held) do
    turtle.select(slot)
    drop()
  end
  turtle.select(1)
  return fuel() >= target
end

-- The shortest a route could possibly be. Real ones are longer: they climb
-- to the travel height, go round whatever will not move and come back down
-- again, so nothing should budget on this figure alone.
local MATERIAL_SLOTS = 8   -- half the inventory, leaving room for spoil

local function materialSlots()
  if not material then return 0 end
  local n = 0
  for slot = 1, 16 do
    local item = turtle.getItemDetail(slot)
    if item and isMaterial(item.name) then n = n + 1 end
  end
  return n
end

-- Load up with whatever we are filling with. Same walk as the fuel hunt:
-- pull stacks out, keep the ones that are the right thing, hand the rest
-- straight back.
local function holding(name)
  name = name:lower()
  for slot = 1, 16 do
    local item = turtle.getItemDetail(slot)
    if item and item.name:lower() == name then return true end
  end
  return false
end

-- How many pulls out of the store to spend hunting for a scarce block
-- before giving up on it for this trip. The store fills with spoil as the
-- job goes on, so what we want can be a long way down it - but not so far
-- that it is worth emptying the whole thing to find.
local HUNT = 32
local HUNT_RESERVE = 2     -- slots kept free so the hunt can always put back

local function takeMaterial(dir)
  if not material then return false end
  local suck, drop = SUCK[dir or "forward"], DROP[dir or "forward"]
  local held = {}

  -- Go looking for the blocks named after the first before filling up on
  -- the first itself. Those are the ones a turtle cannot make - it has no
  -- silk touch, so breaking a grass block hands it dirt - which means the
  -- only grass it will ever put back is grass it took out of the store.
  -- Fill every slot with the main block first and there is no room left to
  -- carry any, so every top goes down as the main block.
  for want = 2, #material do
    local name = material[want]
    if not holding(name) then
      for _ = 1, HUNT do
        local slot, free = nil, 0
        for i = 1, 16 do
          if turtle.getItemCount(i) == 0 then
            free = free + 1
            slot = slot or i
          end
        end
        -- Stop while there is still room to carry what we came for.
        -- Hunting until the inventory is full leaves nothing to load the
        -- actual fill into, and the turtle goes back to the job with an
        -- armful of somebody else's rubble and no blocks at all.
        if not slot or free <= HUNT_RESERVE then break end
        turtle.select(slot)
        if not suck(64) then break end
        local item = turtle.getItemDetail(slot)
        if item and item.name:lower() == name:lower() then break end
        -- Not it. Hold on to it so the next pull comes off the next stack
        -- rather than the same one, and put it all back at the end.
        held[#held + 1] = slot
      end
    end
  end

  -- Put back everything the hunt turned over before loading up. It has to
  -- happen here rather than at the end: the hunt uses slots to get past
  -- what it does not want, and those slots are the ones the fill needs.
  for _, slot in ipairs(held) do
    turtle.select(slot)
    drop()
  end
  held = {}

  for slot = 1, 16 do
    if materialSlots() >= MATERIAL_SLOTS then break end
    if turtle.getItemCount(slot) == 0 then
      turtle.select(slot)
      if not suck(64) then break end
      local item = turtle.getItemDetail(slot)
      if not (item and isMaterial(item.name)) then
        -- Hold onto it while we keep looking. The store fills up with spoil
        -- as the job goes on, so the thing we came for can be a long way
        -- down it, and every free slot is worth using to dig it out.
        held[#held + 1] = slot
      end
    end
  end

  for _, slot in ipairs(held) do
    turtle.select(slot)
    drop()
  end
  turtle.select(1)
  return materialSlots() > 0
end

local function tripCost(target)
  return math.abs(pos.x - target.x) + math.abs(pos.y - target.y) + math.abs(pos.z - target.z)
end

local function columnCost()
  if not box then return 0 end
  -- Down the column and back up it, plus a little for lining up.
  return (box.maxY - box.minY + 1) * 2 + 8
end

-- What it would take to finish the column in hand and still get back to the
-- store afterwards. The doubling is the difference between the straight
-- line and a route that actually has to get there.
local function reserveFrom(where)
  if not depot then return FUEL_MARGIN * 4 end
  local straight = math.abs(where.x - depot.dock.x)
    + math.abs(where.y - depot.dock.y)
    + math.abs(where.z - depot.dock.z)
  return straight * 2 + columnCost() + FUEL_MARGIN
end

-- Fill right up rather than taking just enough to get home. Fuel in the
-- tank costs nothing to carry, and a turtle that tops up with a few hundred
-- spends its life walking back and forth instead of digging.
local function tankTarget()
  local limit = turtle.getFuelLimit()
  if limit == nil or limit == "unlimited" then return FUEL_MARGIN * 8 end
  return math.floor(limit * 0.75)
end

local function needsDepot()
  if inventoryFull() then return true end
  if depot then
    return fuel() < reserveFrom(pos)
  end
  -- The store has not been found yet, so there is no trip to price up.
  -- Go looking while there is still plenty in the tank to get there.
  return fuel() < FUEL_MARGIN * 4
end

-- Enough to get to that column, work it, and get back from there.
local function canAfford(cell)
  if not depot or not box then return true end
  local top = { x = cell.x, y = box.maxY, z = cell.z }
  return fuel() >= tripCost(top) * 2 + reserveFrom(top)
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

-- Nothing outside the marked area may be broken, so getting to the store is
-- entirely a matter of going round what is in the way. There is nothing to
-- remember about the route: the walk climbs exactly when it is blocked and
-- gives the height straight back once there is floor under it, so it hugs
-- whatever is there rather than casting about for a height that works.
--
-- An earlier version tried a ladder of heights and remembered the one that
-- worked, and the fleet shared it. Measured over every job here, including
-- one with a wall twenty-two blocks above the area, it never once needed
-- anything but the first - so it was carrying a memory of nothing.
local function goToDock()
  local travelY = math.max(box and box.maxY or depot.dock.y, depot.dock.y + 1)
  return goTo(depot.dock.x, depot.dock.y, depot.dock.z, travelY)
end

local function useDepot()
  local dir = depot.dir or "forward"
  local travelY = math.max(box and box.maxY or depot.dock.y, depot.dock.y + 1)

  local ok, why = goToDock()
  if not ok then return false, why end
  if dir == "forward" then turnTo(depot.facing) end

  -- Hand over the spoil but hold on to what we are filling with.
  -- Everything we are filling with stays aboard, not just the first slot
  -- of it. The blocks named after the first are the ones that only ever
  -- come out of the ground - grass, say - and the store has none to give
  -- back, so handing one over loses it for good and the column it came off
  -- gets topped with plain fill instead.
  --
  -- Those go first when there is not room for all of it, for the same
  -- reason: the store is full of the first block and will hand back as much
  -- of it as we want.
  local keep = {}
  local slot = fillSlot()
  if slot then keep[slot] = true end

  if material then
    local precious, plain = {}, {}
    for s = 1, 16 do
      local item = turtle.getItemDetail(s)
      if item and isMaterial(item.name) then
        if item.name:lower() == material[1]:lower() then
          plain[#plain + 1] = s
        else
          precious[#precious + 1] = s
        end
      end
    end
    local room = MATERIAL_SLOTS
    for _, list in ipairs({ precious, plain }) do
      for _, s in ipairs(list) do
        if room <= 0 then break end
        if not keep[s] then
          keep[s] = true
          room = room - 1
        end
      end
    end
  end

  if not dumpInventory(dir, keep) then
    trouble("the resupply store is FULL - empty it or I cannot keep mining")
  end
  if not takeFuel(tankTarget(), dir) and fuel() < reserveFrom(pos) * 2 then
    trouble("not enough fuel in the resupply store - put coal in it")
  end
  if mode == "fill" then
    -- Leave with a load of whatever we are filling with.
    if not takeMaterial(dir) then
      trouble("no " .. tostring(material and material[1])
        .. " in the store - I cannot fill without it")
    end
  else
    -- Leave with something to patch floors with, even if that means taking
    -- back a stack of the dirt just handed over.
    takeFill(dir)
  end

  -- Get off the dock before handing the store on, so the next turtle in the
  -- queue is not walking into this one. Always upwards: when the dock is the
  -- roof of the store, down is the store itself.
  return goToY(math.max(travelY, depot.dock.y + 1))
end

-- Everything that happens at the chest, including the hunt for it, runs
-- under the coordinator's depot token. Looking for the chest is the one
-- job that would otherwise send the whole fleet to the same block at the
-- same moment, the first time they all start up together.
local function depotRun()
  local grant = claimDepot()
  if not grant then return false, "the depot never came free" end

  depotTypes = grant.depotTypes or depotTypes
  if not depot and grant.depot then
    depot = normaliseDepot(grant.depot)
    -- The coordinator's copy can be as stale as our own: it caches whatever
    -- the first turtle reported, and that turtle may have been on a version
    -- that looked further afield than this one does.
    forgetDistantDepot()
    if depot then saveLocal() end
  end

  local ok, why
  if not depot then
    state = "finding depot"
    -- Walking the cube found nothing last time, and nothing has moved
    -- since. Look again now and then, in case somebody has come and put a
    -- chest there, but not on every single attempt: without this the turtle
    -- walks the whole cube every time it wants fuel, which is a great deal
    -- of walking to reach the same answer.
    searchedFor = searchedFor + 1
    if searchedFor == 1 or searchedFor % LOOK_AGAIN_EVERY == 0 then
      depot = probeDepot()
    end
    if depot then
      searchedFor = 0
      print("resupply store found at " .. common.formatPos(depot.store))
      tell({ type = common.DEPOT_FOUND, depot = depot })
      saveLocal()
    end
  end

  if depot then
    state = "resupplying"
    ok, why = useDepot()

    -- Say where the store is whenever we have just used it. A turtle can
    -- know from a note on its own disk while the coordinator does not know
    -- at all, and the coordinator holds back work until somebody tells it.
    if ok then tell({ type = common.DEPOT_FOUND, depot = depot }) end

    -- A docking spot that cannot be reached any more is worse than none at
    -- all, because it will go on failing forever. Forget it and look again
    -- next time: the store may have been rebuilt, or the note may have come
    -- from a version that picked its spot differently.
    if not ok then
      print("cannot get to the docking spot any more - will look again")
      depot = nil
      saveLocal()
    end
  else
    ok, why = false, "no container next to the coordinator"
  end

  tell({ type = common.DEPOT_RELEASE })
  return ok, why
end

--------------------------------------------------------------------------
-- Mining
--------------------------------------------------------------------------

-- With nothing to do for a moment, get off the travel plane. Each turtle
-- waits at its own height above the area so they do not stack up on each
-- other either.
local function parkOutOfTheWay()
  if not box then return end
  -- Already off the site: nothing to get out of the way of, and climbing
  -- from out here is how a turtle ends up on the roof of something built
  -- over the area, having gone up outside it, across the top and found no
  -- way back down.
  if pos.x < box.minX or pos.x > box.maxX
     or pos.z < box.minZ or pos.z > box.maxZ then
    return
  end
  local parkY = box.maxY + 2 + (os.getComputerID() % 4)
  if pos.y >= parkY then return end
  goToY(parkY)
end

-- Somewhere out of the way entirely, on the side of the area the store is
-- on, spread along that side so a whole fleet standing down does not end up
-- in a heap. Above the area is not out of the way enough for a turtle that
-- has been told there is no work for it: it still has to be gone round.
local function standDownSpot()
  if not box then return nil end
  local id = os.getComputerID()
  local target = (depot and depot.dock) or coordPos
  -- At the area's own height, not above it. With something built over the
  -- area there is no above to get to, and a turtle told to stand down would
  -- spend the rest of the job trying to climb into a ceiling.
  local y = box.maxY

  local alongZ = box.minZ + (id % (box.maxZ - box.minZ + 1))
  local alongX = box.minX + (id % (box.maxX - box.minX + 1))

  -- The far side from the store, not the near one. Waiting on the store's
  -- side means waiting on the one path everybody uses to reach it, and a
  -- turtle standing on the docking square stops the whole fleet resupplying
  -- - which is the opposite of getting out of the way.
  if target and target.x > box.maxX then
    return { x = box.minX - 3, y = y, z = alongZ }
  elseif target and target.x < box.minX then
    return { x = box.maxX + 3, y = y, z = alongZ }
  elseif target and target.z > box.maxZ then
    return { x = alongX, y = y, z = box.minZ - 3 }
  end
  return { x = alongX, y = y, z = box.maxZ + 3 }
end

-- Standing outside the area is not the same as being out of the way. The
-- one square every turtle in the fleet has to reach is the docking square,
-- and that is always outside the area - so a turtle that has just left the
-- store and been told to stand clear is standing on the worst block on the
-- job. The whole column above the dock counts, since that is how everybody
-- comes down onto it.
local function blocksTheStore()
  local dock = depot and depot.dock
  if not dock then return false end
  return math.abs(pos.x - dock.x) <= 1 and math.abs(pos.z - dock.z) <= 1
end

-- A turtle already outside the area that is only in the store's way needs
-- to step aside, not walk the length of the job to the far side of it -
-- which in fill mode means crossing ground it has just made solid. Further
-- out than the dock, so it is behind the queue rather than in it, and
-- spread out by id so a whole shift does not stack up on one square.
local function asideFromStore()
  local dock = depot and depot.dock
  if not dock or not box then return nil end
  local awayX = (dock.x > box.maxX and 1) or (dock.x < box.minX and -1) or 0
  local awayZ = (dock.z > box.maxZ and 1) or (dock.z < box.minZ and -1) or 0
  if awayX == 0 and awayZ == 0 then return nil end
  local out = 2 + (os.getComputerID() % 3)
  return { x = dock.x + awayX * out, y = dock.y, z = dock.z + awayZ * out }
end

local function standDown()
  if not box then return end

  if blocksTheStore() then
    local aside = asideFromStore()
    -- Keep the height it already has: it has just left the store, and
    -- coming down to get out of the way puts it back behind the store.
    if aside and goTo(aside.x, aside.y, aside.z, math.max(aside.y, pos.y)) then
      return
    end
    -- Could not step aside, so fall through and go properly clear.
  elseif pos.x < box.minX or pos.x > box.maxX
         or pos.z < box.minZ or pos.z > box.maxZ then
    -- Already clear of the area and not in the store's way, so there is
    -- nothing to do but wait.
    return
  end

  local spot = standDownSpot()
  if not spot then return end
  -- Out at the height the job is worked at, which is a road that exists
  -- whether or not there is sky over the area.
  goTo(spot.x, spot.y, spot.z, box.maxY)
end

-- Lava and water are not dug, they are displaced: lay a block into one and
-- it is gone, then break that block and the space is properly empty. Doing
-- it to a source is permanent. Doing it to a flow only buys a moment, since
-- it refills from whatever source is feeding it - so only sources are worth
-- the block, and once they are gone the flows drain on their own.
--
-- Without this a turtle swims through a column of lava without noticing,
-- digs nothing, and leaves the finished area full of it.
local function displaceFluidBelow()
  local present, info = turtle.inspectDown()
  if not present or not common.isFluid(info.name) then return true end
  if not common.isFluidSource(info) then return true end

  if not selectFill() then
    trouble("found " .. info.name .. " and have nothing to plug it with")
    return false
  end
  local plugged = turtle.placeDown()
  turtle.select(1)
  if not plugged then return false end
  return true
end

-- Clear one column of the box from the top down, patch the floor beneath
-- it, then climb back to the travel plane. Returns "done", "full" when the
-- inventory needs emptying part-way, or "blocked" with a reason.
local function digCell(cell)
  state = "mining"

  local ok, why = goTo(cell.x, box.maxY, cell.z, box.maxY)
  if not ok then return "blocked", why end

  while pos.y > box.minY do
    if inventoryFull() then return "full" end
    -- Plug anything liquid before dropping into it, so it is dug out like
    -- everything else rather than closing over the turtle's head.
    displaceFluidBelow()
    local moved, reason = moveDown()
    if not moved then return "blocked", reason end
  end

  if floorPatch and not turtle.detectDown() and selectFill() then
    turtle.placeDown()
    turtle.select(1)
  end

  local climbed, climbWhy = goToY(box.maxY)
  if not climbed then return "blocked", climbWhy end
  return "done"
end

--------------------------------------------------------------------------
-- Draining
--------------------------------------------------------------------------

-- Go down a column as far as open space allows, plugging every source on
-- the way. Nothing is dug: where the ground is solid the turtle simply
-- stops, because there is no fluid there it could have reached anyway.
--
-- Returns how many sources it plugged, so the coordinator knows whether
-- another pass is worth making - draining a source lets what it was feeding
-- run away, which uncovers more.
local function drainCell(cell)
  state = "draining"

  local plugged = 0
  local ok = goTo(cell.x, box.maxY, cell.z, box.maxY)

  if ok then
    while pos.y > box.minY do
      local present, info = turtle.inspectDown()

      if present and common.isFluid(info.name) then
        if common.isFluidSource(info) and selectFill() then
          if turtle.placeDown() then
            plugged = plugged + 1
            -- Take the plug straight back out: the point is to be rid of
            -- the lava, not to leave a pillar of dirt where it was.
            turtle.digDown()
          end
          turtle.select(1)
        end
      elseif present then
        break                  -- solid ground, and nothing to dig through
      end

      if not moveDown() then break end
    end
  end

  goToY(box.maxY)
  return plugged
end

--------------------------------------------------------------------------
-- Filling
--------------------------------------------------------------------------

-- The route to a column while filling: out to the road, along it to the
-- column's own row, then out along that row. Never a diagonal shortcut,
-- because a shortcut is exactly what crosses a column already finished -
-- and crossing one means digging its top block out to get through.
--
-- It holds because every row is worked from its far end inwards, so the
-- half of a row nearest the road is still open for as long as that row has
-- anything left to do.
local function goToViaSpine(cx, cz, travelY, ceiling)
  if not spine then return goTo(cx, box.maxY, cz, travelY, ceiling) end

  local onRoad = (spine.axis == "x" and cx == spine.value)
              or (spine.axis == "z" and cz == spine.value)

  -- Which side of the road the world is: the far side from the area, which
  -- is the side the store is on.
  local outward = (spine.axis == "x")
    and (spine.value == box.maxX and 1 or -1)
    or  (spine.value == box.maxZ and 1 or -1)

  local legs
  if onRoad then
    -- The road is filled as one long retreat towards the store: fill a
    -- square, step to the next one along, seal the one just left behind
    -- from there. A turtle already standing on the road simply carries on
    -- along it, and everything between it and its next square is nearer the
    -- store, so it is still open.
    --
    -- Coming back to the road after a trip to the store, it goes in at the
    -- mouth - the square nearest the store, which is the very last one
    -- filled and so open until the end - and walks up from there. That way
    -- the only clear ground the road ever needs is the step outside its own
    -- mouth, which is the way to the store anyway.
    local onRoadNow = (spine.axis == "x" and pos.x == spine.value)
                   or (spine.axis == "z" and pos.z == spine.value)
    if onRoadNow then
      legs = { { cx, cz } }
    elseif spine.axis == "x" then
      -- The store can be unknown here: forgotten because the note pointed
      -- nowhere, or given up on because the dock stopped working. The road
      -- still has a mouth, so aim at the near end of it rather than
      -- falling over.
      local mz = math.max(box.minZ, math.min(box.maxZ,
        depot and depot.dock.z or box.minZ))
      legs = {
        { spine.value + outward, mz },   -- outside the mouth
        { spine.value, mz },             -- in at the mouth
        { cx, cz },                      -- up the road to the square
      }
    else
      local mx = math.max(box.minX, math.min(box.maxX,
        depot and depot.dock.x or box.minX))
      legs = {
        { mx, spine.value + outward },
        { mx, spine.value },
        { cx, cz },
      }
    end
  elseif spine.axis == "x" then
    legs = {
      { spine.value, pos.z },   -- back to the road along the row we are on
      { spine.value, cz },      -- along the road to the right row
      { cx, cz },               -- out along that row
    }
  else
    legs = {
      { pos.x, spine.value },
      { cx, spine.value },
      { cx, cz },
    }
  end

  -- Down to the road first, not just up to it. This is the way used when
  -- there is no sky over the area, which means the turtle has very likely
  -- just tried the high road and is now sitting above a ceiling it cannot
  -- break. Coming down is safe: outside the area there is nothing it is
  -- allowed to dig, so a descent either finds air or stops.
  if travelY then goToY(travelY) end
  for _, leg in ipairs(legs) do
    local ok, why = goToXZ(leg[1], leg[2], travelY, ceiling)
    if not ok then return false, why end
  end
  return goToY(box.maxY)
end

local function selectNamed(want)
  if not want then return false end
  want = want:lower()
  for slot = 1, 16 do
    local item = turtle.getItemDetail(slot)
    if item and item.name:lower() == want then
      turtle.select(slot)
      return true
    end
  end
  return false
end

-- Whatever came out of this spot, if we still have it and it counts. Else
-- the block we are filling with.
local function selectMaterial(wasHere)
  if not material then return false end
  if wasHere and isMaterial(wasHere) and selectNamed(wasHere) then return true end
  return selectNamed(material[1])
end

-- Which way home is. Columns are given out furthest-from-the-store first,
-- so the neighbour in this direction has not been filled yet and can be
-- stood in.
-- Where the road meets the store: the square on it nearest the store, and
-- the last one of the lot to be filled.
local function roadMouth()
  if not spine or not depot then return nil end
  if spine.axis == "x" then
    return spine.value, math.max(box.minZ, math.min(box.maxZ, depot.dock.z))
  end
  return math.max(box.minX, math.min(box.maxX, depot.dock.x)), spine.value
end

-- Which way home is. Off the road that is simply towards the store.
--
-- On the road it is towards the mouth instead, which is not the same thing:
-- the road can run past the mouth and out the other side, and a turtle down
-- that end pointed straight at the store walks into whatever is beside the
-- road rather than back along it.
local function towardStore()
  local onRoadNow = spine and
    ((spine.axis == "x" and pos.x == spine.value)
     or (spine.axis == "z" and pos.z == spine.value))

  if onRoadNow then
    local mx, mz = roadMouth()
    if mx then
      if spine.axis == "x" then
        if pos.z < mz then return 2 end
        if pos.z > mz then return 0 end
      else
        if pos.x < mx then return 1 end
        if pos.x > mx then return 3 end
      end
      -- Standing on the mouth itself: out of the area, towards the store.
      if spine.axis == "x" then
        return spine.value == box.maxX and 1 or 3
      end
      return spine.value == box.maxZ and 2 or 0
    end
  end

  local target = (depot and depot.dock) or coordPos
  if not target then return nil end
  local dx, dz = target.x - pos.x, target.z - pos.z
  if math.abs(dx) >= math.abs(dz) then
    return dx >= 0 and 1 or 3
  end
  return dz >= 0 and 2 or 0
end

local function layInto(place, wasHere)
  if not selectMaterial(wasHere) then
    return false, "out of " .. tostring(material[1])
  end
  local ok = place()
  turtle.select(1)
  return ok
end

-- Get off the column just filled and put the last block in behind, since
-- there is no standing on a block while you place it.
--
-- Straight up is the way whenever there is room, which there usually is:
-- one step and lay it back down. Only when something is sitting on the area
-- does the turtle have to go sideways instead, and then only onto ground
-- nobody has filled yet - stepping into a finished column would mean
-- digging it back out to get in, which just moves the hole along.
local function retreatAndSeal(wasHere)
  if not turtle.detectUp() and moveUp() then
    local laid, why = layInto(turtle.placeDown, wasHere)
    if laid then return true end
    return false, why or "could not lay the top block from above"
  end

  -- Towards the store is the one direction guaranteed not to be filled
  -- yet, because that is the order the columns go out in - so it is worth
  -- digging into. Any other direction might be a column already finished,
  -- and cutting into one of those to get out just carries the hole along
  -- with us, so those are only used if they are already open.
  -- Never back into a column that is already done. Getting in would mean
  -- digging its top block out, and the block we lay goes into the column we
  -- came from - so the hole simply moves along, and the last one in the
  -- chain stays open. A neighbour made of the stuff we are filling with has
  -- been done already.
  local function open(dir)
    turnTo(dir)
    local present, info = turtle.inspect()
    if not present then return true end
    return not isMaterial(info.name)
  end

  local home = towardStore()
  if home and open(home) then
    turnTo(home)
    if moveForward() then
      turnTo((facing + 2) % 4)
      local laid, why = layInto(turtle.place, wasHere)
      if laid then return true end
      if why then return false, why end
      turnTo((facing + 2) % 4)
    end
  end

  for dir = 0, 3 do
    if dir ~= home and open(dir) then
      turnTo(dir)
      if not turtle.detect() and moveForward() then
        turnTo((facing + 2) % 4)
        local laid, why = layInto(turtle.place, wasHere)
        if laid then return true end
        if why then return false, why end
        turnTo((facing + 2) % 4)
      end
    end
  end
  return false, "nowhere to step to seal the column"
end

-- Make one column solid, top to bottom. Dig it out first - a block cannot
-- be placed where another already is - then climb back out laying material
-- underfoot, and seal the last block from the neighbour on the way home.
-- Whatever comes out that matches the material goes straight back in, so
-- filling stone with stone costs almost nothing from the store.
-- What was in each block of the column we are part way through, kept
-- across going away to empty out and coming back. Without it the second
-- attempt at a column looks down at the hole the first attempt dug, sees
-- air, and concludes there was never anything there - so the grass it is
-- still carrying never goes back on, and plain fill goes down instead.
local partCell, partWasHere = nil, nil

local function fillCell(cell)
  state = "filling"
  if not material then return "blocked", "nothing to fill with" end

  -- Two ways to get there, and which one works depends on the sky. One
  -- above the area is the good road: a finished column is solid, and coming
  -- back down to the area's own top would mean digging out work already
  -- done. But with something built over the area that road is the underside
  -- of somebody's floor, and then the only way across is at the area's own
  -- top, through the columns still to do - which is exactly where the
  -- furthest-first ordering leaves open ground.
  -- Over the top of the area where there is sky for it, since a finished
  -- column is solid and crossing one at its own height would take the top
  -- off it. Where something is built over the area there is no room up
  -- there, and then the way across is the road: out to the open row, along
  -- it, and out along this column's own row, over ground that has to be dug
  -- anyway.
  --
  -- Which of the two applies is not something to guess at halfway across -
  -- a turtle that starts over the top and finds a ceiling in the way ends
  -- up stranded on the roof of the job. So the road is used until the
  -- turtle has stood in a column and looked up once, and from then on it
  -- knows.
  -- Note what was in each block on the way down, so anything that already
  -- counts as material goes back exactly as it was. The top block has to be
  -- looked at from above, because moving into a column is what digs it -
  -- and the top block is where the grass lives.
  local wasHere = {}
  if partCell and partCell.x == cell.x and partCell.z == cell.z then
    wasHere = partWasHere
  end
  partCell, partWasHere = cell, wasHere

  local ok, why
  if skyOverhead then
    ok, why = goTo(cell.x, box.maxY + 1, cell.z, box.maxY + 1, box.maxY + 1)
    if ok then
      local present, info = turtle.inspectDown()
      if present then wasHere[box.maxY] = info.name end
      ok, why = goToY(box.maxY)
    end
  end
  if not ok then
    ok, why = goToViaSpine(cell.x, cell.z, box.maxY, box.maxY)
  end
  if not ok then return "blocked", why end

  if skyOverhead == nil then
    skyOverhead = not turtle.detectUp()
    print(skyOverhead and "there is sky over the area - going over the top"
      or "something is over the area - working along the road")
  end

  while pos.y > box.minY do
    if inventoryFull() then return "full" end
    local present, info = turtle.inspectDown()
    if present then wasHere[pos.y - 1] = info.name end
    local moved, reason = moveDown()
    if not moved then return "blocked", reason end
  end

  while pos.y < box.maxY do
    if not selectMaterial(wasHere[pos.y]) then return "empty" end
    local climbed, climbWhy = moveUp()
    if not climbed then return "blocked", climbWhy end
    if not turtle.placeDown() then
      turtle.select(1)
      return "blocked", "could not lay a block"
    end
    turtle.select(1)
  end

  local sealed, sealWhy = retreatAndSeal(wasHere[box.maxY])
  if not sealed then
    if sealWhy and sealWhy:find("out of", 1, true) then return "empty" end
    return "blocked", sealWhy
  end
  partCell, partWasHere = nil, nil
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
        trouble("could not reach the resupply store: " .. tostring(why))
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
      elseif reply.type == common.NO_CELL and reply.findDepot then
        -- No work goes out until the store has been found, so go and find
        -- it. The token means only one turtle is off looking at a time.
        local ok, why = depotRun()
        if not ok then
          trouble("could not find the resupply store: " .. tostring(why))
          sleep(5)
        end
      elseif reply.type == common.NO_CELL and reply.standDown then
        -- More fleet than there is room for. Get right out of the area and
        -- wait there, and ask less often while doing it.
        if state ~= "stood down" then
          print("no room for me on this job - standing clear")
        end
        state = "stood down"
        standDown()
        sleep(15)
      elseif reply.type == common.NO_CELL then
        state = "parked"
        parkOutOfTheWay()
        sleep(3)
      elseif reply.type == common.CELL then
        myCell = reply.cell
        mode = reply.mode or mode
        material = reply.material or material
        if type(material) == "string" then material = { material } end
        spine = reply.spine or spine
        if reply.floorPatch ~= nil then floorPatch = reply.floorPatch end
        print(("%s %d,%d"):format(mode == "fill" and "fill" or "cell",
          myCell.x, myCell.z))
      end
    end

    -- Work out whether that column is affordable before setting off for
    -- it, rather than finding out at the bottom of it. Handing it straight
    -- back costs nothing; running dry halfway down strands the turtle.
    if myCell and not canAfford(myCell) then
      tell({
        type = common.CELL_SKIP, cell = myCell,
        reason = "too far on the fuel I have", transient = true,
      })
      myCell = nil
      local ok, why = depotRun()
      if not ok then
        trouble("could not reach the resupply store: " .. tostring(why))
        sleep(5)
      end
    end

    if myCell then
      local status, detail, plugged
      if mode == "fill" then
        status, detail = fillCell(myCell)
      elseif mode == "drain" then
        plugged = drainCell(myCell)
        status = "done"
      else
        status, detail = digCell(myCell)
      end

      -- Out of what it is meant to be laying down: go and get more, and
      -- come back to the same column.
      if status == "empty" then
        trouble("out of " .. tostring(material and material[1])
          .. " - put some in the store")
        local got = depotRun()
        if not got then sleep(5) end
        status = "full"
      end

      if status == "done" then
        tell({ type = common.CELL_DONE, cell = myCell, plugged = plugged })
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
    giveUp("no modem attached - a turtle needs a wireless modem")
  end
  coordId = findCoordinator()
  if not coordId then
    giveUp("could not find the coordinator - is coordinator.lua running?")
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

-- Print exactly what the turtle sees around it, state table and all. What
-- CC reports for a fluid - whether it shows up at all, and whether it says
-- which are source blocks and which are only flowing - decides how lava can
-- be dealt with, and that is worth knowing rather than assuming.
local LOOK_FILE = "look.txt"

-- A turtle screen is a few lines with no way back up them, so this keeps
-- what it says short and puts the whole of it in a file to read at leisure.
local function cmdLook()
  local lines = {}
  local function record(text) lines[#lines + 1] = text end

  local function summary(where, present, info)
    if not present then return where .. ": nothing" end
    local bits = {}
    for key, value in pairs(info.state or {}) do
      bits[#bits + 1] = tostring(key) .. "=" .. tostring(value)
    end
    table.sort(bits)
    local name = tostring(info.name)
    if #bits == 0 then return where .. ": " .. name end
    return where .. ": " .. name .. " " .. table.concat(bits, " ")
  end

  local function detail(where, present, info)
    record("")
    record("[" .. where .. "]")
    if not present then
      record("  nothing here - air, or something CC does not report")
      return
    end
    record("  name  " .. tostring(info.name))
    local keys = {}
    for key in pairs(info.state or {}) do keys[#keys + 1] = tostring(key) end
    table.sort(keys)
    for _, key in ipairs(keys) do
      record(("  state %s = %s"):format(key, tostring(info.state[key])))
    end
    local tags = {}
    for tag in pairs(info.tags or {}) do tags[#tags + 1] = tag end
    table.sort(tags)
    for _, tag in ipairs(tags) do record("  tag   " .. tag) end
  end

  local fp, fi = turtle.inspect()
  local up, ui = turtle.inspectUp()
  local dp, di = turtle.inspectDown()

  -- Short enough to read on the turtle itself.
  print(summary("front", fp, fi))
  print(summary("up", up, ui))
  print(summary("down", dp, di))
  print(("detect f=%s u=%s d=%s"):format(
    tostring(turtle.detect()), tostring(turtle.detectUp()),
    tostring(turtle.detectDown())))

  -- And the whole of it on disk.
  record("flatten " .. tostring(common.VERSION)
    .. " look, turtle " .. os.getComputerID())
  local here = gpsPos(2)
  if here then record("at " .. common.formatPos(here)) end
  record(("detect  front=%s up=%s down=%s"):format(
    tostring(turtle.detect()), tostring(turtle.detectUp()),
    tostring(turtle.detectDown())))
  detail("front", fp, fi)
  detail("up", up, ui)
  detail("down", dp, di)

  local file = fs.open(LOOK_FILE, "a")
  if not file then
    print("(could not write " .. LOOK_FILE .. ")")
    return
  end
  for _, line in ipairs(lines) do file.writeLine(line) end
  file.writeLine("")
  file.close()
  print("added to " .. LOOK_FILE .. " - 'edit " .. LOOK_FILE .. "' to read")
end

local function cmdStatus()
  local saved = common.loadState(STATE_FILE)
  print("turtle id: " .. os.getComputerID())
  print("fuel: " .. tostring(turtle.getFuelLevel()))
  local p = gpsPos(2)
  print("position: " .. common.formatPos(p))
  if saved and saved.depot then
    print("depot: " .. common.formatPos(saved.depot.store))
  else
    print("depot: not found yet")
  end
end

local function cmdWork()
  connect()

  -- Fuel first: everything below needs to be able to move, and a turtle
  -- that cannot move cannot even work out which way it is facing.
  if not refuelFromInventory(FUEL_MARGIN) then
    giveUp("out of fuel - put coal in my inventory to get started")
  end

  local ok, why = measureFacing()
  if not ok then giveUp(why) end

  local saved = common.loadState(STATE_FILE)
  if saved and saved.depot then depot = normaliseDepot(saved.depot) end

  local welcome = ask({ type = common.HELLO, pos = pos, version = common.VERSION }, 10)
  if not welcome then giveUp("the coordinator did not answer my hello") end
  if welcome.type == common.NACK then giveUp(tostring(welcome.message)) end
  if welcome.version ~= common.VERSION then
    giveUp(("version mismatch: I am %s, the coordinator is %s - run 'update all' on both")
      :format(tostring(common.VERSION), tostring(welcome.version)))
  end

  box = welcome.box
  depot = normaliseDepot(welcome.depot) or depot
  coordPos = welcome.coordPos
  depotTypes = welcome.depotTypes or depotTypes
  mode = welcome.mode or mode
  material = welcome.material
  -- Older coordinators sent a single block rather than a list.
  if type(material) == "string" then material = { material } end
  spine = welcome.spine
  if welcome.floorPatch ~= nil then floorPatch = welcome.floorPatch end
  if not box then
    giveUp("no area marked yet - run 'flatten mark1' and 'flatten mark2' on a turtle")
  end

  forgetDistantDepot()

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

print(("flatten %s (turtle %d)"):format(common.VERSION, os.getComputerID()))

if command == "mark1" then
  cmdMark(1)
elseif command == "mark2" then
  cmdMark(2)
elseif command == "status" then
  cmdStatus()
elseif command == "look" then
  if not turtle then error("this only runs on a turtle", 0) end
  cmdLook()
elseif command == "work" then
  if not turtle then error("this only runs on a turtle", 0) end
  cmdWork()
else
  print("Usage: flatten [mark1|mark2|status|look]")
  print("  no argument joins the fleet and starts working")
end
