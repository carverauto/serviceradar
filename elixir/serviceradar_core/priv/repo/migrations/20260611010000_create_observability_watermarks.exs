defmodule ServiceRadar.Repo.Migrations.CreateObservabilityWatermarks do
  @moduledoc """
  Plain table holding ingest-time watermarks for observability maintenance
  workers (first consumer: RefreshTraceSummariesWorker, key `trace_summaries`).
  """
  use Ecto.Migration

  def up do
    execute("""
    CREATE TABLE IF NOT EXISTS #{schema()}.observability_watermarks (
      key        TEXT PRIMARY KEY,
      watermark  TIMESTAMPTZ NOT NULL,
      updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
    )
    """)
  end

  def down do
    execute("DROP TABLE IF EXISTS #{schema()}.observability_watermarks")
  end

  defp schema, do: prefix() || "platform"
end
