// BL616 4-Wire SPI Protocol Processor (Mode 1: CPOL=0, CPHA=1)
// Uses SCLK as direct clock for shift registers (matches mcu_spi.v design)
// with toggle-based CDC to hand off bytes to the system clock domain FSM.
// Mode 1: data sampled on falling SCLK edge, shifted out on rising edge.
module bl616_spi_proto_proc #(
    parameter USE_CRC = 0
)(
    input  wire        clk,
    input  wire        rst_n,

    // SPI pins
    input  wire        spi_cs_n,
    input  wire        spi_sclk,
    input  wire        spi_mosi,
    output wire        spi_miso,

    // Register file interface
    output reg         reg_rd_req,
    output reg         reg_wr_req,
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

    // =========================================================
    // SPI CLOCK DOMAIN — RX shift register
    // Mode 1: sample MOSI on falling SCLK edge (negedge)
    // CS# high used as async reset for bit counter only.
    // spi_byte_toggle is NOT reset on CS# to avoid false CDC pulse.
    // =========================================================
    reg [2:0]  spi_bit_cnt;
    reg [6:0]  spi_rx_sr;
    reg [7:0]  spi_rx_byte;
    reg        spi_byte_toggle;

    always @(negedge spi_sclk or posedge spi_cs_n) begin
        if (spi_cs_n) begin
            spi_bit_cnt <= 3'd0;
        end else begin
            spi_rx_sr <= {spi_rx_sr[5:0], spi_mosi};
            spi_bit_cnt <= spi_bit_cnt + 3'd1;
            if (spi_bit_cnt == 3'd7) begin
                spi_rx_byte <= {spi_rx_sr, spi_mosi};
                spi_byte_toggle <= !spi_byte_toggle;
            end
        end
    end

    // =========================================================
    // SPI CLOCK DOMAIN — TX (MISO output)
    // Mode 1: master samples on negedge, so we shift out on posedge.
    // Registered output: spi_miso_r loaded from tx_byte on each
    // rising SCLK edge. CS# async-resets MISO high.
    //
    // spi_bit_cnt is incremented on negedge (RX block), so at each
    // posedge it holds the count from the previous negedge:
    //   posedge 0: bit_cnt=0 -> tx_byte[7] (MSB first)
    //   posedge 1: bit_cnt=1 -> tx_byte[6]
    //   ...
    //   posedge 7: bit_cnt=7 -> tx_byte[0]
    // =========================================================
    reg [7:0] tx_byte;
    reg       spi_miso_r;

    assign spi_miso = spi_miso_r;

    always @(posedge spi_sclk or posedge spi_cs_n) begin
        if (spi_cs_n) begin
            spi_miso_r <= 1'b1;
        end else begin
            spi_miso_r <= tx_byte[3'd7 - spi_bit_cnt];
        end
    end

    // =========================================================
    // CDC: Toggle synchronizer for byte-ready handoff
    // =========================================================
    reg [1:0] toggle_sync;
    reg       toggle_prev;
    wire      byte_rx_stb = toggle_sync[1] ^ toggle_prev;

    // 2FF sync for CS# (needed for FSM reset in system domain)
    reg cs_n_q1, cs_n_q2;
    wire cs_active = !cs_n_q2;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            toggle_sync <= 2'b00;
            toggle_prev <= 1'b0;
            cs_n_q1     <= 1'b1;
            cs_n_q2     <= 1'b1;
        end else begin
            toggle_sync <= {toggle_sync[0], spi_byte_toggle};
            toggle_prev <= toggle_sync[1];
            cs_n_q1     <= spi_cs_n;
            cs_n_q2     <= cs_n_q1;
        end
    end

    // =========================================================
    // Status byte
    // =========================================================
    localparam [7:0] PROTO_VER = 8'h01;
    reg status_crcerr, status_busy, status_ok;
    wire [7:0] status_byte = {PROTO_VER[3:0], 1'b0, status_crcerr, status_busy, status_ok};

    // =========================================================
    // FSM states (system clock domain)
    // =========================================================
    localparam [3:0]
        ST_IDLE        = 4'd0,
        ST_OPCODE      = 4'd1,
        ST_REG_RW      = 4'd2,
        ST_X0          = 4'd3,
        ST_XA0         = 4'd4,
        ST_XA1         = 4'd5,
        ST_XA2         = 4'd6,
        ST_XL0         = 4'd7,
        ST_XL1         = 4'd8,
        ST_XPAY_WR     = 4'd9,
        ST_XPAY_RD_DMY = 4'd10,
        ST_XPAY_RD     = 4'd11,
        ST_DONE        = 4'd12;
    reg [3:0] st;

    // Header fields
    reg        op_is_read;
    reg [6:0]  op_reg;
    reg [7:0]  sub0;
    reg [23:0] addr;
    reg [15:0] len, len_cnt;
    reg        sub_dir, sub_crc, sub_inc;
    reg [2:0]  sub_space;

    // Read pipeline
    reg [7:0] rd_buf;
    reg       rd_buf_valid;

    // Register read pipeline: reg_rdata is combinational from reg_idx,
    // but reg_idx uses non-blocking assignment, so reg_rdata reflects
    // the new address one cycle after reg_idx is set. We use a 2-stage
    // pipeline: set reg_idx on byte_rx_stb, capture reg_rdata next cycle.
    reg        reg_rd_pending;
    reg [7:0]  reg_read_value;

    // =========================================================
    // Main FSM (system clock domain)
    // =========================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st            <= ST_IDLE;
            tx_byte       <= 8'hFF;
            status_crcerr <= 1'b0;
            status_busy   <= 1'b0;
            status_ok     <= 1'b1;
            op_is_read    <= 1'b0;
            op_reg        <= 7'd0;
            sub0          <= 8'd0;
            addr          <= 24'd0;
            len           <= 16'd0;
            len_cnt       <= 16'd0;
            sub_dir       <= 1'b0;
            sub_crc       <= 1'b0;
            sub_inc       <= 1'b0;
            sub_space     <= 3'd0;
            rd_buf        <= 8'h00;
            rd_buf_valid  <= 1'b0;
            reg_rd_pending <= 1'b0;
            reg_read_value <= 8'h00;
            reg_rd_req    <= 1'b0;
            reg_wr_req    <= 1'b0;
            reg_idx       <= 7'd0;
            reg_wdata     <= 8'd0;
            mem_wr_en     <= 1'b0;
            mem_space     <= 3'd0;
            mem_wr_addr   <= 24'd0;
            mem_wr_data   <= 8'd0;
            mem_rd_req    <= 1'b0;
            mem_rd_space  <= 3'd0;
            mem_rd_addr   <= 24'd0;
        end else begin
            // One-shot clears
            reg_rd_req <= 1'b0;
            reg_wr_req <= 1'b0;
            mem_wr_en  <= 1'b0;
            mem_rd_req <= 1'b0;

            // Register read pipeline: capture reg_rdata one cycle after
            // reg_idx was set, then load it into tx_byte
            if (reg_rd_pending) begin
                reg_rd_pending <= 1'b0;
                tx_byte <= reg_rdata;
            end

            // CS# deassert -> IDLE, preload status for next transaction
            if (!cs_active) begin
                st             <= ST_IDLE;
                rd_buf_valid   <= 1'b0;
                reg_rd_pending <= 1'b0;
                tx_byte        <= status_byte;
            end else begin
                // Latch mem read data and update TX for read transfers
                if (mem_rd_valid) begin
                    rd_buf       <= mem_rd_data;
                    rd_buf_valid <= 1'b1;
                    if (st == ST_XPAY_RD || st == ST_XPAY_RD_DMY)
                        tx_byte <= mem_rd_data;
                end

                if (byte_rx_stb) begin
                    case (st)
                        ST_IDLE: begin
                            status_ok     <= 1'b1;
                            status_crcerr <= 1'b0;
                            status_busy   <= 1'b0;
                            rd_buf_valid  <= 1'b0;
                            op_is_read    <= spi_rx_byte[7];
                            op_reg        <= spi_rx_byte[6:0];
                            reg_idx       <= spi_rx_byte[6:0];
                            if (spi_rx_byte[6:0] != 7'd127) begin
                                if (spi_rx_byte[7]) begin
                                    // READ register: reg_idx set above,
                                    // reg_rdata valid next cycle
                                    reg_rd_pending <= 1'b1;
                                    st <= ST_REG_RW;
                                end else begin
                                    // WRITE register
                                    tx_byte <= status_byte;
                                    st <= ST_REG_RW;
                                end
                            end else begin
                                tx_byte <= status_byte;
                                st <= ST_X0;
                            end
                        end

                        ST_REG_RW: begin
                            if (op_is_read) begin
                                reg_rd_req <= 1'b1;
                                st <= ST_DONE;
                            end else begin
                                reg_wdata  <= spi_rx_byte;
                                reg_wr_req <= 1'b1;
                                st <= ST_DONE;
                            end
                            tx_byte <= status_byte;
                        end

                        ST_DONE: begin
                            // Back-to-back: treat next byte as opcode
                            rd_buf_valid <= 1'b0;
                            op_is_read   <= spi_rx_byte[7];
                            op_reg       <= spi_rx_byte[6:0];
                            reg_idx      <= spi_rx_byte[6:0];
                            if (spi_rx_byte[6:0] != 7'd127) begin
                                if (spi_rx_byte[7]) begin
                                    reg_rd_pending <= 1'b1;
                                    st <= ST_REG_RW;
                                end else begin
                                    tx_byte <= status_byte;
                                    st <= ST_REG_RW;
                                end
                            end else begin
                                tx_byte <= status_byte;
                                st <= ST_X0;
                            end
                        end

                        // XFER subheader
                        ST_X0: begin
                            sub0      <= spi_rx_byte;
                            sub_dir   <= spi_rx_byte[0];
                            sub_space <= spi_rx_byte[3:1];
                            sub_inc   <= spi_rx_byte[4];
                            sub_crc   <= spi_rx_byte[5];
                            addr      <= 24'd0;
                            len       <= 16'd0;
                            st <= ST_XA0;
                        end
                        ST_XA0: begin addr[7:0]   <= spi_rx_byte; st <= ST_XA1; end
                        ST_XA1: begin addr[15:8]  <= spi_rx_byte; st <= ST_XA2; end
                        ST_XA2: begin addr[23:16] <= spi_rx_byte; st <= ST_XL0; end
                        ST_XL0: begin len[7:0]    <= spi_rx_byte; st <= ST_XL1; end
                        ST_XL1: begin
                            len[15:8]    <= spi_rx_byte;
                            len_cnt      <= {spi_rx_byte, len[7:0]};
                            mem_space    <= sub_space;
                            mem_rd_space <= sub_space;
                            if (sub_dir) begin
                                tx_byte <= 8'hFF; // dummy byte for read
                                st <= ST_XPAY_RD_DMY;
                            end else begin
                                st <= ST_XPAY_WR;
                            end
                        end

                        // WRITE payload
                        ST_XPAY_WR: begin
                            if (len_cnt == 16'd0) begin
                                st <= ST_DONE;
                            end else begin
                                mem_wr_addr <= addr;
                                mem_wr_data <= spi_rx_byte;
                                mem_wr_en   <= 1'b1;
                                len_cnt <= len_cnt - 16'd1;
                                if (sub_inc) addr <= addr + 24'd1;
                                if (len_cnt == 16'd1) st <= ST_DONE;
                            end
                        end

                        // READ payload (dummy byte first)
                        ST_XPAY_RD_DMY: begin
                            mem_rd_addr <= addr;
                            mem_rd_req  <= 1'b1;
                            tx_byte     <= 8'hFF;
                            st <= ST_XPAY_RD;
                        end

                        ST_XPAY_RD: begin
                            if (len_cnt == 16'd0) begin
                                tx_byte <= status_byte;
                                st <= ST_DONE;
                            end else if (rd_buf_valid) begin
                                len_cnt      <= len_cnt - 16'd1;
                                rd_buf_valid <= 1'b0;
                                if (len_cnt > 16'd1) begin
                                    mem_rd_addr <= sub_inc ? (addr + 24'd1) : addr;
                                    mem_rd_req  <= 1'b1;
                                    if (sub_inc) addr <= addr + 24'd1;
                                end else begin
                                    tx_byte <= status_byte;
                                end
                                // tx_byte will be updated by mem_rd_valid handler above
                            end
                        end

                        default: st <= ST_IDLE;
                    endcase
                end
            end
        end
    end

endmodule
