defmodule ServiceRadar.SweepJobs.DeclaredTargetsNotifier do
  @moduledoc """
  Refreshes a sweep group's persisted declared targets when its targeting changes.

  The declared relation (`platform.sweep_group_declared_targets`) feeds the
  declared side of the `device_sweep_overlap` view (issue #4963). Only
  targeting changes rewrite it -- agent assignment, partition and enabled
  state are read live from `sweep_groups` by the view, and hot bookkeeping
  updates (`record_execution` bumps `last_run_at` every run) must not trigger
  a fleet-scale SRQL resolution per sweep. Group deletion needs no hook: the
  foreign key cascades.

  The refresh runs under a task supervisor so resolving a large SRQL target
  query never blocks the operator's save. A failed refresh is logged and
  leaves the previous snapshot in place.
  """

  use Ash.Notifier

  alias Ash.Notifier.Notification
  alias ServiceRadar.SweepJobs.DeclaredTargets

  require Logger

  @task_supervisor ServiceRadar.SweepJobs.DeclaredTargets.TaskSupervisor

  @targeting_actions [:update, :add_targets, :remove_targets]
  @targeting_attributes [:target_query, :static_targets]

  @impl true
  def notify(%Notification{} = notification) do
    if refresh?(notification) do
      dispatch_refresh(notification.data)
    end

    :ok
  end

  def notify(_notification), do: :ok

  defp refresh?(%Notification{action: %{type: :create}}), do: true

  defp refresh?(%Notification{action: %{name: name}, changeset: changeset})
       when name in @targeting_actions and not is_nil(changeset) do
    Enum.any?(@targeting_attributes, fn attribute ->
      match?({:ok, _}, Ash.Changeset.fetch_change(changeset, attribute))
    end)
  end

  defp refresh?(_notification), do: false

  defp dispatch_refresh(group) do
    case Task.Supervisor.start_child(@task_supervisor, fn ->
           # Best-effort, like the DependencyDispatcher's async dispatches: a
           # failed refresh must never crash the caller, and in sandboxed tests
           # a task process cannot check out the test's connection at all --
           # either way the previous snapshot stays visible and the failure is
           # logged.
           try do
             case DeclaredTargets.refresh(group) do
               {:ok, count} ->
                 Logger.info(
                   "DeclaredTargetsNotifier: refreshed #{count} declared target(s) for group #{inspect(group.id)}"
                 )

               {:error, reason} ->
                 Logger.warning(
                   "DeclaredTargetsNotifier: refresh failed for group #{inspect(group.id)}: #{inspect(reason)}"
                 )
             end
           rescue
             exception ->
               Logger.warning(
                 "DeclaredTargetsNotifier: refresh raised for group #{inspect(group.id)}: " <>
                   Exception.format(:error, exception)
               )
           catch
             :exit, reason ->
               Logger.warning(
                 "DeclaredTargetsNotifier: refresh exited for group #{inspect(group.id)}: " <>
                   inspect(reason)
               )
           end
         end) do
      {:ok, _pid} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "DeclaredTargetsNotifier: failed to start refresh for group #{inspect(group.id)}: #{inspect(reason)}"
        )

        :ok
    end
  end
end
