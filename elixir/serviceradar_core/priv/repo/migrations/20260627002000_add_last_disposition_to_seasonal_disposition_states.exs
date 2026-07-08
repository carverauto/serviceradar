defmodule ServiceRadar.Repo.Migrations.AddLastDispositionToSeasonalDispositionStates do
  @moduledoc """
  Records the latest central-seasonal evaluation outcome per persisted state row.
  """
  use Ecto.Migration

  def up do
    create_if_not_exists table(:seasonal_disposition_states,
                           primary_key: false,
                           prefix: "platform"
                         ) do
      add(:source, :text, primary_key: true, null: false)
      add(:series_key, :text, primary_key: true, null: false)
      add(:dow, :integer, primary_key: true, null: false)
      add(:hod, :integer, primary_key: true, null: false)
      add(:consecutive_anomalous, :integer, null: false, default: 0)
      add(:last_bucket_started_at, :utc_datetime_usec)
      add(:last_bucket_ended_at, :utc_datetime_usec)
      add(:expires_at, :utc_datetime_usec, null: false)

      timestamps(type: :utc_datetime_usec)
    end

    ensure_check_constraint(
      :seasonal_disposition_states_dow_check,
      "dow >= 0 AND dow <= 6"
    )

    ensure_check_constraint(
      :seasonal_disposition_states_hod_check,
      "hod >= 0 AND hod <= 23"
    )

    ensure_check_constraint(
      :seasonal_disposition_states_counter_check,
      "consecutive_anomalous >= 0"
    )

    create_if_not_exists(index(:seasonal_disposition_states, [:expires_at], prefix: "platform"))

    create_if_not_exists(
      index(:seasonal_disposition_states, [:source, :expires_at],
        prefix: "platform",
        name: :seasonal_disposition_states_source_expires_idx
      )
    )

    execute(
      "ALTER TABLE platform.seasonal_disposition_states ADD COLUMN IF NOT EXISTS last_disposition text",
      "ALTER TABLE platform.seasonal_disposition_states DROP COLUMN IF EXISTS last_disposition"
    )

    execute(
      "ALTER TABLE platform.seasonal_disposition_states ADD COLUMN IF NOT EXISTS last_status text",
      "ALTER TABLE platform.seasonal_disposition_states DROP COLUMN IF EXISTS last_status"
    )

    execute(
      "ALTER TABLE platform.seasonal_disposition_states ADD COLUMN IF NOT EXISTS last_score double precision",
      "ALTER TABLE platform.seasonal_disposition_states DROP COLUMN IF EXISTS last_score"
    )

    execute(
      "ALTER TABLE platform.seasonal_disposition_states ADD COLUMN IF NOT EXISTS last_evaluated_at timestamp(6) without time zone",
      "ALTER TABLE platform.seasonal_disposition_states DROP COLUMN IF EXISTS last_evaluated_at"
    )
  end

  def down do
    execute(
      "ALTER TABLE platform.seasonal_disposition_states DROP COLUMN IF EXISTS last_evaluated_at",
      "ALTER TABLE platform.seasonal_disposition_states ADD COLUMN IF NOT EXISTS last_evaluated_at timestamp(6) without time zone"
    )

    execute(
      "ALTER TABLE platform.seasonal_disposition_states DROP COLUMN IF EXISTS last_score",
      "ALTER TABLE platform.seasonal_disposition_states ADD COLUMN IF NOT EXISTS last_score double precision"
    )

    execute(
      "ALTER TABLE platform.seasonal_disposition_states DROP COLUMN IF EXISTS last_status",
      "ALTER TABLE platform.seasonal_disposition_states ADD COLUMN IF NOT EXISTS last_status text"
    )

    execute(
      "ALTER TABLE platform.seasonal_disposition_states DROP COLUMN IF EXISTS last_disposition",
      "ALTER TABLE platform.seasonal_disposition_states ADD COLUMN IF NOT EXISTS last_disposition text"
    )
  end

  defp ensure_check_constraint(name, check) do
    execute("""
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conname = '#{name}'
          AND conrelid = 'platform.seasonal_disposition_states'::regclass
      ) THEN
        ALTER TABLE platform.seasonal_disposition_states
          ADD CONSTRAINT #{name} CHECK (#{check});
      END IF;
    END
    $$;
    """)
  end
end
