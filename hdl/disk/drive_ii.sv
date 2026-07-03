
// WORK IN PROGRESS
//
// Drive II
//
// Adapted from:
// https://github.com/alanswx/Apple-II-Verilog_MiSTer/blob/master/rtl/drive_ii.v
// https://github.com/MiSTer-devel/Apple-II_MiSTer/blob/master/rtl/drive_ii.vhd
//
// Adapted for use with A2FPGA multicard bus interface
//
// Uses A2FPGA SDRAM controller for disk storage and requires the use
// of the PicoSoC core to provide the FAT32 file system interface
//
// Current status: Functional with hardcoded disk images
//

module drive_ii (
    a2bus_if.slave a2bus_if,

    output [7:0] data_o,

    drive_volume_if.drive volume_if,

    input drive_id_i,
    input drive_active,
    input [3:0] motor_phase_i,
    input write_mode_i,
    input read_disk_i,
    input write_reg_i,

    mem_port_if.client ram_disk_if
);

    // --- Track-on-demand loader (NanoApple2 floppy_track model) --------------
    // Instead of the whole nibblized disk living in SDRAM, only the track the
    // head is currently over is resident, in a small per-drive 8KB SDRAM window.
    // On a seek we ask the MCU (drive_volume_if block protocol) to stream the
    // new track in: lba = track*13 (13 * 512 = 0x1A00 bytes/track). Read-only
    // for now; dirty-track writeback is a later phase.
    localparam [5:0] TRACK_NONE = 6'h3f;
    reg  [5:0] cur_track_r;   // track resident in the SDRAM window
    reg  [5:0] req_track_r;   // track being fetched (latched at request time)
    reg        load_req_r;    // waiting for the MCU to stream the track in
    reg        save_req_r;    // waiting for the MCU to flush a dirty track back
    reg        dirty_r;       // resident track has writes not yet flushed

    assign volume_if.active  = drive_active;
    assign volume_if.blk_cnt = 6'd12;                 // 13 sectors = 0x1A00 bytes
    // A save flushes the resident (old) track; a load fetches the new track.
    assign volume_if.lba     = 32'd13 * (save_req_r ? cur_track_r : req_track_r);
    assign volume_if.rd      = load_req_r;
    assign volume_if.wr      = save_req_r;


    logic [5:0] track_w;  // output to ramdisk
    logic [12:0] track_addr_w;  // output to ramdisk
    logic [7:0] track_di_w;  // output to ramdisk
    logic [7:0] track_do_w;  // input from ramdisk
    reg track_we_r;  // output to ramdisk
    reg track_rd_r;  // output to ramdisk
    logic track_busy_w;  // input from ramdisk

    assign track_busy_w = 1'b0;

    reg [7:0] phase_r;

    reg [12:0] track_byte_addr_r;
    reg [7:0] data_r;
    reg reset_data_r;


    always @(posedge a2bus_if.clk_logic or negedge a2bus_if.system_reset_n) begin : update_phase
        automatic integer phase_change_temp;
        automatic integer new_phase_temp;
        automatic logic [3:0] rel_phase_temp;
        if (!a2bus_if.system_reset_n) phase_r <= 70;
        else begin
            if (a2bus_if.clk_14M_posedge) begin
                if (drive_active) begin
                    phase_change_temp = 0;
                    new_phase_temp = phase_r;
                    rel_phase_temp = motor_phase_i;
                    case (phase_r[2:1])
                        2'b00:   rel_phase_temp = {rel_phase_temp[1:0], rel_phase_temp[3:2]};
                        2'b01:   rel_phase_temp = {rel_phase_temp[2:0], rel_phase_temp[3]};
                        2'b10:   ;
                        2'b11:   rel_phase_temp = {rel_phase_temp[0], rel_phase_temp[3:1]};
                        default: ;
                    endcase

                    if (phase_r[0] == 1'b1)
                        case (rel_phase_temp)
                            4'b0000: phase_change_temp = 0;
                            4'b0001: phase_change_temp = -3;
                            4'b0010: phase_change_temp = -1;
                            4'b0011: phase_change_temp = -2;
                            4'b0100: phase_change_temp = 1;
                            4'b0101: phase_change_temp = -1;
                            4'b0110: phase_change_temp = 0;
                            4'b0111: phase_change_temp = -1;
                            4'b1000: phase_change_temp = 3;
                            4'b1001: phase_change_temp = 0;
                            4'b1010: phase_change_temp = 1;
                            4'b1011: phase_change_temp = -3;
                            4'b1111: phase_change_temp = 0;
                            default: ;
                        endcase
                    else
                        case (rel_phase_temp)
                            4'b0000: phase_change_temp = 0;
                            4'b0001: phase_change_temp = -2;
                            4'b0010: phase_change_temp = 0;
                            4'b0011: phase_change_temp = -1;
                            4'b0100: phase_change_temp = 2;
                            4'b0101: phase_change_temp = 0;
                            4'b0110: phase_change_temp = 1;
                            4'b0111: phase_change_temp = 0;
                            4'b1000: phase_change_temp = 0;
                            4'b1001: phase_change_temp = 1;
                            4'b1010: phase_change_temp = 2;
                            4'b1011: phase_change_temp = -2;
                            4'b1111: phase_change_temp = 0;
                            default: ;
                        endcase

                    if (new_phase_temp + phase_change_temp <= 0) new_phase_temp = 0;
                    else if (new_phase_temp + phase_change_temp > 139) new_phase_temp = 139;
                    else new_phase_temp = new_phase_temp + phase_change_temp;
                    phase_r <= 8'(new_phase_temp);
                end
            end
        end
    end

    assign track_w = phase_r[7:2];

    // The head may only read once the track it is over is actually resident in
    // the SDRAM window (i.e. the MCU has streamed it in). While a load is in
    // flight, or the head has stepped to a not-yet-loaded track, reads stall.
    wire track_resident_w = (cur_track_r == track_w) & ~load_req_r & ~save_req_r;

    // Track loader: on a seek, flush the old track if it was written, then fetch
    // the new track from the MCU (drive_volume_if block protocol). Save then load
    // are two separate request/ack handshakes.
    always @(posedge a2bus_if.clk_logic or negedge a2bus_if.system_reset_n) begin : track_loader
        if (!a2bus_if.system_reset_n) begin
            cur_track_r <= TRACK_NONE;
            req_track_r <= 6'd0;
            load_req_r  <= 1'b0;
            save_req_r  <= 1'b0;
            dirty_r     <= 1'b0;
        end else begin
            if (track_we_r) dirty_r <= 1'b1;  // a write landed in the resident track

            if (save_req_r) begin
                if (volume_if.ack) begin      // MCU flushed the dirty track to the image
                    save_req_r <= 1'b0;
                    dirty_r    <= 1'b0;
                end
            end else if (load_req_r) begin
                if (volume_if.ack) begin      // MCU streamed the new track in
                    load_req_r  <= 1'b0;
                    cur_track_r <= req_track_r;
                end
            end else if (volume_if.mounted & volume_if.ready & (cur_track_r != track_w)) begin
                if (dirty_r & (cur_track_r != TRACK_NONE) & ~volume_if.readonly) begin
                    save_req_r <= 1'b1;       // flush old track first (lba = cur_track*13)
                end else begin
                    req_track_r <= track_w;   // latch target, hold rd until ack
                    load_req_r  <= 1'b1;
                end
            end
        end
    end

    // Q3 is not wired on this board (top.sv ties a2_q3_i to 0, so
    // clk_q3_posedge never pulses). The WRITE head still uses a synthesized Q3
    // cadence from the CPU phase clocks (phi0_posedge | phi1_posedge, twice per
    // CPU cycle). The READ head no longer uses this — see below.
    wire q3_tick_w = a2bus_if.phi0_posedge | a2bus_if.phi1_posedge;

    always @(posedge a2bus_if.clk_logic or negedge a2bus_if.system_reset_n) begin : read_head
        static reg [5:0] byte_delay_r;
        if (!a2bus_if.system_reset_n) begin
            track_byte_addr_r <= 13'b0;
            byte_delay_r = 6'b0;
            reset_data_r <= 1'b0;
        end else begin
            track_we_r <= 1'b0;
            track_rd_r <= 1'b0;

            // Data-latch clear, decoupled from the nibble advance: the CPU reads
            // $C0EC during phi0; clear the latch only AFTER phi0 has fallen
            // (during phi1) so the clear can never race the CPU's end-of-phi0
            // bus sample. Placed before the nibble load below so a coincident
            // load still wins the data_r assignment (present the nibble, not 0).
            if (!write_mode_i) begin
                if (read_disk_i & a2bus_if.phi0)
                    reset_data_r <= 1'b1;
                else if (reset_data_r & ~a2bus_if.phi0) begin
                    data_r       <= 8'b0;
                    reset_data_r <= 1'b0;
                end
            end

            if (!write_mode_i) begin
                // Advance the read head one nibble per 32 CPU cycles, ONLY on
                // phi0_posedge (the RISING edge of phi0, i.e. the start of the
                // CPU read window). data_r is then presented at the beginning of
                // the window and held rock-stable through the phi0 FALLING edge,
                // which is where the 6502 latches the $C0EC read. Advancing on
                // the q3 cadence (or on phi1_posedge == the phi0 falling edge ==
                // the CPU's own sample point) let a nibble update coincide with
                // the latch, so a read occasionally caught the update mid-flight
                // and shifted a data field by one nibble -> CRC -> RWTS retry ->
                // intermittent I/O ERROR / boot hang. The falling edge is the
                // one place we must never move data_r; the rising edge is the
                // safe one.
                //
                // Keep the "disk" spinning whenever the drive is on, even while
                // a track is (re)loading: present real nibbles when resident,
                // otherwise $FF self-sync gap bytes so a read overlapping a
                // seek/load sees valid sync instead of a dead 0. The read
                // position only advances on resident data, holding our place in
                // the track across the load.
                if (a2bus_if.phi0_posedge & volume_if.ready & drive_active) begin
                    if (byte_delay_r == 0) begin
                        byte_delay_r = 6'd31;   // 32 phi0 ticks = 32 CPU cycles
                        if (track_resident_w) begin
                            data_r <= track_do_w;
                            if (track_byte_addr_r == 13'h19ff) track_byte_addr_r <= 13'b0;
                            else track_byte_addr_r <= 13'(track_byte_addr_r + 1'b1);
                            track_rd_r <= 1'b1;
                        end else begin
                            data_r <= 8'hFF;   // self-sync gap while (re)loading
                        end
                    end else begin
                        byte_delay_r = 6'(byte_delay_r - 1);
                    end
                end
            end else begin
                if (q3_tick_w) begin
                    if (volume_if.ready & drive_active & track_resident_w) begin
                        if (write_reg_i) data_r <= a2bus_if.data;
                        if (read_disk_i & a2bus_if.phi0) begin
                            track_we_r <= (~track_busy_w);
                            if (track_byte_addr_r == 13'h19ff) track_byte_addr_r <= 13'b0;
                            else track_byte_addr_r <= 13'(track_byte_addr_r + 1'b1);
                        end
                    end
                end
            end
        end
    end

    assign data_o = data_r;
    assign track_addr_w = track_byte_addr_r;
    assign track_di_w = data_r;

    // Track-on-demand window: only the resident track lives in SDRAM, so the
    // address is just the byte offset within the track (no track*0x1A00 whole-
    // disk offset). drive_id_i selects this drive's 8KB window (word bit 11 =
    // byte 0x2000 stride); the port base (DISK_WORD_BASE) is added by the
    // arbiter so it lands where the MCU streamed the track via XFER SPACE 1.
    assign ram_disk_if.addr = {9'b0, drive_id_i, track_byte_addr_r[12:2]};
    assign ram_disk_if.rd = track_rd_r;
    // Writes go to the resident track in the SDRAM window; byte_en selects the
    // lane within the 32-bit word so a single nibble byte is written in place.
    // The dirty track is later flushed to the image file by the MCU on a seek.
    assign ram_disk_if.wr = track_we_r;
    assign ram_disk_if.data = {4{data_r}};
    assign ram_disk_if.byte_en = track_we_r ? (4'b0001 << track_byte_addr_r[1:0]) : 4'b1111;
    assign ram_disk_if.burst = 1'b0;
    assign track_do_w = ram_disk_if.q[track_byte_addr_r[1:0]*8+:8];

endmodule
