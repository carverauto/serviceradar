defmodule ServiceRadar.Edge.Projectors.MapperTopology do
  @moduledoc """
  Projects `serviceradar.mapper.topology.batch` edge records into
  `ServiceRadar.NetworkDiscovery.MapperResultsIngestor.ingest_topology/2`,
  the destination `service_type: "mapper_topology"` results have today.
  Each batch is rebuilt as the JSON update array the legacy status push
  carried (candidate-only links were already filtered by the agent's
  payload builder), so topology normalization and confidence handling are
  unchanged.
  """

  @behaviour ServiceRadar.Edge.Projector

  alias ServiceRadar.Edge.Compression
  alias ServiceRadar.Edge.Projectors.DiscoveryCommon
  alias Serviceradar.Edge.V1.EdgeRecordV1
  alias Serviceradar.Edge.V1.MapperTopologyBatchV1
  alias Serviceradar.Edge.V1.MapperTopologyLinkRecordV1
  alias ServiceRadar.Edge.WireDecode
  alias ServiceRadar.NetworkDiscovery.MapperResultsIngestor

  @doc """
  Decodes and validates a mapper topology batch: no source authorization,
  a host-stamped agent id, at least one link, one projected row per link,
  and per link a local device anchor.
  """
  @impl true
  def decode(
        %EdgeRecordV1{
          source_authorization: nil,
          payload_family: :EDGE_RECORD_PAYLOAD_FAMILY_RECORD_BATCH_V1
        } = record
      ) do
    with {:ok, body} <- Compression.inner_payload(record),
         {:ok, %MapperTopologyBatchV1{} = batch} <- WireDecode.decode_mapper_topology_batch(body),
         :ok <-
           DiscoveryCommon.check(
             DiscoveryCommon.present?(batch.agent_id),
             :mapper_topology_batch_no_agent
           ),
         :ok <- DiscoveryCommon.check(batch.links != [], :mapper_topology_batch_empty),
         :ok <-
           DiscoveryCommon.check(
             length(batch.links) == record.projected_row_count,
             :mapper_topology_batch_row_count
           ),
         :ok <- check_links(batch.links) do
      {:ok, batch}
    end
  end

  def decode(%EdgeRecordV1{source_authorization: nil}), do: {:error, :unsupported_payload_family}
  def decode(%EdgeRecordV1{}), do: {:error, :mapper_topology_batch_source_authorization}

  @doc """
  Ingests the rebuilt topology payload after checking the standing grant
  is still current.
  """
  @impl true
  def publish(%EdgeRecordV1{} = record, %MapperTopologyBatchV1{} = batch, _opts) do
    DiscoveryCommon.with_current_grant(record, fn _agent_id ->
      message = batch.links |> Enum.map(&link_update/1) |> DiscoveryCommon.encode_updates()

      case MapperResultsIngestor.ingest_topology(message, %{}) do
        :ok -> :ok
        {:ok, _} -> :ok
        {:error, reason} -> {:error, {:mapper_topology_ingest_failed, reason}}
      end
    end)
  end

  defp check_links(links) do
    Enum.reduce_while(links, :ok, fn %MapperTopologyLinkRecordV1{} = link, :ok ->
      if DiscoveryCommon.present?(link.local_device_id) or
           DiscoveryCommon.present?(link.local_device_ip) do
        {:cont, :ok}
      else
        {:halt, {:error, :mapper_topology_link_no_local_device}}
      end
    end)
  end

  defp link_update(%MapperTopologyLinkRecordV1{} = link) do
    %{
      "protocol" => link.protocol,
      "local_device_ip" => link.local_device_ip,
      "local_device_id" => link.local_device_id,
      "local_if_index" => link.local_if_index,
      "local_if_name" => link.local_if_name,
      "neighbor_device_id" => link.neighbor_device_id,
      "neighbor_chassis_id" => link.neighbor_chassis_id,
      "neighbor_port_id" => link.neighbor_port_id,
      "neighbor_port_descr" => link.neighbor_port_descr,
      "neighbor_system_name" => link.neighbor_system_name,
      "neighbor_mgmt_addr" => link.neighbor_mgmt_addr,
      "metadata" => link.metadata || %{},
      "timestamp" => DiscoveryCommon.iso8601(link.timestamp_unix_nano),
      "agent_id" => link.agent_id,
      "gateway_id" => link.gateway_id,
      "partition" => link.partition
    }
    |> DiscoveryCommon.put_present("neighbor_identity", neighbor_identity(link.neighbor_identity))
    |> DiscoveryCommon.put_present("observation", topology_observation(link.observation))
    |> DiscoveryCommon.put_present("confidence_tier", link.confidence_tier)
    |> DiscoveryCommon.put_present("confidence_reason", link.confidence_reason)
    |> DiscoveryCommon.compact()
  end

  defp neighbor_identity(nil), do: nil

  defp neighbor_identity(identity) do
    DiscoveryCommon.compact(%{
      "management_ip" => identity.management_ip,
      "device_id" => identity.device_id,
      "chassis_id" => identity.chassis_id,
      "port_id" => identity.port_id,
      "port_descr" => identity.port_descr,
      "system_name" => identity.system_name
    })
  end

  defp topology_observation(nil), do: nil

  defp topology_observation(observation) do
    %{
      "contract_version" => observation.contract_version,
      "observation_type" => observation.observation_type,
      "source_protocol" => observation.source_protocol,
      "source_adapter" => observation.source_adapter,
      "evidence_class" => observation.evidence_class,
      "confidence_tier" => observation.confidence_tier,
      "observed_at_unix" => observation.observed_at_unix,
      "discovery_id" => observation.discovery_id,
      "raw_attributes" => observation.raw_attributes || %{}
    }
    |> DiscoveryCommon.put_present(
      "source_endpoint",
      topology_endpoint(observation.source_endpoint)
    )
    |> DiscoveryCommon.put_present(
      "target_endpoint",
      topology_endpoint(observation.target_endpoint)
    )
    |> DiscoveryCommon.compact()
  end

  defp topology_endpoint(nil), do: nil

  defp topology_endpoint(endpoint) do
    DiscoveryCommon.compact(%{
      "uid" => endpoint.uid,
      "device_id" => endpoint.device_id,
      "ip" => endpoint.ip,
      "mac" => endpoint.mac,
      "port_id" => endpoint.port_id,
      "if_name" => endpoint.if_name,
      "if_index" => endpoint.if_index,
      "sys_name" => endpoint.sys_name
    })
  end
end
