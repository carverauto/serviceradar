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

file_mode() {
    stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"
}

reset_root
chmod 777 "$test_root/etc/serviceradar"
printf '%s\n' 'export SERVICERADAR_OTX_PARTITION="synthetic-zone.7"' > "$test_root/etc/serviceradar/nats.env"
run_postinstall
grep -qx 'partition=synthetic-zone.7' "$test_root/etc/nats/nats-server.conf"
[[ "$(file_mode "$test_root/etc/serviceradar")" == "755" ]]

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

reset_root
run_postinstall
for nats_dir in /var/lib/nats /var/lib/nats/jetstream /var/log/nats; do
    [[ -d "$test_root$nats_dir" ]]
    [[ "$(file_mode "$test_root$nats_dir")" == "750" ]]
done
for nats_log in /var/log/nats/nats.log /var/log/nats/nats-error.log; do
    [[ -f "$test_root$nats_log" ]]
    [[ "$(file_mode "$test_root$nats_log")" == "640" ]]
done

reset_root
mkdir -p "$test_root/var/log/nats"
printf 'earlier line\n' > "$test_root/var/log/nats/nats.log"
printf 'earlier error\n' > "$test_root/var/log/nats/nats-error.log"
chmod 666 "$test_root/var/log/nats/nats.log" "$test_root/var/log/nats/nats-error.log"
run_postinstall
grep -qx 'earlier line' "$test_root/var/log/nats/nats.log"
grep -qx 'earlier error' "$test_root/var/log/nats/nats-error.log"
[[ "$(file_mode "$test_root/var/log/nats/nats.log")" == "640" ]]
[[ "$(file_mode "$test_root/var/log/nats/nats-error.log")" == "640" ]]

for nats_log in /var/log/nats/nats.log /var/log/nats/nats-error.log; do
    reset_root
    mkdir -p "$test_root/var/log/nats"
    printf 'keep\n' > "$test_root/target.log"
    chmod 644 "$test_root/target.log"
    ln -s "$test_root/target.log" "$test_root$nats_log"
    if err="$(run_postinstall 2>&1)"; then
        echo "symlinked $nats_log was accepted" >&2
        exit 1
    fi
    [[ "$err" == *"refusing symlinked $nats_log"* ]]
    [[ "$(file_mode "$test_root/target.log")" == "644" ]]
done

for nats_dir in /var/lib/nats /var/lib/nats/jetstream /var/log/nats; do
    reset_root
    mkdir -p "$(dirname "$test_root$nats_dir")" "$test_root/target-dir"
    chmod 755 "$test_root/target-dir"
    ln -s "$test_root/target-dir" "$test_root$nats_dir"
    if err="$(run_postinstall 2>&1)"; then
        echo "symlinked $nats_dir was accepted" >&2
        exit 1
    fi
    [[ "$err" == *"refusing symlinked $nats_dir"* ]]
    [[ "$(file_mode "$test_root/target-dir")" == "755" ]]
done
