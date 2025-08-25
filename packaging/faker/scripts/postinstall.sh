#!/bin/bash

set -e

# Create serviceradar user if it doesn't exist
if ! id -u serviceradar &>/dev/null; then
    useradd -r -s /sbin/nologin -d /var/lib/serviceradar -c "ServiceRadar Service Account" serviceradar
fi

# Create necessary directories
mkdir -p /etc/serviceradar
mkdir -p /var/lib/serviceradar/faker
mkdir -p /var/log/serviceradar

# Set ownership and permissions
chown -R serviceradar:serviceradar /var/lib/serviceradar/faker
chown -R serviceradar:serviceradar /var/log/serviceradar
chmod 755 /var/lib/serviceradar/faker
chmod 755 /var/log/serviceradar

# The systemd service file should already be in place from the package
# Just reload systemd
systemctl daemon-reload

# Enable service but don't start it (let the user decide when to start)
if [ -f /lib/systemd/system/serviceradar-faker.service ]; then
    systemctl enable serviceradar-faker.service
fi

echo "ServiceRadar Faker service installed successfully."
echo "To start the service, run: systemctl start serviceradar-faker"
echo "To check status, run: systemctl status serviceradar-faker"
echo "Configuration file: /etc/serviceradar/faker.json"
echo "Data directory: /var/lib/serviceradar/faker"
echo "Log file: /var/log/serviceradar/faker.log"