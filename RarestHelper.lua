--[[
  RarestHelper - "Guess the rarest word" prompt solver using the free Kilo gateway.
]]
local genv = typeof(getgenv) == "function" and getgenv() or _G
local state = genv.RarestHelperState
if type(state) ~= "table" then
    state = {}
    genv.RarestHelperState = state
end
state.autoSuggest = state.autoSuggest or false
state.objects = state.objects or {}
state.connections = state.connections or {}
state.words = state.words or {}

local SETTINGS_PATH = "RarestHelper/settings.json"

local function loadSettings()
    if typeof(isfile) ~= "function" or typeof(readfile) ~= "function" then return end
    local okExists, exists = pcall(function() return isfile(SETTINGS_PATH) end)
    if not okExists or not exists then return end
    local okRead, content = pcall(function() return readfile(SETTINGS_PATH) end)
    if not okRead or type(content) ~= "string" then return end
    local okJson, data = pcall(function() return game:GetService("HttpService"):JSONDecode(content) end)
    if okJson and type(data) == "table" and type(data.autoSuggest) == "boolean" then
        state.autoSuggest = data.autoSuggest
    end
end

local function saveSettings()
    if typeof(writefile) ~= "function" then return end
    local okJson, json = pcall(function()
        return game:GetService("HttpService"):JSONEncode({ autoSuggest = state.autoSuggest })
    end)
    if okJson and type(json) == "string" then
        pcall(function() writefile(SETTINGS_PATH, json) end)
    end
end

loadSettings()

local API_URL = "https://ai-gateway.kilo.ai/api/v1/chat/completions"
local SYSTEM_PROMPT = [[You are helping win a word game: the player must submit the LEAST KNOWN valid answer to a prompt. First think of 12 genuine answers that fit the prompt. Throw out every famous, obvious, common, or top-of-mind answer - if an average person would name it, it is disqualified. Keep only answers that dedicated fans or specialists know. From those, pick the 5 most obscure and order them least known first. "best" must be the very first word, the most obscure of all. JSON only: {"words":["a","b","c","d","e"],"best":"a"}]]
-- Three free models are raced per prompt; the first valid answer wins.
local MODELS = {
    { id = "particle-ai/particle-1:free", maxTokens = 2000 },
    { id = "nvidia/nemotron-3-ultra-550b-a55b:free", maxTokens = 2000 },
    { id = "nvidia/nemotron-3-nano-omni-30b-a3b-reasoning:free", maxTokens = 2000 },
}

