--[[
  WordleHelper - Wordle solver helper
  Uses APIVerve Wordle Helper and oanor Wordle API (official 2,315 answer list).
]]
local genv = typeof(getgenv) == "function" and getgenv() or _G
local state = genv.WordleHelperState
if type(state) ~= "table" then
    state = {}
    genv.WordleHelperState = state
end
state.source = state.source or "apiverve"
state.apiKey = state.apiKey or ""
state.oanorKey = state.oanorKey or ""
state.green = state.green or ""
state.yellow = state.yellow or ""
state.gray = state.gray or ""
state.guesses = state.guesses or ""
state.autoSolve = state.autoSolve or false
state.objects = state.objects or {}
state.connections = state.connections or {}
state.cache = state.cache or {}

local SETTINGS_PATH = "WordleHelper/settings.json"

local function loadSettings()
    if typeof(isfile) ~= "function" or typeof(readfile) ~= "function" then return end
    local okExists, exists = pcall(function() return isfile(SETTINGS_PATH) end)
    if not okExists or not exists then return end
    local okRead, content = pcall(function() return readfile(SETTINGS_PATH) end)
    if not okRead or type(content) ~= "string" then return end
    local okJson, data = pcall(function() return game:GetService("HttpService"):JSONDecode(content) end)
    if not okJson or type(data) ~= "table" then return end
    for _, key in ipairs({ "source", "apiKey", "oanorKey", "green", "yellow", "gray", "guesses" }) do
        if type(data[key]) == "string" then state[key] = data[key] end
    end
    if type(data.autoSolve) == "boolean" then state.autoSolve = data.autoSolve end
end

local function saveSettings()
    if typeof(writefile) ~= "function" then return end
    local okJson, json = pcall(function()
        return game:GetService("HttpService"):JSONEncode({
            source = state.source,
            apiKey = state.apiKey,
            oanorKey = state.oanorKey,
            green = state.green,
            yellow = state.yellow,
            gray = state.gray,
            guesses = state.guesses,
            autoSolve = state.autoSolve,
        })
    end)
    if okJson and type(json) == "string" then
        pcall(function() writefile(SETTINGS_PATH, json) end)
    end
end

loadSettings()

local APIVERVE_URL = "https://api.apiverve.com/v1/wordlehelper"
local OANOR_URL = "https://api.oanor.com/wordle-api/v1/solve"

local function urlEncode(s)
    return (tostring(s):gsub("[^%w%-_%.~]", function(c)
        return string.format("%%%02X", c:byte())
    end))
end

local function requestJson(url, headers)
    local ok, response = pcall(function()
        return request({ Url = url, Method = "GET", Headers = headers or {} })
    end)
    if not ok then return nil, "HTTP error: " .. tostring(response) end
    if type(response) == "string" then return nil, "HTTP error: " .. response end
    local status, body = response.StatusCode, response.Body
    if type(status) == "number" and (status < 200 or status >= 300) then
        return nil, "HTTP " .. tostring(status) .. ": " .. tostring(body):sub(1, 160)
    end
    if type(body) ~= "string" or body == "" then return nil, "Empty response" end
    local okJson, data = pcall(function() return game:GetService("HttpService"):JSONDecode(body) end)
    if not okJson or type(data) ~= "table" then return nil, "Invalid JSON response" end
    if data.status == "error" or data.success == false then
        return nil, tostring(data.error or data.message or "API error")
    end
    return data
end

local function solveApiverve()
    local green = state.green or ""
    local yellow = state.yellow or ""
    local gray = state.gray or ""
    local key = tostring(state.apiKey or "")
    local url = string.format("%s?green=%s&yellow=%s&gray=%s",
        APIVERVE_URL, urlEncode(green), urlEncode(yellow), urlEncode(gray))
    local headers = {}
    if key ~= "" then headers["x-api-key"] = key end
    local cacheKey = "apiverve|" .. green .. "|" .. yellow .. "|" .. gray
    if state.cache[cacheKey] then return state.cache[cacheKey], "cached" end
    local data, err = requestJson(url, headers)
    if not data then return nil, err end
    local suggestions = data.data and data.data.suggestions or {}
    if type(suggestions) ~= "table" or #suggestions == 0 then
        return nil, "No matching words for those clues"
    end
    local result = {
        source = "APIVerve",
        suggestion = tostring(suggestions[1]),
        candidates = suggestions,
        count = data.data.matchCount or #suggestions,
        pattern = data.data.pattern or "",
    }
    state.cache[cacheKey] = result
    return result, nil
