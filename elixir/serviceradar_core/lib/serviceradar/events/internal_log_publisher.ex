defmodule ServiceRadar.Events.InternalLogPublisher do
  @moduledoc """
  Publishes internal OCSF log activity payloads to NATS as `logs.internal.*`.
  """

  alias ServiceRadar.NATS.Channels
  alias ServiceRadar.NATS.Connection

  require Logger

  @default_service_name "serviceradar.core"

  @spec publish(String.t(), map(), keyword()) :: :ok | {:error, term()}
  def publish(subject, payload, opts \\ []) when is_binary(subject) and is_map(payload) do
    service_name = Keyword.get(opts, :service_name, @default_service_name)
    nats_subject = Channels.build("logs.internal.#{subject}")

    payload = normalize_payload(payload, service_name)

    case Jason.encode(payload) do
      {:ok, json} ->
        case Connection.publish(nats_subject, json) do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.warning("Failed to publish internal log",
              subject: nats_subject,
              reason: inspect(reason)
            )

            {:error, reason}
        end

      {:error, reason} ->
        Logger.warning("Failed to encode internal log payload", reason: inspect(reason))
        {:error, reason}
    end
  end

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
