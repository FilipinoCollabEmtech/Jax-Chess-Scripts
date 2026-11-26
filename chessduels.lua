--[[
  chessduels - Chess Duels helper
  Engine analysis (manual + auto), depth selector, mate display, board arrows
  and highlights, auto play with human timing, bot/online join, puzzle auto next.
]]
local genv = typeof(getgenv) == "function" and getgenv() or _G
local state = genv.chessduelsState
if type(state) ~= "table" then
    state = {}
    genv.chessduelsState = state
end
state.depth = state.depth or 12
state.humanTiming = state.humanTiming or true
state.autoSuggest = state.autoSuggest or false
state.autoPlay = state.autoPlay or false
state.puzzleAutoNext = state.puzzleAutoNext or false
state.botKey = state.botKey or "pip"
state.tc = state.tc or "blitz"
state.connections = state.connections or {}
state.objects = state.objects or {}
state.suggestionCache = state.suggestionCache or {}
state.opponentTimes = state.opponentTimes or {}
state.ourMoveCount = state.ourMoveCount or 0

local SETTINGS_PATH = "chessduels/settings.json"

local function loadSettings()
    if typeof(isfile) ~= "function" or typeof(readfile) ~= "function" then return end
    local okExists, exists = pcall(function() return isfile(SETTINGS_PATH) end)
    if not okExists or not exists then return end
    local okRead, content = pcall(function() return readfile(SETTINGS_PATH) end)
    if not okRead or type(content) ~= "string" then return end
    local okJson, data = pcall(function()
        return game:GetService("HttpService"):JSONDecode(content)
    end)
    if not okJson or type(data) ~= "table" then return end
    if type(data.depth) == "number" then state.depth = math.clamp(math.floor(data.depth), 1, 18) end
    if type(data.humanTiming) == "boolean" then state.humanTiming = data.humanTiming end
    if type(data.autoSuggest) == "boolean" then state.autoSuggest = data.autoSuggest end
    if type(data.autoPlay) == "boolean" then state.autoPlay = data.autoPlay end
    if type(data.puzzleAutoNext) == "boolean" then state.puzzleAutoNext = data.puzzleAutoNext end
    if type(data.botKey) == "string" then state.botKey = data.botKey end
    if type(data.tc) == "string" then state.tc = data.tc end
end

local function saveSettings()
    if typeof(writefile) ~= "function" then return end
    local okJson, json = pcall(function()
        return game:GetService("HttpService"):JSONEncode({
            depth = state.depth,
            humanTiming = state.humanTiming,
            autoSuggest = state.autoSuggest,
            autoPlay = state.autoPlay,
            puzzleAutoNext = state.puzzleAutoNext,
            botKey = state.botKey,
            tc = state.tc,
        })
    end)
    if okJson and type(json) == "string" then
        pcall(function() writefile(SETTINGS_PATH, json) end)
    end
end

loadSettings()

local API_URL = "https://stockfish.online/api/s/v2.php"

local function getBoard()
    local ok, board = pcall(function()
        return filtergc("table", { Keys = { "state", "premoveList" } }, true)
    end)
    if ok and type(board) == "table" then return board end
    return nil
end

local function getEngine()
    local ok, engine = pcall(function()
        return require(game:GetService("ReplicatedStorage").Chess.Engine)
    end)
    if ok and type(engine) == "table" then return engine end
    return nil
end

local function getAction()
    local ok, action = pcall(function()
        return game:GetService("ReplicatedStorage").ChessRemotes.Action
    end)
    if ok and action then return action end
    return nil
end

local function getFen()
    local board, engine = getBoard(), getEngine()
    if not board or not engine then return nil end
    local ok, fen = pcall(function() return engine.toFEN(board.state) end)
    if ok and type(fen) == "string" then return fen end
    return nil
end

local function getSession()
    local ok, list = pcall(function()
        return filtergc("table", { Keys = { "you", "ply", "kind" } })
    end)
    if not ok or type(list) ~= "table" then return nil end
    local best, bestScore = nil, -1
    for _, session in ipairs(list) do
        if type(session) == "table" then
            local score = (session.running == true and 100 or 0)
                + (tonumber(session.ply) or 0)
                + (session.kind ~= "game" and 20 or 0)
            if score > bestScore then
                best, bestScore = session, score
            end
        end
    end
    return best
