#the integrated collision and gesture code running on the pynq
#!/usr/bin/env python3
import json
import socket
import struct
import threading
import time
from collections import deque
from typing import Any, Dict, List, Optional

import cv2
import numpy as np
from pynq import Overlay, allocate, MMIO

SERVER_IP = "192.168.2.1"
CONTROL_PORT = 9001
PHYSICS_PORT = 9002

CONTROL_NODE_ID = "pynq-combined-control"
PHYSICS_NODE_ID = "pynq-combined-physics"
CONTROL_ROLE = "control_lr"
PHYSICS_ROLE = "physics"

BIT_PATH = "final.bit"
DMA0_NAME = "axi_dma_0"
DMA1_NAME = "axi_dma_1"
COL_IP_NAME = "col_0"
COL_CTRL_BASE = 0x40000000      # s_axi_control
COL_CTRL_RANGE = 0x10000

GESTURE_HOLD_S = 0.12
CAM_DEVICE = 0
CAP_W, CAP_H = 320, 240
CAP_FPS = 30
PROC_W = 320
PROC_H = 240
FRAME_PIXELS = PROC_W * PROC_H
HISTORY_LEN = 10
CONSIST_FRAC = 0.75
LOST_MAX = 6
COOLDOWN_S = 0.50
MIN_AREA = 800
MIN_COUNT = MIN_AREA
DX_MIN = 30
MAX_COV = 0.45
MAX_COUNT = int(MAX_COV * FRAME_PIXELS)
MIRROR = False
WARMUP_S = 1.0

MM2S_DMASR = 0x04
S2MM_DMASR = 0x34
IOC_IRQ = (1 << 12)
ERR_MASK = (1 << 4) | (1 << 5) | (1 << 6) | (1 << 14)

N_MAX = 256
RECORD_BYTES = 32
Q_SCALE = 65536
DEFAULT_RESTITUTION = 1.0
REC_STRUCT = struct.Struct("<8i")

CTRL_OFFSET = 0x00
N_OFFSET = 0x10
FRAME_DT_OFFSET = 0x18
RESTITUTION_OFFSET = 0x20

STATE_IN_LO = 0x10
STATE_IN_HI = 0x14
STATE_OUT_LO = 0x1C
STATE_OUT_HI = 0x20


def fmt_ts(ts: float) -> str:
    return f"{time.strftime('%Y-%m-%d %H:%M:%S', time.localtime(ts))}.{int((ts % 1) * 1000):03d}"


def read_json_line(fobj) -> Dict[str, Any]:
    line = fobj.readline()
    if not line:
        raise ConnectionError("Disconnected")
    return json.loads(line)


def send_json(sock: socket.socket, msg: Dict[str, Any], tag: str = "NODE") -> None:
    sock.sendall((json.dumps(msg) + "\n").encode("utf-8"))
    print(f"[{tag} SEND ] at={fmt_ts(time.time())} msg_type={msg.get('type')} tick={msg.get('tick')}", flush=True)


def connect_role(server_ip: str, port: int, role: str, node_id: str, tag: str) -> socket.socket:
    while True:
        try:
            s = socket.create_connection((server_ip, port), timeout=10)
            s.settimeout(None)
            f = s.makefile("r")
            send_json(s, {"type": "hello", "role": role, "node_id": node_id}, tag)
            ack = f.readline().strip()
            print(f"[{tag} ACK  ] at={fmt_ts(time.time())} ack={ack}", flush=True)
            return s
        except Exception as e:
            print(f"[{tag} CONN ] at={fmt_ts(time.time())} reconnecting... {e}", flush=True)
            time.sleep(1)


def decode_dmasr(sr: int) -> str:
    parts = ["HALTED" if (sr & 0x1) else "RUN", "IDLE" if (sr & 0x2) else "BUSY"]
    if sr & (1 << 4):
        parts.append("INT_ERR")
    if sr & (1 << 5):
        parts.append("SLV_ERR")
    if sr & (1 << 6):
        parts.append("DEC_ERR")
    if sr & (1 << 14):
        parts.append("ERR_IRQ")
    if sr & IOC_IRQ:
        parts.append("IOC")
    return "|".join(parts)


def clear_dma_irqs(mmio) -> None:
    mmio.write(MM2S_DMASR, 0xFFFFFFFF)
    mmio.write(S2MM_DMASR, 0xFFFFFFFF)


def wait_ioc(mmio, off: int, timeout_s: float = 0.8, label: str = "") -> int:
    t0 = time.time()
    while True:
        sr = mmio.read(off)
        if sr & ERR_MASK:
            raise RuntimeError(f"{label} error SR=0x{sr:08X} ({decode_dmasr(sr)})")
        if sr & IOC_IRQ:
            return sr
        if (time.time() - t0) > timeout_s:
            raise TimeoutError(f"{label} timeout SR=0x{sr:08X} ({decode_dmasr(sr)})")
        time.sleep(0.0005)


