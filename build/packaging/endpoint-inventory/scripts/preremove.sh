#!/bin/sh
set -e

if command -v systemctl >/dev/null 2>&1; then
    systemctl stop serviceradar-endpoint-inventory.timer >/dev/null 2>&1 || true
    systemctl stop serviceradar-endpoint-inventory.service >/dev/null 2>&1 || true
    systemctl disable serviceradar-endpoint-inventory.timer >/dev/null 2>&1 || true
    systemctl daemon-reload >/dev/null 2>&1 || true
fi
