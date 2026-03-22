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

### 2. Setup Video + Physics Node (PYNQ Z1)
1. Connect a USB camera (we used a Logitech C310 – 720p @ 30fps).
2. Ensure WiFi is enabled on the board.
3. Upload:
- the files in the video_and_physics_hardware folder (bitstream + overlays)
- video_and_physics_code.py
4 Make sure to import the custom IP repository (video_physics_ip_repo.zip) in Vivado by adding the path to video_physics_ip_repo in settings->IP->repository.

5. Open a Jupyter terminal on the PYNQ and run:
python3 video_and_physics_code.py

### 3. Setup Render + Audio Node (PYNQ Z1)
1. Ensure WiFi is enabled on the board with a monitor connected over HDMI and python libraries numba and noise are installed.
2. Upload:
- render_and_audio_hardware files
- render_and_audio_code.ipynb

3. Run the uploaded jupyter notebook (the hardware files should be stored in the same folder): the first cell loads the bitstream, the second cell contains the game software. Numba uses JIT compilation, so after connecting to the server it may take a minute or two before rendering begins and output is displayed on the monitor.

### Notes
- Ensure that you run the Jupyter terminal commands in the relevant directory (home/xilinx/jupyter_notebooks).
- Verify ports/IPs in the scripts match the EC2 server (currently set to the IP address of our instance).
- We have not provided our .pem file and any details on our database infrastructure support, since this is a public repo. Proof of it running can be seen in our demo video.
- If you would like to inspect the Vivado files, they are available through the zip files (video_and_physics_project.zip, collision_physics_project.zip, etc.) – the final bitstreams have only been taken from the merged hardware files (video_and_physics_project and render_and_audio_project).
