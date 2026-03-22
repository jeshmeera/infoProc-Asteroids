#!/usr/bin/env python3
import asyncio
import json
import math
import os
import random
import time
from dataclasses import dataclass, field, asdict
from decimal import Decimal
from typing import Any, Dict, List, Optional, Set

try:
    import boto3
except Exception:
    boto3 = None

# Network / ports
HOST = os.getenv("HOST", "0.0.0.0")
CONTROL_PORT = int(os.getenv("CONTROL_PORT", "9001"))
PHYSICS_PORT = int(os.getenv("PHYSICS_PORT", "9002"))
RENDER_CTRL_PORT = int(os.getenv("RENDER_CTRL_PORT", "9004"))

# Game tuning
TICK_HZ = float(os.getenv("TICK_HZ", "30.0"))
DT = 1.0 / TICK_HZ
MAX_ASTEROIDS = int(os.getenv("MAX_ASTEROIDS", "63"))
PHYSICS_TIMEOUT_S = float(os.getenv("PHYSICS_TIMEOUT_S", "2.0"))
CONTROL_KEEPALIVE_HZ = float(os.getenv("CONTROL_KEEPALIVE_HZ", "30.0"))
AUTOSAVE_EVERY_TICKS = int(os.getenv("AUTOSAVE_EVERY_TICKS", "1"))

X_SPAWN_RANGE = 1.0
Y_SPAWN_RANGE = 1.0
Z_NEAR_SPAWN = 12.0
Z_FAR_SPAWN = 25.0
VX_RANGE = 1.5
VY_RANGE = 1.2
VZ_MIN = 4.0
VZ_MAX = 9.0
SIZE_MIN = 0.05
SIZE_MAX = 0.4
PLAYER_SPEED = 8.0
PLAYER_LR_SPEED = 9
PLAYER_SIZE = 0.2
PLAYER_X_MIN = -1.5
PLAYER_X_MAX = 1.5
PLAYER_Y_MIN = -0.6
PLAYER_Y_MAX = Y_SPAWN_RANGE

# Database configuration
REGION = os.getenv("AWS_REGION", "eu-north-1")
TABLE_SESSIONS = os.getenv("TABLE_SESSIONS", "GameSessions")
TABLE_GAMESTATE = os.getenv("TABLE_GAMESTATE", "GameState")
DEFAULT_USER_ID = os.getenv("GAME_USER_ID", "user123")
SESSION_ID = os.getenv("GAME_SESSION_ID", f"session-{int(time.time())}")
USER_ID = DEFAULT_USER_ID
DB_ENABLED = os.getenv("DB_ENABLED", "1") == "1"


def log(msg: str) -> None:
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)


# DB helpers
def to_dynamo(value: Any) -> Any:
    if isinstance(value, float):
        return Decimal(str(value))
    if isinstance(value, dict):
        return {k: to_dynamo(v) for k, v in value.items()}
    if isinstance(value, list):
        return [to_dynamo(v) for v in value]
    return value


