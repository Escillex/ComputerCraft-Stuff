-- coordinator.lua
-- Runs on a stationary computer + modem near the shared chest. Splits one
-- box into regions, hands them to turtles running `flatten fleet`, and
-- arbitrates the shared chest.
--
-- coordinator <x1> <y1> <z1> <x2> <y2> <z2> <turtleCount> <chestX> <chestY> <chestZ> <chestDir>
-- coordinator   (prompts instead)
--
-- chestX/Y/Z is the resupply park spot; chestDir is a compass direction
-- (north/south/east/west/up/down) since there's no turtle facing here to
-- be relative to - each turtle converts it with its own GPS facing.

local PROTOCOL = "flatten_fleet"

----------------------------------------------------------------------
-- Input
----------------------------------------------------------------------

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

local COMPASS_WORDS = {
  north = true, n = true, south = true, s = true,
  east = true, e = true, west = true, w = true, up = true, u = true, down = true, d = true,
}

local function readDirection(promptText)
  while true do
    io.write(promptText .. " (north/south/east/west/up/down): ")
    local input = read()
    if input and COMPASS_WORDS[input:lower()] then return input:lower() end
    print("Please enter one of: north, south, east, west, up, down.")
  end
end

local function readCount(promptText)
  while true do
    io.write(promptText .. ": ")
    local n = tonumber(read())
    if n and n >= 1 then return math.floor(n + 0.5) end
    print("Please enter a whole number of at least 1.")
  end
end

local args = { ... }
local x1, y1, z1, x2, y2, z2, turtleCount, chestX, chestY, chestZ, chestDir

if #args >= 11 then
  x1, y1, z1 = tonumber(args[1]), tonumber(args[2]), tonumber(args[3])
  x2, y2, z2 = tonumber(args[4]), tonumber(args[5]), tonumber(args[6])
  turtleCount = tonumber(args[7])
  chestX, chestY, chestZ = tonumber(args[8]), tonumber(args[9]), tonumber(args[10])
  chestDir = tostring(args[11]):lower()
  if not (x1 and y1 and z1 and x2 and y2 and z2 and turtleCount and chestX and chestY and chestZ
      and COMPASS_WORDS[chestDir]) then
    error("Usage: coordinator <x1> <y1> <z1> <x2> <y2> <z2> <turtleCount> <chestX> <chestY> <chestZ> <chestDir>\n" ..
      "chestDir must be a compass direction: north/south/east/west/up/down (or n/s/e/w/u/d).")
  end
  turtleCount = math.floor(turtleCount + 0.5)
else
  print("Job box - enter the two corner positions as real (F3) coordinates.")
  x1, y1, z1 = readCoordTriple("Corner 1")
  x2, y2, z2 = readCoordTriple("Corner 2")
  turtleCount = readCount("How many turtles will work this job")
  print("Shared resupply chest - park spot coordinates and which direction the chest is from there.")
  chestX, chestY, chestZ = readCoordTriple("Park spot")
  chestDir = readDirection("Chest direction")
end

----------------------------------------------------------------------
-- Region division: split the longer axis into turtleCount strips
----------------------------------------------------------------------

local minX, maxX = math.min(x1, x2), math.max(x1, x2)
local minY, maxY = math.min(y1, y2), math.max(y1, y2)
local minZ, maxZ = math.min(z1, z2), math.max(z1, z2)

