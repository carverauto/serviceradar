defmodule ServiceRadar.EventWriter.AnomalyEpisodeGuardTables do
  @moduledoc """
  Owns the node-local counters behind the anomaly episode rate guard and the
  ingest flood tripwire (`ServiceRadar.EventWriter.Processors.AnomalyEpisodeRegistry`).

  Both tables are `:public` so processors update them without a GenServer
  round-trip. This process only creates them, which ties their lifetime to a
  supervised process instead of whichever processor touched them first, and
  prunes buckets that can no longer be consulted: rate-guard counts are per
  finding per wall-clock hour and tripwire counts are per minute, so without
  pruning every finding and every minute left a row behind forever.

  Without this process the registry fails open: no rate limiting and no
  tripwire counting.
  """

  use GenServer

  @rate_guard_table :serviceradar_anomaly_episode_rate_guard
  @tripwire_table :serviceradar_anomaly_episode_tripwire
  @default_prune_interval_ms to_timeout(minute: 1)

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Table of `{{finding_uid, hour_bucket}, count}` rows."
  @spec rate_guard_table() :: atom()
  def rate_guard_table, do: @rate_guard_table

  @doc "Table of `{{:count, minute_bucket}, count}` and `{{:fired, minute_bucket}, true}` rows."
  @spec tripwire_table() :: atom()
  def tripwire_table, do: @tripwire_table

  @doc """
  Deletes every bucket older than the current one, as of `now_seconds` (Unix
  time). Returns the number of rows removed. Runs every minute on its own.
  """
  @spec prune(integer()) :: non_neg_integer()
  def prune(now_seconds \\ System.system_time(:second)) when is_integer(now_seconds) do
    delete_buckets_before(@rate_guard_table, div(now_seconds, 3600)) +
      delete_buckets_before(@tripwire_table, div(now_seconds, 60))
  end

  @doc "Number of rows currently held across both tables."
  @spec size() :: non_neg_integer()
  def size, do: table_size(@rate_guard_table) + table_size(@tripwire_table)

  @impl true
  def init(opts) do
    for table <- [@rate_guard_table, @tripwire_table] do
      :ets.new(table, [
        :set,
        :public,
        :named_table,
        read_concurrency: true,
        write_concurrency: true
      ])
    end

    interval = Keyword.get(opts, :prune_interval_ms, @default_prune_interval_ms)
    schedule_prune(interval)
    {:ok, %{interval: interval}}
  end

  @impl true
  def handle_info(:prune, %{interval: interval} = state) do
    prune()
    schedule_prune(interval)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # Both tables key every row as a 2-tuple whose second element is its bucket.
  defp delete_buckets_before(table, current_bucket) do
    :ets.select_delete(table, [{{{:_, :"$1"}, :_}, [{:<, :"$1", current_bucket}], [true]}])
  rescue
    ArgumentError -> 0
  end

  defp table_size(table) do
    case :ets.info(table, :size) do
      :undefined -> 0
      size -> size
    end
  end

  defp schedule_prune(interval),
    do: Process.send_after(self(), :prune, max(interval, to_timeout(second: 1)))
end
