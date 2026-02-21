import asyncio
import json
import time
from dataclasses import dataclass, field
from typing import Dict, Any, List

CONTROL_PORT = 9001
PHYSICS_PORT = 9002
RENDER_PORT  = 9003
HOST = "0.0.0.0"

TICK_HZ = 30.0
DT = 1.0 / TICK_HZ
MAX_ASTEROIDS = 20

# -------- NDJSON helpers --------
async def read_msg(reader: asyncio.StreamReader) -> Dict[str, Any]:
    line = await reader.readline()
    if not line:
        raise ConnectionError("Disconnected")
    return json.loads(line.decode("utf-8"))

async def send_msg(writer: asyncio.StreamWriter, msg: Dict[str, Any]) -> None:
    writer.write((json.dumps(msg) + "\n").encode("utf-8"))
    await writer.drain()

# -------- Game state --------
@dataclass
class Obj:
    id: int
    type: str  # "player" or "asteroid"
    pos: List[float]
    vel: List[float]
    size: float = 1.0

@dataclass
class GameState:
    tick: int = 0
    objects: Dict[int, Obj] = field(default_factory=dict)
    control_lr: int = 0  # -1/0/1
    control_ud: int = 0  # -1/0/1

    def snapshot(self) -> Dict[str, Any]:
        return {
            "tick": self.tick,
            "dt": DT,
            "objects": [
                {"id": o.id, "type": o.type, "pos": o.pos, "vel": o.vel, "size": o.size}
                for o in self.objects.values()
            ],
            "controls": {"lr": self.control_lr, "ud": self.control_ud},
        }

def init_game() -> GameState:
    gs = GameState()
    gs.objects[0] = Obj(0, "player", [0.0, 0.0, 0.0], [0.0, 0.0, 0.0], size=1.0)
    for i in range(1, MAX_ASTEROIDS + 1):
        x = 8.0 + 0.6 * i
        y = (-5.0 + (i % 10)) * 0.6
        vx = -0.12 - 0.01 * (i % 5)
        vy = 0.02 * ((i % 3) - 1)
        gs.objects[i] = Obj(i, "asteroid", [x, y, 0.0], [vx, vy, 0.0], size=0.6 + 0.05 * (i % 6))
    return gs

# -------- Connections --------
control_queue: asyncio.Queue = asyncio.Queue()
physics_conn: Dict[str, Any] = {"writer": None}
render_conn: Dict[str, Any]  = {"writer": None}
physics_result_queue: asyncio.Queue = asyncio.Queue()

# -------- CONTROL stream (both PYNQs connect) --------
async def control_handler(reader: asyncio.StreamReader, writer: asyncio.StreamWriter):
    peer = writer.get_extra_info("peername")
    try:
        hello = await read_msg(reader)
        if hello.get("type") != "hello":
            await send_msg(writer, {"type": "error", "error": "expected hello"})
            return

        role = hello.get("role")
        if role not in ("control_ud", "control_lr"):
            await send_msg(writer, {"type": "error", "error": f"bad role {role}"})
            return

        await send_msg(writer, {"type": "hello_ack", "role": role})
        print(f"[CONTROL] + {role} from {peer}")

        while True:
            msg = await read_msg(reader)
            if msg.get("type") == "control":
                await control_queue.put(msg)
    except Exception as e:
        print(f"[CONTROL] - {peer} ({e})")
    finally:
        try:
            writer.close()
            await writer.wait_closed()
        except Exception:
            pass

# -------- PHYSICS stream (only UD PYNQ connects) --------
async def physics_handler(reader: asyncio.StreamReader, writer: asyncio.StreamWriter):
    peer = writer.get_extra_info("peername")
    try:
        hello = await read_msg(reader)
        if hello.get("type") != "hello" or hello.get("role") != "physics":
            await send_msg(writer, {"type": "error", "error": "expected hello role=physics"})
            return
        physics_conn["writer"] = writer
        await send_msg(writer, {"type": "hello_ack", "role": "physics"})
        print(f"[PHYS] + physics node from {peer}")

        while True:
            msg = await read_msg(reader)
            if msg.get("type") == "physics_result":
                await physics_result_queue.put(msg)
    except Exception as e:
        print(f"[PHYS] - {peer} ({e})")
    finally:
        if physics_conn.get("writer") is writer:
            physics_conn["writer"] = None
        try:
            writer.close()
            await writer.wait_closed()
        except Exception:
            pass

