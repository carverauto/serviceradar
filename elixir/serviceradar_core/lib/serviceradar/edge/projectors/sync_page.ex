defmodule ServiceRadar.Edge.Projectors.SyncPage do
  @moduledoc """
  Projects `serviceradar.sync.page.batch` edge records into the sync
  ingestion pipeline, the destination `service_type: "sync"` results have
  today. Each page is rebuilt as the JSON chunk array the legacy status
  push carried -- every device update with the page's `sync_meta`
  attached, the collection-final control item last -- so the DIRE run
  ledger, incomplete-run population guard and conflicting-identity
  refusal inside that pipeline see exactly the run shape they see today.
  The record's run ordering is the agent's chunk numbering, preserved in
  `sync_meta`.

  Rebuilt timestamps use the sync wire form (RFC3339 truncated to one
  second). Field aliases the producer resolved while converting
  (`vendor_name`, canonical interface keys) are the first forms the sync
  normalizers read, so ingest behavior is unchanged.
  """

  @behaviour ServiceRadar.Edge.Projector

  alias ServiceRadar.Edge.Compression
  alias ServiceRadar.Edge.Projectors.DiscoveryCommon
  alias Serviceradar.Edge.V1.EdgeRecordV1
  alias Serviceradar.Edge.V1.SyncDeviceRecordV1
  alias Serviceradar.Edge.V1.SyncMetaV1
  alias Serviceradar.Edge.V1.SyncPageBatchV1
  alias ServiceRadar.Edge.WireDecode

  @doc """
  Decodes and validates a sync page: no source authorization, run
  tracking metadata naming the sync run, at least one device unless the
  page carries only the control marker, a projected row count equal to
  its row formula (devices, or one for a control-only page), and per
  device an identity anchor.
  """
  @impl true
  def decode(
        %EdgeRecordV1{
          source_authorization: nil,
          payload_family: :EDGE_RECORD_PAYLOAD_FAMILY_RECORD_BATCH_V1
        } = record
      ) do
    with {:ok, body} <- Compression.inner_payload(record),
         {:ok, %SyncPageBatchV1{} = batch} <- WireDecode.decode_sync_page_batch(body),
         :ok <- check_meta(batch.sync_meta),
         :ok <-
           DiscoveryCommon.check(
             batch.devices != [] or not is_nil(batch.control_marker),
             :sync_page_empty
           ),
         :ok <-
           DiscoveryCommon.check(
             page_rows(batch) == record.projected_row_count,
             :sync_page_row_count
           ),
         :ok <- check_devices(batch.devices) do
      {:ok, batch}
    end
  end

  def decode(%EdgeRecordV1{source_authorization: nil}), do: {:error, :unsupported_payload_family}
  def decode(%EdgeRecordV1{}), do: {:error, :sync_page_source_authorization}

  @doc """
  Schedules the rebuilt page for sync ingestion after checking the
  standing grant is still current.
  """
  @impl true
  def publish(%EdgeRecordV1{} = record, %SyncPageBatchV1{} = batch, _opts) do
    DiscoveryCommon.with_current_grant(record, fn _agent_id ->
      meta = sync_meta(batch.sync_meta)

      updates = Enum.map(batch.devices, fn device -> device_update(device, meta) end)
      updates = append_control(updates, batch.control_marker, meta)

      updates
      |> DiscoveryCommon.encode_updates()
      |> DiscoveryCommon.schedule_sync_ingestion()
    end)
  end

  defp page_rows(%SyncPageBatchV1{devices: [], control_marker: marker}) when not is_nil(marker),
    do: 1

  defp page_rows(%SyncPageBatchV1{devices: devices}), do: length(devices || [])

  defp check_meta(%SyncMetaV1{sync_run_id: run_id}) do
    DiscoveryCommon.check(DiscoveryCommon.present?(run_id), :sync_page_no_run_id)
  end

  defp check_meta(_meta), do: {:error, :sync_page_no_run_id}

  defp check_devices(devices) do
    Enum.reduce_while(devices || [], :ok, fn %SyncDeviceRecordV1{} = device, :ok ->
      if DiscoveryCommon.present?(device.device_id) or DiscoveryCommon.present?(device.uid) or
           DiscoveryCommon.present?(device.ip) or DiscoveryCommon.present?(device.mac) do
        {:cont, :ok}
      else
        {:halt, {:error, :sync_device_no_anchor}}
      end
    end)
  end

  defp append_control(updates, nil, _meta), do: updates

  defp append_control(updates, marker, meta) do
    control =
      DiscoveryCommon.compact(%{
        "_sync_control" => marker.control_type,
        "timestamp" => DiscoveryCommon.iso8601_second(marker.timestamp_unix_nano),
        "sync_meta" => meta
      })

    updates ++ [control]
  end

  # The sync_meta map the legacy chunk builder stamps on every update of a
  # chunk, population attached only on the run-final chunk.
  defp sync_meta(%SyncMetaV1{} = meta) do
    base = %{
      "sync_service_id" => meta.sync_service_id,
      "sync_run_id" => meta.sync_run_id,
      "chunk_index" => meta.chunk_index,
      "total_chunks" => meta.total_chunks,
      "total_devices" => meta.total_devices,
      "is_final" => meta.is_final
    }

    if meta.is_final do
      DiscoveryCommon.put_present(base, "population", population(meta.population))
    else
      base
    end
  end

  defp population(nil), do: nil

  defp population(population) do
    %{
      "raw_rows" => population.raw_rows,
      "excluded_rows" => population.excluded_rows,
      "invalid_rows" => population.invalid_rows,
      "valid_occurrences" => population.valid_occurrences,
      "distinct_source_ids" => population.distinct_source_ids,
      "duplicate_occurrences" => population.duplicate_occurrences,
      "duplicate_source_id_examples" => population.duplicate_source_id_examples || [],
      "invalid_row_examples" => population.invalid_row_examples || [],
      "conflicting_duplicate_ids" => population.conflicting_duplicate_ids,
      "conflicting_duplicate_examples" => population.conflicting_duplicate_examples || []
    }
  end

  defp device_update(%SyncDeviceRecordV1{} = device, meta) do
    %{
      "device_id" => device.device_id,
      "uid" => device.uid,
      "uid_alt" => device.uid_alt,
      "agent_id" => device.agent_id,
      "gateway_id" => device.gateway_id,
      "partition" => device.partition,
      "ip" => device.ip,
      "mac" => device.mac,
      "hostname" => device.hostname,
      "name" => device.name,
      "source" => device.source,
      "source_instance" => device.source_instance,
      "type" => device.type,
      "type_id" => device.type_id,
      "device_type" => device.device_type,
      "vendor_name" => device.vendor_name,
      "model" => device.model,
      "domain" => device.domain,
      "zone" => device.zone,
      "subnet_uid" => device.subnet_uid,
      "vlan_uid" => device.vlan_uid,
      "region" => device.region,
      "risk_level" => device.risk_level,
      "timestamp" => DiscoveryCommon.iso8601_second(device.timestamp_unix_nano),
      "metadata" => device.metadata || %{},
      "sync_meta" => meta
    }
    |> DiscoveryCommon.put_present("discovery_sources", device.discovery_sources)
    |> DiscoveryCommon.put_present("os", device_os(device.os))
    |> DiscoveryCommon.put_present("hw_info", device_hw_info(device.hw_info))
    |> DiscoveryCommon.put_present("risk_level_id", device.risk_level_id)
    |> DiscoveryCommon.put_present("risk_score", device.risk_score)
    |> DiscoveryCommon.put_present("is_available", device.is_available)
    |> DiscoveryCommon.put_present("is_managed", device.is_managed)
    |> DiscoveryCommon.put_present("is_compliant", device.is_compliant)
    |> DiscoveryCommon.put_present("is_trusted", device.is_trusted)
    |> DiscoveryCommon.put_present(
      "first_seen_time",
      DiscoveryCommon.iso8601_second(device.first_seen_unix_nano)
    )
    |> DiscoveryCommon.put_present(
      "last_seen_time",
      DiscoveryCommon.iso8601_second(device.last_seen_unix_nano)
    )
    |> DiscoveryCommon.put_present(
      "created_time",
      DiscoveryCommon.iso8601_second(device.created_time_unix_nano)
    )
    |> DiscoveryCommon.put_present(
      "modified_time",
      DiscoveryCommon.iso8601_second(device.modified_time_unix_nano)
    )
    |> DiscoveryCommon.put_present(
      "network_interfaces",
      Enum.map(device.network_interfaces || [], &network_interface/1)
    )
    |> DiscoveryCommon.put_present("owner", device_user(device.owner))
    |> DiscoveryCommon.put_present("org", device_org(device.org))
    |> DiscoveryCommon.put_present("groups", Enum.map(device.groups || [], &device_group/1))
    |> DiscoveryCommon.put_present(
      "agent_list",
      Enum.map(device.agent_list || [], &device_agent/1)
    )
    |> DiscoveryCommon.put_present("switch_port_attachment", device.switch_port_attachment)
    |> DiscoveryCommon.put_present("tags", device.tags)
    |> DiscoveryCommon.put_present("facts", device.facts)
    |> DiscoveryCommon.compact()
  end

  defp device_os(nil), do: nil

  defp device_os(os) do
    %{
      "name" => os.name,
      "type" => os.type,
      "version" => os.version,
      "build" => os.build,
      "edition" => os.edition,
      "kernel_release" => os.kernel_release,
      "sp_name" => os.sp_name,
      "sp_ver" => os.sp_ver,
      "lang" => os.lang
    }
    |> DiscoveryCommon.put_present("type_id", os.type_id)
    |> DiscoveryCommon.put_present("cpu_bits", os.cpu_bits)
    |> DiscoveryCommon.compact()
  end

  defp device_hw_info(nil), do: nil

  defp device_hw_info(hw) do
    %{
      "cpu_architecture" => hw.cpu_architecture,
      "cpu_type" => hw.cpu_type,
      "serial_number" => hw.serial_number,
      "chassis" => hw.chassis,
      "bios_manufacturer" => hw.bios_manufacturer,
      "bios_ver" => hw.bios_ver,
      "bios_date" => hw.bios_date,
      "uuid" => hw.uuid
    }
    |> DiscoveryCommon.put_present("cpu_bits", hw.cpu_bits)
    |> DiscoveryCommon.put_present("cpu_cores", hw.cpu_cores)
    |> DiscoveryCommon.put_present("cpu_count", hw.cpu_count)
    |> DiscoveryCommon.put_present("cpu_speed_mhz", hw.cpu_speed_mhz)
    |> DiscoveryCommon.put_present("ram_size", hw.ram_size)
    |> DiscoveryCommon.compact()
  end

  defp network_interface(iface) do
    %{
      "name" => iface.name,
      "description" => iface.description,
      "alias" => iface.alias,
      "mac_address" => iface.mac_address,
      "ipv4_address" => iface.ipv4_address,
      "ipv6_address" => iface.ipv6_address,
      "cidr" => iface.cidr,
      "subnet" => iface.subnet,
      "hostname" => iface.hostname,
      "uid" => iface.uid,
      "type" => iface.type,
      "brand" => iface.brand,
      "broadcast_ssid" => iface.broadcast_ssid,
      "last_connected_ssid" => iface.last_connected_ssid
    }
    |> DiscoveryCommon.put_present("ip_addresses", iface.ip_addresses)
    |> DiscoveryCommon.put_present("type_id", iface.type_id)
    |> DiscoveryCommon.put_present("hidden_broadcast_ssid", iface.hidden_broadcast_ssid)
    |> DiscoveryCommon.put_present("channels", iface.channels)
    |> DiscoveryCommon.put_present("vlan", iface.vlan)
    |> DiscoveryCommon.compact()
  end

  defp device_user(nil), do: nil

  defp device_user(user) do
    %{"uid" => user.uid, "name" => user.name, "email_addr" => user.email, "type" => user.type}
    |> DiscoveryCommon.put_present("type_id", user.type_id)
    |> DiscoveryCommon.compact()
  end

  defp device_org(nil), do: nil

  defp device_org(org) do
    DiscoveryCommon.compact(%{
      "uid" => org.uid,
      "name" => org.name,
      "ou_uid" => org.ou_uid,
      "ou_name" => org.ou_name
    })
  end

  defp device_group(group) do
    DiscoveryCommon.compact(%{
      "uid" => group.uid,
      "name" => group.name,
      "type" => group.type,
      "desc" => group.desc
    })
  end

  defp device_agent(agent) do
    %{
      "uid" => agent.uid,
      "name" => agent.name,
      "type" => agent.type,
      "version" => agent.version,
      "vendor_name" => agent.vendor_name
    }
    |> DiscoveryCommon.put_present("type_id", agent.type_id)
    |> DiscoveryCommon.compact()
  end
end
