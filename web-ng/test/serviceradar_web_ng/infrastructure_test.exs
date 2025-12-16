defmodule ServiceRadarWebNG.InfrastructureTest do
  use ServiceRadarWebNG.DataCase, async: true

  alias ServiceRadarWebNG.Infrastructure
  alias ServiceRadarWebNG.Repo

  test "list_pollers returns pollers ordered by last_seen desc" do
    Repo.insert_all("pollers", [
      %{
        poller_id: "test-poller-1",
        last_seen: ~U[2025-01-01 00:00:00Z]
      },
      %{
        poller_id: "test-poller-2",
        last_seen: ~U[2025-02-01 00:00:00Z]
      }
    ])

    pollers = Infrastructure.list_pollers(limit: 10)
    ids = Enum.map(pollers, & &1.id)

    assert "test-poller-2" in ids
    assert "test-poller-1" in ids

    assert Enum.find_index(ids, &(&1 == "test-poller-2")) <
             Enum.find_index(ids, &(&1 == "test-poller-1"))
  end
end
