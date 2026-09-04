defmodule ServiceRadar.Repo.Migrations.CreateSweepCoverageDaily do
  @moduledoc false
  use Ecto.Migration

  @prefix "platform"

  def up do
    create table(:sweep_coverage_daily, primary_key: false, prefix: @prefix) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
      add :day, :date, null: false
      add :device_uid, :text
      add :ip, :text, null: false
      add :sweep_group_id, :uuid
      add :agent_id, :text
      add :execution_count, :bigint, null: false, default: 0
      add :available_count, :bigint, null: false, default: 0
      add :unavailable_count, :bigint, null: false, default: 0
      add :error_count, :bigint, null: false, default: 0
      add :first_seen_at, :utc_datetime_usec, null: false
      add :last_seen_at, :utc_datetime_usec, null: false
      add :scanned_ports, {:array, :bigint}, null: false, default: []
      add :open_ports, {:array, :bigint}, null: false, default: []
      add :modes_requested, {:array, :text}, null: false, default: []
      add :modes_observed, {:array, :text}, null: false, default: []
      add :last_status, :text
      add :last_response_time_ms, :bigint

      timestamps(type: :utc_datetime_usec)
    end

    # COALESCE in the key: a pre-Task-2 row has no group or agent, and NULLs
    # would defeat the unique index, letting every rerun insert duplicates.
    execute("""
    CREATE UNIQUE INDEX sweep_coverage_daily_grain_uidx
    ON #{@prefix}.sweep_coverage_daily (
      day,
      COALESCE(device_uid, ''),
      ip,
      COALESCE(sweep_group_id, '00000000-0000-0000-0000-000000000000'::uuid),
      COALESCE(agent_id, '')
    )
    """)

    create index(:sweep_coverage_daily, [:device_uid, :day],
             prefix: @prefix,
             name: "sweep_coverage_daily_device_day_idx"
           )

    create index(:sweep_coverage_daily, [:sweep_group_id, :day],
             prefix: @prefix,
             name: "sweep_coverage_daily_group_day_idx"
           )
  end

  def down do
    drop_if_exists table(:sweep_coverage_daily, prefix: @prefix)
  end
end
