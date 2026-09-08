defmodule Mix.Tasks.Serviceradar.TopologyReport do
  @shortdoc "Print per-run topology operator report as JSON"

  @moduledoc """
  Emits a per-run topology operator report as JSON.

  Output includes:
  - devices by discovery source
  - topology observations by protocol/evidence class
  - projection diagnostics (accepted/rejected reason buckets)
  - unresolved endpoint IDs in the lookback window

  Usage:
    mix serviceradar.topology_report
    mix serviceradar.topology_report --lookback-minutes 30
  """

  use Mix.Task

  import Ecto.Query

  alias Ecto.Adapters.SQL
  alias ServiceRadar.NetworkDiscovery.MapperResultsIngestor
  alias ServiceRadar.NetworkDiscovery.TopologyGraph
  alias ServiceRadar.NetworkDiscovery.TopologyLink
  alias ServiceRadar.Repo

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _argv, _invalid} =
      OptionParser.parse(args,
        strict: [lookback_minutes: :integer]
      )

    lookback_minutes = Keyword.get(opts, :lookback_minutes, 60)
    cutoff = DateTime.add(DateTime.utc_now(), -lookback_minutes * 60, :second)

    report =
      %{
        generated_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
        lookback_minutes: lookback_minutes,
        devices_by_source: devices_by_source(),
        observations_by_type: observations_by_type(cutoff),
        projection_diagnostics: projection_diagnostics(cutoff),
        unresolved_ids: unresolved_ids(cutoff)
      }

    Mix.shell().info(Jason.encode!(report, pretty: true))
  end

  defp devices_by_source do
    sql = """
    WITH expanded AS (
      SELECT uid, unnest(COALESCE(discovery_sources, ARRAY['unknown'])) AS source
      FROM platform.ocsf_devices
      WHERE deleted_at IS NULL
    )
    SELECT source, COUNT(DISTINCT uid)
    FROM expanded
    GROUP BY source
    ORDER BY source
    """

    case SQL.query(Repo, sql, []) do
      {:ok, %{rows: rows}} ->
        Enum.map(rows, fn [source, count] ->
          %{source: source || "unknown", count: count || 0}
        end)

      _ ->
        []
    end
  end

  defp observations_by_type(cutoff) do
    TopologyLink
    |> where([l], l.timestamp >= ^cutoff)
    |> select([l], %{protocol: l.protocol, metadata: l.metadata})
    |> Repo.all()
    |> Enum.reduce(%{}, fn link, acc ->
      protocol =
        link.protocol
        |> to_string()
        |> String.trim()
        |> case do
          "" -> "unknown"
          value -> String.downcase(value)
        end

      evidence_class =
        (link.metadata || %{})
        |> Map.get("evidence_class")
        |> case do
          nil -> "unknown"
          value -> value |> to_string() |> String.trim() |> String.downcase()
        end

      Map.update(acc, {protocol, evidence_class}, 1, &(&1 + 1))
    end)
    |> Enum.map(fn {{protocol, evidence_class}, count} ->
      %{protocol: protocol, evidence_class: evidence_class, count: count}
    end)
    |> Enum.sort_by(&{&1.protocol, &1.evidence_class})
  end

  defp projection_diagnostics(cutoff) do
    links =
      TopologyLink
      |> where([l], l.timestamp >= ^cutoff)
      |> Repo.all()
      |> Enum.map(&topology_link_to_update/1)
      |> Enum.map(&MapperResultsIngestor.normalize_topology/1)
      |> Enum.reject(&is_nil/1)

    TopologyGraph.projection_diagnostics(links)
  end

  defp topology_link_to_update(link) do
    %{
      timestamp: link.timestamp,
      agent_id: link.agent_id,
      gateway_id: link.gateway_id,
      partition: link.partition,
      protocol: link.protocol,
      local_device_ip: link.local_device_ip,
      local_device_id: link.local_device_id,
      local_if_index: link.local_if_index,
      local_if_name: link.local_if_name,
      neighbor_device_id: link.neighbor_device_id,
      neighbor_chassis_id: link.neighbor_chassis_id,
      neighbor_port_id: link.neighbor_port_id,
      neighbor_port_descr: link.neighbor_port_descr,
      neighbor_system_name: link.neighbor_system_name,
      neighbor_mgmt_addr: link.neighbor_mgmt_addr,
      metadata: link.metadata || %{}
    }
  end

  defp unresolved_ids(cutoff) do
    sql = """
    WITH ids AS (
      SELECT local_device_id AS uid
      FROM platform.mapper_topology_links
      WHERE timestamp >= $1
        AND local_device_id IS NOT NULL
        AND btrim(local_device_id) <> ''
      UNION
      SELECT neighbor_device_id AS uid
      FROM platform.mapper_topology_links
      WHERE timestamp >= $1
        AND neighbor_device_id IS NOT NULL
        AND btrim(neighbor_device_id) <> ''
    )
    SELECT ids.uid
    FROM ids
    LEFT JOIN platform.ocsf_devices d
      ON d.uid = ids.uid
      AND d.deleted_at IS NULL
    WHERE d.uid IS NULL
    ORDER BY ids.uid
    """

    case SQL.query(Repo, sql, [cutoff]) do
      {:ok, %{rows: rows}} -> Enum.map(rows, fn [uid] -> uid end)
      _ -> []
    end
  end
end
