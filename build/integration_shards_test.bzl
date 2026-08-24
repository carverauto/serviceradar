"""Contract tests for the ordinary core integration lane topology."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load(
    ":integration_shards.bzl",
    "FIXED_EXTERNAL_RESOURCE_LANE",
    "FROZEN_FIXTURE_USABLE_CLIENT_SLOTS",
    "INTEGRATION_ASYNC_MAX_CASES",
    "INTEGRATION_MAX_BEAMS",
    "INTEGRATION_MAX_POOL_SLOTS",
    "INTEGRATION_REPO_POOL_SIZE",
    "INTEGRATION_SERIAL_MAX_CASES",
    "LARGE_INGESTION_BOOTSTRAP_ADMIN_CONNECTION_SLOTS",
    "LARGE_INGESTION_BOOTSTRAP_POOL_SIZE",
    "LARGE_INGESTION_DB_SHARD",
    "LARGE_INGESTION_REPO_POOL_SIZE",
    "LARGE_INGESTION_WORKFLOW_CONNECTION_SLOTS",
    "async_integration_sources",
    "fixed_external_resource_sources",
    "integration_configured_pool_slots",
    "integration_lane_names",
    "integration_selected_sources",
    "integration_serial_lane_names",
    "integration_test_env",
    "partition_by_lane",
    "serial_lane_count_for_capacity",
    "serial_source_module_counts",
)

_FIXED_EXTERNAL_RESOURCE_SRCS = [
    "test/integration/netflow_ingestion_integration_test.exs",
    "test/integration/proxmox_api_smoke_integration_test.exs",
    "test/serviceradar/scans/adhoc_scan_nats_e2e_test.exs",
]

def _missing_fixed_source_impl(_ctx):
    missing = _FIXED_EXTERNAL_RESOURCE_SRCS[1]
    partition_by_lane([
        source
        for source in integration_selected_sources()
        if source != missing
    ])
    return []

missing_fixed_source = rule(implementation = _missing_fixed_source_impl)

def _missing_fixed_source_failure_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(
        env,
        "audited integration source is absent from ALL_TEST_SRCS: test/integration/proxmox_api_smoke_integration_test.exs",
    )
    return analysistest.end(env)

missing_fixed_source_failure_test = analysistest.make(
    _missing_fixed_source_failure_test_impl,
    expect_failure = True,
)

def _insufficient_capacity_impl(_ctx):
    serial_lane_count_for_capacity(26, 1)
    return []

insufficient_capacity = rule(implementation = _insufficient_capacity_impl)

def _insufficient_capacity_failure_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(
        env,
        "fixture capacity cannot fund one async and one serial integration BEAM",
    )
    return analysistest.end(env)

insufficient_capacity_failure_test = analysistest.make(
    _insufficient_capacity_failure_test_impl,
    expect_failure = True,
)

def _integration_shards_topology_test_impl(ctx):
    env = unittest.begin(ctx)

    lanes = integration_lane_names()
    serial_lanes = integration_serial_lane_names()
    expected_lanes = ["async"] + ["serial_{}".format(index) for index in range(7)]
    expected_env_keys = [
        "SERVICERADAR_INTEGRATION_MAX_CASES",
        "SERVICERADAR_ONLY_INTEGRATION",
        "SERVICERADAR_TEST_DATABASE_POOL_SIZE",
        "SERVICERADAR_TEST_DB_SHARD",
        "SERVICERADAR_TEST_LANE",
        "SERVICERADAR_TEST_TOPOLOGY",
    ]

    asserts.equals(env, expected_lanes, lanes)
    asserts.equals(env, expected_lanes[1:], serial_lanes)
    asserts.equals(env, 8, INTEGRATION_ASYNC_MAX_CASES)
    asserts.equals(env, 1, INTEGRATION_SERIAL_MAX_CASES)
    asserts.equals(env, 12, INTEGRATION_REPO_POOL_SIZE)
    asserts.equals(env, 8, INTEGRATION_MAX_BEAMS)
    asserts.equals(env, 96, INTEGRATION_MAX_POOL_SLOTS)
    asserts.equals(env, 197, FROZEN_FIXTURE_USABLE_CLIENT_SLOTS)
    asserts.equals(env, 96, integration_configured_pool_slots())
    asserts.equals(env, "large_ingestion", LARGE_INGESTION_DB_SHARD)
    asserts.equals(env, 12, LARGE_INGESTION_REPO_POOL_SIZE)
    asserts.equals(env, 2, LARGE_INGESTION_BOOTSTRAP_POOL_SIZE)
    asserts.equals(env, 1, LARGE_INGESTION_BOOTSTRAP_ADMIN_CONNECTION_SLOTS)
    asserts.equals(env, 15, LARGE_INGESTION_WORKFLOW_CONNECTION_SLOTS)
    asserts.equals(env, "serial_0", FIXED_EXTERNAL_RESOURCE_LANE)

    asserts.equals(env, 7, serial_lane_count_for_capacity(197, 159))
    asserts.equals(env, 7, serial_lane_count_for_capacity(107, 159))
    asserts.equals(env, 6, serial_lane_count_for_capacity(106, 159))
    asserts.equals(env, 1, serial_lane_count_for_capacity(27, 159))
    asserts.equals(env, 1, serial_lane_count_for_capacity(197, 1))

    async_sources = async_integration_sources()
    serial_counts = serial_source_module_counts()
    selected_sources = integration_selected_sources()
    asserts.equals(env, 120, len(async_sources))
    asserts.equals(env, 159, len(serial_counts))
    asserts.equals(env, 279, len(selected_sources))
    asserts.equals(env, _FIXED_EXTERNAL_RESOURCE_SRCS, fixed_external_resource_sources())

    partitions = partition_by_lane(selected_sources)
    reversed_partitions = partition_by_lane(reversed(selected_sources))
    asserts.equals(env, partitions, reversed_partitions)
    asserts.equals(env, async_sources, partitions["async"])

    partitioned_sources = []
    serial_partitioned_sources = []
    serial_lane_sizes = []
    for lane in lanes:
        partitioned_sources += partitions[lane]
        if lane != "async":
            serial_partitioned_sources += partitions[lane]
            serial_lane_sizes.append(len(partitions[lane]))

    asserts.equals(env, sorted(selected_sources), sorted(partitioned_sources))
    asserts.equals(env, len(selected_sources), len(partitioned_sources))
    asserts.equals(env, sorted(serial_counts.keys()), sorted(serial_partitioned_sources))
    asserts.true(env, max(serial_lane_sizes) - min(serial_lane_sizes) <= 1)

    for source in _FIXED_EXTERNAL_RESOURCE_SRCS:
        asserts.true(env, source in partitions[FIXED_EXTERNAL_RESOURCE_LANE])
        for lane in lanes:
            if lane != FIXED_EXTERNAL_RESOURCE_LANE:
                asserts.false(env, source in partitions[lane])

    for lane in lanes:
        integration_env = integration_test_env(lane)
        expected_cap = "8" if lane == "async" else "1"
        asserts.equals(env, expected_cap, integration_env["SERVICERADAR_INTEGRATION_MAX_CASES"])
        asserts.equals(env, "1", integration_env["SERVICERADAR_ONLY_INTEGRATION"])
        asserts.equals(env, "12", integration_env["SERVICERADAR_TEST_DATABASE_POOL_SIZE"])
        asserts.equals(env, lane, integration_env["SERVICERADAR_TEST_DB_SHARD"])
        asserts.equals(env, lane, integration_env["SERVICERADAR_TEST_LANE"])
        asserts.equals(env, "async_serial", integration_env["SERVICERADAR_TEST_TOPOLOGY"])
        asserts.equals(env, expected_env_keys, sorted(integration_env.keys()))

    return unittest.end(env)

integration_shards_topology_test = unittest.make(_integration_shards_topology_test_impl)
