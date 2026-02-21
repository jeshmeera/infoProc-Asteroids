import socket, json, time

SERVER_IP = "56.228.33.153"
PHYSICS_PORT = 9002

def send(sock, msg):
    sock.sendall((json.dumps(msg) + "\n").encode("utf-8"))

def connect():
    while True:
        try:
            s = socket.create_connection((SERVER_IP, PHYSICS_PORT), timeout=10)
            f = s.makefile("r")
            send(s, {"type":"hello","role":"physics","node_id":"pynq-physics"})
            print("ack:", f.readline().strip())
            return s, f
        except Exception as e:
            print("reconnecting...", e)
            time.sleep(1)

def physics_step(objects, dt):
    # dt ~ 1/30, integrate directly
    for o in objects:
        o["pos"][0] += o["vel"][0] * dt
        o["pos"][1] += o["vel"][1] * dt
        # respawn asteroids that leave screen (left side)
        if o["type"] == "asteroid" and o["pos"][0] < -10.0:
            o["pos"][0] = 12.0
    return objects, []

def main():
    sock, f = connect()

    while True:
        line = f.readline()
        if not line:
            sock.close()
            sock, f = connect()
            continue

        msg = json.loads(line)
        if msg.get("type") != "physics":
            continue

        tick = int(msg["tick"])
        dt = float(msg.get("dt", 1/30))
        objects = msg["objects"]

        new_objects, collisions = physics_step(objects, dt)

        try:
            send(sock, {"type":"physics_result", "tick": tick, "objects": new_objects, "collisions": collisions})
        except Exception:
            sock.close()
            sock, f = connect()

if __name__ == "__main__":
    main()