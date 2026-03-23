`timescale 1ns / 1ps
module axis_hamming_1024 #(
    parameter integer DATA_WIDTH  = 16,
    parameter integer COEFF_WIDTH = 16
) (
    input wire aclk,
    input wire aresetn,

    input  wire                  s_axis_tvalid,
    input  wire [DATA_WIDTH-1:0] s_axis_tdata,
    input  wire                  s_axis_tlast,
    output reg                   s_axis_tready,

    output reg                   m_axis_tvalid,
    output reg  [DATA_WIDTH-1:0] m_axis_tdata,
    output reg                   m_axis_tlast,
    input  wire                  m_axis_tready
);

  reg         [            9:0] index;

  wire signed [COEFF_WIDTH-1:0] hamming_coeff;

  hamming_rom_1024 coeff_rom (
      .clk  (aclk),
      .addr (index),
      .coeff(hamming_coeff)
  );

  wire signed [DATA_WIDTH-1:0] sample_in;
  assign sample_in = s_axis_tdata;

  wire signed [DATA_WIDTH+COEFF_WIDTH-1:0] mult_full;
  assign mult_full = sample_in * hamming_coeff;

  wire signed [DATA_WIDTH-1:0] mult_scaled;
  assign mult_scaled = mult_full >>> 15;

  always @(posedge aclk) begin
    if (!aresetn) begin
      index         <= 0;
      s_axis_tready <= 0;
      m_axis_tvalid <= 0;
      m_axis_tdata  <= 0;
      m_axis_tlast  <= 0;
    end else begin
      s_axis_tready <= m_axis_tready;

      if (s_axis_tvalid && m_axis_tready) begin
        m_axis_tvalid <= 1;
        m_axis_tdata  <= mult_scaled;
        m_axis_tlast  <= s_axis_tlast;

        if (s_axis_tlast) index <= 0;
        else index <= index + 1;
      end else begin
        m_axis_tvalid <= 0;
      end
    end
  end

endmodule

