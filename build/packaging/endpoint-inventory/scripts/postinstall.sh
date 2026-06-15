#!/bin/sh
set -e

if ! getent group serviceradar >/dev/null; then
    groupadd --system serviceradar
fi

if ! id -u serviceradar >/dev/null 2>&1; then
    useradd --system --no-create-home --shell /usr/sbin/nologin -g serviceradar serviceradar
fi

install -d -m 0755 /etc/serviceradar
# setgid (2) + group-write so the root scanner and the non-root serviceradar
# agent can both write spool entries, cache manifests, runtime profiles, and
# upload markers into the shared serviceradar-group dirs.
install -d -o root -g serviceradar -m 2770 /var/lib/serviceradar/endpoint-inventory
install -d -o root -g serviceradar -m 2770 /var/lib/serviceradar/endpoint-inventory/profile
install -d -o root -g serviceradar -m 2770 /var/lib/serviceradar/endpoint-inventory/cache
install -d -o root -g serviceradar -m 2770 /var/lib/serviceradar/endpoint-inventory/spool
install -d -o root -g serviceradar -m 2770 /var/lib/serviceradar/endpoint-inventory/spool/runs
install -d -o root -g serviceradar -m 2770 /var/lib/serviceradar/endpoint-inventory/tmp

# Re-assert modes on upgrade: `install -d` leaves the mode of pre-existing dirs
# untouched, so older installs that created these at 0750 (and a root-owned
# cache/ dir) must be relaxed to setgid group-writable so the non-root agent can
# write upload markers and clear pending-upload.json.
for d in \
    /var/lib/serviceradar/endpoint-inventory \
    /var/lib/serviceradar/endpoint-inventory/profile \
    /var/lib/serviceradar/endpoint-inventory/cache \
    /var/lib/serviceradar/endpoint-inventory/spool \
    /var/lib/serviceradar/endpoint-inventory/spool/runs \
    /var/lib/serviceradar/endpoint-inventory/tmp; do
    if [ -d "$d" ]; then
        chown root:serviceradar "$d" || true
        chmod 2770 "$d" || true
    fi
done

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
