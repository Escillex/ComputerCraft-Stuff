-- startup.lua
-- Puts a turtle straight to work when it boots, and puts it back to work
-- if it ever falls over. Nothing to configure.

if not turtle then return end

-- flatten leaves the reason it stopped here.
local STOP_FILE = "flatten.stopped"

-- A turtle that will not start usually will not start for a reason a
-- person has to deal with: no coal in it, nothing marked out yet, a
-- coordinator on a different version. Trying again every ten seconds fixes
-- none of those, and it scrolls the one line that says which it is off the
-- screen. So wait longer each time the same thing goes wrong, and say it
-- again only when the reason changes.
local FIRST_WAIT, LONGEST_WAIT = 10, 300

local function stopReason()
  if not fs.exists(STOP_FILE) then return nil end
  local ok, file = pcall(fs.open, STOP_FILE, "r")
  if not ok or not file then return nil end
  local why = file.readAll()
  file.close()
  return why ~= "" and why or nil
end

print("ComCraft worker starting - hold Ctrl+T now to drop to the shell.")
sleep(3)

local wait, lastReason = FIRST_WAIT, nil

while true do
  -- Clear last run's reason first, so a crash with no reason of its own is
  -- not read as whatever went wrong the time before.
  if fs.exists(STOP_FILE) then fs.delete(STOP_FILE) end

  if shell.run("flatten") then
    -- Either the job is done or the coordinator is not handing out work.
    -- Check back occasionally rather than spinning.
    wait, lastReason = FIRST_WAIT, nil
    sleep(30)
  else
    local why = stopReason() or "flatten stopped with an error"
    if why == lastReason then
      -- Same thing still wrong. Nothing to add, so wait longer and keep
      -- quiet about it.
      wait = math.min(wait * 2, LONGEST_WAIT)
    else
      wait, lastReason = FIRST_WAIT, why
      print(why)
    end
    print(("trying again in %ds - Ctrl+T to stop"):format(wait))
    sleep(wait)
  end
end
