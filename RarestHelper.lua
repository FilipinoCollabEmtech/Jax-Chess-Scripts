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
local SYSTEM_PROMPT = [[You help a player in a word-rarity game. Given a short prompt, suggest five genuine, valid answers that fit it exactly. Prefer obscure but real answers, not famous ones. Order them from rarest to least rare. Reply with strict JSON only, no markdown, with the exact key "best" set to one of the five words: {"words":["answer1","answer2","answer3","answer4","answer5"],"best":"answer1"}]]
-- Several free gateway models spend their whole token budget on reasoning and return no content.
-- Try the ones that reliably answer, then fall back to the routed free model.
local MODELS = {
    "particle-ai/particle-1:free",
    "baidu/ernie-5.5-flash-preview:free",
    "kilo-auto/free",
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
                if word ~= "" and #word <= 60 then words[#words + 1] = word end
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

local function askKilo(prompt)
    local lastError = "No models tried"
    for _, model in ipairs(MODELS) do
        local payload = {
            model = model,
            messages = {
                { role = "system", content = SYSTEM_PROMPT },
                { role = "user", content = prompt },
            },
            max_tokens = 1200,
            temperature = 0.2,
            stream = false,
            reasoning = { effort = "none" },
        }
        local okEncode, body = pcall(function() return game:GetService("HttpService"):JSONEncode(payload) end)
        if not okEncode or type(body) ~= "string" then
            lastError = "Could not encode request"
            continue
        end

        local okRequest, response = pcall(function()
            return request({
                Url = API_URL,
                Method = "POST",
                Headers = { ["Content-Type"] = "application/json" },
                Body = body,
            })
        end)
        if not okRequest then lastError = "Request failed: " .. tostring(response) continue end
        if type(response) == "string" then lastError = "Request failed: " .. response:sub(1, 140) continue end

        local status = response.StatusCode
        if type(status) == "number" and (status < 200 or status >= 300) then
            lastError = "HTTP " .. tostring(status) .. ": " .. tostring(response.Body):sub(1, 120)
            continue
        end
        local data = response.Body
        if type(data) == "string" then
            local okDecode, decoded = pcall(function() return game:GetService("HttpService"):JSONDecode(data) end)
            if okDecode then data = decoded end
        end
        local choice = type(data) == "table" and data.choices and data.choices[1]
        local content = choice and choice.message and choice.message.content
        if type(content) ~= "string" or content == "" then
            lastError = "Empty completion from " .. model
            continue
        end
        local words, best = parseCompletion(content)
        if words then return words, best, nil end
        lastError = "No words parsed from " .. model
    end
    return nil, nil, lastError
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
                    if text:find("ROUND", 1, true) then round = text else question = text end
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
        ToggleKey = Enum.KeyCode.RightShift,
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
        if not silent then
            setPanel(round.question, "Asking Kilo free gateway..." .. (round.round and ("\n" .. round.round) or ""))
        end
        local words, best, err = askKilo(round.question)
        if not words then
            setPanel(round.question, "Failed: " .. tostring(err))
            return
        end
        state.words = words
        for i = 1, 5 do
            local word = words[i]
            pcall(function()
                rows[i]:SetDesc(word and ((i == 1 or word == best) and (word .. "  <- rarest") or word) or "waiting...")
            end)
        end
        setPanel(round.question, string.format("Rarest: %s\n\n%s\nClick a row to fill your answer.",
            best, table.concat(words, "  |  ")) .. (round.round and ("\n" .. round.round) or ""))
    end

    Main:Button({ Title = "Refresh now", Desc = "Ask again for the current prompt", Callback = function() refresh(false) end })

    local initGuard = true
    Main:Toggle({
        Title = "Auto Suggest",
        Desc = "Read each new prompt and show 5 rare answers",
        Value = state.autoSuggest,
        Callback = function(on)
            -- WindUI invokes this during construction; ignore that synthetic event.
            if initGuard then return end
            state.autoSuggest = on
            saveSettings()
            state.suggestToken = (state.suggestToken or 0) + 1
            if not on then return end
            task.spawn(function()
                local token = state.suggestToken
                while state.suggestToken == token and state.autoSuggest do
                    task.wait(1)
                    if state.asking then continue end
                    local round = readRound()
                    if round and round.signature ~= state.lastSignature then
                        state.asking = true
                        refresh(false)
                        state.asking = false
                    end
                end
            end)
        end,
    })
    initGuard = false
    if state.autoSuggest then
        local toggle
        for _, element in pairs(Main.Elements or {}) do
            if type(element) == "table" and element.Title == "Auto Suggest" then toggle = element break end
        end
        if toggle and type(toggle.Callback) == "function" then pcall(function() toggle.Callback(true) end) end
    end
end

main()
