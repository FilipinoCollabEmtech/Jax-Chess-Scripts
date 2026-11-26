--[[
  WordleHelper - Wordie board solver (APIVerve Wordle Helper only)
]]
local genv = typeof(getgenv) == "function" and getgenv() or _G
local state = genv.WordleHelperState
if type(state) ~= "table" then
    state = {}
    genv.WordleHelperState = state
end
state.apiKey = state.apiKey or ""
state.autoSolve = state.autoSolve or false
state.cache = state.cache or {}
state.objects = state.objects or {}
state.connections = state.connections or {}

local SETTINGS_PATH = "WordleHelper/settings.json"

local function loadSettings()
    if typeof(isfile) ~= "function" or typeof(readfile) ~= "function" then return end
    local okExists, exists = pcall(function() return isfile(SETTINGS_PATH) end)
    if not okExists or not exists then return end
    local okRead, content = pcall(function() return readfile(SETTINGS_PATH) end)
    if not okRead or type(content) ~= "string" then return end
    local okJson, data = pcall(function() return game:GetService("HttpService"):JSONDecode(content) end)
    if not okJson or type(data) ~= "table" then return end
    if type(data.apiKey) == "string" then state.apiKey = data.apiKey end
    if type(data.autoSolve) == "boolean" then state.autoSolve = data.autoSolve end
end

local function saveSettings()
    if typeof(writefile) ~= "function" then return end
    local okJson, json = pcall(function()
        return game:GetService("HttpService"):JSONEncode({
            apiKey = state.apiKey,
            autoSolve = state.autoSolve,
        })
    end)
    if okJson and type(json) == "string" then
        pcall(function() writefile(SETTINGS_PATH, json) end)
    end
end

loadSettings()

local URL = "https://api.apiverve.com/v1/wordlehelper"

local function urlEncode(s)
    return (tostring(s):gsub("[^%w%-_%.~]", function(c)
        return string.format("%%%02X", c:byte())
    end))
end

local function solveapiverde(green, yellow, gray)
    local key = tostring(state.apiKey or "")
    local url = string.format("%s?green=%s&yellow=%s&gray=%s",
        URL, urlEncode(green), urlEncode(yellow), urlEncode(gray))
    local headers = {}
    if key ~= "" then headers["x-api-key"] = key end
    local ok, response = pcall(function()
        return request({ Url = url, Method = "GET", Headers = headers })
    end)
    if not ok then return nil, "HTTP error: " .. tostring(response) end
    if type(response) == "string" then return nil, "HTTP error: " .. response end
    local status, body = response.StatusCode, response.Body
    if type(status) == "number" and (status < 200 or status >= 300) then
        return nil, "HTTP " .. tostring(status) .. ": " .. tostring(body):sub(1, 160)
    end
    if type(body) ~= "string" or body == "" then return nil, "Empty response" end
    local okJson, data = pcall(function() return game:GetService("HttpService"):JSONDecode(body) end)
    if not okJson or type(data) ~= "table" then return nil, "Invalid JSON" end
    if data.status == "error" then return nil, tostring(data.error or "API error") end
    local suggestions = data.data and data.data.suggestions or {}
    if type(suggestions) ~= "table" or #suggestions == 0 then
        return nil, "No matching words"
    end
    return {
        words = suggestions,
        best = tostring(suggestions[1]),
        count = data.data.matchCount or #suggestions,
        pattern = data.data.pattern or "",
    }
end

