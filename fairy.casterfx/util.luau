-- Util: shared helpers for fairy.casterfx

local Util = {}

Util.TeamIndex = { NoTeam = -1, HomeTeam = 0, AwayTeam = 1 }

-- Color from the game is 0-1 in gamemode data but 0-255 from Color.new. Normalise either.
function Util.linearColor(c)
    if not c then return LinearColor.White end
    if c.R <= 1 and c.G <= 1 and c.B <= 1 then return LinearColor.new(c.R, c.G, c.B, 1) end
    return LinearColor.new(c.R / 255, c.G / 255, c.B / 255, 1)
end

function Util.colorEquals(a, b)
    if a == nil or b == nil then return a == b end
    return math.abs(a.R - b.R) < 0.002 and math.abs(a.G - b.G) < 0.002 and math.abs(a.B - b.B) < 0.002
end

-- Push a colour toward white/oversaturation. mul > 1 brightens.
function Util.boost(c, mul)
    return LinearColor.new(math.min(c.R * mul, 1), math.min(c.G * mul, 1), math.min(c.B * mul, 1), 1)
end

-- Blend toward white by t (0-1) for hot cores.
function Util.whiten(c, t)
    return LinearColor.new(c.R + (1 - c.R) * t, c.G + (1 - c.G) * t, c.B + (1 - c.B) * t, 1)
end

function Util.lerp(a, b, t) return a + (b - a) * t end

-- Exponential damping. Frame-rate independent, unlike a raw lerp by a fixed alpha.
function Util.damp(cur, tgt, speed, dt) return cur + (tgt - cur) * (1 - math.exp(-speed * dt)) end
function Util.dampVec3(cur, tgt, speed, dt)
    return Vec3.lerp(cur, tgt, 1 - math.exp(-speed * dt))
end
function Util.easeOutCubic(t) t = math.clamp(t, 0, 1); return 1 - (1 - t) ^ 3 end
function Util.smoothstep(t) t = math.clamp(t, 0, 1); return t * t * (3 - 2 * t) end

-- The arena ball is the white/white one; team-coloured balls belong to other modes.
function Util.isArenaBall(b)
    local white = Color.new(255, 255, 255, 255)
    return b.color1 == white and b.color2 == white
end

function Util.dist(a, b)
    return math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2 + (a.z - b.z) ^ 2)
end

-- Uniformly distributed unit vector (Marsaglia): rejection-free, no pole bias.
function Util.randomUnit()
    local z = math.random() * 2 - 1
    local a = math.random() * 2 * math.pi
    local r = math.sqrt(math.max(0, 1 - z * z))
    return Vec3.new(r * math.cos(a), r * math.sin(a), z)
end

function Util.randomRange(lo, hi) return lo + math.random() * (hi - lo) end

-- Any vector perpendicular to v, for building a basis without hitting the degenerate case.
function Util.perpendicular(v)
    local n = v:getSafeNormal()
    if n:length() < 0.001 then return Vec3.new(0, 1, 0) end
    local ref = math.abs(n.z) < 0.9 and Vec3.new(0, 0, 1) or Vec3.new(1, 0, 0)
    return Vec3.cross(n, ref):getSafeNormal()
end

-- Team name -> logo filename stem. MUST stay byte-for-byte identical to the
-- Sanitize function in get-logos.ps1, which walks the UTF-8 bytes for the same reason.
function Util.sanitizeTeamName(name)
    if name == nil or name == "" then return "TEAM" end
    local out = string.gsub(string.upper(name), "[^A-Z0-9]", "_")
    if out == "" then return "TEAM" end
    return out
end

-- Fill in missing config keys without clobbering user edits. Returns true if anything changed.
local function fillDefaults(defaults, target)
    local changed = false
    for k, v in pairs(defaults) do
        if target[k] == nil then
            target[k] = v
            changed = true
        elseif typeof(target[k]) ~= typeof(v) then
            target[k] = v
            changed = true
        elseif typeof(v) == "table" then
            if fillDefaults(v, target[k]) then changed = true end
        end
    end
    return changed
end

function Util.initializeConfig(defaults)
    if fillDefaults(defaults, config) then saveConfig() end
end

return Util
