-- ccsim.lua - a small ComputerCraft:Tweaked stand-in so the fleet scripts
-- can be run for real (world, turtles, rednet, GPS) outside Minecraft.

local sim = {}

local REPO = os.getenv("COMCRAFT_REPO") or "."

--------------------------------------------------------------------------
-- World
--------------------------------------------------------------------------

local blocks = {}          -- "x,y,z" -> block name
local chests = {}          -- "x,y,z" -> { slots = {} }
local machines = {}
local violations = {}

local function key(x, y, z) return x .. "," .. y .. "," .. z end

function sim.setBlock(x, y, z, name)
  if name then blocks[key(x, y, z)] = name else blocks[key(x, y, z)] = nil end
end

function sim.getBlock(x, y, z) return blocks[key(x, y, z)] end

function sim.addChest(x, y, z)
  blocks[key(x, y, z)] = "minecraft:chest"
  chests[key(x, y, z)] = { slots = {} }
  return chests[key(x, y, z)]
end

-- Point another position at an existing inventory, the way every block of a
-- multiblock store shares one set of contents.
function sim.linkChest(x, y, z, chest)
  chests[key(x, y, z)] = chest
end

-- Something alive standing in a block: it stops a turtle moving, but there
-- is no block there to inspect, which is exactly how CC presents a mob or a
-- player in the way.
local creatures = {}

function sim.addCreature(x, y, z)
  creatures[key(x, y, z)] = { hits = 0 }
  return creatures[key(x, y, z)]
end

function sim.creatureAt(x, y, z) return creatures[key(x, y, z)] end

-- Fluids: a turtle walks straight into them, detect does not see them, but
-- inspect reports them with the level that says source from flow. Laying a
-- block into one replaces it, which is the only way to be rid of it.
local fluids = {}

function sim.setFluid(x, y, z, name, level)
  fluids[key(x, y, z)] = name and { name = name, level = level or 0 } or nil
end

function sim.getFluid(x, y, z)
  local f = fluids[key(x, y, z)]
  return f and f.name, f and f.level
end

