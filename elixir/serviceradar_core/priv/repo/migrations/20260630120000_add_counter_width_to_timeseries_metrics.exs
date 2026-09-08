defmodule ServiceRadar.Repo.Migrations.AddCounterWidthToTimeseriesMetrics do
  @moduledoc """
  Adds a nullable `counter_width` column to the `timeseries_metrics` hypertable.

  SNMP counter metrics are either 32-bit (Counter32, e.g. ifInOctets/ifOutOctets) or
  64-bit (Counter64, e.g. ifHCInOctets/ifHCOutOctets). The SRQL rate CTE needs to know
  the counter modulus to recover the real delta when a counter wraps inside a poll
  interval (a 32-bit octet counter on a busy 1 Gbps link wraps every ~34s). The width is
  already extracted by `ServiceRadar.Observability.MetricEnvelope` from the agent metric
  envelope; this column persists it per sample so the rate query can branch 2^32 vs 2^64.

  Nullable so the add is a cheap metadata-only change on the large hypertable; legacy rows
  keep NULL and the rate CTE falls back to a 32-bit wrap heuristic for them.
  """
  use Ecto.Migration

  def up do
    alter table(:timeseries_metrics, prefix: "platform") do
      add :counter_width, :integer
    end
  end

  def down do
    alter table(:timeseries_metrics, prefix: "platform") do
      remove :counter_width
    end
  end
end
