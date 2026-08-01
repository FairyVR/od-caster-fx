-- Recorder: time-series capture of real game data to a file outside the game.
--
-- diagnostics.luau answers "what does the world look like RIGHT NOW". This answers "what
-- happened over the last minute" -- ball trajectories, rotations, events, value ranges.
-- Nobody developing this package can see a frame or attach a debugger, so recorded motion
-- is the only way to check an assumption about the game's data against reality.
--
-- Writes gamedata-log.json into the package folder, which is readable from outside the game.
--
-- There is no append in the file API (saveText overwrites), so samples are buffered in
-- memory and the whole file is rewritten on each flush. That makes the sample cap load-
-- bearing rather than cosmetic: every flush costs O(samples), so an uncapped buffer would
-- degrade the frame it is trying to measure. Default is a rolling one-minute window.

local Util = require("util")
local Sideline = require("sideline")

local Recorder = {}

local OUTPUT = "gamedata-log.json"

Recorder.status = "idle"
Recorder.lastWriteAt = -1
Recorder.flushCount = 0
Recorder.droppedEvents = 0

-- Circular sample buffer. `written` counts every sample ever taken, so it doubles as the
-- write cursor and as the "how much did we drop" figure.
local samples = {}
local written = 0
local events = {}
local sampleTimer = 0
local flushTimer = 0
local elapsed = 0
local startedAt = 0

-- Running aggregates. These are the numbers most worth having: they say what the real value
-- ranges are, which is what guesses about thresholds and scales get wrong.
local agg = nil

local function resetAgg()
    agg = {
        samples = 0,
        ballPresent = 0,
        ballMissing = 0,
        ballSpeedMin = math.huge, ballSpeedMax = 0, ballSpeedSum = 0,
        ballDistMin = math.huge, ballDistMax = 0,
        ballSpinMax = 0,
        playersMax = 0,
    }
end
resetAgg()

local function vec(v)
    if v == nil then return nil end
    return { x = v.x, y = v.y, z = v.z }
end

-- Both forms on purpose: euler is readable, raw xyzw is unambiguous. Euler wraps and can
-- gimbal, so a question like "is the ball actually spinning" needs the raw quat to settle.
local function rot(q)
    if q == nil then return nil end
    local e = q:euler()
    return {
        roll = e.x, pitch = e.y, yaw = e.z,
        x = q.x, y = q.y, z = q.z, w = q.w,
    }
end

--------------------------------------------------------------------------------
-- Buffer
--------------------------------------------------------------------------------

local function cap()
    return math.max(10, math.floor(config.logMaxSamples or 600))
end

-- Slot assignment is modulo the cap, so changing the cap mid-recording would scatter the
-- existing samples and read them back out of order. Re-linearise instead, keeping the most
-- recent ones -- silently corrupting a recording because a slider moved is not acceptable.
local lastCap = nil

local function reindexIfCapChanged()
    local c = cap()
    if lastCap == c then return end
    if lastCap ~= nil and written > 0 then
        local old = {}
        local n = math.min(written, lastCap)
        local startAt = written > lastCap and (written % lastCap) or 0
        for i = 1, n do
            old[i] = samples[(startAt + i - 1) % lastCap + 1]
        end
        -- Keep the newest c of them, oldest-first, in plain 1..k order.
        local keep = math.min(n, c)
        samples = {}
        for i = 1, keep do
            samples[i] = old[n - keep + i]
        end
        written = keep
    end
    lastCap = c
end

local function push(sample)
    reindexIfCapChanged()
    local c = cap()
    if config.logRolling then
        written += 1
        samples[(written - 1) % c + 1] = sample
    else
        if written >= c then
            Recorder.status = "buffer full (rolling off)"
            return false
        end
        written += 1
        samples[written] = sample
    end
    return true
end

