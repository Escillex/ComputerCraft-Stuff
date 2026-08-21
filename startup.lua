-- startup.lua
-- Puts a turtle straight to work when it boots, and puts it back to work
-- if it ever falls over. Nothing to configure.

if not turtle then return end

print("ComCraft worker starting - hold Ctrl+T now to drop to the shell.")
sleep(3)

while true do
  if shell.run("flatten") then
    -- Either the job is done or the coordinator is not handing out work.
    -- Check back occasionally rather than spinning.
    sleep(30)
  else
    print("flatten stopped with an error - trying again in 10s")
    sleep(10)
  end
end
