#!/usr/bin/env bats

setup() {
    export TEST_ROOT="$BATS_TEST_TMPDIR/root"
    export POSTINSTALL="$BATS_TEST_DIRNAME/postinstall.sh"
    mkdir -p "$TEST_ROOT/etc/nats/templates"
}

write_nats_configs() {
    cat >"$TEST_ROOT/etc/nats/nats-server.conf" <<'EOF_CONF'
permissions = ["flow.attributed.__SERVICERADAR_PARTITION_ID__"]
EOF_CONF

    cat >"$TEST_ROOT/etc/nats/templates/nats-cloud.conf" <<'EOF_CONF'
permissions = ["flow.attributed.__SERVICERADAR_PARTITION_ID__.>"]
EOF_CONF
}

run_postinstall() {
    run env "$@" SERVICERADAR_POSTINSTALL_ROOT="$TEST_ROOT" "$POSTINSTALL"
}

@test "env unset substitutes default partition" {
    write_nats_configs

    run env -u SERVICERADAR_OTX_PARTITION SERVICERADAR_POSTINSTALL_ROOT="$TEST_ROOT" "$POSTINSTALL"

    [ "$status" -eq 0 ]
    grep -q 'flow.attributed.default' "$TEST_ROOT/etc/nats/nats-server.conf"
    grep -q 'flow.attributed.default.>' "$TEST_ROOT/etc/nats/templates/nats-cloud.conf"
    ! grep -R -q '__SERVICERADAR_PARTITION_ID__' "$TEST_ROOT/etc/nats"
}

@test "env set substitutes partition verbatim" {
    write_nats_configs

    run_postinstall SERVICERADAR_OTX_PARTITION='prod-east.1'

    [ "$status" -eq 0 ]
    grep -q 'flow.attributed.prod-east.1' "$TEST_ROOT/etc/nats/nats-server.conf"
    grep -q 'flow.attributed.prod-east.1.>' "$TEST_ROOT/etc/nats/templates/nats-cloud.conf"
}

@test "idempotent re-run preserves first substitution" {
    write_nats_configs

    run_postinstall SERVICERADAR_OTX_PARTITION='prod-east'
    [ "$status" -eq 0 ]

    run_postinstall SERVICERADAR_OTX_PARTITION='prod-west'
    [ "$status" -eq 0 ]

    grep -q 'flow.attributed.prod-east' "$TEST_ROOT/etc/nats/nats-server.conf"
    ! grep -q 'flow.attributed.prod-west' "$TEST_ROOT/etc/nats/nats-server.conf"
}

@test "rejects malformed partition that would break sed substitution" {
    write_nats_configs

    run_postinstall SERVICERADAR_OTX_PARTITION='bad|partition'

    [ "$status" -ne 0 ]
    grep -q 'SERVICERADAR_OTX_PARTITION must match' <<<"$output"
    grep -q '__SERVICERADAR_PARTITION_ID__' "$TEST_ROOT/etc/nats/nats-server.conf"
}
