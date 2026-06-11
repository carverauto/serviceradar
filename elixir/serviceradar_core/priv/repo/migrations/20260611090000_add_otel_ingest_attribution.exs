defmodule ServiceRadar.Repo.Migrations.AddOtelIngestAttribution do
  @moduledoc """
  Adds gateway ingest-attribution columns to the four OTel signal
  hypertables.

  Column contract (shared with the Go gateway and rust/srql — do not
  deviate): `platform.{otel_traces, logs, otel_metrics, otel_metric_points}`
  gain `ingest_identity`, `ingest_agent_id`, `ingest_partition`
  TEXT NOT NULL DEFAULT ''.

  Header mapping (stamped by the agent gateway at publish time):

  - `Sr-Ingest-Identity` → `ingest_identity`
  - `Sr-Agent-Id`        → `ingest_agent_id`
  - `Sr-Partition`       → `ingest_partition`

  Absent headers map to `''`. `otel_trace_summaries` is derived state and
  intentionally does not carry attribution columns.
  """
  use Ecto.Migration

  @tables ~w(otel_traces logs otel_metrics otel_metric_points)

  def up do
    for table <- @tables do
      execute("""
      ALTER TABLE #{schema()}.#{table}
        ADD COLUMN IF NOT EXISTS ingest_identity TEXT NOT NULL DEFAULT '',
        ADD COLUMN IF NOT EXISTS ingest_agent_id TEXT NOT NULL DEFAULT '',
        ADD COLUMN IF NOT EXISTS ingest_partition TEXT NOT NULL DEFAULT ''
      """)
    end
  end

  def down do
    for table <- @tables do
      execute("""
      ALTER TABLE #{schema()}.#{table}
        DROP COLUMN IF EXISTS ingest_identity,
        DROP COLUMN IF EXISTS ingest_agent_id,
        DROP COLUMN IF EXISTS ingest_partition
      """)
    end
  end

  defp schema, do: prefix() || "platform"
end
