`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 25.02.2026 17:04:39
// Design Name: 
// Module Name: frame_differencing
// Project Name: 
// Target Devices: 
// Tool Versions: 
// Description: 
// 
// Dependencies: 
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////

module frame_differencing #(
    parameter DATA_WIDTH = 8,
    parameter THRESHOLD = 15
)(
    input  wire                   aclk,
    input  wire                   aresetn,

    // AXI Stream Input 0 (Blur output 1)
    input  wire [DATA_WIDTH-1:0]  s0_axis_tdata,
    input  wire                   s0_axis_tvalid,
    output wire                   s0_axis_tready,
    input  wire                   s0_axis_tlast,

    // AXI Stream Input 1 (Blur output 2)
    input  wire [DATA_WIDTH-1:0]  s1_axis_tdata,
    input  wire                   s1_axis_tvalid,
    output wire                   s1_axis_tready,
    input  wire                   s1_axis_tlast,

    // AXI Stream Output (Difference)
    output reg                    m_axis_tdata,
    output reg                    m_axis_tvalid,
    input  wire                   m_axis_tready,
    output reg                    m_axis_tlast
);
    wire pipeline_ready = m_axis_tready || !m_axis_tvalid;
    wire both_valid = s0_axis_tvalid && s1_axis_tvalid;

    assign s0_axis_tready = pipeline_ready && s1_axis_tvalid;
    assign s1_axis_tready = pipeline_ready && s0_axis_tvalid;

    always @(posedge aclk) begin
        if (!aresetn) begin
            m_axis_tdata  <= 0;
            m_axis_tvalid <= 0;
            m_axis_tlast  <= 0;
        end 
        else if (pipeline_ready) begin

            if (both_valid) begin
                if (s0_axis_tdata > s1_axis_tdata)
                    if (s0_axis_tdata - s1_axis_tdata >= THRESHOLD) begin
                        m_axis_tdata <= 1;
                    end
                    else begin
                        m_axis_tdata <= 0;
                    end
                else
                    if (s1_axis_tdata - s0_axis_tdata >= THRESHOLD) begin
                        m_axis_tdata <= 1;
                    end
                    else begin
                        m_axis_tdata <= 0;
                    end
                    
                m_axis_tvalid <= 1;
                m_axis_tlast <= s0_axis_tlast & s1_axis_tlast;
            end
            else begin
                m_axis_tvalid <= 0;
            end
        end
    end

endmodule
