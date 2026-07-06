// A2Mega - DDR3 implementation of Apple II shadow memory
//
// (c) 2023,2024,2025 Ed Anuff <ed@a2fpga.com>
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
// Unified DDR3 shadow memory for Apple II text, hires, and VGC aux data.
// Text ($0400-$0BFF) uses flat shadow format. Hires and VGC ($2000-$9FFF)
// use a unified 128-bit layout: one DDR3 burst = main + aux_2000 + aux_6000
// for 4 consecutive addresses. Single-entry burst cache for video reads.
//

module apple_memory #(
    parameter VGC_MEMORY = 0  // 1 = extend aux memory to 32KB for VGC, 0 = 16KB
) (
    a2bus_if.slave a2bus_if,
    a2mem_if.master a2mem_if,

    // DDR3 ports for shadow memory
    mem_port_if.client main_mem_if,    // CPU writes to DDR3
    mem_port_if.client video_mem_if,   // video gen reads from DDR3

    input [15:0] video_address_i,
    input video_bank_i,
    input video_rd_i,
    output [31:0] video_data_o,
    output video_ready_o,

    input vgc_active_i,
    input [12:0] vgc_address_i,
    input vgc_rd_i,
    output [31:0] vgc_data_o,
    output vgc_ready_o,

    // Debug: CPU shadow writes lost to a full shadow FIFO (sticky)
    output [7:0] dbg_shadow_drop_o,

    // Debug: read FSM snapshot {rd_pending, rd_is_vgc, cache_valid, 2'b0, rd_state}
    output [7:0] dbg_rd_state_o
);

    wire write_strobe = !a2bus_if.rw_n && a2bus_if.data_in_strobe;
    wire read_strobe = a2bus_if.rw_n && a2bus_if.data_in_strobe;

   // II Soft switches
    reg SWITCHES_II[8];
    assign a2mem_if.TEXT_MODE = SWITCHES_II[0];
    assign a2mem_if.MIXED_MODE = SWITCHES_II[1];
    assign a2mem_if.PAGE2 = SWITCHES_II[2];
    assign a2mem_if.HIRES_MODE = SWITCHES_II[3];
    assign a2mem_if.AN0 = SWITCHES_II[4];
    assign a2mem_if.AN1 = SWITCHES_II[5];
    assign a2mem_if.AN2 = SWITCHES_II[6];
    assign a2mem_if.AN3 = SWITCHES_II[7];

    // ][e auxilary switches
    reg SWITCHES_IIE[8];
    assign a2mem_if.STORE80 = SWITCHES_IIE[0];
    assign a2mem_if.RAMRD = SWITCHES_IIE[1];
    assign a2mem_if.RAMWRT = SWITCHES_IIE[2];
    assign a2mem_if.INTCXROM = SWITCHES_IIE[3];
    assign a2mem_if.ALTZP = SWITCHES_IIE[4];
    assign a2mem_if.SLOTC3ROM = SWITCHES_IIE[5];
    assign a2mem_if.COL80 = SWITCHES_IIE[6];
    assign a2mem_if.ALTCHAR = SWITCHES_IIE[7];


    reg INTC8ROM;
    assign a2mem_if.INTC8ROM = INTC8ROM;

    reg [2:0] SLOTROM;
    assign a2mem_if.SLOTROM = SLOTROM;

    // capture the soft switches
    always @(posedge a2bus_if.clk_logic or negedge a2bus_if.system_reset_n) begin
        if (!a2bus_if.system_reset_n) begin
            SWITCHES_II <= '{1'b1, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b1};
        end else if ((a2bus_if.phi1_posedge) && (a2bus_if.addr[15:4] == 12'hC05) && !a2bus_if.m2sel_n) begin
            SWITCHES_II[a2bus_if.addr[3:1]] <= a2bus_if.addr[0];
        end else if (!a2bus_if.rw_n && (a2bus_if.phi1_posedge) && (a2bus_if.addr == 16'hC068) && !a2bus_if.m2sel_n) begin
            SWITCHES_II[2] <= a2bus_if.data[6];
        end
    end

    always @(posedge a2bus_if.clk_logic or negedge a2bus_if.system_reset_n) begin
        if (!a2bus_if.system_reset_n) begin
            SWITCHES_IIE <= '{8{1'b0}};
        end else if (!a2bus_if.rw_n && (a2bus_if.phi1_posedge) && (a2bus_if.addr[15:4] == 12'hC00) && !a2bus_if.m2sel_n) begin
            SWITCHES_IIE[a2bus_if.addr[3:1]] <= a2bus_if.addr[0];
        end else if (!a2bus_if.rw_n && (a2bus_if.phi1_posedge) && (a2bus_if.addr == 16'hC068) && !a2bus_if.m2sel_n) begin
            SWITCHES_IIE[1] <= a2bus_if.data[5];
            SWITCHES_IIE[2] <= a2bus_if.data[4];
            SWITCHES_IIE[3] <= a2bus_if.data[0];
        end
    end

    always @(posedge a2bus_if.clk_logic or negedge a2bus_if.device_reset_n) begin
        if (!a2bus_if.device_reset_n) begin
            a2mem_if.BACKGROUND_COLOR <= 4'h0;
            a2mem_if.TEXT_COLOR <= 4'hF;
        end else if (write_strobe && (a2bus_if.addr == 16'hC022)) begin
            a2mem_if.BACKGROUND_COLOR <= a2bus_if.data[3:0];
            a2mem_if.TEXT_COLOR <= a2bus_if.data[7:4];
        end
    end

    always @(posedge a2bus_if.clk_logic or negedge a2bus_if.device_reset_n) begin
        if (!a2bus_if.device_reset_n) begin
            a2mem_if.BORDER_COLOR <= 4'h0;
        end else if (write_strobe && (a2bus_if.addr == 16'hC034)) begin
            a2mem_if.BORDER_COLOR <= a2bus_if.data[3:0];
        end
    end

    always @(posedge a2bus_if.clk_logic or negedge a2bus_if.system_reset_n) begin
        if (!a2bus_if.system_reset_n) begin
            a2mem_if.MONOCHROME_MODE <= 1'b0;
        end else if (write_strobe && (a2bus_if.addr == 16'hC021)) begin
            a2mem_if.MONOCHROME_MODE <= a2bus_if.data[7];
        end
    end

    always @(posedge a2bus_if.clk_logic or negedge a2bus_if.system_reset_n) begin
        if (!a2bus_if.system_reset_n) begin
            a2mem_if.MONOCHROME_DHIRES_MODE <= 1'b0;
            a2mem_if.LINEARIZE_MODE <= 1'b0;
            a2mem_if.SHRG_MODE <= 1'b0;
        end else if (write_strobe && (a2bus_if.addr == 16'hC029)) begin
            a2mem_if.MONOCHROME_DHIRES_MODE <= a2bus_if.data[5];
            a2mem_if.LINEARIZE_MODE <= a2bus_if.data[6] | a2bus_if.data[7];
            a2mem_if.SHRG_MODE <= a2bus_if.data[7];
        end
    end

    always @(posedge a2bus_if.clk_logic or negedge a2bus_if.system_reset_n) begin
        if (!a2bus_if.system_reset_n) begin
            INTC8ROM <= 1'b0;
            SLOTROM <= 3'b0;
        end else if ((a2bus_if.phi1_posedge) && (a2bus_if.addr == 16'hCFFF) && !a2bus_if.m2sel_n) begin
            INTC8ROM <= 1'b0;
            SLOTROM <= 3'b0;
        end else if ((a2bus_if.phi1_posedge) && (a2bus_if.addr >= 16'hC100) && (a2bus_if.addr < 16'hC800) && !a2bus_if.m2sel_n) begin
            if (!a2mem_if.SLOTC3ROM && (a2bus_if.addr[15:8] == 8'hC3)) INTC8ROM <= 1'b1; // Slot C3 ROM
            SLOTROM <= a2bus_if.addr[10:8];
        end
    end

    reg [7:0] keycode_r;
    reg keypress_strobe_r;

    always @(posedge a2bus_if.clk_logic or negedge a2bus_if.system_reset_n) begin
        if (!a2bus_if.system_reset_n) begin
            keycode_r <= 8'h00;
            keypress_strobe_r <= 1'b0;
        end else begin
            keypress_strobe_r <= 1'b0;
            if (read_strobe && (a2bus_if.addr == 16'hC000)) begin
                if (a2bus_if.data[7] & !keycode_r[7]) begin
                    keycode_r <= a2bus_if.data;
                    keypress_strobe_r <= 1'b1;
                end
            end else if (a2bus_if.data_in_strobe && (a2bus_if.addr == 16'hC010)) begin
                keycode_r[7] <= 1'b0;
            end
        end
    end

    assign a2mem_if.keycode = keycode_r;
    assign a2mem_if.keypress_strobe = keypress_strobe_r;

    logic aux_mem_r;

    always_comb begin
        aux_mem_r = 1'b0;
        if (a2bus_if.addr[15:9] == 7'b0000000 | a2bus_if.addr[15:14] == 2'b11)		// Page 00,01,C0-FF
            aux_mem_r = a2mem_if.ALTZP;
        else if (a2bus_if.addr[15:10] == 6'b000001)		// Page 04-07
            aux_mem_r = (a2mem_if.STORE80 & a2mem_if.PAGE2) | ((~a2mem_if.STORE80) & (a2mem_if.RAMWRT & !a2bus_if.rw_n));
        else if (a2bus_if.addr[15:13] == 3'b001)		// Page 20-3F
            aux_mem_r = (a2mem_if.STORE80 & a2mem_if.PAGE2 & a2mem_if.HIRES_MODE) | (((~a2mem_if.STORE80) | (~a2mem_if.HIRES_MODE)) & (a2mem_if.RAMWRT & !a2bus_if.rw_n));
        else
            aux_mem_r = (a2mem_if.RAMWRT & !a2bus_if.rw_n);
    end
    assign a2mem_if.aux_mem = aux_mem_r;

    wire E1 = aux_mem_r || a2bus_if.m2b0;

    wire [31:0] write_word = {a2bus_if.data, a2bus_if.data, a2bus_if.data, a2bus_if.data};

    // Apple II bus address ranges
    wire bus_addr_0400_0BFF = a2bus_if.addr[15:10] inside {6'b000001, 3'b000010};
    wire bus_addr_2000_5FFF = a2bus_if.addr[15:13] inside {3'b001, 3'b010};
    wire bus_addr_6000_9FFF = a2bus_if.addr[15:13] inside {3'b011, 3'b100};
    wire bus_addr_2000_9FFF = bus_addr_2000_5FFF || bus_addr_6000_9FFF;

    wire [14:0] hires_write_offset = 15'({3'(a2bus_if.addr[15:13] - 1'b1), a2bus_if.addr[12:0]});

    function automatic [31:0] interleave_mux(input hi, input [31:0] data_a, input [31:0] data_b);
        logic [31:0] result = 0;
        if (hi) result = {data_b[31:24], data_a[31:24], data_b[23:16], data_a[23:16]};
        else result = {data_b[15:8], data_a[15:8], data_b[7:0], data_a[7:0]};
        return result;
    endfunction

    // =========================================================================
    // Unified DDR3 layout — each 128-bit burst stores 4 consecutive addresses:
    //   Word 0: main bytes      Word 1: (padding)
    //   Word 2: aux $2000-$5FFF Word 3: aux $6000-$9FFF
    // =========================================================================

    localparam [20:0] UNIFIED_OFFSET = 21'h010000;  // above flat shadow region

    // =========================================================================
    // DDR3 write path — text to flat shadow, $2000+ to unified region
    // =========================================================================

    wire is_text_write = bus_addr_0400_0BFF;
    wire is_unified_write = bus_addr_2000_5FFF || (bus_addr_6000_9FFF && E1);

    // Compute unified group R, word (slot), and byte within the 128-bit line
    logic [11:0] unified_group;
    logic [1:0]  unified_word;
    logic [1:0]  unified_byte;

    always_comb begin
        unified_group = 12'b0;
        unified_word  = 2'b0;
        unified_byte  = 2'b0;

        if (a2mem_if.LINEARIZE_MODE && bus_addr_2000_9FFF && E1) begin
            // Linearize mode: aux $2000-$9FFF interleaved by bit 0
            unified_group = hires_write_offset[14:3];
            unified_word  = hires_write_offset[0] ? 2'd3 : 2'd2;
            unified_byte  = hires_write_offset[2:1];
        end else if (bus_addr_2000_5FFF) begin
            // Non-linearize: main→word 0, aux→word 2
            unified_group = hires_write_offset[13:2];
            unified_word  = E1 ? 2'd2 : 2'd0;
            unified_byte  = hires_write_offset[1:0];
        end else if (bus_addr_6000_9FFF) begin
            // Non-linearize: aux $6000-$9FFF → word 3
            unified_group = hires_write_offset[13:2];
            unified_word  = 2'd3;
            unified_byte  = hires_write_offset[1:0];
        end
    end

    wire [20:0] unified_write_addr = UNIFIED_OFFSET + {7'b0, unified_group, unified_word};
    wire [3:0]  unified_byte_en    = 4'(1 << unified_byte);

    // Mux between text (flat shadow) and unified ($2000+) addressing.
    // NOTE: the text WRITE path never encodes a video bank, while the text
    // READ path muxes on video_bank_i. On a2mega video_bank_i is constant 0
    // (video_control_if.enable tied off in top.sv); if a video-control
    // override is ever enabled, bank-1 text reads would hit unwritten DDR3 —
    // tie the read bank to 0 or add bank encoding here first.
    wire [20:0] write_addr = is_text_write ?
        {6'b0, a2bus_if.addr[15:1]} : unified_write_addr;
    wire [3:0]  write_byte_en = is_text_write ?
        4'(1 << {a2bus_if.addr[0], aux_mem_r || a2bus_if.m2b0}) : unified_byte_en;

    wire write_en = write_strobe && !a2bus_if.m2sel_n &&
        (is_text_write || is_unified_write);

    // Shadow write FIFO — replaces the single-slot deferral, which LOST
    // writes in two collision cases (the cause of permanently wrong/dropped
    // pixels until the CPU rewrote the location):
    //   1. A new write_en while a deferred write waited and the port was
    //      busy overwrote the deferred slot — older write lost.
    //   2. A new write_en on the same cycle the deferred write drained was
    //      never stored — new write lost.
    // All writes now transit the FIFO in strict order. Depth 8 absorbs
    // worst-case port-busy stretches (~1µs behind an 8-beat FB read burst)
    // at the CPU's ~0.36-1µs/write rate. Forced to registers: the head and
    // the coherency scan below need combinational access to all entries.
    localparam SW_FIFO_DEPTH = 8;
    localparam SW_FIFO_ADDR_BITS = 3;
    // Entry: {byte_en[56:53], addr[52:32], data[31:0]}
    reg [56:0] sw_fifo [0:SW_FIFO_DEPTH-1] /* synthesis syn_ramstyle="registers" */;
    reg [SW_FIFO_DEPTH-1:0] sw_valid_r;
    reg [SW_FIFO_ADDR_BITS:0] sw_wr_ptr_r, sw_rd_ptr_r;
    reg [7:0] dbg_shadow_drop_r;  // Sticky: writes lost to a full FIFO

    wire sw_empty_w = (sw_wr_ptr_r == sw_rd_ptr_r);
    wire [SW_FIFO_ADDR_BITS:0] sw_count_w = sw_wr_ptr_r - sw_rd_ptr_r;
    wire sw_full_w = sw_count_w[SW_FIFO_ADDR_BITS];
    wire sw_push_w = write_en && !sw_full_w;
    wire sw_pop_w  = !sw_empty_w && main_mem_if.available;
    wire [56:0] sw_head_w = sw_fifo[sw_rd_ptr_r[SW_FIFO_ADDR_BITS-1:0]];

    always @(posedge a2bus_if.clk_logic or negedge a2bus_if.system_reset_n) begin
        if (!a2bus_if.system_reset_n) begin
            sw_wr_ptr_r <= '0;
            sw_rd_ptr_r <= '0;
            sw_valid_r  <= '0;
            dbg_shadow_drop_r <= 8'd0;
        end else begin
            if (sw_push_w) begin
                sw_fifo[sw_wr_ptr_r[SW_FIFO_ADDR_BITS-1:0]] <= {write_byte_en, write_addr, write_word};
                sw_valid_r[sw_wr_ptr_r[SW_FIFO_ADDR_BITS-1:0]] <= 1'b1;
                sw_wr_ptr_r <= sw_wr_ptr_r + 1'd1;
            end
            if (sw_pop_w) begin
                sw_valid_r[sw_rd_ptr_r[SW_FIFO_ADDR_BITS-1:0]] <= 1'b0;
                sw_rd_ptr_r <= sw_rd_ptr_r + 1'd1;
            end
            if (write_en && sw_full_w && dbg_shadow_drop_r != 8'hFF)
                dbg_shadow_drop_r <= dbg_shadow_drop_r + 8'd1;
        end
    end

    assign main_mem_if.rd      = 1'b0;
    assign main_mem_if.burst   = 1'b0;
    assign main_mem_if.wr      = sw_pop_w;
    assign main_mem_if.addr    = sw_head_w[52:32];
    assign main_mem_if.data    = sw_head_w[31:0];
    assign main_mem_if.byte_en = sw_head_w[56:53];
    assign dbg_shadow_drop_o   = dbg_shadow_drop_r;

    // =========================================================================
    // DDR3 read path — burst cache for unified region, passthrough for text
    // =========================================================================

    // Read address classification
    wire is_text_read  = !vgc_active_i && (video_address_i < 16'h2000);
    wire is_hires_read = !vgc_active_i && (video_address_i >= 16'h2000);
    wire is_vgc_read   = vgc_active_i;

    // Compute group R for cache lookup
    wire [14:0] hires_read_offset = {(video_address_i[15:13] - 1'b1), video_address_i[12:0]};
    wire [11:0] video_group = hires_read_offset[13:2];
    wire [11:0] vgc_group   = vgc_address_i[12:1];
    wire [11:0] read_group  = is_vgc_read ? vgc_group : video_group;

    // Single-entry burst cache: 4 × 32-bit words + 12-bit tag
    reg [31:0] cache_r [0:3];
    reg [11:0] cache_tag_r;
    reg        cache_valid_r;

    wire cache_hit = cache_valid_r && (cache_tag_r == read_group);

    // Cache invalidation: snoop writes to unified region
    wire [11:0] wr_unified_group = unified_group;
    wire cache_inv_write = cache_valid_r && write_en && is_unified_write &&
                           (cache_tag_r == wr_unified_group);

    // Read state machine
    localparam RD_IDLE       = 3'd0;
    localparam RD_TEXT_WAIT  = 3'd1;  // Non-burst text read in flight
    localparam RD_BURST_WAIT = 3'd2;  // Burst read filling cache
    localparam RD_HIT_RESP   = 3'd3;  // Cache hit, 1-cycle ready pulse

    reg [2:0]  rd_state_r;
    reg [1:0]  burst_cnt_r;
    reg        rd_is_vgc_r;         // Which requester gets the response
    reg [14:0] rd_hires_offset_r;   // Latched for format conversion
    reg [12:0] rd_vgc_addr_r;       // Latched for VGC extraction

    // Pending read retry (port busy when rd pulse fires)
    reg        rd_pending_r;
    reg [20:0] rd_pending_addr_r;
    reg        rd_pending_burst_r;
    reg        rd_pending_vgc_r;
    reg [14:0] rd_pending_hires_r;
    reg [12:0] rd_pending_vgc_addr_r;

    // Cache-coherency: snoop writes to the in-flight burst tag.
    //
    // RACE BUG (without this): cache_inv_write checks cache_tag_r, but during
    // RD_BURST_WAIT cache_tag_r still holds the OLD tag — the NEW tag isn't
    // committed until burst_cnt_r==3. If the CPU writes to the NEW tag while
    // the burst is in flight, no invalidation fires, the burst loads
    // pre-write data, and cache_valid_r is set with stale data. For static
    // content (e.g. a splash screen written once and then displayed), the
    // stale entry never gets invalidated by another write and persists
    // indefinitely as wrong-color pixels.
    //
    // Fix: track an in-flight stale flag, set it whenever a write hits the
    // tag currently being burst-loaded, and gate cache_valid_r at burst end.
    // The in-flight tag itself is already held in rd_is_vgc_r / rd_vgc_addr_r
    // / rd_hires_offset_r (latched at issue time, valid throughout RD_BURST_WAIT).
    //
    // There are TWO classes of racing writes we need to catch:
    //   1. write_en pulses during RD_BURST_WAIT (or same cycle as issue).
    //      These are new Apple-II bus writes that hit the in-flight tag.
    //   2. the shadow write FIFO already holding a queued write to the
    //      in-flight tag at burst issue time. This happens when an earlier
    //      write couldn't issue because main_mem_if was busy (async CDC
    //      handshake), and the deferred write hasn't drained yet. The
    //      write_en pulse for this write already fired in a PRIOR cycle
    //      (before rd_state_r was RD_BURST_WAIT), so burst_snoop_hit_w
    //      won't catch it — we must consult the shadow FIFO directly.
    //
    // Unified-region addresses are of the form UNIFIED_OFFSET (0x010000) +
    // {7'b0, group[11:0], word[1:0]}, so bit[16] set identifies unified and
    // bits[13:2] are the tag.
    reg burst_data_stale_r;
    wire [11:0] inflight_burst_tag_w = rd_is_vgc_r ? rd_vgc_addr_r[12:1]
                                                   : rd_hires_offset_r[13:2];
    wire burst_snoop_hit_w = (rd_state_r == RD_BURST_WAIT) && write_en &&
                             is_unified_write &&
                             (inflight_burst_tag_w == wr_unified_group);

    // Helper: check whether ANY queued shadow write targets a given tag.
    // Used at burst-issue / pending-retry time before rd_is_vgc_r / rd_*_r
    // have been latched. Scans all occupied shadow-FIFO entries — a queued
    // write that hasn't drained is exactly as stale-producing as the old
    // single-slot deferred write was. Packed entry: addr[16] = bit 48,
    // addr[13:2] = bits [45:34].
    function automatic shadow_pending_matches(input [11:0] tag);
        integer i;
        begin
            shadow_pending_matches = 1'b0;
            for (i = 0; i < SW_FIFO_DEPTH; i = i + 1) begin
                if (sw_valid_r[i] && sw_fifo[i][48] && (sw_fifo[i][45:34] == tag))
                    shadow_pending_matches = 1'b1;
            end
        end
    endfunction

    // Combinational: DDR3 read address for new requests
    wire [20:0] text_rd_addr   = {5'b0, video_bank_i, video_address_i[15:1]};
    wire [20:0] unified_rd_addr = UNIFIED_OFFSET + {7'b0, read_group, 2'b00};

    // New read request detection
    wire new_text_rd  = is_text_read  && video_rd_i && (rd_state_r == RD_IDLE) && !rd_pending_r;
    wire new_hires_rd = is_hires_read && video_rd_i && (rd_state_r == RD_IDLE) && !rd_pending_r;
    wire new_vgc_rd   = is_vgc_read   && vgc_rd_i  && (rd_state_r == RD_IDLE) && !rd_pending_r;

    // Issue DDR3 read (text non-burst or unified burst on cache miss)
    wire issue_text_rd  = new_text_rd;
    wire issue_burst_rd = (new_hires_rd || new_vgc_rd) && !cache_hit;

    // Ready output signals
    reg video_ready_r;
    reg vgc_ready_r;

    // Data output registers
    reg [31:0] video_data_r;
    reg [31:0] vgc_data_r;

    // Format conversion: extract {main_odd, aux_odd, main_even, aux_even}
    // from cached words 0 (main) and 2 (aux_2000)
    function automatic [31:0] format_hires_data(input [14:0] offset, input [31:0] w_main, input [31:0] w_aux);
        logic [31:0] result;
        if (offset[1] == 1'b0)  // addresses off+0, off+1
            result = {w_main[15:8], w_aux[15:8], w_main[7:0], w_aux[7:0]};
        else                     // addresses off+2, off+3
            result = {w_main[31:24], w_aux[31:24], w_main[23:16], w_aux[23:16]};
        return result;
    endfunction

    always @(posedge a2bus_if.clk_logic or negedge a2bus_if.system_reset_n) begin
        if (!a2bus_if.system_reset_n) begin
            rd_state_r    <= RD_IDLE;
            burst_cnt_r   <= 2'd0;
            cache_valid_r <= 1'b0;
            cache_tag_r   <= 12'd0;
            rd_is_vgc_r   <= 1'b0;
            rd_pending_r  <= 1'b0;
            video_ready_r <= 1'b0;
            vgc_ready_r   <= 1'b0;
            video_data_r  <= 32'd0;
            vgc_data_r    <= 32'd0;
            rd_hires_offset_r    <= 15'd0;
            rd_vgc_addr_r        <= 13'd0;
            rd_pending_addr_r    <= 21'd0;
            rd_pending_burst_r   <= 1'b0;
            rd_pending_vgc_r     <= 1'b0;
            rd_pending_hires_r   <= 15'd0;
            rd_pending_vgc_addr_r <= 13'd0;
            burst_data_stale_r   <= 1'b0;
        end else begin
            // Default: clear ready pulses each cycle
            video_ready_r <= 1'b0;
            vgc_ready_r   <= 1'b0;

            // Cache invalidation on writes to same unified group
            if (cache_inv_write)
                cache_valid_r <= 1'b0;

            // Pending read retry: if we captured a request while port was busy,
            // try to issue it now
            if (rd_pending_r && video_mem_if.available && rd_state_r == RD_IDLE) begin
                rd_pending_r <= 1'b0;
                rd_is_vgc_r  <= rd_pending_vgc_r;
                rd_hires_offset_r <= rd_pending_hires_r;
                rd_vgc_addr_r     <= rd_pending_vgc_addr_r;
                if (rd_pending_burst_r) begin
                    rd_state_r <= RD_BURST_WAIT;
                    // Catch a same-cycle write to the tag we're about to load,
                    // AND any deferred write still queued in the shadow FIFO
                    // for the same tag. The write port and read port are on
                    // independent CDC handshakes, so the arbiter may service
                    // them in either order — treat coincident activity as
                    // stale-producing.
                    burst_data_stale_r <=
                        (write_en && is_unified_write &&
                         ((rd_pending_vgc_r ? rd_pending_vgc_addr_r[12:1]
                                            : rd_pending_hires_r[13:2]) == wr_unified_group)) ||
                        shadow_pending_matches(rd_pending_vgc_r ? rd_pending_vgc_addr_r[12:1]
                                                                : rd_pending_hires_r[13:2]);
                end else
                    rd_state_r <= RD_TEXT_WAIT;
                burst_cnt_r <= 2'd0;
            end else begin
                case (rd_state_r)
                    RD_IDLE: begin
                        if (issue_text_rd) begin
                            if (video_mem_if.available) begin
                                rd_state_r <= RD_TEXT_WAIT;
                            end else begin
                                // Port busy — latch for retry
                                rd_pending_r          <= 1'b1;
                                rd_pending_addr_r     <= text_rd_addr;
                                rd_pending_burst_r    <= 1'b0;
                                rd_pending_vgc_r      <= 1'b0;
                                rd_pending_hires_r    <= 15'd0;
                                rd_pending_vgc_addr_r <= 13'd0;
                            end
                        end else if (issue_burst_rd) begin
                            rd_is_vgc_r       <= is_vgc_read;
                            rd_hires_offset_r <= hires_read_offset;
                            rd_vgc_addr_r     <= vgc_address_i;
                            if (video_mem_if.available) begin
                                burst_cnt_r <= 2'd0;
                                rd_state_r  <= RD_BURST_WAIT;
                                // Catch a same-cycle write to the new burst's
                                // tag AND any deferred write still sitting in
                                // the shadow FIFO for the same tag.
                                // (read_group is the combinational tag for this issue.)
                                burst_data_stale_r <=
                                    (write_en && is_unified_write &&
                                     (read_group == wr_unified_group)) ||
                                    shadow_pending_matches(read_group);
                            end else begin
                                // Port busy — latch for retry
                                rd_pending_r          <= 1'b1;
                                rd_pending_addr_r     <= unified_rd_addr;
                                rd_pending_burst_r    <= 1'b1;
                                rd_pending_vgc_r      <= is_vgc_read;
                                rd_pending_hires_r    <= hires_read_offset;
                                rd_pending_vgc_addr_r <= vgc_address_i;
                            end
                        end else if ((new_hires_rd || new_vgc_rd) && cache_hit) begin
                            // Cache hit — respond next cycle
                            rd_is_vgc_r       <= is_vgc_read;
                            rd_hires_offset_r <= hires_read_offset;
                            rd_vgc_addr_r     <= vgc_address_i;
                            rd_state_r        <= RD_HIT_RESP;
                        end
                    end

                    RD_TEXT_WAIT: begin
                        if (video_mem_if.ready) begin
                            video_data_r  <= video_mem_if.q;
                            video_ready_r <= 1'b1;
                            rd_state_r    <= RD_IDLE;
                        end
                    end

                    RD_BURST_WAIT: begin
                        // Snoop writes to the in-flight burst tag during the
                        // entire load (in-flight tag = inflight_burst_tag_w).
                        // burst_snoop_hit_w is gated by (rd_state_r == RD_BURST_WAIT).
                        if (burst_snoop_hit_w)
                            burst_data_stale_r <= 1'b1;

                        if (video_mem_if.ready) begin
                            cache_r[burst_cnt_r] <= video_mem_if.q;
                            if (burst_cnt_r == 2'd3) begin
                                cache_tag_r   <= inflight_burst_tag_w;
                                // Combine accumulated stale flag with same-cycle
                                // snoop so a write happening on the very last
                                // beat is not lost (the second non-blocking
                                // assignment to burst_data_stale_r below would
                                // otherwise win).
                                cache_valid_r <= !(burst_data_stale_r || burst_snoop_hit_w);
                                burst_data_stale_r <= 1'b0;
                                rd_state_r    <= RD_HIT_RESP;
                            end
                            burst_cnt_r <= burst_cnt_r + 2'd1;
                        end
                    end

                    RD_HIT_RESP: begin
                        // Provide formatted data and pulse ready
                        if (rd_is_vgc_r) begin
                            vgc_data_r  <= interleave_mux(rd_vgc_addr_r[0],
                                                          cache_r[2], cache_r[3]);
                            vgc_ready_r <= 1'b1;
                        end else begin
                            video_data_r  <= format_hires_data(rd_hires_offset_r,
                                                               cache_r[0], cache_r[2]);
                            video_ready_r <= 1'b1;
                        end
                        rd_state_r <= RD_IDLE;
                    end

                    default: rd_state_r <= RD_IDLE;
                endcase
            end
        end
    end

    // Drive video_mem_if for DDR3 reads
    // Text: non-burst read. Burst: read with burst=1 at group-aligned address.
    wire do_text_issue  = issue_text_rd  && video_mem_if.available;
    wire do_burst_issue = issue_burst_rd && video_mem_if.available;
    wire do_pending_issue = rd_pending_r && video_mem_if.available && (rd_state_r == RD_IDLE);

    assign video_mem_if.wr      = 1'b0;
    assign video_mem_if.data    = 32'b0;
    assign video_mem_if.byte_en = 4'b1111;
    assign video_mem_if.rd      = do_text_issue || do_burst_issue || do_pending_issue;
    assign video_mem_if.burst   = do_burst_issue || (do_pending_issue && rd_pending_burst_r);
    assign video_mem_if.addr    = do_pending_issue ? rd_pending_addr_r :
                                  do_burst_issue   ? unified_rd_addr :
                                                     text_rd_addr;

    // Output assignments — text uses registered data from DDR3, hires/VGC from cache
    assign video_data_o  = (rd_state_r == RD_TEXT_WAIT) ? video_mem_if.q : video_data_r;
    assign video_ready_o = video_ready_r;
    assign vgc_data_o    = vgc_data_r;
    assign vgc_ready_o   = vgc_ready_r;

    assign dbg_rd_state_o = {rd_pending_r, rd_is_vgc_r, cache_valid_r, 2'b00, rd_state_r};

endmodule
