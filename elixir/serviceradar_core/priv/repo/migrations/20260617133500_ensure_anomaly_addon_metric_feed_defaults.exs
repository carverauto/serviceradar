defmodule ServiceRadar.Repo.Migrations.EnsureAnomalyAddonMetricFeedDefaults do
  @moduledoc """
  Repairs imported anomaly add-on package rows that predate the metric-feed
  config schema, then backfills default metric-feed params on existing anomaly
  profiles and assignments.

  This preserves explicit operator params: only missing schema keys and missing
  `params.metric_feed` entries are added.
  """

  use Ecto.Migration

  @addon_id "anomaly"
  @default_metric_feed ~s({"sources":["sysmon","snmp"]})
  @metric_feed_schema ~s({
    "type": "object",
    "title": "Local metric feed subscription",
    "description": "Controls which local agent metric sources are streamed into the add-on. The default subscribes only to sysmon and SNMP metrics; ICMP and generic timeseries batches must be opted in explicitly.",
    "additionalProperties": false,
    "properties": {
      "sources": {
        "type": "array",
        "title": "Metric sources",
        "items": {
          "type": "string",
          "enum": [
            "sysmon",
            "sysmon-metrics",
            "snmp",
            "snmp-metrics",
            "icmp",
            "icmp-metrics",
            "timeseries",
            "timeseries-metrics"
          ]
        },
        "uniqueItems": true,
        "default": ["sysmon", "snmp"]
      }
    },
    "default": {
      "sources": ["sysmon", "snmp"]
    }
  })
  @metric_feed_sources_schema ~s({
    "type": "array",
    "title": "Legacy metric feed source list",
    "description": "Deprecated compatibility form for metric_feed.sources.",
    "items": {
      "type": "string",
      "enum": [
        "sysmon",
        "sysmon-metrics",
        "snmp",
        "snmp-metrics",
        "icmp",
        "icmp-metrics",
        "timeseries",
        "timeseries-metrics"
      ]
    },
    "uniqueItems": true
  })

  def up do
    ensure_anomaly_schema_properties_object()
    add_missing_metric_feed_schema()
    add_missing_legacy_metric_feed_sources_schema()
    backfill_assignment_metric_feed_params()
    backfill_profile_metric_feed_params()
  end

  def down do
    # Data repair only. Removing these keys would risk deleting operator-visible
    # schema/params that may have been intentionally edited after the migration.
    :ok
  end

  defp ensure_anomaly_schema_properties_object do
    execute("""
    UPDATE platform.addon_packages
    SET config_schema = jsonb_set(
          COALESCE(config_schema::jsonb, '{}'::jsonb),
          '{properties}',
          COALESCE(config_schema::jsonb->'properties', '{}'::jsonb),
          true
        ),
        updated_at = now()
    WHERE addon_id = '#{@addon_id}'
      AND NOT (COALESCE(config_schema::jsonb, '{}'::jsonb) ? 'properties')
    """)
  end

  defp add_missing_metric_feed_schema do
    execute("""
    UPDATE platform.addon_packages
    SET config_schema = jsonb_set(
          COALESCE(config_schema::jsonb, '{}'::jsonb),
          '{properties,metric_feed}',
          '#{@metric_feed_schema}'::jsonb,
          true
        ),
        updated_at = now()
    WHERE addon_id = '#{@addon_id}'
      AND NOT (COALESCE(COALESCE(config_schema::jsonb, '{}'::jsonb)->'properties', '{}'::jsonb) ? 'metric_feed')
    """)
  end

  defp add_missing_legacy_metric_feed_sources_schema do
    execute("""
    UPDATE platform.addon_packages
    SET config_schema = jsonb_set(
          COALESCE(config_schema::jsonb, '{}'::jsonb),
          '{properties,metric_feed_sources}',
          '#{@metric_feed_sources_schema}'::jsonb,
          true
        ),
        updated_at = now()
    WHERE addon_id = '#{@addon_id}'
      AND NOT (COALESCE(COALESCE(config_schema::jsonb, '{}'::jsonb)->'properties', '{}'::jsonb) ? 'metric_feed_sources')
    """)
  end

  defp backfill_assignment_metric_feed_params do
    execute("""
    UPDATE platform.addon_assignments AS assignment
    SET params = jsonb_set(
          COALESCE(assignment.params::jsonb, '{}'::jsonb),
          '{metric_feed}',
          '#{@default_metric_feed}'::jsonb,
          true
        ),
        updated_at = now()
    FROM platform.addon_packages AS package
    WHERE assignment.addon_package_id = package.id
      AND package.addon_id = '#{@addon_id}'
      AND NOT (COALESCE(assignment.params::jsonb, '{}'::jsonb) ? 'metric_feed')
    """)
  end

  defp backfill_profile_metric_feed_params do
    execute("""
    UPDATE platform.addon_profiles AS profile
    SET params = jsonb_set(
          COALESCE(profile.params::jsonb, '{}'::jsonb),
          '{metric_feed}',
          '#{@default_metric_feed}'::jsonb,
          true
        ),
        updated_at = now()
    FROM platform.addon_packages AS package
    WHERE profile.addon_package_id = package.id
      AND package.addon_id = '#{@addon_id}'
      AND NOT (COALESCE(profile.params::jsonb, '{}'::jsonb) ? 'metric_feed')
    """)
  end
end
