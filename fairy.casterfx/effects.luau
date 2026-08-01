-- Effects: the VFX, composed from the HDR line particle engine.
--
-- Deliberately over the top. Every count scales with settings.intensity, so turning it down
-- is one slider rather than an edit.
--
-- Team colours are multiplied well past 1 before being handed to the engine, because that is
-- what makes them bloom. A team colour used raw (0-1) reads as a dull coloured stick.

local Util = require("util")
local Particles = require("particles")
local CCFX = require("ccfx")

local Effects = {}

-- Which engine draws the goal and kickoff. "ccfx" is the ported CasterCamera system, which
-- is known to work in game; "hdr" is this package's own line engine. Kept switchable so the
-- two can be compared directly instead of argued about.
Effects.engine = "ccfx"

Effects.settings = {
    intensity = 1,
    goalEnabled = true,
    goalOutline = true,
    goalOutlineRoll = 0,
    goalOutlinePitch = 0,
    goalOutlineYaw = 0,
    goalOutlineX = 0,
    goalOutlineY = 0,
    goalOutlineZ = 0,
    goalShockwaves = true,
    goalDebris = true,
    goalSparks = true,
    goalSprites = true,
    goalLights = true,
    lightIntensity = 0.35,
    kickoffEnabled = true,
    trailEnabled = true,
    trailInterval = 0.02,
    trailLength = 26,
    trailBoost = 12,
    impactEnabled = true,
    hdrBoost = 20,     -- how far past 1 team colours are pushed
}

local function count(n)
    return math.max(1, math.floor(n * Effects.settings.intensity))
end

local function up()
    return gravity.strength > 0 and gravity.upDirection or Vec3.upVector
end

-- LinearColor (0-1) -> HDR Vec3 for the engine. Normalised first so a dark team colour still
-- glows: without this, a navy team would emit almost nothing.
local function hdr(colour, boost)
    local peak = math.max(colour.R, colour.G, colour.B, 0.15)
    local scale = (boost or Effects.settings.hdrBoost) / peak
    return Vec3.new(colour.R * scale, colour.G * scale, colour.B * scale)
end

local function whiteHot(boost)
    local b = boost or 40
    return Vec3.new(b, b, b)
end

--------------------------------------------------------------------------------
-- Goal
--------------------------------------------------------------------------------

-- The outline's own axes are x = pitch/plane normal, y = width, z = height -- the same
-- convention as the ARENA frame (compare ARENA_TYPES goalOffset, which is +x down the pitch
-- and +z up). goalRotation is that frame yawed by 90 degrees, which is right for a ring
-- normal but would stand the goal silhouette edge-on. So the outline uses the arena frame,
-- and the sliders exist only for fine tuning on top of a default that should already be right.
local function outlineFrame(arenaRotation, goalRotation)
    local s = Effects.settings
    local base = arenaRotation or goalRotation
    return base * Quat.fromEuler(s.goalOutlineRoll, s.goalOutlinePitch, s.goalOutlineYaw)
end

-- goalPosition comes from a hardcoded per-arena-type offset, which is close but not exact for
-- every map. The nudge is applied in the outline's own frame, so "forward" stays along the
-- pitch and "up" stays up no matter how the arena is rotated.
local function outlinePosition(position, rot)
    local s = Effects.settings
    return position + rot:rotateVector(
        Vec3.new(s.goalOutlineX, s.goalOutlineY, s.goalOutlineZ))
end

-- Draws the silhouette at both goals every frame it is called, so the calibration sliders
-- can be judged live instead of by triggering a goal and watching a 2 second effect.
function Effects.previewGoalOutline(match)
    if match == nil then return end
    local rot = outlineFrame(match.transform.rotation, nil)
    for _, team in { match.home, match.away } do
        Particles.drawShape(Particles.goalOutline, outlinePosition(team.goalPosition, rot),
            rot, 1, hdr(team.color, 12), 22)
    end
