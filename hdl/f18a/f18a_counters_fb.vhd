--
-- F18A Counters — Framebuffer variant for A2Mega (DDR3)
--
-- Based on f18a_counters.vhd by Matthew Hagerty (3-Clause BSD License)
-- Modified for DDR3 framebuffer pipeline:
--   - 2x horizontal pixel doubling (512 raster pixels for 256 TMS pixels)
--   - No vertical doubling (1:1 Y scale, 192 TMS lines = 192 FB lines)
--   - Margin constants for 560x192 visible frame
--   - Both clk and vga_clk are the same clock (54 MHz) — no CDC needed
--   - Simplified scan line blanking (no doubled VGA lines)
--   - Simplified sprite collision flag (no cross-domain toggle)
--

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.std_logic_unsigned.all;


entity f18a_counters is
   port (
      clk            : in std_logic;
      vga_clk        : in std_logic;
      rst_n          : in std_logic;            -- reset active low
      raster_x       : in unsigned(0 to 9);
      raster_y       : in unsigned(0 to 9);
      y_tick         : in std_logic;
      y_max          : in std_logic;
      sprt_yreal     : in std_logic;            -- 1 to use real sprite location, 0 for original off-by-one
      gmode          : in unsigned(0 to 3);
      row30          : in std_logic;            -- 1 when 30 rows
      blank_in       : in std_logic;            -- VGA blanking signal in
      sl_blank       : out std_logic;           -- scan line blanking signal out
      intr_en        : out std_logic;           -- interrupt tick
      sp_cf_en       : out std_logic;           -- sprite collision flag tick
      scanline       : out unsigned(0 to 7);    -- current horz scan line location
      in_margin      : out std_logic;
      y_margin_n     : out std_logic;
      x_pixel_max    : out unsigned(0 to 8);    -- max pixel count
      x_pixel_pos    : out unsigned(0 to 8);    -- current x location for tiles
      x_sprt_pos     : out unsigned(0 to 7);    -- current x location for sprites
      y_next         : out unsigned(0 to 8);    -- next y location for tiles
      y_sprt_pos     : out unsigned(0 to 7);    -- next y location for sprites
      prescan_start  : out std_logic
   );
end f18a_counters;

architecture rtl of f18a_counters is

   -- Start and end points to center the TMS9918 display within the 560-pixel
   -- framebuffer scanline at 2x horizontal scale.
   -- No vertical margin (192 TMS lines = 192 FB lines).
   --
   -- Graphics modes: 256 TMS pixels × 2 = 512 raster pixels, centered in 560
   --   margin = (560-512)/2 = 24. XEND = 24+512-1 = 535
   -- Text modes:     240 TMS pixels × 2 = 480 raster pixels, centered in 560
   --   margin = (560-480)/2 = 40. XEND2 = 40+480-1 = 519
   constant XSTART   : integer := 24;     -- X start for graphics modes
   constant XSTART2  : integer := 40;     -- X start for text modes
   constant XEND     : integer := 535;    -- X end for graphics modes (24+512-1)
   constant XEND2    : integer := 519;    -- X end for text modes (40+480-1)

   -- No vertical margin — 192 visible lines fill the entire frame.
   -- YPRESCAN equivalent: line 261 is the non-visible prescan line where
   -- y_count=0, filling tile/sprite buffers before first visible line (0).
   constant YPRESCAN : integer := 261;    -- = VMAX, prescan line for row 0
   constant YSTART   : integer := 0;
   constant YEND     : integer := 191;

   constant SL_RESET1: integer := 260;    -- 1 line before VMAX (prescan line 261)
   constant SL_RESET2: integer := 260;    -- 1 line before VMAX (prescan line 261)

   -- row30 mode uses same values (no vertical margin either way)
   constant YPRESCAN2: integer := 261;
   constant YSTART2  : integer := 0;
   constant YEND2    : integer := 191;

   -- Margin indicators
   signal xmargin    : std_logic;
   signal ymargin    : std_logic;

   signal xstart_mux : unsigned(0 to 9);
   signal xend_mux   : unsigned(0 to 9);
   signal ystart_mux : unsigned(0 to 9);
   signal yend_mux   : unsigned(0 to 9);

   signal margin_next: std_logic;
   signal margin_reg : std_logic;
   signal y_margin_reg : std_logic;

   signal row30reg   : std_logic;
   signal y_count_en : std_logic;

   signal x_pixel_pos_reg  : unsigned(0 to 8);     -- current x location for tiles
   signal x_pixel_pos_next : unsigned(0 to 8);
   signal x_sprt_pos_reg   : unsigned(0 to 7);     -- current x location for sprites
   signal x_sprt_pos_next  : unsigned(0 to 7);

   -- Interrupt
   signal intr_ff       : std_logic;
   signal valid_y       : std_logic;
   signal valid_y_last  : std_logic;

   -- Sprite collision flag (simplified — no CDC needed, same clock domain)
   signal sprt_cf_ff    : std_logic;
   signal sprt_cf_tick  : std_logic;

   -- X 1x-pixels
   signal x480 : unsigned(0 to 9);  -- text modes (8x6 tiles)
   signal x512 : unsigned(0 to 9);  -- graphics modes (8x8 tiles)

   -- X pixels at 2x scale (divide by 2 to get TMS pixel coords)
   signal x240 : unsigned(0 to 7);
   signal x256 : unsigned(0 to 7);

   -- Y 1x-pixels
   signal y_count : unsigned(0 to 8);  -- 0 to 191 in this variant

   -- Y at 1:1 (no vertical doubling)
   signal y_half : unsigned(0 to 7);

   -- Scan line counter
   signal scanline_cnt     : unsigned(0 to 8);
   signal scanline_reset   : std_logic;

