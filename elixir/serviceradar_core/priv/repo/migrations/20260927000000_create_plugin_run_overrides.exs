defmodule ServiceRadar.Repo.Migrations.CreatePluginRunOverrides do
  @moduledoc """
  Time-bounded run overrides that a plugin action returns for its assignment
  (`ServiceRadar.Plugins.PluginRunOverride`).

  The agent config generator delivers every override of an assignment that is
  neither ended nor acknowledged. An expired override stays deliverable until
  the agent reports that a run which received it (marked expired) succeeded, so
  the plugin always gets one chance to emit its resolving event. The unique
  index is named for the resource's `:unique_assignment_override` identity.

  `max_override_duration_seconds` on an action descriptor bounds how long an
  override returned by that action may last; a descriptor without it may not
  set overrides at all.
  """
  use Ecto.Migration

  @prefix "platform"

  def up do
    create table(:plugin_run_overrides, primary_key: false, prefix: @prefix) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true

      add :plugin_assignment_id,
          references(:plugin_assignments, type: :uuid, prefix: @prefix, on_delete: :delete_all),
          null: false

      add :override_id, :text, null: false
      add :kind, :text, null: false
      add :target, :text
      add :params, :map, null: false, default: %{}
      add :starts_at, :utc_datetime_usec, null: false
      add :expires_at, :utc_datetime_usec, null: false
      add :ended_at, :utc_datetime_usec
      add :acknowledged_at, :utc_datetime_usec
      add :invocation_id, :uuid

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("timezone('utc', now())")

      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("timezone('utc', now())")
    end

    create unique_index(:plugin_run_overrides, [:plugin_assignment_id, :override_id],
             prefix: @prefix,
             name: "plugin_run_overrides_unique_assignment_override_index"
           )

    create index(:plugin_run_overrides, [:plugin_assignment_id],
             prefix: @prefix,
             name: "plugin_run_overrides_deliverable_index",
             where: "ended_at IS NULL AND acknowledged_at IS NULL"
           )

    alter table(:northbound_action_descriptors, prefix: @prefix) do
      add :max_override_duration_seconds, :integer
    end
  end

  def down do
    alter table(:northbound_action_descriptors, prefix: @prefix) do
      remove :max_override_duration_seconds
    end

    drop_if_exists table(:plugin_run_overrides, prefix: @prefix)
  end
end