end

function Effects.goalExplosion(position, rotation, colour, arenaRotation)
    local s = Effects.settings
    if not s.goalEnabled then return end

    if Effects.engine == "ccfx" then
        -- Their recipe expects the goal frame flipped 180 in yaw, and the outline sits in the
        -- arena frame (x across the goal mouth), so build the same frames used by the preview.
        local outlineRot = outlineFrame(arenaRotation, rotation)
        CCFX.goalExplosion(outlinePosition(position, outlineRot), outlineRot, colour,
            s.intensity, s.goalOutline)
        if s.goalLights then
            local lit = s.intensity * s.lightIntensity
            Particles.flash(position, LinearColor.White, 30000 * lit, 3000, 0.35)
            Particles.flash(position, colour, 50000 * lit, 5000, 0.9)
        end
        return
    end

    local teamHdr = hdr(colour)
    local u = up()
    -- Rings sit in the plane of the goal mouth; forward is the goal's own facing.
    local goalForward = rotation:getForwardVector()

    local dim = Vec3.new(teamHdr.x * 0.1, teamHdr.y * 0.1, teamHdr.z * 0.1)

    -- The goal's own silhouette, blown out of the mouth as three shells at halving speeds.
    -- This is the part that makes the celebration read as a GOAL: rings and embers alone are
    -- a generic explosion that could be happening anywhere on the pitch.
    if s.goalOutline then
        local outlineRot = outlineFrame(arenaRotation, rotation)
        local outlinePos = outlinePosition(position, outlineRot)
        local speed = 1300
        for i = 1, 3 do
            Particles.spawn({
                variant = "goalOutline",
                position = outlinePos,
                rotation = outlineRot,
                velocity = goalForward * speed,
                life = 1.0 + i * 0.4,
                colourStart = i == 1 and whiteHot(55) or teamHdr,
                colourEnd = dim,
            })
            speed /= 2
        end
    end

    if s.goalShockwaves then
        -- Three staggered rings read as a pulse train rather than one pop.
        for i = 1, 3 do
            Particles.spawn({
                variant = "goalRing",
                position = position,
                forward = goalForward,
                life = 0.55 + i * 0.3,
                radius = 40,
                colourStart = i == 1 and whiteHot(50) or teamHdr,
                colourEnd = dim,
            })
        end
        -- One flat on the floor, which is what sells scale on a wide shot.
        Particles.spawn({
            variant = "goalRing",
            position = position - u * 40,
            forward = u,
            life = 1.4, radius = 60,
            colourStart = teamHdr,
        })
    end

    -- Denser than the first pass. The reference throws 300 embers at a goal; 90 spread over
    -- a 25m goal mouth is sparse enough to read as a few sparks rather than a blast.
    if s.goalDebris then
        for _ = 1, count(170) do
            local dir = Util.randomUnit()
            Particles.spawn({
                variant = "goalEmber",
                position = position + dir * Util.randomRange(10, 80),
                velocity = dir * Util.randomRange(400, 1800) + u * Util.randomRange(100, 600),
                life = Util.randomRange(1.4, 3.0),
                colourStart = math.random() < 0.3 and whiteHot(45) or teamHdr,
            })
        end
    end

    if s.goalSparks then
        for _ = 1, count(95) do
            Particles.spawn({
                variant = "goalSpark",
                position = position,
                velocity = Util.randomUnit() * Util.randomRange(2000, 4500),
                life = Util.randomRange(0.35, 0.9),
                colourStart = whiteHot(60),
                colourEnd = Vec3.new(teamHdr.x * 0.3, teamHdr.y * 0.3, teamHdr.z * 0.3),
            })
        end
    end

    -- A slow, wide cloud that lingers after the fast stuff is gone.
    if s.goalSprites then
        for _ = 1, count(40) do
            local dir = Util.randomUnit()
            Particles.spawn({
                variant = "goalEmber",
                position = position + dir * Util.randomRange(50, 400),
                velocity = dir * Util.randomRange(100, 500) + u * Util.randomRange(50, 250),
                life = Util.randomRange(2.0, 4.0),
                colourStart = teamHdr,
                colourEnd = Vec3.new(0.5, 0.5, 0.6),
            })
        end
    end

    if s.goalLights then
        local lit = s.intensity * s.lightIntensity
        Particles.flash(position, LinearColor.White, 30000 * lit, 3000, 0.35)
        Particles.flash(position, colour, 50000 * lit, 5000, 0.9)
    end
