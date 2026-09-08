defmodule ServiceRadar.Repo.Migrations.ExtendOtelMetricPointsIdentity do
  @moduledoc """
  Extends otel_metric_points with the identity columns required by the
  attributes_hash recipe v2 (cross-language deterministic hashing shared
  with the Go gateway):

  - `service_instance_id` from resource attribute `service.instance.id`
  - `scope_name` from the instrumentation scope
  - `start_time_unix_nano` from the data point (NULL when absent/zero)

  The primary key (timestamp, metric_name, service_name, attributes_hash)
  is unchanged; the new identity inputs are folded into attributes_hash by
  the EventWriter OtelMetrics processor.
  """
  use Ecto.Migration

  def up do
    execute("""
    ALTER TABLE #{schema()}.otel_metric_points
      ADD COLUMN IF NOT EXISTS start_time_unix_nano BIGINT NULL,
      ADD COLUMN IF NOT EXISTS scope_name TEXT NOT NULL DEFAULT '',
      ADD COLUMN IF NOT EXISTS service_instance_id TEXT NOT NULL DEFAULT ''
    """)
  end

  def down do
    execute("""
    ALTER TABLE #{schema()}.otel_metric_points
      DROP COLUMN IF EXISTS start_time_unix_nano,
      DROP COLUMN IF EXISTS scope_name,
      DROP COLUMN IF EXISTS service_instance_id
    """)
  end

  defp schema, do: prefix() || "platform"
end
