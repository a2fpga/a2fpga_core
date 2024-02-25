--
-- F18A
--   A pin-compatible enhanced replacement for the TMS9918A VDP family.
--   https://dnotq.io
--

-- Released under the 3-Clause BSD License:
--
-- Copyright 2011-2018 Matthew Hagerty (matthew <at> dnotq <dot> io)
--
-- Redistribution and use in source and binary forms, with or without
-- modification, are permitted provided that the following conditions are met:
--
-- 1. Redistributions of source code must retain the above copyright notice,
-- this list of conditions and the following disclaimer.
--
-- 2. Redistributions in binary form must reproduce the above copyright
-- notice, this list of conditions and the following disclaimer in the
-- documentation and/or other materials provided with the distribution.
--
-- 3. Neither the name of the copyright holder nor the names of its
-- contributors may be used to endorse or promote products derived from this
-- software without specific prior written permission.
--
-- THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
-- AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
-- IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
-- ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE
-- LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
-- CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
-- SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
-- INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
-- CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
-- ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
-- POSSIBILITY OF SUCH DAMAGE.

-- Version history.  See README.md for details.
--
--   V1.9 Dec 31, 2018
--   V1.8 Aug 24, 2016
--   V1.7 Jan  1, 2016
--   V1.6 May  3, 2014 .. Apr 26, 2015
--   V1.5 Jul 23, 2013
--   V1.4 Mar 20, 2013 .. Apr 26, 2013
--   V1.3 Jul 26, 2012, Release firmware

-- 100MHz TMS9900-compatible CPU (called the "GPU" in the F18A)
--
-- Notable differences between this implementation and the original 9900:
--
--   Does not implement all instructions.
--
--   Certain instructions are modified for alternate use.
--
--   Does not attempt to maintain original instruction timing.
--
--   The 16 general purpose registers (R0..R15) are a real register-file and
--   not implemented in RAM.
--
--   Uses a hard-coded instruction decode and control vs. a microcoded control
--   model of the original 9900.
--
--   Does not use the ALU for PC and other registers calculations.  Dedicated
--   adders are used instead.
--
-- The GPU has a not-so-great interface with the F18A host-CPU interface and
-- will be blocked at certain points to prevent VRAM contention.  This really
-- needs to be reworked, if only to make the implementation simpler (and
-- probably use less FPGA resources).
--
-- Most instructions take around 60ns to 150ns depending on memory access, and
-- have a 1-clock execute cycle.
--
-- The MUL, DIV, and Shift instructions are much faster than the original 9900
-- CPU.  The execute cycle for MUL is 1-clock (10ns) like other instructions.
-- The DIV and Shift instructions take a maximum of 16-clock cycles for the
-- execution cycle.


library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.std_logic_unsigned.all;


entity f18a_gpu is
   port (
      clk            : in  std_logic;
      rst_n          : in  std_logic;     -- reset and load PC, active low
      trigger        : in  std_logic;     -- trigger the GPU
      running        : out std_logic;     -- '1' if the GPU is running, '0' when idle
      pause          : in  std_logic;     -- pause the GPU, active high
      pause_ack      : out std_logic;     -- acknowledge pause
      load_pc        : in  std_logic_vector(0 to 15);
   -- VRAM Interface
      vdin           : in  std_logic_vector(0 to 7);
      vwe            : out std_logic;
      vaddr          : out std_logic_vector(0 to 13);
      vdout          : out std_logic_vector(0 to 7);
   -- Palette Interface
      pdin           : in  std_logic_vector(0 to 11);
      pwe            : out std_logic;
      paddr          : out std_logic_vector(0 to 5);
      pdout          : out std_logic_vector(0 to 11);
   -- Register Interface
      rdin           : in  std_logic_vector(0 to 7);
      raddr          : out std_logic_vector(0 to 13);
      rwe            : out std_logic;     -- write enable for VDP registers
   -- Data inputs
      scanline       : in std_logic_vector(0 to 7);
      blank          : in std_logic;                  -- '1' when blanking (horz and vert)
      bmlba          : in std_logic_vector(0 to 7);   -- bitmap layer base address
      bml_w          : in std_logic_vector(0 to 7);   -- bitmap layer width
      pgba           : in std_logic;                  -- pattern generator base address
   -- Data output, 7-bits of user defined status
      gstatus        : out std_logic_vector(0 to 6);
   -- SPI Interface
      spi_clk        : out std_logic;
      spi_cs         : out std_logic;
      spi_mosi       : out std_logic;
      spi_miso       : in  std_logic
   );
end f18a_gpu;

architecture rtl of f18a_gpu is

begin
    running <= '0';
    pause_ack <= '1';

    vwe <= '0';
    vaddr <= (others => '0');
    vdout <= (others => '0');

    pwe <= '0';
    paddr <= (others => '0');
    pdout <= (others => '0');

    rwe <= '0';
    raddr <= (others => '0');

    gstatus <= (others => '0');

    spi_clk <= '0';
    spi_cs <= '0';
    spi_mosi <= '0';

end rtl;
