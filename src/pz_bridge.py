"""
Project Zomboid × DeepSeek 桥接服务
====================================

职责：
1. 通过「文件 IPC」与游戏内 Lua 模组通信（原版 PZ Lua 无 HttpRequest，社区通用做法）：
   - 读取 Lua 写入的状态文件  DeepSeekAI_state.json   （Lua -> Python）
   - 写入 LLM 决策的动作文件 DeepSeekAI_action.json  （Python -> Lua）
2. 按固定频率异步调用 DeepSeek API（SSE 流式），只让大模型做「高层生存策略」决策。
3. 维护 Agent 记忆与反思历史，自动截断超长上下文，防止 token 爆炸。
4. API 调用失败时不改写动作文件 —— Lua 侧继续执行旧策略，角色不会卡死。

启动方式：
    uvicorn src.pz_bridge:app --host 127.0.0.1 --port 8765
"""

import json
import logging
import os
import sys
import threading
import time
from collections import deque
from pathlib import Path

import requests
from fastapi import FastAPI
from pydantic import BaseModel

# ---------------------------------------------------------------------------
# 路径与日志
# ---------------------------------------------------------------------------

BASE_DIR = Path(__file__).resolve().parent.parent          # 项目根目录
CONFIG_PATH = Path(__file__).resolve().parent / "config.json"
LOG_DIR = BASE_DIR / "logs"
LOG_DIR.mkdir(exist_ok=True)

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[
        logging.FileHandler(LOG_DIR / "bridge.log", encoding="utf-8"),
        logging.StreamHandler(sys.stdout),
    ],
)
log = logging.getLogger("pz_bridge")


# ---------------------------------------------------------------------------
# 环境变量与配置加载
# ---------------------------------------------------------------------------

def load_env() -> None:
    """手动解析项目根目录的 .env（不引入 python-dotenv 等额外依赖）。

    已存在的系统环境变量优先级更高，不会被 .env 覆盖。
    """
    env_file = BASE_DIR / ".env"
    if not env_file.exists():
        return
    for line in env_file.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        os.environ.setdefault(key.strip(), value.strip().strip('"').strip("'"))


def load_config() -> dict:
    """读取 src/config.json，全部数值阈值集中在此，方便后续 AI 自动调参。"""
    with open(CONFIG_PATH, encoding="utf-8") as f:
        return json.load(f)


def detect_ipc_dir() -> Path:
    """定位 PZ 的 Zomboid/Lua 目录（getFileReader/getFileWriter 的相对根目录）。

    可用环境变量 PZ_IPC_DIR 显式覆盖；否则按常见系统路径自动探测。
    """
    override = os.environ.get("PZ_IPC_DIR")
    if override:
        return Path(override)

    home = Path.home()
    candidates = [
        home / "Zomboid" / "Lua",                                  # Windows / Linux 默认
        home / "Library" / "Application Support" / "ProjectZomboid" / "Lua",  # macOS 备选
    ]
    for c in candidates:
        if c.exists():
            return c
    # 都没找到时返回默认路径（服务仍可启动，仅提示警告）
    log.warning("未找到 Zomboid/Lua 目录，请通过环境变量 PZ_IPC_DIR 指定。默认使用: %s", candidates[0])
    return candidates[0]


load_env()
CONFIG = load_config()

API_KEY = os.environ.get("DEEPSEEK_API_KEY", "").strip()
BASE_URL = os.environ.get("DEEPSEEK_BASE_URL", "https://api.deepseek.com").rstrip("/")
MODEL = os.environ.get("DEEPSEEK_MODEL", "deepseek-chat")

IPC_DIR = detect_ipc_dir()
STATE_FILE = IPC_DIR / "DeepSeekAI_state.json"    # Lua 写入，Python 读取
ACTION_FILE = IPC_DIR / "DeepSeekAI_action.json"  # Python 写入，Lua 读取

