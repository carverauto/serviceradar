defmodule ServiceRadar.Events.InternalLogPublisher do
  @moduledoc """
  Persists internal OCSF log activity payloads and optionally publishes them to
  NATS as `live.logs.internal.*` for live subscribers.
  """

  alias ServiceRadar.EventWriter.Processors.Logs
  alias ServiceRadar.NATS.Channels
  alias ServiceRadar.NATS.Connection

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
    message = %{
      data: json,
      metadata: %{
        subject: subject,
        received_at: DateTime.utc_now(),
        headers: []
      }
    }

    case process_logs(log_processor(opts), [message]) do
      {:ok, _count} ->
        :ok

      {:error, reason} ->
        ServiceRadar.Otel.set_error(reason)

        Logger.warning("Failed to persist internal log",
          subject: subject,
          reason: inspect(reason)
        )

        {:error, reason}

      other ->
        ServiceRadar.Otel.set_error(other)

        Logger.warning("Unexpected internal log persistence result",
          subject: subject,
          result: inspect(other)
        )

        {:error, other}
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

  defp log_processor(opts) do
    Keyword.get(opts, :log_processor, Logs)
  end

  defp publisher(opts) do
    Keyword.get(opts, :publisher, {Connection, :publish, []})
  end

  defp process_logs({mod, fun, extra_args}, messages) do
    apply(mod, fun, [messages | extra_args])
  end

  defp process_logs(mod, messages) when is_atom(mod), do: mod.process_batch(messages)
  defp process_logs(fun, messages) when is_function(fun, 1), do: fun.(messages)

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
  end

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
