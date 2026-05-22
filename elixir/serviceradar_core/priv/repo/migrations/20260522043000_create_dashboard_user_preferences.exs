defmodule ServiceRadar.Repo.Migrations.CreateDashboardUserPreferences do
  @moduledoc false
  use Ecto.Migration

  @prefix "platform"

  def up do
    create table(:dashboard_user_preferences, primary_key: false, prefix: @prefix) do
      add(:id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:user_id, references(:ng_users, type: :uuid, prefix: @prefix, on_delete: :delete_all), null: false)
      add(:target_type, :text, null: false)
      add(:target_id, :text, null: false)
      add(:favorite, :boolean, null: false, default: false)
      add(:is_default, :boolean, null: false, default: false)
      add(:metadata, :map, null: false, default: %{})

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:dashboard_user_preferences, [:user_id, :target_type, :target_id],
             name: :dashboard_user_preferences_unique_target_idx,
             prefix: @prefix
           )

    create unique_index(:dashboard_user_preferences, [:user_id],
             name: :dashboard_user_preferences_one_default_idx,
             prefix: @prefix,
             where: "is_default = true"
           )

    create index(:dashboard_user_preferences, [:user_id, :favorite],
             name: :dashboard_user_preferences_user_favorite_idx,
             prefix: @prefix
           )
  end

  def down do
    drop(table(:dashboard_user_preferences, prefix: @prefix))
  end
end