if not API_KEY:
    # 启动即校验密钥：宁可直接报错退出，也不让服务带着错误配置空跑
    log.error("未检测到 DEEPSEEK_API_KEY！请复制 .env.example 为 .env 并填入真实密钥后重启。")
    sys.exit(1)


# ---------------------------------------------------------------------------
# LLM 提示词（固定顶层目标 + 强制 JSON 输出）
# ---------------------------------------------------------------------------

SYSTEM_PROMPT = """你是《僵尸毁灭工程 Project Zomboid》中的一名 AI 幸存者，由 DeepSeek 驱动。

【固定顶层目标】
1. 活下来 —— 高于一切。受伤、感染、被包围时优先保命。
2. 建立/巩固安全屋。
3. 保障食物与饮水。
4. 谨慎探索，避免不必要的战斗。

【重要约束】
- 你只做「高层战略决策」。贴脸近战、紧急逃跑由游戏内 Lua 本地逻辑毫秒级处理，与你无关。
- 每次决策会携带：当前游戏状态、最近的历史动作+结果、你之前的反思。
- 你必须输出严格合法的 JSON，禁止输出任何 JSON 以外的文字、注释或 markdown 代码块。

【输出 JSON 格式】（字段缺一不可）
{
  "thought": "对当前局势的简要分析（<=80字）",
  "immediate_action": {
    "type": "move_to | loot | rest | flee | idle | attack_nearest",
    "x": 目标格子X坐标(整数, 仅move_to/flee需要),
    "y": 目标格子Y坐标(整数, 仅move_to/flee需要),
    "reason": "为什么这么做（<=40字）"
  },
  "plan": ["未来几步的子计划1", "子计划2", "子计划3"],
  "reflection": "对照上一轮结果反思：上一轮做对了什么/错了什么（<=60字）",
  "memory_note": "值得长期记住的信息（如安全屋位置、资源点），没有则填空字符串"
}

【动作类型说明】
- move_to: 移动到指定坐标（探索、前往资源点、回安全屋）
- flee:    战略性转移（远离当前区域，给出远处目标坐标）
- loot:    在当前建筑搜刮物资
- rest:    原地休息恢复体力
- idle:    按兵不动，继续观察
- attack_nearest: 主动攻击最近的僵尸（仅在数量少且状态好时）
"""


# ---------------------------------------------------------------------------
# Agent 记忆与反思
# ---------------------------------------------------------------------------

class AgentMemory:
    """记忆系统：限制最大轮数，自动截断超长上下文，定期触发深度反思。"""

    def __init__(self, cfg: dict):
        self.max_rounds = cfg["max_memory_rounds"]
        self.max_context_chars = cfg["max_context_chars"]
        self.reflect_every = cfg["reflect_every_n_rounds"]
        self.rounds: deque = deque(maxlen=self.max_rounds)  # 每轮: {state, action, result}
        self.long_term: list = []                            # memory_note 沉淀的长期记忆
        self.round_count = 0                                 # 累计决策轮数（用于反思节奏）

    def add_round(self, state: dict, action: dict) -> None:
        self.rounds.append({"state": state, "action": action, "result": state.get("last_action_result", "unknown")})
        self.round_count += 1
        note = action.get("memory_note", "")
        if note and note not in self.long_term:
            self.long_term.append(note)

    def need_deep_reflection(self) -> bool:
        """每 reflect_every 轮触发一次深度反思指令。"""
        return self.round_count > 0 and self.round_count % self.reflect_every == 0

    def build_messages(self, state: dict) -> list:
        """组装发给 DeepSeek 的 messages：系统提示 + 历史窗口 + 当前状态。"""
        history_text = json.dumps(list(self.rounds), ensure_ascii=False, indent=1)
        # 超长截断：只保留结尾部分（最近的记忆最重要），防止 token 爆炸
        if len(history_text) > self.max_context_chars:
            history_text = "……（早期记忆已截断）……\n" + history_text[-self.max_context_chars:]

        user_parts = [
            "【当前游戏状态】",
            json.dumps(state, ensure_ascii=False, indent=1),
            "\n【近期历史（动作+结果+反思）】",
            history_text if self.rounds else "（暂无历史，这是第一轮决策）",
            "\n【长期记忆】",
            json.dumps(self.long_term, ensure_ascii=False) if self.long_term else "（暂无）",
        ]
        if self.need_deep_reflection():
            user_parts.append(
                "\n【深度反思指令】本轮请额外认真反思：回顾长期目标的完成进度，"
                "评估当前策略是否有效，并在 reflection 字段中给出策略调整建议。"
            )
        user_parts.append("\n请输出决策 JSON：")

        return [
            {"role": "system", "content": SYSTEM_PROMPT},
            {"role": "user", "content": "\n".join(user_parts)},
        ]


