module frame_top #(
    parameter integer HRES                = 1280,
    parameter integer VRES                = 720,
    parameter integer TILE_SIZE           = 16,
    parameter integer SCREEN_XY_W         = 16,
    parameter integer SCREEN_XY_FRAC_BITS = 4,
    parameter integer SCREEN_Z_W          = 16,
    parameter integer SCREEN_Z_FRAC_BITS  = 8,
    parameter         INV_AREA_W          = 24,
    parameter         INV_AREA_FRAC_BITS  = 22,
    parameter integer MAX_TRI_PER_TILE    = 32,
    parameter integer WORLD_W             = 16,
    parameter integer WORLD_FRAC_BITS     = 8,
    parameter integer NORMAL_W            = 8,
    parameter integer NORMAL_FRAC_BITS    = 6,                                        //Q2.6
    parameter integer SCREEN_VERT_W       = SCREEN_XY_W * 2 + SCREEN_Z_W,
    parameter integer NUM_TILES           = (HRES / TILE_SIZE) * (VRES / TILE_SIZE),
    parameter integer TILE_PIXELS         = TILE_SIZE * TILE_SIZE,
    parameter         TRI_COUNT           = 8184,                                     //<8192
    parameter integer VCOL_W              = 24
) (
    input clk,
    input rst,
    input start,

    input  wire        [SCREEN_VERT_W-1:0] tri_pos0_i,
    input  wire        [SCREEN_VERT_W-1:0] tri_pos1_i,
    input  wire        [SCREEN_VERT_W-1:0] tri_pos2_i,
    input  wire        [       VCOL_W-1:0] tri_col0_i,
    input  wire        [       VCOL_W-1:0] tri_col1_i,
    input  wire        [       VCOL_W-1:0] tri_col2_i,
    input  wire signed [    WORLD_W*3-1:0] tri_wpos0_i,
    input  wire signed [    WORLD_W*3-1:0] tri_wpos1_i,
    input  wire signed [    WORLD_W*3-1:0] tri_wpos2_i,
    input  wire signed [   NORMAL_W*3-1:0] tri_normal_i,
    input  wire signed [   NORMAL_W*3-1:0] light_dir_i,
    input  wire                            s_axis_tvalid,
    input  wire                            s_axis_tlast,
    output wire                            s_axis_tready,
    input  wire        [   NORMAL_W*2-1:0] ambient,


    output wire [                         3:0] state_o,
    output wire [       $clog2(NUM_TILES)-1:0] tile_counter_o,
    output wire [$clog2(MAX_TRI_PER_TILE)-1:0] tri_index_o,

    output wire        m_axis_tvalid,
    output wire [63:0] m_axis_tdata,
    output wire        m_axis_tlast,
    input              m_axis_tready
);
  localparam integer TRI_ADDR_W = $clog2(TRI_COUNT);



  wire [31:0] tile_addr_offset;
  wire [31:0] tile_data;
  wire frame_done, tile_valid;
  wire tile_ready = m_axis_tready;
  assign m_axis_tvalid = tile_valid;
  assign m_axis_tlast  = frame_done;
  assign m_axis_tdata  = {tile_addr_offset, tile_data};


  localparam TILE_BIN_ADDR_W = $clog2(NUM_TILES * MAX_TRI_PER_TILE);
  localparam TILE_COUNT_W = $clog2(NUM_TILES);
  localparam TILE_COUNT_DW = $clog2(MAX_TRI_PER_TILE);
  localparam TILE_SHIFT = $clog2(MAX_TRI_PER_TILE);


  localparam IDLE = 0;
  localparam CLEAR = 1;
  localparam DIVIDE = 2;
  localparam RASTER = 3;
  reg        [$clog2(NUM_TILES)-1:0] clear_index;
  reg        [                  3:0] state;
  reg signed [       NORMAL_W*3-1:0] light_dir;
  always @(posedge clk) begin
    if (rst) light_dir <= 0;
    else if (state == CLEAR && s_axis_tvalid && s_axis_tready && s_axis_tlast) light_dir <= light_dir_i;
  end

  wire state_divide = (state == DIVIDE);
  wire state_raster = (state == RASTER);


  wire [TRI_ADDR_W-1:0] svertex_rd_addr, svertex_wr_addr;
  wire [SCREEN_VERT_W-1:0] svertex_rd_0, svertex_rd_1, svertex_rd_2;
  wire [SCREEN_VERT_W-1:0] svertex_wr_0, svertex_wr_1, svertex_wr_2;
  wire svertex_valid, svertex_wr_en, svertex_clr;

  triangle_ram #(
      .TRI_COUNT(TRI_COUNT),
      .VERTEX_W (SCREEN_VERT_W),
      .ADDR_W   (TRI_ADDR_W)
  ) svertex_ram (
      .clk    (clk),
      .clr    (state == IDLE),
      .rd_addr(svertex_rd_addr),
      .v0_o   (svertex_rd_0),
      .v1_o   (svertex_rd_1),
      .v2_o   (svertex_rd_2),
      .valid_o(svertex_valid),
      .wr_en  (svertex_wr_en),
      .wr_addr(svertex_wr_addr),
      .v0_i   (svertex_wr_0),
      .v1_i   (svertex_wr_1),
      .v2_i   (svertex_wr_2)
  );


  wire [VCOL_W-1:0] scol_rd_0, scol_rd_1, scol_rd_2;
  wire [VCOL_W-1:0] scol_wr_0, scol_wr_1, scol_wr_2;
  wire scol_valid;
  triangle_ram #(
      .TRI_COUNT(TRI_COUNT),
      .VERTEX_W (VCOL_W),
      .ADDR_W   (TRI_ADDR_W)
  ) scol_ram (
      .clk    (clk),
      .clr    (state == IDLE),
      .rd_addr(svertex_rd_addr),
      .v0_o   (scol_rd_0),
      .v1_o   (scol_rd_1),
      .v2_o   (scol_rd_2),
      .valid_o(scol_valid),
      .wr_en  (svertex_wr_en),
      .wr_addr(svertex_wr_addr),
      .v0_i   (scol_wr_0),
      .v1_i   (scol_wr_1),
      .v2_i   (scol_wr_2)
  );

  //Note: Currently unused, automatically removed during synthesis and implementation
  wire [WORLD_W-1:0] wpos_rd_0, wpos_rd_1, wpos_rd_2;
  wire [WORLD_W-1:0] wpos_wr_0, wpos_wr_1, wpos_wr_2;
  wire wpos_valid;
  triangle_ram #(
      .TRI_COUNT(TRI_COUNT),
      .VERTEX_W (WORLD_W),
      .ADDR_W   (TRI_ADDR_W)
  ) wpos_ram (
      .clk    (clk),
      .clr    (state == IDLE),
      .rd_addr(svertex_rd_addr),
      .v0_o   (wpos_rd_0),
      .v1_o   (wpos_rd_1),
      .v2_o   (wpos_rd_2),
      .valid_o(wpos_valid),
      .wr_en  (svertex_wr_en),
      .wr_addr(svertex_wr_addr),
      .v0_i   (wpos_wr_0),
      .v1_i   (wpos_wr_1),
      .v2_i   (wpos_wr_2)
  );
  wire [INV_AREA_W-1:0] inv_area_rd;
  wire [INV_AREA_W-1:0] inv_area_wr;
  dp_single_ram #(
      .ADDR_W(TRI_ADDR_W),
      .DATA_W(INV_AREA_W),
      .DEPTH (TRI_COUNT)
  ) inv_area_ram (
      .clk  (clk),
      .raddr(svertex_rd_addr),
      .din  (inv_area_wr),
      .we   (svertex_wr_en),
      .waddr(svertex_wr_addr),
      .dout (inv_area_rd)
  );

  wire [NORMAL_W*3-1:0] normal_rd, normal_wr;
  dp_single_ram #(
      .ADDR_W(TRI_ADDR_W),
      .DATA_W(NORMAL_W * 3),
      .DEPTH (TRI_COUNT)
  ) normal_ram (
      .clk  (clk),
      .raddr(svertex_rd_addr),
      .din  (normal_wr),
      .we   (svertex_wr_en),
      .waddr(svertex_wr_addr),
      .dout (normal_rd)
  );

  wire input_valid, input_last, input_ready;
  wire inv_area_ready_i;
  assign s_axis_tready = inv_area_ready_i && state == CLEAR;
  inv_area #(
      .VPOS_W            (SCREEN_VERT_W),
      .VCOL_W            (VCOL_W),
      .INV_AREA_W        (INV_AREA_W),
      .INV_AREA_FRAC_BITS(INV_AREA_FRAC_BITS),
      .WORLD_W           (WORLD_W),
      .NORMAL_W          (NORMAL_W),
      .SCREEN_XY_W       (SCREEN_XY_W)
  ) inv_area_inst (

      .clk(clk),
      .rst(rst),

      .pos0_i  (tri_pos0_i),
      .pos1_i  (tri_pos1_i),
      .pos2_i  (tri_pos2_i),
      .col0_i  (tri_col0_i),
      .col1_i  (tri_col1_i),
      .col2_i  (tri_col2_i),
      .wpos0_i (tri_wpos0_i),
      .wpos1_i (tri_wpos1_i),
      .wpos2_i (tri_wpos2_i),
      .n_i     (tri_normal_i),
      .tvalid_i(s_axis_tvalid),
      .tlast_i (s_axis_tlast),
      .tready_i(inv_area_ready_i),

      .pos0    (svertex_wr_0),
      .pos1    (svertex_wr_1),
      .pos2    (svertex_wr_2),
      .col0    (scol_wr_0),
      .col1    (scol_wr_1),
      .col2    (scol_wr_2),
      .inv_area(inv_area_wr),
      .tvalid  (input_valid),
      .tlast   (input_last),
      .tready  (input_ready),
      .wpos0   (wpos_wr_0),
      .wpos1   (wpos_wr_1),
      .wpos2   (wpos_wr_2),
      .n       (normal_wr)
  );



  wire [     TRI_ADDR_W-1:0] tile_bin_rd;
  wire [     TRI_ADDR_W-1:0] tile_bin_write;

  wire [TILE_BIN_ADDR_W-1:0] tile_bin_addr;
  wire                       tile_bin_wr_en;

  single_ram #(
      .ADDR_W(TILE_BIN_ADDR_W),
      .DATA_W(TRI_ADDR_W),
      .DEPTH (NUM_TILES * MAX_TRI_PER_TILE)
  ) tile_bins (
      .clk (clk),
      .addr(tile_bin_addr),
      .din (tile_bin_write),
      .we  (tile_bin_wr_en),
      .dout(tile_bin_rd)
  );


  wire [TILE_COUNT_DW-1:0] tile_count_rd;
  wire [TILE_COUNT_DW-1:0] tile_count_write;

  wire [ TILE_COUNT_W-1:0] tile_count_addr;
  wire                     tile_count_wr_en;

  single_ram #(
      .ADDR_W(TILE_COUNT_W),
      .DATA_W(TILE_COUNT_DW),
      .DEPTH (NUM_TILES)
  ) tile_counts (
      .clk (clk),
      .addr(tile_count_addr),
      .din (tile_count_write),
      .we  (tile_count_wr_en),
      .dout(tile_count_rd)
  );


  wire                       tile_divide_done;

  wire [   TILE_COUNT_W-1:0] td_tile_addr;
  wire [TILE_BIN_ADDR_W-1:0] td_bin_addr;
  wire [  TILE_COUNT_DW-1:0] td_tile_count_write;
  wire                       td_tile_count_wr_en;
  wire                       td_tile_bin_wr_en;
  reg                        divide_start;
  reg                        divide_start_d;
  always @(posedge clk) begin
    divide_start_d <= divide_start;
  end
  tile_divide #(
      .HRES            (HRES),
      .VRES            (VRES),
      .TILE_SIZE       (TILE_SIZE),
      .TRI_ID_W        (TRI_ADDR_W),
      .VERTEX_W        (SCREEN_XY_W),
      .VERTEX_FRAC_BITS(SCREEN_XY_FRAC_BITS),
      .MAX_TRI_PER_TILE(MAX_TRI_PER_TILE)
  ) tile_divide_inst (
      .clk  (clk),
      .reset(rst),
      .start(divide_start_d),

      .triangle_id(svertex_rd_addr),

      .v0x(svertex_rd_0[SCREEN_XY_W-1:0]),
      .v0y(svertex_rd_0[2*SCREEN_XY_W-1:SCREEN_XY_W]),
      .v1x(svertex_rd_1[SCREEN_XY_W-1:0]),
      .v1y(svertex_rd_1[2*SCREEN_XY_W-1:SCREEN_XY_W]),
      .v2x(svertex_rd_2[SCREEN_XY_W-1:0]),
      .v2y(svertex_rd_2[2*SCREEN_XY_W-1:SCREEN_XY_W]),

      .tile_addr     (td_tile_addr),
      .tile_count_in (tile_count_rd),
      .tile_count_out(td_tile_count_write),
      .tile_count_we (td_tile_count_wr_en),

      .bin_addr(td_bin_addr),
      .bin_data(tile_bin_write),
      .bin_we  (td_tile_bin_wr_en),

      .done(tile_divide_done)
  );


  reg  [$clog2(NUM_TILES)-1:0] tile_counter;
  reg  [$clog2(TRI_COUNT)-1:0] tri_index;

  reg  [     $clog2(HRES)-1:0] rast_tile_x;
  reg  [     $clog2(VRES)-1:0] rast_tile_y;


  wire [  TILE_BIN_ADDR_W-1:0] raster_bin_addr;

  assign raster_bin_addr = {tile_counter, tri_index[$clog2(MAX_TRI_PER_TILE)-1:0]};

  assign tile_count_write = (state == CLEAR) ? 0 : td_tile_count_write;

  assign tile_count_addr =
        (state == CLEAR)  ? clear_index :
        (state == DIVIDE) ? (tile_divide_done ? 0 : td_tile_addr) :
        (state == RASTER) ? tile_counter :
        0;

  assign tile_count_wr_en = (state == CLEAR) ? 1'b1 : (state == DIVIDE) ? td_tile_count_wr_en : 1'b0;

  assign tile_bin_addr = state_divide ? td_bin_addr : state_raster ? raster_bin_addr : {TILE_BIN_ADDR_W{1'b0}};

  assign tile_bin_wr_en = state_divide ? td_tile_bin_wr_en : 1'b0;

  assign svertex_rd_addr = state_raster ? tile_bin_rd : tri_index;



  wire tri_done;
  wire tile_first;
  wire tile_last;
  assign tile_first = (tri_index == 0);
  assign tile_last  = (tri_index == tile_count_rd - 1) || (tile_count_rd == 0);
  reg end_pending;
  rast_frag_tile #(
      .HRES              (HRES),
      .VRES              (VRES),
      .TILE_SIZE         (TILE_SIZE),
      .VERTEX_W          (SCREEN_XY_W),
      .VERTEX_FRAC_BITS  (SCREEN_XY_FRAC_BITS),
      .VCOL_W            (VCOL_W),
      .INV_AREA_W        (INV_AREA_W),
      .INV_AREA_FRAC_BITS(INV_AREA_FRAC_BITS),
      .SCREEN_Z_W        (SCREEN_Z_W),
      .SCREEN_Z_FRAC_BITS(SCREEN_Z_FRAC_BITS),
      .WORLD_W           (WORLD_W),
      .WORLD_FRAC_BITS   (WORLD_FRAC_BITS),
      .NORMAL_W          (NORMAL_W),
      .NORMAL_FRAC_BITS  (NORMAL_FRAC_BITS)
  ) rast_frag_inst (
      .clk             (clk),
      .rst             (rst),
      .valid_in        (state_raster && !end_pending),
      .tile_empty      (tile_count_rd == 0),
      .tri_done        (tri_done),
      .inv_area        (inv_area_rd),
      .v0x             (svertex_rd_0[SCREEN_XY_W-1:0]),
      .v0y             (svertex_rd_0[2*SCREEN_XY_W-1:SCREEN_XY_W]),
      .v1x             (svertex_rd_1[SCREEN_XY_W-1:0]),
      .v1y             (svertex_rd_1[2*SCREEN_XY_W-1:SCREEN_XY_W]),
      .v2x             (svertex_rd_2[SCREEN_XY_W-1:0]),
      .v2y             (svertex_rd_2[2*SCREEN_XY_W-1:SCREEN_XY_W]),
      .v0z             (svertex_rd_0[2*SCREEN_XY_W+SCREEN_Z_W-1 : 2*SCREEN_XY_W]),
      .v1z             (svertex_rd_1[2*SCREEN_XY_W+SCREEN_Z_W-1 : 2*SCREEN_XY_W]),
      .v2z             (svertex_rd_2[2*SCREEN_XY_W+SCREEN_Z_W-1 : 2*SCREEN_XY_W]),
      .col0            (scol_rd_0),
      .col1            (scol_rd_1),
      .col2            (scol_rd_2),
      .tile_x          (rast_tile_x),
      .tile_y          (rast_tile_y),
      .tile_first      (tile_first),
      .tile_last       (tile_last),
      .tile_valid      (tile_valid),
      .tile_addr_offset(tile_addr_offset),
      .tile_data       (tile_data),
      .tile_ready      (tile_ready),
      .wpos0           (wpos_rd_0),
      .wpos1           (wpos_rd_1),
      .wpos2           (wpos_rd_2),
      .n               (normal_rd),
      .light           (light_dir),
      .ambient         (ambient)
  );

  //FSM

  reg                       frame_done_trig;

  reg [$clog2(TRI_COUNT):0] in_w_count;
  reg                       in_w_done;
  assign svertex_wr_addr = in_w_count;
  assign svertex_wr_en   = input_valid && !in_w_done && state == CLEAR && (in_w_count < TRI_COUNT);
  assign input_ready     = state == CLEAR && !in_w_done;
  always @(posedge clk) begin
    if (frame_done) frame_done_trig <= 1;
    if (rst) begin
      state           <= IDLE;
      tile_counter    <= 0;
      tri_index       <= 0;
      rast_tile_x     <= 0;
      rast_tile_y     <= 0;
      end_pending     <= 0;
      frame_done_trig <= 0;
      in_w_count      <= 0;
      in_w_done       <= 0;
    end else
      case (state)

        IDLE:
        if (start) begin
          state       <= CLEAR;
          clear_index <= 0;
          in_w_count  <= 0;
          in_w_done   <= 0;
          tri_index   <= 0;

        end
        CLEAR: begin
          if (input_ready && input_valid) begin
            in_w_count <= in_w_count + 1;
            in_w_done  <= input_last;
          end
          if (clear_index < NUM_TILES) begin
            clear_index <= clear_index + 1;
          end else if (in_w_done) begin
            state        <= DIVIDE;
            tri_index    <= 0;
            divide_start <= 1;
          end
        end

        DIVIDE: begin
          divide_start <= 0;
          if (tile_divide_done) begin
            if (tri_index + 1 < in_w_count) begin
              tri_index    <= tri_index + 1;
              divide_start <= 1;
            end else begin
              tile_counter <= 0;
              tri_index    <= 0;
              state        <= RASTER;
            end
          end
        end

        RASTER: begin
          if (!end_pending && tri_done) begin
            if (tri_index + 1 < tile_count_rd) tri_index <= tri_index + 1;
            else begin
              tri_index <= 0;
              if (tile_counter == NUM_TILES - 1) begin
                end_pending <= 1;
              end else begin
                tile_counter <= tile_counter + 1;
                rast_tile_x  <= (rast_tile_x + TILE_SIZE == HRES) ? 0 : rast_tile_x + TILE_SIZE;
                rast_tile_y  <= (rast_tile_x + TILE_SIZE == HRES) ? rast_tile_y + TILE_SIZE : rast_tile_y;
              end
            end
          end
          if (frame_done) begin
            state           <= IDLE;
            rast_tile_x     <= 0;
            rast_tile_y     <= 0;
            frame_done_trig <= 0;
            end_pending     <= 0;
            tile_counter    <= 0;
          end

        end

      endcase

  end


  assign state_o           = state;
  assign tile_counter_o    = tile_counter;
  assign tri_index_o       = tri_index;
  assign rast_tile_x_o     = rast_tile_x;
  assign rast_tile_y_o     = rast_tile_y;
  assign frag_tile_start_o = tile_first;
  assign frag_tile_done_o  = tile_last;
  localparam LAST_PIXEL_ADDR = 4 * (HRES * VRES - 1);
  assign frame_done = (tile_addr_offset == LAST_PIXEL_ADDR) && tile_valid;

endmodule
