defmodule ServiceRadar.EventWriter.Processors.Sweep do
  @moduledoc """
  Processor for network sweep/discovery messages.

  Parses sweep results from NATS JetStream and inserts them into
  the `sweep_host_states` hypertable.

  ## Message Format

  JSON sweep result messages:

  ```json
  {
    "host_ip": "192.168.1.100",
    "poller_id": "poller-1",
    "agent_id": "agent-1",
    "partition": "default",
    "network_cidr": "192.168.1.0/24",
    "hostname": "server1",
    "mac": "00:11:22:33:44:55",
    "icmp_available": true,
    "icmp_response_time_ns": 1500000,
    "last_sweep_time": "2024-01-01T00:00:00Z"
  }
  ```

  ## Table Schema

  ```sql
  CREATE TABLE sweep_host_states (
    host_ip TEXT NOT NULL,
    poller_id TEXT NOT NULL,
    agent_id TEXT NOT NULL,
    partition TEXT NOT NULL,
    network_cidr TEXT,
    hostname TEXT,
    mac TEXT,
    icmp_available BOOLEAN,
    icmp_response_time_ns BIGINT,
    icmp_packet_loss DOUBLE PRECISION,
    tcp_ports_scanned JSONB,
    tcp_ports_open JSONB,
    port_scan_results JSONB,
    last_sweep_time TIMESTAMPTZ NOT NULL,
    first_seen TIMESTAMPTZ,
    metadata JSONB,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (host_ip, poller_id, partition, last_sweep_time)
  );
  ```
  """

  @behaviour ServiceRadar.EventWriter.Processor

  require Logger

  @impl true
  def table_name, do: "sweep_host_states"

  @impl true
  def process_batch(messages) do
    rows =
      messages
      |> Enum.map(&parse_message/1)
      |> Enum.reject(&is_nil/1)

    if Enum.empty?(rows) do
      {:ok, 0}
    else
      case ServiceRadar.Repo.insert_all(table_name(), rows,
             on_conflict: :nothing,
             returning: false
           ) do
        {count, _} ->
          {:ok, count}
      end
    end
  rescue
    e ->
      Logger.error("Sweep batch insert failed: #{inspect(e)}")
      {:error, e}
  end

  @impl true
  def parse_message(%{data: data, metadata: _metadata}) do
    case Jason.decode(data) do
      {:ok, json} ->
        parse_sweep_result(json)

      {:error, _} ->
        Logger.debug("Failed to parse sweep message as JSON")
        nil
    end
  end

  # Private functions

  defp parse_sweep_result(json) do
    last_sweep_time = parse_timestamp(json["last_sweep_time"] || json["lastSweepTime"])

    %{
      host_ip: json["host_ip"] || json["hostIp"] || json["ip"],
      poller_id: json["poller_id"] || json["pollerId"] || "unknown",
      agent_id: json["agent_id"] || json["agentId"] || "unknown",
      partition: json["partition"] || "default",
      network_cidr: json["network_cidr"] || json["networkCidr"],
      hostname: json["hostname"],
      mac: json["mac"],
      icmp_available: json["icmp_available"] || json["icmpAvailable"],
      icmp_response_time_ns: json["icmp_response_time_ns"] || json["icmpResponseTimeNs"],
      icmp_packet_loss: json["icmp_packet_loss"] || json["icmpPacketLoss"],
      tcp_ports_scanned: encode_jsonb(json["tcp_ports_scanned"] || json["tcpPortsScanned"]),
      tcp_ports_open: encode_jsonb(json["tcp_ports_open"] || json["tcpPortsOpen"]),
      port_scan_results: encode_jsonb(json["port_scan_results"] || json["portScanResults"]),
      last_sweep_time: last_sweep_time,
      first_seen: parse_timestamp(json["first_seen"] || json["firstSeen"]),
      metadata: encode_jsonb(json["metadata"]),
      created_at: DateTime.utc_now()
    }
  end

  defp parse_timestamp(nil), do: DateTime.utc_now()
  defp parse_timestamp(ts) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _} -> dt
      _ -> DateTime.utc_now()
    end
  end
  defp parse_timestamp(ts) when is_integer(ts) do
    if ts > 1_000_000_000_000 do
      DateTime.from_unix!(ts, :millisecond)
    else
      DateTime.from_unix!(ts, :second)
    end
  end
  defp parse_timestamp(_), do: DateTime.utc_now()

  defp encode_jsonb(nil), do: nil
  defp encode_jsonb(value) when is_map(value) or is_list(value), do: value
  defp encode_jsonb(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} -> decoded
      _ -> nil
    end
  end
  defp encode_jsonb(_), do: nil
end
