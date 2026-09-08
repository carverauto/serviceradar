defmodule ServiceRadar.Repo.Migrations.AddAnsibleControllerEnabled do
  @moduledoc false
  use Ecto.Migration

  @prefix "platform"

  def up do
    alter table(:ansible_controllers, prefix: @prefix) do
      add(:enabled, :boolean, null: false, default: true)
    end
  end

  def down do
    alter table(:ansible_controllers, prefix: @prefix) do
      remove(:enabled)
    end
  end
end
