-- Profiles: named setting sets, because Orion Drift has several competitive arenas and
-- each one wants its own framing and its own logo placement.
--
-- A profile owns camera settings, VFX settings, and per-arena-type logo slots. Modules read
-- from Profiles.active() rather than from `config` directly, so switching profile switches
-- everything at once with no copying.
--
-- config.bindings maps a gamemode slotId ("Beta 01") to a profile name, so walking into an
-- arena can select its profile automatically.

local Profiles = {}

-- Single source of truth for defaults. Adding a key here makes it appear in every existing
-- profile on next load, via ensureShape below.
Profiles.cameraDefaults = {
    enabled = true,
    sideDistance = 2600,
    lengthLimit = 2200,
    heightOffset = 220,
    maxHeight = 1250,
    minHeightAboveGround = 130,
    riserScale = 1.0,
    hookScale = 1.0,

    -- Side switching. "smooth" slides the dolly across; "cut" jumps.
    switchMode = "smooth",
    switchThreshold = 400,
    switchSeconds = 0.9,
    switchDwell = 2.5,

    lead = 0.45,
    -- Our own damping of the dolly/aim targets, on top of the engine's smoothing. This is
    -- what removes the jitter; engine smoothing alone was chasing a noisy target.
    followSpeed = 6.0,
    aimSpeed = 10.0,
    positionSmoothing = 0.12,
    rotationSmoothing = 0.08,
    fovSmoothing = 0.25,

    -- Auto zoom frames the ACTION (ball plus nearby players), not the ball. Framing a 35cm
    -- ball at any sane screen fraction from 26m away asks for a ~5 degree FOV, which is why
    -- this used to sit pinned at fovMin.
    autoZoom = true,
    zoomFraction = 0.7,
    subjectMin = 2000,
    subjectMax = 4200,
    subjectPadding = 1.25,
    fovMin = 60,
    fovMax = 130,
    fovFixed = 90,
}

Profiles.vfxDefaults = {
    enabled = true,
    intensity = 1.0,
    simSpeed = 1.0,
    sizeScale = 1.0,
    maxParticles = 900,
    -- How far past 1 team colours are pushed before being drawn. Values above 1 bloom, and
    -- that glow is the entire difference between a satisfying particle and a coloured stick.
    hdrBoost = 20,

    goalEnabled = true,
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
    impactThreshold = 900,
}

local SCOREBOARD_COUNT = 2

-- Two scoreboards, two teams each. Placeholder positions only: the real offsets are not
-- exposed anywhere in the API, so these just need to be findable in the freecam.
function Profiles.defaultSlot(index, side, arenaHeight)
    local board = math.ceil(index / 2)
    local sideSign = side == "home" and -1 or 1
    -- Put board 1 toward -Y and board 2 toward +Y so all four start visibly apart.
    local boardSign = board == 1 and -1 or 1
    return {
        name = string.format("Board %d %s", board, side),
        side = side,
        enabled = true,
        x = boardSign * 600,
        y = sideSign * 340,
        z = (arenaHeight or 1440) * 0.62,
        pitch = 0,
        yaw = boardSign > 0 and 180 or 0,
        roll = 0,
        width = 260,
        height = 260,
        faceCamera = false,
        flipU = false,
        flipV = false,
    }
end

function Profiles.defaultSlots(arenaHeight)
    local slots = {}
    for board = 1, SCOREBOARD_COUNT do
        for _, side in { "home", "away" } do
            local index = #slots + 1
            slots[index] = Profiles.defaultSlot(index, side, arenaHeight)
        end
    end
    return slots
end

-- Fill in missing keys without touching values the user has already set.
local function ensureShape(defaults, target)
    for k, v in pairs(defaults) do
        if target[k] == nil or typeof(target[k]) ~= typeof(v) then
            target[k] = v
        end
    end
end

