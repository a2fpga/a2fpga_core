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

-- The on-board 16K VRAM.  Initialized with font pattern and name table data
-- that will display the F18A power-on screen.  This allows the F18A to produce
-- a display even when there is no host CPU and helps troubleshooting.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity f18a_single_port_ram is
   port (
      clk   : in  std_logic;
      we    : in  std_logic;
      addr  : in  std_logic_vector(0 to 13);
      addr2 : in  std_logic_vector(0 to 13);
      din   : in  std_logic_vector(0 to 7);
      dout  : out std_logic_vector(0 to 7);
      dout2 : out std_logic_vector(0 to 7)
      );
end f18a_single_port_ram;

architecture rtl of f18a_single_port_ram is

   -- Initialize the VRAM with patterns for a font and credits / version information on the screen.
   type ram_t is array (0 to 16383) of std_logic_vector(0 to 7);
   signal ram : ram_t;

begin
   -- Inferred read_first ram.
   process (clk)
   begin
      if rising_edge(clk) then
         dout2 <= ram(to_integer(unsigned(addr2)));
         if we = '1' then
            ram(to_integer(unsigned(addr))) <= din;
         else
            dout <= ram(to_integer(unsigned(addr)));
         end if;
      end if;
   end process;

end rtl;
