defmodule ServiceRadar.Events.InternalLogPublisher do
  @moduledoc """
  Publishes internal OCSF log activity payloads to NATS as `logs.internal.*`.
  """

  alias ServiceRadar.NATS.{Channels, Connection}

  require Logger
  require Ash.Query

  @default_service_name "serviceradar.core"

  @spec publish(String.t(), map(), keyword()) :: :ok | {:error, term()}
  def publish(subject, payload, opts \\ []) when is_binary(subject) and is_map(payload) do
    tenant_id = Keyword.get(opts, :tenant_id)
    tenant_slug = Keyword.get(opts, :tenant_slug) || lookup_tenant_slug(tenant_id)
    service_name = Keyword.get(opts, :service_name, @default_service_name)
    nats_subject = Channels.build("logs.internal.#{subject}", tenant_slug: tenant_slug)

    payload = normalize_payload(payload, service_name)

    case Jason.encode(payload) do
      {:ok, json} ->
        case Connection.publish(nats_subject, json) do
          :ok -> :ok
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
    DateTime.from_unix!(ts, :second)
    |> DateTime.to_iso8601()
  rescue
    _ -> DateTime.utc_now() |> DateTime.to_iso8601()
  end

  defp normalize_timestamp(_), do: DateTime.utc_now() |> DateTime.to_iso8601()

  defp stringify_keys(map) when is_map(map) do
    map
    |> Enum.map(fn {key, value} -> {to_string(key), stringify_value(value)} end)
    |> Map.new()
  end

  defp stringify_keys(value), do: value

  defp stringify_value(value) when is_map(value), do: stringify_keys(value)
  defp stringify_value(value) when is_list(value), do: Enum.map(value, &stringify_value/1)
  defp stringify_value(value), do: value

  defp lookup_tenant_slug(nil), do: nil

  defp lookup_tenant_slug(tenant_id) do
    case ServiceRadar.Identity.Tenant
         |> Ash.Query.filter(id == ^tenant_id)
         |> Ash.Query.limit(1)
         |> Ash.read(authorize?: false) do
      {:ok, [tenant | _]} -> to_string(tenant.slug)
      _ -> nil
    end
  rescue
    _ -> nil
  end
end
