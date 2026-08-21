-- update.lua
-- update flatten | update coordinator | update all

local FILES = {
  flatten = "https://raw.githubusercontent.com/Escillex/ComputerCraft-Stuff/main/flatten.lua",
  coordinator = "https://raw.githubusercontent.com/Escillex/ComputerCraft-Stuff/main/coordinator.lua",
  startup = "https://raw.githubusercontent.com/Escillex/ComputerCraft-Stuff/main/startup.lua",
}

local function validNames()
  local names = {}
  for k in pairs(FILES) do names[#names + 1] = k end
  return table.concat(names, ", ")
end

local function updateOne(name)
  local url = FILES[name]
  if not url then
    print("Unknown target '" .. name .. "'. Valid: " .. validNames())
    return false
  end

  -- Clean up both possible filenames first - a stale "name" left sitting
  -- next to a freshly-fetched "name.lua" is exactly how a turtle keeps
  -- silently running an old version after every "successful" update (the
  -- shell finds the bare name first when you just type "flatten").
  if fs.exists(name) then fs.delete(name) end
  if fs.exists(name .. ".lua") then fs.delete(name .. ".lua") end

  print("Updating " .. name .. "...")
  local ok = shell.run("wget", url, name)

  -- Normalize back to the bare name if wget saved with .lua anyway.
  if fs.exists(name .. ".lua") and not fs.exists(name) then
    fs.move(name .. ".lua", name)
  end

  local success = ok and fs.exists(name)
  print(success and (name .. " updated.") or (name .. " FAILED - check network/HTTP settings."))
  return success
end

local args = { ... }

if #args == 0 or tostring(args[1]):lower() == "help" then
  print("Usage: update <flatten|coordinator|startup|all>")
  return
end

local target = tostring(args[1]):lower()
if target == "all" then
  local allOk = true
  for name in pairs(FILES) do
    if not updateOne(name) then allOk = false end
  end
  if not allOk then error("One or more updates failed - see above.") end
else
  if not updateOne(target) then error("Update failed.") end
end
