-- Sideline: ball-following sideline camera.
--
-- Only drives the camera when this script is the active (or followed) camera. In overlay
-- mode it never touches the camera, so it composes with Plutus Autocaster and friends.
--
-- Geometry follows yuki's od-sideline-cam (https://github.com/vrdeeznuts/od-sideline-cam):
-- project the ball into the arena frame, dolly along the touchline, rise and hook inward near
-- the endzones, raycast down to stay above the floor, and lead the aim by ball velocity.
--
-- Two deliberate departures:
--   * The frame comes from the gamemode's own ModuleStateSpectatorLuaApi.transform instead of
--     hardcoded arena centres and slot ids -- the part its author called hardest to maintain.
--   * Auto zoom frames the ACTION (ball plus nearby players), not the ball. Framing a 35cm
--     ball at a sane screen fraction from 26m out asks for a ~5 degree FOV, so a ball-framing
--     zoom just sits pinned at whatever the minimum FOV is.

local Util = require("util")

local Sideline = {}

Sideline.settings = {}          -- filled from the active profile by main
Sideline.debug = {
    side = 1, blend = 1, fov = 90, groundLift = 0,
    hasBall = false, subject = 0, dwell = 0,
}

local sideTarget = 1            -- which touchline we want to be on (-1 / +1)
local sideBlend = 1             -- where we actually are; animated for a smooth crossing
local dwellTimer = 0
local smoothDolly = nil
local smoothLook = nil
local activeFov = 90
local wasDriving = false

-- Arena basis. Goals sit along the arena's own Y axis (Plutus rotates its goal offset by
-- yaw +/-90 to reach them), so Y is the length axis and X is the width axis.
local function frame(match)
    local rot = match.transform.rotation
    return rot:getForwardVector(),  -- width  (touchline offset direction)
        rot:getRightVector(),       -- length (goal to goal)
        rot:getUpVector()
end

-- Vertical FOV that makes an object of `diameter` at `distance` fill `frac` of the screen.
local function fovForScreenSize(distance, diameter, frac)
    if distance < 1 or frac <= 0 then return Sideline.settings.fovFixed end
    return math.deg(2 * math.atan(diameter / (2 * frac * distance)))
end

-- How big is the action? Radius of the players clustered around the ball, so the FOV opens up
-- for a scramble and tightens for a solo run.
local function subjectDiameter(match, ballPos)
    local s = Sideline.settings
    local radius = 0
    local frame_ = getGameData()
    if frame_ and ballPos then
        for _, p in frame_.players do
            if p.teamIndex ~= Util.TeamIndex.NoTeam then
                local d = Util.dist(ballPos, p.head.position)
                -- Ignore players on the far side of the station, or in another arena.
                if d < s.subjectMax and d > radius then radius = d end
            end
        end
    end
    return math.clamp(radius * 2 * s.subjectPadding, s.subjectMin, s.subjectMax)
end

local function updateSideTarget(widthOffset, dt)
    local s = Sideline.settings
    dwellTimer = math.max(0, dwellTimer - dt)
    if dwellTimer > 0 then return end
    local wanted = sideTarget
    if sideTarget == 1 and widthOffset < -s.switchThreshold then
        wanted = -1
    elseif sideTarget == -1 and widthOffset > s.switchThreshold then
        wanted = 1
    end
    if wanted ~= sideTarget then
        sideTarget = wanted
        dwellTimer = s.switchDwell
    end
end

-- Quadratic rise as the ball approaches an endzone, so the net stays in frame.
local function riserAdjust(lengthOffset)
    local s = Sideline.settings
    if s.riserScale <= 0 then return 0 end
    return (s.riserScale * 5e-5) * lengthOffset * lengthOffset
end

-- Past the quarterline, pull the dolly toward the middle and back off the endline.
local function hookAdjust(lengthOffset)
    local s = Sideline.settings
    if s.hookScale <= 0 then return 0, 0 end
    local quarter = s.lengthLimit * 0.5
    local mag = math.abs(lengthOffset)
    if mag <= quarter then return 0, 0 end
    local past = mag - quarter
    local sq = past * past
    return (s.hookScale * 1e-4) * sq, (s.hookScale * 0.6e-4) * sq
end

-- Push the dolly up if it ended up inside or under the floor.
local function liftAboveGround(pos, up)
    local s = Sideline.settings
    local hit = camera:castRay(pos + up * 600, pos - up * 5000)
    if not hit or not hit.successful then return pos, 0 end
    local floorHeight = hit.position:dot(up) + s.minHeightAboveGround
    local currentHeight = pos:dot(up)
    if currentHeight >= floorHeight then return pos, 0 end
    local lift = floorHeight - currentHeight
    return pos + up * lift, lift
end

