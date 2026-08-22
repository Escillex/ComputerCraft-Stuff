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
local depotTypes = {}   -- block ids of whatever is attached, for turtles to look for
local depotHolder       -- only one turtle uses the chest at a time
local depotSince
local mode = "clear"    -- "clear" empties the area, "fill" makes it solid
local spine             -- the row kept open as a road while filling
local material          -- the block id fill mode lays down
local floorPatch = true -- cap a cleared column that bottoms out over a cave
local depotSeeker       -- the one turtle sent to find the store
local depotSeekerSince
local SEEK_TIMEOUT = 90 -- before giving the errand to somebody else
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

local refreshSpine   -- set once findSpine exists, below

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

-- One character per column, in the order they were built. Writing the cell
-- table out as tables cost about 67 bytes a column every time anything
-- happened, which for a job of any size is most of what the coordinator
-- would spend its day doing: an area of 900 columns would have written
-- something like 175MB of state file over the course of clearing it.
local MARKS = { free = ".", claimed = ".", done = "#", skipped = "x" }
local FROM_MARK = { ["."] = "free", ["#"] = "done", ["x"] = "skipped" }

local function encodeCells()
  if not order then return nil end
  local out = {}
  for i, cell in ipairs(order) do
    -- A column that was being worked when we went down is nobody's now.
    out[i] = MARKS[cell.state] or "."
  end
  return table.concat(out)
end

local function applyCells(marks)
  if not marks or not order then return end
  for i, cell in ipairs(order) do
    cell.state = FROM_MARK[marks:sub(i, i)] or "free"
  end
end

local dirty, lastSaved = false, -math.huge

local function writeNow()
  dirty = false
  lastSaved = os.clock()
  common.saveState(STATE_FILE, {
    corners = corners, box = box, depot = depot, running = running,
    mode = mode, material = material, floorPatch = floorPatch,
    marks = encodeCells(),
  })
end

-- Progress is written on a timer rather than after every column. Losing a
-- few seconds of it to a crash only costs the time to dig through air
-- again, which is cheaper than writing the whole job out over and over.
local function save()
  dirty = true
end

local SAVE_EVERY = 10

local function saverLoop()
  while true do
    sleep(2)
    if dirty and os.clock() - lastSaved >= SAVE_EVERY then writeNow() end
  end
end

