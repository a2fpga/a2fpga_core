# A2FPGA Multicard Core

Multicard core for A2FPGA Apple II FPGA co-processor cards.

The A2FPGA consists of an Apple II peripheral card PCB that can be installed in any Apple II 
slot (slot-7 recommended) that interfaces a modern FPGA to the Apple II bus. The
FPGA interfaces with the Apple II bus to capture all accesses to display memory
in order to drive a 480p HDMI display as well a providing the functionality of
a number of popular peripheral cards in a single Apple II slot.  The A2FPGA
has been tested with Apple II, II+, //e, and IIgs models.

Basic functionality provided:

- 720x480 HDMI output supporting all Apple II, //e, & IIgs display modes

- Mockingboard sound compatibility

- Synetix SuperSprite and Ciarcia EZ-Color TMS9918a compatibility

- Super Serial Card compatibility communications over USB for ADTPro

There are several models of A2FPGA cards that are designed to use different types
of FPGAs from different manufacturers such as Gowin or Xilinx. For ease of design
and manufacturing as well as cost and availability, these have primarily focused 
on using inexpensive FPGA modules such as the Tang Nano 20K that are readily
available from AliExpress or Amazon in quantity and often at prices less than
the FPGA chip alone would cost from a distributor.  These modules have the added
benefit of providing easy USB-based programming.

