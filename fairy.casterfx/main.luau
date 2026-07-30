-- Fairy Caster FX -- sideline camera, team logo overlays, and VFX for Orion Drift casting.
--
-- Two modes, decided by whether this script owns the camera:
--   ACTIVE  -- the sideline camera (or the debug freecam) drives the view, overlays on top.
--   OVERLAY -- alwaysTick keeps it running while ANOTHER camera is active (Plutus
--              Autocaster, freecam, anything). The camera is never written to.
--
-- It renders with meshes only, never WorldDraw lines, on purpose: other scripts call
-- WorldDraw.clear() every frame (Plutus does) which would wipe our lines but leaves
-- meshes alone. Do not add drawLine calls here.
--
-- Settings live in named profiles (Profiles module) because Orion Drift has several
-- competitive arenas and each wants its own framing and logo placement.

local Util = require("util")
local Match = require("match")
local Profiles = require("profiles")
-- "scoreboard", not "logos": require("logos") resolves to the logos/ asset folder.
local Scoreboard = require("scoreboard")
local Particles = require("particles")
local Effects = require("effects")
local Sideline = require("sideline")
local Freecam = require("freecam")
local Diagnostics = require("diagnostics")

Util.initializeConfig({
    logosEnabled = true,
    writeWanted = true,
    autoSelectArena = true,
    autoBindProfile = true,
    -- Defaults taken from UVC's freecam; the first attempt at these was unusable.
    freecamSpeed = 1600,
    freecamSensitivity = 3.6,
    freecamSmoothing = 0.55,
    freecamRequireRightMouse = false,
})

local matches = {}
local selected = nil
local selectedIndex = 0
local lastSlotCount = -1
local refreshTimer = 99
local wantedTimer = 0
local prevBallVelocity = Vec3.zeroVector
local lastImpactTime = -99
local totalTime = 0
local selfTestResult = ""
local newProfileName = ""

-- Error handling. A raw error inside tick() kills the script for the rest of the session,
-- which is how a goal flash can end up stuck on: the lights stop being decayed. Each phase
-- is guarded so one bad frame degrades instead of stopping everything.
local lastError = ""
local errorCount = 0