class DB:
    def __init__(self):
        self.enabled = False
        self.sessions = None
        self.gamestate = None
        if DB_ENABLED and boto3 is not None:
            try:
                ddb = boto3.resource("dynamodb", region_name=REGION)
                self.sessions = ddb.Table(TABLE_SESSIONS)
                self.gamestate = ddb.Table(TABLE_GAMESTATE)
                self.enabled = True
            except Exception as e:
                log(f"DB init failed, continuing without DB: {e}")
        else:
            log("DB disabled or boto3 unavailable; continuing without DB")

    def create_session(self, user_id: str, session_id: str, high_score: int = 0):
        if not self.enabled:
            return
        self.sessions.put_item(Item={
            "user_id": user_id,
            "session_id": session_id,
            "status": "RUNNING",
            "current_tick": 0,
            "score": 0,
            "high_score": int(high_score),
            "latest_save_ts": -1,
            "latest_save_tick": -1,
            "created_at": int(time.time()),
        })

    def autosave(self, user_id: str, session_id: str, gs: "GameState"):
        if not self.enabled:
            return
        save_ts = int(time.time() * 1000)
        state = gs.snapshot()
        self.gamestate.put_item(Item=to_dynamo({
            "session_id": session_id,
            "save_ts": save_ts,
            "tick": int(gs.tick),
            "state": state,
        }))
        self.sessions.update_item(
            Key={"user_id": user_id, "session_id": session_id},
            UpdateExpression=(
                "SET latest_save_ts=:ts, latest_save_tick=:t, current_tick=:t, "
                "score=:s, high_score=:h, #status=:st"
            ),
            ExpressionAttributeNames={"#status": "status"},
            ExpressionAttributeValues={
                ":ts": save_ts,
                ":t": int(gs.tick),
                ":s": int(gs.score),
                ":h": int(gs.high_score),
                ":st": "GAME_OVER" if gs.game_over else "RUNNING",
            },
        )

    def mark_complete(self, user_id: str, session_id: str, gs: "GameState"):
        if not self.enabled:
            return
        self.sessions.update_item(
            Key={"user_id": user_id, "session_id": session_id},
            UpdateExpression="SET #status=:st, current_tick=:t, score=:s, high_score=:h",
            ExpressionAttributeNames={"#status": "status"},
            ExpressionAttributeValues={
                ":st": "GAME_OVER",
                ":t": int(gs.tick),
                ":s": int(gs.score),
                ":h": int(gs.high_score),
            },
        )


db = DB()


# NDJSON helpers
async def read_msg(reader: asyncio.StreamReader) -> Dict[str, Any]:
    line = await reader.readline()
    if not line:
        raise ConnectionError("Disconnected")
    return json.loads(line.decode("utf-8"))


async def send_msg(writer: asyncio.StreamWriter, msg: Dict[str, Any]) -> None:
    writer.write((json.dumps(msg) + "\n").encode("utf-8"))
    await writer.drain()


# Game data model
@dataclass
class Obj:
    id: int
    type: str
    pos: List[float]
    vel: List[float]
    size: float = 1.0
    angle: float = 0.0
    rot_speed: float = 0.0


@dataclass
class GameState:
    tick: int = 0
    objects: Dict[int, Obj] = field(default_factory=dict)
    control_lr: int = 0
    control_ud: int = 0
    score: int = 0
    high_score: int = 0
    user_id: str = USER_ID
    session_id: str = SESSION_ID
    game_over: bool = False
    last_collision: Optional[Dict[str, Any]] = None
    last_score_delta: int = 0
    physics_node_id: Optional[str] = None

    def snapshot(self) -> Dict[str, Any]:
        return {
            "tick": self.tick,
            "dt": DT,
            "objects": [asdict(o) for o in self.objects.values()],
            "controls": {"lr": self.control_lr, "ud": self.control_ud},
            "score": self.score,
            "high_score": self.high_score,
            "game_over": self.game_over,
            "session_id": self.session_id,
            "user_id": self.user_id,
            "last_collision": self.last_collision,
            "last_score_delta": self.last_score_delta,
            "physics_node_id": self.physics_node_id,
        }


HIGH_SCORE_FILE = "global_high_score.txt"


def load_global_high_score() -> int:
    try:
        with open(HIGH_SCORE_FILE, "r", encoding="utf-8") as f:
            return max(0, int(f.read().strip() or "0"))
    except (FileNotFoundError, ValueError, OSError):
        return 0


def save_score(user_id: str, score: int) -> None:
    prev = load_global_high_score()
    best = max(prev, int(score))
    try:
        with open(HIGH_SCORE_FILE, "w", encoding="utf-8") as f:
            f.write(str(best))
    except OSError as e:
        log(f"save_score failed user_id={user_id} score={score} error={e}")
        return
    log(f"save_score user_id={user_id} score={score} global_high_score={best}")


