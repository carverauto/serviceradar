defmodule ServiceRadar.Repo.Migrations.CreateSeasonalDispositionStates do
  @moduledoc """
  Stores central-seasonal confirmation counters across worker runs.
  """
  use Ecto.Migration

  def up do
    create table(:seasonal_disposition_states, primary_key: false, prefix: "platform") do
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

    create(
      constraint(:seasonal_disposition_states, :seasonal_disposition_states_dow_check,
        check: "dow >= 0 AND dow <= 6",
        prefix: "platform"
      )
    )

    create(
      constraint(:seasonal_disposition_states, :seasonal_disposition_states_hod_check,
        check: "hod >= 0 AND hod <= 23",
        prefix: "platform"
      )
    )

    create(
      constraint(:seasonal_disposition_states, :seasonal_disposition_states_counter_check,
        check: "consecutive_anomalous >= 0",
        prefix: "platform"
      )
    )

    create(index(:seasonal_disposition_states, [:expires_at], prefix: "platform"))

    create(
      index(:seasonal_disposition_states, [:source, :expires_at],
        prefix: "platform",
        name: :seasonal_disposition_states_source_expires_idx
      )
    )
  end

  def down do
    drop(table(:seasonal_disposition_states, prefix: "platform"))
  end
end
