defmodule ServiceRadar.EventWriter.Processors.Mdns do
  @moduledoc """
  Processor for mDNS discovery messages.

  Decodes protobuf-encoded `MdnsRecord` messages from the Rust mDNS collector,
  inserts discovery events into the `mdns_discovery_events` hypertable, and
  upserts discovered devices into `ocsf_devices`.

  ## Message Format

  Binary protobuf-encoded `Mdnspb.MdnsRecord` messages published to
  NATS subject `discovery.raw.mdns`.
  """

  @behaviour ServiceRadar.EventWriter.Processor

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Observability.MdnsPubSub
  alias ServiceRadar.Repo

  import Ecto.Query

  require Logger

  @impl true
  def table_name, do: "mdns_discovery_events"

  @impl true
  def process_batch(messages) do
    # DB connection's search_path determines the schema
    decoded = decode_messages(messages)

    if Enum.empty?(decoded) do
      {:ok, 0}
    else
      rows = Enum.map(decoded, &record_to_row/1)
      {count, _} = Repo.insert_all(table_name(), rows, on_conflict: :nothing, returning: false)

      devices_upserted = upsert_devices(decoded)

      MdnsPubSub.broadcast_ingest(%{count: count, devices_upserted: devices_upserted})
      {:ok, count}
    end
  rescue
    e ->
      Logger.error("mDNS batch insert failed: #{inspect(e)}")
      {:error, e}
  end

  # Decode protobuf messages, skipping any that fail to parse
  defp decode_messages(messages) do
    messages
    |> Enum.map(fn %{data: data} -> safe_decode(data) end)
    |> Enum.reject(&is_nil/1)
  end

  defp safe_decode(data) do
    Mdnspb.MdnsRecord.decode(data)
  rescue
    e ->
      Logger.debug("Failed to decode mDNS protobuf: #{inspect(e)}")
      nil
  end

  defp record_to_row(record) do
    time = time_from_nanos(record.time_received_ns)

    %{
      id: UUID.uuid4(),
      time: time,
      record_type: record_type_string(record.record_type),
      source_ip: format_ip(record.source_ip),
      hostname: record.hostname,
      resolved_addr: record.resolved_addr_str,
      dns_name: record.dns_name,
      dns_ttl: record.dns_ttl,
      device_uid: nil,
      created_at: DateTime.utc_now()
    }
  end

  defp time_from_nanos(0), do: DateTime.utc_now()

  defp time_from_nanos(ns) when is_integer(ns) do
    ns
    |> DateTime.from_unix!(:nanosecond)
    |> DateTime.truncate(:microsecond)
  end

  defp record_type_string(:A), do: "A"
  defp record_type_string(:AAAA), do: "AAAA"
  defp record_type_string(:PTR), do: "PTR"
  defp record_type_string(_), do: "UNKNOWN"

  defp format_ip(<<a, b, c, d>>), do: "#{a}.#{b}.#{c}.#{d}"

  defp format_ip(<<a::16, b::16, c::16, d::16, e::16, f::16, g::16, h::16>>) do
    [a, b, c, d, e, f, g, h]
    |> Enum.map(&Integer.to_string(&1, 16))
    |> Enum.join(":")
  end

  defp format_ip(_), do: nil

  # Upsert devices for A/AAAA records (they have resolved IPs)
  defp upsert_devices(records) do
    # DB connection's search_path determines the schema
    device_records =
      records
      |> Enum.filter(fn r -> r.record_type in [:A, :AAAA] end)
      |> Enum.filter(fn r -> r.resolved_addr_str != "" end)
      |> Enum.uniq_by(fn r -> r.resolved_addr_str end)

    if Enum.empty?(device_records) do
      0
    else
      timestamp = DateTime.utc_now() |> DateTime.truncate(:second)
      actor = SystemActor.system(:mdns_processor)

      Enum.reduce(device_records, 0, fn record, count ->
        ip = record.resolved_addr_str
        hostname = if record.hostname != "", do: record.hostname, else: nil

        case upsert_device(ip, hostname, timestamp, actor) do
          :ok -> count + 1
          :noop -> count
        end
      end)
    end
  rescue
    e ->
      Logger.warning("mDNS device upsert failed (non-fatal): #{inspect(e)}")
      0
  end

  defp upsert_device(ip, hostname, timestamp, _actor) do
    # DB connection's search_path determines the schema
    # Try to update existing device first
    query =
      from(d in {"ocsf_devices", Device},
        where: d.uid == ^ip
      )

    case Repo.update_all(query,
           set: [
             hostname: hostname,
             is_available: true,
             last_seen_time: timestamp,
             modified_time: timestamp
           ]
         ) do
      {0, _} ->
        # Device doesn't exist, insert it
        insert_new_device(ip, hostname, timestamp)

      {_n, _} ->
        # Updated existing device, also ensure "mdns" is in discovery_sources
        append_discovery_source(ip)
        :ok
    end
  end

  defp insert_new_device(ip, hostname, timestamp) do
    # DB connection's search_path determines the schema
    row = %{
      uid: ip,
      type_id: 0,
      name: hostname || ip,
      hostname: hostname,
      ip: ip,
      first_seen_time: timestamp,
      last_seen_time: timestamp,
      created_time: timestamp,
      modified_time: timestamp,
      is_available: true,
      is_managed: false,
      is_trusted: false,
      discovery_sources: ["mdns"],
      tags: %{},
      metadata: %{},
      os: %{},
      hw_info: %{},
      network_interfaces: [],
      owner: %{},
      org: %{},
      groups: [],
      agent_list: []
    }

    case Repo.insert_all("ocsf_devices", [row], on_conflict: :nothing, returning: false) do
      {1, _} -> :ok
      {0, _} -> :noop
    end
  end

  defp append_discovery_source(ip) do
    # DB connection's search_path determines the schema
    # Append "mdns" to discovery_sources (text[]) if not already present
    Repo.query(
      """
      UPDATE ocsf_devices
      SET discovery_sources = array_append(discovery_sources, 'mdns')
      WHERE uid = $1
        AND NOT ('mdns' = ANY(discovery_sources))
      """,
      [ip]
    )
  rescue
    _ -> :ok
  end
end