-- Oldest-first, accounting for wrap. Reindexes first so a flush that lands between a cap
-- change and the next sample still reads the buffer with the layout it was written in.
local function orderedSamples()
    reindexIfCapChanged()
    local c = cap()
    local n = math.min(written, c)
    local out = {}
    local startAt = written > c and (written % c) or 0
    for i = 1, n do
        out[i] = samples[(startAt + i - 1) % c + 1]
    end
    return out
end

function Recorder.sampleCount()
    return math.min(written, cap())
end

function Recorder.totalWritten() return written end
function Recorder.eventCount() return #events end
function Recorder.isRecording() return config.logEnabled == true end

--------------------------------------------------------------------------------
-- Sampling
--------------------------------------------------------------------------------

local function sampleBall(ball, match, out)
    if ball == nil then
        agg.ballMissing += 1
        return
    end
    agg.ballPresent += 1

    local speed = (ball.velocity or Vec3.zeroVector):length()
    local dist = Util.dist(match.transform.position, ball.transform.position)
    agg.ballSpeedMin = math.min(agg.ballSpeedMin, speed)
    agg.ballSpeedMax = math.max(agg.ballSpeedMax, speed)
    agg.ballSpeedSum += speed
    agg.ballDistMin = math.min(agg.ballDistMin, dist)
    agg.ballDistMax = math.max(agg.ballDistMax, dist)

    out.ball = {
        index = ball.index,
        type = ball.type,
        size = ball.size,
        arena = ball.arena,
        position = vec(ball.transform.position),
        rotation = rot(ball.transform.rotation),
        velocity = vec(ball.velocity),
        speed = speed,
        distanceToArenaCentre = dist,
        isArenaBall = Util.isArenaBall(ball),
    }
end

local function sampleAllBalls(frame, out)
    if frame == nil then return end
    local list = {}
    for _, b in frame.balls do
        table.insert(list, {
            index = b.index,
            type = b.type,
            size = b.size,
            arena = b.arena,
            position = vec(b.transform.position),
            rotation = rot(b.transform.rotation),
            speed = (b.velocity or Vec3.zeroVector):length(),
            isArenaBall = Util.isArenaBall(b),
        })
    end
    out.allBalls = list
end

