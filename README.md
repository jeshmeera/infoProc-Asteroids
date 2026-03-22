# Asteroid Apocalypse

## Demo Video
Distributed FPGA Asteroids System Demo

https://github.com/user-attachments/assets/aeb886e7-354f-464c-96a0-d8a1817ff284

## How to Run

### 1. Launch Cloud Server (AWS EC2)
1. Start an EC2 instance (Ubuntu recommended).
2. SSH into the instance:
   ```bash
   ssh -i <your-key.pem> ubuntu@<your-ec2-ip>
Upload final_master_server.py to the instance.

Run the server: python3 server.py

2. Setup Video + Physics Node (PYNQ Z1)
Connect a USB camera
(we used a Logitech C310 – 720p @ 30fps).
Ensure WiFi is enabled on the board.
Upload:
video_and_physics_hardware (bitstream + overlays)
video_and_physics_code.py

Open a Jupyter terminal on the PYNQ and run:
python3 video_and_physics_code.py

3. Setup Render + Audio Node (PYNQ Z1)
Ensure WiFi is enabled on the board.
Upload:
render_and_audio_hardware
render_and_audio_code.py

Open a Jupyter terminal on the PYNQ and run:
python3 render_and_audio_code.py

Ensure that you run this command in the relevant directory (home/xilinx/jupyter_notebooks).

Notes
Ensure all devices (EC2 + both PYNQ boards) are on the same network or correctly configured with public IPs.
Verify ports/IPs in the scripts match the EC2 server (currently set to the IP address of our instance).
