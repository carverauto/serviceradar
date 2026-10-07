#!/bin/sh
set -e

postinstall_root="${SERVICERADAR_POSTINSTALL_ROOT:-}"

root_path() {
    printf '%s%s' "$postinstall_root" "$1"
}

serviceradar_etc_dir="$(root_path /etc/serviceradar)"

validate_partition_id() {
    case "$1" in
        ""|*[!A-Za-z0-9_.-]*)
            echo "Error: SERVICERADAR_OTX_PARTITION must match [A-Za-z0-9_.-]+" >&2
            return 1
            ;;
    esac
}

# Create serviceradar group if it doesn't exist
if [ -z "$postinstall_root" ]; then
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
fi

# Older packages made this shared configuration directory service-owned.
# Repair the directory itself without changing ownership of any package's files.
if [ -L "$serviceradar_etc_dir" ]; then
    echo "Error: refusing symlinked $serviceradar_etc_dir" >&2
    exit 1
fi
if [ -d "$serviceradar_etc_dir" ]; then
    if [ -z "$postinstall_root" ]; then
        chown root:root "$serviceradar_etc_dir"
    fi
    chmod 755 "$serviceradar_etc_dir"
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
# style assignment in /etc/serviceradar/nats.env. This matches the
# `EnvironmentFile=-/etc/serviceradar/*.env` convention used by every other
# ServiceRadar systemd unit (core-elx, agent-gateway, etc.). The
# value defaults to "default" — the same fallback used by
# elixir/serviceradar_core/config/runtime.exs and go/pkg/cli/nats_bootstrap.go.
#
# We use `sed` rather than envsubst (which lives in gettext-base /
# gettext-envsubst and would add a package dep) because the placeholder is
# a single literal token chosen to be sed-safe. The rendered file is written
# through the existing inode so /etc/nats/nats-server.conf keeps its package
# config(noreplace) ownership and mode. The `grep -q` guard makes
# substitution idempotent: once the placeholder is gone, re-runs (e.g. apt
# reinstall) are no-ops and will not clobber a rendered file.
nats_env="$serviceradar_etc_dir/nats.env"
if [ -L "$nats_env" ]; then
    echo "Error: refusing symlinked $nats_env" >&2
    exit 1
fi
if [ -f "$nats_env" ]; then
    if ! file_partition="$(awk '
        function trim(value) {
            sub(/^[[:space:]]+/, "", value)
            sub(/[[:space:]]+$/, "", value)
            return value
        }
        {
            line = $0
            sub(/^[[:space:]]+/, "", line)
            if (line == "" || line ~ /^#/) next
            sub(/^export[[:space:]]+/, "", line)
            if (line ~ /^SERVICERADAR_OTX_PARTITION[[:space:]]*=/) {
                count++
                sub(/^SERVICERADAR_OTX_PARTITION[[:space:]]*=[[:space:]]*/, "", line)
                value = trim(line)
                first = substr(value, 1, 1)
                last = substr(value, length(value), 1)
                if ((first == "\"" && last == "\"") || (first == "\047" && last == "\047")) {
                    value = substr(value, 2, length(value) - 2)
                } else if (first == "\"" || last == "\"" || first == "\047" || last == "\047") {
                    invalid = 1
                }
                partition = value
            } else if (line ~ /^SERVICERADAR_OTX_PARTITION([[:space:]]|$)/) {
                invalid = 1
            }
        }
        END {
            if (count > 1 || invalid) exit 1
            if (count == 1) print partition
        }
    ' "$nats_env")"; then
        echo "Error: invalid SERVICERADAR_OTX_PARTITION assignment in $nats_env" >&2
        exit 1
    fi
    if [ -n "$file_partition" ]; then
        SERVICERADAR_OTX_PARTITION="$file_partition"
    elif grep -Eq '^[[:space:]]*(export[[:space:]]+)?SERVICERADAR_OTX_PARTITION[[:space:]]*=' "$nats_env"; then
        SERVICERADAR_OTX_PARTITION=""
    fi
fi
: "${SERVICERADAR_OTX_PARTITION:=default}"
validate_partition_id "$SERVICERADAR_OTX_PARTITION"
for nats_conf in "$(root_path /etc/nats/nats-server.conf)" "$(root_path /etc/nats/templates/nats-cloud.conf)"; do
    if [ -f "$nats_conf" ] && grep -q '__SERVICERADAR_PARTITION_ID__' "$nats_conf"; then
        tmp_conf="${nats_conf}.tmp.$$"
        sed "s|__SERVICERADAR_PARTITION_ID__|${SERVICERADAR_OTX_PARTITION}|g" "$nats_conf" > "$tmp_conf"
        cat "$tmp_conf" > "$nats_conf"
        rm -f "$tmp_conf"
    fi
done

# Only try to manage service if it exists
if [ -z "$postinstall_root" ] && [ -f "/lib/systemd/system/serviceradar-${component_dir}.service" ]; then
    # Reload systemd
    systemctl daemon-reload

    # Enable and start service
    systemctl enable "serviceradar-${component_dir}"
    systemctl start "serviceradar-${component_dir}"
fi
