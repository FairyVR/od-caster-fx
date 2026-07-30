-- Particles: HDR line-based particle engine.
--
-- Rewritten after the mesh version looked flat and dull in game. Approach and tuning follow
-- yasai's laserTag VFX, which is the best-looking particle work in the spectator ecosystem:
--
--   * Colours are HDR. WorldDraw.drawLine takes 0-1 nominally, but values FAR above 1
--     (10, 20, 40) blow out into bloom. That glow is what makes a particle read as
--     energetic rather than as a coloured stick. Untextured meshes cannot do this at all,
--     which is why the mesh version looked lifeless.
--   * Embers are drawn from position to position+velocity, so they stretch along their own
--     motion. A fast particle becomes a streak and a slow one becomes a dot, for free, and
--     it reads as 3D depth even though a line is flat.
--   * Colour ramps from colourStart to colourEnd over the lifetime, and thickness ramps to
--     zero. Nothing pops out of existence.
--   * Rings are polylines, so they can be huge without costing anything.
--
-- Meshes are still used for the logo quads (they need textures) but no longer for particles.
--
-- NOTE ON CLEARING: lines are drawn every frame with lifetime 0 and cleared at the start of
-- our own update. WorldDraw.clear() is global -- it drops other scripts' lines too -- but
-- every line-drawing camera script does exactly this, and only the active camera's script
-- runs the clear.

local Util = require("util")

local Particles = {}

Particles.maxParticles = 900
Particles.maxLights = 6
Particles.simSpeed = 1
Particles.sizeScale = 1
Particles.enabled = true
Particles.clearEachFrame = true
Particles.stats = { live = 0, lights = 0, dropped = 0, spawned = 0 }

local particles = {}
local lights = {}

--------------------------------------------------------------------------------
-- Variants: the emitter presets. HDR colours on purpose.
--------------------------------------------------------------------------------

-- appearance:
--   "ember"  line from position along velocity -- streaks, sparks, debris
--   "ring"   expanding polyline circle facing `forward` -- shockwaves
--   "spark"  short fixed-length line along velocity -- bright fast chips
Particles.variants = {
    goalRing = {
        appearance = "ring",
        colourStart = Vec3.new(30, 30, 30),
        colourEnd = Vec3.new(6, 6, 6),
        gravity = 0, drag = 0.985, growth = 2600,
        thickness = 26, resolution = 40, collision = false,
    },
    -- streak: seconds of travel drawn as the line. minLength: floor in cm, so a slow or
    -- nearly stopped particle is still a visible dash rather than a point.
    goalEmber = {
        appearance = "ember",
        colourStart = Vec3.new(24, 10, 2),
        colourEnd = Vec3.new(3, 0.4, 0.1),
        gravity = 420, drag = 0.965, growth = 0,
        thickness = 18, collision = true, restitution = 0.55,
        streak = 0.09, minLength = 90,
    },
    goalSpark = {
        appearance = "spark",
        colourStart = Vec3.new(40, 40, 26),
        colourEnd = Vec3.new(8, 3, 0.5),
        gravity = 200, drag = 0.94, growth = 0,
        thickness = 10, collision = false,
        streak = 0.07, minLength = 120,
    },
    kickoffEmber = {
        appearance = "ember",
        colourStart = Vec3.new(18, 18, 18),
        colourEnd = Vec3.new(2, 2, 4),
        gravity = 500, drag = 0.97, growth = 0,
        thickness = 14, collision = true, restitution = 0.4,
        streak = 0.09, minLength = 90,
    },
    kickoffRing = {
        appearance = "ring",
        colourStart = Vec3.new(20, 20, 20),
        colourEnd = Vec3.new(3, 3, 3),
        gravity = 0, drag = 0.99, growth = 1700,
        thickness = 18, resolution = 36, collision = false,
    },
    trail = {
        appearance = "ember",
        colourStart = Vec3.new(14, 14, 14),
        colourEnd = Vec3.new(1.5, 1.5, 1.5),
        gravity = 0, drag = 0.9, growth = 0,
        thickness = 9, collision = false,
        streak = 0.05, minLength = 40,
    },
    impactRing = {
        appearance = "ring",
        colourStart = Vec3.new(24, 24, 24),
        colourEnd = Vec3.new(4, 4, 4),
        gravity = 0, drag = 0.98, growth = 700,
        thickness = 12, resolution = 28, collision = false,
    },
}

