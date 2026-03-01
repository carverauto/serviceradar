#!/bin/bash

set -e

# Stop and disable the service if it's running
if systemctl is-active --quiet serviceradar-faker; then
    echo "Stopping serviceradar-faker service..."
    systemctl stop serviceradar-faker
fi

if systemctl is-enabled --quiet serviceradar-faker; then
    echo "Disabling serviceradar-faker service..."
    systemctl disable serviceradar-faker
fi

# Remove systemd service file
if [ -f /etc/systemd/system/serviceradar-faker.service ]; then
    rm -f /etc/systemd/system/serviceradar-faker.service
    systemctl daemon-reload
fi

echo "ServiceRadar Faker service stopped and disabled."