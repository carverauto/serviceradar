defmodule ServiceRadar.EventWriter.Processors.NetFlow do
  @moduledoc """
  Processor for NetFlow/IPFIX metrics messages.

  Parses NetFlow data from NATS JetStream and inserts them into
  the `netflow_metrics` hypertable.

  ## Message Format

  JSON NetFlow messages:

  ```json
  {
    "timestamp": "2024-01-01T00:00:00Z",
    "poller_id": "poller-1",
    "agent_id": "agent-1",
    "device_id": "router-1",
    "flow_direction": "ingress",
    "src_addr": "192.168.1.100",
    "dst_addr": "10.0.0.1",
    "src_port": 45678,
    "dst_port": 443,
    "protocol": 6,
    "packets": 100,
    "octets": 150000
  }
  ```

  ## Table Schema

  ```sql
  CREATE TABLE netflow_metrics (
    timestamp TIMESTAMPTZ NOT NULL,
    poller_id TEXT,
    agent_id TEXT,
    device_id TEXT,
    flow_direction TEXT,
    src_addr TEXT,
    dst_addr TEXT,
    src_port INTEGER,
    dst_port INTEGER,
    protocol INTEGER,
    packets BIGINT,
    octets BIGINT,
    sampler_address TEXT,
    input_snmp INTEGER,
    output_snmp INTEGER,
    metadata JSONB,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
  );
  ```
  """

  @behaviour ServiceRadar.EventWriter.Processor

  alias ServiceRadar.EventWriter.FieldParser

  require Logger

  @impl true
  def table_name, do: "netflow_metrics"

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
      Logger.error("NetFlow batch insert failed: #{inspect(e)}")
      {:error, e}
  end

  @impl true
  def parse_message(%{data: data, metadata: _metadata}) do
    case Jason.decode(data) do
      {:ok, json} ->
        parse_netflow(json)

      {:error, _} ->
        Logger.debug("Failed to parse netflow message as JSON")
        nil
    end
  end

  # Private functions

  defp parse_netflow(json) do
    timestamp = FieldParser.parse_timestamp(json["timestamp"])

    %{
      timestamp: timestamp,
      poller_id: FieldParser.get_field(json, "poller_id", "pollerId"),
      agent_id: FieldParser.get_field(json, "agent_id", "agentId"),
      device_id: FieldParser.get_field(json, "device_id", "deviceId"),
      flow_direction: FieldParser.get_field(json, "flow_direction", "flowDirection"),
      src_addr: FieldParser.get_field(json, "src_addr", "srcAddr") || json["sourceAddress"],
      dst_addr: FieldParser.get_field(json, "dst_addr", "dstAddr") || json["destinationAddress"],
      src_port: FieldParser.get_field(json, "src_port", "srcPort") || json["sourcePort"],
      dst_port: FieldParser.get_field(json, "dst_port", "dstPort") || json["destinationPort"],
      protocol: json["protocol"],
      packets: json["packets"],
      octets: json["octets"] || json["bytes"],
      sampler_address: FieldParser.get_field(json, "sampler_address", "samplerAddress"),
      input_snmp: FieldParser.get_field(json, "input_snmp", "inputSnmp"),
      output_snmp: FieldParser.get_field(json, "output_snmp", "outputSnmp"),
      metadata: FieldParser.encode_jsonb(json["metadata"]),
      created_at: DateTime.utc_now()
    }
  end
end
