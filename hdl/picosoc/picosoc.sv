//
// PicoSoC integration for the A2FPGA
//
// (c) 2023,2024 Ed Anuff <ed@a2fpga.com> 
//
// Permission to use, copy, modify, and/or distribute this software for any
// purpose with or without fee is hereby granted, provided that the above
// copyright notice and this permission notice appear in all copies.
//
// THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
// WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
// MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
// ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
// WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
// ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
// OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
//
// Description:
//
// Embeds the PicoRV32 core and peripherals into the A2FPGA to provide
// support for SDCard access and OSD functionality
//

module picosoc #(
    parameter bit ENABLE = 1'b1,
    parameter int CLOCK_SPEED_HZ = 50_000_000
) (
    a2bus_if.slave a2bus_if,
    a2mem_if.slave a2mem_if,

    output [7:0] data_o,
    output rd_en_o,
    output irq_n_o,

    input  uart_rx_i,
    output uart_tx_o,

    output sd_cs_o,
    output sd_sclk_o,
    output sd_mosi_o,
    input  sd_miso_i,

    input  button_i,
    output led_o,

    f18a_gpu_if.slave f18a_gpu_if,
    video_control_if.control video_control_if,
    sdram_port_if.client mem_if,
    drive_volume_if.volume volumes[2]
);

    assign irq_n_o = 1'b1;
    assign rd_en_o = 1'b0;
    assign data_o = 8'h0;

    assign f18a_gpu_if.running = 1'b0;
    assign f18a_gpu_if.pause_ack = 1'b1;
    assign f18a_gpu_if.vwe = 1'b0;
    assign f18a_gpu_if.vaddr = 14'b0;
    assign f18a_gpu_if.vdout = 8'b0;
    assign f18a_gpu_if.pwe = 1'b0;
    assign f18a_gpu_if.paddr = 6'b0;
    assign f18a_gpu_if.pdout = 12'b0;
    assign f18a_gpu_if.rwe = 1'b0;
    assign f18a_gpu_if.raddr = 13'b0;
    assign f18a_gpu_if.gstatus = 7'b0;

    //assign mem_if.rd = 1'b0;
    //assign mem_if.addr = 21'h0;
    //assign mem_if.data = 32'h0;
    //assign mem_if.byte_en = 4'h0;
    //assign mem_if.wr = 1'b0;

    localparam int BAUD_RATE = 115200;
    localparam integer MEM_WORDS = 3584;  // use 14KBytes of block RAM by default (9 BRAMS)
    localparam [31:0] STACKADDR = (4 * MEM_WORDS);  // end of memory, start of stack

    ///////////////////////////////////
    // Interrupts
    ///////////////////////////////////

    reg [31:0] irq;
    wire irq_stall = 0;
    wire irq_uart = 0;
    wire irq_5 = 0;
    wire irq_6 = 0;
    wire irq_7 = 0;

    always @* begin
        irq = 0;
        irq[3] = irq_stall;
        irq[4] = irq_uart;
        irq[5] = irq_5;
        irq[6] = irq_6;
        irq[7] = irq_7;
    end

    ///////////////////////////////////
    // Peripheral Bus
    ///////////////////////////////////
    wire        iomem_valid;
    wire        iomem_ready;
    wire        iomem_instr;

    wire [ 3:0] iomem_wstrb;
    wire [31:0] iomem_addr;
    wire [31:0] iomem_wdata;
    wire [31:0] iomem_rdata;

    wire [31:0] iomem_la_addr;

    // enable signals for each of the peripherals
    wire        sram_en = (iomem_addr[31:24] == 8'h00);  /* SRAM mapped to 0x00xx_xxxx */
    wire        uart_en = (iomem_addr[31:24] == 8'h02);  /* UART mapped to 0x02xx_xxxx */
    wire        gpio_en = (iomem_addr[31:24] == 8'h03);  /* GPIO mapped to 0x03xx_xxxx */
    wire        sdram_en = (iomem_addr[31:24] == 8'h04);  /* SDRAM mapped to 0x04xx_xxxx */
    wire        a2fpga_en = (iomem_addr[31:24] == 8'h05);  /* A2FPGA mapped to 0x05xx_xxxx */
    wire        sdcard_en = (iomem_addr[31:24] == 8'h06);  /* SPI SD card mapped to 0x06xx_xxxx */

    wire [31:0] sram_iomem_rdata;
    wire        sram_iomem_ready;

    picosoc_sram #(
        .MEM_WORDS(MEM_WORDS)
    ) sram (
        .clk(a2bus_if.clk_logic),
        .resetn(a2bus_if.device_reset_n),
        .iomem_valid(iomem_valid && sram_en),
        .iomem_wstrb(iomem_wstrb),
        .iomem_addr(iomem_addr),
        .iomem_wdata(iomem_wdata),
        .iomem_rdata(sram_iomem_rdata),
        .iomem_ready(sram_iomem_ready)
    );

    wire [31:0] uart_iomem_rdata;
    wire uart_iomem_ready;

    picosoc_uart #(
        .CLOCK_SPEED_HZ(CLOCK_SPEED_HZ),
        .BAUD_RATE(BAUD_RATE)
    ) uart (
        .clk(a2bus_if.clk_logic),
        .resetn(a2bus_if.device_reset_n),
        .iomem_valid(iomem_valid && uart_en),
        .iomem_wstrb(iomem_wstrb),
        .iomem_addr(iomem_addr),
        .iomem_wdata(iomem_wdata),
        .iomem_rdata(uart_iomem_rdata),
        .iomem_ready(uart_iomem_ready),
        .uart_rx_i(uart_rx_i),
        .uart_tx_o(uart_tx_o)
    );

    wire [31:0] sdram_iomem_rdata;
    wire sdram_iomem_ready;

    picosoc_sdram sdram (
        .a2bus_if(a2bus_if),
        .iomem_valid(iomem_valid && sdram_en),
        .iomem_wstrb(iomem_wstrb),
        .iomem_addr(iomem_addr),
        .iomem_wdata(iomem_wdata),
        .iomem_rdata(sdram_iomem_rdata),
        .iomem_ready(sdram_iomem_ready),
        .iomem_instr(iomem_instr),
        .iomem_la_addr(iomem_la_addr),
        .mem_if(mem_if)
    );

    wire [31:0] sdcard_iomem_rdata;
    wire sdcard_iomem_ready;

    picosoc_sdcard #(
        .CLOCK_SPEED_HZ(CLOCK_SPEED_HZ)
    ) sd (
        .clk(a2bus_if.clk_logic),
        .resetn(a2bus_if.device_reset_n),
        .iomem_valid(iomem_valid && sdcard_en),
        .iomem_wstrb(iomem_wstrb),
        .iomem_addr(iomem_addr),
        .iomem_wdata(iomem_wdata),
        .iomem_rdata(sdcard_iomem_rdata),
        .iomem_ready(sdcard_iomem_ready),
        .SD_MOSI(sd_mosi_o),
        .SD_MISO(sd_miso_i),
        .SD_SCK(sd_sclk_o),
        .SD_CS(sd_cs_o)
    );

    wire [31:0] gpio_iomem_rdata;
    wire gpio_iomem_ready;

    picosoc_gpio gpio_peripheral (
        .clk(a2bus_if.clk_logic),
        .resetn(a2bus_if.device_reset_n),
        .iomem_valid(iomem_valid && gpio_en),
        .iomem_wstrb(iomem_wstrb),
        .iomem_addr(iomem_addr),
        .iomem_wdata(iomem_wdata),
        .iomem_rdata(gpio_iomem_rdata),
        .iomem_ready(gpio_iomem_ready),
        .button(button_i),
        .led(led_o)
    );

    wire [31:0] a2fpga_iomem_rdata;
    wire a2fpga_iomem_ready;

    picosoc_a2fpga #(
        .CLOCK_SPEED_HZ(CLOCK_SPEED_HZ)
    ) soc_io_peripheral (
        .clk(a2bus_if.clk_logic),
        .resetn(a2bus_if.device_reset_n),
        .iomem_valid(iomem_valid && a2fpga_en),
        .iomem_wstrb(iomem_wstrb),
        .iomem_addr(iomem_addr),
        .iomem_rdata(a2fpga_iomem_rdata),
        .iomem_ready(a2fpga_iomem_ready),
        .iomem_wdata(iomem_wdata),
        .a2bus_if(a2bus_if),
        .a2mem_if(a2mem_if),
        .video_control_if(video_control_if),
        .volumes(volumes)
    );

    assign iomem_ready = sram_en ? sram_iomem_ready
        : uart_en ? uart_iomem_ready
        : gpio_en ? gpio_iomem_ready 
        : sdram_en ? sdram_iomem_ready
        : sdcard_en ? sdcard_iomem_ready
        : a2fpga_en ? a2fpga_iomem_ready
        : 1'b1;

    assign iomem_rdata = sram_iomem_ready ? sram_iomem_rdata
        : uart_iomem_ready ? uart_iomem_rdata
        : gpio_iomem_ready ? gpio_iomem_rdata
        : sdram_iomem_ready ? sdram_iomem_rdata
        : sdcard_iomem_ready ? sdcard_iomem_rdata
        : a2fpga_iomem_ready ? a2fpga_iomem_rdata
        : 32'h0;

    picorv32 #(
        .COMPRESSED_ISA(0),
        .ENABLE_MUL(0),
        .ENABLE_DIV(0),
        .ENABLE_FAST_MUL(1),
        .ENABLE_IRQ(1),
        .STACKADDR(STACKADDR)
    ) cpu (
        .clk(a2bus_if.clk_logic),
        .resetn(a2bus_if.device_reset_n),
        .trap(),
        .mem_valid(iomem_valid),
        .mem_instr(iomem_instr),
        .mem_ready(iomem_ready),
        .mem_addr(iomem_addr),
        .mem_wdata(iomem_wdata),
        .mem_wstrb(iomem_wstrb),
        .mem_rdata(iomem_rdata),
        .mem_la_read(),
        .mem_la_write(),
        .mem_la_addr(iomem_la_addr),
        .mem_la_wdata(),
        .mem_la_wstrb(),
        .irq(irq),
        .eoi(),
        .pcpi_valid(),
        .pcpi_insn(),
        .pcpi_rs1(),
        .pcpi_rs2(),
        .pcpi_wr(1'b0),
        .pcpi_rd(0),
        .pcpi_wait(1'b0),
        .pcpi_ready(1'b0),
        .trace_valid(),
        .trace_data()
    );

endmodule

