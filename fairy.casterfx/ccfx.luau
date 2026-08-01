-- CCFX: a faithful port of the particle system from dennssen/CasterCamera
-- (particlesystem.luau, the "Yasaifex" system), plus its GoalExplosionEffect and
-- GameStartEffect recipes.
--
-- This exists because it is KNOWN TO WORK IN GAME. The HDR line engine in particles.luau is
-- more capable on paper but had a failure nobody could see from outside, so this is a second
-- implementation that can be switched to and compared against rather than a replacement.
--
-- Copied faithfully on purpose. The counts, lifespans, drag, gravity and shrink curve are
-- theirs; changing them while also changing engines would make it impossible to tell which
-- change caused a difference.
--
-- ONE deliberate deviation: the original advances by a fixed amount per tick
--   aliveTime -= 1 * speed ;  position += velocity * speed
-- which ties the whole simulation to frame rate. Here `step` is dt * 60 * speed, so it is
-- IDENTICAL at 60fps and merely stays correct at 30 or 144 instead of running at half or
-- double pace. Velocities and lifespans keep their original units (per-60Hz-tick).

local CCFX = {}

CCFX.Variant = {
    Embers = "embers",
    Rings = "rings",
    GoalRing = "goalring",
    Rocket = "rocket",
}

-- Their GUI exposes vibrance as 1-20. Team colours arrive normalised 0-1, and anything at or
-- near 1 reads as a dull stick, so the default sits well above 1 to bloom.
CCFX.vibrance = 8
CCFX.speed = 1
CCFX.maxParticles = 1800
CCFX.collide = true         -- their embers bounce via castRay; 300 rays/frame is their cost
CCFX.stats = { spawned = 0, dropped = 0 }

local particles = {}

-- The real goal mouth outline, in the goal's own frame. Same six points as their GoalRing.
CCFX.goalOutline = {
    Vec3.new(0, -248.905, -52.404),
    Vec3.new(0, -248.905, 109.223),
    Vec3.new(0, -188.979, 172.762),
    Vec3.new(0, 188.979, 172.762),
    Vec3.new(0, 248.905, 109.223),
    Vec3.new(0, 248.905, -52.404),
}

function CCFX.count() return #particles end

function CCFX.clear()
    particles = {}
end

--------------------------------------------------------------------------------
-- Spawning
--------------------------------------------------------------------------------

-- The original mutates the caller's colour table (color.R *= vibrance), which quietly
-- brightens the team colour a little more on every single spawn. Copy instead.
local function boosted(colour)
    local v = CCFX.vibrance
    return { R = (colour.R or 0) * v, G = (colour.G or 0) * v, B = (colour.B or 0) * v }
end

function CCFX.create(position, rotation, scale, velocity, colour, variant, lifespan)
    if #particles >= CCFX.maxParticles then
        -- Recycle the oldest; the newest are the ones being looked at.
        table.remove(particles, 1)
        CCFX.stats.dropped += 1
    end
    table.insert(particles, {
        position = position,
        rotation = rotation or Quat.identity,
        scale = scale,
        velocity = velocity or Vec3.zeroVector,
        colour = boosted(colour),
        variant = variant,
        lifespan = lifespan,
        aliveTime = lifespan,
    })
    CCFX.stats.spawned += 1
end

--------------------------------------------------------------------------------
-- Update -- their particleAffect, with a frame-rate corrected step
--------------------------------------------------------------------------------

local EMBER_DRAG = 0.95
local GRAVITY_MULTIPLIER = 0.8
local RING_RESOLUTION = 90
local RING_MAX_RADIUS = 6000

local function drawEmber(p)
    WorldDraw.drawLine(p.position, p.position - p.velocity,
        p.colour.R, p.colour.G, p.colour.B, p.scale * 20, 0)
end

local function drawRing(p)
    local r = (1 - p.aliveTime / p.lifespan) * RING_MAX_RADIUS
    local theta = 2 * math.pi / RING_RESOLUTION
    local previous = Vec3.new(r, 0, -40)
    for i = 1, RING_RESOLUTION do
        local current = Vec3.new(r * math.cos(i * theta), r * math.sin(i * theta), -40)
        WorldDraw.drawLine(
            p.rotation:rotateVector(previous) + p.position,
            p.rotation:rotateVector(current) + p.position,
            p.colour.R, p.colour.G, p.colour.B, p.scale * 90, 0)
        previous = current
    end
end

local function drawGoalRing(p)
    local outline = CCFX.goalOutline
    for i = 1, #outline - 1 do
        WorldDraw.drawLine(
            p.rotation:rotateVector(outline[i]) + p.position,
            p.rotation:rotateVector(outline[i + 1]) + p.position,
            p.colour.R, p.colour.G, p.colour.B, p.scale * 15, 0)
    end
end