function Profiles.newProfile(arenaHeight)
    local p = { camera = {}, vfx = {}, arenas = {}, logoOverride = {} }
    ensureShape(Profiles.cameraDefaults, p.camera)
    ensureShape(Profiles.vfxDefaults, p.vfx)
    return p
end

function Profiles.ensure()
    if typeof(config.profiles) ~= "table" then config.profiles = {} end
    if typeof(config.bindings) ~= "table" then config.bindings = {} end

    local any = false
    for _ in pairs(config.profiles) do any = true; break end
    if not any then config.profiles["Default"] = Profiles.newProfile() end

    for _, p in pairs(config.profiles) do
        if typeof(p.camera) ~= "table" then p.camera = {} end
        if typeof(p.vfx) ~= "table" then p.vfx = {} end
        if typeof(p.arenas) ~= "table" then p.arenas = {} end
        if typeof(p.logoOverride) ~= "table" then p.logoOverride = {} end
        ensureShape(Profiles.cameraDefaults, p.camera)
        ensureShape(Profiles.vfxDefaults, p.vfx)
    end

    if config.activeProfile == nil or config.profiles[config.activeProfile] == nil then
        config.activeProfile = Profiles.names()[1]
    end
end

function Profiles.names()
    local names = {}
    for name in pairs(config.profiles) do table.insert(names, name) end
    table.sort(names)
    return names
end

function Profiles.active()
    Profiles.ensure()
    return config.profiles[config.activeProfile]
end

function Profiles.select(name)
    if config.profiles[name] then config.activeProfile = name end
end

function Profiles.create(name, copyFrom)
    if name == nil or name == "" or config.profiles[name] then return false end
    if copyFrom and config.profiles[copyFrom] then
        -- Deep copy, so editing the new profile cannot reach back into the old one.
        local function deepCopy(t)
            local out = {}
            for k, v in pairs(t) do
                out[k] = typeof(v) == "table" and deepCopy(v) or v
            end
            return out
        end
        config.profiles[name] = deepCopy(config.profiles[copyFrom])
    else
        config.profiles[name] = Profiles.newProfile()
    end
    config.activeProfile = name
    return true
end

function Profiles.delete(name)
    if config.profiles[name] == nil then return false end
    if #Profiles.names() <= 1 then return false end   -- never leave zero profiles
    config.profiles[name] = nil
    for slotId, bound in pairs(config.bindings) do
        if bound == name then config.bindings[slotId] = nil end
    end
    if config.activeProfile == name then config.activeProfile = Profiles.names()[1] end
    return true
end

function Profiles.rename(from, to)
    if config.profiles[from] == nil or to == nil or to == "" or config.profiles[to] then
        return false
    end
    config.profiles[to] = config.profiles[from]
    config.profiles[from] = nil
    for slotId, bound in pairs(config.bindings) do
        if bound == from then config.bindings[slotId] = to end
    end
    if config.activeProfile == from then config.activeProfile = to end
    return true
end

-- Logo slots for one arena type within the active profile.
function Profiles.slots(arenaType, arenaHeight)
    local p = Profiles.active()
    local key = arenaType or "unknown"
    if typeof(p.arenas[key]) ~= "table" or typeof(p.arenas[key].slots) ~= "table"
        or #p.arenas[key].slots == 0 then
        p.arenas[key] = { slots = Profiles.defaultSlots(arenaHeight) }
    end
    return p.arenas[key].slots
end

function Profiles.resetSlots(arenaType, arenaHeight)
    local p = Profiles.active()
    p.arenas[arenaType or "unknown"] = { slots = Profiles.defaultSlots(arenaHeight) }
end

function Profiles.bindingFor(slotId)
    if slotId == nil then return nil end
    return config.bindings[slotId]
end

function Profiles.bind(slotId, profileName)
    if slotId == nil then return end
    if profileName == nil then
        config.bindings[slotId] = nil
    elseif config.profiles[profileName] then
        config.bindings[slotId] = profileName
    end
end

return Profiles
