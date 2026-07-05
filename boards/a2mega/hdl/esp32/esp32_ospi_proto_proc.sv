// Octal SPI Protocol Processor for ESP32-S3 to FPGA communication
// Based on boards/a2p25/docs/ESP32_SPI_PROTOCOL.md but optimized for 8-bit parallel transfer
//
// Key differences from standard SPI:
// - Transfers 8 bits per SCLK cycle (one byte per clock)
// - Bidirectional data bus with direction control
// - Much higher throughput than bit-serial SPI
//
module esp32_ospi_proto_proc #(
    parameter USE_SYNC    = 1,
    parameter USE_CRC     = 0,
    parameter IDLE_TO_CYC = 54_000
)(
    input  wire        clk,
    input  wire        rst_n,

    // Octal SPI interface
    input  wire        sclk,
    input  wire [7:0]  data_in,      // 8-bit parallel input (directly from pad registers)
    output reg  [7:0]  data_out,     // 8-bit parallel output
    output reg         data_oe,      // Output enable (active high = driving data)

    // Register file interface
    output reg         reg_wr_req,
    output reg         reg_rd_req,
    output reg  [6:0]  reg_idx,
    output reg  [7:0]  reg_wdata,
    input  wire [7:0]  reg_rdata,

    // Memory/XFER interface
    output reg         mem_wr_en,
    output reg  [2:0]  mem_space,
    output reg  [23:0] mem_wr_addr,
    output reg  [7:0]  mem_wr_data,

    output reg         mem_rd_req,
    output reg  [2:0]  mem_rd_space,
    output reg  [23:0] mem_rd_addr,
    input  wire        mem_rd_valid,
    input  wire [7:0]  mem_rd_data
);

    // Synchronize SCLK and data to system clock
    reg sclk_q1, sclk_q2;
    reg [7:0] data_q1, data_q2;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sclk_q1 <= 0;
            sclk_q2 <= 0;
            data_q1 <= 8'h00;
            data_q2 <= 8'h00;
        end else begin
            sclk_q1 <= sclk;
            sclk_q2 <= sclk_q1;
            data_q1 <= data_in;
            data_q2 <= data_q1;
        end
    end

    wire sclk_rise = (sclk_q2 == 0) && (sclk_q1 == 1);
    wire sclk_fall = (sclk_q2 == 1) && (sclk_q1 == 0);

    // Idle timeout for reframing
    reg [31:0] idle_ctr;
    wire idle_expired = (idle_ctr == IDLE_TO_CYC);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            idle_ctr <= 0;
        else if (sclk_rise || sclk_fall)
            idle_ctr <= 0;
        else if (!idle_expired)
            idle_ctr <= idle_ctr + 1'b1;
    end

    // Byte received strobe (one byte per SCLK rise in octal mode)
    reg [7:0] rx_byte;
    reg       byte_rx_stb;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_byte <= 8'h00;
            byte_rx_stb <= 0;
        end else begin
            byte_rx_stb <= 0;
            if (sclk_rise) begin
                rx_byte <= data_q2;
                byte_rx_stb <= 1;
            end
            if (idle_expired) begin
                rx_byte <= 8'h00;
            end
        end
    end

    // Status byte
    localparam [7:0] PROTO_VER = 8'h01;
    reg [3:0] status_ver;
    reg status_align, status_crcerr, status_busy, status_ok;
    wire [7:0] status_byte = {status_ver, status_align, status_crcerr, status_busy, status_ok};

    // FSM states
    localparam [4:0]
        ST_IDLE       = 0,
        ST_SYNC0      = 1,
        ST_SYNC1      = 2,
        ST_OPCODE     = 3,
        ST_HDRCRC     = 4,
        ST_REG_RW     = 5,
        ST_X0         = 6,
        ST_XA0        = 7,
        ST_XA1        = 8,
        ST_XA2        = 9,
        ST_XL0        = 10,
        ST_XL1        = 11,
        ST_XHDRC      = 12,
        ST_XPAY_WR    = 13,
        ST_XPAY_RD_DMY= 14,
        ST_XPAY_RD    = 15,
        ST_XPLCRC     = 16,
        ST_DONE       = 17,
        ST_ERR        = 18;

    reg [4:0] st;

    // Header fields
    reg op_is_read;
    reg [6:0] op_reg;
    reg [7:0] sub0;
    reg [23:0] addr;
    reg [15:0] len, len_cnt;
    reg sub_dir, sub_crc, sub_inc;
    reg [2:0] sub_space;
    reg [7:0] crc_hdr, crc_pl;

    // Read pipeline buffer
    reg [7:0] rd_buf;
    reg rd_buf_valid;
    reg [7:0] reg_read_value;
    reg load_reg_read_next;

    // TX data management - output on falling edge
    reg [7:0] tx_next;

    // The data bus is SHARED (8-bit bidirectional, no separate MISO): the
    // FPGA may only drive during genuine response slots, i.e. after a
    // register-read opcode (data byte, then status byte) and during the
    // XFER-read dummy (carries the status byte) and payload slots. Driving
    // anywhere else — as the original port of the serial protocol did with
    // its status byte — fights the master's push-pull outputs. The master
    // performs a bus turnaround (TX header phase, then RX clock-only phase)
    // for every read.
    reg [1:0] reg_resp_cnt;   // response bytes left to drive for a reg read

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            reg_resp_cnt <= 2'd0;
        end else if (byte_rx_stb) begin
            if (st == ST_OPCODE && rx_byte[7] && (rx_byte[6:0] != 7'd127))
                reg_resp_cnt <= 2'd2;             // [read data][status]
            else if (reg_resp_cnt != 2'd0)
                reg_resp_cnt <= reg_resp_cnt - 2'd1;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            data_out <= 8'hFF;
            data_oe <= 0;
        end else if (sclk_fall) begin
            if (st == ST_XPAY_RD_DMY) begin
                data_out <= status_byte;   // dummy slot returns real status
                data_oe <= 1;
            end else if (st == ST_XPAY_RD) begin
                data_out <= rd_buf_valid ? rd_buf : 8'hFF;
                data_oe <= 1;
            end else if (reg_resp_cnt == 2'd2) begin
                // Live mux, NOT a value latched at the opcode strobe:
                // reg_idx settles one clk after the strobe, and this fall is
                // later still — a latched value is the PREVIOUS command's
                // register (live-tested failure mode).
                data_out <= reg_rdata;
                data_oe <= 1;
            end else if (reg_resp_cnt == 2'd1) begin
                data_out <= status_byte;
                data_oe <= 1;
            end else begin
                data_out <= 8'hFF;
                data_oe <= 0;              // master owns the bus
            end
        end else if (idle_expired) begin
            data_oe <= 0;
            data_out <= 8'hFF;
        end
    end

    // Main FSM
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st <= ST_IDLE;
            status_ver <= PROTO_VER[3:0];
            status_align <= 0;
            status_crcerr <= 0;
            status_busy <= 0;
            status_ok <= 1;
            op_is_read <= 0;
            op_reg <= 0;
            sub0 <= 0;
            addr <= 0;
            len <= 0;
            len_cnt <= 0;
            sub_dir <= 0;
            sub_crc <= 0;
            sub_inc <= 0;
            sub_space <= 0;
            crc_hdr <= 0;
            crc_pl <= 0;
            rd_buf <= 8'h00;
            rd_buf_valid <= 0;
            load_reg_read_next <= 0;
            reg_wr_req <= 0;
            reg_rd_req <= 0;
            reg_idx <= 0;
            reg_wdata <= 0;
            mem_wr_en <= 0;
            mem_space <= 0;
            mem_wr_addr <= 0;
            mem_wr_data <= 0;
            mem_rd_req <= 0;
            mem_rd_space <= 0;
            mem_rd_addr <= 0;
        end else begin
            // One-shots
            reg_wr_req <= 0;
            reg_rd_req <= 0;
            mem_wr_en <= 0;
            mem_rd_req <= 0;
            status_align <= 0;

            if (idle_expired) begin
                st <= ST_IDLE;
                rd_buf_valid <= 0;
            end

            // Latch memory read data
            if (mem_rd_valid) begin
                rd_buf <= mem_rd_data;
                rd_buf_valid <= 1;
            end

            if (byte_rx_stb) begin
                load_reg_read_next <= 0;

                case (st)
                    ST_IDLE: begin
                        status_ok <= 1;
                        status_crcerr <= 0;
                        status_busy <= 0;
                        crc_hdr <= 0;
                        rd_buf_valid <= 0;
                        if (USE_SYNC) begin
                            st <= (rx_byte == 8'hA5) ? ST_SYNC1 : ST_IDLE;
                        end else begin
                            st <= ST_OPCODE;
                        end
                    end

                    ST_SYNC0: begin
                        st <= ST_IDLE;
                    end

                    ST_SYNC1: begin
                        if (rx_byte == 8'h5A) begin
                            status_align <= 1;
                            st <= ST_OPCODE;
                            crc_hdr <= 0;
                        end else begin
                            st <= ST_IDLE;
                        end
                    end

                    ST_OPCODE: begin
                        op_is_read <= rx_byte[7];
                        op_reg <= rx_byte[6:0];
                        rd_buf_valid <= 0;
                        if (rx_byte[6:0] != 7'd127) begin
                            reg_idx <= rx_byte[6:0];
                            if (rx_byte[7]) begin  // READ
                                reg_read_value <= reg_rdata;
                                load_reg_read_next <= 1;
                                reg_rd_req <= 1;
                                st <= ST_REG_RW;
                            end else begin  // WRITE
                                st <= ST_REG_RW;
                            end
                        end else begin
                            st <= ST_X0;
                        end
                    end

                    ST_REG_RW: begin
                        if (op_reg != 7'd127) begin
                            if (op_is_read) begin
                                st <= ST_DONE;
                            end else begin
                                reg_wdata <= rx_byte;
                                reg_wr_req <= 1;
                                st <= ST_DONE;
                            end
                        end else begin
                            st <= ST_ERR;
                        end
                    end

                    ST_DONE: begin
                        if (USE_SYNC) begin
                            st <= (rx_byte == 8'hA5) ? ST_SYNC1 : ST_IDLE;
                        end else begin
                            st <= ST_OPCODE;
                        end
                    end

                    ST_ERR: begin
                        if (USE_SYNC) begin
                            st <= (rx_byte == 8'hA5) ? ST_SYNC1 : ST_IDLE;
                        end else begin
                            st <= ST_OPCODE;
                        end
                    end

                    // XFER header
                    ST_X0: begin
                        sub0 <= rx_byte;
                        sub_dir <= rx_byte[0];
                        sub_space <= rx_byte[3:1];
                        sub_inc <= rx_byte[4];
                        sub_crc <= rx_byte[5];
                        addr <= 0;
                        len <= 0;
                        st <= ST_XA0;
                    end

                    ST_XA0: begin
                        addr[7:0] <= rx_byte;
                        st <= ST_XA1;
                    end

                    ST_XA1: begin
                        addr[15:8] <= rx_byte;
                        st <= ST_XA2;
                    end

                    ST_XA2: begin
                        addr[23:16] <= rx_byte;
                        st <= ST_XL0;
                    end

                    ST_XL0: begin
                        len[7:0] <= rx_byte;
                        st <= ST_XL1;
                    end

                    ST_XL1: begin
                        len[15:8] <= rx_byte;
                        len_cnt <= {rx_byte, len[7:0]};
                        mem_space <= sub_space;
                        mem_rd_space <= sub_space;
                        st <= sub_dir ? ST_XPAY_RD_DMY : ST_XPAY_WR;
                    end

                    // WRITE payload
                    ST_XPAY_WR: begin
                        if (len_cnt == 0) begin
                            st <= ST_DONE;
                        end else begin
                            // Write applies to every space; the connector routes
                            // mem_space to the right backing store.
                            mem_wr_addr <= addr;
                            mem_wr_data <= rx_byte;
                            mem_wr_en <= 1;
                            len_cnt <= len_cnt - 16'd1;
                            if (sub_inc) addr <= addr + 24'd1;
                            if (len_cnt == 16'd1) st <= ST_DONE;
                        end
                    end

                    // READ payload with dummy
                    ST_XPAY_RD_DMY: begin
                        mem_rd_addr <= addr;
                        mem_rd_req <= 1;
                        st <= ST_XPAY_RD;
                    end

                    ST_XPAY_RD: begin
                        if (len_cnt == 0) begin
                            st <= ST_DONE;
                        end else begin
                            if (rd_buf_valid) begin
                                len_cnt <= len_cnt - 16'd1;
                                rd_buf_valid <= 0;
                                if (len_cnt > 16'd1) begin
                                    mem_rd_addr <= sub_inc ? (addr + 24'd1) : addr;
                                    mem_rd_req <= 1;
                                    if (sub_inc) addr <= addr + 24'd1;
                                end
                            end
                        end
                    end

                    default: begin
                        st <= ST_IDLE;
                        rd_buf_valid <= 0;
                        status_ok <= 0;
                    end
                endcase
            end
        end
    end

endmodule
