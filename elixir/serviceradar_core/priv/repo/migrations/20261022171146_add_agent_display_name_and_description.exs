defmodule ServiceRadar.Repo.Migrations.AddAgentDisplayNameAndDescription do
  @moduledoc false
  use Ecto.Migration

  def up do
    alter table(:ocsf_agents, prefix: "platform") do
      add_if_not_exists :display_name, :text
      add_if_not_exists :description, :text
    end
  end

  def down do
    alter table(:ocsf_agents, prefix: "platform") do
      remove :display_name
      remove :description
    end
  end
end
