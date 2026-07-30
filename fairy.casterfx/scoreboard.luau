-- Scoreboard: static team-logo quads anchored to the arena, for covering the in-game
-- scoreboard crests. Arenas have two scoreboards, so the default is four slots
-- (two boards x home/away), and the count is editable per profile.
--
-- Named scoreboard, not logos, because `require("logos")` resolves to the logos/ ASSET
-- FOLDER rather than to this file. Do not rename it back.
--
-- Placement is per profile, per arena type, and edited live in the GUI, because the
-- scoreboard offsets are not exposed anywhere in the API and differ per gamemode. Fly the
-- debug freecam up to a board and drag the sliders.
--
-- The camera cannot reach the internet (there is no HTTP client in the Luau API), so images
-- must already be in logos/. get-logos.ps1 puts them there, either from the ODC API or by
-- importing whatever OD Caster Bridge already has.

local Util = require("util")
local Profiles = require("profiles")

local Scoreboard = {}

local meshes = {}      -- slot index -> { mesh, texturePath, flipU, flipV, needDraw }
local textures = {}    -- path -> LuauTexture | false
local fileList = {}
local lastWanted = ""

Scoreboard.status = {}   -- slot index -> reason string

--------------------------------------------------------------------------------
-- Files
--------------------------------------------------------------------------------

local function isImage(path)
    local lower = string.lower(path)
    return string.sub(lower, -4) == ".png" or string.sub(lower, -4) == ".jpg"
        or string.sub(lower, -5) == ".jpeg"
end

function Scoreboard.rescan()
    fileList = {}
    textures = {}
    local ok, files = pcall(LuauFile.listFiles, "logos")
    if ok and files ~= nil then
        for _, f in files do
            if isImage(f) then table.insert(fileList, f) end
        end
    end
    table.sort(fileList)
    for _, m in pairs(meshes) do m.texturePath = nil end
    return fileList
end

function Scoreboard.files()
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

-- listFiles paths may or may not carry the folder prefix, so match on the filename tail.
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

local function hasFile(path)
    for _, f in fileList do
        if f == path then return true end
    end
    return false
end

--------------------------------------------------------------------------------
-- Which image goes on which slot
--------------------------------------------------------------------------------

-- Order matters. HOME/AWAY beats the team name on purpose: an ordinary lobby reports the
-- SAME teamName for both sides, so a name-keyed lookup would put one crest on both boards.
-- Caster Bridge stores its logos by side, and get-logos.ps1 -FromBridge writes them here as
-- HOME.png / AWAY.png, which is unambiguous.
local function resolvePath(side, teamName)
    local profile = Profiles.active()
    local override = profile.logoOverride and profile.logoOverride[side]
    if override and override ~= "" then
        return override, hasFile(override) and "override" or "override (missing?)"
    end

    local bySide = findFile(string.upper(side))
    if bySide then return bySide, "side: " .. string.upper(side) end

    if teamName == nil or teamName == "" then return nil, "no logo for " .. side end
    local stem = Util.sanitizeTeamName(teamName)
    local found = findFile(stem)
    if found then return found, "team: " .. stem end
    return nil, "missing " .. stem .. ".png"
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

local function ensureMesh(index, slot)
    local m = meshes[index]
    if m == nil then
        local mesh = WorldDraw.spawnMesh()
        if mesh == nil then
            issue("casterfx: spawnMesh() returned nil, cannot show logo slot " .. index)
            return nil
        end
        m = { mesh = mesh, texturePath = nil, flipU = nil, flipV = nil, needDraw = true }
        meshes[index] = m
    end
    if m.flipU ~= slot.flipU or m.flipV ~= slot.flipV then
        local v, t, n, uv = buildQuad(slot.flipU, slot.flipV)
        m.mesh.vertices = v; m.mesh.triangles = t; m.mesh.normals = n; m.mesh.uVs = uv
        m.flipU = slot.flipU; m.flipV = slot.flipV
        m.needDraw = true
    end
    return m
end

local function hide(index)
    local m = meshes[index]
    if m then m.mesh.scale = Vec3.zeroVector end
end

--------------------------------------------------------------------------------
-- Update
--------------------------------------------------------------------------------

local function updateSlot(index, slot, match)
    local team = slot.side == "home" and match.home or match.away
    if not slot.enabled then
        hide(index)
        Scoreboard.status[index] = "hidden"
        return
    end

    local path, why = resolvePath(slot.side, team and team.name)
    Scoreboard.status[index] = why
    if path == nil then
        hide(index)
        return
    end

    local m = ensureMesh(index, slot)
    if m == nil then return end

    if m.texturePath ~= path then
        local tex = loadTexture(path)
        if tex == nil then
            hide(index)
            Scoreboard.status[index] = "load failed: " .. path
            return
        end
        m.mesh.texture = tex
        m.texturePath = path
        m.needDraw = true
    end

    local rot = match.transform.rotation
    m.mesh.position = match.transform.position + rot:rotateVector(Vec3.new(slot.x, slot.y, slot.z))
    if slot.faceCamera then
        m.mesh.rotation = camera.rotation
    else
        m.mesh.rotation = rot * Quat.fromEuler(slot.roll, slot.pitch, slot.yaw)
    end
    -- x is the quad normal, so only y/z carry size.
    m.mesh.scale = Vec3.new(1, slot.width * 0.5, slot.height * 0.5)

    -- Draw AFTER the transform is set. A mesh first drawn at zero scale appears to stay
    -- invisible for good, which is the same trap the particle pool hit.
    if m.needDraw then
        m.mesh:draw()
        m.needDraw = false
    end
end

function Scoreboard.update(match, enabled)
    if match == nil or enabled == false then
        for index in pairs(meshes) do hide(index) end
        return
    end
    local slots = Profiles.slots(match.type, match.arenaHeight)
    for index, slot in slots do
        updateSlot(index, slot, match)
    end
    -- Slots removed from the profile leave their mesh behind; park it.
    for index in pairs(meshes) do
        if slots[index] == nil then hide(index) end
    end
end

--------------------------------------------------------------------------------
-- wanted.json -- the handshake with get-logos.ps1
--------------------------------------------------------------------------------

function Scoreboard.writeWanted(match)
    if match == nil then return end
    local home = match.home and match.home.name or ""
    local away = match.away and match.away.name or ""
    if home == "" and away == "" then return end
    local key = home .. "\0" .. away
    if key == lastWanted then return end
    lastWanted = key

    -- Both sides frequently report the SAME teamName (it is the in-game team name, not the
    -- ODC one, and an ordinary lobby leaves both at the station default). Deduplicate so the
    -- fetcher isn't asked for the same crest twice.
    local teams, stems, seen = {}, {}, {}
    for _, name in { home, away } do
        if name ~= "" and not seen[name] then
            seen[name] = true
            table.insert(teams, name)
            table.insert(stems, Util.sanitizeTeamName(name))
        end
    end

    local payload = {
        teams = teams,
        stems = stems,
        slotId = match.slotId,
        ambiguous = home == away,
    }
    local text = LuauJson.serialize(payload, true)
    if text == "" then return end
    LuauFile.saveText("wanted.json", text)
end

function Scoreboard.destroy()
    for _, m in pairs(meshes) do m.mesh:destroy() end
    meshes = {}
    textures = {}
    Scoreboard.status = {}
    lastWanted = ""
end

return Scoreboard
