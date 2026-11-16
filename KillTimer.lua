-- KillTimer.lua
-- Measures how long this character really takes per kill, so route times match how you play.
--
-- Each detected kill is timestamped. The gap between two consecutive kills in the same zone
-- is one sample: it covers walking to the next mob, pulling, fighting, looting and resting.
-- Gaps longer than MAX_GAP, kills in a different zone, deaths and flights break the chain,
-- because the player was doing something else. The median of recent samples is used.
--
-- Two ways to detect kills (chosen in Settings):
--   "events": the game's death events (PARTY_KILL / UNIT_DIED). Catches kills without a
--             target (AoE), and the mob's NPC ID gives its exact level and rank.
--   "xp":     the "X dies, you gain N experience" chat line. Needs the dead mob targeted
--             on clients whose message wording can't be matched.
-- The full combat log (COMBAT_LOG_EVENT_*) is NOT used: WoW Forever closes it to addons and
-- blocks an addon that registers for it.

local ADDON_NAME, ns = ...

local KillTimer = {}
ns.KillTimer = KillTimer

local MIN_SAMPLES = 20      -- below this, the built-in estimate is used
local MAX_SAMPLES = 60      -- only recent kills count; your speed changes with level and gear
local MIN_GAP = 1           -- seconds; AoE pulls produce near-zero gaps, which are real but noisy
local MAX_GAP = 120         -- seconds; anything longer means you were doing something else
local LEVEL_FACTOR = 0.08   -- each level the mob is above you adds ~8% fight time
local ELITE_FACTOR = 2.5    -- elites take much longer than their double XP suggests
local MERGE_WINDOW = 3      -- seconds: PARTY_KILL and UNIT_DIED for the same mob are one kill
local TARGET_WINDOW = 5     -- seconds: a targeted mob dying this soon after combat counts as ours

KillTimer.MIN_SAMPLES = MIN_SAMPLES
KillTimer.MODES = { "events", "xp" }

local lastKillTime, lastKillZone
local recentDeaths = {}     -- guid -> time, to merge duplicate death reports
local lastTargetGUID, lastCombatTime

---------------------------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------------------------

--- Values the Forever client hands over as "secret" can't be compared; treat them as unknown.
local function Plain(v)
    if type(issecretvalue) == "function" and issecretvalue(v) then return nil end
    return v
end

--- Built-in estimate (seconds per same-level kill, with downtime) before enough samples exist.
local function DefaultSeconds(playerLevel)
    return 16 + playerLevel * 0.2
end
KillTimer.DefaultSeconds = DefaultSeconds

local function Clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

--- Multiplier for a mob that is `diff` levels above (positive) or below (negative) the player.
local function LevelMultiplier(diff)
    return 1 + LEVEL_FACTOR * Clamp(diff or 0, -5, 4)
end

local function Settings()
    ZoneXPAdvisorDB = ZoneXPAdvisorDB or {}
    local db = ZoneXPAdvisorDB
    if db.killDetect ~= "events" and db.killDetect ~= "xp" then db.killDetect = "events" end
    return db
end

local function CharacterStore()
    local db = Settings()
    db.killTimes = db.killTimes or {}
    local name = UnitName("player") or "?"
    local realm = GetRealmName and GetRealmName() or "?"
    local key = name .. "-" .. realm
    local store = db.killTimes[key]
    if not store then
        store = { samples = {} }
        db.killTimes[key] = store
    end
    return store
end

local function BreakChain()
    lastKillTime, lastKillZone = nil, nil
end

--- "Creature-0-1234-0-56-6-0000ABCDEF" -> 6 (the NPC ID), or nil for players/pets.
local function NpcFromGUID(guid)
    guid = Plain(guid)
    if type(guid) ~= "string" then return nil end
    local unitType, _, _, _, _, npcId = strsplit("-", guid)
    if unitType ~= "Creature" and unitType ~= "Vehicle" then return nil end
    return tonumber(npcId)
end

