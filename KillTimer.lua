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
--
-- Time that isn't hunting is taken out of each gap, so AFK breaks don't skew the median:
--   * AFK flag: breaks the chain.
--   * Open vendor / mail / quest / gossip / trainer / auction / bank / flight-map windows:
--     the time they are open is subtracted (quest talking is counted separately in routes).
--   * Standing still out of combat with full health and mana for more than IDLE_GRACE
--     seconds: subtracted. Standing still while health or mana recovers is real downtime and
--     stays in.
--   * Rest areas (inns, cities) and, optionally, party play: the kill isn't recorded.

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
local IDLE_GRACE = 15       -- seconds of idling with full resources before it counts as a pause
local FULL = 0.98           -- health/mana share treated as "full"
local MAX_RAW_GAP = 600     -- seconds; even after removing pauses, longer gaps are discarded
local TICK = 1              -- seconds between pause checks

KillTimer.MIN_SAMPLES = MIN_SAMPLES
KillTimer.MODES = { "events", "xp" }

local lastKillTime, lastKillZone
local recentDeaths = {}     -- guid -> time, to merge duplicate death reports
local lastTargetGUID, lastCombatTime
local pausedSinceKill = 0   -- seconds of non-hunting time since the last kill
local idleRun = 0           -- consecutive seconds of idling with full resources
local openWindows = {}      -- interaction windows currently open (vendor, mail, ...)
local wasAFK = false

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
    if db.killSoloOnly == nil then db.killSoloOnly = true end
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
    store.skipped = store.skipped or { afk = 0, group = 0, resting = 0, long = 0 }
    return store
end

local function BreakChain()
    lastKillTime, lastKillZone = nil, nil
    pausedSinceKill, idleRun = 0, 0
end

local function CountSkip(reason)
    local skipped = CharacterStore().skipped
    skipped[reason] = (skipped[reason] or 0) + 1
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
    -- Kills in towns and in groups don't reflect solo questing pace.
    if IsResting and IsResting() then
        CountSkip("resting")
        BreakChain()
        return
    end
    if Settings().killSoloOnly and IsInGroup and IsInGroup() then
        CountSkip("group")
        BreakChain()
        return
    end

    local now = GetTime()
    local zone = GetRealZoneText and GetRealZoneText() or ""
    local playerLevel = UnitLevel("player")

    if lastKillTime and zone == lastKillZone then
        local raw = now - lastKillTime
        local gap = raw - pausedSinceKill
        if raw > MAX_RAW_GAP or gap > MAX_GAP then
            CountSkip("long")
        elseif gap >= MIN_GAP and not elite then
            -- Normalise to a same-level mob so samples from different mobs are comparable.
            local diff = mobLevel and (mobLevel - playerLevel) or 0
            local samples = CharacterStore().samples
            samples[#samples + 1] = { gap / LevelMultiplier(diff), playerLevel, pausedSinceKill }
            while #samples > MAX_SAMPLES do table.remove(samples, 1) end
        end
    end
    lastKillTime, lastKillZone = now, zone
    pausedSinceKill, idleRun = 0, 0
    wipe(openWindows) -- a kill means no vendor or mail window is in use
end

---------------------------------------------------------------------------------------------
-- Pause detection
---------------------------------------------------------------------------------------------

local function Ratio(current, maximum)
    current, maximum = Plain(current), Plain(maximum)
    if not current or not maximum or maximum <= 0 then return nil end
    return current / maximum
end

--- Standing still, out of combat, with nothing left to recover: not hunting.
--- Any value the client won't reveal makes this false, so unknowns never remove time.
local function IdleWithFullResources()
    if InCombatLockdown() or (UnitAffectingCombat and UnitAffectingCombat("player")) then return false end
    local speed = GetUnitSpeed and Plain(GetUnitSpeed("player"))
    if speed == nil or speed > 0 then return false end
    local health = Ratio(UnitHealth("player"), UnitHealthMax("player"))
    if not health or health < FULL then return false end
    local powerType = UnitPowerType and UnitPowerType("player")
    if powerType == 0 then -- mana users also rest for mana
        local mana = Ratio(UnitPower("player", 0), UnitPowerMax("player", 0))
        if not mana or mana < FULL then return false end
    end
    return true
end

local function Tick()
    local afk = UnitIsAFK and UnitIsAFK("player") and true or false
    if afk and not wasAFK then
        if lastKillTime then CountSkip("afk") end
        BreakChain()
    end
    wasAFK = afk
    if not lastKillTime then return end

    if next(openWindows) then
        pausedSinceKill = pausedSinceKill + TICK
        idleRun = 0
    elseif IdleWithFullResources() then
        idleRun = idleRun + TICK
        if idleRun > IDLE_GRACE then pausedSinceKill = pausedSinceKill + TICK end
    else
        idleRun = 0
    end
end

if C_Timer and C_Timer.NewTicker then C_Timer.NewTicker(TICK, Tick) end

local WINDOW_OPEN = {
    MERCHANT_SHOW = "merchant", MAIL_SHOW = "mail", GOSSIP_SHOW = "gossip",
    QUEST_GREETING = "quest", QUEST_DETAIL = "quest", QUEST_PROGRESS = "quest", QUEST_COMPLETE = "quest",
    TRAINER_SHOW = "trainer", AUCTION_HOUSE_SHOW = "auction", BANKFRAME_OPENED = "bank",
    TAXIMAP_OPENED = "taxi",
}
local WINDOW_CLOSE = {
    MERCHANT_CLOSED = "merchant", MAIL_CLOSED = "mail", GOSSIP_CLOSED = "gossip",
    QUEST_FINISHED = "quest", TRAINER_CLOSED = "trainer", AUCTION_HOUSE_CLOSED = "auction",
    BANKFRAME_CLOSED = "bank", TAXIMAP_CLOSED = "taxi",
}

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
    local store = CharacterStore()
    store.samples = {}
    store.skipped = { afk = 0, group = 0, resting = 0, long = 0 }
    BreakChain()
end

--- What the filters removed: seconds of pauses taken out of the kept samples, and how many
--- kills were skipped for each reason since the last reset.
function KillTimer.Stats()
    local store = CharacterStore()
    local excluded = 0
    for _, s in ipairs(store.samples) do excluded = excluded + (s[3] or 0) end
    return { excluded = excluded, samples = #store.samples, skipped = store.skipped }
end

function KillTimer.GetSoloOnly() return Settings().killSoloOnly end

function KillTimer.SetSoloOnly(value)
    Settings().killSoloOnly = value and true or false
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
for event in pairs(WINDOW_OPEN) do pcall(events.RegisterEvent, events, event) end
for event in pairs(WINDOW_CLOSE) do pcall(events.RegisterEvent, events, event) end

events:SetScript("OnEvent", function(_, event, arg1, arg2)
    local mode = Settings().killDetect
    if WINDOW_OPEN[event] then
        openWindows[WINDOW_OPEN[event]] = true
    elseif WINDOW_CLOSE[event] then
        openWindows[WINDOW_CLOSE[event]] = nil
    elseif event == "CHAT_MSG_COMBAT_XP_GAIN" then
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
        -- Combat means no vendor/mail window is being used; drop any whose close event was missed.
        if event == "PLAYER_REGEN_DISABLED" then wipe(openWindows) end
    else
        wipe(openWindows)
        BreakChain()
    end
end)

-- Exposed for tests.
KillTimer._OnEvent = events:GetScript("OnEvent")
KillTimer._Tick = Tick