end

local function solveOanor()
    local guesses = state.guesses or ""
    if guesses == "" then
        return nil, "Enter guess:pattern pairs first (e.g. crane:xxxgx,slate:ggxxx)"
    end
    local key = tostring(state.oanorKey or "")
    local url = string.format("%s?guesses=%s&limit=20", OANOR_URL, urlEncode(guesses))
    local headers = {}
    if key ~= "" then headers["x-oanor-key"] = key end
    local cacheKey = "oanor|" .. guesses
    if state.cache[cacheKey] then return state.cache[cacheKey], "cached" end
    local data, err = requestJson(url, headers)
    if not data then return nil, err end
    local payload = data.data or {}
    local candidates = payload.candidates or {}
    if type(candidates) ~= "table" or #candidates == 0 then
        return nil, "No matching words for those clues"
    end
    local result = {
        source = "oanor",
        suggestion = tostring(payload.suggestion or candidates[1]),
        candidates = candidates,
        count = payload.remaining or #candidates,
        pattern = "",
    }
    state.cache[cacheKey] = result
    return result, nil
end

local function solve()
    if state.source == "oanor" then
        return solveOanor()
    elseif state.source == "auto" then
        local result, err = solveOanor()
        if result then return result, err end
        return solveApiverve()
    end
    return solveApiverve()
end

