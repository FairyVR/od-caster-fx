-- Particles: pooled mesh particle engine.
--
-- Why meshes and not drawLine: meshes depth-test properly, and their transforms can be
-- changed WITHOUT calling draw() again, so animating hundreds of them is nearly free.
-- draw() is only paid when geometry, colour, or texture changes -- so pool entries cache
-- their current material and skip the redraw when a new particle wants the same one.
--
-- Two material paths, forced by the API: a mesh with a texture ignores `color` entirely
-- (base.d.lua: "Solid color the mesh renders with when no texture is set"). So team-coloured
-- particles are untextured geometry, and textured sprites are used as-is.
-- Cutout alpha also means no soft fade -- everything fades out by SHRINKING instead.

local Util = require("util")

local Particles = {}

Particles.maxMeshes = 420   -- hard ceiling on pooled meshes
Particles.simSpeed = 1
Particles.intensity = 1
Particles.enabled = true
Particles.stats = { live = 0, meshes = 0, draws = 0, dropped = 0 }

local live = {}          -- active particles (unordered; swap-removed)
local freeByShape = {}   -- shape -> { entry }
local liveByShape = {}   -- shape -> count, for recycle decisions
local entries = {}       -- every entry ever created, for destroyAll
local geometry = {}
local sprites = {}       -- path -> LuauTexture | false (false = tried and failed)
local lights = {}
local meshSpawnFailed = false

--------------------------------------------------------------------------------
-- Geometry. Everything is double-sided: both windings are emitted, so the
-- "winding is swapped for Unreal" trap can't make a particle invisible.
--------------------------------------------------------------------------------

-- Push both windings of quad a-b-c-d. Indices are 0-BASED (mesh.triangles is not
-- 1-indexed like the rest of Luau).
local function pushQuad(t, a, b, c, d)
    table.insert(t, a); table.insert(t, c); table.insert(t, b)
    table.insert(t, a); table.insert(t, d); table.insert(t, c)
    table.insert(t, a); table.insert(t, b); table.insert(t, c)
    table.insert(t, a); table.insert(t, c); table.insert(t, d)
end

local function pushTri(t, a, b, c)
    table.insert(t, a); table.insert(t, c); table.insert(t, b)
    table.insert(t, a); table.insert(t, b); table.insert(t, c)
end

-- Unit quad in the YZ plane (normal along X) so a camera-facing rotation points it at us.
local function buildQuad()
    local v = { Vec3.new(0, -1, -1), Vec3.new(0, 1, -1), Vec3.new(0, 1, 1), Vec3.new(0, -1, 1) }
    local uv = { Vec2.new(0, 1), Vec2.new(1, 1), Vec2.new(1, 0), Vec2.new(0, 0) }
    local n = { Vec3.new(-1, 0, 0), Vec3.new(-1, 0, 0), Vec3.new(-1, 0, 0), Vec3.new(-1, 0, 0) }
    local t = {}
    pushQuad(t, 0, 1, 2, 3)
    return { vertices = v, triangles = t, normals = n, uvs = uv }
end

-- Tapered spike along +X. Scale x = length, y/z = width. Used for debris and streaks.
local function buildShard()
    local r = 0.35
    local v = {
        Vec3.new(1, 0, 0),
        Vec3.new(0, r, 0),
        Vec3.new(0, -r * 0.5, r * 0.866),
        Vec3.new(0, -r * 0.5, -r * 0.866),
    }
    local n = { Vec3.new(1, 0, 0), Vec3.new(0, 1, 0), Vec3.new(0, -0.5, 0.866), Vec3.new(0, -0.5, -0.866) }
    local uv = { Vec2.new(0.5, 0), Vec2.new(0, 1), Vec2.new(1, 1), Vec2.new(0.5, 1) }
    local t = {}
    pushTri(t, 0, 1, 2); pushTri(t, 0, 2, 3); pushTri(t, 0, 3, 1); pushTri(t, 1, 3, 2)
    return { vertices = v, triangles = t, normals = n, uvs = uv }
end

