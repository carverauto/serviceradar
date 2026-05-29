defmodule ServiceRadar.Repo.Migrations.AddAddonStatuses do
  @moduledoc """
  Adds `platform.addon_statuses` (issue 3425, task 7.2): the per-agent observed
  status of native add-ons, ingested from the agent capability status payload. DDL
  mirrors the Ash resource ServiceRadar.Plugins.AddonStatus.
  """

  use Ecto.Migration

  def up do
    execute("CREATE SCHEMA IF NOT EXISTS platform")

    create table(:addon_statuses, primary_key: false, prefix: "platform") do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
      add :agent_uid, :text, null: false
      add :addon_id, :text, null: false
      add :state, :text, null: false
      add :active, :boolean, null: false, default: false
      add :degradation_reason, :text
      add :pid, :integer
      add :restart_count, :integer, null: false, default: 0
      add :last_health_at, :utc_datetime_usec
      add :version, :text
      add :arch, :text
      add :reported_at, :utc_datetime_usec, null: false

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
    end

    create unique_index(:addon_statuses, [:agent_uid, :addon_id],
             name: "addon_statuses_unique_agent_addon_index",
             prefix: "platform"
           )
  end

  def down do
    drop table(:addon_statuses, prefix: "platform")
  end
end
