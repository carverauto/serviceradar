defmodule ServiceRadarWebNG.InfrastructureTest do
  use ServiceRadarWebNG.DataCase, async: true

  alias ServiceRadar.Infrastructure.Gateway
  alias ServiceRadarWebNG.Repo

  import ServiceRadarWebNG.AshTestHelpers, only: [system_actor: 0]

  test "list_gateways returns gateways ordered by last_seen desc" do
    Repo.insert_all("gateways", [
      %{
        gateway_id: "test-gateway-1",
        last_seen: ~U[2025-01-01 00:00:00Z]
      },
      %{
        gateway_id: "test-gateway-2",
        last_seen: ~U[2025-02-01 00:00:00Z]
      }
    ])

    gateways =
      Gateway
      |> Ash.Query.sort(last_seen: :desc)
      |> Ash.Query.limit(10)
      |> Ash.read!(actor: system_actor())

    ids = Enum.map(gateways, & &1.id)

    assert "test-gateway-2" in ids
    assert "test-gateway-1" in ids

    assert Enum.find_index(ids, &(&1 == "test-gateway-2")) <
             Enum.find_index(ids, &(&1 == "test-gateway-1"))
  end
end
