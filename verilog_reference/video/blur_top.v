`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 22.02.2026 11:32:19
// Design Name: 
// Module Name: blur_top
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


module blur_top#(
    parameter IMG_WIDTH = 320,
    IMG_HEIGHT = 240
)(
    input  wire        aclk,
    input  wire        aresetn,

    // AXI Stream Slave (input)
    input  wire [7:0]  s_axis_tdata,
    input  wire        s_axis_tvalid,
    output wire        s_axis_tready,
    input  wire        s_axis_tlast,

    // AXI Stream Master (output)
    output reg  [7:0]  m_axis_tdata,
    output reg         m_axis_tvalid,
    input  wire        m_axis_tready,
    output reg         m_axis_tlast
    );
    
    wire pipeline_ready;
    assign pipeline_ready = m_axis_tready || !m_axis_tvalid;
    assign s_axis_tready  = pipeline_ready;

    reg [7:0] linebuf1 [0:IMG_WIDTH-1];
    reg [7:0] linebuf2 [0:IMG_WIDTH-1];

    reg [$clog2(IMG_WIDTH)-1:0] col_s0;
    reg [7:0] row_s0;
    always @(posedge aclk) begin
        if (!aresetn) begin
            col_s0 <= 0;
            row_s0 <= 0;
        end
        else if (s_axis_tvalid && s_axis_tready) begin
            linebuf2[col_s0] <= linebuf1[col_s0];
            linebuf1[col_s0] <= s_axis_tdata;
    
            if (col_s0 == IMG_WIDTH-1) begin
                col_s0 <= 0;
                if (row_s0 == IMG_HEIGHT-1)
                    row_s0 <= 0;
                else
                    row_s0 <= row_s0 + 1;
            end
            else begin
                col_s0 <= col_s0 + 1;
            end
        end
    end
    reg [7:0] bram1_s1, bram2_s1, pixel_s1;
    reg [$clog2(IMG_WIDTH)-1:0] col_s1;
    reg [7:0] row_s1;
    reg valid_s1, tlast_s1;

    always @(posedge aclk)
    begin
        if (!aresetn)
            valid_s1 <= 0;
        else if (pipeline_ready)
        begin
            valid_s1 <= s_axis_tvalid;

            if (s_axis_tvalid)
            begin
                bram1_s1 <= linebuf1[col_s0];
                bram2_s1 <= linebuf2[col_s0];
                pixel_s1 <= s_axis_tdata;

                col_s1   <= col_s0;
                row_s1   <= row_s0;
                tlast_s1 <= (col_s0 == IMG_WIDTH-1) && (row_s0 == IMG_HEIGHT-1);
            end
        end
    end

    reg [7:0] t0,t1,t2;
    reg [7:0] m0,m1,m2;
    reg [7:0] b0,b1,b2;

    reg [$clog2(IMG_WIDTH)-1:0] col_s2;
    reg [7:0] row_s2;
    reg valid_s2, tlast_s2;

    always @(posedge aclk)
    begin
        if (!aresetn)
            valid_s2 <= 0;
        else if (pipeline_ready)
        begin
            valid_s2 <= valid_s1;

            if (valid_s1)
            begin
                t0 <= t1; t1 <= t2;
                m0 <= m1; m1 <= m2;
                b0 <= b1; b1 <= b2;

                t2 <= bram2_s1;
                m2 <= bram1_s1;
                b2 <= pixel_s1;

                col_s2   <= col_s1;
                row_s2   <= row_s1;
                tlast_s2 <= tlast_s1;
            end
        end
    end

    reg [11:0] sum_s3;
    reg [$clog2(IMG_WIDTH)-1:0] col_s3;
    reg [7:0] row_s3;
    reg valid_s3, tlast_s3;

    always @(posedge aclk)
    begin
        if (!aresetn)
            valid_s3 <= 0;
        else if (pipeline_ready)
        begin
            valid_s3 <= valid_s2;

            if (valid_s2)
            begin
                sum_s3 <= t0+t1+t2 +
                          m0+m1+m2 +
                          b0+b1+b2;

                col_s3   <= col_s2;
                row_s3   <= row_s2;
                tlast_s3 <= tlast_s2;
            end
        end
    end

    always @(posedge aclk)
    begin
        if (!aresetn)
        begin
            m_axis_tvalid <= 0;
            m_axis_tdata  <= 0;
            m_axis_tlast  <= 0;
        end
        else if (pipeline_ready)
        begin
            m_axis_tvalid <= valid_s3;

            if (valid_s3)
            begin
                if (row_s3 >= 2 && col_s3 >= 2 && row_s3 < IMG_HEIGHT)
                    m_axis_tdata <= (sum_s3 * 57) >> 9; 
                else
                    m_axis_tdata <= 0;

                m_axis_tlast <= tlast_s3;
            end
        end
    end
     
endmodule
