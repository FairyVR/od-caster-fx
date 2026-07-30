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
-- Controls: WASD move, R/F up-down, mouse look, Shift fast, Ctrl slow, scroll speed,
-- Space snap to the arena, Q/E roll reset.

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

-- Seed from wherever the camera currently is, so enabling freecam never jumps the view.
function Freecam.takeOver()
    position = camera.position
    local euler = camera.rotation:euler()   -- (roll, pitch, yaw) degrees
    pitch = euler.y
    yaw = euler.z
    lookTarget = Vec2.zeroVector
    initialised = true
end

function Freecam.snapTo(match)
    if match == nil then return end
    local rot = match.transform.rotation
    local worldUp = rot:getUpVector()
    position = match.transform.position + rot:getForwardVector() * 2200 + worldUp * 700
    local look = (match.transform.position + worldUp * 300 - position):getSafeNormal()
    local e = Quat.fromXZ(look, worldUp):euler()
    pitch = e.y
    yaw = e.z
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

    if Input.getKeyDown(Input.Key.SpaceBar) then Freecam.snapTo(match) end

    local rotation = Quat.fromEuler(0, pitch, yaw)
    local forward = rotation:getForwardVector()
    local right = rotation:getRightVector()
    local worldUp = gravity.strength > 0 and gravity.upDirection or Vec3.upVector

    local move = Vec3.zeroVector
    if Input.getKey(Input.Key.W) then move = move + forward end
    if Input.getKey(Input.Key.S) then move = move - forward end
    if Input.getKey(Input.Key.D) then move = move + right end
    if Input.getKey(Input.Key.A) then move = move - right end
    if Input.getKey(Input.Key.R) then move = move + worldUp end
    if Input.getKey(Input.Key.F) then move = move - worldUp end

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

return Freecam
