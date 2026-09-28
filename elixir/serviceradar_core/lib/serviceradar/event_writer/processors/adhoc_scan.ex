defmodule ServiceRadar.EventWriter.Processors.AdhocScan do
  @moduledoc """
  Processor for ad-hoc network scan results on the `scans.results.>` stream.

  Ad-hoc scans (`scan.run_adhoc`) return ICMP/TCP/MTR results over the agent
  command channel; core republishes each result row onto JetStream (so results
  traverse JetStream before the DB, per the metrics-through-JetStream rule) and
  this processor persists them:

    * every row -> `platform.adhoc_scan_results` (keyed by `scan_run_id`)
    * MTR rows that carry a full trace -> `mtr_traces`/`mtr_hops`, through the
      same MTR persistence the `Mtr` processor uses
      (`ServiceRadar.EventWriter.Processors.Mtr.persist_all/2`): the warehouse
      when StarRocks is enabled, CNPG otherwise

  Ids are derived from the message bytes, so a redelivered batch writes the
  rows it already wrote under the same keys: `adhoc_scan_results` ignores the
  conflict, CNPG skips a stored trace and the warehouse upserts it. That is
  what lets an MTR trace that could not be stored fail the batch, so JetStream
  redelivers it, as it would on the `mtr.results.>` stream. A trace that can
  never be stored (no target) is logged and dropped.

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
  alias ServiceRadar.EventWriter.Processors.Mtr
  alias ServiceRadar.Observability.MtrMetricsIngestor

  require Logger

  @impl true
  def table_name, do: "adhoc_scan_results"

  @impl true
  def process_batch(messages), do: process_batch(messages, [])

  @doc false
  # `:insert` replaces the `adhoc_scan_results` insert; every other option is
  # passed to `Mtr.persist_all/2` (tests).
  def process_batch(messages, opts) do
    insert = Keyword.get(opts, :insert, &BulkInsert.insert_all/3)

    decoded =
      messages
      |> Enum.map(&decode_message/1)
      |> Enum.reject(&is_nil/1)

    rows = Enum.map(decoded, &build_row/1)

    {count, _} = insert.(table_name(), rows, on_conflict: :nothing)

    case decoded |> mtr_results() |> Mtr.persist_all(opts) do
      :ok ->
        {:ok, count}

      {:error, reason} = error ->
        Logger.warning("Ad-hoc MTR trace persist failed: #{inspect(reason)}")
        error
    end
  rescue
    e ->
      Logger.error("Ad-hoc scan batch processing failed: #{inspect(e)}")
      {:error, e}
  end

  @impl true
  def parse_message(message), do: decode_message(message)

  defp decode_message(%{data: data}) when is_binary(data) do
    case Jason.decode(data) do
      {:ok, json} when is_map(json) ->
        Map.put(json, "__message_uuid", MtrMetricsIngestor.stable_uuid(data))

      _ ->
        Logger.debug("Failed to parse ad-hoc scan message as JSON")
        nil
    end
  end

  defp decode_message(_), do: nil

  defp build_row(json) do
    %{
      id: Ecto.UUID.dump!(json["__message_uuid"]),
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

  # MTR rows carry the full trace, stored as one MTR result in the shape the
  # `Mtr` processor persists. This runs inside the EventWriter consumer, so the
  # trace has already traversed JetStream.
  defp mtr_results(decoded) do
    for json <- decoded,
        to_string(json["mode"] || "") == "mtr",
        is_map(json["trace"]) do
      %{
        payload: mtr_result(json),
        status: %{
          agent_id: json["agent_id"],
          gateway_id: json["gateway_id"],
          partition: json["partition"]
        }
      }
    end
  end

  # The trace id is derived from the message, so a redelivery stores the same
  # trace. The scan row's time stands in for a trace that carries no timestamp
  # of its own, in nanoseconds: the ingestor reads any integer above 10^15 as
  # nanoseconds, so a present-day time in milliseconds or microseconds would
  # land in 1970.
  defp mtr_result(json) do
    result = %{
      "trace" => json["trace"],
      "target" => json["target_ip"],
      "trace_uuid" => MtrMetricsIngestor.stable_uuid("mtr:" <> json["__message_uuid"])
    }

    case json["timestamp_ms"] do
      ms when is_integer(ms) and ms > 0 -> Map.put(result, "timestamp", ms * 1_000_000)
      _ -> result
    end
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