begin

   -- Register row30 to allow more efficient routing.
   process (vga_clk) begin if rising_edge(vga_clk) then
      row30reg <= row30;
   end if; end process;

   -- Indexes for tile and sprite output line buffers.
   -- At 2x horizontal scale, divide raster position by 2 to get TMS pixel coords.
   x512 <= raster_x - XSTART;
   x480 <= raster_x - XSTART2;

   -- 2x horizontal: x512(1 to 8) = bits 1-8 of 10-bit result = divide by 2
   -- x512 goes 0-511 in active area, x256 = 0-255 TMS pixels
   x256 <= x512(1 to 8);
   x240 <= x480(1 to 8);

   x_pixel_max <=
      "011101111" when gmode = 1 else  -- 239 for text1 mode
      "111011111" when gmode = 9 else  -- 479 for text2 mode
      "111111111" when gmode > 9 else  -- 511 for 9938 modes
      "011111111";                     -- 255 for gm1, gm2, mcm

   x_pixel_pos_next <=
      x512(1 to 9) when gmode > 9 else    -- hi-res 1x pixel modes
      x480(1 to 9) when gmode = 9 else    -- text2 mode
      '0' & x240 when gmode = 1 else      -- text1 mode
      '0' & x256;                         -- gm1, gm2, mcm

   x_sprt_pos_next <= x256;               -- sprites are always on a 0 to 255 grid

   process (vga_clk) begin if rising_edge(vga_clk) then
      if xmargin = '1' then
         x_pixel_pos_reg <= (others => '0');
         x_sprt_pos_reg <= (others => '0');
      else
         x_pixel_pos_reg <= x_pixel_pos_next;
         x_sprt_pos_reg <= x_sprt_pos_next;
      end if;
   end if; end process;

   x_pixel_pos <= x_pixel_pos_reg;
   x_sprt_pos <= x_sprt_pos_reg;


   -- Trigger the prescan for tiles and sprites.
   prescan_start <= '1' when raster_x = 1 and y_count_en = '1' else '0';

   -- Normalized Y counter.
   -- At 1:1 vertical scale (no 2x doubling), we must NOT increment y_count
   -- on the scanline_reset tick. In the original 2x design, the division by 2
   -- absorbed the initial increment (y_count=1 → y_half=0). At 1:1 scale,
   -- y_count maps directly to y_half, so we only enable y_count_en on the
   -- scanline_reset tick. This gives us y_count=0 on the prescan line (261),
   -- filling the first tile line buffer with row 0 before the first visible
   -- line (0) renders from that buffer.
   process (vga_clk)
   begin
      if rising_edge(vga_clk) then
         if y_max = '1' then
            -- Reset the counter to zero outside the active area.
            y_count <= (others => '0');
            y_count_en <= '0';
         elsif y_tick = '1' then
            if scanline_reset = '1' then
               -- Enable only — do not increment. First prescan (line 261)
               -- will use y_count=0 to fill row 0 of tile/sprite buffers.
               y_count_en <= '1';
            elsif y_count_en = '1' then
               y_count <= y_count + 1;
            end if;
         end if;
      end if;
   end process;

   -- NO 2x doubling: y_half = y_count directly (y_count goes 0-191,
   -- fits in 8 bits since upper bit y_count(0) is always 0 for values <= 191).
   y_half <= y_count(1 to 8);

   -- y_next: at 1:1 scale, no divide. For modes < 10, y_next = y_count.
   y_next <= '0' & y_half when gmode < 10 else y_count;

   -- Horizontal scan line output.
   scanline_reset <= '1' when
      (raster_y = SL_RESET1 and row30reg = '0') or
      (raster_y = SL_RESET2 and row30reg = '1') else '0';

   process (vga_clk) begin if rising_edge(vga_clk) then
      if raster_x = 1 then
         -- Reset near VMAX before the visible area.
         if scanline_reset = '1' then
            scanline_cnt <= (others => '0');
         -- Stick at the max until reset.
         elsif scanline_cnt /= "111111111" then
            scanline_cnt <= scanline_cnt + 1;
         end if;
      end if;
   end if; end process;

   scanline <= scanline_cnt(0 to 7);

   -- No scan line doubling at 1:1 — pass through blank directly.
   sl_blank <= blank_in;

   -- Sprites are always a 0 to 191 grid and 1 line behind the raster.
   y_sprt_pos <= y_half - 1 when sprt_yreal = '0' else y_half;


   -- Indicate when the raster is in the margin.
   process (gmode, row30reg) begin
      if gmode = 1 or gmode = 9 then
         xstart_mux <= to_unsigned(XSTART2, 10);
         xend_mux <= to_unsigned(XEND2, 10);
      else
         xstart_mux <= to_unsigned(XSTART, 10);
         xend_mux <= to_unsigned(XEND, 10);
      end if;

      if row30reg = '0' then
         ystart_mux <= to_unsigned(YSTART, 10);
         yend_mux <= to_unsigned(YEND, 10);
      else
         ystart_mux <= to_unsigned(YSTART2, 10);
         yend_mux <= to_unsigned(YEND2, 10);
      end if;
   end process;

   margin_next <= '1' when
       raster_x < xstart_mux or raster_x > xend_mux or
       raster_y < ystart_mux or raster_y > yend_mux else '0';
   xmargin <= '1' when raster_x < xstart_mux or raster_x > xend_mux else '0';
   ymargin <= '1' when raster_y < ystart_mux or raster_y > yend_mux else '0';

   -- Register the margin indicator.
   process (vga_clk) begin if rising_edge(vga_clk) then
      margin_reg <= margin_next;
      y_margin_reg <= not ymargin;
   end if; end process;
   in_margin <= margin_reg;
   y_margin_n <= y_margin_reg;

   -- The VDP interrupt happens after the last line of the active display area.
   valid_y <= '1' when
      (raster_y = (YEND  + 1) and row30reg = '0') or
      (raster_y = (YEND2 + 1) and row30reg = '1')
      else '0';

   -- Interrupt edge detector (same clock domain — clk = vga_clk = clk_logic).
   process (clk) begin if rising_edge(clk) then
      intr_ff <= '0';
      valid_y_last <= valid_y;

      if valid_y = '1' and valid_y_last = '0' then
         intr_ff <= '1';
      end if;
   end if; end process;

   intr_en <= intr_ff;

   -- Sprite collision flag: simplified for single clock domain.
   -- In the original, a toggle/edge-detect mechanism crosses from vga_clk to clk.
   -- Since both clocks are now the same (54 MHz), we generate a simple tick
   -- that fires once per raster-x cycle. No scan line doubling means every
   -- scanline is real, so we always enable collision detection.
   process (clk) begin if rising_edge(clk) then
      -- Generate a one-cycle tick at raster_x = 2 (after prescan_start at x=1)
      -- This provides a once-per-pixel collision check opportunity.
      if raster_x > 0 and raster_x <= 560 then
         sprt_cf_ff <= '1';
      else
         sprt_cf_ff <= '0';
      end if;
   end if; end process;

   sp_cf_en <= sprt_cf_ff;

end rtl;
