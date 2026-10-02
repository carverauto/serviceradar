defmodule ServiceRadar.Repo.Migrations.AddSourceIdentifierRetirement do
  @moduledoc """
  Schema for retiring a source-authoritative identifier (an Armis device id) that its source
  stopped reporting (change `add-source-id-succession`, design D1).

  * `device_cleanup_settings` gains the retirement settings: whether retirement runs (on by
    default), the consecutive exact collections an id must be absent from (N) and the hours
    since it was last reported (T), the mass-retirement guard and its one-pass override, the
    grace period before a record left holding only retired ids is soft-deleted, and the cap on
    succession merges per reconciliation run.
  * `ocsf_devices` gains `source_retired_at` (when the record was marked `source_retired`) and
    `identity_observed_at` (the last identity-bearing observation). Both start empty; nothing
    here fills them.
  * `source_identifier_absences` holds one row per source object id that the latest exact
    collections of its source instance did not report: how many consecutive exact collections
    missed it, under which collection query, and which collections those were. Presence in an
    exact collection removes the row. It is keyed like `device_source_observations`.

  Schema only: no existing row is rewritten. The indexes the retirement and grace queries read
  are built concurrently by the next migration.
  """
  use Ecto.Migration

  def up do
    alter table(:device_cleanup_settings, prefix: "platform") do
      add :source_retirement_enabled, :boolean, null: false, default: true
      add :source_retirement_absent_collections, :integer, null: false, default: 3
      add :source_retirement_min_absence_hours, :integer, null: false, default: 24
      add :source_retirement_max_fraction, :float, null: false, default: 0.5
      add :source_retirement_guard_override, :boolean, null: false, default: false
      add :source_retired_grace_days, :integer, null: false, default: 7
      add :max_successions_per_run, :integer, null: false, default: 200
    end

    alter table(:ocsf_devices, prefix: "platform") do
      add :source_retired_at, :utc_datetime_usec
      add :identity_observed_at, :utc_datetime_usec
    end

    create table(:source_identifier_absences, primary_key: false, prefix: "platform") do
      add :partition, :text, primary_key: true, null: false
      add :source, :text, primary_key: true, null: false
      add :source_instance, :text, primary_key: true, null: false
      add :source_object_id, :text, primary_key: true, null: false
      add :identifier_type, :text, null: false
      add :absent_count, :integer, null: false
      add :query_hash, :text
      add :collection_ids, {:array, :text}, null: false, default: []
      add :first_absent_at, :utc_datetime_usec, null: false
      add :last_absent_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec)
    end
  end

  def down do
    drop_if_exists table(:source_identifier_absences, prefix: "platform")

    alter table(:ocsf_devices, prefix: "platform") do
      remove :identity_observed_at
      remove :source_retired_at
    end

    alter table(:device_cleanup_settings, prefix: "platform") do
      remove :max_successions_per_run
      remove :source_retired_grace_days
      remove :source_retirement_guard_override
      remove :source_retirement_max_fraction
      remove :source_retirement_min_absence_hours
      remove :source_retirement_absent_collections
      remove :source_retirement_enabled
    end
  end
end
