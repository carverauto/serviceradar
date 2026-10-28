#!/usr/bin/env bash
set -euo pipefail

agent_postinstall="$1"
rperf_postinstall="$2"
rperf_checker_postinstall="$3"
nats_postinstall="$4"
agent_launcher="$5"

for script in "$agent_postinstall" "$rperf_postinstall" "$rperf_checker_postinstall" "$nats_postinstall"; do
    if awk '
        /^[[:space:]]*(chown|chmod)[[:space:]]+/ {
            line = $0
            sub(/[[:space:]]*#.*/, "", line)
            gsub(/"/, "", line)
            recursive = line ~ /(^|[[:space:]])--recursive([[:space:]]|$)/ ||
                line ~ /(^|[[:space:]])-[A-Za-z]*R[A-Za-z]*([[:space:]]|$)/
            shared_root = line ~ /\/(etc|var\/lib)\/serviceradar\/?([[:space:]]|$)/ ||
                line ~ /\$\{?serviceradar_(etc|var)_dir\}?\/?([[:space:]]|$)/ ||
                line ~ /\/var\/lib\/serviceradar\/agent(\/|[[:space:]]|$)/ ||
                line ~ /\$\{?agent_(runtime|tmp|versions|seed)_dir\}?\/?([[:space:]]|$)/
            if (recursive && shared_root) {
                print FILENAME ": unsafe recursive shared-state permission change: " $0
                failed = 1
            }
        }
        END { exit failed }
    ' "$script"; then
        continue
    fi
    exit 1
done

if ! awk '
    /\/var\/lib\/serviceradar\/agent(\/|[[:space:]]|$)/ {
        line = $0
        sub(/[[:space:]]*#.*/, "", line)
        if (line != "" &&
            line !~ /semanage[[:space:]]+fcontext/ &&
            line !~ /^agent_(runtime|tmp|versions|seed)_dir=/ &&
            line !~ /rm[[:space:]]+-f[[:space:]]+"?\$agent_seed_dir\/serviceradar-agent\.new"?/) {
            print FILENAME ": unexpected privileged operation under service-writable agent runtime: " $0
            failed = 1
        }
    }
    /^[[:space:]]*(cp|mv|ln|restorecon)[[:space:]]+.*(\$agent_(runtime|tmp|versions|seed)_dir|\/var\/lib\/serviceradar\/agent)/ {
        line = $0
        sub(/[[:space:]]*#.*/, "", line)
        if (line != "") {
            print FILENAME ": unsafe file copy/link/relabel in service-writable agent runtime: " $0
            failed = 1
        }
    }
    END { exit failed }
' "$agent_postinstall"; then
    exit 1
fi

# Verify launcher hardcodes package-owned runtime root and seed binary paths.
grep -qx 'RUNTIME_ROOT="/var/lib/serviceradar/agent"' "$agent_launcher"
grep -qx 'SEED_BINARY="/usr/local/lib/serviceradar/agent/serviceradar-agent-seed"' "$agent_launcher"

test_root="${TEST_TMPDIR:-/tmp}/agent_seed_test_$$"
trap 'chmod -R u+w "$test_root" 2>/dev/null || true; rm -rf "$test_root"' EXIT

prepare_fixture() {
    chmod -R u+w "$test_root" 2>/dev/null || true
    rm -rf "$test_root"
    mkdir -p "$test_root/usr/local/lib/serviceradar/agent"
    cat > "$test_root/usr/local/lib/serviceradar/agent/serviceradar-agent-seed" <<'EOF'
#!/bin/sh
printf 'agent-started:%s\n' "$*"
EOF
    chmod 0755 "$test_root/usr/local/lib/serviceradar/agent/serviceradar-agent-seed"

    # Build a test copy of the launcher mapped to $test_root and the current
    # test runner's seed owner UID while keeping the exact launcher logic intact.
    seed_uid="$(stat -c '%u' "$test_root/usr/local/lib/serviceradar/agent/serviceradar-agent-seed")"
    sed \
        -e "s|^RUNTIME_ROOT=\"/var/lib/serviceradar/agent\"$|RUNTIME_ROOT=\"$test_root/var/lib/serviceradar/agent\"|" \
        -e "s|^SEED_BINARY=\"/usr/local/lib/serviceradar/agent/serviceradar-agent-seed\"$|SEED_BINARY=\"$test_root/usr/local/lib/serviceradar/agent/serviceradar-agent-seed\"|" \
        -e "s|if \[ \"\${owner_uid}\" != \"0\" \]; then|if [ \"\${owner_uid}\" != \"${seed_uid}\" ]; then|" \
        "$agent_launcher" > "$test_root/launcher"
    chmod 0755 "$test_root/launcher"
}

# 1. Fresh install via postinstall creates versions/ and versions/seed-installed/
#    and allows the launcher to copy and exec the seed binary.
prepare_fixture
SERVICERADAR_POSTINSTALL_ROOT="$test_root" sh "$agent_postinstall"
for rel in \
    var/lib/serviceradar/agent \
    var/lib/serviceradar/agent/tmp \
    var/lib/serviceradar/agent/versions \
    var/lib/serviceradar/agent/versions/seed-installed; do
    test -d "$test_root/$rel"
    test ! -L "$test_root/$rel"
    [[ "$(stat -c '%a' "$test_root/$rel")" == "755" ]]
done

output="$("$test_root/launcher" --flag-ok)"
[[ "$output" == "agent-started:--flag-ok" ]]
[[ "$(readlink "$test_root/var/lib/serviceradar/agent/current")" == "versions/seed-installed" ]]
test -x "$test_root/var/lib/serviceradar/agent/versions/seed-installed/serviceradar-agent"

# 2. Regression test (#6118): when versions/seed-installed is root-owned / not
#    writable by the service user, the launcher must fail loudly with exit code 77
#    (RestartPreventExitStatus) and a clear message naming versions/seed-installed,
#    and upgrading via postinstall must self-heal the directory so the next start
#    succeeds.
prepare_fixture
mkdir -p "$test_root/var/lib/serviceradar/agent/tmp" "$test_root/var/lib/serviceradar/agent/versions/seed-installed"
printf 'stale-new\n' > "$test_root/var/lib/serviceradar/agent/versions/seed-installed/serviceradar-agent.new"

if [[ "$(id -u)" == "0" ]]; then
    chown 65534:65534 \
        "$test_root/var/lib/serviceradar" \
        "$test_root/var/lib/serviceradar/agent" \
        "$test_root/var/lib/serviceradar/agent/tmp" \
        "$test_root/var/lib/serviceradar/agent/versions"
    chown 0:0 "$test_root/var/lib/serviceradar/agent/versions/seed-installed"
    chmod 0755 "$test_root/var/lib/serviceradar/agent/versions/seed-installed"

    set +e
    err_output="$(su -s /bin/sh nobody -c "\"$test_root/launcher\" --check" 2>&1)"
    status=$?
    set -e
else
    chmod 0555 "$test_root/var/lib/serviceradar/agent/versions/seed-installed"

    set +e
    err_output="$("$test_root/launcher" --check 2>&1)"
    status=$?
    set -e
fi

if [[ "$status" -ne 77 ]]; then
    echo "expected launcher exit code 77 on unwritable seed-installed dir, got $status: $err_output" >&2
    exit 1
fi
if [[ "$err_output" != *"FATAL: serviceradar-agent launcher cannot refresh seed runtime"* ]] || \
   [[ "$err_output" != *"versions/seed-installed"* ]]; then
    echo "launcher did not emit expected fatal diagnostic for seed-installed: $err_output" >&2
    exit 1
fi

# Self-heal on upgrade via postinstall.sh.
if [[ "$(id -u)" == "0" ]]; then
    SERVICERADAR_POSTINSTALL_ROOT="$test_root" SERVICERADAR_POSTINSTALL_OWNER="65534:65534" sh "$agent_postinstall"
    [[ "$(stat -c '%u:%g' "$test_root/var/lib/serviceradar/agent/versions/seed-installed")" == "65534:65534" ]]
    healed_output="$(su -s /bin/sh nobody -c "\"$test_root/launcher\" --healed")"
else
    SERVICERADAR_POSTINSTALL_ROOT="$test_root" sh "$agent_postinstall"
    [[ "$(stat -c '%a' "$test_root/var/lib/serviceradar/agent/versions/seed-installed")" == "755" ]]
    healed_output="$("$test_root/launcher" --healed)"
fi

[[ "$healed_output" == "agent-started:--healed" ]]
test ! -e "$test_root/var/lib/serviceradar/agent/versions/seed-installed/serviceradar-agent.new"
test -x "$test_root/var/lib/serviceradar/agent/versions/seed-installed/serviceradar-agent"

# 3. Symlinked seed-installed directory must be rejected by both postinstall and launcher.
prepare_fixture
mkdir -p "$test_root/var/lib/serviceradar/agent/versions" "$test_root/outside"
ln -s "$test_root/outside" "$test_root/var/lib/serviceradar/agent/versions/seed-installed"

if SERVICERADAR_POSTINSTALL_ROOT="$test_root" sh "$agent_postinstall" >/dev/null 2>&1; then
    echo "postinstall accepted symlinked versions/seed-installed" >&2
    exit 1
fi

set +e
symlink_err="$("$test_root/launcher" 2>&1)"
symlink_status=$?
set -e
if [[ "$symlink_status" -ne 77 ]] || [[ "$symlink_err" != *"path is a symbolic link"* ]]; then
    echo "launcher did not reject symlinked versions/seed-installed with exit 77 ($symlink_status): $symlink_err" >&2
    exit 1
fi
