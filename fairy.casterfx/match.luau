-- Match: live state for one gamemode slot (arena transform, teams, ball, goal/kickoff events).
--
-- Arena classification and goal offsets are the same values Plutus Autocaster
-- (plutus.autocaster) uses, so offsets are interchangeable between the two scripts.

local Util = require("util")

local HOME_ROT = Quat.fromEuler(0, 0, 90)
local AWAY_ROT = Quat.fromEuler(0, 0, -90)

local ARENA_TYPES = {
    ["3v3"]        = { goalOffset = Vec3.new(3250, 0, 175), height = 1440 },
    ["4v4"]        = { goalOffset = Vec3.new(4085, 0, 270), height = 1730 },
    ["driftblitz"] = { goalOffset = Vec3.new(5295, 0, 175), height = 1440 },
    ["zdrift"]     = { goalOffset = Vec3.new(8200, 0, 585), height = 1710 },
}

local function classify(slotId)
    if slotId:find("TKB") and not slotId:find("Driftplex") and not slotId:find("Full")
        and not slotId:find("Playground") then
        return "3v3"
    end
    if slotId:find("Soccer") then return "driftblitz" end
    if slotId:find("Jakeball") or slotId:find("Driftball")
        or (slotId:find("TKB") and slotId:find("Driftplex") and not slotId:find("Full"))
        or slotId:find("Beta") or slotId:find("Gamma") or slotId:find("Alpha") then
        return "4v4"
    end
    if slotId:find("ZDrift") then return "zdrift" end
    return nil
end

local Match = {}
Match.__index = Match

local function newTeam(teamIndex)
    return {
        teamIndex = teamIndex,
        name = "",
        color = LinearColor.White,
        score = 0,
        previousScore = 0,
        roundsWon = 0,
        logoIndex = 0,
        goalPosition = Vec3.zeroVector,
        goalRotation = Quat.identity,
    }
end

function Match.new(api)
    local self = setmetatable({}, Match)
    self.api = api
    self.slotId = api:getSlotId()
    self.type = classify(self.slotId)
    self.arenaHeight = self.type and ARENA_TYPES[self.type].height or 1440
    self.name = (self.slotId:gsub("TKB", ""))
    self.transform = api.transform
    self.home = newTeam(Util.TeamIndex.HomeTeam)
    self.away = newTeam(Util.TeamIndex.AwayTeam)
    self.isRunning = false
    self.wasRunning = false
    self.ball = nil
    self.events = {}
    self.primed = false -- first tick seeds scores so we don't fire a goal on load
    return self
end

-- Enumerate every gamemode slot this station has. Cheap enough to call on a timer,
-- not per frame -- listGamemodes() allocates.
function Match.listAll()
    local out = {}
    for _, api in SpectatorGamemodes.listGamemodes() do
        local ok, m = pcall(Match.new, api)
        if ok and m and m.type then table.insert(out, m) end
    end
    table.sort(out, function(a, b) return a.slotId < b.slotId end)
    return out
end

function Match:teamRotation(teamIndex)
    if teamIndex == Util.TeamIndex.HomeTeam then return self.transform.rotation * HOME_ROT end
    return self.transform.rotation * AWAY_ROT
end

function Match:updateGoals()
    local spec = ARENA_TYPES[self.type]
    if not spec then return end
    for _, team in { self.home, self.away } do
        local rotOffset = team.teamIndex == Util.TeamIndex.HomeTeam and HOME_ROT or AWAY_ROT
        local teamRot = self.transform.rotation * rotOffset
        team.goalPosition = self.transform.position + teamRot:rotateVector(spec.goalOffset)
        team.goalRotation = self.transform.rotation * rotOffset:inverse()
    end
end

function Match:findBall()
    local frame = getGameData()
    if not frame then return nil end
    local best, bestDist = nil, math.huge
    for _, b in frame.balls do
        if Util.isArenaBall(b) then
            local d = Util.dist(self.transform.position, b.transform.position)
            if d < bestDist then bestDist = d; best = b end
        end
    end
    -- Balls from other arenas on the same station are far away; ignore them.
    if best and bestDist > 20000 then return nil end
    return best
end

local function readTeam(team, data)
    if not data then return end
    team.previousScore = team.score
    team.score = data.score or 0
    team.roundsWon = data.roundsWon or 0
    local tc = data.teamColor
    if tc then
        team.name = tc.teamName or ""
        team.logoIndex = tc.teamLogoIndex or 0
        if tc.primary then team.color = Util.linearColor(tc.primary) end
    end
end

function Match:tick()
    self.events = {}
    self.transform = self.api.transform

    local data = SpectatorGamemodes.getGamemodeData(self.slotId)
    if not data then return end

    readTeam(self.home, data.teams and data.teams[1])
    readTeam(self.away, data.teams and data.teams[2])
    self:updateGoals()

    self.wasRunning = self.isRunning
    self.isRunning = data.isGameRunning == true
    self.timeSeconds = data.timeSeconds or 0

    if not self.primed then
        -- Seed on the first tick so a script reload mid-match doesn't fire phantom goals.
        self.home.previousScore = self.home.score
        self.away.previousScore = self.away.score
        self.wasRunning = self.isRunning
        self.primed = true
        return
    end

    -- A team's score going up means they scored. The ball is in the *other* team's goal.
    for _, team in { self.home, self.away } do
        if team.score > team.previousScore then
            local conceded = team.teamIndex == Util.TeamIndex.HomeTeam and self.away or self.home
            table.insert(self.events, {
                kind = "goal",
                team = team,
                position = conceded.goalPosition,
                rotation = conceded.goalRotation,
            })
        end
    end

    if self.isRunning and not self.wasRunning then
        table.insert(self.events, { kind = "kickoff", position = self.transform.position })
    end

    self.ball = self:findBall()
end

return Match
