"""Contract tests for the ordinary core integration shard topology."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load(
    ":integration_shards.bzl",
    "FIXED_EXTERNAL_RESOURCE_SHARD",
    "INTEGRATION_MAX_CASES",
    "LARGE_INGESTION_DB_SHARD",
    "fixed_external_resource_sources",
    "integration_shard_names",
    "integration_test_env",
    "partition_by_shard",
)

_FIXED_EXTERNAL_RESOURCE_SRCS = [
    "test/integration/netflow_ingestion_integration_test.exs",
    "test/integration/proxmox_api_smoke_integration_test.exs",
    "test/serviceradar/scans/adhoc_scan_nats_e2e_test.exs",
]

_ORDINARY_SRCS = ["test/ordinary_{}.exs".format(index) for index in range(8)]

def _missing_fixed_source_impl(_ctx):
    partition_by_shard(
        [
            _FIXED_EXTERNAL_RESOURCE_SRCS[0],
            _FIXED_EXTERNAL_RESOURCE_SRCS[2],
        ] + _ORDINARY_SRCS,
    )
    return []

missing_fixed_source = rule(implementation = _missing_fixed_source_impl)

def _missing_fixed_source_failure_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(
        env,
        "fixed external resource source is absent from integration sources: test/integration/proxmox_api_smoke_integration_test.exs",
    )
    return analysistest.end(env)

missing_fixed_source_failure_test = analysistest.make(
    _missing_fixed_source_failure_test_impl,
    expect_failure = True,
)

def _integration_shards_topology_test_impl(ctx):
    env = unittest.begin(ctx)

    shard_names = integration_shard_names()
    expected_env_keys = [
        "SERVICERADAR_INTEGRATION_MAX_CASES",
        "SERVICERADAR_ONLY_INTEGRATION",
        "SERVICERADAR_TEST_DB_SHARD",
    ]
    asserts.equals(env, 8, len(shard_names))
    asserts.equals(env, 2, INTEGRATION_MAX_CASES)
    asserts.equals(env, "large_ingestion", LARGE_INGESTION_DB_SHARD)
    asserts.equals(env, "s7", FIXED_EXTERNAL_RESOURCE_SHARD)

    asserts.equals(env, _FIXED_EXTERNAL_RESOURCE_SRCS, fixed_external_resource_sources())

    sources = _FIXED_EXTERNAL_RESOURCE_SRCS + _ORDINARY_SRCS
    partitions = partition_by_shard(sources)

    for source in _FIXED_EXTERNAL_RESOURCE_SRCS:
        asserts.equals(
            env,
            1,
            len([candidate for candidate in partitions[FIXED_EXTERNAL_RESOURCE_SHARD] if candidate == source]),
        )
        for shard in shard_names:
            if shard != FIXED_EXTERNAL_RESOURCE_SHARD:
                asserts.equals(
                    env,
                    0,
                    len([candidate for candidate in partitions[shard] if candidate == source]),
                )

    partitioned_sources = []
    for shard in shard_names:
        partitioned_sources += partitions[shard]
    asserts.equals(env, sorted(sources), sorted(partitioned_sources))
    asserts.equals(env, len(sources), len(partitioned_sources))

    for shard in shard_names:
        integration_env = integration_test_env(shard)
        asserts.equals(env, "2", integration_env["SERVICERADAR_INTEGRATION_MAX_CASES"])
        asserts.equals(env, "1", integration_env["SERVICERADAR_ONLY_INTEGRATION"])
        asserts.equals(env, shard, integration_env["SERVICERADAR_TEST_DB_SHARD"])
        asserts.equals(env, expected_env_keys, sorted(integration_env.keys()))

    return unittest.end(env)

integration_shards_topology_test = unittest.make(_integration_shards_topology_test_impl)
