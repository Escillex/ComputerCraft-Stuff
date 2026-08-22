-- startup.lua is what runs unattended for hours, so how it behaves when
-- flatten will not start matters more than how it behaves when it will.

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

-- Stand in for flatten: fail with whatever reason `reasons` gives for this
-- attempt, writing it where flatten writes it. A nil reason means it ran
-- fine and returned normally.
local function fakeFlatten(attempts, reasons)
  return function(env, program)
    if program ~= "flatten" then return true end
    attempts[#attempts + 1] = env.os.clock()
    local why = reasons[math.min(#attempts, #reasons)]
    if why == "ok" then return true end
    local file = env.fs.open("flatten.stopped", "w")
    file.write(why)
    file.close()
    return false
  end
end

local function bootTurtle(sim, shellRun)
  local m = sim.addMachine({
    id = 1, name = "t1", isTurtle = true,
    pos = { x = 0, y = 64, z = 0 }, facing = 1,
    shellRun = shellRun,
  })
  sim.boot(m, "startup.lua", {})
  return m
end

--------------------------------------------------------------------------
print("\n=== the same thing being wrong does not scroll the screen ===")
--------------------------------------------------------------------------
do
  -- The reason a turtle will not start is usually one only a person can
  -- fix. Repeating it every ten seconds pushes it off the screen, which is
  -- the one place it needed to stay.
  local sim = freshSim()
  local attempts = {}
  local m = bootTurtle(sim, fakeFlatten(attempts, { "out of fuel - put coal in my inventory" }))
  sim.run(660)

  check(#attempts >= 2, ("it kept trying (%d attempts)"):format(#attempts))
  check(#attempts <= 10,
    ("it backed off rather than retrying flat out (%d attempts in 11 minutes, %d at 10s)")
      :format(#attempts, 66))

  local said = 0
  for _, line in ipairs(m.log) do
    if line:find("out of fuel", 1, true) then said = said + 1 end
  end
  check(said == 1, ("it gave the reason once, not once per attempt (%d times)"):format(said))

  local last = attempts[#attempts] - attempts[#attempts - 1]
  check(last >= 60, ("and the gap grew to %ds"):format(math.floor(last)))
end

--------------------------------------------------------------------------
print("\n=== something else going wrong is worth saying ===")
--------------------------------------------------------------------------
do
  -- Backing off must not swallow a change. A turtle that has been out of
  -- fuel for an hour and is now failing to reach the coordinator is a
  -- different problem, and gets said and retried promptly.
  local sim = freshSim()
  local attempts = {}
  local m = bootTurtle(sim, fakeFlatten(attempts, {
    "out of fuel - put coal in my inventory",
    "out of fuel - put coal in my inventory",
    "out of fuel - put coal in my inventory",
    "the coordinator did not answer my hello",
  }))
  sim.run(300)

  local said = table.concat(m.log, "\n")
  check(said:find("did not answer my hello", 1, true) ~= nil,
    "it said the new reason")

  -- The fourth attempt onward is the new reason; the gap after it should be
  -- back down to the short one rather than still doubling.
  local gap = attempts[5] and (attempts[5] - attempts[4])
  check(gap ~= nil and gap <= 15,
    ("and went back to trying promptly (%s)"):format(gap and (math.floor(gap) .. "s") or "no further attempt"))
end

--------------------------------------------------------------------------
print("\n=== a crash with no reason of its own is not misreported ===")
--------------------------------------------------------------------------
do
  -- flatten only leaves a reason when it stops on purpose. A genuine crash
  -- leaves nothing, and must not be reported as whatever went wrong last
  -- time.
  local sim = freshSim()
  local attempts = {}
  local m = bootTurtle(sim, function(env, program)
    if program ~= "flatten" then return true end
    attempts[#attempts + 1] = env.os.clock()
    if #attempts == 1 then
      local file = env.fs.open("flatten.stopped", "w")
      file.write("no area marked yet")
      file.close()
    end
    return false   -- second attempt onward: crash, no reason left behind
  end)
  sim.run(200)

  local marked, generic = 0, 0
  for _, line in ipairs(m.log) do
    if line:find("no area marked", 1, true) then marked = marked + 1 end
    if line:find("stopped with an error", 1, true) then generic = generic + 1 end
  end
  check(marked == 1, ("the first reason was reported once (%d)"):format(marked))
  check(generic == 1,
    ("the crash was reported as a crash, once (%d)"):format(generic))
end

--------------------------------------------------------------------------
print("\n=== a clean run resets the wait ===")
--------------------------------------------------------------------------
do
  -- Backing off is for a turtle that cannot start. One that worked for a
  -- while and then fell over should be picked back up promptly.
  local sim = freshSim()
  local attempts = {}
  local m = bootTurtle(sim, fakeFlatten(attempts, {
    "out of fuel - put coal in my inventory",
    "out of fuel - put coal in my inventory",
    "out of fuel - put coal in my inventory",
    "ok",
    "out of fuel - put coal in my inventory",
  }))
  sim.run(400)

  local gap = attempts[6] and (attempts[6] - attempts[5])
  check(gap ~= nil and gap <= 15,
    ("after a clean run it retried promptly again (%s)")
      :format(gap and (math.floor(gap) .. "s") or "no further attempt"))
end

--------------------------------------------------------------------------
print("\n=== flatten leaves the reason where startup looks for it ===")
--------------------------------------------------------------------------
do
  -- The other half of the contract, against the real flatten rather than a
  -- stand-in: startup can only report the reason if flatten writes it.
  -- A turtle switched on before its coordinator is the case that actually
  -- happens, and the one that used to retry every ten seconds forever.
  local sim = freshSim()
  local m = sim.addMachine({
    id = 1, name = "t1", isTurtle = true,
    pos = { x = 0, y = 64, z = 0 }, facing = 1,
    fuel = 1000, slots = {},
  })
  sim.boot(m, "flatten", {})
  sim.run(60)

  local why = m.files["flatten.stopped"]
  check(why ~= nil, "it left a reason behind")
  check(why ~= nil and why:find("coordinator", 1, true) ~= nil,
    ("and the reason is the real one (%s)"):format(tostring(why)))
end

--------------------------------------------------------------------------
if #failures > 0 then
  print(("\n%d CHECK(S) FAILED"):format(#failures))
  for _, f in ipairs(failures) do print("  - " .. f) end
  os.exit(1)
end
print("\nALL STARTUP CHECKS PASSED")
