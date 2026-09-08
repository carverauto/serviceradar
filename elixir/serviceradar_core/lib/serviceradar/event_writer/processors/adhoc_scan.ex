defmodule ServiceRadar.EventWriter.Processors.AdhocScan do
  @moduledoc """
  Processor for ad-hoc network scan results on the `scans.results.>` stream.

  Ad-hoc scans (`scan.run_adhoc`) return ICMP/TCP/MTR results over the agent
  command channel; core republishes each result row onto JetStream (so results
  traverse JetStream before the DB, per the metrics-through-JetStream rule) and
  this processor persists them:

    * every row -> `platform.adhoc_scan_results` (keyed by `scan_run_id`)
    * MTR rows that carry a full trace -> `mtr_traces`/`mtr_hops` via the
      existing `MtrMetricsIngestor` (reached here already past JetStream)

  ## Message format (JSON)

      {
        "scan_run_id": "uuid",
        "agent_id": "agent-1",
        "gateway_id": "gateway-1",
        "partition": "default",
        "target_ip": "192.168.1.10",
        "mode": "icmp" | "tcp" | "mtr",
        "port": 443,
        "available": true,
        "response_ms": 1.2,
        "service": "https",
        "timestamp_ms": 1737460000000,
        "trace": { ... }   // mtr rows only
      }
  """

  @behaviour ServiceRadar.EventWriter.Processor

  alias ServiceRadar.EventWriter.BulkInsert
  alias ServiceRadar.Observability.MtrMetricsIngestor

  require Logger

  @impl true
  def table_name, do: "adhoc_scan_results"

  @impl true
  def process_batch(messages) do
    decoded =
      messages
      |> Enum.map(&decode_message/1)
      |> Enum.reject(&is_nil/1)

    rows = Enum.map(decoded, &build_row/1)

    {count, _} = BulkInsert.insert_all(table_name(), rows, on_conflict: :nothing)
    result = {:ok, count}
    ingest_mtr_traces(decoded)

    result
  rescue
    e ->
      Logger.error("Ad-hoc scan batch processing failed: #{inspect(e)}")
      {:error, e}
  end

  @impl true
  def parse_message(message), do: decode_message(message)

  defp decode_message(%{data: data}) do
    case Jason.decode(data) do
      {:ok, json} when is_map(json) ->
        json

      _ ->
        Logger.debug("Failed to parse ad-hoc scan message as JSON")
        nil
    end
  end

  defp decode_message(_), do: nil

  defp build_row(json) do
    %{
      id: Ecto.UUID.bingenerate(),
      time: parse_time(json["timestamp_ms"]),
      scan_run_id: dump_uuid(json["scan_run_id"]),
      agent_id: to_string(json["agent_id"] || ""),
      gateway_id: nilable_string(json["gateway_id"]),
      partition: nilable_string(json["partition"]),
      target_ip: to_string(json["target_ip"] || json["target"] || ""),
      mode: to_string(json["mode"] || ""),
      port: nilable_int(json["port"]),
      available: json["available"] == true,
      response_ms: nilable_float(json["response_ms"]),
      service: nilable_string(json["service"])
    }
  end

  # MTR rows carry the full trace; persist per-hop detail to mtr_traces/mtr_hops
  # by reusing the existing ingestor. This runs inside the EventWriter consumer,
  # so the trace has already traversed JetStream.
  defp ingest_mtr_traces(decoded) do
    Enum.each(decoded, fn json ->
      with "mtr" <- to_string(json["mode"] || ""),
           trace when is_map(trace) <- json["trace"] do
        status = %{
          agent_id: json["agent_id"],
          gateway_id: json["gateway_id"],
          partition: json["partition"]
        }

        case MtrMetricsIngestor.ingest(%{"trace" => trace, "target" => json["target_ip"]}, status) do
          :ok -> :ok
          {:error, reason} -> Logger.warning("Ad-hoc MTR trace ingest failed: #{inspect(reason)}")
        end
      else
        _ -> :ok
      end
    end)
  end

  defp parse_time(ms) when is_integer(ms), do: DateTime.from_unix!(ms, :millisecond)
  defp parse_time(_), do: DateTime.utc_now()

  defp dump_uuid(value) when is_binary(value) do
    case Ecto.UUID.dump(value) do
      {:ok, bin} -> bin
      :error -> nil
    end
  end

  defp dump_uuid(_), do: nil

  defp nilable_string(nil), do: nil
  defp nilable_string(""), do: nil
  defp nilable_string(value), do: to_string(value)

  defp nilable_int(value) when is_integer(value) and value > 0, do: value
  defp nilable_int(_), do: nil

  defp nilable_float(value) when is_number(value), do: value / 1.0
  defp nilable_float(_), do: nil
end
