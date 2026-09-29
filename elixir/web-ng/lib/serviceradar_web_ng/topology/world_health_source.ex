defmodule ServiceRadarWebNG.Topology.WorldHealthSource do
  @moduledoc "Bounded current-state reads for the native topology availability index."

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Ash.Page
  alias ServiceRadar.Inventory.Device

  require Ash.Query

  @doc "Reads at most 500 identities; missing and topology-only sightings remain unknown."
  def fetch(ids) when is_list(ids) and length(ids) <= 500 do
    query =
      Device
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(uid in ^ids)
      |> Ash.Query.filter(
        is_nil(get_path(metadata, ["identity_source"])) or
          get_path(metadata, ["identity_source"]) != "mapper_topology_sighting"
      )
      |> Ash.Query.select([:uid, :is_available])
      |> Ash.Query.limit(500)
      |> Ash.Query.timeout(5_000)

    # The read action requires pagination. One explicit page covers this
    # already-bounded set of at most 500 unique primary identities.
    with {:ok, rows} <-
           query
           |> Ash.read(actor: SystemActor.system(:topology_health), page: [limit: 500])
           |> Page.unwrap() do
      states = Map.new(rows, &{&1.uid, availability(&1.is_available)})
      {:ok, Enum.map(ids, &%{device_id: &1, state: Map.get(states, &1, :unknown)})}
    end
  end

  def fetch(_ids), do: {:error, :invalid_batch}

  defp availability(true), do: :healthy
  defp availability(false), do: :unavailable
  defp availability(_), do: :unknown
end