function sim.violation(msg)
  violations[#violations + 1] = msg
end

function sim.violations() return violations end

-- A turtle is a block whether or not its program is still running: one that
-- has crashed, finished, or been switched off is still in the way.
local function turtleAt(x, y, z)
  for _, m in ipairs(machines) do
    if m.isTurtle and m.present and m.pos.x == x and m.pos.y == y and m.pos.z == z then
      return m
    end
  end
end

-- What a turtle sees at a position: a placed block, or another turtle.
local function occupant(x, y, z)
  local t = turtleAt(x, y, z)
  if t then return "computercraft:turtle_normal", t end
  local b = blocks[key(x, y, z)]
  if b then return b end
  return nil
end

--------------------------------------------------------------------------
-- Scheduler (CC's event model: coroutines yield a filter, get an event)
--------------------------------------------------------------------------

local now = 0
local timers = {}          -- id -> { time, machine }
local nextTimerId = 0

local function queueEvent(m, ev)
  m.queue[#m.queue + 1] = ev
end

local function resume(m, ev)
  if not m.co or coroutine.status(m.co) == "dead" then
    m.alive = false
    return
  end
  local ok, filter = coroutine.resume(m.co, table.unpack(ev, 1, ev.n or #ev))
  if not ok then
    m.alive = false
    m.crash = filter
    return
  end
  m.filter = filter
  if coroutine.status(m.co) == "dead" then m.alive = false end
end

-- Run until every machine is finished, `stopWhen` returns true, or the
-- clock runs past `limit`.
function sim.run(limit, stopWhen)
  for _, m in ipairs(machines) do
    if m.alive and not m.started then
      m.started = true
      resume(m, { n = 0 })
    end
  end

  local spins = 0
  while now < limit do
    if stopWhen and stopWhen() then return true end
    spins = spins + 1
    if spins > 5000000 then error("simulation spun without advancing the clock") end
    local progressed = false

    for _, m in ipairs(machines) do
      while m.alive and #m.queue > 0 do
        local ev = table.remove(m.queue, 1)
        resume(m, ev)
        progressed = true
      end
    end

    local anyAlive = false
    for _, m in ipairs(machines) do
      if m.alive then anyAlive = true break end
    end
    if not anyAlive then return true end

    if not progressed then
      -- Nothing runnable: jump the clock to the next timer.
      local soonest, soonestId
      for id, t in pairs(timers) do
        if not soonest or t.time < soonest then soonest, soonestId = t.time, id end
      end
      if not soonest then return true end
      now = math.max(now, soonest)
      local t = timers[soonestId]
      timers[soonestId] = nil
      if t.machine.alive then
        queueEvent(t.machine, { n = 2, "timer", soonestId })
      end
    end
  end
  return false
end

function sim.now() return now end

--------------------------------------------------------------------------
-- rednet bus
--------------------------------------------------------------------------

local hosts = {}           -- protocol -> hostname -> id

--------------------------------------------------------------------------
-- Machine environments
--------------------------------------------------------------------------

local BASE_GLOBALS = {
  "pairs", "ipairs", "type", "tostring", "tonumber", "math", "string",
  "table", "select", "error", "pcall", "xpcall", "setmetatable",
  "getmetatable", "rawget", "rawset", "rawequal", "next", "assert",
  "coroutine", "load", "os",
}

local FUELS = {
  ["minecraft:coal"] = 80,
  ["minecraft:charcoal"] = 80,
  ["minecraft:coal_block"] = 800,
}

-- CC:Tweaked refuses to serialize a table that appears more than once in
-- the structure, so this has to as well - otherwise a shared reference sails
-- through here and only blows up in the game.
local function serialize(value, indent, seen)
  indent = indent or ""
  seen = seen or {}
  local t = type(value)
  if t == "number" or t == "boolean" then return tostring(value) end
  if t == "string" then return string.format("%q", value) end
  if t ~= "table" then return "nil" end

  if seen[value] then error("Cannot serialize table with repeated entries", 0) end
  seen[value] = true

  local parts = { "{\n" }
  local inner = indent .. "  "
  for k, v in pairs(value) do
    local ks
    if type(k) == "string" and k:match("^[%a_][%w_]*$") then
      ks = k .. " = "
    else
      ks = "[" .. serialize(k, inner, seen) .. "] = "
    end
    parts[#parts + 1] = inner .. ks .. serialize(v, inner, seen) .. ",\n"
  end
  parts[#parts + 1] = indent .. "}"
  return table.concat(parts)
end

local function makeEnv(m)
  local env = {}
  for _, name in ipairs(BASE_GLOBALS) do env[name] = _G[name] end
  env._G = env
  env._ENV = env

  ------------------------------------------------------------------ os
  local realOs = _G.os
  env.os = {
    getComputerID = function() return m.id end,
    getComputerLabel = function() return m.label end,
    clock = function() return now end,
    time = function() return now / 60 end,
    date = realOs.date,
    startTimer = function(seconds)
      nextTimerId = nextTimerId + 1
      timers[nextTimerId] = { time = now + (seconds or 0), machine = m }
      return nextTimerId
    end,
    cancelTimer = function(id) timers[id] = nil end,
    queueEvent = function(...) queueEvent(m, table.pack(...)) end,
    pullEventRaw = function(filter)
      while true do
        local ev = table.pack(coroutine.yield(filter))
        if filter == nil or ev[1] == filter then
          return table.unpack(ev, 1, ev.n)
        end
      end
    end,
  }
  env.os.pullEvent = env.os.pullEventRaw
  env.os.sleep = function(n)
    local timer = env.os.startTimer(n or 0)
    repeat
      local _, id = env.os.pullEvent("timer")
    until id == timer
  end
  env.sleep = env.os.sleep

  --------------------------------------------------------------- output
  env.print = function(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
    m.log[#m.log + 1] = table.concat(parts, "\t")
    if sim.verbose then print(("[%6.1f %s] %s"):format(now, m.name, table.concat(parts, "\t"))) end
  end
  env.write = function(s)
    if sim.verbose then io.write(("[%6.1f %s] %s"):format(now, m.name, tostring(s))) end
  end
  env.read = function()
    while true do
      if m.console and #m.console > 0 then
        local line = table.remove(m.console, 1)
        env.print("$ " .. line)
        return line
      end
      env.os.sleep(0.5)
    end
  end
  env.term = { clear = function() end, setCursorPos = function() end, write = env.write }

  ------------------------------------------------------------------ fs
  local function normalise(p)
    p = (p or ""):gsub("^/+", ""):gsub("/+$", "")
    return p
  end
  env.fs = {
    combine = function(a, b)
      a, b = normalise(a), normalise(b)
      if a == "" then return b end
      return a .. "/" .. b
    end,
    getDir = function(p)
      p = normalise(p)
      local dir = p:match("^(.*)/[^/]*$")
      return dir or ""
    end,
    getName = function(p) return (normalise(p):match("[^/]*$")) end,
    exists = function(p) return m.files[normalise(p)] ~= nil end,
    isDir = function() return false end,
    isReadOnly = function(p) return normalise(p) == "rom" end,
    delete = function(p) m.files[normalise(p)] = nil end,
    move = function(a, b)
      a, b = normalise(a), normalise(b)
      m.files[b] = m.files[a]
      m.files[a] = nil
    end,
    list = function()
      local names = { "rom" }
      for name in pairs(m.files) do names[#names + 1] = name end
      table.sort(names)
      return names
    end,
    open = function(p, mode)
      p = normalise(p)
      if mode == "r" then
        local data = m.files[p]
        if not data then return nil end
        return {
          readAll = function() return data end,
          close = function() end,
        }
      end
      local buffer = {}
      return {
        write = function(s)
          buffer[#buffer + 1] = s
          sim.bytesWritten = (sim.bytesWritten or 0) + #s
          sim.writes = (sim.writes or 0) + 1
        end,
        writeLine = function(s) buffer[#buffer + 1] = s .. "\n" end,
        close = function() m.files[p] = table.concat(buffer) end,
      }
    end,
  }

  ----------------------------------------------------------------- http
  -- Only as much as update.lua asks of it: fetch a URL, hand back
  -- something with readAll and close. A scenario supplies the answers.
  env.http = {
    get = function(url, headers)
      local body = m.httpGet and m.httpGet(url, headers)
      if body == nil then return nil, "not found" end
      local consumed = false
      return {
        readAll = function()
          if consumed then return nil end
          consumed = true
          return body
        end,
        close = function() end,
      }
    end,
  }

  ---------------------------------------------------------------- shell
  env.shell = {
    getRunningProgram = function() return m.program or "flatten" end,
    run = function(...)
      if m.shellRun then return m.shellRun(env, ...) end
      return true
    end,
  }

  ------------------------------------------------------------ textutils
  env.textutils = {
    serialize = function(v) return serialize(v) end,
    unserialize = function(s)
      local chunk = load("return " .. s, "state", "t", {})
      if not chunk then return nil end
      local ok, value = pcall(chunk)
      if ok then return value end
      return nil
    end,
  }

  ------------------------------------------------------------ peripheral
  -- "back" is the modem; "left" is whatever container is against this
  -- computer, if the scenario gave it one. m.storeType lets a test stand up
  -- a modded block whose name this code has never heard of.
  local function sides()
    local list = { "back" }
    if m.adjacentChest then list[#list + 1] = "left" end
    return list
  end

  env.peripheral = {
    getNames = sides,
    getType = function(side)
      if side == "back" then return "modem" end
      if side == "left" and m.adjacentChest then return m.storeType or "minecraft:chest" end
      return nil
    end,
    hasType = function(side, kind)
      if side == "back" then return kind == "modem" or kind == "peripheral" end
      if side == "left" and m.adjacentChest then return kind == "inventory" end
      return false
    end,
    getMethods = function(side)
      if side == "left" and m.adjacentChest then return { "list", "pushItems" } end
      return {}
    end,
    call = function(side, method)
      if method == "isWireless" then return true end
    end,
    find = function(kind)
      if kind == "inventory" and m.adjacentChest then return m.adjacentChest end
      return nil
    end,
  }

  --------------------------------------------------------------- rednet
  local open = false
  env.rednet = {
    isOpen = function() return open end,
    open = function() open = true end,
    close = function() open = false end,
    host = function(protocol, hostname)
      hosts[protocol] = hosts[protocol] or {}
      hosts[protocol][hostname] = m.id
    end,
    unhost = function(protocol, hostname)
      if hosts[protocol] then hosts[protocol][hostname] = nil end
    end,
    lookup = function(protocol, hostname)
      return hosts[protocol] and hosts[protocol][hostname] or nil
    end,
    send = function(target, message, protocol)
      for _, other in ipairs(machines) do
        if other.id == target and other.alive then
          queueEvent(other, { n = 4, "rednet_message", m.id, message, protocol })
        end
      end
      return true
    end,
    receive = function(protocolFilter, timeout)
      local timer
      if timeout then timer = env.os.startTimer(timeout) end
      while true do
        local ev = table.pack(env.os.pullEvent())
        if ev[1] == "rednet_message" then
          if protocolFilter == nil or ev[4] == protocolFilter then
            return ev[2], ev[3], ev[4]
          end
        elseif ev[1] == "timer" and ev[2] == timer then
          return nil
        end
      end
    end,
  }

  ------------------------------------------------------------------ gps
  env.gps = {
    locate = function(timeout)
      env.os.sleep(math.min(timeout or 2, 0.1))
      local p = m.pos
      if not p then return nil end
      return p.x, p.y, p.z
    end,
  }

  ------------------------------------------------------------- parallel
  local function runUntilLimit(routines, limit)
    local count = #routines
    local living = count
    local filters = {}
    local eventData = { n = 0 }
    while true do
      for n = 1, count do
        local r = routines[n]
        if r then
          if filters[r] == nil or filters[r] == eventData[1] then
            local ok, param = coroutine.resume(r, table.unpack(eventData, 1, eventData.n))
            if not ok then error(param, 0) end
            filters[r] = param
            if coroutine.status(r) == "dead" then
              routines[n] = nil
              living = living - 1
              if living <= limit then return n end
            end
          end
        end
      end
      eventData = table.pack(coroutine.yield())
    end
  end
  env.parallel = {
    waitForAny = function(...)
      local routines = {}
      for i = 1, select("#", ...) do routines[i] = coroutine.create((select(i, ...))) end
      return runUntilLimit(routines, #routines - 1)
    end,
    waitForAll = function(...)
      local routines = {}
      for i = 1, select("#", ...) do routines[i] = coroutine.create((select(i, ...))) end
      return runUntilLimit(routines, 0)
    end,
  }

  --------------------------------------------------------------- turtle
  if m.isTurtle then
    local DIRS = {
      [0] = { dx = 0, dz = -1 }, [1] = { dx = 1, dz = 0 },
      [2] = { dx = 0, dz = 1 },  [3] = { dx = -1, dz = 0 },
    }
    m.slots = m.slots or {}
    m.selected = 1
    m.fuel = m.fuel or 0

    local function ahead()
      local d = DIRS[m.facing]
      return m.pos.x + d.dx, m.pos.y, m.pos.z + d.dz
    end
    local function above() return m.pos.x, m.pos.y + 1, m.pos.z end
    local function below() return m.pos.x, m.pos.y - 1, m.pos.z end

    local function addItem(name)
      for i = 1, 16 do
        local s = m.slots[i]
        if s and s.name == name and s.count < 64 then s.count = s.count + 1 return true end
      end
      for i = 1, 16 do
        if not m.slots[i] then m.slots[i] = { name = name, count = 1 } return true end
      end
      return false
    end

    local function move(x, y, z)
      if creatures[key(x, y, z)] then return false, "Movement obstructed" end
      local blocker, other = occupant(x, y, z)
      if blocker then
        -- Count turtle-on-turtle jostling separately: it is the thing that
        -- makes a fleet crawl, and it does not show up in move counts.
        if other then m.bumps = m.bumps + 1 end
        return false, "Movement obstructed"
      end
      if m.fuel <= 0 then
        m.ranDry = (m.ranDry or 0) + 1
        return false, "Out of fuel"
      end
      m.fuel = m.fuel - 1
      if m.fuel < (m.lowestFuel or math.huge) then m.lowestFuel = m.fuel end
      m.pos = { x = x, y = y, z = z }
      m.moves = m.moves + 1
      return true
    end

    local function digAt(x, y, z)
      local name, other = occupant(x, y, z)
      if not name then return false, "Nothing to dig here" end
      if other then
        sim.violation(("%s dug turtle %d at %s"):format(m.name, other.id, key(x, y, z)))
        return false, "protected"
      end
      if chests[key(x, y, z)] then
        sim.violation(("%s dug the chest at %s"):format(m.name, key(x, y, z)))
        return false, "protected"
      end
      if name == "minecraft:bedrock" or name:find("computercraft:") then
        return false, "Unbreakable block detected"
      end
      blocks[key(x, y, z)] = nil
      addItem(name)
      m.digs = m.digs + 1
      return true
    end

    local function inspectAt(x, y, z)
      local name = occupant(x, y, z)
      if name then return true, { name = name, state = {}, tags = {} } end
      local fluid = fluids[key(x, y, z)]
      if fluid then
        return true, { name = fluid.name, state = { level = fluid.level }, tags = {} }
      end
      return false, "No block to inspect"
    end

    local function chestAt(where)
      local x, y, z
      if where == "down" then x, y, z = below()
      elseif where == "up" then x, y, z = above()
      else x, y, z = ahead() end
      return chests[key(x, y, z)]
    end

    local function dropInto(where)
      local chest = chestAt(where)
      local s = m.slots[m.selected]
      if not chest or not s then return false end
      for _, slot in ipairs(chest.slots) do
        if slot.name == s.name and slot.count + s.count <= 64 then
          slot.count = slot.count + s.count
          m.slots[m.selected] = nil
          return true
        end
      end
      if #chest.slots >= (chest.size or 27) then return false end
      chest.slots[#chest.slots + 1] = { name = s.name, count = s.count }
      m.slots[m.selected] = nil
      return true
    end

    local function suckFrom(where)
      local chest = chestAt(where)
      if not chest or #chest.slots == 0 then return false end
      if m.slots[m.selected] then return false end
      m.slots[m.selected] = table.remove(chest.slots, 1)
      return true
    end

    env.turtle = {
      forward = function() return move(ahead()) end,
      back = function()
        local d = DIRS[(m.facing + 2) % 4]
        return move(m.pos.x + d.dx, m.pos.y, m.pos.z + d.dz)
      end,
      up = function() return move(above()) end,
      down = function() return move(below()) end,
      turnLeft = function() m.facing = (m.facing - 1) % 4 return true end,
      turnRight = function() m.facing = (m.facing + 1) % 4 return true end,

      detect = function() return occupant(ahead()) ~= nil end,
      detectUp = function() return occupant(above()) ~= nil end,
      detectDown = function() return occupant(below()) ~= nil end,

      inspect = function() return inspectAt(ahead()) end,
      inspectUp = function() return inspectAt(above()) end,
      inspectDown = function() return inspectAt(below()) end,

      dig = function() return digAt(ahead()) end,
      digUp = function() return digAt(above()) end,
      digDown = function() return digAt(below()) end,

      attack = function()
        local c = creatures[key(ahead())]
        if c then c.hits = c.hits + 1 return true end
        return false
      end,
      attackUp = function()
        local c = creatures[key(above())]
        if c then c.hits = c.hits + 1 return true end
        return false
      end,
      attackDown = function()
        local c = creatures[key(below())]
        if c then c.hits = c.hits + 1 return true end
        return false
      end,

      select = function(n) m.selected = n return true end,
      getSelectedSlot = function() return m.selected end,
      getItemCount = function(n) local s = m.slots[n or m.selected] return s and s.count or 0 end,
      getItemDetail = function(n)
        local s = m.slots[n or m.selected]
        if not s then return nil end
        return { name = s.name, count = s.count }
      end,
      getFuelLevel = function() return m.fuel end,
      -- What a normal turtle holds; an advanced one holds 100000.
      getFuelLimit = function() return m.fuelLimit or 20000 end,

      refuel = function(count)
        local s = m.slots[m.selected]
        if not s or not FUELS[s.name] then return false end
        if count == 0 then return true end
        m.fuel = m.fuel + FUELS[s.name] * s.count
        m.slots[m.selected] = nil
        return true
      end,

      placeDown = function()
        local s = m.slots[m.selected]
        if not s then return false end
        local x, y, z = below()
        if occupant(x, y, z) then return false end
        fluids[key(x, y, z)] = nil
        blocks[key(x, y, z)] = s.name
        s.count = s.count - 1
        if s.count <= 0 then m.slots[m.selected] = nil end
        return true
      end,

      place = function()
        local s = m.slots[m.selected]
        if not s then return false end
        local x, y, z = ahead()
        if occupant(x, y, z) then return false end
        fluids[key(x, y, z)] = nil
        blocks[key(x, y, z)] = s.name
        s.count = s.count - 1
        if s.count <= 0 then m.slots[m.selected] = nil end
        return true
      end,

      placeUp = function()
        local s = m.slots[m.selected]
        if not s then return false end
        local x, y, z = above()
        if occupant(x, y, z) then return false end
        fluids[key(x, y, z)] = nil
        blocks[key(x, y, z)] = s.name
        s.count = s.count - 1
        if s.count <= 0 then m.slots[m.selected] = nil end
        return true
      end,

      drop     = function() return dropInto("forward") end,
      dropDown = function() return dropInto("down") end,
      dropUp   = function() return dropInto("up") end,

      suck     = function() return suckFrom("forward") end,
      suckDown = function() return suckFrom("down") end,
      suckUp   = function() return suckFrom("up") end,
    }
  end

  return env
end

--------------------------------------------------------------------------
-- Building machines
--------------------------------------------------------------------------

local nextId = 0

local function readRepoFile(name)
  local f = assert(io.open(REPO .. "/" .. name, "r"), "missing " .. name)
  local src = f:read("*a")
  f:close()
  return src
end

function sim.addMachine(opts)
  nextId = nextId + 1
  local m = {
    id = opts.id or nextId,
    name = opts.name or ("machine" .. nextId),
    isTurtle = opts.isTurtle or false,
    present = opts.isTurtle or false,
    pos = opts.pos,
    facing = opts.facing or 0,
    files = {},
    queue = {},
    log = {},
    console = opts.console,
    alive = true,
    program = opts.program,
    slots = opts.slots,
    fuel = opts.fuel,
    fuelLimit = opts.fuelLimit,
    adjacentChest = opts.adjacentChest,
    storeType = opts.storeType,
    shellRun = opts.shellRun,
    httpGet = opts.httpGet,
    moves = 0,
    digs = 0,
    bumps = 0,
  }
  machines[#machines + 1] = m
  return m
end

-- Load the repo's real scripts onto a machine and set one running.
function sim.boot(m, program, args)
  for _, name in ipairs({ "common.lua", "flatten", "coordinator", "reset", "update",
                          "startup.lua" }) do
    local source = name:match("%.lua$") and name or (name .. ".lua")
    local ok, src = pcall(readRepoFile, source)
    if ok then m.files[name] = src end
  end

  m.program = program
  local env = makeEnv(m)
  m.env = env

  local chunk = assert(load(m.files[program], "@" .. program, "t", env))
  m.co = coroutine.create(function()
    local ok, err = pcall(chunk, table.unpack(args or {}))
    if not ok then
      env.print("CRASH: " .. tostring(err))
      m.crash = err
    end
  end)
  m.started = false
  m.alive = true
end

function sim.machines() return machines end
function sim.reset()
  blocks, chests, machines, violations = {}, {}, {}, {}
  fluids = {}
  hosts, timers = {}, {}
  now, nextId, nextTimerId = 0, 0, 0
end

return sim
