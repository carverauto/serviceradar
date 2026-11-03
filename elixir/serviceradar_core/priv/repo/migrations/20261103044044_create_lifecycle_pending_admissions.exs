defmodule ServiceRadar.Repo.Migrations.CreateLifecyclePendingAdmissions do
  @moduledoc """
  One row per lifecycle occurrence whose alert admission has not committed.

  Per-series order is an indexed lookup on this table. The row is inserted in the
  same transaction as the lifecycle event and removed in the transaction that
  records the admission.
  """
  use Ecto.Migration

  @table "lifecycle_pending_admissions"

  def up do
    schema = prefix() || "platform"

    execute("""
    CREATE TABLE IF NOT EXISTS #{schema}.#{@table} (
      class_uid      INTEGER      NOT NULL,
      series_key     TEXT         NOT NULL,
      event_time     TIMESTAMPTZ  NOT NULL,
      event_id       UUID         NOT NULL,
      occurrence_id  UUID         NOT NULL,
      inserted_at    TIMESTAMPTZ  NOT NULL DEFAULT now(),
      PRIMARY KEY (class_uid, series_key, event_time, event_id)
    )
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
