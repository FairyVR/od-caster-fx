-- Freecam: manual flying camera, for placing logo slots by eye.
--
-- Rewritten after the first version was unusable. Numbers and feel follow UVC's freecam,
-- which is the reference implementation in the spectator ecosystem:
--
--   * mouseSensitivity 3.6, not 0.25. The first version was ~14x too slow, which felt like
--     the mouse was doing nothing at all.
--   * moveSpeed 1600 cm/s, not 900. An arena is tens of metres across.
--   * Look is ALWAYS on, not gated behind holding right mouse.
--   * Look input accumulates into a target and is smoothed, rather than being applied raw
--     per frame -- that is the difference between "snappy" and "jittery".
--   * Speed adjusts live with the scroll wheel, because the right speed for crossing an
--     arena is not the right speed for nudging up to a scoreboard.
--
-- Controls: WASD move, R/E/Space/PageUp up, F/Q/C/PageDown down, mouse look, Shift fast,
-- Ctrl slow, scroll speed, Home snap to the arena.

local Freecam = {}

Freecam.enabled = false
Freecam.speed = 1600
Freecam.lookSensitivity = 3.6
Freecam.lookSmoothing = 0.55
Freecam.requireRightMouse = false
Freecam.debug = { yaw = 0, pitch = 0, speed = 0 }

local position = nil
local yaw, pitch = 0, 0
local lookTarget = Vec2.zeroVector      -- accumulated, unconsumed look input
local initialised = false

-- Yaw and pitch from a DIRECTION, never from euler decomposition.
--
-- Reading camera.rotation:euler() and rebuilding with Quat.fromEuler(0, pitch, yaw) looks
-- like it drops roll, but it does not: the pitch and yaw of a rolled rotation only
-- reconstruct that rotation *together with* its roll term. Throw the roll away and you get a
-- different orientation, frequently upside down. The sideline camera produces rolled
-- rotations routinely, because it aims with lookAt using the ARENA's up vector rather than
-- the world's, so entering freecam from it hit this every time.
--
-- Unreal convention: X forward, Y right, Z up; positive pitch looks up.
local function anglesFromForward(forward)
    local f = forward:getSafeNormal()
    if f:length() < 0.001 then return 0, 0 end
    local yawDegrees = math.deg(math.atan2(f.y, f.x))
    local pitchDegrees = math.deg(math.asin(math.clamp(f.z, -1, 1)))
    return yawDegrees, math.clamp(pitchDegrees, -89, 89)
end

Freecam.anglesFromForward = anglesFromForward

-- Seed from wherever the camera currently is, so enabling freecam never jumps the view.
function Freecam.takeOver()
    position = camera.position
    yaw, pitch = anglesFromForward(camera.rotation:getForwardVector())
    lookTarget = Vec2.zeroVector
    initialised = true
end

function Freecam.snapTo(match)
    if match == nil then return end
    local rot = match.transform.rotation
    local arenaUp = rot:getUpVector()
    position = match.transform.position + rot:getForwardVector() * 2200 + arenaUp * 700
    yaw, pitch = anglesFromForward(match.transform.position + arenaUp * 300 - position)
    lookTarget = Vec2.zeroVector
    initialised = true
end

function Freecam.isDriving()
    return Freecam.enabled and (camera.isActive or camera.isFollowed)
end

