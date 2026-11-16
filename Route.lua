-- Route.lua
-- Estimates how long a zone's quests take: plans a short route through every quest pickup,
-- objective area and turn-in inside the zone, then adds travel, fighting and talking time.
--
-- The route is a precedence-constrained travelling-salesman tour (pickup before objectives
-- before turn-in; a chained quest's pickup after its prerequisite's turn-in). It is built
-- with a nearest-neighbour pass and then shortened with 2-opt moves that keep every
-- precedence rule intact.

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
local DEFAULT_ZONE_SIZE = { 3400, 2300 } -- average classic zone in yards, when the client can't say
local CLUSTER_RADIUS = 8      -- percent of zone width; spawns closer than this form one camp
local MAX_CLUSTER_SAMPLE = 80

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

--- Builds route nodes for every quest of a zone. Each node: x, y (yards), duration (s),
--- preds (indices that must be visited first).
local function BuildNodes(zone, ctx, data, width, height)
    local Q = data.Quest
    local nodes = {}
    local turnInOf = {} -- questId -> node index
    local pickupOf = {}

    local function Add(x, y, duration, preds, questId)
        nodes[#nodes + 1] = { x = x / 100 * width, y = y / 100 * height, duration = duration, preds = preds, quest = questId }
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
                local index = Add(x, y, TALK_TIME, {}, id)
                pickupOf[id] = index
                preds = { index }
            end
        end

        -- Objectives
        local objectiveNodes = {}
        if quest.status ~= "ready" and type(quest.targets) == "table" then
            for _, target in ipairs(quest.targets) do
                local points = SpawnsInZone(data, target.kind, target.id, zone.zoneId)
                if points then
                    local x, y = DensestCluster(points)
                    local duration
                    if target.kind == "object" then
                        duration = target.count * OBJECT_TIME
                    else
                        duration = target.count * KillTime(data, ctx.playerLevel, target.id)
                    end
                    objectiveNodes[#objectiveNodes + 1] = Add(x, y, duration, preds, id)
                end
            end
        end

        -- Turn-in
        local finishedBy = Q.finishedBy(id)
        if type(finishedBy) == "table" then
            local x, y = FirstSpawn(data, "npc", finishedBy[1], zone.zoneId)
            if not x then x, y = FirstSpawn(data, "object", finishedBy[2], zone.zoneId) end
            if x then
                local turnPreds = {}
                for _, p in ipairs(preds) do turnPreds[#turnPreds + 1] = p end
                for _, o in ipairs(objectiveNodes) do turnPreds[#turnPreds + 1] = o end
                turnInOf[id] = Add(x, y, TALK_TIME, turnPreds, id)
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
    return nodes
end

---------------------------------------------------------------------------------------------
-- Route solver
---------------------------------------------------------------------------------------------

local function Dist(a, b)
    local dx, dy = a.x - b.x, a.y - b.y
    return sqrt(dx * dx + dy * dy)
end

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
--- connects two nodes that are both inside it.
local function TwoOpt(nodes, order, start, yield)
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
            if yield and i % 20 == 0 then yield() end
        end
        if not improved then break end
    end
    return order
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
    local nodes = BuildNodes(zone, ctx, data, width, height)
    if #nodes == 0 then return end

    local sx, sy = StartPoint(nodes, zone, width, height)
    local start = { x = sx, y = sy }
    local order = NearestNeighbour(nodes, sx, sy)
    if yield then yield() end
    order = TwoOpt(nodes, order, start, yield)

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
    zone.routeDistance = distance
    zone.travelTime = travel
    zone.actionTime = actions
    zone.routeTime = travel + actions
    zone.routeStops = #order
    zone.xpPerHour = zone.routeTime > 0 and zone.score / (zone.routeTime / 3600) or 0
end

-- Exposed for tests.
Route._NearestNeighbour = NearestNeighbour
Route._TwoOpt = TwoOpt