end

local function myColor()
    local session = getSession()
    local color = session and tonumber(session.you) or 0
    if color and color ~= 0 then return color end
    local board = getBoard()
    return board and tonumber(board.side) or 0
end

local function isMyTurn()
    local board = getBoard()
    if not board then return false end
    local color = myColor()
    return color ~= 0 and board.state.turn == color
end

local function clockMs()
    local session = getSession()
    local clock = session and session.clock
    if type(clock) ~= "table" then return nil end
    local color = myColor()
    local key = color == -1 and "b" or "w"
    local remaining = tonumber(clock[key])
    if not remaining then return nil end
    local sentAt = tonumber(clock.sentAt or clock.at)
    if sentAt then
        remaining = remaining - (workspace:GetServerTimeNow() - sentAt) * 1000
    end
    return math.max(0, remaining)
end

local function uciToMove(uci)
    local board, engine = getBoard(), getEngine()
    if not board or not engine or type(uci) ~= "string" or #uci < 4 then return nil end
    local ok, move = pcall(function() return engine.fromUci(board.state, uci) end)
    if ok and type(move) == "table" and move.from and move.to then return move end
    local fromOk, from = pcall(function()
        return engine.square(string.byte(uci, 1) - 97, tonumber(uci:sub(2, 2)) - 1)
    end)
    local toOk, to = pcall(function()
        return engine.square(string.byte(uci, 3) - 97, tonumber(uci:sub(4, 4)) - 1)
    end)
    if not fromOk or not toOk then return nil end
    local promo = ({ q = 5, r = 4, b = 3, n = 2 })[uci:sub(5, 5):lower()] or 0
    return { from = from, to = to, promo = promo }
end

local function playUci(uci)
    local move = uciToMove(uci)
    local action = getAction()
    if not move or not action then return false end
    local ok, err = pcall(function()
        action:FireServer("move", { from = move.from, to = move.to, promo = move.promo })
    end)
    return ok, ok and nil or tostring(err)
end

local function clearVisuals()
    local board = getBoard()
    if not board then return end
    if type(board.renderArrows) == "function" then
        if type(board.arrows) ~= "table" then board.arrows = {} end
        for key in pairs(board.arrows) do
            if tostring(key):find("chessduels", 1, true) then board.arrows[key] = nil end
        end
        pcall(function() board:renderArrows() end)
    end
    if board.arrowLayer then
        for _, child in ipairs(board.arrowLayer:GetChildren()) do
            if child.Name:find("chessduels", 1, true) then
                pcall(function() child:Destroy() end)
            end
        end
    end
    if board.marksLayer then
        for _, child in ipairs(board.marksLayer:GetChildren()) do
            if child.Name:find("chessduels", 1, true) then
                pcall(function() child:Destroy() end)
            end
        end
    end
end

local function drawMarkings(move)
    clearVisuals()
    local board = getBoard()
    if not board or not move then return end
    local layer = board.marksLayer
    if not layer or type(board.cellPos) ~= "function" then return end
    local colors = { Color3.fromRGB(70, 200, 255), Color3.fromRGB(130, 255, 170) }
    for i, sq in ipairs({ move.from, move.to }) do
        local ok, position = pcall(function() return board:cellPos(sq) end)
        if ok and position then
            local frame = Instance.new("Frame")
            frame.Name = "chessduelsMark" .. i
            frame.Size = UDim2.fromScale(0.125, 0.125)
            frame.Position = position
            frame.BackgroundColor3 = colors[i]
            frame.BackgroundTransparency = 0.55
            frame.ZIndex = 2
            frame.Parent = layer
        end
    end
end

local function drawArrow(move)
    local board = getBoard()
    if not board or not move or type(board.renderArrows) ~= "function" then return end
    board.arrows = {
        chessduels = {
            from = move.from,
            to = move.to,
            color = Color3.fromRGB(255, 205, 70),
        },
    }
    pcall(function() board:renderArrows() end)
end

local function urlEncode(s)
    return (tostring(s):gsub("[^%w%-_%.~]", function(c)
        return string.format("%%%02X", c:byte())
    end))
end

