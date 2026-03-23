module tile_divide #(
    parameter integer HRES             = 1280,
    parameter integer VRES             = 720,
    parameter integer TILE_SIZE        = 16,
    parameter integer TRI_ID_W         = 16,
    parameter integer VERTEX_W         = 16,
    parameter integer VERTEX_FRAC_BITS = 4,
    parameter integer MAX_TRI_PER_TILE = 32
) (
    input clk,
    input reset,
    input start,

    input [TRI_ID_W-1:0] triangle_id,

    input signed [VERTEX_W-1:0] v0x,
    v0y,
    input signed [VERTEX_W-1:0] v1x,
    v1y,
    input signed [VERTEX_W-1:0] v2x,
    v2y,

    output wire [$clog2((HRES/TILE_SIZE)*(VRES/TILE_SIZE))-1:0] tile_addr,
    input       [                 $clog2(MAX_TRI_PER_TILE)-1:0] tile_count_in,
    output reg  [                 $clog2(MAX_TRI_PER_TILE)-1:0] tile_count_out,
    output reg                                                  tile_count_we,

    output reg [$clog2((HRES/TILE_SIZE)*(VRES/TILE_SIZE)*MAX_TRI_PER_TILE)-1:0] bin_addr,
    output reg [                                                  TRI_ID_W-1:0] bin_data,
    output reg                                                                  bin_we,

    output reg done
);

  localparam TILE_X = HRES / TILE_SIZE;
  localparam TILE_Y = VRES / TILE_SIZE;
  localparam TILE_COUNT = TILE_X * TILE_Y;

  localparam IDLE = 0;
  localparam BOUNDS = 6;
  localparam WAIT_COUNT = 1;
  localparam WRITE_BIN = 2;
  localparam WRITE_COUNT = 3;
  localparam NEXT_TILE = 4;
  localparam FINISHED = 5;

  reg [2:0] state;

  localparam PX_WM = VERTEX_W - VERTEX_FRAC_BITS - 1;
  localparam TL_WM = $clog2(TILE_X) - 1;

  wire signed [           PX_WM:0] px0 = v0x >>> VERTEX_FRAC_BITS;
  wire signed [           PX_WM:0] px1 = v1x >>> VERTEX_FRAC_BITS;
  wire signed [           PX_WM:0] px2 = v2x >>> VERTEX_FRAC_BITS;

  wire signed [           PX_WM:0] py0 = v0y >>> VERTEX_FRAC_BITS;
  wire signed [           PX_WM:0] py1 = v1y >>> VERTEX_FRAC_BITS;
  wire signed [           PX_WM:0] py2 = v2y >>> VERTEX_FRAC_BITS;


  wire signed [           PX_WM:0] minX = (px0 < px1) ? ((px0 < px2) ? px0 : px2) : ((px1 < px2) ? px1 : px2);

  wire signed [           PX_WM:0] maxX = (px0 > px1) ? ((px0 > px2) ? px0 : px2) : ((px1 > px2) ? px1 : px2);

  wire signed [           PX_WM:0] minY = (py0 < py1) ? ((py0 < py2) ? py0 : py2) : ((py1 < py2) ? py1 : py2);

  wire signed [           PX_WM:0] maxY = (py0 > py1) ? ((py0 > py2) ? py0 : py2) : ((py1 > py2) ? py1 : py2);

  wire                             triangle_outside = (maxX < 0) || (minX >= HRES) || (maxY < 0) || (minY >= VRES);

  wire        [           TL_WM:0] calc_tile_min_x = minX < 0 ? 0 : minX >> $clog2(TILE_SIZE);

  wire        [           TL_WM:0] calc_tile_min_y = minY < 0 ? 0 : minY >> $clog2(TILE_SIZE);

  wire        [           TL_WM:0] calc_tile_max_x = maxX >= HRES ? TILE_X - 1 : (maxX >> $clog2(TILE_SIZE));

  wire        [           TL_WM:0] calc_tile_max_y = maxY >= VRES ? TILE_Y - 1 : (maxY >> $clog2(TILE_SIZE));


  reg         [$clog2(TILE_X)-1:0] tx;
  reg         [$clog2(TILE_Y)-1:0] ty;

  reg [$clog2(TILE_X)-1:0] tile_min_x, tile_max_x;
  reg [$clog2(TILE_Y)-1:0] tile_min_y, tile_max_y;


  assign tile_addr = ty * TILE_X + tx;

  always @(posedge clk) begin

    if (reset) begin
      state         <= IDLE;
      done          <= 0;
      tile_count_we <= 0;
      bin_we        <= 0;
    end else begin

      case (state)

        IDLE: begin
          done <= 0;

          if (start) begin
            state <= BOUNDS;
          end
        end

        BOUNDS: begin
          tile_min_x <= calc_tile_min_x;
          tile_max_x <= calc_tile_max_x;
          tile_min_y <= calc_tile_min_y;
          tile_max_y <= calc_tile_max_y;

          tx         <= calc_tile_min_x;
          ty         <= calc_tile_min_y;

          state      <= triangle_outside ? IDLE : WAIT_COUNT;
        end

        WAIT_COUNT: begin
          state <= WRITE_BIN;
        end


        WRITE_BIN: begin
          if (tile_count_in < MAX_TRI_PER_TILE - 1) begin
            bin_addr <= (tile_addr << $clog2(MAX_TRI_PER_TILE)) + tile_count_in;
            bin_data <= triangle_id;
            bin_we   <= 1;
          end else begin
            bin_we <= 0;
          end
          state <= WRITE_COUNT;
        end


        WRITE_COUNT: begin
          bin_we <= 0;

          if (tile_count_in < MAX_TRI_PER_TILE - 1) begin
            tile_count_out <= tile_count_in + 1;
            tile_count_we  <= 1;
          end else begin
            tile_count_we <= 0;
          end

          state <= NEXT_TILE;
        end


        NEXT_TILE: begin
          tile_count_we <= 0;

          if (tx < tile_max_x) begin
            tx    <= tx + 1;
            state <= WAIT_COUNT;
          end else begin
            tx <= tile_min_x;
            ty <= ty + 1;

            if (ty + 1 > tile_max_y) begin
              state <= IDLE;  //FINISHED;
              done  <= 1;
            end else state <= WAIT_COUNT;
          end
        end


        FINISHED: begin
          state <= IDLE;
        end

      endcase
    end
  end

endmodule
