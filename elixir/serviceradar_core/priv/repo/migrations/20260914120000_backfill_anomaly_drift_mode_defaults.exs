defmodule ServiceRadar.Repo.Migrations.BackfillAnomalyDriftModeDefaults do
  @moduledoc """
  Fills in the per-metric-class `drift_mode` defaults on anomaly detection
  settings rows seeded before those defaults existed.

  `AnomalyConfigSeeder` creates the singleton settings row once and never
  rewrites it, so later chart or code defaults never reach an existing
  deployment. A row seeded before `drift_mode` shipped runs every class in the
  frozen-anchor drift mode, which reads an interface's ordinary daily ramp as
  sustained drift.

  Only missing values are filled. A class entry that already has a `drift_mode`
  keeps it, a class entry that is not a JSON object is left alone, and every
  other key in a class entry is preserved. Classes the row does not have at all
  are added with only their `drift_mode`. The values are the shipped defaults as
  of this migration, frozen here rather than read from the resource, so the
  migration means the same thing whenever it runs.

  `down/0` is a no-op: once filled, a default cannot be told apart from an
  operator's choice, so reverting could erase real settings.
  """

  use Ecto.Migration

  @defaults [
    {"cpu", "deseasonalized_only"},
    {"memory", "deseasonalized_only"},
    {"interface", "deseasonalized_only"},
    {"disk", "off"},
    {"icmp", "off"},
    {"other", "off"}
  ]

  def up do
    # serviceradar:allow-startup-maintenance - updates the anomaly detection
    # settings singleton (one row, keyed "default"), filling only absent
    # per-class drift_mode values. It touches no telemetry table, is bounded to
    # that row, is idempotent, and is a no-op when the row is complete or absent.
    execute(backfill_sql())
  end

  def down, do: :ok

  @doc false
  def backfill_sql do
    values = Enum.map_join(@defaults, ", ", fn {class, mode} -> "('#{class}', '#{mode}')" end)

    """
    UPDATE platform.anomaly_detection_configs AS config
    SET metric_class_overrides = filled.overrides,
        updated_at = (now() AT TIME ZONE 'utc')
    FROM (
      SELECT existing.key,
             existing.metric_class_overrides || COALESCE(
               (
                 SELECT jsonb_object_agg(
                          defaults.class,
                          COALESCE(existing.metric_class_overrides -> defaults.class, '{}'::jsonb)
                            || jsonb_build_object('drift_mode', defaults.drift_mode)
                        )
                 FROM (VALUES #{values}) AS defaults(class, drift_mode)
                 WHERE NOT (existing.metric_class_overrides ? defaults.class)
                    OR (
                      jsonb_typeof(existing.metric_class_overrides -> defaults.class) = 'object'
                      AND NOT ((existing.metric_class_overrides -> defaults.class) ? 'drift_mode')
                    )
               ),
               '{}'::jsonb
             ) AS overrides
      FROM platform.anomaly_detection_configs AS existing
    ) AS filled
    WHERE config.key = filled.key
      AND config.metric_class_overrides IS DISTINCT FROM filled.overrides
    """
  end
end
