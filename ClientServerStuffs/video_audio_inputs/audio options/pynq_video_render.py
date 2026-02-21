import socket, json, time

SERVER_IP = "56.228.33.153"
CONTROL_PORT = 9001
RENDER_PORT  = 9003

def send(sock, msg):
    sock.sendall((json.dumps(msg) + "\n").encode("utf-8"))

def connect(role, port, node_id):
    while True:
        try:
            s = socket.create_connection((SERVER_IP, port), timeout=10)
            f = s.makefile("r")
            send(s, {"type":"hello","role":role,"node_id":node_id})
            ack = f.readline().strip()
            print(f"[{role}] ack:", ack)
            return s, f
        except Exception as e:
            print(f"[{role}] reconnecting... ({e})")
            time.sleep(1)

def clamp(v): 
    return max(-1, min(1, int(v)))

# ----- dummy OpenCV -> left/right control -----
def get_video_lr_control():
    # TODO: replace with motion left/right -> {-1,0,1}
    phase = int(time.time()) % 3
    return [1, 0, -1][phase]

def main():
    control_sock, _ = connect("control_video", CONTROL_PORT, "pynq-video")
    render_sock, render_file = connect("render", RENDER_PORT, "pynq-video")

    last_control_send = 0.0

    while True:
        # Send LR at ~20Hz
        now = time.time()
        if now - last_control_send > 0.05:
            lr = clamp(get_video_lr_control())
            send(control_sock, {"type":"control","tick":0,"control_type":"video","value":lr})
            last_control_send = now

        # Render stream: wait for snapshot
        line = render_file.readline()
        if not line:
            render_sock.close()
            render_sock, render_file = connect("render", RENDER_PORT, "pynq-video")
            continue

        msg = json.loads(line)
        if msg.get("type") != "render":
            continue

        tick = msg["tick"]
        objs = msg["objects"]
        player = next(o for o in objs if o["type"] == "player")
        # replace with real drawing
        print(f"[render] tick={tick} player_pos={player['pos']}")

if __name__ == "__main__":
    main()