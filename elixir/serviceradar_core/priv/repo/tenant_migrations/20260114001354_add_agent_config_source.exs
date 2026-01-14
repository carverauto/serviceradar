defmodule ServiceRadar.Repo.TenantMigrations.AddAgentConfigSource do
  @moduledoc """
  Adds config_source column to ocsf_agents for tracking sysmon config origin.

  Values: remote, local, cached, default
  """

  use Ecto.Migration

  def up do
    alter table(:ocsf_agents, prefix: prefix()) do
      add_if_not_exists :config_source, :string
    end

    create_if_not_exists index(:ocsf_agents, [:config_source], prefix: prefix())
  end

  def down do
    drop_if_exists index(:ocsf_agents, [:config_source], prefix: prefix())

    alter table(:ocsf_agents, prefix: prefix()) do
      remove_if_exists :config_source
    end
  end
end