local function requestSuggestion(fen)
    local key = tostring(state.depth) .. "|" .. fen
    local cached = state.suggestionCache[key]
    if cached then return cached, nil, true end
    local url = string.format("%s?fen=%s&depth=%d", API_URL, urlEncode(fen), state.depth)
    local ok, response = pcall(function() return request({ Url = url, Method = "GET" }) end)
    if not ok then return nil, "HTTP error: " .. tostring(response) end
    if type(response) == "string" then return nil, "HTTP error: " .. response end
    local status, body = response.StatusCode, response.Body
    if type(status) == "number" and (status < 200 or status >= 300) then
        return nil, "HTTP " .. tostring(status) .. ": " .. tostring(body):sub(1, 120)
    end
    if type(body) ~= "string" or body == "" then return nil, "Empty API response" end
    local okJson, data = pcall(function()
        return game:GetService("HttpService"):JSONDecode(body)
    end)
    if not okJson or type(data) ~= "table" then return nil, "Invalid API response" end
    if data.success ~= true then return nil, "API error: " .. tostring(data.data or data.message or "unknown") end
    state.suggestionCache[key] = data
    local count = 0
    for _ in pairs(state.suggestionCache) do count = count + 1 end
    if count > 40 then state.suggestionCache = {} end
    return data, nil, false
end

local function formatSuggestion(data, fen)
    local raw = tostring(data.bestmove or "")
    local move = raw:match("^bestmove%s+(%S+)") or "?"
    local ponder = raw:match("ponder%s+(%S+)")
    local title, score
    if data.mate ~= nil then
        title = "MATE IN " .. tostring(data.mate)
        score = "Forced mate in " .. tostring(data.mate)
    else
        title = "Suggestion"
        score = type(data.evaluation) == "number" and string.format("%+.2f", data.evaluation) or tostring(data.evaluation or "n/a")
    end
    return title, string.format("Best move: %s%s\nEvaluation: %s\nLine: %s\nFEN: %s",
        move, ponder and ("\nOpponent's likely reply: " .. ponder) or "", score,
        tostring(data.continuation or "n/a"), fen), move
end

