`default_nettype none
`timescale 1ns / 1ps
module usb_hid_host_rom(
  input  wire       clk,

  input  wire [9:0] addr,
  output reg  [3:0] dout,
  input  wire       en
);

reg [3:0] mem [0:1023];

initial
  $readmemh("usb_hid_host_rom.mem", mem);

always @(posedge clk)
  if (en)
    dout <= mem[addr];

endmodule
`default_nettype wire
// vim:ts=2 sw=2 tw=120 et
