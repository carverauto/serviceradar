defmodule ServiceRadar.Repo.TenantMigrations.AddJdmDefinitionToZenRules do
  @moduledoc """
  Adds jdm_definition column to zen_rules for storing user-authored JDM JSON.
  """

  use Ecto.Migration

  def up do
    alter table(:zen_rules, prefix: prefix()) do
      add_if_not_exists :jdm_definition, :map, default: %{}
    end
  end

  def down do
    alter table(:zen_rules, prefix: prefix()) do
      remove_if_exists :jdm_definition, :map
    end
  end
end