MEMORY = AgentMemory(CONFIG)


# ---------------------------------------------------------------------------
# DeepSeek API 调用（SSE 流式 + 超时保护）
# ---------------------------------------------------------------------------

def call_deepseek(messages: list) -> dict | None:
    """调用 DeepSeek Chat Completions（流式 SSE），返回解析后的决策 dict。

    任何异常（网络、超时、JSON 解析失败）都返回 None —— 调用方据此保留旧动作文件，
    Lua 侧继续执行旧策略，角色不卡死。
    """
    body = {
        "model": MODEL,
        "messages": messages,
        "stream": True,                                  # SSE 流式返回
        "response_format": {"type": "json_object"},      # 强制合法 JSON
        "temperature": 0.7,
    }
    timeout = (5, CONFIG["api_timeout_sec"])             # (连接超时, 读取超时)

    try:
        with requests.post(
            f"{BASE_URL}/chat/completions",
            headers={
                "Authorization": f"Bearer {API_KEY}",
                "Content-Type": "application/json",
            },
            json=body,
            stream=True,
            timeout=timeout,
        ) as resp:
            resp.raise_for_status()
            # 手工解析 SSE：逐行读取 data: {...} 块，累加 delta.content
            content_parts = []
            for raw_line in resp.iter_lines(decode_unicode=True):
                if not raw_line:                          # SSE 心跳空行
                    continue
                line = raw_line.strip()
                if not line.startswith("data:"):
                    continue
                payload = line[len("data:"):].strip()
                if payload == "[DONE]":                   # 流结束标记
                    break
                try:
                    chunk = json.loads(payload)
                    delta = chunk["choices"][0].get("delta", {})
                    piece = delta.get("content")
                    if piece:
                        content_parts.append(piece)
                except (json.JSONDecodeError, KeyError, IndexError):
                    continue                              # 跳过畸形块，不中断整体
    except requests.exceptions.Timeout:
        log.error("DeepSeek API 请求超时（%ss），沿用上一次策略。", CONFIG["api_timeout_sec"])
        return None
    except requests.exceptions.RequestException as e:
        log.error("DeepSeek API 请求失败: %s，沿用上一次策略。", e)
        return None

    full_text = "".join(content_parts).strip()
    if not full_text:
        log.error("DeepSeek 返回内容为空，沿用上一次策略。")
        return None

    try:
        return json.loads(full_text)
    except json.JSONDecodeError:
        log.error("DeepSeek 返回内容不是合法 JSON，沿用上一次策略。原始内容: %s", full_text[:200])
        return None


# ---------------------------------------------------------------------------
# 文件 IPC：读取游戏状态 / 写入动作决策
# ---------------------------------------------------------------------------

def read_state() -> dict | None:
    """读取 Lua 写入的状态文件。文件不存在或内容不完整时返回 None。"""
    try:
        if not STATE_FILE.exists():
            return None
        text = STATE_FILE.read_text(encoding="utf-8").strip()
        if not text:                                      # Lua 可能正在写入
            return None
        return json.loads(text)
    except (json.JSONDecodeError, OSError):
        return None


