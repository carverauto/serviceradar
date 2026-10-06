defmodule ServiceRadar.Observability.StatefulAlertEngine.Input do
  @moduledoc """
  JSON representation of an accepted occurrence and its immutable rule revision.

  Source identity names an occurrence, never its content. Two equal records
  without a delivery identity receive distinct IDs; a redelivered event with
  the same ID keeps its identity even when its batch boundary changes.
  """

  alias ServiceRadar.Observability.StatefulAlertEngine.Record
  alias ServiceRadar.Observability.StatefulAlertRule

  @rule_fields [
    :id,
    :name,
    :description,
    :enabled,
    :priority,
    :signal,
    :match,
    :group_by,
    :threshold,
    :window_seconds,
    :bucket_seconds,
    :cooldown_seconds,
    :renotify_seconds,
    :event,
    :alert,
    :managed,
    :template_version,
    :template_fingerprint,
    :plugin_package_id
  ]
  @record_fields [
    :id,
    :time,
    :timestamp,
    :severity,
    :severity_id,
    :severity_text,
    :severity_number,
    :message,
    :body,
    :log_name,
    :log_provider,
    :service_name,
    :attributes,
    :resource_attributes,
    :unmapped,
    :metadata,
    :device,
    :device_uid,
    :device_id,
    :agent_id,
    :gateway_id,
    :partition,
    :series_key,
    :metric_name,
    :metric_type,
    :unit,
    :value,
    :tags,
    :class_uid,
    :activity_id,
    :type_uid,
    :category_uid,
    :status_id,
    :status,
    :count,
    :__stateful_alert_violation__,
    :__stateful_alert_condition__
  ]

  def prepare(signal, record) when signal in [:log, :event, :metric] and is_map(record) do
    id = Map.get(record, :id) || Map.get(record, "id")
    # A lifecycle transition may reuse the event row's stable identity. Its
    # caller supplies a distinct occurrence inside the same admission/write
    # transaction; the original event ID remains in incident diagnostics.
    source_id = Map.get(record, :__alert_evaluation_occurrence_id__) || id
    occurrence = if is_nil(source_id), do: Ash.UUID.generate(), else: normalize_id(source_id)
    source_key = "#{signal}:" <> Base.encode16(:crypto.hash(:sha256, occurrence), case: :lower)

    payload_id = if is_nil(id), do: occurrence, else: normalize_id(id)

    record =
      record
      |> attributes()
      |> Map.put(:id, payload_id)
      |> Map.delete("id")
      |> Map.delete(:__alert_evaluation_occurrence_id__)

    record =
      if is_nil(
           Map.get(record, :time) || Map.get(record, "time") || Map.get(record, :timestamp) ||
             Map.get(record, "timestamp")
         ) do
        Map.put(record, :time, DateTime.utc_now())
      else
        record
      end

    # Round-trip before admission, rather than discovering an invalid payload
    # after durable acceptance. JSON owns nested key normalization.
    case Jason.encode(record) do
      {:ok, json} ->
        payload = Jason.decode!(json)
        restore_record(payload)
        {:ok, %{source_key: source_key, payload: payload, bytes: byte_size(json)}}

      {:error, reason} ->
        {:error, {:invalid_payload, reason}}
    end
  rescue
    error -> {:error, {:invalid_payload, error}}
  end

  def prepare(_signal, _record), do: {:error, :invalid_payload}

  def revision(rule) do
    rule |> Map.take(@rule_fields) |> Jason.encode!() |> Jason.decode!()
  end

  @doc "Validates stored input before any lifecycle effect is attempted."
  def decode(work) do
    rule = restore_rule(work.rule_revision)
    record = restore_record(work.payload)

    if rule.id != work.rule_id or rule.signal != work.signal or
         is_nil(
           Record.record_datetime(record, :time) || Record.record_datetime(record, :timestamp)
         ) do
      {:error, :invalid_accepted_input}
    else
      {:ok, rule, record}
    end
  rescue
    _error -> {:error, :invalid_accepted_input}
  end

  def restore_rule(revision) do
    fields =
      Map.new(@rule_fields, fn field -> {field, Map.get(revision, Atom.to_string(field))} end)

    signal =
      case fields.signal do
        "log" -> :log
        "event" -> :event
        "metric" -> :metric
      end

    struct!(StatefulAlertRule, %{fields | signal: signal})
  end

  def restore_record(payload) do
    Enum.reduce(@record_fields, payload, fn field, restored ->
      key = Atom.to_string(field)

      case Map.fetch(payload, key) do
        {:ok, value} -> restored |> Map.delete(key) |> Map.put(field, restore_value(field, value))
        :error -> restored
      end
    end)
  end

  defp attributes(%{__struct__: resource} = record) do
    fields = Enum.map(Ash.Resource.Info.attributes(resource), & &1.name)
    Map.take(record, fields)
  end

  defp attributes(record), do: record

  defp restore_value(field, value) when field in [:time, :timestamp] and is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      {:error, reason} -> raise ArgumentError, "invalid accepted timestamp: #{inspect(reason)}"
    end
  end

  defp restore_value(field, nil) when field in [:time, :timestamp], do: nil

  defp restore_value(field, _value) when field in [:time, :timestamp] do
    raise ArgumentError, "accepted timestamp must be an ISO8601 string"
  end

  defp restore_value(_field, value), do: value

  defp normalize_id(id) when is_binary(id) and byte_size(id) > 0,
    do: Record.canonical_source_id(id)

  defp normalize_id(id) when not is_binary(id),
    do: Record.canonical_source_id(id)
end
