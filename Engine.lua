-- Engine.lua
-- Scores every zone by how much quest XP the player can realistically earn there right now,
-- including XP from the kills those quests require, and rates each zone's hunting ground.
-- Quest data is read at runtime from QuestieDB's public API (global LibQuestieDB); nothing is
-- copied into this addon. Without QuestieDB only the player's quest log is evaluated.

local ADDON_NAME, ns = ...

local Engine = {}
ns.Engine = Engine

local band = bit and bit.band
local floor, max, min = math.floor, math.max, math.min
local pairs, ipairs, type, pcall = pairs, ipairs, type, pcall

local QUEST_CONTRACT = 4
local QUESTS_PER_STEP = 200   -- quests evaluated per frame while scanning
local NPCS_PER_STEP = 400     -- NPCs evaluated per frame in the hunting-ground pass
local ROUTE_ZONES = 10        -- zones (best first) that get a planned route and time estimate
local LEVEL_LOOKAHEAD = 2     -- quests whose required level is at most this far above the player
local MAX_RED_DIFF = 5        -- quests this many levels above the player are ignored
local CHAIN_DEPTH = 3         -- how far prerequisite chains are followed

-- Status weights: how much of a quest's XP counts toward a zone's score.
local WEIGHT = {
    ready = 1.0,
    active = 1.0,
    avail = 1.0,
    chain = 0.7,
    soon = 0.5,
}

---------------------------------------------------------------------------------------------
-- Data source
---------------------------------------------------------------------------------------------

local DB          -- LibQuestieDB
local QuestDB, NpcDB, ObjectDB, ItemDB
local questXP     -- [questId] = { level, baseXP }
local dungeonAreas = {}
local hiddenQuests
local zoneModule  -- Questie's ZoneDB module, used only for subzone -> parent zone

local function GetQuestieModule(name)
    if type(QuestieLoader) == "table" and QuestieLoader.ImportModule then
        local ok, module = pcall(QuestieLoader.ImportModule, QuestieLoader, name)
        if ok and type(module) == "table" then return module end
    end
end

--- Binds QuestieDB once. Returns status: "ok", "nodb", or "contract", plus an optional message.
function Engine.InitDataSource()
    if Engine.dataStatus then return Engine.dataStatus, Engine.dataMessage end

    DB = rawget(_G, "LibQuestieDB")
    if type(DB) ~= "table" or type(DB.Quest) ~= "table" then
        Engine.dataStatus = "nodb"
        return Engine.dataStatus
    end

    if DB.RequireContract then
        local ok, message = DB.RequireContract(QUEST_CONTRACT)
        if not ok then
            Engine.dataStatus, Engine.dataMessage = "contract", message
            DB = nil
            return Engine.dataStatus, Engine.dataMessage
        end
    end

    QuestDB, NpcDB, ObjectDB = DB.Quest, DB.Npc, DB.Object

    if DB.Support and DB.Support.Get then
        local okXP, xpData = pcall(DB.Support.Get, "QuestXP")
        if okXP and type(xpData) == "table" and type(xpData.db) == "table" then
            questXP = xpData.db
        end

        local okZone, zoneData = pcall(DB.Support.Get, "ZoneDB")
        if okZone and type(zoneData) == "table" and type(zoneData.private) == "table" then
            local dungeons = zoneData.private.dungeons
            if type(dungeons) == "table" then
                for areaId, entry in pairs(dungeons) do
                    dungeonAreas[areaId] = true
                    if type(entry) == "table" and type(entry[2]) == "table" then
                        for _, altId in ipairs(entry[2]) do dungeonAreas[altId] = true end
                    end
                end
            end
        end
    end

    ItemDB = DB.Item
    Engine.dataStatus = "ok"
    return Engine.dataStatus
end

--- Drop rates [itemId][npcId] = percent, shipped by QuestieDB as a Lua source string.
--- Parsed on first use only; it is large and only needed for item objectives.
local dropRates
local function GetDropRates()
    if dropRates ~= nil then return dropRates or nil end
    dropRates = false
    if not (DB and DB.Support and DB.Support.Get) then return nil end
    local ok, drops = pcall(DB.Support.Get, "QuestieClassicItemDrops")
    if ok and type(drops) == "table" and type(drops.wowheadData) == "string" and loadstring then
        local chunk = loadstring(drops.wowheadData)
        if chunk then
            local okRun, data = pcall(chunk)
            if okRun and type(data) == "table" then dropRates = data end
        end
    end
    return dropRates or nil
end

