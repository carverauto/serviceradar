defmodule ServiceRadar.EventWriter.Processors.Events do
  @moduledoc """
  Processor for CloudEvents messages.

  Parses CloudEvents from NATS JetStream and inserts them into
  the `events` hypertable.

  ## Message Format

  Expects CloudEvents format with optional GELF compatibility:

  - CloudEvents: Standard CE envelope with data payload
  - GELF: Graylog Extended Log Format (syslog-style)

  ## Table Schema

  ```sql
  CREATE TABLE events (
    event_timestamp TIMESTAMPTZ NOT NULL,
    specversion TEXT,
    id TEXT NOT NULL,
    source TEXT,
    type TEXT,
    datacontenttype TEXT,
    subject TEXT,
    remote_addr TEXT,
    host TEXT,
    level INTEGER,
    severity TEXT,
    short_message TEXT,
    version TEXT,
    raw_data TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (event_timestamp, id)
  );
  ```
  """

  @behaviour ServiceRadar.EventWriter.Processor

  require Logger

  @impl true
  def table_name, do: "events"

  @impl true
  def process_batch(messages) do
    rows =
      messages
      |> Enum.map(&parse_message/1)
      |> Enum.reject(&is_nil/1)

    if Enum.empty?(rows) do
      {:ok, 0}
    else
      # Use ON CONFLICT DO UPDATE for events (upsert)
      case ServiceRadar.Repo.insert_all(table_name(), rows,
             on_conflict: {:replace, [:short_message, :level, :severity]},
             conflict_target: [:event_timestamp, :id],
             returning: false
           ) do
        {count, _} ->
          {:ok, count}
      end
    end
  rescue
    e ->
      Logger.error("Events batch insert failed: #{inspect(e)}")
      {:error, e}
  end

  @impl true
  def parse_message(%{data: data, metadata: _metadata}) do
    case Jason.decode(data) do
      {:ok, json} ->
        parse_cloud_event(json)

      {:error, _} ->
        Logger.debug("Failed to parse event as JSON")
        nil
    end
  end

  # Private functions

  defp parse_cloud_event(json) do
    # Handle both CloudEvents and GELF formats
    timestamp = parse_timestamp(json)
    event_id = json["id"] || generate_id()

    %{
      event_timestamp: timestamp,
      specversion: json["specversion"],
      id: event_id,
      source: json["source"],
      type: json["type"],
      datacontenttype: json["datacontenttype"],
      subject: json["subject"],
      remote_addr: extract_remote_addr(json),
      host: json["host"],
      level: parse_level(json),
      severity: parse_severity(json),
      short_message: extract_short_message(json),
      version: json["version"],
      raw_data: nil,  # Removed raw_data storage to save space
      created_at: DateTime.utc_now()
    }
  end

  defp parse_timestamp(json) do
    # Try CloudEvents timestamp first, then GELF timestamp
    ts = json["time"] || json["timestamp"]

    case ts do
      nil ->
        DateTime.utc_now()

      ts when is_binary(ts) ->
        case DateTime.from_iso8601(ts) do
          {:ok, dt, _} -> dt
          _ -> DateTime.utc_now()
        end

      ts when is_number(ts) ->
        # GELF uses Unix timestamp with optional decimal for microseconds
        {seconds, microseconds} = split_timestamp(ts)
        DateTime.from_unix!(seconds, :second) |> DateTime.add(microseconds, :microsecond)

      _ ->
        DateTime.utc_now()
    end
  end

  defp split_timestamp(ts) when is_float(ts) do
    seconds = trunc(ts)
    microseconds = trunc((ts - seconds) * 1_000_000)
    {seconds, microseconds}
  end
  defp split_timestamp(ts) when is_integer(ts), do: {ts, 0}

  defp parse_level(json) do
    level = json["level"]

    cond do
      is_integer(level) -> level
      is_binary(level) -> level_string_to_int(level)
      true -> nil
    end
  end

  defp level_string_to_int("emergency"), do: 0
  defp level_string_to_int("alert"), do: 1
  defp level_string_to_int("critical"), do: 2
  defp level_string_to_int("error"), do: 3
  defp level_string_to_int("warning"), do: 4
  defp level_string_to_int("notice"), do: 5
  defp level_string_to_int("info"), do: 6
  defp level_string_to_int("debug"), do: 7
  defp level_string_to_int(_), do: nil

  defp parse_severity(json) do
    json["severity"] || level_to_severity(json["level"])
  end

  defp level_to_severity(0), do: "emergency"
  defp level_to_severity(1), do: "alert"
  defp level_to_severity(2), do: "critical"
  defp level_to_severity(3), do: "error"
  defp level_to_severity(4), do: "warning"
  defp level_to_severity(5), do: "notice"
  defp level_to_severity(6), do: "info"
  defp level_to_severity(7), do: "debug"
  defp level_to_severity(_), do: nil

  defp extract_short_message(json) do
    # Try various message fields
    json["short_message"] || json["message"] || json["msg"] ||
      extract_from_data(json["data"])
  end

  defp extract_from_data(nil), do: nil
  defp extract_from_data(data) when is_map(data) do
    data["message"] || data["msg"] || data["short_message"]
  end
  defp extract_from_data(data) when is_binary(data), do: data
  defp extract_from_data(_), do: nil

  defp extract_remote_addr(json) do
    json["remote_addr"] || json["remoteAddr"] || json["_remote_addr"]
  end

  defp generate_id do
    UUID.uuid4()
  end
end
