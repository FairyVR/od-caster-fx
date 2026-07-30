-- Freecam: manual flying camera, for placing logo slots by eye.
--
-- This is a port of AA's shipped aa.freecam.luau (main.luau + inputs.luau + util.luau),
-- because two hand-rolled attempts both felt wrong. Everything below that looks fiddly is
-- fiddly for a reason, and the reasons are:
--
--   * Rotation is stored as an euler RELATIVE TO A GRAVITY FRAME, and applied as
--     `gravityChaser * Quat.fromEuler(roll, pitch, yaw)`. That is what makes roll a real
--     independent axis and lets the camera re-level itself against gravity without the
--     pitch/yaw fighting it. Storing an absolute yaw/pitch, as I did before, cannot express
--     roll at all -- which is exactly why roll "wasn't allowed".
--   * Look input accumulates into lookInputTarget and is consumed a fraction per frame, so
--     smoothing is a property of the input rather than of the camera transform.
--   * Look input is rotated by the current roll angle before being applied, so dragging the
--     mouse sideways still yaws the way you expect while rolled.
--   * Shift/Ctrl RAMP the move speed continuously rather than acting as hold-to-multiply.
--
-- Controls (same as AA's, deliberately -- muscle memory should transfer):
--   WASD move, E up, Q down, Alt swaps local/gravity-aligned axes
--   Mouse look, RIGHT MOUSE + drag to roll, arrows pitch/yaw
--   Shift faster, Ctrl slower, scroll zoom, Space re-level to gravity
--   Home snap to the selected arena

local Freecam = {}

Freecam.enabled = false

-- Tunables, mirroring aa.freecam's inputs.luau.
Freecam.moveSpeed = 1600
Freecam.mouseSensitivity = 3.6
Freecam.lookSmoothness = 0          -- 0 = raw and immediate, which is AA's default
Freecam.speedAdjustmentRate = 1
Freecam.minMoveSpeed = 200
Freecam.maxMoveSpeed = 25000
Freecam.rotSpeed = 180
Freecam.fovRotSpeedMultiplier = 2   -- slows rotation when zoomed in
Freecam.rollResetTolerance = 5
Freecam.gravityChaseSpeed = 6
Freecam.gravitySlowChaseSpeed = 0.5
Freecam.alignToGravity = true
Freecam.localMovementAxes = true
Freecam.minFov = 10
Freecam.maxFov = 160
Freecam.zoomSpeed = 5

Freecam.debug = { roll = 0, pitch = 0, yaw = 0, speed = 0 }

local rotEuler = Vec3.zeroVector        -- (roll, pitch, yaw) in the gravity frame
local lookInputTarget = Vec3.zeroVector
local gravityChaser = gravity.upRotation
local initialised = false

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

local function projectOntoPlane(vec, normal)
    local n = normal:getSafeNormal()
    return vec - n * vec:dot(n)
end

local function xor(a, b)
    return (a and not b) or (not a and b)
end

-- Yaw/pitch from a direction. Used only when seeding, never per frame.
--
-- Deriving these from a Quat's euler and discarding the roll term does NOT remove roll: the
-- pitch and yaw of a rolled rotation only reconstruct it together with that roll, so
-- dropping it flips the camera. Going through the direction vector is roll-free by
-- construction. Unreal convention: X forward, Y right, Z up, positive pitch looks up.
local function anglesFromForward(forward)
    local f = forward:getSafeNormal()
    if f:length() < 0.001 then return 0, 0 end
    local yaw = math.deg(math.atan2(f.y, f.x))
    local pitch = math.deg(math.asin(math.clamp(f.z, -1, 1)))
    return yaw, math.clamp(pitch, -89.9, 89.9)
end

Freecam.anglesFromForward = anglesFromForward

local function snapToGravity()
    gravityChaser = gravity.upRotation
    rotEuler = Vec3.new(0, rotEuler.y, rotEuler.z)
end

--------------------------------------------------------------------------------
-- Entry points
--------------------------------------------------------------------------------

-- Seed from wherever the camera currently is, so enabling freecam never jumps the view.
function Freecam.takeOver()
    -- AA's Util.setSmoothing(false) values. Set once on entry rather than per frame, so the
    -- sliders elsewhere are not fought, and so the freecam does not inherit the sideline
    -- camera's much heavier smoothing, which would feel like input lag.
    camera.positionSmoothing = 0.02
    camera.rotationSmoothing = 0.02
    camera.fieldOfViewSmoothing = 0.05

    gravityChaser = gravity.upRotation
    -- Express the current facing INSIDE the gravity frame before extracting angles, since
    -- that frame is what rotEuler is relative to.
    local localForward = gravityChaser:inverse():rotateVector(camera.rotation:getForwardVector())
    local yaw, pitch = anglesFromForward(localForward)
    rotEuler = Vec3.new(0, pitch, yaw)
    lookInputTarget = Vec3.zeroVector
    initialised = true
end

function Freecam.snapTo(match)
    if match == nil then return end
    local rot = match.transform.rotation
    local arenaUp = rot:getUpVector()
    camera.position = match.transform.position + rot:getForwardVector() * 2200 + arenaUp * 700
    gravityChaser = gravity.upRotation
    local toCentre = match.transform.position + arenaUp * 300 - camera.position
    local localForward = gravityChaser:inverse():rotateVector(toCentre)
    local yaw, pitch = anglesFromForward(localForward)
    rotEuler = Vec3.new(0, pitch, yaw)
    lookInputTarget = Vec3.zeroVector
    initialised = true
end

function Freecam.isDriving()
    return Freecam.enabled and (camera.isActive or camera.isFollowed)
end

--------------------------------------------------------------------------------
-- Update -- follows aa.freecam's tick order
--------------------------------------------------------------------------------

function Freecam.update(dt, match)
    if not Freecam.isDriving() then
        initialised = false
        return
    end
    if not initialised then Freecam.takeOver() end

    local forward = camera.rotation:getForwardVector()
    local right = camera.rotation:getRightVector()
    local up = camera.rotation:getUpVector()
    local gravityDirection = gravityChaser:getUpVector()
    local gravityForward = projectOntoPlane(forward, gravityDirection):getSafeNormal()
    -- Alt swaps between camera-local axes and gravity-aligned ones.
    local useLocalAxes = xor(Freecam.localMovementAxes, Input.getKey(Input.Key.LeftAlt))

    -- Speed ramps while held, rather than a hold-to-multiply.
    if Input.getKey(Input.Key.LeftShift) then
        Freecam.moveSpeed *= (1 + Freecam.speedAdjustmentRate * dt)
    elseif Input.getKey(Input.Key.LeftControl) then
        Freecam.moveSpeed *= (1 - Freecam.speedAdjustmentRate * dt)
    end
    Freecam.moveSpeed = math.clamp(Freecam.moveSpeed, Freecam.minMoveSpeed, Freecam.maxMoveSpeed)

    -- Zoom
    camera.fieldOfView -= Input.getAnalog(Input.Key.MouseWheelAxis) * Freecam.zoomSpeed
    camera.fieldOfView = math.clamp(camera.fieldOfView, Freecam.minFov, Freecam.maxFov)

    -- Movement
    local input = Vec3.zeroVector
    if Input.getKey(Input.Key.W) then
        input += useLocalAxes and forward or gravityForward
    end
    if Input.getKey(Input.Key.S) then
        input -= useLocalAxes and forward or gravityForward
    end
    if Input.getKey(Input.Key.D) then input += right end
    if Input.getKey(Input.Key.A) then input -= right end
    -- E up, Q down: AA's bindings. The previous R/F guess is why up and down did nothing.
    if Input.getKey(Input.Key.E) then
        input += useLocalAxes and up or gravityDirection
    end
    if Input.getKey(Input.Key.Q) then
        input -= useLocalAxes and up or gravityDirection
    end
    -- Gamepad
    input += right * Input.getAnalog(Input.Gamepad.LeftX)
    input += forward * Input.getAnalog(Input.Gamepad.LeftY)
    input += up * Input.getAnalog(Input.Gamepad.RightTriggerAxis)
    input -= up * Input.getAnalog(Input.Gamepad.LeftTriggerAxis)

    -- Rotation. Zoomed in means slower rotation, or aiming at range is unusable.
    local fovFactor = Freecam.fovRotSpeedMultiplier * (camera.fieldOfView - 90) / 90
    local adjustedRotSpeed = fovFactor + Freecam.rotSpeed
    local adjustedSensitivity = fovFactor + Freecam.mouseSensitivity
    local adjustedLookSmoothness = 1 - (1 - Freecam.lookSmoothness) ^ 3
    local delta = Vec3.zeroVector

    local mouse = Input.getMouseDelta()
    local rollAngle = -rotEuler.x * math.pi / 180.0
    if mouse then
        if Input.getKey(Input.Key.RightMouseButton) then
            delta.x += mouse.x * Freecam.mouseSensitivity / 2.0     -- roll
        else
            delta.z += mouse.x * adjustedSensitivity                -- yaw
            delta.y += mouse.y * adjustedSensitivity                -- pitch
        end
    end

    if Input.getKey(Input.Key.Right) then delta.z += adjustedRotSpeed * dt end
    if Input.getKey(Input.Key.Left) then delta.z -= adjustedRotSpeed * dt end
    if Input.getKey(Input.Key.Up) then delta.y += adjustedRotSpeed * dt end
    if Input.getKey(Input.Key.Down) then delta.y -= adjustedRotSpeed * dt end

    if Input.getKey(Input.Gamepad.DPad_Right) then
        delta.x += Freecam.rotSpeed * dt / 2
    elseif Input.getKey(Input.Gamepad.DPad_Left) then
        delta.x -= Freecam.rotSpeed * dt / 2
    end
    delta.z += Input.getAnalog(Input.Gamepad.RightX) * adjustedRotSpeed * dt
    delta.y += Input.getAnalog(Input.Gamepad.RightY) * adjustedRotSpeed * dt

    -- Rotate the yaw/pitch input by the current roll, so sideways still means sideways
    -- on screen when the horizon is tilted.
    local rollAdjusted = Vec3.new(
        delta.x,
        delta.y * math.cos(rollAngle) + delta.z * math.sin(rollAngle),
        delta.z * math.cos(rollAngle) - delta.y * math.sin(rollAngle))
    lookInputTarget += rollAdjusted
    local nextLookDiff = lookInputTarget * math.min((1 - adjustedLookSmoothness) * dt * 60, 1)

    -- Chase gravity: fast while the view is moving, slowly otherwise, so it re-levels
    -- without lurching.
    if Freecam.alignToGravity and gravityChaser ~= gravity.upRotation and gravity.strength ~= 0 then
        local inputTotal = nextLookDiff:length()
        local nextChaser = Quat.slerp(gravityChaser, gravity.upRotation,
            (inputTotal * Freecam.gravityChaseSpeed + Freecam.gravitySlowChaseSpeed) * dt)
        local nextRotation = nextChaser:inverse()
            * Quat.fromXZ(forward, nextChaser:rotateVector(Vec3.new(0, 0, 1)))
        rotEuler = nextRotation:euler() + Vec3.new(rotEuler.x, 0, 0)   -- preserve roll
        gravityChaser = nextChaser
    end
    if Input.getKeyDown(Input.Key.SpaceBar) then snapToGravity() end
    if Input.getKeyDown(Input.Key.Home) then Freecam.snapTo(match) end

    rotEuler += nextLookDiff
    lookInputTarget -= nextLookDiff

    rotEuler.y = math.clamp(rotEuler.y, -89.9, 89.9)

    -- Snap roll back to level when releasing the roll modifier near zero.
    if Input.getKeyUp(Input.Key.RightMouseButton)
        or Input.getKeyUp(Input.Gamepad.DPad_Right)
        or Input.getKeyUp(Input.Gamepad.DPad_Left) then
        if math.abs(rotEuler.x) % 360 <= Freecam.rollResetTolerance then
            rotEuler.x = 0
            lookInputTarget.x = 0
        end
    end

    camera.position += input * Freecam.moveSpeed * dt
    camera.rotation = gravityChaser * Quat.fromEuler(rotEuler.x, rotEuler.y, rotEuler.z)

    Freecam.debug.roll = rotEuler.x
    Freecam.debug.pitch = rotEuler.y
    Freecam.debug.yaw = rotEuler.z
    Freecam.debug.speed = Freecam.moveSpeed
end

--------------------------------------------------------------------------------
-- Placement helper
--------------------------------------------------------------------------------

-- Where the freecam is looking, for "place the selected slot in front of me". Prefers the
-- surface actually being looked at, so a logo lands ON the scoreboard.
function Freecam.aimPoint(distance)
    local forward = camera.rotation:getForwardVector()
    local hit = camera:castRay(camera.position, camera.position + forward * 20000)
    if hit and hit.successful then
        return hit.position - forward * 5
    end
    return camera.position + forward * (distance or 600)
end

function Freecam.getPosition()
    return camera.position
end

-- Live state of every key this camera uses, so a key the client swallows can be identified
-- by looking at the GUI instead of guessing.
local PROBE_KEYS = {
    { "W", Input.Key.W }, { "A", Input.Key.A }, { "S", Input.Key.S }, { "D", Input.Key.D },
    { "E", Input.Key.E }, { "Q", Input.Key.Q }, { "Alt", Input.Key.LeftAlt },
    { "Shift", Input.Key.LeftShift }, { "Ctrl", Input.Key.LeftControl },
    { "RMB", Input.Key.RightMouseButton }, { "Space", Input.Key.SpaceBar },
    { "Home", Input.Key.Home },
}

function Freecam.keyReport()
    local down = {}
    for _, entry in PROBE_KEYS do
        if Input.getKey(entry[2]) then table.insert(down, entry[1]) end
    end
    return down
end

return Freecam
