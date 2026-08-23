"""Shard count and naming for the serviceradar_core integration suite.

Single source of truth, because two packages have to agree exactly:

  * //elixir/serviceradar_core generates one ex_unit_test per shard;
  * //rust/integration-db:provision_db clones every shard database for CI;
  * //rust/integration-db:provision_db_sN clones one matching database for focused runs.

A mismatch is not a build error -- it is a suite that runs against a database nothing
provisioned, so the number lives here and both sides read it.

WHY SHARD AT ALL, AND WHY A DATABASE EACH

The integration tests share one mutable resource. Ecto's SQL sandbox isolates concurrent
tests inside a BEAM VM; it does nothing across OS processes. Splitting the suite into
parallel Bazel targets against ONE database therefore deadlocks -- measured at 25 failures
across 6 of 7 groups, dominated by `40P01 deadlock_detected`, where each group passed when
run on its own.

So each shard gets its own database. That is only affordable because provisioning is now a
`CREATE DATABASE ... TEMPLATE` file copy off a pre-migrated template (~0.7s) rather than a
368-migration replay.

WHY EIGHT

Measured on the unsharded target: ~36s fixed cost per target (sandbox setup, staging a
149-application ERL_LIBS tree, BEAM boot, app load), ~39s ExUnit load, ~165s of tests. The
fixed cost is paid by EVERY shard and does not divide, so:

    wall clock ~= 36 + (39 + 165) / N

    N=1  240s      N=5   77s
    N=3  104s      N=8   62s

Eight lands under the 70s target. Beyond that the fixed 36s dominates and more shards buy
almost nothing while multiplying database load -- N=16 is still ~49s, for twice the
connections and twice the clones.
"""

load(
    "@rules_elixir//:shards.bzl",
    "shard_names",
    _partition_by_shard = "partition_by_shard",
)

# Keep in step with nothing else -- everything derives from this.
INTEGRATION_SHARD_COUNT = 8
INTEGRATION_MAX_CASES = 2

# This is a source-separated release-gate database suffix, not an ordinary ninth shard.
LARGE_INGESTION_DB_SHARD = "large_ingestion"

# Tests using fixture-global external resource names must execute in one existing outer shard.
FIXED_EXTERNAL_RESOURCE_SHARD = "s7"

_FIXED_EXTERNAL_RESOURCE_SRCS = [
    "test/integration/netflow_ingestion_integration_test.exs",
    "test/integration/proxmox_api_smoke_integration_test.exs",
    "test/serviceradar/scans/adhoc_scan_nats_e2e_test.exs",
]

def integration_shard_names():
    """Shard suffixes, e.g. ["s0", "s1", ...]. Used in target names and database names."""
    return shard_names(INTEGRATION_SHARD_COUNT)

def fixed_external_resource_sources():
    """Sources that share a fixture-global resource and must remain in s7."""
    return list(_FIXED_EXTERNAL_RESOURCE_SRCS)

def integration_test_env(shard):
    """The complete, identical-shape environment for one ordinary integration shard."""
    return {
        "SERVICERADAR_ONLY_INTEGRATION": "1",
        "SERVICERADAR_INTEGRATION_MAX_CASES": str(INTEGRATION_MAX_CASES),
        "SERVICERADAR_TEST_DB_SHARD": shard,
    }

# Ordinary test files with known comparatively slow serial work are dealt out BEFORE everything
# else so future additions cannot accidentally pile multiple heavy files into one shard.
#
# The 50,000-device ResultsRouter case now lives only in the source-separated release gate, so it
# is no longer an ordinary shard-balancing input. The plugin result slot allocator is the sole
# remaining hint. This list is an optimization, not a source-membership contract: a stale entry
# costs only balance, while a missing one shows up as a slow shard. Re-measure with
# `--test_env=SERVICERADAR_TEST_SLOWEST=12` when ordinary shard wall-clock distribution drifts.
_HEAVY_SRCS = [
    "test/serviceradar/observability/plugin_result_slot_allocator_test.exs",
]

def partition_by_shard(srcs):
    """Split srcs into INTEGRATION_SHARD_COUNT disjoint, deterministic buckets.

    Deliberately not grouped by directory: shards no longer need to align with subsystems now
    that each has its own database, and serviceradar_core's test tree is far too lopsided for
    directory grouping to balance anything -- one directory holds several hundred files and
    others hold two.
    """
    fixed_sources = fixed_external_resource_sources()
    for source in fixed_sources:
        if source not in srcs:
            fail("fixed external resource source is absent from integration sources: {}".format(source))

    remaining_sources = [source for source in srcs if source not in fixed_sources]
    partitions = _partition_by_shard(
        remaining_sources,
        INTEGRATION_SHARD_COUNT,
        heavy_srcs = _HEAVY_SRCS,
    )
    partitions[FIXED_EXTERNAL_RESOURCE_SHARD] = (
        partitions[FIXED_EXTERNAL_RESOURCE_SHARD] + fixed_sources
    )
    return partitions