# -------- RENDER stream (only LR PYNQ connects) --------
async def render_handler(reader: asyncio.StreamReader, writer: asyncio.StreamWriter):
    peer = writer.get_extra_info("peername")
    try:
        hello = await read_msg(reader)
        if hello.get("type") != "hello" or hello.get("role") != "render":
            await send_msg(writer, {"type": "error", "error": "expected hello role=render"})
            return
        render_conn["writer"] = writer
        await send_msg(writer, {"type": "hello_ack", "role": "render"})
        print(f"[RENDER] + render node from {peer}")

        while True:
            # render node doesn't need to send anything, but keep socket alive
            _ = await read_msg(reader)
    except Exception as e:
        print(f"[RENDER] - {peer} ({e})")
    finally:
        if render_conn.get("writer") is writer:
            render_conn["writer"] = None
        try:
            writer.close()
            await writer.wait_closed()
        except Exception:
            pass

# -------- Tick loop --------
async def game_loop():
    gs = init_game()
    last_physics_tick_applied = -1

    while True:
        t0 = time.perf_counter()

        # Drain controls (latest values)
        while not control_queue.empty():
            msg = await control_queue.get()
            axis = msg.get("axis")  # "ud" or "lr"
            try:
                val = int(msg.get("value", 0))
            except Exception:
                val = 0
            val = max(-1, min(1, val))
            if axis == "lr":
                gs.control_lr = val
            elif axis == "ud":
                gs.control_ud = val

        # Apply controls to player velocity intent
        player = gs.objects[0]
        speed = 4.0  # units/sec (physics integrates with dt)
        player.vel[0] = speed * gs.control_lr
        player.vel[1] = speed * gs.control_ud

        # Send snapshot to physics node (authoritative tick)
        snap = gs.snapshot()
        pw = physics_conn.get("writer")
        if pw is not None:
            try:
                await send_msg(pw, {"type": "physics", **snap})
            except Exception:
                physics_conn["writer"] = None

        # Apply newest physics result
        while not physics_result_queue.empty():
            res = await physics_result_queue.get()
            rtick = int(res.get("tick", -1))
            if rtick > last_physics_tick_applied and "objects" in res:
                new_objs: Dict[int, Obj] = {}
                for o in res["objects"]:
                    new_objs[int(o["id"])] = Obj(
                        id=int(o["id"]),
                        type=o["type"],
                        pos=list(o["pos"]),
                        vel=list(o["vel"]),
                        size=float(o.get("size", 1.0)),
                    )
                gs.objects = new_objs
                last_physics_tick_applied = rtick

        # Send snapshot to render node
        rw = render_conn.get("writer")
        if rw is not None:
            try:
                await send_msg(rw, {"type": "render", **gs.snapshot()})
            except Exception:
                render_conn["writer"] = None

        gs.tick += 1

        # Maintain 30 Hz
        elapsed = time.perf_counter() - t0
        if elapsed < DT:
            await asyncio.sleep(DT - elapsed)

async def main():
    s1 = await asyncio.start_server(control_handler, HOST, CONTROL_PORT)
    s2 = await asyncio.start_server(physics_handler, HOST, PHYSICS_PORT)
    s3 = await asyncio.start_server(render_handler, HOST, RENDER_PORT)

    print(f"CONTROL listening on {HOST}:{CONTROL_PORT}")
    print(f"PHYSICS listening on {HOST}:{PHYSICS_PORT}")
    print(f"RENDER  listening on {HOST}:{RENDER_PORT}")

    async with s1, s2, s3:
        await asyncio.gather(
            s1.serve_forever(),
            s2.serve_forever(),
            s3.serve_forever(),
            game_loop(),
        )

if __name__ == "__main__":
    asyncio.run(main())