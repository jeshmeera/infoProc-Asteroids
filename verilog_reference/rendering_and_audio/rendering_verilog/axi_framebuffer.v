`timescale 1ns / 1ps
module axi_framebuffer #(
    parameter FB0_BASE = 32'h01000000,
    parameter FB1_BASE = 32'h02000000,
    parameter FB2_BASE = 32'h03000000,
    parameter HRES     = 1280,
    parameter VRES     = 720,
    parameter STRIDE   = 5120
) (
    input  wire        clk,
    input  wire        aresetn,
    //debug outputs
    output wire [15:0] outstanding_o,
    output wire [10:0] fifo_data_count_o,
    output reg         fifo_drop,
    output wire        frame_done_trig_o,
    output wire        frame_out_trig_o,
    output reg  [32:0] num_handshakes_o,
    output wire [ 1:0] wstate_o,
    output wire [ 1:0] fidx_o,
    output wire [ 1:0] widx_o,
    output wire [ 1:0] ridx_o,

    input  wire        frame_out,
    //Frame output stream
    output wire [23:0] m_axis_tdata,
    output wire        m_axis_tvalid,
    input  wire        m_axis_tready,
    output wire        m_axis_tlast,
    output wire [ 0:0] m_axis_tuser,
    //AXI
    output wire [31:0] M_AXI_AWID,
    output reg  [31:0] M_AXI_AWADDR,
    output wire [ 7:0] M_AXI_AWLEN,
    output wire [ 2:0] M_AXI_AWSIZE,
    output wire [ 1:0] M_AXI_AWBURST,
    output reg         M_AXI_AWVALID,
    input  wire        M_AXI_AWREADY,

    output wire         M_AXI_AWLOCK,
    output wire [3 : 0] M_AXI_AWCACHE,
    output wire [2 : 0] M_AXI_AWPROT,
    output wire [3 : 0] M_AXI_AWQOS,
    input  wire [1 : 0] M_AXI_RRESP,

    output wire [31:0] M_AXI_WDATA,
    output wire        M_AXI_WVALID,
    output wire        M_AXI_WLAST,
    input  wire        M_AXI_WREADY,

    output wire [3 : 0] M_AXI_WSTRB,

    input  wire [31 : 0] M_AXI_BID,
    input  wire [   1:0] M_AXI_BRESP,
    input  wire          M_AXI_BVALID,
    output reg           M_AXI_BREADY,

    output wire [31 : 0] M_AXI_ARID,
    output reg  [  31:0] M_AXI_ARADDR,
    output reg  [   7:0] M_AXI_ARLEN,
    output wire [   2:0] M_AXI_ARSIZE,
    output wire [   1:0] M_AXI_ARBURST,
    output reg           M_AXI_ARVALID,
    input  wire          M_AXI_ARREADY,

    output wire         M_AXI_ARLOCK,
    output wire [2 : 0] M_AXI_ARPROT,
    output wire [3 : 0] M_AXI_ARCACHE,
    output wire [3 : 0] M_AXI_ARQOS,

    input  wire [31 : 0] M_AXI_RID,
    input  wire [  31:0] M_AXI_RDATA,
    input  wire          M_AXI_RVALID,
    input  wire          M_AXI_RLAST,
    output wire          M_AXI_RREADY,
    //tile input
    input  wire          s_axis_tvalid,
    input  wire [  63:0] s_axis_tdata,
    input  wire          s_axis_tlast,
    output               s_axis_tready,
    //Allocated addresses
    input  wire [  31:0] all_addr0,
    input  wire [  31:0] all_addr1,
    input  wire [  31:0] all_addr2
);
  wire [31:0] tile_addr_offset = s_axis_tdata[63:32];
  wire [31:0] tile_data = s_axis_tdata[31:0];
  wire        tile_valid = s_axis_tvalid;
  wire        frame_done = s_axis_tlast;
  wire        tile_ready;
  assign s_axis_tready = tile_ready;


  localparam RBURST_LEN = 256;
  localparam RBURST_LEN_M1 = RBURST_LEN - 1;

  localparam WBURST_LEN = 16;
  assign M_AXI_AWID    = 'b0;
  assign M_AXI_AWLEN   = WBURST_LEN - 1;
  assign M_AXI_AWSIZE  = 3'b010;
  assign M_AXI_AWBURST = 2'b01;
  assign M_AXI_WSTRB   = {(32 / 8) {1'b1}};

  assign M_AXI_AWLOCK  = 1'b0;
  assign M_AXI_AWCACHE = 4'b0010;
  assign M_AXI_AWPROT  = 3'b0;
  assign M_AXI_AWQOS   = 4'h0;

  assign M_AXI_ARID    = 'b0;
  assign M_AXI_ARSIZE  = 3'b010;
  assign M_AXI_ARBURST = 2'b01;

  assign M_AXI_ARLOCK  = 1'b0;
  assign M_AXI_ARCACHE = 4'b0010;
  assign M_AXI_ARPROT  = 3'h0;
  assign M_AXI_ARQOS   = 4'h0;


  localparam FIFO_DEPTH = 2048;

  reg  [1:0] front_idx;
  reg  [1:0] write_idx;
  wire [1:0] ready_idx = 2'd3 - front_idx - write_idx;
  assign fidx_o = front_idx;
  assign widx_o = write_idx;
  assign ridx_o = ready_idx;
  wire uninit = (all_addr0 == all_addr1);
  function [31:0] fb_base;
    input [1:0] idx;
    begin
      case (idx)
        2'd0:    fb_base = uninit ? FB0_BASE : all_addr0;
        2'd1:    fb_base = uninit ? FB1_BASE : all_addr1;
        2'd2:    fb_base = uninit ? FB2_BASE : all_addr2;
        default: fb_base = uninit ? FB0_BASE : all_addr0;
      endcase
    end
  endfunction
  wire [31:0] front_base = fb_base(front_idx);
  wire [31:0] back_base = fb_base(write_idx);



  wire        fifo_full;
  wire        fifo_empty;


  reg start_burst_d2, start_burst_d1, ar_none_outstanding;
  wire        start_burst;
  reg  [15:0] ar_bursts_outstanding;
  assign outstanding_o = ar_bursts_outstanding;

  reg issue_hlast, issue_vlast;
  reg [    15:0] issue_y_left;
  reg [16-2-1:0] issue_x_left;
  reg [31:0] issue_addr_offset, issue_line_start_addr_offset;
  wire [31:0] issue_addr, issue_line_start_addr;
  assign issue_addr            = front_base + issue_addr_offset;
  assign issue_line_start_addr = front_base + issue_line_start_addr_offset;
  //
  reg rd_hlast, rd_vlast;
  reg  [                  15:0] rd_y_left;
  reg  [              16-2-1:0] rd_x_left;
  //
  wire [$clog2(RBURST_LEN)-1:0] till_boundary = ~issue_addr[2+:$clog2(RBURST_LEN)];
  reg  [                  10:0] start_delay;


  wire                          issuing_last_burst = start_burst && issue_hlast && issue_vlast;
  reg                           frame_fully_issued;
  //
  reg                           frame_done_d;
  wire                          frame_done_pulse;
  assign frame_done_pulse  = (frame_done && !frame_done_d) && tile_valid;
  assign frame_done_trig_o = frame_done_pulse;
  always @(posedge clk) begin
    frame_fully_issued <= 0;
    if (!aresetn) frame_fully_issued <= 0;
    else if (issuing_last_burst) frame_fully_issued <= 1;
  end

  always @(posedge clk) begin
    frame_done_d <= frame_done && tile_ready;
  end
  reg framebuffer_valid;

  always @(posedge clk) begin
    if (!aresetn) framebuffer_valid <= 0;
    else if (frame_done_pulse) framebuffer_valid <= 1;
  end

  reg ready_valid;
  always @(posedge clk) begin
    if (!aresetn) begin
      write_idx   <= 1;
      ready_valid <= 0;
    end else if (frame_done_pulse) begin
      write_idx   <= ready_idx;
      ready_valid <= 1;
    end
    if (!aresetn) begin
      front_idx <= 0;
    end else if (ready_valid && frame_fully_issued) begin
      front_idx   <= ready_idx;
      ready_valid <= 0;
    end
  end

  reg soft_reset, r_err, r_stopped;
  //write section
  localparam W_IDLE = 0, W_ADDR = 1, W_DATA = 2, W_RESP = 3;
  reg [1:0] wstate;
  assign wstate_o = wstate;
  reg [31:0] tile_buf      [0:1] [0:WBURST_LEN-1];
  reg [31:0] burst_addr_buf[0:1];

  reg [ 3:0] fill_cnt;
  reg        fill_sel;
  reg        send_sel;
  reg [ 1:0] buf_full;
  reg        w_active;
  reg [ 3:0] beat_cnt;
  reg [ 3:0] buf_index;

  assign tile_ready   = !buf_full[fill_sel] && !soft_reset;
  assign M_AXI_WVALID = w_active;
  assign M_AXI_WDATA  = tile_buf[send_sel][buf_index];
  assign M_AXI_WLAST  = (beat_cnt == WBURST_LEN - 1);
  always @(posedge clk) begin
    if (!aresetn) begin
      wstate        <= W_IDLE;
      M_AXI_AWVALID <= 0;
      M_AXI_BREADY  <= 0;
      w_active      <= 0;
      fill_cnt      <= 0;
      fill_sel      <= 0;
      send_sel      <= 0;
      buf_full      <= 2'b00;
      beat_cnt      <= 0;
      buf_index     <= 0;
    end else begin

      if (tile_valid && tile_ready) begin
        tile_buf[fill_sel][fill_cnt] <= tile_data;
        if (fill_cnt == 0) burst_addr_buf[fill_sel] <= (tile_addr_offset & ~(WBURST_LEN * 4 - 1));
        if (fill_cnt == WBURST_LEN - 1) begin
          buf_full[fill_sel] <= 1'b1;
          fill_cnt           <= 0;
          fill_sel           <= ~fill_sel;
        end else begin
          fill_cnt <= fill_cnt + 1;
        end
      end

      case (wstate)

        W_IDLE: begin

          if (buf_full[0]) begin
            send_sel      <= 0;
            M_AXI_AWADDR  <= back_base + burst_addr_buf[0];
            M_AXI_AWVALID <= 1'b1;
            wstate        <= W_ADDR;
          end else if (buf_full[1]) begin
            send_sel      <= 1;
            M_AXI_AWADDR  <= back_base + burst_addr_buf[1];
            M_AXI_AWVALID <= 1'b1;
            wstate        <= W_ADDR;
          end

        end
        W_ADDR: begin
          if (M_AXI_AWVALID && M_AXI_AWREADY) begin
            M_AXI_AWVALID <= 0;
            beat_cnt      <= 0;
            buf_index     <= 0;
            w_active      <= 1;
            wstate        <= W_DATA;
          end
        end

        W_DATA: begin
          if (M_AXI_WVALID && M_AXI_WREADY) begin

            if (beat_cnt == WBURST_LEN - 1) begin
              w_active     <= 0;
              M_AXI_BREADY <= 1;
              wstate       <= W_RESP;
            end else begin
              beat_cnt  <= beat_cnt + 1;
              buf_index <= buf_index + 1;
            end

          end
        end

        W_RESP: begin
          if (M_AXI_BVALID) begin
            M_AXI_BREADY       <= 0;
            buf_full[send_sel] <= 0;
            send_sel           <= ~send_sel;
            wstate             <= W_IDLE;
          end
        end

      endcase
    end
  end

  //READ

  always @(posedge clk)
    if (~aresetn) begin
      start_delay <= 0;
      soft_reset  <= 1;
      r_err       <= 0;
    end else if (soft_reset) begin
      start_delay <= start_delay + 1;
      if (!r_err && r_stopped) soft_reset <= 0;  // && start_delay > 5
    end else begin
      //Ignore errors for now
      // if (M_AXI_RREADY && M_AXI_RVALID && M_AXI_RRESP[1]) begin
      //   // soft_reset <= 1;
      //   r_err <= 1;
      // end
    end

  always @(posedge clk)
    if (~aresetn) r_stopped <= 1;
    else if (r_stopped) r_stopped <= soft_reset;
    else if (soft_reset && ar_none_outstanding && !M_AXI_ARVALID) r_stopped <= 1;

  //FIFO
  reg                         sof;
  wire [                31:0] fifo_dout;
  wire [                31:0] fifo_din = {rd_vlast && rd_hlast, rd_hlast, 6'b0, M_AXI_RDATA[23:0]};
  wire                        fifo_wr_en = M_AXI_RVALID && M_AXI_RREADY && (ar_bursts_outstanding != 0);
  wire                        fifo_rd_en = m_axis_tvalid && m_axis_tready && !soft_reset;

  wire [$clog2(FIFO_DEPTH):0] fifo_data_count;
  wire [$clog2(FIFO_DEPTH):0] fifo_free_space = FIFO_DEPTH - fifo_data_count;
  wire                        no_fifo_space_available = (fifo_free_space < RBURST_LEN);
  assign fifo_data_count_o = fifo_data_count;

  always @(posedge clk)
    if (~aresetn) num_handshakes_o <= 0;
    else if (m_axis_tvalid && m_axis_tready) begin
      if (sof) num_handshakes_o <= 1;
      else num_handshakes_o <= num_handshakes_o + 1;
    end

  fifo_generator_0 fifo_inst (
      .clk       (clk),
      .srst      (~aresetn),
      .din       (fifo_din),
      .wr_en     (fifo_wr_en),
      .rd_en     (fifo_rd_en),
      .dout      (fifo_dout),
      .full      (fifo_full),
      .empty     (fifo_empty),
      .data_count(fifo_data_count)
  );

  always @(posedge clk)
    if (~aresetn || r_stopped) sof <= 1'b1;
    else if (m_axis_tvalid && m_axis_tready) sof <= fifo_dout[31];

  reg line_out_active;
  always @(posedge clk) begin
    if (~aresetn) line_out_active <= 0;
    else begin
      if (!line_out_active && fifo_data_count >= HRES) line_out_active <= 1;
      if (m_axis_tlast && m_axis_tvalid && m_axis_tready) line_out_active <= 0;
    end
  end

  assign m_axis_tvalid = !fifo_empty && line_out_active;
  assign m_axis_tdata  = fifo_dout[23:0];
  assign m_axis_tuser  = sof && m_axis_tvalid;
  assign m_axis_tlast  = fifo_dout[30] && m_axis_tvalid;

  assign M_AXI_RREADY  = !fifo_full && !soft_reset;


  //Count issued read addresses
  always @(posedge clk)
    if (~aresetn || r_stopped) begin
      issue_addr_offset            <= 0;
      issue_line_start_addr_offset <= 0;
      issue_x_left                 <= HRES;
      issue_y_left                 <= VRES - 1;
      issue_vlast                  <= 0;
    end else if (start_burst_d1) begin
      if (issue_hlast && issue_vlast) begin
        issue_addr_offset            <= 0;
        issue_line_start_addr_offset <= 0;
        issue_x_left                 <= HRES;
      end else if (issue_hlast) begin
        issue_addr_offset            <= issue_line_start_addr_offset + (STRIDE);
        issue_line_start_addr_offset <= issue_line_start_addr_offset + (STRIDE);
        issue_x_left                 <= HRES;
      end else begin
        issue_addr_offset <= issue_addr_offset + RBURST_LEN * 4;
        issue_x_left      <= issue_x_left - (M_AXI_ARLEN + 1);
      end

      if (issue_hlast)
        if (issue_vlast) begin
          issue_y_left <= VRES - 1;
          issue_vlast  <= 0;
        end else begin
          issue_y_left <= issue_y_left - 1;
          issue_vlast  <= (issue_y_left <= 1);
        end
    end

  //Count incoming
  always @(posedge clk)
    if (~aresetn || r_stopped) begin
      rd_x_left <= HRES - 1;
      rd_hlast  <= 0;
      rd_y_left <= VRES - 1;
      rd_vlast  <= 0;
    end else if (M_AXI_RVALID && M_AXI_RREADY) begin
      if (rd_hlast) begin
        rd_x_left <= HRES - 1;
        rd_hlast  <= (HRES <= 1);
        if (rd_vlast) begin
          rd_y_left <= VRES - 1;
          rd_vlast  <= 0;
        end else begin
          rd_y_left <= rd_y_left - 1;
          rd_vlast  <= (rd_y_left <= 1);
        end
      end else begin
        rd_x_left <= rd_x_left - 1;
        rd_hlast  <= (rd_x_left <= 1);
      end

    end
  //Start burst to be delayed by 2 cycles
  assign start_burst =
   !no_fifo_space_available &&
   !(start_burst_d1 || start_burst_d2) &&
   !(M_AXI_ARVALID && !M_AXI_ARREADY) &&
   !soft_reset
   && !frame_fully_issued && framebuffer_valid;// &&ar_bursts_outstanding <8;// && !frame_out_pulse;


  wire [8:0] burst_len = (issue_x_left < RBURST_LEN) ? issue_x_left : RBURST_LEN;
  wire [8:0] final_len = (burst_len <= till_boundary) ? burst_len : till_boundary;
  wire       rlast_fire = M_AXI_RVALID && M_AXI_RREADY && M_AXI_RLAST;
  reg  [8:0] max_burst;
  always @(posedge clk) begin
    if (~aresetn) begin
      start_burst_d1        <= 0;
      M_AXI_ARVALID         <= 0;
      ar_bursts_outstanding <= 0;
      ar_none_outstanding   <= 1;
      max_burst             <= RBURST_LEN;
    end else begin
      start_burst_d1 <= start_burst;

      if (!start_burst_d1 && rlast_fire) begin
        ar_bursts_outstanding <= ar_bursts_outstanding - 1;
        ar_none_outstanding   <= (ar_bursts_outstanding == 1);
      end else if (start_burst_d1 && !rlast_fire) begin
        ar_bursts_outstanding <= ar_bursts_outstanding + 1;
        ar_none_outstanding   <= 0;
      end

      if (!M_AXI_ARVALID || M_AXI_ARREADY) begin
        M_AXI_ARVALID <= start_burst;
        //M_AXI_ARLEN   <= final_len - 1;
        if (till_boundary > 0 && max_burst <= till_boundary) M_AXI_ARLEN <= max_burst - 1;
        else M_AXI_ARLEN <= till_boundary;
      end
    end

    if (start_burst) M_AXI_ARADDR <= issue_addr[31:0];
    M_AXI_ARADDR[1:0] <= 0;
    if (start_burst_d2) begin
      if (issue_x_left >= RBURST_LEN) max_burst <= RBURST_LEN;
      else max_burst <= issue_x_left;
    end
    if (~aresetn || r_stopped) start_burst_d2 <= 1;
    else start_burst_d2 <= start_burst_d1;

    if (start_burst_d2 || start_burst) begin
      issue_hlast <= 1;
      if (issue_x_left > till_boundary + 1) issue_hlast <= 0;
      if (issue_x_left > max_burst) issue_hlast <= 0;
    end
  end

endmodule




