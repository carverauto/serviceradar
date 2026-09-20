defmodule ServiceRadar.Repo.Migrations.AddStarrocksPendingLoads do
  @moduledoc """
  Durable outbox for StarRocks Stream Loads that fail outside JetStream ACK.

  EventWriter batches get redelivery for free: a failed warehouse write fails
  the JetStream ACK and the broker replays the batch. Oban producers such as
  `ServiceRadar.Inventory.InterfaceThresholdWorker` have no broker --
  `persist_after_cnpg/3` returns `{:error, {:missing_destinations, _}}` and
  the caller held no copy, so under events cutover a minutes-long FE outage
  silently dropped the warehouse copy of every threshold-violation batch
  (the CNPG copy survives; the warehouse-served reads lost them).

  `platform.starrocks_pending_loads` holds the Stream Load documents that
  failed, keyed by the deterministic load label so a re-enqueue of the same
  batch keeps a single row. The producing worker drains due rows on every
  run. Replays are safe twice over: the warehouse tables are PRIMARY KEY
  models (same rows, same keys) and the stored label lets the FE reconcile
  a load whose response was lost.
  """

  use Ecto.Migration

  def up do
    execute("""
    CREATE TABLE IF NOT EXISTS platform.starrocks_pending_loads (
      id bigserial PRIMARY KEY,
      dataset text NOT NULL,
      table_name text NOT NULL,
      label text NOT NULL,
      payload jsonb NOT NULL,
      attempts integer NOT NULL DEFAULT 0,
      next_retry_at timestamp(6) without time zone NOT NULL,
      inserted_at timestamp(6) without time zone NOT NULL,
      updated_at timestamp(6) without time zone NOT NULL
    )
    """)

    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS starrocks_pending_loads_label_idx
    ON platform.starrocks_pending_loads (label)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS starrocks_pending_loads_next_retry_idx
    ON platform.starrocks_pending_loads (next_retry_at)
    """)
  end

  def down do
    execute("DROP TABLE IF EXISTS platform.starrocks_pending_loads")
  end
end
