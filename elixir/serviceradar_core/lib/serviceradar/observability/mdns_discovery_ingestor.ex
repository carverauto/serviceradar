defmodule ServiceRadar.Observability.MdnsDiscoveryIngestor do
  @moduledoc """
  Ingests mDNS discovery records from the gRPC push pipeline.

  Receives JSON payloads with `"records"` containing mDNS discovery data,
  inserts events into the `mdns_discovery_events` table, and upserts
  discovered devices into `ocsf_devices`.

  ## Payload Format

      %{"records" => [%{"record_type" => "A", "hostname" => "...", ...}]}
  """

  require Logger

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Observability.MdnsPubSub
  alias ServiceRadar.Repo

  import Ecto.Query

  @spec ingest(map() | list(), map()) :: :ok | {:error, term()}
  def ingest(payload, _status) when is_map(payload) or is_list(payload) do
    records = normalize_records(payload)

    if records == [] do
      :ok
    else
      rows = Enum.map(records, &record_to_row/1)
      {count, _} = Repo.insert_all("mdns_discovery_events", rows, on_conflict: :nothing, returning: false)

      devices_upserted = upsert_devices(records)

      MdnsPubSub.broadcast_ingest(%{count: count, devices_upserted: devices_upserted})
      :ok
    end
  rescue
    e ->
      Logger.error("mDNS discovery ingest failed: #{inspect(e)}")
      {:error, e}
  end

  def ingest(_payload, _status), do: {:error, :invalid_payload}

  defp normalize_records(%{"records" => records}) when is_list(records), do: records
  defp normalize_records(records) when is_list(records), do: records
  defp normalize_records(_), do: []

  defp record_to_row(record) when is_map(record) do
    time = time_from_nanos(record["time_received_ns"])

    %{
      id: UUID.uuid4(),
      time: time,
      record_type: record["record_type"] || "UNKNOWN",
      source_ip: record["source_ip"],
      hostname: record["hostname"],
      resolved_addr: record["resolved_addr"],
      dns_name: record["dns_name"],
      dns_ttl: record["dns_ttl"],
      device_uid: nil,
      created_at: DateTime.utc_now()
    }
  end

  defp time_from_nanos(nil), do: DateTime.utc_now()
  defp time_from_nanos(0), do: DateTime.utc_now()

  defp time_from_nanos(ns) when is_integer(ns) do
    ns
    |> DateTime.from_unix!(:nanosecond)
    |> DateTime.truncate(:microsecond)
  end

  defp time_from_nanos(_), do: DateTime.utc_now()

  defp upsert_devices(records) do
    # DB connection's search_path determines the schema
    device_records =
      records
      |> Enum.filter(fn r -> r["record_type"] in ["A", "AAAA"] end)
      |> Enum.filter(fn r ->
        addr = r["resolved_addr"]
        is_binary(addr) and addr != ""
      end)
      |> Enum.uniq_by(fn r -> r["resolved_addr"] end)

    if Enum.empty?(device_records) do
      0
    else
      timestamp = DateTime.utc_now() |> DateTime.truncate(:second)
      actor = SystemActor.system(:mdns_discovery_ingestor)

      Enum.reduce(device_records, 0, fn record, count ->
        ip = record["resolved_addr"]
        hostname = if record["hostname"] != "", do: record["hostname"], else: nil

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
        insert_new_device(ip, hostname, timestamp)

      {_n, _} ->
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
