#!/bin/sh
set -e

# Only try to manage service if it exists
if [ -f "/lib/systemd/system/serviceradar-${component_dir}.service" ]; then
    # Stop and disable service
    systemctl stop "serviceradar-${component_dir}"
    systemctl disable "serviceradar-${component_dir}"
fi