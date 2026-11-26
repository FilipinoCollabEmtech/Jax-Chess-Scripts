-- chessduels auto-loader (Chess Duels only)
local start = os.clock()
while (not game:IsLoaded() or not game:GetService("Players").LocalPlayer) and os.clock() - start < 30 do
    task.wait(0.2)
end

if game.PlaceId ~= 89083628291452 then return end
if typeof(getgenv) == "function" and getgenv().chessduelsState then return end

local path = isfile("Scripts/chessduels.lua") and "Scripts/chessduels.lua" or "chessduels.lua"
if not isfile(path) then return end

local ok, source = pcall(readfile, path)
if not ok or type(source) ~= "string" or #source == 0 then return end
local run, err = loadstring(source)
if run then
    pcall(run)
else
    warn("[chessduels autoexec] " .. tostring(err))
end
