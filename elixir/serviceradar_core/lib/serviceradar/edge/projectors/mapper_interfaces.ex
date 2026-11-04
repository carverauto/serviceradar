defmodule ServiceRadar.Edge.Projectors.MapperInterfaces do
  @moduledoc """
  Projects `serviceradar.mapper.interfaces.batch` edge records into
  `ServiceRadar.NetworkDiscovery.MapperResultsIngestor.ingest_interfaces/2`,
  the destination `service_type: "mapper_interfaces"` results have today.
  Each batch is rebuilt as the JSON update array the legacy status push
  carried, so interface normalization, device resolution and alias
  handling are unchanged.
  """

  @behaviour ServiceRadar.Edge.Projector

  alias ServiceRadar.Edge.Compression
  alias ServiceRadar.Edge.Projectors.DiscoveryCommon
  alias Serviceradar.Edge.V1.EdgeRecordV1
  alias Serviceradar.Edge.V1.MapperInterfaceBatchV1
  alias Serviceradar.Edge.V1.MapperInterfaceRecordV1
  alias ServiceRadar.Edge.WireDecode
  alias ServiceRadar.NetworkDiscovery.MapperResultsIngestor

  @doc """
  Decodes and validates a mapper interface batch: no source authorization,
  a host-stamped agent id, at least one interface, one projected row per
  interface, and per interface a device anchor and an interface anchor.
  """
  @impl true
  def decode(
        %EdgeRecordV1{
          source_authorization: nil,
          payload_family: :EDGE_RECORD_PAYLOAD_FAMILY_RECORD_BATCH_V1
        } = record
      ) do
    with {:ok, body} <- Compression.inner_payload(record),
         {:ok, %MapperInterfaceBatchV1{} = batch} <-
           WireDecode.decode_mapper_interface_batch(body),
         :ok <-
           DiscoveryCommon.check(
             DiscoveryCommon.present?(batch.agent_id),
             :mapper_interface_batch_no_agent
           ),
         :ok <- DiscoveryCommon.check(batch.interfaces != [], :mapper_interface_batch_empty),
         :ok <-
           DiscoveryCommon.check(
             length(batch.interfaces) == record.projected_row_count,
             :mapper_interface_batch_row_count
           ),
         :ok <- check_interfaces(batch.interfaces) do
      {:ok, batch}
    end
  end

  def decode(%EdgeRecordV1{source_authorization: nil}), do: {:error, :unsupported_payload_family}
  def decode(%EdgeRecordV1{}), do: {:error, :mapper_interface_batch_source_authorization}

  @doc """
  Ingests the rebuilt interface payload after checking the standing grant
  is still current. An ingest error fails the batch so the record is
  redelivered, as on the legacy path.
  """
  @impl true
  def publish(%EdgeRecordV1{} = record, %MapperInterfaceBatchV1{} = batch, _opts) do
    DiscoveryCommon.with_current_grant(record, fn _agent_id ->
      message =
        batch.interfaces |> Enum.map(&interface_update/1) |> DiscoveryCommon.encode_updates()

      case MapperResultsIngestor.ingest_interfaces(message, %{}) do
        :ok -> :ok
        {:ok, _} -> :ok
        {:error, reason} -> {:error, {:mapper_interface_ingest_failed, reason}}
      end
    end)
  end

  defp check_interfaces(interfaces) do
    Enum.reduce_while(interfaces, :ok, fn %MapperInterfaceRecordV1{} = iface, :ok ->
      cond do
        not DiscoveryCommon.present?(iface.device_id) and
            not DiscoveryCommon.present?(iface.device_ip) ->
          {:halt, {:error, :mapper_interface_no_device}}

        not DiscoveryCommon.present?(iface.if_name) and iface.if_index in [nil, 0] ->
          {:halt, {:error, :mapper_interface_no_anchor}}

        true ->
          {:cont, :ok}
      end
    end)
  end

  defp interface_update(%MapperInterfaceRecordV1{} = iface) do
    %{
      "device_id" => iface.device_id,
      "device_ip" => iface.device_ip,
      "if_index" => iface.if_index,
      "if_name" => iface.if_name,
      "if_descr" => iface.if_descr,
      "if_alias" => iface.if_alias,
      "if_speed" => iface.if_speed,
      "if_phys_address" => iface.if_phys_address,
      "ip_addresses" => iface.ip_addresses || [],
      "if_admin_status" => iface.if_admin_status,
      "if_oper_status" => iface.if_oper_status,
      "if_type" => iface.if_type,
      "source" => iface.source,
      "metadata" => iface.metadata || %{},
      "available_metrics" => Enum.map(iface.available_metrics || [], &interface_metric/1),
      "timestamp" => DiscoveryCommon.iso8601(iface.timestamp_unix_nano),
      "agent_id" => iface.agent_id,
      "gateway_id" => iface.gateway_id,
      "partition" => iface.partition
    }
    |> DiscoveryCommon.put_present("speed_bps", iface.speed_bps)
    |> DiscoveryCommon.put_present("mtu", iface.mtu)
    |> DiscoveryCommon.put_present("duplex", iface.duplex)
    |> DiscoveryCommon.compact()
  end

  defp interface_metric(metric) do
    %{
      "name" => metric.name,
      "oid" => metric.oid,
      "data_type" => metric.data_type,
      "supports_64bit" => metric.supports_64bit,
      "oid_64bit" => metric.oid_64bit,
      "category" => metric.category,
      "unit" => metric.unit
    }
  end
end
