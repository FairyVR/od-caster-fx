-- Models: custom .glb/.gltf props anchored to the arena, same arena-relative placement as
-- scoreboard logos (Profiles.models stores x/y/z + pitch/yaw/roll in the arena's local frame).
--
-- Drop files in props/ (not models/ -- that name is taken by this module, models.luau, and
-- require("models") would resolve to a models/init.lua folder module instead). Embedded
-- glTF textures apply automatically; an image in props/ can be picked as an override the
-- same way logos/ overrides work for scoreboards.
--
-- Parsing (gltf.luau) is vendored from Entity-B/CustomModels.

local Gltf = require("gltf")
local Util = require("util")
local Profiles = require("profiles")
local Freecam = require("freecam")

local Models = {}

local meshes = {}       -- index -> { mesh, file, texturePath, needDraw }
local fileList = {}
local textureList = {}

Models.status = {}      -- index -> reason string

--------------------------------------------------------------------------------
-- Files
--------------------------------------------------------------------------------

local function matches(path, exts)
    local lower = string.lower(path)
    for _, ext in exts do
        if string.sub(lower, -#ext) == ext then return true end
    end
    return false
end

function Models.rescan()
    fileList = {}
    textureList = {}
    local ok, files = pcall(LuauFile.listFiles, "props")
    if ok and files ~= nil then
        for _, f in files do
            if matches(f, { ".glb", ".gltf" }) then
                table.insert(fileList, f)
            elseif matches(f, { ".png", ".jpg", ".jpeg" }) then
                table.insert(textureList, f)
            end
        end
    end
    table.sort(fileList)
    table.sort(textureList)
    for _, m in pairs(meshes) do m.file = nil end -- force reload against the fresh list
    return fileList
end

function Models.files() return fileList end
function Models.textures() return textureList end

--------------------------------------------------------------------------------
-- Per-file presets
--------------------------------------------------------------------------------

-- A .glb almost never lands in the right place on import: it is authored at metres instead
-- of centimetres, or Z-up instead of Y-up, or off its own origin. That correction belongs to
-- the FILE, not to the arena or the profile -- so presets are keyed by filename and shared
-- across every profile and arena. Pick the file again anywhere and it lands correctly.
local PRESET_KEYS = { "x", "y", "z", "pitch", "yaw", "roll", "scale" }

local function presetStore()
    if typeof(config.modelPresets) ~= "table" then config.modelPresets = {} end
    return config.modelPresets
end

function Models.hasPreset(file)
    return file ~= "" and presetStore()[file] ~= nil
end

function Models.savePreset(entry)
    if entry.file == "" then return false end
    local p = {}
    for _, k in PRESET_KEYS do p[k] = entry[k] end
    p.textureOverride = entry.textureOverride
    presetStore()[entry.file] = p
    return true
end

function Models.applyPreset(entry)
    local p = presetStore()[entry.file]
    if p == nil then return false end
    for _, k in PRESET_KEYS do
        if typeof(p[k]) == "number" then entry[k] = p[k] end
    end
    if typeof(p.textureOverride) == "string" then entry.textureOverride = p.textureOverride end
    return true
end

function Models.forgetPreset(file)
    presetStore()[file] = nil
end

--------------------------------------------------------------------------------
-- Mesh
--------------------------------------------------------------------------------

local function loadModel(file)
    if matches(file, { ".glb" }) then
        local bytes = LuauFile.loadBytes(file)
        if #bytes == 0 then return nil, "failed to read " .. file end
        local ok, v, t, n, uv, tex = pcall(Gltf.parseGlb, bytes, "props")
        if not ok then return nil, tostring(v) end
        return { vertices = v, triangles = t, normals = n, uVs = uv, textures = tex }
    end
    local text = LuauFile.loadText(file)
    if text == "" then return nil, "failed to read " .. file end
    local ok, v, t, n, uv, tex = pcall(Gltf.parse, text, "props")
    if not ok then return nil, tostring(v) end
    return { vertices = v, triangles = t, normals = n, uVs = uv, textures = tex }
end

local function hide(index)
    local m = meshes[index]
    if m then m.mesh.scale = Vec3.zeroVector end
end

--------------------------------------------------------------------------------
-- Balls
--------------------------------------------------------------------------------

-- Same radius Match:findBall uses, so a picker on one arena never lists the balls belonging
-- to another arena running on the same station.
local BALL_RADIUS = 20000

-- Live balls near this arena, nearest first. ReplayBall.index is the per-frame identifier
-- an entry stores to pin itself to one specific ball.
function Models.listBalls(match)
    local out = {}
    if match == nil then return out end
    local frame = getGameData()
    if frame == nil then return out end
    for _, b in frame.balls do
        local d = Util.dist(match.transform.position, b.transform.position)
        if d <= BALL_RADIUS then
            table.insert(out, {
                index = b.index,
                distance = d,
                isArenaBall = Util.isArenaBall(b),
            })
        end
    end
    table.sort(out, function(a, c) return a.distance < c.distance end)
    return out
end

local function ballFor(entry, match)
    -- -1 means "let Match decide", which is the closest white/white arena ball.
    if entry.ballIndex == nil or entry.ballIndex < 0 then return match.ball end
    local frame = getGameData()
    if frame == nil then return nil end
    for _, b in frame.balls do
        if b.index == entry.ballIndex
            and Util.dist(match.transform.position, b.transform.position) <= BALL_RADIUS then
            return b
        end
    end
    return nil
end

-- Returns position, rotation for whatever this entry is pinned to, or nil when the chosen
-- ball isn't in play so callers hide rather than draw at a stale position.
--
-- Position and rotation deliberately come from the SAME frame: with spin off, using the
-- ball's position but the arena's rotation keeps the x/y/z offset arena-relative, so it
-- stays put instead of orbiting the ball as it tumbles.
local function anchorFor(entry, match)
    if entry.followMode == "ball" then
        local ball = ballFor(entry, match)
        if ball == nil then return nil, nil end
        if entry.spinWithBall == false then
            return ball.transform.position, match.transform.rotation
        end
        return ball.transform.position, ball.transform.rotation
    end
    return match.transform.position, match.transform.rotation
end

-- Hiding the real ball is what turns "a model floating on the ball" into "the ball IS the
-- model" -- the trick mrstick.contentprops uses. replayBallScaleMultiplier is GLOBAL and
-- affects every ball in the replay, so it is tracked and restored rather than blind-set.
local appliedBallScale = nil

local function applyBallScale(wrapping)
    local want = (config.hideRealBall and wrapping) and 0 or (config.ballScale or 1)
    if appliedBallScale ~= want then
        spectatorDebug.replayBallScaleMultiplier = want
        appliedBallScale = want
    end
end

-- Rebuilds the mesh only when the entry's file or texture override actually changed, since
-- re-parsing a .glb every frame would be wasteful.
local function ensureMesh(index, entry)
    local m = meshes[index]
    if m == nil then
        local mesh = WorldDraw.spawnMesh()
        if mesh == nil then
            issue("casterfx: spawnMesh() returned nil, cannot show model slot " .. index)
            return nil
        end
        m = { mesh = mesh, file = nil, texturePath = nil, needDraw = true }
        meshes[index] = m
    end

    if m.file ~= entry.file then
        local geo, err = loadModel(entry.file)
        if geo == nil then
            Models.status[index] = err
            return nil
        end
        m.mesh.vertices = geo.vertices
        m.mesh.triangles = geo.triangles
        m.mesh.normals = geo.normals
        m.mesh.uVs = geo.uVs
        m.embeddedTexture = geo.textures and geo.textures.baseColor
        m.file = entry.file
        m.texturePath = nil -- force the texture branch below to re-apply
        m.needDraw = true
        Models.status[index] = "loaded"
    end

    local wantOverride = entry.textureOverride ~= "" and entry.textureOverride or nil
    if m.texturePath ~= (wantOverride or "embedded") then
        if wantOverride then
            local ok, tex = pcall(LuauFile.loadTexture, wantOverride)
            if ok and tex then m.mesh.texture = tex end
        elseif m.embeddedTexture then
            m.mesh.texture = LuauTexture.fromBytes(m.embeddedTexture)
        end
        m.texturePath = wantOverride or "embedded"
        m.needDraw = true
    end

    return m
end

local function updateEntry(index, entry, match)
    if not entry.enabled or entry.file == "" then
        hide(index)
        Models.status[index] = entry.file == "" and "no file selected" or "hidden"
        return
    end

    local pos, rot = anchorFor(entry, match)
    if pos == nil then
        hide(index)
        Models.status[index] = "no ball in play"
        return
    end

    local m = ensureMesh(index, entry)
    if m == nil then
        hide(index)
        return
    end

    m.mesh.position = pos + rot:rotateVector(Vec3.new(entry.x, entry.y, entry.z))
    if entry.faceCamera then
        m.mesh.rotation = camera.rotation
    else
        m.mesh.rotation = rot * Quat.fromEuler(entry.roll, entry.pitch, entry.yaw)
    end
    m.mesh.scale = Vec3.new(entry.scale, entry.scale, entry.scale)

    -- Draw AFTER the transform is set -- a mesh first drawn at zero scale stays invisible.
    if m.needDraw then
        m.mesh:draw()
        m.needDraw = false
    end
end

function Models.update(match, enabled)
    if match == nil or enabled == false then
        for index in pairs(meshes) do hide(index) end
        applyBallScale(false)   -- nothing of ours is wrapping a ball; give it back
        return
    end
    local entries = Profiles.models(match.type)

    -- Only hide the real ball if something is actually standing in for it.
    local wrapping = false
    for _, entry in entries do
        if entry.enabled and entry.file ~= "" and entry.followMode == "ball" then
            wrapping = true
            break
        end
    end
    applyBallScale(wrapping)

    for index, entry in entries do
        updateEntry(index, entry, match)
    end
    -- Entries removed from the profile leave their mesh behind; park it.
    for index in pairs(meshes) do
        if entries[index] == nil then hide(index) end
    end
end

function Models.destroy()
    for _, m in pairs(meshes) do m.mesh:destroy() end
    meshes = {}
    Models.status = {}
    -- Unloading with the multiplier still at 0 would leave every ball invisible for the rest
    -- of the session, in every other camera too. Always hand it back at the game default.
    if appliedBallScale ~= nil and appliedBallScale ~= 1 then
        spectatorDebug.replayBallScaleMultiplier = 1
    end
    appliedBallScale = nil
end

--------------------------------------------------------------------------------
-- GUI
--------------------------------------------------------------------------------

local function modelEditor(index, entry, match)
    -- "###" not "##": with "##" the ID hash still includes the visible text, so typing in the
    -- name box below would change this node's ID every keystroke, push a different child ID
    -- scope, and kick focus out of that box on every character. "###" hashes only the suffix.
    if not Gui.treeNode(string.format("%d. %s###model%d", index, entry.name, index)) then return end

    entry.name = Gui.inputText("Label##model" .. index, entry.name)
    entry.enabled = Gui.checkbox("Show##model" .. index, entry.enabled)
    Gui.text("Status: " .. tostring(Models.status[index]))

    if Gui.beginCombo("File##model" .. index, entry.file ~= "" and entry.file or "(none)") then
        for _, f in fileList do
            local label = Models.hasPreset(f) and (f .. "  [preset]") or f
            if Gui.selectable(label, entry.file == f) then
                entry.file = f
                -- A saved correction for this file beats the generic defaults.
                Models.applyPreset(entry)
            end
        end
        Gui.endCombo()
    end
    if Gui.beginCombo("Texture override##model" .. index,
        entry.textureOverride ~= "" and entry.textureOverride or "(embedded)") then
        if Gui.selectable("(embedded)", entry.textureOverride == "") then entry.textureOverride = "" end
        for _, f in textureList do
            if Gui.selectable(f, entry.textureOverride == f) then entry.textureOverride = f end
        end
        Gui.endCombo()
    end

    Gui.separatorText("Follow")
    if Gui.beginCombo("Anchor##model" .. index,
        entry.followMode == "ball" and "Ball" or "Arena") then
        if Gui.selectable("Arena", entry.followMode ~= "ball") then entry.followMode = "arena" end
        if Gui.selectable("Ball", entry.followMode == "ball") then entry.followMode = "ball" end
        Gui.endCombo()
    end

    if entry.followMode == "ball" then
        local balls = Models.listBalls(match)
        local current = entry.ballIndex < 0 and "Closest to arena (auto)"
            or ("Ball #" .. entry.ballIndex)
        if Gui.beginCombo("Which ball##model" .. index, current) then
            if Gui.selectable("Closest to arena (auto)", entry.ballIndex < 0) then
                entry.ballIndex = -1
            end
            for _, b in balls do
                local label = string.format("Ball #%d  --  %.1fm%s", b.index, b.distance / 100,
                    b.isArenaBall and "  (game ball)" or "  (other)")
                if Gui.selectable(label, entry.ballIndex == b.index) then
                    entry.ballIndex = b.index
                end
            end
            Gui.endCombo()
        end
        if #balls == 0 then
            Gui.textDisabled("no balls in play right now")
        end

        entry.spinWithBall = Gui.checkbox("Tumble with the ball##model" .. index,
            entry.spinWithBall)
        Gui.setItemTooltip("The ball really does spin, about 400 deg/s in a measured match. "
            .. "Leave on for a prop; turn OFF for a crest or logo, which is unreadable "
            .. "spinning that fast.")
    end

    entry.faceCamera = Gui.checkbox("Always face the camera##model" .. index, entry.faceCamera)
    Gui.setItemTooltip("Billboards the model, overriding the rotation below.")

    Gui.separatorText(entry.followMode == "ball"
        and "Position (cm, ball-relative)" or "Position (cm, arena-relative)")
    entry.x = Gui.dragFloat("Forward X##model" .. index, entry.x, 2, -20000, 20000)
    entry.y = Gui.dragFloat("Right Y##model" .. index, entry.y, 2, -20000, 20000)
    entry.z = Gui.dragFloat("Up Z##model" .. index, entry.z, 2, -5000, 5000)

    if Freecam.isDriving() then
        if Gui.button(Icon.MapMarkerAlt .. " Put it where I'm looking##model" .. index) then
            local aim = Freecam.aimPoint(400)
            local pos, rot = anchorFor(entry, match)
            if aim and pos then
                local local_ = rot:inverse():rotateVector(aim - pos)
                entry.x, entry.y, entry.z = local_.x, local_.y, local_.z
            end
        end
    end

    Gui.separatorText("Rotation (degrees)")
    entry.roll = Gui.sliderFloat("Roll##model" .. index, entry.roll, -180, 180)
    entry.pitch = Gui.sliderFloat("Pitch##model" .. index, entry.pitch, -180, 180)
    entry.yaw = Gui.sliderFloat("Yaw##model" .. index, entry.yaw, -180, 180)

    Gui.separatorText("Scale")
    entry.scale = Gui.dragFloat("Uniform scale##model" .. index, entry.scale, 1, 0.01, 100000)

    Gui.separatorText("Preset for this file")
    if entry.file == "" then
        Gui.textDisabled("pick a file first")
    else
        Gui.textDisabled(Models.hasPreset(entry.file)
            and ("saved for " .. entry.file) or ("nothing saved for " .. entry.file))
        if Gui.button(Icon.Save .. " Save as this file's default##model" .. index) then
            if Models.savePreset(entry) and saveConfig() then
                print("casterfx: saved preset for " .. entry.file)
            end
        end
        Gui.setItemTooltip("Remembers this position, rotation and scale for "
            .. entry.file .. " everywhere -- every profile and every arena.")
        if Models.hasPreset(entry.file) then
            Gui.sameLine()
            if Gui.button(Icon.Undo .. " Revert to preset##model" .. index) then
                Models.applyPreset(entry)
            end
            Gui.sameLine()
            if Gui.button(Icon.Trash .. " Forget##model" .. index) then
                Models.forgetPreset(entry.file)
                saveConfig()
            end
        end
    end

    Gui.treePop()
end

-- match is the currently selected arena (main.luau's `selected`), or nil if none.
function Models.gui(match)
    if Gui.button(Icon.SyncAlt .. " Rescan props/ folder") then Models.rescan() end
    Gui.sameLine()
    Gui.text(#fileList .. " model(s), " .. #textureList .. " texture(s) found")

    if match == nil then
        Gui.text("No arena detected -- select one on the Debug tab to place models.")
        return
    end

    Gui.separatorText("Game ball")
    config.hideRealBall = Gui.checkbox("Hide the real ball while a model is on it",
        config.hideRealBall)
    Gui.setItemTooltip("Shrinks the game ball to nothing so your model stands in for it "
        .. "instead of sitting inside it. Affects every ball in the replay.")
    config.ballScale = Gui.sliderFloat("Ball scale (when shown)", config.ballScale, 0, 10)
    Gui.text(#Models.listBalls(match) .. " ball(s) near this arena")

    Gui.separatorText("Models -- arena-relative, same convention as logo slots")
    local entries = Profiles.models(match.type)
    for index, entry in entries do
        modelEditor(index, entry, match)
    end

    Gui.separator()
    if Gui.button(Icon.Plus .. " Add model") then
        table.insert(entries, Profiles.defaultModel())
    end
    Gui.sameLine()
    if Gui.button(Icon.Trash .. " Remove last model") and #entries > 0 then
        table.remove(entries)
        Models.status[#entries + 1] = nil
    end
    Gui.sameLine()
    if Gui.button(Icon.Undo .. " Reset all models") then
        Profiles.resetModels(match.type)
    end

    if Gui.button(Icon.Save .. " Save models") then
        if saveConfig() then print("casterfx: models saved") end
    end
end

return Models
