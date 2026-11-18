# ESP32-S3 Arduino CLI Makefile
# A2FPGA ESP32 co-processor firmware (a2mega board; also the a2p25
# "displayport1" rev — see boards/a2p25/docs/ESP32_FW_A2P25.md)

# Module varies by board revision (BOARD_REV below):
#   1.0a3   ESP32-S3-MINI-1-N4R2 — 4 MB flash + 2 MB quad PSRAM
#   1.0a2x  ESP32-S3-MINI-1-N8   — 8 MB flash, no PSRAM
#   a2p25   ESP32-S3-MINI-1-N4R2 (BOARD_REV=225, same settings as 1.0a3)
BOARD = esp32s3
PORT ?= /dev/cu.usbmodem*
BAUD = 115200
PROJECT_NAME = a2fpga_esp32

# Arduino CLI executable (assumes it's in PATH)
ARDUINO_CLI = arduino-cli

# Board revision (see board_pins.h): 103 = 1.0a3 (USB-C DP, N4R2 module),
# 102 = 1.0a2/1.0a2a (N8 module), 225 = a2p25 displayport1 (N4R2).
# Set BOARD_REV=102 to build for old boards.
# a2p25 only: DP_TEST=1 (default) builds the dp_test-bitstream variant
# (IO10 = HPD to FPGA ball B2, UART1 RX on IO11 = FPGA telemetry, no OSPI);
# DP_TEST=0 builds for an OSPI-speaking core.
# NOTE: all revs share ./build; arduino-cli rebuilds fully when the flags
# change, but run 'make clean' if in doubt before switching BOARD_REV.
BOARD_REV ?= 103
DP_TEST ?= 1
ifeq ($(BOARD_REV),102)
FQBN = esp32:esp32:$(BOARD):USBMode=hwcdc,CDCOnBoot=cdc,CPUFreq=240,FlashSize=8M,PSRAM=disabled,PartitionScheme=default_8MB
REV_FLAGS = --build-property compiler.c.extra_flags=-DA2MEGA_BOARD_REV=102 \
            --build-property compiler.cpp.extra_flags=-DA2MEGA_BOARD_REV=102
else ifeq ($(BOARD_REV),225)
# a2p25 displayport1: same N4R2 module + partition rationale as 1.0a3 below.
FQBN = esp32:esp32:$(BOARD):USBMode=hwcdc,CDCOnBoot=cdc,CPUFreq=240,FlashSize=4M,PSRAM=enabled,PartitionScheme=default
REV_FLAGS = --build-property "compiler.c.extra_flags=-DA2MEGA_BOARD_REV=225 -DA2P25_DP_TEST=$(DP_TEST)" \
            --build-property "compiler.cpp.extra_flags=-DA2MEGA_BOARD_REV=225 -DA2P25_DP_TEST=$(DP_TEST)"
else
# no_ota partitions: 2 MB app + 1.875 MB "spiffs" (LittleFS) — the largest
# FS a 4 MB part allows with app headroom. No OTA pair: the ESP32 reflashes
# over its own USB-C. FPGA update-from-file streams the bitstream to JTAG
# (staging a ~2.6 MB image in MCU flash is wasteful and doesn't fit here);
# PC-driven JTAG via the bridge is unaffected. The board footprint accepts
# either MINI variant — an N8-fitted 1.0a3 builds with BOARD_REV=103 plus
# the 102 flash settings if that ever comes up.
FQBN = esp32:esp32:$(BOARD):USBMode=hwcdc,CDCOnBoot=cdc,CPUFreq=240,FlashSize=4M,PSRAM=enabled,PartitionScheme=default
REV_FLAGS =
endif

# Source files
SKETCH = a2fpga_esp32.ino
CPP_FILES = a2fpga_jtag.cpp usbc_glue.cpp usbhost.cpp usbstorage.cpp
C_FILES = fwupdate.c a2fpga_ospi_link.c a2fpga_spi_service.c fpga_link.c fpga_screen.c wedge_watch.c \
          osd_console.c menu.c settings.c disk.c gcr_dsk.c w5100.c \
          wifi_bridge.c usbeth.c usbeth_proto.c net_uplink.c \
          fpga_jtag.c fpgaupdate.c fpgastream.c ftpd.c telnetd.c \
          fusb302.c usbc_port.c esp32s3_integration.c sn75dp130.c gs_socket.c
