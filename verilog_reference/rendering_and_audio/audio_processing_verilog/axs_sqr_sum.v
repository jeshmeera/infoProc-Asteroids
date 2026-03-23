`timescale 1ns / 1ps


module axis_sqr_sum #(
    parameter integer DATA_WIDTH    = 32,
    parameter integer ADD_ACC_WIDTH = 8,
    parameter integer BAND0_LIM     = 32,
    parameter integer BAND1_LIM     = 128,
    parameter integer BAND2_LIM     = 256,
    parameter integer BAND3_LIM     = 512
) (
    input wire aclk,
    input wire aresetn,

    output reg                     s_axis_tready,
    input  wire [DATA_WIDTH-1 : 0] s_axis_tdata,
    input  wire                    s_axis_tlast,
    input  wire                    s_axis_tvalid,

    output reg                     m_axis_tvalid,
    output reg  [DATA_WIDTH-1 : 0] m_axis_tdata,
    output reg                     m_axis_tlast,
    input  wire                    m_axis_tready,

    output reg [DATA_WIDTH-1:0] band0_energy_o,
    output reg [DATA_WIDTH-1:0] band1_energy_o,
    output reg [DATA_WIDTH-1:0] band2_energy_o,
    output reg [DATA_WIDTH-1:0] band3_energy_o,

    output reg [DATA_WIDTH-1:0] peak_o,
    output reg [DATA_WIDTH-1:0] peak_ind_o
);

  reg         [DATA_WIDTH+ADD_ACC_WIDTH-1:0] band0_energy;
  reg         [DATA_WIDTH+ADD_ACC_WIDTH-1:0] band1_energy;
  reg         [DATA_WIDTH+ADD_ACC_WIDTH-1:0] band2_energy;
  reg         [DATA_WIDTH+ADD_ACC_WIDTH-1:0] band3_energy;
  reg         [       $clog2(BAND3_LIM)-1:0] bin_index;
  reg         [              DATA_WIDTH-1:0] peak;
  reg         [              DATA_WIDTH-1:0] peak_ind;


  reg                                        next_m_axis_tvalid;
  reg                                        next_m_axis_tlast;

  reg signed  [              DATA_WIDTH-1:0] real_square;
  reg signed  [              DATA_WIDTH-1:0] imag_square;

  wire signed [            DATA_WIDTH/2-1:0] real_in;
  wire signed [            DATA_WIDTH/2-1:0] imag_in;
  assign real_in = s_axis_tdata[DATA_WIDTH-1:DATA_WIDTH/2];
  assign imag_in = s_axis_tdata[DATA_WIDTH/2-1:0];

  wire [DATA_WIDTH-1:0] mag_sq;
  assign mag_sq = real_square + imag_square;

  //assign band0_energy_o = band0_energy[DATA_WIDTH+ADD_ACC_WIDTH-1:ADD_ACC_WIDTH];
  //assign band1_energy_o = band1_energy[DATA_WIDTH+ADD_ACC_WIDTH-1:ADD_ACC_WIDTH];
  //assign band2_energy_o = band2_energy[DATA_WIDTH+ADD_ACC_WIDTH-1:ADD_ACC_WIDTH];
  //assign band3_energy_o = band3_energy[DATA_WIDTH+ADD_ACC_WIDTH-1:ADD_ACC_WIDTH];

  always @(posedge aclk) begin
    if (aresetn == 0) begin
      s_axis_tready  <= 0;

      m_axis_tvalid  <= 0;
      m_axis_tlast   <= 0;
      m_axis_tdata   <= 0;
      bin_index      <= 0;

      band0_energy   <= 0;
      band1_energy   <= 0;
      band2_energy   <= 0;
      band3_energy   <= 0;

      band0_energy_o <= 0;
      band1_energy_o <= 0;
      band2_energy_o <= 0;
      band3_energy_o <= 0;
      peak           <= 0;
      peak_ind       <= 0;
      peak_o         <= 0;
      peak_ind_o     <= 0;

    end else begin
      s_axis_tready      <= m_axis_tready;

      next_m_axis_tvalid <= s_axis_tvalid;
      next_m_axis_tlast  <= s_axis_tlast;
      real_square        <= real_in * real_in;
      imag_square        <= imag_in * imag_in;
      m_axis_tvalid      <= next_m_axis_tvalid;
      m_axis_tlast       <= next_m_axis_tlast;
      m_axis_tdata       <= mag_sq;

      if (s_axis_tvalid && m_axis_tready) begin

        if (mag_sq > peak) begin
          peak     <= mag_sq;
          peak_ind <= bin_index;
        end

        if (bin_index < BAND0_LIM) band0_energy <= band0_energy + mag_sq;
        else if (bin_index < BAND1_LIM) band1_energy <= band1_energy + mag_sq;
        else if (bin_index < BAND2_LIM) band2_energy <= band2_energy + mag_sq;
        else if (bin_index < BAND3_LIM) band3_energy <= band3_energy + mag_sq;
        if (s_axis_tlast) begin
          bin_index      <= 0;
          peak           <= 0;
          peak_ind       <= 0;
          band0_energy   <= 0;
          band1_energy   <= 0;
          band2_energy   <= 0;
          band3_energy   <= 0;
          band0_energy_o <= band0_energy[DATA_WIDTH+ADD_ACC_WIDTH-1:ADD_ACC_WIDTH];
          band1_energy_o <= band1_energy[DATA_WIDTH+ADD_ACC_WIDTH-1:ADD_ACC_WIDTH];
          band2_energy_o <= band2_energy[DATA_WIDTH+ADD_ACC_WIDTH-1:ADD_ACC_WIDTH];
          band3_energy_o <= band3_energy[DATA_WIDTH+ADD_ACC_WIDTH-1:ADD_ACC_WIDTH];
          peak_o         <= peak;
          peak_ind_o     <= peak_ind;

        end else bin_index <= bin_index + 1;
      end


    end
  end
endmodule