--- Average level and rank of an NPC from QuestieDB, when available.
local function NpcInfo(npcId)
    local data = ns.Engine and ns.Engine.GetData and ns.Engine.GetData()
    local npc = data and data.Npc
    if not (npc and npcId) then return nil end
    local ok, lo, hi, rank = pcall(function()
        return npc.minLevel(npcId), npc.maxLevel(npcId), npc.rank(npcId)
    end)
    if not ok or not lo then return nil end
    return ((lo or 0) + (hi or lo or 0)) / 2, rank or 0
end

--- Highest level that gives no XP (classic thresholds).
local function GreyLevel(playerLevel)
    if playerLevel <= 5 then return 0 end
    if playerLevel <= 39 then return playerLevel - math.floor(playerLevel / 10) - 5 end
    return playerLevel - math.floor(playerLevel / 5) - 1
end

---------------------------------------------------------------------------------------------
-- Recording
---------------------------------------------------------------------------------------------

--- Records one kill. mobLevel may be nil (treated as same level); elite kills only advance
--- the chain, because their fight time says nothing about normal mobs.
local function RecordKill(mobLevel, elite)
    local now = GetTime()
    local zone = GetRealZoneText and GetRealZoneText() or ""
    local playerLevel = UnitLevel("player")

    if lastKillTime and zone == lastKillZone then
        local gap = now - lastKillTime
        if gap >= MIN_GAP and gap <= MAX_GAP and not elite then
            -- Normalise to a same-level mob so samples from different mobs are comparable.
            local diff = mobLevel and (mobLevel - playerLevel) or 0
            local samples = CharacterStore().samples
            samples[#samples + 1] = { gap / LevelMultiplier(diff), playerLevel }
            while #samples > MAX_SAMPLES do table.remove(samples, 1) end
        end
    end
    lastKillTime, lastKillZone = now, zone
end

--- Level and elite status of the dead target, when it is still targeted.
local function DeadTargetInfo()
    if UnitExists and UnitExists("target") and UnitIsDead and UnitIsDead("target") then
        local level = UnitLevel("target")
        if level and level < 0 then level = UnitLevel("player") + 4 end -- skull: treat as +4
        local classification = UnitClassification and UnitClassification("target") or "normal"
        local elite = classification == "elite" or classification == "rareelite" or classification == "worldboss"
        return true, level, elite
    end
    return false
end

-- XP mode -------------------------------------------------------------------------------

--- The literal text between the mob name and the XP number in the client's kill message,
--- e.g. " dies, you gain " from "%s dies, you gain %d experience.".
local killMarker
do
    local fmt = COMBATLOG_XPGAIN_FIRSTPERSON
    if type(fmt) == "string" then
        local middle = fmt:match("^%%s(.-)%%d")
        -- Skip formats with grammar tokens (|1...;) that never appear verbatim in the message.
        if middle and middle ~= "" and not middle:find("|", 1, true) then killMarker = middle end
    end
end

local function OnXPMessage(message)
    local targetDead, level, elite = DeadTargetInfo()
    message = Plain(message)
    local wordingMatches = killMarker and type(message) == "string" and message:find(killMarker, 1, true)
    -- Quest and exploration XP can arrive through the same event on some clients.
    if not (wordingMatches or targetDead) then return end
    RecordKill(level, elite)
end

-- Events mode ---------------------------------------------------------------------------

local function IsMine(guid)
    guid = Plain(guid)
    if not guid then return false end
    return guid == Plain(UnitGUID("player")) or (UnitExists and UnitExists("pet") and guid == Plain(UnitGUID("pet")))
end

local function OnDeath(guid)
    guid = Plain(guid)
    if not guid then return end
    local now = GetTime()
    for g, t in pairs(recentDeaths) do
        if now - t > MERGE_WINDOW then recentDeaths[g] = nil end
    end
    if recentDeaths[guid] then return end
    recentDeaths[guid] = now

    local npcId = NpcFromGUID(guid)
    if not npcId then return end
    local level, rank = NpcInfo(npcId)
    local playerLevel = UnitLevel("player")
    if level and level <= GreyLevel(playerLevel) then return end -- no XP: not a leveling kill
    RecordKill(level, rank and rank > 0 and rank ~= 4)
end

---------------------------------------------------------------------------------------------
-- Public
---------------------------------------------------------------------------------------------

local function Median(values)
    table.sort(values)
    local n = #values
    if n == 0 then return nil end
    if n % 2 == 1 then return values[(n + 1) / 2] end
    return (values[n / 2] + values[n / 2 + 1]) / 2
end

--- Seconds per same-level kill for this character.
--- Returns seconds, source ("measured" or "estimate"), and the sample count.
function KillTimer.BaseSeconds(playerLevel)
    local samples = CharacterStore().samples
    local n = #samples
    if n < MIN_SAMPLES then return DefaultSeconds(playerLevel), "estimate", n end

    -- Scale older samples to the current level with the same slope as the built-in estimate.
    local values = {}
    for i, s in ipairs(samples) do
        values[i] = s[1] * DefaultSeconds(playerLevel) / DefaultSeconds(s[2] or playerLevel)
    end
    return Median(values), "measured", n
end

--- Seconds to kill one mob of the given level and rank, including downtime.
function KillTimer.SecondsPerKill(playerLevel, mobLevel, rank)
    local base = KillTimer.BaseSeconds(playerLevel)
    local seconds = base * LevelMultiplier(mobLevel and (mobLevel - playerLevel) or 0)
    if rank and rank > 0 and rank ~= 4 then seconds = seconds * ELITE_FACTOR end
    return seconds
end

function KillTimer.Reset()
    CharacterStore().samples = {}
    BreakChain()
end

function KillTimer.GetMode() return Settings().killDetect end

function KillTimer.SetMode(mode)
    if mode ~= "events" and mode ~= "xp" then return end
    Settings().killDetect = mode
    BreakChain() -- don't join gaps measured by two different methods
end

---------------------------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------------------------

local events = CreateFrame("Frame")
for _, event in ipairs({
    "CHAT_MSG_COMBAT_XP_GAIN",
    "PARTY_KILL", "UNIT_DIED",
    "PLAYER_TARGET_CHANGED", "PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED",
    "PLAYER_DEAD", "PLAYER_CONTROL_LOST", "PLAYER_ENTERING_WORLD",
}) do
    -- Events that don't exist on a client raise an error; skip them instead of failing.
    pcall(events.RegisterEvent, events, event)
end

events:SetScript("OnEvent", function(_, event, arg1, arg2)
    local mode = Settings().killDetect
    if event == "CHAT_MSG_COMBAT_XP_GAIN" then
        if mode == "xp" then OnXPMessage(arg1) end
    elseif event == "PARTY_KILL" then
        -- PARTY_KILL: attacker GUID, victim GUID. Count only our own (or our pet's) killing blows.
        if mode == "events" and IsMine(arg1) then OnDeath(arg2) end
    elseif event == "UNIT_DIED" then
        -- A mob we were fighting died without a killing blow from us (e.g. a DoT or a helper).
        if mode == "events" and Plain(arg1) and Plain(arg1) == lastTargetGUID
            and lastCombatTime and GetTime() - lastCombatTime <= TARGET_WINDOW then
            OnDeath(arg1)
        end
    elseif event == "PLAYER_TARGET_CHANGED" then
        local guid = UnitExists and UnitExists("target") and Plain(UnitGUID("target"))
        if guid and UnitCanAttack and UnitCanAttack("player", "target") then lastTargetGUID = guid end
    elseif event == "PLAYER_REGEN_DISABLED" or event == "PLAYER_REGEN_ENABLED" then
        lastCombatTime = GetTime()
    else
        BreakChain()
    end
end)

-- Exposed for tests.
KillTimer._OnEvent = events:GetScript("OnEvent")
