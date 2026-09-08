defmodule ServiceRadar.Repo.Migrations.DropGatewayIdFromSweepGroups do
  @moduledoc """
  Remove gateway_id column from sweep_groups.

  Gateways are passive listeners that forward messages from agents to core.
  Sweep groups should only be tied to agents (the actual executors), not gateways.
  """
  use Ecto.Migration

  def change do
    drop_if_exists index(:sweep_groups, [:gateway_id],
                     prefix: "platform",
                     name: "sweep_groups_gateway_idx"
                   )

    alter table(:sweep_groups, prefix: "platform") do
      remove :gateway_id, :string, null: true
    end
  end
end
