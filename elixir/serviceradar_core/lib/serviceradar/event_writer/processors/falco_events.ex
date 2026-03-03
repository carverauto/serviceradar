defmodule ServiceRadar.EventWriter.Processors.FalcoEvents do
  @moduledoc """
  Processor for Falco runtime security events published via NATS JetStream.

  Falco payloads are normalized into OCSF Event Log Activity rows and persisted
  to `ocsf_events` so they participate in the existing Events UI and rule flow.
  """

  @behaviour ServiceRadar.EventWriter.Processor

  import Bitwise

  alias ServiceRadar.Events.PubSub, as: EventsPubSub
  alias ServiceRadar.EventWriter.{FieldParser, OCSF}
  alias ServiceRadar.Observability.StatefulAlertEngine

  require Logger

  @priority_map %{
    "emergency" => {OCSF.severity_fatal(), OCSF.status_failure()},
    "alert" => {OCSF.severity_fatal(), OCSF.status_failure()},
    "critical" => {OCSF.severity_critical(), OCSF.status_failure()},
    "error" => {OCSF.severity_high(), OCSF.status_failure()},
    "err" => {OCSF.severity_high(), OCSF.status_failure()},
    "warning" => {OCSF.severity_medium(), OCSF.status_failure()},
    "warn" => {OCSF.severity_medium(), OCSF.status_failure()},
    "notice" => {OCSF.severity_low(), OCSF.status_success()},
    "informational" => {OCSF.severity_informational(), OCSF.status_success()},
    "info" => {OCSF.severity_informational(), OCSF.status_success()},
    "debug" => {OCSF.severity_informational(), OCSF.status_success()}
  }

  @impl true
  def table_name, do: "ocsf_events"

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
          maybe_evaluate_stateful_rules(rows)
          EventsPubSub.broadcast_event(%{count: count})
          {:ok, count}
      end
    end
  rescue
    e ->
      Logger.error("Falco events batch insert failed: #{inspect(e)}")
      {:error, e}
  end

  @impl true
  def parse_message(%{data: data, metadata: metadata}) do
    with {:ok, payload} <- decode_payload(data, metadata),
         {:ok, row} <- build_row(payload, metadata, data) do
      row
    else
      {:error, reason} ->
        emit_drop(reason, metadata[:subject])
        nil
    end
  rescue
    e ->
      Logger.warning("Failed to parse Falco event",
        reason: inspect(e),
        subject: metadata[:subject]
      )

      emit_drop(:parse_exception, metadata[:subject])
      nil
  end

  def parse_message(_), do: nil

  defp decode_payload(data, _metadata) when is_binary(data) do
    case Jason.decode(data) do
      {:ok, payload} when is_map(payload) -> {:ok, payload}
      {:ok, _payload} -> {:error, :payload_not_map}
      {:error, _} -> {:error, :invalid_json}
    end
  end

  defp decode_payload(_data, _metadata), do: {:error, :invalid_payload}

  defp build_row(payload, metadata, raw_data) do
    subject = normalize_subject(metadata[:subject])
    priority = payload["priority"]
    {severity_id, status_id} = severity_status_for_priority(priority)

    event_time = parse_event_time(payload["time"], metadata[:received_at])
    event_id = resolve_event_id(payload, subject, raw_data)
    output_fields = normalize_map(payload["output_fields"])

    {:ok,
     %{
       id: Ecto.UUID.dump!(event_id),
       time: event_time,
       class_uid: OCSF.class_event_log_activity(),
       category_uid: OCSF.category_system_activity(),
       type_uid: OCSF.type_uid(OCSF.class_event_log_activity(), OCSF.activity_log_update()),
       activity_id: OCSF.activity_log_update(),
       activity_name: OCSF.log_activity_name(OCSF.activity_log_update()),
       severity_id: severity_id,
       severity: OCSF.severity_name(severity_id),
       message: event_message(payload, subject),
       status_id: status_id,
       status: OCSF.status_name(status_id),
       status_code: nil,
       status_detail: nil,
       metadata: build_metadata(payload, subject, output_fields),
       observables: build_observables(payload, output_fields),
       trace_id: nil,
       span_id: nil,
       actor: build_actor(output_fields),
       device: build_device(payload, output_fields),
       src_endpoint: %{},
       dst_endpoint: %{},
       log_name: subject,
       log_provider: "falco",
       log_level: normalize_string(priority),
       log_version: "1.0",
       unmapped: payload,
       raw_data: normalize_raw_data(raw_data),
       created_at: DateTime.utc_now()
     }}
  end

  defp severity_status_for_priority(priority) do
    normalized =
      priority
      |> normalize_string()
      |> case do
        nil -> nil
        value -> String.downcase(value)
      end

    Map.get(@priority_map, normalized, {OCSF.severity_unknown(), OCSF.status_other()})
  end

  defp event_message(payload, subject) do
    normalize_string(payload["output"]) ||
      normalize_string(payload["rule"]) ||
      subject || "falco event"
  end

  defp build_metadata(payload, subject, output_fields) do
    %{
      "source" => "falco",
      "subject" => subject,
      "uuid" => normalize_string(payload["uuid"]),
      "rule" => normalize_string(payload["rule"]),
      "priority" => normalize_string(payload["priority"]),
      "hostname" => normalize_string(payload["hostname"]),
      "source_type" => normalize_string(payload["source"]),
      "tags" => normalize_tags(payload["tags"]),
      "output_fields" => output_fields
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp build_observables(payload, output_fields) do
    [
      maybe_observable(normalize_string(payload["hostname"]), "Hostname", 1),
      maybe_observable(normalize_string(payload["rule"]), "Rule Name", 99),
      maybe_observable(normalize_string(output_fields["container.id"]), "Container ID", 99),
      maybe_observable(normalize_string(output_fields["k8s.pod.name"]), "Kubernetes Pod", 99)
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp build_actor(output_fields) do
    OCSF.build_actor(
      app_name: "falco",
      process: normalize_string(output_fields["proc.name"]),
      user: normalize_string(output_fields["user.name"])
    )
  end

  defp build_device(payload, output_fields) do
    hostname = normalize_string(payload["hostname"])

    uid =
      normalize_string(output_fields["container.id"]) ||
        normalize_string(output_fields["k8s.pod.name"]) ||
        hostname

    name =
      normalize_string(output_fields["container.name"]) ||
        normalize_string(output_fields["k8s.pod.name"])

    OCSF.build_device(uid: uid, name: name, hostname: hostname)
  end

  defp resolve_event_id(payload, subject, raw_data) do
    uuid = normalize_string(payload["uuid"])

    cond do
      is_binary(uuid) ->
        case Ecto.UUID.cast(uuid) do
          {:ok, cast_uuid} -> cast_uuid
          :error -> deterministic_uuid("#{subject}:uuid:#{String.downcase(uuid)}")
        end

      true ->
        hash = Base.encode16(:crypto.hash(:sha256, raw_data), case: :lower)
        deterministic_uuid("#{subject}:sha256:#{hash}")
    end
  end

  defp parse_event_time(nil, %DateTime{} = received_at), do: received_at
  defp parse_event_time(nil, _received_at), do: DateTime.utc_now()
  defp parse_event_time(value, _received_at), do: FieldParser.parse_timestamp(value)

  defp normalize_subject(subject) when is_binary(subject), do: subject
  defp normalize_subject(_), do: "falco.unknown"

  defp normalize_map(value) when is_map(value), do: value
  defp normalize_map(_), do: %{}

  defp normalize_tags(value) when is_list(value) do
    value
    |> Enum.map(&normalize_string/1)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_tags(_), do: []

  defp normalize_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_string(_), do: nil

  defp maybe_observable(nil, _type, _type_id), do: nil
  defp maybe_observable(value, type, type_id), do: OCSF.build_observable(value, type, type_id)

  defp deterministic_uuid(key) do
    <<a1::32, a2::16, a3::16, a4::16, a5::48, _rest::binary>> = :crypto.hash(:sha256, key)
    versioned_a3 = band(a3, 0x0FFF) |> bor(0x4000)
    versioned_a4 = band(a4, 0x3FFF) |> bor(0x8000)

    :io_lib.format(
      "~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b",
      [a1, a2, versioned_a3, versioned_a4, a5]
    )
    |> IO.iodata_to_binary()
  end

  defp normalize_raw_data(data) when is_binary(data) do
    if String.valid?(data), do: data, else: Base.encode64(data)
  end

  defp normalize_raw_data(data), do: inspect(data)

  defp maybe_evaluate_stateful_rules([]), do: :ok

  defp maybe_evaluate_stateful_rules(rows) do
    case StatefulAlertEngine.evaluate_events(rows) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Stateful alert evaluation failed for Falco events: #{inspect(reason)}")
        :ok
    end
  end

  defp emit_drop(reason, subject) do
    :telemetry.execute(
      [:serviceradar, :event_writer, :falco, :dropped],
      %{count: 1},
      %{reason: reason, subject: subject || "falco.unknown"}
    )

    Logger.debug("Dropped Falco message", reason: inspect(reason), subject: subject)
  end
end