--------------------------------------------------------------------------------
-- Drawing helpers
--------------------------------------------------------------------------------

-- Polyline circle in the plane whose normal is `direction`.
local function drawCircle(position, radius, direction, colour, thickness, resolution)
    local normal = direction:getSafeNormal()
    if normal:length() < 0.001 then normal = Vec3.upVector end
    local reference = math.abs(normal.z) < 0.9 and Vec3.upVector or Vec3.rightVector
    local up = Vec3.cross(normal, reference):getSafeNormal()
    local right = Vec3.cross(normal, up):getSafeNormal()

    local step = math.pi * 2 / resolution
    local previous = position + right * radius
    for i = 1, resolution do
        local theta = i * step
        local point = position + (up * math.sin(theta) + right * math.cos(theta)) * radius
        WorldDraw.drawLine(previous, point, colour.x, colour.y, colour.z, thickness, 0)
        previous = point
    end
end

--------------------------------------------------------------------------------
-- Spawning
--------------------------------------------------------------------------------

-- p: { variant, position, velocity, forward, life, radius, colourStart?, colourEnd?, count? }
function Particles.spawn(p)
    if not Particles.enabled then return 0 end
    local preset = Particles.variants[p.variant]
    if preset == nil then
        warn("casterfx: unknown particle variant " .. tostring(p.variant))
        return 0
    end

    local count = p.count or 1
    local spawned = 0
    for _ = 1, count do
        if #particles >= Particles.maxParticles then
            -- Recycle the oldest rather than dropping the newest: the new ones are the ones
            -- the viewer is looking at.
            table.remove(particles, 1)
            Particles.stats.dropped += 1
        end
        local life = p.life or 1
        table.insert(particles, {
            preset = preset,
            position = p.position,
            velocity = p.velocity or Vec3.zeroVector,
            forward = p.forward or Vec3.upVector,
            radius = (p.radius or 0) * Particles.sizeScale,
            thickness = preset.thickness * Particles.sizeScale,
            colourStart = p.colourStart or preset.colourStart,
            colourEnd = p.colourEnd or preset.colourEnd,
            life = life,
            age = life,
        })
        spawned += 1
    end
    Particles.stats.spawned += spawned
    return spawned
end

function Particles.flash(position, colour, intensity, radius, life)
    -- Hard cap. A stuck light is very visible and there is no way to enumerate lights we
    -- have lost track of, so never let the list grow unbounded.
    while #lights >= Particles.maxLights do
        lights[1].light:destroy()
        table.remove(lights, 1)
    end
    local light = WorldDraw.spawnPointLight(position, intensity, Vec3.new(colour.R, colour.G, colour.B), radius)
    if not light then return nil end
    table.insert(lights, { light = light, age = 0, life = life, intensity = intensity, radius = radius })
    return light
end

-- Belt and braces for the "goal stayed lit" case.
function Particles.clearLights()
    for _, l in lights do l.light:destroy() end
    lights = {}
    WorldDraw.clearLights()
end

--------------------------------------------------------------------------------
-- Ball trail: a ribbon, not a row of blobs
--------------------------------------------------------------------------------

local trail = {}

-- Connected segments with a colour and thickness taper along the length. This is what makes
-- a trail read as a trail; independently spawned puffs never do.
function Particles.pushTrailPoint(position, colour, maxPoints)
    table.insert(trail, { position = position, colour = colour })
    while #trail > (maxPoints or 26) do table.remove(trail, 1) end
end

function Particles.clearTrail()
    trail = {}
end

local function drawTrail(baseThickness, boost)
    if #trail < 2 then return end
    local n = #trail
    for i = 2, n do
        local a, b = trail[i - 1], trail[i]
        -- Head of the trail is brightest and thickest, tail fades to nothing.
        local t = (i - 1) / (n - 1)
        local fade = t * t
        local colour = b.colour
        WorldDraw.drawLine(a.position, b.position,
            colour.R * boost * fade, colour.G * boost * fade, colour.B * boost * fade,
            baseThickness * fade * Particles.sizeScale, 0)
    end
end

Particles.drawTrail = drawTrail

--------------------------------------------------------------------------------
-- Update
--------------------------------------------------------------------------------

