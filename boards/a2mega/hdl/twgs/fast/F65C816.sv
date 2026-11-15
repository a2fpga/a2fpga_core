//============================================================================
//  65C816 CPU core
//
//  SystemVerilog conversion of the VHDL 65C816 core written by srg320 for
//  SNES_MiSTer (https://github.com/MiSTer-devel/SNES_MiSTer), with
//  modifications for the Apple IIgs. See README.md in this directory.
//
//  Copyright (c) srg320 -- original VHDL implementation
//  Copyright (c) 2026 Alan Steremberg -- Verilog conversion and IIgs changes
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of version 3 of the GNU General Public License as
//  published by the Free Software Foundation.
//
//  This program is distributed in the hope that it will be useful, but WITHOUT
//  ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
//  FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for
//  more details.
//
//  You should have received a copy of the GNU General Public License along
//  with this program. If not, see <https://www.gnu.org/licenses/>.
//============================================================================
import F65C816_pkg::*;

module F65C816
  (
   input         CLK/*verilator public_flat*/,
   input         RST_N,
   input         CE,
   input [3:0]   CE_X,   // S7: four more copies of CE (same value), one per group of registers

   input         RDY_IN,
   input         NMI_N,
   input         IRQ_N/*verilator public_flat*/,
   input         ABORT_N,
   input [7:0]   D_IN/*verilator public_flat*/,
   output [7:0]  D_OUT/*verilator public_flat*/,
   output [23:0] A_OUT/*verilator public_flat*/,
   output logic  WE/*verilator public_flat*/,
   output logic  RDY_OUT,
   output logic  VPA/*verilator public_flat*/,
   output logic  VDA/*verilator public_flat*/,
   output logic  MLB/*verilator public_flat*/,
   output logic  VPB/*verilator public_flat*/,
   output logic  I_FLAG, // P[2] (interrupt disable) — accelerator IRQ-delay tap
   output [23:0] NA_OUT, // S7 data-late: address of the NEXT step (valid while RDY_OUT), A_OUT is its register
   output [2:0]  NST_OUT, // ... and its bus status: {VPB, WE (1 = read), internal (VPA = VDA = 0)}
   output [13:0] NA_OUT_B // NA_OUT[13:0] again, from gates of its own: the read address of a memory
                          // whose blocks are far apart can be driven half from each
   );

  logic [15:0]   A/*verilator public_flat*/;
  logic [15:0]   X/*verilator public_flat*/;
  logic [15:0]   Y/*verilator public_flat*/;
  logic [15:0]   D/*verilator public_flat*/;
  logic [15:0]   SP/*verilator public_flat*/;
  logic [15:0]   T/*verilator public_flat*/;
  logic [7:0]    PBR/*verilator public_flat*/;
  logic [7:0]    DBR/*verilator public_flat*/;
  logic [8:0]    P/*verilator public_flat*/;
  logic [15:0]   PC/*verilator public_flat*/;

  logic [7:0]    DR;
  logic          EF;
  logic          XF;
  logic          MF;
  logic          oldXF;
  logic [15:0]   SB;
  logic [15:0]   DB;
  logic          EN/*verilator public_flat*/;
  FMCode_r          MC;
  logic [7:0]    IR/*verilator public_flat*/;
  logic [7:0]    NextIR;
  logic [3:0]    STATE;
  // rung 4a: their own copies of IR / STATE for the two microcode lookups (the
  // lookups are most of the load on those registers; kept apart by synthesis)
  logic [7:0]    IR_m    /* synthesis syn_preserve = 1 */;
  logic [3:0]    STATE_m /* synthesis syn_preserve = 1 */;
  logic [3:0]    NextState;
  logic          NS_ZERO;    // rung 3: NextState == 0
  logic          NS_INC2;    // rung 3: NextState == STATE + 2
  logic [23:0]   SN;         // rung 3: address fields and VA of the two successor rows
  logic          LAST_CYCLE;
  logic          GotInterrupt;
  logic          IsResetInterrupt;
  logic          IsNMIInterrupt;
  logic          IsIRQInterrupt;
  logic          IsABORTInterrupt;
  logic          IsBRKInterrupt;
  logic          IsCOPInterrupt;
  logic          JumpTaken;
  logic          JumpNoOverflow;
  logic          IsBranchCycle1;
  logic          w16;
  logic          DLNoZero;
  logic          WAIExec;
  logic          STPExec;
  logic          NMI_SYNC;
  logic          NMI_ACTIVE;
  logic          IRQ_ACTIVE;
  logic          OLD_NMI_N;
  logic          OLD_NMI2_N;
  logic [23:0]   ADDR_BUS;
  logic          EmuSPWrap; // deprecated heuristic (kept if needed)
  logic          EmuStackSeqActive;
  logic          EmuSPZeroAtStart;
  logic          EmuSPFFAtStart;
  // PLD-specific tracking (emulation mode): latch SP low at first stack read
  logic          PLD_SeqActive;
  logic  [7:0]   PLD_SP0;
  logic  [7:0]   PLD_SPW0;
  logic          PLD_Addr0_Valid;
  logic [15:0]   PLD_Addr0;
  logic          PLD_WrapFF_Latched;
  logic  [7:0]   PLD_Low0;
  logic          PLD_FirstCarry;
  // PER/PEI (emulation) 16-bit stack push sequence tracking on 4'b0101 bus
  logic          PERPEI_SeqActive;
  logic          PERPEI_FirstDone;
  // JSR long (22) emulation: track start of two PC-byte pushes and whether it started at SP low FF
  logic          JSRL_SeqActive;
  logic          JSRL_WrapFF;
  // RTL (6B) emulation: track first stack read base to compute subsequent bytes
  logic          RTL_SeqActive;
  logic  [15:0]  RTL_BaseAddr;
  logic  [1:0]   RTL_Offset;
  logic          RTL_WrapFF;
  logic  [7:0]   RTL_SPW0;
  // Snapshot of SP for write address decisions within a cycle
  logic [15:0]   SPW;

  logic [15:0]   AluR;
  logic [15:0]   AluIntR;
  logic          CO;
  logic          VO;
  logic          SO;
  logic          ZO;

  logic [16:0]   AA;
  logic [7:0]    AB;
  logic [15:0]   PC_n;       // S7 data-late: next-step values out of AddrGen
  logic [16:0]   AA_n;
  logic [7:0]    AB_n;
  logic [15:0]   DX_n;
  logic          AALCarry;
  logic [15:0]   DX;

  logic          DBG_DAT_WRr;
  logic [23:0]   DBG_BRK_ADDR;
  logic [7:0]    DBG_CTRL;
  logic          DBG_RUN_LAST;
  logic [15:0]   DBG_NEXT_PC;
  logic [23:0]   JSR_RET_ADDR;
  logic          JSR_FOUND;

  assign EN = RDY_IN & CE & (~WAIExec) & (~STPExec);
  // S7: the step enable reaches every register of the core in one clk of the
  // accelerator clock; separate copies for the microcode registers, the address
  // generator, the register file and the flags / data register keep each net
  // short (same value as EN).
  // (They are made from separate copies of CE, CE_X: copies made from the one
  // CE are merged again by synthesis.)
  wire EN_m = RDY_IN & CE_X[0] & (~WAIExec) & (~STPExec);
  wire EN_g = RDY_IN & CE_X[1] & (~WAIExec) & (~STPExec);
  wire EN_r = RDY_IN & CE_X[2] & (~WAIExec) & (~STPExec);
  wire EN_p = RDY_IN & CE_X[3] & (~WAIExec) & (~STPExec);
`ifdef VERILATOR
  always @(posedge CLK) if (RST_N == 1'b1 && CE_X !== {4{CE}}) $display("ERROR: CE_X %b differs from CE %b @%0t", CE_X, CE, $time);
`endif

  assign IsBranchCycle1 = (IR[4:0] == 5'b10000 & STATE == 4'b0001) ? 1'b1 :
                          1'b0;


