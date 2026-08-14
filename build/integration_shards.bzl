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

# Keep in step with nothing else -- everything derives from this.
INTEGRATION_SHARD_COUNT = 8

def integration_shard_names():
    """Shard suffixes, e.g. ["s0", "s1", ...]. Used in target names and database names."""
    return ["s{}".format(i) for i in range(INTEGRATION_SHARD_COUNT)]

# Test files whose runtime is dominated by a few very slow tests, dealt out BEFORE everything
# else so that no two land in the same shard.
#
# Balancing by file count assumes files cost roughly the same. Measured, they do not: in shard
# s6, two files accounted for 58.5s of its 66.9s, and every other test in it finished in under
# 334ms. Both had landed in the same bucket, making that shard nearly twice the next slowest.
#
# Times are from `SERVICERADAR_TEST_SLOWEST` (see elixir/serviceradar_core/test/test_helper.exs):
#
#   47.2s  results_router_integration_test.exs:121
#            "large Armis sync chunks route through results router into inventory"
#   11.3s  plugin_result_slot_allocator_test.exs:55
#            "more than 257 synchronized identities retain distinct event blocks"
#
# This list is a hint, not a contract: a stale entry costs nothing but a slightly worse
# balance, and a missing one shows up as a single slow shard. Re-measure with
# `--test_env=SERVICERADAR_TEST_SLOWEST=12` when the wall clock drifts.
#
# NOTE: the 47.2s test is a genuine floor. No shard count divides a single test, so the
# slowest shard cannot go below roughly (fixed cost + 47s) until that test itself is cheaper.
_HEAVY_SRCS = [
    "test/serviceradar/results_router_integration_test.exs",
    "test/serviceradar/observability/plugin_result_slot_allocator_test.exs",
]

def partition_by_shard(srcs):
    """Split srcs into INTEGRATION_SHARD_COUNT disjoint, deterministic buckets.

    Two passes, both round-robin over a sorted list:

      1. the known-heavy files, so they are spread across different shards;
      2. everything else, which is uniform enough that file count is a fair proxy.

    Deliberately not grouped by directory: shards no longer need to align with subsystems now
    that each has its own database, and serviceradar_core's test tree is far too lopsided for
    directory grouping to balance anything -- one directory holds several hundred files and
    others hold two.

    Args:
      srcs: the ExUnit test files to partition.

    Returns:
      A dict of shard name -> list of srcs. Every shard is present even when empty, so the
      generated target list always matches the all-shard and focused provision targets.
    """
    names = integration_shard_names()
    buckets = {name: [] for name in names}

    heavy = [src for src in sorted(srcs) if src in _HEAVY_SRCS]
    rest = [src for src in sorted(srcs) if src not in _HEAVY_SRCS]

    for index, src in enumerate(heavy):
        buckets[names[index % INTEGRATION_SHARD_COUNT]].append(src)

    # Offset by len(heavy) so the light files keep filling round-robin from where the heavy
    # pass stopped, rather than piling the first few onto the shards that already hold one.
    for index, src in enumerate(rest):
        buckets[names[(index + len(heavy)) % INTEGRATION_SHARD_COUNT]].append(src)

    return buckets
