# zomboid-deepseek-agent

[![License: AGPL v3](https://img.shields.io/badge/License-AGPL%20v3-blue.svg)](https://www.gnu.org/licenses/agpl-3.0)

《僵尸毁灭工程 Project Zomboid》AI 幸存者 Agent，使用 **DeepSeek 官方 API** 驱动。
灵感来源：Claude Survives Zomboid。

> **核心设计约束**：云端 DeepSeek API 存在网络推理延迟（秒级），
> **贴脸近战等即时保命动作绝不交给大模型**，由游戏内 Lua 本地逻辑毫秒级处理。

## 架构原理

分层混合架构，职责严格分离：

```
┌─────────────────────────────────────────────────────────────┐
│  Project Zomboid 游戏进程                                    │
│  ┌───────────────────────────────────────────────────────┐  │
│  │  DeepSeekAI.lua（客户端模组）                          │  │
│  │  ① emergencyCheck 本地紧急逻辑（每 tick，零延迟）       │  │
│  │     · 僵尸 ≤ 1.5 格：面向僵尸近战攻击                  │  │
│  │     · 僵尸 ≤ 6.0 格：朝反方向逃跑                      │  │
│  │  ② 状态采集：每 5s 写 DeepSeekAI_state.json            │  │
│  │  ③ 动作执行：读 DeepSeekAI_action.json（非紧急时）      │  │
│  └──────────┬────────────────────────────▲────────────────┘  │
└─────────────┼──────── 文件 IPC ──────────┼───────────────────┘
              │ state.json                 │ action.json
              ▼                            │
┌─────────────────────────────────────────────────────────────┐
│  Python FastAPI 桥接服务（本地后台，127.0.0.1:8765）          │
│  · 轮询状态文件，限频调用 LLM（默认 30s/次，防 token 爆炸）   │
│  · 维护 Agent 记忆（最近 10 轮）+ 长期记忆 + 定期深度反思     │
│  · 经验系统：失败自动提炼教训，也可人工注入/删除经验           │
│  · 目标系统：支持下发临时目标（自动过期）与分阶段目标          │
│  · 状态持久化到 data/agent_state.json，重启不丢记忆           │
│  · 自动截断超长上下文；API 失败时沿用旧策略，角色不卡死        │
│  · SSE 流式解析 DeepSeek 返回内容                            │
└──────────────────────────┬──────────────────────────────────┘
                           │ HTTPS（SSE 流式）
                           ▼
┌─────────────────────────────────────────────────────────────┐
│  DeepSeek LLM（api.deepseek.com）                            │
│  只输出「高层生存策略」的结构化 JSON：                        │
│  thought / immediate_action / plan / reflection / lesson /   │
│  goal_status / memory_note                                   │
│  固定顶层目标：活下来 > 安全屋 > 食物饮水 > 谨慎探索           │
└─────────────────────────────────────────────────────────────┘
```

**为什么用文件 IPC 而不是 HttpRequest？** 原版 PZ Lua（Kahlua）没有提供 HTTP 客户端
API，社区同类项目（包括 Claude Survives Zomboid）均采用 `getFileReader` /
`getFileWriter` 文件读写做进程间通信。文件读写的根目录是 `用户目录/Zomboid/Lua/`。

## 目录结构

```
zomboid-deepseek-agent/
├── LICENSE                     # AGPLv3 许可证全文
├── README.md
├── .gitignore                  # 屏蔽 .env / 密钥 / 日志 / 缓存
├── pyproject.toml              # Python 依赖：fastapi, uvicorn, requests
├── .env.example                # 环境变量模板（DEEPSEEK_API_KEY 等）
├── src/
│   ├── pz_bridge.py            # FastAPI 桥接服务（记忆/经验/目标/限流/SSE 解析）
│   └── config.json             # 全部数值阈值（方便后续 AI 自动调参）
├── data/
│   └── agent_state.json        # Agent 状态持久化（记忆/经验/目标，运行时自动生成）
└── zomboid-mod/
    ├── mod.info                # PZ 模组定义（Build 41.78+）
    └── media/lua/client/DeepSeekAI.lua  # 游戏内客户端脚本
```

## 前置依赖

- Project Zomboid **Build 41.78+**（模组为 B41 布局）
- Python **3.10+**
- 一个 DeepSeek API Key（https://platform.deepseek.com 申请）

安装 Python 依赖：

```bash
pip install fastapi uvicorn requests
# 或者
pip install -e .
```

## 启动流程

**顺序不能反：先启动桥接服务，再开游戏。**

### 1. 配置密钥

```bash
cp .env.example .env
# 编辑 .env，填入你的 DEEPSEEK_API_KEY（不要提交到 git！）
```

如 PZ 的 Lua 目录不在默认位置，在 `.env` 中设置 `PZ_IPC_DIR` 指向
`用户目录/Zomboid/Lua`。

### 2. 安装模组

把 `zomboid-mod/` 整个目录复制到 PZ 模组目录：

```
Windows:  C:\Users\<你>\Zomboid\mods\DeepSeekAI
Linux:    ~/Zomboid/mods/DeepSeekAI
```

注意复制后目录名建议改为 `DeepSeekAI`（与 mod.info 中的 id 一致）。

### 3. 启动桥接服务

```bash
uvicorn src.pz_bridge:app --host 127.0.0.1 --port 8765
```

看到 `决策循环已启动` 日志即就绪。可用 `curl http://127.0.0.1:8765/health` 验证。

### 4. 启动游戏

开启 Project Zomboid，在主菜单「模组」中启用 **DeepSeek AI Survivor**，
进入存档后模组自动开始工作：本地紧急逻辑立即生效，状态文件开始写入，
桥接服务检测到状态文件后按 30s 间隔向 DeepSeek 请求高层策略。

## 能力迭代：经验系统与目标系统

Agent 具备自我迭代能力，同时支持人工干预，形成三条成长通道：

```
        ┌───────────────── 自我迭代闭环 ─────────────────┐
        ▼                                                │
每轮决策后对比前后状态（掉血/感染/动作失败/僵尸增多）
  → LLM 在 lesson 字段中提炼可复用教训
  → 教训持久化，注入后续每一轮提示词（必须避免重蹈覆辙）

人工通道（HTTP API，立即生效）：
  · 补充经验：POST /experience    —— 标记为「人工」，优先级最高
  · 下发临时目标：POST /goal       —— 带轮数上限，自动过期
  · 下发阶段目标：POST /goal       —— 按顺序逐个推进
```

### 经验系统（lessons）

- **自动提炼**：LLM 每轮都会收到「上一轮结果评估」（如「生命值 92→55，
  受伤了！必须反思原因」），若本轮付出了代价，会在 `lesson` 字段输出一条
  ≤50 字的可复用教训，桥接服务自动入库。
- **人工注入**：通过 `POST /experience` 直接写入，提示词中标记为 `(人工)`，
  LLM 被告知此类经验优先级最高。
- **去重与上限**：相同文本的经验只保留一条；总数超过 `max_lessons`
  （默认 50）时丢弃最旧的。
- **结局沉淀**：临时目标被完成/放弃/过期时，自动转为一条经验
  （如「临时目标『找到罐头』已完成」）。

### 目标系统（goals）

- **临时目标** `temporary_goal`：人类下发的单点目标（如「去北侧民宅找食物」），
  注入提示词并附带剩余轮数。LLM 每轮通过 `goal_status` 回报
  `in_progress / achieved / abandoned`；完成或放弃后自动结算为经验。
  超过 `expires_rounds` 轮仍未完成则自动过期（同样沉淀为经验）。
- **阶段目标** `phased_goals`：有序的里程碑列表（如「找到安全屋 → 稳定水源
  → 囤积一周食物」），每轮只向 LLM 注入**当前第一个未完成**的阶段，
  通过 `POST /goal/phase/done` 推进。
- 目标与固定顶层目标的关系：提示词明确要求 LLM「在不违背顶层目标
  （活下来）的前提下优先完成人类目标」。

### 状态持久化

记忆（最近 10 轮 + 长期记忆）、全部经验、临时/阶段目标、决策轮数，
在每次状态变更后原子写入 `data/agent_state.json`（先写 `.tmp` 再替换，
防写坏）。服务重启时自动恢复，LLM 的成长不会丢失。该文件已加入
`.gitignore`，不会提交。

## HTTP API 一览

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| GET | `/health` | 健康检查 |
| GET | `/memory` | 查看记忆、经验与目标的完整快照（调试用） |
| POST | `/experience` | 人工注入经验，body: `{"text": "夜间不要出门"}` |
| GET | `/experience` | 列出全部经验（含来源 `human`/`self` 与提炼轮数） |
| DELETE | `/experience/{index}` | 按下标删除经验，越界返回 404 |
| POST | `/goal` | 下发目标，body: `{"text": "...", "type": "temporary\|phased", "expires_rounds": 20}` |
| GET | `/goal` | 查看临时目标、各阶段进度与当前阶段 |
| DELETE | `/goal` | 人工提前清除临时目标（不记结局经验） |
| POST | `/goal/phase/done` | 当前阶段标记完成并推进，无进行中阶段返回 404 |
| POST | `/strategy/test` | 用伪造状态走完整 LLM 决策（无需启动游戏） |

## 重要限制

- **云端 API 有秒级延迟**：因此 LLM 只做战略决策（去哪、做什么），
  贴脸近战、紧急逃跑永远由 Lua 本地逻辑处理。请勿修改这一分层。
- **API 失败降级**：DeepSeek 不可达/超时/返回非法 JSON 时，桥接服务不改写
  动作文件，角色继续执行旧策略，不会卡死原地。
- **原型阶段**：`loot`（搜刮）与 `attack_nearest`（主动攻击）动作暂以
  占位方式降级处理（记录日志不执行），后续版本实现。
- **Token 成本**：默认 30s 一次 LLM 调用 + 记忆窗口 10 轮 + 上下文 6000 字符
  截断，长时间挂机仍会产生 API 费用，请留意额度。
- 所有可调参数集中在 `src/config.json`，Lua 侧每次读取动作文件时
  会热更新阈值，无需重启游戏。

## 无游戏测试（推荐先做）

不启动游戏也能验证完整链路：

```bash
# 健康检查
curl http://127.0.0.1:8765/health

# 用伪造的游戏状态触发一次完整 LLM 决策
curl -X POST http://127.0.0.1:8765/strategy/test \
  -H "Content-Type: application/json" \
  -d '{"state": {"x": 10000, "y": 10000, "z": 0, "health": 95, "hunger": 60,
       "thirst": 40, "fatigue": 20, "panic": 0, "infected": false,
       "hour": 9, "nearby_zombies": 2, "nearest_zombie_dist": 8.5,
       "emergency": false, "current_action": "idle",
       "last_action_result": "none"}}'

# 查看 Agent 记忆与反思历史
curl http://127.0.0.1:8765/memory

# 人工注入一条经验（下一轮提示词即生效）
curl -X POST http://127.0.0.1:8765/experience \
  -H "Content-Type: application/json" \
  -d '{"text": "夜间不要出门，视野太差"}'

# 下发一个 15 轮内有效的临时目标
curl -X POST http://127.0.0.1:8765/goal \
  -H "Content-Type: application/json" \
  -d '{"text": "在附近民宅找到罐头食物", "type": "temporary", "expires_rounds": 15}'

# 追加阶段目标 / 查看目标 / 完成当前阶段
curl -X POST http://127.0.0.1:8765/goal \
  -H "Content-Type: application/json" \
  -d '{"text": "建立有水源的安全屋", "type": "phased"}'
curl http://127.0.0.1:8765/goal
curl -X POST http://127.0.0.1:8765/goal/phase/done
```

把 API Key 改错再调 `/strategy/test`，应返回 `{"decision": null}` ——
验证降级行为符合预期。

## License

本项目采用 **GNU Affero General Public License v3.0 (AGPLv3)** 开源。
详见 [LICENSE](LICENSE)。任何通过网络交互使用本项目修改版的服务，
都必须向用户提供对应源代码。

## 路线图

- **阶段一：原型验证**（已完成）
  文件 IPC 链路打通、LLM 策略循环、记忆与反思、紧急逻辑兜底、降级保护。
- **阶段二：能力迭代**（当前）
  经验系统（失败自动提炼教训 + 人工注入）、临时/阶段目标系统、
  Agent 状态持久化，AI 可在不修改代码的前提下持续积累经验。
- **阶段三：参数自动调优**
  `src/config.json` 中阈值已外置且支持热更新；后续让 Agent 根据死亡/受伤
  反馈自动调整 `zombie_danger_distance`、`api_interval_sec` 等参数。
- **阶段四：离线 Lua 代码迭代**
  让 LLM 生成/改进 Lua 侧的动作实现（搜刮、战斗、建造等），
  本地沙箱验证后热加载，逐步减少人工编码。