For enthusiasts looking for an assembled, programmed, and tested A2FPGA board
that is pre-populated with a Tang Nano 20K FPGA module, we have partnered with 
[ReActiveMicro](https://www.reactivemicro.com/product/a2fpga-multicard/) to make the A2N20v2 card available
for easy purchase.

Schematics and Gerbers are available for some of the A2FPGA board models in
other repos in the A2FPGA org and some boards may be available from time to time
on Tindie and eBay.

## Getting Started

You will need the following:

- A2FPGA Apple II Fpga Co-Processor Card, A2N20 versions 2 recommended.
    - The A2N20 card uses the [SiPeed Tang Nano 20K FPGA Developer Board](https://wiki.sipeed.com/hardware/en/tang/tang-nano-20k/nano-20k.html)
    - Cards purchased from [ReActiveMicro](https://www.reactivemicro.com/product/a2fpga-multicard/) will come fully programmed with the Tang Nano FPGA module installed and should be ready for use unless the FPGA bitsream needs to be updated.

- To update the bitstream on the A2FPGA, the most convenient way for Mac and Linux users is to use [OpenFPGALoader](https://github.com/trabucayre/openFPGALoader)
    - Mac users with [Homebrew](https://brew.sh/) can just type `brew install openfpgaloader` in the Terminal to install it
    - Use OpenFPGALoader to program the correct bitstream for your board.
    - For the updating A2N20v2 using OpenFPGALoader, do the following:
        - Download the [a2n20v2.fs](boards/a2n20v2/impl/pnr/a2n20v2.fs) bitstream file by right-clicking on the link and choosing *Save Link As...*
        - Open the Mac Terminal or Linux shell and `cd` into the directory where you've saved the `a2n20v2.fs` file
        - Make sure you've connected the Tang Nano 20K module via USC-C to your Mac or Linux computer
        - Run `openfpgaloader -b tangnano20k -f a2n20v2.fs`

- For updating the bitstream on the A2FPGA on Windows, or rebuilding or developing the A2FPGA project on Windows or Linux, you will need the Gowin V1.9.9Beta-4 Education Edition IDE (or later)
    - [Windows](https://cdn.gowinsemi.com.cn/Gowin_V1.9.9.03_Education_x64_win.zip) 
    - [Linux](https://cdn.gowinsemi.com.cn/Gowin_V1.9.9.03_Education_linux.tar.gz)
    - For updating the *A2N20v2* card using the Gowin Programmer from the above downloads, do the following:
        - Download the [a2n20v2.fs](boards/a2n20v2/impl/pnr/a2n20v2.fs) bitstream file by right-clicking on the link and choosing *Save Link As...*
        - Attach a USB cable from your PC to the Tang Nano 20K USB-C socket
        - Launch the Gowin Programmer. The *Cable Setup* dialog will appear and should detect the USB cable and the Tang Nano 20K device.  The FPGA will appear in the device list as *GW2AR-18C*.
        - If any device appears in the device list with anything other than *GW2AR-18C* then click on it and hit the *Delete Device* button.  If there no devices after doing this, click *Scan Device* and it will say *Multi-device found*, select *GW2AR-18C*.
        - Right click on the device and select *Configure Device*
        - Select *External Flash Mode*, choose *Generic Flash* in *External Flash Options*, leave address at *0x000000*. Select the `a2n20v2.fs` file in *Programming Options File Name*. Hit *Save*.
        - Hit *Program/Configure*.  It will program the device.

Install the A2FPGA card into any slot in your Apple II or //e.  IIgs users with ROM 00/01 models will need to install the card in slot 3.  Please note that
the default configuration assumes that slots 4 and 7 are empty as it uses
the memory addresses for these to support Mockingboard and
SuperSprite software.  If you are using a build that provides Super Serial Card support, you'll need Slot 1 empty as well.  If you already have cards in those slots and plan to
continue using them, you'll need to build a version of the Multicard core with
those cards disabled in top.v.

### Using the A2N20 Version 2
(Current version, recommended for most users)

- Compatible with the II, II+, //e, and IIgs
- Supports 40/80 column text, lo-res, hi-res, and super-hires graphics
- For use with a IIgs, set DIP switch 4 to on.  For all other models, DIP switch 4 must be off.
- Provides video and sound output as well as providing Supersprite compatibility
- Uses the larger [Tang Nano 20K](https://wiki.sipeed.com/hardware/en/tang/tang-nano-20k/nano-20k.html)
- Delays Apple startup until power-up initialization of FPGA is complete (optional)
- Compatible with most HDMI television sets and monitors
- Not compatible with HDMI-to-DVI converters
- Recommended for all users/models
- General Availability - contact [ReActiveMicro](https://www.reactivemicro.com/product/a2fpga-multicard/) to order

The A2N20v2 has a 4-switch DIP switch that controls the following settings:

1. Enable Scanline effect when set to on
2. Enable Apple II speaker sounds via HDMI when set to on
3. Power-on-Reset Hold - Delay Apple II start-up until FPGA is initialized and running
4. Apple IIgs - Set to on when installed in an Apple IIgs

For ROM 00/01 IIgs models (such as the Woz edition), the A2N20v2 must be placed in Slot 3.  For ROM 03 models, it should work in any slot. This is because it requires the M2B0 signal which is only present in Slot 3 of the original IIgs models, but which is present in slots 1 to size of the ROM 03 model. 

[A2N20v2 Board Support Project (Schematics, Project Files)](boards/a2n20v2/)

[A2N20v2 Board Support Project (Experimental SDRAM Feature Set)](boards/a2n20v2_enhanced/)

### Using the A2N9

- Compatible with the II, II+, and //e
- Supports 40/80 column text, lo-res, and hi-res graphics
- Not bus-compatible with the IIgs
- Provides HDMI video output and Mockingboard sound
- No SuperSprite support
- Uses the smaller and cheaper [Tang Nano 9K](https://wiki.sipeed.com/hardware/en/tang/Tang-Nano-9K/Nano-9K.html)
- Starts instantly on Apple power-up
- Not compatible with many HDMI televisions although it works fine with most monitors
- Not compatible with HDMI-to-DVI converters
- Recommended for hobbyist use and experimentation
- Open Source Hardware Design, boards available periodically via Tindie and eBay

[A2N9 Board Board Support Project (Schematics, Project Files)](boards/a2n9/)

### Using the A2N20 Version 1

- Compatible with the II, II+, and //e
- Supports 40/80 column text, lo-res, hi-res, and super-hires graphics
- Not bus-compatible with the IIgs
- Provides video and sound output as well as providing Supersprite compatibility
- Uses the larger [Tang Nano 20K](https://wiki.sipeed.com/hardware/en/tang/tang-nano-20k/nano-20k.html)
- Delays Apple startup until power-up initialization of FPGA is complete
- Compatible with most HDMI television sets and monitors
- Not compatible with HDMI-to-DVI converters
- Recommended for all users/models (except IIgs)
- Limited Production, replaced by V2

[A2N20v1 Board Support Project (Schematics, Project Files)](boards/a2n20v1/)

## HDMI Apple II Graphics

The Multicard core provides an 720x480 HDMI output of the Apple II, //e, and IIgs
display.  It supports 40 and 80 column text as well as lo-res, hi-res, double-hires, and
super-hires graphics modes (IIgs modes currently only available on A2N20v2 cards).

The Multicard code has a custom graphics pipeline that attempts to provide
accurate Apple II artifacts, leveraging insights from many of the other
Apple II FPGA cores as well as MAME and AppleWin, but in an entirely new
codebase.  Even 40 years later, getting Apple II artifacts right remains
a challenge, but we've been able to achieve very good results comparable
to other implementations.

The A2FPGA uses the 720x480 HDMI resolution, centering the Apple II 280/560
horizontal resolution and doubling the 192 vertical lines. The goal of the
display implementation is to not do any blurring or pixel interpolation
of the display output, so the result is that the display is slightly
stretched horizontally on a modern widescreen HDMI display.  For the IIgs
320/640 by 240 super hires modes, the display is once again centered
and vertically line-doubled within the 720x480 HDMI display area. Many
monitors and TVs have a "4:3 mode" in their settings that will give you a more
faithful aspect ratio if desired.

By default, a scanline effect is provided that dims alternating lines
to create a CRT-like display appearance.  This can be enabled or disabled on the
A2N20 card using DIP switch 1.  

## SuperSprite

The [SuperSprite](https://archive.org/details/CreativeComputing.2-1984_A_New_Way_To_Do_Graphics_On_The_Apple)
was introduced in 1984 by Synetix and is one of the more rare Apple II cards.
The SuperSprite used the TMS9918a Video Display Processor, which was originally
created for the TI 99/4A home computer and was also used within a number of
other computers and video games, ranging from MSX computers to the ColecoVision.
Synetix used the video overlay capabilities of the TMS9918a to let sprite
graphics sit over the Apple II display.  The basics of using a TMS9918a in the
Apple II had been demonstrated by Steve Ciarcia in a Byte magazine article he
published in August of 1982 titled ["High-Resolution Sprite-Oriented Color
Graphics"](https://archive.org/details/byte-magazine-1982-08/page/n57/mode/2up).
The SuperSprite used the same memory-mappings as the Ciarcia design while adding
an AY-3-8910 sound chip as well as a TMS5220 voice processor.

The Multicard core uses the [F18a TMS9918a](https://github.com/dnotq/f18a) core to
provide sprite graphics which are overlayed on top of the Apple II display.  It is
designed to be compatible with the Synetix SuperSprite as well as Steve
Ciarcia's EZ-Color card.  SuperSprite compatibility includes AY-3-8910 sound
although TMS5220 voice support is not currently implemented.

By default, the Multicard core emulates a SuperSprite card in slot 7 although the A2FPGA
card can physically be in any slot.  The slot configuration can be changed
in the top.v file.

## Mockingboard

The [Mockingboard](https://en.wikipedia.org/wiki/Mockingboard) was the most
popular sound card for the Apple II.  It uses a pair of
[AY-3-8910](https://en.wikipedia.org/wiki/General_Instrument_AY-3-8910) sound
chips controled by two [6522
VIA](https://en.wikipedia.org/wiki/MOS_Technology_6522) interface chips to
enable a wide variety of sound effects and musical playback.

The Multicard core implements support for the Sweet Micro Systems Mockingboard,
providing stereo output over HDMI.  Voice support is not currently provided as
there is no FPGA core yet available for the [Votrax
SC-01](https://en.wikipedia.org/wiki/Votrax) used on the Mockingboard.

By default, the Multicard emulates a Mockingboard in slot 4 although the A2FPGA
card can physically be in any slot.  Slot position is configurable in the
top.v file.

## Apple II and IIgs Sound

Apple speaker sounds are generated by the core and played over the HDMI
audio.  If used with the Mockingboard or Supersprite sound generation, the results are
mixed together.

Apple II sound can be enabled or disabled on the A2N20 card using DIP switch 1.  

Apple IIgs sound is currently experimentally provided through an implementation
of the IIgs GLU chip and the Ensoniq 5503 DOC chip.  However, this is still in
the experimental stage and disabled in the default builds.

## Super Serial Card

The Multicard implements Super Serial Card-compatible serial communications over
USB to a host computer.  This is compatible with [ADTPro](https://adtpro.com/)
and can bootstrap from it.

By default, the Multicard emulates a Super Serial Card in slot 2 although the A2FPGA
card can physically be in any slot.  Slot position is configurable in the
software.

## Code Organization

Specific cards are provided as distinct projects under the [boards/](boards/) subdirectory.  Each
board configuration has a specific subdirectory that includes it's project file as well as any
project-specific code or resources.  Synthesis and PnR output is also in these subdirectories.

Common code is in the [hdl/](hdl/) subdirectory and includes all of the Verilog, SystemVerilog, and
VHDL code for the A2FPGA codebase that is portable across FPGA hardware.

Other source code is in the [src/](src/) subdirectory and contains Apple II utilities, sample code,
and the PicoSoC firmware and kernel used by board versions that provide the PicoRV32 co-processor
for handling FAT32 SD-Card access and other functionality.

## Credits

The A2FPGA core was principally coded by [Ed Anuff](https://github.com/edanuff).  Research, design, documentation,
and extensive testing provided by [Joshua Norrid](https://github.com/jnorrid). Advice and testing was provided by
[JB Langston](https://github.com/jblang) and [Hans Hübner](https://github.com/hanshuebner) as well as Henry Courbis from 
[ReactiveMicro.com](https://www.reactivemicro.com/).

The Multicard core draws from a number of other open source FPGA cores, including:

- Matthew Hagerty's [F18a TMS9918a](https://github.com/dnotq/f18a) core and
    - [Felipe Antoniosi's port of the F18a to the Tang Nano 9K](https://github.com/lfantoniosi/tn_vdp)

- [MiSTer FPGA Apple IIe core](https://github.com/MiSTer-devel/Apple-II_MiSTer), leveraging:
    - [Stephen A. Edwards' original Apple II core](http://www.cs.columbia.edu/~sedwards/apple2fpga/)
    - [Szombathelyi György's revised Apple //e core](https://github.com/gyurco/apple2efpga)
    - [Alan Steremberg's Verilog port of the MiSTer core](https://github.com/alanswx/Apple-II-Verilog_MiSTer)

- [Sameer Puri's HDMI core](https://github.com/hdl-util/hdmi)

- [MikeJ & Sorgelig's YM2149 core](https://github.com/MiSTer-devel/Apple-II_MiSTer/blob/master/rtl/mockingboard/YM2149.sv)

- [Gideon Zweijtzer's 6522 core](https://github.com/mist-devel/plus_too/blob/master/via6522.vhd)

- [Gary Becker's 6551 core](https://github.com/MiSTer-devel/CoCo3_MiSTer/blob/master/rtl/UART_6551/uart_6551.v)

- [Claire Xenia Wolf's PicoRV32 and PicoSoC](https://github.com/YosysHQ/picorv32) and
    - [Lawrie Griffiths' example of running PicoSoC from BRAM](https://github.com/lawrie/pico_ram_soc)

- [Adam Gastineau's SDRAM controller core](https://github.com/agg23/sdram-controller)

None of this possible without Jim Sather's Understanding the Apple IIe and
Winston D. Gaylor's The Apple II Circuit Description.

All of this is an homage to Steve Wozniak for creating the Apple II as well as
to the great chip designers of the 8-bit era, such as Karl Guttag who designed the 
TI9918a video processor at Texas Instruments which was used by the SuperSprite card,
the emulation of which was the original impetus for this project. 

## License(s)

A2FPGA an open source hardware project and the A2FPGA Multicard Core gratefully leverages the work
of other open source authors.  New code that was created specifically for this project
is made available under the MIT License but many files may have different licenses in their headers 
from the original authors.  All open source code from other authors that is reused
in this project is believed to be used consistently with the licenses such code is provided
under.  If reusing any code from this project, please be sure to check that your intended
usage is covered by the stated licenses.

## Contact

[info@a2fpga.com](mailto:info@a2fpga.com)