def start_channels(dma0, dma1) -> None:
    dma0.sendchannel.start()
    dma0.recvchannel.start()
    dma1.sendchannel.start()


def hw_centroid(dma0, dma1, prev_frame, cur_frame, centroid_out_u32x2, timeout_s: float = 0.8):
    prev_frame.flush()
    cur_frame.flush()
    centroid_out_u32x2.flush()

    mmio0 = dma0.mmio
    mmio1 = dma1.mmio
    clear_dma_irqs(mmio0)
    clear_dma_irqs(mmio1)

    dma0.recvchannel.transfer(centroid_out_u32x2)
    dma0.sendchannel.transfer(cur_frame)
    dma1.sendchannel.transfer(prev_frame)

    wait_ioc(mmio0, S2MM_DMASR, timeout_s=timeout_s, label="dma0 S2MM")
    wait_ioc(mmio0, MM2S_DMASR, timeout_s=timeout_s, label="dma0 MM2S")
    wait_ioc(mmio1, MM2S_DMASR, timeout_s=timeout_s, label="dma1 MM2S")

    centroid_out_u32x2.invalidate()
    return centroid_out_u32x2


def open_camera(dev: int = 0, w: int = 320, h: int = 240, fps: int = 30):
    cap = cv2.VideoCapture(dev, cv2.CAP_V4L2)
    if not cap.isOpened():
        raise RuntimeError(f"Could not open camera index {dev}.")
    cap.set(cv2.CAP_PROP_FOURCC, cv2.VideoWriter_fourcc(*"MJPG"))
    cap.set(cv2.CAP_PROP_FRAME_WIDTH, w)
    cap.set(cv2.CAP_PROP_FRAME_HEIGHT, h)
    cap.set(cv2.CAP_PROP_FPS, fps)
    cap.set(cv2.CAP_PROP_BUFFERSIZE, 1)
    return cap


def direction_from_history(cx_hist, consist_frac: float):
    if len(cx_hist) < 2:
        return None, 0.0, 0.0
    dx = float(cx_hist[-1] - cx_hist[0])
    steps = np.diff(np.array(cx_hist, dtype=np.float32))
    pos = int(np.sum(steps > 0))
    neg = int(np.sum(steps < 0))
    total = len(steps)
    if total == 0:
        return None, dx, 0.0
    frac = max(pos, neg) / float(total)
    direction = None
    if frac >= consist_frac:
        direction = "LEFT" if pos > neg else "RIGHT"
    return direction, dx, frac


def f2q(x: float) -> int:
    return int(round(float(x) * Q_SCALE))


def q2f(x: int) -> float:
    return float(x) / Q_SCALE


def pack_record(obj: Dict[str, Any]) -> bytes:
    x, y, z = [float(v) for v in obj["pos"]]
    vx, vy, vz = [float(v) for v in obj["vel"]]
    r = float(obj.get("size", 1.0))
    m = r * r * r
    return REC_STRUCT.pack(
        f2q(x), f2q(y), f2q(z),
        f2q(vx), f2q(vy), f2q(vz),
        f2q(r), f2q(m),
    )


def unpack_record(blob: bytes, oid: int, otype: str, size_hint: float) -> Dict[str, Any]:
    px, py, pz, vx, vy, vz, radius_q, _mass_q = REC_STRUCT.unpack(blob)
    return {
        "id": int(oid),
        "type": otype,
        "pos": [q2f(px), q2f(py), q2f(pz)],
        "vel": [q2f(vx), q2f(vy), q2f(vz)],
        "size": float(size_hint if size_hint is not None else q2f(radius_q)),
    }


def snapshot_to_payload(objects: List[Dict[str, Any]]) -> bytes:
    ordered = sorted(objects, key=lambda o: int(o["id"]))
    if len(ordered) > N_MAX:
        raise ValueError(f"Too many objects: {len(ordered)} > {N_MAX}")
    return b"".join(pack_record(o) for o in ordered)


