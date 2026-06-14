# macOS Build Environment Setup

Build environment for BL616 firmware on macOS (Apple Silicon or Intel).

## Prerequisites

```bash
brew install cmake make ninja python3 gawk gnu-sed gmp mpfr libmpc isl zlib expat coreutils texinfo
```

## T-Head RISC-V Toolchain

The BL616 uses a T-Head E907 core requiring vendor-specific GCC extensions (`xtheade`, `zpsfoperand`) not available in upstream RISC-V GCC. No pre-built macOS binaries exist — must build from source.

**Target arch flags**: `-march=rv32imafcpzpsfoperand_xtheade -mabi=ilp32f -mcpu=e907`

### Check if already installed

```bash
/opt/riscv-toolchain/xuantie/bin/riscv64-unknown-elf-gcc --version
# Expected: riscv64-unknown-elf-gcc () 10.4.0
```

If the above works, skip to [PATH Setup](#path-setup).

### Build from source

This takes 30-60 minutes depending on your Mac.

```bash
git clone --recurse-submodules https://github.com/XUANTIE-RV/xuantie-gnu-toolchain.git
cd xuantie-gnu-toolchain

# Apply macOS patches
cd riscv-newlib
wget https://raw.githubusercontent.com/p4ddy1/pine_ox64/main/riscv-newlib.patch
git apply riscv-newlib.patch
cd ..
sed -i '' "s/.*=host-darwin.o$//" riscv-gcc/gcc/config.host
sed -i '' "s/.* x-darwin.$//" riscv-gcc/gcc/config.host

# Create install directory
sudo mkdir -p /opt/riscv-toolchain
sudo chown -R $USER /opt/riscv-toolchain

# Build (requires GNU coreutils in PATH)
export PATH=$(brew --prefix)/opt/coreutils/libexec/gnubin:$PATH
./configure --prefix=/opt/riscv-toolchain/xuantie --with-cmodel=medany --enable-multilib --enable-gdb
make newlib -j$(sysctl -n hw.ncpu)
```

### Verify installation

```bash
/opt/riscv-toolchain/xuantie/bin/riscv64-unknown-elf-gcc --version
# riscv64-unknown-elf-gcc () 10.4.0

/opt/riscv-toolchain/xuantie/bin/riscv64-unknown-elf-gcc -print-multi-lib | head -3
# Should list multilib variants
```

**Important**: Homebrew's `riscv64-unknown-elf-gcc` (14.x) will NOT work — it lacks T-Head vendor extensions and will fail with "unrecognized argument" errors on the arch flags.

## PATH Setup

The T-Head toolchain must be in PATH before any Homebrew RISC-V toolchain:

```bash
export PATH=/opt/riscv-toolchain/xuantie/bin:$PATH
```

Add to your shell profile (`~/.zshrc` or `~/.bashrc`) for persistence:

```bash
echo 'export PATH=/opt/riscv-toolchain/xuantie/bin:$PATH' >> ~/.zshrc
```

## Bouffalo SDK

The SDK should be cloned as a sibling of the project directory:

```bash
# From the parent directory containing a2n20_tn20k_bl616/
git clone https://github.com/bouffalolab/bouffalo_sdk.git
```

Expected layout:
```
parent/
├── a2n20_tn20k_bl616/
│   └── firmware/           # Our firmware
└── bouffalo_sdk/           # SDK
```

The firmware Makefile sets `BL_SDK_BASE` to `../../bouffalo_sdk` relative to `firmware/`.

## Smoke Test

```bash
cd a2n20_tn20k_bl616/firmware
export PATH=/opt/riscv-toolchain/xuantie/bin:$PATH
make CHIP=bl616 BOARD=bl616dk
```

Expected: `build/build_out/a2n20_bl616_bl616.bin` exists and is non-zero.

## Flashing

### Enter boot mode

1. Press and hold the **UPDATE** button (top of Tang Nano 20K, behind HDMI connector)
2. Connect USB-C to the **Debug** port (or power-cycle while holding UPDATE)
3. Release button — BL616 enumerates as CDC-ACM device
4. macOS: appears as `/dev/tty.usbmodem*`

### Flash standalone (address 0x0)

```bash
make flash CHIP=bl616 COMX=/dev/tty.usbmodemXXXX
```

### Flash as Stage 2 (address 0x40000)

For fused boards with Sipeed Stage 1:

```bash
make flash CHIP=bl616 COMX=/dev/tty.usbmodemXXXX FLASH_CFG=flash_stage2_cfg.ini
```

### Verify

1. Disconnect and reconnect USB (no UPDATE button)
2. `ls /dev/tty.usbmodem*` — should show new CDC ACM device ("A2N20 BL616 Test")
3. Open terminal: `screen /dev/tty.usbmodemXXXX 115200`
4. Should see periodic "A2N20 BL616 alive" messages