local function dedupe(list)
    local seen, out = {}, {}
    for _, value in ipairs(list) do
        if not seen[value] then
            seen[value] = true
            out[#out + 1] = value
        end
    end
    return table.concat(out, ",")
end

local function readBoard()
    local ok, clues = pcall(function()
        local pg = game:GetService("Players").LocalPlayer:FindFirstChildOfClass("PlayerGui")
        local hud = pg and pg:FindFirstChild("HUD")
        local gameFrame = hud and hud:FindFirstChild("Content")
        gameFrame = gameFrame and gameFrame:FindFirstChild("Game")
        local grid = gameFrame and gameFrame:FindFirstChild("Grid")
        if not grid then return nil end

        local greens, yellows, grays, signature = {}, {}, {}, ""
        for rowIndex = 1, 6 do
            local row = grid:FindFirstChild("Row" .. rowIndex)
            if row then
                for keyIndex = 1, 5 do
                    local key = row:FindFirstChild("Key" .. keyIndex)
                    local content = key and key:FindFirstChild("Content")
                    local keyCode = content and content:FindFirstChild("KeyCode")
                    local letter = keyCode and tostring(keyCode.Text or ""):upper() or ""
                    local tileState = content and tostring(content:GetAttribute("WordieTileState") or "") or ""
                    if tileState == "Correct" and letter ~= "" then
                        greens[#greens + 1] = letter .. keyIndex
                    elseif tileState == "Present" and letter ~= "" then
                        yellows[#yellows + 1] = letter
                    elseif tileState == "Absent" and letter ~= "" then
                        grays[#grays + 1] = letter
                    end
                    signature = signature .. letter .. tileState:sub(1, 1) .. "|"
                end
            end
        end

        -- An empty board is a fresh round: solve with no constraints to pick an opener.
        return {
            green = dedupe(greens),
            yellow = dedupe(yellows),
            gray = dedupe(grays),
            signature = signature,
        }
    end)
    if ok then return clues end
    return nil
end

local QUEUED_SOURCE = [[pcall(function() loadstring(game:HttpGet("https://raw.githubusercontent.com/FilipinoCollabEmtech/Jax-Chess-Scripts/main/WordleHelper.lua"))() end)]]

local function queueReload()
    if state.queuedFor == game.PlaceId and not state.queueConsumed then return end
    local queue = typeof(queueonteleport) == "function" and queueonteleport
        or typeof(queue_on_teleport) == "function" and queue_on_teleport
        or typeof(queueteleport) == "function" and queueteleport
    local ok
    if queue then ok = pcall(queue, QUEUED_SOURCE) end
    if not ok and typeof(fluxus) == "table" and typeof(fluxus.queue_on_teleport) == "function" then
        ok = pcall(function() return fluxus.queue_on_teleport(QUEUED_SOURCE) end)
    end
    if ok then
        state.queuedFor = game.PlaceId
        state.queueConsumed = false
    end
end

local function main()
    state.uiToken = (state.uiToken or 0) + 1
    local myToken = state.uiToken
    state.autoToken = (state.autoToken or 0) + 1
    state.lastBoardSignature = nil

    for _, connection in ipairs(state.connections) do
        pcall(function() connection:Disconnect() end)
    end
    state.connections = {}
    for _, object in ipairs(state.objects) do
        pcall(function() object:Destroy() end)
    end
    state.objects = {}

    local hosts = {}
    if typeof(gethui) == "function" then
        local ok, ui = pcall(gethui)
        if ok and ui then hosts[#hosts + 1] = ui end
    end
    hosts[#hosts + 1] = game:GetService("CoreGui")
    local playerGui = game:GetService("Players").LocalPlayer:FindFirstChildOfClass("PlayerGui")
    if playerGui then hosts[#hosts + 1] = playerGui end
    for _, host in ipairs(hosts) do
        for _, child in ipairs(host:GetChildren()) do
            local mine = child.Name == "WordleHelper"
            if not mine then
                pcall(function()
                    for _, label in ipairs(child:GetDescendants()) do
                        local text = label:IsA("TextLabel") and tostring(label.Text or "") or ""
                        if text == "Wordle Helper" or text == "APIVerve key" then
                            mine = true
                            break
                        end
                    end
                end)
            end
            if mine then pcall(function() child:Destroy() end) end
        end
    end

    local WindUI
    for attempt = 1, 3 do
        local ok, ui = pcall(function()
            return loadstring(game:HttpGet("https://github.com/Footagesus/WindUI/releases/latest/download/main.lua"))()
        end)
        if ok and type(ui) == "table" and type(ui.CreateWindow) == "function" then WindUI = ui break end
        task.wait(0.4)
    end
    if not WindUI then warn("[WordleHelper] WindUI failed to load") return end
    if state.uiToken ~= myToken then return end
    queueReload()

    pcall(function()
        local connection = game:GetService("Players").LocalPlayer.OnTeleport:Connect(function()
            local queue = typeof(queueonteleport) == "function" and queueonteleport
                or typeof(queue_on_teleport) == "function" and queue_on_teleport
                or typeof(queueteleport) == "function" and queueteleport
            local ok = queue and pcall(queue, QUEUED_SOURCE) or false
            if not ok and typeof(fluxus) == "table" and typeof(fluxus.queue_on_teleport) == "function" then
                pcall(function() return fluxus.queue_on_teleport(QUEUED_SOURCE) end)
            end
        end)
        table.insert(state.connections, connection)
    end)

    local Window = WindUI:CreateWindow({
        Title = "Wordle Helper",
        Icon = "grid",
        Author = "OpenCode",
        Folder = "WordleHelper",
        Size = UDim2.fromOffset(460, 360),
        Theme = "Dark",
        ToggleKey = Enum.KeyCode.RightControl,
    })
    table.insert(state.objects, Window)
    task.spawn(function()
        while state.uiToken == myToken do task.wait(1) end
        pcall(function() Window:Destroy() end)
    end)

    local Main = Window:Tab({ Title = "Main", Icon = "home" })
    local result = Main:Paragraph({ Title = "Suggestion", Desc = "Turn on Auto Solve to read the board." })
    local function setResult(title, desc)
        pcall(function()
            result:SetTitle(title)
            result:SetDesc(desc)
        end)
    end

    local function pressKey(name)
        local ok, handler = pcall(function()
            local pg = game:GetService("Players").LocalPlayer:FindFirstChildOfClass("PlayerGui")
            local hud = pg and pg:FindFirstChild("HUD")
            local content = hud and hud:FindFirstChild("Content")
            local gameFrame = content and content:FindFirstChild("Game")
            local keyboards = gameFrame and gameFrame:FindFirstChild("Keyboards")
            local layout = keyboards and keyboards:FindFirstChild("enKeyboard")
            if not layout then return nil end
            local button
            for _, row in ipairs(layout:GetChildren()) do
                button = row:FindFirstChild("Key" .. tostring(name):upper())
                if button then break end
            end
            if not button then return nil end
            for _, connection in ipairs(getconnections(button.Activated) or {}) do
                local fn = connection.Function
                local info = fn and debug.getinfo(fn)
                if info and tostring(info.source):find("SharedInputLogic", 1, true) then
                    return fn
                end
            end
            return nil
        end)
        if ok and handler then return pcall(handler) end
        return false
    end

    local function typeWord(word)
        if state.typing then return false end
        state.typing = true
        for _ = 1, 5 do
            pcall(pressKey, "BACKSPACE")
            task.wait(0.05)
        end
        for letter in tostring(word):gmatch("%a") do
            pcall(pressKey, letter:upper())
            task.wait(0.08)
        end
        pcall(pressKey, "ENTER")
        state.typing = false
        return true
    end

    local function runSolve(clues)
        setResult("Suggestion", "Thinking...")
        local answer, err = solveapiverde(clues.green, clues.yellow, clues.gray)
        if not answer then
            setResult("No result", tostring(err))
            return nil
        end
        local words = {}
        for i, word in ipairs(answer.words) do
            if i > 12 then break end
            words[#words + 1] = tostring(i) .. ". " .. tostring(word)
        end
        setResult("Suggestion", string.format("Best: %s\nMatches: %s\nPattern: %s\nGreen: %s | Yellow: %s | Gray: %s\n\n%s",
            answer.best, tostring(answer.count), answer.pattern,
            clues.green, clues.yellow, clues.gray, table.concat(words, "\n")))
        return answer.best
    end

    Main:Input({
        Title = "APIVerve key",
        Placeholder = "apv_...",
        Value = state.apiKey,
        Callback = function(text)
            state.apiKey = text
            saveSettings()
        end,
    })

    local autoToggle
    local initGuard = true
    autoToggle = Main:Toggle({
        Title = "Auto Solve",
        Desc = "Read the board, solve, and type the guess",
        Value = state.autoSolve,
        Callback = function(on)
            -- WindUI invokes this during construction; ignore that synthetic event.
            if initGuard then return end
            state.autoSolve = on
            saveSettings()
            state.autoToken = (state.autoToken or 0) + 1
            if not on then return end
            task.spawn(function()
                local token = state.autoToken
                while state.autoToken == token and state.autoSolve do
                    task.wait(1)
                    local clues = readBoard()
                    if clues and clues.signature ~= state.lastBoardSignature then
                        state.lastBoardSignature = clues.signature
                        local best = runSolve(clues)
                        if best and os.clock() - (state.lastTypedAt or 0) > 6 then
                            state.lastTypedAt = os.clock()
                            typeWord(best)
                            -- Let the next poll pick up the feedback from the guess just submitted.
                            state.lastBoardSignature = nil
                        end
                    end
                end
            end)
        end,
    })
    initGuard = false
    if state.autoSolve then
        pcall(function() autoToggle.Callback(true) end)
    end
end

main()
