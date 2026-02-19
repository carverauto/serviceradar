#!/bin/bash
set -e

if ! getent group serviceradar >/dev/null; then
    groupadd --system serviceradar
fi

if ! id -u serviceradar >/dev/null 2>&1; then
    useradd --system --no-create-home --shell /usr/sbin/nologin -g serviceradar serviceradar
fi

mkdir -p /var/log/serviceradar
mkdir -p /var/lib/serviceradar
chown serviceradar:serviceradar /var/log/serviceradar
chown serviceradar:serviceradar /var/lib/serviceradar

chmod 755 /usr/local/bin/serviceradar-bmp-collector
chmod 644 /etc/serviceradar/bmp-collector.json
chown serviceradar:serviceradar /usr/local/bin/serviceradar-bmp-collector
chown serviceradar:serviceradar /etc/serviceradar/bmp-collector.json

if [ -x /usr/local/bin/serviceradar-bmp-collector ]; then
    setcap cap_net_bind_service=+ep /usr/local/bin/serviceradar-bmp-collector || {
        echo "Warning: Failed to set cap_net_bind_service on /usr/local/bin/serviceradar-bmp-collector"
        echo "  sudo setcap cap_net_bind_service=+ep /usr/local/bin/serviceradar-bmp-collector"
    }
fi

systemctl daemon-reload
systemctl enable serviceradar-bmp-collector
if ! systemctl start serviceradar-bmp-collector; then
    echo "WARNING: Failed to start serviceradar-bmp-collector service. Please check the logs."
    echo "Run: journalctl -u serviceradar-bmp-collector.service"
fi

echo "ServiceRadar BMP Collector installed successfully!"