function CCFX.update(dt)
    if #particles == 0 then return end
    -- 1.0 at 60fps, so the ported tuning behaves exactly as it does in the original.
    local step = dt * 60 * CCFX.speed
    if step <= 0 then return end

    local up = gravity.strength > 0 and gravity.upDirection or Vec3.upVector

    local i = 1
    while i <= #particles do
        local p = particles[i]
        p.aliveTime -= step

        local dead = p.aliveTime < 0

        if not dead then
            if p.variant == CCFX.Variant.Embers or p.variant == CCFX.Variant.Rocket then
                p.velocity = p.velocity - up * (GRAVITY_MULTIPLIER * step)
                if p.variant ~= CCFX.Variant.Rocket then
                    p.velocity = p.velocity * (EMBER_DRAG ^ step)
                end
            end

            if CCFX.collide and p.variant == CCFX.Variant.Embers then
                local hit = camera:castRay(p.position, p.position + p.velocity)
                if hit and hit.successful then
                    local n = hit.normal
                    p.velocity = p.velocity - n * (2 * p.velocity:dot(n))
                end
            end

            p.position = p.position + p.velocity * step

            -- Their shrink: a compounding multiply by the remaining-life ratio. It is what
            -- makes these fade out far sooner than the raw lifespan suggests.
            if p.variant ~= CCFX.Variant.Rocket then
                p.scale = p.scale * ((p.aliveTime / p.lifespan) ^ step)
            end

            if p.scale < 0.01 then dead = true end
        end

        if dead then
            particles[i] = particles[#particles]
            table.remove(particles)
        else
            if p.variant == CCFX.Variant.Embers or p.variant == CCFX.Variant.Rocket then
                drawEmber(p)
            elseif p.variant == CCFX.Variant.Rings then
                drawRing(p)
            elseif p.variant == CCFX.Variant.GoalRing then
                drawGoalRing(p)
            end
            i += 1
        end
    end
end

--------------------------------------------------------------------------------
-- Recipes -- their GoalExplosionEffect and GameStartEffect
--------------------------------------------------------------------------------

-- goalRotation should already include their Quat.fromEuler(0, 0, 180) flip.
-- `withOutline` is false for arenas whose goals are not this shape (Driftblitz, ZDrift),
-- which is the same exclusion the original makes.
function CCFX.goalExplosion(goalPosition, goalRotation, colour, intensity, withOutline)
    local embers = math.max(1, math.floor(300 * (intensity or 1)))
    for _ = 1, embers do
        local velocity = Vec3.new(
            math.random(-100, 100), math.random(-100, 100), math.random(-100, 100))
        CCFX.create(goalPosition, Quat.identity, 0.3, velocity, colour,
            CCFX.Variant.Embers, math.random(800, 1300))
    end

    CCFX.create(goalPosition, goalRotation, 0.9, Vec3.zeroVector, colour, CCFX.Variant.Rings, 150)
    CCFX.create(goalPosition, goalRotation, 1, Vec3.zeroVector, colour, CCFX.Variant.Rings, 200)
    CCFX.create(goalPosition, goalRotation, 1, Vec3.zeroVector, colour, CCFX.Variant.Rings, 400)

    if not withOutline then return end

    local goalSpeed = 20
    for _ = 1, 3 do
        CCFX.create(goalPosition, goalRotation, 1,
            goalRotation:getForwardVector() * goalSpeed, colour, CCFX.Variant.GoalRing, 400)
        goalSpeed /= 2
    end
end

function CCFX.kickoff(position, arenaRotation, homeColour, awayColour, intensity)
    local average = {
        R = ((homeColour.R or 0) + (awayColour.R or 0)) / 2,
        G = ((homeColour.G or 0) + (awayColour.G or 0)) / 2,
        B = ((homeColour.B or 0) + (awayColour.B or 0)) / 2,
    }

    CCFX.create(position, arenaRotation, 0.9, Vec3.zeroVector, average, CCFX.Variant.Rings, 150)
    CCFX.create(position, arenaRotation, 0.7,
        arenaRotation:rotateVector(Vec3.new(0, 0, 10)), average, CCFX.Variant.Rings, 600)
    CCFX.create(position, arenaRotation, 0.7,
        arenaRotation:rotateVector(Vec3.new(0, 0, 2)), average, CCFX.Variant.Rings, 400)

    local palette = { homeColour, awayColour }
    local embers = math.max(1, math.floor(300 * (intensity or 1)))
    for _ = 1, embers do
        local velocity = Vec3.new(
            math.random(-30, 30), math.random(-30, 30), math.random(20, 80))
        CCFX.create(position, arenaRotation, 0.5,
            arenaRotation:rotateVector(velocity), palette[math.random(1, 2)],
            CCFX.Variant.Embers, math.random(800, 1300))
    end
end

-- Fires one of each variant in front of the camera. If THIS shows nothing, the problem is
-- drawLine or the clear order, not any particular effect.
function CCFX.testBurst()
    local base = camera.position + camera.rotation:getForwardVector() * 500
    local white = { R = 1, G = 1, B = 1 }
    for _ = 1, 120 do
        CCFX.create(base, Quat.identity, 0.4,
            Vec3.new(math.random(-60, 60), math.random(-60, 60), math.random(-60, 60)),
            white, CCFX.Variant.Embers, math.random(400, 900))
    end
    CCFX.create(base, camera.rotation, 0.8, Vec3.zeroVector, white, CCFX.Variant.Rings, 200)
    print(("casterfx ccfx test: %d particles live"):format(#particles))
    return #particles
end

return CCFX