local holdTimer = 0

-- Must be called at the START of the tick, before anything draws. Clearing inside update()
-- would wipe whatever was drawn earlier in the same frame -- the ball trail, for one.
function Particles.beginFrame()
    -- While holding, skip our clear so long-lifetime probe lines can survive. If they STILL
    -- vanish, something else is clearing, or lines are not rendering at all.
    if holdTimer > 0 then return end
    if Particles.clearEachFrame then WorldDraw.clear() end
end

function Particles.isHolding()
    return holdTimer > 0
end

-- stats.live is only refreshed inside update(), so it reads stale immediately after a
-- spawn. This is the true count right now.
function Particles.count()
    return #particles
end

-- A controlled experiment for "nothing appears". Each line varies exactly one thing, so the
-- answer identifies the cause rather than hinting at it. Drawn with a long lifetime and with
-- our own clearing suspended for the duration.
function Particles.lineProbe(seconds, farPosition)
    seconds = seconds or 10
    holdTimer = seconds
    WorldDraw.clear()

    local rot = camera.rotation
    local base = camera.position + rot:getForwardVector() * 400
    local right = rot:getRightVector()
    local up = rot:getUpVector()

    local function probe(offset, r, g, b, thickness)
        local from = base + right * offset - up * 100
        WorldDraw.drawLine(from, from + up * 200, r, g, b, thickness, seconds)
    end

    -- 1: ordinary colour, ordinary thickness -- does drawLine work here at all?
    probe(-300, 1, 0, 0, 6)
    -- 2: HDR colour -- are values above 1 accepted, or clamped/rejected?
    probe(-100, 20, 0, 0, 6)
    -- 3: very thick, white -- is thickness the reason things are invisible at distance?
    probe(100, 1, 1, 1, 40)
    -- 4: HDR and thick -- what the real effects actually use.
    probe(300, 30, 30, 30, 20)

    -- 5: at the goal, to test whether distance or position is the problem rather than colour.
    if farPosition then
        WorldDraw.drawLine(farPosition, farPosition + Vec3.new(0, 0, 800), 30, 30, 0, 30, seconds)
    end

    print(("casterfx line probe: 4 lines 4m ahead%s, clearing paused %ds")
        :format(farPosition and " + 1 at the goal" or "", seconds))
end

