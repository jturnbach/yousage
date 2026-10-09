#!/bin/bash
# Installs (or updates) the YouSage remote source as a systemd service.
#   sudo Server/install.sh
# Publishing it on the tailnet is a separate, explicit step: see README.md.
set -euo pipefail
cd "$(dirname "$0")"

if [ "$(id -u)" -ne 0 ]; then
    echo "Run with sudo." >&2
    exit 1
fi

install -d -m 0755 /usr/local/lib/yousage-server
install -m 0644 yousage_server.py /usr/local/lib/yousage-server/yousage_server.py
install -m 0644 yousage-server.service /etc/systemd/system/yousage-server.service
# Local plan-limits CLI (runs as the calling user; see docs/limits-source.md).
install -m 0755 yousage_limits.py /usr/local/bin/yousage-limits

systemctl daemon-reload
systemctl enable yousage-server.service
systemctl restart yousage-server.service
sleep 1
systemctl --no-pager --lines=5 status yousage-server.service