local function parseCompletion(content)
    content = content:gsub("^%s*`*%w*%s*", "")
    local startAt, endAt = content:find("{", 1, true), content:match(".*()}")
    local parsed
    if startAt and endAt then
        local ok, result = pcall(function()
            return game:GetService("HttpService"):JSONDecode(content:sub(startAt, endAt))
        end)
        if ok and type(result) == "table" then parsed = result end
    end

    local words = {}
    if parsed and type(parsed.words) == "table" then
        for _, word in ipairs(parsed.words) do
            if type(word) == "string" then
                word = word:gsub("^%s+", ""):gsub("%s+$", "")
                local lower = word:lower()
                if word ~= "" and #word <= 60
                    and not lower:match("^answer%d+$") and not lower:match("^[a-e]$")
                    and lower ~= "first" and lower ~= "word1" then
                    words[#words + 1] = word
                end
            end
            if #words == 5 then break end
        end
    end
    if #words == 0 then
        for line in content:gmatch("[^\r\n]+") do
            local word = line:gsub("^%s*%d+%s*[%.)%-]?%s*", ""):gsub("^[\"'*]+", ""):gsub("[\"'*,]+$", "")
            word = word:gsub("^%s+", ""):gsub("%s+$", "")
            if word ~= "" and #word <= 60 and not word:find("%f[%w]and%f[%w]") then
                words[#words + 1] = word
            end
            if #words == 5 then break end
        end
    end
    if #words == 0 then return nil end

    local best = (type(parsed) == "table" and type(parsed.best) == "string") and parsed.best or ""
    best = best:gsub("^%s+", ""):gsub("%s+$", "")
    local found = false
    for _, word in ipairs(words) do
        if word:lower() == best:lower() then found = true break end
    end
    if not found then best = words[1] end
    return words, best
end

local function askOne(config, prompt)
    local model = config.id
    local payload = {
        model = model,
        messages = {
            { role = "system", content = SYSTEM_PROMPT },
            { role = "user", content = "PROMPT: " .. prompt },
        },
        max_tokens = config.maxTokens,
        temperature = 0.2,
        stream = false,
        reasoning = { effort = "low" },
    }
    local okEncode, body = pcall(function() return game:GetService("HttpService"):JSONEncode(payload) end)
    if not okEncode or type(body) ~= "string" then return nil, nil, "Could not encode request" end

    local okRequest, response = pcall(function()
        return request({
            Url = API_URL,
            Method = "POST",
            Headers = { ["Content-Type"] = "application/json" },
            Body = body,
        })
    end)
    if not okRequest then return nil, nil, "Request failed: " .. tostring(response) end
    if type(response) == "string" then return nil, nil, "Request failed: " .. response:sub(1, 140) end

    local status = response.StatusCode
    if type(status) == "number" and (status < 200 or status >= 300) then
        return nil, nil, "HTTP " .. tostring(status) .. ": " .. tostring(response.Body):sub(1, 120)
    end
    local data = response.Body
    if type(data) == "string" then
        local okDecode, decoded = pcall(function() return game:GetService("HttpService"):JSONDecode(data) end)
        if okDecode then data = decoded end
    end
    local choice = type(data) == "table" and data.choices and data.choices[1]
    local content = choice and choice.message and choice.message.content
    if type(content) ~= "string" or content == "" then
        return nil, nil, "Empty completion from " .. model
    end
    local words, best = parseCompletion(content)
    if words then return words, best, nil end
    return nil, nil, "No words parsed from " .. model
end

local function askKiloAsync(prompt, onResult)
    state.raceToken = (state.raceToken or 0) + 1
    local token = state.raceToken
    local settled = false
    for _, config in ipairs(MODELS) do
        task.spawn(function()
            local words, best, err = askOne(config, prompt)
            if settled or state.raceToken ~= token then return end
            if words then
                settled = true
                pcall(onResult, words, best, nil, config.id)
            end
        end)
    end
    task.delay(45, function()
        if settled or state.raceToken ~= token then return end
        settled = true
        pcall(onResult, nil, nil, "All models failed or timed out")
    end)
end

local function readRound()
    local ok, result = pcall(function()
        local pg = game:GetService("Players").LocalPlayer:FindFirstChildOfClass("PlayerGui")
        local ui = pg and pg:FindFirstChild("RarestUI")
        local canvas = ui and ui:FindFirstChild("Canvas")
        local match = canvas and canvas:FindFirstChild("Match")
        if not match or not match.Visible then return nil end
        local console = match:FindFirstChild("Console")
        local promptFrame = console and console:FindFirstChild("Prompt")
        if not promptFrame then return nil end
        local question, round = "", ""
        for _, child in ipairs(promptFrame:GetChildren()) do
            if child:IsA("TextLabel") then
                local text = tostring(child.Text or ""):gsub("^%s+", ""):gsub("%s+$", "")
                if text ~= "" then
                    if text:match("^ROUND ") or text:match("^QUESTION ") then
                        round = text
                    elseif question == "" then
                        question = text
                    end
                end
            end
        end
        if question == "" then return nil end
        return { question = question, round = round, signature = question .. "|" .. round }
    end)
    if ok then return result end
    return nil
end

local function useWord(index)
    local word = state.words[index]
    if not word then return end
    pcall(function()
        local pg = game:GetService("Players").LocalPlayer:FindFirstChildOfClass("PlayerGui")
        local box = pg and pg:FindFirstChild("RarestUI")
        box = box and box:FindFirstChild("Canvas")
        box = box and box:FindFirstChild("Match")
        box = box and box:FindFirstChild("Console")
        box = box and box:FindFirstChild("Answer")
        box = box and box:FindFirstChild("Frame")
        box = box and box:FindFirstChild("Box")
        if box and box:IsA("TextBox") then
            box.Text = word
        end
    end)
end

local QUEUED_SOURCE = [[pcall(function() loadstring(game:HttpGet("https://raw.githubusercontent.com/FilipinoCollabEmtech/Jax-Chess-Scripts/main/RarestHelper.lua"))() end)]]

local function queueReload()
    local queue = typeof(queueonteleport) == "function" and queueonteleport
        or typeof(queue_on_teleport) == "function" and queue_on_teleport
        or typeof(queueteleport) == "function" and queueteleport
    local ok
    if queue then ok = pcall(queue, QUEUED_SOURCE) end
    if not ok and typeof(fluxus) == "table" and typeof(fluxus.queue_on_teleport) == "function" then
        ok = pcall(function() return fluxus.queue_on_teleport(QUEUED_SOURCE) end)
    end
end

local function main()
    state.uiToken = (state.uiToken or 0) + 1
    local myToken = state.uiToken
    state.suggestToken = (state.suggestToken or 0) + 1
    state.lastSignature = nil
    state.asking = false
    state.raceToken = (state.raceToken or 0) + 1

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
            local mine = child.Name == "RarestHelper"
            if not mine then
                pcall(function()
                    for _, label in ipairs(child:GetDescendants()) do
                        local text = label:IsA("TextLabel") and tostring(label.Text or "") or ""
                        if text == "Rarest Helper" or text == "Auto Suggest" then
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
    if not WindUI then warn("[RarestHelper] WindUI failed to load") return end
    if state.uiToken ~= myToken then return end
    queueReload()

    pcall(function()
        local connection = game:GetService("Players").LocalPlayer.OnTeleport:Connect(function()
            local queue = typeof(queueonteleport) == "function" and queueonteleport
                or typeof(queue_on_teleport) == "function" and queue_on_teleport
                or typeof(queueteleport) == "function" and queueteleport
            if queue then pcall(queue, QUEUED_SOURCE) end
        end)
        table.insert(state.connections, connection)
    end)

    local Window = WindUI:CreateWindow({
        Title = "Rarest Helper",
        Icon = "sparkles",
        Author = "OpenCode",
        Folder = "RarestHelper",
        Size = UDim2.fromOffset(460, 420),
        Theme = "Dark",
        ToggleKey = Enum.KeyCode.RightControl,
    })
    table.insert(state.objects, Window)
    task.spawn(function()
        while state.uiToken == myToken do task.wait(1) end
        pcall(function() Window:Destroy() end)
    end)

    local Main = Window:Tab({ Title = "Main", Icon = "home" })
    local panel = Main:Paragraph({ Title = "Suggestions", Desc = "Turn on Auto Suggest." })
    local function setPanel(title, desc)
        pcall(function()
            panel:SetTitle(title)
            panel:SetDesc(desc)
        end)
    end

    local rows = {}
    for i = 1, 5 do
        rows[i] = Main:Button({
            Title = tostring(i) .. ".",
            Desc = "waiting...",
            Callback = function() useWord(i) end,
        })
    end

    local function refresh(silent)
        local round = readRound()
        if not round then
            if not silent then setPanel("No round", "Join a match to read the prompt.") end
            return
        end
        state.lastSignature = round.signature
        state.words = {}
        state.best = nil
        state.asking = true
        for i = 1, 5 do pcall(function() rows[i]:SetDesc("asking...") end) end
        if not silent then
            setPanel(round.question, "Asking 3 Kilo models..." .. (round.round and ("\n" .. round.round) or ""))
        end
        askKiloAsync(round.question, function(words, best, err, model)
            state.asking = false
            state.winner = model
            local current = readRound()
            if not current or current.signature ~= round.signature then return end
            if not words then
                for i = 1, 5 do pcall(function() rows[i]:SetDesc("no suggestion") end) end
                setPanel(round.question, "Failed: " .. tostring(err))
                return
            end
            state.words = words
            state.best = best
            for i = 1, 5 do
                local word = words[i]
                pcall(function()
                    rows[i]:SetDesc(word and (word == best and (word .. "  <- least known") or word) or "waiting...")
                end)
            end
            setPanel(round.question, string.format("Least known: %s\n\n%s\nClick a row to fill your answer.",
                best, table.concat(words, "  |  ")) .. (round.round and ("\n" .. round.round) or ""))
        end)
    end

    Main:Button({ Title = "Refresh now", Desc = "Ask again for the current prompt", Callback = function() refresh(false) end })

    local function startLoop()
        state.suggestToken = (state.suggestToken or 0) + 1
        task.spawn(function()
            local token = state.suggestToken
            while state.suggestToken == token and state.autoSuggest do
                task.wait(1)
                if state.asking then continue end
                local round = readRound()
                if round and round.signature ~= state.lastSignature then
                    refresh(false)
                end
            end
        end)
    end

    local initUntil = os.clock() + 3
    local toggle = Main:Toggle({
        Title = "Auto Suggest",
        Desc = "Read each new prompt and show 5 rare answers",
        Value = false,
        Callback = function(on)
            -- WindUI fires a synthetic callback during construction; ignore that window.
            if os.clock() < initUntil then return end
            if on == state.autoSuggest then return end
            state.autoSuggest = on
            saveSettings()
            state.suggestToken = (state.suggestToken or 0) + 1
            if on then startLoop() end
        end,
    })
    pcall(function() toggle:Set(state.autoSuggest) end)
    if state.autoSuggest then startLoop() end
end

main()
