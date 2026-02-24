import socket, json, time
import pygame

SERVER_IP = "56.228.33.153"
RENDER_PORT = 9003
CONTROL_PORT = 9001

W, H = 800, 600

def send(sock, msg):
    sock.sendall((json.dumps(msg) + "\n").encode("utf-8"))

def connect_stream(port, hello_msg):
    while True:
        try:
            s = socket.create_connection((SERVER_IP, port), timeout=10)
            s.settimeout(None)
            f = s.makefile("r")
            send(s, hello_msg)
            print("ack:", f.readline().strip())
            return s, f
        except Exception as e:
            print(f"reconnecting port {port}...", e)
            time.sleep(1)

def world_to_screen(x, y):
    scale = 200
    sx = int(W/2 + x * scale)
    sy = int(H/2 - y * scale)
    return sx, sy

def clamp(v): 
    return max(-1, min(1, int(v)))

def main():
    # 1) Render stream (receive game state)
    render_sock, render_file = connect_stream(
        RENDER_PORT,
        {"type": "hello", "role": "render", "node_id": "pynq-render"}
    )

    # 2) LR control stream (send control)
    control_sock, _ = connect_stream(
        CONTROL_PORT,
        {"type": "hello", "role": "control_lr", "node_id": "pynq-lr"}
    )

    pygame.init()
    screen = pygame.display.set_mode((W, H))
    pygame.display.set_caption("PYNQ LR render + LR control (focus here)")
    clock = pygame.time.Clock()
    font = pygame.font.SysFont(None, 24)

    last_send = 0.0
    lr_value = 0

    while True:
        # --- events / quit ---
        for event in pygame.event.get():
            if event.type == pygame.QUIT:
                return

        # --- LR control from keyboard (swap this later for audio/vision) ---
        keys = pygame.key.get_pressed()
        new_lr = 0
        if keys[pygame.K_LEFT] or keys[pygame.K_a]:
            new_lr = -1
        elif keys[pygame.K_RIGHT] or keys[pygame.K_d]:
            new_lr = 1

        now = time.time()
        if new_lr != lr_value or (now - last_send) > 0.1:
            lr_value = clamp(new_lr)
            try:
                send(control_sock, {"type":"control","axis":"lr","value":lr_value,"t":now})
                # print("sent LR", lr_value)  # uncomment for spammy debug
            except Exception:
                try: control_sock.close()
                except Exception: pass
                control_sock, _ = connect_stream(
                    CONTROL_PORT,
                    {"type": "hello", "role": "control_lr", "node_id": "pynq-lr"}
                )
            last_send = now

        # --- receive render snapshot ---
        line = render_file.readline()
        if not line:
            try: render_sock.close()
            except Exception: pass
            render_sock, render_file = connect_stream(
                RENDER_PORT,
                {"type": "hello", "role": "render", "node_id": "pynq-render"}
            )
            continue

        msg = json.loads(line)
        if msg.get("type") != "render":
            continue

        tick = msg.get("tick")
        objs = msg.get("objects", [])
        controls = msg.get("controls", {"lr": 0, "ud": 0})

        # --- draw ---
        screen.fill((0, 0, 0))

        for o in objs:
            x, y = o["pos"][0], o["pos"][1]
            sx, sy = world_to_screen(x, y)
            r = max(2, int(8 * float(o.get("size", 1.0))))
            if o["type"] == "player":
                pygame.draw.circle(screen, (0, 255, 0), (sx, sy), r, 2)
            else:
                pygame.draw.circle(screen, (255, 255, 255), (sx, sy), r, 1)

        # On-screen debug: tick + controls
        txt1 = font.render(f"tick={tick}", True, (200, 200, 200))
        txt2 = font.render(f"controls lr={controls.get('lr',0)} ud={controls.get('ud',0)}", True, (200, 200, 200))
        txt3 = font.render(f"local LR key={lr_value}", True, (200, 200, 200))
        screen.blit(txt1, (10, 10))
        screen.blit(txt2, (10, 30))
        screen.blit(txt3, (10, 50))

        pygame.display.flip()
        clock.tick(60)

if __name__ == "__main__":
    main()