local function guard(name, fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then
        errorCount += 1
        lastError = name .. ": " .. tostring(err)
        -- Log the first few only; a per-frame error would otherwise flood the log.
        if errorCount <= 5 then issue("casterfx " .. lastError) end
    end
    return ok
end

--------------------------------------------------------------------------------
-- Wiring
--------------------------------------------------------------------------------

local function pushSettings()
    local profile = Profiles.active()
    Sideline.settings = profile.camera

    local v = profile.vfx
    Particles.enabled = v.enabled
    Particles.simSpeed = v.simSpeed
    Particles.sizeScale = v.sizeScale
    Particles.maxParticles = math.floor(v.maxParticles)

    local s = Effects.settings
    s.intensity = v.intensity
    s.hdrBoost = v.hdrBoost
    s.trailLength = v.trailLength
    s.trailBoost = v.trailBoost
    s.goalEnabled = v.goalEnabled
    s.goalShockwaves = v.goalShockwaves
    s.goalDebris = v.goalDebris
    s.goalSparks = v.goalSparks
    s.goalSprites = v.goalSprites
    s.goalLights = v.goalLights
    s.lightIntensity = v.lightIntensity
    s.kickoffEnabled = v.kickoffEnabled
    s.trailEnabled = v.trailEnabled
    s.trailInterval = v.trailInterval
    s.impactEnabled = v.impactEnabled

    Freecam.speed = config.freecamSpeed
    Freecam.lookSensitivity = config.freecamSensitivity
    Freecam.lookSmoothing = config.freecamSmoothing
    Freecam.requireRightMouse = config.freecamRequireRightMouse
end

local function selectIndex(i)
    if #matches == 0 then selected = nil; selectedIndex = 0; return end
    selectedIndex = math.clamp(i, 1, #matches)
    selected = matches[selectedIndex]
    Effects.resetTrail()
    -- Cut to the new arena instead of sweeping across the station, and don't let the
    -- old arena's ball velocity fire a phantom impact ring.
    Sideline.reset()
    prevBallVelocity = Vec3.zeroVector

    -- Each competitive arena can have its own profile bound to it.
    if config.autoBindProfile and selected then
        local bound = Profiles.bindingFor(selected.slotId)
        if bound then
            Profiles.select(bound)
            pushSettings()
        end
    end
end

local function refreshMatches(force)
    local count = #SpectatorGamemodes.listGamemodeIds()
    if not force and count == lastSlotCount then return end
    lastSlotCount = count
    local previousId = selected and selected.slotId or nil
    matches = Match.listAll()
    selected = nil
    for i, m in matches do
        if m.slotId == previousId then selectIndex(i) end
    end
    if selected == nil then selectIndex(1) end
end

-- Whichever arena the camera is actually looking from. Beats making the user pick
-- when a station hosts several courts. Skipped while we own the camera, since then the
-- camera sits at the selected arena by construction and this could never move off it.
local function autoSelect()
    if #matches < 2 or Sideline.isDriving() or Freecam.isDriving() then return end
    local pos = camera.position
    local bestIdx, bestDist = selectedIndex, math.huge
    for i, m in matches do
        local d = Util.dist(pos, m.transform.position)
        if d < bestDist then bestDist = d; bestIdx = i end
    end
    if bestIdx ~= selectedIndex then selectIndex(bestIdx) end
end

--------------------------------------------------------------------------------
-- Possession, only accurate enough to colour the trail
--------------------------------------------------------------------------------

local function possessionColor(match)
    if match == nil or match.ball == nil then return LinearColor.White end
    local frame = getGameData()
    if frame == nil then return LinearColor.White end
    local ballPos = match.ball.transform.position
    local bestTeam, bestDist = nil, math.huge
    for _, p in frame.players do
        if p.teamIndex ~= Util.TeamIndex.NoTeam then
            local d = Util.dist(ballPos, p.head.position)
            if d < bestDist then bestDist = d; bestTeam = p.teamIndex end
        end
    end
    if bestTeam == nil or bestDist > 300 then return LinearColor.White end
    if bestTeam == Util.TeamIndex.HomeTeam then return match.home.color end
    return match.away.color
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

function main()
    alwaysTick = true
    math.randomseed(math.floor(os.clock() * 1000) % 2147483647)
    Profiles.ensure()
    pushSettings()
    Scoreboard.rescan()
    refreshMatches(true)
end

function onLoad()
    alwaysTick = true
end

function onConfigChanged()
    Profiles.ensure()
    pushSettings()
end

function onUnload()
    Particles.destroyAll()
    Scoreboard.destroy()
end

function tick(dt)
    totalTime += dt
    pushSettings()

    -- Lines are redrawn every frame, so the clear has to happen before anything draws.
    Particles.beginFrame()

    refreshTimer += dt
    if refreshTimer > 3 then
        refreshTimer = 0
        guard("refreshMatches", refreshMatches, false)
        if config.autoSelectArena then guard("autoSelect", autoSelect) end
    end

    if selected == nil then
        guard("particles", Particles.update, dt)
        return
    end

    guard("match tick", function() selected:tick() end)

    -- Camera first: billboarded particles and face-camera logos read camera.rotation, so the
    -- camera has to be where it is going to be this frame before the overlays are placed.
    -- Freecam wins when enabled, so logo placement can be done by eye.
    if Freecam.isDriving() then
        guard("freecam", Freecam.update, dt, selected)
    else
        guard("sideline", Sideline.update, dt, selected)
    end

    guard("events", function()
        for _, event in selected.events do
            if event.kind == "goal" then
                Effects.goalExplosion(event.position, event.rotation, event.team.color)
            elseif event.kind == "kickoff" then
                Effects.kickoffBurst(event.position, selected.home.color, selected.away.color)
            end
        end
    end)

    guard("ball effects", function()
        local ball = selected.ball
        local trailColor = possessionColor(selected)
        if ball then
            local vel = ball.velocity or Vec3.zeroVector
            Effects.ballTrail(dt, ball.transform.position, vel, trailColor)
            -- A large velocity change in one frame is a hit, a wall, or a save.
            local delta = (vel - prevBallVelocity):length()
            local threshold = Profiles.active().vfx.impactThreshold
            if delta > threshold and totalTime - lastImpactTime > 0.15 then
                lastImpactTime = totalTime
                Effects.impactRing(ball.transform.position,
                    (vel - prevBallVelocity):getSafeNormal(), trailColor)
            end
            prevBallVelocity = vel
        else
            Effects.resetTrail()
            prevBallVelocity = Vec3.zeroVector
        end
    end)

    guard("scoreboard", Scoreboard.update, selected, config.logosEnabled)

    if config.writeWanted then
        wantedTimer += dt
        if wantedTimer > 2 then
            wantedTimer = 0
            guard("writeWanted", Scoreboard.writeWanted, selected)
        end
    end

    guard("particles", Particles.update, dt)
end

--------------------------------------------------------------------------------
-- GUI
--------------------------------------------------------------------------------

local function modeBanner()
    if Freecam.isDriving() then
        Gui.textColored(LinearColor.new(0.5, 0.8, 1, 1),
            "DEBUG FREECAM -- WASD move, R/F up-down, right-mouse look, Shift fast, Space snap to arena")
    elseif Sideline.isDriving() then
        Gui.textColored(LinearColor.new(0.4, 1, 0.4, 1), "Driving the camera (sideline).")
    else
        Gui.textColored(LinearColor.new(1, 0.8, 0.3, 1),
            "Overlay mode -- another camera is active, so the view is not touched.")
        Gui.text("Activate this camera in F2 to have it drive the shot.")
    end
end

local function cameraTab()
    local cam = Profiles.active().camera
    modeBanner()
    Gui.separator()

    cam.enabled = Gui.checkbox("Enable sideline camera", cam.enabled)
    Freecam.enabled = Gui.checkbox("Debug freecam (for placing logos)", Freecam.enabled)
    if Freecam.enabled then
        Gui.text("WASD move, R/F up-down, mouse look, Shift fast, Ctrl slow, scroll speed")
        config.freecamSpeed = Gui.sliderFloat("Speed (cm/s)", config.freecamSpeed, 100, 20000)
        config.freecamSensitivity = Gui.sliderFloat("Look sensitivity",
            config.freecamSensitivity, 0.2, 12)
        config.freecamSmoothing = Gui.sliderFloat("Look smoothing", config.freecamSmoothing, 0, 0.95)
        config.freecamRequireRightMouse = Gui.checkbox("Only look while right mouse held",
            config.freecamRequireRightMouse)
        Gui.text(string.format("yaw %.0f  pitch %.0f  speed %.0f",
            Freecam.debug.yaw, Freecam.debug.pitch, Freecam.debug.speed))
        if Gui.button(Icon.Crosshairs .. " Snap freecam to arena") then Freecam.snapTo(selected) end
    end

    Gui.text(string.format("Side %+d (blend %+.2f)   FOV %.0f   subject %.0f cm   lift %.0f",
        Sideline.debug.side, Sideline.debug.blend, Sideline.debug.fov,
        Sideline.debug.subject, Sideline.debug.groundLift))
    if not Sideline.debug.hasBall then
        Gui.text("No ball found -- framing the arena centre.")
    end

    Gui.separatorText("Framing")
    cam.sideDistance = Gui.sliderFloat("Touchline distance", cam.sideDistance, 500, 8000)
    cam.lengthLimit = Gui.sliderFloat("Track length limit", cam.lengthLimit, 0, 9000)
    cam.heightOffset = Gui.sliderFloat("Height above ball", cam.heightOffset, -500, 1500)
    cam.maxHeight = Gui.sliderFloat("Max height", cam.maxHeight, 0, 3000)
    cam.minHeightAboveGround = Gui.sliderFloat("Min above floor", cam.minHeightAboveGround, 0, 600)

    Gui.separatorText("Zoom -- frames the action, not the ball")
    cam.autoZoom = Gui.checkbox("Auto zoom", cam.autoZoom)
    cam.zoomFraction = Gui.sliderFloat("Action fills fraction of screen", cam.zoomFraction, 0.2, 1.2)
    cam.subjectMin = Gui.sliderFloat("Min action size (cm)", cam.subjectMin, 200, 6000)
    cam.subjectMax = Gui.sliderFloat("Max action size (cm)", cam.subjectMax, 500, 12000)
    cam.subjectPadding = Gui.sliderFloat("Action padding", cam.subjectPadding, 1, 2.5)
    cam.fovMin = Gui.sliderFloat("FOV min", cam.fovMin, 10, 170)
    cam.fovMax = Gui.sliderFloat("FOV max", cam.fovMax, 10, 170)
    cam.fovFixed = Gui.sliderFloat("Fixed FOV (auto zoom off)", cam.fovFixed, 10, 170)

    Gui.separatorText("Smoothing")
    cam.followSpeed = Gui.sliderFloat("Dolly follow speed", cam.followSpeed, 0.5, 20)
    cam.aimSpeed = Gui.sliderFloat("Aim follow speed", cam.aimSpeed, 0.5, 30)
    cam.lead = Gui.sliderFloat("Velocity lead (s)", cam.lead, 0, 1.5)
    cam.positionSmoothing = Gui.sliderFloat("Engine position smoothing", cam.positionSmoothing, 0, 1)
    cam.rotationSmoothing = Gui.sliderFloat("Engine rotation smoothing", cam.rotationSmoothing, 0, 1)
    cam.fovSmoothing = Gui.sliderFloat("Engine FOV smoothing", cam.fovSmoothing, 0, 1.5)

    Gui.separatorText("Side switching")
    if Gui.beginCombo("Switch mode", cam.switchMode) then
        for _, mode in { "smooth", "cut" } do
            if Gui.selectable(mode, cam.switchMode == mode) then cam.switchMode = mode end
        end
        Gui.endCombo()
    end
    cam.switchSeconds = Gui.sliderFloat("Crossing time (s)", cam.switchSeconds, 0.1, 4)
    cam.switchThreshold = Gui.sliderFloat("Switch threshold", cam.switchThreshold, 0, 3000)
    cam.switchDwell = Gui.sliderFloat("Min time between switches (s)", cam.switchDwell, 0, 10)
    if Gui.button(Icon.ExchangeAlt .. " Flip side now") then Sideline.flipSide() end

    Gui.separatorText("Endzone behaviour")
    cam.riserScale = Gui.sliderFloat("Riser strength", cam.riserScale, 0, 4)
    cam.hookScale = Gui.sliderFloat("Inward hook strength", cam.hookScale, 0, 4)

    Gui.separator()
    if Gui.button(Icon.Save .. " Save profile") then
        if saveConfig() then print("casterfx: saved profile " .. config.activeProfile) end
    end
end

local function slotEditor(index, slot)
    if not Gui.treeNode(string.format("%d. %s##slot%d", index, slot.name, index)) then return end

    slot.name = Gui.inputText("Label##" .. index, slot.name)
    slot.enabled = Gui.checkbox("Show##" .. index, slot.enabled)
    Gui.sameLine()
    slot.faceCamera = Gui.checkbox("Face camera##" .. index, slot.faceCamera)
    Gui.sameLine()
    if Gui.beginCombo("Side##" .. index, slot.side) then
        for _, side in { "home", "away" } do
            if Gui.selectable(side, slot.side == side) then slot.side = side end
        end
        Gui.endCombo()
    end
    Gui.text("Status: " .. tostring(Scoreboard.status[index]))

    Gui.separatorText("Position (cm, arena-relative)")
    slot.x = Gui.dragFloat("Forward X##" .. index, slot.x, 2, -20000, 20000)
    slot.y = Gui.dragFloat("Right Y##" .. index, slot.y, 2, -20000, 20000)
    slot.z = Gui.dragFloat("Up Z##" .. index, slot.z, 2, -5000, 5000)

    if Freecam.isDriving() and selected then
        if Gui.button(Icon.MapMarkerAlt .. " Put it where I'm looking##" .. index) then
            local aim = Freecam.aimPoint(400)
            if aim then
                -- World point back into the arena's frame, which is what the slot stores.
                local local_ = selected.transform.rotation:inverse()
                    :rotateVector(aim - selected.transform.position)
                slot.x, slot.y, slot.z = local_.x, local_.y, local_.z
            end
        end
    end

    Gui.separatorText("Rotation (degrees)")
    slot.roll = Gui.sliderFloat("Roll##" .. index, slot.roll, -180, 180)
    slot.pitch = Gui.sliderFloat("Pitch##" .. index, slot.pitch, -180, 180)
    slot.yaw = Gui.sliderFloat("Yaw##" .. index, slot.yaw, -180, 180)

    Gui.separatorText("Size (cm)")
    slot.width = Gui.dragFloat("Width##" .. index, slot.width, 1, 1, 4000)
    slot.height = Gui.dragFloat("Height##" .. index, slot.height, 1, 1, 4000)

    Gui.separatorText("Texture orientation")
    slot.flipU = Gui.checkbox("Flip horizontally##" .. index, slot.flipU)
    Gui.sameLine()
    slot.flipV = Gui.checkbox("Flip vertically##" .. index, slot.flipV)

    Gui.treePop()
end

local function logosTab()
    config.logosEnabled = Gui.checkbox("Enable logo overlays", config.logosEnabled)

    if selected == nil then
        Gui.text("No arena detected.")
        return
    end

    Gui.text("Arena: " .. selected.name .. "  (" .. tostring(selected.type) .. ")")
    Gui.text("Home: " .. (selected.home.name ~= "" and selected.home.name or "-"))
    Gui.text("Away: " .. (selected.away.name ~= "" and selected.away.name or "-"))

    -- Observed live: an ordinary lobby reports the same teamName for both sides, because it is
    -- the in-game team name and not the ODC one. HOME.png/AWAY.png sidestep it entirely.
    if selected.home.name ~= "" and selected.home.name == selected.away.name then
        Gui.textColored(LinearColor.new(1, 0.8, 0.3, 1),
            "Both sides report the same team name.")
        Gui.text("Use HOME.png / AWAY.png (get-logos.ps1 -FromBridge) or the overrides below.")
    end

    Gui.separator()
    if Gui.button(Icon.SyncAlt .. " Rescan logos/ folder") then Scoreboard.rescan() end
    Gui.sameLine()
    Gui.text(#Scoreboard.files() .. " image(s) found")
    config.writeWanted = Gui.checkbox("Write wanted.json for get-logos.ps1", config.writeWanted)

    Gui.separatorText("Manual override (blank = auto)")
    local profile = Profiles.active()
    local files = Scoreboard.files()
    for _, side in { "home", "away" } do
        local current = profile.logoOverride[side] or ""
        if Gui.beginCombo(side == "home" and "Home image" or "Away image",
            current ~= "" and current or "(auto)") then
            if Gui.selectable("(auto)", current == "") then profile.logoOverride[side] = "" end
            for _, f in files do
                if Gui.selectable(f, current == f) then profile.logoOverride[side] = f end
            end
            Gui.endCombo()
        end
    end

    Gui.separatorText("Slots -- one per logo, two scoreboards means four")
    local slots = Profiles.slots(selected.type, selected.arenaHeight)
    for index, slot in slots do
        slotEditor(index, slot)
    end

    Gui.separator()
    if Gui.button(Icon.Plus .. " Add slot") then
        local index = #slots + 1
        slots[index] = Profiles.defaultSlot(index, "home", selected.arenaHeight)
    end
    Gui.sameLine()
    if Gui.button(Icon.Trash .. " Remove last slot") and #slots > 1 then
        table.remove(slots)
    end
    Gui.sameLine()
    if Gui.button(Icon.Undo .. " Reset all slots") then
        Profiles.resetSlots(selected.type, selected.arenaHeight)
    end

    if Gui.button(Icon.Save .. " Save placement") then
        if saveConfig() then print("casterfx: placement saved") end
    end
end

local function vfxTab()
    local v = Profiles.active().vfx
    v.enabled = Gui.checkbox("Enable VFX", v.enabled)
    v.intensity = Gui.sliderFloat("Intensity (counts)", v.intensity, 0.1, 3)
    v.sizeScale = Gui.sliderFloat("Size scale", v.sizeScale, 0.2, 6)
    -- Values above 1 bloom. This is the knob that decides whether particles glow.
    v.hdrBoost = Gui.sliderFloat("HDR brightness (bloom)", v.hdrBoost, 1, 60)
    v.simSpeed = Gui.sliderFloat("Sim speed", v.simSpeed, 0.1, 2)
    v.maxParticles = Gui.sliderInt("Particle budget", math.floor(v.maxParticles), 100, 4000)

    Gui.separatorText("Goal explosion")
    v.goalEnabled = Gui.checkbox("Goal explosion", v.goalEnabled)
    v.goalShockwaves = Gui.checkbox("Shockwave rings", v.goalShockwaves)
    v.goalDebris = Gui.checkbox("Debris shards", v.goalDebris)
    v.goalSparks = Gui.checkbox("Sparks", v.goalSparks)
    v.goalSprites = Gui.checkbox("Sprite flares", v.goalSprites)
    v.goalLights = Gui.checkbox("Light flash", v.goalLights)
    v.lightIntensity = Gui.sliderFloat("Light brightness", v.lightIntensity, 0, 2)

    Gui.separatorText("Other effects")
    v.kickoffEnabled = Gui.checkbox("Kickoff burst", v.kickoffEnabled)
    v.trailEnabled = Gui.checkbox("Ball trail", v.trailEnabled)
    v.trailInterval = Gui.sliderFloat("Trail spacing (s)", v.trailInterval, 0.008, 0.15)
    v.trailLength = Gui.sliderInt("Trail length (points)", math.floor(v.trailLength), 2, 120)
    v.trailBoost = Gui.sliderFloat("Trail brightness", v.trailBoost, 1, 50)
    v.impactEnabled = Gui.checkbox("Impact rings", v.impactEnabled)
    v.impactThreshold = Gui.sliderFloat("Impact threshold (cm/s)", v.impactThreshold, 200, 3000)

    Gui.separator()
    if Gui.button(Icon.Bomb .. " Test goal explosion") and selected then
        Effects.goalExplosion(selected.away.goalPosition, selected.away.goalRotation,
            selected.home.color)
    end
    Gui.sameLine()
    if Gui.button(Icon.Rocket .. " Test kickoff") and selected then
        Effects.kickoffBurst(selected.transform.position, selected.home.color, selected.away.color)
    end
    if Gui.button(Icon.Vial .. " Test burst in front of camera") then
        Particles.testBurst()
    end
    Gui.sameLine()
    if Gui.button(Icon.Trash .. " Clear particles") then Particles.clear() end
    Gui.sameLine()
    if Gui.button(Icon.Lightbulb .. " Kill all lights") then Particles.clearLights() end

    if Gui.button(Icon.Save .. " Save profile") then
        if saveConfig() then print("casterfx: saved profile " .. config.activeProfile) end
    end
end

local function profilesTab()
    Gui.text("Active profile: " .. tostring(config.activeProfile))
    local names = Profiles.names()
    if Gui.beginCombo("Profile", tostring(config.activeProfile)) then
        for _, name in names do
            if Gui.selectable(name, name == config.activeProfile) then
                Profiles.select(name)
                pushSettings()
            end
        end
        Gui.endCombo()
    end

    Gui.separatorText("Manage")
    newProfileName = Gui.inputText("Name", newProfileName)
    if Gui.button(Icon.Plus .. " Create") then
        if Profiles.create(newProfileName) then newProfileName = "" ; pushSettings() end
    end
    Gui.sameLine()
    if Gui.button(Icon.Copy .. " Duplicate active") then
        if Profiles.create(newProfileName, config.activeProfile) then
            newProfileName = ""
            pushSettings()
        end
    end
    Gui.sameLine()
    if Gui.button(Icon.Edit .. " Rename active") then
        if Profiles.rename(config.activeProfile, newProfileName) then newProfileName = "" end
    end
    Gui.sameLine()
    if Gui.button(Icon.Trash .. " Delete active") then
        if Profiles.delete(config.activeProfile) then pushSettings() end
    end
    if #names <= 1 then Gui.text("(the last profile cannot be deleted)") end

    Gui.separatorText("Arena binding")
    config.autoBindProfile = Gui.checkbox("Auto-select profile per arena", config.autoBindProfile)
    if selected then
        local bound = Profiles.bindingFor(selected.slotId)
        Gui.text("Arena " .. selected.slotId .. " -> " .. (bound or "(unbound)"))
        if Gui.button(Icon.Link .. " Bind this arena to the active profile") then
            Profiles.bind(selected.slotId, config.activeProfile)
        end
        Gui.sameLine()
        if Gui.button(Icon.Unlink .. " Unbind") then Profiles.bind(selected.slotId, nil) end
    end

    Gui.separator()
    if Gui.button(Icon.Save .. " Save all profiles") then
        if saveConfig() then print("casterfx: profiles saved") end
    end
end

local function debugTab()
    if lastError ~= "" then
        Gui.textColored(LinearColor.new(1, 0.4, 0.4, 1), "Last error (" .. errorCount .. "): " .. lastError)
        if Gui.button(Icon.Times .. " Clear error") then lastError = ""; errorCount = 0 end
        Gui.separator()
    end

    Gui.separatorText("In-game diagnostics")
    Gui.text("Writes diagnostics.json into the package folder, with live arena, ball,")
    Gui.text("team, framing and mesh-capability data.")
    if Gui.button(Icon.Stethoscope .. " Run diagnostics against live data") then
        guard("diagnostics", Diagnostics.run, selected)
    end
    if Diagnostics.lastSummary ~= "" then
        local colour = Diagnostics.lastFailed == 0
            and LinearColor.new(0.4, 1, 0.4, 1) or LinearColor.new(1, 0.6, 0.3, 1)
        Gui.textColored(colour, "Diagnostics: " .. Diagnostics.lastSummary)
    end
    if Gui.button(Icon.Vial .. " Run particle self-test") then
        local _, msg = Particles.selfTest()
        selfTestResult = msg
    end
    if selfTestResult ~= "" then Gui.text("Self-test: " .. selfTestResult) end

    Gui.separatorText("Arenas")
    Gui.text("Detected: " .. #matches)
    config.autoSelectArena = Gui.checkbox("Auto-select nearest arena", config.autoSelectArena)
    if #matches > 0 and Gui.beginCombo("Arena", selected and selected.name or "-") then
        for i, m in matches do
            if Gui.selectable(m.name, i == selectedIndex) then selectIndex(i) end
        end
        Gui.endCombo()
    end
    if Gui.button(Icon.SyncAlt .. " Re-scan gamemodes") then refreshMatches(true) end

    Gui.separatorText("Runtime")
    local st = Particles.stats
    Gui.text("Particles live: " .. st.live
        .. " / " .. math.floor(Profiles.active().vfx.maxParticles))
    Gui.text("Spawned: " .. st.spawned .. "   recycled: " .. st.dropped
        .. "   lights: " .. st.lights)
    if selected then
        Gui.text("Slot: " .. selected.slotId .. "   running: " .. tostring(selected.isRunning))
        Gui.text("Score: " .. selected.home.score .. " - " .. selected.away.score)
        Gui.text("Ball: " .. (selected.ball and "yes" or "no"))
        Gui.text("Home goal: " .. tostring(selected.home.goalPosition))
        Gui.text("Away goal: " .. tostring(selected.away.goalPosition))
    end
end

function onGui()
    if Freecam.isDriving() then
        Gui.text("Fairy Caster FX -- debug freecam")
    elseif Sideline.isDriving() then
        Gui.text("Fairy Caster FX -- driving the camera")
    else
        Gui.text("Fairy Caster FX -- overlay mode, another camera is active")
    end
    Gui.separator()
    if not Gui.beginTabBar("casterfx") then return end
    if Gui.beginTabItem(Icon.Video .. " Camera") then
        cameraTab()
        Gui.endTabItem()
    end
    if Gui.beginTabItem(Icon.Image .. " Logos") then
        logosTab()
        Gui.endTabItem()
    end
    if Gui.beginTabItem(Icon.Fire .. " VFX") then
        vfxTab()
        Gui.endTabItem()
    end
    if Gui.beginTabItem(Icon.UserCog .. " Profiles") then
        profilesTab()
        Gui.endTabItem()
    end
    if Gui.beginTabItem(Icon.Bug .. " Debug") then
        debugTab()
        Gui.endTabItem()
    end
    Gui.endTabBar()
end
