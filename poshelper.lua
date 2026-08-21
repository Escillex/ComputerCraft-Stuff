-- poshelper.lua
--
-- Converts two world corner positions (like WorldEdit's //pos1 //pos2) plus
-- the direction the turtle will be facing into the flatten command.
-- flatten.lua works in turtle-relative directions (forward/back/left/right/
-- up/down), not world coordinates, so this needs to know which way the
-- turtle faces to translate "north/south/east/west" into that frame.
--
-- Usage:
--   poshelper                                    (prompts for everything)
--   poshelper <x1> <y1> <z1> <x2> <y2> <z2> <facing> [saveAs]
--
-- pos1 is where the turtle will physically stand and start the job.
-- facing is the direction show on the F3 screen (north/south/east/west, or
-- n/s/e/w) that the turtle will be facing at pos1. pos1/pos2 order doesn't
-- matter otherwise - the helper works out the signs either way.
--
-- Optionally saves the resulting command as a small launcher file (e.g.
-- `poshelper ... east myjob` writes a file called "myjob" that runs the
-- flatten command directly - just type its name to launch instead of
-- retyping the whole command).

local function parseFacing(word)
  local map = {
    n = "north", north = "north",
    s = "south", south = "south",
    e = "east", east = "east",
    w = "west", west = "west",
  }
  return word and map[tostring(word):lower()]
end

local function readCoord(promptText)
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

local function readFacing(promptText)
  while true do
    io.write(promptText .. " (north/south/east/west or n/s/e/w): ")
    local facing = parseFacing(read())
    if facing then return facing end
    print("Enter one of north, south, east, west (or n/s/e/w).")
  end
end

local function convert(x1, y1, z1, x2, y2, z2, facing)
  local dx, dy, dz = x2 - x1, y2 - y1, z2 - z1
  local nx, ny, nz = math.abs(dx) + 1, math.abs(dy) + 1, math.abs(dz) + 1

  local dirY = dy >= 0 and "up" or "down"
  local dirX, dirZ

  if facing == "north" then
    dirZ = dz <= 0 and "forward" or "back"
    dirX = dx >= 0 and "right" or "left"
  elseif facing == "south" then
    dirZ = dz >= 0 and "forward" or "back"
    dirX = dx <= 0 and "right" or "left"
  elseif facing == "east" then
    dirX = dx >= 0 and "forward" or "back"
    dirZ = dz >= 0 and "right" or "left"
  elseif facing == "west" then
    dirX = dx <= 0 and "forward" or "back"
    dirZ = dz <= 0 and "right" or "left"
  end

  return nz, dirZ, nx, dirX, ny, dirY
end

-- Writes a launcher file that just runs the flatten command directly.
-- Skips gracefully if the fs API isn't available (e.g. testing on desktop
-- Lua rather than in-game).
local function saveLauncher(filename, n1, d1, n2, d2, n3, d3)
  if not fs then
    print("(fs API not available here - can't save a launcher file)")
    return
  end
  if fs.exists(filename) then
    io.write("'" .. filename .. "' already exists - overwrite? (y/N): ")
    local answer = read()
    if not answer or answer:lower():sub(1, 1) ~= "y" then
      print("Not saved.")
      return
    end
  end
  local f = fs.open(filename, "w")
  f.write(("shell.run(\"flatten\", \"%d\", \"%s\", \"%d\", \"%s\", \"%d\", \"%s\")\n" ..
    "fs.delete(shell.getRunningProgram())\n")
    :format(n1, d1, n2, d2, n3, d3))
  f.close()
  print("Saved as '" .. filename .. "' - run it with: " .. filename .. " (deletes itself after running)")
end

----------------------------------------------------------------------

local args = { ... }
local x1, y1, z1, x2, y2, z2, facing, saveAs

if #args >= 7 then
  x1, y1, z1 = tonumber(args[1]), tonumber(args[2]), tonumber(args[3])
  x2, y2, z2 = tonumber(args[4]), tonumber(args[5]), tonumber(args[6])
  facing = parseFacing(args[7])
  saveAs = args[8]
  if not (x1 and y1 and z1 and x2 and y2 and z2 and facing) then
    error("Usage: poshelper <x1> <y1> <z1> <x2> <y2> <z2> <facing> [saveAs]")
  end
else
  print("Converts two corner positions + facing into a flatten command.")
  x1, y1, z1 = readCoord("pos1 (where the turtle will start)")
  x2, y2, z2 = readCoord("pos2 (opposite corner)")
  facing = readFacing("Facing at pos1")
end

local n1, d1, n2, d2, n3, d3 = convert(x1, y1, z1, x2, y2, z2, facing)

print()
print(("Box: %d x %d x %d (x %d..%d, y %d..%d, z %d..%d)"):format(
  math.abs(x2 - x1) + 1, math.abs(y2 - y1) + 1, math.abs(z2 - z1) + 1,
  math.min(x1, x2), math.max(x1, x2), math.min(y1, y2), math.max(y1, y2), math.min(z1, z2), math.max(z1, z2)))
print()
print("Stand the turtle at pos1, facing " .. facing .. ", then run:")
print(("  flatten %d %s %d %s %d %s"):format(n1, d1, n2, d2, n3, d3))

if not saveAs then
  io.write("\nSave this as a runnable file? Enter a name, or blank to skip: ")
  saveAs = read()
end
if saveAs and not saveAs:match("^%s*$") then
  saveLauncher(saveAs, n1, d1, n2, d2, n3, d3)
end