-- Flat annulus of outer radius 1 in the YZ plane. Scale y/z to grow the shockwave.
local function buildRing(segments, inner)
    local v, n, uv, t = {}, {}, {}, {}
    for i = 0, segments - 1 do
        local a = (i / segments) * 2 * math.pi
        local c, s = math.cos(a), math.sin(a)
        table.insert(v, Vec3.new(0, c * inner, s * inner))
        table.insert(v, Vec3.new(0, c, s))
        table.insert(n, Vec3.new(-1, 0, 0)); table.insert(n, Vec3.new(-1, 0, 0))
        local u = i / segments
        table.insert(uv, Vec2.new(u, 0)); table.insert(uv, Vec2.new(u, 1))
    end
    for i = 0, segments - 1 do
        local j = (i + 1) % segments
        pushQuad(t, i * 2, i * 2 + 1, j * 2 + 1, j * 2)
    end
    return { vertices = v, triangles = t, normals = n, uvs = uv }
end

geometry.quad  = buildQuad()
geometry.shard = buildShard()
geometry.ring  = buildRing(56, 0.88)
geometry.disc  = buildRing(40, 0.0)

--------------------------------------------------------------------------------
-- Sprites
--------------------------------------------------------------------------------

function Particles.sprite(path)
    if sprites[path] ~= nil then
        return sprites[path] or nil
    end
    local ok, tex = pcall(LuauFile.loadTexture, path)
    if not ok or tex == nil then
        sprites[path] = false
        warn("casterfx: could not load sprite " .. path)
        return nil
    end
    sprites[path] = tex
    return tex
end

function Particles.clearSpriteCache()
    sprites = {}
end

--------------------------------------------------------------------------------
-- Pool
--------------------------------------------------------------------------------

