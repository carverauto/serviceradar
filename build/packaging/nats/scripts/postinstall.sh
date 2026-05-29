#!/bin/sh
set -e

# Create serviceradar group if it doesn't exist
if ! getent group serviceradar >/dev/null; then
    groupadd --system serviceradar
fi

# Create serviceradar user if it doesn't exist
if ! id -u serviceradar >/dev/null 2>&1; then
    useradd --system --no-create-home --shell /usr/sbin/nologin -g serviceradar serviceradar
fi

# Create NATS user if it doesn't exist
if ! id -u nats >/dev/null 2>&1; then
    useradd --system --no-create-home --shell /usr/sbin/nologin -g serviceradar nats
fi

# Create required directories
mkdir -p /etc/serviceradar
mkdir -p /var/lib/serviceradar

# Set permissions
chown -R serviceradar:serviceradar /etc/serviceradar
chmod -R 755 /etc/serviceradar
# if the certs dir exists, set permissions
if [ -d "/etc/serviceradar/certs" ]; then
    chown -R serviceradar:serviceradar /etc/serviceradar/certs
    chmod -R 755 /etc/serviceradar/certs
fi

# Render the partition_id placeholder in the NATS server / cloud-template
# configs (B-5 sub-issue 2). The literal token `__SERVICERADAR_PARTITION_ID__`
# is emitted by the shipped conf templates; it MUST be substituted with the
# partition_id of this deployment so the core user's PublishAllow scopes
# `flow.attributed.<partition_id>` correctly (the deny-wildcard on
# `flow.attributed.>` is a fail-safe ceiling that requires the per-partition
# allow to be in place to permit any publish at all).
#
# Source of truth: SERVICERADAR_OTX_PARTITION. We honor either an exported
# env var (set by the installer / config-management tool) or a sysconfig-
# style file at /etc/serviceradar/nats.env. This matches the
# `EnvironmentFile=-/etc/serviceradar/*.env` convention used by every other
# ServiceRadar systemd unit (core-elx, web-ng, agent-gateway, etc.). The
# value defaults to "default" — the same fallback used by
# elixir/serviceradar_core/config/runtime.exs and go/pkg/cli/nats_bootstrap.go.
#
# We use `sed -i` (in coreutils on every base distro) rather than envsubst
# (which lives in gettext-base / gettext-envsubst and would add a package
# dep) because (a) the placeholder is a single literal token chosen to be
# sed-safe and (b) /etc/nats/nats-server.conf ships as config(noreplace),
# so on upgrade the operator-edited file is preserved. The `grep -q` guard
# makes substitution idempotent: once the placeholder is gone, re-runs
# (e.g. apt reinstall) are no-ops and will not clobber a rendered file.
if [ -f /etc/serviceradar/nats.env ]; then
    # shellcheck disable=SC1091
    . /etc/serviceradar/nats.env
fi
: "${SERVICERADAR_OTX_PARTITION:=default}"
for nats_conf in /etc/nats/nats-server.conf /etc/nats/templates/nats-cloud.conf; do
    if [ -f "$nats_conf" ] && grep -q '__SERVICERADAR_PARTITION_ID__' "$nats_conf"; then
        sed -i "s|__SERVICERADAR_PARTITION_ID__|${SERVICERADAR_OTX_PARTITION}|g" "$nats_conf"
    fi
done

# Only try to manage service if it exists
if [ -f "/lib/systemd/system/serviceradar-${component_dir}.service" ]; then
    # Reload systemd
    systemctl daemon-reload

    # Enable and start service
    systemctl enable "serviceradar-${component_dir}"
    systemctl start "serviceradar-${component_dir}"
fi