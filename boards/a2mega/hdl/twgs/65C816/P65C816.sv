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
import P65C816_pkg::*;

module P65C816
  (
   input         CLK/*verilator public_flat*/,
   input         RST_N,
   input         CE,

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
   output logic  I_FLAG  // P[2] (interrupt disable) — accelerator IRQ-delay tap
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
  MCode_r          MC;
  logic [7:0]    IR/*verilator public_flat*/;
  logic [7:0]    NextIR;
  logic [3:0]    STATE;
  logic [3:0]    NextState;
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


   always_comb
      case (MC.STATE_CTRL)
         3'b000 :
            NextState = STATE + 4'd1;
         3'b001 :
            if (AALCarry == 1'b0 & (XF == 1'b1 | EF == 1'b1))
               NextState = STATE + 4'd2;
            else
               NextState = STATE + 4'd1;
         3'b010 :
            if (IsBranchCycle1 == 1'b1 & JumpTaken == 1'b1)
               NextState = 4'b0010;
            else
               NextState = 4'b0000;
         3'b011 :
            if (JumpNoOverflow == 1'b1 | EF == 1'b0)
               NextState = 4'b0000;
            else
               NextState = STATE + 4'd1;
         3'b100 :
            if ((MC.LOAD_AXY[1] == 1'b0 & MF == 1'b0 & EF == 1'b0) | (MC.LOAD_AXY[1] == 1'b1 & XF == 1'b0 & EF == 1'b0))
               NextState = STATE + 4'd1;
            else
               NextState = 4'b0000;
         3'b101 :
            if (DLNoZero == 1'b1)
               NextState = STATE + 4'd1;
            else
               NextState = STATE + 4'd2;
         3'b110 :
            if ((MC.LOAD_AXY[1] == 1'b0 & MF == 1'b0 & EF == 1'b0) | (MC.LOAD_AXY[1] == 1'b1 & XF == 1'b0 & EF == 1'b0))
               NextState = STATE + 4'd1;
            else
               NextState = STATE + 4'd2;
         3'b111 :
            if (EF == 1'b0)
               NextState = STATE + 4'd1;
            else
               NextState = STATE + 4'd2;
         default :
            ;
      endcase

   assign LAST_CYCLE = (NextState == 4'b0000) ? 1'b1 :
                       1'b0;


   always @(posedge CLK or negedge RST_N)
      if (RST_N == 1'b0)
      begin
         STATE <= {4{1'b0}};
         IR <= {8{1'b0}};
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


   P65C816_mcode MCode(.CLK(CLK), .RST_N(RST_N), .EN(EN), .IR(NextIR), .STATE(NextState), .M(MC));


   P65C816_AddrGen AddrGen(.CLK(CLK), .RST_N(RST_N), .EN(EN), .LOAD_PC(MC.LOAD_PC), .PCDec(CO), .GotInterrupt(GotInterrupt), .ADDR_CTRL(MC.ADDR_CTRL), .IND_CTRL(MC.IND_CTRL), .D_IN(D_IN), .X(X), .Y(Y), .D(D), .S(SP), .T(T), .DR(DR), .DBR(DBR), .e6502(EF), .PC(PC), .AA(AA), .AB(AB), .DX(DX), .AALCarry(AALCarry), .JumpNoOfl(JumpNoOverflow));

   assign w16 = (MC.ALU_CTRL.w16 == 1'b1) ? 1'b1 :
                (IR == 8'hEB | IR == 8'hAB) ? 1'b0 :
                ((IR == 8'h44 | IR == 8'h54) & STATE == 4'b0101) ? 1'b1 :
                ((MC.LOAD_AXY[1] == 1'b0) & MF == 1'b0 & EF == 1'b0) ? 1'b1 :
                ((MC.LOAD_AXY[1] == 1'b1) & XF == 1'b0 & EF == 1'b0) ? 1'b1 :
                1'b0;

   assign SB = (MC.BUS_CTRL[5:3] == 3'b000) ? A :
               (MC.BUS_CTRL[5:3] == 3'b001) ? X :
               (MC.BUS_CTRL[5:3] == 3'b010) ? Y :
               (MC.BUS_CTRL[5:3] == 3'b011) ? D :
               (MC.BUS_CTRL[5:3] == 3'b100) ? T :
               (MC.BUS_CTRL[5:3] == 3'b101) ? (EF ? {8'h01, SP[7:0]} : SP) :
               (MC.BUS_CTRL[5:3] == 3'b110) ? {8'h00, PBR} :
               (MC.BUS_CTRL[5:3] == 3'b111) ? {8'h00, DBR} :
               16'h0000;

   assign DB = (MC.BUS_CTRL[2:0] == 3'b000) ? {8'h00, D_IN} :
               (MC.BUS_CTRL[2:0] == 3'b001) ? {D_IN, DR} :
               (MC.BUS_CTRL[2:0] == 3'b010) ? SB :
               (MC.BUS_CTRL[2:0] == 3'b011) ? D :
               (MC.BUS_CTRL[2:0] == 3'b100) ? T :
               (MC.BUS_CTRL[2:0] == 3'b101) ? 16'h0001 :
               16'h0000;


   P65C816_ALU ALU(.CTRL(MC.ALU_CTRL), .L(SB), .R(DB), .w16(w16), .BCD(P[3]), .CI(P[0]), .VI(P[6]), .SI(P[7]), .CO(CO), .VO(VO), .SO(SO), .ZO(ZO), .RES(AluR), .IntR(AluIntR));

   assign MF = P[5];
   assign XF = P[4];
   assign EF = P[8];


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
            SP[15:8] <= 8'h01;
            oldXF <= 1'b1;
         end
         else if (EN == 1'b1)
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

            case (MC.LOAD_SP)
               3'b000 :
                  ;
               3'b001 :
                  if (EF == 1'b0)
                     SP <= (SP + 16'd1);
                  else
                     // Emulation: maintain full 16-bit SP for arithmetic
                     SP <= (SP + 16'd1);
               3'b010 :
                  if (MC.BYTE_SEL[1] == 1'b0 & w16 == 1'b1)
                  begin
                     if (EF == 1'b0)
                        SP <= (SP + 16'd1);
                     else
                        SP <= ({8'h01, SP[7:0]} + 16'd1);
                  end
               3'b011 :
                  if (EF == 1'b0)
                     SP <= (SP - 16'd1);
                  else
                     SP <= (SP - 16'd1);
               3'b100 :
                  if (EF == 1'b0)
                     SP <= A;
                  else begin
                     SP[15:8] <= 8'h01;
                     SP <= {8'h01, A[7:0]};
                  end
               3'b101 :
                  if (EF == 1'b0)
                     SP <= X;
                  else begin
                     SP[15:8] <= 8'h01;
                     SP <= {8'h01, X[7:0]};
                  end
               3'b110 :
                  if (EF == 1'b0)
                     SP <= (SP + 16'd1);
                  else
                     SP <= (SP + 16'd1);
               3'b111 :
                  if (EF == 1'b0)
                     SP <= (SP - 16'd1);
                  else
                     SP <= (SP - 16'd1);
               default :
                  ;
            endcase
         end
      end


   always @(posedge CLK or negedge RST_N)
      if (RST_N == 1'b0)
         P <= 9'b100110100;
      else
      begin
         if (EN == 1'b1)
            case (MC.LOAD_P)
               3'b000 :
                  P <= P;
               3'b001 :
                  begin
                     if (IR == 8'hAB)  // PLB - Set N and Z based on D_IN
                     begin
                        P[7] <= D_IN[7];  // N flag
                        P[1] <= (D_IN == 8'h00);  // Z flag
                     end
                     else if (IR == 8'h2B)  // PLD - Set N and Z based on 16-bit value from stack
                     begin
                        P[7] <= D_IN[7];  // N flag from high byte
                        P[1] <= ({D_IN, DR} == 16'h0000);  // Z flag
                     end
                     else if (IR == 8'hBA)  // TSX - Set N and Z based on SP value transferred to X
                     begin
                        if (XF == 1'b1 | EF == 1'b1)  // 8-bit X
                        begin
                           P[7] <= SP[7];  // N flag from low byte
                           P[1] <= (SP[7:0] == 8'h00);  // Z flag
                        end
                        else  // 16-bit X
                        begin
                           P[7] <= SP[15];  // N flag from high byte
                           P[1] <= (SP == 16'h0000);  // Z flag
                        end
                     end
                     else if ((MC.LOAD_AXY[1] == 1'b0 & MC.BYTE_SEL[0] == 1'b1 & (MF == 1'b1 | EF == 1'b1)) | (MC.LOAD_AXY[1] == 1'b1 & MC.BYTE_SEL[0] == 1'b1 & (XF == 1'b1 | EF == 1'b1)) | (MC.LOAD_AXY[1] == 1'b0 & MC.BYTE_SEL[1] == 1'b1 & (MF == 1'b0 & EF == 1'b0)) | (MC.LOAD_AXY[1] == 1'b1 & MC.BYTE_SEL[1] == 1'b1 & (XF == 1'b0 & EF == 1'b0)) | (MC.LOAD_AXY[1] == 1'b0 & MC.BYTE_SEL[1] == 1'b1 & w16 == 1'b1) | IR == 8'hEB | IR == 8'h5B)
                     begin
                        P[1:0] <= {ZO, CO};
                        P[7:6] <= {SO, VO};
                     end
                  end
               3'b010 :
                  begin
                     P[2] <= 1'b1;
                     P[3] <= 1'b0;
                  end
               3'b011 :
                  begin
                     P[7:6] <= D_IN[7:6];
                     P[5] <= D_IN[5] | EF;
                     P[4] <= D_IN[4] | EF;
                     P[3:0] <= D_IN[3:0];
                  end
               3'b100 :
                  case (IR[7:6])
                     2'b00 :
                        P[0] <= IR[5];
                     2'b01 :
                        P[2] <= IR[5];
                     2'b10 :
                        P[6] <= 1'b0;
                     2'b11 :
                        P[3] <= IR[5];
                     default :
                        ;
                  endcase
               3'b101 :
                  begin
                     P[8] <= P[0];
                     P[0] <= P[8];
                     if (P[0] == 1'b1)
                     begin
                        P[4] <= 1'b1;
                        P[5] <= 1'b1;
                     end
                  end
               3'b110 :
                  case (IR[5])
                     1'b1 :
                        P[7:0] <= P[7:0] | ({DR[7:6], (DR[5] & (~EF)), (DR[4] & (~EF)), DR[3:0]});
                     1'b0 :
                        P[7:0] <= P[7:0] & ((~({DR[7:6], (DR[5] & (~EF)), (DR[4] & (~EF)), DR[3:0]})));
                     default :
                        ;
                  endcase
               3'b111 :
                  P[1] <= ZO;
               default :
                  ;
            endcase

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
         if (EN == 1'b1)
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
                  if (IR == 8'h00 | IR == 8'h02)
                     PBR <= {8{1'b0}};
                  else if (IR == 8'h40 & EF == 1'b1)
                     PBR <= PBR;  // RTI in emulation mode: don't change PBR
                  else
                     PBR <= D_IN;
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

   // Track emulation-mode stack behavior for 4'b1000 addressing
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
      end else if (EN == 1'b1) begin
         if (LAST_CYCLE == 1'b1)
            EmuSPWrap <= 1'b0; // clear at instruction end
         else if (EF == 1'b1 && MC.ADDR_BUS == 4'b1000 && SP[7:0] == 8'hFF)
            EmuSPWrap <= 1'b1;

         // Start-of-sequence sampling (first 4'b1000 access in instruction)
         if (LAST_CYCLE == 1'b1) begin
            EmuStackSeqActive <= 1'b0;
            EmuSPZeroAtStart <= 1'b0;
            EmuSPFFAtStart <= 1'b0;
            PLD_SeqActive <= 1'b0;
            PLD_Addr0_Valid <= 1'b0;
            PLD_Low0 <= 8'h00;
            PLD_FirstCarry <= 1'b0;
         PERPEI_SeqActive <= 1'b0;
         PERPEI_FirstDone <= 1'b0;
         RTL_SeqActive <= 1'b0;
         RTL_BaseAddr <= 16'h0000;
         RTL_Offset <= 2'b00;
         PLD_WrapFF_Latched <= 1'b0;
            JSRL_SeqActive <= 1'b0;
            JSRL_WrapFF <= 1'b0;
         end else if (EF == 1'b1 && MC.ADDR_BUS == 4'b1000 && EmuStackSeqActive == 1'b0) begin
            EmuStackSeqActive <= 1'b1;
            EmuSPZeroAtStart <= (SPW[7:0] == 8'h00);
            EmuSPFFAtStart <= (SPW[7:0] == 8'hFF);
            // For RTL (6B), capture original SP low for carry computation
            if (IR == 8'h6B)
              RTL_SPW0 <= SPW[7:0];
         end

         // Latch SP low at first PLD stack read in this instruction
         if (EF == 1'b1 && IR == 8'h2B && MC.ADDR_BUS == 4'b1000 && MC.OUT_BUS == 3'b000 && PLD_SeqActive == 1'b0) begin
            PLD_SeqActive <= 1'b1;
            PLD_SP0 <= SP[7:0];
            PLD_SPW0 <= SPW[7:0];
            PLD_Low0 <= (SPW[7:0] + 8'h01);
            PLD_FirstCarry <= (SPW[7:0] == 8'hFF);
            PLD_Addr0_Valid <= 1'b1; // reuse as have low0
            // If this cycle increments SP from 0xFF->0x00, second read should use page 0x02
            PLD_WrapFF_Latched <= ((MC.LOAD_SP == 3'b110 || MC.LOAD_SP == 3'b111) && (SP[7:0] == 8'hFF));
         end

         // Track PER/PEI writes (two-byte push via 4'b0101) in emulation
         if (EF == 1'b1 && (IR == 8'h62 || IR == 8'hD4) && MC.ADDR_BUS == 4'b0101 && MC.OUT_BUS != 3'b000) begin
            if (PERPEI_SeqActive == 1'b0) begin
               PERPEI_SeqActive <= 1'b1;
               PERPEI_FirstDone <= 1'b0;
            end else begin
               PERPEI_FirstDone <= 1'b1;
            end
         end

         // Track RTL (6B) stack reads (three-byte pull) in emulation
         if (EF == 1'b1 && IR == 8'h6B && MC.ADDR_BUS == 4'b1000 && MC.OUT_BUS == 3'b000) begin
            if (!RTL_SeqActive) begin
               RTL_SeqActive <= 1'b1;
               RTL_BaseAddr <= ((SP + {14'b0, MC.ADDR_INC}) & 16'h01FF);
               RTL_Offset <= 2'b00;
               RTL_WrapFF <= (SP[7:0] == 8'h00);
               RTL_SPW0 <= SPW[7:0];
            end else begin
               if (RTL_Offset != 2'b10)
                  RTL_Offset <= RTL_Offset + 2'b01;
            end
         end

         // Track JSR long PC-byte pushes (IR=22) in emulation
         if (EF == 1'b1 && IR == 8'h22 && MC.ADDR_BUS == 4'b1000 && MC.OUT_BUS == 3'b010 && MC.OUT_BUS != 3'b000) begin
            if (!JSRL_SeqActive) begin
               JSRL_SeqActive <= 1'b1;
               JSRL_WrapFF <= (SP[7:0] == 8'hFF);
            end
         end
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
   wire [8:0] pld_sum2low_w = {1'b0, PLD_Low0} + 9'd1;
   wire [8:0] pld_sum2car_w = {1'b0, PLD_SPW0} + 9'd2;
   wire [8:0] spw_sum1_w    = {1'b0, SPW[7:0]} + 9'd1;
   wire [1:0] rtl_off_w     = RTL_SeqActive ? (RTL_Offset + 2'b01) : 2'b00; // effective offsets: 0,1,2
   wire [8:0] rtl_sum9_w    = {1'b0, (RTL_SeqActive ? RTL_SPW0 : SPW[7:0])} + 9'd1 + {7'b0, rtl_off_w};
   wire       jsrl_usewrap_w = JSRL_WrapFF | (SP[7:0] == 8'hFF);

   /* verilator lint_off LATCH */
   always @*
   begin: xhdl0
      logic [15:0]     ADDR_INC;
      logic [8:0]      sp_inc9;
      ADDR_INC = { 14'b0, MC.ADDR_INC[1:0] };
      sp_inc9 = 9'((SP + ADDR_INC) & 16'h01FF);
      case (MC.ADDR_BUS)
         4'b0000 :
            ADDR_BUS = {PBR, PC};
         4'b0001 :
            ADDR_BUS = (({DBR, 16'h0000}) + ({8'h00, (AA[15:0])}) + ({8'h00, ADDR_INC}));
         4'b0101 :
            // Normal AB:AA addressing, except stack-push opcodes (PER/PEI) in emulation
            if (EF == 1'b1 && (IR == 8'h62 || IR == 8'hD4)) begin // PER, PEI
               if (PERPEI_SeqActive == 1'b0 || (PERPEI_SeqActive == 1'b1 && PERPEI_FirstDone == 1'b0))
                  // High byte: force to page 0x01xx
                  ADDR_BUS = {8'h00, {8'h01, SP[7:0]} + ADDR_INC};
               else begin
                  // Low byte: use raw SP page (can be 0x00 or 0x01)
                  if (SP[15:8] == 8'h00 || SP[15:8] == 8'h01)
                     ADDR_BUS = {8'h00, SP + ADDR_INC};
                  else
                     ADDR_BUS = {8'h00, {8'h01, SP[7:0]} + ADDR_INC};
               end
            end else begin
               ADDR_BUS = (({AB, 16'h0000}) + ({7'b0000000, AA}) + ({8'h00, ADDR_INC}));
            end
         4'b0010 :
            ADDR_BUS = {PBR, ((AA[15:0]) + ADDR_INC)};
         4'b0110 :
            ADDR_BUS = {8'h00, ((AA[15:0]) + ADDR_INC)};
         4'b0011, 4'b0111 :
            if (EF == 1'b0 || MC.ADDR_BUS[2] == 1'b0 || D[7:0] != 8'h00)
               ADDR_BUS = {8'h00, (DX + ADDR_INC)};
            else
               // Emulation mode with DL=0: force page wrapping
               ADDR_BUS = {8'h00, DX[15:8], DX[7:0] + ADDR_INC[7:0]};
         4'b1000 :
            // Stack addressing variant A:
            // - Emulation mode: allow raw SP page 0x00 or 0x01 (wrap behavior for some ops)
            //   but normalize any other page to 0x01.
            // - Native mode: use full 16-bit SP
            if (EF == 1'b1) begin
               // Force page 0x01xx for BRK/COP pushes
               if (IR == 8'h00 || IR == 8'h02) begin
                  ADDR_BUS = {8'h00, {8'h01, SP[7:0]} + ADDR_INC};
               end else begin
               // Heuristic per 65C816 emulation stack behavior:
               // - Writes: special-case behavior
               // - Reads: use full 16-bit SP (allows 0x0200 etc.)
               if (MC.OUT_BUS == 3'b000) begin
                  // Reads: for PLD, special handling; otherwise force stack page to 0x01xx in emulation
                  if (IR == 8'h2B) begin
                      // PLD reads: first read uses SP+inc; second read uses prev addr + 1
                      if (PLD_Addr0_Valid == 1'b1)
                        begin
                          // Second byte: base on original SPW
                          ADDR_BUS = {8'h00, (8'h01 + {7'b0, pld_sum2car_w[8]}), pld_sum2low_w[7:0]};
                        end
                      else begin
                          // First byte: low0 = (previous SP low + 1); page += 1 if previous SP low was 0xFF
                          ADDR_BUS = {8'h00, (8'h01 + {7'b0, (SPW[7:0] == 8'hFF)}), spw_sum1_w[7:0]};
                      end
                  end else if (IR == 8'h6B) begin
                     // RTL reads: low byte from current SP (post-increment per microcode)
                     // Page determined by carry of (SPW.low + 1 + offset)
                     begin
                       ADDR_BUS = {8'h00, (8'h01 + {7'b0, rtl_sum9_w[8]}), SP[7:0]};
                     end
                  end else if (IR == 8'hAB) begin
                     // PLB read: use page 0x01 plus carry if SP crossed FF->00 prior to this read
                     ADDR_BUS = {8'h00, (8'h01 + {7'b0, (SP[7:0] == 8'h00)}), SP[7:0]};
                  end else begin
                     // Default emulation stack read: 9-bit offset from base page 0x01
                     ADDR_BUS = {8'h00, (8'h01 + {7'b0, sp_inc9[8]}), sp_inc9[7:0]};
                  end
               end else begin
               // Emulation stack writes (push): use current SP; high byte to 0x01xx,
               // low byte to 0x00FF only when SP low is 0xFF at that write cycle; else 0x01xx.
               begin
                  // Special-case JSR long (22) PC-byte pushes: if the pair started at SP low FF, both bytes go to page 0; else page 1
                  if (IR == 8'h22 && MC.OUT_BUS == 3'b010) begin
                     // First PC-byte push decides wrap (SP low==FF) and latches JSRL_WrapFF; second uses latched value
                     ADDR_BUS = {8'h00, (jsrl_usewrap_w ? 8'h00 : 8'h01), SP[7:0]};
                  end else if (MC.OUT_BUS == 3'b100) begin
                     ADDR_BUS = {8'h00, 8'h01, SP[7:0]};
                  end else if (MC.BYTE_SEL[1] == 1'b1) begin
                     // High byte
                     ADDR_BUS = {8'h00, 8'h01, SP[7:0]};
                  end else begin
                     // Low byte with wrap to 0x00FF when SP low is 0xFF
                     ADDR_BUS = {8'h00, (SP[7:0] == 8'hFF ? 8'h00 : 8'h01), SP[7:0]};
                  end
               end
               end
               end
            end else
               ADDR_BUS = {8'h00, SP + ADDR_INC};
         4'b1100 :
            // Stack addressing variant B:
            // - Emulation mode: force stack page 0x01xx always
            // - Native mode: use full 16-bit SP
            if (EF == 1'b1)
               ADDR_BUS = {8'h00, {8'h01, SP[7:0]} + ADDR_INC};
            else
               ADDR_BUS = {8'h00, SP + ADDR_INC};
         4'b1111 :
            begin
               ADDR_BUS[23:4] = {8'h00, 11'b11111111111, EF};
               if (IsResetInterrupt == 1'b1)
                  ADDR_BUS[3:0] = {3'b110, MC.ADDR_INC[0]};
               else if (IsABORTInterrupt == 1'b1)
                  ADDR_BUS[3:0] = {3'b100, MC.ADDR_INC[0]};
               else if (IsNMIInterrupt == 1'b1)
                  ADDR_BUS[3:0] = {3'b101, MC.ADDR_INC[0]};
               else if (IsIRQInterrupt == 1'b1)
                  ADDR_BUS[3:0] = {3'b111, MC.ADDR_INC[0]};
               else if (IsCOPInterrupt == 1'b1)
                  ADDR_BUS[3:0] = {3'b010, MC.ADDR_INC[0]};
               else
                  ADDR_BUS[3:0] = {EF, 2'b11, MC.ADDR_INC[0]};
            end
         default :
            ADDR_BUS = 24'h000000;
      endcase

      // Final emulation-mode overrides for known stack-push opcodes
      if (EF == 1'b1) begin
         // BRK/COP: all push cycles go to page 0x01xx
         if ((IR == 8'h00 || IR == 8'h02) && MC.OUT_BUS != 3'b000 && MC.ADDR_BUS != 4'b1111)
            ADDR_BUS = {8'h00, {8'h01, SP[7:0]} + ADDR_INC};
         // PHD handled above in 4'b1000 branch with wrap-aware low byte behavior
         // PER and PEI handled above in 4'b0101 branch with proper byte-order handling
      end
   end
   /* verilator lint_on LATCH */

   assign A_OUT = ADDR_BUS;


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

      if (LAST_CYCLE == 1'b1 & STATE == 1 & MC.VA == 2'b00)
         twoCls = 1'b1;
      else
         twoCls = 1'b0;

      if ((IsBRKInterrupt == 1'b1 | IsCOPInterrupt == 1'b1) & STATE == 1 & GotInterrupt == 1'b0)
         softInt = 1'b1;
      else
         softInt = 1'b0;

      VDA = MC.VA[1];
      VPA = MC.VA[0] | (twoCls & ((IRQ_ACTIVE & (~P[2])) | NMI_ACTIVE)) | softInt;
   end

   assign RDY_OUT = EN;

endmodule
