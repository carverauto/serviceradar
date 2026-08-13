defmodule ServiceRadar.Inventory.DeviceHostnameRdns do
  @moduledoc """
  Applies reverse-DNS hostnames onto `ocsf_devices` rows.

  The AshOban trigger on `DeviceHostnameRdnsSettings` calls `run/2`. Lookups
  are injected in tests so the job does not depend on a live resolver.
  """

  import Ash.Expr

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Ash.Page
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Observability.IpRdnsCache
  alias ServiceRadar.Observability.ReverseDns
  alias ServiceRadar.Observability.SRQLRunner
  alias ServiceRadar.SRQLAst
  alias ServiceRadar.SRQLQuery
  alias ServiceRadar.Types.Cidr

  require Ash.Query
  require Logger

  @default_srql_query "in:devices sort:last_seen:desc"
  @srql_page_limit 500
  @max_srql_pages 40

  @type stats :: %{
          looked_up: non_neg_integer(),
          updated: non_neg_integer(),
          skipped: non_neg_integer(),
          errors: non_neg_integer(),
          cohort_rows: non_neg_integer(),
          candidates: non_neg_integer(),
          loaded: non_neg_integer()
        }

  @spec default_srql_query() :: String.t()
  def default_srql_query, do: @default_srql_query

  @spec run(map(), keyword()) :: {:ok, stats()} | {:error, term()}
  def run(settings, opts \\ []) when is_map(settings) do
    actor = Keyword.get(opts, :actor) || SystemActor.system(:device_hostname_rdns)
    now = Keyword.get(opts, :now) || DateTime.utc_now()
    lookup = Keyword.get(opts, :lookup) || (&ReverseDns.lookup_status/2)
    persist = Keyword.get(opts, :persist) || (&persist_result/6)
    cache? = Keyword.get(opts, :cache?, true)
    timeout_ms = Map.get(settings, :timeout_ms) || 250

    case resolve_devices(settings, actor, now, opts) do
      {:ok, devices, meta} ->
        stats =
          Enum.reduce(devices, Map.merge(empty_stats(), meta), fn device, acc ->
            apply_device(device, actor, now, lookup, persist, timeout_ms, cache?, acc)
          end)

        Logger.info("DeviceHostnameRdns: finished run",
          query: Map.get(meta, :query),
          cohort_rows: stats.cohort_rows,
          candidates: stats.candidates,
          loaded: stats.loaded,
          looked_up: stats.looked_up,
          updated: stats.updated,
          skipped: stats.skipped,
          errors: stats.errors
        )

        {:ok, stats}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec preview(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def preview(query, opts \\ []) when is_binary(query) do
    limit = Keyword.get(opts, :limit, 10)
    query_page = query_page_fun(opts)

    with {:ok, normalized} <- normalize_device_query(query),
         {:ok, %{rows: rows}} <- query_page.(normalized, limit: limit) do
      {:ok,
       %{
         query: normalized,
         total_count: length(rows),
         rows:
           Enum.map(rows, fn row ->
             %{
               uid: row_uid(row),
               ip: row_ip(row),
               hostname: row_hostname(row)
             }
           end)
       }}
    end
  end

  @spec empty_stats() :: stats()
  def empty_stats do
    %{
      looked_up: 0,
      updated: 0,
      skipped: 0,
      errors: 0,
      cohort_rows: 0,
      candidates: 0,
      loaded: 0
    }
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

  defp resolve_devices(settings, actor, now, opts) do
    case Keyword.fetch(opts, :devices) do
      {:ok, devices} ->
        loaded = unwrap_devices(devices)
        count = length(loaded)
        {:ok, loaded, %{cohort_rows: count, candidates: count, loaded: count}}

      :error ->
        list_candidates(settings, actor, now, opts)
    end
  end

  defp list_candidates(settings, actor, now, opts) do
    batch_size = max(Map.get(settings, :batch_size) || 200, 1)
    query_page = query_page_fun(opts)
    load_devices = Keyword.get(opts, :load_devices, &load_devices_by_uid/2)

    query =
      Map.get(settings, :srql_query) || Map.get(settings, "srql_query") || @default_srql_query

    with {:ok, normalized} <- normalize_device_query(query),
         {:ok, %{scanned: scanned, candidates: candidates}} <-
           collect_candidates(query_page, normalized, settings, now, batch_size),
         {:ok, devices} <- load_devices.(candidates, actor) do
      Logger.info("DeviceHostnameRdns: selected cohort",
        query: normalized,
        srql_rows: scanned,
        candidates: length(candidates),
        loaded: length(devices)
      )

      {:ok, devices,
       %{
         query: normalized,
         cohort_rows: scanned,
         candidates: length(candidates),
         loaded: length(devices)
       }}
    end
  end

  defp query_page_fun(opts) do
    Keyword.get(opts, :query_page, &default_query_page/2)
  end

  defp default_query_page(query, opts) do
    SRQLRunner.query_page(
      query,
      Keyword.merge(
        [
          direction: "next",
          text_param_decoder: &decode_cidr_text_param/1
        ],
        opts
      )
    )
  end

  defp collect_candidates(query_page, query, settings, now, batch_size) do
    collect_candidates(query_page, query, settings, now, batch_size, nil, [], 0, 0)
  end

  defp collect_candidates(
         _query_page,
         _query,
         _settings,
         _now,
         _batch_size,
         _cursor,
         candidates,
         scanned,
         page
       )
       when page >= @max_srql_pages do
    {:ok, %{scanned: scanned, candidates: Enum.reverse(candidates)}}
  end

  defp collect_candidates(
         query_page,
         query,
         settings,
         now,
         batch_size,
         cursor,
         candidates,
         scanned,
         page
       ) do
    page_opts = maybe_put([limit: @srql_page_limit, direction: "next"], :cursor, cursor)

    case query_page.(query, page_opts) do
      {:ok, %{rows: rows} = result} when is_list(rows) ->
        absorb_candidate_page(
          query_page,
          query,
          settings,
          now,
          batch_size,
          result[:next_cursor] || result["next_cursor"],
          candidates,
          scanned,
          page,
          rows
        )

      {:ok, rows} when is_list(rows) ->
        absorb_candidate_page(
          query_page,
          query,
          settings,
          now,
          batch_size,
          nil,
          candidates,
          scanned,
          page,
          rows
        )

      {:error, reason} ->
        {:error, {:srql_query_failed, reason}}

      other ->
        {:error, {:srql_query_failed, other}}
    end
  end

  defp absorb_candidate_page(
         query_page,
         query,
         settings,
         now,
         batch_size,
         next_cursor,
         candidates,
         scanned,
         page,
         rows
       ) do
    page_candidates =
      rows
      |> Enum.map(&row_to_device/1)
      |> Enum.filter(&candidate?(&1, settings, now))

    remaining = batch_size - length(candidates)
    taken = Enum.take(page_candidates, max(remaining, 0))
    next_candidates = Enum.reverse(taken, candidates)
    next_scanned = scanned + length(rows)

    cond do
      length(next_candidates) >= batch_size ->
        {:ok, %{scanned: next_scanned, candidates: Enum.reverse(next_candidates)}}

      is_binary(next_cursor) and next_cursor != "" ->
        collect_candidates(
          query_page,
          query,
          settings,
          now,
          batch_size,
          next_cursor,
          next_candidates,
          next_scanned,
          page + 1
        )

      true ->
        {:ok, %{scanned: next_scanned, candidates: Enum.reverse(next_candidates)}}
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, _key, ""), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp decode_cidr_text_param(value) when is_binary(value) do
    if String.contains?(value, "/") do
      case Cidr.dump_to_native(value, []) do
        {:ok, inet} -> {:ok, inet}
        _ -> {:ok, value}
      end
    else
      {:ok, value}
    end
  end

  defp decode_cidr_text_param(value), do: {:ok, value}

  defp normalize_device_query(query) when is_binary(query) do
    normalized = SRQLQuery.ensure_target(query, :devices)

    if SRQLAst.entity(normalized) == "devices" do
      case SRQLAst.validate(normalized) do
        :ok -> {:ok, normalized}
        {:error, _reason} -> {:error, :invalid_srql_query}
      end
    else
      {:error, :cohort_must_target_devices}
    end
  end

  defp normalize_device_query(_query), do: {:error, :invalid_srql_query}

  defp load_devices_by_uid(candidates, actor) do
    uids =
      candidates
      |> Enum.map(&device_uid/1)
      |> Enum.reject(&is_nil/1)

    if uids == [] do
      {:ok, []}
    else
      Device
      |> Ash.Query.for_read(:read, %{include_deleted: false}, actor: actor)
      |> Ash.Query.filter(expr(uid in ^uids))
      |> Ash.Query.select([:uid, :ip, :hostname, :metadata, :last_seen_time])
      |> Ash.read(actor: actor, page: false)
      |> case do
        {:error, reason} ->
          {:error, {:device_load_failed, reason}}

        result ->
          loaded = unwrap_devices(result)
          by_uid = Map.new(loaded, &{device_uid(&1), &1})

          devices =
            uids
            |> Enum.map(&Map.get(by_uid, &1))
            |> Enum.reject(&is_nil/1)

          {:ok, devices}
      end
    end
  end

  defp unwrap_devices(result) do
    case Page.unwrap(result) do
      {:ok, devices} when is_list(devices) -> devices
      {:ok, _} -> []
      {:error, _} -> []
    end
  end

  defp row_to_device(row) when is_map(row) do
    %{
      uid: row_uid(row),
      ip: row_ip(row),
      hostname: row_hostname(row),
      metadata: row_metadata(row)
    }
  end

  defp row_to_device(_row), do: %{uid: nil, ip: "", hostname: nil, metadata: %{}}

  defp row_uid(row),
    do: stringify_id(first_present(row, ["uid", :uid, "id", :id, "device_uid", :device_uid]))

  defp row_ip(row), do: stringify_ip(first_present(row, ["ip", :ip]))

  defp row_hostname(row),
    do: stringify_hostname(first_present(row, ["hostname", :hostname, "name", :name]))

  defp row_metadata(row) do
    case first_present(row, ["metadata", :metadata]) do
      metadata when is_map(metadata) -> metadata
      _ -> %{}
    end
  end

  defp first_present(row, keys) do
    Enum.find_value(keys, fn key ->
      case Map.get(row, key) do
        value when is_binary(value) ->
          trimmed = String.trim(value)
          if trimmed == "", do: nil, else: trimmed

        value when not is_nil(value) ->
          value

        _ ->
          nil
      end
    end)
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

  defp stringify_ip(%Postgrex.INET{} = inet) do
    case Cidr.cast_stored(inet, []) do
      {:ok, value} when is_binary(value) -> host_address(value)
      _ -> ""
    end
  end

  defp stringify_ip(value) when is_binary(value), do: host_address(value)
  defp stringify_ip(_value), do: ""

  defp stringify_hostname(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp stringify_hostname(_value), do: nil

  defp stringify_id(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp stringify_id(_value), do: nil

  defp host_address(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.split("/", parts: 2)
    |> List.first()
    |> to_string()
  end

  defp device_ip(%{ip: ip}), do: stringify_ip(ip)
  defp device_ip(%{"ip" => ip}), do: stringify_ip(ip)
  defp device_ip(_), do: ""

  defp device_hostname(%{hostname: hostname}), do: stringify_hostname(hostname)
  defp device_hostname(%{"hostname" => hostname}), do: stringify_hostname(hostname)
  defp device_hostname(_), do: nil

  defp device_uid(%{uid: uid}), do: stringify_id(uid)
  defp device_uid(%{"uid" => uid}), do: stringify_id(uid)
  defp device_uid(_), do: nil

  defp device_metadata(%{metadata: metadata}) when is_map(metadata), do: metadata
  defp device_metadata(%{"metadata" => metadata}) when is_map(metadata), do: metadata
  defp device_metadata(_), do: %{}
end
