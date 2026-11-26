--[[
  RoChess - chess helper
  Main tab: engine analysis (manual + auto), depth selector, mate display,
  board arrows/highlights, auto-clear on move, auto play,
  human-timing pace for auto play.
]]

local genv = typeof(getgenv) == "function" and getgenv() or _G
local state = genv.RoChessState
if type(state) ~= "table" then
    state = {}
    genv.RoChessState = state
end
state.connections = state.connections or {}
state.depth = state.depth or 12
state.humanTiming = state.humanTiming or false
state.autoSuggest = state.autoSuggest or false
state.opponentTimes = state.opponentTimes or {}
state.ourMoveCount = state.ourMoveCount or 0
state.suggestionCache = state.suggestionCache or {}
state.botId = state.botId or "jasper"
state.botColor = state.botColor or "Random"
state.tc = state.tc or "3+2"
state.playMode = state.playMode or "Bot"
state.modeAutoPlay = state.modeAutoPlay or { Bot = true, Online = true }
state.modeAutoReplay = state.modeAutoReplay or { Bot = false, Online = false }
state.puzzleAutoNext = state.puzzleAutoNext or false

-- First two moves played locally, no API round trip.
-- White: Queen's Gambit. Black: QGD/Slav/QGA responses after 1.d4 d5 2.c4.
local OPENING_BOOK = {
    [1] = { "d2d4", "c2c4" },
    [-1] = { "d7d5", "e7e6", "c7c6", "d5c4" },
}

local SETTINGS_PATH = "RoChess/settings.json"

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
    if type(data.depth) == "number" and data.depth >= 1 and data.depth <= 15 then
        state.depth = math.clamp(math.floor(data.depth), 1, 15)
    end
    if type(data.humanTiming) == "boolean" then state.humanTiming = data.humanTiming end
    if type(data.autoSuggest) == "boolean" then state.autoSuggest = data.autoSuggest end
    if type(data.autoPlay) == "boolean" then state.autoPlay = data.autoPlay end
    if type(data.puzzleAutoNext) == "boolean" then state.puzzleAutoNext = data.puzzleAutoNext end
    if type(data.botId) == "string" then state.botId = data.botId end
    if type(data.botColor) == "string" then state.botColor = data.botColor end
    if type(data.tc) == "string" then state.tc = data.tc end
    if type(data.playMode) == "string" then state.playMode = data.playMode end
    if type(data.modeAutoPlay) == "table" then
        for mode, on in pairs(data.modeAutoPlay) do
            if type(on) == "boolean" then state.modeAutoPlay[mode] = on end
        end
    end
    if type(data.modeAutoReplay) == "table" then
        for mode, on in pairs(data.modeAutoReplay) do
            if type(on) == "boolean" then state.modeAutoReplay[mode] = on end
        end
    end
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
            botId = state.botId,
            botColor = state.botColor,
            tc = state.tc,
            playMode = state.playMode,
            modeAutoPlay = state.modeAutoPlay,
            modeAutoReplay = state.modeAutoReplay,
        })
    end)
    if not okJson or type(json) ~= "string" then return end
    pcall(function() writefile(SETTINGS_PATH, json) end)
end

loadSettings()

local WINDUI_URL = "https://raw.githubusercontent.com/FilipinoCollabEmtech/Jax-Chess-Scripts/9146aaf/vendor/WindUI.lua"
local KEY_URL = "https://script.google.com/macros/s/AKfycbwVZ90la5-QzCgbtA1uqpOBgMdz0c72Y0qjq-4i66tTNURFk7Ae7rTi025IJ4VXnGMS/exec"
local KEY_COPY_URL = "https://loot-link.com/s?GzjJ7ox2"

local function loadWindUI()
    for attempt = 1, 3 do
        local ok, ui = pcall(function()
            return loadstring(game:HttpGet(WINDUI_URL))()
        end)
        if ok and type(ui) == "table" and type(ui.CreateWindow) == "function" then
            return ui
        end
        task.wait(0.4)
    end
    return nil
end

