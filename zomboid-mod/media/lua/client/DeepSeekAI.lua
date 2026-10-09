-- ===========================================================================
-- DeepSeek AI Survivor - Project Zomboid 客户端模组
-- ===========================================================================
-- 分层架构（严格按优先级执行）：
--   1) emergencyCheck 本地紧急逻辑：每 tick 运行，毫秒级响应贴脸僵尸，
--      近战/逃跑全部本地硬编码，绝不等待云端 LLM（网络延迟会害死角色）。
--   2) 状态采集：按间隔把角色状态写入 DeepSeekAI_state.json（文件 IPC），
--      供本地 Python 桥接服务读取后向 DeepSeek 请求「高层策略」。
--   3) 动作执行：读取桥接服务写回的 DeepSeekAI_action.json，
--      仅在非紧急状态下执行 LLM 的高层决策。
--
-- 说明：原版 PZ Lua 没有 HttpRequest，社区通用方案即本文件采用的文件 IPC
-- （getFileReader/getFileWriter，读写根目录为 用户目录/Zomboid/Lua/）。
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 极简 JSON 编解码（PZ 的 Kahlua Lua 5.1 无内置 JSON 库，内嵌实现避免外部依赖）
-- ---------------------------------------------------------------------------
local json = {}

-- 编码：Lua 值 -> JSON 字符串
local function encodeValue(v, buf)
    local t = type(v)
    if t == "string" then
        buf[#buf + 1] = '"' .. v:gsub('[%c"\\]', function(c)
            local map = {['"'] = '\\"', ['\\'] = '\\\\', ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t'}
            return map[c] or string.format('\\u%04x', c:byte())
        end) .. '"'
    elseif t == "number" then
        buf[#buf + 1] = tostring(v)
    elseif t == "boolean" then
        buf[#buf + 1] = tostring(v)
    elseif t == "table" then
        if #v > 0 then
            -- 数组
            buf[#buf + 1] = "["
            for i, item in ipairs(v) do
                if i > 1 then buf[#buf + 1] = "," end
                encodeValue(item, buf)
            end
            buf[#buf + 1] = "]"
        else
            -- 对象
            buf[#buf + 1] = "{"
            local first = true
            for k, val in pairs(v) do
                if not first then buf[#buf + 1] = "," end
                first = false
                encodeValue(tostring(k), buf)
                buf[#buf + 1] = ":"
                encodeValue(val, buf)
            end
            buf[#buf + 1] = "}"
        end
    else
        buf[#buf + 1] = "null"
    end
end

function json.encode(v)
    local buf = {}
    encodeValue(v, buf)
    return table.concat(buf)
end

-- 解码：JSON 字符串 -> Lua 值（递归下降解析器）
local parseValue, parseObject, parseArray

local function skipWhitespace(str, pos)
    local _, e = str:find("^[ \t\r\n]+", pos)
    return e and e + 1 or pos
end

local function parseString(str, pos)
    local buf = {}
    pos = pos + 1 -- 跳过开头引号
    while pos <= #str do
        local c = str:sub(pos, pos)
        if c == '"' then
            return table.concat(buf), pos + 1
        elseif c == "\\" then
            local esc = str:sub(pos + 1, pos + 1)
            local map = {['"'] = '"', ['\\'] = '\\', ['/'] = '/', b = '\b', f = '\f', n = '\n', r = '\r', t = '\t'}
            if esc == 'u' then
                -- \uXXXX 转 UTF-8（覆盖 BMP，够用）
                local code = tonumber(str:sub(pos + 2, pos + 5), 16) or 63
                if code < 128 then
                    buf[#buf + 1] = string.char(code)
                elseif code < 2048 then
                    buf[#buf + 1] = string.char(192 + math.floor(code / 64), 128 + (code % 64))
                else
                    buf[#buf + 1] = string.char(224 + math.floor(code / 4096), 128 + (math.floor(code / 64) % 64), 128 + (code % 64))
                end
                pos = pos + 6
            else
                buf[#buf + 1] = map[esc] or esc
                pos = pos + 2
            end
        else
            buf[#buf + 1] = c
            pos = pos + 1
        end
    end
    error("JSON 字符串未闭合")
end

local function parseNumber(str, pos)
    local numStr = str:match("^%-?%d+%.?%d*[eE]?[%+%-]?%d*", pos)
    local n = tonumber(numStr)
    if not n then error("JSON 数字格式错误 @ " .. pos) end
    return n, pos + #numStr
end

parseObject = function(str, pos)
    local obj = {}
    pos = skipWhitespace(str, pos + 1) -- 跳过 {
    if str:sub(pos, pos) == "}" then return obj, pos + 1 end
    while true do
        pos = skipWhitespace(str, pos)
        local key
        key, pos = parseString(str, pos)
        pos = skipWhitespace(str, pos) + 1 -- 跳过冒号
        local val
        val, pos = parseValue(str, pos)
        obj[key] = val
        pos = skipWhitespace(str, pos)
        local c = str:sub(pos, pos)
        if c == "," then
            pos = pos + 1
        elseif c == "}" then
            return obj, pos + 1
        else
            error("JSON 对象缺少逗号或 } @ " .. pos)
        end
    end
end

parseArray = function(str, pos)
    local arr = {}
    pos = skipWhitespace(str, pos + 1) -- 跳过 [
    if str:sub(pos, pos) == "]" then return arr, pos + 1 end
    while true do
        local val
        val, pos = parseValue(str, pos)
        arr[#arr + 1] = val
        pos = skipWhitespace(str, pos)
        local c = str:sub(pos, pos)
        if c == "," then
            pos = pos + 1
        elseif c == "]" then
            return arr, pos + 1
        else
            error("JSON 数组缺少逗号或 ] @ " .. pos)
        end
    end
end

parseValue = function(str, pos)
    pos = skipWhitespace(str, pos)
    local c = str:sub(pos, pos)
    if c == '"' then return parseString(str, pos) end
    if c == "{" then return parseObject(str, pos) end
    if c == "[" then return parseArray(str, pos) end
    if str:sub(pos, pos + 3) == "true" then return true, pos + 4 end
    if str:sub(pos, pos + 4) == "false" then return false, pos + 5 end
    if str:sub(pos, pos + 3) == "null" then return nil, pos + 4 end
    return parseNumber(str, pos)
end

function json.decode(str)
    if not str or str == "" then return nil end
    local ok, result = pcall(parseValue, str, 1)
    if ok then return result end
    print("[DeepSeekAI] JSON 解析失败: " .. tostring(result))
    return nil
end

-- ---------------------------------------------------------------------------
-- 配置：硬编码默认值 < DeepSeekAI_config.json 覆盖 < 动作文件附带阈值（最高优先级）
-- 阈值全部外置，方便后续 AI 自动调参。
-- ---------------------------------------------------------------------------
local config = {
    zombie_danger_distance   = 6.0,  -- 僵尸进入此距离：触发逃跑
    zombie_melee_distance    = 1.5,  -- 僵尸进入此距离：触发贴脸近战
    emergency_flee_distance  = 10.0, -- 逃跑时朝反方向移动的距离
    state_write_interval_sec = 5,    -- 状态文件写入间隔（秒）
    survival_eat_threshold   = 0.4,  -- 饥饿超过此值（0~1）：自动吃背包里的食物
    survival_drink_threshold = 0.5,  -- 口渴超过此值（0~1）：自动喝水
    survival_check_interval_ms = 3000, -- 生存自动化检查间隔（毫秒），防止动作队列刷屏
    carry_warn_ratio         = 0.8,  -- 负重达到上限的此比例：拒绝继续搜刮（防止贪到跑不动）
    carry_drop_ratio         = 1.0,  -- 负重超过上限的此比例：反射层自动丢弃低价值物品减重
}

-- 文件读写工具（相对根目录 = 用户目录/Zomboid/Lua/）
local function readJsonFile(filename)
    local reader = getFileReader(filename, false)
    if not reader then return nil end
    local lines = {}
    while true do
        local line = reader:readLine()
        if not line then break end
        lines[#lines + 1] = line
    end
    reader:close()
    return json.decode(table.concat(lines, "\n"))
end

local function writeJsonFile(filename, tbl)
    local writer = getFileWriter(filename, true, false)
    if not writer then return end
    writer:write(json.encode(tbl))
    writer:close()
end

-- 事件复盘日志：逐行追加 NDJSON（每条事件开-写-关，游戏崩溃最多丢一条）
-- 与桥接服务的 decisions.ndjson 互补，供 AI 离线复盘、迭代 Lua 代码
local function logEvent(eventType, details)
    local writer = getFileWriter("DeepSeekAI_events.ndjson", true, true) -- 追加模式
    if not writer then return end
    local rec = { ts = getTimestampMs(), type = eventType }
    if type(details) == "table" then
        for k, v in pairs(details) do rec[k] = v end
    end
    writer:write(json.encode(rec) .. "\n")
    writer:close()
end

-- 启动时读取可选的本地配置覆盖文件
do
    local override = readJsonFile("DeepSeekAI_config.json")
    if type(override) == "table" then
        for k, v in pairs(override) do
            if config[k] ~= nil and type(v) == "number" then
                config[k] = v
            end
        end
        print("[DeepSeekAI] 已加载 DeepSeekAI_config.json 配置覆盖")
    end
end

-- ---------------------------------------------------------------------------
-- 运行时状态
-- ---------------------------------------------------------------------------
local emergencyActive = false          -- 紧急状态标志：为 true 时完全跳过 LLM 动作
local currentAction = "idle"           -- 当前正在执行的 LLM 动作（写入状态文件供反思）
local lastActionResult = "none"        -- 上一个动作的执行结果（写入状态文件供反思）
local lastStateWriteMs = 0             -- 上次写状态文件的时间戳
local lastActionReadMs = 0             -- 上次读动作文件的时间戳
local lastFleeMs = 0                   -- 上次下发逃跑指令的时间戳（防止动作队列刷屏）
local lastPursueMs = 0                 -- 上次下发追击移动指令的时间戳（防止动作队列刷屏）
local manualTarget = nil               -- attack_nearest 锁定的目标僵尸（nil 表示当前无主动攻击目标）
local lastActionTimestamp = 0          -- 动作文件的 updated_at，用于识别新决策
local lastSurvivalMs = 0               -- 上次执行生存自动化检查的时间戳
local lastWeightMs = 0                 -- 上次执行背包减重检查的时间戳
local deathHandled = false             -- 本局死亡是否已写局总结（防止事件/轮询重复写）

-- ---------------------------------------------------------------------------
-- 僵尸探测
-- ---------------------------------------------------------------------------

-- 找到最近的僵尸及其距离
local function findNearestZombie(player)
    local list = player:getCell():getZombieList()
    local nearest, nearestDist = nil, math.huge
    for i = 0, list:size() - 1 do
        local z = list:get(i)
        local d = z:DistTo(player)
        if d < nearestDist then
            nearest, nearestDist = z, d
        end
    end
    return nearest, nearestDist
end

-- 统计指定半径内的僵尸数量（供 LLM 判断局势）
local function countZombies(player, radius)
    local list = player:getCell():getZombieList()
    local n = 0
    for i = 0, list:size() - 1 do
        if list:get(i):DistTo(player) <= radius then n = n + 1 end
    end
    return n
end

-- ---------------------------------------------------------------------------
-- 【最高优先级】本地紧急逻辑：贴脸近战 + 危险逃跑，每 tick 执行，零延迟
-- ---------------------------------------------------------------------------
local function emergencyCheck(player)
    local zombie, dist = findNearestZombie(player)

    -- 主动攻击模式：LLM 下发 attack_nearest 后，本地接管追击/近战，
    -- 直到目标消灭、敌人增多或目标过远才交还默认逻辑
    if manualTarget ~= nil then
        -- a) 目标失效（死亡或被引擎回收）：pcall 防止访问失效对象时报错
        local ok, targetDist = pcall(function()
            if manualTarget:isAlive() then
                return manualTarget:DistTo(player)
            end
            return nil
        end)
        if not ok or targetDist == nil then
            manualTarget = nil
            currentAction = "idle"
            lastActionResult = "executed: 目标已消灭"
            player:NPCSetAttack(false)
            player:NPCSetAiming(false)
            -- 清除目标后继续走下方默认逻辑
        elseif countZombies(player, config.zombie_danger_distance) >= 3 then
            -- b) 敌人增多：中止攻击，交还默认逃跑逻辑保命
            manualTarget = nil
            lastActionResult = "failed: 敌人增多，中止攻击"
        elseif targetDist > 25 then
            -- c) 目标过远：放弃追击
            manualTarget = nil
            lastActionResult = "failed: 目标过远"
        else
            -- d) 追击/近战：贴脸直接打，否则每秒重新下发一次走向目标的移动
            emergencyActive = true
            if targetDist <= config.zombie_melee_distance then
                player:faceThisObject(manualTarget)
                player:setRunning(false)
                player:NPCSetAiming(true)
                player:NPCSetAttack(true)
            else
                player:NPCSetAttack(false)
                player:NPCSetAiming(false)
                local now = getTimestampMs()
                if now - lastPursueMs > 1000 then
                    lastPursueMs = now
                    ISTimedActionQueue.clear(player)
                    ISTimedActionQueue.add(ISWalkToTimedAction:new(player,
                        math.floor(manualTarget:getX()), math.floor(manualTarget:getY()), manualTarget:getZ()))
                end
            end
            return targetDist -- 主动攻击期间不走默认逃跑分支
        end
    end

    if not zombie then
        -- 附近没有僵尸：解除紧急状态
        if emergencyActive then
            player:NPCSetAttack(false)
            player:NPCSetAiming(false)
            player:setRunning(false)
            emergencyActive = false
        end
        return math.huge
    end

    if dist <= config.zombie_melee_distance then
        -- 贴脸近战：面向僵尸攻击。这是保命逻辑，绝不交给云端大模型
        emergencyActive = true
        player:faceThisObject(zombie)
        player:setRunning(false)
        player:NPCSetAiming(true)
        player:NPCSetAttack(true)
    elseif dist <= config.zombie_danger_distance then
        -- 危险距离：停止攻击，朝僵尸反方向逃跑
        emergencyActive = true
        player:NPCSetAttack(false)
        player:NPCSetAiming(false)
        player:setRunning(true)

        local now = getTimestampMs()
        if now - lastFleeMs > 1000 then
            lastFleeMs = now
            local dx = player:getX() - zombie:getX()
            local dy = player:getY() - zombie:getY()
            local len = math.sqrt(dx * dx + dy * dy)
            if len < 0.01 then dx, dy, len = 1, 0, 1 end -- 重合时随便选个方向
            local tx = math.floor(player:getX() + dx / len * config.emergency_flee_distance)
            local ty = math.floor(player:getY() + dy / len * config.emergency_flee_distance)
            ISTimedActionQueue.clear(player)
            ISTimedActionQueue.add(ISWalkToTimedAction:new(player, tx, ty, player:getZ()))
        end
    else
        -- 安全距离：解除紧急状态，交还给 LLM 高层决策
        if emergencyActive then
            player:NPCSetAttack(false)
            player:NPCSetAiming(false)
            player:setRunning(false)
            emergencyActive = false
        end
    end

    return dist
end

-- ---------------------------------------------------------------------------
-- 状态采集：写入 DeepSeekAI_state.json，供桥接服务读取
-- ---------------------------------------------------------------------------

-- 采集背包状态：物品按类型名称聚合计数（降序截断前 20 条），并附负重信息
local function collectInventory(player)
    local inv = player:getInventory()
    local items = inv:getItems()
    local counts = {}
    for i = 0, items:size() - 1 do
        local name = items:get(i):getType()
        counts[name] = (counts[name] or 0) + 1
    end
    -- 转成 {name, count} 数组后按数量降序排序，截断前 20 条以控制状态文件体积
    local sorted = {}
    for name, count in pairs(counts) do
        sorted[#sorted + 1] = { name = name, count = count }
    end
    table.sort(sorted, function(a, b) return a.count > b.count end)
    local top = {}
    for i = 1, math.min(20, #sorted) do
        top[i] = sorted[i]
    end
    return {
        inventory = top,        -- 空背包时为空数组（本文件 JSON 编码器会编成 {}，可接受）
        -- 负重口径与 UI 重量条一致：角色层 API（B41 已验证），
        -- 容器层 getCapacityWeight 语义不符（返回的是容量而非当前重量），勿用
        carry_weight = math.floor(player:getInventoryWeight() * 10 + 0.5) / 10, -- 当前负重，保留 1 位小数
        carry_max = player:getMaxWeight(),    -- 负重上限（受力量/特质/伤病影响）
    }
end

local function collectState(player, nearestDist)
    local stats = player:getStats()
    local body = player:getBodyDamage()
    local invState = collectInventory(player)
    return {
        x = math.floor(player:getX()),
        y = math.floor(player:getY()),
        z = player:getZ(),
        health = math.floor(body:getOverallBodyHealth()),     -- 0~100
        hunger = math.floor(stats:getHunger() * 100),         -- 0~1 转百分比
        thirst = math.floor(stats:getThirst() * 100),
        fatigue = math.floor(stats:getFatigue() * 100),
        endurance = math.floor(stats:getEndurance() * 100),
        panic = math.floor(stats:getPanic()),
        infected = body:IsInfected(),
        dead = player:isDead(),               -- 死亡标记：桥接侧据此感知一局结束
        hour = getGameTime():getHour(),
        nearby_zombies = countZombies(player, config.zombie_danger_distance * 3),
        nearest_zombie_dist = nearestDist == math.huge and -1 or math.floor(nearestDist * 10) / 10,
        emergency = emergencyActive,
        current_action = currentAction,
        last_action_result = lastActionResult,
        inventory = invState.inventory,       -- 背包物品聚合（供 LLM 决策吃什么/用什么）
        carry_weight = invState.carry_weight, -- 当前负重
        carry_max = invState.carry_max,       -- 负重上限
        updated_at = getTimestampMs(),
    }
end

-- ---------------------------------------------------------------------------
-- 搜刮：在玩家当前格及相邻 8 格内寻找容器，收集有价值物品
-- ---------------------------------------------------------------------------

-- 有价值物品类别过滤表（只收集这些类别的物品）
local lootCategories = {
    Food = true,
    FirstAid = true,
    Weapon = true,
    Container = true,
    Literature = true,
}

local function doLoot(player)
    -- 负重守卫：超过八成上限就拒绝搜刮（与种子经验第 1 条一致），防止贪到跑不动
    local maxW = player:getMaxWeight()
    if maxW > 0 and player:getInventoryWeight() > maxW * config.carry_warn_ratio then
        lastActionResult = "failed: 负重超过八成，停止搜刮"
        return
    end

    local sq = player:getCurrentSquare()
    if not sq then
        lastActionResult = "failed: 无法获取当前格子"
        return
    end

    -- 收集当前格 + 相邻 8 格（相邻格可能不存在，需判 nil）
    local squares = { sq }
    local dirs = {
        IsoDirections.N, IsoDirections.S, IsoDirections.E, IsoDirections.W,
        IsoDirections.NE, IsoDirections.NW, IsoDirections.SE, IsoDirections.SW,
    }
    for _, dir in ipairs(dirs) do
        local adj = sq:getAdjacentSquare(dir)
        if adj then squares[#squares + 1] = adj end
    end

    -- 在所有格子中找出带容器的对象（一个对象可能有多个容器）
    local found = {} -- 元素：{ container = 容器, square = 所在格 }
    for _, s in ipairs(squares) do
        local objs = s:getObjects()
        for i = 0, objs:size() - 1 do
            local obj = objs:get(i)
            if obj and obj:getContainerCount() > 0 then
                for ci = 0, obj:getContainerCount() - 1 do
                    local container = obj:getContainerByIndex(ci)
                    if container then
                        found[#found + 1] = { container = container, square = s }
                    end
                end
            end
        end
    end

    if #found == 0 then
        lastActionResult = "failed: 附近没有可搜刮容器"
        return
    end

    -- 限量：单次 loot 最多处理 2 个容器，每个容器最多取 5 件
    local lootedCount = 0
    local handled = 0
    for _, entry in ipairs(found) do
        if handled >= 2 then break end
        local container = entry.container
        -- 先把有价值物品收集到临时表，避免边遍历边从容器删除
        local toTake = {}
        local items = container:getItems()
        for i = 0, items:size() - 1 do
            local item = items:get(i)
            if item and lootCategories[item:getCategory()] then
                toTake[#toTake + 1] = item
                if #toTake >= 5 then break end
            end
        end
        if #toTake > 0 then
            -- 容器不在玩家当前格：先走过去（原型简化：仍直接转移物品，不等走到）
            if entry.square ~= sq then
                ISTimedActionQueue.clear(player)
                ISTimedActionQueue.add(ISWalkToTimedAction:new(player,
                    entry.square:getX(), entry.square:getY(), entry.square:getZ()))
            end
            for _, item in ipairs(toTake) do
                player:getInventory():AddItem(item)
                container:Remove(item)
                lootedCount = lootedCount + 1
            end
            handled = handled + 1
        end
    end

    if lootedCount > 0 then
        currentAction = "loot"
        lastActionResult = "executed: loot 获得 " .. lootedCount .. " 件物品"
    else
        lastActionResult = "failed: 容器中没有有用物品"
    end
end

-- ---------------------------------------------------------------------------
-- 生存自动化（反射层）：吃喝/包扎/装备武器即时处理，不占用 LLM 决策
-- API 用法参照 B41 实战模组 SuperiorSurvivors_Revisited（EatFoodTask /
-- FirstAideTask / EquipWeaponTask）。注意：只搜索主背包（doLoot 搜刮的
-- 物品也放入主背包），吃/喝/包扎的 isValid 均要求物品在主背包。
-- ---------------------------------------------------------------------------

-- 找最值得吃的食物：排除有毒/变质/黑名单物品，按解饿值选最优
local function findFood(inv)
    local blacklist = { Bleach = true, Cigarettes = true, HCCigar = true, Antibiotics = true }
    local items = inv:getItems()
    local best, bestScore = nil, 0
    for i = 0, items:size() - 1 do                    -- Java 列表从 0 开始遍历
        local item = items:get(i)
        if item:getCategory() == "Food"
           and item:getPoisonPower() <= 1             -- 排除漂白剂/被下毒
           and not blacklist[item:getType()]
           and not item:IsRotten() then               -- 排除变质食物
            local score = -item:getHungerChange()     -- 解饿值为负，取反后越大越好
            if score > bestScore then best, bestScore = item, score end
        end
    end
    return best
end

-- 找可饮用的水（排除漂白剂）
local function findWater(inv)
    local items = inv:getItems()
    for i = 0, items:size() - 1 do
        local item = items:get(i)
        if item:isWaterSource() and item:getType() ~= "Bleach" then
            return item
        end
    end
    return nil
end

-- 找绷带：绷带/碎布均可，取绷带强度最高者
local function findBandage(inv)
    local items = inv:getItems()
    local best, bestPow = nil, 0
    for i = 0, items:size() - 1 do
        local item = items:get(i)
        if item:isCanBandage() and item:getBandagePower() > bestPow then
            best, bestPow = item, item:getBandagePower()
        end
    end
    return best
end

-- 找伤害最高的武器（过滤伤害过低的“武器类杂物”）
local function findBestWeapon(inv)
    local items = inv:getItems()
    local best, bestDmg = nil, 0.1
    for i = 0, items:size() - 1 do
        local item = items:get(i)
        if item:getCategory() == "Weapon" and item:getMaxDamage() > bestDmg then
            best, bestDmg = item, item:getMaxDamage()
        end
    end
    return best
end

-- 生存自动化主入口：满足条件立即排队对应动作（带节流与守卫）
local function autoSurvival(player, nowMs)
    if nowMs - lastSurvivalMs < config.survival_check_interval_ms then return end
    if player:isInAction() then return end      -- 正在执行动作（走路/吃喝/包扎中）时不打断
    lastSurvivalMs = nowMs
    if emergencyActive then return end          -- 紧急状态只做保命，生存自动化全部暂停

    local inv = player:getInventory()

    -- 1) 流血最优先：包扎第一个流血且未包扎的部位（拖久了会失血致死）
    local bodyparts = player:getBodyDamage():getBodyParts()
    for i = 0, bodyparts:size() - 1 do
        local bp = bodyparts:get(i)
        if bp:bleeding() and not bp:bandaged() then
            local bandage = findBandage(inv)
            if bandage then
                ISTimedActionQueue.add(ISApplyBandage:new(player, player, bandage, bp, true))
                logEvent("auto_bandage", { item = bandage:getType() })
            end
            return
        end
    end

    -- 2) 饥饿：自动吃下解饿值最高的食物（每次吃 1/4，饿了再吃）
    local stats = player:getStats()
    if stats:getHunger() > config.survival_eat_threshold then
        local food = findFood(inv)
        if food then
            ISTimedActionQueue.add(ISEatFoodAction:new(player, food, 0.25))
            logEvent("auto_eat", { item = food:getType(), hunger = stats:getHunger() })
        end
        return
    end

    -- 3) 口渴：按口渴程度喝水（复刻原版 onDrinkForThirst 的份数算法）
    if stats:getThirst() > config.survival_drink_threshold then
        local water = findWater(inv)
        if water then
            local units = math.min(math.ceil(stats:getThirst() / 0.1), 10, water:getDrainableUsesInt())
            if units > 0 then
                ISTimedActionQueue.add(ISDrinkFromBottle:new(player, water, units))
                logEvent("auto_drink", { item = water:getType(), thirst = stats:getThirst() })
            end
        end
        return
    end

    -- 4) 主手为空且背包有武器：自动装备最好的武器（双手武器需同步副手）
    if player:getPrimaryHandItem() == nil then
        local weapon = findBestWeapon(inv)
        if weapon then
            player:setPrimaryHandItem(weapon)
            if weapon:isRequiresEquippedBothHands() then
                player:setSecondaryHandItem(weapon)
            end
            logEvent("auto_equip", { item = weapon:getType() })
        end
    end
end

-- ---------------------------------------------------------------------------
-- 背包管理（反射层）：超重时自动把低价值物品扔到地面减重
-- 「低价值」= 不在 lootCategories 白名单、不是生存刚需（水/绷带）、不在手上、
-- 未被收藏的物品。走原版 ISDropWorldItemAction 扔到地面而不是直接销毁，
-- 之后还能回来捡；每次检查最多扔 1 件，与生存自动化共用节流节奏。
-- ---------------------------------------------------------------------------

-- 找最该扔的物品：可扔物品里最重的一件
local function findDropCandidate(player)
    local items = player:getInventory():getItems()
    local worst, worstWeight = nil, 0
    for i = 0, items:size() - 1 do
        local item = items:get(i)
        if not lootCategories[item:getCategory()]         -- 白名单类别（食物/药品/武器/包/书）不扔
           and not item:isWaterSource()                   -- 水容器是生存刚需，不扔
           and not item:isCanBandage()                    -- 绷带同理
           and item ~= player:getPrimaryHandItem()        -- 手上的装备不扔
           and item ~= player:getSecondaryHandItem()
           and not item:isFavorite() then                 -- 玩家收藏的物品不扔
            local w = item:getActualWeight()
            if w > worstWeight then worst, worstWeight = item, w end
        end
    end
    return worst
end

-- 背包管理主入口：负重超过 carry_drop_ratio 时扔一件最低价值物品
local function autoManageWeight(player, nowMs)
    if nowMs - lastWeightMs < config.survival_check_interval_ms then return end
    lastWeightMs = nowMs
    if emergencyActive then return end     -- 逃命中动作队列会被 flee 反复清空，扔了也完不成
    if player:isInAction() then return end -- 正在执行动作时不打断

    local maxW = player:getMaxWeight()
    if maxW <= 0 then return end
    local ratio = player:getInventoryWeight() / maxW
    if ratio < config.carry_drop_ratio then return end

    local item = findDropCandidate(player)
    if not item then
        logEvent("auto_drop_skip", { reason = "背包全是刚需物品，无物可扔", ratio = math.floor(ratio * 100) / 100 })
        return
    end
    local sq = player:getCurrentSquare()
    if not sq then return end
    ISTimedActionQueue.add(ISDropWorldItemAction:new(player, item, sq, 0.0, 0.0, 0.0, 0, false))
    logEvent("auto_drop", { item = item:getType(), weight = math.floor(item:getActualWeight() * 100) / 100, ratio = math.floor(ratio * 100) / 100 })
end

-- ---------------------------------------------------------------------------
-- 动作执行：读取 DeepSeekAI_action.json，执行 LLM 的高层决策（非紧急时）
-- ---------------------------------------------------------------------------
local function executeAction(player)
    local payload = readJsonFile("DeepSeekAI_action.json")
    if type(payload) ~= "table" then return end

    -- 阈值热更新：桥接服务每次下发动作都会附带最新阈值，优先级最高
    if type(payload.thresholds) == "table" then
        for k, v in pairs(payload.thresholds) do
            if config[k] ~= nil and type(v) == "number" then config[k] = v end
        end
    end

    -- 没有新决策就不重复执行
    if type(payload.updated_at) ~= "number" or payload.updated_at <= lastActionTimestamp then
        return
    end
    lastActionTimestamp = payload.updated_at

    local decision = payload.decision
    if type(decision) ~= "table" or type(decision.immediate_action) ~= "table" then return end
    local act = decision.immediate_action
    local atype = act.type

    if atype == "move_to" or atype == "flee" then
        if type(act.x) == "number" and type(act.y) == "number" then
            ISTimedActionQueue.clear(player)
            ISTimedActionQueue.add(ISWalkToTimedAction:new(player, math.floor(act.x), math.floor(act.y), player:getZ()))
            currentAction = atype .. " (" .. math.floor(act.x) .. "," .. math.floor(act.y) .. ")"
            lastActionResult = "executed"
        else
            lastActionResult = "failed: 缺少目标坐标"
        end
    elseif atype == "rest" then
        -- 原地休息：清空队列并停止奔跑，等体力自然恢复
        ISTimedActionQueue.clear(player)
        player:setRunning(false)
        currentAction = "rest"
        lastActionResult = "executed"
    elseif atype == "idle" then
        currentAction = "idle"
        lastActionResult = "executed"
    elseif atype == "loot" then
        doLoot(player)
    elseif atype == "attack_nearest" then
        -- 主动攻击前先评估局势：危险距离内僵尸过多则拒绝送死
        if countZombies(player, config.zombie_danger_distance) > 2 then
            lastActionResult = "failed: 僵尸过多，拒绝主动攻击"
        else
            local target = findNearestZombie(player)
            if not target then
                lastActionResult = "failed: 附近没有僵尸"
            else
                -- 锁定目标，之后每 tick 由 emergencyCheck 的主动攻击分支接管追击/近战
                manualTarget = target
                currentAction = "attack_nearest"
                lastActionResult = "executed: 开始追击目标"
            end
        end
    else
        lastActionResult = "failed: 未知动作类型 " .. tostring(atype)
    end
    -- 每个 LLM 动作的执行结果也记入复盘日志（与桥接侧 decisions.ndjson 互补）
    logEvent("llm_action", { action = tostring(atype), result = lastActionResult })
end

-- ---------------------------------------------------------------------------
-- 死亡检测与局总结：OnPlayerDeath 事件 + onTick 轮询 isDead 兜底（双保险）
-- 局总结写入复盘日志（type=death_summary），是阶段三调参的「一局结束」
-- 结构化信号：存活时长/击杀数/死因代理指标/死亡位置。
-- 注意 B41 没有可靠的死因 API（getCauseOfDeath 不存在），只能用代理指标推断。
-- ---------------------------------------------------------------------------

-- 用可验证的代理指标推断死因（火烧 > Knox 感染 > 外伤）
local function guessDeathCause(player)
    local body = player:getBodyDamage()
    if body:IsOnFire() then return "fire" end
    if body:IsInfected() then return "knox_infection" end
    return "trauma" -- 最常见的直接死因（僵尸围殴/坠落等），无法进一步区分
end

-- 新一局开始时重置全部运行时状态（复活/新角色）
local function resetRuntimeState()
    emergencyActive = false
    manualTarget = nil
    currentAction = "idle"
    lastActionResult = "none"
    lastActionTimestamp = 0
    lastFleeMs = 0
    lastPursueMs = 0
    lastSurvivalMs = 0
    lastWeightMs = 0
end

-- 写局总结并收尾（幂等：同一局只写一次）
local function writeDeathSummary(player, source)
    if deathHandled then return end
    deathHandled = true
    local body = player:getBodyDamage()
    logEvent("death_summary", {
        source = source, -- event=OnPlayerDeath 事件；tick=onTick 轮询兜底
        survived_hours = math.floor(player:getHoursSurvived() * 100) / 100,
        survived_nights = getGameTime():getNightsSurvived(),
        zombie_kills = player:getZombieKills(),
        cause = guessDeathCause(player),
        infected = body:IsInfected(),
        x = math.floor(player:getX()),
        y = math.floor(player:getY()),
        game_hour = getGameTime():getHour(),
    })
    -- 最后写一次状态（dead=true），桥接侧据此停止 LLM 调用并记录一局结束
    writeJsonFile("DeepSeekAI_state.json", collectState(player, math.huge))
    resetRuntimeState()
    print("[DeepSeekAI] 玩家死亡，局总结已写入复盘日志（来源: " .. source .. "）")
end

-- 事件通道：死亡瞬间触发（参数为死亡的本地玩家，参照 The Only Cure 模组用法）
local function onPlayerDeath(player)
    if player ~= getSpecificPlayer(0) then return end -- 只跟踪主玩家（兼容分屏）
    writeDeathSummary(player, "event")
end
Events.OnPlayerDeath.Add(onPlayerDeath)

-- ---------------------------------------------------------------------------
-- 主循环：每个游戏 tick 触发
-- 执行顺序严格固定：死亡兜底 -> 紧急逻辑 -> 生存自动化 -> 背包管理 -> 状态写入 -> LLM 动作执行
-- ---------------------------------------------------------------------------
local function onTick()
    local player = getSpecificPlayer(0)
    if not player then return end -- 存档未加载完成时跳过

    -- 0) 死亡兜底：事件因故未触发时，轮询 isDead 也能补写局总结；
    --    死亡后不再执行任何后续逻辑
    if player:isDead() then
        writeDeathSummary(player, "tick")
        return
    end
    deathHandled = false -- 活着（新一局/复活）则重新武装死亡检测

    -- 1) 本地紧急逻辑永远最先执行，毫秒级保命
    local nearestDist = emergencyCheck(player)

    local now = getTimestampMs()

    -- 1.5) 反射层生存自动化：吃喝/包扎/装备武器（内部有节流与紧急守卫）
    autoSurvival(player, now)

    -- 1.6) 反射层背包管理：超重自动扔低价值物品减重（内部有节流与紧急守卫）
    autoManageWeight(player, now)

    -- 2) 按间隔写入状态文件（紧急时也写：桥接服务看到 emergency=true 会暂停 LLM 调用）
    if now - lastStateWriteMs >= config.state_write_interval_sec * 1000 then
        lastStateWriteMs = now
        writeJsonFile("DeepSeekAI_state.json", collectState(player, nearestDist))
    end

    -- 3) 仅在非紧急状态下读取并执行 LLM 决策（限频 1s，避免每 tick 做文件 IO）
    if not emergencyActive and now - lastActionReadMs >= 1000 then
        lastActionReadMs = now
        executeAction(player)
    end
end

Events.OnTick.Add(onTick)
print("[DeepSeekAI] 模组已加载：本地紧急逻辑就绪，等待桥接服务连接")
