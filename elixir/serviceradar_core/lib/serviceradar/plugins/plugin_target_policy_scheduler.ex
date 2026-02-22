defmodule ServiceRadar.Plugins.PluginTargetPolicyScheduler do
  @moduledoc """
  Ensures plugin target policy reconciliation jobs are scheduled when Oban is available.
  """

  use GenServer

  alias ServiceRadar.Plugins.PluginTargetPolicyReconcileWorker
  alias ServiceRadar.Repo
  alias ServiceRadar.SweepJobs.ObanSupport

  require Logger

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, opts)
  end

  @impl GenServer
  def init(state) do
    send(self(), :ensure_jobs)
    {:ok, state}
  end

  @impl GenServer
  def handle_info(:ensure_jobs, state) do
    ensure_jobs()
    Process.send_after(self(), :ensure_jobs, 60_000)
    {:noreply, state}
  end

  defp ensure_jobs do
    if oban_jobs_ready?() do
      case PluginTargetPolicyReconcileWorker.ensure_scheduled() do
        {:ok, _} ->
          :ok

        {:error, reason} ->
          Logger.debug("Plugin policy scheduler deferred", reason: inspect(reason))
      end
    else
      Logger.debug("Plugin policy scheduler skipped; Oban tables not ready")
      :ok
    end
  end

  defp oban_jobs_ready? do
    if ObanSupport.available?() do
      prefix = ObanSupport.prefix()

      case Ecto.Adapters.SQL.query(Repo, "SELECT to_regclass($1)", ["#{prefix}.oban_jobs"]) do
        {:ok, %{rows: [[nil]]}} -> false
        {:ok, _} -> true
        {:error, _} -> false
      end
    else
      false
    end
  rescue
    _ -> false
  end
end