def payload_to_objects(payload: bytes, original_objects: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
    ordered = sorted(original_objects, key=lambda o: int(o["id"]))
    out: List[Dict[str, Any]] = []
    for i, src in enumerate(ordered):
        off = i * RECORD_BYTES
        out.append(
            unpack_record(
                payload[off: off + RECORD_BYTES],
                oid=int(src["id"]),
                otype=str(src.get("type", "asteroid")),
                size_hint=float(src.get("size", 1.0)),
            )
        )
    return out


class CollisionEngine:
    def __init__(self, overlay: Overlay):
        self.addr_mmio = overlay.col_0.mmio            # s_axi_control_r @ 0x40010000
        self.ctrl_mmio = MMIO(COL_CTRL_BASE, COL_CTRL_RANGE)  # s_axi_control @ 0x40000000

        self.buf_in = allocate(shape=(N_MAX * RECORD_BYTES,), dtype=np.uint8)
        self.buf_out = allocate(shape=(N_MAX * RECORD_BYTES,), dtype=np.uint8)

        in_phys = int(self.buf_in.physical_address)
        out_phys = int(self.buf_out.physical_address)

        self.addr_mmio.write(STATE_IN_LO, in_phys & 0xFFFFFFFF)
        self.addr_mmio.write(STATE_IN_HI, (in_phys >> 32) & 0xFFFFFFFF)
        self.addr_mmio.write(STATE_OUT_LO, out_phys & 0xFFFFFFFF)
        self.addr_mmio.write(STATE_OUT_HI, (out_phys >> 32) & 0xFFFFFFFF)

        print(f"[PHYS INFO ] buf_in  phys=0x{in_phys:08x}", flush=True)
        print(f"[PHYS INFO ] buf_out phys=0x{out_phys:08x}", flush=True)

    def run_kernel(self, n: int, frame_dt_q: int, restitution_q: int, payload: bytes) -> bytes:
        n_bytes = n * RECORD_BYTES
        self.buf_in[:n_bytes] = np.frombuffer(payload, dtype=np.uint8)
        self.buf_in.flush()

        self.ctrl_mmio.write(N_OFFSET, int(n))
        self.ctrl_mmio.write(FRAME_DT_OFFSET, int(frame_dt_q))
        self.ctrl_mmio.write(RESTITUTION_OFFSET, int(restitution_q))
        self.ctrl_mmio.write(CTRL_OFFSET, 0x01)

        for _ in range(100000):
            status = self.ctrl_mmio.read(CTRL_OFFSET)
            if status & 0x02:
                break
            time.sleep(1e-6)
        else:
            print(f"[PHYS WARN ] {fmt_ts(time.time())} kernel timeout", flush=True)

        self.buf_out.invalidate()
        return bytes(self.buf_out[:n_bytes])


class IntegratedPynqNode:
    def __init__(self):
        print(f"[NODE INFO ] {fmt_ts(time.time())} loading overlay {BIT_PATH}", flush=True)
        self.ol = Overlay(BIT_PATH)
        print(f"[NODE INFO ] {fmt_ts(time.time())} overlay loaded", flush=True)

        self.dma0 = getattr(self.ol, DMA0_NAME)
        self.dma1 = getattr(self.ol, DMA1_NAME)
        start_channels(self.dma0, self.dma1)

        self.col = CollisionEngine(self.ol)
        self.stop_event = threading.Event()

    def gesture_loop(self):
        cap = open_camera(CAM_DEVICE, CAP_W, CAP_H, CAP_FPS)
        control_sock = connect_role(SERVER_IP, CONTROL_PORT, CONTROL_ROLE, CONTROL_NODE_ID, "CTRL")

        in_bufs = [
            allocate(shape=(PROC_H, PROC_W), dtype=np.uint8),
            allocate(shape=(PROC_H, PROC_W), dtype=np.uint8),
        ]
        centroid_out = allocate(shape=(2,), dtype=np.uint32)
        buf_idx = 0

        cx_hist = deque(maxlen=HISTORY_LEN)
        lost_count = 0
        last_trigger_t = 0.0
        warmup_end = time.time() + WARMUP_S

        gesture_lr = 0
        gesture_lr_until = 0.0
        last_sent_lr: Optional[int] = None
        last_detect_t: Optional[float] = None

        try:
            while not self.stop_event.is_set():
                ok, frame = cap.read()
                if not ok:
                    continue

                if MIRROR:
                    frame = cv2.flip(frame, 1)

                proc_frame = cv2.resize(frame, (PROC_W, PROC_H), interpolation=cv2.INTER_AREA)
                gray_full = cv2.cvtColor(proc_frame, cv2.COLOR_BGR2GRAY)

                cur = in_bufs[buf_idx]
                cur[:, :] = gray_full
                now = time.time()

                if now >= warmup_end:
                    prev = in_bufs[1 - buf_idx]
                    words = hw_centroid(self.dma0, self.dma1, prev, cur, centroid_out, timeout_s=0.8)

                    count = int(words[0])
                    sum_x = int(words[1])
                    cooldown = (now - last_trigger_t) < COOLDOWN_S
                    valid = (count >= MIN_COUNT) and (count <= MAX_COUNT)

                    if not valid:
                        lost_count += 1
                        if lost_count > LOST_MAX:
                            cx_hist.clear()
                    else:
                        lost_count = 0
                        cx = int((sum_x + (count // 2)) // count)
                        cx = max(0, min(PROC_W - 1, cx))

                        if not cooldown:
                            cx_hist.append(float(cx))
                            direction, dx, frac = direction_from_history(list(cx_hist), CONSIST_FRAC)

                            if len(cx_hist) == HISTORY_LEN and abs(dx) >= DX_MIN and direction is not None:
                                last_trigger_t = now
                                last_detect_t = now
                                cx_hist.clear()

                                if direction == "LEFT":
                                    gesture_lr = -1
                                elif direction == "RIGHT":
                                    gesture_lr = 1

                                gesture_lr_until = now + GESTURE_HOLD_S
                                print(
                                    f"[CTRL DETECT] detect_at={fmt_ts(now)} direction={direction} dx={dx:.1f} count={count} frac={frac:.2f} lr={gesture_lr}",
                                    flush=True,
                                )

                if now >= gesture_lr_until:
                    gesture_lr = 0

                if gesture_lr != last_sent_lr:
                    try:
                        send_json(
                            control_sock,
                            {
                                "type": "control",
                                "axis": "lr",
                                "value": int(gesture_lr),
                                "t": time.time(),
                                "detect_t": last_detect_t,
                            },
                            "CTRL",
                        )
                        last_sent_lr = gesture_lr
                    except Exception as e:
                        print(f"[CTRL ERROR] at={fmt_ts(time.time())} send failed: {e}", flush=True)
                        try:
                            control_sock.close()
                        except Exception:
                            pass
                        control_sock = connect_role(SERVER_IP, CONTROL_PORT, CONTROL_ROLE, CONTROL_NODE_ID, "CTRL")
                        last_sent_lr = None

                buf_idx = 1 - buf_idx

        except KeyboardInterrupt:
            pass
        finally:
            cap.release()
            try:
                control_sock.close()
            except Exception:
                pass

    def physics_loop(self):
        sock = connect_role(SERVER_IP, PHYSICS_PORT, PHYSICS_ROLE, PHYSICS_NODE_ID, "PHYS")
        fobj = sock.makefile("r")

        try:
            while not self.stop_event.is_set():
                try:
                    msg = read_json_line(fobj)
                except Exception as e:
                    print(f"[PHYS ERR  ] at={fmt_ts(time.time())} recv failed: {e}", flush=True)
                    try:
                        sock.close()
                    except Exception:
                        pass
                    sock = connect_role(SERVER_IP, PHYSICS_PORT, PHYSICS_ROLE, PHYSICS_NODE_ID, "PHYS")
                    fobj = sock.makefile("r")
                    continue

                if msg.get("type") != "physics":
                    continue

                tick = int(msg.get("tick", 0))
                dt = float(msg.get("dt", 1.0 / 60.0))
                objects = list(msg.get("objects", []))
                n = len(objects)

                if n == 0 or n > N_MAX:
                    print(f"[PHYS WARN ] at={fmt_ts(time.time())} bad object count n={n}", flush=True)
                    continue

                t0 = time.time()
                payload = snapshot_to_payload(objects)
                result = self.col.run_kernel(
                    n=n,
                    frame_dt_q=f2q(dt),
                    restitution_q=f2q(DEFAULT_RESTITUTION),
                    payload=payload,
                )
                new_objects = payload_to_objects(result, objects)
                t1 = time.time()

                out = {
                    "type": "physics_result",
                    "tick": tick,
                    "dt": dt,
                    "objects": new_objects,
                    "node_id": PHYSICS_NODE_ID,
                    "kernel_ms": (t1 - t0) * 1000.0,
                }

                try:
                    send_json(sock, out, "PHYS")
                except Exception as e:
                    print(f"[PHYS ERR  ] at={fmt_ts(time.time())} send failed: {e}", flush=True)
                    try:
                        sock.close()
                    except Exception:
                        pass
                    sock = connect_role(SERVER_IP, PHYSICS_PORT, PHYSICS_ROLE, PHYSICS_NODE_ID, "PHYS")
                    fobj = sock.makefile("r")

        except KeyboardInterrupt:
            pass
        finally:
            try:
                sock.close()
            except Exception:
                pass

    def run(self):
        gesture_thread = threading.Thread(target=self.gesture_loop, name="gesture-loop", daemon=True)
        physics_thread = threading.Thread(target=self.physics_loop, name="physics-loop", daemon=True)

        gesture_thread.start()
        physics_thread.start()

        try:
            while gesture_thread.is_alive() and physics_thread.is_alive():
                time.sleep(0.5)
        except KeyboardInterrupt:
            print(f"[NODE INFO ] {fmt_ts(time.time())} stopping", flush=True)
            self.stop_event.set()
            time.sleep(1.0)


def main():
    node = IntegratedPynqNode()
    node.run()


if __name__ == "__main__":
    main()