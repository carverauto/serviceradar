defmodule ServiceRadarWebNGWeb.Settings.NetworksLive.Index.Executions do
  @moduledoc false
  import Phoenix.Component, only: [to_form: 1]

  alias AshPhoenix.Form
  alias ServiceRadar.Inventory.DeviceCleanupSettings
  alias ServiceRadar.Inventory.DeviceCleanupWorker
  alias ServiceRadar.SweepJobs.SweepGroupExecution
  alias ServiceRadarWebNGWeb.Settings.NetworksLive.Index.Data
  alias ServiceRadarWebNGWeb.Settings.NetworksLive.Index.MtrJobs

  def load_or_create_cleanup_settings(scope) do
    case DeviceCleanupSettings.get_settings(scope: scope) do
      {:ok, settings} ->
        settings

      {:error, _} ->
        case DeviceCleanupSettings.create_settings(%{}, scope: scope) do
          {:ok, settings} ->
            _ = DeviceCleanupWorker.ensure_scheduled()
            settings

          {:error, _} ->
            nil
        end
    end
  end

  def build_cleanup_form(_scope, nil), do: nil

  def build_cleanup_form(scope, settings) do
    settings
    |> Form.for_update(:update, domain: ServiceRadar.Inventory, scope: scope, as: "cleanup")
    |> to_form()
  end

  @doc """
  Loads MTR bulk jobs for Active Scans, or none when the viewer lacks the
  sweep view permission. Pass `load?: false` for the disconnected mount.
  """
  def assign_mtr_jobs(socket, scope, opts \\ []) do
    if Data.can_view_mtr_jobs?(scope) and Keyword.get(opts, :load?, true) do
      socket
      |> Phoenix.Component.assign(:can_view_mtr_jobs, true)
      |> Phoenix.Component.assign(:mtr_running, MtrJobs.load_running(scope))
      |> Phoenix.Component.assign(:mtr_recent, MtrJobs.load_recent(scope))
    else
      socket
      |> Phoenix.Component.assign(:can_view_mtr_jobs, Data.can_view_mtr_jobs?(scope))
      |> Phoenix.Component.assign(:mtr_running, [])
      |> Phoenix.Component.assign(:mtr_recent, [])
    end
  end

  def load_running_executions(scope) do
    case Ash.read(SweepGroupExecution, action: :running, scope: scope) do
      {:ok, executions} -> executions
      {:error, _} -> []
    end
  end

  def load_recent_executions(scope) do
    case Ash.read(SweepGroupExecution,
           action: :recent,
           scope: scope
         ) do
      {:ok, executions} ->
        # Filter out running ones (they appear in the running section)
        Enum.reject(executions, &(&1.status == :running))

      {:error, _} ->
        []
    end
  end

  def merge_running_with_progress(running, progress_map) do
    running = List.wrap(running)
    progress_map = progress_map || %{}

    running_ids = MapSet.new(running, &(Map.get(&1, :execution_id) || &1.id))

    virtuals =
      progress_map
      |> Enum.reject(fn {execution_id, _} -> MapSet.member?(running_ids, execution_id) end)
      |> Enum.map(fn {execution_id, progress} ->
        %{
          id: execution_id,
          execution_id: execution_id,
          sweep_group_id: Map.get(progress, :sweep_group_id),
          agent_id: Map.get(progress, :agent_id),
          started_at: Map.get(progress, :started_at),
          status: :running,
          hosts_total: Map.get(progress, :hosts_total),
          hosts_available: Map.get(progress, :hosts_available),
          hosts_failed: Map.get(progress, :hosts_failed)
        }
      end)

    Enum.sort_by(running ++ virtuals, &latest_execution_time/1, {:desc, DateTime})
  end

  def latest_execution_time(execution) do
    Map.get(execution, :completed_at) ||
      Map.get(execution, :updated_at) ||
      Map.get(execution, :started_at) ||
      DateTime.from_unix!(0)
  end
end
