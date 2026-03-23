`timescale 1ns / 1ps
module axis_dec_d #(
    parameter DATA_WIDTH  = 32,
    parameter PACKET_SIZE = 1024
) (
    input wire clk,
    input wire rst,
    input wire out_en,

    // Input samples
    input wire                         pcm_valid_in,
    input wire signed [DATA_WIDTH-1:0] pcm_data_in,

    // AXI-Stream output
    output reg  [    DATA_WIDTH-1:0] m_axis_tdata,
    output reg                       m_axis_tvalid,
    input  wire                      m_axis_tready,
    output wire                      m_axis_tlast,
    output wire [(DATA_WIDTH/8)-1:0] m_axis_tkeep,

    output reg [DATA_WIDTH-1:0] sent_c
);

  // Fraction = 32 / 39
  localparam integer NUM = 32;
  localparam integer DEN = 39;

  reg         [                  7:0] phase;
  reg signed  [                 47:0] sum;
  reg         [                  7:0] count;

  reg         [$clog2(PACKET_SIZE):0] packet_count;

  wire signed [       DATA_WIDTH-1:0] decimated_sample;
  reg signed  [       DATA_WIDTH-1:0] next_data;
  reg                                 sample_ready;

  assign decimated_sample = (count != 0) ? (sum / count) : pcm_data_in;
  assign m_axis_tkeep     = {(DATA_WIDTH / 8) {1'b1}};
  assign m_axis_tlast     = m_axis_tvalid && (packet_count == PACKET_SIZE - 1);
  always @(posedge clk) begin
    if (rst) begin
      phase         <= 0;
      sum           <= 0;
      count         <= 0;

      m_axis_tvalid <= 0;
      m_axis_tdata  <= 0;
      //m_axis_tlast   <= 0;

      packet_count  <= 0;
      sample_ready  <= 0;

      sent_c        <= 0;
    end else begin
      //m_axis_tlast <= 0;


      if (pcm_valid_in) begin
        sum   <= sum + pcm_data_in;
        count <= count + 1;

        if (phase + NUM >= DEN) begin
          phase        <= phase + NUM - DEN;
          sample_ready <= 1;
          next_data    <= decimated_sample;
        end else begin
          phase <= phase + NUM;
        end
      end


      if (sample_ready) begin
        if (!m_axis_tvalid || m_axis_tready) begin
          m_axis_tdata  <= next_data;
          m_axis_tvalid <= out_en;

          sample_ready  <= 0;
        end
        sum   <= 0;
        count <= 0;
      end


      //            if (m_axis_tvalid && !m_axis_tready) begin
      //                m_axis_tvalid <= m_axis_tvalid;
      //            end else 
      if (m_axis_tvalid && m_axis_tready) begin
        // Transfer completed
        m_axis_tvalid <= 0;
        sent_c        <= sent_c + 1;
        if (m_axis_tlast) begin
          packet_count <= 0;
        end else begin
          packet_count <= packet_count + 1;
        end
      end

    end
  end

endmodule


