-- Fairy Caster FX -- sideline camera, team logo overlays, and VFX for Orion Drift casting.
--
-- Two modes, decided by whether this script owns the camera:
--   ACTIVE  -- the sideline camera drives the view and the overlays render on top.
--   OVERLAY -- alwaysTick keeps it running while ANOTHER camera is active (Plutus
--              Autocaster, freecam, anything). The camera is never written to.
--
-- It renders with meshes only, never WorldDraw lines, on purpose: other scripts call
-- WorldDraw.clear() every frame (Plutus does) which would wipe our lines but leaves
-- meshes alone. Do not add drawLine calls here.

local Util = require("util")
local Match = require("match")
-- "scoreboard", not "logos": require("logos") resolves to the logos/ asset folder.
local Scoreboard = require("scoreboard")
local Particles = require("particles")
local Effects = require("effects")
local Sideline = require("sideline")

Util.initializeConfig({
    logosEnabled = true,
    logoOverride = { home = "", away = "" },
    logoSlots = {},
    writeWanted = true,

    vfxEnabled = true,
    intensity = 1.0,
    simSpeed = 1.0,
    maxMeshes = 420,

    goalEnabled = true,
    goalShockwaves = true,
    goalDebris = true,
    goalSparks = true,
    goalSprites = true,
    goalLights = true,
    lightIntensity = 1.0,
    kickoffEnabled = true,
    trailEnabled = true,
    trailInterval = 0.03,
    impactEnabled = true,
    impactThreshold = 900,

    autoSelectArena = true,
    showDebug = false,

    -- Sideline camera. Only applies when this script is the active/followed camera.
    camEnabled = true,
    camSideDistance = 2600,
    camLengthLimit = 2200,
    camHeightOffset = 220,
    camMaxHeight = 1250,
    camMinHeightAboveGround = 130,
    camRiserScale = 1.0,
    camHookScale = 1.0,
    camSwitchThreshold = 400,
    camSwitchInstant = true,
    camLead = 0.45,
    camPositionSmoothing = 0.25,
    camRotationSmoothing = 0.12,
    camFovSmoothing = 0.2,
    camAutoZoom = true,
    camZoomFraction = 0.16,
    camFovMin = 35,
    camFovMax = 95,
    camFovFixed = 70,
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

--------------------------------------------------------------------------------
-- Wiring
--------------------------------------------------------------------------------

local function pushSettings()
    Particles.enabled = config.vfxEnabled
    Particles.simSpeed = config.simSpeed
    Particles.maxMeshes = math.floor(config.maxMeshes)
    local s = Effects.settings
    s.intensity = config.intensity
    s.goalEnabled = config.goalEnabled
    s.goalShockwaves = config.goalShockwaves
    s.goalDebris = config.goalDebris
    s.goalSparks = config.goalSparks
    s.goalSprites = config.goalSprites
    s.goalLights = config.goalLights
    s.lightIntensity = config.lightIntensity
    s.kickoffEnabled = config.kickoffEnabled
    s.trailEnabled = config.trailEnabled
    s.trailInterval = config.trailInterval
    s.impactEnabled = config.impactEnabled

    local c = Sideline.settings
    c.enabled = config.camEnabled
    c.sideDistance = config.camSideDistance
    c.lengthLimit = config.camLengthLimit
    c.heightOffset = config.camHeightOffset
    c.maxHeight = config.camMaxHeight
    c.minHeightAboveGround = config.camMinHeightAboveGround
    c.riserScale = config.camRiserScale
    c.hookScale = config.camHookScale
    c.switchThreshold = config.camSwitchThreshold
    c.switchInstant = config.camSwitchInstant
    c.lead = config.camLead
    c.positionSmoothing = config.camPositionSmoothing
    c.rotationSmoothing = config.camRotationSmoothing
    c.fovSmoothing = config.camFovSmoothing
    c.autoZoom = config.camAutoZoom
    c.zoomFraction = config.camZoomFraction
    c.fovMin = config.camFovMin
    c.fovMax = config.camFovMax
    c.fovFixed = config.camFovFixed
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
    if #matches < 2 or Sideline.isDriving() then return end
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
    pushSettings()
    Scoreboard.rescan()
    refreshMatches(true)
end

function onLoad()
    alwaysTick = true
end

function onConfigChanged()
    pushSettings()
end

function onUnload()
    Particles.destroyAll()
    Scoreboard.destroy()
end

function tick(dt)
    totalTime += dt
    pushSettings()

    refreshTimer += dt
    if refreshTimer > 3 then
        refreshTimer = 0
        refreshMatches(false)
        if config.autoSelectArena then autoSelect() end
    end

    if selected == nil then
        Particles.update(dt)
        return
    end

    selected:tick()

    -- Before the overlays: billboarded particles and face-camera logos read camera.rotation,
    -- so the camera has to be where it is going to be this frame first.
    Sideline.update(dt, selected)

    for _, event in selected.events do
        if event.kind == "goal" then
            Effects.goalExplosion(event.position, event.rotation, event.team.color)
        elseif event.kind == "kickoff" then
            Effects.kickoffBurst(event.position, selected.home.color, selected.away.color)
        end
    end

    local ball = selected.ball
    local trailColor = possessionColor(selected)
    if ball then
        local vel = ball.velocity or Vec3.zeroVector
        Effects.ballTrail(dt, ball.transform.position, vel, trailColor)
        -- A large velocity change in one frame is a hit, a wall, or a save.
        local delta = (vel - prevBallVelocity):length()
        if delta > config.impactThreshold and totalTime - lastImpactTime > 0.15 then
            lastImpactTime = totalTime
            local normal = (vel - prevBallVelocity):getSafeNormal()
            Effects.impactRing(ball.transform.position, normal, trailColor)
        end
        prevBallVelocity = vel
    else
        Effects.resetTrail()
        prevBallVelocity = Vec3.zeroVector
    end

    Scoreboard.update(selected)

    if config.writeWanted then
        wantedTimer += dt
        if wantedTimer > 2 then
            wantedTimer = 0
            Scoreboard.writeWanted(selected)
        end
    end

    Particles.update(dt)
end

--------------------------------------------------------------------------------
-- GUI
--------------------------------------------------------------------------------

local function slotEditor(label, side, slot)
    if not Gui.treeNode(label) then return end
    slot.enabled = Gui.checkbox("Show##" .. side, slot.enabled)
    Gui.sameLine()
    slot.faceCamera = Gui.checkbox("Face camera##" .. side, slot.faceCamera)

    Gui.separatorText("Position (cm, arena-relative)")
    slot.x = Gui.dragFloat("Forward X##" .. side, slot.x, 2, -20000, 20000)
    slot.y = Gui.dragFloat("Right Y##" .. side, slot.y, 2, -20000, 20000)
    slot.z = Gui.dragFloat("Up Z##" .. side, slot.z, 2, -5000, 5000)

    Gui.separatorText("Rotation (degrees)")
    slot.roll = Gui.sliderFloat("Roll##" .. side, slot.roll, -180, 180)
    slot.pitch = Gui.sliderFloat("Pitch##" .. side, slot.pitch, -180, 180)
    slot.yaw = Gui.sliderFloat("Yaw##" .. side, slot.yaw, -180, 180)

    Gui.separatorText("Size (cm)")
    slot.width = Gui.dragFloat("Width##" .. side, slot.width, 1, 1, 4000)
    slot.height = Gui.dragFloat("Height##" .. side, slot.height, 1, 1, 4000)

    Gui.separatorText("Texture orientation")
    slot.flipU = Gui.checkbox("Flip horizontally##" .. side, slot.flipU)
    Gui.sameLine()
    slot.flipV = Gui.checkbox("Flip vertically##" .. side, slot.flipV)

    if Gui.button(Icon.Copy .. " Mirror to other side##" .. side) then
        local slots = Scoreboard.slotsFor(selected and selected.type, selected and selected.arenaHeight)
        local other = side == "home" and slots.away or slots.home
        other.x = slot.x; other.y = -slot.y; other.z = slot.z
        other.roll = slot.roll; other.pitch = slot.pitch; other.yaw = -slot.yaw
        other.width = slot.width; other.height = slot.height
        other.flipU = slot.flipU; other.flipV = slot.flipV
        other.faceCamera = slot.faceCamera
    end
    Gui.treePop()
end

local function logosTab()
    config.logosEnabled = Gui.checkbox("Enable logo overlays", config.logosEnabled)

    if selected == nil then
        Gui.text("No arena detected.")
        return
    end

    Gui.text("Arena: " .. selected.name .. "  (" .. tostring(selected.type) .. ")")
    Gui.text("Home: " .. (selected.home.name ~= "" and selected.home.name or "-")
        .. "   [" .. Scoreboard.status.home .. "]")
    Gui.text("Away: " .. (selected.away.name ~= "" and selected.away.name or "-")
        .. "   [" .. Scoreboard.status.away .. "]")

    -- Observed live: an ordinary lobby reports the same teamName for both sides, because
    -- it is the in-game team name and not the ODC one. Auto-match cannot tell the sides
    -- apart in that case, so say so instead of quietly showing one crest twice.
    if selected.home.name ~= "" and selected.home.name == selected.away.name then
        Gui.textColored(LinearColor.new(1, 0.8, 0.3, 1),
            "Both sides report the same team name -- set the overrides below.")
    end

    Gui.separator()
    if Gui.button(Icon.SyncAlt .. " Rescan logos/ folder") then
        Scoreboard.rescan()
    end
    Gui.sameLine()
    Gui.text(#Scoreboard.files() .. " image(s) found")

    config.writeWanted = Gui.checkbox("Write wanted.json for get-logos.ps1", config.writeWanted)

    Gui.separatorText("Manual override (blank = auto by team name)")
    local files = Scoreboard.files()
    for _, side in { "home", "away" } do
        local current = config.logoOverride[side]
        if Gui.beginCombo(side == "home" and "Home image" or "Away image",
            current ~= "" and current or "(auto)") then
            if Gui.selectable("(auto)", current == "") then config.logoOverride[side] = "" end
            for _, f in files do
                if Gui.selectable(f, current == f) then config.logoOverride[side] = f end
            end
            Gui.endCombo()
        end
    end

    Gui.separatorText("Placement -- nudge until it covers the in-game crest")
    local slots = Scoreboard.slotsFor(selected.type, selected.arenaHeight)
    slotEditor(Icon.Home .. " Home slot", "home", slots.home)
    slotEditor(Icon.PlaneDeparture .. " Away slot", "away", slots.away)

    Gui.separator()
    if Gui.button(Icon.Save .. " Save placement") then
        if saveConfig() then print("casterfx: placement saved") end
    end
    Gui.sameLine()
    if Gui.button(Icon.Undo .. " Reset this arena") then
        config.logoSlots[selected.type or "unknown"] = {
            home = Scoreboard.defaultSlot("home", selected.arenaHeight),
            away = Scoreboard.defaultSlot("away", selected.arenaHeight),
        }
    end
end

local function vfxTab()
    config.vfxEnabled = Gui.checkbox("Enable VFX", config.vfxEnabled)
    config.intensity = Gui.sliderFloat("Intensity", config.intensity, 0.1, 3)
    config.simSpeed = Gui.sliderFloat("Sim speed", config.simSpeed, 0.1, 2)
    config.maxMeshes = Gui.sliderInt("Mesh budget", math.floor(config.maxMeshes), 50, 1200)

    Gui.separatorText("Goal explosion")
    config.goalEnabled = Gui.checkbox("Goal explosion", config.goalEnabled)
    config.goalShockwaves = Gui.checkbox("Shockwave rings", config.goalShockwaves)
    config.goalDebris = Gui.checkbox("Debris shards", config.goalDebris)
    config.goalSparks = Gui.checkbox("Sparks", config.goalSparks)
    config.goalSprites = Gui.checkbox("Sprite flares", config.goalSprites)
    config.goalLights = Gui.checkbox("Light flash", config.goalLights)
    config.lightIntensity = Gui.sliderFloat("Light brightness", config.lightIntensity, 0, 3)

    Gui.separatorText("Other effects")
    config.kickoffEnabled = Gui.checkbox("Kickoff burst", config.kickoffEnabled)
    config.trailEnabled = Gui.checkbox("Ball trail", config.trailEnabled)
    config.trailInterval = Gui.sliderFloat("Trail spacing (s)", config.trailInterval, 0.008, 0.15)
    config.impactEnabled = Gui.checkbox("Impact rings", config.impactEnabled)
    config.impactThreshold = Gui.sliderFloat("Impact threshold (cm/s)", config.impactThreshold, 200, 3000)

    Gui.separator()
    if Gui.button(Icon.Bomb .. " Test goal explosion") and selected then
        local target = selected.away.goalPosition
        local rot = selected.away.goalRotation
        Effects.goalExplosion(target, rot, selected.home.color)
    end
    Gui.sameLine()
    if Gui.button(Icon.Rocket .. " Test kickoff") and selected then
        Effects.kickoffBurst(selected.transform.position, selected.home.color, selected.away.color)
    end
    if Gui.button(Icon.Trash .. " Clear live particles") then
        Particles.clear()
    end
    Gui.sameLine()
    if Gui.button(Icon.Save .. " Save VFX settings") then
        if saveConfig() then print("casterfx: VFX settings saved") end
    end
end

local function cameraTab()
    config.camEnabled = Gui.checkbox("Enable sideline camera", config.camEnabled)
    if Sideline.isDriving() then
        Gui.textColored(LinearColor.new(0.4, 1, 0.4, 1), "Driving the camera.")
    else
        Gui.textColored(LinearColor.new(1, 0.8, 0.3, 1),
            "Overlay mode -- another camera is active, so the view is not touched.")
        Gui.text("Activate this camera in F2 to have it drive the shot.")
    end
    Gui.text(string.format("Side: %s   FOV: %.0f   Ground lift: %.0f",
        Sideline.debug.side > 0 and "+" or "-", Sideline.debug.fov, Sideline.debug.groundLift))
    if not Sideline.debug.hasBall then
        Gui.text("No ball found -- framing the arena centre.")
    end

    Gui.separatorText("Framing")
    config.camSideDistance = Gui.sliderFloat("Touchline distance", config.camSideDistance, 500, 8000)
    config.camLengthLimit = Gui.sliderFloat("Track length limit", config.camLengthLimit, 0, 9000)
    config.camHeightOffset = Gui.sliderFloat("Height above ball", config.camHeightOffset, -500, 1500)
    config.camMaxHeight = Gui.sliderFloat("Max height", config.camMaxHeight, 0, 3000)
    config.camMinHeightAboveGround = Gui.sliderFloat("Min above floor",
        config.camMinHeightAboveGround, 0, 600)

    Gui.separatorText("Endzone behaviour")
    config.camRiserScale = Gui.sliderFloat("Riser strength", config.camRiserScale, 0, 4)
    config.camHookScale = Gui.sliderFloat("Inward hook strength", config.camHookScale, 0, 4)

    Gui.separatorText("Side switching")
    config.camSwitchThreshold = Gui.sliderFloat("Switch threshold",
        config.camSwitchThreshold, 0, 3000)
    config.camSwitchInstant = Gui.checkbox("Hard cut on switch", config.camSwitchInstant)
    if Gui.button(Icon.ExchangeAlt .. " Flip side now") then Sideline.flipSide() end

    Gui.separatorText("Aim and smoothing")
    config.camLead = Gui.sliderFloat("Velocity lead (s)", config.camLead, 0, 1.5)
    config.camPositionSmoothing = Gui.sliderFloat("Position smoothing",
        config.camPositionSmoothing, 0, 1.5)
    config.camRotationSmoothing = Gui.sliderFloat("Rotation smoothing",
        config.camRotationSmoothing, 0, 1.5)
    config.camFovSmoothing = Gui.sliderFloat("FOV smoothing", config.camFovSmoothing, 0, 1.5)

    Gui.separatorText("Zoom")
    config.camAutoZoom = Gui.checkbox("Auto zoom", config.camAutoZoom)
    config.camZoomFraction = Gui.sliderFloat("Ball screen fraction",
        config.camZoomFraction, 0.02, 0.6)
    config.camFovMin = Gui.sliderFloat("FOV min", config.camFovMin, 1, 170)
    config.camFovMax = Gui.sliderFloat("FOV max", config.camFovMax, 1, 170)
    config.camFovFixed = Gui.sliderFloat("Fixed FOV", config.camFovFixed, 1, 170)

    Gui.separator()
    if Gui.button(Icon.Save .. " Save camera settings") then
        if saveConfig() then print("casterfx: camera settings saved") end
    end
end

local function debugTab()
    Gui.text("Arenas detected: " .. #matches)
    config.autoSelectArena = Gui.checkbox("Auto-select nearest arena", config.autoSelectArena)
    if #matches > 0 then
        if Gui.beginCombo("Arena", selected and selected.name or "-") then
            for i, m in matches do
                if Gui.selectable(m.name, i == selectedIndex) then selectIndex(i) end
            end
            Gui.endCombo()
        end
    end
    if Gui.button(Icon.SyncAlt .. " Re-scan gamemodes") then refreshMatches(true) end

    Gui.separator()
    local st = Particles.stats
    Gui.text("Particles live: " .. st.live)
    Gui.text("Meshes pooled: " .. st.meshes .. " / " .. math.floor(config.maxMeshes))
    Gui.text("Mesh draws: " .. st.draws .. "   recycled: " .. st.dropped)
    if selected then
        Gui.text("Slot: " .. selected.slotId)
        Gui.text("Running: " .. tostring(selected.isRunning)
            .. "   Score: " .. selected.home.score .. " - " .. selected.away.score)
        Gui.text("Ball: " .. (selected.ball and "yes" or "no"))
        Gui.text("Home goal: " .. tostring(selected.home.goalPosition))
        Gui.text("Away goal: " .. tostring(selected.away.goalPosition))
    end

    Gui.separator()
    if Gui.button(Icon.Vial .. " Run self-test") then
        local _, msg = Particles.selfTest()
        selfTestResult = msg
    end
    if selfTestResult ~= "" then Gui.text("Self-test: " .. selfTestResult) end
end

function onGui()
    Gui.text(Sideline.isDriving()
        and "Fairy Caster FX -- driving the camera"
        or "Fairy Caster FX -- overlay mode, another camera is active")
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
    if Gui.beginTabItem(Icon.Bug .. " Debug") then
        debugTab()
        Gui.endTabItem()
    end
    Gui.endTabBar()
end
