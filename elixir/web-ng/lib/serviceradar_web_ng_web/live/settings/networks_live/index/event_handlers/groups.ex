defmodule ServiceRadarWebNGWeb.Settings.NetworksLive.Index.EventHandlers.Groups do
  @moduledoc false
  use ServiceRadarWebNGWeb, :live_view

  import ServiceRadarWebNGWeb.Settings.NetworksLive.Index.CommandStatus
  import ServiceRadarWebNGWeb.Settings.NetworksLive.Index.Data
  import ServiceRadarWebNGWeb.Settings.NetworksLive.Index.Formatting
  import ServiceRadarWebNGWeb.Settings.NetworksLive.Index.MapperPersistence
  import ServiceRadarWebNGWeb.Settings.NetworksLive.Index.Messages

  require Logger

  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    active_tab =
      case tab do
        "groups" -> :groups
        "profiles" -> :profiles
        "active_scans" -> :active_scans
        "cleanup" -> :cleanup
        _ -> socket.assigns.active_tab
      end

    {:noreply, assign(socket, :active_tab, active_tab)}
  end

  def handle_event("toggle_group", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope

    case load_sweep_group(scope, id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Sweep group not found")}

      group ->
        action = if group.enabled, do: :disable, else: :enable

        case group
             |> Ash.Changeset.for_update(action, %{})
             |> Ash.update(scope: scope) do
          {:ok, _updated} ->
            flash_message = sweep_group_toggle_message(action)
            {groups, summary_agents} = load_sweep_groups_with_summary_agents(scope)

            {:noreply,
             socket
             |> assign(:sweep_groups, groups)
             |> assign(:sweep_group_summary_agents, summary_agents)
             |> put_flash(:info, flash_message)}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to update sweep group")}
        end
    end
  end

  def handle_event("delete_group", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope

    case load_sweep_group(scope, id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Sweep group not found")}

      group ->
        case Ash.destroy(group, scope: scope) do
          :ok ->
            {groups, summary_agents} = load_sweep_groups_with_summary_agents(scope)

            {:noreply,
             socket
             |> assign(:sweep_groups, groups)
             |> assign(:sweep_group_summary_agents, summary_agents)
             |> put_flash(:info, "Sweep group deleted")}

          {:error, reason} ->
            Logger.error("Failed to delete sweep group",
              sweep_group_id: id,
              reason: inspect(reason)
            )

            {:noreply, put_flash(socket, :error, sweep_group_delete_error_message(reason))}
        end
    end
  end

  def handle_event("run_sweep_group", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope

    with :ok <- require_run_sweeps(socket),
         {:ok, group} <- fetch_sweep_group(scope, id) do
      case Ash.update(group, %{}, action: :run_now, scope: scope) do
        {:ok, _updated} ->
          {groups, summary_agents} = load_sweep_groups_with_summary_agents(scope)

          {:noreply,
           socket
           |> assign(:sweep_groups, groups)
           |> assign(:sweep_group_summary_agents, summary_agents)
           |> put_flash(:info, "Sweep dispatch started")}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Failed to run sweep group: #{format_error(reason)}")}
      end
    else
      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, "You are not authorized to run sweep groups")}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Sweep group not found")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to run sweep group: #{format_error(reason)}")}
    end
  end

  def handle_event("toggle_mapper_job", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope

    with {:ok, job} <- fetch_mapper_job(scope, id),
         {:ok, _updated} <-
           Ash.update(job, %{enabled: not job.enabled}, action: :update, scope: scope) do
      message = if job.enabled, do: "Discovery job disabled", else: "Discovery job enabled"

      {:noreply,
       socket
       |> assign(:mapper_jobs, load_mapper_jobs(scope))
       |> put_flash(:info, message)}
    else
      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Discovery job not found")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to update discovery job")}
    end
  end

  def handle_event("delete_mapper_job", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope

    with {:ok, job} <- fetch_mapper_job(scope, id),
         :ok <- Ash.destroy(job, scope: scope) do
      {:noreply,
       socket
       |> assign(:mapper_jobs, load_mapper_jobs(scope))
       |> put_flash(:info, "Discovery job deleted")}
    else
      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Discovery job not found")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to delete discovery job")}
    end
  end

  def handle_event("run_mapper_job", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope

    with :ok <- require_run_discovery(socket),
         {:ok, job} <- fetch_mapper_job(scope, id),
         {:ok, _updated} <- Ash.update(job, %{}, action: :run_now, scope: scope) do
      statuses = mark_command_sent(socket.assigns.mapper_command_statuses, job.id, "Discovery command queued")

      {:noreply,
       socket
       |> assign(:mapper_jobs, load_mapper_jobs(scope))
       |> assign(:mapper_command_statuses, statuses)
       |> put_flash(:info, "Discovery job queued to run now")}
    else
      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, "You are not authorized to run discovery jobs")}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Discovery job not found")}

      {:error, reason} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Failed to run discovery job: #{format_mapper_run_error(reason)}"
         )}
    end
  end
end
