-- Route.lua
-- Estimates how long a zone's quests take: plans a short route through every quest pickup,
-- objective area and turn-in inside the zone, then adds travel, fighting and talking time.
--
-- The route is a precedence-constrained travelling-salesman tour (pickup before objectives
-- before turn-in; a chained quest's pickup after its prerequisite's turn-in). It is built
-- with a nearest-neighbour pass and then shortened with 2-opt and Or-opt moves that keep
-- every precedence rule intact.

local ADDON_NAME, ns = ...

local Route = {}
ns.Route = Route

local sqrt, floor, min, max, abs = math.sqrt, math.floor, math.min, math.max, math.abs
local pairs, ipairs, type, pcall = pairs, ipairs, type, pcall

-- Time model (seconds, yards). Tuned for solo questing; deliberately simple.
local RUN_SPEED = 7           -- yards/second on foot
local MOUNT_SPEED = 11.2      -- 60% ground mount
local MOUNT_LEVEL = 40
local PATH_FACTOR = 1.35      -- real paths wind around terrain and mobs
local TALK_TIME = 12          -- per pickup or turn-in (walking up, reading, accepting)
local OBJECT_TIME = 6         -- per object interaction (loot a crate, click a plant)
local MAX_TWO_OPT_PASSES = 3
local MAX_OR_OPT_PASSES = 3
local OR_OPT_MAX_RUN = 3      -- Or-opt moves runs of 1..3 consecutive stops
-- Route improvement (2-opt, Or-opt, 2-opt) stops after this many milliseconds per zone and
-- keeps what it has, so a big zone never stalls a frame. Each zone is planned in its own frame.
local IMPROVE_BUDGET_MS = 8
local Now = debugprofilestop
    or (GetTimePreciseSec and function() return GetTimePreciseSec() * 1000 end)
    or function() return 0 end
local DEFAULT_ZONE_SIZE = { 3400, 2300 } -- average classic zone in yards, when the client can't say
local CLUSTER_RADIUS = 8      -- percent of zone width; spawns closer than this form one camp
local MAX_CLUSTER_SAMPLE = 80
-- Kill / collect objectives whose spots are this close (yards) form one camp: in a mixed camp
-- you kill every kind of mob together, so the route visits it once.
local CAMP_RADIUS = 160
-- Getting to a zone that isn't the current one.
local FLIGHT_SPEED = 32       -- yards/second on a flight path
local FLIGHT_OVERHEAD = 120   -- seconds: reaching the flight master, landing, walking to the hub
local FLIGHT_PATH_FACTOR = 1.4 -- flight routes are not straight lines
local OTHER_CONTINENT = 15 * 60 -- boat or zeppelin: waiting, sailing and travelling on
-- Round trip to another zone for objectives that are not in the quest's zone, when the
-- client can't tell where that zone is.
local DEFAULT_AWAY_TRIP = 10 * 60

--- Seconds per kill of one NPC including downtime. Uses this character's measured pace
--- (KillTimer.lua) once enough kills are recorded, adjusted for the mob's level and rank.
local function KillTime(data, playerLevel, npcId)
    local npc = data.Npc
    local lo = npc and npc.minLevel(npcId) or nil
    local hi = npc and npc.maxLevel(npcId) or lo
    local level = lo and hi and (lo + hi) / 2 or lo
    local rank = npc and npc.rank(npcId) or 0
    if ns.KillTimer then return ns.KillTimer.SecondsPerKill(playerLevel, level, rank) end
    return 16 + playerLevel * 0.2
end

---------------------------------------------------------------------------------------------
-- Zone geometry
---------------------------------------------------------------------------------------------

local sizeCache = {}

