ifneq ($(wildcard /opt/homebrew/opt/riscv-gnu-toolchain/bin/riscv64-unknown-elf-gcc),)
    $(info Using Mac Homebrew 64-bit RISC-V GCC Toolchain (riscv64-unknown-elf))
	TOOLCHAIN_BIN_DIR = /opt/homebrew/opt/riscv-gnu-toolchain/bin
	RISCVBUILD = 64
else
    $(info Using 32-bit RISC-V GCC Toolchain installed in /opt/riscv/bin (riscv32-unknown-elf))
	TOOLCHAIN_BIN_DIR = /opt/riscv/bin
	RISCVBUILD = 32
endif

GCC = $(TOOLCHAIN_BIN_DIR)/riscv$(RISCVBUILD)-unknown-elf-gcc
OBJCOPY = $(TOOLCHAIN_BIN_DIR)/riscv$(RISCVBUILD)-unknown-elf-objcopy
FIRMWARE_DIR = .
INCLUDE_DIR = ../libraries

LDS_FILE = $(FIRMWARE_DIR)/boot.lds
START_FILE = $(FIRMWARE_DIR)/boot.S
C_FILES = \
	main.c \
	$(INCLUDE_DIR)/a2fpga/a2fpga.c \
	$(INCLUDE_DIR)/a2slots/a2slots.c \
	$(INCLUDE_DIR)/soc/soc.c \
	$(INCLUDE_DIR)/uart/uart.c \
	$(INCLUDE_DIR)/xprintf/xprintf.c \
	$(INCLUDE_DIR)/a2mem/a2mem.c \
	$(INCLUDE_DIR)/ff/ffunicode.c \
	$(INCLUDE_DIR)/ff/sdmm.c \
	$(INCLUDE_DIR)/ff/ff.c \

all: boot.bin

boot.elf: $(C_FILES) 
	$(GCC) -march=rv32i -mabi=ilp32 -mno-div \
	-nostartfiles \
	-Wl,-Bstatic,-T,$(LDS_FILE),--strip-debug,-Map=boot.map,--cref \
	-fno-zero-initialized-in-bss -ffreestanding -Os \
	-o boot.elf \
	-I$(INCLUDE_DIR) $(START_FILE) $(C_FILES)

boot.bin: boot.elf
	$(OBJCOPY) -O binary boot.elf boot.bin

clean:
	rm -f boot.elf boot.bin boot.o boot.map