--- Questie-only extras (hidden-quest list, subzone mapping). Bound lazily because Questie
--- fills them during its own initialization, which may finish after our PLAYER_LOGIN.
local function BindQuestieExtras()
    if not hiddenQuests then
        local corrections = GetQuestieModule("QuestieCorrections")
        if corrections and type(corrections.hiddenQuests) == "table" then
            hiddenQuests = corrections.hiddenQuests
        end
    end
    if not zoneModule then
        local zoneDB = GetQuestieModule("ZoneDB")
        if zoneDB and zoneDB.GetParentZoneId then zoneModule = zoneDB end
    end
end

function Engine.HasXPData() return questXP ~= nil end

--- Shared handles for Route.lua.
function Engine.GetData()
    return { DB = DB, Quest = QuestDB, Npc = NpcDB, Object = ObjectDB, zoneModule = zoneModule }
end

---------------------------------------------------------------------------------------------
-- Player state
---------------------------------------------------------------------------------------------

local function GetCompletedQuests()
    local completed = {}
    if C_QuestLog and C_QuestLog.GetAllCompletedQuestIDs then
        local ids = C_QuestLog.GetAllCompletedQuestIDs()
        if ids then
            for _, id in ipairs(ids) do completed[id] = true end
        end
    elseif GetQuestsCompleted then
        GetQuestsCompleted(completed)
    end
    for id in pairs(Engine.turnedInThisSession) do completed[id] = true end
    return completed
end

--- Returns [questId] = { title, level, complete } for every quest in the log.
local function ReadQuestLog()
    local log = {}
    if C_QuestLog and C_QuestLog.GetNumQuestLogEntries and C_QuestLog.GetInfo then
        local numEntries = C_QuestLog.GetNumQuestLogEntries() or 0
        for i = 1, numEntries do
            local info = C_QuestLog.GetInfo(i)
            if info and not info.isHeader and info.questID and info.questID > 0 then
                local complete = C_QuestLog.IsComplete and C_QuestLog.IsComplete(info.questID)
                local failed = C_QuestLog.IsFailed and C_QuestLog.IsFailed(info.questID)
                if not failed then
                    log[info.questID] = { title = info.title, level = info.level, complete = complete and true or false }
                end
            end
        end
    elseif GetNumQuestLogEntries and GetQuestLogTitle then
        local numEntries = GetNumQuestLogEntries() or 0
        for i = 1, numEntries do
            local title, level, _, isHeader, _, isComplete, _, questId = GetQuestLogTitle(i)
            if not isHeader and questId and questId > 0 and isComplete ~= -1 then
                log[questId] = { title = title, level = level, complete = isComplete == 1 }
            end
        end
    end
    return log
end

--- Faction the scan is evaluated for: "Alliance" or "Horde".
function Engine.GetPlayerFaction()
    local faction = UnitFactionGroup("player")
    if faction == "Alliance" or faction == "Horde" then return faction end
    return "Alliance"
end

---------------------------------------------------------------------------------------------
-- XP estimate
---------------------------------------------------------------------------------------------

--- Level-scaled quest XP, following the classic server rules: full XP up to 5 levels above
--- the quest, then 20% less per level down to a 10% floor, rounded the way the server rounds.
local function ScaleXP(baseXP, questLevel, playerLevel)
    local factor = 2 * (questLevel - playerLevel) + 20
    if factor < 1 then factor = 1 elseif factor > 10 then factor = 10 end

    local xp = baseXP * factor / 10
    if xp <= 100 then
        xp = 5 * floor((xp + 2) / 5)
    elseif xp <= 500 then
        xp = 10 * floor((xp + 5) / 10)
    elseif xp <= 1000 then
        xp = 25 * floor((xp + 12) / 25)
    else
        xp = 50 * floor((xp + 25) / 50)
    end
    return xp
end

local function EstimateXP(questId, playerLevel)
    local entry = questXP and questXP[questId]
    if entry then
        local level, xp = entry[1], entry[2]
        if level and xp and level > 0 and xp > 0 then
            return ScaleXP(xp, level, playerLevel)
        end
    end
    if GetQuestLogRewardXP and C_QuestLog and C_QuestLog.GetLogIndexForQuestID then
        -- Fallback for quests already in the log: ask the client.
        local index = C_QuestLog.GetLogIndexForQuestID(questId)
        if index then
            local ok, xp = pcall(GetQuestLogRewardXP, questId)
            if ok and type(xp) == "number" then return xp end
        end
    end
    return 0
end

