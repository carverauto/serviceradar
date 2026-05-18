defmodule ServiceRadar.Repo.Migrations.AddDeviceActiveLifecycle do
  @moduledoc false
  use Ecto.Migration

  def change do
    alter table(:ocsf_devices, prefix: "platform") do
      add :is_active, :boolean, null: false, default: true
    end

    create index(:ocsf_devices, [:is_active],
             prefix: "platform",
             name: "ocsf_devices_is_active_idx"
           )
  end
end
