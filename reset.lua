-- reset.lua
-- Wipes this computer back to a blank slate: every file and folder in the
-- writable root goes, including reset.lua itself. The read-only `rom` mount
-- is left alone.
--
-- Nothing is left behind to re-download with, so bootstrap update.lua again
-- afterwards (see the line printed at the end).

local KEEP = { rom = true }

local removed, failed = 0, 0

for _, name in ipairs(fs.list("")) do
  if KEEP[name] or fs.isReadOnly(name) then
    print("keeping " .. name)
  else
    local ok, err = pcall(fs.delete, name)
    if ok then
      removed = removed + 1
    else
      failed = failed + 1
      print("could not delete " .. name .. ": " .. tostring(err))
    end
  end
end

print(("wiped %d item(s)%s"):format(removed, failed > 0 and (", " .. failed .. " failed") or ""))
print("to set this computer up again:")
print("  wget https://raw.githubusercontent.com/Escillex/ComputerCraft-Stuff/main/update.lua update")
print("  update all")
