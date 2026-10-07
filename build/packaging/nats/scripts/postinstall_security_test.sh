#!/usr/bin/env bash
set -euo pipefail

postinstall="$1"
test_root="${TEST_TMPDIR}/root"

reset_root() {
    rm -rf "$test_root"
    mkdir -p "$test_root/etc/serviceradar" "$test_root/etc/nats/templates"
    printf 'partition=__SERVICERADAR_PARTITION_ID__\n' > "$test_root/etc/nats/nats-server.conf"
}

run_postinstall() {
    SERVICERADAR_POSTINSTALL_ROOT="$test_root" sh "$postinstall"
}

reset_root
chmod 777 "$test_root/etc/serviceradar"
printf '%s\n' 'export SERVICERADAR_OTX_PARTITION="synthetic-zone.7"' > "$test_root/etc/serviceradar/nats.env"
run_postinstall
grep -qx 'partition=synthetic-zone.7' "$test_root/etc/nats/nats-server.conf"
[[ "$(stat -c '%a' "$test_root/etc/serviceradar")" == "755" ]]

reset_root
marker="$test_root/command-ran"
printf 'SERVICERADAR_OTX_PARTITION=$(touch %s)\n' "$marker" > "$test_root/etc/serviceradar/nats.env"
if run_postinstall >/dev/null 2>&1; then
    echo "malicious partition value was accepted" >&2
    exit 1
fi
if [[ -e "$marker" ]]; then
    echo "nats.env command substitution was executed" >&2
    exit 1
fi

reset_root
cat > "$test_root/etc/serviceradar/nats.env" <<'EOF'
SERVICERADAR_OTX_PARTITION=first
SERVICERADAR_OTX_PARTITION=second
EOF
if run_postinstall >/dev/null 2>&1; then
    echo "duplicate partition assignments were accepted" >&2
    exit 1
fi

reset_root
printf '%s\n' 'SERVICERADAR_OTX_PARTITION=synthetic-zone' > "$test_root/partition.env"
ln -s "$test_root/partition.env" "$test_root/etc/serviceradar/nats.env"
if run_postinstall >/dev/null 2>&1; then
    echo "symlinked nats.env was accepted" >&2
    exit 1
fi