HEADER_FILES = a2fpga_jtag.h a2fpga_ospi_link.h a2fpga_spi_service.h wedge_watch.h \
               a2fpga_regs.h fpga_link.h fpga_screen.h osd_console.h menu.h \
               net_status.h settings.h disk.h gcr_dsk.h w5100.h \
               wifi_bridge.h usbeth.h usbeth_proto.h net_uplink.h \
               fpga_jtag.h fpgaupdate.h fpgastream.h ftpd.h telnetd.h \
               board_pins.h fusb302.h usb_pd.h usbc_port.h usbc_glue.h \
               esp32s3_integration.h sn75dp130.h usbhost.h usbstorage.h fwupdate.h gs_socket.h
ALL_SOURCES = $(SKETCH) $(CPP_FILES) $(C_FILES) $(HEADER_FILES)

# Default target
.PHONY: all
all: compile

# Initialize Arduino CLI and install ESP32 core
.PHONY: init
init:
	$(ARDUINO_CLI) core update-index
	$(ARDUINO_CLI) core install esp32:esp32

# Compile the sketch and all source files
.PHONY: compile
compile:
	@echo "Compiling $(PROJECT_NAME) with files: $(ALL_SOURCES)"
	$(ARDUINO_CLI) compile --fqbn $(FQBN) $(REV_FLAGS) --build-path ./build $(SKETCH)

# Upload to ESP32
.PHONY: upload
upload: compile
	$(ARDUINO_CLI) upload --fqbn $(FQBN) --port $(PORT) --input-dir ./build .

# Monitor serial output
.PHONY: monitor
monitor:
	$(ARDUINO_CLI) monitor --port $(PORT) --config baudrate=$(BAUD)

# Upload and then monitor
.PHONY: flash
flash: upload monitor

# Clean build artifacts
.PHONY: clean
clean:
	rm -rf build/

# Check that all source files exist
.PHONY: check-sources
check-sources:
	@echo "Checking source files..."
	@for file in $(ALL_SOURCES); do \
		if [ ! -f "$$file" ]; then \
			echo "Error: Source file $$file not found"; \
			exit 1; \
		else \
			echo "OK $$file"; \
		fi; \
	done
	@echo "All source files found."

# List available ports
.PHONY: ports
ports:
	$(ARDUINO_CLI) board list

# Show board details
.PHONY: board-info
board-info:
	$(ARDUINO_CLI) board details --fqbn $(FQBN)

# Install required libraries (if any)
.PHONY: install-libs
install-libs:
	@echo "No additional libraries required - using ESP32 Arduino Core built-ins"

# Help target
.PHONY: help
help:
	@echo "Available targets:"
	@echo "  init        - Initialize Arduino CLI and install ESP32 core"
	@echo "  compile     - Compile the sketch and all source files"
	@echo "  upload      - Upload to ESP32 (set PORT= to override)"
	@echo "  monitor     - Monitor serial output"
	@echo "  flash       - Upload and monitor"
	@echo "  clean       - Clean build artifacts"
	@echo "  check-sources - Verify all source files exist"
	@echo "  ports       - List available serial ports"
	@echo "  board-info  - Show ESP32-S3 board information"
	@echo "  install-libs- Install required libraries"
	@echo "  help        - Show this help"
	@echo ""
	@echo "Usage examples:"
	@echo "  make init           # First time setup"
	@echo "  make compile        # Build only"
	@echo "  make BOARD_REV=225 compile          # a2p25 displayport1 (dp_test mode)"
	@echo "  make BOARD_REV=225 DP_TEST=0 compile # a2p25, OSPI core"
	@echo "  make PORT=/dev/ttyUSB0 upload  # Upload to specific port"
	@echo "  make flash          # Upload and monitor"