local function dedupeLetters(list)
    local seen, out = {}, {}
    for _, letter in ipairs(list) do
        if not seen[letter] then
            seen[letter] = true
            out[#out + 1] = letter
        end
    end
    return table.concat(out)
end

local function readBoard()
    local ok, clues = pcall(function()
        local pg = game:GetService("Players").LocalPlayer:FindFirstChildOfClass("PlayerGui")
        local hud = pg and pg:FindFirstChild("HUD")
        local grid = hud and hud:FindFirstChild("Content")
        grid = grid and grid:FindFirstChild("Game")
        grid = grid and grid:FindFirstChild("Grid")
        if not grid then return nil end

        local pairs, greens, yellows, grays, signature = {}, {}, {}, {}, ""
        for rowIndex = 1, 6 do
            local row = grid:FindFirstChild("Row" .. rowIndex)
            if row then
                local word, pattern = "", ""
                for keyIndex = 1, 5 do
                    local key = row:FindFirstChild("Key" .. keyIndex)
                    local content = key and key:FindFirstChild("Content")
                    local keyCode = content and content:FindFirstChild("KeyCode")
                    local letter = keyCode and tostring(keyCode.Text or "") or ""
                    local tileState = content and content:GetAttribute("WordieTileState") or "Empty"
                    local code = tileState == "Correct" and "g" or tileState == "Present" and "y" or tileState == "Absent" and "x" or ""
                    word = word .. letter:upper()
                    pattern = pattern .. code
                    if code == "g" then greens[#greens + 1] = letter:upper() .. keyIndex end
                    if code == "y" then yellows[#yellows + 1] = letter:upper() end
                    if code == "x" then grays[#grays + 1] = letter:upper() end
                end
                signature = signature .. word .. pattern .. "|"
                if #word == 5 and #pattern == 5 and pattern:find("[gyx]") then
                    pairs[#pairs + 1] = word:lower() .. ":" .. pattern
                end
            end
        end
        if #pairs == 0 then return nil end
        return {
            green = table.concat(greens, ","),
            yellow = dedupeLetters(yellows),
            gray = dedupeLetters(grays),
            guesses = table.concat(pairs, ","),
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
        or typeof(queue_on_tp) == "function" and queue_on_tp
    local ok
    if queue then ok = pcall(queue, QUEUED_SOURCE) end
    if not ok and typeof(fluxus) == "table" and typeof(fluxus.queue_on_teleport) == "function" then
        ok = pcall(function() return fluxus.queue_on_teleport(QUEUED_SOURCE) end)
    end
    if ok then
        state.queuedFor = game.PlaceId
        state.queueConsumed = false
    else
        warn("[WordleHelper] queueonteleport failed")
    end
end

local function main()
    state.uiToken = (state.uiToken or 0) + 1
    local myToken = state.uiToken
    for _, connection in ipairs(state.connections) do
        pcall(function() connection:Disconnect() end)
    end
    state.connections = {}
    for _, object in ipairs(state.objects) do
        pcall(function() object:Destroy() end)
    end
    state.objects = {}

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
        Size = UDim2.fromOffset(470, 460),
        Theme = "Dark",
        ToggleKey = Enum.KeyCode.RightControl,
    })
    table.insert(state.objects, Window)
    task.spawn(function()
        while state.uiToken == myToken do task.wait(1) end
        pcall(function() Window:Destroy() end)
    end)

    local Main = Window:Tab({ Title = "Main", Icon = "home" })
    Main:Section({ Title = "Clues", Opened = true })

    local greenInput = Main:Input({
        Title = "Green (A1,E5)",
        Placeholder = "A1,E5",
        Value = state.green,
        Callback = function(text) state.green = text; saveSettings() end,
    })
    local yellowInput = Main:Input({
        Title = "Yellow letters",
        Placeholder = "R",
        Value = state.yellow,
        Callback = function(text) state.yellow = text; saveSettings() end,
    })
    local grayInput = Main:Input({
        Title = "Gray letters",
        Placeholder = "STLN",
        Value = state.gray,
        Callback = function(text) state.gray = text; saveSettings() end,
    })
    local guessesInput = Main:Input({
        Title = "oanor guesses",
        Placeholder = "crane:xxxgx,slate:ggxxx",
        Value = state.guesses,
        Callback = function(text) state.guesses = text; saveSettings() end,
    })

    local result = Main:Paragraph({ Title = "Suggestion", Desc = "Enter your clues and press Suggest." })
    local function setResult(title, desc)
        pcall(function()
            result:SetTitle(title)
            result:SetDesc(desc)
        end)
    end

    local function showAnswer(answer, cached)
        if not answer then
            setResult("No result", "No matching words for those clues")
            return
        end
        local list = {}
        for i, word in ipairs(answer.candidates) do
            if i > 12 then break end
            list[#list + 1] = tostring(i) .. ". " .. tostring(word)
        end
        local header = string.format("Best: %s\nSource: %s\nRemaining: %s%s",
            answer.suggestion, answer.source, tostring(answer.count),
            cached and "\n(cached)" or "")
        if answer.pattern and answer.pattern ~= "" then
            header = header .. "\nPattern: " .. answer.pattern
        end
        setResult("Suggestion", header .. "\n\n" .. table.concat(list, "\n"))
    end

    local function runSolve()
        state.green = greenInput.Value or state.green
        state.yellow = yellowInput.Value or state.yellow
        state.gray = grayInput.Value or state.gray
        state.guesses = guessesInput.Value or state.guesses
        saveSettings()
        setResult("Suggestion", "Thinking...")
        local answer, err, cached = solve()
        if not answer then
            setResult("No result", tostring(err))
            return
        end
        showAnswer(answer, cached)
    end

    Main:Button({
        Title = "Suggest",
        Desc = "Rank the next guesses from your constraints",
        Callback = runSolve,
    })

    Main:Button({
        Title = "Clear cache",
        Callback = function()
            state.cache = {}
            setResult("Suggestion", "Cache cleared.")
        end,
    })

    Main:Toggle({
        Title = "Auto Solve",
        Desc = "Read the Wordie board and solve when it changes",
        Value = state.autoSolve,
        Callback = function(on)
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
                        state.green = clues.green
                        state.yellow = clues.yellow
                        state.gray = clues.gray
                        state.guesses = clues.guesses
                        pcall(function()
                            greenInput:Set(clues.green)
                            yellowInput:Set(clues.yellow)
                            grayInput:Set(clues.gray)
                            guessesInput:Set(clues.guesses)
                        end)
                        saveSettings()
                        runSolve()
                    end
                end
            end)
        end,
    })

    Main:Section({ Title = "Settings", Opened = false })
    Main:Dropdown({
        Title = "Source",
        Values = { "apiverve", "oanor", "auto" },
        Value = state.source,
        Callback = function(value)
            state.source = value
            saveSettings()
        end,
    })
    local apiKeyInput = Main:Input({
        Title = "APIVerve key",
        Value = state.apiKey,
        Callback = function(text) state.apiKey = text; saveSettings() end,
    })
    local oanorKeyInput = Main:Input({
        Title = "oanor key",
        Value = state.oanorKey,
        Callback = function(text) state.oanorKey = text; saveSettings() end,
    })
    Main:Button({
        Title = "Save keys",
        Callback = function()
            state.apiKey = apiKeyInput.Value or state.apiKey
            state.oanorKey = oanorKeyInput.Value or state.oanorKey
            saveSettings()
            setResult("Suggestion", "Settings saved.")
        end,
    })
end

main()
