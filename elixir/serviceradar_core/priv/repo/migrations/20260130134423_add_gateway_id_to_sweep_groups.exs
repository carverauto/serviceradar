defmodule ServiceRadar.Repo.Migrations.AddGatewayIdToSweepGroups do
  @moduledoc """
  Add gateway_id column to sweep_groups for gateway-scoped sweep profiles.

  This allows sweep groups to be tied to a specific gateway, ensuring that
  only agents connected to that gateway receive the sweep configuration.
  """
  use Ecto.Migration

  def change do
    alter table(:sweep_groups, prefix: "platform") do
      add :gateway_id, :string, null: true
    end

    create index(:sweep_groups, [:gateway_id],
             where: "gateway_id IS NOT NULL",
             prefix: "platform",
             name: "sweep_groups_gateway_idx"
           )
  end
end
