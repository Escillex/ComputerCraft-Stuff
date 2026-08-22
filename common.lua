-- common.lua
-- Constants and helpers shared by coordinator.lua (a computer) and
-- flatten.lua (a turtle). Both load this with their own tiny loader rather
-- than require(), so the two sides can never drift apart on the protocol.

local common = {}

common.PROTOCOL = "comcraft"
common.HOSTNAME = "coordinator"

-- Bump this on every change that goes out. Every program prints it on
-- startup and the coordinator refuses to talk to a turtle running anything
-- else, so a computer quietly still running last week's copy shows up
-- straight away instead of behaving strangely for an hour.
common.VERSION = "2026-08-22l"

-- Worker -> coordinator
common.HELLO       = "hello"
common.MARK        = "mark"
common.WANT_CELL     = "want_cell"
common.CELL_DONE     = "cell_done"
common.CELL_SKIP     = "cell_skip"
common.HEARTBEAT     = "heartbeat"
common.DEPOT_FOUND   = "depot_found"
common.WANT_DEPOT    = "want_depot"
common.DEPOT_RELEASE = "depot_release"
common.TROUBLE       = "trouble"     -- something a person needs to know about

-- Coordinator -> worker
common.WELCOME     = "welcome"
common.CELL        = "cell"
common.NO_CELL     = "no_cell"
common.JOB_DONE    = "job_done"
common.DEPOT_GRANT = "depot_grant"
common.DEPOT_WAIT  = "depot_wait"
common.ACK         = "ack"
common.NACK        = "nack"

common.HEARTBEAT_INTERVAL = 5   -- seconds between worker position pings
common.MISSING_AFTER      = 25  -- seconds of silence before a turtle is "missing"
common.CELL_SPACING       = 2   -- min Chebyshev gap between two active cells
common.MAX_CELL_ATTEMPTS  = 3   -- real obstacles before a cell is written off
common.MAX_CELL_RETRIES   = 12  -- times a cell may be handed back over traffic
-- A turtle that has gone quiet loses the chest immediately (the sweep sees
-- to that); this is only a backstop for one that is still alive but wedged.
common.DEPOT_TIMEOUT      = 600

-- Facings as unit vectors on the world XZ plane, indexed so that
-- turning right is +1 and turning left is -1 (mod 4).
common.FACINGS = {
  [0] = { name = "north", dx =  0, dz = -1 },
  [1] = { name = "east",  dx =  1, dz =  0 },
  [2] = { name = "south", dx =  0, dz =  1 },
  [3] = { name = "west",  dx = -1, dz =  0 },
}

function common.facingFromDelta(dx, dz)
  for i = 0, 3 do
    local f = common.FACINGS[i]
    if f.dx == dx and f.dz == dz then return i end
  end
  return nil
end

function common.cellKey(x, z)
  return x .. "," .. z
end

function common.round(n)
  return math.floor(n + 0.5)
end

function common.formatPos(p)
  if not p then return "unknown" end
  return ("x=%d y=%d z=%d"):format(p.x, p.y, p.z)
end

-- Blocks a turtle must never break: anything computer-shaped (that is
-- another turtle, or this fleet's coordinator) and any container, which
-- could be the depot or a player's storage.
local PROTECTED = {
  "computercraft:",
  "chest", "barrel", "shulker", "hopper", "furnace", "dispenser", "dropper",
  -- Common names for modded storage. A multiblock store is the worst thing
  -- to get wrong: breaking any one of its blocks takes the whole structure
  -- apart, so err towards leaving unfamiliar containers alone.
  "vault", "crate", "drawer", "safe", "locker",
}

-- Another turtle is worth waiting for, because it will move on. A chest or
-- a computer never will, so there is no point standing there.
function common.isTurtleBlock(name)
  return name ~= nil and name:lower():find("turtle", 1, true) ~= nil
end

function common.isProtected(name)
  if not name then return false end
  name = name:lower()
  for _, pattern in ipairs(PROTECTED) do
    if name:find(pattern, 1, true) then return true end
  end
  return false
end

-- Only a fallback, for when the coordinator could not tell us what its own
-- inventory is. Guessing from the name only ever works for vanilla.
local DEPOT_BLOCKS = { "chest", "barrel", "shulker", "vault", "crate", "drawer" }

-- `known` is the block id the coordinator actually found attached to
-- itself, which is the reliable answer: it covers any modded storage
-- without this having to have heard of it.
function common.looksLikeDepot(name, known)
  if not name then return false end
  name = name:lower()

  if known then
    for _, id in ipairs(known) do
      if name == id:lower() then return true end
    end
  end

  for _, pattern in ipairs(DEPOT_BLOCKS) do
    if name:find(pattern, 1, true) then return true end
  end
  return false
end

-- The note on disk is a convenience, not something worth dying over: a
-- turtle that cannot write it should carry on mining. Anything that goes
-- wrong here is reported rather than thrown.
function common.saveState(path, tbl)
  local ok, text = pcall(textutils.serialize, tbl)
  if not ok then
    print("could not write " .. path .. ": " .. tostring(text))
    return false
  end

  local file = fs.open(path, "w")
  if not file then return false end
  file.write(text)
  file.close()
  return true
end

function common.loadState(path)
  if not fs.exists(path) then return nil end
  local file = fs.open(path, "r")
  if not file then return nil end
  local data = file.readAll()
  file.close()
  local ok, tbl = pcall(textutils.unserialize, data)
  if ok and type(tbl) == "table" then return tbl end
  return nil
end

-- Open the first wireless modem we can find, falling back to a wired one.
-- GPS needs wireless, so prefer it.
function common.openModem()
  if rednet.isOpen() then return true end
  local wired
  for _, name in ipairs(peripheral.getNames()) do
    if peripheral.getType(name) == "modem" then
      if peripheral.call(name, "isWireless") then
        rednet.open(name)
        return true
      end
      wired = wired or name
    end
  end
  if wired then
    rednet.open(wired)
    return true
  end
  return false
end

-- Send a message and wait for the reply to that specific message. Every
-- request carries a nonce and the reply must echo it, so a stray broadcast
-- or a late reply can never be mistaken for the answer we are waiting on.
local nextNonce = 0

function common.request(dest, msg, timeout)
  nextNonce = nextNonce + 1
  msg.nonce = nextNonce
  msg.from = os.getComputerID()
  rednet.send(dest, msg, common.PROTOCOL)

  local deadline = os.clock() + (timeout or 5)
  while true do
    local left = deadline - os.clock()
    if left <= 0 then return nil end
    local id, reply = rednet.receive(common.PROTOCOL, left)
    if id == dest and type(reply) == "table" and reply.nonce == msg.nonce then
      return reply
    end
  end
end

return common
