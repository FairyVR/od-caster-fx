-- Logos: static team-logo quads anchored to the arena, for covering the in-game
-- scoreboard crests.
--
-- Placement is config-driven per arena type and edited live in the GUI, because the
-- scoreboard offset is not exposed anywhere in the API and differs per gamemode.
-- Nudge each slot into place once, hit Save, done.
--
-- The camera script cannot reach the internet (there is no HTTP client in the Luau API),
-- so images have to already be in logos/. get-logos.ps1 puts them there; this module
-- writes wanted.json with the team names it detected so that script knows what to fetch.

local Util = require("util")

local Logos = {}

local meshes = {}      -- "home" | "away" -> { mesh, texturePath }
local textures = {}    -- path -> LuauTexture | false
local fileList = {}
local lastWanted = ""

Logos.status = { home = "", away = "" }

--------------------------------------------------------------------------------
-- Files
--------------------------------------------------------------------------------

local function isImage(path)
    local lower = string.lower(path)
    return string.sub(lower, -4) == ".png" or string.sub(lower, -4) == ".jpg"
        or string.sub(lower, -5) == ".jpeg"
end

function Logos.rescan()
    fileList = {}
    textures = {}
    local ok, files = pcall(LuauFile.listFiles, "logos")
    if not ok or files == nil then
        -- listFiles on a missing folder: treat as empty rather than erroring out.
        return fileList
    end
    for _, f in files do
        if isImage(f) then table.insert(fileList, f) end
    end
    table.sort(fileList)
    -- Force a reload of whatever is currently applied.
    for _, m in pairs(meshes) do m.texturePath = nil end
    return fileList
end

function Logos.files()
    return fileList
end

local function loadTexture(path)
    if textures[path] ~= nil then return textures[path] or nil end
    local ok, tex = pcall(LuauFile.loadTexture, path)
    if not ok or tex == nil then
        textures[path] = false
        warn("casterfx: failed to load logo " .. path)
        return nil
    end
    textures[path] = tex
    return tex
end

-- listFiles returns paths that may or may not carry the folder prefix depending on
-- what was passed in, so match on the tail rather than assuming a shape.
local function findFile(stem)
    local want = string.lower(stem)
    for _, f in fileList do
        local lower = string.lower(f)
        local base = string.match(lower, "([^/\\]+)$") or lower
        local noExt = string.gsub(base, "%.%a+$", "")
        if noExt == want then return f end
    end
    return nil
end

--------------------------------------------------------------------------------
-- Slots
--------------------------------------------------------------------------------

-- A slot is flat numbers so every field is a slider and the config stays JSON-simple.
function Logos.defaultSlot(side, arenaHeight)
    local sign = side == "home" and -1 or 1
    return {
        enabled = true,
        x = 0,
        y = sign * 340,
        z = (arenaHeight or 1440) * 0.62,
        pitch = 0,
        yaw = 0,
        roll = 0,
        width = 260,
        height = 260,
        faceCamera = false,
        flipU = false,
        flipV = false,
    }
end

function Logos.slotsFor(arenaType, arenaHeight)
    if config.logoSlots == nil then config.logoSlots = {} end
    local key = arenaType or "unknown"
    if config.logoSlots[key] == nil then
        config.logoSlots[key] = {
            home = Logos.defaultSlot("home", arenaHeight),
            away = Logos.defaultSlot("away", arenaHeight),
        }
    end
    return config.logoSlots[key]
end

--------------------------------------------------------------------------------
-- Mesh
--------------------------------------------------------------------------------

-- Double-sided quad in the YZ plane (normal along X) with unit half-extents.
local function buildQuad(flipU, flipV)
    local v = { Vec3.new(0, -1, -1), Vec3.new(0, 1, -1), Vec3.new(0, 1, 1), Vec3.new(0, -1, 1) }
    local u0, u1 = 0, 1
    local v0, v1 = 1, 0
    if flipU then u0, u1 = 1, 0 end
    if flipV then v0, v1 = 0, 1 end
    local uv = { Vec2.new(u0, v0), Vec2.new(u1, v0), Vec2.new(u1, v1), Vec2.new(u0, v1) }
    local n = { Vec3.new(-1, 0, 0), Vec3.new(-1, 0, 0), Vec3.new(-1, 0, 0), Vec3.new(-1, 0, 0) }
    -- 0-based indices, both windings so the quad is never invisible from the front.
    local t = { 0, 2, 1, 0, 3, 2, 0, 1, 2, 0, 2, 3 }
    return v, t, n, uv
end

