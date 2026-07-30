-- Diagnostics: in-game tests against real game data.
--
-- The point of this module is to close the feedback loop. Nobody developing this can see a
-- rendered frame, so instead of guessing, run this from the Debug tab and it writes
-- diagnostics.json into the package folder -- which IS readable from outside the game.
--
-- It answers the questions that cannot be answered by reading code:
--   * does WorldDraw.spawnMesh() actually return a mesh here?
--   * does spawnPointLight?
--   * what does this arena's transform, ball, and team data really look like?
--   * are the goal positions where we think they are?
--   * what FOV does the auto-zoom actually ask for at the current distance?

local Util = require("util")
local Particles = require("particles")
local Sideline = require("sideline")
local Profiles = require("profiles")
local Freecam = require("freecam")

local Diagnostics = {}

Diagnostics.lastSummary = ""
Diagnostics.lastPassed = 0
Diagnostics.lastFailed = 0

local function vec(v)
    if v == nil then return nil end
    return { x = v.x, y = v.y, z = v.z }
end

local function quat(q)
    if q == nil then return nil end
    local e = q:euler()
    return { roll = e.x, pitch = e.y, yaw = e.z }
end

-- Every check appends a record rather than asserting, so one failure never hides the rest.
local function runner()
    local r = { checks = {}, passed = 0, failed = 0 }
    function r.check(name, ok, detail)
        table.insert(r.checks, { name = name, ok = ok and true or false, detail = tostring(detail) })
        if ok then r.passed += 1 else r.failed += 1 end
        return ok
    end
    return r
end

--------------------------------------------------------------------------------
-- Capability probes -- can the engine do the things this package depends on?
--------------------------------------------------------------------------------

-- Particles no longer use meshes, but the logo quads still do, so this probe still matters.
local function probeMesh(r)
    local mesh = WorldDraw.spawnMesh()
    if not r.check("WorldDraw.spawnMesh returns a mesh (logos need it)", mesh ~= nil, tostring(mesh)) then
        return nil
    end
    -- Minimal visible-size triangle in front of the camera, drawn AFTER the transform is set.
    mesh.vertices = { Vec3.new(0, -50, -50), Vec3.new(0, 50, -50), Vec3.new(0, 0, 50) }
    mesh.triangles = { 0, 2, 1, 0, 1, 2 }
    mesh.normals = { Vec3.new(-1, 0, 0), Vec3.new(-1, 0, 0), Vec3.new(-1, 0, 0) }
    mesh.uVs = { Vec2.new(0, 1), Vec2.new(1, 1), Vec2.new(0.5, 0) }
    mesh.color = LinearColor.new(1, 0, 1, 1)
    mesh.position = camera.position + camera.rotation:getForwardVector() * 400
    mesh.rotation = camera.rotation
    mesh.scale = Vec3.oneVector
    local ok = pcall(function() mesh:draw() end)
    r.check("mesh:draw() succeeds", ok, "magenta triangle 4m in front of camera")
    mesh:destroy()
    r.check("mesh:destroy() succeeds", true, "destroyed")
    return true
end

local function probeLight(r)
    local light = WorldDraw.spawnPointLight(camera.position, 5000, Vec3.new(1, 1, 1), 500)
    if not r.check("WorldDraw.spawnPointLight returns a light", light ~= nil, tostring(light)) then
        return
    end
    local ok = pcall(function() light.intensity = 1 end)
    r.check("point light intensity is writable", ok,
        "if this fails, decaying flashes cannot dim and would stay lit")
    light:destroy()
end

-- Pure maths, no game state needed. Verifies the yaw/pitch convention actually round-trips
-- against the engine's own Quat, which is what the freecam's orientation depends on. The
-- upside-down entry bug came from getting exactly this wrong.
local function probeAngles(r)
    local worst, worstCase = 0, ""
    for _, pair in { { 0, 0 }, { 45, 20 }, { -120, -35 }, { 179, 60 }, { -90, -80 } } do
        local yaw, pitch = pair[1], pair[2]
        local forward = Quat.fromEuler(0, pitch, yaw):getForwardVector()
        local gotYaw, gotPitch = Freecam.anglesFromForward(forward)
        -- Yaw wraps at +/-180, so compare the shortest angular distance.
        local dYaw = math.abs((gotYaw - yaw + 180) % 360 - 180)
        local dPitch = math.abs(gotPitch - pitch)
        local err = math.max(dYaw, dPitch)
        if err > worst then
            worst = err
            worstCase = ("yaw %d pitch %d -> yaw %.1f pitch %.1f"):format(yaw, pitch, gotYaw, gotPitch)
        end
    end
    r.check("freecam yaw/pitch round-trips through the engine Quat", worst < 1,
        ("worst error %.2f deg (%s)"):format(worst, worstCase))
    return { worstAngleError = worst, worstCase = worstCase }
