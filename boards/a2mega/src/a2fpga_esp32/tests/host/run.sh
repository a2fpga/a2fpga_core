#!/usr/bin/env bash
# Host tests for the ESP32 firmware's pure (no ESP-IDF) modules:
#   - the USB-C stale-session guard (usbc_port.c)
#   - the USB-Ethernet protocol helpers (usbeth_proto.c: CDC descriptors,
#     ECM MAC string, NCM NTB16)
#   - the hub-port enumeration retry ladder (usbhub_retry.c)
set -e
cd "$(dirname "$0")"
cc -std=c11 -Wall -Wextra -I../.. -I. \
   -o /tmp/test_stale_guard \
   test_stale_guard.c mock_fusb302.c ../../usbc_port.c
/tmp/test_stale_guard
cc -std=c11 -Wall -Wextra -I../.. -I. \
   -o /tmp/test_usbeth_proto \
   test_usbeth_proto.c ../../usbeth_proto.c
/tmp/test_usbeth_proto
cc -std=c11 -Wall -Wextra -I../.. -I. \
   -o /tmp/test_usbhub_retry \
   test_usbhub_retry.c ../../usbhub_retry.c
/tmp/test_usbhub_retry
