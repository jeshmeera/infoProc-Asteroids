module dp_single_ram #(
    parameter integer ADDR_W = 16,
    parameter integer DATA_W = 16,
    parameter integer DEPTH  = (1 << 16)
) (
    input clk,

    input [ADDR_W-1:0] raddr,
    input [DATA_W-1:0] din,
    input              we,
    input [ADDR_W-1:0] waddr,

    output reg [DATA_W-1:0] dout
);

  reg [DATA_W-1:0] mem[0:DEPTH-1];

  always @(posedge clk) begin
    if (we) begin
      mem[waddr] <= din;
    end
    dout <= mem[raddr];
  end

endmodule

