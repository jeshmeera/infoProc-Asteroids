import socket, json, time

SERVER_IP = "56.228.33.153"
CONTROL_PORT = 9001
PHYSICS_PORT = 9002

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

# ----- dummy audio -> up/down control -----
def get_audio_ud_control():
    # TODO: replace with your FFT thresholding -> {-1,0,1}
    phase = int(time.time()) % 3
    return [-1, 0, 1][phase]

def physics_step(objects, dt):
    # very simple integrate + wrap asteroids when offscreen
    for o in objects:
        o["pos"][0] += o["vel"][0] * (dt * 30.0)  # dt already ~0.033; scale optional
        o["pos"][1] += o["vel"][1] * (dt * 30.0)

        if o["type"] == "asteroid" and o["pos"][0] < -8.0:
            o["pos"][0] = 12.0  # respawn to the right
    return objects, []

def main():
    control_sock, _ = connect("control_audio", CONTROL_PORT, "pynq-audio")
    phys_sock, phys_file = connect("physics", PHYSICS_PORT, "pynq-audio")

    last_control_send = 0.0

    while True:
        # Send control at ~20Hz (fine)
        now = time.time()
        if now - last_control_send > 0.05:
            ud = clamp(get_audio_ud_control())
            send(control_sock, {"type":"control","tick":0,"control_type":"audio","value":ud})
            last_control_send = now

        # Physics stream: blocking wait for snapshot
        line = phys_file.readline()
        if not line:
            phys_sock.close()
            phys_sock, phys_file = connect("physics", PHYSICS_PORT, "pynq-audio")
            continue

        msg = json.loads(line)
        if msg.get("type") != "physics":
            continue

        tick = int(msg["tick"])
        dt = float(msg.get("dt", 0.0333))
        objs = msg["objects"]

        # integrate/collisions on this node
        new_objs, collisions = physics_step(objs, dt)

        # return full updated state
        send(phys_sock, {
            "type": "physics_result",
            "tick": tick,
            "objects": new_objs,
            "collisions": collisions
        })

if __name__ == "__main__":
    main()