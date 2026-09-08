defmodule ServiceRadar.Repo.Migrations.AddIpToOcsfAgents do
  @moduledoc false
  use Ecto.Migration

  def up do
    alter table(:ocsf_agents, prefix: "platform") do
      add_if_not_exists :ip, :text
    end
  end

  def down do
    execute "ALTER TABLE platform.ocsf_agents DROP COLUMN IF EXISTS ip"
  end
end
