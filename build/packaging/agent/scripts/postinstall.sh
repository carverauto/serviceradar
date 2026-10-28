#!/bin/sh
set -e

postinstall_root="${SERVICERADAR_POSTINSTALL_ROOT:-}"
service_owner="${SERVICERADAR_POSTINSTALL_OWNER:-serviceradar:serviceradar}"

root_path() {
    printf '%s%s' "$postinstall_root" "$1"
}

apply_owner() {
    owner="$1"
    target="$2"
    if [ -z "$postinstall_root" ] || [ -n "${SERVICERADAR_POSTINSTALL_OWNER:-}" ]; then
        chown -h "$owner" "$target"
    fi
}

lock_runtime_dir() {
    dir="$1"
    mode="$2"
    if [ -L "$dir" ]; then
        echo "Error: refusing symlinked $dir" >&2
        exit 1
    fi
    if [ -e "$dir" ] && [ ! -d "$dir" ]; then
        echo "Error: expected directory at $dir" >&2
        exit 1
    fi
    mkdir -p "$dir"
    if [ -L "$dir" ] || [ ! -d "$dir" ]; then
        echo "Error: refusing non-directory $dir" >&2
        exit 1
    fi
    apply_owner root:root "$dir"
    chmod "$mode" "$dir"
}

own_runtime_dir() {
    dir="$1"
    mode="$2"
    if [ -L "$dir" ] || [ ! -d "$dir" ]; then
        echo "Error: refusing non-directory $dir" >&2
        exit 1
    fi
    apply_owner "$service_owner" "$dir"
    chmod "$mode" "$dir"
}

if [ -z "$postinstall_root" ]; then
    # Create serviceradar group if it doesn't exist
    if ! getent group serviceradar >/dev/null; then
        groupadd --system serviceradar
    fi

    # Create serviceradar user if it doesn't exist
    if ! id -u serviceradar >/dev/null 2>&1; then
        useradd --system --no-create-home --shell /usr/sbin/nologin -g serviceradar serviceradar
    fi
fi

serviceradar_etc_dir="$(root_path /etc/serviceradar)"
serviceradar_var_dir="$(root_path /var/lib/serviceradar)"
agent_runtime_dir="$(root_path /var/lib/serviceradar/agent)"
agent_tmp_dir="$(root_path /var/lib/serviceradar/agent/tmp)"
agent_versions_dir="$(root_path /var/lib/serviceradar/agent/versions)"
agent_seed_dir="$(root_path /var/lib/serviceradar/agent/versions/seed-installed)"
addons_dir="$(root_path /usr/lib/serviceradar/addons)"

# Create required directories
mkdir -p "$serviceradar_etc_dir"
mkdir -p "$serviceradar_var_dir/cache"
mkdir -p "$addons_dir"
chmod 755 "$addons_dir"
apply_owner root:root "$addons_dir"

# Repair or create the agent runtime directory skeleton without recursive chown.
# Lock parents to root:root 0755 top-down before creating/checking children so a
# running service process cannot swap an intermediate path with a symlink, then
# restore service ownership bottom-up while each parent remains root-locked.
lock_runtime_dir "$serviceradar_var_dir" 0755
lock_runtime_dir "$agent_runtime_dir" 0755
lock_runtime_dir "$agent_tmp_dir" 0755
lock_runtime_dir "$agent_versions_dir" 0755
lock_runtime_dir "$agent_seed_dir" 0755
rm -f "$agent_seed_dir/serviceradar-agent.new"
own_runtime_dir "$agent_seed_dir" 0755
own_runtime_dir "$agent_versions_dir" 0755
own_runtime_dir "$agent_tmp_dir" 0755
own_runtime_dir "$agent_runtime_dir" 0755
own_runtime_dir "$serviceradar_var_dir" 0755

# Endpoint-inventory state dirs: the agent writes its runtime profile here as the
# serviceradar user. Create and own this subtree explicitly so a stale root-owned
# directory cannot permanently defer the config-version ack (fj #4301).
mkdir -p "$serviceradar_var_dir/endpoint-inventory/profile"
mkdir -p "$serviceradar_var_dir/endpoint-inventory/spool"
mkdir -p "$serviceradar_var_dir/endpoint-inventory/cache"
mkdir -p "$serviceradar_var_dir/endpoint-inventory/tmp"
mkdir -p "$serviceradar_etc_dir/sidecars"

