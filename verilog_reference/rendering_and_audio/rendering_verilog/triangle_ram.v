module triangle_ram #(
    parameter TRI_COUNT = 256,
    parameter VERTEX_W  = 48,
    parameter ADDR_W    = 16
) (
    input clk,
    input clr,

    input  wire [  ADDR_W-1:0] rd_addr,
    output reg  [VERTEX_W-1:0] v0_o,
    output reg  [VERTEX_W-1:0] v1_o,
    output reg  [VERTEX_W-1:0] v2_o,
    output reg                 valid_o,
    input  wire                wr_en,
    input  wire [  ADDR_W-1:0] wr_addr,
    input  wire [VERTEX_W-1:0] v0_i,
    input  wire [VERTEX_W-1:0] v1_i,
    input  wire [VERTEX_W-1:0] v2_i
);

  reg [VERTEX_W-1:0] v0_mem[0:TRI_COUNT-1];
  reg [VERTEX_W-1:0] v1_mem[0:TRI_COUNT-1];
  reg [VERTEX_W-1:0] v2_mem[0:TRI_COUNT-1];
  reg [    ADDR_W:0] top;
  always @(posedge clk) begin
    if (clr) top <= 0;
    if (wr_en) begin
      v0_mem[wr_addr] <= v0_i;
      v1_mem[wr_addr] <= v1_i;
      v2_mem[wr_addr] <= v2_i;
      if (top < wr_addr + 1) top <= wr_addr + 1;
    end
    v0_o    <= v0_mem[rd_addr];
    v1_o    <= v1_mem[rd_addr];
    v2_o    <= v2_mem[rd_addr];
    valid_o <= rd_addr < top;
  end

endmodule

