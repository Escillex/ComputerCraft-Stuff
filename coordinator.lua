-- coordinator.lua
-- Runs on a computer standing next to the resupply chest. Owns the area,
-- hands out one column of work at a time, and keeps track of where every
-- turtle in the fleet is.
--
-- Corners are marked from a turtle ('flatten mark1' / 'flatten mark2').
-- Everything else happens here: start, stop, list, locate.

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

local STATE_FILE = "coordinator.state"

local corners = {}      -- [1] and [2], as marked by a turtle
local box               -- min/max on each axis, once both corners are in
local cells, order      -- keyed by "x,z", plus a stable list for scanning
local turtles = {}      -- id -> { pos, state, lastSeen, cell, fuel }
local depot             -- chest/dock positions, once a turtle has found it
local depotHolder       -- only one turtle uses the chest at a time
local depotSince
local running = false
local myPos

--------------------------------------------------------------------------
-- The area
--------------------------------------------------------------------------

local function buildCells()
  cells, order = {}, {}
  for x = box.minX, box.maxX do
    for z = box.minZ, box.maxZ do
      local cell = { x = x, z = z, state = "free", attempts = 0 }
      cells[common.cellKey(x, z)] = cell
      order[#order + 1] = cell
    end
  end
end

local function buildBox()
  local a, b = corners[1], corners[2]
  box = {
    minX = math.min(a.x, b.x), maxX = math.max(a.x, b.x),
    minY = math.min(a.y, b.y), maxY = math.max(a.y, b.y),
    minZ = math.min(a.z, b.z), maxZ = math.max(a.z, b.z),
  }
  buildCells()
end

local function boxSize()
  if not box then return nil end
  return box.maxX - box.minX + 1, box.maxY - box.minY + 1, box.maxZ - box.minZ + 1
end

local function tally()
  local counts = { free = 0, claimed = 0, done = 0, skipped = 0 }
  if not order then return counts end
  for _, cell in ipairs(order) do
    counts[cell.state] = (counts[cell.state] or 0) + 1
  end
  return counts
end

--------------------------------------------------------------------------
-- Persistence
--------------------------------------------------------------------------

local function save()
  common.saveState(STATE_FILE, {
    corners = corners, box = box, depot = depot, running = running,
    cells = cells,
  })
end

local function restore()
  local saved = common.loadState(STATE_FILE)
  if not saved then return end
  corners = saved.corners or {}
  box = saved.box
  depot = saved.depot
  running = saved.running or false
  if box then
    buildCells()
    -- Put back what was already finished, but hand any cell that was
    -- claimed when we went down back to the pool.
    for key, cell in pairs(saved.cells or {}) do
      local live = cells[key]
      if live then
        live.attempts = cell.attempts or 0
        live.state = (cell.state == "claimed") and "free" or cell.state
      end
    end
  end
end

--------------------------------------------------------------------------
-- Handing out work
--------------------------------------------------------------------------

-- Refuse to put two turtles in neighbouring columns. Keeping a cell of
-- clear air between them is what stops them from bumping into each other
-- in the first place, rather than having to untangle it afterwards.
local function tooClose(cell, exceptId)
  for id, turtle_ in pairs(turtles) do
    if id ~= exceptId and turtle_.cell and turtle_.state ~= "missing" then
      local dx = math.abs(turtle_.cell.x - cell.x)
      local dz = math.abs(turtle_.cell.z - cell.z)
      if math.max(dx, dz) < common.CELL_SPACING then return true end
    end
  end
  return false
end

-- Give out the nearest workable cell, which keeps each turtle in its own
-- corner of the area instead of all of them chasing the same scan order.
local function grantCell(id, from)
  local best, bestDistance
  for _, cell in ipairs(order) do
    if cell.state == "free" and not tooClose(cell, id) then
      local distance = 0
      if from then
        distance = math.abs(cell.x - from.x) + math.abs(cell.z - from.z)
      end
      if not best or distance < bestDistance then
        best, bestDistance = cell, distance
      end
    end
  end
  if best then
    best.state = "claimed"
    best.owner = id
  end
  return best
end

-- `transient` means the turtle only bumped into another turtle on its way
-- there. That is traffic, not an obstacle, so the column goes straight back
-- in the pool instead of counting against its three strikes.
local function releaseCell(id, cellRef, outcome, transient)
  if not cellRef or not cells then return end
  local cell = cells[common.cellKey(cellRef.x, cellRef.z)]
  if not cell or cell.owner ~= id then return end

  cell.owner = nil
  if outcome == "done" then
    cell.state = "done"
  elseif transient then
    cell.retries = (cell.retries or 0) + 1
    cell.state = (cell.retries >= common.MAX_CELL_RETRIES) and "skipped" or "free"
  else
    cell.attempts = cell.attempts + 1
    cell.state = (cell.attempts >= common.MAX_CELL_ATTEMPTS) and "skipped" or "free"
  end
end

--------------------------------------------------------------------------
-- Messages
--------------------------------------------------------------------------

local function seen(id, msg)
  local entry = turtles[id]
  if not entry then
    entry = { id = id }
    turtles[id] = entry
  end
  entry.lastSeen = os.clock()
  if msg.pos then entry.pos = msg.pos end
  if msg.state then entry.state = msg.state end
  if msg.fuel then entry.fuel = msg.fuel end
  return entry
end

local function reply(id, msg, nonce)
  msg.nonce = nonce
  rednet.send(id, msg, common.PROTOCOL)
end

local function handle(id, msg)
  if type(msg) ~= "table" or not msg.type then return end
  local entry = seen(id, msg)

  if msg.type == common.HEARTBEAT then
    entry.cell = msg.cell
    return
  end

  if msg.type == common.HELLO then
    entry.state = "idle"
    entry.cell = nil
    print(("turtle %d joined at %s"):format(id, common.formatPos(msg.pos)))
    reply(id, {
      type = common.WELCOME, version = common.VERSION,
      box = box, depot = depot, coordPos = myPos, running = running,
    }, msg.nonce)

  elseif msg.type == common.MARK then
    if msg.which ~= 1 and msg.which ~= 2 then
      reply(id, { type = common.NACK, message = "corner must be 1 or 2" }, msg.nonce)
      return
    end
    corners[msg.which] = msg.pos
    local note
    if corners[1] and corners[2] then
      buildBox()
      running = false
      local w, h, d = boxSize()
      note = ("area is %d x %d x %d (%d columns) - run 'start' when the turtles are ready")
        :format(w, h, d, w * d)
    else
      note = "now mark the opposite corner with 'flatten mark2'"
    end
    save()
    print(("corner %d marked at %s"):format(msg.which, common.formatPos(msg.pos)))
    print(note)
    reply(id, { type = common.ACK, message = note }, msg.nonce)

  elseif msg.type == common.WANT_CELL then
    if not box then
      reply(id, { type = common.NACK, message = "no area marked" }, msg.nonce)
      return
    end
    -- Finished is checked before stopped, so the turtles still working when
    -- the last column lands are told to knock off rather than being left
    -- asking for work that will never come.
    local counts = tally()
    if counts.free == 0 and counts.claimed == 0 then
      if running then
        running = false
        save()
        print("job finished - every column is cleared")
      end
      reply(id, { type = common.JOB_DONE }, msg.nonce)
      return
    end

    if not running then
      reply(id, { type = common.NO_CELL }, msg.nonce)
      return
    end

    local cell = grantCell(id, msg.pos)
    if cell then
      entry.cell = { x = cell.x, z = cell.z }
      entry.state = "mining"
      reply(id, { type = common.CELL, cell = { x = cell.x, z = cell.z } }, msg.nonce)
      save()
    else
      -- Everything left is either taken or too near another turtle.
      reply(id, { type = common.NO_CELL }, msg.nonce)
    end

  elseif msg.type == common.CELL_DONE then
    releaseCell(id, msg.cell, "done")
    entry.cell = nil
    entry.state = "idle"
    -- Finishing a column means whatever it was complaining about is over.
    entry.trouble, entry.troubleAt = nil, nil
    save()

  elseif msg.type == common.CELL_SKIP then
    releaseCell(id, msg.cell, "skip", msg.transient)
    entry.cell = nil
    entry.state = "idle"
    if not msg.transient then
      print(("turtle %d skipped %d,%d: %s")
        :format(id, msg.cell.x, msg.cell.z, tostring(msg.reason)))
    end
    save()

  elseif msg.type == common.WANT_DEPOT then
    local holder = depotHolder and turtles[depotHolder]
    local stale = depotHolder and (
      os.clock() - (depotSince or 0) > common.DEPOT_TIMEOUT
      or not holder or holder.state == "missing")

    if depotHolder and depotHolder ~= id and not stale then
      reply(id, { type = common.DEPOT_WAIT }, msg.nonce)
    else
      depotHolder, depotSince = id, os.clock()
      -- Pass on where the chest is, so a turtle that started before it was
      -- found does not go hunting for it all over again.
      reply(id, { type = common.DEPOT_GRANT, depot = depot }, msg.nonce)
    end

  elseif msg.type == common.DEPOT_RELEASE then
    if depotHolder == id then depotHolder, depotSince = nil, nil end

  elseif msg.type == common.TROUBLE then
    entry.trouble, entry.troubleAt = msg.message, os.clock()
    print(("turtle %d: %s"):format(id, tostring(msg.message)))
    print(("  it is at %s"):format(common.formatPos(msg.pos or entry.pos)))

  elseif msg.type == common.DEPOT_FOUND then
    if not depot and msg.depot then
      depot = msg.depot
      save()
      print("resupply chest found at " .. common.formatPos(depot.chest))
    end
  end
end

local function rednetLoop()
  while true do
    local id, msg = rednet.receive(common.PROTOCOL)
    local ok, err = pcall(handle, id, msg)
    if not ok then print("error handling a message: " .. tostring(err)) end
  end
end

--------------------------------------------------------------------------
-- Watching for turtles that go quiet
--------------------------------------------------------------------------

local function sweepLoop()
  while true do
    sleep(5)
    local now = os.clock()
    for id, entry in pairs(turtles) do
      if entry.state ~= "missing" and now - (entry.lastSeen or 0) > common.MISSING_AFTER then
        entry.state = "missing"
        print(("turtle %d has gone quiet - last seen at %s")
          :format(id, common.formatPos(entry.pos)))
        -- Its column goes back in the pool, but its last known position
        -- stays on the books so 'locate' can still point you at it.
        if entry.cell then
          releaseCell(id, entry.cell, "skip", true)
          entry.cell = nil
        end
        if depotHolder == id then depotHolder, depotSince = nil, nil end
        save()
      end
    end
  end
end

--------------------------------------------------------------------------
-- Console
--------------------------------------------------------------------------

local function ago(t)
  if not t then return "never" end
  return ("%ds ago"):format(math.floor(os.clock() - t))
end

local function cmdList()
  local ids = {}
  for id in pairs(turtles) do ids[#ids + 1] = id end
  table.sort(ids)

  if #ids == 0 then
    print("no turtles have joined yet")
    return
  end

  print(("%-5s %-10s %-24s %-10s %s"):format("id", "state", "position", "seen", "fuel"))
  for _, id in ipairs(ids) do
    local entry = turtles[id]
    print(("%-5d %-10s %-24s %-10s %s"):format(
      id, entry.state or "?", common.formatPos(entry.pos),
      ago(entry.lastSeen), tostring(entry.fuel or "?")))
    if entry.trouble then
      print("      ^ " .. entry.trouble)
    end
  end
end

local function cmdLocate(arg)
  local id = tonumber(arg)
  if not id then print("usage: locate <turtle id>") return end
  local entry = turtles[id]
  if not entry then print("turtle " .. id .. " has never joined") return end

  print(("turtle %d"):format(id))
  print("  state:    " .. (entry.state or "?"))
  print("  position: " .. common.formatPos(entry.pos))
  print("  seen:     " .. ago(entry.lastSeen))
  print("  fuel:     " .. tostring(entry.fuel or "?"))
  if entry.cell then
    print(("  cell:     %d,%d"):format(entry.cell.x, entry.cell.z))
  end
  if entry.trouble then
    print(("  problem:  %s (%s)"):format(entry.trouble, ago(entry.troubleAt)))
  end
  if entry.state == "missing" then
    print("  (gone quiet - the position above is where it was last heard from)")
  end
end

local function cmdStatus()
  print("coordinator " .. os.getComputerID() .. " at " .. common.formatPos(myPos))
  print("depot: " .. (depot and common.formatPos(depot.chest) or "not found yet"))
  if not box then
    print("area: not marked - run 'flatten mark1' and 'flatten mark2' on a turtle")
    return
  end
  local w, h, d = boxSize()
  print(("area: %d x %d x %d, corners %s .. %s"):format(w, h, d,
    common.formatPos({ x = box.minX, y = box.minY, z = box.minZ }),
    common.formatPos({ x = box.maxX, y = box.maxY, z = box.maxZ })))
  local counts = tally()
  print(("columns: %d done, %d being cleared, %d to go, %d written off")
    :format(counts.done, counts.claimed, counts.free, counts.skipped))
  print("job is " .. (running and "running" or "stopped"))
end

local function cmdStart()
  if not box then
    print("mark the area first: 'flatten mark1' and 'flatten mark2' on a turtle")
    return
  end
  if not depot then
    print("note: no resupply chest found yet - the first turtle will look for one")
  end
  running = true
  save()
  print("started - turtles will pick up work on their next request")
end

local function cmdClear()
  corners, box, cells, order, depot = {}, nil, nil, nil, nil
  running = false
  save()
  print("area cleared - mark two new corners to set up another job")
end

local function cmdHelp()
  print("start          begin handing out work")
  print("stop           stop handing out work")
  print("list           every turtle: state, position, last seen")
  print("locate <id>    where one turtle is, even if it has gone quiet")
  print("status         area, progress and depot")
  print("clear          forget the area and start over")
  print("exit           quit the coordinator")
  print("")
  print("corners are marked from a turtle: 'flatten mark1', 'flatten mark2'")
end

local function commandLoop()
  cmdHelp()
  while true do
    write("> ")
    local line = read()
    local verb, rest = line:match("^%s*(%S*)%s*(.-)%s*$")
    verb = (verb or ""):lower()

    if verb == "" then
      -- nothing typed
    elseif verb == "start" then cmdStart()
    elseif verb == "stop" then
      running = false
      save()
      print("stopped - turtles will idle after their current column")
    elseif verb == "list" then cmdList()
    elseif verb == "locate" then cmdLocate(rest)
    elseif verb == "status" then cmdStatus()
    elseif verb == "clear" then cmdClear()
    elseif verb == "help" then cmdHelp()
    elseif verb == "exit" then return
    else print("unknown command '" .. verb .. "' - try 'help'")
    end
  end
end

--------------------------------------------------------------------------

if turtle then error("coordinator.lua runs on a computer, not a turtle", 0) end
if not common.openModem() then
  error("no modem attached - the coordinator needs a wireless modem", 0)
end

rednet.host(common.PROTOCOL, common.HOSTNAME)

local x, y, z = gps.locate(3)
if x then
  myPos = { x = common.round(x), y = common.round(y), z = common.round(z) }
else
  print("!! no GPS signal - turtles will not be able to find the resupply chest")
end

if not peripheral.find("inventory") then
  print("!! no chest next to me - put one against this computer for resupply")
end

restore()
print(("ComCraft coordinator %s (computer %d) ready.")
  :format(common.VERSION, os.getComputerID()))
cmdStatus()
print("")

parallel.waitForAny(commandLoop, rednetLoop, sweepLoop)

rednet.unhost(common.PROTOCOL, common.HOSTNAME)
print("coordinator stopped")