function Particles.update(dt)
    local step = dt * Particles.simSpeed
    if holdTimer > 0 then holdTimer = math.max(0, holdTimer - dt) end
    if step <= 0 then return end

    local up = gravity.strength > 0 and gravity.upDirection or Vec3.upVector

    local i = 1
    while i <= #particles do
        local p = particles[i]
        p.age -= step
        if p.age <= 0 then
            particles[i] = particles[#particles]
            table.remove(particles)
        else
            local preset = p.preset
            local remaining = p.age / p.life          -- 1 at birth, 0 at death
            local elapsed = 1 - remaining

            if preset.gravity ~= 0 then
                p.velocity = p.velocity - up * (preset.gravity * step)
            end
            if preset.drag < 1 then
                p.velocity = p.velocity * (preset.drag ^ (step * 60))
            end

            if preset.collision then
                local nextPos = p.position + p.velocity * step
                local hit = camera:castRay(p.position, nextPos)
                if hit and hit.successful then
                    local n = hit.normal
                    local bounce = (preset.restitution or 0.5) * (0.7 + math.random() * 0.3)
                    p.velocity = (p.velocity - n * (2 * p.velocity:dot(n))) * bounce
                    nextPos = hit.position + n * 2
                end
                p.position = nextPos
            else
                p.position = p.position + p.velocity * step
            end

            -- Colour ramp start -> end. Thickness tapers but never to nothing: a particle
            -- that thins to zero disappears well before its lifetime is up.
            local colour = Vec3.lerp(p.colourStart, p.colourEnd, elapsed)
            local thickness = p.thickness * (0.35 + 0.65 * remaining)

            if preset.appearance == "ember" or preset.appearance == "spark" then
                -- Streak length is proportional to speed, with a floor. The first version
                -- used velocity/60, which is a 6cm line for a 400cm/s ember -- invisible
                -- from the touchline, however bright it was.
                local dir = p.velocity:getSafeNormal()
                if dir:length() < 0.001 then dir = Vec3.upVector end
                local length = math.max(
                    p.velocity:length() * (preset.streak or 0.06),
                    (preset.minLength or 70) * Particles.sizeScale)
                WorldDraw.drawLine(p.position, p.position + dir * length,
                    colour.x, colour.y, colour.z, thickness, 0)
            elseif preset.appearance == "ring" then
                -- Ease out, so the shockwave leaves fast and settles.
                local radius = p.radius + (preset.growth * Particles.sizeScale) * Util.easeOutCubic(elapsed)
                drawCircle(p.position, radius, p.forward, colour, thickness, preset.resolution or 32)
            end

            i += 1
        end
    end

    local li = 1
    while li <= #lights do
        local l = lights[li]
        l.age += step
        if l.age >= l.life then
            l.light:destroy()
            lights[li] = lights[#lights]
            table.remove(lights)
        else
            l.light.intensity = l.intensity * (1 - l.age / l.life) ^ 2
            li += 1
        end
    end

    Particles.stats.live = #particles
    Particles.stats.lights = #lights
end

function Particles.clear()
    particles = {}
    trail = {}
    Particles.clearLights()
    WorldDraw.clear()
end

function Particles.destroyAll()
    Particles.clear()
    Particles.stats = { live = 0, lights = 0, dropped = 0, spawned = 0 }
end

--------------------------------------------------------------------------------
-- Debug
--------------------------------------------------------------------------------

-- One of everything, right in front of the camera, at a size that cannot be missed.
function Particles.testBurst()
    local rot = camera.rotation
    local base = camera.position + rot:getForwardVector() * 600
    local right = rot:getRightVector()
    local up = rot:getUpVector()

    local total = 0
    total += Particles.spawn({
        variant = "goalRing", position = base, forward = rot:getForwardVector(),
        life = 3, radius = 60,
    })
    for _ = 1, 30 do
        total += Particles.spawn({
            variant = "goalEmber", position = base + right * 200,
            velocity = Util.randomUnit() * Util.randomRange(300, 900), life = 2.5,
        })
    end
    for _ = 1, 20 do
        total += Particles.spawn({
            variant = "goalSpark", position = base - right * 200,
            velocity = Util.randomUnit() * Util.randomRange(1500, 3000), life = 1.2,
        })
    end
    Particles.flash(base + up * 100, LinearColor.new(1, 1, 1, 1), 8000, 800, 1.5)

    print(("casterfx test burst: %d particles, %d live, %d lights")
        :format(total, #particles, #lights))
    return total
end

function Particles.selfTest()
    local problems = {}
    local function check(cond, msg)
        if not cond then table.insert(problems, msg) end
    end

    for name, v in pairs(Particles.variants) do
        check(v.appearance == "ember" or v.appearance == "ring" or v.appearance == "spark",
            name .. ": unknown appearance " .. tostring(v.appearance))
        check(v.colourStart ~= nil and v.colourEnd ~= nil, name .. ": missing colour ramp")
        check(v.thickness and v.thickness > 0, name .. ": thickness must be positive")
        -- HDR is the point: a variant capped at 1 will look like a dull stick.
        local peak = math.max(v.colourStart.x, v.colourStart.y, v.colourStart.z)
        check(peak > 1, name .. ": colourStart peak is " .. peak .. ", needs >1 to bloom")
    end

    local wasEnabled, wasSpeed = Particles.enabled, Particles.simSpeed
    Particles.enabled, Particles.simSpeed = true, 1

    local before = #particles
    local spawned = Particles.spawn({
        variant = "goalEmber", position = Vec3.zeroVector,
        velocity = Vec3.new(100, 0, 0), life = 0.1,
    })
    check(spawned == 1, "spawn returned " .. spawned)
    check(#particles == before + 1, "particle count did not increase")
    Particles.update(0.25)
    check(#particles == before, "particle outlived its lifespan")

    Particles.enabled, Particles.simSpeed = wasEnabled, wasSpeed

    if #problems == 0 then
        print("casterfx selftest: PASS")
        return true, "PASS"
    end
    for _, msg in problems do issue("casterfx selftest: " .. msg) end
    return false, #problems .. " failure(s), see Camera Logs"
end

-- Kept so diagnostics can report it; the particle system no longer uses meshes at all.
function Particles.meshSpawnFailed()
    return false
end

return Particles