local function ensureMesh(side, slot)
    local m = meshes[side]
    if m and m.flipU == slot.flipU and m.flipV == slot.flipV then return m end
    if m then
        -- UV flip changes geometry, which needs a redraw anyway; reuse the mesh.
        local v, t, n, uv = buildQuad(slot.flipU, slot.flipV)
        m.mesh.vertices = v; m.mesh.triangles = t; m.mesh.normals = n; m.mesh.uVs = uv
        m.flipU = slot.flipU; m.flipV = slot.flipV
        m.needDraw = true
        return m
    end
    local mesh = WorldDraw.spawnMesh()
    if mesh == nil then
        issue("casterfx: WorldDraw.spawnMesh() returned nil, cannot show " .. side .. " logo")
        return nil
    end
    local v, t, n, uv = buildQuad(slot.flipU, slot.flipV)
    mesh.vertices = v; mesh.triangles = t; mesh.normals = n; mesh.uVs = uv
    mesh.color = LinearColor.White
    mesh.scale = Vec3.zeroVector
    m = { mesh = mesh, texturePath = nil, flipU = slot.flipU, flipV = slot.flipV, needDraw = true }
    meshes[side] = m
    return m
end

local function hide(side)
    local m = meshes[side]
    if m then m.mesh.scale = Vec3.zeroVector end
end

--------------------------------------------------------------------------------
-- Update
--------------------------------------------------------------------------------

local function hasFile(path)
    for _, f in fileList do
        if f == path then return true end
    end
    return false
end

-- Which image should this side use? Manual override wins, then <TEAMNAME>.png.
local function resolvePath(side, teamName)
    local override = config.logoOverride and config.logoOverride[side]
    if override and override ~= "" then
        -- Still returned when absent: listFiles may be stale, and a failed load is cached.
        return override, hasFile(override) and "override" or "override (missing?)"
    end
    if teamName == nil or teamName == "" then return nil, "no team name" end
    local stem = Util.sanitizeTeamName(teamName)
    local found = findFile(stem)
    if found then return found, "auto: " .. stem end
    return nil, "missing " .. stem .. ".png"
end

local function updateSide(side, team, slot, matchTransform)
    if not slot.enabled then
        hide(side)
        Logos.status[side] = "disabled"
        return
    end
    local path, why = resolvePath(side, team and team.name)
    Logos.status[side] = why
    if path == nil then
        hide(side)
        return
    end

    local m = ensureMesh(side, slot)
    if m == nil then return end

    if m.texturePath ~= path then
        local tex = loadTexture(path)
        if tex == nil then
            hide(side)
            Logos.status[side] = "load failed: " .. path
            return
        end
        m.mesh.texture = tex
        m.texturePath = path
        m.needDraw = true
    end
    if m.needDraw then
        m.mesh:draw()
        m.needDraw = false
    end

    local rot = matchTransform.rotation
    m.mesh.position = matchTransform.position + rot:rotateVector(Vec3.new(slot.x, slot.y, slot.z))
    if slot.faceCamera then
        m.mesh.rotation = camera.rotation
    else
        m.mesh.rotation = rot * Quat.fromEuler(slot.roll, slot.pitch, slot.yaw)
    end
    -- x is the quad normal, so only y/z carry size.
    m.mesh.scale = Vec3.new(1, slot.width * 0.5, slot.height * 0.5)
end

function Logos.update(match)
    if match == nil or config.logosEnabled == false then
        hide("home"); hide("away")
        return
    end
    local slots = Logos.slotsFor(match.type, match.arenaHeight)
    updateSide("home", match.home, slots.home, match.transform)
    updateSide("away", match.away, slots.away, match.transform)
end

--------------------------------------------------------------------------------
-- wanted.json -- the handshake with get-logos.ps1
--------------------------------------------------------------------------------

function Logos.writeWanted(match)
    if match == nil then return end
    local home = match.home and match.home.name or ""
    local away = match.away and match.away.name or ""
    if home == "" and away == "" then return end
    local key = home .. "\0" .. away
    if key == lastWanted then return end
    lastWanted = key
    local payload = {
        teams = { home, away },
        stems = { Util.sanitizeTeamName(home), Util.sanitizeTeamName(away) },
        slotId = match.slotId,
    }
    local text = LuauJson.serialize(payload, true)
    if text == "" then return end
    LuauFile.saveText("wanted.json", text)
end

function Logos.destroy()
    for _, m in pairs(meshes) do m.mesh:destroy() end
    meshes = {}
    textures = {}
    lastWanted = ""
end

return Logos
