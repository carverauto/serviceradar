defmodule ServiceRadar.Repo.Migrations.AddInterfaceEgressSettings do
  @moduledoc """
  Adds manual Internet egress designation columns to `platform.interface_settings`.
  """

  use Ecto.Migration

  def up do
    alter table(:interface_settings, prefix: "platform") do
      add(:internet_egress, :boolean, null: false, default: false)
      add(:egress_upstream_asn, :integer)
      add(:egress_vantage_id, :text)
      add(:egress_port_speed_mbps, :integer)
    end

    create(
      index(:interface_settings, [:device_id],
        where: "internet_egress = true",
        name: :interface_settings_internet_egress_idx,
        prefix: "platform"
      )
    )
  end

  def down do
    drop_if_exists(
      index(:interface_settings, [:device_id],
        name: :interface_settings_internet_egress_idx,
        prefix: "platform"
      )
    )

    alter table(:interface_settings, prefix: "platform") do
      remove(:egress_port_speed_mbps)
      remove(:egress_vantage_id)
      remove(:egress_upstream_asn)
      remove(:internet_egress)
    end
  end
end
