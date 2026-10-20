defmodule ServiceRadar.Events.InternalLogPublisher do
  @moduledoc """
  Publishes internal OCSF log activity (health, audit, jobs, onboarding,
  sweep, sync, k8s) to JetStream on `logs.internal.*`, where EventWriter
  stores and promotes it like any other log, and optionally publishes a
  `live.logs.internal.*` copy for live subscribers.

  The publish is durable (`ServiceRadar.NATS.DurablePublish`): when NATS is
  unavailable the log is retried from an Oban job rather than dropped, and its
  `Nats-Msg-Id` gives it a stable row id so a retry stores it once.
  """

  alias ServiceRadar.EventWriter.LogSeverity
  alias ServiceRadar.EventWriter.OCSF
  alias ServiceRadar.NATS.Channels
  alias ServiceRadar.NATS.Connection
  alias ServiceRadar.NATS.DurablePublish

  require Logger

  @default_service_name "serviceradar.core"

  @spec publish(String.t(), map(), keyword()) :: :ok | {:error, term()}
  def publish(subject, payload, opts \\ []) when is_binary(subject) and is_map(payload) do
    service_name = Keyword.get(opts, :service_name, @default_service_name)
    persist_subject = Channels.build("logs.internal.#{subject}")
    live_subject = Channels.build("live.logs.internal.#{subject}")

    payload = normalize_payload(payload, service_name)

    ServiceRadar.Otel.span(
      "internal_log.persist",
      %{
        kind: :internal,
        attributes: %{
          "serviceradar.log.subject" => persist_subject
        }
      },
      fn ->
        case Jason.encode(payload) do
          {:ok, json} ->
            with :ok <- persist_log(persist_subject, json, opts) do
              maybe_publish(live_subject, json, opts)
            end

          {:error, reason} ->
            ServiceRadar.Otel.set_error(reason)
            Logger.warning("Failed to encode internal log payload", reason: inspect(reason))
            {:error, reason}
        end
      end
    )
  end

  defp persist_log(subject, json, opts) do
    durable_publish = Keyword.get(opts, :durable_publish, &DurablePublish.publish/3)

    case durable_publish.(subject, json, msg_id: Ash.UUID.generate()) do
      :ok ->
        :ok

      {:ok, :enqueued} ->
        :ok

      {:error, reason} ->
        ServiceRadar.Otel.set_error(reason)

        Logger.warning("Failed to publish internal log",
          subject: subject,
          reason: inspect(reason)
        )

        {:error, reason}
    end
  end

  defp maybe_publish(subject, json, opts) do
    if nats_live_publish?(opts) do
      case publish_to_nats(publisher(opts), subject, json) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning("Failed to publish internal log live copy",
            subject: subject,
            reason: inspect(reason)
          )

          :ok
      end
    else
      :ok
    end
  end

  defp nats_live_publish?(opts) do
    Keyword.get_lazy(opts, :publish_to_nats?, fn ->
      Application.get_env(:serviceradar_core, :internal_log_live_nats, true)
    end)
  end

  defp publisher(opts) do
    Keyword.get(opts, :publisher, {Connection, :publish, []})
  end

  defp publish_to_nats({mod, fun, extra_args}, subject, payload) do
    apply(mod, fun, [subject, payload | extra_args])
  end

  defp publish_to_nats(fun, subject, payload) when is_function(fun, 2), do: fun.(subject, payload)

  defp normalize_payload(payload, service_name) do
    payload = stringify_keys(payload)
    timestamp = normalize_timestamp(payload["timestamp"] || payload["time"])

    payload
    |> Map.put("time", timestamp)
    |> Map.put("timestamp", timestamp)
    |> Map.put_new("service_name", service_name)
    |> put_otel_severity()
  end

  # Most internal producers describe severity in OCSF terms (`severity_id` and
  # a name such as "Informational") or as a bare `severity` word. The logs
  # processor stores an explicit `severity_text` verbatim and otherwise keeps
  # that name with no `severity_number`, so the row would drop out of level
  # filters. Derive the OTEL pair here unless the producer already set one.
  defp put_otel_severity(%{"severity_text" => text} = payload)
       when is_binary(text) and text != "", do: payload

  defp put_otel_severity(payload) do
    case severity_label(payload) do
      nil ->
        payload

      label ->
        {text, number} = LogSeverity.from_level(label)

        payload
        |> Map.put("severity_text", text)
        |> Map.put_new("severity_number", number)
    end
  end

  # An OCSF id goes through its name: LogSeverity reads a bare integer as a
  # syslog level, where 1 means alert rather than informational.
  defp severity_label(%{"severity_id" => id}) when is_integer(id), do: OCSF.severity_name(id)
  defp severity_label(%{"severity" => name}) when is_binary(name) and name != "", do: name
  defp severity_label(_payload), do: nil

  defp normalize_timestamp(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp normalize_timestamp(ts) when is_binary(ts) and ts != "", do: ts

  defp normalize_timestamp(ts) when is_integer(ts) do
    ts
    |> DateTime.from_unix!(:second)
    |> DateTime.to_iso8601()
  rescue
    _ -> DateTime.to_iso8601(DateTime.utc_now())
  end

  defp normalize_timestamp(_), do: DateTime.to_iso8601(DateTime.utc_now())

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), stringify_value(value)} end)
  end

  defp stringify_keys(value), do: value

  defp stringify_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp stringify_value(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp stringify_value(%Date{} = value), do: Date.to_iso8601(value)
  # Avoid treating structs (e.g. Ash.CiString) as maps, since they don't implement Enumerable.
  defp stringify_value(%_{} = value) do
    to_string(value)
  rescue
    _ -> inspect(value)
  end

  defp stringify_value(value) when is_map(value), do: stringify_keys(value)
  defp stringify_value(value) when is_list(value), do: Enum.map(value, &stringify_value/1)
  defp stringify_value(value), do: value
end
