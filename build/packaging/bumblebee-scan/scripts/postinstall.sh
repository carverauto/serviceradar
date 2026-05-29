#!/bin/sh
set -e

if ! getent group serviceradar >/dev/null; then
    groupadd --system serviceradar
fi

if ! id -u serviceradar >/dev/null 2>&1; then
    useradd --system --no-create-home --shell /usr/sbin/nologin -g serviceradar serviceradar
fi

install -d -m 0755 /etc/serviceradar
install -d -o root -g serviceradar -m 0770 /var/lib/serviceradar/bumblebee
install -d -o root -g serviceradar -m 0770 /var/lib/serviceradar/bumblebee/cache
install -d -o root -g serviceradar -m 0770 /var/lib/serviceradar/bumblebee/catalog
install -d -o root -g serviceradar -m 0770 /var/lib/serviceradar/bumblebee/profile
install -d -o root -g serviceradar -m 0750 /var/lib/serviceradar/bumblebee/spool
install -d -o root -g serviceradar -m 0750 /var/lib/serviceradar/bumblebee/spool/runs
install -d -o root -g serviceradar -m 0770 /var/lib/serviceradar/bumblebee/tmp

if [ -f /etc/serviceradar/bumblebee-scan.json ]; then
    chown root:serviceradar /etc/serviceradar/bumblebee-scan.json
    chmod 0640 /etc/serviceradar/bumblebee-scan.json
fi

if [ -x /usr/local/lib/serviceradar/bin/serviceradar-bumblebee-scan ]; then
    chown root:root /usr/local/lib/serviceradar/bin/serviceradar-bumblebee-scan
    chmod 0755 /usr/local/lib/serviceradar/bin/serviceradar-bumblebee-scan
fi

if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload || true
fi

cat <<'EOF'
ServiceRadar Bumblebee scanner add-on installed.
Enable it after configuring /etc/serviceradar/bumblebee-scan.json with:
  systemctl enable --now serviceradar-bumblebee-scan.timer
EOF
