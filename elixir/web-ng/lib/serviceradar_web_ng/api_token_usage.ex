defmodule ServiceRadarWebNG.ApiTokenUsage do
  @moduledoc """
  Coalesces API token usage into at most one database write per token per
  flush interval (one minute by default).

  `ServiceRadarWebNGWeb.Plugs.ApiAuth` used to start an unsupervised task per
  token-authenticated request, each running its own `UPDATE` of the token row:
  a burst of requests became that many concurrent updates of one row, and a
  failed write vanished silently.

  `record/2` runs in the request process and only touches a public ETS table,
  counting uses and keeping the latest client IP per token. This process owns
  the table and, on every flush, writes each token once with the use count it
  accumulated (`ApiToken` `:record_use` with `uses: n`, so `use_count` stays
  exact). Writes run under a `Task.Supervisor` with bounded concurrency and a
  per-write timeout; failures are logged. Pending usage is flushed on shutdown.

  Without this process running, usage is not recorded and requests are
  unaffected.
  """

  use GenServer

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Identity.ApiToken

  require Logger

  @table __MODULE__
  @default_flush_interval_ms to_timeout(minute: 1)
  @default_task_supervisor ServiceRadarWebNG.TaskSupervisor
  @max_concurrent_writes 4
  @write_timeout_ms to_timeout(second: 15)

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Counts one use of `api_token` from `client_ip`, to be written at the next flush."
  @spec record(map(), String.t() | nil) :: :ok | :unavailable
  def record(%{id: id} = api_token, client_ip) do
    :ets.update_counter(@table, id, {4, 1}, {id, api_token, client_ip, 0})
    :ets.update_element(@table, id, {3, client_ip})
    :ok
  rescue
    ArgumentError -> :unavailable
  end

  @doc "Writes all usage recorded so far and returns once those writes have finished."
  @spec flush() :: :ok
  def flush do
    GenServer.call(__MODULE__, :flush, @write_timeout_ms * 2)
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    :ets.new(@table, [:set, :public, :named_table, write_concurrency: true])

    state = %{
      interval: Keyword.get(opts, :flush_interval_ms, @default_flush_interval_ms),
      task_supervisor: Keyword.get(opts, :task_supervisor, @default_task_supervisor),
      writer: Keyword.get(opts, :writer, &write_usage/3),
      write_timeout_ms: Keyword.get(opts, :write_timeout_ms, @write_timeout_ms)
    }

    schedule_flush(state.interval)
    {:ok, state}
  end

  @impl true
  def handle_call(:flush, _from, state) do
    write_pending(state)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:flush, state) do
    write_pending(state)
    schedule_flush(state.interval)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    write_pending(state)
  end

  defp write_pending(state) do
    @table
    |> :ets.tab2list()
    |> Enum.flat_map(fn {id, _token, _ip, _uses} -> :ets.take(@table, id) end)
    |> run_writes(state)
  end

  defp run_writes([], _state), do: :ok

  defp run_writes(pending, state) do
    state.task_supervisor
    |> Task.Supervisor.async_stream_nolink(
      pending,
      fn {_id, token, ip, uses} -> state.writer.(token, ip, uses) end,
      max_concurrency: @max_concurrent_writes,
      timeout: state.write_timeout_ms,
      on_timeout: :kill_task,
      zip_input_on_exit: true,
      ordered: false
    )
    |> Enum.each(&log_failed_write/1)
  end

  defp log_failed_write({:ok, :ok}), do: :ok
  defp log_failed_write({:ok, {:ok, _token}}), do: :ok

  defp log_failed_write({:ok, other}) do
    Logger.warning("Failed to record API token usage: #{inspect(other)}")
  end

  defp log_failed_write({:exit, {{id, _token, _ip, uses}, reason}}) do
    Logger.warning("Recording #{uses} use(s) of API token #{id} exited: #{inspect(reason)}")
  end

  defp write_usage(api_token, client_ip, uses) do
    api_token
    |> Ash.Changeset.for_update(:record_use, %{last_used_ip: client_ip, uses: uses})
    |> Ash.update(actor: SystemActor.system(:api_auth), authorize?: false)
  end

  defp schedule_flush(interval), do: Process.send_after(self(), :flush, max(interval, to_timeout(second: 1)))
end
