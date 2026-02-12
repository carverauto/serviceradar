defmodule ServiceRadar.Repo.Migrations.AddManagementDeviceId do
  @moduledoc """
  Adds management_device_id to ocsf_devices for management device fallback.
  """

  use Ecto.Migration

  def up do
    alter table(:ocsf_devices, prefix: "platform") do
      add :management_device_id, :text
    end
  end

  def down do
    alter table(:ocsf_devices, prefix: "platform") do
      remove :management_device_id
    end
  end
end