local function trackConnection(connection)
    if connection then
        state.connections[#state.connections + 1] = connection
    end
end

local ARROW_IDS = { "urochess", "urochess_p" }
local HL_FROM, HL_TO = "RoChessFrom", "RoChessTo"

local function getApp()
    -- Resolve the module at runtime: a literal path fails Real's static analyzer.
    local parts = { "Chess", "Client" }
    local ok, App = pcall(function()
        local root = game:GetService("ReplicatedStorage"):FindFirstChild(table.concat(parts))
        if not root then return nil end
        local module = root:FindFirstChild("App")
        if not module then return nil end
        return require(module)
    end)
    if ok and type(App) == "table" then return App end
    return nil
end

local function inTournamentGame()
    local ok, TourFx = pcall(function()
        local rs = game:GetService("ReplicatedStorage")
        return require(rs:FindFirstChild("ChessClient"):FindFirstChild("TourFx"))
    end)
    if ok and type(TourFx) == "table" and type(TourFx.isArmed) == "function" then
        local armedOk, armed = pcall(function() return TourFx.isArmed() end)
        if armedOk and armed == true then return true end
    end

    local App = getApp()
    local Tournament = App and App.Tournament
    if Tournament then
        local okRun, running = pcall(function()
            return Tournament.isRunning and Tournament.isRunning()
        end)
        local okEnt, entrant = pcall(function()
            return Tournament.isEntrant and Tournament.isEntrant()
        end)
        if okRun and okEnt and running == true and entrant == true then return true end
    end
    return false
end

local function getConfig()
    local ok, Config = pcall(function()
        local rs = game:GetService("ReplicatedStorage")
        return require(rs:FindFirstChild("Chess"):FindFirstChild("Config"))
    end)
    if ok and type(Config) == "table" then return Config end
    return nil
end

local function modeForKind(kind)
    if kind == "bot" then return "Bot" end
    if kind == "online" then return "Online" end
    return nil
end

local function modeAllowsPlay(kind)
    local mode = modeForKind(kind)
    if not mode then return true end
    if state.modeAutoPlay.All == true then return true end
    if state.playMode == "All" then return state.modeAutoPlay[mode] ~= false end
    if state.playMode ~= mode then return false end
    return state.modeAutoPlay[mode] == true
end

local function modeAllowsReplay(mode)
    if state.modeAutoReplay.All == true then return true end
    if state.playMode == "All" then return state.modeAutoReplay[mode] == true end
    if state.playMode ~= mode then return false end
    return state.modeAutoReplay[mode] == true
end

local function startSameMode(kind)
    local App = getApp()
    if not App then return false end
    if kind == "bot" then
        local ok, result = pcall(function()
            return App.startBotGame(state.botId, state.botColor)
        end)
        return ok and result ~= false
    elseif kind == "online" then
        -- Queue a fresh game directly; never send a rematch offer to the last opponent.
        local queued, qresult = pcall(function() return App.startSearch(state.tc) end)
        return queued and qresult ~= false
    end
    return false
end

local function getBoardContainers()
    local ok, result = pcall(function()
        local pg = game:GetService("Players").LocalPlayer:FindFirstChildOfClass("PlayerGui")
        local ui = pg and pg:FindFirstChild("ChessUI")
        local root = ui and ui:FindFirstChild("Root")
        local board = root and root:FindFirstChild("Board")
        if not board then return nil end
        local squares = board:FindFirstChild("Squares")
        return {
            arrows = board:FindFirstChild("Arrows"),
            highlights = squares and squares:FindFirstChild("Highlights"),
        }
    end)
    if ok and type(result) == "table" then return result end
    return nil
end

local function clearVisuals()
    local App = getApp()
    if App and App.board then
        for _, id in ipairs(ARROW_IDS) do
            pcall(function() App.board:setArrow(id, nil) end)
        end
    end
    local containers = getBoardContainers()
    local highlights = containers and containers.highlights
    if highlights then
        for _, name in ipairs({ HL_FROM, HL_TO }) do
            local frame = highlights:FindFirstChild(name)
            if frame then pcall(function() frame:Destroy() end) end
        end
    end
end

local function cleanup()
    state.autoEnabled = false
    state.autoToken = (state.autoToken or 0) + 1
    state.playToken = (state.playToken or 0) + 1
    -- autoPlay is persisted; loadSettings restored it before cleanup.
    state.lastAutoFen = nil
    state.lastSeenFen = nil
    state.lastPlayedFen = nil
    state.lastObservedFen = nil
    state.lastOurMoveAt = 0
    state.awaitingOpponent = false
    state.ourMoveCount = 0
    clearVisuals()

    for _, connection in ipairs(state.connections) do
        pcall(function() connection:Disconnect() end)
    end
    state.connections = {}

    local hosts = {}
    if typeof(gethui) == "function" then
        local ok, ui = pcall(gethui)
        if ok and ui then hosts[#hosts + 1] = ui end
    end
    hosts[#hosts + 1] = game:GetService("CoreGui")
    local player = game:GetService("Players").LocalPlayer
    local playerGui = player and player:FindFirstChildOfClass("PlayerGui")
    if playerGui then hosts[#hosts + 1] = playerGui end

    for _, host in ipairs(hosts) do
        for _, child in ipairs(host:GetChildren()) do
            if child.Name == "RoChess" then
                pcall(function() child:Destroy() end)
            end
        end
    end
end

-- Queued chunk: always load the newest script straight from GitHub raw.
local QUEUED_SOURCE = [[pcall(function() loadstring(game:HttpGet("https://raw.githubusercontent.com/FilipinoCollabEmtech/Jax-Chess-Scripts/843a983/RoChess.lua"))() end)]]

local function queueReload()
    if state.queuedFor == game.PlaceId and not state.queueConsumed then return end
    local queue = typeof(queueonteleport) == "function" and queueonteleport
        or typeof(queue_on_teleport) == "function" and queue_on_teleport
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
        warn("[RoChess] queueonteleport failed: " .. tostring(err))
    end
end

local API_URL = "https://stockfish.online/api/s/v2.php"

local function urlEncode(s)
    return (tostring(s):gsub("[^%w%-_%.~]", function(c)
        return string.format("%%%02X", c:byte())
    end))
end

local function getLiveFen()
    local App = getApp()
    if not App or type(App.session) ~= "table" then
        return nil, "Could not access the chess session"
    end

    local session = App.session
    local engine = session.engine
    if type(engine) ~= "table" or type(engine.getFen) ~= "function" then
        return nil, "Chess engine is unavailable"
    end

    -- After a history rewind, analyse the ply actually on screen, not the live ply.
    if type(session.viewPly) == "number" and type(session.engineAt) == "function"
        and session.viewPly ~= engine.ply then
        local okAt, atEngine = pcall(function() return session:engineAt(session.viewPly) end)
        if okAt and type(atEngine) == "table" and type(atEngine.getFen) == "function" then
            engine = atEngine
        end
    end

    local okFen, fen = pcall(function() return engine:getFen() end)
    if not okFen or type(fen) ~= "string" or fen == "" then
        return nil, "Could not read the board position"
    end
    return fen
end

local function myClockMs()
    local App = getApp()
    local session = App and App.session
    if not session or type(session.clockFor) ~= "function" then return nil end
    local ok, ms = pcall(function() return session:clockFor(session.myColor) end)
    if ok and type(ms) == "number" then return ms end
    return nil
end

local function requestSuggestion(fen)
    -- Always use the selected depth; low-clock fast mode only removes artificial delay.
    local depth = state.depth

    local cacheKey = tostring(depth) .. "|" .. fen
    local cached = state.suggestionCache[cacheKey]
    if cached then return cached, nil, true end

    local url = string.format("%s?fen=%s&depth=%d", API_URL, urlEncode(fen), depth)
    local ok, response = pcall(function()
        return request({ Url = url, Method = "GET" })
    end)
    if not ok then return nil, "HTTP error: " .. tostring(response) end
    if type(response) == "string" then return nil, "HTTP error: " .. response end

    local status, body = response.StatusCode, response.Body
    if type(status) == "number" and (status < 200 or status >= 300) then
        return nil, "HTTP " .. tostring(status) .. ": " .. tostring(body):sub(1, 120)
    end
    if type(body) ~= "string" or body == "" then
        return nil, "Empty API response"
    end

    local okJson, data = pcall(function()
        return game:GetService("HttpService"):JSONDecode(body)
    end)
    if not okJson or type(data) ~= "table" then
        return nil, "Invalid API response: " .. tostring(body):sub(1, 120)
    end
    if data.success ~= true then
        return nil, "API error: " .. tostring(data.data or data.message or "unknown")
    end

    state.suggestionCache[cacheKey] = data
    local count = 0
    for _ in pairs(state.suggestionCache) do count = count + 1 end
    if count > 40 then state.suggestionCache = {} end
    return data, nil, false
end

local function uciToIndex(square)
    if type(square) ~= "string" or #square < 2 then return nil end
    local algebraic = square:sub(1, 2):lower()
    local ok, Engine = pcall(function()
        local rs = game:GetService("ReplicatedStorage")
        return require(rs:FindFirstChild("Chess"):FindFirstChild("Engine"))
    end)
    if ok and type(Engine) == "table" and type(Engine.algToIndex64) == "function" then
        local okIndex, index = pcall(function() return Engine.algToIndex64(algebraic) end)
        if okIndex and type(index) == "number" then return index end
    end
    local file = string.byte(algebraic, 1) - 96
    local rank = tonumber(algebraic:sub(2, 2))
    if not rank or file < 1 or file > 8 or rank < 1 or rank > 8 then return nil end
    return file + (rank - 1) * 8
end

local function squareToScreen(index)
    local App = getApp()
    if App and App.board then
        local ok, col, row = pcall(function() return App.board:colRow(index) end)
        if ok and type(col) == "number" and type(row) == "number" then
            return col, row
        end
    end
    return (index - 1) % 8, (index - 1) // 8
end

local function placeHighlight(name, index, color)
    local containers = getBoardContainers()
    local highlights = containers and containers.highlights
    if not highlights then return end
    local frame = highlights:FindFirstChild(name)
    if not frame then
        frame = Instance.new("Frame")
        frame.Name = name
        frame.Size = UDim2.fromScale(0.125, 0.125)
        frame.BackgroundTransparency = 0.45
        frame.ZIndex = 2
        frame.Parent = highlights
    end
    frame.BackgroundColor3 = color
    local col, row = squareToScreen(index)
    frame.Position = UDim2.fromScale(col / 8, row / 8)
    frame.Visible = true
end

local function drawSuggestionArrow(move, ponder)
    clearVisuals()
    if type(move) ~= "string" or #move < 4 then return false end
    local from = uciToIndex(move:sub(1, 2))
    local to = uciToIndex(move:sub(3, 4))
    if not from or not to or from == to then return false end

    local App = getApp()
    if not App or not App.board then return false end

    local ok = pcall(function()
        App.board:setArrow(ARROW_IDS[1], from, to)
        if type(ponder) == "string" and #ponder >= 4 then
            local pf, pt = uciToIndex(ponder:sub(1, 2)), uciToIndex(ponder:sub(3, 4))
            if pf and pt and pf ~= pt then
                App.board:setArrow(ARROW_IDS[2], pf, pt, Color3.fromRGB(255, 170, 60), 0.18)
            end
        end
    end)
    placeHighlight(HL_FROM, from, Color3.fromRGB(80, 220, 255))
    placeHighlight(HL_TO, to, Color3.fromRGB(120, 255, 160))
    return ok
end

local PROMO_INDEX = { q = 5, r = 4, b = 3, n = 2 }

local function playUci(move)
    if type(move) ~= "string" or #move < 4 then return false, "bad move" end
    local App = getApp()
    if not App then return false, "no chess session" end
    local from, to = uciToIndex(move:sub(1, 2)), uciToIndex(move:sub(3, 4))
    if not from or not to then return false, "bad squares" end
    local promo = PROMO_INDEX[move:sub(5, 5):lower()] or 0
    local ok, result = pcall(function() return App.onBoardMove(from, to, promo, false) end)
    if not ok then return false, tostring(result) end
    return result ~= false, tostring(result)
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
        score = type(data.evaluation) == "number"
            and string.format("%+.2f", data.evaluation)
            or tostring(data.evaluation or "n/a")
    end
    local desc = string.format(
        "Best move: %s%s\nEvaluation: %s\nLine: %s\nFEN: %s",
        move,
        ponder and ("  (ponder: " .. ponder .. ")") or "",
        score,
        tostring(data.continuation or "n/a"),
        fen
    )
    return title, desc, move, ponder
end

local function main()
    cleanup()
    queueReload()

    local WindUI = loadWindUI()
    if not WindUI then
        warn("[RoChess] vendored WindUI failed to load after 3 attempts")
        return
    end
    local Window = WindUI:CreateWindow({
        Title = "RoChess",
        Icon = "castle",
        Author = "OpenCode",
        Folder = "RoChess",
        Size = UDim2.fromOffset(460, 420),
        Theme = "Dark",
        ToggleKey = Enum.KeyCode.RightControl,
        KeySystem = {
            Title = "RoChess Key",
            Note = "Paste a key.",
            SaveKey = true,
            URL = KEY_COPY_URL,
            KeyValidator = WindUI.CreateKeyValidator(KEY_URL),
        },
    })
    if not Window then return end

    local Main = Window:Tab({ Title = "Main", Icon = "home" })
    Main:Section({ Title = "Chess", Opened = true })

    local result = Main:Paragraph({
        Title = "Suggestion",
        Desc = "Press Suggest Move to analyse the current position.",
    })

    local suggestBtn

    local function setResult(title, desc)
        pcall(function()
            result:SetTitle(title)
            result:SetDesc(desc)
        end)
    end

    local function setButtonDesc(text)
        if suggestBtn then
            pcall(function() suggestBtn:SetDesc(text) end)
        end
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

    local function humanDelay()
        if not state.humanTiming then return 0 end
        -- First two moves are instant; afterwards mirror the opponent's pace.
        if state.ourMoveCount < 2 then return 0 end
        local clock = myClockMs()
        if clock and clock < 20000 then return 0 end -- no slow-roll when time is short
        local base = median(state.opponentTimes) or 2.5
        local jitter = 0.85 + (math.random() * 0.30) -- 0.85x .. 1.15x
        local delay = math.clamp(base * 0.7 * jitter, 0.3, 3.5)
        if clock then delay = math.min(delay, math.max(0.3, clock / 15000)) end
        return delay
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

    local function openingMove()
        if not state.autoPlay or state.playBusy then return nil end
        if state.ourMoveCount >= 2 then return nil end
        local App = getApp()
        local session = App and App.session
        if not session or session.kind ~= "bot" and session.kind ~= "online" then return nil end

        local color = tonumber(session.myColor)
        local book = OPENING_BOOK[color]
        if not book then return nil end

        local index = state.ourMoveCount + 1
        local candidates
        if color == 1 then
            candidates = { book[index] }
        elseif index == 1 then
            -- Answer 1.d4 with 1...d5, but only if White actually opened d4.
            if session.ucis and session.ucis[1] ~= "d2d4" then return nil end
            candidates = { book[1] }
        else
            -- After 1.d4 d5 2.c4, take the first legal QGD/Slav/QGA reply.
            if session.ucis and (session.ucis[1] ~= "d2d4" or session.ucis[2] ~= "c2c4") then return nil end
            candidates = { book[2], book[3], book[4] }
        end

        for _, uci in ipairs(candidates) do
            if type(uci) == "string" and #uci >= 4 then
                local from, to = uciToIndex(uci:sub(1, 2)), uciToIndex(uci:sub(3, 4))
                if from and to then
                    local ok, legal = pcall(function() return session:findMove(from, to, 0) end)
                    if ok and legal then return uci end
                end
            end
        end
        return nil
    end

    local function playOpening(uci)
        if state.playBusy then return false end
        state.playBusy = true
        state.lastPlayedFen = getLiveFen() or uci
        setResult("Opening", "Queen's Gambit: " .. uci .. " (instant)")
        drawSuggestionArrow(uci)
        local ok, err = playUci(uci)
        if ok then
            noteOurMove()
        else
            state.lastPlayedFen = nil
            setResult("Opening failed", tostring(err))
        end
        state.playBusy = false
        return ok
    end

    local function playSuggested(move, fen)
        if not state.autoPlay or state.playBusy or not move or move == "?" then return end
        local opening = openingMove()
        if opening then
            playOpening(opening)
            return
        end
        local App = getApp()
        local session = App and App.session
        if not session or session.kind == "idle" then return end
        local okTurn, mine = pcall(function() return session:isMyTurn() end)
        if not okTurn or not mine or fen == state.lastPlayedFen then return end
        state.playBusy = true
        state.lastPlayedFen = fen
        local delay = humanDelay()
        if delay > 0 then
            setResult("Auto play", string.format("Human timing: waiting %.1fs", delay))
            task.wait(delay)
        end
        local ok, err = playUci(move)
        if not ok then
            state.lastPlayedFen = nil
            setResult("Auto play failed", tostring(err))
        else
            noteOurMove()
        end
        state.playBusy = false
    end

    local function analyseFen(fen)
        local t0 = os.clock()
        local data, apiErr, cached = requestSuggestion(fen)
        state.lastLatency = os.clock() - t0
        if not data then
            setResult("Analysis failed", apiErr .. "\nFEN: " .. fen)
            return false
        end
        local title, desc, move, ponder = formatSuggestion(data, fen)
        desc = desc .. string.format("\nEngine: %.2fs%s", state.lastLatency, cached and " (cached)" or "")
        if state.turbo then desc = desc .. "\nTURBO: no delay" end
        setResult(title, desc)
        drawSuggestionArrow(move, ponder)
        playSuggested(move, fen)
        return true
    end

    suggestBtn = Main:Button({
        Title = "Suggest Move",
        Desc = "Analyse the board at depth " .. state.depth,
        Callback = function()
            if state.suggesting then return end
            state.suggesting = true
            setButtonDesc("Reading board...")
            setResult("Suggestion", "Reading the live position...")
            pcall(function()
                WindUI:Notify({ Title = "RoChess", Content = "Analysing the position...", Duration = 2 })
            end)
            local fen, fenErr = getLiveFen()
            if not fen then
                setResult("No position", fenErr)
            else
                setButtonDesc("Asking engine...")
                analyseFen(fen)
            end
            state.suggesting = false
            setButtonDesc("Analyse the board at depth " .. state.depth)
        end,
    })

    Main:Dropdown({
        Title = "Engine Depth",
        Desc = "Stockfish search depth (max 15)",
        Values = { "8", "10", "12", "14", "15" },
        Value = tostring(state.depth),
        Callback = function(value)
            state.depth = tonumber(value) or 12
            setButtonDesc("Analyse the board at depth " .. state.depth)
            saveSettings()
        end,
    })

    local function autoStep()
        local App = getApp()
        local session = App and App.session
        if type(session) ~= "table" then return end

        local fen = getLiveFen()
        if not fen then return end

        -- Auto-clear on move: drop stale arrows/highlights as soon as the board changes.
        if fen ~= state.lastSeenFen then
            state.lastSeenFen = fen
            clearVisuals()
        end

        if session.kind == "idle" or session.over then return end
        local okTurn, mine = pcall(function() return session:isMyTurn() end)
        if not okTurn or not mine then return end
        if fen == state.lastAutoFen then return end
        if state.suggesting or state.autoBusy then return end

        state.autoBusy = true
        state.lastAutoFen = fen
        setResult("Auto", "Engine thinking...\nFEN: " .. fen)
        local ok = analyseFen(fen)
        state.autoBusy = false
        if not ok then state.lastAutoFen = nil end
    end

    local function startAutoLoop(token)
        task.spawn(function()
            while state.autoToken == token and state.autoEnabled do
                task.wait(0.5)
                if state.autoToken ~= token then return end
                pcall(autoStep)
            end
        end)
    end

    local autoSuggestToggle
    autoSuggestToggle = Main:Toggle({
        Title = "Auto Suggest",
        Desc = "Analyse automatically on your turn",
        Value = state.autoSuggest,
        Callback = function(on)
            state.autoSuggest = on
            saveSettings()
            state.autoEnabled = on
            state.autoToken = (state.autoToken or 0) + 1
            if on then
                state.lastAutoFen = nil
                state.lastSeenFen = nil
                state.autoBusy = false
                setResult("Auto", "Waiting for your turn...")
                startAutoLoop(state.autoToken)
            else
                clearVisuals()
                setResult("Suggestion", "Auto suggest off.")
            end
        end,
    })
    if state.autoSuggest then
        pcall(function() autoSuggestToggle.Callback(true) end)
    end

    local function playStep()
        local App = getApp()
        local session = App and App.session
        if not session or session.kind == "idle" then return end

        local clockNow = myClockMs()
        state.turbo = clockNow ~= nil and clockNow > 0 and clockNow < 20000

        if session.over then
            local key = tostring(session.id or "") .. ":" .. tostring(#(session.ucis or {}))
            if key ~= state.replayKey then
                state.replayKey = key
                if inTournamentGame() then
                    -- The bracket owns the next round; queueing a normal game here
                    -- would pull the player out of the tournament.
                    setResult("Tournament", "Bracket handles the next round - auto replay skipped")
                else
                    local mode = modeForKind(session.kind)
                    if mode and modeAllowsReplay(mode) then
                        setResult("Auto replay", "Starting another " .. mode .. " game...")
                        startSameMode(session.kind)
                    end
                end
            end
            return
        end
        state.replayKey = nil

        if not modeAllowsPlay(session.kind) then return end

        local currentFen = getLiveFen()
        if currentFen and state.lastObservedFen and currentFen ~= state.lastObservedFen then
            local okTurnNow, mineNow = pcall(function() return session:isMyTurn() end)
            if okTurnNow and mineNow then noteOpponentMove() end
        end
        state.lastObservedFen = currentFen

        if not state.autoPlay or state.playBusy then return end
        local okTurn, mine = pcall(function() return session:isMyTurn() end)
        if not okTurn or not mine then return end
        local fen = currentFen
        if not fen or fen == state.lastPlayedFen then return end

        local opening = openingMove()
        if opening then
            playOpening(opening)
            return
        end

        state.playBusy = true
        state.lastPlayedFen = fen
        setResult("Auto play", "Engine thinking...")
        local t0 = os.clock()
        local data, apiErr, cached = requestSuggestion(fen)
        state.lastLatency = os.clock() - t0
        if not data then
            state.lastPlayedFen = nil
            setResult("Auto play failed", tostring(apiErr))
        else
            local title, desc, suggested = formatSuggestion(data, fen)
            desc = desc .. string.format("\nEngine: %.2fs%s", state.lastLatency, cached and " (cached)" or "")
            if state.turbo then desc = desc .. "\nTURBO: no delay" end
            setResult(title, desc)
            drawSuggestionArrow(suggested)
            local delay = humanDelay()
            if delay > 0 then
                setResult("Auto play", string.format("Human timing: waiting %.1fs", delay))
                task.wait(delay)
            end
            local ok, err = playUci(suggested)
            if not ok then
                state.lastPlayedFen = nil
                setResult("Auto play failed", tostring(err))
            else
                noteOurMove()
            end
        end
        state.playBusy = false
    end

    local function pressNextPuzzleButton()
        local ok, face = pcall(function()
            local pg = game:GetService("Players").LocalPlayer:FindFirstChildOfClass("PlayerGui")
            local ui = pg and pg:FindFirstChild("ChessUI")
            local root = ui and ui:FindFirstChild("Root")
            local side = root and root:FindFirstChild("Side")
            local panel = side and side:FindFirstChild("Panel")
            local body = panel and panel:FindFirstChild("Body")
            local puzzles = body and body:FindFirstChild("puzzles")
            local scroll = puzzles and puzzles:FindFirstChild("ScrollingFrame")
            local buttons = scroll and scroll:FindFirstChild("Buttons")
            if not buttons then return nil end

            -- Only act when the given parent frame is visible.
            local parent = buttons:GetChildren()[5]
            if not parent or parent.Visible ~= true then return nil end
            return parent:FindFirstChild("Face")
        end)
        if not ok or not face then return false end
        if typeof(firesignal) ~= "function" then return false end

        -- Method 5 only: fire every GUI signal the button listens to.
        local performed = false
        performed = pcall(function() firesignal(face.Activated) end) or performed
        performed = pcall(function() firesignal(face.MouseButton1Down) end) or performed
        performed = pcall(function() firesignal(face.MouseButton1Up) end) or performed
        return performed
    end

    local function autoNextStep()
        local App = getApp()
        local session = App and App.session
        if not session or session.kind ~= "puzzle" then return end
        local pz = session.pz
        if type(pz) ~= "table" then return end
        if not pz.done and not session.over then
            state.puzzleNextKey = nil
            return
        end
        if os.clock() - (state.puzzleNextLast or 0) < 2 then return end
        local key = tostring(pz.data and pz.data.id or "") .. ":" .. tostring(pz.step or 0)
        if key == state.puzzleNextKey then return end
        state.puzzleNextKey = key
        state.puzzleNextLast = os.clock()
        setResult("Puzzle", "Pressing Next...")
        pressNextPuzzleButton()
    end

    local function startAutoNextLoop(token)
        task.spawn(function()
            while state.puzzleNextToken == token and state.puzzleAutoNext do
                task.wait(0.5)
                if state.puzzleNextToken ~= token then return end
                pcall(autoNextStep)
            end
        end)
    end

    local function startPlayLoop(token)
        task.spawn(function()
            while state.playToken == token and (state.autoPlay
                or state.modeAutoReplay.Bot or state.modeAutoReplay.Online
                or state.modeAutoReplay.All) do
                task.wait(state.turbo and 0 or 0.25)
                if state.playToken ~= token then return end
                pcall(playStep)
            end
        end)
    end

    local function updatePlayLoop()
        state.playToken = (state.playToken or 0) + 1
        state.lastObservedFen = nil
        state.awaitingOpponent = false
        if state.autoPlay or state.modeAutoReplay.Bot
            or state.modeAutoReplay.Online or state.modeAutoReplay.All then
            state.lastPlayedFen = nil
            startPlayLoop(state.playToken)
        else
            clearVisuals()
        end
    end

    Main:Section({ Title = "Auto Play Settings", Opened = false })

    Main:Toggle({
        Title = "Human Timing",
        Desc = "",
        Value = state.humanTiming,
        Callback = function(on)
            state.humanTiming = on
            saveSettings()
            if on then
                state.ourMoveCount = 0
                state.awaitingOpponent = false
            end
        end,
    })

    local autoPlayToggle
    autoPlayToggle = Main:Toggle({
        Title = "Auto Play",
        Desc = "Play the suggested move on your turn",
        Value = state.autoPlay,
        Callback = function(on)
            state.autoPlay = on
            saveSettings()
            if on then
                state.ourMoveCount = 0
                state.lastOurMoveAt = 0
                state.awaitingOpponent = false
            end
            updatePlayLoop()
        end,
    })
    if state.autoPlay then
        pcall(function() autoPlayToggle.Callback(true) end)
    end

    Main:Button({
        Title = "Clear Arrow",
        Desc = "Remove arrows and highlights from the board",
        Callback = function()
            clearVisuals()
            pcall(function()
                WindUI:Notify({ Title = "RoChess", Content = "Board markings cleared", Duration = 2 })
            end)
        end,
    })

    local Play = Window:Tab({ Title = "Play", Icon = "gamepad" })
    local Config = getConfig()

    local botEntries = {}
    if Config and type(Config.BOT_BY_ID) == "table" then
        for id, bot in pairs(Config.BOT_BY_ID) do
            botEntries[#botEntries + 1] = {
                id = tostring(id),
                label = tostring(bot.name or id) .. " (" .. tostring(bot.rating or 0) .. ")",
            }
        end
        table.sort(botEntries, function(a, b) return a.label < b.label end)
    end
    local botLabels = {}
    local defaultBotLabel = botEntries[1] and botEntries[1].label or state.botId
    for _, entry in ipairs(botEntries) do
        botLabels[#botLabels + 1] = entry.label
        if entry.id == state.botId then defaultBotLabel = entry.label end
    end
    local function botIdFromLabel(label)
        for _, entry in ipairs(botEntries) do
            if entry.label == label then return entry.id end
        end
        return state.botId
    end

    local tcValues = {}
    if Config and type(Config.TC_BY_ID) == "table" then
        for id in pairs(Config.TC_BY_ID) do tcValues[#tcValues + 1] = tostring(id) end
    end
    table.sort(tcValues)

    local function appCall(name, ...)
        local App = getApp()
        if not App or type(App[name]) ~= "function" then
            return false, "App." .. name .. " unavailable"
        end
        local args = { ... }
        return pcall(function() return App[name](App, table.unpack(args)) end)
    end

    Play:Section({ Title = "Bot Game", Opened = true })

    Play:Dropdown({
        Title = "Bot",
        Desc = "Opponent rating shown in parentheses",
        Values = #botLabels > 0 and botLabels or { state.botId },
        Value = defaultBotLabel,
        Callback = function(value)
            state.botId = botIdFromLabel(value)
            saveSettings()
        end,
    })

    Play:Dropdown({
        Title = "Your Color",
        Values = { "Random", "White", "Black" },
        Value = state.botColor,
        Callback = function(value)
            state.botColor = value
            saveSettings()
        end,
    })

    Play:Button({
        Title = "Start Bot Game",
        Desc = "Start a bot game with the chosen opponent and color",
        Callback = function()
            local color = state.botColor == "Random" and nil or state.botColor:lower()
            local ok, err = appCall("startBotGame", state.botId, color)
            pcall(function()
                WindUI:Notify({
                    Title = "RoChess",
                    Content = ok and "Bot game started" or ("Failed: " .. tostring(err)),
                    Duration = 3,
                })
            end)
        end,
    })

    Play:Section({ Title = "Online" })

    Play:Dropdown({
        Title = "Time Control",
        Values = #tcValues > 0 and tcValues or { state.tc },
        Value = state.tc,
        Callback = function(value)
            state.tc = value
            saveSettings()
        end,
    })

    Play:Button({
        Title = "Join Queue",
        Desc = "Queue for a rated online game",
        Callback = function()
            local ok, err = appCall("startSearch", state.tc)
            pcall(function()
                WindUI:Notify({
                    Title = "RoChess",
                    Content = ok and "Searching..." or ("Failed: " .. tostring(err)),
                    Duration = 3,
                })
            end)
        end,
    })

    Play:Button({
        Title = "Cancel Queue",
        Desc = "Leave the matchmaking queue",
        Callback = function()
            local ok = appCall("cancelSearch")
            pcall(function()
                WindUI:Notify({ Title = "RoChess", Content = ok and "Queue cancelled" or "Failed", Duration = 2 })
            end)
        end,
    })

    Play:Section({ Title = "Automation by Mode", Opened = true })

    Play:Dropdown({
        Title = "Mode",
        Desc = "Which game mode the toggles below apply to",
        Values = { "Bot", "Online", "All" },
        Value = state.playMode,
        Callback = function(value)
            state.playMode = value
            saveSettings()
        end,
    })

    Play:Toggle({
        Title = "Auto Play in Mode",
        Desc = "Allow auto play for the selected mode",
        Value = state.modeAutoPlay[state.playMode] ~= false,
        Callback = function(on)
            state.modeAutoPlay[state.playMode] = on
            if state.playMode == "All" then
                state.modeAutoPlay.Bot = on
                state.modeAutoPlay.Online = on
            end
            saveSettings()
            updatePlayLoop()
        end,
    })

    Play:Toggle({
        Title = "Auto Replay in Mode",
        Desc = "Queue a fresh game of this mode when one finishes",
        Value = state.modeAutoReplay[state.playMode] == true,
        Callback = function(on)
            state.modeAutoReplay[state.playMode] = on
            if state.playMode == "All" then
                state.modeAutoReplay.Bot = on
                state.modeAutoReplay.Online = on
            end
            saveSettings()
            updatePlayLoop()
        end,
    })

    Play:Section({ Title = "Puzzle", Opened = false })

    local autoNextToggle
    autoNextToggle = Play:Toggle({
        Title = "Auto Next",
        Desc = "Press the game's Next button when a puzzle is solved",
        Value = state.puzzleAutoNext,
        Callback = function(on)
            state.puzzleAutoNext = on
            saveSettings()
            state.puzzleNextToken = (state.puzzleNextToken or 0) + 1
            if on then
                state.puzzleNextKey = nil
                state.puzzleNextLast = 0
                setResult("Puzzle", "Auto Next armed")
                startAutoNextLoop(state.puzzleNextToken)
            else
                setResult("Suggestion", "Auto Next off")
            end
        end,
    })


    if state.puzzleAutoNext then
        pcall(function() autoNextToggle.Callback(true) end)
    end
end

main()
