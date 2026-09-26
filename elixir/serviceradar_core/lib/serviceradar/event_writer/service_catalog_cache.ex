defmodule ServiceRadar.EventWriter.ServiceCatalogCache do
  @moduledoc """
  Node-local seen-cache for the OTel service catalog upsert.

  Keyed by `{service_name, signal}`. A pair recorded here within the refresh
  interval (default 60s) is not written to `platform.otel_service_catalog`
  again, so catalog write volume is bounded by services x signals x nodes per
  interval rather than by telemetry volume.

  `ServiceRadar.EventWriter.ServiceCatalog` marks pairs only after its upsert
  succeeds, so a failed upsert is retried by the next batch.

  The table is `:public` so processors read and write it without a GenServer
  round-trip. The owning process only creates it and sweeps expired entries.
  Every call fails open: without the table (the cache is not running on this
  node), every pair counts as unseen and marking is a no-op.

  Configuration:

      config :serviceradar_core, ServiceRadar.EventWriter.ServiceCatalogCache,
        refresh_interval_ms: 60_000
  """

  use GenServer

  @table :serviceradar_event_writer_service_catalog_cache
  @default_refresh_interval_ms to_timeout(minute: 1)
  @interval_key :"$refresh_interval_ms"

  @type key :: {String.t(), atom()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "The default table name, used when no `:table` is given."
  @spec table() :: atom()
  def table, do: @table

  @doc """
  Returns the keys that are not fresh in the cache, in their given order.
  """
  @spec unseen(atom(), [key()]) :: [key()]
  def unseen(table \\ @table, keys) when is_list(keys) do
    now = now_ms()

    Enum.reject(keys, fn key ->
      case :ets.lookup(table, key) do
        [{^key, expires_at}] -> expires_at > now
        [] -> false
      end
    end)
  rescue
    ArgumentError -> keys
  end

  @doc """
  Records the keys as seen for one refresh interval.
  """
  @spec mark_seen(atom(), [key()]) :: :ok
  def mark_seen(table \\ @table, keys) when is_list(keys) do
    expires_at = now_ms() + refresh_interval_ms(table)
    :ets.insert(table, Enum.map(keys, &{&1, expires_at}))
    :ok
  rescue
    ArgumentError -> :ok
  end

  @impl true
  def init(opts) do
    table = Keyword.get(opts, :table, @table)

    interval =
      Keyword.get_lazy(opts, :refresh_interval_ms, fn ->
        :serviceradar_core
        |> Application.get_env(__MODULE__, [])
        |> Keyword.get(:refresh_interval_ms, @default_refresh_interval_ms)
      end)

    :ets.new(table, [
      :set,
      :public,
      :named_table,
      read_concurrency: true,
      write_concurrency: true
    ])

    :ets.insert(table, {@interval_key, interval})
    schedule_sweep(interval)

    {:ok, %{table: table, interval: interval}}
  end

  @impl true
  def handle_info(:sweep, %{table: table, interval: interval} = state) do
    now = now_ms()
    # Only `{key, expires_at}` pairs whose key is a 2-tuple; the interval entry is kept.
    :ets.select_delete(table, [{{{:_, :_}, :"$1"}, [{:<, :"$1", now}], [true]}])
    schedule_sweep(interval)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp refresh_interval_ms(table) do
    case :ets.lookup(table, @interval_key) do
      [{@interval_key, interval}] -> interval
      [] -> @default_refresh_interval_ms
    end
  end

  defp schedule_sweep(interval) do
    Process.send_after(self(), :sweep, max(interval, to_timeout(second: 1)))
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
