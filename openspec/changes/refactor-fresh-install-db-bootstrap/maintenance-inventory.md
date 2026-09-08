# Maintenance Migration Inventory

This inventory captures historical migrations that mix schema evolution with
operational maintenance. Baseline bootstrap skips these for empty databases by
marking included migrations as applied; upgrades still run them when needed.

Future migrations after the current baseline must keep this work off the
install-critical path. CI enforces that boundary with
`scripts/db/check-migration-startup-safety.sh`.

## Continuous Aggregate Creation And Refresh

These migrations create, rebuild, or refresh Timescale continuous aggregates.
Refresh calls are data maintenance and must not run synchronously during fresh
bootstrap.

- `20260203193000_add_ocsf_events_hourly_stats.exs`
- `20260203204000_ensure_ocsf_events_hourly_stats.exs`
- `20260207093000_add_ocsf_network_activity_rollups.exs`
- `20260207112000_ensure_ocsf_network_activity_rollups.exs`
- `20260220110000_add_srql_metric_hourly_caggs.exs`
- `20260301120000_add_flow_traffic_hierarchical_caggs.exs`
- `20260314054000_add_traces_stats_5m_cagg.exs`
- `20260314072500_rebuild_traces_stats_5m_with_otel_error_status.exs`
- `20260314113000_replace_otel_metrics_hourly_stats_with_cagg.exs`
- `20260315120000_ensure_ocsf_events_hourly_stats_cagg.exs`

## Retention And Policy Maintenance

These migrations register Timescale retention or continuous aggregate policies.
Policy state is part of the desired schema, but retrying policy registration
does not need to block an empty database from becoming ready.

- `20260120021558_ensure_discovered_interfaces_hypertable.exs`
- `20260120130000_update_interface_observations.exs`
- `20260126121000_retry_timescaledb_hypertables.exs`
- `20260129154221_add_observability_retention_policies.exs`
- `20260203120000_create_ocsf_events.exs`
- `20260207090000_add_ocsf_network_activity_retention_policy.exs`
- `20260218235900_create_bmp_routing_events.exs`
- `20260228090000_create_mtr_traces_hypertables.exs`
- `20260429220000_update_observability_retention_policies.exs`

## Data Backfills And Cleanup Updates

These migrations update existing product data. They are upgrade work, not
fresh-install provisioning.

- `20260206130000_migrate_role_profile_permission_keys.exs`
- `20260211130000_fix_dire_incorrect_mac_merge_cleanup.exs`
- `20260211140000_fix_dire_agent_deduplication_cleanup.exs`
- `20260213201000_enforce_unique_active_device_ip.exs`
- `20260221133000_add_policy_fields_to_plugin_assignments.exs`
- `20260306013000_update_timeseries_metric_series_identity.exs`
- `20260324123000_add_health_fields_to_camera_analysis_workers.exs`
- `20260429043500_raise_otx_plugin_timeout_schema.exs`
- `20260429052000_filter_otx_plugin_to_netflow_indicators.exs`
- `20260429060000_optimize_otx_retrohunt_and_reset_cursor.exs`
- `20260509120000_repair_camera_polluted_agent_devices.exs`
- `20260511120000_disable_manual_plugin_assignments_shadowed_by_policy.exs`
- `20260518133000_add_partition_id_to_edge_onboarding_packages.exs`
- `20260518144500_disable_default_geoip_enrichment.exs`

## Operational Repair And Retry Loops

These migrations include sleeps, retry loops, object moves, or public-schema
cleanup. They are historically necessary for upgrades, but are not valid fresh
bootstrap primitives.

- `20260119051352_add_mapper_topology_links.exs`
- `20260119090000_add_age_graph_serviceradar.exs`
- `20260126120000_move_public_schema_objects_to_platform.exs`
- `20260204090000_use_platform_age_graph.exs`
- `20260210120000_convert_trace_summaries_to_table.exs`
- `20260226230000_fix_trace_summaries_schema.exs`