// Debug prints removed


   always_comb begin
      case (IR[7:5])
         3'b000 :
            JumpTaken = (~P[7]);
         3'b001 :
            JumpTaken = P[7];
         3'b010 :
            JumpTaken = (~P[6]);
         3'b011 :
            JumpTaken = P[6];
         3'b100 :
            JumpTaken = (~P[0]);
         3'b101 :
            JumpTaken = P[0];
         3'b110 :
            JumpTaken = (~P[1]);
         3'b111 :
            JumpTaken = P[1];
         default :
            JumpTaken = 1'b0;
      endcase
   end
   assign DLNoZero = (D[7:0] == 8'h00) ? 1'b0 :
                     1'b1;

   assign NextIR = ((STATE != 4'b0000)) ? IR :
                   (GotInterrupt == 1'b1) ? 8'h00 :
                   D_IN;


   always_comb begin
      NS_ZERO = 1'b0;
      NS_INC2 = 1'b0;
      case (MC.STATE_CTRL)
         3'b000 :
            NextState = STATE + 4'd1;
         3'b001 :
            if (AALCarry == 1'b0 & (XF == 1'b1 | EF == 1'b1))
               begin NextState = STATE + 4'd2; NS_INC2 = 1'b1; end
            else
               NextState = STATE + 4'd1;
         3'b010 :
            if (IsBranchCycle1 == 1'b1 & JumpTaken == 1'b1)
               NextState = 4'b0010;
            else
               begin NextState = 4'b0000; NS_ZERO = 1'b1; end
         3'b011 :
            if (JumpNoOverflow == 1'b1 | EF == 1'b0)
               begin NextState = 4'b0000; NS_ZERO = 1'b1; end
            else
               NextState = STATE + 4'd1;
         3'b100 :
            if ((MC.LOAD_AXY[1] == 1'b0 & MF == 1'b0 & EF == 1'b0) | (MC.LOAD_AXY[1] == 1'b1 & XF == 1'b0 & EF == 1'b0))
               NextState = STATE + 4'd1;
            else
               begin NextState = 4'b0000; NS_ZERO = 1'b1; end
         3'b101 :
            if (DLNoZero == 1'b1)
               NextState = STATE + 4'd1;
            else
               begin NextState = STATE + 4'd2; NS_INC2 = 1'b1; end
         3'b110 :
            if ((MC.LOAD_AXY[1] == 1'b0 & MF == 1'b0 & EF == 1'b0) | (MC.LOAD_AXY[1] == 1'b1 & XF == 1'b0 & EF == 1'b0))
               NextState = STATE + 4'd1;
            else
               begin NextState = STATE + 4'd2; NS_INC2 = 1'b1; end
         3'b111 :
            if (EF == 1'b0)
               NextState = STATE + 4'd1;
            else
               begin NextState = STATE + 4'd2; NS_INC2 = 1'b1; end
         default :
            ;
      endcase
   end

   assign LAST_CYCLE = (NextState == 4'b0000) ? 1'b1 :
                       1'b0;


   always @(posedge CLK or negedge RST_N)
      if (RST_N == 1'b0)
      begin
         STATE <= {4{1'b0}};
         IR <= {8{1'b0}};
         STATE_m <= {4{1'b0}};
         IR_m <= {8{1'b0}};
`ifdef DEBUG_VERBOSE
         $display("CPU_RESET: RST_N asserted (low), STATE<=0, IR<=0");
`endif
      end
      else
      begin
`ifdef DEBUG_RESET
         // Debug reset vector fetch
         if (IsResetInterrupt && MC.ADDR_BUS == 4'b1111) begin
            $display("CPU_RESET_VECTOR: IsResetInterrupt=%d ADDR_BUS=%06x D_IN=%02x STATE=%d EN=%d",
                     IsResetInterrupt, ADDR_BUS, D_IN, STATE, EN);
         end
         // Debug when reset interrupt clears
         if (GotInterrupt && LAST_CYCLE && EN) begin
            $display("CPU_RESET_COMPLETE: GotInterrupt clearing, PC will be %04x (DR=%02x D_IN=%02x)",
                     {D_IN, DR}, DR, D_IN);
         end
`endif
         if (IR == 8'h28 && STATE == 3) begin
            //$display("CYCLE_START: EN=%d STATE=%d NextState=%d PC=%02x:%04x ADDR_BUS=%06x D_IN=%02x", EN, STATE, NextState, PBR, {PC[15:8], PC[7:0]}, ADDR_BUS, D_IN);
         end

         if (EN == 1'b1)
         begin
            if (IR == 8'h28 && STATE == 3) begin
              // $display("STATE_UPDATE: EN=1, assigning STATE<=%d (currently %d)", NextState, STATE);
            end
            IR <= NextIR;
            STATE <= NextState;
            IR_m <= NextIR;
            STATE_m <= NextState;

            // Debug: Track every instruction completion with P[2] value (after this cycle completes)
            if (LAST_CYCLE && EN) begin
               //if (MC.LOAD_P == 3'b011)
                  //$display("INSTR_COMPLETE: %02x:%04x IR=%02x P[2]=%d (PLP will load %d from stack=%02x)", PBR, PC, IR, P[2], D_IN[2], D_IN);
               //else
                  //$display("INSTR_COMPLETE: %02x:%04x IR=%02x P[2]=%d", PBR, PC, IR, P[2]);
            end

            // Debug: Track MVN instruction state transitions
            if (IR == 8'h54 && STATE != NextState) begin
               //$display("MVN_STATE: %02x:%04x STATE %d -> %d (A=%04x P[2]=%d)", PBR, PC, STATE, NextState, A, P[2]);
            end

`ifdef DEBUG_VERBOSE
            // Debug: Track P[2] for every MVN instruction cycle
            if (IR == 8'h54) begin
               $display("MVN_P2_TRACK: %02x:%04x STATE=%d P[2]=%d IRQ_ACTIVE=%d LAST_CYCLE=%d",
                        PBR, PC, STATE, P[2], IRQ_ACTIVE, LAST_CYCLE);
            end
`endif
         end
      end


   // rung 4: the microcode module takes the registered IR / STATE and the late
   // decision as selects (the next state is 0, STATE + 1 or STATE + 2; 1 in the
   // fetch step, with the opcode on the bus) - see gen_fast_mcode.py
   // (F65C816_MCODE_ROM: the successor rows from block RAM, for a core that steps no
   // faster than every second clk - rung 5, gen_fast_mcode.py; the same registered row)
`ifdef F65C816_MCODE_ROM
   F65C816_mcode_s
`else
   F65C816_mcode
`endif
                 MCode(.CLK(CLK), .RST_N(RST_N), .EN(EN_m), .IR(IR_m), .STATE(STATE_m), .NIR(NextIR),
                       .NS_ZERO(NS_ZERO), .NS_INC2(NS_INC2), .M(MC), .SN(SN));
`ifdef VERILATOR
   always @(posedge CLK)
      if (RST_N == 1'b1 && EN == 1'b1 &&
          NextState !== ((STATE == 4'd0) ? 4'd1 : NS_ZERO ? 4'd0 : NS_INC2 ? STATE + 4'd2 : STATE + 4'd1)) begin
         $display("ERROR: NextState %0d is not 0 / STATE + 1 / STATE + 2 as flagged (STATE %0d zero %b inc2 %b IR %02h) @%0t",
                  NextState, STATE, NS_ZERO, NS_INC2, IR, $time);
         $finish;
      end
`endif


   // S7 data-late: the MVN/MVP repeat decision (LOAD_PC == 111, step 5 of 44/54) was the
   // ALU's carry-out of A - 1, which put memory data -> ALU -> carry -> PC adder in front
   // of the next address.  In that step the ALU operands are A and the constant 1 in 16-bit
   // mode (BUS_CTRL 000101, ALU row 10000: checked by gen_fast_mcode.py), so the carry is
   // simply A != 0, a function of the register alone.
   wire PCDecA = (A != 16'h0000);
`ifdef VERILATOR
   always @(posedge CLK)
      if (RST_N == 1'b1 && EN == 1'b1 && MC.LOAD_PC == 3'b111 && CO !== PCDecA)
         $display("PCDec MISMATCH @%0t: CO=%b A=%04h", $time, CO, A);
`endif

   F65C816_AddrGen AddrGen(.CLK(CLK), .RST_N(RST_N), .EN(EN_g), .LOAD_PC(MC.LOAD_PC), .PCDec(PCDecA), .GotInterrupt(GotInterrupt), .ADDR_CTRL(MC.ADDR_CTRL), .IND_CTRL(MC.IND_CTRL), .D_IN(D_IN), .X(X), .Y(Y), .D(D), .S(SP), .T(T), .DR(DR), .DBR(DBR), .e6502(EF), .PC(PC), .AA(AA), .AB(AB), .DX(DX), .AALCarry(AALCarry), .JumpNoOfl(JumpNoOverflow),
                           .PC_n(PC_n), .AA_n(AA_n), .AB_n(AB_n), .DX_n(DX_n));

   // rung 2b: the IR/STATE terms of w16 are pre-decoded into the microcode
   // (XT_TAB, gen_fast_mcode.py); only the mode flags are evaluated at run time.
   assign w16 = MC.W16_FORCE | (MC.W16_M & ~MF & ~EF) | (MC.W16_X & ~XF & ~EF);

   // rung 2b: AND-OR operand muxes from one-hot selects (same values as the
   // stock priority mux: every select value is covered, 6/7 on DB give zero).
   assign SB = ({16{MC.SB_SEL[0]}} & A) | ({16{MC.SB_SEL[1]}} & X) | ({16{MC.SB_SEL[2]}} & Y) |
               ({16{MC.SB_SEL[3]}} & D) | ({16{MC.SB_SEL[4]}} & T) |
               ({16{MC.SB_SEL[5]}} & (EF ? {8'h01, SP[7:0]} : SP)) |
               ({16{MC.SB_SEL[6]}} & {8'h00, PBR}) | ({16{MC.SB_SEL[7]}} & {8'h00, DBR});

   assign DB = ({16{MC.DB_SEL[0]}} & {8'h00, D_IN}) | ({16{MC.DB_SEL[1]}} & {D_IN, DR}) |
               ({16{MC.DB_SEL[2]}} & SB) | ({16{MC.DB_SEL[3]}} & D) |
               ({16{MC.DB_SEL[4]}} & T) | ({16{MC.DB_SEL[5]}} & 16'h0001);


   F65C816_ALU ALU(.CTRL(MC.ALU_CTRL), .L(SB), .R(DB), .w16(w16), .BCD(P[3]), .CI(P[0]), .VI(P[6]), .SI(P[7]), .CO(CO), .VO(VO), .SO(SO), .ZO(ZO), .RES(AluR), .IntR(AluIntR));

   assign MF = P[5];
   assign XF = P[4];
   assign EF = P[8];


   // S7 data-late: SP's next value (assuming the step is enabled) as logic of its own;
   // the register block below loads it, the address one step ahead reads it.
   logic [15:0] SP_n;
   always @* begin
      SP_n = SP;
      if (IR == 8'hFB & (P[0] == 1'b1 | P[8] == 1'b1) & MC.LOAD_P == 3'b101)
         SP_n = {8'h01, SP[7:0]};
      else begin
            case (MC.LOAD_SP)
               3'b000 :
                  ;
               3'b001 :
                  if (EF == 1'b0)
                     SP_n = (SP + 16'd1);
                  else
                     // Emulation: maintain full 16-bit SP for arithmetic
                     SP_n = (SP + 16'd1);
               3'b010 :
                  if (MC.BYTE_SEL[1] == 1'b0 & w16 == 1'b1)
                  begin
                     if (EF == 1'b0)
                        SP_n = (SP + 16'd1);
                     else
                        SP_n = ({8'h01, SP[7:0]} + 16'd1);
                  end
               3'b011 :
                  if (EF == 1'b0)
                     SP_n = (SP - 16'd1);
                  else
                     SP_n = (SP - 16'd1);
               3'b100 :
                  if (EF == 1'b0)
                     SP_n = A;
                  else begin
                     SP_n[15:8] = 8'h01;
                     SP_n = {8'h01, A[7:0]};
                  end
               3'b101 :
                  if (EF == 1'b0)
                     SP_n = X;
                  else begin
                     SP_n[15:8] = 8'h01;
                     SP_n = {8'h01, X[7:0]};
                  end
               3'b110 :
                  if (EF == 1'b0)
                     SP_n = (SP + 16'd1);
                  else
                     SP_n = (SP + 16'd1);
               3'b111 :
                  if (EF == 1'b0)
                     SP_n = (SP - 16'd1);
                  else
                     SP_n = (SP - 16'd1);
               default :
                  ;
            endcase
      end
   end

   always @(posedge CLK or negedge RST_N)
      if (RST_N == 1'b0)
      begin
         A <= {16{1'b0}};
         X <= {16{1'b0}};
         Y <= {16{1'b0}};
         SP <= 16'h0100;
         oldXF <= 1'b1;
      end
      else
      begin
         // XCE: Force SP high=$01, X/Y high=0 when involving emulation mode.
         // P[0]=carry, P[8]=emulation BEFORE the swap. After XCE: new_E=old_C, new_C=old_E.
         // Force when: entering emulation (P[0]=1), OR leaving emulation (P[8]=1, SP was
         // constrained to 0x01xx). Only skip when both=0 (native with C=0, stays native).
         if (IR == 8'hFB & (P[0] == 1'b1 | P[8] == 1'b1) & MC.LOAD_P == 3'b101)
         begin
            X[15:8] <= 8'h00;
            Y[15:8] <= 8'h00;
            SP <= SP_n;
            oldXF <= 1'b1;
         end
         else if (EN_r == 1'b1)
         begin
            if (MC.LOAD_AXY == 3'b110)
            begin
               if (MC.BYTE_SEL[1] == 1'b1 & XF == 1'b0 & EF == 1'b0)
               begin
                  X[15:8] <= AluR[15:8];
                  X[7:0] <= AluR[7:0];
               end
               else if (MC.BYTE_SEL[0] == 1'b1 & (XF == 1'b1 | EF == 1'b1))
               begin
                  X[7:0] <= AluR[7:0];
                  X[15:8] <= 8'h00;
               end
            end
            if (MC.LOAD_AXY == 3'b101)
            begin
               if (IR == 8'hEB)
               begin
                  A[15:8] <= A[7:0];
                  A[7:0] <= A[15:8];
               end
               else if ((MC.BYTE_SEL[1] == 1'b1 & MF == 1'b0 & EF == 1'b0) | (MC.BYTE_SEL[1] == 1'b1 & w16 == 1'b1))
               begin
                  A[15:8] <= AluR[15:8];
                  A[7:0] <= AluR[7:0];
               end
               else if (MC.BYTE_SEL[0] == 1'b1 & (MF == 1'b1 | EF == 1'b1))
                  A[7:0] <= AluR[7:0];
            end
            if (MC.LOAD_AXY == 3'b111)
            begin
               if (MC.BYTE_SEL[1] == 1'b1 & XF == 1'b0 & EF == 1'b0)
               begin
                  Y[15:8] <= AluR[15:8];
                  Y[7:0] <= AluR[7:0];
               end
               else if (MC.BYTE_SEL[0] == 1'b1 & (XF == 1'b1 | EF == 1'b1))
               begin
                  Y[7:0] <= AluR[7:0];
                  Y[15:8] <= 8'h00;
               end
            end

            oldXF <= XF;
            if (XF == 1'b1 & oldXF == 1'b0 & EF == 1'b0)
            begin
               X[15:8] <= 8'h00;
               Y[15:8] <= 8'h00;
            end

            SP <= SP_n;
         end
      end


   // S7: the next P.  The ALU's flags are its latest inputs (memory data -> ALU ->
   // carry / zero), so they are selected LAST, one level, against everything else
   // (P_o: the registers, the microinstruction and the data bus).  The same values
   // as the stock case statement, which had the ALU branch inside it.
   wire pf_alu = (MC.LOAD_P == 3'b001) & ~MC.PF_PLB & ~MC.PF_PLD & ~MC.PF_TSX &
                 (MC.PF_FORCE | (MC.PF_M8 & (MF | EF)) | (MC.PF_X8 & (XF | EF)) | (MC.PF_M16 & ((~MF & ~EF) | w16)) | (MC.PF_X16 & ~XF & ~EF));
   wire pf_z   = pf_alu | (MC.LOAD_P == 3'b111);
   logic [8:0] P_o;
   always_comb begin
      P_o = P;
      case (MC.LOAD_P)
         3'b001 :
            begin
               if (MC.PF_PLB)  // PLB (rung 2c: IR terms pre-decoded in XT_TAB)
               begin
                  P_o[7] = D_IN[7];  // N flag
                  P_o[1] = (D_IN == 8'h00);  // Z flag
               end
               else if (MC.PF_PLD)  // PLD
               begin
                  P_o[7] = D_IN[7];  // N flag from high byte
                  P_o[1] = ({D_IN, DR} == 16'h0000);  // Z flag
               end
               else if (MC.PF_TSX)  // TSX
               begin
                  if (XF == 1'b1 | EF == 1'b1)  // 8-bit X
                  begin
                     P_o[7] = SP[7];  // N flag from low byte
                     P_o[1] = (SP[7:0] == 8'h00);  // Z flag
                  end
                  else  // 16-bit X
                  begin
                     P_o[7] = SP[15];  // N flag from high byte
                     P_o[1] = (SP == 16'h0000);  // Z flag
                  end
               end
            end
         3'b010 :
            begin
               P_o[2] = 1'b1;
               P_o[3] = 1'b0;
            end
         3'b011 :
            begin
               P_o[7:6] = D_IN[7:6];
               P_o[5] = D_IN[5] | EF;
               P_o[4] = D_IN[4] | EF;
               P_o[3:0] = D_IN[3:0];
            end
         3'b100 :
            case (IR[7:6])
               2'b00 :
                  P_o[0] = IR[5];
               2'b01 :
                  P_o[2] = IR[5];
               2'b10 :
                  P_o[6] = 1'b0;
               2'b11 :
                  P_o[3] = IR[5];
               default :
                  ;
            endcase
         3'b101 :
            begin
               P_o[8] = P[0];
               P_o[0] = P[8];
               if (P[0] == 1'b1)
               begin
                  P_o[4] = 1'b1;
                  P_o[5] = 1'b1;
               end
            end
         3'b110 :
            case (IR[5])
               1'b1 :
                  P_o[7:0] = P[7:0] | ({DR[7:6], (DR[5] & (~EF)), (DR[4] & (~EF)), DR[3:0]});
               1'b0 :
                  P_o[7:0] = P[7:0] & ((~({DR[7:6], (DR[5] & (~EF)), (DR[4] & (~EF)), DR[3:0]})));
               default :
                  ;
            endcase
         default :
            ;
      endcase
   end
   wire [8:0] P_n = {P_o[8], pf_alu ? SO : P_o[7], pf_alu ? VO : P_o[6], P_o[5:2],
                     pf_z ? ZO : P_o[1], pf_alu ? CO : P_o[0]};

   always @(posedge CLK or negedge RST_N)
      if (RST_N == 1'b0)
         P <= 9'b100110100;
      else
      begin
         if (EN_p == 1'b1)
            P <= P_n;

            // Debug: Track I flag (P[2]) changes (only on the cycle where P actually changes)
            if (MC.LOAD_P == 3'b010) begin
               // SEI or CLD (sets I=1, D=0)
               //$display("I_FLAG_DEBUG: %02x:%04x SEI/CLD executed, P[2]: 0 -> 1 (IR=%02x STATE=%d)", PBR, PC, IR, STATE);
            end
            else if (MC.LOAD_P == 3'b011) begin
               // PLP - restore P from stack
               //$display("I_FLAG_DEBUG: %02x:%04x IR=%02x STATE=%d NextState=%d STATE_CTRL=%03b LAST_CYCLE=%d EN=%d PLP loads P, P[2]: %d -> %d (from stack=%02x)", PBR, PC, IR, STATE, NextState, MC.STATE_CTRL, LAST_CYCLE, EN, P[2], D_IN[2], D_IN);
            end
            else if (MC.LOAD_P == 3'b100 && IR[7:6] == 2'b01) begin
               // CLI or SEI (IR[5] = new value)
               //if (P[2] != IR[5])
               //   $display("I_FLAG_DEBUG: %02x:%04x CLI/SEI executed, P[2]: %d -> %d (IR=%02x STATE=%d)", PBR, PC, P[2], IR[5], IR, STATE);
            end
      end


   // S7 data-late: PBR / SPW next values (PBR loads from the bus in the last step of
   // RTI, RTL, JML: the fetch that follows is addressed with the new bank)
   logic [7:0]  PBR_n;
   logic [15:0] SPW_n;
   always @* begin
      PBR_n = PBR;
      if (MC.LOAD_DKB == 2'b10) begin
         if (IR == 8'h00 | IR == 8'h02)       PBR_n = 8'h00;
         else if (IR == 8'h40 & EF == 1'b1)   PBR_n = PBR;  // RTI in emulation mode: don't change PBR
         else                                 PBR_n = D_IN;
      end
      SPW_n = IsResetInterrupt ? SPW : SP;
   end

   always @(posedge CLK or negedge RST_N)
      if (RST_N == 1'b0)
      begin
         T <= {16{1'b0}};
         DR <= {8{1'b0}};
         D <= {16{1'b0}};
         PBR <= {8{1'b0}};
         DBR <= {8{1'b0}};
      end
      else
      begin
         if (EN_p == 1'b1)
         begin
            DR <= D_IN;

            case (MC.LOAD_T)
               2'b01 :
                  if (MC.BYTE_SEL[1] == 1'b1)
                     T[15:8] <= D_IN;
                  else
                     T[7:0] <= D_IN;
               2'b10 :
                  T <= AluR;
               default :
                  ;
            endcase

            case (MC.LOAD_DKB)
               2'b01 :
                  if (IR == 8'h2B)  // PLD - Load D from stack
                     D <= {D_IN, DR};  // High byte from D_IN, low byte from DR
                  else
                     D <= AluIntR;
               2'b10 :
                  PBR <= PBR_n;
               2'b11 :
                  if (IR == 8'h44 | IR == 8'h54 | IR == 8'hAB)  // MVN, MVP, PLB
                     DBR <= D_IN;
                  else
                     DBR <= AluIntR[7:0];
               default :
                  ;
            endcase
         end
      end

   assign D_OUT = (MC.OUT_BUS == 3'b001) ? {P[7], P[6], (P[5] | EF), ( EF ? ~GotInterrupt : P[4] ), P[3:0]} :
                  (MC.OUT_BUS == 3'b010 & MC.BYTE_SEL[1] == 1'b1) ? PC[15:8] :
                  (MC.OUT_BUS == 3'b010 & MC.BYTE_SEL[1] == 1'b0) ? PC[7:0] :
                  (MC.OUT_BUS == 3'b011 & MC.BYTE_SEL[1] == 1'b1) ? AA[15:8] :
                  (MC.OUT_BUS == 3'b011 & MC.BYTE_SEL[1] == 1'b0) ? AA[7:0] :
                  (MC.OUT_BUS == 3'b100) ? PBR :
                  (MC.OUT_BUS == 3'b101 & MC.BYTE_SEL[1] == 1'b1) ? SB[15:8] :
                  (MC.OUT_BUS == 3'b101 & MC.BYTE_SEL[1] == 1'b0) ? SB[7:0] :
                  (MC.OUT_BUS == 3'b110) ? DR :
                  8'h00;


   // Write enable is active-low when OUT_BUS drives data onto the bus.
   // Do not gate writes on reset/interrupt state here; microcode controls sequencing.
   always @* begin
      WE = 1'b1;
      if (MC.OUT_BUS != 3'b000)
         WE = 1'b0;
   end

   // Track emulation-mode stack behavior for 4'b1000 addressing.
   // S7 data-late: next values (_n, assuming the step is enabled) as
   // combinational logic, registered below; the address one step ahead reads the _n side.
   logic          EmuSPWrap_n;
   logic          EmuStackSeqActive_n;
   logic          EmuSPZeroAtStart_n;
   logic          EmuSPFFAtStart_n;
   logic          PLD_SeqActive_n;
   logic          PLD_Addr0_Valid_n;
   logic [7:0]    PLD_Low0_n;
   logic          PLD_FirstCarry_n;
   logic          PERPEI_SeqActive_n;
   logic          PERPEI_FirstDone_n;
   logic          RTL_SeqActive_n;
   logic [15:0]   RTL_BaseAddr_n;
   logic [1:0]    RTL_Offset_n;
   logic          PLD_WrapFF_Latched_n;
   logic          JSRL_SeqActive_n;
   logic          JSRL_WrapFF_n;
   logic [7:0]    RTL_SPW0_n;
   logic [7:0]    PLD_SP0_n;
   logic [7:0]    PLD_SPW0_n;
   logic          RTL_WrapFF_n;
   always @* begin
      EmuSPWrap_n = EmuSPWrap;
      EmuStackSeqActive_n = EmuStackSeqActive;
      EmuSPZeroAtStart_n = EmuSPZeroAtStart;
      EmuSPFFAtStart_n = EmuSPFFAtStart;
      PLD_SeqActive_n = PLD_SeqActive;
      PLD_Addr0_Valid_n = PLD_Addr0_Valid;
      PLD_Low0_n = PLD_Low0;
      PLD_FirstCarry_n = PLD_FirstCarry;
      PERPEI_SeqActive_n = PERPEI_SeqActive;
      PERPEI_FirstDone_n = PERPEI_FirstDone;
      RTL_SeqActive_n = RTL_SeqActive;
      RTL_BaseAddr_n = RTL_BaseAddr;
      RTL_Offset_n = RTL_Offset;
      PLD_WrapFF_Latched_n = PLD_WrapFF_Latched;
      JSRL_SeqActive_n = JSRL_SeqActive;
      JSRL_WrapFF_n = JSRL_WrapFF;
      RTL_SPW0_n = RTL_SPW0;
      PLD_SP0_n = PLD_SP0;
      PLD_SPW0_n = PLD_SPW0;
      RTL_WrapFF_n = RTL_WrapFF;

         if (LAST_CYCLE == 1'b1)
            EmuSPWrap_n = 1'b0; // clear at instruction end
         else if (EF == 1'b1 && MC.ADDR_BUS == 4'b1000 && SP[7:0] == 8'hFF)
            EmuSPWrap_n = 1'b1;

         // Start-of-sequence sampling (first 4'b1000 access in instruction)
         if (LAST_CYCLE == 1'b1) begin
            EmuStackSeqActive_n = 1'b0;
            EmuSPZeroAtStart_n = 1'b0;
            EmuSPFFAtStart_n = 1'b0;
            PLD_SeqActive_n = 1'b0;
            PLD_Addr0_Valid_n = 1'b0;
            PLD_Low0_n = 8'h00;
            PLD_FirstCarry_n = 1'b0;
         PERPEI_SeqActive_n = 1'b0;
         PERPEI_FirstDone_n = 1'b0;
         RTL_SeqActive_n = 1'b0;
         RTL_BaseAddr_n = 16'h0000;
         RTL_Offset_n = 2'b00;
         PLD_WrapFF_Latched_n = 1'b0;
            JSRL_SeqActive_n = 1'b0;
            JSRL_WrapFF_n = 1'b0;
         end else if (EF == 1'b1 && MC.ADDR_BUS == 4'b1000 && EmuStackSeqActive == 1'b0) begin
            EmuStackSeqActive_n = 1'b1;
            EmuSPZeroAtStart_n = (SPW[7:0] == 8'h00);
            EmuSPFFAtStart_n = (SPW[7:0] == 8'hFF);
            // For RTL (6B), capture original SP low for carry computation
            if (IR == 8'h6B)
              RTL_SPW0_n = SPW[7:0];
         end

         // Latch SP low at first PLD stack read in this instruction
         if (EF == 1'b1 && IR == 8'h2B && MC.ADDR_BUS == 4'b1000 && MC.OUT_BUS == 3'b000 && PLD_SeqActive == 1'b0) begin
            PLD_SeqActive_n = 1'b1;
            PLD_SP0_n = SP[7:0];
            PLD_SPW0_n = SPW[7:0];
            PLD_Low0_n = (SPW[7:0] + 8'h01);
            PLD_FirstCarry_n = (SPW[7:0] == 8'hFF);
            PLD_Addr0_Valid_n = 1'b1; // reuse as have low0
            // If this cycle increments SP from 0xFF->0x00, second read should use page 0x02
            PLD_WrapFF_Latched_n = ((MC.LOAD_SP == 3'b110 || MC.LOAD_SP == 3'b111) && (SP[7:0] == 8'hFF));
         end

         // Track PER/PEI writes (two-byte push via 4'b0101) in emulation
         if (EF == 1'b1 && (IR == 8'h62 || IR == 8'hD4) && MC.ADDR_BUS == 4'b0101 && MC.OUT_BUS != 3'b000) begin
            if (PERPEI_SeqActive == 1'b0) begin
               PERPEI_SeqActive_n = 1'b1;
               PERPEI_FirstDone_n = 1'b0;
            end else begin
               PERPEI_FirstDone_n = 1'b1;
            end
         end

         // Track RTL (6B) stack reads (three-byte pull) in emulation
         if (EF == 1'b1 && IR == 8'h6B && MC.ADDR_BUS == 4'b1000 && MC.OUT_BUS == 3'b000) begin
            if (!RTL_SeqActive) begin
               RTL_SeqActive_n = 1'b1;
               RTL_BaseAddr_n = ((SP + {14'b0, MC.ADDR_INC}) & 16'h01FF);
               RTL_Offset_n = 2'b00;
               RTL_WrapFF_n = (SP[7:0] == 8'h00);
               RTL_SPW0_n = SPW[7:0];
            end else begin
               if (RTL_Offset != 2'b10)
                  RTL_Offset_n = RTL_Offset + 2'b01;
            end
         end

         // Track JSR long PC-byte pushes (IR=22) in emulation
         if (EF == 1'b1 && IR == 8'h22 && MC.ADDR_BUS == 4'b1000 && MC.OUT_BUS == 3'b010 && MC.OUT_BUS != 3'b000) begin
            if (!JSRL_SeqActive) begin
               JSRL_SeqActive_n = 1'b1;
               JSRL_WrapFF_n = (SP[7:0] == 8'hFF);
            end
         end
   end

   // The same next values with "last cycle" taken as false, for the next-step address
   // only (_a).  When the step IS the last one the next step is a fetch, which
   // addresses PBR:PC and reads none of them, so the address is the same; leaving
   // LAST_CYCLE (NextState) out keeps the next-state logic off the address path.
   logic          EmuSPWrap_a;
   logic          EmuStackSeqActive_a;
   logic          EmuSPZeroAtStart_a;
   logic          EmuSPFFAtStart_a;
   logic          PLD_SeqActive_a;
   logic          PLD_Addr0_Valid_a;
   logic [7:0]    PLD_Low0_a;
   logic          PLD_FirstCarry_a;
   logic          PERPEI_SeqActive_a;
   logic          PERPEI_FirstDone_a;
   logic          RTL_SeqActive_a;
   logic [15:0]   RTL_BaseAddr_a;
   logic [1:0]    RTL_Offset_a;
   logic          PLD_WrapFF_Latched_a;
   logic          JSRL_SeqActive_a;
   logic          JSRL_WrapFF_a;
   logic [7:0]    RTL_SPW0_a;
   logic [7:0]    PLD_SP0_a;
   logic [7:0]    PLD_SPW0_a;
   logic          RTL_WrapFF_a;
   always @* begin
      EmuSPWrap_a = EmuSPWrap;
      EmuStackSeqActive_a = EmuStackSeqActive;
      EmuSPZeroAtStart_a = EmuSPZeroAtStart;
      EmuSPFFAtStart_a = EmuSPFFAtStart;
      PLD_SeqActive_a = PLD_SeqActive;
      PLD_Addr0_Valid_a = PLD_Addr0_Valid;
      PLD_Low0_a = PLD_Low0;
      PLD_FirstCarry_a = PLD_FirstCarry;
      PERPEI_SeqActive_a = PERPEI_SeqActive;
      PERPEI_FirstDone_a = PERPEI_FirstDone;
      RTL_SeqActive_a = RTL_SeqActive;
      RTL_BaseAddr_a = RTL_BaseAddr;
      RTL_Offset_a = RTL_Offset;
      PLD_WrapFF_Latched_a = PLD_WrapFF_Latched;
      JSRL_SeqActive_a = JSRL_SeqActive;
      JSRL_WrapFF_a = JSRL_WrapFF;
      RTL_SPW0_a = RTL_SPW0;
      PLD_SP0_a = PLD_SP0;
      PLD_SPW0_a = PLD_SPW0;
      RTL_WrapFF_a = RTL_WrapFF;

         if (1'b0)
            EmuSPWrap_a = 1'b0; // clear at instruction end
         else if (EF == 1'b1 && MC.ADDR_BUS == 4'b1000 && SP[7:0] == 8'hFF)
            EmuSPWrap_a = 1'b1;

         // Start-of-sequence sampling (first 4'b1000 access in instruction)
         if (1'b0) begin
            EmuStackSeqActive_a = 1'b0;
            EmuSPZeroAtStart_a = 1'b0;
            EmuSPFFAtStart_a = 1'b0;
            PLD_SeqActive_a = 1'b0;
            PLD_Addr0_Valid_a = 1'b0;
            PLD_Low0_a = 8'h00;
            PLD_FirstCarry_a = 1'b0;
         PERPEI_SeqActive_a = 1'b0;
         PERPEI_FirstDone_a = 1'b0;
         RTL_SeqActive_a = 1'b0;
         RTL_BaseAddr_a = 16'h0000;
         RTL_Offset_a = 2'b00;
         PLD_WrapFF_Latched_a = 1'b0;
            JSRL_SeqActive_a = 1'b0;
            JSRL_WrapFF_a = 1'b0;
         end else if (EF == 1'b1 && MC.ADDR_BUS == 4'b1000 && EmuStackSeqActive == 1'b0) begin
            EmuStackSeqActive_a = 1'b1;
            EmuSPZeroAtStart_a = (SPW[7:0] == 8'h00);
            EmuSPFFAtStart_a = (SPW[7:0] == 8'hFF);
            // For RTL (6B), capture original SP low for carry computation
            if (IR == 8'h6B)
              RTL_SPW0_a = SPW[7:0];
         end

         // Latch SP low at first PLD stack read in this instruction
         if (EF == 1'b1 && IR == 8'h2B && MC.ADDR_BUS == 4'b1000 && MC.OUT_BUS == 3'b000 && PLD_SeqActive == 1'b0) begin
            PLD_SeqActive_a = 1'b1;
            PLD_SP0_a = SP[7:0];
            PLD_SPW0_a = SPW[7:0];
            PLD_Low0_a = (SPW[7:0] + 8'h01);
            PLD_FirstCarry_a = (SPW[7:0] == 8'hFF);
            PLD_Addr0_Valid_a = 1'b1; // reuse as have low0
            // If this cycle increments SP from 0xFF->0x00, second read should use page 0x02
            PLD_WrapFF_Latched_a = ((MC.LOAD_SP == 3'b110 || MC.LOAD_SP == 3'b111) && (SP[7:0] == 8'hFF));
         end

         // Track PER/PEI writes (two-byte push via 4'b0101) in emulation
         if (EF == 1'b1 && (IR == 8'h62 || IR == 8'hD4) && MC.ADDR_BUS == 4'b0101 && MC.OUT_BUS != 3'b000) begin
            if (PERPEI_SeqActive == 1'b0) begin
               PERPEI_SeqActive_a = 1'b1;
               PERPEI_FirstDone_a = 1'b0;
            end else begin
               PERPEI_FirstDone_a = 1'b1;
            end
         end

         // Track RTL (6B) stack reads (three-byte pull) in emulation
         if (EF == 1'b1 && IR == 8'h6B && MC.ADDR_BUS == 4'b1000 && MC.OUT_BUS == 3'b000) begin
            if (!RTL_SeqActive) begin
               RTL_SeqActive_a = 1'b1;
               RTL_BaseAddr_a = ((SP + {14'b0, MC.ADDR_INC}) & 16'h01FF);
               RTL_Offset_a = 2'b00;
               RTL_WrapFF_a = (SP[7:0] == 8'h00);
               RTL_SPW0_a = SPW[7:0];
            end else begin
               if (RTL_Offset != 2'b10)
                  RTL_Offset_a = RTL_Offset + 2'b01;
            end
         end

         // Track JSR long PC-byte pushes (IR=22) in emulation
         if (EF == 1'b1 && IR == 8'h22 && MC.ADDR_BUS == 4'b1000 && MC.OUT_BUS == 3'b010 && MC.OUT_BUS != 3'b000) begin
            if (!JSRL_SeqActive) begin
               JSRL_SeqActive_a = 1'b1;
               JSRL_WrapFF_a = (SP[7:0] == 8'hFF);
            end
         end
   end


   always @(posedge CLK or negedge RST_N) begin
      if (!RST_N) begin
         EmuSPWrap <= 1'b0;
         EmuStackSeqActive <= 1'b0;
         EmuSPZeroAtStart <= 1'b0;
         EmuSPFFAtStart <= 1'b0;
         PLD_SeqActive <= 1'b0;
         PLD_SP0 <= 8'h00;
         PLD_Addr0_Valid <= 1'b0;
         PLD_Addr0 <= 16'h0000;
         PERPEI_SeqActive <= 1'b0;
         PERPEI_FirstDone <= 1'b0;
         JSRL_SeqActive <= 1'b0;
         JSRL_WrapFF <= 1'b0;
         RTL_SeqActive <= 1'b0;
         RTL_BaseAddr <= 16'h0000;
         RTL_Offset <= 2'b00;
         RTL_WrapFF <= 1'b0;
         RTL_SPW0 <= 8'h00;
      end else if (EN_p == 1'b1) begin
         EmuSPWrap <= EmuSPWrap_n;
         EmuStackSeqActive <= EmuStackSeqActive_n;
         EmuSPZeroAtStart <= EmuSPZeroAtStart_n;
         EmuSPFFAtStart <= EmuSPFFAtStart_n;
         PLD_SeqActive <= PLD_SeqActive_n;
         PLD_Addr0_Valid <= PLD_Addr0_Valid_n;
         PLD_Low0 <= PLD_Low0_n;
         PLD_FirstCarry <= PLD_FirstCarry_n;
         PERPEI_SeqActive <= PERPEI_SeqActive_n;
         PERPEI_FirstDone <= PERPEI_FirstDone_n;
         RTL_SeqActive <= RTL_SeqActive_n;
         RTL_BaseAddr <= RTL_BaseAddr_n;
         RTL_Offset <= RTL_Offset_n;
         PLD_WrapFF_Latched <= PLD_WrapFF_Latched_n;
         JSRL_SeqActive <= JSRL_SeqActive_n;
         JSRL_WrapFF <= JSRL_WrapFF_n;
         RTL_SPW0 <= RTL_SPW0_n;
         PLD_SP0 <= PLD_SP0_n;
         PLD_SPW0 <= PLD_SPW0_n;
         RTL_WrapFF <= RTL_WrapFF_n;
      end
   end


   always @(posedge CLK or negedge RST_N)
      if (RST_N == 1'b0)
      begin
         OLD_NMI_N <= 1'b1;
         NMI_SYNC <= 1'b0;
      end
      else
      begin
         if (RDY_IN == 1'b1 && CE == 1'b1 & IsResetInterrupt == 1'b0)
         begin
            // Snapshot SP at cycle boundary for stable write addressing decisions
            SPW <= SP;
            OLD_NMI_N <= NMI_N;
            if (NMI_N == 1'b0 & OLD_NMI_N == 1'b1 & NMI_SYNC == 1'b0)
               NMI_SYNC <= 1'b1;
            else if (LAST_CYCLE == 1'b1 && NMI_SYNC == 1'b1 && EN == 1'b1)
               NMI_SYNC <= 1'b0;
         end
      end


   always @(posedge CLK or negedge RST_N)
      if (RST_N == 1'b0)
      begin
         IsResetInterrupt <= 1'b1;
         IsNMIInterrupt <= 1'b0;
         IsIRQInterrupt <= 1'b0;
         GotInterrupt <= 1'b1;
         NMI_ACTIVE <= 1'b0;
         IRQ_ACTIVE <= 1'b0;
`ifdef DEBUG_VERBOSE
         $display("CPU_RESET_INT: RST_N low -> IsResetInterrupt=1, GotInterrupt=1");
`endif
      end
      else
      begin
         if (RDY_IN == 1'b1 & CE == 1'b1)
         begin
            NMI_ACTIVE <= NMI_SYNC;
            IRQ_ACTIVE <= (~IRQ_N);

            if (LAST_CYCLE == 1'b1 & EN == 1'b1)
            begin
               if (GotInterrupt == 1'b0)
               begin
                  GotInterrupt <= (IRQ_ACTIVE & (~P[2])) | NMI_ACTIVE;

                  // Debug: Track interrupt decisions
                  if ((IRQ_ACTIVE & (~P[2])) | NMI_ACTIVE) begin
                     //$display("INTERRUPT_CHECK: %02x:%04x LAST_CYCLE, setting GotInterrupt=1 (IRQ_ACTIVE=%d P[2]=%d NMI_ACTIVE=%d) IR=%02x STATE=%d", PBR, PC, IRQ_ACTIVE, P[2], NMI_ACTIVE, IR, STATE);
                  end
                  else if (IRQ_ACTIVE & P[2]) begin
                     //$display("INTERRUPT_BLOCKED: %02x:%04x LAST_CYCLE, I flag blocks IRQ (IRQ_ACTIVE=%d P[2]=%d) IR=%02x STATE=%d", PBR, PC, IRQ_ACTIVE, P[2], IR, STATE);
                  end

                  if (NMI_ACTIVE == 1'b1)
                     NMI_ACTIVE <= 1'b0;
               end
               else begin
                  GotInterrupt <= 1'b0;
`ifdef DEBUG_VERBOSE
                  if (IsResetInterrupt)
                     $display("CPU_RESET_INT: LAST_CYCLE clearing GotInterrupt and IsResetInterrupt, PC=%04x", PC);
`endif
               end

               IsResetInterrupt <= 1'b0;
               IsNMIInterrupt <= NMI_ACTIVE;
               IsIRQInterrupt <= IRQ_ACTIVE & (~P[2]);
            end
         end
      end

   assign IsBRKInterrupt = (IR == 8'h00) ? 1'b1 :
                           1'b0;
   assign IsCOPInterrupt = (IR == 8'h02) ? 1'b1 :
                           1'b0;
   assign IsABORTInterrupt = 1'b0;


   always @(posedge CLK or negedge RST_N)
      if (RST_N == 1'b0)
      begin
         WAIExec <= 1'b0;
         STPExec <= 1'b0;
      end
      else
      begin
         if (EN == 1'b1 & GotInterrupt == 1'b0)
         begin
            if (STATE == 4'b0001)
            begin
               if (IR == 8'hCB)
                  WAIExec <= 1'b1;
               else if (IR == 8'hDB)
                  STPExec <= 1'b1;
            end
         end

         if (RDY_IN == 1'b1 & CE == 1'b1)
         begin
            // WAI ends when an interrupt line is ASSERTED (IRQ_N low, masked or not), as in
            // the VHDL original; the conversion had the IRQ_N test inverted, so WAI fell
            // through with no interrupt pending and hung when one arrived during it.
            if ((NMI_SYNC == 1'b1 | IRQ_N == 1'b0 | ABORT_N == 1'b0) & WAIExec == 1'b1)
               WAIExec <= 1'b0;
         end
      end


   // The temporaries below are assigned only on the control paths that use
   // them (ported-VHDL structure); Verilator flags latches. Scoped waiver --
   // the block is combinationally consumed the same cycle, and the core is
   // validated against 504/512 SingleStepTests.
   // Emulation-mode stack address helpers, hoisted out of the block below
   // (a2mega): they are pure functions of registers, so computing them
   // continuously is identical in value, and it removes the branch-scoped
   // temporaries that GowinSynthesis turned into latches (EX2420 on
   // sum2low[8]) - a latch loop is poison for timing-driven routing.
   // ---- S7 data-late step: the address one step ahead ------------------------
   // ADDR_BUS (this step's address, from the registers) is the stock function.
   // NA_OUT is the same function evaluated on the values the registers will
   // hold after this step, i.e. the address of the NEXT step, valid during this
   // one; A_OUT is its register.  Inputs that cannot change in a step whose
   // successor uses them are taken from the registers (each case is from the
   // microcode table, checked by gen_fast_mcode.py):
   //   IR   changes only in the fetch step, and every opcode's step 1 addresses
   //        PBR:PC with no bus write, where the function does not read IR;
   //   D, DBR, EF and the interrupt-class flags load only in steps whose
   //        successor is a fetch (PBR:PC) or, for DBR in MVN/MVP step 1, a PC
   //        operand read.
   // The next step's microcode address fields come from NA_TAB, indexed by the
   // registered IR and NextState; NextState 0 and 1 are the fetch step and
   // step 1 (PBR:PC, no write).
   logic [11:0] NAF;            // {addrBus[3:0], addrInc[1:0], byteSel[1], outBus[2:0], va[1:0]} of the next step
   logic [23:0] NA_BUS;
   logic [23:0] A_OUT_r;
   // The fields of both possible successor rows are registered with the microinstruction
   // (SN, from SUCC_TAB); the NextState decision picks one.  NextState is 0, STATE+1 or
   // STATE+2 (the taken branch's state 2 is STATE+1): NS_ZERO / NS_INC2 are set beside it.
   assign NAF = NS_ZERO ? 12'b0 : NS_INC2 ? SN[11:0] : SN[23:12];
`ifdef VERILATOR
   logic [11:0] NAF_ref;
   F65C816_naf NAFRom(.IR(IR), .STATE(NextState), .NAF(NAF_ref));
   always @(posedge CLK)
      if (RST_N == 1'b1 && EN == 1'b1 && NAF !== NAF_ref)
         $display("NAF MISMATCH @%0t: NAF=%012b ref=%012b IR=%02h STATE=%0d NextState=%0d", $time, NAF, NAF_ref, IR, STATE, NextState);
`endif

   F65C816_AddrBus AddrBusNow
     (.ADDR_SEL(MC.ADDR_BUS), .INC(MC.ADDR_INC), .OUT_BUS(MC.OUT_BUS), .BYTE_SEL1(MC.BYTE_SEL[1]),
      .IR(IR), .EF(EF), .D_LO_NZ(DLNoZero),
      .PBR(PBR), .PC(PC), .DBR(DBR), .AA(AA), .AB(AB), .DX(DX), .SP(SP), .SPW(SPW),
      .PERPEI_SeqActive(PERPEI_SeqActive), .PERPEI_FirstDone(PERPEI_FirstDone),
      .PLD_Addr0_Valid(PLD_Addr0_Valid), .PLD_Low0(PLD_Low0), .PLD_SPW0(PLD_SPW0),
      .RTL_SeqActive(RTL_SeqActive), .RTL_Offset(RTL_Offset), .RTL_SPW0(RTL_SPW0),
      .JSRL_WrapFF(JSRL_WrapFF),
      .IsResetInterrupt(IsResetInterrupt), .IsNMIInterrupt(IsNMIInterrupt), .IsIRQInterrupt(IsIRQInterrupt),
      .ADDR_BUS(ADDR_BUS));
   // The next address is formed two ways and the next step's ADDR_INC picks one:
   //  NA_MOVE  the registers at their NEXT values, no increment.  This is the late
   //           path (operand bytes arriving from memory, index adds) and it has no
   //           second adder behind it.
   //  NA_STAY  AA / AB / DX / SP / PBR / PC at their CURRENT values plus the increment:
   //           the adders, but from registers.
   // A nonzero increment follows only steps that leave those registers alone
   // (gen_fast_mcode.py asserts it of every row and successor), so NA_STAY is exact
   // whenever it is selected; PBR:PC never takes an increment.
   // rung 4: evaluated for each candidate of the next microinstruction (the fetch
   // step's PBR:PC, the row for STATE + 1, the row for STATE + 2: SN) in parallel,
   // and the late NextState decision selects the RESULT - no adder behind it.
   logic [23:0] NA_FETCH;
   logic [23:0] NA_CAND [0:1];
   F65C816_AddrBus AddrBusFetch
     (.ADDR_SEL(4'b0000), .INC(2'b00), .OUT_BUS(3'b000), .BYTE_SEL1(1'b0),
      .IR(IR), .EF(EF), .D_LO_NZ(DLNoZero),
      .PBR(PBR_n), .PC(PC_n), .DBR(DBR), .AA(AA_n), .AB(AB_n), .DX(DX_n), .SP(SP_n), .SPW(SPW_n),
      .PERPEI_SeqActive(PERPEI_SeqActive_a), .PERPEI_FirstDone(PERPEI_FirstDone_a),
      .PLD_Addr0_Valid(PLD_Addr0_Valid_a), .PLD_Low0(PLD_Low0_a), .PLD_SPW0(PLD_SPW0_a),
      .RTL_SeqActive(RTL_SeqActive_a), .RTL_Offset(RTL_Offset_a), .RTL_SPW0(RTL_SPW0_a),
      .JSRL_WrapFF(JSRL_WrapFF_a),
      .IsResetInterrupt(IsResetInterrupt), .IsNMIInterrupt(IsNMIInterrupt), .IsIRQInterrupt(IsIRQInterrupt),
      .ADDR_BUS(NA_FETCH));
   for (genvar c = 0; c < 2; c++) begin : g_na
      wire [11:0] naf_c = (c == 0) ? SN[23:12] : SN[11:0];
      logic [23:0] na_move, na_stay;
      F65C816_AddrBus AddrBusNext
        (.ADDR_SEL(naf_c[11:8]), .INC(2'b00), .OUT_BUS(naf_c[4:2]), .BYTE_SEL1(naf_c[5]),
         .IR(IR), .EF(EF), .D_LO_NZ(DLNoZero),
         .PBR(PBR_n), .PC(PC_n), .DBR(DBR), .AA(AA_n), .AB(AB_n), .DX(DX_n), .SP(SP_n), .SPW(SPW_n),
         .PERPEI_SeqActive(PERPEI_SeqActive_a), .PERPEI_FirstDone(PERPEI_FirstDone_a),
         .PLD_Addr0_Valid(PLD_Addr0_Valid_a), .PLD_Low0(PLD_Low0_a), .PLD_SPW0(PLD_SPW0_a),
         .RTL_SeqActive(RTL_SeqActive_a), .RTL_Offset(RTL_Offset_a), .RTL_SPW0(RTL_SPW0_a),
         .JSRL_WrapFF(JSRL_WrapFF_a),
         .IsResetInterrupt(IsResetInterrupt), .IsNMIInterrupt(IsNMIInterrupt), .IsIRQInterrupt(IsIRQInterrupt),
         .ADDR_BUS(na_move));
      F65C816_AddrBus AddrBusNextInc
        (.ADDR_SEL(naf_c[11:8]), .INC(naf_c[7:6]), .OUT_BUS(naf_c[4:2]), .BYTE_SEL1(naf_c[5]),
         .IR(IR), .EF(EF), .D_LO_NZ(DLNoZero),
         .PBR(PBR), .PC(PC), .DBR(DBR), .AA(AA), .AB(AB), .DX(DX), .SP(SP), .SPW(SPW_n),
         .PERPEI_SeqActive(PERPEI_SeqActive_a), .PERPEI_FirstDone(PERPEI_FirstDone_a),
         .PLD_Addr0_Valid(PLD_Addr0_Valid_a), .PLD_Low0(PLD_Low0_a), .PLD_SPW0(PLD_SPW0_a),
         .RTL_SeqActive(RTL_SeqActive_a), .RTL_Offset(RTL_Offset_a), .RTL_SPW0(RTL_SPW0_a),
         .JSRL_WrapFF(JSRL_WrapFF_a),
         .IsResetInterrupt(IsResetInterrupt), .IsNMIInterrupt(IsNMIInterrupt), .IsIRQInterrupt(IsIRQInterrupt),
         .ADDR_BUS(na_stay));
      assign NA_CAND[c] = (naf_c[7:6] == 2'b00) ? na_move : na_stay;
   end
   assign NA_BUS = NS_ZERO ? NA_FETCH : NS_INC2 ? NA_CAND[1] : NA_CAND[0];
   wire [13:0] NA_BUS_B /* synthesis syn_keep = 1 */;
   assign NA_BUS_B = NS_ZERO ? NA_FETCH[13:0] : NS_INC2 ? NA_CAND[1][13:0] : NA_CAND[0][13:0];
   assign NA_OUT_B = NA_BUS_B;
`ifdef VERILATOR
   always @(posedge CLK)
      if (RST_N == 1'b1 && NA_BUS_B !== NA_BUS[13:0]) begin
         $display("ERROR: NA_OUT_B %04h differs from NA_OUT[13:0] %04h @%0t", NA_BUS_B, NA_BUS[13:0], $time);
         $finish;
      end
`endif


   assign NA_OUT = NA_BUS;

   // ---- the bus status of the next step --------------------------------------
   // WE, VPB and the VA field come from the next microinstruction: the fetch
   // microinstruction when the next step is a fetch (NS_ZERO); in the fetch
   // step, step 1 of the opcode on the data bus (always a read, never a vector
   // pull; VA[0] and "last cycle of a two-cycle instruction" from ST1_TAB);
   // otherwise the successor row (NAF).  VPA's two extra terms need STATE = 1,
   // so they exist only in the fetch step, where P, GotInterrupt and NMI_SYNC do
   // not change and IRQ_ACTIVE takes the IRQ pin.
   logic       st1_va, st1_twoc;
   F65C816_st1 St1Rom(.IR(NextIR), .VA1(st1_va), .TWOC(st1_twoc));
   wire        nx_st1  = (STATE == 4'b0000);
   wire        nx_plain = NS_ZERO | nx_st1;                      // next step: opcode fetch or step 1
   wire [1:0]  nx_va   = NS_ZERO ? 2'b11 : nx_st1 ? {1'b0, st1_va} : NAF[1:0];
   wire        nx_soft = nx_st1 & ~GotInterrupt & (NextIR == 8'h00 | NextIR == 8'h02);
   wire        nx_two  = nx_st1 & st1_twoc & (((~IRQ_N) & (~P[2])) | NMI_SYNC);
   wire        nx_vpa  = nx_va[0] | nx_two | nx_soft;
   wire        nx_we   = nx_plain | (NAF[4:2] == 3'b000);
   wire        nx_vpb  = nx_plain | (NAF[11:8] != 4'b1111);
   assign NST_OUT = {nx_vpb, nx_we, ~nx_vpa & ~nx_va[1]};
`ifdef VERILATOR
   logic [2:0] NST_r;
   always @(posedge CLK or negedge RST_N)
      if (RST_N == 1'b0)   NST_r <= 3'b110;
      else if (EN == 1'b1) NST_r <= NST_OUT;
   always @(posedge CLK)
      if (RST_N == 1'b1 && NST_r !== {VPB, WE, ~VPA & ~VDA})
         $display("NST_OUT MISMATCH @%0t: said %03b, is %03b IR=%02h STATE=%0d", $time, NST_r, {VPB, WE, ~VPA & ~VDA}, IR, STATE);
`endif
   always @(posedge CLK or negedge RST_N)
      if (RST_N == 1'b0)   A_OUT_r <= 24'h000000;
      else if (EN == 1'b1) A_OUT_r <= NA_BUS;
   assign A_OUT = A_OUT_r;

`ifdef VERILATOR
   // The registered next-address must equal the stock function of the registers.
   always @(posedge CLK)
      if (RST_N == 1'b1 && A_OUT_r !== ADDR_BUS)
         $display("NA_OUT MISMATCH @%0t: A_OUT_r=%06h ADDR_BUS=%06h IR=%02h STATE=%0d sel=%04b", $time, A_OUT_r, ADDR_BUS, IR, STATE, MC.ADDR_BUS);
`endif



   always @*
   begin: xhdl1
      logic           rmw;
      logic           twoCls;
      logic           softInt;
      if (IR == 8'h06 | IR == 8'h0E | IR == 8'h16 | IR == 8'h1E | IR == 8'hC6 | IR == 8'hCE | IR == 8'hD6 | IR == 8'hDE | IR == 8'hE6 | IR == 8'hEE | IR == 8'hF6 | IR == 8'hFE | IR == 8'h46 | IR == 8'h4E | IR == 8'h56 | IR == 8'h5E | IR == 8'h26 | IR == 8'h2E | IR == 8'h36 | IR == 8'h3E | IR == 8'h66 | IR == 8'h6E | IR == 8'h76 | IR == 8'h7E | IR == 8'h14 | IR == 8'h1C | IR == 8'h04 | IR == 8'h0C)
         rmw = 1'b1;
      else
         rmw = 1'b0;

      if (MC.ADDR_BUS == 4'b1111)
         VPB = 1'b0;
      else
         VPB = 1'b1;

      I_FLAG = P[2];

      if ((MC.ADDR_BUS == 4'b0001 | MC.ADDR_BUS == 4'b0011 | MC.ADDR_BUS == 4'b0111) & rmw == 1'b1)
         MLB = 1'b0;
      else
         MLB = 1'b1;

      // S7 data-late: "last cycle" taken from the microinstruction instead of NextState,
      // so VPA is a function of registers alone (it feeds the broker's step decision).
      // In step 1 with VA = 00 the step is the last one exactly when STATE_CTRL is 010
      // (the two-cycle implied instructions); gen_fast_mcode.py asserts it of the table.
      if (STATE == 1 & MC.VA == 2'b00 & MC.STATE_CTRL == 3'b010)
         twoCls = 1'b1;
      else
         twoCls = 1'b0;
`ifdef VERILATOR
      if (RST_N == 1'b1 && twoCls !== (LAST_CYCLE == 1'b1 & STATE == 1 & MC.VA == 2'b00))
         $display("twoCls MISMATCH @%0t: IR=%02h STATE=%0d", $time, IR, STATE);
`endif

      if ((IsBRKInterrupt == 1'b1 | IsCOPInterrupt == 1'b1) & STATE == 1 & GotInterrupt == 1'b0)
         softInt = 1'b1;
      else
         softInt = 1'b0;

      VDA = MC.VA[1];
      VPA = MC.VA[0] | (twoCls & ((IRQ_ACTIVE & (~P[2])) | NMI_ACTIVE)) | softInt;
   end

   assign RDY_OUT = EN;

endmodule