local function divideRegions(n)
  local width, depth = maxX - minX + 1, maxZ - minZ + 1
  local regions = {}
  if width >= depth then
    local base, extra = math.floor(width / n), width % n
    local x = minX
    for i = 1, n do
      local w = base + (i <= extra and 1 or 0)
      if w > 0 then
        regions[#regions + 1] = { x1 = x, y1 = minY, z1 = minZ, x2 = x + w - 1, y2 = maxY, z2 = maxZ }
        x = x + w
      end
    end
  else
    local base, extra = math.floor(depth / n), depth % n
    local z = minZ
    for i = 1, n do
      local d = base + (i <= extra and 1 or 0)
      if d > 0 then
        regions[#regions + 1] = { x1 = minX, y1 = minY, z1 = z, x2 = maxX, y2 = maxY, z2 = z + d - 1 }
        z = z + d
      end
    end
  end
  return regions
end

local regions = divideRegions(turtleCount)
local nextRegion = 1

print(("Box: x %d..%d, y %d..%d, z %d..%d"):format(minX, maxX, minY, maxY, minZ, maxZ))
print(("Split into %d region(s) for up to %d turtle(s):"):format(#regions, turtleCount))
for i, r in ipairs(regions) do
  print(("  %d: x %d..%d, y %d..%d, z %d..%d"):format(i, r.x1, r.x2, r.y1, r.y2, r.z1, r.z2))
end
if #regions < turtleCount then
  print(("Note: box too narrow for %d regions - only the first %d registrant(s) get work."):format(
    turtleCount, #regions))
end

----------------------------------------------------------------------
-- Networking
----------------------------------------------------------------------

local modemSide = nil
for _, side in ipairs(peripheral.getNames()) do
  if peripheral.getType(side) == "modem" then
    modemSide = side
    break
  end
end
if not modemSide then
  error("No modem attached to this computer - the coordinator needs a wireless/ender modem.")
end
rednet.open(modemSide)
rednet.host(PROTOCOL, "coordinator")
print(("Hosting on protocol '%s' via modem '%s'."):format(PROTOCOL, modemSide))

----------------------------------------------------------------------
-- Chest queue - one holder at a time
----------------------------------------------------------------------

local chestHolder = nil
local chestQueue = {}

local function grantNext()
  if chestHolder == nil and #chestQueue > 0 then
    chestHolder = table.remove(chestQueue, 1)
    rednet.send(chestHolder, { type = "chest_granted" }, PROTOCOL)
    print(("chest: granted to turtle %d"):format(chestHolder))
  end
end

----------------------------------------------------------------------
-- Main loop
----------------------------------------------------------------------

local assignedTo = {} -- turtle id -> region index
local lastPos = {} -- turtle id -> { x, y, z, cell, total, seenAt }

local function rednetLoop()
  while true do
    local senderId, message = rednet.receive(PROTOCOL)
    if type(message) == "table" then
      if message.type == "pos" then
        lastPos[senderId] = {
          x = message.x, y = message.y, z = message.z,
          cell = message.cell, total = message.total, seenAt = os.epoch("utc"),
        }
      elseif message.type == "register" then
        local regionIndex = assignedTo[senderId]
        if not regionIndex and nextRegion <= #regions then
          regionIndex = nextRegion
          assignedTo[senderId] = regionIndex
          nextRegion = nextRegion + 1
        end
        if regionIndex then
          local r = regions[regionIndex]
          rednet.send(senderId, {
            type = "assigned",
            region = { x1 = r.x1, y1 = r.y1, z1 = r.z1, x2 = r.x2, y2 = r.y2, z2 = r.z2 },
            chest = { x = chestX, y = chestY, z = chestZ, dir = chestDir },
          }, PROTOCOL)
          print(("turtle %d: assigned region %d (x %d..%d, z %d..%d)"):format(
            senderId, regionIndex, r.x1, r.x2, r.z1, r.z2))
        else
          rednet.send(senderId, { type = "no_region" }, PROTOCOL)
          print(("turtle %d: no region left to assign"):format(senderId))
        end
      elseif message.type == "chest_request" then
        if chestHolder == senderId then
          rednet.send(senderId, { type = "chest_granted" }, PROTOCOL)
        elseif chestHolder == nil then
          chestHolder = senderId
          rednet.send(senderId, { type = "chest_granted" }, PROTOCOL)
          print(("chest: granted to turtle %d"):format(senderId))
        else
          local alreadyQueued = false
          for _, id in ipairs(chestQueue) do
            if id == senderId then alreadyQueued = true break end
          end
          if not alreadyQueued then
            chestQueue[#chestQueue + 1] = senderId
            print(("chest: turtle %d queued (%d waiting)"):format(senderId, #chestQueue))
          end
        end
      elseif message.type == "chest_release" then
        if chestHolder == senderId then
          chestHolder = nil
          print(("chest: released by turtle %d"):format(senderId))
          grantNext()
        end
      end
    end
  end
end

local function printHelp()
  print("Commands:")
  print("  list              - show region assignments and chest queue status")
  print("  free <region#>    - release a region so the next new registrant gets it")
  print("  ping              - ask every connected turtle for a LIVE gps.locate() position")
  print("  reset <turtleId>|all - ping turtle(s) AND correct their tracked position to match")
  print("  help              - show this again")
end

local function commandLoop()
  printHelp()
  while true do
    io.write("> ")
    local input = read()
    local cmd, rest = (input or ""):match("^%s*(%S*)%s*(.-)%s*$")
    cmd = (cmd or ""):lower()
    if cmd == "list" then
      local any = false
      for id, idx in pairs(assignedTo) do
        any = true
        local r = regions[idx]
        local p = lastPos[id]
        local posStr
        if p then
          local secondsAgo = math.floor((os.epoch("utc") - p.seenAt) / 1000)
          posStr = (", last at (%d,%d,%d), cell %d/%d, seen %ds ago"):format(
            p.x, p.y, p.z, p.cell, p.total, secondsAgo)
        else
          posStr = ", no position report yet"
        end
        print(("  turtle %d -> region %d (x %d..%d, z %d..%d)%s"):format(
          id, idx, r.x1, r.x2, r.z1, r.z2, posStr))
      end
      if not any then print("  (no turtles registered yet)") end
      print(("  chest: %s%s"):format(
        chestHolder and ("held by turtle " .. chestHolder) or "free",
        #chestQueue > 0 and (", " .. #chestQueue .. " waiting") or ""))
    elseif cmd == "free" then
      local idx = tonumber(rest)
      if not idx or not regions[idx] then
        print("Usage: free <region#> - see 'list' for valid region numbers.")
      else
        local freedFrom = {}
        for id, ri in pairs(assignedTo) do
          if ri == idx then
            assignedTo[id] = nil
            freedFrom[#freedFrom + 1] = id
          end
        end
        if #freedFrom == 0 then
          print(("Region %d wasn't assigned to anyone."):format(idx))
        else
          print(("Freed region %d (was turtle %s) - the next new registrant will get it."):format(
            idx, table.concat(freedFrom, ", ")))
        end
      end
    elseif cmd == "ping" then
      print("Broadcasting ping - waiting up to 3s for live GPS responses...")
      rednet.broadcast({ type = "ping" }, PROTOCOL)
      local deadline = os.clock() + 3
      local any = false
      while os.clock() < deadline do
        local senderId, message = rednet.receive(PROTOCOL, deadline - os.clock())
        if senderId and type(message) == "table" and message.type == "pong" then
          any = true
          if message.error then
            print(("  turtle %d: %s"):format(senderId, message.error))
          else
            print(("  turtle %d: live GPS (%d,%d,%d)"):format(senderId, message.x, message.y, message.z))
          end
        end
      end
      if not any then print("  no responses - no turtles currently running flatten fleet?") end
    elseif cmd == "reset" then
      local function printResetAck(id, message)
        if message.ok then
          local o, n, lp = message.oldRelative, message.newRelative, message.livePos
          print(("  turtle %d: live GPS (%d,%d,%d)"):format(id, lp.x, lp.y, lp.z))
          print(("    corrected: (%d,%d,%d) facing %d -> (%d,%d,%d) facing %d"):format(
            o.x, o.y, o.z, o.facing, n.x, n.y, n.z, n.facing))
        else
          print(("  turtle %d could not reset: %s"):format(id, message.error))
        end
      end

      if rest:lower() == "all" then
        print("Broadcasting reset to all turtles - waiting up to 5s for responses...")
        rednet.broadcast({ type = "reset" }, PROTOCOL)
        local deadline = os.clock() + 5
        local any = false
        while os.clock() < deadline do
          local senderId, message = rednet.receive(PROTOCOL, deadline - os.clock())
          if senderId and type(message) == "table" and message.type == "reset_ack" then
            any = true
            printResetAck(senderId, message)
          end
        end
        if not any then print("  no responses - no turtles currently running flatten fleet?") end
      else
        local targetId = tonumber(rest)
        if not targetId then
          print("Usage: reset <turtleId>|all - see 'list' for known turtle IDs.")
        else
          print(("Requesting reset from turtle %d - waiting up to 5s..."):format(targetId))
          rednet.send(targetId, { type = "reset" }, PROTOCOL)
          local deadline = os.clock() + 5
          local got = false
          while os.clock() < deadline do
            local senderId, message = rednet.receive(PROTOCOL, deadline - os.clock())
            if senderId == targetId and type(message) == "table" and message.type == "reset_ack" then
              got = true
              printResetAck(targetId, message)
              break
            end
          end
          if not got then print("  no response - is that turtle ID running flatten fleet right now?") end
        end
      end
    elseif cmd == "help" or cmd == "" then
      printHelp()
    else
      print("Unknown command '" .. cmd .. "'. Type 'help'.")
    end
  end
end

print("\nWaiting for turtles to register (Ctrl+T to stop)...")
parallel.waitForAny(rednetLoop, commandLoop)
