defmodule ServiceRadar.Repo.Migrations.CreateLifecyclePendingAdmissions do
  @moduledoc """
  One row per lifecycle occurrence whose alert admission has not committed.

  The row is the only record of admission state: an occurrence is unadmitted
  while its row exists. It is inserted in the same transaction as the lifecycle
  event and removed in the transaction that records the admission.

  Each occurrence keeps its own row, keyed by its stable `occurrence_id`, so a
  newer transition for the same event never overwrites one still waiting.
  `occurrence` is an immutable snapshot of what alert evaluation receives, so a
  later upsert of the current-state event row cannot change or erase it.
  Per-(class, series) FIFO order is `seq`, assigned at insert; it also orders
  occurrences that share an event time.
  """
  use Ecto.Migration

  @table "lifecycle_pending_admissions"

  def up do
    schema = prefix() || "platform"

    execute("""
    CREATE TABLE IF NOT EXISTS #{schema}.#{@table} (
      occurrence_id  UUID         PRIMARY KEY,
      seq            BIGINT       GENERATED ALWAYS AS IDENTITY,
      class_uid      INTEGER      NOT NULL,
      series_key     TEXT         NOT NULL,
      event_time     TIMESTAMPTZ  NOT NULL,
      event_id       UUID         NOT NULL,
      occurrence     JSONB        NOT NULL,
      inserted_at    TIMESTAMPTZ  NOT NULL DEFAULT now()
    )
    """)

    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS lifecycle_pending_admissions_series_seq_idx
      ON #{schema}.#{@table} (class_uid, series_key, seq)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS lifecycle_pending_admissions_event_id_idx
      ON #{schema}.#{@table} (event_id)
    """)
  end

  def down do
    schema = prefix() || "platform"
    execute("DROP TABLE IF EXISTS #{schema}.#{@table}")
  end
end
