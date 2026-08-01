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
    goalOutline = true,
    -- Calibration for the goal silhouette. The outline geometry is measured in the goal's own
    -- frame, but this package derives goalRotation differently from where the numbers came
    -- from, and the shape is asymmetric top-to-bottom -- so a wrong frame reads as upside
    -- down. Nobody can check that from the code, hence a knob rather than a fixed constant.
    goalOutlineRoll = 0,
    goalOutlinePitch = 0,
    goalOutlineYaw = 0,
    -- The per-arena-type goalOffset is close but not exact on every map, so the silhouette
    -- gets its own nudge in the arena frame (x along the pitch, y across, z up).
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

local function deepCopy(t)
    local out = {}
    for k, v in pairs(t) do
        out[k] = typeof(v) == "table" and deepCopy(v) or v
    end
    return out
end

-- Scale a reference arena's dialed-in slots onto a differently-sized arena. Only x/y/z move;
-- everything else (rotation, on-screen size, flips) carries over unchanged since those are
-- about the logo image, not the arena.
local function scaledFromReference(reference, arenaHeight)
    local ratio = arenaHeight / reference.height
    local slots = {}
    for index, slot in reference.slots do
        local copy = deepCopy(slot)
        copy.x, copy.y, copy.z = slot.x * ratio, slot.y * ratio, slot.z * ratio
        slots[index] = copy
    end
    return slots
end

function Profiles.defaultSlots(arenaHeight, reference)
    if reference and typeof(reference.slots) == "table" and reference.height then
        return scaledFromReference(reference, arenaHeight)
    end
    local slots = {}
    for board = 1, SCOREBOARD_COUNT do
        for _, side in { "home", "away" } do
            local index = #slots + 1
            slots[index] = Profiles.defaultSlot(index, side, arenaHeight)
        end
    end
    return slots
end

-- Capture the currently-tuned slots for one arena type as the template new arena types seed
-- from, scaled by height ratio, instead of the generic placeholder positions.
function Profiles.saveReference(arenaType, arenaHeight)
    local p = Profiles.active()
    local arena = p.arenas[arenaType or "unknown"]
    if typeof(arena) ~= "table" or typeof(arena.slots) ~= "table" then return false end
    p.reference = { height = arenaHeight, slots = deepCopy(arena.slots) }
    return true
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

-- Both slots and models live side by side under the same arena-type entry, so getters must
-- patch in their own key rather than replacing the whole entry (that would wipe the other).
local function arenaEntry(p, arenaType)
    local key = arenaType or "unknown"
    if typeof(p.arenas[key]) ~= "table" then p.arenas[key] = {} end
    return p.arenas[key]
end

-- Logo slots for one arena type within the active profile.
function Profiles.slots(arenaType, arenaHeight)
    local p = Profiles.active()
    local arena = arenaEntry(p, arenaType)
    if typeof(arena.slots) ~= "table" or #arena.slots == 0 then
        arena.slots = Profiles.defaultSlots(arenaHeight, p.reference)
    end
    return arena.slots
end

function Profiles.resetSlots(arenaType, arenaHeight)
    local p = Profiles.active()
    arenaEntry(p, arenaType).slots = Profiles.defaultSlots(arenaHeight, p.reference)
end

-- Custom .glb/.gltf model placements for one arena type, same arena-relative convention as
-- logo slots (x/y/z and pitch/yaw/roll in the arena's local frame).
--
-- Module-level rather than built per call: Profiles.models runs this over every entry every
-- frame to backfill keys, and rebuilding the table each time would allocate for nothing.
Profiles.modelDefaults = {
    file = "",
    name = "Model",
    enabled = true,
    -- "arena" anchors to the arena frame (existing behaviour); "ball" anchors to a live
    -- ball instead, so x/y/z/pitch/yaw/roll become ball-relative.
    followMode = "arena",
    -- Which ball, when followMode is "ball". -1 = whichever is closest to the arena
    -- centre (what Match:findBall picks); otherwise a specific ReplayBall.index.
    ballIndex = -1,
    -- Measured from a real match: the ball tumbles at ~400 deg/s (median) about a stable
    -- axis. Right for a prop, unreadable for a crest -- so following that spin is opt-out.
    spinWithBall = true,
    -- Billboard to the camera, same idea as the logo slots. Always readable.
    faceCamera = false,
    x = 0, y = 0, z = 200,
    pitch = 0, yaw = 0, roll = 0,
    scale = 100,
    textureOverride = "",
}

function Profiles.defaultModel()
    local out = {}
    ensureShape(Profiles.modelDefaults, out)
    return out
end

function Profiles.models(arenaType)
    local p = Profiles.active()
    local arena = arenaEntry(p, arenaType)
    if typeof(arena.models) ~= "table" then arena.models = {} end
    -- Backfill keys added after these entries were saved. Without this, a placement stored
    -- before a new option existed hands nil to that option's GUI widget, which then writes
    -- the wrong value back the first time it renders.
    for _, entry in arena.models do
        ensureShape(Profiles.modelDefaults, entry)
    end
    return arena.models
end

function Profiles.resetModels(arenaType)
    local p = Profiles.active()
    arenaEntry(p, arenaType).models = {}
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
