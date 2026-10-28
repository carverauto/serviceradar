#!/usr/bin/env bash
set -euo pipefail

agent_postinstall="$1"
rperf_postinstall="$2"
rperf_checker_postinstall="$3"
nats_postinstall="$4"
agent_launcher="$5"

agent_spec="$6"

test_root="${TEST_TMPDIR:-/tmp}/agent_seed_test_$$"
trap 'chmod -R u+w "$test_root" 2>/dev/null || true; rm -rf "$test_root"' EXIT

prepare_fixture() {
    chmod -R u+w "$test_root" 2>/dev/null || true
    rm -rf "$test_root"
    mkdir -p "$test_root/bin" "$test_root/usr/local/lib/serviceradar/agent"
    cat > "$test_root/usr/local/lib/serviceradar/agent/serviceradar-agent-seed" <<'EOF'
#!/bin/sh
printf 'agent-started:%s\n' "$*"
EOF
    chmod 0755 "$test_root/usr/local/lib/serviceradar/agent/serviceradar-agent-seed"

    for command in getent useradd groupadd systemctl sudo semanage restorecon; do
        printf '#!/bin/sh\nexit 0\n' > "$test_root/bin/$command"
        chmod +x "$test_root/bin/$command"
    done
    printf '#!/bin/sh\nprintf "Disabled\\n"\n' > "$test_root/bin/getenforce"
    chmod +x "$test_root/bin/getenforce"

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

runner_owner="$(id -u):$(id -g)"
service_owner="$runner_owner"
if [[ "$(id -u)" == 0 ]]; then
    service_owner=65534:65534
fi

run_agent_postinstall() {
    local target_owner="${1:-$service_owner}"
    sed -e "s|/var/lib/serviceradar|$test_root/var/lib/serviceradar|g" \
        -e "s|/etc/serviceradar|$test_root/etc/serviceradar|g" \
        -e "s|/usr/local/bin/|$test_root/usr/local/bin/|g" \
        -e "s|/usr/lib/serviceradar|$test_root/usr/lib/serviceradar|g" \
        -e "s|serviceradar:serviceradar|$target_owner|g" \
        -e "s|root:serviceradar|$runner_owner|g" \
        -e "s|root:root|$runner_owner|g" \
        "$agent_postinstall" > "$test_root/agent_postinstall"
    PATH="$test_root/bin:$PATH" sh "$test_root/agent_postinstall"
}

# 1. Fresh install via postinstall creates versions/ and versions/seed-installed/
#    and allows the launcher to copy and exec the seed binary.
prepare_fixture
run_agent_postinstall "$runner_owner"
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
    run_agent_postinstall "65534:65534"
    [[ "$(stat -c '%u:%g' "$test_root/var/lib/serviceradar/agent/versions/seed-installed")" == "65534:65534" ]]
    healed_output="$(su -s /bin/sh nobody -c "\"$test_root/launcher\" --healed")"
else
    run_agent_postinstall "$runner_owner"
    [[ "$(stat -c '%a' "$test_root/var/lib/serviceradar/agent/versions/seed-installed")" == "755" ]]
    healed_output="$("$test_root/launcher" --healed)"
fi

[[ "$healed_output" == "agent-started:--healed" ]]
test ! -e "$test_root/var/lib/serviceradar/agent/versions/seed-installed/serviceradar-agent.new"
test -x "$test_root/var/lib/serviceradar/agent/versions/seed-installed/serviceradar-agent"

for rel in agent agent/tmp agent/versions agent/versions/seed-installed; do
    prepare_fixture
    mkdir -p "$test_root/var/lib/serviceradar/$(dirname "$rel")" "$test_root/outside"
    printf 'protected\n' > "$test_root/outside/sentinel"
    chmod 0700 "$test_root/outside"
    before="$(stat -c '%u:%g:%a' "$test_root/outside")"
    ln -s "$test_root/outside" "$test_root/var/lib/serviceradar/$rel"
    if run_agent_postinstall "$runner_owner" > /dev/null 2>&1; then
        echo "postinstall accepted symlinked $rel" >&2
        exit 1
    fi
    set +e
    "$test_root/launcher" > /dev/null 2>&1
    status=$?
    set -e
    [[ "$status" == 77 ]]
    [[ "$(stat -c '%u:%g:%a' "$test_root/outside")" == "$before" ]]
    [[ "$(cat "$test_root/outside/sentinel")" == protected ]]
done

prepare_fixture
chmod 0777 "$test_root/usr/local/lib/serviceradar/agent/serviceradar-agent-seed"
set +e
"$test_root/launcher" > /dev/null 2>&1
status=$?
set -e
[[ "$status" == 78 ]]