---------------------------------------------------------------------------------------------
-- Mob XP
---------------------------------------------------------------------------------------------

local DEFAULT_OBJECTIVE_COUNT = 8   -- when a quest text names no count
local DEFAULT_DROP_RATE = 40        -- percent, when no drop data exists for an item
local MAX_KILLS_PER_ITEM = 6        -- cap on kills per required item (very rare drops)
local HUNT_MAX_ABOVE = 2            -- hunting-ground mobs at most this many levels above the player

--- Highest level that is grey (trivial) for the player, using the classic thresholds.
local function GreyLevel(playerLevel)
    if playerLevel <= 5 then return 0 end
    if playerLevel <= 39 then return playerLevel - floor(playerLevel / 10) - 5 end
    return playerLevel - floor(playerLevel / 5) - 1
end

--- "Zero difference" value from the classic kill-XP formula.
local function ZeroDifference(playerLevel)
    if playerLevel <= 7 then return 5 end
    if playerLevel <= 9 then return 6 end
    if playerLevel <= 11 then return 7 end
    if playerLevel <= 15 then return 8 end
    if playerLevel <= 19 then return 9 end
    if playerLevel <= 29 then return 11 end
    if playerLevel <= 39 then return 12 end
    if playerLevel <= 44 then return 13 end
    if playerLevel <= 49 then return 14 end
    if playerLevel <= 54 then return 15 end
    if playerLevel <= 59 then return 16 end
    return 17
end

--- Classic solo kill XP (no rested bonus, no group split). Elites give double.
local function KillXP(mobLevel, rank, playerLevel)
    if not mobLevel or mobLevel <= 0 then return 0 end
    local base = playerLevel * 5 + 45
    local xp
    if mobLevel >= playerLevel then
        xp = base * (1 + 0.05 * min(mobLevel - playerLevel, 4))
    else
        if mobLevel <= GreyLevel(playerLevel) then return 0 end
        xp = base * (1 - (playerLevel - mobLevel) / ZeroDifference(playerLevel))
    end
    if rank and rank > 0 and rank ~= 4 then xp = xp * 2 end -- elite, rare elite, boss (4 = rare)
    return max(floor(xp), 0)
end

local npcXPCache = {}

--- Average kill XP of one NPC across its level range, cached per scan.
local function NpcKillXP(npcId, playerLevel)
    local cached = npcXPCache[npcId]
    if cached then return cached end
    local lo = NpcDB.minLevel(npcId) or 0
    local hi = NpcDB.maxLevel(npcId) or lo
    local rank = NpcDB.rank(npcId) or 0
    local xp = (KillXP(lo, rank, playerLevel) + KillXP(hi, rank, playerLevel)) / 2
    npcXPCache[npcId] = xp
    return xp
end

