defmodule ServiceRadar.Repo.Migrations.CreateIdentityDeduplicationTasks do
  @moduledoc """
  De-duplication tasks and distinct-device assertions (#4604).

  `identity_deduplication_tasks`: one row per candidate device set for its whole life
  (`candidate_key` is unique, not only while open), so a repeat decision can never open a
  second task or reopen a resolved one. `identity_distinct_assertions`: one row per
  operator-asserted pair, stored sorted.
  """
  use Ecto.Migration

  @prefix "platform"

  def up do
    create table(:identity_deduplication_tasks, primary_key: false, prefix: @prefix) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
      add :candidate_key, :text, null: false
      add :device_uids, {:array, :text}, null: false
      add :category, :text, null: false
      add :last_decision_kind, :text, null: false
      add :last_reason, :text, null: false
      add :evidence, :map, null: false, default: %{}
      add :status, :text, null: false, default: "open"
      add :occurrence_count, :bigint, null: false, default: 1
      add :opened_at, :utc_datetime_usec, null: false
      add :last_decided_at, :utc_datetime_usec, null: false
      add :resolved_at, :utc_datetime_usec
      add :resolved_by, :text
      add :merged_into, :text
      add :resolution_note, :text

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("timezone('utc', now())")

      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("timezone('utc', now())")
    end

    create unique_index(:identity_deduplication_tasks, [:candidate_key],
             prefix: @prefix,
             name: "identity_deduplication_tasks_unique_candidate_key_index"
           )

    create index(:identity_deduplication_tasks, [:status, :last_decided_at], prefix: @prefix)

    execute("""
    CREATE INDEX identity_deduplication_tasks_device_uids_gin_idx
    ON #{@prefix}.identity_deduplication_tasks USING GIN (device_uids)
    """)

    create table(:identity_distinct_assertions, primary_key: false, prefix: @prefix) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
      add :device_a, :text, null: false
      add :device_b, :text, null: false
      add :task_id, :uuid
      add :asserted_by, :text
      add :note, :text

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("timezone('utc', now())")

      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("timezone('utc', now())")
    end

    create unique_index(:identity_distinct_assertions, [:device_a, :device_b],
             prefix: @prefix,
             name: "identity_distinct_assertions_unique_pair_index"
           )

    create constraint(:identity_distinct_assertions, :identity_distinct_assertions_sorted_pair,
             check: "device_a < device_b",
             prefix: @prefix
           )
  end

  def down do
    drop table(:identity_distinct_assertions, prefix: @prefix)
    drop table(:identity_deduplication_tasks, prefix: @prefix)
  end
end