end

local function probeFiles(r)
    local files = LuauFile.listFiles("")
    r.check("LuauFile.listFiles works", files ~= nil and #files > 0,
        files and (#files .. " files in package") or "nil")
    local logos = LuauFile.listFiles("logos")
    r.check("logos/ folder readable", logos ~= nil, logos and (#logos .. " entries") or "nil")
    local sprites = LuauFile.listFiles("sprites")
    r.check("sprites/ folder readable", sprites ~= nil, sprites and (#sprites .. " entries") or "nil")
    local tex = LuauFile.loadTexture("sprites/flare.png")
    r.check("sprites/flare.png decodes", tex ~= nil, tostring(tex))
end

--------------------------------------------------------------------------------
-- Live data
--------------------------------------------------------------------------------

local function snapshotMatch(r, match)
    if not r.check("an arena is selected", match ~= nil, "nil means no gamemode matched") then
        return nil
    end

    local snap = {
        slotId = match.slotId,
        type = match.type,
        arenaHeight = match.arenaHeight,
        isRunning = match.isRunning,
        transformPosition = vec(match.transform.position),
        transformRotation = quat(match.transform.rotation),
        home = {
            name = match.home.name,
            score = match.home.score,
            roundsWon = match.home.roundsWon,
            logoIndex = match.home.logoIndex,
            color = { r = match.home.color.R, g = match.home.color.G, b = match.home.color.B },
            goalPosition = vec(match.home.goalPosition),
        },
        away = {
            name = match.away.name,
            score = match.away.score,
            roundsWon = match.away.roundsWon,
            logoIndex = match.away.logoIndex,
            color = { r = match.away.color.R, g = match.away.color.G, b = match.away.color.B },
            goalPosition = vec(match.away.goalPosition),
        },
    }

    r.check("arena type recognised", match.type ~= nil, tostring(match.type))
    r.check("arena transform is not the origin",
        not match.transform.position:isNearlyZero(), tostring(match.transform.position))
    r.check("team names present", match.home.name ~= "" or match.away.name ~= "",
        ("home=%q away=%q"):format(match.home.name, match.away.name))
    r.check("team names differ", match.home.name ~= match.away.name,
        "same name on both sides means logos cannot be auto-matched per side")

    local goalSpan = Util.dist(match.home.goalPosition, match.away.goalPosition)
    r.check("goals are a plausible distance apart", goalSpan > 1000 and goalSpan < 30000,
        ("%.0f cm apart"):format(goalSpan))
    snap.goalSpan = goalSpan

    -- Ball
    local frame = getGameData()
    local ballCount = 0
    local arenaBalls = 0
    if frame then
        for _, b in frame.balls do
            ballCount += 1
            if Util.isArenaBall(b) then arenaBalls += 1 end
        end
    end
    snap.ballsInFrame = ballCount
    snap.arenaBalls = arenaBalls
    snap.ball = match.ball and {
        position = vec(match.ball.transform.position),
        velocity = vec(match.ball.velocity),
        distanceToArenaCentre = Util.dist(match.transform.position, match.ball.transform.position),
    } or nil
    r.check("a ball was found for this arena", match.ball ~= nil,
        ("%d balls in frame, %d white/white"):format(ballCount, arenaBalls))

    -- Players
    local players, inArena = 0, 0
    if frame then
        for _, p in frame.players do
            players += 1
            if p.teamIndex ~= Util.TeamIndex.NoTeam then inArena += 1 end
        end
    end
    snap.playersInFrame = players
    snap.playersOnTeams = inArena
    r.check("players are visible", players > 0, players .. " in frame, " .. inArena .. " on teams")

    return snap
end

-- The bug that made FOV useless was arithmetic, so record the arithmetic.
local function snapshotFraming(r, match)
    local s = Sideline.settings
    local out = {
        settings = {
            sideDistance = s.sideDistance, zoomFraction = s.zoomFraction,
            fovMin = s.fovMin, fovMax = s.fovMax, fovFixed = s.fovFixed,
            subjectMin = s.subjectMin, subjectMax = s.subjectMax,
        },
        debug = {
            side = Sideline.debug.side, blend = Sideline.debug.blend,
            fov = Sideline.debug.fov, subject = Sideline.debug.subject,
            groundLift = Sideline.debug.groundLift, hasBall = Sideline.debug.hasBall,
        },
        cameraPosition = vec(camera.position),
        cameraFov = camera.fieldOfView,
        isActive = camera.isActive,
        isFollowed = camera.isFollowed,
    }
    if match and match.ball then
        out.distanceToBall = Util.dist(camera.position, match.ball.transform.position)
    end
    r.check("FOV is not pinned to the minimum",
        math.abs(Sideline.debug.fov - s.fovMin) > 0.5 or not s.autoZoom,
        ("fov=%.1f min=%.1f subject=%.0f"):format(Sideline.debug.fov, s.fovMin, Sideline.debug.subject))
    return out
end

local function snapshotParticles(r)
    local before = Particles.stats.live
    local spawned = Particles.testBurst()
    r.check("test burst spawned particles", spawned > 0, spawned .. " spawned")
    r.check("particles are live after the burst", Particles.stats.live > before,
        ("live %d -> %d"):format(before, Particles.stats.live))

    -- HDR is what makes particles glow rather than look like coloured sticks, so record the
    -- peak channel actually being emitted.
    local peak = 0
    for _, v in pairs(Particles.variants) do
        peak = math.max(peak, v.colourStart.x, v.colourStart.y, v.colourStart.z)
    end
    r.check("variant colours are HDR (>1)", peak > 1, "peak channel " .. peak)

    return {
        liveBefore = before,
        liveAfter = Particles.stats.live,
        spawnedTotal = Particles.stats.spawned,
        recycled = Particles.stats.dropped,
        lights = Particles.stats.lights,
        sizeScale = Particles.sizeScale,
        peakColourChannel = peak,
        maxParticles = Particles.maxParticles,
    }
end

--------------------------------------------------------------------------------
-- Entry point
--------------------------------------------------------------------------------

function Diagnostics.run(match)
    local r = runner()
    local report = {
        version = "1.1.0",
        clock = os.clock(),
        activeProfile = config.activeProfile,
        profileCount = #Profiles.names(),
    }

    probeMesh(r)
    probeLight(r)
    probeFiles(r)
    report.angles = probeAngles(r)
    report.match = snapshotMatch(r, match)
    report.framing = snapshotFraming(r, match)
    report.particles = snapshotParticles(r)
    report.selfTest = select(2, Particles.selfTest())

    local gamemodes = {}
    for _, id in SpectatorGamemodes.listGamemodeIds() do table.insert(gamemodes, id) end
    report.gamemodeIds = gamemodes
    r.check("at least one gamemode slot exists", #gamemodes > 0, #gamemodes .. " slots")

    if match then
        local slots = Profiles.slots(match.type, match.arenaHeight)
        report.logoSlots = {}
        for i, slot in slots do
            table.insert(report.logoSlots, {
                index = i, name = slot.name, side = slot.side, enabled = slot.enabled,
                offset = { x = slot.x, y = slot.y, z = slot.z },
                size = { width = slot.width, height = slot.height },
                status = require("scoreboard").status[i],
            })
        end
        r.check("logo slots configured", #slots > 0, #slots .. " slots")
    end

    report.checks = r.checks
    report.passed = r.passed
    report.failed = r.failed

    Diagnostics.lastPassed = r.passed
    Diagnostics.lastFailed = r.failed
    Diagnostics.lastSummary = ("%d passed, %d failed"):format(r.passed, r.failed)

    local text = LuauJson.serialize(report, true)
    if text == "" then
        issue("casterfx diagnostics: serialize failed (a value was not table/number/string/bool)")
        Diagnostics.lastSummary = Diagnostics.lastSummary .. " (write FAILED)"
        return report
    end
    if LuauFile.saveText("diagnostics.json", text) then
        print("casterfx diagnostics: " .. Diagnostics.lastSummary .. " -> diagnostics.json")
    else
        issue("casterfx diagnostics: could not write diagnostics.json")
    end

    for _, c in r.checks do
        if not c.ok then issue("casterfx FAIL: " .. c.name .. " -- " .. c.detail) end
    end
    return report
end

return Diagnostics
