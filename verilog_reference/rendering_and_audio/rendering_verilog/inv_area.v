`timescale 1ns / 1ps

module inv_area #(
    parameter integer VPOS_W             = 48,
    parameter integer VCOL_W             = 24,
    parameter integer INV_AREA_W         = 24,
    parameter integer INV_AREA_FRAC_BITS = 22,
    parameter integer WORLD_W            = 16,
    parameter integer NORMAL_W           = 8,
    parameter integer SCREEN_XY_W        = 16,
    parameter integer VERTEX_FRAC_BITS   = 4
) (
    input clk,
    input rst,

    // input triangle stream
    input wire [VPOS_W-1:0] pos0_i,
    input wire [VPOS_W-1:0] pos1_i,
    input wire [VPOS_W-1:0] pos2_i,

    input wire [VCOL_W-1:0] col0_i,
    input wire [VCOL_W-1:0] col1_i,
    input wire [VCOL_W-1:0] col2_i,

    input wire signed [WORLD_W*3-1:0] wpos0_i,
    input wire signed [WORLD_W*3-1:0] wpos1_i,
    input wire signed [WORLD_W*3-1:0] wpos2_i,

    input wire signed [NORMAL_W*3-1:0] n_i,

    input  wire tvalid_i,
    input  wire tlast_i,
    output wire tready_i,

    // output triangle stream
    output reg [VPOS_W-1:0] pos0,
    output reg [VPOS_W-1:0] pos1,
    output reg [VPOS_W-1:0] pos2,

    output reg [VCOL_W-1:0] col0,
    output reg [VCOL_W-1:0] col1,
    output reg [VCOL_W-1:0] col2,

    output reg [INV_AREA_W-1:0] inv_area,

    output reg  tvalid,
    output reg  tlast,
    input  wire tready,

    output reg signed [WORLD_W*3-1:0] wpos0,
    output reg signed [WORLD_W*3-1:0] wpos1,
    output reg signed [WORLD_W*3-1:0] wpos2,

    output reg signed [NORMAL_W*3-1:0] n
);

  wire signed [SCREEN_XY_W-1:0] v0x = pos0_i[SCREEN_XY_W-1:0];
  wire signed [SCREEN_XY_W-1:0] v0y = pos0_i[2*SCREEN_XY_W-1:SCREEN_XY_W];

  wire signed [SCREEN_XY_W-1:0] v1x = pos1_i[SCREEN_XY_W-1:0];
  wire signed [SCREEN_XY_W-1:0] v1y = pos1_i[2*SCREEN_XY_W-1:SCREEN_XY_W];

  wire signed [SCREEN_XY_W-1:0] v2x = pos2_i[SCREEN_XY_W-1:0];
  wire signed [SCREEN_XY_W-1:0] v2y = pos2_i[2*SCREEN_XY_W-1:SCREEN_XY_W];

  reg signed [SCREEN_XY_W:0] dx10, dy10;
  reg signed [SCREEN_XY_W:0] dx20, dy20;

  always @(posedge clk) begin
    dx10 <= v1x - v0x;
    dy10 <= v1y - v0y;
    dx20 <= v2x - v0x;
    dy20 <= v2y - v0y;
  end

  reg signed [(SCREEN_XY_W+1)*2-1:0] mul0;
  reg signed [(SCREEN_XY_W+1)*2-1:0] mul1;

  always @(posedge clk) begin
    mul0 <= dx10 * dy20;
    mul1 <= dx20 * dy10;
  end

  reg signed [(SCREEN_XY_W+1)*2:0] area;

  always @(posedge clk) begin
    area <= mul0 - mul1;
  end


  reg         divisor_valid;
  reg         dividend_valid;

  wire        divisor_ready;
  wire        dividend_ready;

  wire        div_out_valid;
  wire [23:0] div_out;

  div_gen_0 divider_inst (
      .aclk(clk),

      .s_axis_divisor_tvalid(divisor_valid),
      .s_axis_divisor_tready(divisor_ready),
      .s_axis_divisor_tdata (area[(SCREEN_XY_W+1)*2:VERTEX_FRAC_BITS*2]),

      .s_axis_dividend_tvalid(dividend_valid),
      .s_axis_dividend_tready(dividend_ready),
      .s_axis_dividend_tdata (8'd1),

      .m_axis_dout_tvalid(div_out_valid),
      .m_axis_dout_tdata (div_out)
  );

  localparam S_IDLE = 0;
  localparam S_DIVIDE = 1;
  localparam S_OUT = 2;

  reg [1:0] state;

  assign tready_i = (state == S_IDLE);

  reg start_d1, start_d2, start_d3;

  always @(posedge clk) begin
    start_d1 <= (tvalid_i && tready_i);
    start_d2 <= start_d1;
    start_d3 <= start_d2;
  end


  always @(posedge clk) begin

    if (rst) begin
      state          <= S_IDLE;
      divisor_valid  <= 0;
      dividend_valid <= 0;
      tvalid         <= 0;
    end else begin

      divisor_valid  <= 0;
      dividend_valid <= 0;
      tvalid         <= 0;

      case (state)
        S_IDLE: begin
          if (tvalid_i && tready_i) begin

            pos0  <= pos0_i;
            pos1  <= pos1_i;
            pos2  <= pos2_i;

            col0  <= col0_i;
            col1  <= col1_i;
            col2  <= col2_i;

            wpos0 <= wpos0_i;
            wpos1 <= wpos1_i;
            wpos2 <= wpos2_i;

            n     <= n_i;

            tlast <= tlast_i;

            state <= S_DIVIDE;
          end
        end

        S_DIVIDE: begin
          if (start_d2) begin  //wait for area
            divisor_valid  <= 1;
            dividend_valid <= 1;
          end

          if (div_out_valid) begin
            inv_area <= div_out;
            state    <= S_OUT;
          end
        end

        S_OUT: begin
          tvalid <= 1;

          if (tready) begin
            state <= S_IDLE;
          end
        end

      endcase
    end

  end

endmodule

