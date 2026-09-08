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
    "serial_source_test_counts",
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

    asserts.equals(env, 7, serial_lane_count_for_capacity(197, 160))
    asserts.equals(env, 7, serial_lane_count_for_capacity(107, 160))
    asserts.equals(env, 6, serial_lane_count_for_capacity(106, 160))
    asserts.equals(env, 1, serial_lane_count_for_capacity(27, 160))
    asserts.equals(env, 1, serial_lane_count_for_capacity(197, 1))

    async_sources = async_integration_sources()
    serial_counts = serial_source_module_counts()
    serial_test_counts = serial_source_test_counts()
    selected_sources = integration_selected_sources()
    # Consistency RELATIONS, not three magic totals.
    #
    # These were pinned to 126 / 160 / 286 -- and 126 + 160 == 286, so the only
    # real invariant was that the async and serial projections partition the
    # selection exactly. Pinning the absolutes meant every added or removed test
    # file failed this test even when the projection was correct, and made two
    # concurrent PRs invalidate each other: BazelCI tests the MERGE of a branch
    # with its base, so the second PR to run saw a failure caused entirely by the
    # first. The relations below hold no matter how many tests exist.
    asserts.equals(env, len(serial_counts), len(serial_test_counts))
    asserts.equals(env, sorted(serial_counts.keys()), sorted(serial_test_counts.keys()))
    asserts.equals(
        env,
        len(async_sources) + len(serial_counts),
        len(selected_sources),
        "async + serial projections must partition the selection exactly",
    )

    # A floor, so an emptied or truncated projection still fails loudly. This is
    # deliberately far below the real figures (126 async / 160 serial) -- it is a
    # tripwire for catastrophic loss, not a count to maintain.
    asserts.true(env, len(async_sources) > 50, "async projection looks truncated")
    asserts.true(env, len(serial_counts) > 50, "serial projection looks truncated")
    asserts.equals(env, _FIXED_EXTERNAL_RESOURCE_SRCS, fixed_external_resource_sources())

    partitions = partition_by_lane(selected_sources)
    reversed_partitions = partition_by_lane(reversed(selected_sources))
    asserts.equals(env, partitions, reversed_partitions)
    asserts.equals(env, async_sources, partitions["async"])

    partitioned_sources = []
    serial_partitioned_sources = []
    serial_lane_sizes = []
    serial_lane_test_counts = []
    serial_lane_weights = []
    for lane in lanes:
        partitioned_sources += partitions[lane]
        if lane != "async":
            serial_partitioned_sources += partitions[lane]
            serial_lane_sizes.append(len(partitions[lane]))
            lane_test_count = 0
            for source in partitions[lane]:
                lane_test_count += serial_test_counts[source]
            serial_lane_test_counts.append(lane_test_count)
            serial_lane_weights.append(lane_test_count + len(partitions[lane]))

    asserts.equals(env, sorted(selected_sources), sorted(partitioned_sources))
    asserts.equals(env, len(selected_sources), len(partitioned_sources))
    asserts.equals(env, sorted(serial_counts.keys()), sorted(serial_partitioned_sources))
    # Balance is asserted as a PROPERTY, not as a snapshot of one distribution.
    #
    # These three lists used to be pinned to exact values -- [26, 22, 22, ...] and
    # friends. Those numbers are output of the bin-packer, not a contract anyone
    # chose, so adding or removing a single test file redistributed every lane and
    # failed all three assertions. Nobody could compute the new distribution by
    # hand, so the fix was always "run it, read the `got` value, paste it back":
    # churn that carried no information and could not fail usefully. Worse, two PRs
    # that each added a test invalidated each other, so the second to run saw a red
    # BazelCI caused by the first. `git log` on this file shows 15 commits in 90
    # days, several of them titled purely as rebalances or drift reconciliation.
    #
    # What actually matters is that no serial lane is much heavier than the others:
    # the lanes run in parallel, so the heaviest one sets the wall clock. That is
    # what is asserted here, and it survives adding a test.
    asserts.equals(env, len(lanes) - 1, len(serial_lane_weights))
    asserts.equals(env, len(serial_lane_weights), len(serial_lane_sizes))
    asserts.equals(env, len(serial_lane_weights), len(serial_lane_test_counts))

    serial_lane_count = len(serial_lane_weights)
    total_weight = 0
    for weight in serial_lane_weights:
        total_weight += weight

    max_weight = serial_lane_weights[0]
    min_weight = serial_lane_weights[0]
    for weight in serial_lane_weights:
        if weight > max_weight:
            max_weight = weight
        if weight < min_weight:
            min_weight = weight

    # Integer arithmetic rather than division: `max <= mean * 1.25` and
    # `min >= mean * 0.75`, with mean = total / lane_count. A lane 25% above
    # average is a real wall-clock regression; a lane 25% below average means the
    # packer is leaving capacity unused. Both bounds are far outside the observed
    # spread (212..214 against a mean of ~213) so ordinary churn cannot trip them,
    # while a partitioner that collapsed everything into one lane fails loudly.
    asserts.true(
        env,
        max_weight * serial_lane_count * 100 <= total_weight * 125,
        "serial lane weights are unbalanced (heaviest lane): %s" % serial_lane_weights,
    )
    asserts.true(
        env,
        min_weight * serial_lane_count * 100 >= total_weight * 75,
        "serial lane weights are unbalanced (lightest lane): %s" % serial_lane_weights,
    )

    # Every serial lane must carry work. A zero-weight lane is a scheduling bug
    # that the ratio bounds alone would not catch if the total were small.
    for weight in serial_lane_weights:
        asserts.true(env, weight > 0, "a serial lane carries no tests: %s" % serial_lane_weights)

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
