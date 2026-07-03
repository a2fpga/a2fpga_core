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
# Multi-threaded SPI access (overlay writers + W5100 bridge task) -> enable the
# FreeRTOS mutex in the shared fpga_spi.c. The device build omits this (no FreeRTOS).
sdk_add_compile_definitions(-DFPGA_SPI_THREADSAFE)
# DIAGNOSTIC: intercept the SDK's exception_entry (it only printf's the fault to a
# UART we can't see) so __wrap_exception_entry can paint mcause/mepc on the overlay.
sdk_add_link_options(-Wl,--wrap=exception_entry)

# The host build routes FatFS disk_* between SD and USB in diskio_host.c, so
# sdmm.c must export its SD logic as mmc_disk_* instead of owning disk_*.
sdk_add_compile_definitions(-DFATFS_EXTERNAL_DISKIO)

target_sources(app PRIVATE
    usbh_xinput.c
    w5100.c
    disk.c
    diskio_host.c
    osd_console.c
    settings.c
    menu.c
    ../firmware/gcr_dsk.c
    ../firmware/fpga_spi.c
    ../firmware/fpga_screen.c
    # Disk II image serving: FatFS + SD-over-FPGA-SPI-tunnel (same set the FT2232
    # build compiles; diskio.c is intentionally excluded -- diskio_host.c provides
    # the FatFS disk_* router that dispatches to SD (sdmm.c) or USB (usbh_msc)).
    ../firmware/sdmm.c
    ../firmware/ff.c
    ../firmware/ffunicode.c
    ../firmware/fpga_sd.c
)
sdk_set_main_file(main.c)

project(a2n20_bl616_host)
