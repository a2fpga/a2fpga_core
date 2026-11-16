//
// IIgs GLU
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
// The GLU interfaces the Ensoniq DOC5503 sound chip to the Apple II bus
//

module sound_glu #(
    parameter bit ENABLE = 1'b1,
    parameter bit MONO_MIX = 1'b0, // If true, mono mix is used instead of stereo
    parameter bit USE_BSRAM = 1'b0, // If true, use on-chip BSRAM instead of DDR3 for sound RAM
    // If true (and USE_BSRAM=0), use the pipelined-fetch DOC5503 variant that
    // tolerates DDR3 read latency (issue at service slot N, consume at N+1).
    // See boards/a2mega/docs/ensoniq_ddr3_pipelined_design.md.
    parameter bit USE_DDR3_PIPELINED = 1'b0,
    // Passed to doc5503_pipelined: 1 = oscillator register banks in DPB
    // BSRAMs (rev 3.3+), 0 = rev-3.2-style FF banks with baseline read
    // timing (hardware discriminator for the register-path question).
    // Default 0 = oscillator register banks in flops, as every board ran
    // before 2026-10-22. The a2p25 (GW5A-25, logic-bound) passes 1 and the
    // a2mega passes 0 explicitly; a default of 1 silently moved the Tang Nano
    // boards' banks into BSRAM (+8 blocks: Enhanced classic 44 -> 46/46).
    parameter bit DOC_BANKS_IN_BSRAM = 1'b0,
    // gen_doc_ext word cache: 0 = whole-cache flush on every sound-RAM write
    // (hardware control build), 1 = per-word invalidation.
    parameter bit DOC_CACHE_PER_WORD_INVALIDATE = 1'b1,
    parameter bit DOC_CACHE_HIT_DISABLE = 1'b0,   // diagnostic, see doc_fetch_cache
    // Output stage gain: audio = sat16(mix <<< OUTPUT_BOOST_SHIFT).
    // Default 1 preserves the field-validated GS x2 loudness — but now
    // CLAMPED instead of wrapping (tracker-class music with 8-14 voices
    // wrapped audibly; see design doc 12.17).
    parameter int OUTPUT_BOOST_SHIFT = 1,
    // Honor the $C03C[3:0] master volume as linear amplitude:
    // out = mix * (vol+1)/16 (INFERRED mapping — the original commented-out
    // shift mapping was defective; needs hardware listening validation
    // before enabling by default).
    parameter bit ENABLE_MASTER_VOLUME = 1'b0,
    // How the sound-RAM write queue knows a write was taken.
    //   0 = `ready` pulse (hdl/sdram/mem_port_cdc.sv — a2n20v2-GS: the
    //       SDRAM CDC pulses ready on write completion).
    //   1 = `available` handshake (hdl/ddr3/ddr3_port_cdc.sv — a2mega:
    //       the DDR3 arbiter's S_WRITE goes straight to S_DONE and NEVER
    //       asserts resp_valid, so client_ready NEVER pulses for a write.
    //       Waiting on it wedges the queue: `wr` sticks high, the
    //       level-sensitive CDC re-fires the same write forever, the read
    //       pointer never advances, and every later sample byte is
    //       dropped — the wavetable in DDR3 is never written.)
    parameter bit GLU_WR_ACK_AVAIL = 1'b0
) (
    a2bus_if.slave a2bus_if,

    output [7:0] data_o,
    output rd_en_o,

    output [15:0] audio_l_o,
    output [15:0] audio_r_o,

    output [7:0] debug_osc_en_o,  // Debug output for oscillator enable register
    output [1:0] debug_osc_mode_o[8], // Debug output for oscillator mode register;
    output [7:0] debug_osc_halt_o, // Debug output for oscillator halt register

    mem_port_if.client glu_mem_if,
    mem_port_if.client doc_mem_if,

    // Pipelined-DOC FB-aware issue gating (rev 3): high while the
    // framebuffer line fetch is actively issuing bursts. Tie 0 if unused
    // (gating disabled; correctness unaffected).
    input fb_fetch_active_i,

    output [7:0] glu_wq_drops_o,  // sound-RAM write-queue overflow drops (diagnostics)

    // Pipelined-DOC diagnostics (all zero in USE_DDR3_PIPELINED=0 configs).
    // Expected all-zero on hardware in steady state; see design doc.
    output [7:0] dbg_doc_prime_miss_o,
    output [7:0] dbg_doc_stale_fetch_o,
    output [7:0] dbg_doc_fetch_drop_o,
    output [15:0] dbg_doc_fetch_count_o,
    output [15:0] dbg_doc_timeouts_o,    // baseline DOC on external memory: fetches past the slot deadline (free-running)
    output [7:0] dbg_doc_frame_resync_o,  // rev 3.9 beat-framing resyncs

    // Ground-truth instrumentation at the DOC wave_* seam — measures the
    // DOC's ACTUAL memory-request behavior identically in BSRAM and
    // DDR3-pipelined configs (doc_mem_rd_w is the request strobe in both),
    // so numbers are directly comparable across builds.
    input  dbg_frame_tick_i,             // 1-cycle pulse per video frame
    output [15:0] dbg_doc_req_count_o,   // free-running request counter
    output [7:0]  dbg_doc_req_mingap_o   // min clk_logic cycles between
                                         // requests since last frame tick
                                         // (x18.5 ns; 0xFF = none seen)
);

    reg [7:0] sound_control_r;      // Sound Control Register
    reg [7:0] sound_data_r;         // Sound Data Register 
    reg [7:0] sound_ptr_lo_r;       // Sound Pointer Lo Register
    reg [7:0] sound_ptr_hi_r;       // Sound Pointer Hi Register

    localparam [15:0] SOUND_CONTROL_ADDR = 16'hC03C;
    localparam [15:0] SOUND_DATA_ADDR = 16'hC03D;
    localparam [15:0] SOUND_PTR_LO_ADDR = 16'hC03E;
    localparam [15:0] SOUND_PTR_HI_ADDR = 16'hC03F;

    // address in GLU range, $C03C-$C03F, during phi0 and m2sel_n asserted
    wire glu_sel_w = ENABLE & a2bus_if.phi0 & (a2bus_if.addr[15:2] == SOUND_CONTROL_ADDR[15:2]) & !a2bus_if.m2sel_n;
    // sound control register is at $C03C
    wire sc_sel_w = glu_sel_w & (a2bus_if.addr[1:0] == 2'b00);
    // sound data register is at $C03D
    wire sd_sel_w = glu_sel_w & (a2bus_if.addr[1:0] == 2'b01);
    // address pointer lo register is at $C03E
    wire spl_sel_w = glu_sel_w & (a2bus_if.addr[1:0] == 2'b10);
    // address pointer hi register is at $C03F
    wire sph_sel_w = glu_sel_w & (a2bus_if.addr[1:0] == 2'b11);

    // all accesses are to the dedicated 64K sound RAM
    wire access_ram_w = sound_control_r[6];
    // all accesses are to the DOC
    wire access_doc_w = ~access_ram_w;
    // auto increment address pointer
    wire auto_inc_w = sound_control_r[5];
    // volume control, 0 is lowest, 15 is highest
    wire [3:0] volume_w = sound_control_r[3:0];

    //assign rd_en_o = glu_sel_w & a2bus_if.rw_n;
    assign rd_en_o = 1'b0;

    logic [7:0] doc_data_o_w;

    assign data_o = a2bus_if.addr[1:0] == 2'b00 ? sound_control_r :
        (a2bus_if.addr[1:0] == 2'b01) & access_ram_w ? sound_data_r :
        (a2bus_if.addr[1:0] == 2'b01) & access_doc_w ? doc_data_o_w :
        a2bus_if.addr[1:0] == 2'b10 ? sound_ptr_lo_r :
        sound_ptr_hi_r;

    // write only for a2fpga, will need to implement reads at alternate address
    // and for future standalone IIgs core
    // DOC memory is at 0x4_0000/8 or 0x1_0000/32
    reg [20:0] glu_mem_addr_r;
    reg glu_mem_wr_r;
    reg [3:0] glu_mem_byte_en_r;

    // GLU mem_if driven to DDR3 when USE_BSRAM=0, idle when USE_BSRAM=1
    generate
        if (USE_BSRAM) begin : gen_glu_idle
            assign glu_wq_drops_o = 8'd0;
            assign glu_wq_pop_w = 1'b0;
            assign glu_wq_pop_waddr_w = 14'd0;
            assign glu_mem_if.rd = '0;
            assign glu_mem_if.wr = '0;
            assign glu_mem_if.addr = '0;
            assign glu_mem_if.data = '0;
            assign glu_mem_if.byte_en = '0;
            assign glu_mem_if.burst = 1'b0;
        end else begin : gen_glu_ddr3
            // Sound-RAM uploads arrive as back-to-back 1 MHz bus writes
            // (auto-increment data register). The controller port serves one
            // request at a time, and re-pulsing while a request is still
            // queued replaces it — so under memory contention (framebuffer /
            // storage traffic) a slow write dropped the next sample byte,
            // audible as corrupted waveforms. Queue write jobs in a small
            // FIFO and drain one at a time instead. This also latches the
            // write data, which was previously combinational off the bus.
            // Deep enough to ride out arbiter starvation during uploads.
            // The queue arrays infer as RAM, so depth is cheap. A DROPPED
            // WRITE PERMANENTLY CORRUPTS THE WAVETABLE — the DOC then
            // fetches wrong-but-plausible bytes forever (harmonic
            // distortion) with every DOC-side counter reading clean.
            localparam GQ_DEPTH = 32;
            // Entry layout (RESOURCE_AUDIT B5a): the sound RAM is 64 KB, so
            // glu_mem_addr_r carries 14 significant word-address bits
            // ({7'b0, ptr_hi, ptr_lo[7:2]}), and the data word is one byte
            // replicated into four lanes. Storing {be, addr[13:0]} (18 bits)
            // and the byte (8 bits) as two arrays keeps every inferred
            // primitive at x18 or narrower: 2 BSRAM blocks instead of the 4
            // that 21 + 32 bits cost on GW5A, where an x32 SDP primitive is
            // split into two blocks (Convert_SDP32_36_to_SDP16_18). Same
            // depth, same behaviour; the port sees the same 21-bit address,
            // 32-bit data and byte enables as before. The block_ram style is
            // required: left to the heuristic, GowinSynthesis extracted these
            // small arrays as RAM and then built them from ~830 flip-flops.
            localparam GQ_ADDR_BITS = 14;
            reg [GQ_ADDR_BITS+3:0] gq_ctl_r  [GQ_DEPTH-1:0] /* synthesis syn_ramstyle="block_ram" */;   // {be[3:0], addr[13:0]}
            reg [7:0]              gq_data_r [GQ_DEPTH-1:0] /* synthesis syn_ramstyle="block_ram" */;   // the sample byte
            reg [$clog2(GQ_DEPTH)-1:0] gq_wp_r, gq_rp_r;
            reg [$clog2(GQ_DEPTH):0]   gq_cnt_r;
            reg gq_wr_r;
            reg [7:0] gq_drop_cnt_r;
            assign glu_wq_drops_o = gq_drop_cnt_r;

            wire gq_room_w = (gq_cnt_r < ($clog2(GQ_DEPTH)+1)'(GQ_DEPTH));
            wire gq_push_w = glu_mem_wr_r && gq_room_w;
            // Write-taken indication — see GLU_WR_ACK_AVAIL.
            wire gq_ack_w = GLU_WR_ACK_AVAIL ? glu_mem_if.available
                                             : glu_mem_if.ready;
            wire gq_pop_w = gq_wr_r && gq_ack_w;
            assign glu_wq_pop_w = gq_pop_w;
            assign glu_wq_pop_waddr_w = gq_ctl_r[gq_rp_r][GQ_ADDR_BITS-1:0];

            always_ff @(posedge a2bus_if.clk_logic) begin
                if (!a2bus_if.system_reset_n) begin
                    gq_wp_r  <= '0;
                    gq_rp_r  <= '0;
                    gq_cnt_r <= '0;
                    gq_wr_r  <= 1'b0;
                    gq_drop_cnt_r <= 8'd0;
                end else begin
                    if (gq_push_w) begin
                        gq_ctl_r[gq_wp_r]  <= {glu_mem_byte_en_r, glu_mem_addr_r[GQ_ADDR_BITS-1:0]};
                        gq_data_r[gq_wp_r] <= a2bus_if.data;
                        gq_wp_r            <= gq_wp_r + 1'b1;
                    end
                    if (glu_mem_wr_r && !gq_room_w)
                        gq_drop_cnt_r <= gq_drop_cnt_r + 8'd1;
                    gq_cnt_r <= gq_cnt_r + ($clog2(GQ_DEPTH)+1)'(gq_push_w)
                                         - ($clog2(GQ_DEPTH)+1)'(gq_pop_w);

                    // Hold wr until the completion pulse; one dead cycle
                    // between jobs gives the controller a fresh edge.
                    if (gq_wr_r) begin
                        if (gq_ack_w) begin
                            gq_wr_r <= 1'b0;
                            gq_rp_r <= gq_rp_r + 1'b1;
                        end
                    end else if (gq_cnt_r != 0) begin
                        gq_wr_r <= 1'b1;
                    end
                end
            end

            assign glu_mem_if.rd = '0;
            assign glu_mem_if.wr = gq_wr_r;
            assign glu_mem_if.addr = {{(21-GQ_ADDR_BITS){1'b0}}, gq_ctl_r[gq_rp_r][GQ_ADDR_BITS-1:0]};
            assign glu_mem_if.data = {4{gq_data_r[gq_rp_r]}};
            assign glu_mem_if.byte_en = gq_ctl_r[gq_rp_r][GQ_ADDR_BITS+3:GQ_ADDR_BITS];
            assign glu_mem_if.burst = 1'b0;
        end
    endgenerate

    reg doc_wr_r;
    reg [7:0] doc_addr_r;

    always_ff @(posedge a2bus_if.clk_logic) begin

        if (!a2bus_if.system_reset_n) begin
            glu_mem_wr_r <= 1'b0;
            glu_mem_addr_r <= 21'h0;
            glu_mem_byte_en_r <= 4'b1111;
            sound_control_r <= 8'h0F;
            sound_data_r <= 8'h00;
            sound_ptr_lo_r <= 8'h00;
            sound_ptr_hi_r <= 8'h00;
        end else begin
            glu_mem_wr_r <= 1'b0;
            doc_wr_r <= 1'b0;
            if (ENABLE && glu_sel_w && a2bus_if.data_in_strobe) begin
                if (!a2bus_if.rw_n) begin
                    case (a2bus_if.addr[1:0])
                        2'b00: sound_control_r <= a2bus_if.data;
                        2'b01: begin
                            sound_data_r <= a2bus_if.data;
                            if (access_ram_w) begin
                                // write to sound RAM
                                glu_mem_wr_r <= 1'b1;
                                glu_mem_addr_r <= {7'b0, sound_ptr_hi_r, sound_ptr_lo_r[7:2]};
                                glu_mem_byte_en_r <= 1'b1 << sound_ptr_lo_r[1:0];
                            end else if (access_doc_w) begin
                                // write to DOC
                                doc_wr_r <= 1'b1;
                                doc_addr_r <= sound_ptr_lo_r;
                            end
                            if (auto_inc_w) begin
                                {sound_ptr_hi_r, sound_ptr_lo_r} <= {sound_ptr_hi_r, sound_ptr_lo_r} + 1'd1;
                            end
                        end
                        2'b10: sound_ptr_lo_r <= a2bus_if.data;
                        2'b11: sound_ptr_hi_r <= a2bus_if.data;
                    endcase
                end else begin
                    if (a2bus_if.addr[1:0] == 2'b01) begin
                        if (auto_inc_w) begin
                            {sound_ptr_hi_r, sound_ptr_lo_r} <= {sound_ptr_hi_r, sound_ptr_lo_r} + 1'd1;
                        end
                    end
                end
            end

        end

    end

    // DOC Memory Interface
    // All DOC logic in the sound module is clocked by clk_logic

    wire [15:0] wave_addr_w;
    wire doc_mem_rd_w;

    reg [1:0] doc_mem_offset_r;

    always_ff @(posedge a2bus_if.clk_logic) begin
        if (doc_mem_rd_w) begin
            doc_mem_offset_r <= wave_addr_w[1:0];
        end
    end

    reg [7:0] wave_data_r;
    reg [31:0] wave_data_word_r;   // rev-2 pipelined path: full-word response
    reg wave_data_ready_r;
    wire [7:0] doc_filter_late_w;  // gen_doc_ext: superseded responses discarded
    wire [15:0] doc_cache_hits_w, doc_cache_miss_w;  // gen_doc_ext word cache (free-running)
    wire       glu_wq_pop_w;       // a queued sound-RAM write left for memory (cache invalidate)
    wire [13:0] glu_wq_pop_waddr_w;  // ... its word address (sound-RAM relative)

    generate
        if (USE_BSRAM) begin : gen_doc_bsram
            // Drive DDR3 DOC port idle
            assign doc_mem_if.wr = '0;
            assign doc_mem_if.rd = '0;
            assign doc_mem_if.data = '0;
            assign doc_mem_if.byte_en = '0;
            assign doc_mem_if.addr = '0;
            assign doc_mem_if.burst = 1'b0;

            // BSRAM instance for 64KB sound RAM
            wire [31:0] bsram_rd_data;
            wire        bsram_rd_valid;

            ensoniq_bsram ensoniq_bsram (
                .clk(a2bus_if.clk_logic),

                // Write port (GLU) - use registered signals from always_ff block
                .wr_en(glu_mem_wr_r),
                .wr_addr(glu_mem_addr_r[13:0]),
                .wr_data({sound_data_r, sound_data_r, sound_data_r, sound_data_r}),
                .wr_byte_en(glu_mem_byte_en_r),

                // Read port (DOC)
                .rd_en(ENABLE && doc_mem_rd_w),
                .rd_addr(wave_addr_w[15:2]),
                .rd_data(bsram_rd_data),
                .rd_valid(bsram_rd_valid)
            );

            // BSRAM read completes in 1 cycle (rd_valid is 1 cycle after rd_en)
            always_ff @(posedge a2bus_if.clk_logic) begin
                wave_data_ready_r <= 1'b0;
                if (bsram_rd_valid) begin
                    wave_data_r <= bsram_rd_data[8*doc_mem_offset_r +: 8];
                    wave_data_ready_r <= 1'b1;
                end
            end

        end else if (USE_DDR3_PIPELINED) begin : gen_doc_ddr3_pipe
            // Pipelined-fetch DDR3 path (rev 3): the DOC fetches 16-byte
            // LINES as 4-beat bursts (addresses are 16-byte aligned) —
            // byte-lane selection and the per-oscillator line cache live
            // inside doc5503_pipelined. This module forwards requests and
            // registers each of the four word beats verbatim (in order).
            assign doc_mem_if.wr = '0;
            assign doc_mem_if.data = '0;
            assign doc_mem_if.byte_en = 4'b1111;
            assign doc_mem_if.addr = {7'b0, wave_addr_w[15:2]};
            assign doc_mem_if.rd = ENABLE && doc_mem_rd_w;
            assign doc_mem_if.burst = 1'b1;

            always_ff @(posedge a2bus_if.clk_logic) begin
                wave_data_ready_r <= 1'b0;
                if (doc_mem_if.ready) begin
                    wave_data_word_r  <= doc_mem_if.q;
                    wave_data_ready_r <= 1'b1;
                end
            end
        end else begin : gen_doc_ext
            // Baseline DOC on external memory (HyperRAM / DDR3), single-word
            // reads through doc_fetch_cache: a 64-word cache (sequential
            // wavetable walks hit the same 32-bit word up to 4x, cutting the
            // DOC's share of the memory bus ~4x and answering hits in two
            // cycles) that also owns request ordering — a response still
            // outstanding when a newer request arrives is superseded, so a
            // fetch that missed the DOC's slot budget can never be consumed
            // as the next oscillator's sample. Flushed on every sound-RAM
            // write and again when that write leaves the queue for memory.
            assign doc_mem_if.wr = '0;
            assign doc_mem_if.data = '0;
            assign doc_mem_if.byte_en = 4'b1111;
            assign doc_mem_if.burst = 1'b0;
            wire        cache_rd_w;
            wire [13:0] cache_waddr_w;
            wire        cache_valid_w;
            wire [7:0]  cache_data_w;
            assign doc_mem_if.rd   = ENABLE && cache_rd_w;
            assign doc_mem_if.addr = {7'b0, cache_waddr_w};
            doc_fetch_cache #(.PER_WORD_INVALIDATE(DOC_CACHE_PER_WORD_INVALIDATE),
                              .HIT_DISABLE(DOC_CACHE_HIT_DISABLE)) u_fetch_cache (
                .clk_i(a2bus_if.clk_logic),
                .rst_n_i(a2bus_if.system_reset_n),
                .req_i(ENABLE && doc_mem_rd_w),
                .addr_i(wave_addr_w),
                .flush_i(glu_mem_wr_r | glu_wq_pop_w),
                .flush_waddr_i(glu_mem_wr_r ? glu_mem_addr_r[13:0] : glu_wq_pop_waddr_w),
                .valid_o(cache_valid_w),
                .data_o(cache_data_w),
                .mem_rd_o(cache_rd_w),
                .mem_addr_o(cache_waddr_w),
                .mem_available_i(doc_mem_if.available),
                .mem_ready_i(doc_mem_if.ready),
                .mem_q_i(doc_mem_if.q),
                .dbg_hits_o(doc_cache_hits_w),
                .dbg_misses_o(doc_cache_miss_w),
                .dbg_late_o(doc_filter_late_w));
            always_ff @(posedge a2bus_if.clk_logic) begin
                wave_data_ready_r <= cache_valid_w;
                if (cache_valid_w) wave_data_r <= cache_data_w;
            end
        end
    endgenerate

    // Request-rate/spacing instrumentation (config-independent)
    reg [15:0] dbg_req_count_r;
    reg [7:0]  dbg_gap_cnt_r;
    reg [7:0]  dbg_min_gap_r;
    always_ff @(posedge a2bus_if.clk_logic) begin
        if (!a2bus_if.system_reset_n) begin
            dbg_req_count_r <= '0;
            dbg_gap_cnt_r   <= 8'hFF;
            dbg_min_gap_r   <= 8'hFF;
        end else begin
            if (doc_mem_rd_w) begin
                dbg_req_count_r <= dbg_req_count_r + 16'd1;
                if (dbg_gap_cnt_r < dbg_min_gap_r)
                    dbg_min_gap_r <= dbg_gap_cnt_r;
                dbg_gap_cnt_r <= 8'd0;
            end else if (dbg_gap_cnt_r != 8'hFF) begin
                dbg_gap_cnt_r <= dbg_gap_cnt_r + 8'd1;
            end
            if (dbg_frame_tick_i)
                dbg_min_gap_r <= 8'hFF;   // top.sv samples before this reset
        end
    end
    assign dbg_doc_req_count_o  = dbg_req_count_r;
    assign dbg_doc_req_mingap_o = dbg_min_gap_r;

    wire signed [15:0] mono_mix_w;
    wire signed [15:0] left_mix_w;
    wire signed [15:0] right_mix_w;
    //wire signed [15:0] channel_w[15:0]; 

    // Debug: Capture and expose the oscillator enable register
    wire [7:0] debug_doc_osc_en_w;
    assign debug_osc_en_o = debug_doc_osc_en_w;

    wire [1:0] debug_osc_mode_w[8];
    assign debug_osc_mode_o = debug_osc_mode_w;
    wire [7:0] debug_osc_halt_w;
    assign debug_osc_halt_o = debug_osc_halt_w;

    generate
        if (USE_DDR3_PIPELINED && !USE_BSRAM) begin : gen_doc_pipelined
            doc5503_pipelined #(
                .BANKS_IN_BSRAM(DOC_BANKS_IN_BSRAM)
            ) doc5503 (
                .clk_i(a2bus_if.clk_logic),
                .reset_n_i(a2bus_if.system_reset_n),
                .clk_en_i(a2bus_if.clk_7M_posedge),
                .cs_n_i(~doc_wr_r),
                .we_n_i(1'b0),
                .addr_i(doc_addr_r),
                .data_i(a2bus_if.data),
                .data_o(doc_data_o_w),
                .wave_address_o(wave_addr_w),
                .wave_rd_o(doc_mem_rd_w),
                .wave_available_i(doc_mem_if.available),
                .wave_data_ready_i(wave_data_ready_r),
                .wave_data_i(8'h00),                // legacy, unused in rev 2
                .wave_data_word_i(wave_data_word_r),
                .cache_flush_i(glu_mem_wr_r),       // GLU sound-RAM write pulse
                // Written BYTE address for targeted (dirty-range) cache
                // invalidation — bulk flush on every write caused refetch
                // storms during play-while-writing titles (rev 3.5).
                .cache_flush_addr_i({glu_mem_addr_r[13:0], 2'b00}),
                .fb_fetch_active_i(fb_fetch_active_i),
                .left_mix_o(left_mix_w),
                .right_mix_o(right_mix_w),
                .mono_mix_o(mono_mix_w),
                .channel_o(),
                .ready_o(),
                .debug_osc_en_o(debug_doc_osc_en_w),
                .debug_osc_mode_o(debug_osc_mode_w),
                .debug_osc_halt_o(debug_osc_halt_w),
                .dbg_prime_miss_o(dbg_doc_prime_miss_o),
                .dbg_stale_fetch_o(dbg_doc_stale_fetch_o),
                .dbg_fetch_drop_o(dbg_doc_fetch_drop_o),
                .dbg_fetch_count_o(dbg_doc_fetch_count_o),
                .dbg_frame_resync_o(dbg_doc_frame_resync_o)
            );
            assign dbg_doc_timeouts_o = 16'd0;
        end else begin : gen_doc_baseline
            assign dbg_doc_prime_miss_o = doc_latmax_w;
            assign dbg_doc_stale_fetch_o = doc_timeout_w[7:0];
            assign dbg_doc_fetch_drop_o = doc_late_w;
            assign dbg_doc_fetch_count_o = doc_cache_miss_w;   // memory reads actually issued (word-cache misses)
            assign dbg_doc_timeouts_o    = doc_timeout_w;
            assign dbg_doc_frame_resync_o = 8'd0;
            // fetch telemetry: prime_miss = max fetch latency (clk), stale = budget
            // timeouts (0x80 substituted), drop = stale responses discarded (filter)
            wire [15:0] doc_timeout_w;
            wire [7:0]  doc_latmax_w;
            wire [7:0] doc_late_w = USE_BSRAM ? 8'd0 : doc_filter_late_w;
            doc5503 #(
                .BANKS_IN_BSRAM(DOC_BANKS_IN_BSRAM)
            ) doc5503 (
                .clk_i(a2bus_if.clk_logic),
                .reset_n_i(a2bus_if.system_reset_n),
                .clk_en_i(a2bus_if.clk_7M_posedge),
                .cs_n_i(~doc_wr_r),
                .we_n_i(1'b0),
                .addr_i(doc_addr_r),
                .data_i(a2bus_if.data),
                .data_o(doc_data_o_w),
                .wave_address_o(wave_addr_w),
                .wave_rd_o(doc_mem_rd_w),
                .wave_data_ready_i(wave_data_ready_r),
                .wave_data_i(wave_data_r),
                .left_mix_o(left_mix_w),
                .right_mix_o(right_mix_w),
                .mono_mix_o(mono_mix_w),
                .channel_o(),
                .ready_o(),
                .debug_osc_en_o(debug_doc_osc_en_w),
                .debug_osc_mode_o(debug_osc_mode_w),
                .debug_osc_halt_o(debug_osc_halt_w),
                .dbg_fetch_timeout_o(doc_timeout_w),
                .dbg_fetch_latmax_o(doc_latmax_w)
            );
        end
    endgenerate

    // Output stage (design doc 12.17): optional master volume, then boost
    // shift computed in widened precision and SATURATED to 16 bits — the
    // old bare `<<< 1` WRAPPED on overflow, which is what tracker-class
    // music (8-14 voices) exposed as harsh distortion.
    //
    // Master volume ($C03C[3:0]) as linear amplitude: mix * (vol+1)/16,
    // vol=15 = unity. INFERRED mapping (the original shift-based mapping,
    // now removed, was defective: 4 coarse steps with a discontinuity).
    // Off by default until validated by listening test.
    localparam int OB = OUTPUT_BOOST_SHIFT;

    function automatic signed [15:0] sat16(input signed [21:0] v);
        if (v > 22'sd32767)       sat16 = 16'sd32767;
        else if (v < -22'sd32768) sat16 = -16'sd32768;
        else                      sat16 = v[15:0];
    endfunction

    function automatic signed [15:0] out_stage(input signed [15:0] mix);
        logic signed [5:0]  volp1;   // (vol+1): 1..16, kept signed so the
                                     // multiply below stays signed x signed
        logic signed [21:0] scaled;
        logic signed [21:0] boosted;
        volp1 = signed'({2'b00, volume_w}) + 6'sd1;
        if (ENABLE_MASTER_VOLUME)
            scaled = (22'(mix) * 22'(volp1)) >>> 4;
        else
            scaled = 22'(mix);
        boosted = scaled <<< OB;
        out_stage = sat16(boosted);
    endfunction

    // Output registers for audio with zero-centering preserved
    reg signed [15:0] audio_l_reg;
    reg signed [15:0] audio_r_reg;

    // Assign outputs from registers
    assign audio_l_o = audio_l_reg;
    assign audio_r_o = audio_r_reg;

    always_ff @(posedge a2bus_if.clk_logic) begin
        if (MONO_MIX) begin
            audio_l_reg <= out_stage(mono_mix_w);
            audio_r_reg <= out_stage(mono_mix_w);
        end else begin
            audio_l_reg <= out_stage(left_mix_w);
            audio_r_reg <= out_stage(right_mix_w);
        end
    end
    //assign audio_l_o = channel_w[0] >>> (4'd15 - volume_w);
    //assign audio_r_o = channel_w[0] >>> (4'd15 - volume_w);
    //assign audio_l_o = channel_w[1] >>> (4'd15 - volume_w);
    //assign audio_r_o = channel_w[2] >>> (4'd15 - volume_w);

endmodule
