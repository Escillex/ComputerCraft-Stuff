-- update.lua
-- Pulls the latest scripts from GitHub.
--   update all            everything (what you usually want)
--   update flatten        one target, plus anything it needs

local BASE = "https://raw.githubusercontent.com/Escillex/ComputerCraft-Stuff/main/"

-- `save` is the name the file must end up with. Programs get a bare name so
-- you can type `flatten`; common.lua keeps its extension because the other
-- scripts load it by filename.
--
-- `update` is in here too, so it keeps itself current. Overwriting the
-- running program is safe: it is already loaded, and the new copy is what
-- runs next time. Without this, a stale updater on one computer quietly
-- fetches through whatever GitHub's cache is holding and every other file
-- it pulls is suspect.
local FILES = {
  common      = { source = "common.lua",      save = "common.lua" },
  flatten     = { source = "flatten.lua",     save = "flatten",    needs = { "common" } },
  coordinator = { source = "coordinator.lua", save = "coordinator", needs = { "common" } },
  startup     = { source = "startup.lua",     save = "startup.lua" },
  reset       = { source = "reset.lua",       save = "reset" },
  update      = { source = "update.lua",      save = "update" },
}

local function targetNames()
  local names = {}
  for name in pairs(FILES) do names[#names + 1] = name end
  table.sort(names)
  return table.concat(names, ", ")
end

-- GitHub serves raw files through a cache that can hold a stale copy for
-- several minutes after a change is pushed. A unique query string each time
-- gets us the real file rather than whatever the cache happens to be
-- holding, which otherwise looks exactly like an update that did nothing.
local function freshUrl(source)
  local stamp = (os.epoch and os.epoch("utc")) or os.time()
  return BASE .. source .. "?nocache=" .. tostring(stamp)
end

local function fetch(name)
  local entry = FILES[name]
  local temp = name .. ".download"

  print("updating " .. name .. "...")
  if fs.exists(temp) then fs.delete(temp) end

  if not shell.run("wget", freshUrl(entry.source), temp) or not fs.exists(temp) then
    if fs.exists(temp) then fs.delete(temp) end
    print(name .. " FAILED - check the network and HTTP settings")
    return false
  end

  -- Only clear the old copies once the new one is safely on disk. Both
  -- spellings go: a stale `flatten` sitting next to a fresh `flatten.lua`
  -- is exactly how a turtle keeps running last week's code after every
  -- apparently successful update. Say which ones went, so you can see it
  -- happen rather than take it on trust.
  for _, stale in ipairs({ name, name .. ".lua" }) do
    if fs.exists(stale) then
      fs.delete(stale)
      print("  removed old " .. stale)
    end
  end
  fs.move(temp, entry.save)

  print("  " .. name .. " -> " .. entry.save)
  return true
end

-- Read the version out of the copy now on disk, rather than trusting that
-- the download did what it said.
local function installedVersion()
  if not fs.exists("common.lua") then return nil end
  local file = fs.open("common.lua", "r")
  local source = file.readAll()
  file.close()
  return source:match('VERSION%s*=%s*"([^"]+)"')
end

local function updateWithDeps(name, done)
  local entry = FILES[name]
  if not entry then
    print("unknown target '" .. name .. "'. try: " .. targetNames() .. ", all")
    return false
  end
  if done[name] then return true end
  done[name] = true

  local ok = true
  for _, dep in ipairs(entry.needs or {}) do
    if not updateWithDeps(dep, done) then ok = false end
  end
  return fetch(name) and ok
end

local args = { ... }
local target = (args[1] or ""):lower()

if target == "" or target == "help" then
  print("usage: update <all|" .. targetNames():gsub(", ", "|") .. ">")
  return
end

local done, allOk = {}, true

if target == "all" then
  for name in pairs(FILES) do
    if not updateWithDeps(name, done) then allOk = false end
  end
else
  allOk = updateWithDeps(target, done)
end

if not allOk then error("one or more updates failed - see above", 0) end

local version = installedVersion()
print("now on version " .. (version or "unknown - common.lua missing"))
print("every computer in the fleet must be on this same version")

if done.update then
  -- The copy that just ran is the old one; the new one is on disk.
  print("update replaced itself - the new one runs from next time")
end