local function median(values)
    if #values == 0 then return nil end
    local sorted = table.create(#values)
    for i = 1, #values do sorted[i] = values[i] end
    table.sort(sorted)
    local n = #sorted
    if n % 2 == 1 then return sorted[(n + 1) // 2] end
    return (sorted[n // 2] + sorted[n // 2 + 1]) / 2
end

local function noteOurMove()
    state.ourMoveCount = state.ourMoveCount + 1
    state.lastOurMoveAt = os.clock()
    state.awaitingOpponent = true
end

local function noteOpponentMove()
    if not state.awaitingOpponent then return end
    local elapsed = os.clock() - (state.lastOurMoveAt or 0)
    state.awaitingOpponent = false
    if elapsed > 0.3 and elapsed < 30 then
        state.opponentTimes[#state.opponentTimes + 1] = elapsed
        if #state.opponentTimes > 6 then table.remove(state.opponentTimes, 1) end
    end
end

local function humanDelay()
    local clock = clockMs()
    if clock and clock > 0 and clock < 20000 then return 0 end
    if not state.humanTiming then return 0 end
    if state.ourMoveCount < 2 then return 0 end
    local base = median(state.opponentTimes) or 2.5
    local jitter = 0.85 + math.random() * 0.30
    return math.clamp(base * 0.7 * jitter, 0.3, 3.5)
end

-- Queued chunk: always load the newest script straight from GitHub raw.
local QUEUED_SOURCE = [[pcall(function() loadstring(game:HttpGet("https://raw.githubusercontent.com/FilipinoCollabEmtech/Jax-Chess-Scripts/main/chessduels.lua"))() end)]]

local function queueReload()
    if state.queuedFor == game.PlaceId and not state.queueConsumed then return end
    if typeof(clearqueueonteleport) == "function" then
        pcall(clearqueueonteleport)
    elseif typeof(clear_tp_queue) == "function" then
        pcall(clear_tp_queue)
    elseif typeof(clearqueueteleport) == "function" then
        pcall(clearqueueteleport)
    end
    local queue = typeof(queueonteleport) == "function" and queueonteleport
        or typeof(queue_on_teleport) == "function" and queue_on_teleport
        or typeof(queueteleport) == "function" and queueteleport
        or typeof(queue_on_tp) == "function" and queue_on_tp
        or typeof(queueontp) == "function" and queueontp
    local ok, err
    if queue then
        ok, err = pcall(queue, QUEUED_SOURCE)
    end
    if not ok and typeof(fluxus) == "table" and typeof(fluxus.queue_on_teleport) == "function" then
        ok, err = pcall(function() return fluxus.queue_on_teleport(QUEUED_SOURCE) end)
    end
    if ok then
        state.queuedFor = game.PlaceId
        state.queueConsumed = false
    else
        warn("[chessduels] queueonteleport failed: " .. tostring(err))
    end
end

local function main()
    state.autoEnabled = false
    state.autoToken = (state.autoToken or 0) + 1
    state.playToken = (state.playToken or 0) + 1
    state.puzzleNextToken = (state.puzzleNextToken or 0) + 1
    state.sideToken = (state.sideToken or 0) + 1
    state.uiToken = (state.uiToken or 0) + 1
    local myUiToken = state.uiToken
    state.lastAutoFen = nil
    state.lastPlayedFen = nil
    clearVisuals()

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
            local mine = child.Name == "chessduels" or child.Name == "WindUI"
            if not mine then
                pcall(function()
                    for _, label in ipairs(child:GetDescendants()) do
                        local text = label:IsA("TextLabel") and tostring(label.Text or "") or ""
                        if text == "chessduels" or text == "Your side" then
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
            return loadstring(game:HttpGet("https://raw.githubusercontent.com/FilipinoCollabEmtech/Jax-Chess-Scripts/main/vendor/WindUI.lua?v=1e46707"))()
        end)
        if ok and type(ui) == "table" and type(ui.CreateWindow) == "function" then
            WindUI = ui
            break
        end
        task.wait(0.4)
    end
    if not WindUI then warn("[chessduels] WindUI failed to load") return end
    if state.uiToken ~= myUiToken then return end

    queueReload()

    pcall(function()
        local player = game:GetService("Players").LocalPlayer
        local connection = player.OnTeleport:Connect(function()
            if typeof(clearqueueonteleport) == "function" then
                pcall(clearqueueonteleport)
            end
            local queue = typeof(queueonteleport) == "function" and queueonteleport
                or typeof(queue_on_teleport) == "function" and queue_on_teleport
                or typeof(queueteleport) == "function" and queueteleport
                or typeof(queue_on_tp) == "function" and queue_on_tp
                or typeof(queueontp) == "function" and queueontp
            local ok = queue and pcall(queue, QUEUED_SOURCE) or false
            if not ok and typeof(fluxus) == "table" and typeof(fluxus.queue_on_teleport) == "function" then
                pcall(function() return fluxus.queue_on_teleport(QUEUED_SOURCE) end)
            end
        end)
        table.insert(state.connections, connection)
    end)

    local Window = WindUI:CreateWindow({
        Title = "chessduels",
        Icon = "castle",
        Author = "By Criexter",
        Folder = "chessduels",
        Size = UDim2.fromOffset(460, 420),
        Theme = "Dark",
        ToggleKey = Enum.KeyCode.RightControl,
    })
    table.insert(state.objects, Window)
    task.spawn(function()
        while state.uiToken == myUiToken do task.wait(1) end
        pcall(function() Window:Destroy() end)
    end)

    local Main = Window:Tab({ Title = "Main", Icon = "home" })
    Main:Section({ Title = "Chess", Opened = true })

    local result = Main:Paragraph({ Title = "Suggestion", Desc = "Press Suggest Move to analyse the current position." })
    local sideLabel = Main:Paragraph({ Title = "Your side", Desc = "Unknown - join a game or puzzle first." })

    local function setSideLabel()
        local color = myColor()
        local session = getSession()
        local text = color == 1 and "White" or color == -1 and "Black" or "Unknown - not in a game"
        if session and session.kind and session.kind ~= "game" then
            text = text .. " (" .. tostring(session.kind) .. ")"
        end
        pcall(function() sideLabel:SetDesc(text) end)
    end

    setSideLabel()
    task.spawn(function()
        local token = state.sideToken
        while state.sideToken == token do
            task.wait(1)
            setSideLabel()
        end
    end)

    local function setResult(title, desc)
        pcall(function()
            result:SetTitle(title)
            result:SetDesc(desc)
        end)
    end

    local function analyseFen(fen)
        local t0 = os.clock()
        local data, apiErr, cached = requestSuggestion(fen)
        local latency = os.clock() - t0
        if not data then
            setResult("Analysis failed", apiErr .. "\nFEN: " .. fen)
            return false
        end
        local title, desc, move = formatSuggestion(data, fen)
        desc = desc .. string.format("\nEngine: %.2fs%s", latency, cached and " (cached)" or "")
        setResult(title, desc)
        drawMarkings(uciToMove(move))
        drawArrow(uciToMove(move))
        return true
    end

    Main:Button({
        Title = "Suggest Move",
        Desc = "Analyse the current board",
        Callback = function()
            local fen = getFen()
            if not fen then setResult("No board", "Join a game first") return end
            setResult("Suggestion", "Engine thinking...")
            analyseFen(fen)
        end,
    })

    Main:Dropdown({
        Title = "Engine Depth",
        Values = { "8", "10", "12", "14", "15", "16", "18" },
        Value = tostring(state.depth),
        Callback = function(value)
            state.depth = tonumber(value) or 12
            saveSettings()
        end,
    })

    local autoSuggestToggle
    autoSuggestToggle = Main:Toggle({
        Title = "Auto Suggest",
        Desc = "Analyse on every new position when it is your turn",
        Value = state.autoSuggest,
        Callback = function(on)
            state.autoSuggest = on
            saveSettings()
            state.autoToken = (state.autoToken or 0) + 1
            if on then
                state.lastAutoFen = nil
                task.spawn(function()
                    local token = state.autoToken
                    while state.autoToken == token and state.autoSuggest do
                        task.wait(state.turbo and 0 or 0.5)
                        local clockNow = clockMs()
                        state.turbo = clockNow ~= nil and clockNow > 0 and clockNow < 20000
                        setSideLabel()
                        local fen = getFen()
                        if fen and fen ~= state.lastSeenFen then
                            if state.awaitingOpponent and not isMyTurn() then noteOpponentMove() end
                            state.lastSeenFen = fen
                        end
                        if not isMyTurn() then continue end
                        if fen and fen ~= state.lastAutoFen then
                            state.lastAutoFen = fen
                            pcall(analyseFen, fen)
                        end
                    end
                end)
            end
        end,
    })
    if state.autoSuggest then
        pcall(function() autoSuggestToggle.Callback(true) end)
    end

    Main:Section({ Title = "Auto Play Settings", Opened = false })
    Main:Toggle({
        Title = "Human Timing",
        Desc = "First 2 moves instant, then mirror opponent pace",
        Value = state.humanTiming,
        Callback = function(on) state.humanTiming = on; saveSettings() end,
    })
    local autoPlayToggle
    autoPlayToggle = Main:Toggle({
        Title = "Auto Play",
        Desc = "Play the suggested move on your turn",
        Value = state.autoPlay,
        Callback = function(on)
            state.autoPlay = on
            saveSettings()
            state.playToken = (state.playToken or 0) + 1
            if on then
                state.ourMoveCount = 0
                task.spawn(function()
                    local token = state.playToken
                    while state.playToken == token and state.autoPlay do
                        task.wait(state.turbo and 0 or 0.5)
                        local clockNow = clockMs()
                        state.turbo = clockNow ~= nil and clockNow > 0 and clockNow < 20000
                        setSideLabel()
                        if not isMyTurn() then continue end
                        local fen = getFen()
                        if not fen or fen == state.lastPlayedFen then continue end
                        local t0 = os.clock()
                        local data = requestSuggestion(fen)
                        if data then
                            local _, _, move = formatSuggestion(data, fen)
                            if move and move ~= "?" then
                                task.wait(humanDelay())
                                local ok = playUci(move)
                                if ok then
                                    state.lastPlayedFen = fen
                                    noteOurMove()
                                    drawMarkings(uciToMove(move))
                                end
                            end
                        end
                    end
                end)
            end
        end,
    })
    if state.autoPlay then
        pcall(function() autoPlayToggle.Callback(true) end)
    end
    Main:Button({
        Title = "Clear Markings",
        Callback = function() clearVisuals() end,
    })

    local Play = Window:Tab({ Title = "Play", Icon = "gamepad" })
    local theme = require(game:GetService("ReplicatedStorage").Chess.Theme)
    local botEntries = {}
    if type(theme.BOT_ROSTER) == "table" then
        for _, bot in ipairs(theme.BOT_ROSTER) do
            botEntries[#botEntries + 1] = { key = bot.key, label = tostring(bot.name or bot.key) .. " (" .. tostring(bot.elo or 0) .. ")" }
        end
    end
    if #botEntries == 0 then
        local Bot = require(game:GetService("ReplicatedStorage").Chess.Bot)
        for i, bot in ipairs(Bot.ROSTER or {}) do
            botEntries[#botEntries + 1] = { key = bot.key, label = tostring(bot.name or i) .. " (" .. tostring(bot.elo or 0) .. ")" }
        end
    end
    table.sort(botEntries, function(a, b) return a.label < b.label end)
    local botLabels = {}
    local defaultBot = botEntries[1] and botEntries[1].label or state.botKey
    for _, entry in ipairs(botEntries) do
        botLabels[#botLabels + 1] = entry.label
        if entry.key == state.botKey then defaultBot = entry.label end
    end
    local function botKeyFor(label)
        for _, entry in ipairs(botEntries) do
            if entry.label == label then return entry.key end
        end
        return state.botKey
    end

    Play:Section({ Title = "Bot Game", Opened = true })
    Play:Dropdown({
        Title = "Bot",
        Values = #botLabels > 0 and botLabels or { state.botKey },
        Value = defaultBot,
        Callback = function(value) state.botKey = botKeyFor(value); saveSettings() end,
    })
    Play:Button({
        Title = "Play Bot",
        Desc = "Start a game against the selected bot",
        Callback = function()
            local action = getAction()
            if not action then return end
            pcall(function() action:FireServer("playBot", { level = state.botKey }) end)
        end,
    })

    Play:Section({ Title = "Online" })
    local tcs = {}
    for _, tc in ipairs(theme.TimeControls or {}) do tcs[#tcs + 1] = tc.key end
    if #tcs == 0 then tcs = { "bullet", "blitz", "rapid" } end
    Play:Dropdown({
        Title = "Time Control",
        Values = tcs,
        Value = state.tc,
        Callback = function(value) state.tc = value; saveSettings() end,
    })
    Play:Button({
        Title = "Join Queue",
        Callback = function()
            local action = getAction()
            if action then pcall(function() action:FireServer("queue", { tc = state.tc }) end) end
        end,
    })
    Play:Button({
        Title = "Cancel Queue",
        Callback = function()
            local action = getAction()
            if action then pcall(function() action:FireServer("cancelQueue") end) end
        end,
    })
    Play:Button({
        Title = "Rematch",
        Callback = function()
            local action = getAction()
            if action then pcall(function() action:FireServer("rematch") end) end
        end,
    })

    Play:Section({ Title = "Puzzle", Opened = false })
    Play:Toggle({
        Title = "Auto Next",
        Desc = "Press the game's Next button when a puzzle is solved",
        Value = state.puzzleAutoNext,
        Callback = function(on)
            state.puzzleAutoNext = on
            saveSettings()
            state.puzzleNextToken = (state.puzzleNextToken or 0) + 1
            if on then
                task.spawn(function()
                    local token = state.puzzleNextToken
                    while state.puzzleNextToken == token and state.puzzleAutoNext do
                        task.wait(0.5)
                        local button = findNextButton()
                        if button and button.Visible then
                            if typeof(firesignal) == "function" then
                                pcall(function() firesignal(button.Activated) end)
                                pcall(function() firesignal(button.MouseButton1Down) end)
                                pcall(function() firesignal(button.MouseButton1Up) end)
                            end
                        end
                    end
                end)
            end
        end,
    })
end

function findNextButton()
    local pg = game:GetService("Players").LocalPlayer:FindFirstChildOfClass("PlayerGui")
    if not pg then return nil end
    for _, descendant in ipairs(pg:GetDescendants()) do
        if descendant:IsA("TextLabel") and tostring(descendant.Text or "") == "Next" then
            local parent = descendant:FindFirstAncestorOfClass("TextButton")
            if parent and parent.Visible then return parent end
        end
    end
    return nil
end

main()
