#!/bin/sh
set -e

if [ -f "/lib/systemd/system/serviceradar-bumblebee-scan.timer" ]; then
    systemctl stop serviceradar-bumblebee-scan.timer || true
    systemctl disable serviceradar-bumblebee-scan.timer || true
fi

# Only try to manage service if it exists
if [ -f "/lib/systemd/system/serviceradar-${component_dir}.service" ]; then
    # Stop and disable service
    systemctl stop "serviceradar-${component_dir}"
    systemctl disable "serviceradar-${component_dir}"
fi