def spawn_asteroid(obj_id: int, player_z: float = 0.0) -> Obj:
    return Obj(
        id=obj_id,
        type="asteroid",
        pos=[
            random.uniform(-X_SPAWN_RANGE, X_SPAWN_RANGE),
            random.uniform(-Y_SPAWN_RANGE, Y_SPAWN_RANGE),
            player_z - random.uniform(Z_NEAR_SPAWN, Z_FAR_SPAWN),
        ],
        vel=[
            random.uniform(-VX_RANGE, VX_RANGE),
            random.uniform(-VY_RANGE, VY_RANGE),
            random.uniform(VZ_MIN, VZ_MAX),
        ],
        size=random.uniform(SIZE_MIN, SIZE_MAX),
        rot_speed=random.uniform(-6.0, 6.0),
    )


def init_game() -> GameState:
    gs = GameState(high_score=load_global_high_score(), user_id=USER_ID, session_id=SESSION_ID)
    gs.objects[0] = Obj(0, "player", [0.0, 0.0, 0.0], [0.0, 0.0, 0.0], PLAYER_SIZE)
    for i in range(1, MAX_ASTEROIDS + 1):
        gs.objects[i] = spawn_asteroid(i, player_z=0.0)
    return gs


# Shared server state
physics_conn: Dict[str, Optional[asyncio.StreamWriter]] = {"writer": None}
control_sinks: Set[asyncio.StreamWriter] = set()

latest_controls: Dict[str, Any] = {"lr": 0, "ud": 0, "seq": 0, "ud_seq": 0, "t": 0.0}
latest_physics_result: Optional[Dict[str, Any]] = None
control_lock = asyncio.Lock()


async def safe_broadcast(sinks: Set[asyncio.StreamWriter], msg: Dict[str, Any], tag: str) -> None:
    dead: List[asyncio.StreamWriter] = []
    for writer in list(sinks):
        try:
            await send_msg(writer, msg)
        except Exception as e:
            peer = writer.get_extra_info("peername")
            log(f"{tag} drop {peer}: {e}")
            dead.append(writer)
    for writer in dead:
        sinks.discard(writer)
        try:
            writer.close()
            await writer.wait_closed()
        except Exception:
            pass


async def broadcast_controls() -> None:
    async with control_lock:
        msg = {
            "type": "controls",
            "lr": int(latest_controls["lr"]),
            "ud": int(latest_controls["ud"]),
            "seq": int(latest_controls["seq"]),
            "t": float(latest_controls["t"]),
        }
    await safe_broadcast(control_sinks, msg, "RCTRL")


# Handlers
async def control_handler(reader: asyncio.StreamReader, writer: asyncio.StreamWriter):
    peer = writer.get_extra_info("peername")
    try:
        hello = await read_msg(reader)
        if hello.get("type") != "hello":
            await send_msg(writer, {"type": "error", "error": "expected hello"})
            return

        role = hello.get("role", "control")
        if role not in {"control", "control_lr", "control_ud", "gesture", "input"}:
            await send_msg(writer, {"type": "error", "error": f"unexpected control role={role}"})
            return

        await send_msg(writer, {"type": "hello_ack", "role": role})
        log(f"CTRL + {role} from {peer}")

        while True:
            msg = await read_msg(reader)
            if msg.get("type") != "control":
                continue

            axis = str(msg.get("axis", "lr"))
            value = max(-1, min(1, int(msg.get("value", 0))))
            if axis not in {"lr", "ud"}:
                continue

            async with control_lock:
                latest_controls[axis] = value
                latest_controls["seq"] = int(latest_controls["seq"]) + 1
                if axis == "ud":
                    latest_controls["ud_seq"] = int(latest_controls["ud_seq"]) + 1
                latest_controls["t"] = float(msg.get("t", time.time()))

            await broadcast_controls()
    except Exception as e:
        log(f"CTRL - {peer} ({e})")
    finally:
        try:
            writer.close()
            await writer.wait_closed()
        except Exception:
            pass


