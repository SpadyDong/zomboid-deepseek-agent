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
local lastActionTimestamp = 0          -- 动作文件的 updated_at，用于识别新决策

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
local function collectState(player, nearestDist)
    local stats = player:getStats()
    local body = player:getBodyDamage()
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
        hour = getGameTime():getHour(),
        nearby_zombies = countZombies(player, config.zombie_danger_distance * 3),
        nearest_zombie_dist = nearestDist == math.huge and -1 or math.floor(nearestDist * 10) / 10,
        emergency = emergencyActive,
        current_action = currentAction,
        last_action_result = lastActionResult,
        updated_at = getTimestampMs(),
    }
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
    elseif atype == "loot" or atype == "attack_nearest" then
        -- 原型阶段降级：复杂交互待后续版本实现，先跳过不执行
        currentAction = atype
        lastActionResult = "pending: " .. atype .. " 待实现"
        print("[DeepSeekAI] 动作 " .. atype .. " 原型阶段暂未实现，已跳过")
    else
        lastActionResult = "failed: 未知动作类型 " .. tostring(atype)
    end
end

-- ---------------------------------------------------------------------------
-- 主循环：每个游戏 tick 触发
-- 执行顺序严格固定：紧急逻辑 -> 状态写入 -> LLM 动作执行
-- ---------------------------------------------------------------------------
local function onTick()
    local player = getSpecificPlayer(0)
    if not player then return end -- 存档未加载完成时跳过

    -- 1) 本地紧急逻辑永远最先执行，毫秒级保命
    local nearestDist = emergencyCheck(player)

    local now = getTimestampMs()

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
