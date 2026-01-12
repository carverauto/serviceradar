defmodule ServiceRadar.Repo.TenantMigrations.AddDeviceTags do
  @moduledoc """
  Adds tags map to ocsf_devices for user-defined labels.
  """

  use Ecto.Migration

  def up do
    alter table(:ocsf_devices, prefix: prefix()) do
      add_if_not_exists :tags, :map, default: %{}
    end
  end

  def down do
    alter table(:ocsf_devices, prefix: prefix()) do
      remove_if_exists :tags
    end
  end
end
