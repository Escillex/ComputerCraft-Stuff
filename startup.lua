-- launches flatten fleet on boot, retries on failure. delete/rename this file to stop it.

while true do
  local ok = shell.run("flatten", "fleet")
  if ok then break end
  print("flatten fleet stopped/errored - retrying in 10 seconds...")
  sleep(10)
end
