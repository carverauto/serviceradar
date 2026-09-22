defmodule ServiceRadar.Repo.Migrations.AddRoleProfileToUserGroups do
  @moduledoc false
  use Ecto.Migration

  def change do
    alter table(:user_groups, prefix: "platform") do
      add :role_profile_id,
          references(:role_profiles,
            prefix: "platform",
            type: :uuid,
            on_delete: :restrict
          )
    end

    create index(:user_groups, [:role_profile_id], prefix: "platform")
  end
end