--- Zone size in yards, from the client's map data when available.
local function ZoneSize(areaId, data)
    local cached = sizeCache[areaId]
    if cached then return cached[1], cached[2] end

    local width, height
    local uiMapId
    if data.zoneModule and data.zoneModule.GetUiMapIdByAreaId then
        local ok, id = pcall(data.zoneModule.GetUiMapIdByAreaId, data.zoneModule, areaId)
        if ok then uiMapId = id end
    end
    if uiMapId and C_Map then
        if C_Map.GetMapWorldSize then
            local ok, w, h = pcall(C_Map.GetMapWorldSize, uiMapId)
            if ok and w and h and w > 0 and h > 0 then width, height = w, h end
        end
        if not width and C_Map.GetWorldPosFromMapPos and CreateVector2D then
            local ok1, _, topLeft = pcall(C_Map.GetWorldPosFromMapPos, uiMapId, CreateVector2D(0, 0))
            local ok2, _, bottomRight = pcall(C_Map.GetWorldPosFromMapPos, uiMapId, CreateVector2D(1, 1))
            if ok1 and ok2 and topLeft and bottomRight then
                local w = abs(topLeft.y - bottomRight.y) -- world axes are swapped relative to the map
                local h = abs(topLeft.x - bottomRight.x)
                if w > 0 and h > 0 then width, height = w, h end
            end
        end
    end
    width = width or DEFAULT_ZONE_SIZE[1]
    height = height or DEFAULT_ZONE_SIZE[2]
    sizeCache[areaId] = { width, height }
    return width, height
end

--- Map coordinates for the Forever client (some zones were reshaped).
local function ToClientCoords(data, areaId, x, y)
    local db = data.DB
    if db and db.EraToForever then
        local ok, fx, fy = pcall(db.EraToForever, areaId, x, y)
        if ok and fx and fy and fx >= 0 then return fx, fy end
    end
    return x, y
end