def write_action(decision: dict) -> None:
    """把 LLM 决策写入动作文件，同时附带阈值参数供 Lua 侧实时调参。"""
    payload = {
        "decision": decision,
        "updated_at": time.time(),
        # 阈值随动作文件一起下发，Lua 每次读取都能拿到最新值（方便 AI 自动调参）
        "thresholds": {
            "zombie_danger_distance": CONFIG["zombie_danger_distance"],
            "zombie_melee_distance": CONFIG["zombie_melee_distance"],
            "emergency_flee_distance": CONFIG["emergency_flee_distance"],
        },
    }
    tmp = ACTION_FILE.with_suffix(".tmp")
    tmp.write_text(json.dumps(payload, ensure_ascii=False), encoding="utf-8")
    tmp.replace(ACTION_FILE)                              # 原子替换，避免 Lua 读到半截文件


# ---------------------------------------------------------------------------
# 后台决策主循环
# ---------------------------------------------------------------------------

def decision_loop() -> None:
    """轮询状态文件 -> 限频调用 LLM -> 写动作文件。异常永不让线程退出。"""
    log.info("决策循环已启动 | IPC 目录: %s | LLM 间隔: %ss", IPC_DIR, CONFIG["api_interval_sec"])
    last_call = 0.0

    while True:
        try:
            time.sleep(CONFIG["state_poll_interval_sec"])

            state = read_state()
            if state is None:
                continue                                  # 游戏未启动或模组未写入状态
            if state.get("emergency"):
                continue                                  # 紧急状态由 Lua 本地全权处理，不打扰 LLM

            # 限频：距离上次调用不足 api_interval_sec 就跳过，防止 token 爆炸
            now = time.time()
            if now - last_call < CONFIG["api_interval_sec"]:
                continue
            last_call = now

            messages = MEMORY.build_messages(state)
            decision = call_deepseek(messages)
            if decision is None:
                continue                                  # 失败不改写动作文件，沿用旧策略

            MEMORY.add_round(state, decision)
            write_action(decision)
            log.info("第 %d 轮决策: %s", MEMORY.round_count, decision.get("immediate_action", {}))

        except Exception:
            log.exception("决策循环发生未预期异常，继续运行。")


# ---------------------------------------------------------------------------
# FastAPI 应用
# ---------------------------------------------------------------------------

app = FastAPI(title="PZ DeepSeek Bridge", version="0.1.0")


@app.on_event("startup")
def _startup() -> None:
    t = threading.Thread(target=decision_loop, daemon=True)
    t.start()


@app.get("/health")
def health() -> dict:
    """健康检查：确认服务存活与 IPC 状态文件是否就位。"""
    return {
        "status": "ok",
        "ipc_dir": str(IPC_DIR),
        "state_file_exists": STATE_FILE.exists(),
        "action_file_exists": ACTION_FILE.exists(),
        "memory_rounds": MEMORY.round_count,
    }


@app.get("/memory")
def memory() -> dict:
    """查看当前记忆与反思历史，便于调试。"""
    return {
        "round_count": MEMORY.round_count,
        "rounds": list(MEMORY.rounds),
        "long_term": MEMORY.long_term,
    }


class TestState(BaseModel):
    """/strategy/test 的入参：任意游戏状态 JSON，无需启动游戏即可测试完整 LLM 流程。"""
    state: dict


@app.post("/strategy/test")
def strategy_test(body: TestState) -> dict:
    """用给定状态走一遍完整决策流程（构建提示词 -> 调用 LLM -> 写入记忆）。

    返回 LLM 原始决策；API 失败时返回 {"decision": null}，用于验证降级行为。
    """
    messages = MEMORY.build_messages(body.state)
    decision = call_deepseek(messages)
    if decision is not None:
        MEMORY.add_round(body.state, decision)
        write_action(decision)
    return {"decision": decision, "memory_rounds": MEMORY.round_count}