local function samplePlayers(frame, out)
    if frame == nil then return end
    local list = {}
    for _, p in frame.players do
        table.insert(list, {
            playerId = p.playerId,
            name = p.playerName,
            teamIndex = p.teamIndex,
            head = vec(p.head.position),
            root = vec(p.root.position),
        })
    end
    agg.playersMax = math.max(agg.playersMax, #list)
    out.players = list
end

local function takeSample(match)
    local frame = getGameData()
    local out = {
        t = elapsed,
        worldTime = frame and frame.worldTime or nil,
        interpolated = frame and frame.interpolated or nil,
    }

    if config.logBall then
        sampleBall(match.ball, match, out)
        if config.logAllBalls then sampleAllBalls(frame, out) end
    end

    if config.logTeams then
        out.teams = {
            homeName = match.home.name, homeScore = match.home.score,
            awayName = match.away.name, awayScore = match.away.score,
            isRunning = match.isRunning,
            timeSeconds = match.timeSeconds,
        }
    end

    if config.logCamera then
        out.camera = {
            position = vec(camera.position),
            rotation = rot(camera.rotation),
            fov = camera.fieldOfView,
            isActive = camera.isActive,
        }
    end

    if config.logArena then
        out.arena = {
            position = vec(match.transform.position),
            rotation = rot(match.transform.rotation),
        }
    end

    -- The auto-zoom was measured hitting its fovMax rail 12% of the time. Recording what the
    -- framing maths actually asked for is the only way to tell whether that is the subject
    -- size ballooning or simply the ball flying close to the camera.
    if config.logFraming then
        out.framing = {
            fov = Sideline.debug.fov,
            subject = Sideline.debug.subject,
            side = Sideline.debug.side,
            blend = Sideline.debug.blend,
            groundLift = Sideline.debug.groundLift,
            hasBall = Sideline.debug.hasBall,
            isDriving = Sideline.isDriving(),
        }
    end

    if config.logPlayers then samplePlayers(frame, out) end

    agg.samples += 1
    return out
end

-- Discrete events are kept in their own list, never in the ring buffer -- a goal is exactly
-- the thing you go looking for, and it must not be aged out by ordinary motion samples.
function Recorder.note(kind, detail)
    if not config.logEnabled then return end
    if #events >= 200 then
        Recorder.droppedEvents += 1
        return
    end
    table.insert(events, { t = elapsed, kind = kind, detail = detail })
end

--------------------------------------------------------------------------------
-- Flush
--------------------------------------------------------------------------------

function Recorder.flush()
    local list = orderedSamples()
    local report = {
        note = "Written by fairy.casterfx Recorder. Times are seconds since recording started."
            .. " Distances are centimetres, speeds cm/s, angles degrees.",
        version = "1.0.0",
        recordedAt = startedAt,
        durationSeconds = elapsed,
        sampleHz = config.logHz,
        samplesHeld = #list,
        samplesTaken = written,
        rolling = config.logRolling == true,
        droppedOldest = math.max(0, written - #list),
        channels = {
            ball = config.logBall == true,
            allBalls = config.logAllBalls == true,
            teams = config.logTeams == true,
            camera = config.logCamera == true,
            arena = config.logArena == true,
            players = config.logPlayers == true,
            framing = config.logFraming == true,
        },
        summary = {
            samples = agg.samples,
            ballPresent = agg.ballPresent,
            ballMissing = agg.ballMissing,
            ballSpeedMin = agg.ballSpeedMin < math.huge and agg.ballSpeedMin or 0,
            ballSpeedMax = agg.ballSpeedMax,
            ballSpeedAvg = agg.ballPresent > 0 and (agg.ballSpeedSum / agg.ballPresent) or 0,
            ballDistMin = agg.ballDistMin < math.huge and agg.ballDistMin or 0,
            ballDistMax = agg.ballDistMax,
            -- Only meaningful when the channel was on; a flat 0 otherwise reads as a bug.
            playersMax = config.logPlayers and agg.playersMax or nil,
        },
        events = events,
        samples = list,
    }

    -- Pretty on purpose: the file is read from outside in line ranges, and one enormous
    -- single line is far worse to work with than many short ones.
    local text = LuauJson.serialize(report, true)
    if text == "" then
        issue("casterfx recorder: serialize failed (a value was not table/number/string/bool)")
        Recorder.status = "serialize FAILED"
        return false
    end
    if not LuauFile.saveText(OUTPUT, text) then
        issue("casterfx recorder: could not write " .. OUTPUT)
        Recorder.status = "write FAILED"
        return false
    end
    Recorder.flushCount += 1
    Recorder.lastWriteAt = elapsed
    Recorder.status = ("wrote %d samples, %d events"):format(#list, #events)
    return true
end

function Recorder.clear()
    samples = {}
    written = 0
    events = {}
    elapsed = 0
    sampleTimer = 0
    flushTimer = 0
    Recorder.droppedEvents = 0
    Recorder.flushCount = 0
    Recorder.lastWriteAt = -1
    resetAgg()
    Recorder.status = "cleared"
end

function Recorder.start()
    Recorder.clear()
    startedAt = os.clock()
    config.logEnabled = true
    Recorder.status = "recording"
end

function Recorder.stop()
    config.logEnabled = false
    Recorder.flush()
    Recorder.status = "stopped -- " .. Recorder.status
end

--------------------------------------------------------------------------------
-- Tick
--------------------------------------------------------------------------------

-- The clock is advanced separately, at the very TOP of the frame, because Recorder.note is
-- called by effects that run before Recorder.tick. Advancing it here would stamp every event
-- with the previous frame's time, which shrinks short intervals by a whole frame and made a
-- correctly debounced pair of impacts look 0.069s apart when they were really 0.15s+.
-- It also keeps running when no arena is selected, so `t` stays honest wall-clock.
function Recorder.advance(dt)
    if not config.logEnabled then return end
    elapsed += dt
end

function Recorder.tick(dt, match)
    if not config.logEnabled or match == nil then return end

    sampleTimer += dt
    flushTimer += dt

    local interval = 1 / math.clamp(config.logHz or 10, 0.5, 60)
    if sampleTimer >= interval then
        -- Subtract rather than zero. Zeroing threw away the overshoot every time, which cost
        -- a whole frame per sample and ran the recorder at 7.9Hz when it was asked for 10.
        sampleTimer -= interval
        -- After a real stall, don't let a backlog build: game state only changes per frame,
        -- so the queued samples would be duplicates anyway.
        if sampleTimer > interval then sampleTimer = 0 end
        push(takeSample(match))
    end

    -- Flushing is the expensive half (serialize + disk), so it runs far slower than sampling.
    if flushTimer >= math.max(1, config.logFlushSeconds or 3) then
        flushTimer = 0
        Recorder.flush()
    end
end

--------------------------------------------------------------------------------
-- GUI
--------------------------------------------------------------------------------

function Recorder.gui(match)
    Gui.text("Records live game data to " .. OUTPUT .. " in the package folder, which can be")
    Gui.text("read from outside the game. Use it to check assumptions against real data")
    Gui.text("instead of guessing: ball spin, real speed ranges, event timing.")

    if config.logEnabled then
        if Gui.button(Icon.Stop .. " Stop and write") then Recorder.stop() end
        Gui.sameLine()
        Gui.textColored(LinearColor.new(1, 0.5, 0.5, 1),
            ("REC  %.0fs"):format(elapsed))
    else
        if Gui.button(Icon.Circle .. " Start recording") then Recorder.start() end
    end
    Gui.sameLine()
    if Gui.button(Icon.Save .. " Write now") then Recorder.flush() end
    Gui.sameLine()
    if Gui.button(Icon.Trash .. " Clear") then Recorder.clear() end

    if match == nil then
        Gui.textColored(LinearColor.new(1, 0.6, 0.3, 1),
            "No arena selected -- nothing will be sampled.")
    end

    Gui.text(("Held: %d / %d samples   events: %d   flushes: %d")
        :format(Recorder.sampleCount(), cap(), #events, Recorder.flushCount))
    if written > Recorder.sampleCount() then
        Gui.text(("Aged out %d older samples (rolling window)")
            :format(written - Recorder.sampleCount()))
    end
    if Recorder.droppedEvents > 0 then
        Gui.textColored(LinearColor.new(1, 0.6, 0.3, 1),
            Recorder.droppedEvents .. " events dropped (200 cap)")
    end
    Gui.text("Status: " .. Recorder.status)

    Gui.separatorText("Capture settings")
    config.logHz = Gui.sliderFloat("Samples per second", config.logHz, 1, 30)
    config.logMaxSamples = Gui.sliderInt("Sample cap",
        math.floor(config.logMaxSamples), 50, 5000)
    Gui.setItemTooltip("Every write re-serialises the whole buffer, so this bounds both file "
        .. "size and per-write cost. 600 at 10/s is a rolling minute.")
    config.logRolling = Gui.checkbox("Keep the most recent (off = stop when full)",
        config.logRolling)
    config.logFlushSeconds = Gui.sliderFloat("Write to disk every (s)",
        config.logFlushSeconds, 1, 30)

    Gui.separatorText("What to record")
    config.logBall = Gui.checkbox("Ball (position, rotation, velocity)", config.logBall)
    config.logAllBalls = Gui.checkbox("Every ball in frame, not just this arena's",
        config.logAllBalls)
    config.logTeams = Gui.checkbox("Teams and score", config.logTeams)
    config.logCamera = Gui.checkbox("Camera", config.logCamera)
    config.logArena = Gui.checkbox("Arena transform", config.logArena)
    config.logFraming = Gui.checkbox("Sideline framing (fov, subject size)", config.logFraming)
    config.logPlayers = Gui.checkbox("Players (verbose)", config.logPlayers)
    Gui.setItemTooltip("One entry per player per sample -- fills the buffer fast.")
end

return Recorder