end

--------------------------------------------------------------------------------
-- Kickoff
--------------------------------------------------------------------------------

function Effects.kickoffBurst(position, homeColor, awayColor, arenaRotation)
    local s = Effects.settings
    if not s.kickoffEnabled then return end

    if Effects.engine == "ccfx" then
        CCFX.kickoff(position, arenaRotation or Quat.identity, homeColor, awayColor,
            s.intensity)
        return
    end

    local u = up()

    for i, colour in { homeColor, awayColor } do
        Particles.spawn({
            variant = "kickoffRing",
            position = position,
            forward = u,
            life = 0.9 + i * 0.25,
            radius = 40,
            colourStart = hdr(colour),
        })
    end

    -- Column rising out of centre court.
    for _ = 1, count(50) do
        local dir = Util.randomUnit()
        -- Project onto the floor plane rather than assuming world Z is up, so this still
        -- works in a zero-g or rotated arena.
        local flat = (dir - u * dir:dot(u)):getSafeNormal()
        Particles.spawn({
            variant = "kickoffEmber",
            position = position + flat * Util.randomRange(0, 150),
            velocity = u * Util.randomRange(800, 2200) + flat * Util.randomRange(50, 300),
            life = Util.randomRange(0.9, 1.8),
            colourStart = hdr(math.random() < 0.5 and homeColor or awayColor),
        })
    end
end

--------------------------------------------------------------------------------
-- Ball trail -- a connected ribbon
--------------------------------------------------------------------------------

local trailTimer = 0

function Effects.ballTrail(dt, position, velocity, colour)
    local s = Effects.settings
    if not s.trailEnabled or position == nil then
        Effects.resetTrail()
        return
    end

    trailTimer += dt
    local interval = math.max(s.trailInterval, 0.008)
    -- Cap the catch-up: after a hitch or the first frame following a load, dt can be large
    -- enough to ask for dozens of points at once.
    local budget = 6
    while trailTimer >= interval and budget > 0 do
        trailTimer -= interval
        budget -= 1
        Particles.pushTrailPoint(position, colour, math.floor(s.trailLength))
    end
    if budget == 0 then trailTimer = 0 end

    -- Redrawn every frame, since lines are cleared every frame.
    local speed = velocity and velocity:length() or 0
    local speedBoost = 1 + math.clamp(speed / 2000, 0, 1)
    Particles.drawTrail(10, s.trailBoost * speedBoost)
end

function Effects.resetTrail()
    trailTimer = 0
    Particles.clearTrail()
end

--------------------------------------------------------------------------------
-- Impact
--------------------------------------------------------------------------------

function Effects.impactRing(position, normal, colour)
    if not Effects.settings.impactEnabled then return end
    Particles.spawn({
        variant = "impactRing",
        position = position,
        forward = normal,
        life = 0.4,
        radius = 25,
        colourStart = hdr(colour, 26),
    })
    for _ = 1, count(8) do
        local dir = (normal + Util.randomUnit() * 0.7):getSafeNormal()
        Particles.spawn({
            variant = "goalSpark",
            position = position,
            velocity = dir * Util.randomRange(600, 1600),
            life = Util.randomRange(0.2, 0.45),
            colourStart = whiteHot(35),
        })
    end
end

return Effects
