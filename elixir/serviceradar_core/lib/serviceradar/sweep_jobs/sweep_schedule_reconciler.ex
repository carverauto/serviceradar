defmodule ServiceRadar.SweepJobs.SweepScheduleReconciler do
  @moduledoc """
  Periodically ensures sweep scheduling workers are enqueued when Oban is available.

  This reconciles sweep scheduling when sweep groups were created while Oban
  was unavailable in the current process.
  """

  use GenServer

  alias ServiceRadar.Actors.SystemActor

  alias ServiceRadar.SweepJobs.{
    ObanSupport,
    SweepDataCleanupWorker,
    SweepGroup,
    SweepMonitorWorker
  }

  require Ash.Query
  require Logger

  @default_interval_seconds 60

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    interval =
      Application.get_env(
        :serviceradar_core,
        :sweep_schedule_reconcile_interval_seconds,
        @default_interval_seconds
      )

    schedule_reconcile(0)

    {:ok, %{interval: interval}}
  end

  @impl true
  def handle_info(:reconcile, %{interval: interval} = state) do
    reconcile()
    schedule_reconcile(interval)
    {:noreply, state}
  end

  defp schedule_reconcile(delay_seconds) do
    Process.send_after(self(), :reconcile, delay_seconds * 1000)
  end

  defp reconcile do
    if ObanSupport.available?() do
      actor = SystemActor.system(:sweep_schedule_reconciler)

      SweepGroup
      |> Ash.Query.for_read(:enabled_groups)
      |> Ash.read(actor: actor)
      |> handle_groups()
    else
      Logger.debug("Sweep schedule reconciliation skipped; Oban unavailable")
    end
  end

  defp handle_groups({:ok, []}), do: :ok

  defp handle_groups({:ok, _groups}) do
    schedule_worker(SweepMonitorWorker, "sweep monitor")
    schedule_worker(SweepDataCleanupWorker, "sweep data cleanup")
  end

  defp handle_groups({:error, error}) do
    Logger.warning("Sweep schedule reconciliation failed to load groups", reason: inspect(error))
  end

  defp schedule_worker(worker, label) do
    case worker.ensure_scheduled() do
      {:ok, :already_scheduled} ->
        :ok

      {:ok, _job} ->
        Logger.info("Sweep schedule reconciliation scheduled #{label}")

      {:error, reason} ->
        Logger.warning("Sweep schedule reconciliation deferred #{label}",
          reason: inspect(reason)
        )
    end
  end
end
