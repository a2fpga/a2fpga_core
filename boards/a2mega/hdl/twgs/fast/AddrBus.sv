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
// The address-bus function of the core as a module of its own (S7 data-late
// step): the core instantiates it on the NEXT values of its inputs, so the
// address of step n+1 is available during step n and a synchronous memory can
// register it at the step edge.  The logic is the stock ADDR_BUS block,
// moved; the input names changed, and the RTL page carry is a compare.
module F65C816_AddrBus
  (
   input  [3:0]        ADDR_SEL,     // microcode ADDR_BUS field
   input  [1:0]        INC,          // microcode ADDR_INC field
   input  [2:0]        OUT_BUS,
   input               BYTE_SEL1,
   input  [7:0]        IR,
   input               EF,
   input               D_LO_NZ,      // D[7:0] != 0
   input  [7:0]        PBR,
   input  [15:0]       PC,
   input  [7:0]        DBR,
   input  [16:0]       AA,
   input  [7:0]        AB,
   input  [15:0]       DX,
   input  [15:0]       SP,
   input  [15:0]       SPW,
   input               PERPEI_SeqActive,
   input               PERPEI_FirstDone,
   input               PLD_Addr0_Valid,
   input  [7:0]        PLD_Low0,
   input  [7:0]        PLD_SPW0,
   input               RTL_SeqActive,
   input  [1:0]        RTL_Offset,
   input  [7:0]        RTL_SPW0,
   input               JSRL_WrapFF,
   input               IsResetInterrupt,
   input               IsNMIInterrupt,
   input               IsIRQInterrupt,
   output logic [23:0] ADDR_BUS
   );

   wire IsABORTInterrupt = 1'b0;
   wire IsCOPInterrupt   = (IR == 8'h02);

   wire [8:0] pld_sum2low_w = {1'b0, PLD_Low0} + 9'd1;
   wire [8:0] pld_sum2car_w = {1'b0, PLD_SPW0} + 9'd2;
   wire [8:0] spw_sum1_w    = {1'b0, SPW[7:0]} + 9'd1;
   // RTL in emulation mode: the page of a stack read is 01 plus the carry of
   // (SP low at the start of the pull) + 1 + (the read's number).  The stock block adds
   // (rtl_sum9_w, of which only bit 8 is used); the carry alone is a compare (S7).
   wire       rtl_c_w       = !RTL_SeqActive ? (SPW[7:0] == 8'hFF) :
                              (RTL_Offset == 2'b00) ? (RTL_SPW0 >= 8'hFE) :
                              (RTL_Offset == 2'b01) ? (RTL_SPW0 >= 8'hFD) :
                              (RTL_Offset == 2'b10) ? (RTL_SPW0 >= 8'hFC) : (RTL_SPW0 == 8'hFF);
`ifdef VERILATOR
   wire [1:0] rtl_off_w     = RTL_SeqActive ? (RTL_Offset + 2'b01) : 2'b00; // effective offsets: 0,1,2
   wire [8:0] rtl_sum9_w    = {1'b0, (RTL_SeqActive ? RTL_SPW0 : SPW[7:0])} + 9'd1 + {7'b0, rtl_off_w};
   always @* if (rtl_c_w !== rtl_sum9_w[8]) begin
      $display("ERROR: AddrBus RTL carry %b, the stock sum says %b (active %b offset %0d sp0 %02h spw %02h)",
               rtl_c_w, rtl_sum9_w[8], RTL_SeqActive, RTL_Offset, RTL_SPW0, SPW[7:0]);
      $finish;
   end
`endif
   wire       jsrl_usewrap_w = JSRL_WrapFF | (SP[7:0] == 8'hFF);

   /* verilator lint_off LATCH */
   always @*
   begin: xhdl0
      logic [15:0]     ADDR_INC;
      logic [8:0]      sp_inc9;
      ADDR_INC = { 14'b0, INC };
      sp_inc9 = 9'((SP + ADDR_INC) & 16'h01FF);
      case (ADDR_SEL)
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
            if (EF == 1'b0 || ADDR_SEL[2] == 1'b0 || D_LO_NZ)
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
               if (OUT_BUS == 3'b000) begin
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
                       ADDR_BUS = {8'h00, (8'h01 + {7'b0, rtl_c_w}), SP[7:0]};
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
                  if (IR == 8'h22 && OUT_BUS == 3'b010) begin
                     // First PC-byte push decides wrap (SP low==FF) and latches JSRL_WrapFF; second uses latched value
                     ADDR_BUS = {8'h00, (jsrl_usewrap_w ? 8'h00 : 8'h01), SP[7:0]};
                  end else if (OUT_BUS == 3'b100) begin
                     ADDR_BUS = {8'h00, 8'h01, SP[7:0]};
                  end else if (BYTE_SEL1 == 1'b1) begin
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
                  ADDR_BUS[3:0] = {3'b110, INC[0]};
               else if (IsABORTInterrupt == 1'b1)
                  ADDR_BUS[3:0] = {3'b100, INC[0]};
               else if (IsNMIInterrupt == 1'b1)
                  ADDR_BUS[3:0] = {3'b101, INC[0]};
               else if (IsIRQInterrupt == 1'b1)
                  ADDR_BUS[3:0] = {3'b111, INC[0]};
               else if (IsCOPInterrupt == 1'b1)
                  ADDR_BUS[3:0] = {3'b010, INC[0]};
               else
                  ADDR_BUS[3:0] = {EF, 2'b11, INC[0]};
            end
         default :
            ADDR_BUS = 24'h000000;
      endcase

      // Final emulation-mode overrides for known stack-push opcodes
      if (EF == 1'b1) begin
         // BRK/COP: all push cycles go to page 0x01xx
         if ((IR == 8'h00 || IR == 8'h02) && OUT_BUS != 3'b000 && ADDR_SEL != 4'b1111)
            ADDR_BUS = {8'h00, {8'h01, SP[7:0]} + ADDR_INC};
         // PHD handled above in 4'b1000 branch with wrap-aware low byte behavior
         // PER and PEI handled above in 4'b0101 branch with proper byte-order handling
      end
   end
   /* verilator lint_on LATCH */

endmodule
