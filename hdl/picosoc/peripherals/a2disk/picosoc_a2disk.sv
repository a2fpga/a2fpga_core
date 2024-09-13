//
// PicoSoC peripheral to interface the PicoSoC to the A2FPGA core
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
// Exposes the A2FPGA core to the PicoSoC as memory-mapped I/O
//


module picosoc_a2disk #(parameter int CLOCK_SPEED_HZ = 0)
(
	input clk,
	input resetn,

	input iomem_valid,
	input [3:0]  iomem_wstrb,
	input [31:0] iomem_addr,
	output reg [31:0] iomem_rdata,
	output reg iomem_ready,
	input [31:0] iomem_wdata,

    a2bus_if.slave a2bus_if,
    drive_volume_if.volume volumes[2]
);

    localparam ADDR_VOL_READY =      8'h00;      // V0 ready
    localparam ADDR_VOL_ACTIVE =     8'h04;      // V0 active
    localparam ADDR_VOL_MOUNTED =    8'h08;      // V0 mounted
    localparam ADDR_VOL_READONLY =   8'h0C;      // V0 readonly
    localparam ADDR_VOL_SIZE =       8'h10;      // V0 size
    localparam ADDR_VOL_LBA =        8'h14;      // V0 lba,
    localparam ADDR_VOL_BLK_CNT =    8'h18;      // V0 blk_cnt,
    localparam ADDR_VOL_RD =         8'h1C;      // V0 rd,
    localparam ADDR_VOL_WR =         8'h20;      // V0 wr,
    localparam ADDR_VOL_ACK =        8'h24;      // V0 ack

    reg volume_ready_r[2];
    reg volume_mounted_r[2];
    reg volume_readonly_r[2];
    reg [31:0] volume_size_r[2];
    reg volume_ack_r[2];

    assign volumes[0].ready = volume_ready_r[0];
    assign volumes[0].mounted = volume_mounted_r[0];
    assign volumes[0].readonly = volume_readonly_r[0];
    assign volumes[0].size = volume_size_r[0];
    assign volumes[0].ack = volume_ack_r[0];

    assign volumes[1].ready = volume_ready_r[1];
    assign volumes[1].mounted = volume_mounted_r[1];
    assign volumes[1].readonly = volume_readonly_r[1];
    assign volumes[1].size = volume_size_r[1];
    assign volumes[1].ack = volume_ack_r[1];

    wire volume_active_w[2];
    wire [31:0] volume_lba_w[2];
    wire [5:0] volume_blk_cnt_w[2];
    wire volume_rd_w[2];
    wire volume_wr_w[2];

    assign volume_active_w[0] = volumes[0].active;
    assign volume_lba_w[0] = volumes[0].lba;
    assign volume_blk_cnt_w[0] = volumes[0].blk_cnt;
    assign volume_rd_w[0] = volumes[0].rd;
    assign volume_wr_w[0] = volumes[0].wr;

    assign volume_active_w[1] = volumes[1].active;
    assign volume_lba_w[1] = volumes[1].lba;
    assign volume_blk_cnt_w[1] = volumes[1].blk_cnt;
    assign volume_rd_w[1] = volumes[1].rd;
    assign volume_wr_w[1] = volumes[1].wr;

	always @(posedge clk) begin

      	iomem_ready <= 0;
        iomem_rdata <= 32'b0;

        if (iomem_valid) begin
            if (|iomem_wstrb) begin
                case (iomem_addr[5:2])
                    ADDR_VOL_READY[5:2]: volume_ready_r[iomem_addr[7]] <= iomem_wdata[0];
                    ADDR_VOL_MOUNTED[5:2]: volume_mounted_r[iomem_addr[7]] <= iomem_wdata[0];
                    ADDR_VOL_READONLY[5:2]: volume_readonly_r[iomem_addr[7]] <= iomem_wdata[0];
                    ADDR_VOL_SIZE[5:2]: volume_size_r[iomem_addr[7]] <= iomem_wdata;
                    ADDR_VOL_ACK[5:2]: volume_ack_r[iomem_addr[7]] <= iomem_wdata[0];
                    default: ;
                endcase
            end else begin
                case (iomem_addr[5:2])
                    ADDR_VOL_ACTIVE[5:2]: iomem_rdata <= {31'b0, volume_active_w[iomem_addr[7]]};
                    ADDR_VOL_LBA[5:2]: iomem_rdata <= volume_lba_w[iomem_addr[7]];
                    ADDR_VOL_BLK_CNT[5:2]: iomem_rdata <= {26'b0, volume_blk_cnt_w[iomem_addr[7]]};
                    ADDR_VOL_RD[5:2]: iomem_rdata <= {31'b0, volume_rd_w[iomem_addr[7]]};
                    ADDR_VOL_WR[5:2]: iomem_rdata <= {31'b0, volume_wr_w[iomem_addr[7]]};
                    default: ;
                endcase
            end

            iomem_ready <= 1;
        end
	end

endmodule
