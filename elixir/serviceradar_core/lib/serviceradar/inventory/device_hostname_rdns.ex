defmodule ServiceRadar.Inventory.DeviceHostnameRdns do
  @moduledoc """
  Applies reverse-DNS hostnames onto `ocsf_devices` rows.

  The AshOban trigger on `DeviceHostnameRdnsSettings` calls `run/2`. Lookups
  are injected in tests so the job does not depend on a live resolver.
  """

  import Ash.Expr

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Observability.IpRdnsCache
  alias ServiceRadar.Observability.ReverseDns

  require Ash.Query
  require Logger

  @type stats :: %{
          looked_up: non_neg_integer(),
          updated: non_neg_integer(),
          skipped: non_neg_integer(),
          errors: non_neg_integer()
        }

  @spec run(map(), keyword()) :: {:ok, stats()}
  def run(settings, opts \\ []) when is_map(settings) do
    actor = Keyword.get(opts, :actor) || SystemActor.system(:device_hostname_rdns)
    now = Keyword.get(opts, :now) || DateTime.utc_now()
    lookup = Keyword.get(opts, :lookup) || (&ReverseDns.lookup_status/2)
    persist = Keyword.get(opts, :persist) || (&persist_result/6)
    cache? = Keyword.get(opts, :cache?, true)
    timeout_ms = Map.get(settings, :timeout_ms) || 250

    devices =
      Keyword.get_lazy(opts, :devices, fn ->
        list_candidates(settings, actor, now)
      end)

    stats =
      Enum.reduce(devices, empty_stats(), fn device, acc ->
        apply_device(device, actor, now, lookup, persist, timeout_ms, cache?, acc)
      end)

    {:ok, stats}
  end

  @spec empty_stats() :: stats()
  def empty_stats do
    %{looked_up: 0, updated: 0, skipped: 0, errors: 0}
  end

  @spec candidate?(map(), map(), DateTime.t()) :: boolean()
  def candidate?(device, settings, now \\ DateTime.utc_now()) do
    ip = device_ip(device)
    overwrite? = Map.get(settings, :overwrite_existing) == true
    retry_after = Map.get(settings, :retry_after_minutes) || 1_440

    cond do
      ip == "" ->
        false

      not overwrite? and not ReverseDns.missing_or_ip_hostname?(device_hostname(device), ip) ->
        false

      recently_looked_up?(device, now, retry_after) ->
        false

      true ->
        true
    end
  end

  defp list_candidates(settings, actor, now) do
    batch_size = max(Map.get(settings, :batch_size) || 200, 1)
    overwrite? = Map.get(settings, :overwrite_existing) == true

    Device
    |> Ash.Query.for_read(:read, %{include_deleted: false})
    |> Ash.Query.filter(expr(not is_nil(ip) and ip != ""))
    |> maybe_filter_missing_hostname(overwrite?)
    |> Ash.Query.select([:uid, :ip, :hostname, :metadata, :last_seen_time])
    |> Ash.Query.sort(last_seen_time: :desc)
    |> Ash.Query.limit(batch_size * 5)
    |> Ash.read(actor: actor)
    |> case do
      {:ok, devices} ->
        devices
        |> Enum.filter(&candidate?(&1, settings, now))
        |> Enum.take(batch_size)

      {:error, reason} ->
        Logger.warning("DeviceHostnameRdns: failed to list candidates", reason: inspect(reason))
        []
    end
  end

  defp maybe_filter_missing_hostname(query, true), do: query

  defp maybe_filter_missing_hostname(query, _overwrite?) do
    Ash.Query.filter(query, expr(is_nil(hostname) or hostname == "" or hostname == ip))
  end

  @spec result_attrs(map(), String.t() | nil, String.t(), String.t() | nil, DateTime.t()) ::
          {:update, map()} | {:skip, map()}
  def result_attrs(device, hostname, status, error, now) do
    metadata = put_rdns_metadata(device, hostname, status, error, now)

    if status == "ok" and ReverseDns.usable_hostname?(hostname, device_ip(device)) do
      {:update, %{hostname: hostname, metadata: metadata}}
    else
      {:skip, %{metadata: metadata}}
    end
  end

  defp apply_device(device, actor, now, lookup, persist, timeout_ms, cache?, acc) do
    ip = device_ip(device)

    {hostname, status, error} = lookup.(ip, timeout_ms: timeout_ms)
    acc = Map.update!(acc, :looked_up, &(&1 + 1))

    if cache? do
      cache_rdns(ip, hostname, status, error, actor, now)
    end

    case persist.(device, hostname, status, error, now, actor) do
      :updated -> Map.update!(acc, :updated, &(&1 + 1))
      :skipped -> Map.update!(acc, :skipped, &(&1 + 1))
      {:error, _} -> Map.update!(acc, :errors, &(&1 + 1))
    end
  end

  defp persist_result(device, hostname, status, error, now, actor) do
    case result_attrs(device, hostname, status, error, now) do
      {:update, attrs} ->
        case update_device(device, attrs, actor) do
          :ok -> :updated
          {:error, reason} -> {:error, reason}
        end

      {:skip, attrs} ->
        case update_device(device, attrs, actor) do
          :ok -> :skipped
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp update_device(device, attrs, actor) do
    device
    |> Ash.Changeset.for_update(:update, attrs)
    |> Ash.update(actor: actor)
    |> case do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning("DeviceHostnameRdns: failed to update device",
          device_id: device_uid(device),
          ip: device_ip(device),
          reason: inspect(reason)
        )

        {:error, reason}
    end
  end

  defp cache_rdns(ip, hostname, status, error, actor, now) do
    attrs = %{
      ip: ip,
      hostname: hostname,
      status: status,
      looked_up_at: now,
      expires_at: DateTime.add(now, 86_400, :second),
      error: error,
      error_count: if(is_nil(error), do: 0, else: 1)
    }

    changeset = Ash.Changeset.for_create(IpRdnsCache, :upsert, attrs)

    case Ash.create(changeset, actor: actor) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning("DeviceHostnameRdns: failed to upsert rDNS cache",
          ip: ip,
          reason: inspect(reason)
        )

        :error
    end
  end

  defp put_rdns_metadata(device, hostname, status, error, now) do
    metadata = device_metadata(device)

    Map.put(metadata, "rdns", %{
      "looked_up_at" => DateTime.to_iso8601(now),
      "status" => status,
      "hostname" => hostname,
      "error" => error
    })
  end

  defp recently_looked_up?(device, now, retry_after_minutes) do
    case rdns_looked_up_at(device) do
      nil ->
        false

      looked_up_at ->
        DateTime.diff(now, looked_up_at, :second) < retry_after_minutes * 60
    end
  end

  defp rdns_looked_up_at(device) do
    case device_metadata(device) do
      %{"rdns" => %{"looked_up_at" => value}} -> parse_datetime(value)
      %{rdns: %{"looked_up_at" => value}} -> parse_datetime(value)
      %{rdns: %{looked_up_at: value}} -> parse_datetime(value)
      _ -> nil
    end
  end

  defp parse_datetime(%DateTime{} = datetime), do: datetime

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end

  defp parse_datetime(_), do: nil

  defp device_ip(%{ip: ip}) when is_binary(ip), do: String.trim(ip)
  defp device_ip(%{"ip" => ip}) when is_binary(ip), do: String.trim(ip)
  defp device_ip(_), do: ""

  defp device_hostname(%{hostname: hostname}), do: hostname
  defp device_hostname(%{"hostname" => hostname}), do: hostname
  defp device_hostname(_), do: nil

  defp device_uid(%{uid: uid}), do: uid
  defp device_uid(%{"uid" => uid}), do: uid
  defp device_uid(_), do: nil

  defp device_metadata(%{metadata: metadata}) when is_map(metadata), do: metadata
  defp device_metadata(%{"metadata" => metadata}) when is_map(metadata), do: metadata
  defp device_metadata(_), do: %{}
end
