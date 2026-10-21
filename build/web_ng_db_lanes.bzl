"""Disposable database lanes for the web-ng database targets.

Each name is a database suffix: the BazelCI web-ng DB action clones one
`sr_core_test_<run>_<lane>` database per entry with
//rust/integration-db:provision_generation_web_ng, and every web-ng database
target selects exactly one of them through SERVICERADAR_TEST_DB_SHARD. They are
distinct from the ordinary core lanes, so the web-ng action can run beside the
core integration action under its own run id, and its targets can run
concurrently because no two of them share a clone.
"""

WEB_NG_NETWORKS_LIVE_LANES = ["webng_net_0", "webng_net_1", "webng_net_2"]
WEB_NG_TOPOLOGY_ATLAS_LANES = ["webng_atlas_0", "webng_atlas_1"]
WEB_NG_PLUGIN_CONFIG_CLI_LANE = "webng_plugin_cli"

WEB_NG_DB_LANES = WEB_NG_NETWORKS_LIVE_LANES + WEB_NG_TOPOLOGY_ATLAS_LANES + [WEB_NG_PLUGIN_CONFIG_CLI_LANE]