for installer in "$agent_postinstall" "$rperf_postinstall" "$rperf_checker_postinstall" "$nats_postinstall" "$agent_spec"; do
    for link in none agent agent/tmp agent/versions agent/versions/seed-installed; do
        if [[ "$installer" != "$agent_postinstall" && "$installer" != "$agent_spec" && "$link" != none ]]; then
            continue
        fi
        prepare_fixture
        mkdir -p "$test_root/bin" "$test_root/etc/serviceradar/rperf" "$test_root/etc/serviceradar/checkers" \
            "$test_root/var/lib/serviceradar/agent/tmp" "$test_root/var/lib/serviceradar/agent/versions/seed-installed" \
            "$test_root/var/lib/serviceradar/protected" "$test_root/usr/local/bin"
        for file in usr/local/bin/serviceradar-agent usr/local/bin/serviceradar-agent-updater \
            usr/local/bin/serviceradar-rperf usr/local/bin/serviceradar-rperf-checker \
            etc/serviceradar/rperf/rperf.conf etc/serviceradar/checkers/rperf.json; do
            touch "$test_root/$file"
        done
        sentinel="$test_root/var/lib/serviceradar/protected"
        printf 'protected\n' > "$sentinel/sentinel"
        chmod 0700 "$sentinel"
        before="$(stat -c '%u:%g:%a' "$sentinel")"
        protected_paths=("$sentinel")
        if [[ "$link" == none ]]; then
            for rel in agent agent/tmp agent/versions agent/versions/seed-installed; do
                protected="$test_root/var/lib/serviceradar/$rel/protected"
                mkdir "$protected"
                chmod 0700 "$protected"
                printf 'protected\n' > "$protected/sentinel"
                protected_paths+=("$protected")
            done
            if [[ "$installer" != "$agent_spec" ]]; then
                protected="$test_root/etc/serviceradar/protected"
                mkdir "$protected"
                chmod 0700 "$protected"
                printf 'protected\n' > "$protected/sentinel"
                protected_paths+=("$protected")
            fi
        fi
        if [[ "$link" != none ]]; then
            rm -rf "$test_root/var/lib/serviceradar/$link"
            ln -s "$sentinel" "$test_root/var/lib/serviceradar/$link"
        fi
        for command in getent useradd groupadd systemctl sudo semanage restorecon; do
            printf '#!/bin/sh\nexit 0\n' > "$test_root/bin/$command"
            chmod +x "$test_root/bin/$command"
        done
        printf '#!/bin/sh\nprintf "Disabled\\n"\n' > "$test_root/bin/getenforce"
        chmod +x "$test_root/bin/getenforce"
        if [[ "$installer" == "$agent_spec" ]]; then
            awk '/^%post$/ { active=1; next } /^%preun/ { active=0 } active && !/^%systemd_post/ { print }' "$installer" > "$test_root/body"
        else
            cp "$installer" "$test_root/body"
        fi
        sed -e "s|/var/lib/serviceradar|$test_root/var/lib/serviceradar|g" \
            -e "s|/etc/serviceradar|$test_root/etc/serviceradar|g" \
            -e "s|/usr/local/bin/|$test_root/usr/local/bin/|g" \
            -e "s|/usr/lib/serviceradar|$test_root/usr/lib/serviceradar|g" \
            -e "s|/etc/nats|$test_root/etc/nats|g" \
            -e "s|/lib/systemd/system|$test_root/lib/systemd/system|g" \
            -e "s|serviceradar:serviceradar|$service_owner|g" \
            -e "s|root:serviceradar|$runner_owner|g" \
            -e "s|root:root|$runner_owner|g" \
            "$test_root/body" > "$test_root/installer"
        set +e
        PATH="$test_root/bin:$PATH" sh "$test_root/installer" 2 > "$test_root/install.log" 2>&1
        status=$?
        set -e
        if [[ "$link" == none ]]; then
            if [[ "$status" != 0 ]]; then cat "$test_root/install.log"; exit 1; fi
            if [[ "$installer" == "$agent_postinstall" || "$installer" == "$agent_spec" ]]; then
                for rel in agent agent/tmp agent/versions agent/versions/seed-installed; do
                    [[ "$(stat -c '%u:%g:%a' "$test_root/var/lib/serviceradar/$rel")" == "$service_owner:755" ]]
                done
            fi
        else
            [[ "$status" != 0 ]]
        fi
        for protected in "${protected_paths[@]}"; do
            [[ "$(stat -c '%u:%g:%a' "$protected")" == "$before" ]]
            [[ "$(cat "$protected/sentinel")" == protected ]]
        done
    done
done
