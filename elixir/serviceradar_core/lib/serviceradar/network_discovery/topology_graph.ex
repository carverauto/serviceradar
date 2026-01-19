defmodule ServiceRadar.NetworkDiscovery.TopologyGraph do
  @moduledoc """
  Projects mapper topology links into the Apache AGE graph.
  """

  require Logger

  alias ServiceRadar.Repo

  @graph "serviceradar_topology"

  @spec upsert_links([map()]) :: :ok
  def upsert_links([]), do: :ok

  def upsert_links(links) when is_list(links) do
    Enum.each(links, &upsert_link/1)
    :ok
  end

  defp upsert_link(link) when is_map(link) do
    local_id = Map.get(link, :local_device_id) || Map.get(link, "local_device_id")
    neighbor_id = neighbor_device_id(link)
    protocol = Map.get(link, :protocol) || Map.get(link, "protocol") || "unknown"
    local_if = Map.get(link, :local_if_name) || Map.get(link, "local_if_name")
    neighbor_port = Map.get(link, :neighbor_port_id) || Map.get(link, "neighbor_port_id")
    neighbor_name = Map.get(link, :neighbor_system_name) || Map.get(link, "neighbor_system_name")
    neighbor_ip = Map.get(link, :neighbor_mgmt_addr) || Map.get(link, "neighbor_mgmt_addr")

    if local_id == nil or neighbor_id == nil do
      Logger.debug("Skipping topology link missing device identifiers")
      :ok
    else
      cypher = """
      MERGE (a:Device {device_id: '#{escape(local_id)}'})
      MERGE (b:Device {device_id: '#{escape(neighbor_id)}'})
      SET a.source = 'mapper'
      SET b.source = 'mapper'
      #{neighbor_name_assignment(neighbor_name)}
      #{neighbor_ip_assignment(neighbor_ip)}
      MERGE (a)-[r:CONNECTED {protocol: '#{escape(protocol)}', local_if: '#{escape(local_if)}', neighbor_port: '#{escape(neighbor_port)}'}]->(b)
      """

      query = "SELECT * FROM ag_catalog.cypher('#{@graph}', $$#{cypher}$$) AS (v agtype);"

      case Repo.query(query) do
        {:ok, _} -> :ok
        {:error, reason} -> Logger.warning("Topology graph upsert failed: #{inspect(reason)}")
      end
    end
  end

  defp upsert_link(_link), do: :ok

  defp neighbor_device_id(link) do
    Map.get(link, :neighbor_device_id) ||
      Map.get(link, "neighbor_device_id") ||
      Map.get(link, :neighbor_mgmt_addr) ||
      Map.get(link, "neighbor_mgmt_addr") ||
      Map.get(link, :neighbor_chassis_id) ||
      Map.get(link, "neighbor_chassis_id") ||
      Map.get(link, :neighbor_system_name) ||
      Map.get(link, "neighbor_system_name")
  end

  defp neighbor_name_assignment(nil), do: ""
  defp neighbor_name_assignment(""), do: ""
  defp neighbor_name_assignment(value),
    do: "SET b.name = '#{escape(value)}'"

  defp neighbor_ip_assignment(nil), do: ""
  defp neighbor_ip_assignment(""), do: ""
  defp neighbor_ip_assignment(value),
    do: "SET b.ip = '#{escape(value)}'"

  defp escape(nil), do: ""

  defp escape(value) do
    value
    |> to_string()
    |> String.replace("'", "''")
  end
end
