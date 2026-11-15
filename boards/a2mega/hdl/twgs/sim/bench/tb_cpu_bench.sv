// CPU bench — stock P65C816 (reference) vs the fast variant F65C816 (DUT),
// both on ideal memory, same clock, same reset, same RDY.  Used by the S7
// fast-core exploration (boards/a2mega/docs/gs_socket_s7_fast_core_exploration.md).
//
// Two comparison layers:
//  * lockstep (+lockstep=1, default): every step the bus must match — address,
//    RWB, VPA/VDA/VPB, write data.  For cycle-exact rungs (timing-only
//    rewrites of the datapath).
//  * architectural (always on): at every opcode fetch the register file
//    (PC, A, X, Y, SP, D, P incl. E, PBR, DBR) is pushed to a per-core queue
//    and the two queues are compared head-to-head; the ordered write stream
//    (address, data) is compared the same way.  Rungs that change the cycle
//    count (data-late pipeline, dead-cycle removal) are checked by this layer
//    with +lockstep=0.
//
// Program mode (+prog=<64 KB bank-0 image>): the image is loaded at 000000.
// Bench port in bank 0:
//    $BFF0 write  -> done; value = status (0 = pass)
//    $BFF1 write  -> putchar
//    $BFF2 write  -> checkpoint mark n: per-core step/instruction deltas
// ROM mode (+rom=<boot1.rom>): ROM 01 image at FE0000 (no bench port); banks 00/01/E0/E1
// read $C100-$FFFF from the FF image; $C0xx is a write-back register file.
// Boots the ROM self-test path far enough to be a strong lockstep stress.
//
// +datalate   DUT on a synchronous memory (S7 data-late step): the read address is the
//             core's NA_OUT (next-step address) registered at the step edge, writes go
//             to A_OUT at the step edge, and a read of the location written at the same
//             edge is served by a one-entry bypass (the memory itself returns garbage
//             there, as a block RAM may).  The reference stays on ideal memory.
// +irq        pseudo-random IRQ and NMI pulses (same for both cores); for ROM mode, where
//             the image has handlers — exercises the interrupt sequence and vector fetch
// +cycles=N   clock budget (default 8,000,000)
// +stall      pseudo-random RDY_IN stalls (same for both cores)
// +ce2        both cores step every second clk at most (CE on alternate clks): what
//             F65C816_MCODE_ROM needs (microcode read from block RAM in the clk
//             before a step ends); twice the clocks for the same steps
// +trace      print every reference bus cycle
// +vcd        write cpu_bench.vcd
`timescale 1ns/1ps

module tb_cpu_bench;

    logic clk = 1'b0;
    always #5 clk = ~clk;
    logic rst_n = 1'b0;
    logic rdy   = 1'b1;
    logic irq_n = 1'b1, nmi_n = 1'b1;

    //---------------------------------------------------------------- memories
    logic [7:0] mem_ref [0:(1<<24)-1];
    logic [7:0] mem_dut [0:(1<<24)-1];
    bit         rom_mode = 0;

    function automatic logic [23:0] map(input logic [23:0] a);
        // ROM-mode address translation shared by both cores
        if (!rom_mode) return a;
        if ((a[23:16] == 8'h00 || a[23:16] == 8'h01 || a[23:16] == 8'hE0 || a[23:16] == 8'hE1)
            && a[15:8] != 8'hC0 && a[15:12] >= 4'hC)
            return {8'hFF, a[15:0]};
        return a;
    endfunction

    function automatic logic [7:0] rd_ref(input logic [23:0] a);
        return mem_ref[map(a)];
    endfunction
    function automatic logic [7:0] rd_dut(input logic [23:0] a);
        return mem_dut[map(a)];
    endfunction

    //---------------------------------------------------------------- cores
    bit   ce2 = 0;
    logic ce = 1'b1;
    always @(negedge clk) ce <= ce2 ? ~ce : 1'b1;
    logic [7:0]  ref_din, ref_dout, dut_din, dut_dout;
    logic [23:0] ref_a, dut_a;
    logic        ref_we, ref_vpb, ref_rdyo, ref_vpa, ref_vda, ref_mlb, ref_if;
    logic        dut_we, dut_vpb, dut_rdyo, dut_vpa, dut_vda, dut_mlb, dut_if;

    P65C816 u_ref (
        .CLK(clk), .RST_N(rst_n), .CE(ce), .RDY_IN(rdy),
        .NMI_N(nmi_n), .IRQ_N(irq_n), .ABORT_N(1'b1),
        .D_IN(ref_din), .D_OUT(ref_dout), .A_OUT(ref_a), .WE(ref_we), .RDY_OUT(ref_rdyo),
        .VPA(ref_vpa), .VDA(ref_vda), .MLB(ref_mlb), .VPB(ref_vpb), .I_FLAG(ref_if));

    F65C816 u_dut (
        .CLK(clk), .RST_N(rst_n), .CE(ce), .CE_X({4{ce}}), .RDY_IN(rdy),
        .NMI_N(nmi_n), .IRQ_N(irq_n), .ABORT_N(1'b1),
        .D_IN(dut_din), .D_OUT(dut_dout), .A_OUT(dut_a), .WE(dut_we), .RDY_OUT(dut_rdyo),
        .VPA(dut_vpa), .VDA(dut_vda), .MLB(dut_mlb), .VPB(dut_vpb), .I_FLAG(dut_if));

    always_comb ref_din = rd_ref(ref_a);
    // data-late memory model (+datalate)
    bit          datalate = 0;
    logic [7:0]  dl_rdata, dl_wd;
    logic [23:0] dl_wa;
    logic        dl_wr = 1'b0;
    longint      dl_collisions = 0;
    wire         dl_hit = dl_wr && (map(dl_wa) == map(dut_a));
    always_comb dut_din = !datalate ? rd_dut(dut_a) : dl_hit ? dl_wd : dl_rdata;

    //---------------------------------------------------------------- bookkeeping
    typedef struct packed {
        logic [23:0] pc;
        logic [15:0] a, x, y, sp, d;
        logic [8:0]  p;
        logic [7:0]  pbr, dbr;
    } arch_t;
    typedef struct packed { logic [23:0] a; logic [7:0] d; } wr_t;

    arch_t ref_arch_q[$], dut_arch_q[$];
    wr_t   ref_wr_q[$],   dut_wr_q[$];

    longint ref_steps = 0, dut_steps = 0, ref_instrs = 0, dut_instrs = 0;
    longint ref_mark_steps = 0, dut_mark_steps = 0, ref_mark_instrs = 0, dut_mark_instrs = 0;
    longint ref_mark_tab[0:255], dut_mark_tab[0:255];   // step deltas per mark id
    int     marks_seen[0:255];
    int     mark_order[$];
    bit     ref_done = 0, dut_done = 0;
    int     ref_status = -1, dut_status = -1;
    int     errors = 0, lockstep = 1, trace = 0;
    longint max_cycles = 8000000, clocks = 0;

    task automatic err(input string s);
        errors++;
        $display("ERROR @%0t clk %0d: %s", $time, clocks, s);
        if (errors > 20) begin $display("too many errors"); finish_up(); end
    endtask

    function automatic string arch_str(input arch_t r);
        return $sformatf("pc=%06h a=%04h x=%04h y=%04h sp=%04h d=%04h p=%03h(e%b) pbr=%02h dbr=%02h",
                         r.pc, r.a, r.x, r.y, r.sp, r.d, r.p[7:0], r.p[8], r.pbr, r.dbr);
    endfunction

    // bench port (bank 0 $BFF0-$BFF2), per core
    task automatic port_write(input bit is_dut, input logic [7:0] off, input logic [7:0] v);
        string who = is_dut ? "dut" : "ref";
        case (off)
            8'hF0: begin
                if (is_dut) begin dut_done = 1; dut_status = v; end else begin ref_done = 1; ref_status = v; end
                $display("[%s] DONE status=%0d steps=%0d instrs=%0d", who, v,
                         is_dut ? dut_steps : ref_steps, is_dut ? dut_instrs : ref_instrs);
            end
            8'hF1: if (!is_dut) $write("%c", v);
            8'hF2: begin
                longint ds, di;
                if (is_dut) begin
                    ds = dut_steps - dut_mark_steps; di = dut_instrs - dut_mark_instrs;
                    dut_mark_steps = dut_steps; dut_mark_instrs = dut_instrs; dut_mark_tab[v] = ds;
                end else begin
                    ds = ref_steps - ref_mark_steps; di = ref_instrs - ref_mark_instrs;
                    ref_mark_steps = ref_steps; ref_mark_instrs = ref_instrs; ref_mark_tab[v] = ds;
                    if (!marks_seen[v]) mark_order.push_back(v);
                end
                marks_seen[v]++;
                $display("[%s] MARK %0d: steps=%0d instrs=%0d (%.2f steps/instr)", who, v, ds, di,
                         di ? real'(ds) / real'(di) : 0.0);
            end
            default: ;
        endcase
    endtask

    //---------------------------------------------------------------- per-step model
    always @(posedge clk) begin
      // synchronous read at the next-step address, evaluated before this edge's write
      if (datalate && (!rst_n || dut_rdyo)) begin
          logic [23:0] na;
          bit          wr_now;
          na = u_dut.NA_OUT;
          wr_now = rst_n && !dut_we && !(!rom_mode && dut_a[23:8] == 16'h00BF && dut_a[7:4] == 4'hF);
          if (wr_now && map(na) == map(dut_a)) begin
              dl_rdata <= ~mem_dut[map(na)];      // collision: not the new data, not the old
              dl_collisions++;
          end else
              dl_rdata <= mem_dut[map(na)];
          dl_wr <= wr_now; dl_wa <= dut_a; dl_wd <= dut_dout;
      end
      if (rst_n) begin
        clocks++;
        if (rdy && ce) begin
            arch_t r;
            wr_t w;
            // ---- reference
            ref_steps++;
            if (trace) $display("[ref] %06h %s %02h vpa%b vda%b vp%b", ref_a, ref_we ? "R" : "W",
                                ref_we ? ref_din : ref_dout, ref_vpa, ref_vda, ref_vpb);
            if (ref_vpa && ref_vda && ref_we) begin
                ref_instrs++;
                r = '{pc: ref_a, a: u_ref.A, x: u_ref.X, y: u_ref.Y, sp: u_ref.SP, d: u_ref.D,
                      p: u_ref.P, pbr: u_ref.PBR, dbr: u_ref.DBR};
                ref_arch_q.push_back(r);
            end
            if (!ref_we) begin
                if (!rom_mode && ref_a[23:8] == 16'h00BF && ref_a[7:4] == 4'hF) port_write(0, ref_a[7:0], ref_dout);
                else begin
                    mem_ref[map(ref_a)] = ref_dout;
                    w = '{a: ref_a, d: ref_dout}; ref_wr_q.push_back(w);
                end
            end
            // ---- DUT
            dut_steps++;
            if (dut_vpa && dut_vda && dut_we) begin
                dut_instrs++;
                r = '{pc: dut_a, a: u_dut.A, x: u_dut.X, y: u_dut.Y, sp: u_dut.SP, d: u_dut.D,
                      p: u_dut.P, pbr: u_dut.PBR, dbr: u_dut.DBR};
                dut_arch_q.push_back(r);
            end
            if (!dut_we) begin
                if (!rom_mode && dut_a[23:8] == 16'h00BF && dut_a[7:4] == 4'hF) port_write(1, dut_a[7:0], dut_dout);
                else begin
                    mem_dut[map(dut_a)] = dut_dout;
                    w = '{a: dut_a, d: dut_dout}; dut_wr_q.push_back(w);
                end
            end
            // ---- lockstep
            if (lockstep) begin
                if (ref_a != dut_a || ref_we != dut_we || ref_vpa != dut_vpa || ref_vda != dut_vda ||
                    ref_vpb != dut_vpb || (!ref_we && ref_dout != dut_dout) || (ref_we && ref_din != dut_din))
                    err($sformatf("LOCKSTEP: ref %06h %s %02h vpa%b vda%b vp%b | dut %06h %s %02h vpa%b vda%b vp%b",
                        ref_a, ref_we ? "R" : "W", ref_we ? ref_din : ref_dout, ref_vpa, ref_vda, ref_vpb,
                        dut_a, dut_we ? "R" : "W", dut_we ? dut_din : dut_dout, dut_vpa, dut_vda, dut_vpb));
            end
            // ---- architectural
            while (ref_arch_q.size() > 0 && dut_arch_q.size() > 0) begin
                arch_t ra = ref_arch_q.pop_front(), da = dut_arch_q.pop_front();
                if (ra !== da) begin
                    err($sformatf("ARCH divergence at instruction %0d:\n   ref %s\n   dut %s",
                                  ref_instrs - ref_arch_q.size(), arch_str(ra), arch_str(da)));
                    finish_up();
                end
            end
            while (ref_wr_q.size() > 0 && dut_wr_q.size() > 0) begin
                wr_t rw = ref_wr_q.pop_front(), dw = dut_wr_q.pop_front();
                if (rw !== dw) begin
                    err($sformatf("WRITE-STREAM divergence: ref %06h<=%02h dut %06h<=%02h", rw.a, rw.d, dw.a, dw.d));
                    finish_up();
                end
            end
            if (ref_arch_q.size() > 100000 || dut_arch_q.size() > 100000) begin
                err("one core is not fetching opcodes any more (queue runaway)"); finish_up();
            end
        end
      end
    end

    //---------------------------------------------------------------- RDY stalls
    logic [15:0] lfsr = 16'hACE1;
    bit stall_on = 0;
    always @(negedge clk) if (rst_n && stall_on) begin
        lfsr <= {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};
        rdy  <= (lfsr[2:0] != 3'b000);   // ~12% stall cycles
    end

    //---------------------------------------------------------------- interrupts
    logic [22:0] ilfsr = 23'h2A5A5A;
    bit irq_on = 0;
    longint irq_pulses = 0, nmi_pulses = 0;
    always @(negedge clk) if (rst_n && irq_on) begin
        ilfsr <= {ilfsr[21:0], ilfsr[22] ^ ilfsr[17]};
        // IRQ: level, held ~64 clocks about every 2000; NMI: 4-clock low pulse about every 16000
        if (ilfsr[10:0] == 11'h5A3) begin irq_n <= 1'b0; irq_pulses++; end
        else if (ilfsr[5:0] == 6'h2B) irq_n <= 1'b1;
        if (ilfsr[13:0] == 14'h1F37) begin nmi_n <= 1'b0; nmi_pulses++; end
        else if (ilfsr[1:0] == 2'b10) nmi_n <= 1'b1;
    end

    //---------------------------------------------------------------- report
    task automatic finish_up();
        $display("");
        $display("==== CPU bench summary: %0d clocks, ref %0d steps / %0d instrs, dut %0d steps / %0d instrs",
                 clocks, ref_steps, ref_instrs, dut_steps, dut_instrs);
        if (mark_order.size() > 0) begin
            $display("  mark      ref steps      dut steps   dut/ref");
            foreach (mark_order[i]) begin
                int m = mark_order[i];
                $display("  %4d  %13d  %13d   %.4f", m, ref_mark_tab[m], dut_mark_tab[m],
                         ref_mark_tab[m] ? real'(dut_mark_tab[m]) / real'(ref_mark_tab[m]) : 0.0);
            end
        end
        if (irq_on) $display("  interrupts: %0d IRQ assertions, %0d NMI pulses", irq_pulses, nmi_pulses);
        if (datalate) $display("  data-late memory: %0d write/read collisions served by the bypass", dl_collisions);
        if (!ref_done && !rom_mode) $display("  reference did not reach DONE");
        if (!dut_done && !rom_mode) $display("  DUT did not reach DONE");
        if (ref_status != 0 && ref_done) $display("  reference program status %0d (nonzero = self-check failed)", ref_status);
        if (dut_status != 0 && dut_done) $display("  DUT program status %0d (nonzero = self-check failed)", dut_status);
        if (errors == 0 && ((ref_done && dut_done && ref_status == 0 && dut_status == 0) || rom_mode)) $display("PASS");
        else $display("FAIL (%0d errors)", errors);
        $finish;
    endtask

    //---------------------------------------------------------------- load + run
    initial begin
        string path;
        int fd, n, v;
        if ($test$plusargs("trace")) trace = 1;
        if ($test$plusargs("stall")) stall_on = 1;
        if ($test$plusargs("ce2")) ce2 = 1;
        if ($test$plusargs("datalate")) datalate = 1;
        if ($test$plusargs("irq")) irq_on = 1;
        if (!$value$plusargs("lockstep=%d", lockstep)) lockstep = 1;
        if (!$value$plusargs("cycles=%d", max_cycles)) max_cycles = 8000000;
        if ($test$plusargs("vcd")) begin $dumpfile("cpu_bench.vcd"); $dumpvars(0, tb_cpu_bench); end

        if ($value$plusargs("rom=%s", path)) begin
            rom_mode = 1;
            fd = $fopen(path, "rb");
            if (fd == 0) begin $display("cannot open ROM %s", path); $finish; end
            n = 0;
            while (!$feof(fd) && n < (1<<17)) begin
                v = $fgetc(fd); if (v < 0) break;
                mem_ref[24'hFE0000 + n] = v[7:0]; mem_dut[24'hFE0000 + n] = v[7:0]; n++;
            end
            $fclose(fd);
            if (n != (1<<17)) begin $display("ROM %s: read %0d bytes, want 131072", path, n); $finish; end
            $display("ROM mode: %s loaded at FE0000", path);
        end else if ($value$plusargs("prog=%s", path)) begin
            fd = $fopen(path, "rb");
            if (fd == 0) begin $display("cannot open program %s", path); $finish; end
            n = 0;
            while (!$feof(fd) && n < (1<<16)) begin
                v = $fgetc(fd); if (v < 0) break;
                mem_ref[n] = v[7:0]; mem_dut[n] = v[7:0]; n++;
            end
            $fclose(fd);
            $display("program %s: %0d bytes at 000000", path, n);
        end else begin
            $display("need +prog=<image> or +rom=<boot1.rom>"); $finish;
        end

        repeat (4) @(posedge clk);
        #1 rst_n = 1'b1;
        while (clocks < max_cycles) begin
            @(posedge clk);
            if (ref_done && dut_done) begin repeat (4) @(posedge clk); finish_up(); end
        end
        $display("TIMEOUT after %0d clocks", clocks);
        finish_up();
    end
endmodule
