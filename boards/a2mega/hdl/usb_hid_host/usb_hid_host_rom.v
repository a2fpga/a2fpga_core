`default_nettype none
`timescale 1ns / 1ps
module usb_hid_host_rom(
  input  wire       clk,

  input  wire [9:0] addr,
  output reg  [3:0] dout,
  input  wire       en
);

reg [3:0] mem [0:1023];

// Microcode is inlined via `include (resolved relative to THIS file —
// well-defined), because $readmemh relative paths resolve against
// GowinSynthesis's working directory and silently zero-filled this ROM
// in every build: the UKP executed empty microcode and no USB device
// could ever enumerate (live-debugged: dead-but-ticking host, typ=0).
// usb_hid_host_rom_init.vh is GENERATED from usb_hid_host_rom.mem.
`include "usb_hid_host_rom_init.vh"

always @(posedge clk)
  if (en)
    dout <= mem[addr];

endmodule
`default_nettype wire
// vim:ts=2 sw=2 tw=120 et
