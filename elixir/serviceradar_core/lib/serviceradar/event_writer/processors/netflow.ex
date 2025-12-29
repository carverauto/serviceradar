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
    timestamp = parse_timestamp(json["timestamp"])

    %{
      timestamp: timestamp,
      poller_id: json["poller_id"] || json["pollerId"],
      agent_id: json["agent_id"] || json["agentId"],
      device_id: json["device_id"] || json["deviceId"],
      flow_direction: json["flow_direction"] || json["flowDirection"],
      src_addr: json["src_addr"] || json["srcAddr"] || json["sourceAddress"],
      dst_addr: json["dst_addr"] || json["dstAddr"] || json["destinationAddress"],
      src_port: json["src_port"] || json["srcPort"] || json["sourcePort"],
      dst_port: json["dst_port"] || json["dstPort"] || json["destinationPort"],
      protocol: json["protocol"],
      packets: json["packets"],
      octets: json["octets"] || json["bytes"],
      sampler_address: json["sampler_address"] || json["samplerAddress"],
      input_snmp: json["input_snmp"] || json["inputSnmp"],
      output_snmp: json["output_snmp"] || json["outputSnmp"],
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
  defp encode_jsonb(value) when is_map(value), do: value
  defp encode_jsonb(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} -> decoded
      _ -> nil
    end
  end
  defp encode_jsonb(_), do: nil
end
