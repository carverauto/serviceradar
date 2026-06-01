#!/bin/sh
set -e

if ! getent group serviceradar >/dev/null; then
    groupadd --system serviceradar
fi

if ! id -u serviceradar >/dev/null 2>&1; then
    useradd --system --no-create-home --shell /usr/sbin/nologin -g serviceradar serviceradar
fi

install -d -m 0755 /etc/serviceradar
install -d -o root -g serviceradar -m 0770 /var/lib/serviceradar/endpoint-inventory
install -d -o root -g serviceradar -m 0770 /var/lib/serviceradar/endpoint-inventory/profile
install -d -o root -g serviceradar -m 0750 /var/lib/serviceradar/endpoint-inventory/spool
install -d -o root -g serviceradar -m 0750 /var/lib/serviceradar/endpoint-inventory/spool/runs
install -d -o root -g serviceradar -m 0770 /var/lib/serviceradar/endpoint-inventory/tmp

if [ -f /etc/serviceradar/endpoint-inventory.json ]; then
    chown root:serviceradar /etc/serviceradar/endpoint-inventory.json
    chmod 0640 /etc/serviceradar/endpoint-inventory.json
fi

if [ -x /usr/local/lib/serviceradar/bin/serviceradar-endpoint-inventory ]; then
    chown root:root /usr/local/lib/serviceradar/bin/serviceradar-endpoint-inventory
    chmod 0755 /usr/local/lib/serviceradar/bin/serviceradar-endpoint-inventory
fi

if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload || true
fi

cat <<'EOF'
ServiceRadar endpoint software inventory add-on installed.
Enable it after configuring /etc/serviceradar/endpoint-inventory.json with:
  systemctl enable --now serviceradar-endpoint-inventory.timer
EOF