local function createEntry(shape)
    if meshSpawnFailed or #entries >= Particles.maxMeshes then return nil end
    local mesh = WorldDraw.spawnMesh()
    if mesh == nil then
        meshSpawnFailed = true
        issue("casterfx: WorldDraw.spawnMesh() returned nil; particle pool capped at " .. #entries)
        return nil
    end
    local g = geometry[shape]
    mesh.vertices = g.vertices
    mesh.triangles = g.triangles
    mesh.normals = g.normals
    mesh.uVs = g.uvs
    mesh.color = LinearColor.White
    mesh.position = Vec3.zeroVector
    mesh.scale = Vec3.zeroVector
    mesh:draw()
    Particles.stats.draws += 1
    local entry = { mesh = mesh, shape = shape, color = LinearColor.White, texture = false }
    table.insert(entries, entry)
    return entry
end

-- Hide a mesh: there is no visibility flag, so scale it to nothing.
local function park(entry)
    entry.mesh.scale = Vec3.zeroVector
end

local function release(p)
    park(p.entry)
    liveByShape[p.shape] = (liveByShape[p.shape] or 1) - 1
    local fl = freeByShape[p.shape]
    if not fl then fl = {}; freeByShape[p.shape] = fl end
    table.insert(fl, p.entry)
end

-- Oldest live particle of this shape, so a burst that exceeds the budget recycles
-- its own tail rather than dropping the new (more visible) particles.
local function stealOldest(shape)
    local bestIdx, bestAge = nil, -1
    for i, p in live do
        if p.shape == shape and p.age > bestAge then bestAge = p.age; bestIdx = i end
    end
    if not bestIdx then return nil end
    local p = live[bestIdx]
    local entry = p.entry
    liveByShape[shape] = (liveByShape[shape] or 1) - 1
    live[bestIdx] = live[#live]
    table.remove(live)
    Particles.stats.dropped += 1
    return entry
end

local function acquire(shape)
    local fl = freeByShape[shape]
    if fl and #fl > 0 then
        local e = fl[#fl]
        table.remove(fl)
        return e
    end
    local e = createEntry(shape)
    if e then return e end
    return stealOldest(shape)
end

--------------------------------------------------------------------------------
-- Spawning
--------------------------------------------------------------------------------

-- p fields (all optional except shape/position):
--   shape        "quad" | "shard" | "ring" | "disc"
--   position     Vec3
--   velocity     Vec3         cm/s
--   color        LinearColor  ignored when texture is set
--   texture      LuauTexture
--   size         Vec3         local half-extents before curves
--   life         seconds
--   gravity      cm/s^2 along -up
--   drag         per-second exponential damping
--   bounce       reflect off geometry via raycast
--   restitution  bounce energy kept (default 0.5)
--   facing       "billboard" | "velocity" | "fixed" | "spin"
--   rotation     Quat, used by "fixed" and as the base for "spin"
--   spin         Vec3 of euler degrees/second, used by "spin"
--   roll         starting roll degrees, used by "billboard"
--   rollSpeed    degrees/second, used by "billboard"
--   growFrom     size multiplier at birth (default 1)
--   growTo       size multiplier at death (default 1)
function Particles.spawn(p)
    if not Particles.enabled then return nil end
    local shape = p.shape or "quad"
    if not geometry[shape] then
        warn("casterfx: unknown particle shape " .. tostring(shape))
        return nil
    end
    local entry = acquire(shape)
    if not entry then return nil end

    local needDraw = false
    local tex = p.texture
    if tex ~= nil then
        if entry.texture ~= tex then
            entry.mesh.texture = tex
            entry.texture = tex
            needDraw = true
        end
    else
        if entry.texture ~= false then
            entry.mesh.texture = nil
            entry.texture = false
            needDraw = true
        end
        local col = p.color or LinearColor.White
        if not Util.colorEquals(entry.color, col) then
            entry.mesh.color = col
            entry.color = col
            needDraw = true
        end
    end
    if needDraw then
        entry.mesh:draw()
        Particles.stats.draws += 1
    end

    local particle = {
        entry = entry,
        shape = shape,
        position = p.position,
        velocity = p.velocity or Vec3.zeroVector,
        size = p.size or Vec3.oneVector,
        life = math.max(p.life or 1, 0.05),
        age = 0,
        gravity = p.gravity or 0,
        drag = p.drag or 0,
        bounce = p.bounce == true,
        restitution = p.restitution or 0.5,
        facing = p.facing or "billboard",
        rotation = p.rotation or Quat.identity,
        spin = p.spin or Vec3.zeroVector,
        roll = p.roll or 0,
        rollSpeed = p.rollSpeed or 0,
        growFrom = p.growFrom or 1,
        growTo = p.growTo or 1,
    }
    liveByShape[shape] = (liveByShape[shape] or 0) + 1
    table.insert(live, particle)
    return particle
end

-- A point light that decays. Real light on the arena walls sells an explosion more
-- than any number of quads.
function Particles.flash(position, color, intensity, radius, life)
    local light = WorldDraw.spawnPointLight(position, intensity, Vec3.new(color.R, color.G, color.B), radius)
    if not light then return nil end
    table.insert(lights, { light = light, age = 0, life = life, intensity = intensity })
    return light
end

--------------------------------------------------------------------------------
-- Update
--------------------------------------------------------------------------------

-- Shrink-out tail over the last 25% of life, so nothing pops out of existence
-- (cutout alpha can't cross-fade).
local function tail(t)
    return Util.smoothstep(math.min((1 - t) / 0.25, 1))
end

function Particles.update(dt)
    dt = dt * Particles.simSpeed
    if dt <= 0 then return end

    local camRot = camera.rotation
    local up = gravity.strength > 0 and gravity.upDirection or Vec3.upVector

    local i = 1
    while i <= #live do
        local p = live[i]
        p.age += dt
        local t = p.age / p.life
        if t >= 1 then
            release(p)
            live[i] = live[#live]
            table.remove(live)
        else
            if p.gravity ~= 0 then p.velocity = p.velocity - up * (p.gravity * dt) end
            if p.drag > 0 then p.velocity = p.velocity * math.exp(-p.drag * dt) end

            local nextPos = p.position + p.velocity * dt
            if p.bounce then
                local hit = camera:castRay(p.position, nextPos)
                if hit and hit.successful then
                    local n = hit.normal
                    p.velocity = (p.velocity - n * (2 * p.velocity:dot(n))) * p.restitution
                    nextPos = hit.position + n * 2
                end
            end
            p.position = nextPos

            local mesh = p.entry.mesh
            mesh.position = p.position
            local mul = Util.lerp(p.growFrom, p.growTo, Util.easeOutCubic(t)) * tail(t)
            mesh.scale = p.size * mul

            if p.facing == "billboard" then
                mesh.rotation = camRot * Quat.fromEuler(p.roll + p.rollSpeed * p.age, 0, 0)
            elseif p.facing == "velocity" then
                local dir = p.velocity:getSafeNormal()
                if dir:length() > 0.001 then
                    mesh.rotation = Quat.fromXZ(dir, up)
                end
            elseif p.facing == "spin" then
                mesh.rotation = p.rotation * Quat.fromEuler(
                    p.spin.x * p.age, p.spin.y * p.age, p.spin.z * p.age)
            else
                mesh.rotation = p.rotation
            end

            i += 1
        end
    end

    local li = 1
    while li <= #lights do
        local l = lights[li]
        l.age += dt
        if l.age >= l.life then
            l.light:destroy()
            lights[li] = lights[#lights]
            table.remove(lights)
        else
            l.light.intensity = l.intensity * (1 - l.age / l.life) ^ 2
            li += 1
        end
    end

    Particles.stats.live = #live
    Particles.stats.meshes = #entries
end

function Particles.clear()
    for _, p in live do release(p) end
    live = {}
    for _, l in lights do l.light:destroy() end
    lights = {}
end

function Particles.destroyAll()
    Particles.clear()
    for _, e in entries do e.mesh:destroy() end
    entries = {}
    freeByShape = {}
    liveByShape = {}
    sprites = {}
    meshSpawnFailed = false
    Particles.stats = { live = 0, meshes = 0, draws = 0, dropped = 0 }
end

--------------------------------------------------------------------------------
-- Self-test: asserts the invariants that are easy to get wrong and impossible to
-- eyeball (0-based indices, index range, UV/normal counts, pool accounting).
-- Wired to a button in the Debug tab.
--------------------------------------------------------------------------------

function Particles.selfTest()
    local problems = {}
    local function check(cond, msg)
        if not cond then table.insert(problems, msg) end
    end

    for name, g in pairs(geometry) do
        local vn = #g.vertices
        check(vn > 0, name .. ": no vertices")
        check(#g.normals == vn, name .. ": normals " .. #g.normals .. " ~= vertices " .. vn)
        check(#g.uvs == vn, name .. ": uvs " .. #g.uvs .. " ~= vertices " .. vn)
        check(#g.triangles % 3 == 0, name .. ": triangle list not a multiple of 3")
        local minI, maxI = math.huge, -1
        for _, idx in g.triangles do
            if idx < minI then minI = idx end
            if idx > maxI then maxI = idx end
        end
        -- mesh.triangles is 0-based: index 0 must be used, and vn must never appear.
        check(minI == 0, name .. ": min index " .. minI .. " (expected 0, list is 0-based)")
        check(maxI == vn - 1, name .. ": max index " .. maxI .. " (expected " .. (vn - 1) .. ")")
    end

    -- Force a known state: the test asserts on exact lifetimes, and a user's
    -- sim-speed or an off toggle would make it fail for the wrong reason.
    local wasEnabled, wasSpeed = Particles.enabled, Particles.simSpeed
    Particles.enabled, Particles.simSpeed = true, 1

    local before = #live
    local p = Particles.spawn({
        shape = "shard", position = Vec3.zeroVector, life = 0.1,
        color = LinearColor.new(1, 0, 0, 1), size = Vec3.oneVector,
    })
    check(p ~= nil, "spawn returned nil")
    check(#live == before + 1, "live count did not increase on spawn")
    if p then
        Particles.update(0.2) -- outlives it
        check(#live == before, "particle was not released after its life expired")
        check(p.entry.mesh.scale:isNearlyZero(), "released mesh was not parked at zero scale")
    end

    Particles.enabled, Particles.simSpeed = wasEnabled, wasSpeed

    if #problems == 0 then
        print("casterfx selftest: PASS (" .. #entries .. " meshes pooled)")
        return true, "PASS"
    end
    for _, msg in problems do issue("casterfx selftest: " .. msg) end
    return false, #problems .. " failure(s), see Camera Logs"
end

return Particles
