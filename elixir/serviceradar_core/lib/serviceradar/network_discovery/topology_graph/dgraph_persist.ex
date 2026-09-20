defmodule ServiceRadar.NetworkDiscovery.TopologyGraph.DgraphPersist do
  @moduledoc false

  alias ServiceRadar.Dgraph
  alias ServiceRadar.NetworkDiscovery.TopologyGraph.Backend
  alias ServiceRadar.NetworkDiscovery.TopologyGraph.Projection

  require Logger

  @spec upsert_interface(map()) :: :ok
  def upsert_interface(payload) when is_map(payload) do
    maybe(fn ->
      with :ok <-
             Dgraph.upsert_device(%{
               id: payload.device_id,
               ip: payload[:ip]
             }),
           :ok <-
             Dgraph.upsert_interface(%{
               key: payload.interface_id,
               device_id: payload.device_id,
               name: payload.if_name,
               if_index: int_or_nil(payload.if_index)
             }) do
        :ok
      end
    end)
  end

  @doc """
  Project config-declared interface and Prefix facts. Does not upsert
  canonical or CONNECTS_TO edges, so mapper `direct-physical` backbone
  is left untouched.
  """
  @spec project_config_facts(map()) :: :ok
  def project_config_facts(payloads) when is_map(payloads) do
    maybe(fn ->
      device_uid = payloads[:device_uid] || payloads[:device_id]
      revision_id = payloads[:revision_id]

      with :ok <-
             Dgraph.upsert_device(%{
               id: device_uid,
               config_revision_id: revision_id && to_string(revision_id)
             }),
           :ok <- upsert_config_interfaces(payloads[:interfaces] || []),
           :ok <- upsert_config_prefixes(payloads[:prefixes] || []) do
        :ok
      end
    end)
  end

  @spec upsert_link(map(), String.t()) :: :ok
  def upsert_link(payload, relation) when is_map(payload) and is_binary(relation) do
    maybe(fn ->
      with :ok <- upsert_endpoint(payload.local_device_id, payload.local_device_ip),
           :ok <- upsert_endpoint(payload.neighbor_device_id, payload.neighbor_ip),
           :ok <-
             maybe_interface(
               payload.local_interface_id,
               payload.local_device_id,
               payload.local_if_name,
               payload.local_if_index
             ),
           :ok <-
             maybe_interface(
               payload.neighbor_interface_id,
               payload.neighbor_device_id,
               payload.neighbor_port_name,
               nil
             ),
           :ok <-
             Dgraph.upsert_edge(%{
               source: payload.local_device_id,
               target: payload.neighbor_device_id,
               kind: edge_kind(relation),
               protocol: payload.protocol || "unknown",
               evidence_class: payload.evidence_class || "direct",
               ingestor: "mapper_topology_v1",
               if_name_ab: payload.local_if_name,
               if_name_ba: payload.neighbor_port_name,
               if_index_ab: int_or_nil(payload.local_if_index),
               if_index_ba: 0,
               confidence_tier: payload.confidence_tier,
               last_seen: payload.observed_at
             }) do
        :ok
      end
    end)
  end

  @spec upsert_risk_summary(String.t(), map()) :: :ok
  def upsert_risk_summary(device_uid, summary) when is_binary(device_uid) and is_map(summary) do
    maybe(fn ->
      Dgraph.upsert_device(%{
        id: device_uid,
        pkg_worst_severity: summary[:pkg_worst_severity] || summary["pkg_worst_severity"],
        pkg_critical_count: summary[:pkg_critical_count] || summary["pkg_critical_count"],
        pkg_kev_count: summary[:pkg_kev_count] || summary["pkg_kev_count"],
        pkg_has_unpatched_rce:
          summary[:pkg_has_unpatched_rce] || summary["pkg_has_unpatched_rce"],
        pkg_risk_summary_at: summary[:pkg_risk_summary_at] || summary["pkg_risk_summary_at"]
      })
    end)
  end

  @spec prune_stale(String.t()) :: :ok
  def prune_stale(cutoff) when is_binary(cutoff) do
    maybe(fn ->
      case Dgraph.prune_stale(cutoff) do
        {:ok, _count} -> :ok
        other -> other
      end
    end)
  end

  @spec upsert_mtr_path(map()) :: :ok
  def upsert_mtr_path(attrs) when is_map(attrs) do
    maybe(fn ->
      from_id = Map.fetch!(attrs, :from_id)
      to_id = Map.fetch!(attrs, :to_id)
      from_kind = Map.get(attrs, :from_kind, :device)
      to_kind = Map.get(attrs, :to_kind, :device)

      with :ok <- upsert_mtr_node(from_kind, from_id),
           :ok <- upsert_mtr_node(to_kind, to_id),
           :ok <-
             Dgraph.upsert_mtr_path(%{
               source: from_id,
               target: to_id,
               kind: :mtr_path,
               protocol: "mtr",
               evidence_class: "path",
               ingestor: "mtr_path_v1",
               agent_id: Map.get(attrs, :agent_id),
               last_seen: Map.get(attrs, :observed_at)
             }) do
        :ok
      end
    end)
  end

  @spec rebuild_canonical_from_age_rows([map()]) :: :ok
  def rebuild_canonical_from_age_rows(rows) when is_list(rows) do
    maybe(fn ->
      edges =
        rows
        |> Enum.map(&canonical_edge_from_row/1)
        |> Enum.reject(&is_nil/1)

      Dgraph.rebuild_canonical(edges)
    end)
  end

  @spec projection_relation(map()) :: String.t()
  def projection_relation(payload) when is_map(payload) do
    Projection.evidence_relation_type(payload)
  end

  defp upsert_endpoint(id, ip) when is_binary(id) do
    Dgraph.upsert_device(%{id: id, ip: ip})
  end

  defp upsert_endpoint(_, _), do: :ok

  defp maybe_interface(nil, _device_id, _name, _index), do: :ok

  defp maybe_interface(key, device_id, name, index)
       when is_binary(key) and is_binary(device_id) do
    Dgraph.upsert_interface(%{
      key: key,
      device_id: device_id,
      name: name,
      if_index: int_or_nil(index)
    })
  end

  defp maybe_interface(_, _, _, _), do: :ok

  defp upsert_mtr_node(:hop, ip) when is_binary(ip), do: Dgraph.upsert_hop(%{ip: ip})
  defp upsert_mtr_node(_, id) when is_binary(id), do: Dgraph.upsert_device(%{id: id})
  defp upsert_mtr_node(_, _), do: :ok

  defp canonical_edge_from_row(row) when is_map(row) do
    source = row_value(row, :local_device_id) || row_value(row, :source) || row_value(row, :a)
    target = row_value(row, :neighbor_device_id) || row_value(row, :target) || row_value(row, :b)

    if is_binary(source) and is_binary(target) do
      %{
        source: source,
        target: target,
        kind: :canonical_topology,
        protocol: row_value(row, :protocol) || "unknown",
        evidence_class: row_value(row, :evidence_class) || "direct",
        ingestor: "mapper_topology_v1",
        if_name_ab: row_value(row, :local_if_name),
        if_name_ba: row_value(row, :neighbor_if_name),
        if_index_ab: int_or_nil(row_value(row, :local_if_index)),
        if_index_ba: int_or_nil(row_value(row, :neighbor_if_index)),
        confidence_tier: row_value(row, :confidence_tier),
        flow_pps_ab: int_or_nil(row_value(row, :flow_pps_ab)),
        flow_pps_ba: int_or_nil(row_value(row, :flow_pps_ba)),
        flow_bps_ab: int_or_nil(row_value(row, :flow_bps_ab)),
        flow_bps_ba: int_or_nil(row_value(row, :flow_bps_ba)),
        capacity_bps: int_or_nil(row_value(row, :capacity_bps)),
        telemetry_eligible: row_value(row, :telemetry_eligible) == true
      }
    end
  end

  defp canonical_edge_from_row(_), do: nil

  defp row_value(row, key) do
    Map.get(row, key, Map.get(row, Atom.to_string(key)))
  end

  defp edge_kind("CONNECTS_TO"), do: :connects_to
  defp edge_kind("CANONICAL_TOPOLOGY"), do: :canonical_topology
  defp edge_kind("LOGICAL_PEER"), do: :logical_peer
  defp edge_kind("HOSTED_ON"), do: :hosted_on
  defp edge_kind("INFERRED_TO"), do: :inferred_to
  defp edge_kind("ATTACHED_TO"), do: :attached_to
  defp edge_kind("MTR_PATH"), do: :mtr_path
  defp edge_kind("CONFIG_DECLARED"), do: :config_declared
  defp edge_kind(_), do: :inferred_to

  defp int_or_nil(value) when is_integer(value), do: value

  defp int_or_nil(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} -> int
      :error -> nil
    end
  end

  defp int_or_nil(_), do: nil

  defp upsert_config_interfaces(interfaces) do
    Enum.reduce_while(interfaces, :ok, fn iface, :ok ->
      result =
        Dgraph.upsert_interface(%{
          key: iface.interface_id,
          device_id: iface.device_id,
          name: iface.if_name,
          if_index: int_or_nil(iface[:if_index])
        })

      case result do
        :ok -> {:cont, :ok}
        other -> {:halt, other}
      end
    end)
  end

  defp upsert_config_prefixes(prefixes) do
    Enum.reduce_while(prefixes, :ok, fn prefix, :ok ->
      result =
        with :ok <- Dgraph.upsert_prefix(%{cidr: prefix.cidr, family: prefix.family}),
             :ok <- Dgraph.attach_prefix(prefix.interface_id, prefix.cidr) do
          :ok
        end

      case result do
        :ok -> {:cont, :ok}
        other -> {:halt, other}
      end
    end)
  end

  defp maybe(fun) when is_function(fun, 0) do
    if Backend.write_dgraph?() do
      try do
        case fun.() do
          :ok ->
            :ok

          {:ok, _} ->
            :ok

          {:error, reason} ->
            Logger.warning("Dgraph topology persist failed: #{inspect(reason)}")
            :ok
        end
      rescue
        exception ->
          Logger.warning("Dgraph topology persist raised: #{inspect(exception)}")
          :ok
      end
    else
      :ok
    end
  end
end
