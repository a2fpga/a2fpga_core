module cam_serializer #(
    parameter COUNT_WIDTH = 2,
    // Assert VSYNC (cam_sync) only once every N packets to lower EOF rate on ESP32.
    // Set to 1 for legacy behavior (VSYNC every packet).
    parameter int SYNC_EVERY_PKTS = 409,
    // Idle flush: when no writes for this many clk_i cycles and a partial frame
    // is in progress (packet_count_r != 0), inject one dummy packet and assert
    // VSYNC to force an EOF on the receiver.
    parameter int IDLE_FLUSH_CYCLES = 13500,  // ~250us at 54MHz
    // Padding mode for LEN-EOF operation: after the last real packet, emit up to
    // PAD_COUNT dummy (heartbeat) packets unless preempted by new real writes.
    // This guarantees crossing the ESP32 chunk boundary in LEN-EOF mode.
    parameter bit PAD_MODE = 1'b0,
    parameter int PAD_COUNT = 409
) (
    input         clk_i,
    input         rst_n,
    input         wr_i,
    input  [31:0] data_i,
    output        cam_pclk,
    output        cam_sync,
    output [3:0]  cam_data,
    output        busy,
    output        overwrite_detected 
);

    // ----------------------------
    // Write queue (1-deep)
    // ----------------------------
    reg [31:0] pending_data_r;
    reg        overwrite_detected_r;
    
    // Detect overwrite condition
    wire packet_overwrite_w = wr_i & packet_pending_r;
    
    always @(posedge clk_i or negedge rst_n) begin
        if (!rst_n) begin
            pending_data_r <= 32'h0;
            overwrite_detected_r <= 1'b0;
        end else begin
            if (wr_i) begin
                pending_data_r <= data_i;    // last write wins
                if (packet_pending_r) begin
                    overwrite_detected_r <= 1'b1; // Sticky flag - indicates overwrite occurred
                end
            end
        end
    end

    // ----------------------------
    // Clock divider (free-runs)
    // ----------------------------
    reg [COUNT_WIDTH-1:0] clk_count_r = '0;
    wire cam_pclk_w          = clk_count_r[COUNT_WIDTH-1];                // MSB
    wire cam_pclk_rising_w   = (clk_count_r == (1 << (COUNT_WIDTH-1)));   // 0->1
    wire cam_pclk_falling_w  = (clk_count_r == '0);                       // 1->0

    always @(posedge clk_i or negedge rst_n) begin
        if (!rst_n) begin
            clk_count_r <= '0;
        end else begin
            clk_count_r <= clk_count_r + 1;
        end
    end

    // ----------------------------
    // Packet engine
    // ----------------------------
    // Packet Protocol:
    // Clock active during transmission, otherwise halted
    // Packet consists of 10 4-bit nibbles
    // Send 32-bit data word, one nibble at a time on nibbles 0 to 7
    // Raise SYNC bit on nibble 8 (gated by SYNC_EVERY_PKTS)
    // Empty pad on nibble 9
    // ----------------------------
    reg         packet_pending_r;
    reg         packet_active_r;
    reg  [31:0] packet_data_r;
    reg  [3:0]  nibble_count_r;
    reg  [15:0] packet_count_r;
    reg         sync_this_packet_r;
    reg         force_sync_next_r;
    reg  [31:0] idle_count_r;
    reg  [15:0] pad_remain_r;
    reg         dummy_pending_r;   // marks that the queued packet is a dummy/heartbeat

    // Drive outputs
    assign cam_data = packet_data_r[3:0];
    assign cam_pclk = packet_active_r ? cam_pclk_w : 1'b0;

    // VSYNC at end-of-word (nibble 8) and only while active, gated by SYNC cadence
    // Disabled in PAD_MODE (LEN-EOF): hold low
    assign cam_sync = (PAD_MODE) ? 1'b0 : (packet_active_r && (nibble_count_r == 4'd8) && sync_this_packet_r);

    // busy = active OR queued
    assign busy = packet_active_r | packet_pending_r;
    
    // Output overwrite detection (sticky flag)
    assign overwrite_detected = overwrite_detected_r;

    // Serializer / flow
    always @(posedge clk_i or negedge rst_n) begin
        if (!rst_n) begin
            nibble_count_r     <= 4'd0;
            packet_active_r    <= 1'b0;
            packet_data_r      <= '0;
            packet_pending_r   <= 1'b0;
            packet_count_r     <= 16'd0;
            sync_this_packet_r <= 1'b0;
            force_sync_next_r  <= 1'b0;
            idle_count_r       <= 32'd0;
            pad_remain_r       <= 16'd0;
            dummy_pending_r    <= 1'b0;
        end else begin
            if (wr_i) begin
                packet_pending_r <= 1'b1;
                if (PAD_MODE) begin
                    pad_remain_r <= PAD_COUNT[15:0];
                end
                // real data preempts any queued dummy
                dummy_pending_r <= 1'b0;
            end

            // Idle counter (no activity) only used when not in padding mode
            if (!PAD_MODE) begin
                if (!packet_active_r && !wr_i) begin
                    if (idle_count_r != 32'hFFFF_FFFF)
                        idle_count_r <= idle_count_r + 1;
                end else begin
                    idle_count_r <= 32'd0;
                end
            end

            // If idle timeout and partial frame exists, inject one dummy packet with forced VSYNC
            if (!PAD_MODE) begin
                if (!packet_active_r && !packet_pending_r && (packet_count_r != 16'd0) &&
                    (idle_count_r >= IDLE_FLUSH_CYCLES)) begin
                    packet_pending_r   <= 1'b1;
                    dummy_pending_r    <= 1'b1;           // queue a dummy for flush
                    force_sync_next_r  <= 1'b1;
                    idle_count_r       <= 32'd0;
                end
            end

            if (cam_pclk_falling_w) begin
                // Start a new word exactly after finishing one, if something is pending
                if (packet_active_r && (nibble_count_r == 4'd9)) begin
                    // Finished a packet: advance or wrap the VSYNC gating counter
                    if (PAD_MODE) begin
                        // No VSYNC cadence in padding mode
                        packet_count_r <= 16'd0;
                    end else if (SYNC_EVERY_PKTS <= 1) begin
                        packet_count_r <= 16'd0;
                    end else if (sync_this_packet_r) begin
                        packet_count_r <= 16'd0; // just emitted gated VSYNC
                    end else if (packet_count_r == SYNC_EVERY_PKTS-1) begin
                        packet_count_r <= 16'd0;
                    end else begin
                        packet_count_r <= packet_count_r + 16'd1;
                    end

                    if (packet_pending_r) begin
                        packet_data_r    <= (dummy_pending_r ? 32'hC0FF_0000 : pending_data_r);
                        packet_active_r  <= 1'b1;      // stay active (back-to-back)
                        nibble_count_r   <= 4'd0;
                        packet_pending_r <= 1'b0;
                        dummy_pending_r  <= 1'b0;
                        // Latch whether this new packet should assert VSYNC at nibble 8
                        if (PAD_MODE) begin
                            sync_this_packet_r <= 1'b0;
                        end else begin
                            if (SYNC_EVERY_PKTS <= 1)
                                sync_this_packet_r <= 1'b1;  // legacy behavior
                            else if (force_sync_next_r) begin
                                sync_this_packet_r <= 1'b1;
                                force_sync_next_r  <= 1'b0;
                            end else begin
                                sync_this_packet_r <= (packet_count_r == SYNC_EVERY_PKTS-1);
                            end
                        end
                    end else begin
                        // If no real packet queued, in padding mode emit dummy packets while budget remains
                        if (PAD_MODE && (pad_remain_r != 16'd0)) begin
                            packet_data_r      <= '0;        // will load dummy next cycle
                            packet_active_r    <= 1'b0;
                            nibble_count_r     <= 4'd0;
                            sync_this_packet_r <= 1'b0;
                            packet_pending_r   <= 1'b1;
                            dummy_pending_r    <= 1'b1;            // heartbeat is queued
                            pad_remain_r       <= pad_remain_r - 16'd1;
                        end else begin
                            packet_data_r    <= '0;        // idle pattern
                            packet_active_r  <= 1'b0;      // gate off PCLK
                            nibble_count_r   <= 4'd0;
                            sync_this_packet_r <= 1'b0;
                        end
                    end
                end
                // If idle and we have a packet queued, launch it
                else if (!packet_active_r && packet_pending_r) begin
                    packet_data_r    <= (dummy_pending_r ? 32'hC0FF_0000 : pending_data_r);
                    packet_active_r  <= 1'b1;
                    nibble_count_r   <= 4'd0;
                    packet_pending_r <= 1'b0;
                    dummy_pending_r  <= 1'b0;
                    // Latch whether this new packet should assert VSYNC at nibble 8
                    if (PAD_MODE) begin
                        sync_this_packet_r <= 1'b0;
                    end else begin
                        if (SYNC_EVERY_PKTS <= 1)
                            sync_this_packet_r <= 1'b1;  // legacy behavior
                        else if (force_sync_next_r) begin
                            sync_this_packet_r <= 1'b1;
                            force_sync_next_r  <= 1'b0;
                        end else begin
                            sync_this_packet_r <= (packet_count_r == SYNC_EVERY_PKTS-1);
                        end
                    end
                end

                // SHIFT & COUNT only when active, on the PCLK falling edge
                if (packet_active_r) begin
                    packet_data_r  <= {4'b0, packet_data_r[31:4]};  // LSN-first
                    nibble_count_r <= nibble_count_r + 4'd1;
                end
            end
        end
    end

endmodule
