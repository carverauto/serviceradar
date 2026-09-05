defmodule ServiceRadarWebNGWeb.SRQL.Catalog do
  @moduledoc false

  @wifi_site_filter_fields [
    "source_id",
    "site_code",
    "iata",
    "name",
    "site_name",
    "site_type",
    "region",
    "latitude",
    "lat",
    "longitude",
    "lon",
    "lng",
    "ap_count",
    "up_count",
    "down_count",
    "wlc_count",
    "ap_family",
    "wlc_model",
    "aos_version",
    "server_group",
    "cluster",
    "aaa_profile",
    "all_server_groups",
    "controller_names",
    "controllers"
  ]

  @wifi_site_numeric_fields [
    "latitude",
    "lat",
    "longitude",
    "lon",
    "lng",
    "ap_count",
    "up_count",
    "down_count",
    "wlc_count"
  ]

  @wifi_device_filter_fields [
    "id",
    "source_id",
    "batch_id",
    "device_uid",
    "site_code",
    "iata",
    "site_name",
    "region",
    "latitude",
    "lat",
    "longitude",
    "lon",
    "lng",
    "name",
    "hostname",
    "host",
    "mac",
    "serial",
    "ip",
    "status",
    "model"
  ]

  @wifi_device_numeric_fields ["latitude", "lat", "longitude", "lon", "lng"]

  @entities [
    %{
      id: "dashboards",
      label: "Dashboards",
      route: "/dashboards",
      default_time: "",
      default_sort_field: "title",
      default_sort_dir: "asc",
      default_filter_field: "title",
      filter_fields: ["title", "description", "slug", "dashboard_ref", "id", "type", "status"],
      downsample: false
    },
    %{
      id: "agents",
      label: "Agents",
      route: "/agents",
      default_time: "",
      default_sort_field: "last_seen",
      default_sort_dir: "desc",
      default_filter_field: "uid",
      filter_fields: [
        "uid",
        "name",
        "gateway_id",
        "version",
        "desired_version",
        "release_rollout_state",
        "last_update_error",
        "vendor_name",
        "host",
        "ip",
        "type_id",
        "capabilities",
        "config_source"
      ],
      array_fields: ["capabilities"],
      downsample: false
    },
    %{
      id: "addon_fleet",
      label: "Add-on Fleet",
      route: "/settings/agents/addons/fleet",
      default_time: "",
      default_sort_field: "category",
      default_sort_dir: "asc",
      default_filter_field: "category",
      filter_fields: [
        "agent_uid",
        "agent_label",
        "addon_id",
        "addon_name",
        "assigned_version",
        "observed_state",
        "observed_version",
        "category",
        "reason_code",
        "rollout_state",
        "update_policy",
        "package_status",
        "degradation_reason",
        "assigned",
        "active",
        "evidence_age_seconds"
      ],
      boolean_fields: ["assigned", "active"],
      numeric_fields: ["evidence_age_seconds"],
      known_values: %{
        "category" => [
          "healthy",
          "updating",
          "action_required",
          "unavailable",
          "expected_inactive",
          "observed_only"
        ],
        "assigned" => ["true", "false"],
        "active" => ["true", "false"]
      },
      downsample: false
    },
    %{
      id: "devices",
      label: "Devices",
      route: "/devices",
      default_time: "",
      default_sort_field: "last_seen",
      default_sort_dir: "desc",
      default_filter_field: "hostname",
      filter_fields: [
        "hostname",
        "ip",
        "mac",
        "uid",
        "gateway_id",
        "agent_id",
        "availability_source_agent_id",
        "available_from_agent",
        "unavailable_from_agent",
        "is_available",
        "is_active",
        "is_managed",
        "is_compliant",
        "is_trusted",
        "type_id",
        "type",
        "vendor_name",
        "discovery_sources",
        "awx_managed",
        "tags",
        "include_inactive",
        "include_deleted",
        "first_seen",
        "first_seen_time",
        "cve",
        "cve_id",
        "kev"
      ],
      boolean_fields: [
        "is_available",
        "is_active",
        "is_managed",
        "is_compliant",
        "is_trusted",
        # Derived predicate: device is in an AWX inventory / ansible-capable
        # (backed by `metadata.awx.host_id`/`controller_id`, falling back to the
        # `awx`/`ansible` discovery source). More discoverable than
        # `discovery_sources:(awx)` and semantically "manageable by AWX".
        "awx_managed",
        "include_inactive",
        "include_deleted",
        "kev"
      ],
      # Fields backed by array columns - builder will always use list syntax for these
      array_fields: ["discovery_sources", "tags"],
      # Low-cardinality fields with a stable, curated value set. Editors offer
      # these as completions so users discover the correct spelling/syntax (e.g.
      # `discovery_sources:(awx)`) instead of guessing `%awx%`. Static by design:
      # never run `SELECT DISTINCT` per keystroke.
      known_values: %{
        "first_seen" => ["last_7d", "last_30d", "last_90d", "today"],
        "first_seen_time" => ["last_7d", "last_30d", "last_90d", "today"],
        "discovery_sources" => [
          "agent",
          "sweep",
          "armis",
          "proxmox",
          "mapper",
          "sighting",
          "hypervisor_enrichment",
          "sysmon",
          "awx",
          "passive-netprobe",
          "camera_plugin",
          "manual"
        ],
        # Derived boolean filter (see boolean_fields): editors offer the two
        # truth values after `awx_managed:` so the completion is self-documenting.
        "awx_managed" => ["true", "false"]
      },
      # Fields that support GROUP BY in stats queries (stats:count() as count by <field>)
      stats_fields: [
        "type",
        "vendor_name",
        "risk_level",
        "is_available",
        "is_active",
        "gateway_id",
        "tags.<key>",
        "metadata.<key>"
      ],
      downsample: false
    },
    # Identity reconciliation diagnostics. All five ride `devices.view` and all
    # five are read-only; they route to /devices because they explain what is
    # (and is no longer) in device inventory rather than owning a page.
    %{
      id: "merge_audit",
      label: "Device Merges",
      route: "/devices",
      default_time: "",
      default_sort_field: "created_at",
      default_sort_dir: "desc",
      default_filter_field: "device_id",
      filter_fields: [
        "device_id",
        "from_device_id",
        "to_device_id",
        "reason",
        "source",
        "confidence_score",
        # Resolves the whole canonical chain from one uid, both directions.
        "chain",
        "depth",
        "include_unmerge"
      ],
      boolean_fields: ["include_unmerge"],
      downsample: false
    },
    %{
      id: "device_revival_audit",
      label: "Device Revivals",
      route: "/devices",
      default_time: "",
      default_sort_field: "revived_at",
      default_sort_dir: "desc",
      default_filter_field: "device_uid",
      filter_fields: [
        "device_uid",
        "previous_deleted_by",
        "previous_deleted_reason",
        "revived_by_application"
      ],
      downsample: false
    },
    %{
      id: "device_identifiers",
      label: "Device Identifiers",
      route: "/devices",
      default_time: "",
      default_sort_field: "last_seen",
      default_sort_dir: "desc",
      default_filter_field: "device_id",
      filter_fields: [
        "device_id",
        "identifier_type",
        "value",
        "partition",
        "confidence",
        "source",
        "verified",
        "owner_deleted",
        "matches_current_facts"
      ],
      boolean_fields: ["verified", "owner_deleted", "matches_current_facts"],
      known_values: %{
        "identifier_type" => [
          "agent_id",
          "armis_device_id",
          "integration_id",
          "netbox_device_id",
          "hardware_serial",
          "mac",
          "ip",
          "passive_fingerprint"
        ],
        "confidence" => ["strong", "medium", "weak"]
      },
      downsample: false
    },
    %{
      id: "identity_reconciliation_runs",
      label: "Identity Reconciliation Runs",
      route: "/devices",
      default_time: "",
      default_sort_field: "started_at",
      default_sort_dir: "desc",
      default_filter_field: "status",
      filter_fields: [
        "run_id",
        "status",
        "trigger",
        "merge_cap_reached",
        "merges",
        "errors",
        "blocked_components",
        "largest_blocked_component",
        "duration_ms"
      ],
      boolean_fields: ["merge_cap_reached"],
      known_values: %{
        "status" => ["completed", "failed"],
        "trigger" => ["scheduled", "manual"]
      },
      downsample: false
    },
    %{
      id: "identity_evidence_edges",
      label: "Identity Evidence",
      route: "/devices",
      default_time: "",
      default_sort_field: "depth",
      default_sort_dir: "asc",
      # A seed is mandatory: an unseeded walk is a self-join across the whole
      # identifier table and is refused rather than served slowly.
      default_filter_field: "device",
      filter_fields: ["device", "identifier_type", "depth"],
      known_values: %{
        "identifier_type" => [
          "agent_id",
          "armis_device_id",
          "integration_id",
          "netbox_device_id",
          "hardware_serial",
          "mac",
          "ip",
          "passive_fingerprint"
        ]
      },
      downsample: false
    },
    %{
      id: "gateways",
      label: "Gateways",
      route: "/gateways",
      default_time: "",
      default_sort_field: "last_seen",
      default_sort_dir: "desc",
      default_filter_field: "id",
      filter_fields: ["id", "status", "component_id", "registration_source", "is_healthy"],
      boolean_fields: ["is_healthy"],
      downsample: false
    },
    # Sweep diagnostics (issue 4167): declared sweep configuration plus its
    # execution/result history. `sweep_groups`/`sweep_profiles` are config and
    # route to the page that manages them; `sweep_executions`/`sweep_results`/
    # `sweep_coverage` are read-only history and route to /devices, following
    # the identity-reconciliation-diagnostics precedent above.
    %{
      id: "sweep_groups",
      label: "Sweep Groups",
      route: "/settings/networks",
      default_time: "",
      default_sort_field: "name",
      default_sort_dir: "asc",
      default_filter_field: "partition",
      filter_fields: [
        "name",
        "partition",
        "schedule_type",
        "enabled",
        "profile_id",
        "agent_id"
      ],
      boolean_fields: ["enabled"],
      known_values: %{
        "schedule_type" => ["interval", "cron", "manual"]
      },
      downsample: false
    },
    # Admin-only scanner profiles (`admin_only == true`) are excluded from
    # this entity unconditionally, matching the row-level read restriction
    # the settings page enforces via Ash (`sweep_profile.ex`). SRQL's raw-SQL
    # path has no actor/scope context to authorize per caller, so the
    # restriction is applied to every query rather than being conditional on
    # the viewer's role. A missing admin-only profile therefore means
    # "restricted", not "no such profile". `admin_only` is not offered as a
    # filter field here: the SRQL entity rejects it as unsupported, since
    # every query is already unconditionally restricted to `admin_only =
    # false` and accepting it as a caller filter would only ever produce
    # either a redundant or a contradictory (and rejected) query.
    %{
      id: "sweep_profiles",
      label: "Sweep Profiles",
      route: "/settings/networks",
      default_time: "",
      default_sort_field: "name",
      default_sort_dir: "asc",
      default_filter_field: "name",
      filter_fields: ["name", "enabled"],
      boolean_fields: ["enabled"],
      downsample: false
    },
    %{
      id: "sweep_executions",
      label: "Sweep Executions",
      route: "/settings/networks",
      default_time: "",
      default_sort_field: "started_at",
      default_sort_dir: "desc",
      default_filter_field: "sweep_group_id",
      filter_fields: ["status", "agent_id", "config_version", "sweep_group_id"],
      known_values: %{
        "status" => ["pending", "running", "completed", "failed"]
      },
      downsample: false
    },
    # `sweep_host_results` is pruned at a 7-day retention default (see
    # `DataRetentionWorker`); an empty result for an older window means
    # "outside the retention window", not "no sweep activity" — query
    # `sweep_coverage` for the daily rollup that survives past 7 days.
    %{
      id: "sweep_results",
      label: "Sweep Results",
      route: "/devices",
      default_time: "last_24h",
      default_sort_field: "inserted_at",
      default_sort_dir: "desc",
      default_filter_field: "device_id",
      filter_fields: [
        "ip",
        "hostname",
        "status",
        "device_id",
        "agent_id",
        "sweep_group_id",
        "execution_id"
      ],
      known_values: %{
        "status" => ["available", "unavailable", "timeout", "error"]
      },
      downsample: false
    },
    %{
      id: "sweep_coverage",
      label: "Sweep Coverage",
      route: "/devices",
      default_time: "last_30d",
      default_sort_field: "day",
      default_sort_dir: "desc",
      default_filter_field: "device_uid",
      filter_fields: ["device_uid", "ip", "agent_id", "sweep_group_id"],
      downsample: false
    },
    # Declared-vs-observed diagnostic view (issue 4167, task 4): finds a sweep
    # group that was told to target a device but produced no coverage rows
    # for it (`relationship = "declared_not_observed"`).
    %{
      id: "device_sweep_overlap",
      label: "Sweep Declared vs Observed",
      route: "/devices",
      default_time: "",
      # Deliberately blank. `declared_not_observed` rows carry a NULL
      # `last_seen_at` by construction -- never observed is what makes them the
      # alert -- so the Rust query defaults to a compound sort that lifts them
      # ahead of the ordinary rows. An explicit `sort:` from the caller replaces
      # that default entirely, and naming a field here would make the visual
      # builder emit exactly such a token on every query it builds, burying the
      # alerts behind a prefix that at this view's scale exceeds
      # `max_cursor_offset` and so cannot even be paged past.
      default_sort_field: "",
      default_sort_dir: "desc",
      default_filter_field: "device_uid",
      filter_fields: [
        "device_uid",
        "ip",
        "sweep_group_id",
        "agent_id",
        "relationship",
        "declared",
        "observed"
      ],
      boolean_fields: ["declared", "observed"],
      known_values: %{
        "relationship" => [
          "declared_and_observed",
          "declared_not_observed",
          "observed_not_declared"
        ]
      },
      downsample: false
    },
    %{
      id: "events",
      label: "Events",
      route: "/observability/events",
      route_params: %{},
      default_time: "last_7d",
      default_sort_field: "time",
      default_sort_dir: "desc",
      default_filter_field: "message",
      filter_fields: [
        "id",
        "event_id",
        "activity_name",
        "activity_id",
        "class_uid",
        "category_uid",
        "type_uid",
        "severity",
        "severity_id",
        "log_level",
        "log_name",
        "log_provider",
        "source",
        "source_type",
        "addon_id",
        "status",
        "status_id",
        "status_code",
        "status_detail",
        "trace_id",
        "span_id",
        "uid",
        "device_id",
        "source_device_uid",
        "service_radar_device_uid",
        "host",
        "message",
        "short_message"
      ],
      downsample: false
    },
    %{
      id: "composite_results",
      label: "Composite Check Results",
      # Must match the router. `page_test.exs` asserts every catalog route is
      # routable, which is what caught this pointing at a path that never
      # existed — composite checks live under Networks.
      route: "/settings/networks/composite-checks",
      default_time: "",
      default_sort_field: "evaluated_at",
      default_sort_dir: "desc",
      default_filter_field: "check",
      filter_fields: [
        "check",
        "check_name",
        "verdict",
        "status",
        "device_uid"
      ],
      # Verdict slugs are operator-defined per check, so they cannot be listed
      # statically. `status` is a fixed enum and can be.
      known_values: %{
        "status" => ["healthy", "degraded", "down", "unknown"]
      },
      stats_fields: ["verdict", "status", "check"],
      downsample: false
    },
    %{
      id: "capacity_forecasts",
      label: "Capacity Forecasts",
      route: "/observability/health",
      default_time: "",
      default_sort_field: "projected_exhaustion_at",
      default_sort_dir: "asc",
      default_filter_field: "resource_label",
      filter_fields: [
        "resource_id",
        "resource_key",
        "resource_label",
        "metric_name",
        "status",
        "skip_reason",
        "has_exhaustion"
      ],
      boolean_fields: ["has_exhaustion"],
      downsample: false
    },
    %{
      id: "security_findings",
      label: "Security Findings",
      route: "/security",
      default_time: "",
      default_sort_field: "time",
      default_sort_dir: "desc",
      default_filter_field: "severity",
      filter_fields: [
        "activity_name",
        "activity_id",
        "class_uid",
        "category_uid",
        "type_uid",
        "severity",
        "severity_id",
        "log_name",
        "log_provider",
        "source",
        "source_type",
        "addon_id",
        "status",
        "status_id",
        "device_id",
        "uid",
        "source_device_uid",
        "finding_uid",
        "purl",
        "purl_canonical",
        "canonical_purl",
        "cpe",
        "cve",
        "message",
        "short_message"
      ],
      numeric_fields: ["class_uid", "category_uid", "type_uid", "activity_id", "severity_id", "status_id"],
      downsample: false
    },
    %{
      id: "scan_activity",
      label: "Scan Activity",
      route: "/security",
      default_time: "",
      default_sort_field: "time",
      default_sort_dir: "desc",
      default_filter_field: "status",
      filter_fields: [
        "activity_name",
        "activity_id",
        "class_uid",
        "category_uid",
        "type_uid",
        "severity",
        "severity_id",
        "log_name",
        "log_provider",
        "source",
        "source_type",
        "addon_id",
        "status",
        "status_id",
        "device_id",
        "uid",
        "source_device_uid",
        "message",
        "short_message"
      ],
      numeric_fields: ["class_uid", "category_uid", "type_uid", "activity_id", "severity_id", "status_id"],
      downsample: false
    },
    %{
      id: "dns_activity",
      label: "DNS Activity",
      route: "/security",
      default_time: "",
      default_sort_field: "time",
      default_sort_dir: "desc",
      default_filter_field: "message",
      filter_fields: [
        "activity_name",
        "activity_id",
        "class_uid",
        "category_uid",
        "type_uid",
        "severity",
        "severity_id",
        "log_name",
        "log_provider",
        "source",
        "source_type",
        "addon_id",
        "status",
        "status_id",
        "device_id",
        "uid",
        "source_device_uid",
        "message",
        "short_message"
      ],
      numeric_fields: ["class_uid", "category_uid", "type_uid", "activity_id", "severity_id", "status_id"],
      downsample: false
    },
    %{
      id: "bmp_events",
      label: "BMP Events",
      route: "/observability/bmp",
      default_time: "last_24h",
      default_sort_field: "time",
      default_sort_dir: "desc",
      default_filter_field: "router_ip",
      filter_fields: [
        "event_type",
        "severity_id",
        "router_id",
        "router_ip",
        "peer_ip",
        "peer_asn",
        "local_asn",
        "prefix",
        "message"
      ],
      downsample: false
    },
    %{
      id: "field_survey_sessions",
      label: "FieldSurvey Sessions",
      route: "/spatial/field-surveys",
      default_time: "",
      default_sort_field: "updated_at",
      default_sort_dir: "desc",
      default_filter_field: "site_id",
      filter_fields: [
        "session_id",
        "user_id",
        "site_id",
        "site_name",
        "building_id",
        "building_name",
        "floor_id",
        "floor_name",
        "floor_index",
        "tags",
        "has_floorplan"
      ],
      array_fields: ["tags"],
      boolean_fields: ["has_floorplan"],
      downsample: false
    },
    %{
      id: "field_survey_rasters",
      label: "FieldSurvey Rasters",
      route: "/spatial/field-surveys",
      default_time: "",
      default_sort_field: "generated_at",
      default_sort_dir: "desc",
      default_filter_field: "site_id",
      filter_fields: [
        "raster_id",
        "session_id",
        "user_id",
        "overlay_type",
        "selector_type",
        "selector_value",
        "site_id",
        "site_name",
        "building_id",
        "building_name",
        "floor_id",
        "floor_name",
        "floor_index",
        "tags",
        "has_floorplan"
      ],
      array_fields: ["tags"],
      boolean_fields: ["has_floorplan"],
      downsample: false
    },
    %{
      id: "field_survey_artifacts",
      label: "FieldSurvey Artifacts",
      route: "/spatial/field-surveys",
      default_time: "",
      default_sort_field: "uploaded_at",
      default_sort_dir: "desc",
      default_filter_field: "artifact_type",
      filter_fields: [
        "artifact_id",
        "session_id",
        "user_id",
        "artifact_type",
        "content_type",
        "object_key",
        "sha256",
        "site_id",
        "site_name",
        "building_id",
        "building_name",
        "floor_id",
        "floor_name",
        "floor_index",
        "tags"
      ],
      array_fields: ["tags"],
      downsample: false
    },
    %{
      id: "field_survey_rf_observations",
      label: "FieldSurvey RF Observations",
      route: "/spatial/field-surveys",
      default_time: "last_1h",
      default_sort_field: "captured_at",
      default_sort_dir: "desc",
      default_filter_field: "bssid",
      filter_fields: [
        "id",
        "session_id",
        "sidekick_id",
        "radio_id",
        "interface_name",
        "bssid",
        "ssid",
        "frame_type",
        "frequency_mhz",
        "channel",
        "rssi_dbm",
        "noise_floor_dbm",
        "snr_db"
      ],
      downsample: false
    },
    %{
      id: "field_survey_pose_samples",
      label: "FieldSurvey Pose Samples",
      route: "/spatial/field-surveys",
      default_time: "last_1h",
      default_sort_field: "captured_at",
      default_sort_dir: "desc",
      default_filter_field: "session_id",
      filter_fields: [
        "id",
        "session_id",
        "scanner_device_id",
        "tracking_quality",
        "x",
        "y",
        "z"
      ],
      downsample: false
    },
    %{
      id: "field_survey_rf_pose_matches",
      label: "FieldSurvey RF/Pose Matches",
      route: "/spatial/field-surveys",
      default_time: "last_1h",
      default_sort_field: "rf_captured_at",
      default_sort_dir: "desc",
      default_filter_field: "bssid",
      filter_fields: [
        "rf_observation_id",
        "pose_sample_id",
        "session_id",
        "sidekick_id",
        "radio_id",
        "interface_name",
        "bssid",
        "ssid",
        "frame_type",
        "frequency_mhz",
        "channel",
        "rssi_dbm",
        "pose_offset_nanos",
        "scanner_device_id",
        "tracking_quality"
      ],
      downsample: false
    },
    %{
      id: "field_survey_spectrum_observations",
      label: "FieldSurvey Spectrum Observations",
      route: "/spatial/field-surveys",
      default_time: "last_1h",
      default_sort_field: "captured_at",
      default_sort_dir: "desc",
      default_filter_field: "sdr_id",
      filter_fields: [
        "id",
        "session_id",
        "sidekick_id",
        "sdr_id",
        "device_kind",
        "serial_number",
        "sweep_id",
        "start_frequency_hz",
        "stop_frequency_hz",
        "sample_count"
      ],
      downsample: false
    },
    %{
      id: "wifi_sites",
      label: "WiFi Sites",
      route: "/devices/wifi",
      default_time: "",
      default_sort_field: "collection_timestamp",
      default_sort_dir: "desc",
      default_filter_field: "site_code",
      filter_fields: @wifi_site_filter_fields,
      numeric_fields: @wifi_site_numeric_fields,
      array_fields: ["all_server_groups", "controller_names", "controllers"],
      downsample: false
    },
    %{
      id: "wifi_site_snapshots",
      label: "WiFi Site Snapshots",
      route: "/devices/wifi",
      default_time: "last_24h",
      default_sort_field: "collection_timestamp",
      default_sort_dir: "desc",
      default_filter_field: "site_code",
      filter_fields: [
        "id",
        "source_id",
        "batch_id",
        "site_code",
        "iata",
        "ap_count",
        "up_count",
        "down_count",
        "wlc_count",
        "server_group",
        "cluster",
        "aaa_profile",
        "all_server_groups",
        "controller_names",
        "controllers"
      ],
      numeric_fields: ["ap_count", "up_count", "down_count", "wlc_count"],
      array_fields: ["all_server_groups", "controller_names", "controllers"],
      downsample: false
    },
    %{
      id: "wifi_aps",
      label: "WiFi Access Points",
      route: "/devices/wifi",
      default_time: "last_24h",
      default_sort_field: "collection_timestamp",
      default_sort_dir: "desc",
      default_filter_field: "hostname",
      filter_fields: @wifi_device_filter_fields ++ ["vendor_name", "vendor"],
      numeric_fields: @wifi_device_numeric_fields,
      downsample: false
    },
    %{
      id: "wifi_controllers",
      label: "WiFi Controllers",
      route: "/devices/wifi",
      default_time: "last_24h",
      default_sort_field: "collection_timestamp",
      default_sort_dir: "desc",
      default_filter_field: "hostname",
      filter_fields: @wifi_device_filter_fields ++ ["aos_version", "base_mac", "psu_status"],
      numeric_fields: @wifi_device_numeric_fields,
      downsample: false
    },
    %{
      id: "wifi_radius_groups",
      label: "WiFi RADIUS Groups",
      route: "/devices/wifi",
      default_time: "last_24h",
      default_sort_field: "collection_timestamp",
      default_sort_dir: "desc",
      default_filter_field: "server_group",
      filter_fields: [
        "id",
        "source_id",
        "batch_id",
        "controller_device_uid",
        "site_code",
        "iata",
        "site_name",
        "region",
        "latitude",
        "lat",
        "longitude",
        "lon",
        "lng",
        "controller_alias",
        "controller",
        "aaa_profile",
        "server_group",
        "cluster",
        "all_server_groups",
        "status"
      ],
      numeric_fields: @wifi_device_numeric_fields,
      array_fields: ["all_server_groups"],
      downsample: false
    },
    %{
      id: "wifi_fleet_history",
      label: "WiFi Fleet History",
      route: "/devices/wifi",
      default_time: "",
      default_sort_field: "build_date",
      default_sort_dir: "desc",
      default_filter_field: "build_date",
      filter_fields: [
        "source_id",
        "batch_id",
        "build_date",
        "date",
        "ap_total",
        "count_2xx",
        "count_3xx",
        "count_4xx",
        "count_5xx",
        "count_6xx",
        "count_7xx",
        "count_other",
        "count_ap325",
        "pct_6xx",
        "pct_legacy",
        "site_count"
      ],
      numeric_fields: [
        "ap_total",
        "count_2xx",
        "count_3xx",
        "count_4xx",
        "count_5xx",
        "count_6xx",
        "count_7xx",
        "count_other",
        "count_ap325",
        "pct_6xx",
        "pct_legacy",
        "site_count"
      ],
      downsample: false
    },
    %{
      id: "wifi_site_references",
      label: "WiFi Site References",
      route: "/devices/wifi",
      default_time: "",
      default_sort_field: "updated_at",
      default_sort_dir: "desc",
      default_filter_field: "site_code",
      filter_fields: [
        "source_id",
        "site_code",
        "iata",
        "name",
        "site_name",
        "site_type",
        "region",
        "latitude",
        "lat",
        "longitude",
        "lon",
        "lng",
        "reference_hash"
      ],
      numeric_fields: ["latitude", "lat", "longitude", "lon", "lng"],
      downsample: false
    },
    %{
      id: "alerts",
      label: "Alerts",
      route: "/observability/alerts",
      route_params: %{},
      default_time: "last_7d",
      default_sort_field: "timestamp",
      default_sort_dir: "desc",
      default_filter_field: "title",
      filter_fields: [
        "id",
        "title",
        "status",
        "severity",
        "source_type",
        "source_id",
        "device_uid",
        "agent_uid",
        "event_id"
      ],
      downsample: false
    },
    %{
      id: "logs",
      label: "Logs",
      route: "/observability/logs",
      route_params: %{},
      default_time: "last_24h",
      default_sort_field: "timestamp",
      default_sort_dir: "desc",
      default_filter_field: "message",
      filter_fields: [
        "uid",
        "id",
        "device_id",
        "source_device_uid",
        "gateway_id",
        "agent_id",
        "severity",
        "severity_text",
        "severity_number",
        "source",
        "source_ip",
        "service_name",
        "service",
        "host",
        "hostname",
        "body",
        "message",
        "event_name",
        "facility",
        "scope_name",
        "scope_version",
        "trace_id",
        "span_id",
        "ingest_identity",
        "ingest_agent_id",
        "ingest_partition"
      ],
      numeric_fields: ["severity_number"],
      # Canonical normalized OTel severity texts (see log_promotion_parser.ex).
      known_values: %{
        "severity_text" => ["FATAL", "ERROR", "WARN", "INFO", "DEBUG"]
      },
      downsample: false
    },
    %{
      id: "otel_trace_summaries",
      label: "Traces",
      route: "/observability/traces",
      route_params: %{},
      default_time: "last_24h",
      default_sort_field: "timestamp",
      default_sort_dir: "desc",
      default_filter_field: "trace_id",
      filter_fields: [
        "trace_id",
        "root_service_name",
        "root_span_name",
        "error_count",
        "span_count",
        "duration_ms"
      ],
      numeric_fields: ["error_count", "span_count", "duration_ms"],
      downsample: false
    },
    %{
      id: "otel_traces",
      label: "Spans",
      route: "/observability/traces",
      route_params: %{},
      default_time: "last_24h",
      default_sort_field: "timestamp",
      default_sort_dir: "desc",
      default_filter_field: "trace_id",
      filter_fields: [
        "trace_id",
        "span_id",
        "parent_span_id",
        "service_name",
        "name",
        "status_code",
        "ingest_identity",
        "ingest_agent_id",
        "ingest_partition"
      ],
      numeric_fields: ["status_code"],
      downsample: false
    },
    %{
      # SRQL parses `in:traces` as an alias of `in:otel_traces` (span rows).
      id: "traces",
      label: "Spans",
      route: "/observability/traces",
      route_params: %{},
      default_time: "last_24h",
      default_sort_field: "timestamp",
      default_sort_dir: "desc",
      default_filter_field: "trace_id",
      filter_fields: [
        "trace_id",
        "span_id",
        "parent_span_id",
        "service_name",
        "name",
        "status_code",
        "ingest_identity",
        "ingest_agent_id",
        "ingest_partition"
      ],
      numeric_fields: ["status_code"],
      downsample: false
    },
    %{
      id: "otel_metrics",
      label: "Metrics",
      route: "/observability/metrics",
      route_params: %{},
      default_time: "last_24h",
      default_sort_field: "timestamp",
      default_sort_dir: "desc",
      default_filter_field: "trace_id",
      filter_fields: [
        "trace_id",
        "span_id",
        "service_name",
        "span_name",
        "metric_type",
        "is_slow",
        "ingest_identity",
        "ingest_agent_id",
        "ingest_partition"
      ],
      boolean_fields: ["is_slow"],
      downsample: false
    },
    %{
      # Real OTLP metric data points (sum/gauge/histogram) written by the
      # EventWriter pipeline — distinct from the span-derived samples in
      # `otel_metrics`. SRQL also accepts the `metric_points` alias.
      id: "otel_metric_points",
      label: "OTLP Metrics",
      route: "/observability/metrics",
      route_params: %{"mview" => "points"},
      default_time: "last_24h",
      default_sort_field: "timestamp",
      default_sort_dir: "desc",
      default_filter_field: "metric_name",
      filter_fields: [
        "metric_name",
        "service_name",
        "metric_type",
        "unit",
        "temporality",
        "ingest_identity",
        "ingest_agent_id",
        "ingest_partition"
      ],
      downsample: false
    },
    %{
      id: "threat_intel_matches",
      label: "Threat Intel Matches",
      route: "/security/threat-intel",
      default_time: "",
      default_sort_field: "evaluated_at",
      default_sort_dir: "desc",
      default_filter_field: "source",
      filter_fields: [
        "observed_ip",
        "ip",
        "source",
        "label",
        "indicator",
        "indicator_id",
        "indicator_type",
        "severity",
        "confidence",
        "match_kind",
        "stale",
        "status"
      ],
      numeric_fields: ["severity", "confidence"],
      address_fields: ["observed_ip", "ip", "indicator"],
      examples: [
        "in:threat_intel_matches source:alienvault_otx sort:evaluated_at:desc limit:100",
        "in:threat_intel_matches observed_ip:198.51.100.10",
        "in:flows threat_matched:true time:last_24h sort:time:desc limit:100"
      ],
      downsample: false
    },
    %{
      id: "flows",
      label: "Flows",
      route: "/observability/netflows",
      route_params: %{},
      default_time: "last_24h",
      default_sort_field: "time",
      default_sort_dir: "desc",
      default_filter_field: "src_endpoint_ip",
      # Row / table explorer allowlist (broader than chart path).
      filter_fields: [
        "src_endpoint_ip",
        "src_ip",
        "dst_endpoint_ip",
        "dst_ip",
        # Bidirectional: matches either endpoint, like the bare `near:` / `tag:` forms.
        "ip",
        "endpoint_ip",
        "cidr",
        "src_endpoint_port",
        "src_port",
        "dst_endpoint_port",
        "dst_port",
        # Bidirectional port (either side of the 5-tuple). Prefer `port:22` over
        # unsupported boolean OR: `(dst_port:22 OR src_port:22)`.
        # NOTE: bare `port` is row-only — downsample rejects it (see filter_fields_downsample).
        "port",
        "endpoint_port",
        "protocol_group",
        "protocol_name",
        "protocol_num",
        "direction",
        "app",
        "sampler_address",
        "exporter_name",
        "input_snmp",
        "in_if_index",
        "output_snmp",
        "out_if_index",
        "in_if_name",
        "out_if_name",
        "in_if_speed_bps",
        "out_if_speed_bps",
        "src_country_iso2",
        "dst_country_iso2",
        "src_cidr",
        "dst_cidr",
        "device_id",
        "tag",
        "src_tag",
        "dst_tag",
        "near",
        "src_near",
        "dst_near",
        "threat_matched",
        "threat_source",
        "threat_indicator",
        "threat_observed_ip",
        "threat_severity"
      ],
      # Chart / `bucket:` path only — must stay a projection of
      # rust/srql/.../downsample/filters.rs `flows_filter_clause` arms.
      # Excludes: port, tag*, near*, geo countries, and device_id.
      filter_fields_downsample: [
        "src_endpoint_ip",
        "src_ip",
        "dst_endpoint_ip",
        "dst_ip",
        "ip",
        "endpoint_ip",
        "src_cidr",
        "dst_cidr",
        "cidr",
        "src_endpoint_port",
        "src_port",
        "dst_endpoint_port",
        "dst_port",
        "protocol_name",
        "protocol_num",
        "protocol_group",
        "app",
        "direction",
        "sampler_address",
        "exporter_name",
        "input_snmp",
        "in_if_index",
        "output_snmp",
        "out_if_index",
        "in_if_name",
        "out_if_name",
        "in_if_speed_bps",
        "out_if_speed_bps"
      ],
      # Address-shaped fields default to `equals`, not `contains` (see address_fields/1).
      address_fields: [
        "src_endpoint_ip",
        "src_ip",
        "dst_endpoint_ip",
        "dst_ip",
        "sampler_address"
      ],
      downsample: true,
      default_bucket: "5m",
      default_agg: "sum",
      default_value_field: "bytes_total",
      default_series_field: "app",
      value_fields: [
        "bytes_total",
        "packets_total",
        "bytes_in",
        "bytes_out",
        "packets_in",
        "packets_out"
      ],
      series_fields: [
        "protocol_group",
        "protocol_name",
        "app",
        "dst_port",
        "src_ip",
        "dst_ip",
        "direction",
        "sampler_address",
        "exporter_name",
        "in_if_name",
        "out_if_name",
        "src_cidr",
        "dst_cidr"
      ]
    },
    %{
      id: "attributed_flows",
      label: "Attributed Flows",
      route: "/observability/flows/attributed",
      default_time: "last_24h",
      default_sort_field: "time",
      default_sort_dir: "desc",
      default_filter_field: "process",
      filter_fields: [
        "attribution_status",
        "pid",
        "process",
        "process_name",
        "comm",
        "cmdline",
        "uid",
        "container_id",
        "agent_id",
        "pod_namespace",
        "pod_name",
        "pod_uid",
        "container_name",
        "image",
        "runtime_source",
        "service_name",
        "gateway_name",
        "exposure_class",
        "route_name",
        "public_endpoint_namespace",
        "src_endpoint_ip",
        "src_ip",
        "dst_endpoint_ip",
        "dst_ip",
        # Bidirectional either-endpoint matchers (same as raw flows).
        "ip",
        "endpoint_ip",
        "src_endpoint_port",
        "src_port",
        "dst_endpoint_port",
        "dst_port",
        "port",
        "endpoint_port",
        "protocol_name",
        "protocol_num",
        "protocol_group",
        "direction",
        "app",
        "sampler_address",
        "tag",
        "src_tag",
        "dst_tag",
        "threat_matched",
        "threat_source",
        "threat_indicator",
        "threat_observed_ip",
        "threat_severity"
      ],
      numeric_fields: [
        "pid",
        "uid",
        "src_endpoint_port",
        "dst_endpoint_port",
        "port",
        "endpoint_port",
        "protocol_num"
      ],
      address_fields: [
        "src_endpoint_ip",
        "src_ip",
        "dst_endpoint_ip",
        "dst_ip",
        "ip",
        "endpoint_ip",
        "sampler_address"
      ],
      downsample: false
    },
    %{
      id: "services",
      label: "Services",
      route: "/services",
      default_time: "last_7d",
      default_sort_field: "timestamp",
      default_sort_dir: "desc",
      default_filter_field: "service_type",
      filter_fields: [
        "uid",
        "service_id",
        "gateway_id",
        "service_type",
        "service_status",
        "name",
        "port",
        "protocol"
      ],
      downsample: false
    },
    # Kubernetes public VIP / Gateway ownership inventory (cluster-plane).
    %{
      id: "public_endpoints",
      label: "Public Endpoints",
      route: "/inventory/public-endpoints",
      default_time: "",
      default_sort_field: "ip",
      default_sort_dir: "asc",
      default_filter_field: "ip",
      filter_fields: [
        "ip",
        "hostname",
        "port",
        "protocol",
        "namespace",
        "cluster_id",
        "exposure_class",
        "service_name",
        "gateway_name",
        "route_name",
        "route_kind",
        "metallb_pool"
      ],
      known_values: %{
        "exposure_class" => ["LoadBalancer", "Gateway", "ExternalIP"],
        "protocol" => ["TCP", "UDP", "SCTP"]
      },
      downsample: false
    },
    %{
      id: "service_availability",
      label: "Service Availability",
      route: "/services",
      default_time: "last_1h",
      default_sort_field: "last_observed_at",
      default_sort_dir: "desc",
      default_filter_field: "status",
      filter_fields: [
        "uid",
        "service_name",
        "service_key",
        "service_kind",
        "descriptor_id",
        "status",
        "available",
        "summary",
        "gateway_id",
        "agent_id",
        "partition"
      ],
      boolean_fields: ["available"],
      downsample: false
    },
    %{
      id: "monitored_services",
      label: "Monitored Services",
      route: "/services",
      default_time: "last_1h",
      default_sort_field: "display_name",
      default_sort_dir: "asc",
      default_filter_field: "display_name",
      filter_fields: [
        "uid",
        "display_name",
        "service_name",
        "service_key",
        "service_kind",
        "protocol",
        "host",
        "status",
        "available",
        "gateway_id",
        "agent_id",
        "partition"
      ],
      boolean_fields: ["available"],
      downsample: false
    },
    %{
      id: "endpoint_inventory_status",
      label: "Endpoint Inventory Status",
      route: "/dashboards/endpoint-inventory",
      default_time: "",
      default_sort_field: "last_scan_at",
      default_sort_dir: "desc",
      default_filter_field: "device_id",
      filter_fields: [
        "device_uid",
        "device_id",
        "agent_id",
        "scan_id",
        "state",
        "coverage_state",
        "coverage",
        "current",
        "freshness",
        "freshness_verdict",
        "package_set_hash",
        "upload_reason"
      ],
      boolean_fields: ["current"],
      downsample: false
    },
    %{
      id: "endpoint_packages",
      label: "Endpoint Packages",
      route: "/dashboards/endpoint-inventory",
      default_time: "",
      default_sort_field: "updated_at",
      default_sort_dir: "desc",
      default_filter_field: "name",
      filter_fields: [
        "device_uid",
        "device_id",
        "agent_id",
        "package_id",
        "endpoint_package_ref",
        "name",
        "package",
        "version",
        "architecture",
        "arch",
        "package_manager",
        "manager",
        "ecosystem",
        "purl",
        "purl_canonical",
        "canonical_purl",
        "raw_purl",
        "supplier",
        "license",
        "source",
        "current",
        "cpe",
        "cpes",
        "cve",
        "cve_id",
        "kev"
      ],
      boolean_fields: ["current", "kev"],
      array_fields: ["cpes"],
      downsample: false
    },
    %{
      id: "vulnerability_advisories",
      label: "Vulnerability Advisories",
      route: "/dashboards/endpoint-inventory",
      default_time: "",
      # The Rust query has a stable compound default (published_at, then cve_id).
      # Leaving this blank keeps the visual builder from replacing it with a
      # weaker single-column sort unless the operator explicitly chooses one.
      default_sort_field: "",
      default_sort_dir: "desc",
      default_filter_field: "cve_id",
      filter_fields: [
        "id",
        "cve",
        "cve_id",
        "advisory_id",
        "provider",
        "feed_key",
        "severity",
        "title",
        "description",
        "kev",
        "exploit_available",
        "current",
        "cvss_score",
        "cpe",
        "cpes",
        "cpe_vendor",
        "cpe_product",
        "cpe_part",
        "cpe_version"
      ],
      exact_fields: ["id", "feed_key", "severity"],
      boolean_fields: ["kev", "exploit_available", "current"],
      numeric_fields: ["cvss_score"],
      stats_fields: [
        "severity",
        "kev",
        "exploit_available",
        "provider",
        "feed_key",
        "cve_id"
      ],
      downsample: false
    },
    %{
      id: "advisory_coordinates",
      label: "Advisory Coordinates",
      route: "/dashboards/endpoint-inventory",
      default_time: "",
      # Preserve the engine's vendor/product/value ordering when no explicit
      # sort is present in the query.
      default_sort_field: "",
      default_sort_dir: "asc",
      default_filter_field: "cve_id",
      filter_fields: [
        "id",
        "cve",
        "cve_id",
        "coordinate_type",
        "value",
        "cpe",
        "cpes",
        "cpe_part",
        "cpe_vendor",
        "cpe_product",
        "cpe_version",
        "advisory_ref",
        "provider",
        "feed_key",
        "kev",
        "current",
        "cvss_score"
      ],
      exact_fields: ["id", "advisory_ref", "coordinate_type", "cpe_part", "feed_key"],
      boolean_fields: ["kev", "current"],
      numeric_fields: ["cvss_score"],
      downsample: false
    },
    %{
      id: "endpoint_vulnerability_assessments",
      label: "Vulnerability Assessments",
      route: "/dashboards/endpoint-inventory",
      default_time: "",
      # Actionability, KEV, exploit availability, CVSS, and recency form the
      # engine's compound default. An empty UI default preserves all of it.
      default_sort_field: "",
      default_sort_dir: "desc",
      default_filter_field: "cve_id",
      filter_fields: [
        "id",
        "device_uid",
        "device_id",
        "agent_id",
        "cve",
        "cve_id",
        "advisory_id",
        "advisory_ref",
        "provider",
        "feed_key",
        "assessment",
        "disposition",
        "authority",
        "authority_generation",
        "authority_as_of",
        "applicability_reason",
        "freshness",
        "source_scope",
        "package_identity_key",
        "package_type",
        "package_manager",
        "ecosystem",
        "package_namespace",
        "namespace",
        "package_release",
        "release",
        "distro",
        "package_name",
        "name",
        "installed_version",
        "package_version",
        "version",
        "package_purl",
        "purl",
        "purl_canonical",
        "source_package",
        "source_version",
        "binary_package",
        "architecture",
        "version_scheme",
        "fixed_version",
        "coordinate_type",
        "coordinate_value",
        "cpe",
        "cpes",
        "status",
        "severity",
        "confidence",
        "kev",
        "exploit_available",
        "cvss_score",
        "package_id",
        "endpoint_package_ref",
        "inventory_package_ref",
        "scan_ref",
        "epss_score",
        "due_date",
        "ransomware_use"
      ],
      exact_fields: [
        "id",
        "device_uid",
        "device_id",
        "agent_id",
        "feed_key",
        "assessment",
        "disposition",
        "authority",
        "applicability_reason",
        "freshness",
        "source_scope",
        "package_identity_key",
        "package_type",
        "package_manager",
        "ecosystem",
        "package_namespace",
        "namespace",
        "package_release",
        "release",
        "distro",
        "architecture",
        "version_scheme",
        "coordinate_type",
        "status",
        "severity",
        "confidence",
        "package_id",
        "advisory_ref",
        "endpoint_package_ref",
        "inventory_package_ref",
        "scan_ref",
        "due_date",
        "ransomware_use"
      ],
      boolean_fields: ["kev", "exploit_available"],
      numeric_fields: ["authority_generation", "cvss_score", "epss_score"],
      timestamp_fields: ["authority_as_of"],
      stats_fields: [
        "severity",
        "kev",
        "exploit_available",
        "provider",
        "feed_key",
        "cve_id",
        "device_uid",
        "status",
        "assessment",
        "disposition",
        "freshness",
        "authority",
        "source_scope",
        "package_release"
      ],
      downsample: false
    },
    %{
      id: "slo_evaluations",
      label: "SLO Evaluations",
      route: "/dashboards/service-availability-noc",
      default_time: "last_24h",
      default_sort_field: "evaluated_at",
      default_sort_dir: "desc",
      default_filter_field: "severity",
      filter_fields: [
        "uid",
        "slo_key",
        "slo_name",
        "owner",
        "compliance_state",
        "severity",
        "status",
        "service_key",
        "service_kind",
        "partition"
      ],
      numeric_fields: ["budget_remaining_basis_points", "burn_rate_short"],
      downsample: false
    },
    %{
      id: "mtr_traces",
      label: "MTR Traces",
      route: "/diagnostics/mtr",
      default_time: "",
      default_sort_field: "time",
      default_sort_dir: "desc",
      default_filter_field: "target",
      filter_fields: [
        "target",
        "target_ip",
        "agent_id",
        "protocol",
        "check_name",
        "device_id",
        "target_reached",
        "error"
      ],
      boolean_fields: ["target_reached"],
      downsample: false
    },
    %{
      id: "interfaces",
      label: "Interfaces",
      route: "/interfaces",
      default_time: "last_7d",
      default_sort_field: "timestamp",
      default_sort_dir: "desc",
      default_filter_field: "uid",
      filter_fields: [
        "uid",
        "device_id",
        "interface_uid",
        "if_name",
        "if_index",
        "mac",
        "ip_addresses",
        "admin_status",
        "oper_status",
        "favorited",
        "metrics_enabled",
        "latest"
      ],
      boolean_fields: ["favorited", "metrics_enabled", "latest"],
      downsample: false
    },
    %{
      id: "timeseries_metrics",
      label: "Timeseries Metrics",
      route: "/dashboard",
      default_time: "last_24h",
      default_sort_field: "timestamp",
      default_sort_dir: "desc",
      default_filter_field: "metric_name",
      filter_fields: [
        "gateway_id",
        "agent_id",
        "metric_name",
        "metric_type",
        "uid",
        "target_device_ip",
        "partition",
        "if_index"
      ],
      downsample: true,
      default_bucket: "5m",
      default_agg: "avg",
      default_series_field: "metric_name",
      series_fields: [
        "metric_name",
        "metric_type",
        "uid",
        "gateway_id",
        "agent_id",
        "core_id",
        "partition",
        "target_device_ip",
        "if_index"
      ]
    },
    %{
      id: "snmp_metrics",
      label: "SNMP Metrics",
      route: "/dashboard",
      default_time: "last_24h",
      default_sort_field: "timestamp",
      default_sort_dir: "desc",
      default_filter_field: "metric_name",
      filter_fields: [
        "gateway_id",
        "agent_id",
        "metric_name",
        "uid",
        "device_id",
        "target_device_ip",
        "partition",
        "if_index"
      ],
      downsample: true,
      default_bucket: "5m",
      # Use rate aggregation by default for SNMP metrics (byte counters need rate calculation)
      default_agg: "rate",
      default_series_field: "metric_name",
      series_fields: [
        "metric_name",
        "uid",
        "gateway_id",
        "agent_id",
        "partition",
        "target_device_ip",
        "if_index"
      ]
    },
    %{
      id: "rperf_metrics",
      label: "rPerf Metrics",
      route: "/dashboard",
      default_time: "last_24h",
      default_sort_field: "timestamp",
      default_sort_dir: "desc",
      default_filter_field: "metric_name",
      filter_fields: [
        "gateway_id",
        "agent_id",
        "metric_name",
        "uid",
        "target_device_ip",
        "partition",
        "if_index"
      ],
      downsample: true,
      default_bucket: "5m",
      default_agg: "avg",
      default_series_field: "metric_name",
      series_fields: [
        "metric_name",
        "uid",
        "gateway_id",
        "agent_id",
        "partition",
        "target_device_ip",
        "if_index"
      ]
    },
    %{
      id: "cpu_metrics",
      label: "CPU Metrics",
      route: "/dashboard",
      default_time: "last_24h",
      default_sort_field: "timestamp",
      default_sort_dir: "desc",
      default_filter_field: "uid",
      filter_fields: [
        "gateway_id",
        "agent_id",
        "host_id",
        "uid",
        "partition",
        "cluster",
        "label",
        "core_id"
      ],
      downsample: true,
      default_bucket: "5m",
      default_agg: "avg",
      default_series_field: "uid",
      series_fields: [
        "uid",
        "host_id",
        "gateway_id",
        "agent_id",
        "core_id",
        "label",
        "cluster",
        "partition"
      ]
    },
    %{
      id: "memory_metrics",
      label: "Memory Metrics",
      route: "/dashboard",
      default_time: "last_24h",
      default_sort_field: "timestamp",
      default_sort_dir: "desc",
      default_filter_field: "uid",
      filter_fields: ["gateway_id", "agent_id", "host_id", "uid", "partition"],
      downsample: true,
      default_bucket: "5m",
      default_agg: "avg",
      default_series_field: "uid",
      series_fields: ["uid", "host_id", "gateway_id", "agent_id", "partition"]
    },
    %{
      id: "disk_metrics",
      label: "Disk Metrics",
      route: "/dashboard",
      default_time: "last_24h",
      default_sort_field: "timestamp",
      default_sort_dir: "desc",
      default_filter_field: "uid",
      filter_fields: [
        "gateway_id",
        "agent_id",
        "host_id",
        "uid",
        "partition",
        "mount_point",
        "device_name"
      ],
      downsample: true,
      default_bucket: "5m",
      default_agg: "avg",
      default_series_field: "mount_point",
      series_fields: [
        "uid",
        "host_id",
        "gateway_id",
        "agent_id",
        "partition",
        "mount_point",
        "device_name"
      ]
    },
    %{
      id: "process_metrics",
      label: "Process Metrics",
      route: "/dashboard",
      default_time: "last_24h",
      default_sort_field: "timestamp",
      default_sort_dir: "desc",
      default_filter_field: "name",
      filter_fields: [
        "gateway_id",
        "agent_id",
        "host_id",
        "uid",
        "partition",
        "name",
        "pid",
        "status"
      ],
      downsample: true,
      default_bucket: "5m",
      default_agg: "avg",
      default_series_field: "name",
      series_fields: [
        "uid",
        "host_id",
        "gateway_id",
        "agent_id",
        "partition",
        "name",
        "pid",
        "status"
      ]
    },
    %{
      id: "interface_settings",
      label: "Interface Settings",
      route: "/devices",
      default_time: "",
      default_sort_field: "updated_at",
      default_sort_dir: "desc",
      default_filter_field: "device_id",
      filter_fields: [
        "device_id",
        "interface_uid",
        "favorited",
        "metrics_enabled",
        "threshold_enabled",
        "tags"
      ],
      boolean_fields: ["favorited", "metrics_enabled", "threshold_enabled"],
      downsample: false
    }
  ]

  # Keep the public query spellings accepted by the Rust parser pointed at one
  # catalog record per entity. Without this, opening a legacy query in the
  # visual builder silently falls back to the generic timestamp-sorted shape.
  @entity_aliases %{
    # Sweep diagnostics (issue 4167). Every alias here is one the SRQL parser
    # already accepts (`rust/srql/src/parser/entity.rs`) and `EntityAccess`
    # already gates. Without the mapping, `entity/1` falls through to the
    # synthesized fallback below, which hands the visual builder
    # `default_sort_field: "timestamp"` and an empty filter allowlist -- so the
    # builder emits `sort:timestamp:desc` against entities that have no
    # `timestamp` column and the query is rejected downstream.
    "sweep_group" => "sweep_groups",
    "sweeps" => "sweep_groups",
    "sweep_profile" => "sweep_profiles",
    "scanner_profiles" => "sweep_profiles",
    "scanner_profile" => "sweep_profiles",
    "sweep_execution" => "sweep_executions",
    "sweep_group_executions" => "sweep_executions",
    "sweep_result" => "sweep_results",
    "sweep_host_results" => "sweep_results",
    "sweep_coverage_daily" => "sweep_coverage",
    "sweep_overlap" => "device_sweep_overlap",
    "vulnerability_advisory" => "vulnerability_advisories",
    "advisories" => "vulnerability_advisories",
    "cves" => "vulnerability_advisories",
    "advisory_cpes" => "advisory_coordinates",
    "cpe_coordinates" => "advisory_coordinates",
    "endpoint_vulnerability_assessment" => "endpoint_vulnerability_assessments",
    "package_vulnerabilities" => "endpoint_vulnerability_assessments",
    "endpoint_vulnerability_matches" => "endpoint_vulnerability_assessments",
    "vulnerability_matches" => "endpoint_vulnerability_assessments",
    "cve_matches" => "endpoint_vulnerability_assessments",
    "advisory_matches" => "endpoint_vulnerability_assessments"
  }

  @completion_field_groups [
    :filter_fields,
    :filter_fields_downsample,
    :value_fields,
    :series_fields,
    :stats_fields,
    :boolean_fields,
    :array_fields,
    :timestamp_fields
  ]
  # Reserved control tokens. The editor accepts `["in:", "where" | control_tokens]` and
  # underlines anything else as unknown, so a downsample/stats token missing here renders
  # a valid query as invalid. Keep in sync with `CONTROL_PREFIXES` in
  # assets/js/lib/srql/tokenizer.js.
  @completion_control_tokens ~w(limit: sort: time: status: type: tag: site: where group: by:) ++
                               ~w(bucket: agg: value_field: series: stats:)
  @completion_tokens (
                       entity_tokens = Enum.map(@entities, &"in:#{&1.id}")

                       field_tokens =
                         Enum.flat_map(@entities, fn entity ->
                           Enum.flat_map(@completion_field_groups, &Map.get(entity, &1, []))
                         end)

                       (entity_tokens ++ @completion_control_tokens ++ field_tokens)
                       |> Enum.reject(&is_nil/1)
                       |> Enum.uniq()
                       |> Enum.sort()
                     )

  def entities, do: @entities

  def completion_tokens, do: @completion_tokens

  @doc """
  Catalog for a request scope, including composite-check entities when enabled.
  Shared by GET /api/srql/catalog and the MCP get_srql_catalog tool.
  """
  def for_scope(scope) do
    case ServiceRadarWebNGWeb.CompositeChecks.Catalog.enabled_with_verdicts(scope: scope) do
      [] ->
        structured()

      checks ->
        @entities
        |> with_composite_checks(checks)
        |> structured_from_entities()
    end
  end

  def structured do
    # Content-hash keyed cache so hot reloads that change filter fields (e.g.
    # events.id) bust the previous catalog instead of serving a sticky
    # :persistent_term snapshot until full BEAM restart.
    cache_key = {__MODULE__, :structured, :v2}
    catalog = structured_from_entities(@entities)
    version = Map.fetch!(catalog, "version")

    case :persistent_term.get(cache_key, nil) do
      %{"version" => ^version} = cached ->
        cached

      _ ->
        :persistent_term.put(cache_key, catalog)
        catalog
    end
  end

  @composite_statuses ["healthy", "degraded", "down", "unknown"]

  @doc """
  Injects one `composite.<slug>` filter field per authored check into the
  devices entity, with that check's verdicts as completions.

  Composite fields are the only runtime-varying part of the catalog: slugs and
  verdicts are operator-authored data, not a static vocabulary, so a hardcoded
  list would be wrong on every deployment but the one it was written for.

  Pure by design — the caller loads the checks and passes them in, which keeps
  the catalog free of database access and lets the content-hash version pick up
  changes automatically.

  Each check contributes two fields: `composite.<slug>` matching verdict slugs,
  and `composite.<slug>.status` matching the fixed status enum.
  """
  @spec with_composite_checks([map()], [map()]) :: [map()]
  def with_composite_checks(entities, []) when is_list(entities), do: entities

  def with_composite_checks(entities, checks) when is_list(entities) and is_list(checks) do
    Enum.map(entities, fn
      %{id: "devices"} = devices -> inject_composite_fields(devices, checks)
      entity -> entity
    end)
  end

  defp inject_composite_fields(devices, checks) do
    fields =
      Enum.flat_map(checks, fn check ->
        ["composite.#{check.slug}", "composite.#{check.slug}.status"]
      end)

    values =
      Enum.reduce(checks, %{}, fn check, acc ->
        acc
        |> Map.put("composite.#{check.slug}", Map.get(check, :verdicts, []))
        |> Map.put("composite.#{check.slug}.status", @composite_statuses)
      end)

    devices
    |> Map.update!(:filter_fields, &(&1 ++ fields))
    |> Map.update(:known_values, values, &Map.merge(&1, values))
  end

  def structured_from_entities(entities) when is_list(entities) do
    payload = %{
      "control_tokens" => control_tokens(),
      "entities" => Map.new(entities, &structured_entity/1),
      "operators" => operators()
    }

    Map.put(payload, "version", content_hash(payload))
  end

  def etag(catalog \\ structured()) when is_map(catalog) do
    version = Map.fetch!(catalog, "version")
    ~s("#{version}")
  end

  def entity(id) when is_binary(id) do
    canonical_id = Map.get(@entity_aliases, id, id)

    Enum.find(@entities, &(&1.id == canonical_id)) ||
      %{
        id: id,
        label: String.capitalize(id),
        default_time: "",
        default_sort_field: "timestamp",
        default_sort_dir: "desc",
        default_filter_field: "",
        filter_fields: [],
        downsample: false
      }
  end

  def entity(_), do: entity("devices")

  @doc """
  Filter field allowlist for an entity in a given query mode.

  Modes:
  - `:row` — default table / explorer path (`filter_fields`)
  - `:downsample` — chart / `bucket:` path (`filter_fields_downsample` when set)

  Stats is not a visual-builder mode. `:stats` returns `nil` until stats has
  explicit builder state and a verified mode-specific allowlist.

  Returns:
  - a list of field names when the catalog constrains the mode
  - `nil` when the entity does not constrain fields (free-text filter field input)
  """
  def filter_fields(entity_id, mode \\ :row)

  def filter_fields(entity_id, mode) when is_binary(entity_id) do
    entity_id |> entity() |> filter_fields(mode)
  end

  def filter_fields(%{} = entity, :row) do
    case Map.get(entity, :filter_fields, []) do
      [] -> nil
      fields when is_list(fields) -> fields
      _ -> nil
    end
  end

  def filter_fields(%{} = entity, :downsample) do
    case Map.get(entity, :filter_fields_downsample) do
      fields when is_list(fields) and fields != [] ->
        fields

      _ ->
        # Metrics and other downsample entities without an explicit list keep
        # their row allowlist (or unrestricted) rather than hiding every field.
        filter_fields(entity, :row)
    end
  end

  def filter_fields(%{} = _entity, :stats), do: nil

  def filter_fields(%{} = _entity, _mode), do: nil

  @doc """
  Address-shaped filter fields for an entity (IP addresses and the like).

  These are matched exactly by default. `contains` on an address is a substring
  match, so `10.0.0.1` would also match `110.0.0.1` and `10.0.0.100` — never what
  someone filtering on an address means.
  """
  def address_fields(entity_id) when is_binary(entity_id) do
    entity_id |> entity() |> address_fields()
  end

  def address_fields(%{} = entity), do: Map.get(entity, :address_fields, [])

  @doc """
  Fields whose values are identifiers or structured enums and therefore only
  support exact equality in the visual builder.
  """
  def exact_fields(entity_id) when is_binary(entity_id) do
    entity_id |> entity() |> exact_fields()
  end

  def exact_fields(%{} = entity), do: Map.get(entity, :exact_fields, [])

  @doc """
  Default filter operator for a field on an entity.

  `contains` is the right default for free-text fields, but it is wrong for
  fields with a structured value: booleans, numerics, timestamps, and addresses
  are all matched exactly. Callers seeding a new filter row
  (`Builder.default_state/2`, the builder's "add filter" event) use this so the
  seeded operator agrees with the operator list the UI actually offers for that
  field.
  """
  def default_filter_op(entity_id, field) when is_binary(entity_id) do
    entity_id |> entity() |> default_filter_op(field)
  end

  def default_filter_op(%{} = entity, field) when is_binary(field) do
    exact? =
      field in Map.get(entity, :boolean_fields, []) or
        field in Map.get(entity, :numeric_fields, []) or
        field in Map.get(entity, :timestamp_fields, []) or
        field in address_fields(entity) or
        field in exact_fields(entity)

    if exact?, do: "equals", else: "contains"
  end

  def default_filter_op(_entity, _field), do: "contains"

  defp structured_entity(%{} = entity) do
    fields = %{
      "address" => entity |> address_fields() |> Enum.sort(),
      "array" => entity |> Map.get(:array_fields, []) |> Enum.sort(),
      "boolean" => entity |> Map.get(:boolean_fields, []) |> Enum.sort(),
      "filter" => entity |> Map.get(:filter_fields, []) |> Enum.sort(),
      "filter_downsample" => entity |> Map.get(:filter_fields_downsample, []) |> Enum.sort(),
      "numeric" => entity |> Map.get(:numeric_fields, []) |> Enum.sort(),
      "series" => entity |> Map.get(:series_fields, []) |> Enum.sort(),
      "stats" => entity |> Map.get(:stats_fields, []) |> Enum.sort(),
      "timestamp" => entity |> Map.get(:timestamp_fields, []) |> Enum.sort(),
      "value" => entity |> Map.get(:value_fields, []) |> Enum.sort()
    }

    {entity.id,
     %{
       "default_filter_field" => Map.get(entity, :default_filter_field, ""),
       "default_sort" => %{
         "field" => Map.get(entity, :default_sort_field, ""),
         "direction" => Map.get(entity, :default_sort_dir, "desc")
       },
       "default_time" => Map.get(entity, :default_time, ""),
       "downsample" => Map.get(entity, :downsample, false),
       # Curated, low-cardinality value sets keyed by field name. Empty map when
       # the entity declares no `known_values`. Editors offer these after
       # `field:` / inside `field:(` so users discover valid values.
       "enums" => entity |> Map.get(:known_values, %{}) |> normalize_enums(),
       "fields" => fields,
       "label" => Map.get(entity, :label, entity.id),
       "route" => Map.get(entity, :route),
       "route_params" => Map.get(entity, :route_params, %{})
     }}
  end

  # Preserve the declared value order (severity reads FATAL..DEBUG, not
  # alphabetized) while guaranteeing string keys/values for JSON encoding.
  defp normalize_enums(%{} = known_values) do
    Map.new(known_values, fn {field, values} ->
      {to_string(field), Enum.map(values, &to_string/1)}
    end)
  end

  defp normalize_enums(_), do: %{}

  defp control_tokens do
    Enum.sort(@completion_control_tokens)
  end

  defp operators do
    [":", ":contains", ":equals", "!=", ">", "<", ">=", "<="]
  end

  defp content_hash(payload) do
    :sha256
    |> :crypto.hash(canonical_json(payload))
    |> Base.encode16(case: :lower)
  end

  defp canonical_json(value) when is_map(value) do
    value
    |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
    |> Enum.map_join(",", fn {key, nested} -> Jason.encode!(to_string(key)) <> ":" <> canonical_json(nested) end)
    |> then(&("{" <> &1 <> "}"))
  end

  defp canonical_json(value) when is_list(value) do
    value
    |> Enum.map_join(",", &canonical_json/1)
    |> then(&("[" <> &1 <> "]"))
  end

  defp canonical_json(value) do
    Jason.encode!(value)
  end
end
