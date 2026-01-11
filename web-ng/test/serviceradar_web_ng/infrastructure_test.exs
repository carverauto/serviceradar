defmodule ServiceRadarWebNG.InfrastructureTest do
  use ServiceRadarWebNG.DataCase, async: true

  alias ServiceRadarWebNG.Infrastructure
  alias ServiceRadarWebNG.Repo

  test "list_gateways returns gateways ordered by last_seen desc" do
    {:ok, tenant_uuid} = Ecto.UUID.dump(test_tenant_id())

    Repo.insert_all("gateways", [
      %{
        gateway_id: "test-gateway-1",
        last_seen: ~U[2025-01-01 00:00:00Z],
        tenant_id: tenant_uuid
      },
      %{
        gateway_id: "test-gateway-2",
        last_seen: ~U[2025-02-01 00:00:00Z],
        tenant_id: tenant_uuid
      }
    ])

    gateways = Infrastructure.list_gateways(limit: 10)
    ids = Enum.map(gateways, & &1.id)

    assert "test-gateway-2" in ids
    assert "test-gateway-1" in ids

    assert Enum.find_index(ids, &(&1 == "test-gateway-2")) <
             Enum.find_index(ids, &(&1 == "test-gateway-1"))
  end
end
