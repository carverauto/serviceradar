defmodule ServiceRadar.Analytics.StarRocks.Destination do
  @moduledoc """
  EventWriter destination seam for opt-in StarRocks shadow writes.

  CNPG remains the serving authority while shadowing. Each destination is
  tracked independently: a partial success retries only the missing destination
  with the same stable identities. Shadow failure does not fail JetStream ACK
  until the dataset is listed in `cutover_datasets`; then Stream Load Success
  or durable quarantine is required before ACK.

  MTR traces and hops (`:mtr_traces`, `:mtr_hops`) are not shadowed: while
  StarRocks is enabled they are written to the warehouse only, through
  `persist_warehouse/3`, and a failed load fails the ACK.

  ## Load sizing

  One call is one EventWriter batch. Its rows are encoded once and split into
  Stream Loads of at most `stream_load[:max_rows]` rows and
  `stream_load[:max_bytes]` encoded bytes, run at most
  `stream_load[:max_in_flight]` at a time. Every load must succeed before the
  call does, so the batch keeps a single ACK decision. A batch within both
  limits is one load, labelled exactly as before; a split load's label is still
  derived from its own rows (or suffixed from a caller-supplied label), so a
  retry of the same batch reuses the same labels. The tables are primary-key
  tables, so a retry that regroups rows into different loads upserts rather
  than duplicates.

  ## Replacing rows by id

  The warehouse keys `events` on `(id, time)`. A producer that keeps one row per
  id and moves its time forward -- Trivy, which replaces a report's event on
  every rescan -- passes `replace: %{ids: ids, log_provider: provider}`: before
  loading, the rows with those ids and that `log_provider` are deleted, as the
  producer deletes them from CNPG. The delete runs only when the load does, and
  a failed delete fails the call without loading, so a redelivery repeats both.
  Callers serialise concurrent replaces of the same ids themselves.
  """

  alias ServiceRadar.Analytics.StarRocks
  alias ServiceRadar.Analytics.StarRocks.Attribution
  alias ServiceRadar.Analytics.StarRocks.Env
  alias ServiceRadar.Analytics.StarRocks.MySQL
  alias ServiceRadar.Analytics.StarRocks.Readers
  alias ServiceRadar.Analytics.StarRocks.Rows
  alias ServiceRadar.Analytics.StarRocks.Schema
  alias ServiceRadar.Analytics.StarRocks.StreamLoad

  require Logger

  @type dataset ::
          :flows | :flow_attribution | :metrics | :logs | :events | :mtr_traces | :mtr_hops
  @type dest :: :cnpg | :starrocks

  @tables %{
    flows: "ocsf_network_activity",
    flow_attribution: "ocsf_network_activity",
    metrics: "timeseries_metrics",
    logs: "logs",
    events: "events",
    mtr_traces: "mtr_traces",
    mtr_hops: "mtr_hops"
  }

  @spec table_for(dataset()) :: String.t()
  def table_for(dataset) when is_map_key(@tables, dataset), do: Map.fetch!(@tables, dataset)

  @doc """
  Whether StarRocks is the active telemetry backend (`analytics.starrocks.enabled`).

  Delegates to `Readers.enabled?/0` so the write side and the read side can
  never disagree about which backend is active.
  """
  @spec enabled?() :: boolean()
  defdelegate enabled?, to: Readers

  @doc """
  Loads rows into the warehouse only, for a dataset whose rows are written to
  the warehouse instead of CNPG while StarRocks is enabled.

  Stream Load Success or quarantine is `{:ok, _}`; anything else is
  `{:error, _}`, so the caller fails its JetStream acknowledgement and the
  message is redelivered. There is no CNPG fallback.
  """
  @spec persist_warehouse(dataset(), [map()], keyword()) :: {:ok, map()} | {:error, term()}
  def persist_warehouse(dataset, rows, opts \\ [])

  def persist_warehouse(dataset, [], _opts), do: {:ok, %{dataset: dataset, loaded: 0}}

  def persist_warehouse(dataset, rows, opts) when is_list(rows) do
    encoded = Rows.encode(dataset, rows)

    case persist_starrocks(dataset, encoded, MapSet.new(), opts) do
      {:ok, result} when is_map(result) ->
        {:ok, Map.merge(%{dataset: dataset, loaded: length(encoded)}, result)}

      {:error, reason} ->
        {:error, {:warehouse_load, dataset, reason}}

      other ->
        {:error, {:warehouse_load, dataset, other}}
    end
  end

  @spec maybe_shadow(dataset(), [map()], keyword()) ::
          {:ok, map()} | {:ok, :disabled} | {:error, term()}
  def maybe_shadow(dataset, rows, opts \\ [])

  def maybe_shadow(_dataset, [], _opts), do: {:ok, :disabled}

  def maybe_shadow(dataset, rows, opts) when is_list(rows) do
    if shadow_enabled?(dataset, opts) do
      persist_shadow(dataset, rows, opts)
    else
      {:ok, :disabled}
    end
  rescue
    error ->
      Logger.error("StarRocks shadow persist crashed",
        dataset: dataset,
        error: Exception.message(error)
      )

      {:error, error}
  end

  @doc """
  After a CNPG insert, persist to StarRocks.

  When `Readers.mode_for/1` is `starrocks`, Stream Load Success or durable
  quarantine is required and a failure fails the EventWriter ACK. Otherwise
  shadow writes stay best-effort.
  """
  @spec persist_after_cnpg(dataset(), [map()], keyword()) ::
          {:ok, map()} | {:ok, :disabled} | {:error, term()}
  def persist_after_cnpg(dataset, rows, opts \\ [])

  def persist_after_cnpg(_dataset, [], _opts), do: {:ok, :disabled}

  def persist_after_cnpg(dataset, rows, opts) when is_list(rows) do
    if Readers.mode_for(dataset) == "starrocks" do
      persist_shadow(
        dataset,
        rows,
        opts
        |> Keyword.put(:completed, [:cnpg])
        |> Keyword.put(:require_all, true)
      )
    else
      case maybe_shadow(dataset, rows, opts) do
        {:error, reason} ->
          Logger.warning("StarRocks shadow persist failed",
            dataset: dataset,
            error: inspect(reason)
          )

          {:ok, :disabled}

        other ->
          other
      end
    end
  end

  @doc """
  Insert into CNPG then apply `persist_after_cnpg/3`. The insert function is
  the processor's existing CNPG writer.
  """
  @spec ack_cnpg_batch(
          dataset(),
          [map()],
          ([map()] -> {:ok, non_neg_integer()} | {:error, term()}),
          keyword()
        ) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def ack_cnpg_batch(dataset, rows, insert_fun, opts \\ []) when is_function(insert_fun, 1) do
    with {:ok, count} <- insert_fun.(rows) do
      case persist_after_cnpg(dataset, rows, opts) do
        {:ok, _} -> {:ok, count}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  Persist to every destination not already listed in `:completed`.

  `completed` is a list of `:cnpg` and/or `:starrocks`. A retry after CNPG
  succeeded therefore loads StarRocks only.
  """
  @spec persist_shadow(dataset(), [map()], keyword()) :: {:ok, map()} | {:error, term()}
  def persist_shadow(dataset, rows, opts \\ []) when is_list(rows) do
    completed = MapSet.new(Keyword.get(opts, :completed, []))
    encoded = Rows.encode(dataset, rows)

    starrocks_result = persist_starrocks(dataset, encoded, completed, opts)

    progress = %{
      dataset: dataset,
      completed: completed_dests(starrocks_result, completed),
      missing: missing_dests(starrocks_result, completed)
    }

    cond do
      progress.missing == [] ->
        {:ok, Map.put(progress, :loaded, length(encoded))}

      Keyword.get(opts, :require_all, false) ->
        {:error, {:missing_destinations, progress}}

      true ->
        {:ok, Map.put(progress, :partial, true)}
    end
  end

  defp persist_starrocks(dataset, encoded, completed, opts) do
    if MapSet.member?(completed, :starrocks) do
      :already
    else
      table = table_for(dataset)
      persist = Keyword.get(opts, :persist, &StreamLoad.persist/3)
      limits = stream_load_limits(opts)

      persist_opts =
        opts
        |> Keyword.take([:http, :label, :config, :partial_update, :columns])
        |> Keyword.put_new(:config, client_config())
        |> attribution_load_opts(dataset)

      chunks = split_loads(encoded, limits)
      emit_batch_telemetry(dataset, table, chunks)

      with :ok <- replace_ids(dataset, table, persist_opts[:config], opts) do
        case chunks do
          [{rows, body, _bytes}] ->
            load_chunk(persist, dataset, table, rows, Keyword.put(persist_opts, :body, body))

          chunks ->
            load_chunks(persist, dataset, table, chunks, persist_opts, limits[:max_in_flight])
        end
      end
    end
  end

  @replace_chunk 500
  @provider_pattern ~r/^[a-z0-9_.-]+$/

  defp replace_ids(dataset, table, config, opts) do
    case Keyword.get(opts, :replace) do
      nil ->
        :ok

      %{ids: ids, log_provider: provider} when dataset == :events ->
        delete = Keyword.get(opts, :delete, &MySQL.query/1)

        with {:ok, database} <- replace_database(config),
             {:ok, provider} <- replace_provider(provider),
             {:ok, ids} <- canonical_ids(ids) do
          ids
          |> Enum.chunk_every(@replace_chunk)
          |> Enum.reduce_while(:ok, fn chunk, :ok ->
            sql =
              "DELETE FROM #{database}.#{table} WHERE log_provider = '#{provider}' " <>
                "AND id IN (#{Enum.map_join(chunk, ", ", &"'#{&1}'")})"

            case delete.(sql) do
              {:ok, _result} -> {:cont, :ok}
              {:error, reason} -> {:halt, {:error, {:replace_failed, reason}}}
            end
          end)
        end

      other ->
        raise ArgumentError, "unsupported replace for #{inspect(dataset)}: #{inspect(other)}"
    end
  end

  defp replace_database(%{database: database}) when is_binary(database) do
    if Schema.valid_database?(database),
      do: {:ok, database},
      else: {:error, {:invalid_database, database}}
  end

  defp replace_database(_config), do: {:error, :no_database}

  defp replace_provider(provider) when is_binary(provider) do
    if Regex.match?(@provider_pattern, provider),
      do: {:ok, provider},
      else: {:error, {:invalid_log_provider, provider}}
  end

  defp replace_provider(provider), do: {:error, {:invalid_log_provider, provider}}

  # Ids are interpolated into SQL text (the FE client speaks the text protocol),
  # so each is re-rendered from a cast UUID and nothing else reaches the query.
  defp canonical_ids(ids) do
    ids
    |> Enum.reduce_while({:ok, []}, fn id, {:ok, acc} ->
      case Ecto.UUID.cast(id) do
        {:ok, uuid} -> {:cont, {:ok, [uuid | acc]}}
        :error -> {:halt, {:error, {:invalid_replace_id, id}}}
      end
    end)
    |> case do
      {:ok, uuids} -> {:ok, uuids |> Enum.reverse() |> Enum.uniq()}
      error -> error
    end
  end

  defp load_chunk(persist, dataset, table, rows, persist_opts) do
    case persist.(table, rows, persist_opts) do
      {:quarantine, reason} when dataset == :flow_attribution ->
        {:error, reason}

      {:quarantine, reason} ->
        report_quarantine(dataset, table, reason)
        {:ok, %{quarantine: true, reason: reason}}

      other ->
        other
    end
  end

  defp load_chunks(persist, dataset, table, chunks, persist_opts, max_in_flight) do
    count = length(chunks)

    load = fn {{rows, body, _bytes}, index} ->
      opts =
        persist_opts
        |> Keyword.put(:body, body)
        |> chunk_label(index)

      load_chunk(persist, dataset, table, rows, opts)
    end

    indexed = Enum.with_index(chunks)

    results =
      if max_in_flight <= 1 do
        Enum.map(indexed, load)
      else
        indexed
        |> Task.async_stream(load,
          max_concurrency: max_in_flight,
          ordered: true,
          timeout: :infinity
        )
        |> Enum.map(fn
          {:ok, result} -> result
          {:exit, reason} -> {:error, {:load_exit, reason}}
        end)
      end

    case Enum.find(results, &(not match?({:ok, _}, &1))) do
      nil ->
        loaded =
          results |> Enum.map(fn {:ok, result} -> Map.get(result, :loaded, 0) end) |> Enum.sum()

        quarantined? =
          Enum.any?(results, fn {:ok, result} -> Map.get(result, :quarantine, false) end)

        {:ok, %{loaded: loaded, loads: count, quarantine: quarantined?}}

      failure ->
        failure
    end
  end

  # A caller-supplied label names the whole batch; each load of a split batch
  # needs its own, or the second would be reconciled against the first.
  defp chunk_label(opts, index) do
    case Keyword.fetch(opts, :label) do
      {:ok, label} when is_binary(label) -> Keyword.put(opts, :label, "#{label}-#{index}")
      _ -> opts
    end
  end

  @doc false
  # Splits rows into loads of at most `max_rows` rows and `max_bytes` encoded
  # bytes. Each load carries its rows, its JSON array body and the body size.
  # A single row larger than `max_bytes` still loads on its own: refusing it
  # would wedge the batch on redelivery forever.
  def split_loads([], _limits), do: []

  def split_loads(rows, limits) do
    max_rows = limits[:max_rows]
    max_bytes = limits[:max_bytes]

    rows
    |> Enum.map(fn row ->
      json = Jason.encode_to_iodata!(row)
      {row, json, IO.iodata_length(json)}
    end)
    |> Enum.chunk_while(
      {[], [], 0, 0},
      fn {row, json, size}, {chunk_rows, chunk_json, count, bytes} = acc ->
        # 2 bytes for the array brackets, 1 per separating comma.
        next_bytes = bytes + size + if(count == 0, do: 2, else: 1)

        if count > 0 and (count >= max_rows or next_bytes > max_bytes) do
          {:cont, finish_load(acc), {[row], [json], 1, size + 2}}
        else
          {:cont, {[row | chunk_rows], [json | chunk_json], count + 1, next_bytes}}
        end
      end,
      fn
        {_, _, 0, _} -> {:cont, []}
        acc -> {:cont, finish_load(acc), []}
      end
    )
  end

  defp finish_load({chunk_rows, chunk_json, _count, bytes}) do
    body = IO.iodata_to_binary(["[", chunk_json |> Enum.reverse() |> Enum.intersperse(","), "]"])
    {Enum.reverse(chunk_rows), body, bytes}
  end

  defp emit_batch_telemetry(dataset, table, chunks) do
    :telemetry.execute(
      [:serviceradar, :starrocks, :stream_load, :batch],
      %{
        rows: chunks |> Enum.map(fn {rows, _body, _bytes} -> length(rows) end) |> Enum.sum(),
        bytes: chunks |> Enum.map(fn {_rows, _body, bytes} -> bytes end) |> Enum.sum(),
        loads: length(chunks)
      },
      %{dataset: dataset, table: table}
    )
  end

  @doc """
  Stream Load sizing limits: `opts[:stream_load]`, else the runtime
  `stream_load` config, else `Env.default_stream_load/0`.
  """
  @spec stream_load_limits(keyword()) :: keyword(pos_integer())
  def stream_load_limits(opts \\ []) do
    configured =
      Keyword.get_lazy(opts, :stream_load, fn ->
        :serviceradar_core
        |> Application.get_env(StarRocks, [])
        |> Keyword.get(:stream_load, [])
      end)

    Keyword.merge(Env.default_stream_load(), configured || [])
  end

  @doc """
  StarRocks FE connection config for Stream Load calls.
  """
  @spec client_config() :: %{
          fe_http: String.t(),
          database: String.t(),
          user: String.t(),
          password: String.t()
        }
  def client_config do
    env = Application.get_env(:serviceradar_core, StarRocks, [])

    %{
      fe_http: Keyword.get(env, :fe_http, "http://127.0.0.1:8030"),
      database: Keyword.get(env, :database, "serviceradar"),
      user: Keyword.get(env, :user, "root"),
      password: Keyword.get(env, :password, "")
    }
  end

  defp report_quarantine(dataset, table, reason) do
    rows =
      case reason do
        {:filtered_rows, count, _label} when is_integer(count) -> count
        _ -> 0
      end

    Logger.warning("StarRocks Stream Load quarantined rows",
      dataset: dataset,
      table: table,
      rows: rows,
      reason: inspect(reason)
    )

    :telemetry.execute(
      [:serviceradar, :starrocks, :stream_load, :quarantine],
      %{rows: rows},
      %{dataset: dataset, table: table, reason: reason}
    )
  end

  defp completed_dests(starrocks_result, completed) do
    completed
    |> maybe_put(:starrocks, starrocks_result)
    |> MapSet.to_list()
    |> Enum.sort()
  end

  defp missing_dests(starrocks_result, completed) do
    []
    |> maybe_missing(:starrocks, starrocks_result, completed)
    |> Enum.sort()
  end

  defp maybe_put(completed, dest, :already), do: MapSet.put(completed, dest)
  defp maybe_put(completed, dest, {:ok, _}), do: MapSet.put(completed, dest)
  defp maybe_put(completed, _dest, _), do: completed

  defp maybe_missing(missing, dest, result, completed) do
    cond do
      MapSet.member?(completed, dest) -> missing
      match?({:ok, _}, result) -> missing
      result == :already -> missing
      true -> [dest | missing]
    end
  end

  defp attribution_load_opts(opts, :flow_attribution) do
    opts
    |> Keyword.put(:partial_update, true)
    |> Keyword.put(:merge_condition, "attribution_version")
    |> Keyword.put(:columns, Attribution.load_columns())
  end

  defp attribution_load_opts(opts, :flows) do
    Keyword.put(opts, :merge_condition, "attribution_version")
  end

  defp attribution_load_opts(opts, _dataset), do: opts

  defp shadow_enabled?(dataset, opts) do
    enabled = enabled_datasets(opts)
    dataset in enabled or (dataset == :flow_attribution and :flows in enabled)
  end

  defp enabled_datasets(opts) do
    case Keyword.fetch(opts, :enabled) do
      {:ok, true} -> [:flows, :flow_attribution, :metrics, :logs, :events]
      {:ok, :all} -> [:flows, :flow_attribution, :metrics, :logs, :events]
      {:ok, value} when is_list(value) -> value
      :error -> configured_shadow_datasets()
      {:ok, _} -> []
    end
  end

  defp configured_shadow_datasets do
    env = Application.get_env(:serviceradar_core, StarRocks, [])

    case Keyword.get(env, :shadow_datasets, []) do
      [] ->
        if Keyword.get(env, :enabled, false) do
          [:flows, :flow_attribution, :metrics, :logs, :events]
        else
          []
        end

      datasets ->
        datasets
    end
  end
end
