defmodule ServiceRadar.EventWriter.ServiceCatalog do
  @moduledoc """
  Best-effort maintenance of `platform.otel_service_catalog` from EventWriter.

  Processors call `record/3` after a logs, traces or metrics batch has been
  persisted. It:

  1. takes the distinct `service_name` values in the rows, dropping blank names,
     names longer than 255 characters and values Postgres cannot store as
     text (counted in `[:serviceradar, :event_writer, :service_catalog,
     :names_dropped]`);
  2. drops the `{service_name, signal}` pairs that
     `ServiceRadar.EventWriter.ServiceCatalogCache` saw within its refresh
     interval;
  3. upserts the rest in one statement per bind-parameter chunk. On conflict
     only the signal's column and `last_seen_at` move, each to the greater of
     the stored and new value, and a `WHERE` skips rows the write would not
     advance;
  4. marks the pairs in the cache only after the upsert succeeds, so a failed
     upsert is retried by the next batch.

  The telemetry is already durable when this runs, so a failure never reaches
  the batch: it is logged, emitted as
  `[:serviceradar, :event_writer, :service_catalog, :upsert_error]`, and
  returned as `{:error, reason}` for callers that care. It never raises.

  The catalog is control-plane inventory in CNPG in both telemetry modes; the
  Ash resource `ServiceRadar.Observability.OtelServiceCatalogEntry` owns its
  schema. This hot path writes with `Repo.insert_all/3` like the processors.
  """

  import Ecto.Query, only: [from: 2]

  alias ServiceRadar.EventWriter.BulkInsert
  alias ServiceRadar.EventWriter.ServiceCatalogCache

  require Logger

  @type signal :: :logs | :traces | :metrics

  @max_name_length 255
  @table "otel_service_catalog"
  @prefix "platform"
  @columns %{
    logs: :logs_last_seen_at,
    traces: :traces_last_seen_at,
    metrics: :metrics_last_seen_at
  }
  @dropped_event [:serviceradar, :event_writer, :service_catalog, :names_dropped]
  @upsert_error_event [:serviceradar, :event_writer, :service_catalog, :upsert_error]

  @doc "Longest service name the catalog stores, in characters."
  @spec max_name_length() :: pos_integer()
  def max_name_length, do: @max_name_length

  @doc """
  Records the services in `rows` as seen for `signal`.

  Options:

    * `:repo` - repo module for the write (default `ServiceRadar.Repo`)
    * `:cache` - seen-cache table (default `ServiceCatalogCache.table/0`)
    * `:now` - the last-seen timestamp to record (default now)

  Returns `{:ok, rows_written}`, or `{:error, reason}` after logging and
  emitting the upsert-error event.
  """
  @spec record(signal(), [map()], keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def record(signal, rows, opts \\ []) when is_map_key(@columns, signal) and is_list(rows) do
    cache = Keyword.get(opts, :cache, ServiceCatalogCache.table())

    pending =
      rows
      |> service_names(signal)
      |> Enum.map(&{&1, signal})
      |> then(&ServiceCatalogCache.unseen(cache, &1))

    case pending do
      [] ->
        {:ok, 0}

      pairs ->
        pairs
        |> Enum.map(&elem(&1, 0))
        |> upsert(signal, opts)
        |> tap(fn
          {:ok, _written} -> ServiceCatalogCache.mark_seen(cache, pairs)
          {:error, _reason} -> :ok
        end)
    end
  end

  defp service_names(rows, signal) do
    {names, dropped} =
      Enum.reduce(rows, {MapSet.new(), %{too_long: MapSet.new(), invalid: MapSet.new()}}, fn
        row, {names, dropped} ->
          case classify(service_name(row)) do
            {:ok, name} -> {MapSet.put(names, name), dropped}
            {:drop, reason, name} -> {names, Map.update!(dropped, reason, &MapSet.put(&1, name))}
            :skip -> {names, dropped}
          end
      end)

    Enum.each(dropped, fn {reason, dropped_names} ->
      if MapSet.size(dropped_names) > 0 do
        :telemetry.execute(@dropped_event, %{count: MapSet.size(dropped_names)}, %{
          signal: signal,
          reason: reason
        })
      end
    end)

    # Sorted so concurrent upserts from other nodes take row locks in one order.
    names |> MapSet.to_list() |> Enum.sort()
  end

  defp service_name(%{service_name: name}), do: name
  defp service_name(%{"service_name" => name}), do: name
  defp service_name(_row), do: nil

  defp classify(name) when is_binary(name) do
    cond do
      String.trim(name) == "" -> :skip
      not String.valid?(name) or String.contains?(name, <<0>>) -> {:drop, :invalid, name}
      String.length(name) > @max_name_length -> {:drop, :too_long, name}
      true -> {:ok, name}
    end
  end

  defp classify(_name), do: :skip

  defp upsert(names, signal, opts) do
    repo = Keyword.get(opts, :repo, ServiceRadar.Repo)
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    column = Map.fetch!(@columns, signal)

    entries =
      Enum.map(names, fn name ->
        %{
          :service_name => name,
          column => {:placeholder, :now},
          :last_seen_at => {:placeholder, :now}
        }
      end)

    {written, _} =
      BulkInsert.insert_all(repo, @table, entries,
        prefix: @prefix,
        placeholders: %{now: now},
        conflict_target: [:service_name],
        on_conflict: on_conflict(column),
        returning: false
      )

    {:ok, written}
  rescue
    error -> upsert_failed(signal, names, error)
  catch
    :exit, reason -> upsert_failed(signal, names, {:exit, reason})
  end

  # One conflict clause per signal column: only that column and `last_seen_at`
  # move, each to the greater of the stored and incoming value, and the WHERE
  # skips a row the write would not advance.
  for column <- Map.values(@columns) do
    defp on_conflict(unquote(column)) do
      from(c in @table,
        update: [
          set: [
            {unquote(column),
             fragment(unquote("GREATEST(?, EXCLUDED.#{column})"), field(c, unquote(column)))},
            {:last_seen_at, fragment("GREATEST(?, EXCLUDED.last_seen_at)", c.last_seen_at)}
          ]
        ],
        where:
          is_nil(field(c, unquote(column))) or
            field(c, unquote(column)) < fragment(unquote("EXCLUDED.#{column}"))
      )
    end
  end

  defp upsert_failed(signal, names, reason) do
    Logger.warning("OTel service catalog upsert failed; telemetry batch unaffected",
      signal: signal,
      services: length(names),
      reason: inspect(reason)
    )

    :telemetry.execute(@upsert_error_event, %{count: 1, services: length(names)}, %{
      signal: signal,
      reason: reason
    })

    {:error, reason}
  end
end
