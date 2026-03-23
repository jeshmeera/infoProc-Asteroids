`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 26.02.2026 13:32:10
// Design Name: 
// Module Name: direction
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


module direction #(
    parameter DATAWIDTH = 1
)(
    input wire aclk,
    input wire aresetn,
    
    input wire [DATAWIDTH-1:0]s_axis_tdata,
    input wire s_axis_tvalid,
    input wire s_axis_tlast,
    output wire s_axis_tready,
    
    output reg [63:0] m_axis_tdata,
    output reg m_axis_tvalid,
    output reg m_axis_tlast,
    input wire m_axis_tready
);

reg [31:0] sum_x;
reg [31:0] count;
reg [8:0] x;
reg [8:0] y;

wire [31:0] sum_next = sum_x + (s_axis_tdata ? x : 9'd0);
wire [31:0] cnt_next = count + s_axis_tdata;

wire in_fire;
wire out_fire;

assign s_axis_tready = aresetn && (!m_axis_tvalid || m_axis_tready);
assign in_fire = s_axis_tvalid && s_axis_tready;
assign out_fire = m_axis_tvalid && m_axis_tready;

always @ (posedge aclk) begin
    if (!aresetn) begin
        m_axis_tdata <= 0;
        m_axis_tvalid <= 0;
        m_axis_tlast <= 0;
        sum_x <= 0;
        count <= 0;
        x <= 0;
        y <= 0;
    end 
    else begin 
        if (m_axis_tvalid && m_axis_tready) begin
            m_axis_tvalid <= 0;
            m_axis_tlast <= 0;
            
            sum_x <= 0;
            count <= 0;
            x <= 0;
            y <= 0;
        end
        if (in_fire) begin

            sum_x <= sum_next;
            count <= cnt_next;
            
            if (x == 319) begin
                x <= 0;
                y <= y + 1;
            end 
            else begin
                x <= x + 1;
                y <= y;
            end
            
            if (s_axis_tlast || (x == 319 && y == 239)) begin
                m_axis_tdata <= {sum_next, cnt_next};
                m_axis_tvalid <= 1;
                m_axis_tlast <= 1;
            end
        end 
        
    end
           
 end
 
 endmodule    