cmake_minimum_required(VERSION 3.15)

include(proj.conf)

find_package(bouffalo_sdk REQUIRED HINTS $ENV{BL_SDK_BASE})

# Pull in shared FPGA-SPI sources from the FT2232 firmware (../firmware) so we
# do not duplicate them. Only fpga_spi/fpga_screen are reused; the device-mode
# (FTDI/JTAG/UART/CLI) sources are intentionally excluded from the host build.
sdk_add_include_directories(. ../firmware)
# lwIP base config (SDK's reference lwipopts.h).
sdk_add_include_directories($ENV{BL_SDK_BASE}/components/net/lwip/lwip/lwip-port/config)
# CRITICAL: the SDK lwipopts defaults PBUF_POOL_SIZE to 0 unless CFG_ETHERNET_ENABLE
# is defined, which makes pbuf_alloc(PBUF_POOL) fail for EVERY received frame
# (USB-Ethernet RX silently dropped -> no DHCP). Give it an Ethernet-sized pbuf
# pool. (lwipopts uses #if !defined / #ifndef, so these compile defs win.)
sdk_add_compile_definitions(-DPBUF_POOL_SIZE=16 -DPBUF_POOL_BUFSIZE=1600)

target_sources(app PRIVATE
    usbh_xinput.c
    ../firmware/fpga_spi.c
    ../firmware/fpga_screen.c
)
sdk_set_main_file(main.c)

project(a2n20_bl616_host)
