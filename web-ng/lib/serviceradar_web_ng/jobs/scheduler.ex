defmodule ServiceRadarWebNG.Jobs.Scheduler do
  @moduledoc """
  Oban plugin for database-driven job scheduling.

  This scheduler polls the ng_job_schedules table and enqueues jobs
  based on their cron expressions. Only the Oban peer leader node
  will enqueue jobs to prevent duplicates.
  """

  @behaviour Oban.Plugin

  use GenServer

  alias Oban.Validation
  alias ServiceRadarWebNG.Jobs

  require Logger

  defstruct [:conf, :timer, :leader, :env_applied, poll_interval_ms: 30_000]

  @impl Oban.Plugin
  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name)

    state = %__MODULE__{
      conf: opts[:conf],
      poll_interval_ms: Keyword.get(opts, :poll_interval_ms, 30_000)
    }

    GenServer.start_link(__MODULE__, state, name: name)
  end

  @impl Oban.Plugin
  def validate(opts) do
    Validation.validate_schema(opts,
      conf: :any,
      name: :any,
      poll_interval_ms: :timeout
    )
  end

  @impl Oban.Plugin
  def format_logger_output(_conf, %{enqueued: enqueued, errors: errors}) do
    %{enqueued: enqueued, errors: length(errors)}
  end

  @impl GenServer
  def init(state) do
    case validate(conf: state.conf, poll_interval_ms: state.poll_interval_ms) do
      :ok ->
        {:ok, schedule_poll(%{state | timer: nil})}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl GenServer
  def terminate(_reason, %__MODULE__{timer: timer}) do
    if is_reference(timer), do: Process.cancel_timer(timer)
    :ok
  end

  @impl GenServer
  def handle_info(:poll, state) do
    state = schedule_poll(state) |> maybe_log_leader()

    state =
      if Oban.Peer.leader?(state.conf) and !state.env_applied do
        Jobs.apply_env_overrides()
        %{state | env_applied: true}
      else
        state
      end

    if Oban.Peer.leader?(state.conf) do
      result = Jobs.enqueue_due_schedules(state.conf.name)

      if result.enqueued > 0 or result.errors != [] do
        Logger.info(
          "Job scheduler tick completed: enqueued=#{result.enqueued} errors=#{length(result.errors)}"
        )
      end
    end

    {:noreply, state}
  end

  @impl GenServer
  def handle_cast(:refresh, state) do
    state = maybe_log_leader(state)

    if Oban.Peer.leader?(state.conf) do
      result = Jobs.enqueue_due_schedules(state.conf.name)

      Logger.info(
        "Job scheduler refresh completed: enqueued=#{result.enqueued} errors=#{length(result.errors)}"
      )
    end

    {:noreply, state}
  end

  defp schedule_poll(%__MODULE__{timer: timer, poll_interval_ms: poll_interval_ms} = state) do
    if is_reference(timer), do: Process.cancel_timer(timer)

    %{state | timer: Process.send_after(self(), :poll, poll_interval_ms)}
  end

  defp maybe_log_leader(state) do
    leader = Oban.Peer.get_leader(state.conf)

    if leader != state.leader and leader do
      Logger.info("Oban scheduler leader elected: #{inspect(leader)}")
    end

    %{state | leader: leader}
  end
end