-- True when this script owns the camera. In overlay mode we must not write to it at all.
function Sideline.isDriving()
    local s = Sideline.settings
    return s.enabled == true and (camera.isActive or camera.isFollowed)
end

function Sideline.update(dt, match)
    if not Sideline.isDriving() then
        wasDriving = false
        return
    end
    if match == nil then return end

    local s = Sideline.settings
    local widthAxis, lengthAxis, up = frame(match)
    local origin = match.transform.position
    local ball = match.ball
    local ballPos = ball and ball.transform.position or nil
    local ballVel = ball and (ball.velocity or Vec3.zeroVector) or Vec3.zeroVector

    -- No ball (warmup, between rounds, empty court): frame the arena so that picking an
    -- arena visibly does something instead of leaving the camera parked.
    local rawLook
    local widthOffset, lengthOffset, heightOffset
    if ballPos then
        local rel = ballPos - origin
        widthOffset = rel:dot(widthAxis)
        lengthOffset = rel:dot(lengthAxis)
        heightOffset = rel:dot(up)
        updateSideTarget(widthOffset, dt)
        rawLook = ballPos + ballVel * s.lead
    else
        widthOffset, lengthOffset, heightOffset = 0, 0, 0
        rawLook = origin + up * 300
    end
    Sideline.debug.hasBall = ballPos ~= nil

    -- Animate the crossing instead of teleporting. sideBlend runs continuously between the
    -- two touchlines, so a switch is a move rather than a jump cut.
    if s.switchMode == "cut" then
        sideBlend = sideTarget
    else
        local speed = 4 / math.max(s.switchSeconds, 0.05)
        sideBlend = Util.damp(sideBlend, sideTarget, speed, dt)
    end

    local hookWidth, hookLength = hookAdjust(lengthOffset)
    local lengthSign = lengthOffset >= 0 and 1 or -1

    local dollyWidth = sideBlend * s.sideDistance - hookWidth * sideBlend
    local dollyLength = math.clamp(lengthOffset, -s.lengthLimit, s.lengthLimit)
        - hookLength * lengthSign
    local dollyHeight = math.clamp(
        heightOffset + s.heightOffset + riserAdjust(lengthOffset), -85, s.maxHeight)

    local rawDolly = origin
        + widthAxis * dollyWidth
        + lengthAxis * dollyLength
        + up * dollyHeight

    local lift
    rawDolly, lift = liftAboveGround(rawDolly, up)
    Sideline.debug.groundLift = lift

    -- Hard cut only when taking over the camera or on an explicit cut-mode switch. Otherwise
    -- damp our own targets: the engine's smoothing was chasing a noisy target, which is what
    -- made this feel jittery rather than smooth.
    local takingOver = not wasDriving
    if takingOver or smoothDolly == nil then
        smoothDolly = rawDolly
        smoothLook = rawLook
    else
        smoothDolly = Util.dampVec3(smoothDolly, rawDolly, s.followSpeed, dt)
        smoothLook = Util.dampVec3(smoothLook, rawLook, s.aimSpeed, dt)
    end

    if takingOver then
        camera.positionSmoothing = 0
        camera.rotationSmoothing = 0
        camera.fieldOfViewSmoothing = 0
    else
        camera.positionSmoothing = s.positionSmoothing
        camera.rotationSmoothing = s.rotationSmoothing
        camera.fieldOfViewSmoothing = s.fovSmoothing
    end
    wasDriving = true

    -- Field of view
    local subject = subjectDiameter(match, ballPos)
    Sideline.debug.subject = subject
    local targetFov = s.fovFixed
    if s.autoZoom then
        targetFov = math.clamp(
            fovForScreenSize(Util.dist(smoothDolly, smoothLook), subject, s.zoomFraction),
            math.min(s.fovMin, s.fovMax), math.max(s.fovMin, s.fovMax))
    end
    activeFov = targetFov

    -- lookAt with an up vector parallel to the view direction gimbal-locks.
    local viewDir = (smoothLook - smoothDolly):getSafeNormal()
    local safeUp = up
    if math.abs(viewDir:dot(up)) > 0.999 then safeUp = widthAxis end

    camera.position = smoothDolly
    camera:lookAt(smoothLook, safeUp)
    camera.fieldOfView = activeFov

    Sideline.debug.side = sideTarget
    Sideline.debug.blend = sideBlend
    Sideline.debug.fov = activeFov
    Sideline.debug.dwell = dwellTimer
end

-- Called when the arena changes, so the next frame cuts rather than sweeping across
-- the station from the old arena.
function Sideline.reset()
    wasDriving = false
    smoothDolly = nil
    smoothLook = nil
    dwellTimer = 0
end

function Sideline.flipSide()
    sideTarget = -sideTarget
    dwellTimer = Sideline.settings.switchDwell or 0
end

return Sideline
