#!/bin/sh
set -e

if command -v systemctl >/dev/null 2>&1; then
    systemctl stop serviceradar-bumblebee-scan.timer >/dev/null 2>&1 || true
    systemctl stop serviceradar-bumblebee-scan.service >/dev/null 2>&1 || true
    systemctl disable serviceradar-bumblebee-scan.timer >/dev/null 2>&1 || true
    systemctl daemon-reload >/dev/null 2>&1 || true
fi
