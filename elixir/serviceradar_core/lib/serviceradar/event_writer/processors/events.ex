defmodule ServiceRadar.EventWriter.Processors.Events do
  @moduledoc """
  Processor for OCSF Event Log Activity payloads.

  Parses JSON events from NATS and inserts them into the `ocsf_events`
  hypertable using the OCSF Event Log Activity schema (class_uid: 1008).
  """

  @behaviour ServiceRadar.EventWriter.Processor

  alias ServiceRadar.Events.PubSub, as: EventsPubSub
  alias ServiceRadar.EventWriter.BulkInsert
  alias ServiceRadar.EventWriter.FieldParser
  alias ServiceRadar.EventWriter.PluginDeviceAttribution
  alias ServiceRadar.EventWriter.StableId
  alias ServiceRadar.Observability.StatefulEvaluationLedger

  require Logger

  @first_statement_error_key {__MODULE__, :first_statement_error}
  @repo_query_event [:service_radar, :repo, :query]

  @impl true
  def table_name, do: "ocsf_events"

  @impl true
  def process_batch(messages) do
    with_statement_error_tracking(fn ->
      # DB connection's search_path determines the schema
      rows = build_rows(messages)

      if Enum.empty?(rows) do
        {:ok, 0}
      else
        insert_event_rows(rows)
      end
    end)
  end

  @doc false
  def handle_repo_query_telemetry(
        _event,
        _measurements,
        %{result: {:error, error}} = metadata,
        owner
      ) do
    if self() == owner do
      record_statement_error(error, metadata[:query])
    end

    :ok
  end

  def handle_repo_query_telemetry(_event, _measurements, _metadata, _owner), do: :ok

  @impl true
  def parse_message(%{data: data, metadata: metadata}) do
    # DB connection's search_path determines the schema
    case Jason.decode(data) do
      {:ok, json} ->
        if metric_payload?(json) do
          reject_metric_on_events_stream(json)
        else
          parse_event(json, metadata, data)
        end

      {:error, _} ->
        Logger.debug("Failed to parse events message as JSON")
        nil
    end
  end

  # REC9b (fj #3788): metric time-series must never land on the OCSF events stream.
  # A metric point carries `temporality`/`points[]` or a `serviceradar.metric.*`
  # schema, none of which a security/activity event has. Reject it loudly rather
  # than coercing it into an OCSF event row.
  defp metric_payload?(json) when is_map(json) do
    String.starts_with?(to_string(Map.get(json, "schema", "")), "serviceradar.metric") or
      Map.has_key?(json, "temporality") or Map.has_key?(json, "points")
  end

  defp metric_payload?(_json), do: false

  defp reject_metric_on_events_stream(json) do
    :telemetry.execute(
      [:serviceradar, :event_writer, :events, :misbucketed],
      %{count: 1},
      %{reason: :metric_on_events_stream}
    )

    Logger.warning("Rejected mis-bucketed metric payload on the OCSF events stream",
      schema: Map.get(json, "schema")
    )

    nil
  end

  @doc """
  Parses a message batch into insert-ready rows.

  A plugin event whose `device.uid` is the plugin's own device reference
  (`<source>:<...>`) gets the canonical device uid there, resolved once for the
  whole batch by `PluginDeviceAttribution`; an unresolved reference is stored as
  emitted.
  """
  @spec build_rows(map() | [map()]) :: [map()]
  def build_rows(messages) when is_map(messages) do
    messages
    |> Map.values()
    |> build_rows()
  end

  def build_rows(messages) do
    messages
    |> Enum.map(&parse_message/1)
    |> Enum.reject(&is_nil/1)
    |> PluginDeviceAttribution.attribute_event_rows()
    |> dedupe_event_rows()
  end

  @doc false
  @spec dedupe_event_rows(map() | [map()]) :: [map()]
  def dedupe_event_rows(rows) when is_map(rows) do
    rows
    |> Map.values()
    |> dedupe_event_rows()
  end

  def dedupe_event_rows(rows) when is_list(rows) do
    rows
    |> Enum.reduce(%{}, fn row, acc ->
      Map.put(acc, event_conflict_key(row), row)
    end)
    |> Map.values()
    |> Enum.sort_by(&event_conflict_key/1)
  end

  # Private functions

  defp insert_event_rows(rows) do
    rows = dedupe_event_rows(rows)

    # DB connection's search_path determines the schema
    {count, _} =
      BulkInsert.insert_all(
        table_name(),
        rows,
        on_conflict: :nothing,
        returning: false
      )

    if count > 0 do
      EventsPubSub.broadcast_event(%{count: count})
      EventsPubSub.broadcast_event_rows(rows)
    end

    # Stateful evaluation runs once per event (the ledger), synchronously, and
    # a failure fails the batch so JetStream redelivers it. The insert and the
    # warehouse load are idempotent on the event id, so the redelivery repeats
    # only what did not finish.
    with {:ok, _} <-
           ServiceRadar.Analytics.StarRocks.Destination.persist_after_cnpg(:events, rows),
         :ok <- StatefulEvaluationLedger.evaluate_once(rows) do
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
          id: coerce_event_id(id),
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
          # An absent key means the producer left the field to EventWriter; an
          # explicit null (core's publisher sends every field) is stored as null.
          log_name: default_when_absent(json, "log_name", metadata[:subject]),
          log_provider: parse_string(json["log_provider"]),
          log_level: parse_string(json["log_level"]),
          log_version: parse_string(json["log_version"]),
          unmapped: jsonb_or_empty_map(json["unmapped"]),
          raw_data: default_when_absent(json, "raw_data", raw_data),
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

  # An OCSF event `id` is stored in a `uuid` column, but not every producer emits
  # a UUID — e.g. a plugin that emits `"plugin-<nanos>-<n>"`. `Ecto.UUID.dump!/1`
  # RAISES on such a value, and because `process_batch/1` rescues and fails the
  # ENTIRE batch, one malformed id dead-letters every event batched with it
  # (including valid device-discovery events). Coerce a non-UUID id into a stable
  # v5-style UUID derived from the id string so the event is preserved and
  # de-duplication stays deterministic, instead of losing the whole batch.
  defp coerce_event_id(id) do
    case Ecto.UUID.dump(id) do
      {:ok, dumped} -> dumped
      :error -> StableId.uuid(to_string(id))
    end
  end

  defp jsonb_or_empty_map(value), do: FieldParser.encode_jsonb(value) || %{}
  defp jsonb_or_empty_list(value), do: FieldParser.encode_jsonb(value) || []

  defp default_when_absent(json, key, default) do
    if Map.has_key?(json, key), do: parse_string(json[key]), else: default
  end

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

  defp event_conflict_key(%{id: id, time: time}),
    do: {time_conflict_value(time), uuid_conflict_value(id)}

  defp event_conflict_key(%{"id" => id, "time" => time}),
    do: {time_conflict_value(time), uuid_conflict_value(id)}

  defp event_conflict_key(_row), do: nil

  defp uuid_conflict_value(<<_::128>> = id) do
    case Ecto.UUID.load(id) do
      {:ok, uuid} -> uuid
      :error -> id
    end
  end

  defp uuid_conflict_value(id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> uuid
      :error -> id
    end
  end

  defp uuid_conflict_value(id), do: id

  defp time_conflict_value(%DateTime{} = time), do: DateTime.to_unix(time, :microsecond)

  defp time_conflict_value(%NaiveDateTime{} = time) do
    time
    |> DateTime.from_naive!("Etc/UTC")
    |> DateTime.to_unix(:microsecond)
  end

  defp time_conflict_value(time), do: time

  defp with_statement_error_tracking(fun) when is_function(fun, 0) do
    owner = self()
    handler_id = {__MODULE__, :statement_error_tracker, make_ref()}
    Process.delete(@first_statement_error_key)

    :telemetry.attach(
      handler_id,
      @repo_query_event,
      &__MODULE__.handle_repo_query_telemetry/4,
      owner
    )

    try do
      fun.()
    rescue
      e ->
        root_error = resolve_logged_error(e)
        log_batch_insert_failure(root_error)
        {:error, root_error}
    after
      :telemetry.detach(handler_id)
      Process.delete(@first_statement_error_key)
    end
  end

  defp record_statement_error(error, query) do
    if not in_failed_sql_transaction?(error) and is_nil(Process.get(@first_statement_error_key)) do
      Process.put(@first_statement_error_key, attach_query(error, query))
    end

    :ok
  end

  defp attach_query(%Postgrex.Error{query: nil} = error, query)
       when is_binary(query) and query != "" do
    %{error | query: query}
  end

  defp attach_query(error, _query), do: error

  defp resolve_logged_error(error) do
    case {in_failed_sql_transaction?(error), Process.get(@first_statement_error_key)} do
      {true, first_error} when not is_nil(first_error) -> first_error
      _ -> error
    end
  end

  defp log_batch_insert_failure(error) do
    case extract_sqlstate(error) do
      nil ->
        Logger.error("OCSF events batch insert failed: #{inspect(error)}")

      sqlstate ->
        Logger.error(
          "OCSF events batch insert failed (sqlstate=#{sqlstate}): #{inspect(error)}",
          sqlstate: sqlstate
        )
    end
  end

  defp in_failed_sql_transaction?(error) do
    case extract_postgres_fields(error) do
      %{pg_code: "25P02"} -> true
      %{code: :in_failed_sql_transaction} -> true
      _ -> false
    end
  end

  defp extract_sqlstate(error) do
    case extract_postgres_fields(error) do
      %{pg_code: pg_code} when is_binary(pg_code) and pg_code != "" ->
        pg_code

      %{code: code} when is_atom(code) and not is_nil(code) ->
        Atom.to_string(code)

      _ ->
        nil
    end
  end

  defp extract_postgres_fields(%Postgrex.Error{postgres: postgres}) when is_map(postgres),
    do: postgres

  defp extract_postgres_fields(%MatchError{term: term}), do: extract_postgres_fields(term)

  defp extract_postgres_fields({:error, reason}), do: extract_postgres_fields(reason)

  defp extract_postgres_fields({:store_unavailable, reason}), do: extract_postgres_fields(reason)

  defp extract_postgres_fields(_error), do: nil
end
