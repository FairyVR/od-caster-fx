-- Effects: the actual VFX, composed out of the particle engine.
--
-- Deliberately over the top. Every count is multiplied by settings.intensity, so
-- turning it down is one slider rather than an edit.

local Util = require("util")
local Particles = require("particles")

local Effects = {}

Effects.settings = {
    intensity = 1,
    goalEnabled = true,
    goalShockwaves = true,
    goalDebris = true,
    goalSparks = true,
    goalSprites = true,
    goalLights = true,
    kickoffEnabled = true,
    trailEnabled = true,
    trailInterval = 0.03,
    impactEnabled = true,
    -- Point light intensity is in engine units with no documented scale, so this is a
    -- calibration knob rather than a constant. Turn it down if goals blow out the exposure.
    lightIntensity = 1.0,
}

local SPRITE_FLARE = "sprites/flare.png"
local SPRITE_STAR  = "sprites/star.png"
local SPRITE_SPARK = "sprites/spark.png"

local function count(n)
    return math.max(1, math.floor(n * Effects.settings.intensity))
end

local function up()
    return gravity.strength > 0 and gravity.upDirection or Vec3.upVector
end

-- Rotation that puts a ring/disc (whose geometry lies in the YZ plane, normal +X)
-- flat against the plane whose normal is `normal`.
local function facePlane(normal)
    local n = normal:getSafeNormal()
    if n:length() < 0.001 then return Quat.identity end
    return Quat.fromXZ(n, Util.perpendicular(n))
end

--------------------------------------------------------------------------------
-- Goal
--------------------------------------------------------------------------------

function Effects.goalExplosion(position, rotation, color)
    local s = Effects.settings
    if not s.goalEnabled then return end

    local hot = Util.whiten(color, 0.55)
    local bright = Util.boost(color, 1.6)
    local u = up()

    -- Core flash: a disc that blows up fast and vanishes. Reads as the initial pop.
    Particles.spawn({
        shape = "disc", position = position, color = LinearColor.White,
        size = Vec3.new(1, 90, 90), life = 0.3,
        growFrom = 0.15, growTo = 7, facing = "billboard",
    })

    if s.goalShockwaves then
        -- Rings in the plane of the goal mouth, staggered so they read as a pulse train.
        for i = 1, 3 do
            Particles.spawn({
                shape = "ring", position = position, color = i == 1 and hot or bright,
                size = Vec3.new(1, 120, 120), life = 0.7 + i * 0.35,
                growFrom = 0.08, growTo = 14 + i * 6,
                facing = "fixed", rotation = rotation,
            })
        end
        -- One flat on the floor, which is what sells scale on a wide autocam shot.
        Particles.spawn({
            shape = "ring", position = position - u * 60, color = bright,
            size = Vec3.new(1, 150, 150), life = 1.5,
            growFrom = 0.05, growTo = 22,
            facing = "fixed", rotation = facePlane(u),
        })
    end

    if s.goalDebris then
        for _ = 1, count(140) do
            local dir = Util.randomUnit()
            local speed = Util.randomRange(300, 1500)
            Particles.spawn({
                shape = "shard", position = position + dir * Util.randomRange(10, 90),
                velocity = dir * speed + u * Util.randomRange(100, 500),
                color = math.random() < 0.25 and hot or color,
                size = Vec3.new(Util.randomRange(25, 70), Util.randomRange(5, 12), Util.randomRange(5, 12)),
                life = Util.randomRange(1.6, 3.2),
                gravity = 900, drag = 0.35, bounce = true, restitution = 0.45,
                facing = "spin",
                rotation = Quat.fromEuler(math.random() * 360, math.random() * 360, math.random() * 360),
                spin = Vec3.new(Util.randomRange(-400, 400), Util.randomRange(-400, 400), Util.randomRange(-400, 400)),
                growTo = 0.7,
            })
        end
    end

    if s.goalSparks then
        for _ = 1, count(70) do
            local dir = Util.randomUnit()
            Particles.spawn({
                shape = "shard", position = position,
                velocity = dir * Util.randomRange(1200, 3200),
                color = hot,
                size = Vec3.new(Util.randomRange(60, 160), 4, 4),
                life = Util.randomRange(0.45, 1.1),
                gravity = 400, drag = 1.4,
                facing = "velocity", growTo = 0.2,
            })
        end
    end

    if s.goalSprites then
        local flare = Particles.sprite(SPRITE_FLARE)
        local star = Particles.sprite(SPRITE_STAR)
        if flare then
            for _ = 1, count(45) do
                local dir = Util.randomUnit()
                local size = Util.randomRange(60, 180)
                Particles.spawn({
                    shape = "quad", position = position + dir * Util.randomRange(20, 200),
                    velocity = dir * Util.randomRange(200, 900) + u * Util.randomRange(50, 300),
                    texture = flare, size = Vec3.new(1, size, size),
                    life = Util.randomRange(0.6, 1.5),
                    gravity = 200, drag = 1.0,
                    facing = "billboard", roll = math.random() * 360,
                    rollSpeed = Util.randomRange(-220, 220),
                    growFrom = 0.4, growTo = 1.3,
                })
            end
        end
        if star then
            for _ = 1, count(22) do
                local dir = Util.randomUnit()
                local size = Util.randomRange(120, 320)
                Particles.spawn({
                    shape = "quad", position = position + dir * Util.randomRange(50, 300),
                    velocity = dir * Util.randomRange(100, 500),
                    texture = star, size = Vec3.new(1, size, size),
                    life = Util.randomRange(0.8, 1.8),
                    drag = 1.2,
                    facing = "billboard", roll = math.random() * 360,
                    rollSpeed = Util.randomRange(-90, 90),
                    growFrom = 0.2, growTo = 1.6,
                })
            end
        end
    end

    if s.goalLights then
        local lit = s.intensity * s.lightIntensity
        Particles.flash(position, LinearColor.White, 90000 * lit, 4000, 0.35)
        Particles.flash(position, bright, 140000 * lit, 6000, 0.9)
    end
