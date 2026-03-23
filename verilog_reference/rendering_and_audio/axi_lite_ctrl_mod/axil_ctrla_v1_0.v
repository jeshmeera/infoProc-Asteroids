
`timescale 1 ns / 1 ps

module axil_ctrla_v1_0 #(
    // Users to add parameters here

    // User parameters ends
    // Do not modify the parameters beyond this line


    // Parameters of Axi Slave Bus Interface S00_AXI
    parameter integer C_S00_AXI_DATA_WIDTH = 32,
    parameter integer C_S00_AXI_ADDR_WIDTH = 5
) (
    // Users to add ports here
    output wire [C_S00_AXI_DATA_WIDTH-1:0] ctrl0_o,
    output wire [C_S00_AXI_DATA_WIDTH-1:0] ctrl1_o,
    output wire [C_S00_AXI_DATA_WIDTH-1:0] ctrl2_o,
    output wire [C_S00_AXI_DATA_WIDTH-1:0] ctrl3_o,
    output wire [C_S00_AXI_DATA_WIDTH-1:0] ctrl4_o,
    output wire [C_S00_AXI_DATA_WIDTH-1:0] ctrl5_o,
    output wire [C_S00_AXI_DATA_WIDTH-1:0] ctrl6_o,
    output wire [C_S00_AXI_DATA_WIDTH-1:0] irq_o,
    input  wire [C_S00_AXI_DATA_WIDTH-1:0] data0_i,
    input  wire [C_S00_AXI_DATA_WIDTH-1:0] data1_i,
    input  wire [C_S00_AXI_DATA_WIDTH-1:0] data2_i,
    input  wire [C_S00_AXI_DATA_WIDTH-1:0] data3_i,
    input  wire [C_S00_AXI_DATA_WIDTH-1:0] data4_i,
    input  wire [C_S00_AXI_DATA_WIDTH-1:0] data5_i,
    input  wire [C_S00_AXI_DATA_WIDTH-1:0] data6_i,
    input  wire [C_S00_AXI_DATA_WIDTH-1:0] irq_i,


    // User ports ends
    // Do not modify the ports beyond this line


    // Ports of Axi Slave Bus Interface S00_AXI
    input  wire                                  s00_axi_aclk,
    input  wire                                  s00_axi_aresetn,
    input  wire [    C_S00_AXI_ADDR_WIDTH-1 : 0] s00_axi_awaddr,
    input  wire [                         2 : 0] s00_axi_awprot,
    input  wire                                  s00_axi_awvalid,
    output wire                                  s00_axi_awready,
    input  wire [    C_S00_AXI_DATA_WIDTH-1 : 0] s00_axi_wdata,
    input  wire [(C_S00_AXI_DATA_WIDTH/8)-1 : 0] s00_axi_wstrb,
    input  wire                                  s00_axi_wvalid,
    output wire                                  s00_axi_wready,
    output wire [                         1 : 0] s00_axi_bresp,
    output wire                                  s00_axi_bvalid,
    input  wire                                  s00_axi_bready,
    input  wire [    C_S00_AXI_ADDR_WIDTH-1 : 0] s00_axi_araddr,
    input  wire [                         2 : 0] s00_axi_arprot,
    input  wire                                  s00_axi_arvalid,
    output wire                                  s00_axi_arready,
    output wire [    C_S00_AXI_DATA_WIDTH-1 : 0] s00_axi_rdata,
    output wire [                         1 : 0] s00_axi_rresp,
    output wire                                  s00_axi_rvalid,
    input  wire                                  s00_axi_rready
);
  //    reg [C_S00_AXI_DATA_WIDTH-1:0]	slv_reg0;
  //	reg [C_S00_AXI_DATA_WIDTH-1:0]	slv_reg1;
  //	reg [C_S00_AXI_DATA_WIDTH-1:0]	slv_reg2;
  //	reg [C_S00_AXI_DATA_WIDTH-1:0]	slv_reg3;
  // Instantiation of Axi Bus Interface S00_AXI
  axil_ctrla_v1_0_S00_AXI #(
      .C_S_AXI_DATA_WIDTH(C_S00_AXI_DATA_WIDTH),
      .C_S_AXI_ADDR_WIDTH(C_S00_AXI_ADDR_WIDTH)
  ) axil_ctrla_v1_0_S00_AXI_inst (
      .S_AXI_ACLK   (s00_axi_aclk),
      .S_AXI_ARESETN(s00_axi_aresetn),
      .S_AXI_AWADDR (s00_axi_awaddr),
      .S_AXI_AWPROT (s00_axi_awprot),
      .S_AXI_AWVALID(s00_axi_awvalid),
      .S_AXI_AWREADY(s00_axi_awready),
      .S_AXI_WDATA  (s00_axi_wdata),
      .S_AXI_WSTRB  (s00_axi_wstrb),
      .S_AXI_WVALID (s00_axi_wvalid),
      .S_AXI_WREADY (s00_axi_wready),
      .S_AXI_BRESP  (s00_axi_bresp),
      .S_AXI_BVALID (s00_axi_bvalid),
      .S_AXI_BREADY (s00_axi_bready),
      .S_AXI_ARADDR (s00_axi_araddr),
      .S_AXI_ARPROT (s00_axi_arprot),
      .S_AXI_ARVALID(s00_axi_arvalid),
      .S_AXI_ARREADY(s00_axi_arready),
      .S_AXI_RDATA  (s00_axi_rdata),
      .S_AXI_RRESP  (s00_axi_rresp),
      .S_AXI_RVALID (s00_axi_rvalid),
      .S_AXI_RREADY (s00_axi_rready),
      .slv_reg0     (ctrl0_o),
      .slv_reg1     (ctrl1_o),
      .slv_reg2     (ctrl2_o),
      .slv_reg3     (ctrl3_o),
      .slv_reg4     (ctrl4_o),
      .slv_reg5     (ctrl5_o),
      .slv_reg6     (ctrl6_o),
      .slv_reg7     (irq_o),
      .slv_reg0_i   (data0_i),
      .slv_reg1_i   (data1_i),
      .slv_reg2_i   (data2_i),
      .slv_reg3_i   (data3_i),
      .slv_reg4_i   (data4_i),
      .slv_reg5_i   (data5_i),
      .slv_reg6_i   (data6_i),
      .slv_reg7_i   (irq_i)
  );

  // Add user logic here

  // User logic ends

endmodule

