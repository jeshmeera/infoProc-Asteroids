`timescale 1ns / 1ps

module rast_frag_tile #(
    parameter         HRES               = 1280,
    parameter         VRES               = 720,
    parameter         TILE_SIZE          = 16,
    parameter         VERTEX_W           = 16,
    parameter         VERTEX_FRAC_BITS   = 4,
    parameter         TILE_PIXELS        = TILE_SIZE * TILE_SIZE,
    parameter         VCOL_W             = 24,
    parameter         INV_AREA_W         = 24,                     //Q2.22
    parameter         INV_AREA_FRAC_BITS = 22,
    parameter integer SCREEN_Z_W         = 16,
    parameter integer SCREEN_Z_FRAC_BITS = 8,
    parameter integer WORLD_W            = 16,
    parameter integer WORLD_FRAC_BITS    = 8,
    parameter integer NORMAL_W           = 8,
    parameter integer NORMAL_FRAC_BITS   = 6,                      //Q2.6
    parameter         TILE_BITS          = $clog2(TILE_SIZE),
    parameter         PIX_IDX_W          = $clog2(TILE_PIXELS),
    parameter         EW                 = VERTEX_W + 1,           //17
    parameter         MULT_W             = VERTEX_W * 2 + 1,       //33
    parameter         RW                 = MULT_W + 2              //35
) (
    input clk,
    input rst,

    input                       valid_in,
    input                       tile_empty,
    output reg                  tri_done,
    input      [INV_AREA_W-1:0] inv_area,

    input signed [VERTEX_W-1:0] v0x,
    v0y,
    input signed [VERTEX_W-1:0] v1x,
    v1y,
    input signed [VERTEX_W-1:0] v2x,
    v2y,

    input [SCREEN_Z_W-1:0] v0z,
    v1z,
    v2z,

    input [VCOL_W-1:0] col0,
    input [VCOL_W-1:0] col1,
    input [VCOL_W-1:0] col2,

    input [$clog2(HRES)-1:0] tile_x,
    input [$clog2(VRES)-1:0] tile_y,

    input tile_first,
    input tile_last,

    output reg        tile_valid,
    output reg [31:0] tile_addr_offset,
    output reg [31:0] tile_data,
    input             tile_ready,

    input wire signed [ WORLD_W*3-1:0] wpos0,
    wpos1,
    wpos2,
    input wire signed [NORMAL_W*3-1:0] n,
    input wire signed [NORMAL_W*3-1:0] light,
    input wire        [NORMAL_W*2-1:0] ambient
);
  wire signed [ WORLD_W-1:0] w_v0x = wpos0[WORLD_W-1:0];
  wire signed [ WORLD_W-1:0] w_v0y = wpos0[WORLD_W*2-1:WORLD_W];
  wire signed [ WORLD_W-1:0] w_v0z = wpos0[WORLD_W*3-1:WORLD_W*2];
  wire signed [ WORLD_W-1:0] w_v1x = wpos1[WORLD_W-1:0];
  wire signed [ WORLD_W-1:0] w_v1y = wpos1[WORLD_W*2-1:WORLD_W];
  wire signed [ WORLD_W-1:0] w_v1z = wpos1[WORLD_W*3-1:WORLD_W*2];
  wire signed [ WORLD_W-1:0] w_v2x = wpos2[WORLD_W-1:0];
  wire signed [ WORLD_W-1:0] w_v2y = wpos2[WORLD_W*2-1:WORLD_W];
  wire signed [ WORLD_W-1:0] w_v2z = wpos2[WORLD_W*3-1:WORLD_W*2];
  wire signed [NORMAL_W-1:0] nx = n[NORMAL_W-1:0];
  wire signed [NORMAL_W-1:0] ny = n[NORMAL_W*2-1:NORMAL_W];
  wire signed [NORMAL_W-1:0] nz = n[NORMAL_W*3-1:NORMAL_W*2];
  wire signed [NORMAL_W-1:0] lightx = light[NORMAL_W-1:0];
  wire signed [NORMAL_W-1:0] lighty = light[NORMAL_W*2-1:NORMAL_W];
  wire signed [NORMAL_W-1:0] lightz = light[NORMAL_W*3-1:NORMAL_W*2];

  localparam S_IDLE = 0;
  localparam S_CALC = 1;
  localparam S_RASTER = 2;
  localparam S_STREAM_START = 3;
  localparam S_STREAM_START2 = 4;
  localparam S_STREAM = 5;

  reg [          2:0] state;

  reg [PIX_IDX_W-1:0] pixel_idx;
  reg [PIX_IDX_W-1:0] pixel_idx_d1;
  reg [PIX_IDX_W-1:0] pixel_idx_d2;
  reg [PIX_IDX_W-1:0] pixel_idx_d3;
  reg [PIX_IDX_W-1:0] pixel_idx_d4;
  reg [PIX_IDX_W-1:0] pixel_idx_d5;
  reg [PIX_IDX_W-1:0] pixel_idx_d6;
  reg [PIX_IDX_W-1:0] pixel_idx_d7;
  always @(posedge clk) begin
    pixel_idx_d1 <= pixel_idx;
    pixel_idx_d2 <= pixel_idx_d1;
    pixel_idx_d3 <= pixel_idx_d2;
    pixel_idx_d4 <= pixel_idx_d3;
    pixel_idx_d5 <= pixel_idx_d4;
    pixel_idx_d6 <= pixel_idx_d5;
    pixel_idx_d7 <= pixel_idx_d6;
  end
  reg [PIX_IDX_W-1:0] stream_index;
  reg [PIX_IDX_W-1:0] tile_read_addr;
  reg [PIX_IDX_W-1:0] stream_index_d;
  always @(posedge clk) stream_index_d <= stream_index;
  wire                 stream_handshake = tile_ready && tile_valid;

  wire [PIX_IDX_W-1:0] ram_raddr = tile_read_addr + stream_handshake;
  reg  [PIX_IDX_W-1:0] ram_waddr;
  wire [         24:0] ram_dout;
  reg  [         24:0] ram_din;
  reg                  ram_we;

  dp_single_ram #(
      .ADDR_W(PIX_IDX_W),
      .DATA_W(25),
      .DEPTH (TILE_PIXELS)
  ) tile_ram (
      .clk  (clk),
      .raddr(ram_raddr),
      .din  (ram_din),
      .we   (ram_we),
      .waddr(ram_waddr),
      .dout (ram_dout)
  );

  wire        [                  TILE_BITS-1:0] px = pixel_idx[TILE_BITS-1:0];
  wire        [                  TILE_BITS-1:0] py = pixel_idx[PIX_IDX_W-1:TILE_BITS];

  wire        [               $clog2(HRES)-1:0] abs_x = tile_x + px;
  wire        [               $clog2(VRES)-1:0] abs_y = tile_y + py;

  wire signed [$clog2(HRES)+VERTEX_FRAC_BITS:0] x = (abs_x << VERTEX_FRAC_BITS) + (1 << (VERTEX_FRAC_BITS - 1));

  wire signed [$clog2(VRES)+VERTEX_FRAC_BITS:0] y = (abs_y << VERTEX_FRAC_BITS) + (1 << (VERTEX_FRAC_BITS - 1));



  wire signed [                         EW-1:0] A0 = v0y - v1y;
  wire signed [                         EW-1:0] B0 = v1x - v0x;
  wire signed [                         EW-1:0] A1 = v1y - v2y;
  wire signed [                         EW-1:0] B1 = v2x - v1x;
  wire signed [                         EW-1:0] A2 = v2y - v0y;
  wire signed [                         EW-1:0] B2 = v0x - v2x;

  reg signed [MULT_W-1:0] Ax0, By0;
  reg signed [MULT_W-1:0] Ax1, By1;
  reg signed [MULT_W-1:0] Ax2, By2;

  always @(posedge clk) begin
    Ax0 <= A0 * x;
    By0 <= B0 * y;

    Ax1 <= A1 * x;
    By1 <= B1 * y;

    Ax2 <= A2 * x;
    By2 <= B2 * y;
  end

  reg signed [RW-1:0] E0_r, E1_r, E2_r;
  reg signed [MULT_W-1:0] C0_r, C1_r, C2_r;
  always @(posedge clk) begin
    E0_r <= Ax0 + By0 + C0_r;
    E1_r <= Ax1 + By1 + C1_r;
    E2_r <= Ax2 + By2 + C2_r;
  end
  //back face culling handles elsewhere
  wire inside = (((E0_r >= 0) && (E1_r >= 0) && (E2_r >= 0)) || ((E0_r <= 0) && (E1_r <= 0) && (E2_r <= 0)));
  reg  inside_r;
  reg  inside_d2;
  reg  inside_d3;
  reg  inside_d4;
  always @(posedge clk) begin
    inside_r  <= inside;
    inside_d2 <= inside_r;
    inside_d3 <= inside_d2;
    inside_d4 <= inside_d3;
  end

  reg signed [RW+SCREEN_Z_W-1:0] z0_mul, z1_mul, z2_mul;
  always @(posedge clk) begin
    z0_mul <= E0_r * v0z;
    z1_mul <= E1_r * v1z;
    z2_mul <= E2_r * v2z;
  end
  reg signed [RW+SCREEN_Z_W+2:0] z_num_r;
  always @(posedge clk) begin
    z_num_r <= z0_mul + z1_mul + z2_mul;
  end
  reg signed [RW+SCREEN_Z_W+INV_AREA_W+2:0] z_mul;
  always @(posedge clk) begin
    z_mul <= z_num_r * inv_area;
  end
  localparam Z_SHIFT = INV_AREA_FRAC_BITS + (2 * VERTEX_FRAC_BITS);
  wire [SCREEN_Z_W-1:0] z_interp = z_mul[Z_SHIFT+SCREEN_Z_W-1 : Z_SHIFT];
  reg  [SCREEN_Z_W-1:0] z_interp_d1;
  always @(posedge clk) z_interp_d1 <= z_interp;
  wire [SCREEN_Z_W-1:0] z_dout;
  reg  [SCREEN_Z_W-1:0] z_din;
  reg                   z_we;
  reg  [ PIX_IDX_W-1:0] z_waddr;
  dp_single_ram #(
      .ADDR_W(PIX_IDX_W),
      .DATA_W(SCREEN_Z_W),
      .DEPTH (TILE_PIXELS)
  ) tile_z_ram (
      .clk  (clk),
      .raddr(pixel_idx_d4),
      .din  (z_din),
      .we   (z_we),
      .waddr(z_waddr),
      .dout (z_dout)
  );
  reg depth_pass;
  always @(posedge clk) depth_pass <= z_dout == 0 || z_interp < z_dout;

  wire [7:0] r0 = col0[23:16];
  wire [7:0] g0 = col0[15:8];
  wire [7:0] b0 = col0[7:0];

  wire [7:0] r1 = col1[23:16];
  wire [7:0] g1 = col1[15:8];
  wire [7:0] b1 = col1[7:0];

  wire [7:0] r2 = col2[23:16];
  wire [7:0] g2 = col2[15:8];
  wire [7:0] b2 = col2[7:0];

  reg signed [RW+7:0] r0_mul, r1_mul, r2_mul;
  reg signed [RW+7:0] g0_mul, g1_mul, g2_mul;
  reg signed [RW+7:0] b0_mul, b1_mul, b2_mul;

  always @(posedge clk) begin
    r0_mul <= E1_r * r0;
    r1_mul <= E2_r * r1;
    r2_mul <= E0_r * r2;

    g0_mul <= E1_r * g0;
    g1_mul <= E2_r * g1;
    g2_mul <= E0_r * g2;

    b0_mul <= E1_r * b0;
    b1_mul <= E2_r * b1;
    b2_mul <= E0_r * b2;
  end

  reg signed [RW+9:0] r_num_r, g_num_r, b_num_r;

  always @(posedge clk) begin
    r_num_r <= r0_mul + r1_mul + r2_mul;
    g_num_r <= g0_mul + g1_mul + g2_mul;
    b_num_r <= b0_mul + b1_mul + b2_mul;
  end

  reg signed [RW+INV_AREA_W+9:0] r_mul, g_mul, b_mul;
  always @(posedge clk) begin
    r_mul <= r_num_r * inv_area;
    g_mul <= g_num_r * inv_area;
    b_mul <= b_num_r * inv_area;
  end
  localparam COLOR_SHIFT = INV_AREA_FRAC_BITS + (2 * VERTEX_FRAC_BITS);  //30
  reg signed [NORMAL_W*2+1:0] ndotl;  //17bit
  localparam AMBIENT = 1 << (NORMAL_FRAC_BITS * 2 - 1);  //0.5
  localparam LIGHT_SUM_W = NORMAL_W * 2 + 1;  //17 bits unsigned Q5.12
  reg [LIGHT_SUM_W-1:0] light_sum;  //Q5.12
  reg [(8 + NORMAL_FRAC_BITS*2 + LIGHT_SUM_W )-1:0] r_w_light, g_w_light, b_w_light;  //8+12+17=35
  always @(posedge clk) begin
    r_w_light <= r_mul[COLOR_SHIFT+7:COLOR_SHIFT-NORMAL_FRAC_BITS*2] * light_sum;  //[37:18] -> Q8.12*Q5.12 = Q13.24
    g_w_light <= g_mul[COLOR_SHIFT+7:COLOR_SHIFT-NORMAL_FRAC_BITS*2] * light_sum;
    b_w_light <= b_mul[COLOR_SHIFT+7:COLOR_SHIFT-NORMAL_FRAC_BITS*2] * light_sum;
  end
  localparam COLOR_SHIFT2 = NORMAL_FRAC_BITS * 4;  //24
  wire    [             7:0] r_interp = r_w_light[COLOR_SHIFT2+7 : COLOR_SHIFT2];  //[31:24]
  wire    [             7:0] g_interp = g_w_light[COLOR_SHIFT2+7 : COLOR_SHIFT2];
  wire    [             7:0] b_interp = b_w_light[COLOR_SHIFT2+7 : COLOR_SHIFT2];


  reg     [$clog2(HRES)-1:0] tile_x_reg;
  reg     [$clog2(VRES)-1:0] tile_y_reg;

  wire    [            15:0] pixel_x = tile_x_reg + (tile_read_addr[$clog2(TILE_SIZE)-1:0]);
  wire    [            15:0] pixel_y = tile_y_reg + (tile_read_addr[PIX_IDX_W-1:$clog2(TILE_SIZE)]);

  integer                    i;
  wire                       coverage = ram_dout[24];
  wire    [            23:0] colour = ram_dout[23:0];
  reg     [   PIX_IDX_W-1:0] stream_index_prev;
  reg [31:0] next_tile_data, next_tile_addr;
  reg [2:0] idle_count;


  always @(posedge clk) begin
    tri_done          <= 0;
    stream_index_prev <= stream_index;

    if (rst) begin
      state          <= S_IDLE;
      pixel_idx      <= 0;
      stream_index   <= 0;
      tile_read_addr <= 0;
      tile_valid     <= 0;
      idle_count     <= 0;
    end else begin
      tile_valid <= 0;
      ram_we     <= 0;
      ram_din    <= 0;
      z_we       <= 0;
      z_din      <= 0;
      case (state)

        S_IDLE: begin


          if (valid_in) begin
            idle_count <= idle_count + 1;
            if (idle_count >= 3) begin
              idle_count <= 0;
              C0_r       <= v0x * v1y - v1x * v0y;
              C1_r       <= v1x * v2y - v2x * v1y;
              C2_r       <= v2x * v0y - v0x * v2y;
              ndotl      <= nx * lightx + ny * lighty + nz * lightz;
              pixel_idx  <= 0;
              if (tile_empty) begin
                tri_done       <= 1;
                tile_x_reg     <= tile_x;
                tile_y_reg     <= tile_y;
                stream_index   <= 0;
                state          <= S_STREAM_START;
                tile_read_addr <= 1;
              end else begin
                state <= S_CALC;
              end
            end
          end
        end
        S_CALC: begin
          light_sum <= ambient + (ndotl[NORMAL_W*2+1] ? 17'd0 : ndotl[NORMAL_W*2:0]);
          state     <= S_RASTER;
        end

        S_RASTER: begin
          if (pixel_idx_d6 <= pixel_idx) begin
            if (pixel_idx > 5 && inside_d4 && depth_pass) begin
              ram_we    <= 1;
              ram_din   <= {1'b1, r_interp, g_interp, b_interp};
              ram_waddr <= pixel_idx_d6;

              z_we      <= 1;
              z_din     <= z_interp_d1;
              z_waddr   <= pixel_idx_d6;
            end

            if (pixel_idx < TILE_PIXELS - 1) pixel_idx <= pixel_idx + 1;

            if (pixel_idx_d6 == TILE_PIXELS - 1) begin
              tri_done   <= 1;
              tile_x_reg <= tile_x;
              tile_y_reg <= tile_y;
              pixel_idx  <= 0;
              if (tile_last) begin
                stream_index   <= 0;
                state          <= S_STREAM_START;
                tile_read_addr <= 1;

              end else begin
                state <= S_IDLE;
              end
            end
          end
        end

        S_STREAM_START: begin
          ram_din          <= 0;
          // tile_data <= read(0)
          tile_valid       <= 1;
          tile_data        <= coverage ? {8'hFF, colour} : 32'h00000000;
          tile_addr_offset <= ((tile_y_reg * HRES) + tile_x_reg) << 2;
          state            <= S_STREAM;

          //tile_read_addr = 1

        end
        S_STREAM: begin
          tile_valid <= 1;
          if (tile_ready && tile_valid) begin
            ram_we           <= 1;
            ram_din          <= 0;
            ram_waddr        <= stream_index;
            z_we             <= 1;
            z_din            <= 0;
            z_waddr          <= stream_index;

            tile_data        <= coverage ? {8'hFF, colour} : 32'h00000000;
            tile_addr_offset <= ((pixel_y * HRES) + pixel_x) << 2;

            stream_index     <= stream_index + 1;
            tile_read_addr   <= tile_read_addr + 1;

            if (stream_index == TILE_PIXELS - 1) begin
              state          <= S_IDLE;
              tile_read_addr <= 0;
              tile_valid     <= 0;
            end
          end
        end

      endcase
    end

  end

endmodule
