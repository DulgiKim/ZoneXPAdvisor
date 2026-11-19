-- Calibration.lua
-- Learns how far the classic XP formulas are off on this client by comparing each predicted
-- value with the XP the game actually awards:
--   * Quest turn-ins: QUEST_TURNED_IN reports the XP reward; the prediction comes from the
--     quest's level and base XP in QuestieDB.
--   * Kills: the "<mob> dies, you gain N experience" chat line, while the dead mob is still
--     targeted (its level and elite status come from the target). The rested bonus in the
--     same line is removed first, and kills in a group are skipped (XP is split there).
-- The median ratio (actual / predicted) per character scales the estimates of later scans.

local ADDON_NAME, ns = ...

local Calibration = {}
ns.Calibration = Calibration

local MAX_SAMPLES = 30
local MIN_QUEST_SAMPLES = 3
local MIN_KILL_SAMPLES = 5
local MIN_RATIO, MAX_RATIO = 0.25, 4   -- ratios outside this are bad matches, not real modifiers
local FACTOR_MIN, FACTOR_MAX = 0.5, 3
local QUEST_RULE = 2                   -- version of Engine's quest XP rule the samples were taken with

Calibration.MIN_QUEST_SAMPLES = MIN_QUEST_SAMPLES
Calibration.MIN_KILL_SAMPLES = MIN_KILL_SAMPLES

local function Plain(v)
    if type(issecretvalue) == "function" and issecretvalue(v) then return nil end
    return v
end

local function Store()
    ZoneXPAdvisorDB = ZoneXPAdvisorDB or {}
    local db = ZoneXPAdvisorDB
    db.calibration = db.calibration or {}
    local name = UnitName("player") or "?"
    local realm = GetRealmName and GetRealmName() or "?"
    local key = name .. "-" .. realm
    local store = db.calibration[key]
    if not store then
        store = {}
        db.calibration[key] = store
    end
    -- Quest samples are ratios against the predicted reward; when the prediction rule changes
    -- (WoW Forever's level-gap rule instead of classic's) the old ones no longer fit.
    if store.questRule ~= QUEST_RULE then
        store.quest = {}
        store.questRule = QUEST_RULE
    end
    store.quest = store.quest or {}
    store.kill = store.kill or {}
    return store
end

local function Median(list)
    local sorted = {}
    for i, v in ipairs(list) do sorted[i] = v end
    table.sort(sorted)
    local n = #sorted
    if n == 0 then return nil end
    if n % 2 == 1 then return sorted[(n + 1) / 2] end
    return (sorted[n / 2] + sorted[n / 2 + 1]) / 2
end

local function AddSample(list, actual, predicted)
    if not (actual and predicted) or actual <= 0 or predicted <= 0 then return false end
    local ratio = actual / predicted
    if ratio < MIN_RATIO or ratio > MAX_RATIO then return false end
    list[#list + 1] = ratio
    while #list > MAX_SAMPLES do table.remove(list, 1) end
    return true
end

--- Factor, source ("measured" or "default") and sample count for one kind of XP.
local function Factor(list, minSamples)
    local n = #list
    if n < minSamples then return 1, "default", n end
    local m = Median(list) or 1
    if m < FACTOR_MIN then m = FACTOR_MIN elseif m > FACTOR_MAX then m = FACTOR_MAX end
    return m, "measured", n
end

function Calibration.QuestFactor() return (Factor(Store().quest, MIN_QUEST_SAMPLES)) end
function Calibration.KillFactor() return (Factor(Store().kill, MIN_KILL_SAMPLES)) end

function Calibration.Stats()
    local store = Store()
    local qf, qs, qn = Factor(store.quest, MIN_QUEST_SAMPLES)
    local kf, ks, kn = Factor(store.kill, MIN_KILL_SAMPLES)
    return {
        quest = { factor = qf, source = qs, samples = qn },
        kill = { factor = kf, source = ks, samples = kn },
    }
end

function Calibration.Reset()
    local store = Store()
    store.quest, store.kill = {}, {}
end

---------------------------------------------------------------------------------------------
-- Quest turn-ins
---------------------------------------------------------------------------------------------

local function OnQuestTurnedIn(questId, xpReward)
    questId, xpReward = Plain(questId), Plain(xpReward)
    if type(questId) ~= "number" or type(xpReward) ~= "number" or xpReward <= 0 then return end
    local Engine = ns.Engine
    if not (Engine and Engine.PredictQuestXP) then return end
    local predicted = Engine.PredictQuestXP(questId, UnitLevel("player"))
    AddSample(Store().quest, xpReward, predicted)
end

---------------------------------------------------------------------------------------------
-- Kills
---------------------------------------------------------------------------------------------

--- Base kill XP from a kill message: the first number is the total, a second number in
--- parentheses is the rested bonus (group penalties never reach here: groups are skipped).
local function ParseKillXP(message, mobName)
    local rest = message
    if mobName and mobName ~= "" then
        -- Drop the mob name so digits in it are not read as XP.
        local s, e = message:find(mobName, 1, true)
        if not s then return nil end
        rest = message:sub(1, s - 1) .. message:sub(e + 1)
    end
    -- Grammar tokens ("|1이;가;") and color codes contain digits that are not XP.
    rest = rest:gsub("|1[^;]*;[^;]*;", ""):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
    local total = tonumber(rest:match("(%d+)"))
    if not total then return nil end
    local bonus = 0
    local paren = rest:match("%((.-)%)")
    if paren then bonus = tonumber(paren:match("(%d+)")) or 0 end
    return total - bonus
end

local function OnXPMessage(message)
    message = Plain(message)
    if type(message) ~= "string" then return end
    if IsInGroup and IsInGroup() then return end
    if not (UnitExists and UnitExists("target") and UnitIsDead and UnitIsDead("target")) then return end
    local mobName = Plain(UnitName("target"))
    local level = Plain(UnitLevel("target"))
    if type(mobName) ~= "string" or type(level) ~= "number" or level <= 0 then return end

    local base = ParseKillXP(message, mobName)
    if not base or base <= 0 then return end

    local classification = UnitClassification and Plain(UnitClassification("target")) or "normal"
    local elite = classification == "elite" or classification == "rareelite" or classification == "worldboss"
    local Engine = ns.Engine
    if not (Engine and Engine.KillXP) then return end
    local predicted = Engine.KillXP(level, elite and 1 or 0, UnitLevel("player"))
    AddSample(Store().kill, base, predicted)
end

---------------------------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------------------------

local events = CreateFrame("Frame")
pcall(events.RegisterEvent, events, "QUEST_TURNED_IN")
pcall(events.RegisterEvent, events, "CHAT_MSG_COMBAT_XP_GAIN")
events:SetScript("OnEvent", function(_, event, arg1, arg2)
    if event == "QUEST_TURNED_IN" then
        pcall(OnQuestTurnedIn, arg1, arg2)
    elseif event == "CHAT_MSG_COMBAT_XP_GAIN" then
        pcall(OnXPMessage, arg1)
    end
end)

-- Exposed for tests.
Calibration._OnEvent = events:GetScript("OnEvent")
Calibration._ParseKillXP = ParseKillXP
