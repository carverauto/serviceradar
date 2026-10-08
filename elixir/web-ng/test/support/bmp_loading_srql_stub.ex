defmodule ServiceRadarWebNG.TestSupport.BmpLoadingSRQLStub do
  @moduledoc false
  @behaviour ServiceRadarWebNG.SRQLBehaviour

  @impl true
  def query(query, _opts) do
    row =
      if String.contains?(query, "event_type:peer_up") do
        %{"id" => "peer-a", "event_type" => "peer_up", "router_ip" => "192.0.2.2"}
      else
        %{"id" => "route-a", "event_type" => "route_update", "router_ip" => "192.0.2.1", "prefix" => "198.51.100.0/24"}
      end

    {:ok, %{"results" => [row], "pagination" => %{}, "error" => nil}}
  end

  @impl true
  def query_request(%{"query" => query}), do: query(query, %{})
end
