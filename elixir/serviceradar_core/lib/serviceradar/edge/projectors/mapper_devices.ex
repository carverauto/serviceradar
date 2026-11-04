defmodule ServiceRadar.Edge.Projectors.MapperDevices do
  @moduledoc """
  Projects `serviceradar.mapper.devices.batch` edge records into the
  destinations mapper device results have today: each batch is rebuilt as
  the JSON update array the legacy `mapper` status push carried, mapper
  runs are recorded from it, and it is scheduled into the sync ingestion
  pipeline, exactly as `ServiceRadar.Ingestion.ResultIngestor` routes
  `service_type: "mapper"` results. Device metadata rides verbatim; the
  DIRE identity handling downstream is unchanged. The connecting gateway
  id the durable path cannot attest stays whatever the host stamped on
  the update, as on the legacy path.
  """

  @behaviour ServiceRadar.Edge.Projector

  alias ServiceRadar.Edge.Compression
  alias ServiceRadar.Edge.Projectors.DiscoveryCommon
  alias Serviceradar.Edge.V1.EdgeRecordV1
  alias Serviceradar.Edge.V1.MapperDeviceBatchV1
  alias Serviceradar.Edge.V1.MapperDeviceRecordV1
  alias ServiceRadar.Edge.WireDecode
  alias ServiceRadar.NetworkDiscovery.MapperResultsIngestor

  @doc """
  Decodes and validates a mapper device batch: no source authorization, a
  host-stamped agent id, at least one device, one projected row per
  device, and per device an identity anchor (device id or ip).
  """
  @impl true
  def decode(
        %EdgeRecordV1{
          source_authorization: nil,
          payload_family: :EDGE_RECORD_PAYLOAD_FAMILY_RECORD_BATCH_V1
        } = record
      ) do
    with {:ok, body} <- Compression.inner_payload(record),
         {:ok, %MapperDeviceBatchV1{} = batch} <- WireDecode.decode_mapper_device_batch(body),
         :ok <-
           DiscoveryCommon.check(
             DiscoveryCommon.present?(batch.agent_id),
             :mapper_device_batch_no_agent
           ),
         :ok <- DiscoveryCommon.check(batch.devices != [], :mapper_device_batch_empty),
         :ok <-
           DiscoveryCommon.check(
             length(batch.devices) == record.projected_row_count,
             :mapper_device_batch_row_count
           ),
         :ok <- check_devices(batch.devices) do
      {:ok, batch}
    end
  end

  def decode(%EdgeRecordV1{source_authorization: nil}), do: {:error, :unsupported_payload_family}
  def decode(%EdgeRecordV1{}), do: {:error, :mapper_device_batch_source_authorization}

  @doc """
  Records mapper runs from the rebuilt payload and schedules it for sync
  ingestion after checking the standing grant is still current.
  """
  @impl true
  def publish(%EdgeRecordV1{} = record, %MapperDeviceBatchV1{} = batch, _opts) do
    DiscoveryCommon.with_current_grant(record, fn _agent_id ->
      message = batch.devices |> Enum.map(&device_update/1) |> DiscoveryCommon.encode_updates()
      MapperResultsIngestor.record_runs_from_payload(message)
      DiscoveryCommon.schedule_sync_ingestion(message)
    end)
  end

  defp check_devices(devices) do
    Enum.reduce_while(devices, :ok, fn %MapperDeviceRecordV1{} = device, :ok ->
      if DiscoveryCommon.present?(device.device_id) or DiscoveryCommon.present?(device.ip) do
        {:cont, :ok}
      else
        {:halt, {:error, :mapper_device_no_anchor}}
      end
    end)
  end

  # Rebuilds one legacy mapper device update. Metadata is emitted verbatim
  # (the producer copies the promoted fields out of it, never the reverse),
  # and the SNMP fingerprint rides back in its nested JSON shape.
  defp device_update(%MapperDeviceRecordV1{} = device) do
    %{
      "device_id" => device.device_id,
      "ip" => device.ip,
      "source" => device.source,
      "timestamp" => DiscoveryCommon.iso8601(device.timestamp_unix_nano),
      "is_available" => device.is_available,
      "hostname" => device.hostname,
      "mac" => device.mac,
      "agent_id" => device.agent_id,
      "gateway_id" => device.gateway_id,
      "partition" => device.partition,
      "metadata" => device.metadata || %{}
    }
    |> DiscoveryCommon.put_present("snmp_fingerprint", fingerprint(device.snmp_fingerprint))
    |> DiscoveryCommon.put_present(
      "first_seen_time",
      DiscoveryCommon.iso8601_second(device.first_seen_unix_nano)
    )
    |> DiscoveryCommon.put_present(
      "last_seen_time",
      DiscoveryCommon.iso8601_second(device.last_seen_unix_nano)
    )
    |> DiscoveryCommon.compact()
  end

  defp fingerprint(nil), do: nil

  defp fingerprint(fp) do
    %{}
    |> DiscoveryCommon.put_present("system", fingerprint_system(fp.system))
    |> DiscoveryCommon.put_present("bridge", fingerprint_bridge(fp.bridge))
    |> DiscoveryCommon.put_present("vlan", fingerprint_vlan(fp.vlan))
    |> DiscoveryCommon.put_present("interface_summary", fingerprint_summary(fp.interface_summary))
    |> DiscoveryCommon.put_present("extraction_errors", fp.extraction_errors)
  end

  defp fingerprint_system(nil), do: nil

  defp fingerprint_system(system) do
    %{
      "sys_name" => system.sys_name,
      "sys_descr" => system.sys_descr,
      "sys_object_id" => system.sys_object_id,
      "sys_contact" => system.sys_contact,
      "sys_location" => system.sys_location,
      "ip_forwarding" => system.ip_forwarding
    }
  end

  defp fingerprint_bridge(nil), do: nil

  defp fingerprint_bridge(bridge) do
    %{
      "bridge_base_mac" => bridge.bridge_base_mac,
      "bridge_port_count" => bridge.bridge_port_count,
      "stp_forwarding_port_count" => bridge.stp_forwarding_port_count
    }
  end

  defp fingerprint_vlan(nil), do: nil

  defp fingerprint_vlan(vlan) do
    %{
      "vlan_ids_seen" => vlan.vlan_ids_seen || [],
      "pvid_distribution" =>
        Enum.map(vlan.pvid_distribution || [], fn entry ->
          %{"pvid" => entry.pvid, "count" => entry.count}
        end),
      "port_evidence" =>
        Enum.map(vlan.port_evidence || [], fn entry ->
          %{
            "vlan_id" => entry.vlan_id,
            "egress_ports_hex" => entry.egress_ports_hex,
            "untagged_ports_hex" => entry.untagged_ports_hex
          }
        end)
    }
  end

  defp fingerprint_summary(nil), do: nil

  defp fingerprint_summary(summary) do
    %{
      "interface_count" => summary.interface_count,
      "bridge_like_name_count" => summary.bridge_like_name_count,
      "wireless_like_name_count" => summary.wireless_like_name_count,
      "if_type_counts" =>
        Enum.map(summary.if_type_counts || [], fn entry ->
          %{"if_type" => entry.if_type, "count" => entry.count}
        end)
    }
  end
end