function Freecam.update(dt, match)
    if not Freecam.isDriving() then
        initialised = false
        return
    end
    if not initialised then Freecam.takeOver() end

    -- Look
    local lookAllowed = not Freecam.requireRightMouse or Input.getKey(Input.Key.RightMouseButton)
    if lookAllowed then
        local mouse = Input.getMouseDelta()
        if mouse then
            lookTarget = Vec2.new(
                lookTarget.x + mouse.x * Freecam.lookSensitivity,
                lookTarget.y + mouse.y * Freecam.lookSensitivity)
        end
    end
    -- Consume a fraction of the accumulated input each frame. Cubed so the slider's top end
    -- is genuinely smooth rather than merely slow.
    local consume = math.min((1 - (1 - (1 - Freecam.lookSmoothing) ^ 3)) * dt * 60, 1)
    local applied = Vec2.new(lookTarget.x * consume, lookTarget.y * consume)
    yaw += applied.x
    pitch += applied.y
    lookTarget = Vec2.new(lookTarget.x - applied.x, lookTarget.y - applied.y)
    -- Stop short of straight up/down; at exactly +/-90 the basis degenerates.
    pitch = math.clamp(pitch, -89, 89)

    -- Speed, adjustable live
    if Input.getKey(Input.Key.MouseScrollUp) then Freecam.speed *= 1.08 end
    if Input.getKey(Input.Key.MouseScrollDown) then Freecam.speed /= 1.08 end
    Freecam.speed = math.clamp(Freecam.speed, 50, 40000)

    -- Snap moved off Space, which is now an up-movement alternative. Home, or the GUI button.
    if Input.getKeyDown(Input.Key.Home) then Freecam.snapTo(match) end

    local rotation = Quat.fromEuler(0, pitch, yaw)
    local forward = rotation:getForwardVector()
    local right = rotation:getRightVector()
    local worldUp = gravity.strength > 0 and gravity.upDirection or Vec3.upVector

    -- R/F did not work in game even though the code was right, so up/down accept several
    -- alternatives rather than betting on one key the client might be swallowing.
    -- Freecam.keys below reports what is actually being detected.
    local anyOf = function(...)
        for _, key in { ... } do
            if Input.getKey(key) then return true end
        end
        return false
    end

    local move = Vec3.zeroVector
    if anyOf(Input.Key.W) then move = move + forward end
    if anyOf(Input.Key.S) then move = move - forward end
    if anyOf(Input.Key.D) then move = move + right end
    if anyOf(Input.Key.A) then move = move - right end
    if anyOf(Input.Key.R, Input.Key.E, Input.Key.SpaceBar, Input.Key.PageUp) then
        move = move + worldUp
    end
    if anyOf(Input.Key.F, Input.Key.Q, Input.Key.C, Input.Key.PageDown) then
        move = move - worldUp
    end

    local speed = Freecam.speed
    if Input.getKey(Input.Key.LeftShift) then speed = speed * 4 end
    if Input.getKey(Input.Key.LeftControl) then speed = speed * 0.2 end

    if not move:isNearlyZero() then
        position = position + move:getSafeNormal() * (speed * dt)
    end

    -- Light smoothing on position only; rotation is already smoothed above, and smoothing it
    -- twice feels like input lag.
    camera.positionSmoothing = 0.03
    camera.rotationSmoothing = 0
    camera.fieldOfViewSmoothing = 0.1
    camera.position = position
    camera.rotation = rotation

    Freecam.debug.yaw = yaw
    Freecam.debug.pitch = pitch
    Freecam.debug.speed = speed
end

-- Where the freecam is looking, for "place the selected slot in front of me".
function Freecam.aimPoint(distance)
    if position == nil then return nil end
    local rotation = Quat.fromEuler(0, pitch, yaw)
    -- Prefer whatever surface is actually being looked at, so placing a logo on a scoreboard
    -- lands ON the scoreboard rather than floating a fixed distance in front of the camera.
    local forward = rotation:getForwardVector()
    local hit = camera:castRay(position, position + forward * 20000)
    if hit and hit.successful then
        return hit.position - forward * 5   -- just off the surface, not inside it
    end
    return position + forward * (distance or 600)
end

function Freecam.getPosition()
    return position
end

-- Live state of every key this camera cares about, so a key the client swallows can be
-- identified by looking at the GUI instead of guessing. Names match Input.Key.
local PROBE_KEYS = {
    { "W", Input.Key.W }, { "A", Input.Key.A }, { "S", Input.Key.S }, { "D", Input.Key.D },
    { "R", Input.Key.R }, { "F", Input.Key.F }, { "E", Input.Key.E }, { "Q", Input.Key.Q },
    { "C", Input.Key.C }, { "Space", Input.Key.SpaceBar },
    { "PgUp", Input.Key.PageUp }, { "PgDn", Input.Key.PageDown },
    { "Shift", Input.Key.LeftShift }, { "Ctrl", Input.Key.LeftControl },
    { "RMB", Input.Key.RightMouseButton }, { "Home", Input.Key.Home },
}

function Freecam.keyReport()
    local down, up = {}, {}
    for _, entry in PROBE_KEYS do
        if Input.getKey(entry[2]) then
            table.insert(down, entry[1])
        else
            table.insert(up, entry[1])
        end
    end
    return down, up
end

return Freecam
