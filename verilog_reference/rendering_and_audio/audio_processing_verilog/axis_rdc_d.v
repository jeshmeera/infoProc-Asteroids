`timescale 1ns / 1ps
module axis_rdc_d #(
    parameter DATA_WIDTH  = 32,
    parameter PACKET_SIZE = 1024
) (
    input  wire                  clk,
    input  wire                  rst,
    input  wire                  out_en,
    output wire [DATA_WIDTH-1:0] outcnt_o,

    output reg [DATA_WIDTH-1:0] mean_o,

    input  wire [    DATA_WIDTH-1:0] s_axis_tdata,
    input  wire                      s_axis_tvalid,
    output wire                      s_axis_tready,
    input  wire [(DATA_WIDTH/8)-1:0] s_axis_tkeep,
    input  wire                      s_axis_tlast,

    output reg  [    DATA_WIDTH-1:0] m_axis_tdata,
    output reg                       m_axis_tvalid,
    input  wire                      m_axis_tready,
    output wire [(DATA_WIDTH/8)-1:0] m_axis_tkeep,
    output wire                      m_axis_tlast
);


  reg signed [47:0] sum;

  localparam IDLE = 0, PLAYBACK = 1;

  reg        [                      1:0] state;

  reg signed [           DATA_WIDTH-1:0] input_buffer [0:(2*PACKET_SIZE)-1];
  reg                                    sel_buffer;
  reg        [    $clog2(PACKET_SIZE):0] input_count;
  reg        [    $clog2(PACKET_SIZE):0] output_count;

  wire       [$clog2(2*PACKET_SIZE)-1:0] wr_addr;
  wire       [$clog2(2*PACKET_SIZE)-1:0] rd_addr;
  wire                                   next_valid;

  assign next_valid   = state == PLAYBACK && out_en && !(fire_output && last_output);
  assign m_axis_tkeep = 4'b1111;
  assign wr_addr      = sel_buffer ? (input_count + PACKET_SIZE) : input_count;
  assign rd_addr      = (!sel_buffer) ? (output_count + PACKET_SIZE) : output_count;
  wire fire_input;
  wire fire_output;
  wire last_input;
  wire last_output;
  assign fire_input    = s_axis_tvalid && s_axis_tready;
  assign last_input    = fire_input && (input_count == PACKET_SIZE - 1);
  assign fire_output   = m_axis_tvalid && m_axis_tready;
  assign last_output   = (output_count == PACKET_SIZE - 1);
  assign m_axis_tlast  = m_axis_tvalid && last_output;
  assign s_axis_tready = (input_count < PACKET_SIZE);
  assign outcnt_o      = output_count;
  always @(posedge clk) begin
    //Slave
    if (rst) begin
      input_count <= 0;
      sum         <= 0;
    end else if (fire_input) begin
      input_buffer[wr_addr] <= s_axis_tdata;
      sum                   <= sum + $signed(s_axis_tdata);
      input_count           <= input_count + 1;
      if (last_input) begin
        sum <= 0;
        if (state != PLAYBACK) begin
          sel_buffer  <= !sel_buffer;
          mean_o      <= (sum + $signed(s_axis_tdata)) / PACKET_SIZE;
          input_count <= 0;
        end
      end
    end

    //Master logic
    if (rst) begin
      m_axis_tvalid <= 0;
      m_axis_tdata  <= 0;
    end else if (!m_axis_tvalid || m_axis_tready) begin
      m_axis_tvalid <= next_valid;
      m_axis_tdata  <= input_buffer[rd_addr] - mean_o;
    end

    if (rst) begin
      state        <= IDLE;
      output_count <= 0;
    end else begin
      case (state)
        IDLE: begin
          if (last_input) begin
            state <= PLAYBACK;
          end
        end
        PLAYBACK: begin
          if (fire_output) begin
            if (last_output) begin
              output_count <= 0;
              state        <= IDLE;
            end else output_count <= output_count + 1;
          end
        end
      endcase
    end
  end

endmodule