--- Spawn coordinates of an NPC or object that lie inside the zone.
local function SpawnsInZone(data, kind, id, zone)
    local source = kind == "object" and data.Object or data.Npc
    if not source then return nil end
    local spawns = source.spawns(id)
    if type(spawns) ~= "table" then return nil end

    local points
    for areaId, coords in pairs(spawns) do
        local inZone = areaId == zone
        if not inZone and data.zoneModule then
            local ok, parent = pcall(data.zoneModule.GetParentZoneId, data.zoneModule, areaId)
            inZone = ok and parent == zone
        end
        if inZone and type(coords) == "table" then
            for _, c in ipairs(coords) do
                if type(c) == "table" and c[1] and c[2] and c[1] >= 0 then
                    points = points or {}
                    local x, y = ToClientCoords(data, areaId, c[1], c[2])
                    points[#points + 1] = { x, y }
                end
            end
        end
    end
    return points
end

--- The centre of the densest group of spawns: where you would actually go to farm them.
local function DensestCluster(points)
    local n = #points
    if n == 1 then return points[1][1], points[1][2] end
    local step = max(1, floor(n / MAX_CLUSTER_SAMPLE))
    local r2 = CLUSTER_RADIUS * CLUSTER_RADIUS
    local bestCount, bestX, bestY = -1, points[1][1], points[1][2]
    for i = 1, n, step do
        local px, py = points[i][1], points[i][2]
        local count, sx, sy = 0, 0, 0
        for j = 1, n, step do
            local dx, dy = points[j][1] - px, points[j][2] - py
            if dx * dx + dy * dy <= r2 then
                count = count + 1
                sx, sy = sx + points[j][1], sy + points[j][2]
            end
        end
        if count > bestCount then
            bestCount, bestX, bestY = count, sx / count, sy / count
        end
    end
    return bestX, bestY
end

--- The area id where an NPC or object has the most spawns.
local function MainSpawnArea(data, kind, id)
    local source = kind == "object" and data.Object or data.Npc
    local spawns = source and source.spawns(id)
    if type(spawns) ~= "table" then return nil end
    local best, bestCount
    for areaId, coords in pairs(spawns) do
        local n = type(coords) == "table" and #coords or 0
        if n > 0 and (not bestCount or n > bestCount) then best, bestCount = areaId, n end
    end
    return best
end

local function FirstSpawn(data, kind, ids, zone)
    if type(ids) ~= "table" then return nil end
    for _, id in ipairs(ids) do
        local points = SpawnsInZone(data, kind, id, zone)
        if points then return points[1][1], points[1][2] end
    end
end

---------------------------------------------------------------------------------------------
-- Node construction
---------------------------------------------------------------------------------------------

local function Dist(a, b)
    local dx, dy = a.x - b.x, a.y - b.y
    return sqrt(dx * dx + dy * dy)
end

--- True when the precedence edges contain a cycle (Kahn's algorithm leaves nodes behind).
local function HasCycle(nodes)
    local indegree, children = {}, {}
    for i, node in ipairs(nodes) do
        indegree[i] = indegree[i] or 0
        for _, p in ipairs(node.preds) do
            indegree[i] = indegree[i] + 1
            children[p] = children[p] or {}
            table.insert(children[p], i)
        end
    end
    local queue, done = {}, 0
    for i = 1, #nodes do if indegree[i] == 0 then queue[#queue + 1] = i end end
    local head = 1
    while queue[head] do
        local i = queue[head]
        head = head + 1
        done = done + 1
        for _, c in ipairs(children[i] or {}) do
            indegree[c] = indegree[c] - 1
            if indegree[c] == 0 then queue[#queue + 1] = c end
        end
    end
    return done < #nodes
end

--- Merges objective nodes that lie within CAMP_RADIUS of each other into one camp node:
--- position weighted by time spent, time summed, prerequisites combined, and `members`
--- listing each quest objective inside. With `sameQuestOnly`, only objectives of one quest
--- are merged (always safe: they share the same pickup).
local function MergeCamps(nodes, sameQuestOnly)
    local objectives = {}
    for i, node in ipairs(nodes) do
        if node.kind == "objective" then objectives[#objectives + 1] = i end
    end
    if #objectives < 2 then return nodes end
    table.sort(objectives, function(a, b) return nodes[a].duration > nodes[b].duration end)

    local campOf, camps = {}, {}
    for _, seed in ipairs(objectives) do
        if not campOf[seed] then
            local s = nodes[seed]
            local camp = { seed }
            local w = math.max(s.duration, 1)
            local cx, cy, cpx, cpy, total = s.x * w, s.y * w, s.px * w, s.py * w, w
            campOf[seed] = camp
            for _, other in ipairs(objectives) do
                local o = nodes[other]
                if not campOf[other] and (not sameQuestOnly or o.quest == s.quest)
                    and Dist(o, { x = cx / total, y = cy / total }) <= CAMP_RADIUS then
                    camp[#camp + 1] = other
                    campOf[other] = camp
                    local ow = math.max(o.duration, 1)
                    cx, cy = cx + o.x * ow, cy + o.y * ow
                    cpx, cpy, total = cpx + o.px * ow, cpy + o.py * ow, total + ow
                end
            end
            camp.x, camp.y, camp.px, camp.py = cx / total, cy / total, cpx / total, cpy / total
            camps[#camps + 1] = camp
        end
    end

    -- New node list: every node that is not in a multi-objective camp, plus one node per camp.
    local merged, newIndex, sourcesOf = {}, {}, {}
    for i, node in ipairs(nodes) do
        local camp = campOf[i]
        if not camp or #camp == 1 then
            merged[#merged + 1] = { x = node.x, y = node.y, px = node.px, py = node.py, duration = node.duration,
                quest = node.quest, kind = node.kind, target = node.target }
            newIndex[i] = #merged
            sourcesOf[#merged] = { i }
        elseif camp[1] == i then
            local members, duration = {}, 0
            for _, m in ipairs(camp) do
                members[#members + 1] = { quest = nodes[m].quest, target = nodes[m].target }
                duration = duration + nodes[m].duration
            end
            merged[#merged + 1] = { x = camp.x, y = camp.y, px = camp.px, py = camp.py, duration = duration,
                quest = node.quest, kind = "objective", members = members }
            for _, m in ipairs(camp) do newIndex[m] = #merged end
            sourcesOf[#merged] = camp
        end
    end
    -- Remap prerequisites (a camp gets the union of its members'), without duplicates or self-links.
    for index, node in ipairs(merged) do
        local preds, seen = {}, {}
        for _, old in ipairs(sourcesOf[index]) do
            for _, p in ipairs(nodes[old].preds) do
                local np = newIndex[p]
                if np and np ~= index and not seen[np] then
                    seen[np] = true
                    preds[#preds + 1] = np
                end
            end
        end
        node.preds = preds
    end
    return merged
end

--- Builds route nodes for every quest of a zone. Each node: x, y (yards), duration (s),
--- preds (indices that must be visited first).
local function BuildNodes(zone, ctx, data, width, height)
    local Q = data.Quest
    local nodes = {}
    -- Objectives done in another zone: their fighting time and the zones you must travel to.
    local away = { time = 0, quests = 0, areas = {} }
    local turnInOf = {} -- questId -> node index
    local pickupOf = {}

    -- kind: "pickup", "objective" or "turnin"; px/py keep the map position in percent for the
    -- next-steps panel; target is the objective's {kind, id, count}.
    local function Add(x, y, duration, preds, questId, kind, target)
        nodes[#nodes + 1] = {
            x = x / 100 * width, y = y / 100 * height, px = x, py = y,
            duration = duration, preds = preds, quest = questId, kind = kind, target = target,
        }
        return #nodes
    end

    for _, quest in ipairs(zone.quests) do
        local id = quest.id
        local preds = {}

        -- Pickup
        if quest.status ~= "active" and quest.status ~= "ready" then
            local startedBy = Q.startedBy(id)
            local x, y
            if type(startedBy) == "table" then
                x, y = FirstSpawn(data, "npc", startedBy[1], zone.zoneId)
                if not x then x, y = FirstSpawn(data, "object", startedBy[2], zone.zoneId) end
            end
            if x then
                local index = Add(x, y, TALK_TIME, {}, id, "pickup")
                pickupOf[id] = index
                preds = { index }
            end
        end

        -- Objectives
        local objectiveNodes = {}
        local awayQuest = false
        if quest.status ~= "ready" and type(quest.targets) == "table" then
            for _, target in ipairs(quest.targets) do
                local duration
                if target.kind == "object" then
                    duration = target.count * OBJECT_TIME
                else
                    duration = target.count * KillTime(data, ctx.playerLevel, target.id)
                end
                local points = SpawnsInZone(data, target.kind, target.id, zone.zoneId)
                if points then
                    local x, y = DensestCluster(points)
                    objectiveNodes[#objectiveNodes + 1] = Add(x, y, duration, preds, id, "objective", target)
                else
                    -- The mobs live in another zone (e.g. a city quest sending you elsewhere):
                    -- the fighting still takes time, plus a trip there and back.
                    away.time = away.time + duration
                    awayQuest = true
                    local area = MainSpawnArea(data, target.kind, target.id)
                    if area then away.areas[area] = true else away.unknown = true end
                end
            end
        end
        if awayQuest then away.quests = away.quests + 1 end

        -- Turn-in
        local finishedBy = Q.finishedBy(id)
        if type(finishedBy) == "table" then
            local x, y = FirstSpawn(data, "npc", finishedBy[1], zone.zoneId)
            if not x then x, y = FirstSpawn(data, "object", finishedBy[2], zone.zoneId) end
            if x then
                local turnPreds = {}
                for _, p in ipairs(preds) do turnPreds[#turnPreds + 1] = p end
                for _, o in ipairs(objectiveNodes) do turnPreds[#turnPreds + 1] = o end
                turnInOf[id] = Add(x, y, TALK_TIME, turnPreds, id, "turnin")
            end
        end
    end

    -- Chains: a follow-up quest can only be picked up after its prerequisite is turned in.
    for _, quest in ipairs(zone.quests) do
        local pickup = pickupOf[quest.id]
        if pickup then
            local function Link(list)
                if type(list) ~= "table" then return end
                for _, preId in ipairs(list) do
                    local t = turnInOf[preId]
                    if t and t ~= pickup then table.insert(nodes[pickup].preds, t) end
                end
            end
            Link(Q.preQuestGroup(quest.id))
            Link(Q.preQuestSingle(quest.id))
        end
    end

    -- Objectives inherit the pickup's chain predecessors transitively through the pickup,
    -- so no further edges are needed.

    -- Mixed camps: merge nearby objectives. Merging objectives of different quests can create
    -- a cycle when one quest unlocks the other; then only same-quest objectives are merged.
    local merged = MergeCamps(nodes, false)
    if HasCycle(merged) and not HasCycle(nodes) then merged = MergeCamps(nodes, true) end
    return merged, away
end

---------------------------------------------------------------------------------------------
-- Route solver
---------------------------------------------------------------------------------------------

--- Nearest-neighbour tour that only visits nodes whose predecessors are done.
--- Nodes stuck behind an unreachable predecessor (e.g. a cycle) are appended at the end.
local function NearestNeighbour(nodes, startX, startY)
    local n = #nodes
    local visited, order = {}, {}
    local cur = { x = startX, y = startY }
    for _ = 1, n do
        local best, bestD
        for i = 1, n do
            if not visited[i] then
                local ready = true
                for _, p in ipairs(nodes[i].preds) do
                    if not visited[p] then ready = false break end
                end
                if ready then
                    local d = Dist(cur, nodes[i])
                    if not bestD or d < bestD then best, bestD = i, d end
                end
            end
        end
        if not best then break end
        visited[best] = true
        order[#order + 1] = best
        cur = nodes[best]
    end
    for i = 1, n do
        if not visited[i] then order[#order + 1] = i end
    end
    return order
end

--- Shortens the tour with 2-opt segment reversals. Reversing order[i..j] flips the relative
--- order of every pair inside the segment, so it is only allowed when no precedence edge
--- connects two nodes that are both inside it. Stops early once `deadline` (Now() ms) passes.
local function TwoOpt(nodes, order, start, deadline)
    local n = #order
    if n < 4 then return order end
    local pos = {}
    for i, node in ipairs(order) do pos[node] = i end

    local function At(i)
        if i == 0 then return start end
        return nodes[order[i]]
    end

    local function SegmentOk(i, j)
        for k = i, j do
            for _, p in ipairs(nodes[order[k]].preds) do
                local pp = pos[p]
                if pp and pp >= i and pp <= j then return false end
            end
        end
        return true
    end

    for _ = 1, MAX_TWO_OPT_PASSES do
        local improved = false
        for i = 1, n - 1 do
            local a, b = At(i - 1), At(i)
            for j = i + 1, n do
                local c = At(j)
                local d = j < n and At(j + 1) or nil
                -- Open tour: the last edge has no successor.
                local before = Dist(a, b) + (d and Dist(c, d) or 0)
                local after = Dist(a, c) + (d and Dist(b, d) or 0)
                if after + 0.01 < before and SegmentOk(i, j) then
                    local lo, hi = i, j
                    while lo < hi do
                        order[lo], order[hi] = order[hi], order[lo]
                        pos[order[lo]], pos[order[hi]] = lo, hi
                        lo, hi = lo + 1, hi - 1
                    end
                    improved = true
                    b = At(i)
                end
            end
            if deadline and i % 8 == 0 and Now() > deadline then return order end
        end
        if not improved then break end
    end
    return order
end

--- Or-opt: moves a run of 1-3 consecutive stops to the place in the tour where it adds the
--- least distance (e.g. a lone pickup far from the rest goes next to nearby stops). A move is
--- only made when it keeps every precedence rule:
---   * moving the run later: none of the stops it jumps over may need a stop of the run first;
---   * moving it earlier: no stop of the run may need one of the stops it jumps over.
--- Stops early once `deadline` passes.
local function OrOpt(nodes, order, start, deadline)
    local n = #order
    if n < 3 then return order end
    local function At(i)
        if i == 0 then return start end
        return nodes[order[i]]
    end

    local function MoveOk(i, last, j)
        if j > last then
            local inRun = {}
            for x = i, last do inRun[order[x]] = true end
            for x = last + 1, j do
                for _, p in ipairs(nodes[order[x]].preds) do
                    if inRun[p] then return false end
                end
            end
        else
            local between = {}
            for x = j + 1, i - 1 do between[order[x]] = true end
            for x = i, last do
                for _, p in ipairs(nodes[order[x]].preds) do
                    if between[p] then return false end
                end
            end
        end
        return true
    end

    for _ = 1, MAX_OR_OPT_PASSES do
        local improved = false
        for k = 1, OR_OPT_MAX_RUN do
            local i = 1
            while i + k - 1 <= n do
                if deadline and Now() > deadline then return order end
                local last = i + k - 1
                local a, first, final = At(i - 1), At(i), At(last)
                local b = last < n and At(last + 1) or nil
                -- Distance saved by taking the run out (the open tour has no edge after the end).
                local saved = Dist(a, first) + (b and (Dist(final, b) - Dist(a, b)) or 0)
                local bestJ, bestDelta
                for j = 0, n do
                    if j < i - 1 or j > last then
                        -- Insert between stop j and the stop after it (skipping the run itself).
                        local c = At(j)
                        local nextIndex = j + 1
                        if nextIndex >= i and nextIndex <= last then nextIndex = last + 1 end
                        local d = nextIndex <= n and At(nextIndex) or nil
                        local added = Dist(c, first) + (d and (Dist(final, d) - Dist(c, d)) or 0)
                        local delta = added - saved
                        if delta < -0.01 and (not bestDelta or delta < bestDelta) and MoveOk(i, last, j) then
                            bestJ, bestDelta = j, delta
                        end
                    end
                end
                if bestJ then
                    local run, rest = {}, {}
                    for x = 1, n do
                        if x >= i and x <= last then run[#run + 1] = order[x] else rest[#rest + 1] = order[x] end
                    end
                    local after = bestJ > last and bestJ - k or bestJ
                    local moved = {}
                    for x = 1, after do moved[#moved + 1] = rest[x] end
                    for _, v in ipairs(run) do moved[#moved + 1] = v end
                    for x = after + 1, #rest do moved[#moved + 1] = rest[x] end
                    order = moved
                    improved = true
                else
                    i = i + 1
                end
            end
        end
        if not improved then break end
    end
    return order
end

---------------------------------------------------------------------------------------------
-- Getting there
---------------------------------------------------------------------------------------------

local function UiMapFor(areaId, data)
    if data.zoneModule and data.zoneModule.GetUiMapIdByAreaId then
        local ok, id = pcall(data.zoneModule.GetUiMapIdByAreaId, data.zoneModule, areaId)
        if ok and type(id) == "number" and id > 0 then return id end
    end
end

--- Continent and world position (yards) of a point on a UI map.
local function WorldPos(uiMapId, fx, fy)
    if not (uiMapId and C_Map and C_Map.GetWorldPosFromMapPos and CreateVector2D) then return nil end
    local ok, continent, pos = pcall(C_Map.GetWorldPosFromMapPos, uiMapId, CreateVector2D(fx, fy))
    if ok and type(continent) == "number" and pos and type(pos.x) == "number" and type(pos.y) == "number" then
        return continent, pos.x, pos.y
    end
end

--- Seconds to get from the player's position to the zone's starting point: the faster of
--- running there and taking a flight path, or a fixed boat trip for another continent.
--- Returns nil when either position is unknown (e.g. inside an instance).
local function ApproachTime(zone, ctx, data, hx, hy, width, height)
    if zone.isCurrent then return 0 end
    if not (C_Map and C_Map.GetBestMapForUnit and C_Map.GetPlayerMapPosition) then return nil end
    local zc, zx, zy = WorldPos(UiMapFor(zone.zoneId, data), hx / width, hy / height)
    if not zc then return nil end
    local playerMap = C_Map.GetBestMapForUnit("player")
    local pos = playerMap and C_Map.GetPlayerMapPosition(playerMap, "player")
    if not (pos and type(pos.x) == "number") then return nil end
    local pc, px, py = WorldPos(playerMap, pos.x, pos.y)
    if not pc then return nil end
    if pc ~= zc then return OTHER_CONTINENT end
    local d = sqrt((zx - px) ^ 2 + (zy - py) ^ 2)
    local speed = ctx.playerLevel >= MOUNT_LEVEL and MOUNT_SPEED or RUN_SPEED
    local ground = d * PATH_FACTOR / speed
    local flight = FLIGHT_OVERHEAD + d * FLIGHT_PATH_FACTOR / FLIGHT_SPEED
    return min(ground, flight)
end

--- Time for objectives outside the zone: their fighting time plus a round trip to each other
--- zone involved (flight or running on the same continent, boat otherwise).
local function AwayTime(away, zone, ctx, data)
    if not away or away.quests == 0 then return 0 end
    local total = away.time
    local zc, zx, zy = WorldPos(UiMapFor(zone.zoneId, data), 0.5, 0.5)
    local speed = ctx.playerLevel >= MOUNT_LEVEL and MOUNT_SPEED or RUN_SPEED
    for area in pairs(away.areas) do
        local trip = DEFAULT_AWAY_TRIP
        local ac, ax, ay = WorldPos(UiMapFor(area, data), 0.5, 0.5)
        if zc and ac then
            if zc ~= ac then
                trip = 2 * OTHER_CONTINENT
            else
                local d = sqrt((ax - zx) ^ 2 + (ay - zy) ^ 2)
                trip = 2 * min(d * PATH_FACTOR / speed, FLIGHT_OVERHEAD + d * FLIGHT_PATH_FACTOR / FLIGHT_SPEED)
            end
        end
        total = total + trip
    end
    if away.unknown then total = total + DEFAULT_AWAY_TRIP end
    return total
end

--- Quests in the order the route finishes them (last node of each quest), so the level-up
--- simulation hands out XP in the order it is earned. Quests without nodes go last.
local function QuestsInRouteOrder(zone, nodes, order)
    local finish = {}
    for position, index in ipairs(order) do
        local id = nodes[index].quest
        if id then finish[id] = position end
    end
    local list = {}
    for i, q in ipairs(zone.quests) do list[i] = q end
    local fallback = #order + 1
    table.sort(list, function(a, b)
        local pa, pb = finish[a.id] or fallback, finish[b.id] or fallback
        if pa ~= pb then return pa < pb end
        return a.id < b.id
    end)
    return list
end

--- The route as a list of steps for the next-steps panel (capped; the panel shows a few).
local MAX_STEPS = 60
local function RouteSteps(zone, nodes, order)
    local names = {}
    for _, q in ipairs(zone.quests) do names[q.id] = q.name end
    local steps = {}
    for _, index in ipairs(order) do
        local node = nodes[index]
        if node.kind then
            local target = node.target
            local step = {
                kind = node.kind, quest = node.quest, name = names[node.quest],
                x = node.px, y = node.py,
                targetKind = target and target.kind, targetId = target and target.id,
                count = target and target.count,
            }
            if node.members then
                -- A camp: every objective killed or collected there, possibly of several quests.
                step.members = {}
                for _, m in ipairs(node.members) do
                    step.members[#step.members + 1] = {
                        quest = m.quest, name = names[m.quest],
                        targetKind = m.target and m.target.kind, targetId = m.target and m.target.id,
                        count = m.target and m.target.count,
                    }
                end
            end
            steps[#steps + 1] = step
            if #steps >= MAX_STEPS then break end
        end
    end
    return steps
end

---------------------------------------------------------------------------------------------
-- Public
---------------------------------------------------------------------------------------------

--- Where the player starts: their own position if they stand in the zone, otherwise the
--- zone's busiest quest hub (the point most pickups are near).
local function StartPoint(nodes, zone, width, height)
    if C_Map and C_Map.GetBestMapForUnit and C_Map.GetPlayerMapPosition and zone.isCurrent then
        local uiMapId = C_Map.GetBestMapForUnit("player")
        local pos = uiMapId and C_Map.GetPlayerMapPosition(uiMapId, "player")
        if pos and pos.x then return pos.x * width, pos.y * height end
    end
    local bestCount, bx, by = -1, nodes[1].x, nodes[1].y
    local radius = 0.05 * width
    for i = 1, #nodes do
        if #nodes[i].preds == 0 then
            local count = 0
            for j = 1, #nodes do
                if #nodes[j].preds == 0 and Dist(nodes[i], nodes[j]) <= radius then count = count + 1 end
            end
            if count > bestCount then bestCount, bx, by = count, nodes[i].x, nodes[i].y end
        end
    end
    return bx, by
end

--- Plans a zone's route and stores routeTime (s), routeDistance (yards), travelTime,
--- actionTime and xpPerHour on the zone. `yield` lets the caller spread work over frames.
function Route.Compute(zone, ctx, yield)
    local data = ns.Engine.GetData()
    if not data.Quest or type(zone.zoneId) ~= "number" then return end

    local width, height = ZoneSize(zone.zoneId, data)
    local nodes, away = BuildNodes(zone, ctx, data, width, height)
    if #nodes == 0 then return end

    local sx, sy = StartPoint(nodes, zone, width, height)
    local start = { x = sx, y = sy }
    local order = NearestNeighbour(nodes, sx, sy)
    if yield then yield() end
    local deadline = Now() + IMPROVE_BUDGET_MS
    order = TwoOpt(nodes, order, start, deadline)
    order = OrOpt(nodes, order, start, deadline)
    order = TwoOpt(nodes, order, start, deadline)

    local distance, actions = 0, 0
    local cur = start
    for _, index in ipairs(order) do
        local node = nodes[index]
        distance = distance + Dist(cur, node)
        actions = actions + node.duration
        cur = node
    end

    local speed = ctx.playerLevel >= MOUNT_LEVEL and MOUNT_SPEED or RUN_SPEED
    local travel = distance * PATH_FACTOR / speed
    local okApproach, approach = pcall(ApproachTime, zone, ctx, data, sx, sy, width, height)
    approach = okApproach and approach or nil

    -- XP in the order the route earns it, levelling up on the way.
    if ns.Engine.SimulateZone then ns.Engine.SimulateZone(zone, ctx, QuestsInRouteOrder(zone, nodes, order)) end

    zone.routeDistance = distance
    zone.travelTime = travel
    zone.actionTime = actions
    zone.approachTime = approach
    local okAway, awayTime = pcall(AwayTime, away, zone, ctx, data)
    zone.awayTime = okAway and awayTime > 0 and awayTime or nil
    zone.awayQuests = away and away.quests > 0 and away.quests or nil
    zone.routeTime = travel + actions + (approach or 0) + (zone.awayTime or 0)
    zone.routeStops = #order
    zone.routeSteps = RouteSteps(zone, nodes, order)
    zone.uiMapId = UiMapFor(zone.zoneId, data)
    zone.xpPerHour = zone.routeTime > 0 and zone.score / (zone.routeTime / 3600) or 0
end

-- Exposed for tests.
Route._NearestNeighbour = NearestNeighbour
Route._TwoOpt = TwoOpt
Route._OrOpt = OrOpt
Route._MergeCamps = MergeCamps
Route._HasCycle = HasCycle
