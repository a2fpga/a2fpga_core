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

### Newer macOS / recent Xcode build fixes

The `--enable-gdb` + `make newlib` recipe above works on older Command Line
Tools, but on a recent macOS with current Xcode CLT (Apple clang 16/17+) the
vendored GCC 10.4.0 tree fails to build in three independent ways. If `make
newlib` errors out, apply these and build the compiler target directly.

1. **Bundled zlib won't compile** (in `binutils`, and `gdb`).
   ```
   zutil.c:133:16: error: expected identifier or '('
     133 | const char * ZEXPORT zError(err)
   make[3]: *** [libz_a-zutil.o] Error 1
   ```
   Only the top-level `gcc` configure passes `--with-system-zlib`; the
   `binutils`/`gdb` sub-builds don't. Fix: in the generated `Makefile`, add
   `--with-system-zlib` to the `configure` invocation under
   `stamps/build-binutils-newlib:` (and `stamps/build-gdb-newlib:` if you build
   gdb).

2. **GCC's host C++ won't compile against Apple's libc++.**
   ```
   .../c++/v1/__locale:477:3: error: '__abi_tag__' attribute only applies to
     structs, variables, functions, and namespaces
   ```
   Fix: build the host tools with Homebrew GCC instead of Apple clang
   (`brew install gcc`), e.g. `export CC=gcc-16 CXX=g++-16` (match your installed
   version).

3. **A `.` on your `$PATH` shadows the assembler.**
   GCC's build tree contains wrapper scripts literally named `as`/`ld`; if `.`
   (or `./`) is on `$PATH`, they are picked up instead of the system assembler.
   ```
   Assembler messages:
   Fatal error: invalid listing option `r'
   ```
   Fix: build with a `$PATH` that has no `.`/`./` entries.

Target `gdb` is **not needed** to build firmware, and it does not compile against
the current libc++ even with fix (1). Skip it: drop `--enable-gdb` and build the
compiler stamp directly rather than the `newlib` meta-target (which depends on
gdb).

Working recipe (after the clone + newlib patch + `config.host` edits above, and
after adding `--with-system-zlib` to the binutils recipe in the `Makefile`):

```bash
# GNU coreutils first; NO '.' anywhere on PATH
export PATH="$(brew --prefix)/opt/coreutils/libexec/gnubin:/opt/homebrew/bin:/usr/bin:/bin"
export CC=gcc-16 CXX=g++-16          # Homebrew GCC as the host compiler

./configure --prefix=/opt/riscv-toolchain/xuantie --with-cmodel=medany --enable-multilib
make stamps/build-gcc-newlib-stage2 -j$(sysctl -n hw.ncpu)   # builds gcc + newlib, skips gdb
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

**Pin the SDK to the tested tag `v2.3.27` (CherryUSB v1.5.3).** A bare clone
lands on `master`, whose CherryUSB API differs and will not build without
porting — this is the #1 cause of "works on one machine, not another".

```bash
git clone --branch v2.3.27 --depth 1 https://github.com/bouffalolab/bouffalo_sdk.git
# existing clone:  cd bouffalo_sdk && git fetch --tags && git checkout v2.3.27
git -C bouffalo_sdk describe --tags    # verify -> v2.3.27
```

Clone it anywhere; the build does **not** rely on a particular relative layout.
`BL_SDK_BASE` is passed explicitly to `make` (the Makefile's default relative
path is not used). No macOS patches to the SDK are needed at v2.3.27 — upstream
handles Darwin directly (older notes about editing `bflb_flash.cmake` /
`project.build` are obsolete).

## Smoke Test

Build with the T-Head toolchain first on `PATH` and `BL_SDK_BASE` set
explicitly. After any toolchain/SDK change, `rm -rf build` first.

```bash
cd a2fpga_core/boards/a2n20v2-Enhanced/src/a2n20_bl616/firmware
PATH=/opt/riscv-toolchain/xuantie/bin:$PATH BL_SDK_BASE=/path/to/bouffalo_sdk \
    make CHIP=bl616 BOARD=bl616dk
# -> build/build_out/a2n20_bl616_bl616.bin

# the USB-host build is built the same way:
cd ../firmware_host
PATH=/opt/riscv-toolchain/xuantie/bin:$PATH BL_SDK_BASE=/path/to/bouffalo_sdk \
    make CHIP=bl616 BOARD=bl616dk
# -> build/build_out/a2n20_bl616_host_bl616.bin
```

Expected: a clean run ends with `Built target combine` and the `.bin` exists.

## Flashing

### Flashing-tool prerequisites (`a2n20-mcu-program`)

The recommended flasher, `tools/a2n20-mcu-program`, is a Python wrapper around
`bflb-iot-tool`. Two things bite on macOS:

- It needs the `pyserial` and `bflb-iot-tool` Python packages.
- `bflb-iot-tool` imports `telnetlib`, which was **removed in Python 3.13**.
  Homebrew's default `python3` is now 3.13/3.14, so use **Python 3.12 or older**.

A self-contained venv avoids touching system Python:

```bash
cd boards/a2n20v2-Enhanced/src/a2n20_bl616
/opt/homebrew/bin/python3.12 -m venv .venv        # brew install python@3.12 if needed
.venv/bin/pip install pyserial bflb-iot-tool
# run with the venv's bin on PATH so the wrapper can find bflb-iot-tool:
PATH="$PWD/.venv/bin:$PATH" .venv/bin/python tools/a2n20-mcu-program --detect
```

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
