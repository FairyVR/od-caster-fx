-- Freecam: manual flying camera, for placing logo slots by eye.
--
-- Takes over from the sideline camera while enabled, so you can fly up to a scoreboard,
-- see the quad you are dragging, and put it where it belongs. Only ever active when this
-- script owns the camera -- in overlay mode it does nothing.
--
-- Controls: WASD move, R/F up-down, hold right mouse to look, Shift fast, Ctrl slow,
-- Space to snap back to the arena.

local Freecam = {}

Freecam.enabled = false
Freecam.speed = 900            -- cm/s
Freecam.lookSensitivity = 0.25
Freecam.debug = { yaw = 0, pitch = 0, speed = 0 }

local position = nil
local yaw, pitch = 0, 0
local initialised = false

local function keys()
    return {
        forward = Input.getKey(Input.Key.W),
        back = Input.getKey(Input.Key.S),
        left = Input.getKey(Input.Key.A),
        right = Input.getKey(Input.Key.D),
        up = Input.getKey(Input.Key.R),
        down = Input.getKey(Input.Key.F),
        fast = Input.getKey(Input.Key.LeftShift),
        slow = Input.getKey(Input.Key.LeftControl),
        look = Input.getKey(Input.Key.RightMouseButton),
        snap = Input.getKeyDown(Input.Key.SpaceBar),
    }
end

-- Seed from wherever the camera currently is, so enabling freecam never jumps the view.
function Freecam.takeOver()
    position = camera.position
    local euler = camera.rotation:euler()
    -- Quat:euler() returns (roll, pitch, yaw) in degrees.
    pitch = euler.y
    yaw = euler.z
    initialised = true
end

function Freecam.snapTo(match)
    if match == nil then return end
    local rot = match.transform.rotation
    local up = rot:getUpVector()
    position = match.transform.position + rot:getForwardVector() * 1800 + up * 600
    local look = (match.transform.position + up * 300 - position):getSafeNormal()
    local e = Quat.fromXZ(look, up):euler()
    pitch = e.y
    yaw = e.z
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

    local k = keys()

    if k.look then
        local delta = Input.getMouseDelta()
        yaw += delta.x * Freecam.lookSensitivity
        pitch -= delta.y * Freecam.lookSensitivity
        -- Stop short of straight up/down; at exactly +/-90 the basis degenerates.
        pitch = math.clamp(pitch, -89, 89)
    end

    if k.snap then Freecam.snapTo(match) end

    local rotation = Quat.fromEuler(0, pitch, yaw)
    local forward = rotation:getForwardVector()
    local right = rotation:getRightVector()
    local worldUp = gravity.strength > 0 and gravity.upDirection or Vec3.upVector

    local move = Vec3.zeroVector
    if k.forward then move = move + forward end
    if k.back then move = move - forward end
    if k.right then move = move + right end
    if k.left then move = move - right end
    if k.up then move = move + worldUp end
    if k.down then move = move - worldUp end

    local speed = Freecam.speed
    if k.fast then speed = speed * 4 end
    if k.slow then speed = speed * 0.25 end

    if not move:isNearlyZero() then
        position = position + move:getSafeNormal() * (speed * dt)
    end

    camera.positionSmoothing = 0
    camera.rotationSmoothing = 0
    camera.fieldOfViewSmoothing = 0
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
    return position + rotation:getForwardVector() * (distance or 400)
end

function Freecam.getPosition()
    return position
end

return Freecam
