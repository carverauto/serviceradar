#!/bin/bash
set -e

systemctl daemon-reload
systemctl stop serviceradar-bmp-collector >/dev/null 2>&1 || true
systemctl disable serviceradar-bmp-collector >/dev/null 2>&1 || true

exit 0
