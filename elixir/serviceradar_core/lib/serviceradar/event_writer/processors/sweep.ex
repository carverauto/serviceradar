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

  alias ServiceRadar.EventWriter.FieldParser

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
    last_sweep_time = FieldParser.parse_timestamp(FieldParser.get_field(json, "last_sweep_time", "lastSweepTime"))

    %{
      host_ip: FieldParser.get_field(json, "host_ip", "hostIp") || json["ip"],
      poller_id: FieldParser.get_field(json, "poller_id", "pollerId", "unknown"),
      agent_id: FieldParser.get_field(json, "agent_id", "agentId", "unknown"),
      partition: json["partition"] || "default",
      network_cidr: FieldParser.get_field(json, "network_cidr", "networkCidr"),
      hostname: json["hostname"],
      mac: json["mac"],
      icmp_available: FieldParser.get_field(json, "icmp_available", "icmpAvailable"),
      icmp_response_time_ns: FieldParser.get_field(json, "icmp_response_time_ns", "icmpResponseTimeNs"),
      icmp_packet_loss: FieldParser.get_field(json, "icmp_packet_loss", "icmpPacketLoss"),
      tcp_ports_scanned: FieldParser.encode_jsonb(FieldParser.get_field(json, "tcp_ports_scanned", "tcpPortsScanned")),
      tcp_ports_open: FieldParser.encode_jsonb(FieldParser.get_field(json, "tcp_ports_open", "tcpPortsOpen")),
      port_scan_results: FieldParser.encode_jsonb(FieldParser.get_field(json, "port_scan_results", "portScanResults")),
      last_sweep_time: last_sweep_time,
      first_seen: FieldParser.parse_timestamp(FieldParser.get_field(json, "first_seen", "firstSeen")),
      metadata: FieldParser.encode_jsonb(json["metadata"]),
      created_at: DateTime.utc_now()
    }
  end
end
