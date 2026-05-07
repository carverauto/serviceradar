defmodule ServiceRadar.Repo.Migrations.AddVmidToVirtualizationGuests do
  @moduledoc false
  use Ecto.Migration

  @prefix "platform"

  def change do
    alter table(:virtualization_guests, prefix: @prefix) do
      add :vmid, :bigint
    end

    create index(:virtualization_guests, [:provider, :vmid],
             prefix: @prefix,
             name: :virtualization_guests_provider_vmid_idx
           )
  end
end