end

--------------------------------------------------------------------------------
-- Kickoff
--------------------------------------------------------------------------------

function Effects.kickoffBurst(position, homeColor, awayColor)
    local s = Effects.settings
    if not s.kickoffEnabled then return end
    local u = up()

    for i, col in { homeColor, awayColor } do
        Particles.spawn({
            shape = "ring", position = position, color = Util.boost(col, 1.4),
            size = Vec3.new(1, 100, 100), life = 1.1 + i * 0.2,
            growFrom = 0.05, growTo = 16,
            facing = "fixed", rotation = facePlane(u),
        })
    end

    -- Column of sparks rising out of centre court.
    for _ = 1, count(60) do
        local dir = Util.randomUnit()
        -- Project onto the arena floor plane rather than assuming world Z is up,
        -- so this still works in a zero-g or rotated arena.
        local flat = (dir - u * dir:dot(u)):getSafeNormal()
        Particles.spawn({
            shape = "shard", position = position + flat * Util.randomRange(0, 160),
            velocity = u * Util.randomRange(600, 1600) + flat * Util.randomRange(50, 250),
            color = math.random() < 0.5 and homeColor or awayColor,
            size = Vec3.new(Util.randomRange(40, 90), 5, 5),
            life = Util.randomRange(0.9, 1.8),
            gravity = 700, drag = 0.5,
            facing = "velocity", growTo = 0.3,
        })
    end

    local spark = Particles.sprite(SPRITE_SPARK)
    if spark then
        for _ = 1, count(24) do
            local dir = Util.randomUnit()
            local size = Util.randomRange(80, 200)
            Particles.spawn({
                shape = "quad", position = position + dir * Util.randomRange(30, 250),
                velocity = u * Util.randomRange(200, 700),
                texture = spark, size = Vec3.new(1, size, size),
                life = Util.randomRange(0.7, 1.4), drag = 1.0,
                facing = "billboard", roll = math.random() * 360,
                rollSpeed = Util.randomRange(-160, 160), growTo = 1.4,
            })
        end
    end
end

--------------------------------------------------------------------------------
-- Ball trail
--------------------------------------------------------------------------------

local trailTimer = 0

function Effects.ballTrail(dt, position, velocity, color)
    local s = Effects.settings
    if not s.trailEnabled or position == nil then
        trailTimer = 0
        return
    end
    local speed = velocity and velocity:length() or 0
    trailTimer += dt
    local interval = math.max(s.trailInterval, 0.008)
    -- Cap the catch-up: after a hitch or the first frame following a load, dt can be large
    -- enough to ask for hundreds of puffs at once and blow the whole particle budget.
    local budget = 8
    while trailTimer >= interval and budget > 0 do
        trailTimer -= interval
        budget -= 1
        local scaled = math.clamp(speed / 1500, 0, 1)
        -- Coloured part is untextured: a textured mesh ignores `color`, and the
        -- trail must be the possessing team's colour.
        Particles.spawn({
            shape = "disc", position = position,
            color = Util.boost(color, 1.3),
            size = Vec3.new(1, 22 + scaled * 26, 22 + scaled * 26),
            life = 0.34 + scaled * 0.2,
            facing = "billboard", growTo = 0.1,
        })
        if speed > 900 and math.random() < 0.5 then
            local spark = Particles.sprite(SPRITE_SPARK)
            if spark then
                Particles.spawn({
                    shape = "quad", position = position,
                    velocity = velocity * -0.15 + Util.randomUnit() * 120,
                    texture = spark, size = Vec3.new(1, 40, 40),
                    life = 0.35, drag = 2.0,
                    facing = "billboard", roll = math.random() * 360, growTo = 0.2,
                })
            end
        end
    end
    if budget == 0 then trailTimer = 0 end
end

--------------------------------------------------------------------------------
-- Impact
--------------------------------------------------------------------------------

function Effects.impactRing(position, normal, color)
    if not Effects.settings.impactEnabled then return end
    Particles.spawn({
        shape = "ring", position = position, color = Util.boost(color, 1.5),
        size = Vec3.new(1, 60, 60), life = 0.45,
        growFrom = 0.1, growTo = 7,
        facing = "fixed", rotation = facePlane(normal),
    })
    for _ = 1, count(10) do
        local dir = (normal + Util.randomUnit() * 0.6):getSafeNormal()
        Particles.spawn({
            shape = "shard", position = position,
            velocity = dir * Util.randomRange(400, 1100),
            color = Util.whiten(color, 0.4),
            size = Vec3.new(Util.randomRange(30, 60), 4, 4),
            life = Util.randomRange(0.3, 0.6),
            gravity = 600, drag = 1.5,
            facing = "velocity", growTo = 0.2,
        })
    end
end

function Effects.resetTrail()
    trailTimer = 0
end

return Effects
