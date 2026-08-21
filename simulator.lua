-- simulator.lua
--
-- Not a turtle program - a desktop Lua tool for visually checking
-- flatten.lua's movement/dig logic without needing Minecraft. Mocks the
-- CC:Tweaked turtle/fs/peripheral API, tracks every single position the
-- turtle visits, and prints an ASCII grid per Y-layer showing the order
-- cells were visited in, plus automated sanity checks.
--
-- Usage (desktop Lua, not in-game):
--   lua5.1 simulator.lua flatten.lua <n1> <n2> <n3> <dir1> <dir2> <dir3> [homeBack homeDir homeExtra]
--
-- Keep box sizes small (e.g. 5x4x3) so the grids stay readable - the
-- algorithm's correctness doesn't depend on size, so a small case is just
-- as valid a check as a huge one.

local path = {} -- ordered list of {x=,y=,z=,event="move"|"place"}
local minX, maxX, minY, maxY, minZ, maxZ = 0, 0, 0, 0, 0, 0
local cur = { x = 0, y = 0, z = 0 }

local function track(event)
  path[#path + 1] = { x = cur.x, y = cur.y, z = cur.z, event = event }
  minX, maxX = math.min(minX, cur.x), math.max(maxX, cur.x)
  minY, maxY = math.min(minY, cur.y), math.max(maxY, cur.y)
  minZ, maxZ = math.min(minZ, cur.z), math.max(maxZ, cur.z)
end

track("start")

_G.sleep = function() end

_G.turtle = {
  getFuelLevel = function() return "unlimited" end,
  getFuelLimit = function() return "unlimited" end,
  refuel = function() return true end,

  select = function() return true end,
  getSelectedSlot = function() return 1 end,
  getItemCount = function(slot) if (slot or 1) == 1 then return 64 end return 0 end,
  getItemSpace = function() return 0 end,
  getItemDetail = function(slot)
    if (slot or 1) == 1 then return { name = "minecraft:dirt", count = 64 } end
    return nil
  end,

  detect = function() return false end,
  detectUp = function() return false end,
  detectDown = function() return false end,
  inspect = function() return false, {} end,
  inspectUp = function() return false, {} end,
  inspectDown = function() return false, {} end,

  dig = function() return true end,
  digUp = function() return true end,
  digDown = function() return true end,
  attack = function() return false end,
  attackUp = function() return false end,
  attackDown = function() return false end,

  place = function() return true end,
  placeUp = function() return true end,
  placeDown = function() track("place"); return true end,

  suck = function() return false end,
  suckUp = function() return false end,
  suckDown = function() return false end,
  drop = function() return true end,
  dropUp = function() return true end,
  dropDown = function() return true end,

  forward = function()
    cur.facing = cur.facing or 0
    local dx = ({ [0] = 0, [1] = 1, [2] = 0, [3] = -1 })[cur.facing]
    local dz = ({ [0] = 1, [1] = 0, [2] = -1, [3] = 0 })[cur.facing]
    cur.x, cur.z = cur.x + dx, cur.z + dz
    track("move")
    return true
  end,
  back = function() return true end,
  up = function() cur.y = cur.y + 1; track("move"); return true end,
  down = function() cur.y = cur.y - 1; track("move"); return true end,
  turnLeft = function() cur.facing = ((cur.facing or 0) - 1) % 4; return true end,
  turnRight = function() cur.facing = ((cur.facing or 0) + 1) % 4; return true end,
}

_G.peripheral = { wrap = function() return nil end }
_G.fs = {
  exists = function() return false end,
  open = function() return { write = function() end, close = function() end, readAll = function() return "" end } end,
  delete = function() end,
}
_G.textutils = {
  serialize = function() return "" end,
  unserialize = function() return nil end,
}

local flattenPath = arg[1]
local scriptArgs = {}
for i = 2, #arg do scriptArgs[i - 1] = arg[i] end

local chunk, err = loadfile(flattenPath)
if not chunk then
  print("Failed to load " .. tostring(flattenPath) .. ": " .. tostring(err))
  os.exit(1)
end

local unpack = table.unpack or unpack
local ok, runErr = pcall(chunk, unpack(scriptArgs))
if not ok then
  print("Script errored: " .. tostring(runErr))
end

----------------------------------------------------------------------
-- Analysis
----------------------------------------------------------------------

print("\n==================== SIMULATION RESULT ====================")
print(("bounds: x %d..%d, y %d..%d, z %d..%d"):format(minX, maxX, minY, maxY, minZ, maxZ))
print(("total tracked steps: %d"):format(#path))

-- Sanity check: consecutive "move" steps must differ by exactly 1 in
-- exactly one axis (a real turtle can't teleport).
local badJumps = 0
local lastMove = nil
for _, p in ipairs(path) do
  if p.event == "move" then
    if lastMove then
      local dx, dy, dz = math.abs(p.x - lastMove.x), math.abs(p.y - lastMove.y), math.abs(p.z - lastMove.z)
      local total = dx + dy + dz
      if total ~= 1 then
        badJumps = badJumps + 1
        print(("!! bad jump: (%d,%d,%d) -> (%d,%d,%d), distance %d"):format(
          lastMove.x, lastMove.y, lastMove.z, p.x, p.y, p.z, total))
      end
    end
    lastMove = p
  end
end
print(("adjacency check: %d bad jump(s) found"):format(badJumps))

-- Visit order grid per Y-layer (top to bottom), only for the "move" event
-- type, first-visit order number. Skipped if the footprint is too wide to
-- print legibly.
local width, depth = maxX - minX + 1, maxZ - minZ + 1
if width <= 40 and depth <= 40 then
  for y = maxY, minY, -1 do
    local grid = {}
    for z = minZ, maxZ do grid[z] = {} end
    local order = 0
    local visited = {}
    for _, p in ipairs(path) do
      if p.event == "move" and p.y == y then
        local key = p.x .. "," .. p.z
        if not visited[key] then
          order = order + 1
          visited[key] = order
        end
      end
    end
    local anyVisited = false
    print(("\n-- layer y=%d --"):format(y))
    for z = minZ, maxZ do
      local row = {}
      for x = minX, maxX do
        local v = visited[x .. "," .. z]
        if v then anyVisited = true end
        row[#row + 1] = v and (("%3d"):format(v % 1000)) or "  ."
      end
      print(table.concat(row, " "))
    end
    if not anyVisited then print("(never entered this layer)") end
  end
else
  print(("\n(footprint %dx%d too wide to grid-print - counts only)"):format(width, depth))
end

-- Per-layer move counts, to spot which layers cost the most.
local perLayer = {}
for _, p in ipairs(path) do
  if p.event == "move" then
    perLayer[p.y] = (perLayer[p.y] or 0) + 1
  end
end
print("\n-- moves per layer --")
for y = maxY, minY, -1 do
  print(("y=%d: %d moves"):format(y, perLayer[y] or 0))
end

print("\n=============================================================")