# Create checkers/sweep directory if it doesnt already exist
mkdir -p "$serviceradar_etc_dir/checkers/sweep"

# Set permissions
if [ -f "$serviceradar_etc_dir/agent.json" ]; then
    apply_owner "$service_owner" "$serviceradar_etc_dir/agent.json"
fi
if [ -z "$postinstall_root" ]; then
    chown -R serviceradar:serviceradar "$serviceradar_etc_dir/checkers"
    chown -R serviceradar:serviceradar "$serviceradar_etc_dir/sidecars"
    # Do not recursively chown the shared state root. Native add-ons keep root-owned
    # state below it and may intentionally drop CAP_DAC_OVERRIDE; taking ownership of
    # those directories while the add-on remains running makes its next write fail.
    chown -R serviceradar:serviceradar "$serviceradar_var_dir/cache"
    chown -R serviceradar:serviceradar "$serviceradar_var_dir/endpoint-inventory"
fi
chmod 755 "$serviceradar_etc_dir/"
chmod 750 "$serviceradar_etc_dir/sidecars"
chmod 755 "$serviceradar_var_dir/cache"
chmod 750 "$serviceradar_var_dir/endpoint-inventory"

updater_bin="$(root_path /usr/local/bin/serviceradar-agent-updater)"
if [ -x "$updater_bin" ]; then
    if [ -z "$postinstall_root" ]; then
        chown root:serviceradar "$updater_bin"
    fi
    chmod 4750 "$updater_bin"
fi

if [ -z "$postinstall_root" ]; then
    # Privileged add-on binaries live under /usr/lib/serviceradar/addons. Without a
    # persistent bin_t fcontext, a later restorecon resets them to usr_t/lib_t and
    # systemd exec fails with status=203/EXEC. Register the legacy staging context
    # for compatibility, but never mutate that service-writable tree as root.
    # Idempotent: skip add if the fcontext already exists.
    if command -v semanage >/dev/null 2>&1; then
        if ! semanage fcontext -l 2>/dev/null | grep -F '/usr/lib/serviceradar/addons' >/dev/null 2>&1; then
            semanage fcontext -a -t bin_t '/usr/lib/serviceradar/addons(/.*)?' || true
        fi
        if ! semanage fcontext -l 2>/dev/null | grep -F '/var/lib/serviceradar/agent/addons' >/dev/null 2>&1; then
            semanage fcontext -a -t bin_t '/var/lib/serviceradar/agent/addons(/.*)?' || true
        fi
    fi
    if command -v restorecon >/dev/null 2>&1; then
        restorecon -Rv /usr/lib/serviceradar/addons >/dev/null 2>&1 || true
    fi

    # netprobe is no longer shipped by the base agent package: its binary and the
    # cap_net_raw,cap_bpf,cap_perfmon setcap step moved into the netprobe add-on
    # delivery path (migrate-netprobe-to-native-addon §1.4). The root-owned
    # setuid agent-updater applies those file capabilities to the privileged
    # add-on binary per the add-on assignment's os_capabilities, not here.

    # The service runs build/packaging/agent/bin/serviceradar-agent as the
    # serviceradar user. That launcher validates the root-owned package seed, then
    # initializes or refreshes the writable runtime and current link without a
    # privileged process following paths controlled by the service account.

    # Reload systemd and manage service
    systemctl daemon-reload
    systemctl enable serviceradar-agent
    if [ -f /etc/serviceradar/agent.json ] && \
       [ -f /etc/serviceradar/certs/component.pem ] && \
       [ -f /etc/serviceradar/certs/component-key.pem ] && \
       [ -f /etc/serviceradar/certs/ca-chain.pem ]; then
        systemctl restart serviceradar-agent || {
            echo "Failed to start serviceradar-agent service. Check logs with: journalctl -xeu serviceradar-agent"
            exit 1
        }
    else
        echo "Skipping serviceradar-agent start: enrollment assets not found. Run srctl enroll, then: systemctl restart serviceradar-agent"
    fi
fi
