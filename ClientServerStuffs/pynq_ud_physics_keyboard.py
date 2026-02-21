import socket, json, time
import pygame

SERVER_IP = "56.228.33.153"
CONTROL_PORT = 9001
PHYSICS_PORT = 9002

def send(sock, msg):
    sock.sendall((json.dumps(msg) + "\n").encode("utf-8"))

def connect(port, hello_msg):
    while True:
        try:
            s = socket.create_connection((SERVER_IP, port), timeout=10)
            f = s.makefile("r")
            send(s, hello_msg)
            ack = f.readline().strip()
            print("ack:", ack)
            return s, f
        except Exception as e:
            print("reconnecting...", e)
            time.sleep(1)

def clamp(v): return max(-1, min(1, int(v)))

def physics_step(objects, dt):
    # integrate; respawn asteroids when off left edge
    for o in objects:
        o["pos"][0] += o["vel"][0] * dt
        o["pos"][1] += o["vel"][1] * dt
        if o["type"] == "asteroid" and o["pos"][0] < -10.0:
            o["pos"][0] = 12.0
    return objects, []

def main():
    # CONTROL socket (UD)
    control_sock, _ = connect(
        CONTROL_PORT,
        {"type":"hello","role":"control_ud","node_id":"pynq-ud"}
    )

    # PHYSICS socket
    phys_sock, phys_file = connect(
        PHYSICS_PORT,
        {"type":"hello","role":"physics","node_id":"pynq-ud"}
    )

    # Keyboard init (needs a focused window)
    pygame.init()
    screen = pygame.display.set_mode((320, 120))
    pygame.display.set_caption("PYNQ UD control (focus here)")

    last_control_send = 0.0
    ud_value = 0

    while True:
        # --- Keyboard -> UD control ---
        for event in pygame.event.get():
            if event.type == pygame.QUIT:
                return

        keys = pygame.key.get_pressed()
        new_ud = 0
        if keys[pygame.K_UP] or keys[pygame.K_w]:
            new_ud = 1
        elif keys[pygame.K_DOWN] or keys[pygame.K_s]:
            new_ud = -1

        now = time.time()
        if new_ud != ud_value or (now - last_control_send) > 0.1:
            ud_value = clamp(new_ud)
            try:
                send(control_sock, {"type":"control","axis":"ud","value":ud_value,"t":now})
            except Exception:
                try: control_sock.close()
                except Exception: pass
                control_sock, _ = connect(
                    CONTROL_PORT,
                    {"type":"hello","role":"control_ud","node_id":"pynq-ud"}
                )
            last_control_send = now

        # --- Physics stream: receive snapshot (blocking) ---
        line = phys_file.readline()
        if not line:
            try: phys_sock.close()
            except Exception: pass
            phys_sock, phys_file = connect(
                PHYSICS_PORT,
                {"type":"hello","role":"physics","node_id":"pynq-ud"}
            )
            continue

        msg = json.loads(line)
        if msg.get("type") != "physics":
            continue

        tick = int(msg["tick"])
        dt = float(msg.get("dt", 1/30))
        objects = msg["objects"]

        new_objects, collisions = physics_step(objects, dt)

        try:
            send(phys_sock, {
                "type":"physics_result",
                "tick": tick,
                "objects": new_objects,
                "collisions": collisions
            })
        except Exception:
            try: phys_sock.close()
            except Exception: pass
            phys_sock, phys_file = connect(
                PHYSICS_PORT,
                {"type":"hello","role":"physics","node_id":"pynq-ud"}
            )

        time.sleep(0.001)

if __name__ == "__main__":
    main()