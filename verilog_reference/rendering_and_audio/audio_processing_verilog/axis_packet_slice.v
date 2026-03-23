`timescale 1ns / 1ps

module axis_packet_slice #(
    parameter integer DATA_WIDTH    = 32,
    parameter integer KEEP_BEATS    = 512,
    parameter integer PACKET_LENGTH = 1024
) (
    input wire aclk,
    input wire aresetn,


    input  wire [    DATA_WIDTH-1:0] s_axis_tdata,
    input  wire                      s_axis_tvalid,
    output wire                      s_axis_tready,
    input  wire                      s_axis_tlast,
    input  wire [(DATA_WIDTH/8)-1:0] s_axis_tkeep,


    output reg  [    DATA_WIDTH-1:0] m_axis_tdata,
    output reg                       m_axis_tvalid,
    input  wire                      m_axis_tready,
    output wire                      m_axis_tlast,
    output wire [(DATA_WIDTH/8)-1:0] m_axis_tkeep
);

  localparam COUNT_WIDTH = $clog2(PACKET_LENGTH);

  reg  [COUNT_WIDTH-1:0] beat_count;

  wire                   handshake = s_axis_tvalid && s_axis_tready;

  assign s_axis_tready = (beat_count >= KEEP_BEATS) || m_axis_tready;
  assign m_axis_tlast  = m_axis_tvalid && (beat_count == KEEP_BEATS - 1);
  assign m_axis_tkeep  = s_axis_tkeep;
  always @(posedge aclk) begin
    if (!aresetn) begin
      beat_count    <= 0;
      m_axis_tvalid <= 0;
    end else begin
      m_axis_tvalid <= 0;
      if (handshake) begin
        if (beat_count < KEEP_BEATS) begin
          m_axis_tdata  <= s_axis_tdata;
          m_axis_tvalid <= 1;
        end
        if (s_axis_tlast) beat_count <= 0;
        else beat_count <= beat_count + 1;

      end
    end
  end

endmodule

