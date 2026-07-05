# ESP32-S3 Arduino CLI Makefile
# A2FPGA ESP32 co-processor firmware (a2mega board)

# Configuration - ESP32-S3-MINI-1-N8 module on the a2mega (8M flash, no PSRAM)
BOARD = esp32s3
PORT ?= /dev/cu.usbmodem*
BAUD = 115200
PROJECT_NAME = a2fpga_esp32

# Arduino CLI executable (assumes it's in PATH)
ARDUINO_CLI = arduino-cli

# Board FQBN with specific settings
FQBN = esp32:esp32:$(BOARD):USBMode=hwcdc,CDCOnBoot=cdc,CPUFreq=240,FlashSize=8M,PSRAM=disabled,PartitionScheme=default_8MB

# Source files
SKETCH = a2fpga_esp32.ino
CPP_FILES = a2fpga_jtag.cpp
C_FILES = a2fpga_ospi_link.c a2fpga_spi_service.c fpga_link.c fpga_screen.c \
          osd_console.c menu.c settings.c disk.c gcr_dsk.c w5100.c \
          wifi_bridge.c fpga_jtag.c fpgaupdate.c
HEADER_FILES = a2fpga_jtag.h a2fpga_ospi_link.h a2fpga_spi_service.h \
               a2fpga_regs.h fpga_link.h fpga_screen.h osd_console.h menu.h \
               net_status.h settings.h disk.h gcr_dsk.h w5100.h \
               wifi_bridge.h fpga_jtag.h fpgaupdate.h
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
	$(ARDUINO_CLI) compile --fqbn $(FQBN) --build-path ./build $(SKETCH)

# Upload to ESP32
.PHONY: upload
upload: compile
	$(ARDUINO_CLI) upload --fqbn $(FQBN) --port $(PORT) .

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
	@echo "  make PORT=/dev/ttyUSB0 upload  # Upload to specific port"
	@echo "  make flash          # Upload and monitor"
