defmodule ServiceRadar.Repo.Migrations.AddFinalMetaToSyncIngestRuns do
  @moduledoc """
  Retains a final chunk's activation inputs while earlier chunks are still in flight.

  Sync chunks are not delivered in index order: a redelivered or slower record can
  commit after the run's final chunk. The final chunk was the only place the source
  snapshot was activated, so a run whose last-committed chunk was not the final one
  ended fully received and never activated. `final_meta` holds the final chunk's
  population accounting and observation time until the chunk that completes the run
  claims it. It is NULL for every existing row; no backfill is needed.
  """
  use Ecto.Migration

  def up do
    alter table(:sync_ingest_runs, prefix: "platform") do
      add_if_not_exists :final_meta, :map
    end
  end

  def down do
    alter table(:sync_ingest_runs, prefix: "platform") do
      remove_if_exists :final_meta, :map
    end
  end
end
