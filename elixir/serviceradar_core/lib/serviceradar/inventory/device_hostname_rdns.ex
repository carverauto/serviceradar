defmodule ServiceRadar.Inventory.DeviceHostnameRdns do
  @moduledoc """
  Applies reverse-DNS hostnames onto `ocsf_devices` rows.

  The AshOban trigger on `DeviceHostnameRdnsSettings` calls `run/2`. Each run
  processes every eligible device in the operator's SRQL cohort. One database
  query pre-filters the fleet to devices that can be due (an IP, a missing or
  IP-shaped hostname unless overwriting, and outside the retry window), most
  recently seen first. The default all-devices query, any scope larger than
  that pre-filter, and a scope walk that ends on a full page without a cursor,
  are applied to those uids in chunks. A smaller scope is read in uid order,
  with the operator's sort removed, and intersected with the pre-filter, then
  processed in the pre-filter's order. `candidate?/4` still decides. Lookups
  are injected in tests so the job does not depend on a live resolver.
  """

  import Ash.Expr

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Ash.Page
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Observability.IpRdnsCache
  alias ServiceRadar.Observability.ReverseDns
  alias ServiceRadar.Observability.SRQLRunner
  alias ServiceRadar.Repo
  alias ServiceRadar.SRQLAst
  alias ServiceRadar.SRQLQuery
  alias ServiceRadar.Types.Cidr

  require Ash.Query
  require Logger

  @default_srql_query "in:devices sort:last_seen:desc"

  # SRQL list filters accept at most 200 values, so the operator scope is
  # checked against at most this many pre-filtered uids per query.
  @srql_uid_chunk 200

  # Same explicit page size `SrqlInputResolver` uses. SRQL's default limit is
  # 100, and a full page without a cursor stops inside the cursor window, so
  # either one would drop the rest of a scope the job has to process.
  @scope_page_limit 1_000

  # Pre-filters the fleet to devices that can be due for a lookup, most recently
  # seen first. It is a superset of `candidate?/4`, which still decides on the
  # SRQL rows, so every clause errs toward keeping a device:
  #
  # * the hostname clause keeps every hostname that could parse as an IP
  #   (`ReverseDns.missing_or_ip_hostname?/2`), and is skipped by `$1`
  #   (overwrite_existing);
  # * the retry clause excludes a device only when `rdns.looked_up_at` is a
  #   strict ISO 8601 timestamp after the cutoff `$2`; a missing or malformed
  #   value is kept, as `recently_looked_up?/3` treats it as never looked up.
  #   A NULL `$2` (ignore_retry?) disables it. The LATERAL extracts the value
  #   once per row instead of once per reference.
  #
  # Returned most recently seen first. The default all-devices query, and any
  # operator scope larger than this set, is checked against these uids in
  # `@srql_uid_chunk` chunks. A smaller scope is walked in uid order and the
  # intersection is processed in this order.
  @eligible_uids_sql ~S"""
  SELECT d.uid
  FROM platform.ocsf_devices AS d
  CROSS JOIN LATERAL (
    SELECT d.metadata #>> '{rdns,looked_up_at}' AS looked_up_at OFFSET 0
  ) AS r
  WHERE d.deleted_at IS NULL
    AND d.ip IS NOT NULL
    AND btrim(d.ip) <> ''
    AND (
      $1::boolean
      OR d.hostname IS NULL
      OR d.hostname ~ '^\s*[0-9A-Fa-fxX.:]*(%[^/]*)?(/.*)?\s*$'
      OR lower(btrim(d.hostname)) = lower(btrim(split_part(btrim(d.ip), '/', 1)))
    )
    AND (
      $2::timestamptz IS NULL
      OR CASE
        WHEN r.looked_up_at ~ '^\d{4}-\d{2}-\d{2}T([01]\d|2[0-3]):[0-5]\d:[0-5]\d(\.\d{1,6})?(Z|[+-]\d{2}:\d{2})$'
          AND r.looked_up_at !~ '-00:00$'
          AND pg_input_is_valid(r.looked_up_at, 'timestamptz')
        THEN r.looked_up_at::timestamptz <= $2::timestamptz
        ELSE true
      END
    )
  ORDER BY d.last_seen_time DESC, d.uid ASC
  """

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

    case Keyword.fetch(opts, :devices) do
      {:ok, devices} ->
        loaded = unwrap_devices(devices)
        count = length(loaded)

        loaded
        |> process_devices(
          actor,
          now,
          lookup,
          persist,
          timeout_ms,
          cache?,
          Map.merge(empty_stats(), %{cohort_rows: count, candidates: count, loaded: count})
        )
        |> finish_run()

      :error ->
        run_srql_cohort(settings, actor, now, lookup, persist, timeout_ms, cache?, opts)
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

  @spec candidate?(map(), map(), DateTime.t(), keyword()) :: boolean()
  def candidate?(device, settings, now \\ DateTime.utc_now(), opts \\ []) do
    ip = device_ip(device)
    overwrite? = Map.get(settings, :overwrite_existing) == true
    retry_after = retry_after_minutes(settings)
    ignore_retry? = Keyword.get(opts, :ignore_retry?, false)

    cond do
      ip == "" ->
        false

      not overwrite? and not ReverseDns.missing_or_ip_hostname?(device_hostname(device), ip) ->
        false

      not ignore_retry? and recently_looked_up?(device, now, retry_after) ->
        false

      true ->
        true
    end
  end

  defp run_srql_cohort(settings, actor, now, lookup, persist, timeout_ms, cache?, opts) do
    batch_size = max(Map.get(settings, :batch_size) || 200, 1)
    ignore_retry? = Keyword.get(opts, :ignore_retry?, false)
    query_page = query_page_fun(opts)
    load_devices = Keyword.get(opts, :load_devices, &load_devices_by_uid/2)
    eligible_uids = Keyword.get(opts, :eligible_uids, &eligible_uids/3)

    query =
      Map.get(settings, :srql_query) || Map.get(settings, "srql_query") || @default_srql_query

    with {:ok, normalized} <- normalize_device_query(query),
         {:ok, prefilter} <- eligible_uids.(settings, now, ignore_retry?) do
      context = %{
        actor: actor,
        batch_size: batch_size,
        cache?: cache?,
        ignore_retry?: ignore_retry?,
        load_devices: load_devices,
        lookup: lookup,
        now: now,
        persist: persist,
        query: normalized,
        query_page: query_page,
        settings: settings,
        timeout_ms: timeout_ms
      }

      case select_cohort(context, prefilter, Map.put(empty_stats(), :query, normalized)) do
        {:ok, stats} ->
          Logger.info("DeviceHostnameRdns: selected cohort",
            query: normalized,
            srql_rows: stats.cohort_rows,
            candidates: stats.candidates,
            loaded: stats.loaded,
            batch_size: batch_size
          )

          finish_run(stats)

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # The pre-filter is one query. Walking the operator's query is a page per
  # `@scope_page_limit` devices, so a run pays for the smaller side. The default
  # query is the whole fleet and is never the smaller side. An empty pre-filter
  # has nothing to process, so it does not page either.
  defp select_cohort(context, prefilter, stats) do
    if prefilter == [] or default_device_query?(context.query) do
      process_prefilter_chunks(context, prefilter, stats)
    else
      case scope_uids(context, length(prefilter)) do
        {:ok, :scope_larger} ->
          process_prefilter_chunks(context, prefilter, stats)

        {:ok, scope} ->
          process_intersection(
            context,
            Enum.filter(prefilter, &MapSet.member?(scope, &1)),
            stats
          )

        {:error, _} = error ->
          error
      end
    end
  end

  defp default_device_query?(query), do: query == @default_srql_query

  defp process_prefilter_chunks(context, uids, stats) do
    process_scoped_chunks(context, Enum.chunk_every(uids, @srql_uid_chunk), [], stats)
  end

  # Pages the operator query in uid order. Membership does not depend on the
  # operator's sort, so `sort:` and `order:` tokens are removed before
  # `sort:uid:asc` is the walk's only order. Each page carries an explicit
  # limit and the previous cursor. Once the scope has more devices than the
  # pre-filter, or a full page comes back without a cursor, the caller checks
  # the pre-filter in uid chunks instead.
  defp scope_uids(context, prefilter_count) do
    walk_scope(
      context.query_page,
      scope_membership_query(context.query),
      nil,
      MapSet.new(),
      prefilter_count
    )
  end

  defp scope_membership_query(query) do
    kept =
      query
      |> srql_tokens()
      |> Enum.reject(&order_token?/1)

    Enum.join(kept, " ") <> " sort:uid:asc"
  end

  defp order_token?(token) do
    key =
      token
      |> String.split(":", parts: 2)
      |> hd()
      |> String.trim()
      |> String.downcase()

    key in ["sort", "order"]
  end

  defp srql_tokens(query) do
    query
    |> split_srql_tokens([], [], nil, 0, false)
    |> Enum.reverse()
  end

  defp split_srql_tokens(<<>>, tokens, current, _quoted, _depth, _escape) do
    push_srql_token(tokens, current)
  end

  defp split_srql_tokens(<<ch::utf8, rest::binary>>, tokens, current, quoted, depth, true) do
    split_srql_tokens(rest, tokens, [<<ch::utf8>> | current], quoted, depth, false)
  end

  defp split_srql_tokens(<<ch::utf8, rest::binary>>, tokens, current, quoted, depth, false)
       when quoted != nil do
    cond do
      ch == ?\\ ->
        split_srql_tokens(rest, tokens, [<<ch::utf8>> | current], quoted, depth, true)

      ch == quoted ->
        split_srql_tokens(rest, tokens, [<<ch::utf8>> | current], nil, depth, false)

      true ->
        split_srql_tokens(rest, tokens, [<<ch::utf8>> | current], quoted, depth, false)
    end
  end

  defp split_srql_tokens(<<ch::utf8, rest::binary>>, tokens, current, nil, depth, false)
       when ch in [?", ?', ?`] do
    split_srql_tokens(rest, tokens, [<<ch::utf8>> | current], ch, depth, false)
  end

  defp split_srql_tokens(<<ch::utf8, rest::binary>>, tokens, current, nil, depth, false)
       when ch in [?(, ?[] do
    split_srql_tokens(rest, tokens, [<<ch::utf8>> | current], nil, depth + 1, false)
  end

  defp split_srql_tokens(<<ch::utf8, rest::binary>>, tokens, current, nil, depth, false)
       when ch in [?), ?]] do
    split_srql_tokens(rest, tokens, [<<ch::utf8>> | current], nil, max(depth - 1, 0), false)
  end

  defp split_srql_tokens(<<ch::utf8, rest::binary>>, tokens, current, nil, 0, false) do
    if whitespace?(ch) do
      split_srql_tokens(rest, push_srql_token(tokens, current), [], nil, 0, false)
    else
      split_srql_tokens(rest, tokens, [<<ch::utf8>> | current], nil, 0, false)
    end
  end

  defp split_srql_tokens(<<ch::utf8, rest::binary>>, tokens, current, nil, depth, false) do
    split_srql_tokens(rest, tokens, [<<ch::utf8>> | current], nil, depth, false)
  end

  defp push_srql_token(tokens, []), do: tokens

  defp push_srql_token(tokens, current) do
    token = current |> Enum.reverse() |> IO.iodata_to_binary() |> String.trim()
    if token == "", do: tokens, else: [token | tokens]
  end

  defp whitespace?(ch), do: <<ch::utf8>> != String.trim(<<ch::utf8>>)

  defp walk_scope(query_page, query, cursor, seen, prefilter_count) do
    opts = [limit: @scope_page_limit]
    opts = if is_binary(cursor), do: Keyword.put(opts, :cursor, cursor), else: opts

    with {:ok, page} <- query_scope_page(query_page, query, opts),
         {:ok, rows} <- page_rows(page) do
      seen = Enum.reduce(rows, seen, &put_scope_uid/2)

      if MapSet.size(seen) > prefilter_count do
        {:ok, :scope_larger}
      else
        case next_page_cursor(page) do
          next when is_binary(next) ->
            walk_scope(query_page, query, next, seen, prefilter_count)

          _no_cursor when length(rows) >= @scope_page_limit ->
            {:ok, :scope_larger}

          _last_page ->
            {:ok, seen}
        end
      end
    end
  end

  defp query_scope_page(query_page, query, opts) do
    case query_page.(query, opts) do
      {:ok, page} -> {:ok, page}
      {:error, reason} -> {:error, {:srql_query_failed, reason}}
      other -> {:error, {:srql_query_failed, other}}
    end
  end

  defp page_rows(%{rows: rows}) when is_list(rows), do: {:ok, rows}
  defp page_rows(rows) when is_list(rows), do: {:ok, rows}
  defp page_rows(other), do: {:error, {:srql_query_failed, other}}

  defp put_scope_uid(row, seen) do
    case row_uid(row) do
      nil -> seen
      uid -> MapSet.put(seen, uid)
    end
  end

  defp next_page_cursor(%{next_cursor: cursor}) when is_binary(cursor) and cursor != "",
    do: cursor

  defp next_page_cursor(_page), do: nil

  # The scope walk already applied the operator query. Load these uids in the
  # pre-filter's order and let candidate?/4 drop anything the pre-filter kept
  # in excess of a device it would actually look up.
  defp process_intersection(context, uids, stats) do
    stats = Map.update!(stats, :cohort_rows, &(&1 + length(uids)))

    uids
    |> Stream.chunk_every(context.batch_size)
    |> Enum.reduce_while({:ok, stats}, fn batch, {:ok, acc} ->
      case context.load_devices.(Enum.map(batch, &%{uid: &1}), context.actor) do
        {:ok, devices} when is_list(devices) ->
          candidates =
            Enum.filter(
              devices,
              &candidate?(&1, context.settings, context.now, ignore_retry?: context.ignore_retry?)
            )

          next =
            process_devices(
              candidates,
              context.actor,
              context.now,
              context.lookup,
              context.persist,
              context.timeout_ms,
              context.cache?,
              acc
              |> Map.update!(:candidates, &(&1 + length(candidates)))
              |> Map.update!(:loaded, &(&1 + length(candidates)))
            )

          {:cont, {:ok, next}}

        {:error, reason} ->
          {:halt, {:error, reason}}

        other ->
          {:halt, {:error, {:device_load_failed, other}}}
      end
    end)
  end

  defp process_candidate_batches(
         candidates,
         batch_size,
         load_devices,
         actor,
         now,
         lookup,
         persist,
         timeout_ms,
         cache?,
         stats
       ) do
    candidates
    |> Stream.chunk_every(batch_size)
    |> Enum.reduce_while({:ok, stats}, fn batch, {:ok, acc} ->
      case load_devices.(batch, actor) do
        {:ok, devices} when is_list(devices) ->
          next_acc =
            process_devices(
              devices,
              actor,
              now,
              lookup,
              persist,
              timeout_ms,
              cache?,
              Map.update!(acc, :loaded, &(&1 + length(devices)))
            )

          {:cont, {:ok, next_acc}}

        {:error, reason} ->
          {:halt, {:error, reason}}

        other ->
          {:halt, {:error, {:device_load_failed, other}}}
      end
    end)
  end

  defp process_devices(devices, actor, now, lookup, persist, timeout_ms, cache?, stats) do
    Enum.reduce(devices, stats, fn device, acc ->
      apply_device(device, actor, now, lookup, persist, timeout_ms, cache?, acc)
    end)
  end

  defp finish_run(stats) do
    Logger.info("DeviceHostnameRdns: finished run",
      query: Map.get(stats, :query),
      cohort_rows: stats.cohort_rows,
      candidates: stats.candidates,
      loaded: stats.loaded,
      looked_up: stats.looked_up,
      updated: stats.updated,
      skipped: stats.skipped,
      errors: stats.errors
    )

    {:ok, Map.delete(stats, :query)}
  end

  defp query_page_fun(opts) do
    Keyword.get(opts, :query_page, &default_query_page/2)
  end

  defp default_query_page(query, opts) do
    SRQLRunner.query_page(query, Keyword.merge([direction: "next"], opts))
  end

  # One SRQL query per chunk of pre-filtered uids, each restricted to the chunk
  # with `uid:(...)`, so the operator's query still decides the scope while the
  # database only ever sorts the chunk.
  defp process_scoped_chunks(context, [], pending_candidates, stats) do
    process_candidate_batches(
      pending_candidates,
      context.batch_size,
      context.load_devices,
      context.actor,
      context.now,
      context.lookup,
      context.persist,
      context.timeout_ms,
      context.cache?,
      stats
    )
  end

  defp process_scoped_chunks(context, [chunk | chunks], pending_candidates, stats) do
    with {:ok, rows} <- query_scoped_chunk(context, chunk),
         {:ok, remaining_candidates, stats} <-
           absorb_scoped_rows(context, chunk, rows, pending_candidates, stats) do
      process_scoped_chunks(context, chunks, remaining_candidates, stats)
    end
  end

  defp absorb_scoped_rows(context, chunk, rows, pending_candidates, stats) do
    rows_by_uid = Map.new(rows, &{row_uid(&1), &1})

    # Keep the pre-filter's order (most recently seen first); the operator's
    # sort only ever orders this chunk.
    chunk_candidates =
      chunk
      |> Enum.flat_map(fn uid ->
        case Map.fetch(rows_by_uid, uid) do
          {:ok, row} -> [row_to_device(row)]
          :error -> []
        end
      end)
      |> Enum.filter(
        &candidate?(&1, context.settings, context.now, ignore_retry?: context.ignore_retry?)
      )

    stats =
      stats
      |> Map.update!(:cohort_rows, &(&1 + length(rows)))
      |> Map.update!(:candidates, &(&1 + length(chunk_candidates)))

    {ready_candidates, remaining_candidates} =
      split_complete_batches(pending_candidates ++ chunk_candidates, context.batch_size)

    case process_candidate_batches(
           ready_candidates,
           context.batch_size,
           context.load_devices,
           context.actor,
           context.now,
           context.lookup,
           context.persist,
           context.timeout_ms,
           context.cache?,
           stats
         ) do
      {:ok, stats} -> {:ok, remaining_candidates, stats}
      {:error, reason} -> {:error, reason}
    end
  end

  defp query_scoped_chunk(context, uids) do
    list = Enum.map_join(uids, ",", &quote_srql_string/1)

    case context.query_page.("#{context.query} uid:(#{list})", limit: @srql_uid_chunk) do
      {:ok, %{rows: rows}} when is_list(rows) -> {:ok, rows}
      {:ok, rows} when is_list(rows) -> {:ok, rows}
      {:error, reason} -> {:error, {:srql_query_failed, reason}}
      other -> {:error, {:srql_query_failed, other}}
    end
  end

  defp quote_srql_string(value) do
    escaped =
      value
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")

    "\"#{escaped}\""
  end

  @doc """
  Uids the pre-filter keeps for `settings`, most recently seen first.

  The pre-filter is a superset of `candidate?/4`, which still decides.
  """
  @spec eligible_device_uids(map(), DateTime.t(), keyword()) ::
          {:ok, [String.t()]} | {:error, term()}
  def eligible_device_uids(settings, now \\ DateTime.utc_now(), opts \\ [])
      when is_map(settings) do
    eligible_uids(settings, now, Keyword.get(opts, :ignore_retry?, false))
  end

  defp eligible_uids(settings, now, ignore_retry?) do
    overwrite? = Map.get(settings, :overwrite_existing) == true

    cutoff =
      if ignore_retry?,
        do: nil,
        else: DateTime.shift(now, minute: -retry_after_minutes(settings))

    case Repo.query(@eligible_uids_sql, [overwrite?, cutoff]) do
      {:ok, %Postgrex.Result{rows: rows}} -> {:ok, Enum.map(rows, fn [uid] -> uid end)}
      {:error, reason} -> {:error, {:eligible_devices_query_failed, reason}}
    end
  end

  defp retry_after_minutes(settings), do: Map.get(settings, :retry_after_minutes) || 1_440

  defp split_complete_batches(candidates, batch_size) do
    complete_count = div(length(candidates), batch_size) * batch_size
    Enum.split(candidates, complete_count)
  end

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
      |> Ash.read(actor: actor, page: [limit: max(length(uids), 1)])
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
    patch = rdns_metadata_patch(hostname, status, error, now)

    if status == "ok" and ReverseDns.usable_hostname?(hostname, device_ip(device)) do
      {:update, %{hostname: hostname, metadata_patch: patch}}
    else
      {:skip, %{metadata_patch: patch}}
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

  # Two writes on purpose. The metadata patch merges in the database so it cannot
  # clobber another writer's keys; hostname is a scalar column this module owns,
  # so writing it directly touches nothing else.
  defp maybe_update_hostname(device, attrs, _actor) when map_size(attrs) == 0, do: {:ok, device}

  defp maybe_update_hostname(device, attrs, actor) do
    device
    |> Ash.Changeset.for_update(:update, attrs)
    |> Ash.update(actor: actor)
  end

  defp update_device(device, attrs, actor) do
    {patch, attrs} = Map.pop(attrs, :metadata_patch)

    device
    |> Ash.Changeset.for_update(:merge_metadata, %{metadata_patch: patch || %{}})
    |> Ash.update(actor: actor)
    |> case do
      {:ok, updated} -> maybe_update_hostname(updated, attrs, actor)
      error -> error
    end
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
      expires_at: DateTime.shift(now, day: 1),
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

  # Only the one key this module owns. It used to return the device's whole
  # metadata map with "rdns" put into it, which meant every rDNS write carried a
  # snapshot of every OTHER writer's keys back to the database and clobbered
  # anything committed since the read.
  defp rdns_metadata_patch(hostname, status, error, now) do
    %{
      "rdns" => %{
        "looked_up_at" => DateTime.to_iso8601(now),
        "status" => status,
        "hostname" => hostname,
        "error" => error
      }
    }
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
