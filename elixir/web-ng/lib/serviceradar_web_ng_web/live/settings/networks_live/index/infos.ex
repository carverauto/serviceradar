defmodule ServiceRadarWebNGWeb.Settings.NetworksLive.Index.Infos do
  @moduledoc false
  use ServiceRadarWebNGWeb, :live_view

  import ServiceRadarWebNGWeb.Settings.NetworksLive.Index.CommandStatus
  import ServiceRadarWebNGWeb.Settings.NetworksLive.Index.Data
  import ServiceRadarWebNGWeb.Settings.NetworksLive.Index.Executions

  def handle_info(:refresh_active_scans, socket) do
    scope = socket.assigns.current_scope
    running = load_running_executions(scope)
    running_ids = MapSet.new(Enum.map(running, & &1.id))

    progress =
      socket.assigns.execution_progress
      |> Enum.filter(fn {execution_id, _} -> MapSet.member?(running_ids, execution_id) end)
      |> Map.new()

    {:noreply,
     socket
     |> refresh_sweep_groups()
     |> assign(:running_executions, running)
     |> assign(:execution_progress, progress)
     |> assign(:recent_executions, load_recent_executions(scope))}
  end

  # Handle sweep execution started event
  def handle_info({:sweep_execution_started, execution_data}, socket) do
    scope = socket.assigns.current_scope

    # Initialize progress tracking for this execution
    progress =
      Map.put(socket.assigns.execution_progress, execution_data.execution_id, %{
        batch_num: 0,
        total_batches: nil,
        hosts_processed: 0,
        hosts_available: 0,
        hosts_failed: 0,
        hosts_total: Map.get(execution_data, :hosts_total),
        sweep_group_id: Map.get(execution_data, :sweep_group_id),
        agent_id: Map.get(execution_data, :agent_id),
        started_at: execution_data.started_at
      })

    {:noreply,
     socket
     |> assign(:execution_progress, progress)
     |> refresh_sweep_groups()
     |> assign(:running_executions, load_running_executions(scope))}
  end

  # Handle sweep execution progress event (real-time batch updates)
  def handle_info({:sweep_execution_progress, progress_data}, socket) do
    execution_id = progress_data.execution_id
    existing = Map.get(socket.assigns.execution_progress, execution_id, %{})

    # Update progress tracking for this execution
    progress =
      Map.put(socket.assigns.execution_progress, execution_id, %{
        sweep_group_id: Map.get(progress_data, :sweep_group_id) || existing[:sweep_group_id],
        agent_id: Map.get(progress_data, :agent_id) || existing[:agent_id],
        started_at: Map.get(progress_data, :started_at) || existing[:started_at],
        batch_num: progress_data.batch_num,
        total_batches: progress_data.total_batches,
        hosts_processed: progress_data.hosts_processed,
        hosts_available: progress_data.hosts_available,
        hosts_failed: progress_data.hosts_failed,
        hosts_total: Map.get(progress_data, :hosts_total) || existing[:hosts_total],
        devices_created: progress_data[:devices_created] || 0,
        devices_updated: progress_data[:devices_updated] || 0,
        updated_at: progress_data.updated_at
      })

    {:noreply, assign(socket, :execution_progress, progress)}
  end

  # Handle sweep execution completed event
  def handle_info({:sweep_execution_completed, execution_data}, socket) do
    scope = socket.assigns.current_scope
    execution_id = execution_data.execution_id

    # Remove from progress tracking
    progress = Map.delete(socket.assigns.execution_progress, execution_id)

    {:noreply,
     socket
     |> assign(:execution_progress, progress)
     |> refresh_sweep_groups()
     |> assign(:running_executions, load_running_executions(scope))
     |> assign(:recent_executions, load_recent_executions(scope))}
  end

  # Handle sweep execution failed event
  def handle_info({:sweep_execution_failed, execution_data}, socket) do
    scope = socket.assigns.current_scope
    execution_id = execution_data.execution_id

    # Remove from progress tracking
    progress = Map.delete(socket.assigns.execution_progress, execution_id)

    {:noreply,
     socket
     |> assign(:execution_progress, progress)
     |> refresh_sweep_groups()
     |> assign(:running_executions, load_running_executions(scope))
     |> assign(:recent_executions, load_recent_executions(scope))}
  end

  def handle_info({:sweep_dispatch, data}, socket) do
    case apply_sweep_dispatch(socket.assigns.sweep_command_statuses, data) do
      {:ignored, _statuses} ->
        {:noreply, socket}

      {:accepted, statuses} ->
        socket = assign(socket, :sweep_command_statuses, statuses)

        case Map.get(data, :phase) || Map.get(data, "phase") do
          phase when phase in [:started, "started"] ->
            {:noreply, socket}

          _finished_or_legacy ->
            {flash_kind, flash_message} = sweep_dispatch_flash(data)
            {:noreply, put_flash(socket, flash_kind, flash_message)}
        end
    end
  end

  def handle_info({:command_ack, data}, socket) do
    {:noreply, update_command_statuses(socket, :ack, data)}
  end

  def handle_info({:command_progress, data}, socket) do
    {:noreply, update_command_statuses(socket, :progress, data)}
  end

  def handle_info({:command_result, data}, socket) do
    {:noreply, update_command_statuses(socket, :result, data)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp sweep_dispatch_flash(data) do
    successes = data |> Map.get(:commands, []) |> List.wrap() |> length()
    failures = data |> Map.get(:failures, []) |> List.wrap() |> length()

    cond do
      successes > 0 and failures == 0 ->
        {:info, "Sweep queued for #{agent_count(successes)}"}

      successes > 0 ->
        {:info, "Sweep queued for #{agent_count(successes)}; #{agent_count(failures)} failed to dispatch"}

      failures == 0 ->
        {:error, "Sweep dispatch failed"}

      true ->
        {:error, "Sweep dispatch failed for #{agent_count(failures)}"}
    end
  end

  defp refresh_sweep_groups(socket) do
    {groups, summary_agents} = load_sweep_groups_with_summary_agents(socket.assigns.current_scope)

    socket
    |> assign(:sweep_groups, groups)
    |> assign(:sweep_group_summary_agents, summary_agents)
  end

  defp agent_count(1), do: "1 agent"
  defp agent_count(count), do: "#{count} agents"
end
