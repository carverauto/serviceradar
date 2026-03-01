defmodule ServiceRadar.EventWriter.Processors.Events do
  @moduledoc """
  Processor for OCSF Event Log Activity payloads.

  Parses JSON events from NATS and inserts them into the `ocsf_events`
  hypertable using the OCSF Event Log Activity schema (class_uid: 1008).
  """

  @behaviour ServiceRadar.EventWriter.Processor

  alias ServiceRadar.Events.PubSub, as: EventsPubSub
  alias ServiceRadar.EventWriter.FieldParser
  alias ServiceRadar.Observability.StatefulAlertEngine

  require Logger

  @impl true
  def table_name, do: "ocsf_events"

  @impl true
  def process_batch(messages) do
    # DB connection's search_path determines the schema
    rows = build_rows(messages)

    if Enum.empty?(rows) do
      {:ok, 0}
    else
      insert_event_rows(rows)
    end
  rescue
    e ->
      Logger.error("OCSF events batch insert failed: #{inspect(e)}")
      {:error, e}
  end

  @impl true
  def parse_message(%{data: data, metadata: metadata}) do
    # DB connection's search_path determines the schema
    case Jason.decode(data) do
      {:ok, json} ->
        parse_event(json, metadata, data)

      {:error, _} ->
        Logger.debug("Failed to parse events message as JSON")
        nil
    end
  end

  # Private functions

  defp build_rows(messages) do
    messages
    |> Enum.map(&parse_message/1)
    |> Enum.reject(&is_nil/1)
  end

  defp insert_event_rows(rows) do
    # DB connection's search_path determines the schema
    case ServiceRadar.Repo.insert_all(
           table_name(),
           rows,
           on_conflict: :nothing,
           returning: false
         ) do
      {count, _} ->
        maybe_evaluate_stateful_rules(rows)
        EventsPubSub.broadcast_event(%{count: count})
        {:ok, count}
    end
  end

  # DB connection's search_path determines the schema
  defp parse_event(json, metadata, raw_data) when is_map(json) do
    case required_event_fields(json) do
      {:ok,
       %{
         id: id,
         class_uid: class_uid,
         category_uid: category_uid,
         type_uid: type_uid,
         activity_id: activity_id
       }} ->
        severity_id = parse_int(json["severity_id"]) || 1
        severity = parse_string(json["severity"]) || severity_name(severity_id)

        %{
          id: Ecto.UUID.dump!(id),
          time: FieldParser.parse_timestamp(json["time"]),
          class_uid: class_uid,
          category_uid: category_uid,
          type_uid: type_uid,
          activity_id: activity_id,
          activity_name: parse_string(json["activity_name"]),
          severity_id: severity_id,
          severity: severity,
          message: parse_string(json["message"]),
          status_id: parse_int(json["status_id"]),
          status: parse_string(json["status"]),
          status_code: parse_string(json["status_code"]),
          status_detail: parse_string(json["status_detail"]),
          metadata: jsonb_or_empty_map(json["metadata"]),
          observables: jsonb_or_empty_list(json["observables"]),
          trace_id: FieldParser.get_field(json, "trace_id", "traceId"),
          span_id: FieldParser.get_field(json, "span_id", "spanId"),
          actor: jsonb_or_empty_map(json["actor"]),
          device: jsonb_or_empty_map(json["device"]),
          src_endpoint: jsonb_or_empty_map(json["src_endpoint"]),
          dst_endpoint: jsonb_or_empty_map(json["dst_endpoint"]),
          log_name: parse_string_or(json["log_name"], metadata[:subject]),
          log_provider: parse_string(json["log_provider"]),
          log_level: parse_string(json["log_level"]),
          log_version: parse_string(json["log_version"]),
          unmapped: jsonb_or_empty_map(json["unmapped"]),
          raw_data: parse_string_or(json["raw_data"], raw_data),
          created_at: DateTime.utc_now()
        }

      {:error, reason} ->
        Logger.debug("Invalid OCSF event payload: #{inspect(reason)}",
          subject: metadata[:subject]
        )

        nil
    end
  end

  defp parse_event(_json, _metadata, _raw_data), do: nil

  defp required_event_fields(json) do
    with {:ok, id} <- fetch_required_string(json, "id"),
         {:ok, class_uid} <- fetch_required_int(json, "class_uid"),
         {:ok, category_uid} <- fetch_required_int(json, "category_uid"),
         {:ok, type_uid} <- fetch_required_int(json, "type_uid"),
         {:ok, activity_id} <- fetch_required_int(json, "activity_id") do
      {:ok,
       %{
         id: id,
         class_uid: class_uid,
         category_uid: category_uid,
         type_uid: type_uid,
         activity_id: activity_id
       }}
    end
  end

  defp jsonb_or_empty_map(value), do: FieldParser.encode_jsonb(value) || %{}
  defp jsonb_or_empty_list(value), do: FieldParser.encode_jsonb(value) || []
  defp parse_string_or(value, fallback), do: parse_string(value) || fallback

  defp fetch_required_string(json, key) do
    case parse_string(json[key]) do
      nil -> {:error, {:missing, key}}
      "" -> {:error, {:missing, key}}
      value -> {:ok, value}
    end
  end

  defp fetch_required_int(json, key) do
    case parse_int(json[key]) do
      nil -> {:error, {:missing, key}}
      0 -> {:error, {:missing, key}}
      value -> {:ok, value}
    end
  end

  defp parse_int(nil), do: nil
  defp parse_int(value) when is_integer(value), do: value
  defp parse_int(value) when is_float(value), do: trunc(value)

  defp parse_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} -> int
      :error -> nil
    end
  end

  defp parse_int(_), do: nil

  defp parse_string(value) when is_binary(value), do: value
  defp parse_string(_), do: nil

  defp severity_name(0), do: "Unknown"
  defp severity_name(1), do: "Informational"
  defp severity_name(2), do: "Low"
  defp severity_name(3), do: "Medium"
  defp severity_name(4), do: "High"
  defp severity_name(5), do: "Critical"
  defp severity_name(6), do: "Fatal"
  defp severity_name(_), do: "Unknown"

  defp maybe_evaluate_stateful_rules([]), do: :ok

  defp maybe_evaluate_stateful_rules(rows) do
    case StatefulAlertEngine.evaluate_events(rows) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Stateful alert evaluation failed: #{inspect(reason)}")
        :ok
    end
  end
end
