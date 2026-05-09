defmodule ServiceRadar.Repo.Migrations.AddGuestIdentityToVirtualizationNetworkInterfaces do
  @moduledoc false
  use Ecto.Migration

  def change do
    alter table(:virtualization_network_interfaces, prefix: "platform") do
      add :guest_id,
          references(:virtualization_guests,
            column: :id,
            type: :uuid,
            prefix: "platform",
            on_delete: :nilify_all
          )

      add :guest_provider_ref, :text
      add :mac_address, :text
      add :ip_addresses, {:array, :text}, default: [], null: false
      add :source, :text
    end

    create index(:virtualization_network_interfaces, [:guest_id],
             prefix: "platform",
             name: :virtualization_network_interfaces_guest_id_idx
           )

    create index(:virtualization_network_interfaces, [:guest_provider_ref],
             prefix: "platform",
             name: :virtualization_network_interfaces_guest_provider_ref_idx
           )

    create index(:virtualization_network_interfaces, [:mac_address],
             prefix: "platform",
             name: :virtualization_network_interfaces_mac_address_idx
           )
  end
end
