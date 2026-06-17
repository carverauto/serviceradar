defmodule ServiceRadar.Repo.Migrations.AddDefaultProfileTargetQueryToAddonPackages do
  @moduledoc false
  use Ecto.Migration

  def up do
    alter table(:addon_packages, prefix: "platform") do
      add_if_not_exists(:default_profile_target_query, :text)
    end
  end

  def down do
    alter table(:addon_packages, prefix: "platform") do
      remove_if_exists(:default_profile_target_query)
    end
  end
end
