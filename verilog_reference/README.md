# Verilog Reference

## Rendering
[./rendering_and_audio/rendering_verilog/frame_top.v]: Top level rendering module
 - [./rendering_and_audio/rendering_verilog/inv_area.v]: Inverse Area Calculation
 - [./rendering_and_audio/rendering_verilog/tile_divide.v]: Dividing triangles into 16x16px tile bins
 - [./rendering_and_audio/rendering_verilog/rast_frag_tile.v]: Tile rasterisation and shading 
 - [./rendering_and_audio/rendering_verilog/triangle_ram.v], single_ram.v, dp_single_ram.v: RAM modules

[./rendering_and_audio/rendering_verilog/axi_framebuffer.v]: AXI triple framebuffer IP
## Misc

[./rendering_and_audio/axi_lite_ctrl_mod]: AXI-Lite Control Signal Module

## Audio
[./rendering_and_audio/audio_processing_verilog/pdm_mic.v], pdm_clk_gen.v: PDM to PCM conversion from Labs 

[./rendering_and_audio/audio_processing_verilog/axis_dec_d.v]: AXI-Stream packets and fractional decimation 

[./rendering_and_audio/audio_processing_verilog/axis_rdc_d.v]: DC-offset removal 

[./rendering_and_audio/audio_processing_verilog/axis_hamming_1024.v]: Hamming window function on 1024 sample packet 

[./rendering_and_audio/audio_processing_verilog/hamming_rom_1024.v]: Python generated hamming window coefficients 

[./rendering_and_audio/audio_processing_verilog/axs_sqr_sum.v]: energy bands and spectral peak magnitude/frequency 

[./rendering_and_audio/audio_processing_verilog/axis_packet_slice.v]: Slice part of an AXI-Stream packet

## Video
[./video/blur_top.v]: Blurring (box filter)

[./video/frame_differencing.v]: Frame Differencing

[./video/direction.v]: motion direction

