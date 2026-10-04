defmodule ServiceRadar.Repo.Migrations.AddAgentSupersession do
  @moduledoc """
  Columns that record when an agent identity was replaced on its device.

  `status = superseded` is the lifecycle state. `superseded_at` is set in the
  same write and is what `in:agents` excludes. No existing rows are rewritten.
  """

  use Ecto.Migration

  def up do
    alter table(:ocsf_agents, prefix: "platform") do
      add :superseded_by, :text
      add :superseded_at, :utc_datetime
    end

    create index(:ocsf_agents, [:device_uid],
             name: "ocsf_agents_unsuperseded_device_uid_index",
             prefix: "platform",
             where: "superseded_at IS NULL AND device_uid IS NOT NULL"
           )
  end

  def down do
    execute("UPDATE platform.ocsf_agents SET status = 'unavailable' WHERE status = 'superseded'")

    drop_if_exists index(:ocsf_agents, [:device_uid],
                     name: "ocsf_agents_unsuperseded_device_uid_index",
                     prefix: "platform"
                   )

    alter table(:ocsf_agents, prefix: "platform") do
      remove :superseded_at
      remove :superseded_by
    end
  end
end
