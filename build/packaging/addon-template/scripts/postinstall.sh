#!/bin/sh
# Post-install for an os-package native add-on. DORMANT BY DESIGN: it prepares the
# user/group, state dirs, and permissions, then daemon-reloads — but it deliberately
# does NOT `systemctl enable`/`start` anything. The ServiceRadar agent activates the
# add-on (enables the unit / launches the go-plugin) only when it is enabled for this
# host in Edge Ops. Enabling here would bypass per-agent targeting and approval.
set -e

if ! getent group serviceradar >/dev/null; then
    groupadd --system serviceradar
fi

if ! id -u serviceradar >/dev/null 2>&1; then
    useradd --system --no-create-home --shell /usr/sbin/nologin -g serviceradar serviceradar
fi

install -d -m 0755 /etc/serviceradar
install -d -o root -g serviceradar -m 0750 /var/lib/serviceradar/example-addon
install -d -o root -g serviceradar -m 0750 /var/lib/serviceradar/example-addon/spool

if [ -f /etc/serviceradar/serviceradar-addon-example.json ]; then
    chown root:serviceradar /etc/serviceradar/serviceradar-addon-example.json
    chmod 0640 /etc/serviceradar/serviceradar-addon-example.json
fi

if [ -x /usr/local/lib/serviceradar/bin/serviceradar-addon-example ]; then
    chown root:root /usr/local/lib/serviceradar/bin/serviceradar-addon-example
    chmod 0755 /usr/local/lib/serviceradar/bin/serviceradar-addon-example
fi

if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload || true
fi

cat <<'EOF'
ServiceRadar Example native add-on installed (inactive).
It activates automatically once enabled for this agent in Edge Ops. To run it
standalone for testing only (bypasses Edge Ops governance):
  systemctl enable --now serviceradar-addon-example.timer
EOF