async def physics_handler(reader: asyncio.StreamReader, writer: asyncio.StreamWriter):
    peer = writer.get_extra_info("peername")
    try:
        hello = await read_msg(reader)
        if hello.get("type") != "hello" or hello.get("role") != "physics":
            await send_msg(writer, {"type": "error", "error": "expected hello role=physics"})
            return

        physics_conn["writer"] = writer
        await send_msg(writer, {"type": "hello_ack", "role": "physics"})
        log(f"PHYS + physics node from {peer}")

        while True:
            msg = await read_msg(reader)
            if msg.get("type") != "physics_result":
                continue
            global latest_physics_result
            latest_physics_result = msg
    except Exception as e:
        log(f"PHYS - {peer} ({e})")
    finally:
        if physics_conn.get("writer") is writer:
            physics_conn["writer"] = None
        try:
            writer.close()
            await writer.wait_closed()
        except Exception:
            pass


async def renderer_control_handler(reader: asyncio.StreamReader, writer: asyncio.StreamWriter):
    peer = writer.get_extra_info("peername")
    try:
        hello = await read_msg(reader)
        if hello.get("type") != "hello" or hello.get("role") != "render_control":
            await send_msg(writer, {"type": "error", "error": "expected hello role=render_control"})
            return

        control_sinks.add(writer)
        await send_msg(writer, {"type": "hello_ack", "role": "render_control"})
        log(f"RCTRL + sink from {peer}")
        await broadcast_controls()

        while True:
            _ = await read_msg(reader)
    except Exception as e:
        log(f"RCTRL - {peer} ({e})")
    finally:
        control_sinks.discard(writer)
        try:
            writer.close()
            await writer.wait_closed()
        except Exception:
            pass


# Game helpers
def maybe_respawn_asteroids(gs: GameState) -> int:
    player = gs.objects.get(0)
    if player is None:
        return 0

    player_z = player.pos[2]
    respawned = 0
    for obj_id, obj in list(gs.objects.items()):
        if obj.type != "asteroid":
            continue
        if obj.pos[2] > player_z + SIZE_MAX:
            gs.objects[obj_id] = spawn_asteroid(obj_id, player_z=player_z)
            gs.score += 10
            respawned += 1

    return respawned


def apply_controls(gs: GameState) -> None:
    p = gs.objects.get(0)
    if p is None:
        return
    p.vel[0] = PLAYER_LR_SPEED * gs.control_lr
    p.vel[1] = PLAYER_SPEED * gs.control_ud
    p.vel[2] = 0.0


def detect_collision(gs: GameState) -> Optional[Dict[str, Any]]:
    player = gs.objects.get(0)
    if player is None:
        return None

    for obj in gs.objects.values():
        if obj.type != "asteroid":
            continue
        dx = obj.pos[0] - player.pos[0]
        dy = obj.pos[1] - player.pos[1]
        dz = obj.pos[2] - player.pos[2]
        dist = math.sqrt(dx * dx + dy * dy + dz * dz)
        if dist < player.size + obj.size:
            return {
                "player_id": player.id,
                "other_id": obj.id,
                "other_type": obj.type,
                "distance": dist,
                "t": time.time(),
            }

    return None


def parse_objects(objects: List[Dict[str, Any]]) -> Dict[int, Obj]:
    out: Dict[int, Obj] = {}
    for o in objects:
        out[int(o["id"])] = Obj(
            id=int(o["id"]),
            type=str(o["type"]),
            pos=list(o["pos"]),
            vel=list(o["vel"]),
            size=float(o.get("size", 1.0)),
            angle=float(o.get("angle", 0.0)),
            rot_speed=float(o.get("rot_speed", 0.0)),
        )
    return out


# Loops
async def keepalive_loop() -> None:
    while True:
        await asyncio.sleep(1.0 / CONTROL_KEEPALIVE_HZ)
        await broadcast_controls()


