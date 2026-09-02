"""One async BEAM plus capacity-bounded serial BEAMs for core integration tests.

Ecto's SQL Sandbox isolates concurrent tests inside one BEAM when every query stays under the
test's rollback-only owner. It cannot isolate application-global state, database-global state, or
fixed external resources. The exhaustive disposition inventory therefore produces two source
classes:

* one async lane at ``max_cases: 8`` for audited transaction-owned or explicitly async modules;
* seven serial lanes at ``max_cases: 1`` for audited blockers, with fixed external resources
  confined to ``serial_0``.

Every lane receives a distinct disposable database cloned on ``srql-fixtures``. A 12-connection
Repo pool gives an eight-case async BEAM four checkout slots of headroom for test-supervised child
processes. Those slots are not reserved for deployed applications: no deployed ServiceRadar
application, demo, or production workload participates in this test topology.

The fixture currently reports 197 usable client slots (200 max minus three superuser-reserved).
The checked-in core topology consumes at most 96 configured pool slots. The ordinary wildcard also
selects three existing SRQL binaries, each with a five-slot pool and one administrator connection,
so the workflow-wide capacity preflight funds 114 possible connections. The connection observer
rechecks this live before a workflow run becomes ready and fails closed if the fixture can no
longer fund the complete selected set with ten-percent headroom.

The source-separated heavy workflow pins its parent test BEAM Repo to 12 connections. Its cold
bootstrap case temporarily starts a separate two-connection Repo plus one direct Postgrex admin
connection while the parent application is still alive, so that workflow reserves 15 possible
connections rather than only the parent pool.
"""

load(
    ":integration_test_dispositions.bzl",
    "ASYNC_INTEGRATION_SRCS",
    "FIXED_EXTERNAL_INTEGRATION_SRCS",
    "SERIAL_INTEGRATION_MODULE_COUNTS",
    "SERIAL_INTEGRATION_SELECTED_TEST_COUNTS",
)

INTEGRATION_ASYNC_MAX_CASES = 8
INTEGRATION_SERIAL_MAX_CASES = 1
INTEGRATION_REPO_POOL_SIZE = 12
INTEGRATION_MAX_BEAMS = 8
INTEGRATION_MAX_POOL_SLOTS = 96
INTEGRATION_AUXILIARY_CONNECTION_SLOTS = 18
INTEGRATION_WORKFLOW_CONNECTION_SLOTS = 114
FROZEN_FIXTURE_USABLE_CLIENT_SLOTS = 197

# Hermetic source-selection proof: deterministic selected and load-only chunks run concurrently
# in fresh BEAMs, keeping the always-on contract off the integration lifecycle critical path while
# still executing ExUnit's real filters for every ordinary source.
INTEGRATION_SELECTION_SELECTED_CHUNK_COUNT = 2
INTEGRATION_SELECTION_LOAD_ONLY_CHUNK_COUNT = 4

# This is a source-separated release-gate database suffix, not an ordinary lane.
LARGE_INGESTION_DB_SHARD = "large_ingestion"
LARGE_INGESTION_REPO_POOL_SIZE = 12
LARGE_INGESTION_BOOTSTRAP_POOL_SIZE = 2
LARGE_INGESTION_BOOTSTRAP_ADMIN_CONNECTION_SLOTS = 1
LARGE_INGESTION_WORKFLOW_CONNECTION_SLOTS = 15

FIXED_EXTERNAL_RESOURCE_LANE = "serial_0"