--- Numbers in the objective text ("Kill 10 ...", "bring 8 ..."), in order.
local function TextCounts(questId)
    local counts = {}
    local lines = QuestDB.objectivesText(questId)
    if type(lines) ~= "table" then return counts end
    for _, line in ipairs(lines) do
        for digits in tostring(line):gmatch("%d+") do
            local n = tonumber(digits)
            if n and n >= 1 and n <= 60 then counts[#counts + 1] = n end
        end
    end
    return counts
end

--- Remaining counts from the live quest log, grouped by objective type, in order.
local function LogCounts(questId)
    if not (C_QuestLog and C_QuestLog.GetQuestObjectives) then return nil end
    local ok, objectives = pcall(C_QuestLog.GetQuestObjectives, questId)
    if not ok or type(objectives) ~= "table" then return nil end
    local byType = { monster = {}, item = {} }
    for _, o in ipairs(objectives) do
        local list = byType[o.type]
        if list then
            local remaining = (o.numRequired or 0) - (o.numFulfilled or 0)
            if o.finished then remaining = 0 end
            list[#list + 1] = max(remaining, 0)
        end
    end
    return byType
end

--- Kills needed to loot `count` of an item, and the XP of those kills.
local function ItemObjectiveXP(itemId, count, playerLevel)
    if count <= 0 or not ItemDB then return 0, 0 end
    local npcs = ItemDB.npcDrops(itemId)
    if type(npcs) ~= "table" or not npcs[1] then return 0, 0 end

    local rates = GetDropRates()
    local itemRates = rates and rates[itemId]
    local bestRate, bestXP, bestNpc = 0, 0, nil
    for _, npcId in ipairs(npcs) do
        local xp = NpcKillXP(npcId, playerLevel)
        if xp > 0 then
            local rate = (itemRates and itemRates[npcId]) or DEFAULT_DROP_RATE
            -- Prefer the mob that yields the item fastest.
            if rate > bestRate or (rate == bestRate and xp > bestXP) then
                bestRate, bestXP, bestNpc = rate, xp, npcId
            end
        end
    end
    if bestXP <= 0 then return 0, 0 end
    local kills = min(count / (bestRate / 100), count * MAX_KILLS_PER_ITEM)
    return kills, kills * bestXP, bestNpc
end

--- XP from the kills a quest's objectives require. Uses live counts for quests in the log.
--- Also returns the objective targets ({kind, id, count}) for route planning.
local function ObjectiveMobXP(questId, playerLevel, inLog)
    local targets = {}
    local objectives = QuestDB.objectives(questId)
    if type(objectives) ~= "table" then return 0, 0, targets end

    local creatures, objects, items, credits = objectives[1], objectives[2], objectives[3], objectives[5]
    local live = inLog and LogCounts(questId)
    local textCounts = (not live) and TextCounts(questId) or nil
    local textIndex = 0
    local function NextTextCount()
        textIndex = textIndex + 1
        return textCounts and textCounts[textIndex] or DEFAULT_OBJECTIVE_COUNT
    end

    local totalXP, totalKills = 0, 0
    local monsterIndex, itemIndex = 0, 0

    local function AddKills(npcId, count)
        local xp = NpcKillXP(npcId, playerLevel)
        totalXP = totalXP + xp * count
        totalKills = totalKills + count
        if count > 0 then targets[#targets + 1] = { kind = "npc", id = npcId, count = count } end
    end

    if type(creatures) == "table" then
        for _, o in ipairs(creatures) do
            monsterIndex = monsterIndex + 1
            local count = live and (live.monster[monsterIndex] or 0) or NextTextCount()
            if o[1] then AddKills(o[1], count) end
        end
    end
    if type(objects) == "table" then
        for _, o in ipairs(objects) do
            -- Live counts for objects come back as "object" objectives, which LogCounts skips;
            -- objects are cheap to collect, so the text count is good enough either way.
            local count = live and 1 or NextTextCount()
            if o[1] then targets[#targets + 1] = { kind = "object", id = o[1], count = count } end
        end
    end
    if type(credits) == "table" then
        for _, o in ipairs(credits) do
            monsterIndex = monsterIndex + 1
            local count = live and (live.monster[monsterIndex] or 0) or NextTextCount()
            local npcList = o[1]
            if type(npcList) == "table" and npcList[1] then AddKills(npcList[1], count) end
        end
    end
    if type(items) == "table" then
        for _, o in ipairs(items) do
            itemIndex = itemIndex + 1
            local count = live and (live.item[itemIndex] or 0) or NextTextCount()
            if o[1] then
                local kills, xp, npcId = ItemObjectiveXP(o[1], count, playerLevel)
                totalXP = totalXP + xp
                totalKills = totalKills + kills
                if npcId and kills > 0 then
                    targets[#targets + 1] = { kind = "npc", id = npcId, count = kills }
                elseif count > 0 and ItemDB then
                    -- Item comes from a container object (e.g. a crate) rather than a mob.
                    local objectsWithItem = ItemDB.objectDrops(o[1])
                    if type(objectsWithItem) == "table" and objectsWithItem[1] then
                        targets[#targets + 1] = { kind = "object", id = objectsWithItem[1], count = count }
                    end
                end
            end
        end
    end
    return floor(totalXP), floor(totalKills + 0.5), targets
end

---------------------------------------------------------------------------------------------
-- Eligibility
---------------------------------------------------------------------------------------------

--- QuestieDB reports "no requirement" as nil, 0, or an empty table depending on the field.
local function Present(value)
    if value == nil or value == 0 or value == false then return false end
    if type(value) == "table" then return next(value) ~= nil end
    return true
end

local function HasBit(mask, bitValue)
    if not mask or mask == 0 then return true end
    if not band then return true end
    return band(mask, bitValue) ~= 0
end

local function AnyIn(list, set)
    if type(list) ~= "table" then return false end
    for _, id in ipairs(list) do
        if set[id] then return true end
    end
    return false
end

-- Negative zoneOrSort values are quest-sort categories. Only these are normal leveling quests
-- whose zone can be taken from the quest starter; holidays, battlegrounds, invasions,
-- professions, reputation, and legendary chains are left out.
local LEVELING_SORTS = {
    [-1] = true,   -- epic
    [-23] = true,  -- Undercity
    [-61] = true, [-81] = true, [-82] = true, [-141] = true, [-161] = true,
    [-162] = true, [-261] = true, [-262] = true, [-263] = true, -- class quests
}

--- Resolves the zone a quest belongs to.
local function ResolveZone(questId, zoneOrSort, startedBy)
    local zone
    if zoneOrSort and zoneOrSort > 0 then
        zone = zoneOrSort
    elseif zoneOrSort and zoneOrSort < 0 and not LEVELING_SORTS[zoneOrSort] then
        return nil
    elseif type(startedBy) == "table" then
        local npcs, objects = startedBy[1], startedBy[2]
        if type(npcs) == "table" and npcs[1] and NpcDB then
            zone = NpcDB.zoneID(npcs[1])
        end
        if (not zone or zone == 0) and type(objects) == "table" and objects[1] and ObjectDB then
            zone = ObjectDB.zoneID(objects[1])
        end
    end
    if not zone or zone <= 0 then return nil end

    if zoneModule then
        local ok, parent = pcall(zoneModule.GetParentZoneId, zoneModule, zone)
        if ok and parent and parent > 0 then zone = parent end
    end
    return zone
end

--- True when at least one quest starter is friendly to the faction (or of unknown faction).
--- Quests with no starter at all are treated as unobtainable.
local function StarterFriendly(startedBy, factionLetter)
    if type(startedBy) ~= "table" then return false end
    local npcs, objects, items = startedBy[1], startedBy[2], startedBy[3]

    if type(npcs) == "table" then
        for _, npcId in ipairs(npcs) do
            local friendly = NpcDB and NpcDB.friendlyToFaction(npcId)
            if not friendly or friendly:find(factionLetter, 1, true) then return true end
        end
    end
    if type(objects) == "table" and objects[1] then return true end
    if type(items) == "table" and items[1] then return true end
    return false
end

---------------------------------------------------------------------------------------------
-- Scan
---------------------------------------------------------------------------------------------

Engine.turnedInThisSession = {}

local function NewZone(zoneId)
    return {
        zoneId = zoneId,
        score = 0,     -- weighted quest XP + objective kill XP
        questXP = 0,   -- weighted quest reward XP
        mobXP = 0,     -- weighted XP from kills the quests require
        kills = 0,
        count = 0,
        inLog = 0,
        hunt = 0,      -- hunting-ground potential (spawns x kill XP), filled after the quest pass
        minLevel = nil,
        maxLevel = nil,
        quests = {},
    }
end

local function GetZone(zones, zoneId)
    local zone = zones[zoneId]
    if not zone then
        zone = NewZone(zoneId)
        zones[zoneId] = zone
    end
    return zone
end

local function AddToZone(zones, zoneId, questId, name, questLevel, xp, status, mobXP, kills, targets)
    local zone = GetZone(zones, zoneId)
    mobXP, kills = mobXP or 0, kills or 0
    local weight = WEIGHT[status] or 1
    zone.questXP = zone.questXP + xp * weight
    zone.mobXP = zone.mobXP + mobXP * weight
    zone.score = zone.questXP + zone.mobXP
    zone.kills = zone.kills + kills
    zone.count = zone.count + 1
    if status == "active" or status == "ready" then zone.inLog = zone.inLog + 1 end
    if questLevel and questLevel > 0 then
        zone.minLevel = zone.minLevel and min(zone.minLevel, questLevel) or questLevel
        zone.maxLevel = zone.maxLevel and max(zone.maxLevel, questLevel) or questLevel
    end
    zone.quests[#zone.quests + 1] = {
        id = questId, name = name, level = questLevel, status = status,
        xp = xp, mobXP = mobXP, kills = kills, total = xp + mobXP, targets = targets,
    }
end

--- Builds the scan context shared by every quest evaluation.
local function NewContext(factionMode)
    local ownFaction = Engine.GetPlayerFaction()
    local faction = (factionMode == "Alliance" or factionMode == "Horde") and factionMode or ownFaction
    local isOwn = faction == ownFaction

    local raceMask
    local enum = DB and DB.Enum
    if isOwn then
        local raceId = select(3, UnitRace("player"))
        raceMask = enum and enum.raceMaskById and enum.raceMaskById[raceId]
    end
    if not raceMask and enum and enum.factionRaceMasks then
        raceMask = enum.factionRaceMasks[faction]
    end

    local classId = select(3, UnitClass("player"))
    local classMask = classId and 2 ^ (classId - 1) or nil

    return {
        playerLevel = UnitLevel("player"),
        faction = faction,
        factionLetter = faction == "Horde" and "H" or "A",
        isOwnFaction = isOwn,
        raceMask = raceMask,
        classMask = classMask,
        completed = GetCompletedQuests(),
        log = isOwn and ReadQuestLog() or {},
        statusCache = {},
    }
end

local EvaluateQuest

--- Prerequisite check. Returns "done" when satisfied by completed quests, "chain" when it
--- is satisfied only through quests the player can still pick up, or nil when blocked.
local function PrereqState(ctx, questId, depth)
    local group = QuestDB.preQuestGroup(questId)
    local single = QuestDB.preQuestSingle(questId)
    local state = "done"

    local function Reachable(preId)
        if ctx.completed[preId] then return "done" end
        if ctx.log[preId] then return "chain" end
        if depth >= CHAIN_DEPTH then return nil end
        local status = EvaluateQuest(ctx, preId, depth + 1)
        if status then return "chain" end
        return nil
    end

    if type(group) == "table" then
        for _, preId in ipairs(group) do
            local r = Reachable(preId)
            if not r then return nil end
            if r == "chain" then state = "chain" end
        end
    end

    if type(single) == "table" and single[1] then
        local best
        for _, preId in ipairs(single) do
            local r = Reachable(preId)
            if r == "done" then best = "done" break end
            if r == "chain" then best = "chain" end
        end
        if not best then return nil end
        if best == "chain" then state = "chain" end
    end

    return state
end

--- Status of a quest the player has not started: "avail", "chain", "soon", or nil (skip).
EvaluateQuest = function(ctx, questId, depth)
    local cached = ctx.statusCache[questId]
    if cached ~= nil then return cached or nil end
    ctx.statusCache[questId] = false -- guards against prerequisite cycles

    if ctx.completed[questId] or ctx.log[questId] then return nil end
    if hiddenQuests and hiddenQuests[questId] then return nil end

    local playerLevel = ctx.playerLevel
    local requiredLevel = QuestDB.requiredLevel(questId) or 1
    if requiredLevel > playerLevel + LEVEL_LOOKAHEAD then return nil end

    local questLevel = QuestDB.questLevel(questId) or requiredLevel
    if questLevel > 0 and questLevel - playerLevel > MAX_RED_DIFF then return nil end

    local maxLevel = QuestDB.requiredMaxLevel(questId)
    if maxLevel and maxLevel > 0 and playerLevel > maxLevel then return nil end

    if not HasBit(QuestDB.requiredRaces(questId), ctx.raceMask or 0xFFFFFFFF) then return nil end
    if ctx.classMask and not HasBit(QuestDB.requiredClasses(questId), ctx.classMask) then return nil end

    local specialFlags = QuestDB.specialFlags(questId)
    if specialFlags and band and band(specialFlags, 3) ~= 0 then return nil end -- repeatable / event

    if Present(QuestDB.requiredSkill(questId)) or Present(QuestDB.requiredSpell(questId))
        or Present(QuestDB.requiredSpecialization(questId)) or Present(QuestDB.requiredMinRep(questId))
        or Present(QuestDB.requiredSourceItems(questId)) then
        return nil
    end

    local exclusive = QuestDB.exclusiveTo(questId)
    if AnyIn(exclusive, ctx.completed) or AnyIn(exclusive, ctx.log) then return nil end

    local untilCompleted = QuestDB.availableUntilCompleted(questId)
    if Present(untilCompleted) and ctx.completed[untilCompleted] then return nil end

    local disabledBy = QuestDB.disabledByQuest(questId)
    if Present(disabledBy) and ctx.log[disabledBy] then return nil end

    local breadcrumbFor = QuestDB.breadcrumbForQuestId(questId)
    if Present(breadcrumbFor) and (ctx.completed[breadcrumbFor] or ctx.log[breadcrumbFor]) then return nil end

    local startedBy = QuestDB.startedBy(questId)
    if not StarterFriendly(startedBy, ctx.factionLetter) then return nil end

    local prereq = PrereqState(ctx, questId, depth or 0)
    if not prereq then return nil end

    local status
    if requiredLevel > playerLevel then
        status = "soon"
    elseif prereq == "chain" then
        status = "chain"
    else
        status = "avail"
    end
    ctx.statusCache[questId] = status
    return status
end

--- Adds one quest to the zone table, if it counts.
local function ScoreQuest(ctx, zones, questId)
    local logEntry = ctx.log[questId]
    local status
    if logEntry then
        status = logEntry.complete and "ready" or "active"
    else
        status = EvaluateQuest(ctx, questId, 0)
        if not status then return end
        -- Grey quests are not worth travelling for. They still count as prerequisites above.
        local level = QuestDB.questLevel(questId)
        if level and level > 0 and level <= GreyLevel(ctx.playerLevel) then return end
    end

    local zoneOrSort = QuestDB.zoneOrSort(questId)
    local startedBy = QuestDB.startedBy(questId)
    local zone = ResolveZone(questId, zoneOrSort, startedBy)
    if not zone or dungeonAreas[zone] then return end

    local xp = EstimateXP(questId, ctx.playerLevel)
    if xp <= 0 then return end

    local mobXP, kills, targets = 0, 0, nil
    if status ~= "ready" then
        mobXP, kills, targets = ObjectiveMobXP(questId, ctx.playerLevel, logEntry ~= nil)
    end

    local name = (logEntry and logEntry.title) or QuestDB.name(questId) or ("#" .. questId)
    local questLevel = QuestDB.questLevel(questId) or (logEntry and logEntry.level)
    AddToZone(zones, zone, questId, name, questLevel, xp, status, mobXP, kills, targets)
end

--- Adds one NPC's spawns to the hunting-ground totals if it is a good solo target.
local function ScoreHuntingNpc(ctx, hunt, npcId)
    local playerLevel = ctx.playerLevel
    local hi = NpcDB.maxLevel(npcId) or 0
    if hi <= ctx.greyLevel then return end
    local lo = NpcDB.minLevel(npcId) or hi
    if lo > playerLevel + HUNT_MAX_ABOVE then return end

    local rank = NpcDB.rank(npcId) or 0
    if rank ~= 0 then return end -- elites and rares are not farmable solo
    local flags = NpcDB.npcFlags(npcId)
    if Present(flags) then return end -- vendors, trainers, quest givers, ...
    local friendly = NpcDB.friendlyToFaction(npcId)
    if friendly and friendly:find(ctx.factionLetter, 1, true) then return end

    local spawns = NpcDB.spawns(npcId)
    if type(spawns) ~= "table" then return end
    local xp = NpcKillXP(npcId, playerLevel)
    if xp <= 0 then return end

    for areaId, coords in pairs(spawns) do
        local zone = areaId
        if zoneModule then
            local ok, parent = pcall(zoneModule.GetParentZoneId, zoneModule, areaId)
            if ok and parent and parent > 0 then zone = parent end
        end
        if not dungeonAreas[zone] and type(coords) == "table" then
            local n = #coords
            if n > 0 then
                local entry = hunt[zone]
                if not entry then
                    entry = { value = 0, spawns = 0 }
                    hunt[zone] = entry
                end
                entry.value = entry.value + n * xp
                entry.spawns = entry.spawns + n
            end
        end
    end
end

--- Log-only fallback when QuestieDB is missing: groups quests under their log header.
local function ScanLogOnly(factionMode)
    local zones = {}
    if not (C_QuestLog and C_QuestLog.GetNumQuestLogEntries and C_QuestLog.GetInfo) then return zones end
    local header = "?"
    local playerLevel = UnitLevel("player")
    for i = 1, C_QuestLog.GetNumQuestLogEntries() or 0 do
        local info = C_QuestLog.GetInfo(i)
        if info then
            if info.isHeader then
                header = info.title or "?"
            elseif info.questID and info.questID > 0 then
                local xp = 0
                if GetQuestLogRewardXP then
                    local ok, value = pcall(GetQuestLogRewardXP, info.questID)
                    if ok and type(value) == "number" then xp = value end
                end
                local complete = C_QuestLog.IsComplete and C_QuestLog.IsComplete(info.questID)
                if xp > 0 then
                    AddToZone(zones, header, info.questID, info.title, info.level, xp, complete and "ready" or "active")
                end
            end
        end
    end
    return zones
end

--- Rates each listed zone's hunting ground relative to the best one in the list.
local function RateHunting(list, hunt)
    if not hunt then return end
    local best = 0
    for _, zone in ipairs(list) do
        local entry = hunt[zone.zoneId]
        if entry then
            zone.hunt = entry.value
            zone.huntSpawns = entry.spawns
            if entry.value > best then best = entry.value end
        end
    end
    for _, zone in ipairs(list) do
        local share = best > 0 and (zone.hunt or 0) / best or 0
        if share >= 0.6 then
            zone.huntRating = "good"
        elseif share >= 0.3 then
            zone.huntRating = "fair"
        else
            zone.huntRating = "poor"
        end
    end
end

local function FinishZones(zones, hunt)
    local list = {}
    for _, zone in pairs(zones) do
        if zone.score > 0 then
            table.sort(zone.quests, function(a, b) return a.total > b.total end)
            if type(zone.zoneId) == "number" then
                zone.name = (C_Map and C_Map.GetAreaInfo and C_Map.GetAreaInfo(zone.zoneId)) or ("Zone " .. zone.zoneId)
            else
                zone.name = tostring(zone.zoneId)
            end
            list[#list + 1] = zone
        end
    end
    table.sort(list, function(a, b) return a.score > b.score end)
    RateHunting(list, hunt)
    return list
end

local scanFrame = CreateFrame("Frame")
local activeScan

--- Starts an asynchronous scan. onProgress(fraction) and onDone(zoneList, context) are called
--- from frame updates. A running scan is replaced by the new one.
function Engine.StartScan(factionMode, onProgress, onDone)
    Engine.InitDataSource()
    BindQuestieExtras()

    if Engine.dataStatus ~= "ok" then
        local zones = ScanLogOnly(factionMode)
        onDone(FinishZones(zones), { playerLevel = UnitLevel("player"), faction = Engine.GetPlayerFaction() })
        return
    end

    local ctx = NewContext(factionMode)
    ctx.greyLevel = GreyLevel(ctx.playerLevel)
    npcXPCache = {}

    local zones, hunt = {}, {}
    local questIds = QuestDB.GetAllIds() or {}
    local npcIds = (NpcDB and NpcDB.GetAllIds and NpcDB.GetAllIds()) or {}
    local questTotal, npcTotal = #questIds, #npcIds
    -- Progress: quests 0-50%, hunting grounds 50-85%, routes 85-100%.
    local QUEST_SHARE, HUNT_END = 0.5, 0.85
    local currentZone = GetRealZoneText and GetRealZoneText() or nil
    local finalList

    -- Quests in the log are always counted even if the DB would filter them out.
    local seen = {}

    activeScan = coroutine.create(function()
        for questId in pairs(ctx.log) do
            seen[questId] = true
            local ok, err = pcall(ScoreQuest, ctx, zones, questId)
            if not ok then Engine.lastError = err end
        end

        local index = 0
        while index < questTotal do
            local stop = min(index + QUESTS_PER_STEP, questTotal)
            for i = index + 1, stop do
                local questId = questIds[i]
                if not seen[questId] then
                    local ok, err = pcall(ScoreQuest, ctx, zones, questId)
                    if not ok then Engine.lastError = err end
                end
            end
            index = stop
            coroutine.yield(QUEST_SHARE * index / max(questTotal, 1))
        end

        index = 0
        while index < npcTotal do
            local stop = min(index + NPCS_PER_STEP, npcTotal)
            for i = index + 1, stop do
                local ok, err = pcall(ScoreHuntingNpc, ctx, hunt, npcIds[i])
                if not ok then Engine.lastError = err end
            end
            index = stop
            coroutine.yield(QUEST_SHARE + (HUNT_END - QUEST_SHARE) * index / max(npcTotal, 1))
        end

        -- Routes for the best zones, one zone per frame. Route.Compute runs inside pcall,
        -- so it must not yield (WoW's Lua cannot yield across pcall).
        local list = FinishZones(zones, hunt)
        local routeCount = min(ROUTE_ZONES, #list)
        for i = 1, routeCount do
            local zone = list[i]
            zone.isCurrent = currentZone ~= nil and zone.name == currentZone
            if ns.Route then
                local ok, err = pcall(ns.Route.Compute, zone, ctx)
                if not ok then Engine.lastError = err end
            end
            coroutine.yield(HUNT_END + (1 - HUNT_END) * i / max(routeCount, 1))
        end
        finalList = list
    end)

    scanFrame:SetScript("OnUpdate", function(self)
        if not activeScan then self:SetScript("OnUpdate", nil) return end
        local ok, progress = coroutine.resume(activeScan)
        if not ok then
            Engine.lastError = progress
            activeScan = nil
            self:SetScript("OnUpdate", nil)
            onDone(FinishZones(zones, hunt), ctx)
            return
        end
        if coroutine.status(activeScan) == "dead" then
            activeScan = nil
            self:SetScript("OnUpdate", nil)
            onDone(finalList or FinishZones(zones, hunt), ctx)
        elseif progress and onProgress then
            onProgress(progress)
        end
    end)
end

function Engine.IsScanning() return activeScan ~= nil end
