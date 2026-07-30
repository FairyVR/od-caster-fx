-- Sideline: ball-following sideline camera.
--
-- Only drives the camera when this script is the active (or followed) camera. In overlay
-- mode it never touches the camera, so it composes with Plutus Autocaster and friends.
--
-- Geometry follows yuki's od-sideline-cam (https://github.com/vrdeeznuts/od-sideline-cam):
-- project the ball into the arena frame, dolly along the touchline, switch sides with
-- hysteresis, rise and hook inward near the endzones, raycast down to stay above the floor,
-- and lead the aim by ball velocity.
--
-- The difference: that script hardcodes arena centres and slot ids, which its author called
-- the hardest part to maintain. This one takes the frame from the gamemode's own
-- ModuleStateSpectatorLuaApi.transform, so it works on any arena the client reports,
-- including Ares servers, with nothing to update.

local Util = require("util")

local Sideline = {}

Sideline.settings = {
    enabled = true,
    sideDistance = 2600,      -- cm from the centre line out to the touchline
    lengthLimit = 2200,       -- how far along the arena the dolly tracks the ball
    heightOffset = 220,       -- cm above the ball
    maxHeight = 1250,
    minHeightAboveGround = 130,
    riserScale = 1.0,         -- endzone riser strength (quadratic in length)
    hookScale = 1.0,          -- endzone inward hook strength
    switchThreshold = 400,    -- ball must cross this far past centre to switch sides
    switchInstant = true,     -- hard cut on a side switch instead of sweeping through play
    lead = 0.45,              -- seconds of ball velocity to aim ahead
    positionSmoothing = 0.25,
    rotationSmoothing = 0.12,
    fovSmoothing = 0.2,
    autoZoom = true,
    zoomFraction = 0.16,      -- ball diameter as a fraction of vertical screen height
    fovMin = 35,
    fovMax = 95,
    fovFixed = 70,            -- used when autoZoom is off
}

local BALL_DIAMETER = 35      -- cm; ball radius is 17.5

local currentSide = 1
local previousSide = 1
local activeFov = 70
local wasDriving = false

Sideline.debug = { side = 1, fov = 70, groundLift = 0, hasBall = false }

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
    local visibleHeight = diameter / frac
    return math.deg(2 * math.atan((visibleHeight * 0.5) / distance))
end

local function autoSwitchSides(widthOffset)
    local s = Sideline.settings
    if currentSide == 1 and widthOffset < -s.switchThreshold then
        currentSide = -1
    elseif currentSide == -1 and widthOffset > s.switchThreshold then
        currentSide = 1
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
    local rayStart = pos + up * 600
    local rayEnd = pos - up * 5000
    local hit = camera:castRay(rayStart, rayEnd)
    if not hit or not hit.successful then return pos, 0 end
    local floorHeight = hit.position:dot(up) + s.minHeightAboveGround
    local currentHeight = pos:dot(up)
    if currentHeight >= floorHeight then return pos, 0 end
    local lift = floorHeight - currentHeight
    return pos + up * lift, lift
end

-- True when this script owns the camera. In overlay mode we must not write to it at all.
function Sideline.isDriving()
    return Sideline.settings.enabled and (camera.isActive or camera.isFollowed)
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
    local lookTarget
    local widthOffset, lengthOffset, heightOffset
    if ballPos then
        local rel = ballPos - origin
        widthOffset = rel:dot(widthAxis)
        lengthOffset = rel:dot(lengthAxis)
        heightOffset = rel:dot(up)
        autoSwitchSides(widthOffset)
        lookTarget = ballPos + ballVel * s.lead
    else
        widthOffset, lengthOffset, heightOffset = 0, 0, 0
        lookTarget = origin + up * 300
    end
    Sideline.debug.hasBall = ballPos ~= nil

    local hookWidth, hookLength = hookAdjust(lengthOffset)
    local lengthSign = lengthOffset >= 0 and 1 or -1

    local dollyWidth = currentSide * s.sideDistance - hookWidth * currentSide
    local dollyLength = math.clamp(lengthOffset, -s.lengthLimit, s.lengthLimit)
        - hookLength * lengthSign
    local dollyHeight = math.clamp(
        heightOffset + s.heightOffset + riserAdjust(lengthOffset), -85, s.maxHeight)

    local dollyPos = origin
        + widthAxis * dollyWidth
        + lengthAxis * dollyLength
        + up * dollyHeight

    local lift
    dollyPos, lift = liftAboveGround(dollyPos, up)
    Sideline.debug.groundLift = lift

    -- Field of view
    local targetFov = s.fovFixed
    if s.autoZoom and ballPos then
        targetFov = math.clamp(
            fovForScreenSize(Util.dist(dollyPos, ballPos), BALL_DIAMETER, s.zoomFraction),
            s.fovMin, s.fovMax)
    end
    activeFov = targetFov

    -- Cut instantly on a side switch or on taking over the camera, otherwise the dolly
    -- sweeps straight through the middle of play, or drifts in from wherever it was.
    local hardCut = (s.switchInstant and currentSide ~= previousSide) or not wasDriving
    if hardCut then
        camera.positionSmoothing = 0
        camera.rotationSmoothing = 0
        camera.fieldOfViewSmoothing = 0
        if ballPos then lookTarget = ballPos end
    else
        camera.positionSmoothing = s.positionSmoothing
        camera.rotationSmoothing = s.rotationSmoothing
        camera.fieldOfViewSmoothing = s.fovSmoothing
    end
    previousSide = currentSide
    wasDriving = true

    -- lookAt with an up vector parallel to the view direction gimbal-locks.
    local viewDir = (lookTarget - dollyPos):getSafeNormal()
    local safeUp = up
    if math.abs(viewDir:dot(up)) > 0.999 then safeUp = widthAxis end

    camera.position = dollyPos
    camera:lookAt(lookTarget, safeUp)
    camera.fieldOfView = activeFov

    Sideline.debug.side = currentSide
    Sideline.debug.fov = activeFov
end

-- Called when the arena changes, so the next frame cuts rather than sweeping across
-- the station from the old arena.
function Sideline.reset()
    wasDriving = false
end

function Sideline.flipSide()
    currentSide = -currentSide
end

return Sideline