def _safe_pool_budget(usable_client_slots):
    if usable_client_slots < 0:
        fail("usable fixture client slots cannot be negative")
    return min(INTEGRATION_MAX_POOL_SLOTS, (usable_client_slots * 9) // 10)

def serial_lane_count_for_capacity(usable_client_slots, serial_source_count):
    """Returns the serial BEAM count funded by the frozen 12-slot-per-BEAM contract."""
    if serial_source_count < 0:
        fail("serial integration source count cannot be negative")
    if serial_source_count == 0:
        return 0

    funded_beams = _safe_pool_budget(usable_client_slots) // INTEGRATION_REPO_POOL_SIZE
    if funded_beams < 2:
        fail(
            "fixture capacity cannot fund one async and one serial integration BEAM: " +
            "usable_client_slots={} safe_pool_budget={} pool_per_beam={}".format(
                usable_client_slots,
                _safe_pool_budget(usable_client_slots),
                INTEGRATION_REPO_POOL_SIZE,
            ),
        )

    return min(serial_source_count, min(INTEGRATION_MAX_BEAMS - 1, funded_beams - 1))

INTEGRATION_SERIAL_LANE_COUNT = serial_lane_count_for_capacity(
    FROZEN_FIXTURE_USABLE_CLIENT_SLOTS,
    len(SERIAL_INTEGRATION_MODULE_COUNTS),
)

def integration_serial_lane_names():
    return ["serial_{}".format(index) for index in range(INTEGRATION_SERIAL_LANE_COUNT)]

def integration_lane_names():
    """Database suffixes and Bazel target suffixes for the complete ordinary topology."""
    return ["async"] + integration_serial_lane_names()

# Compatibility for the Rust provisioner while the generic lifecycle API still says "shard".
# The returned values are lane names; no s0..s7 database is part of the new topology.
def integration_shard_names():
    return integration_lane_names()

def integration_configured_pool_slots():
    return len(integration_lane_names()) * INTEGRATION_REPO_POOL_SIZE

def async_integration_sources():
    return list(ASYNC_INTEGRATION_SRCS)

def serial_source_module_counts():
    return dict(SERIAL_INTEGRATION_MODULE_COUNTS)

def serial_source_test_counts():
    return dict(SERIAL_INTEGRATION_SELECTED_TEST_COUNTS)

def fixed_external_resource_sources():
    return list(FIXED_EXTERNAL_INTEGRATION_SRCS)

def integration_selected_sources():
    return sorted(ASYNC_INTEGRATION_SRCS + SERIAL_INTEGRATION_MODULE_COUNTS.keys())

def integration_selection_source_sets(all_test_sources):
    """Returns the selected set plus deterministic chunks covering its exact complement."""
    selected = integration_selected_sources()
    source_set = {source: True for source in all_test_sources}

    for source in selected:
        if source not in source_set:
            fail("selected integration source is absent from ALL_TEST_SRCS: {}".format(source))

    selected_set = {source: True for source in selected}
    load_only = sorted([source for source in all_test_sources if source not in selected_set])
    selected_chunks = [[] for _index in range(INTEGRATION_SELECTION_SELECTED_CHUNK_COUNT)]
    chunks = [[] for _index in range(INTEGRATION_SELECTION_LOAD_ONLY_CHUNK_COUNT)]

    for index, source in enumerate(selected):
        selected_chunks[index % INTEGRATION_SELECTION_SELECTED_CHUNK_COUNT].append(source)

    for index, source in enumerate(load_only):
        chunks[index % INTEGRATION_SELECTION_LOAD_ONLY_CHUNK_COUNT].append(source)

    return struct(
        selected = selected,
        selected_chunks = selected_chunks,
        load_only_chunks = chunks,
    )

def integration_selection_runner_names():
    return struct(
        selected = [
            "integration_selection_selected_{}_runner".format(index)
            for index in range(INTEGRATION_SELECTION_SELECTED_CHUNK_COUNT)
        ],
        load_only = [
            "integration_selection_load_only_{}_runner".format(index)
            for index in range(INTEGRATION_SELECTION_LOAD_ONLY_CHUNK_COUNT)
        ],
    )

def integration_test_env(lane):
    """Returns the complete fail-closed runner environment for one audited lane."""
    if lane == "async":
        max_cases = INTEGRATION_ASYNC_MAX_CASES
    elif lane in integration_serial_lane_names():
        max_cases = INTEGRATION_SERIAL_MAX_CASES
    else:
        fail("unknown integration lane: {}".format(lane))

    return {
        "SERVICERADAR_ONLY_INTEGRATION": "1",
        "SERVICERADAR_INTEGRATION_MAX_CASES": str(max_cases),
        "SERVICERADAR_TEST_DATABASE_POOL_SIZE": str(INTEGRATION_REPO_POOL_SIZE),
        "SERVICERADAR_TEST_DB_SHARD": lane,
        "SERVICERADAR_TEST_LANE": lane,
        "SERVICERADAR_TEST_TOPOLOGY": "async_serial",
    }

def _source_weight(source):
    # One source-load unit plus one unit per exact test identity selected by ExUnit's real filters.
    # The database-free selection-equivalence test verifies this checked-in projection, so the LPT
    # input is structural and reproducible rather than a timing-derived weight.
    return 1 + SERIAL_INTEGRATION_SELECTED_TEST_COUNTS[source]

def _least_loaded_lane(lanes, loads, counts):
    selected = lanes[0]
    selected_key = (loads[selected], counts[selected], selected)

    for lane in lanes[1:]:
        candidate_key = (loads[lane], counts[lane], lane)
        if candidate_key < selected_key:
            selected = lane
            selected_key = candidate_key

    return selected

def partition_by_lane(all_test_sources):
    """Returns a deterministic, disjoint async/serial source map.

    ``all_test_sources`` is the complete BUILD glob. Unit-only sources are intentionally ignored,
    but every audited selected source must be present. The disposition inventory and its exact
    Starlark projection are checked independently by //:ci_heavy_gate_contract_test.
    """
    source_set = {source: True for source in all_test_sources}
    selected_sources = integration_selected_sources()

    for source in selected_sources:
        if source not in source_set:
            fail("audited integration source is absent from ALL_TEST_SRCS: {}".format(source))

    if len(selected_sources) != len({source: True for source in selected_sources}):
        fail("integration disposition projection contains duplicate sources")

    for source in FIXED_EXTERNAL_INTEGRATION_SRCS:
        if source not in SERIAL_INTEGRATION_MODULE_COUNTS:
            fail("fixed external resource source is not serial: {}".format(source))

    if sorted(SERIAL_INTEGRATION_SELECTED_TEST_COUNTS.keys()) != sorted(SERIAL_INTEGRATION_MODULE_COUNTS.keys()):
        fail("serial selected-test-count projection differs from serial source inventory")

    for source, test_count in SERIAL_INTEGRATION_SELECTED_TEST_COUNTS.items():
        if test_count <= 0:
            fail("serial selected-test count must be positive: {}={}".format(source, test_count))

    serial_lanes = integration_serial_lane_names()
    partitions = {lane: [] for lane in integration_lane_names()}
    loads = {lane: 0 for lane in serial_lanes}
    counts = {lane: 0 for lane in serial_lanes}
    partitions["async"] = list(ASYNC_INTEGRATION_SRCS)

    # Shared fixture-global NATS/JetStream identifiers must never overlap across BEAMs.
    for source in FIXED_EXTERNAL_INTEGRATION_SRCS:
        partitions[FIXED_EXTERNAL_RESOURCE_LANE].append(source)
        loads[FIXED_EXTERNAL_RESOURCE_LANE] += _source_weight(source)
        counts[FIXED_EXTERNAL_RESOURCE_LANE] += 1

    remaining_serial = [
        source
        for source in SERIAL_INTEGRATION_MODULE_COUNTS.keys()
        if source not in FIXED_EXTERNAL_INTEGRATION_SRCS
    ]
    ranked_sources = sorted([(-_source_weight(source), source) for source in remaining_serial])

    for negative_weight, source in ranked_sources:
        lane = _least_loaded_lane(serial_lanes, loads, counts)
        partitions[lane].append(source)
        loads[lane] += -negative_weight
        counts[lane] += 1

    for lane in integration_lane_names():
        partitions[lane] = sorted(partitions[lane])

    return partitions

# Compatibility for call sites that are migrated in the same change. New code should say lane.
def partition_by_shard(all_test_sources):
    return partition_by_lane(all_test_sources)
