"""Contract tests for the ordinary core integration shard topology."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
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

    fixed_sources = fixed_external_resource_sources()
    ordinary_sources = ["test/ordinary_{}.exs".format(index) for index in range(8)]
    sources = fixed_sources + ordinary_sources
    partitions = partition_by_shard(sources)

    for source in fixed_sources:
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
