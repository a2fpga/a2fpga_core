# A2N20 RISC-V/32 SOC

The A2N20 uses the [PicoRV32](https://github.com/YosysHQ/picorv32) core as a coprocessor for on-screen display and FAT32 SDCard support.

The `firmware` subdirectory contains the code for generating the .hex file that is used to initialize blockram in the FPGA core during synthesis.  This is what
is executed when the FPGA finishes configuration at power up.  The firmware uses the [Petite Fat File System](http://elm-chan.org/fsw/ff/00index_p.html) to
load `boot.bin` from the root directory of an SDCard.  Use `make` to build the firmware.  The `firmware.hex` file will be copied into the appropriate
directory in the rtl source, assuming files are all in the correct directory.

The `boot` subdirectory contains the actual runtime kernel for generating the on-screen display for mounting disk volume images as well as configuring
options for the A2N20.  Use `make` to build the boot kernel and place the resultant `boot.bin` file in the root directory of an SDCard.

For Mac, use the [RISC-V Toolchain installed via Homebrew](https://github.com/riscv-software-src/homebrew-riscv).  Use the standard `brew install riscv-tools` option.  This will install the version that supports both 64-bit and 32-bit targets.  Contrary to many sources online, the riscv64-unknown-elf-* tools will build for 32-bit targets such as PicoRV32 as long as the command line options `-march` and `-mabi` are set properly.  You do not need to build or install the riscv32-unknown-elf-* toolset.

For Windows under WSL2 or Linux, use the [Prebuilt RISC-V GCC Toolchains for Linux](https://github.com/stnolting/riscv-gcc-prebuilt) and choose the rv32i download and follow the installation instructions.

Note: This firmware and PicoSoc implementation is derived from Lawrie Griffiths' [pico_ram_soc](https://github.com/lawrie/pico_ram_soc) project which adapts PicoRV32 to use FPGA BlockRam as program memory as well as Claire Wolf's [icotools](https://github.com/cliffordwolf/icotools) project.
