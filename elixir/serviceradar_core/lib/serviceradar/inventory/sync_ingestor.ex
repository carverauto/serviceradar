defmodule ServiceRadar.Inventory.SyncIngestor do
  @moduledoc """
  Ingests sync device updates and upserts OCSF device records using DIRE.
  """

  require Logger

  alias ServiceRadar.Inventory.{Device, IdentityReconciler}

  @spec ingest_updates([map()], String.t(), keyword()) :: :ok | {:error, term()}
  def ingest_updates(updates, tenant_id, opts \\ []) do
    actor = Keyword.get(opts, :actor, system_actor(tenant_id))

    updates
    |> List.wrap()
    |> Enum.reduce(:ok, fn update, _acc ->
      ingest_update(update, tenant_id, actor)
      :ok
    end)
  end

  defp ingest_update(update, tenant_id, actor) do
    normalized = normalize_update(update)

    with {:ok, device_id} <- IdentityReconciler.resolve_device_id(normalized, actor: actor) do
      ids = IdentityReconciler.extract_strong_identifiers(normalized)
      _ = IdentityReconciler.register_identifiers(device_id, ids, actor: actor)

      timestamp = normalized.timestamp || DateTime.utc_now()
      {create_attrs, update_attrs} = build_device_attrs(normalized, device_id, timestamp)

      case Device.get_by_uid(device_id, tenant: tenant_id, actor: actor, authorize?: false) do
        {:ok, device} ->
          device
          |> Ash.Changeset.for_update(:update, update_attrs)
          |> Ash.update(tenant: tenant_id, actor: actor, authorize?: false)
          |> case do
            {:ok, _} -> :ok
            {:error, reason} ->
              Logger.warning("Sync update failed for device #{device_id}: #{inspect(reason)}")
              {:error, reason}
          end

        {:error, reason} ->
          if not_found_error?(reason) do
            Device
            |> Ash.Changeset.for_create(:create, create_attrs)
            |> Ash.create(tenant: tenant_id, actor: actor, authorize?: false)
            |> case do
              {:ok, _} -> :ok
              {:error, create_reason} ->
                Logger.warning("Sync create failed for device #{device_id}: #{inspect(create_reason)}")
                {:error, create_reason}
            end
          else
            Logger.warning("Sync lookup failed for device #{device_id}: #{inspect(reason)}")
            {:error, reason}
          end
      end
    else
      {:error, reason} ->
        Logger.warning("Sync identity resolution failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp normalize_update(update) when is_map(update) do
    %{
      device_id: get_string(update, ["device_id", :device_id]),
      ip: get_string(update, ["ip", :ip]),
      mac: get_string(update, ["mac", :mac]),
      hostname: get_string(update, ["hostname", :hostname]),
      partition: get_string(update, ["partition", :partition]) || "default",
      metadata: get_map(update, ["metadata", :metadata]),
      timestamp: parse_timestamp(get_value(update, ["timestamp", :timestamp])),
      is_available: get_bool(update, ["is_available", :is_available])
    }
  end

  defp normalize_update(_update) do
    %{
      device_id: nil,
      ip: nil,
      mac: nil,
      hostname: nil,
      partition: "default",
      metadata: %{},
      timestamp: nil,
      is_available: false
    }
  end

  defp build_device_attrs(update, device_id, timestamp) do
    metadata = update.metadata || %{}

    update_attrs = %{
      ip: update.ip,
      mac: update.mac,
      hostname: update.hostname,
      name: update.hostname || update.ip,
      last_seen_time: timestamp,
      modified_time: timestamp,
      is_available: update.is_available,
      metadata: metadata
    }

    create_attrs =
      update_attrs
      |> Map.put(:uid, device_id)
      |> Map.put(:first_seen_time, timestamp)
      |> Map.put(:created_time, timestamp)

    {create_attrs, update_attrs}
  end

  defp parse_timestamp(nil), do: nil

  defp parse_timestamp(timestamp) when is_binary(timestamp) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, parsed, _offset} -> parsed
      _ -> nil
    end
  end

  defp parse_timestamp(%DateTime{} = timestamp), do: timestamp

  defp parse_timestamp(_timestamp), do: nil

  defp get_value(map, keys) do
    Enum.find_value(keys, fn key ->
      case map do
        %{^key => value} -> value
        _ -> nil
      end
    end)
  end

  defp get_string(map, keys) do
    case get_value(map, keys) do
      value when is_binary(value) -> String.trim(value)
      _ -> nil
    end
  end

  defp get_map(map, keys) do
    case get_value(map, keys) do
      value when is_map(value) -> value
      _ -> %{}
    end
  end

  defp get_bool(map, keys) do
    case get_value(map, keys) do
      true -> true
      _ -> false
    end
  end

  defp not_found_error?(%Ash.Error.Query.NotFound{}), do: true

  defp not_found_error?(%Ash.Error.Invalid{errors: errors}) when is_list(errors) do
    Enum.any?(errors, &match?(%Ash.Error.Query.NotFound{}, &1))
  end

  defp not_found_error?(_error), do: false

  defp system_actor(tenant_id) do
    %{
      id: "system",
      email: "gateway@serviceradar",
      role: :admin,
      tenant_id: tenant_id
    }
  end
end
