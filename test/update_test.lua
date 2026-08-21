-- update.lua is the bootstrap path: if it saves files under the wrong
-- names, nothing else on the computer can load.

package.path = "test/?.lua;" .. package.path

local failures = {}
local function check(ok, message)
  print((ok and "  PASS  " or "  FAIL  ") .. message)
  if not ok then failures[#failures + 1] = message end
end

local function freshSim()
  package.loaded.ccsim = nil
  local sim = require("ccsim")
  sim.verbose = os.getenv("VERBOSE") == "1"
  return sim
end

-- Stand in for wget: record what was asked for and drop a file at the
-- destination, the way a successful download would.
local function makeWget(fetched, failOn)
  return function(env, program, url, dest)
    if program ~= "wget" then return false end
    fetched[#fetched + 1] = url
    if failOn and url:find(failOn, 1, true) then return false end
    local f = env.fs.open(dest, "w")
    f.write("-- downloaded from " .. url)
    f.close()
    return true
  end
end

--------------------------------------------------------------------------
print("\n=== update all ===")
--------------------------------------------------------------------------
do
  local sim = freshSim()
  local fetched = {}
  local m = sim.addMachine({ id = 1, name = "pc", pos = { x = 0, y = 0, z = 0 },
    shellRun = makeWget(fetched) })
  sim.boot(m, "update", { "all" })
  -- Start from a bare computer that only has update itself.
  m.files = { ["update"] = m.files["update"] }
  sim.run(60)

  check(not m.crash, "update all ran cleanly" .. (m.crash and (": " .. tostring(m.crash)) or ""))

  -- These exact names are what the other scripts look for on disk.
  for _, name in ipairs({ "common.lua", "flatten", "coordinator", "startup.lua",
                          "reset", "update" }) do
    check(m.files[name] ~= nil, "saved " .. name)
  end

  -- A stale updater fetches through GitHub's cache, which makes every other
  -- file it pulls suspect, so it has to keep itself current too.
  check(m.files["update"]:find("downloaded from", 1, true) ~= nil,
    "update replaced itself rather than leaving the old copy")
  check(table.concat(m.log, "\n"):find("replaced itself", 1, true) ~= nil,
    "it said the new updater runs from next time")

  local stray = {}
  for name in pairs(m.files) do
    if name:find("%.download$") then stray[#stray + 1] = name end
  end
  check(#stray == 0, "no half-finished downloads left behind")
  check(m.files["flatten.lua"] == nil and m.files["common"] == nil,
    "no duplicate spellings that could shadow the real file")
  check(#fetched == 6, ("fetched every target (%d)"):format(#fetched))
end

--------------------------------------------------------------------------
print("\n=== a stale copy under the other spelling is removed ===")
--------------------------------------------------------------------------
do
  local sim = freshSim()
  local fetched = {}
  local m = sim.addMachine({ id = 1, name = "pc", pos = { x = 0, y = 0, z = 0 },
    shellRun = makeWget(fetched) })
  sim.boot(m, "update", { "flatten" })
  -- The exact trap: an old `flatten.lua` sitting where a fresh `flatten`
  -- is about to land. The shell would find one of them and run it forever.
  m.files = {
    ["update"] = m.files["update"],
    ["flatten"] = "-- last week",
    ["flatten.lua"] = "-- last week, other spelling",
  }
  sim.run(60)

  check(m.files["flatten.lua"] == nil, "the stale .lua copy is gone")
  check(m.files["flatten"] ~= nil and m.files["flatten"]:find("downloaded", 1, true) ~= nil,
    "the fresh copy replaced the old one")

  local said = table.concat(m.log, "\n")
  check(said:find("removed old flatten.lua", 1, true) ~= nil,
    "it reported removing the stale copy rather than doing it silently")
  check(said:find("now on version", 1, true) ~= nil,
    "it printed the version now on disk")
end

--------------------------------------------------------------------------
print("\n=== update flatten pulls common.lua too ===")
--------------------------------------------------------------------------
do
  local sim = freshSim()
  local fetched = {}
  local m = sim.addMachine({ id = 1, name = "pc", pos = { x = 0, y = 0, z = 0 },
    shellRun = makeWget(fetched) })
  sim.boot(m, "update", { "flatten" })
  m.files = { ["update"] = m.files["update"] }
  sim.run(60)

  check(m.files["flatten"] ~= nil, "saved flatten")
  check(m.files["common.lua"] ~= nil, "pulled the module flatten depends on")
  check(m.files["coordinator"] == nil, "left the other targets alone")
end

--------------------------------------------------------------------------
print("\n=== a stale copy is only replaced once the new one lands ===")
--------------------------------------------------------------------------
do
  local sim = freshSim()
  local fetched = {}
  local m = sim.addMachine({ id = 1, name = "pc", pos = { x = 0, y = 0, z = 0 },
    shellRun = makeWget(fetched, "flatten.lua") })
  sim.boot(m, "update", { "flatten" })
  m.files = { ["update"] = m.files["update"], ["flatten"] = "-- last week's copy" }
  sim.run(60)

  check(m.files["flatten"] == "-- last week's copy",
    "a failed download did not destroy the working copy")
  check(m.files["flatten.download"] == nil, "the temporary file was cleaned up")
  check(table.concat(m.log, "\n"):find("FAILED", 1, true) ~= nil,
    "it said so loudly rather than failing quietly")
end

--------------------------------------------------------------------------
if #failures > 0 then
  print(("\n%d CHECK(S) FAILED"):format(#failures))
  for _, f in ipairs(failures) do print("  - " .. f) end
  os.exit(1)
end
print("\nALL UPDATE CHECKS PASSED")
