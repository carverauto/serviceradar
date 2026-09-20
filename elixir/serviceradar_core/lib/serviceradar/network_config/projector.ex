defmodule ServiceRadar.NetworkConfig.Projector do
  @moduledoc """
  Turn interface facts into TopologyGraph / Dgraph Prefix updates.

  Config-declared evidence uses `ingestor=network_config_v1`,
  `evidence_class=config-declared`, and `protocol=config`. The projector
  upserts Prefix nodes and `iface.prefixes`. It does not emit or overwrite
  `direct-physical` backbone edges.
  """

  alias ServiceRadar.Graph
  alias ServiceRadar.NetworkDiscovery.TopologyGraph.DgraphPersist
  alias ServiceRadar.NetworkDiscovery.TopologyGraph.Persist
  alias ServiceRadar.NetworkDiscovery.TopologyGraph.Utils

  @ingestor "network_config_v1"
  @evidence_class "config-declared"
  @protocol "config"

  @spec ingestor() :: String.t()
  def ingestor, do: @ingestor

  @spec evidence_class() :: String.t()
  def evidence_class, do: @evidence_class

  @spec protocol() :: String.t()
  def protocol, do: @protocol

  @spec project(String.t(), map() | String.t(), [map()], keyword()) :: :ok | {:error, term()}
  def project(device_uid, revision, facts, opts \\ [])
      when is_binary(device_uid) and is_list(facts) do
    persist_age = Keyword.get(opts, :persist_age, &persist_age_interfaces/2)
    persist_dgraph = Keyword.get(opts, :persist_dgraph, &DgraphPersist.project_config_facts/1)
    payloads = payloads(device_uid, revision, facts)

    with :ok <- persist_age.(device_uid, payloads),
         :ok <- persist_dgraph.(payloads) do
      :ok
    end
  end

  @spec payloads(String.t(), map() | String.t(), [map()]) :: map()
  def payloads(device_uid, revision, facts) when is_binary(device_uid) and is_list(facts) do
    revision_id = revision_id(revision)

    %{
      device_uid: device_uid,
      revision_id: revision_id,
      ingestor: @ingestor,
      evidence_class: @evidence_class,
      protocol: @protocol,
      overwrite_backbone?: false,
      interfaces:
        facts
        |> Enum.map(&interface_payload(device_uid, &1))
        |> Enum.reject(&is_nil/1),
      prefixes:
        facts
        |> Enum.flat_map(&prefix_payloads(device_uid, &1))
        |> Enum.uniq_by(&{&1.interface_id, &1.cidr})
    }
  end

  defp persist_age_interfaces(device_uid, payloads) do
    Enum.reduce_while(payloads.interfaces, :ok, fn iface, :ok ->
      cypher = """
      MERGE (d:Device {id: '#{Graph.escape(device_uid)}'})
      MERGE (i:Interface {id: '#{Graph.escape(iface.interface_id)}'})
      SET i.device_id = '#{Graph.escape(device_uid)}'
      #{Utils.set_prop("i", "name", iface.if_name)}
      #{Utils.set_prop("i", "descr", iface.description)}
      #{Utils.set_prop("i", "shutdown", iface.shutdown)}
      MERGE (d)-[:HAS_INTERFACE]->(i)
      """

      case Persist.execute_age(cypher) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp interface_payload(device_uid, fact) do
    if_name = fact_value(fact, :if_name)
    interface_id = Utils.interface_id(device_uid, if_name, nil)

    if is_nil(if_name) or is_nil(interface_id) do
      nil
    else
      %{
        device_id: device_uid,
        interface_id: interface_id,
        if_name: if_name,
        description: fact_value(fact, :description),
        shutdown: fact_value(fact, :shutdown) || false,
        vlan: fact_value(fact, :vlan),
        vrf: fact_value(fact, :vrf),
        ipv4_prefix: fact_value(fact, :ipv4_prefix),
        ipv6_prefix: fact_value(fact, :ipv6_prefix),
        ingestor: @ingestor,
        evidence_class: @evidence_class,
        protocol: @protocol
      }
    end
  end

  defp prefix_payloads(device_uid, fact) do
    case interface_payload(device_uid, fact) do
      nil ->
        []

      iface ->
        [
          prefix_entry(iface, fact_value(fact, :ipv4_prefix), "ipv4"),
          prefix_entry(iface, fact_value(fact, :ipv6_prefix), "ipv6")
        ]
        |> Enum.reject(&is_nil/1)
    end
  end

  defp prefix_entry(iface, cidr, family) when is_binary(cidr) and cidr != "" do
    %{
      device_id: iface.device_id,
      interface_id: iface.interface_id,
      if_name: iface.if_name,
      cidr: cidr,
      family: family,
      ingestor: @ingestor,
      evidence_class: @evidence_class,
      protocol: @protocol
    }
  end

  defp prefix_entry(_iface, _cidr, _family), do: nil

  defp revision_id(%{id: id}) when not is_nil(id), do: to_string(id)
  defp revision_id(%{"id" => id}) when not is_nil(id), do: to_string(id)
  defp revision_id(id) when is_binary(id), do: id
  defp revision_id(_), do: nil

  defp fact_value(fact, key) when is_map(fact) do
    Map.get(fact, key, Map.get(fact, Atom.to_string(key)))
  end
end