local function restore()
  local saved = common.loadState(STATE_FILE)
  if not saved then return end
  corners = saved.corners or {}
  box = saved.box
  depot = saved.depot
  mode = saved.mode or "clear"
  material = saved.material
  if saved.floorPatch ~= nil then floorPatch = saved.floorPatch end
  running = saved.running or false
  if box then
    buildCells()
    refreshSpine()
    if saved.marks then
      applyCells(saved.marks)
    else
      -- Written by a version that kept a table per column. Read it once so
      -- that updating in the middle of a job does not throw away everything
      -- already dug and send the turtles back over it.
      for key, cell in pairs(saved.cells or {}) do
        local live = cells[key]
        if live and cell.state and cell.state ~= "claimed" then
          live.state = cell.state
        end
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
-- Which edge of the area the store sits off. That row is left open as a
-- road until everything else is solid: with a ceiling over the area there
-- is nowhere else to travel, and crossing a finished column takes its top
-- block out on the way past.
-- The edge the store is actually beyond, not merely the nearest-numbered
-- one: a store off the east side can sit at a z that falls inside the
-- area's own range, and measuring each axis on its own would then pick a
-- north or south edge and send everybody the wrong way home.
local function findSpine()
  if not box or not depot then return nil end
  local d = depot.dock
  local sides = {}

  if d.x > box.maxX then
    sides[#sides + 1] = { axis = "x", value = box.maxX, gap = d.x - box.maxX }
  elseif d.x < box.minX then
    sides[#sides + 1] = { axis = "x", value = box.minX, gap = box.minX - d.x }
  end
  if d.z > box.maxZ then
    sides[#sides + 1] = { axis = "z", value = box.maxZ, gap = d.z - box.maxZ }
  elseif d.z < box.minZ then
    sides[#sides + 1] = { axis = "z", value = box.minZ, gap = box.minZ - d.z }
  end

  -- Standing inside the area's own footprint: there is no edge to leave by.
  if #sides == 0 then return nil end

  local best = sides[1]
  for _, side in ipairs(sides) do
    if side.gap < best.gap then best = side end
  end
  return { axis = best.axis, value = best.value }
end

local function onSpine(cell)
  if not spine then return false end
  if spine.axis == "x" then return cell.x == spine.value end
  return cell.z == spine.value
end

-- How far a column sits from the spine, along the axis that matters.
local function fromSpine(cell)
  if spine.axis == "x" then return math.abs(cell.x - spine.value) end
  return math.abs(cell.z - spine.value)
end

local SPINE_LAST = 1e9

-- Work out the road again whenever the area or the store moves.
refreshSpine = function()
  spine = findSpine()
end

-- Clearing hands out whatever is nearest the turtle, which keeps each of
-- them working its own corner.
--
-- Filling cannot: a finished column is solid, so turtles can only travel
-- over ground nobody has filled. Every row is worked from its far end in
-- towards the spine, which leaves the half of each row nearest the spine
-- open for as long as that row has work left - so the way to any column is
-- along the spine and then out along its own row, and never across
-- anything finished. The spine itself goes last, furthest end first, walked
-- in by a single turtle backing up towards the store.
local function cellScore(cell, from)
  if mode == "fill" and spine and depot then
    if onSpine(cell) then
      local home = math.abs(cell.x - depot.dock.x) + math.abs(cell.z - depot.dock.z)
      return SPINE_LAST - home
    end
    return -fromSpine(cell)
  end
  if not from then return 0 end
  return math.abs(cell.x - from.x) + math.abs(cell.z - from.z)
end

-- Two turtles on the spine would wall each other in, since it is one row
-- wide and each of them fills the ground behind the other.
local function spineTaken(exceptId)
  for id, t in pairs(turtles) do
    if id ~= exceptId and t.cell and t.state ~= "missing" and onSpine(t.cell) then
      return true
    end
  end
  return false
end

local function grantCell(id, from)
  local best, bestDistance
  for _, cell in ipairs(order) do
    local usable = cell.state == "free" and not tooClose(cell, id)
    if usable and mode == "fill" and spine and onSpine(cell) and spineTaken(id) then
      usable = false
    end
    if usable then
      local distance = cellScore(cell, from)
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
      depotTypes = depotTypes, mode = mode, material = material,
      spine = spine, floorPatch = floorPatch,
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
      refreshSpine()
      running = false
      local w, h, d = boxSize()
      note = ("area is %d x %d x %d (%d columns) - run 'start' when the turtles are ready")
        :format(w, h, d, w * d)
    else
      note = "now mark the opposite corner with 'flatten mark2'"
    end
    writeNow()
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
        if counts.skipped > 0 then
          print(("job finished - %d column(s) beaten us, 'status' to see")
            :format(counts.skipped))
        else
          print("job finished - every column is cleared")
        end
      end
      reply(id, { type = common.JOB_DONE }, msg.nonce)
      return
    end

    if not running then
      reply(id, { type = common.NO_CELL }, msg.nonce)
      return
    end

    -- Nothing is handed out until somebody has been and found the store.
    -- Turtles need to know where they are heading before they start filling
    -- their inventories, and in fill mode the order columns are worked in
    -- is measured from the store, so there is no order at all without it.
    --
    -- One turtle goes, and only one. The rest wait where they are: a fleet
    -- all setting off to look at the same block is what the queue for the
    -- store exists to prevent, and there is nothing to be gained by three
    -- turtles finding the same answer.
    if not depot then
      local seeker = depotSeeker and turtles[depotSeeker]
      local lapsed = not seeker
        or seeker.state == "missing"
        or os.clock() - (depotSeekerSince or 0) > SEEK_TIMEOUT

      if depotSeeker == id or lapsed then
        if depotSeeker ~= id then
          print(("turtle %d is going to find the store"):format(id))
        end
        depotSeeker, depotSeekerSince = id, os.clock()
        entry.state = "finding store"
        reply(id, { type = common.NO_CELL, findDepot = true }, msg.nonce)
      else
        reply(id, { type = common.NO_CELL }, msg.nonce)
      end
      return
    end

    local cell = grantCell(id, msg.pos)
    if cell then
      entry.cell = { x = cell.x, z = cell.z }
      entry.state = "mining"
      reply(id, { type = common.CELL, cell = { x = cell.x, z = cell.z },
        mode = mode, material = material, spine = spine,
        floorPatch = floorPatch }, msg.nonce)
      save()
    else
      -- Nothing that can be given out: what is left is either being worked
      -- already or sits too close to a turtle that is working it. Either
      -- way there is more fleet here than there is room for, so this one is
      -- told to stand down and get out of the way rather than hover over
      -- the job waiting for a gap that is not coming.
      entry.state = "stood down"
      reply(id, { type = common.NO_CELL, standDown = true }, msg.nonce)
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
      reply(id, { type = common.DEPOT_GRANT, depot = depot,
        depotTypes = depotTypes }, msg.nonce)
    end

  elseif msg.type == common.DEPOT_RELEASE then
    if depotHolder == id then depotHolder, depotSince = nil, nil end

  elseif msg.type == common.TROUBLE then
    entry.trouble, entry.troubleAt = msg.message, os.clock()
    print(("turtle %d: %s"):format(id, tostring(msg.message)))
    print(("  it is at %s"):format(common.formatPos(msg.pos or entry.pos)))

  elseif msg.type == common.DEPOT_FOUND then
    -- A turtle only says this straight after going and looking, so take its
    -- word over what is on file. A docking spot that stopped working has to
    -- be replaceable, or every turtle keeps being sent to the same dead end.
    if msg.depot then
      local moved = not depot or not depot.dock
        or depot.dock.x ~= msg.depot.dock.x
        or depot.dock.y ~= msg.depot.dock.y
        or depot.dock.z ~= msg.depot.dock.z
      depot = msg.depot
      depotSeeker, depotSeekerSince = nil, nil
      refreshSpine()
      writeNow()
      if moved then
        print("resupply store found at " .. common.formatPos(depot.store))
      end
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
  print("depot: " .. (depot and common.formatPos(depot.store) or "not found yet"))
  print("mode: " .. mode .. (mode == "fill"
    and (" with " .. (material or "NOTHING SET")) or ""))
  if mode == "clear" then
    print("floor: " .. (floorPatch and "capping holes underneath"
      or "leaving holes underneath open"))
  end
  if mode == "fill" and spine then
    print(("road: %s=%d, kept open until the rest is solid")
      :format(spine.axis, spine.value))
  end
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
  if mode == "fill" then
    if not material then
      print("nothing to fill with - try: material minecraft:cobblestone")
      return
    end
    -- Filling works outwards-in towards the store, so the store has to be
    -- outside the area. Standing inside it, "towards the store" stops being
    -- a direction that is safe to walk in.
    if depot and depot.dock.x >= box.minX and depot.dock.x <= box.maxX
       and depot.dock.z >= box.minZ and depot.dock.z <= box.maxZ then
      print("the store is inside the marked area - move it out, or mark a")
      print("smaller area. filling works back towards it, and it would be")
      print("filled in along with everything else.")
      return
    end
  end

  running = true
  writeNow()
  if depot then
    print("started - turtles will pick up work on their next request")
  else
    print("started - no store found yet, so the first turtle goes and finds")
    print("one before any digging begins. watch for 'resupply store found'.")
  end
end

-- A column gets written off after a few real failures, and nothing ever
-- puts it back: the job then finishes with holes in it and the only way to
-- pick them up was to clear the area and start over, losing everything
-- already dug. Usually whatever stopped them has since gone - a turtle that
-- was in the way, a chunk that was not loaded, a wall you have since taken
-- down - so it is worth another go.
local function cmdMode(rest)
  local want = (rest or ""):lower()
  if want ~= "clear" and want ~= "fill" then
    print("usage: mode <clear|fill>")
    print("  clear  empty the marked area out (what it does by default)")
    print("  fill   make the marked area solid, out of 'material'")
    return
  end
  mode = want
  writeNow()
  print("mode is now " .. mode)
  if mode == "fill" and not material then
    print("set what to fill it with first: material minecraft:cobblestone")
  end
end

local function cmdMaterial(rest)
  local want = (rest or ""):match("^%s*(%S+)%s*$")
  if not want then
    print("usage: material <block id>, e.g. material minecraft:cobblestone")
    if material then print("currently: " .. material) end
    return
  end
  material = want
  writeNow()
  print("filling with " .. material .. " - keep the store stocked with it")
end

local function cmdFloor(rest)
  local want = (rest or ""):lower()
  if want ~= "on" and want ~= "off" then
    print("usage: floor <on|off>   (currently " .. (floorPatch and "on" or "off") .. ")")
    print("  on   cap a cleared column that bottoms out over a cave, laying")
    print("       one block below the area so you get a floor not a hole")
    print("  off  break nothing and place nothing outside the marked area,")
    print("       and leave any holes in the ground open")
    return
  end
  floorPatch = (want == "on")
  writeNow()
  print(floorPatch and "holes in the floor will be capped"
    or "nothing will be laid outside the area - holes stay open")
end

local function cmdRetry()
  if not order then
    print("no area marked yet")
    return
  end
  local n = 0
  for _, cell in ipairs(order) do
    if cell.state == "skipped" then
      cell.state, cell.attempts, cell.retries = "free", 0, 0
      n = n + 1
    end
  end
  writeNow()
  if n == 0 then
    print("no columns have been written off")
  else
    print(("%d column(s) back in the pool - 'start' to have another go"):format(n))
  end
end

local function cmdClear()
  corners, box, cells, order, depot = {}, nil, nil, nil, nil
  running = false
  writeNow()
  print("area cleared - mark two new corners to set up another job")
end

local function cmdHelp()
  print("start          begin handing out work")
  print("stop           stop handing out work")
  print("list           every turtle: state, position, last seen")
  print("locate <id>    where one turtle is, even if it has gone quiet")
  print("status         area, progress and depot")
  print("mode <c|f>     clear the area out, or fill it in")
  print("material <id>  what to fill it with")
  print("floor <on|off> cap holes under a cleared area, or leave them")
  print("retry          put the written-off columns back in the pool")
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
      writeNow()
      print("stopped - turtles will idle after their current column")
    elseif verb == "list" then cmdList()
    elseif verb == "locate" then cmdLocate(rest)
    elseif verb == "status" then cmdStatus()
    elseif verb == "mode" then cmdMode(rest)
    elseif verb == "material" then cmdMaterial(rest)
    elseif verb == "floor" then cmdFloor(rest)
    elseif verb == "retry" then cmdRetry()
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

-- Work out what is actually attached, and what block it is. Anything that
-- accepts items counts, vanilla or not - what matters is that turtles are
-- told the block id, because they identify the depot by looking at it.
local function findAttachedInventories()
  local found = {}
  for _, side in ipairs(peripheral.getNames()) do
    local isInventory
    if peripheral.hasType then
      isInventory = peripheral.hasType(side, "inventory")
    else
      -- Older builds without hasType: fall back to asking for the methods
      -- an inventory would have.
      local methods = peripheral.getMethods(side) or {}
      for _, method in ipairs(methods) do
        if method == "pushItems" or method == "list" then isInventory = true break end
      end
    end
    if isInventory then
      found[#found + 1] = { side = side, type = peripheral.getType(side) or "unknown" }
    end
  end
  return found
end

local attached = findAttachedInventories()
depotTypes = {}  -- filled in below
for _, inv in ipairs(attached) do
  depotTypes[#depotTypes + 1] = inv.type
  print(("resupply store: %s (on %s)"):format(inv.type, inv.side))
end

if #attached == 0 then
  print("!! nothing next to me accepts items. put a container against this")
  print("   computer. what I can see is:")
  for _, side in ipairs(peripheral.getNames()) do
    print(("     %s (%s)"):format(peripheral.getType(side) or "?", side))
  end
end

restore()
print(("ComCraft coordinator %s (computer %d) ready.")
  :format(common.VERSION, os.getComputerID()))
cmdStatus()
print("")

parallel.waitForAny(commandLoop, rednetLoop, sweepLoop, saverLoop)

-- Whatever has happened since the last timed write goes down now.
writeNow()

rednet.unhost(common.PROTOCOL, common.HOSTNAME)
print("coordinator stopped")
