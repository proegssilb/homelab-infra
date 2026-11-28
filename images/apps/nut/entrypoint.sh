#!/bin/sh
# Start the UPS driver(s) from ups.conf, then upsd in the foreground (the
# container's main process). If the driver can't reach the UPS, exit: the Quadlet
# restarts the container, which also picks up a re-enumerated USB device node.
set -e
install -d -o nut -g nut -m 0770 /run/nut
upsdrvctl -u nut start
exec upsd -F -u nut
