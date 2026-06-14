// Testbench for esp32_spi_connector (3-wire SPI, Mode 0)
`timescale 1ns/1ps

module test_esp32_spi_connector;
  // 54 MHz core clock (~18.518 ns period)
  localparam real CLK_PERIOD_NS = 18.518;

  // DUT ports
  reg  clk = 0;
  reg  rst_n = 0;
  reg  sclk = 0;
  reg  mosi = 0;
  wire miso;

  // Instantiate DUT with generous idle timeout to avoid reframing during sim
  esp32_spi_connector #(
    .USE_SYNC(1),
    .USE_CRC(0),
    .IDLE_TO_CYC(5_400_000)
  ) dut (
    .clk(clk),
    .rst_n(rst_n),
    .sclk(sclk),
    .mosi(mosi),
    .miso(miso)
  );

  // Core clock
  always #(CLK_PERIOD_NS/2.0) clk = ~clk;

  // Make SPI SCLK much slower than core clk
  localparam real SCLK_HALF_NS = 8.0 * CLK_PERIOD_NS; // ~1/16 of core clock

  // Simple SPI mode-0 bit-banger:
  // - SCLK idle low, sample MOSI on rising edge, update MISO on falling edge
  task automatic spi_send_byte(input [7:0] tx, output [7:0] rx);
    integer i;
    begin
      rx = 8'h00;
      for (i=7; i>=0; i=i-1) begin
        mosi = tx[i];
        // setup time before rising edge
        #(SCLK_HALF_NS);
        sclk = 1'b1; // rising edge: sample MOSI in DUT; we sample MISO here
        rx[i] = miso;
        #(SCLK_HALF_NS);
        sclk = 1'b0; // falling edge: DUT updates MISO for next bit
        #(SCLK_HALF_NS/2.0);
      end
      // leave a small idle
      #(SCLK_HALF_NS);
      $display("[TB] spi_send_byte tx=0x%02h rx=0x%02h @%0t", tx, rx, $time);
    end
  endtask

  // Helpers
  task automatic spi_sync;
    reg [7:0] r;
    begin
      spi_send_byte(8'hA5, r);
      spi_send_byte(8'h5A, r);
    end
  endtask

  function automatic void check_eq(input [7:0] got, input [7:0] exp, input [255:0] what);
    if (got !== exp) begin
      $display("[FAIL] %s: got=0x%02X exp=0x%02X @%0t", what, got, exp, $time);
      $fatal(1);
    end else begin
      $display("[PASS] %s: 0x%02X", what, got);
    end
  endfunction

  // RX sample regs declared at module scope for Icarus compatibility
  reg [7:0] rx;
  reg [7:0] r0, r1, r2, r3;

  initial begin
    $dumpfile("esp32_spi_connector.vcd");
    $dumpvars(0, test_esp32_spi_connector);

    $display("=== esp32_spi_connector test ===");
    // Reset
    sclk = 0; mosi = 0;
    #(20*CLK_PERIOD_NS);
    rst_n = 1;
    #(10*CLK_PERIOD_NS);

    // 1) Sync and read PROTO_VER (reg 0x04)
    spi_sync();
    // rx declared above
    spi_send_byte(8'h84, rx); // opcode: read bit + reg 0x04
    // allow some idle before next byte
    #(SCLK_HALF_NS);
    spi_send_byte(8'h00, rx); // dummy clocks to fetch data
    check_eq(rx, 8'h01, "PROTO_VER reg[0x04]");

    // 2) Write reg[0x06] = 0x55 and read back
    spi_sync();
    spi_send_byte(8'h06, rx); // write opcode to reg 0x06
    spi_send_byte(8'h55, rx); // payload
    spi_sync();
    spi_send_byte(8'h86, rx); // read reg 0x06
    spi_send_byte(8'h00, rx); // dummy to receive
    check_eq(rx, 8'h55, "reg[0x06] echo");

    // 3) XFER write 4 bytes to SPACE=0, ADDR=0x20
    spi_sync();
    spi_send_byte(8'h7F, rx);          // XFER portal
    spi_send_byte(8'h10, rx);          // SUB0: DIR=0 (write), SPACE=0, INC=1, CRC=0
    spi_send_byte(8'h20, rx);          // ADDR[7:0]
    spi_send_byte(8'h00, rx);          // ADDR[15:8]
    spi_send_byte(8'h00, rx);          // ADDR[23:16]
    spi_send_byte(8'h04, rx);          // LEN[7:0]
    spi_send_byte(8'h00, rx);          // LEN[15:8]
    spi_send_byte(8'h01, rx);          // DATA[0]
    spi_send_byte(8'h02, rx);          // DATA[1]
    spi_send_byte(8'h03, rx);          // DATA[2]
    spi_send_byte(8'h04, rx);          // DATA[3]

    // 4) XFER read back 4 bytes from same address
    spi_sync();
    spi_send_byte(8'h7F, rx);
    spi_send_byte(8'h11, rx);          // SUB0: DIR=1 (read), SPACE=0, INC=1
    spi_send_byte(8'h20, rx);
    spi_send_byte(8'h00, rx);
    spi_send_byte(8'h00, rx);
    spi_send_byte(8'h04, rx);
    spi_send_byte(8'h00, rx);

    // Dummy byte to accommodate first-read latency
    spi_send_byte(8'h00, rx);

    // r0..r3 declared above
    spi_send_byte(8'h00, r0);
    spi_send_byte(8'h00, r1);
    spi_send_byte(8'h00, r2);
    spi_send_byte(8'h00, r3);

    check_eq(r0, 8'h01, "xfer rd[0]");
    check_eq(r1, 8'h02, "xfer rd[1]");
    check_eq(r2, 8'h03, "xfer rd[2]");
    check_eq(r3, 8'h04, "xfer rd[3]");

    $display("=== All checks passed ===");
    $finish;
  end

endmodule
