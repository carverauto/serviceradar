defmodule ServiceRadar.EventWriter.Processors.Telemetry do
  @moduledoc """
  Processor for telemetry metrics messages.

  Parses telemetry metrics from NATS JetStream and inserts them into
  the `timeseries_metrics` hypertable.

  ## Message Format

  Canonical protobuf metric batches:

  Non-OTLP metric producers publish `serviceradar.metric.v1` payloads on
  `metrics.*`. OTLP metrics stay on the OTLP processor.

  ## Table Schema

  ```sql
  CREATE TABLE timeseries_metrics (
    timestamp TIMESTAMPTZ NOT NULL,
    gateway_id TEXT NOT NULL,
    agent_id TEXT,
    metric_name TEXT NOT NULL,
    metric_type TEXT NOT NULL,
    series_key TEXT NOT NULL,
    device_id TEXT,
    value DOUBLE PRECISION NOT NULL,
    unit TEXT,
    tags JSONB,
    partition TEXT,
    scale DOUBLE PRECISION,
    is_delta BOOLEAN DEFAULT FALSE,
    counter_width INTEGER,
    target_device_ip TEXT,
    if_index INTEGER,
    metadata JSONB,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
  );
  ```
  """

  @behaviour ServiceRadar.EventWriter.Processor

  alias ServiceRadar.EventWriter.BulkInsert
  alias ServiceRadar.Observability.MetricEnvelope

  require Logger

  @impl true
  def table_name, do: "timeseries_metrics"

  @impl true
  def process_batch(messages) do
    # DB connection's search_path determines the schema
    rows = build_rows(messages)

    insert_rows(rows)
  rescue
    e ->
      Logger.error("Telemetry batch insert failed: #{inspect(e)}")
      {:error, e}
  end

  @impl true
  def parse_message(%{data: data, metadata: _metadata}) do
    case MetricEnvelope.decode_rows(data) do
      {:ok, rows} ->
        rows

      {:error, reason} ->
        Logger.debug("Failed to parse telemetry protobuf envelope", reason: inspect(reason))
        nil
    end
  end

  # Private functions

  @spec insert_rows([map()]) :: {:ok, non_neg_integer()}
  def insert_rows(rows) when is_list(rows) do
    if Enum.empty?(rows) do
      {:ok, 0}
    else
      insert_telemetry_rows(rows)
    end
  end

  defp build_rows(messages) do
    messages
    |> Enum.reduce([], fn message, rows ->
      case parse_message(message) do
        decoded_rows when is_list(decoded_rows) ->
          Enum.reverse(decoded_rows, rows)

        _ ->
          rows
      end
    end)
    |> Enum.reverse()
  end

  defp insert_telemetry_rows(rows) do
    # DB connection's search_path determines the schema
    {count, _} =
      BulkInsert.insert_all(
        table_name(),
        rows,
        on_conflict: :nothing,
        returning: false
      )

    {:ok, count}
  end
end