async def game_loop() -> None:
    gs = init_game()
    db.create_session(gs.user_id, gs.session_id, gs.high_score)
    log(f"GAME session created user_id={gs.user_id} session_id={gs.session_id}")

    waiting_for_physics = False
    pending_tick: Optional[int] = None
    game_over_saved = False
    last_saved_tick = -1
    restart_requested = False
    last_seen_ud_seq = 0

    while True:
        t0 = time.perf_counter()
        gs.last_collision = None
        gs.last_score_delta = 0

        async with control_lock:
            gs.control_lr = int(latest_controls["lr"])
            gs.control_ud = int(latest_controls["ud"])
            current_ud_seq = int(latest_controls["ud_seq"])

        if gs.game_over and current_ud_seq != last_seen_ud_seq:
            log("GAME RESTART received")
            restart_requested = True
        last_seen_ud_seq = current_ud_seq

        apply_controls(gs)

        if not waiting_for_physics:
            pw = physics_conn.get("writer")
            if pw is not None:
                await send_msg(pw, {"type": "physics", **gs.snapshot()})
                pending_tick = gs.tick
                waiting_for_physics = True

        if waiting_for_physics:
            global latest_physics_result
            try:
                res = latest_physics_result
                if res is not None:
                    rtick = int(res.get("tick", -1))
                    if rtick == pending_tick:
                        gs.objects = parse_objects(list(res.get("objects", [])))
                        player = gs.objects.get(0)
                        if player is not None:
                            player.pos[0] = max(
                                PLAYER_X_MIN + player.size,
                                min(PLAYER_X_MAX - player.size, player.pos[0]),
                            )
                            player.pos[1] = max(
                                PLAYER_Y_MIN + player.size,
                                min(PLAYER_Y_MAX - player.size, player.pos[1]),
                            )
                        gs.physics_node_id = res.get("node_id")
                        gs.tick += 1
                        if not gs.game_over:
                            gs.score += 1
                            gs.last_score_delta += 1
                        waiting_for_physics = False
                        latest_physics_result = None
                    else:
                        log(f"GAME ignoring stale physics_result tick={rtick} expected={pending_tick}")
                        latest_physics_result = None
                else:
                    await asyncio.sleep(min(DT, PHYSICS_TIMEOUT_S))
            except Exception as e:
                log(f"GAME physics wait failed: {e}")
                waiting_for_physics = False

        respawned = maybe_respawn_asteroids(gs)
        if respawned:
            gs.last_score_delta += respawned * 10

        collision = detect_collision(gs)
        if collision is not None:
            gs.game_over = True
            gs.last_collision = collision

        if gs.game_over and not game_over_saved:
            save_score(gs.user_id, gs.score)
            gs.high_score = max(gs.high_score, gs.score)
            try:
                db.mark_complete(gs.user_id, gs.session_id, gs)
            except Exception as e:
                log(f"DB mark_complete failed: {e}")
            game_over_saved = True
        elif not gs.game_over:
            game_over_saved = False

        if gs.tick >= 0 and gs.tick != last_saved_tick and (gs.tick % max(1, AUTOSAVE_EVERY_TICKS) == 0):
            try:
                db.autosave(gs.user_id, gs.session_id, gs)
                last_saved_tick = gs.tick
            except Exception as e:
                log(f"DB autosave failed tick={gs.tick}: {e}")

        if gs.game_over and restart_requested:
            prev_high_score = gs.high_score
            gs = init_game()
            gs.high_score = max(gs.high_score, prev_high_score)
            waiting_for_physics = False
            pending_tick = None
            game_over_saved = False
            last_saved_tick = -1
            restart_requested = False
            latest_physics_result = None

        elapsed = time.perf_counter() - t0
        if elapsed < DT:
            await asyncio.sleep(DT - elapsed)


# Main
async def main() -> None:
    s1 = await asyncio.start_server(control_handler, HOST, CONTROL_PORT)
    s2 = await asyncio.start_server(physics_handler, HOST, PHYSICS_PORT)
    s3 = await asyncio.start_server(renderer_control_handler, HOST, RENDER_CTRL_PORT)

    log(f"CONTROL         listening on {HOST}:{CONTROL_PORT}")
    log(f"PHYSICS         listening on {HOST}:{PHYSICS_PORT}")
    log(f"RENDER CONTROL  listening on {HOST}:{RENDER_CTRL_PORT}")

    async with s1, s2, s3:
        await asyncio.gather(
            s1.serve_forever(),
            s2.serve_forever(),
            s3.serve_forever(),
            keepalive_loop(),
            game_loop(),
        )


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass
