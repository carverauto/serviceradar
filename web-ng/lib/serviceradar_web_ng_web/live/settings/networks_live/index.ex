defmodule ServiceRadarWebNGWeb.Settings.NetworksLive.Index do
  @moduledoc """
  LiveView for managing network sweep configuration.

  Provides UI for:
  - Sweep Groups: User-configured scan jobs with schedules and targeting
  - Scanner Profiles: Admin-managed scan configuration templates
  - Active Scans: Real-time view of running sweeps
  """
  use ServiceRadarWebNGWeb, :live_view

  import ServiceRadarWebNGWeb.SettingsComponents

  alias AshPhoenix.Form

  alias ServiceRadar.SweepJobs.{
    ObanSupport,
    SweepGroup,
    SweepGroupExecution,
    SweepProfile,
    SweepPubSub
  }

  alias ServiceRadar.AgentCommands.PubSub, as: AgentCommandsPubSub

  alias ServiceRadar.NetworkDiscovery.{
    MapperJob,
    MapperSeed,
    MapperUnifiController
  }

  alias ServiceRadar.Inventory.{DeviceCleanupSettings, DeviceCleanupWorker}
  alias ServiceRadar.Infrastructure.Agent

  @refresh_interval :timer.seconds(15)

  alias ServiceRadarWebNGWeb.SRQL.Catalog

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope
    cleanup_settings = load_or_create_cleanup_settings(scope)
    cleanup_form = build_cleanup_form(scope, cleanup_settings)
    can_manage_networks = can_manage_networks?(scope)

    if connected?(socket) do
      # Subscribe to sweep updates for this instance
      SweepPubSub.subscribe()
      AgentCommandsPubSub.subscribe()

      # Refresh active scans periodically (fallback for any missed events)
      :timer.send_interval(@refresh_interval, self(), :refresh_active_scans)
    end

    socket =
      socket
      |> assign(:page_title, "Network Sweeps")
      |> assign(:current_path, "/settings/networks")
      |> assign(:active_tab, :groups)
      |> assign(:sweep_groups, load_sweep_groups(scope))
      |> assign(:sweep_profiles, load_sweep_profiles(scope))
      |> assign(:running_executions, load_running_executions(scope))
      |> assign(:recent_executions, load_recent_executions(scope))
      # Track real-time progress for running executions (execution_id -> progress_data)
      |> assign(:execution_progress, %{})
      |> assign(:selected_group, nil)
      |> assign(:selected_profile, nil)
      |> assign(:show_form, nil)
      |> assign(:ash_form, nil)
      |> assign(:form, nil)
      |> assign(:target_device_count, nil)
      |> assign(:builder_open, false)
      |> assign(:builder, default_builder_state())
      |> assign(:builder_sync, true)
      |> assign(:show_mapper_form, nil)
      |> assign(:mapper_jobs, load_mapper_jobs(scope))
      |> assign(:agents, load_agents(scope))
      |> assign(:can_manage_networks, can_manage_networks)
      |> assign(:mapper_job, nil)
      |> assign(:mapper_form, nil)
      |> assign(:mapper_seeds_text, "")
      |> assign(:mapper_unifi_form, nil)
      |> assign(:mapper_unifi_present, false)
      |> assign(:mapper_command_statuses, %{})
      |> assign(:sweep_command_statuses, %{})
      |> assign(:cleanup_settings, cleanup_settings)
      |> assign(:cleanup_form, cleanup_form)

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:page_title, "Network Sweeps")
    |> assign(:current_path, "/settings/networks")
    |> assign(:show_form, nil)
    |> assign(:ash_form, nil)
    |> assign(:selected_group, nil)
    |> assign(:selected_profile, nil)
  end

  defp apply_action(socket, :new_group, _params) do
    scope = socket.assigns.current_scope
    ash_form = Form.for_create(SweepGroup, :create, domain: ServiceRadar.SweepJobs, scope: scope)

    socket
    |> assign(:page_title, "New Sweep Group")
    |> assign(:current_path, "/settings/networks")
    |> assign(:show_form, :new_group)
    |> assign(:ash_form, ash_form)
    |> assign(:form, to_form(ash_form))
    |> assign(:target_device_count, nil)
    |> assign(:builder_open, false)
    |> assign(:builder, default_builder_state())
    |> assign(:builder_sync, true)
    |> assign(:agents, load_agents(scope))
  end

  defp apply_action(socket, :edit_group, %{"id" => id}) do
    require Logger

    case load_sweep_group(socket.assigns.current_scope, id) do
      nil ->
        socket
        |> put_flash(:error, "Sweep group not found")
        |> push_navigate(to: ~p"/settings/networks")

      group ->
        scope = socket.assigns.current_scope
        ash_form = Form.for_update(group, :update, domain: ServiceRadar.SweepJobs, scope: scope)
        device_count = count_target_devices(scope, group.target_query)
        {builder, builder_sync} = parse_target_query_to_builder(group.target_query)

        socket
        |> assign(:page_title, "Edit Sweep Group")
        |> assign(:current_path, "/settings/networks")
        |> assign(:show_form, :edit_group)
        |> assign(:selected_group, group)
        |> assign(:ash_form, ash_form)
        |> assign(:form, to_form(ash_form))
        |> assign(:target_device_count, device_count)
        |> assign(:builder_open, false)
        |> assign(:builder, builder)
        |> assign(:builder_sync, builder_sync)
        |> assign(:agents, load_agents(scope))
    end
  end

  defp apply_action(socket, :discovery, _params) do
    socket
    |> assign(:page_title, "Discovery Jobs")
    |> assign(:current_path, "/settings/networks/discovery")
    |> assign(:show_form, nil)
    |> assign(:show_mapper_form, nil)
    |> assign(:mapper_job, nil)
    |> assign(:mapper_form, nil)
    |> assign(:mapper_seeds_text, "")
    |> assign(:mapper_unifi_form, nil)
  end

  defp apply_action(socket, :new_mapper_job, _params) do
    defaults = %{
      "name" => "",
      "description" => "",
      "enabled" => true,
      "interval" => "2h",
      "partition" => "default",
      "agent_id" => "",
      "discovery_mode" => "snmp_api",
      "discovery_type" => "full",
      "concurrency" => 10,
      "timeout" => "45s",
      "retries" => 2
    }

    socket
    |> assign(:page_title, "New Discovery Job")
    |> assign(:current_path, "/settings/networks/discovery")
    |> assign(:show_form, nil)
    |> assign(:show_mapper_form, :new_mapper_job)
    |> assign(:mapper_job, nil)
    |> assign(:mapper_form, to_form(defaults, as: :mapper_job))
    |> assign(:mapper_seeds_text, "")
    |> assign(:mapper_unifi_form, to_form(%{}, as: :unifi))
    |> assign(:mapper_unifi_present, false)
  end

  defp apply_action(socket, :edit_mapper_job, %{"id" => id}) do
    scope = socket.assigns.current_scope

    case load_mapper_job(scope, id) do
      nil ->
        socket
        |> put_flash(:error, "Discovery job not found")
        |> push_navigate(to: ~p"/settings/networks/discovery")

      job ->
        {unifi_form, unifi_present} = mapper_unifi_form(job.unifi_controllers)

        socket
        |> assign(:page_title, "Edit Discovery Job")
        |> assign(:current_path, "/settings/networks/discovery")
        |> assign(:show_form, nil)
        |> assign(:show_mapper_form, :edit_mapper_job)
        |> assign(:mapper_job, job)
        |> assign(:mapper_form, to_form(mapper_job_to_form(job), as: :mapper_job))
        |> assign(:mapper_seeds_text, seeds_to_text(job.seeds || []))
        |> assign(:mapper_unifi_form, unifi_form)
        |> assign(:mapper_unifi_present, unifi_present)
    end
  end

  defp apply_action(socket, :show_group, %{"id" => id}) do
    case load_sweep_group(socket.assigns.current_scope, id) do
      nil ->
        socket
        |> put_flash(:error, "Sweep group not found")
        |> push_navigate(to: ~p"/settings/networks")

      group ->
        socket
        |> assign(:page_title, group.name)
        |> assign(:current_path, "/settings/networks")
        |> assign(:show_form, :show_group)
        |> assign(:selected_group, group)
    end
  end

  defp apply_action(socket, :new_profile, _params) do
    scope = socket.assigns.current_scope

    ash_form =
      Form.for_create(SweepProfile, :create, domain: ServiceRadar.SweepJobs, scope: scope)

    socket
    |> assign(:page_title, "New Scanner Profile")
    |> assign(:current_path, "/settings/networks")
    |> assign(:show_form, :new_profile)
    |> assign(:ash_form, ash_form)
    |> assign(:form, to_form(ash_form))
  end

  defp apply_action(socket, :edit_profile, %{"id" => id}) do
    case load_sweep_profile(socket.assigns.current_scope, id) do
      nil ->
        socket
        |> put_flash(:error, "Scanner profile not found")
        |> push_navigate(to: ~p"/settings/networks")

      profile ->
        scope = socket.assigns.current_scope
        ash_form = Form.for_update(profile, :update, domain: ServiceRadar.SweepJobs, scope: scope)

        socket
        |> assign(:page_title, "Edit Scanner Profile")
        |> assign(:current_path, "/settings/networks")
        |> assign(:show_form, :edit_profile)
        |> assign(:selected_profile, profile)
        |> assign(:ash_form, ash_form)
        |> assign(:form, to_form(ash_form))
    end
  end

  @impl true
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

        case Ash.update(group, action, scope: scope) do
          {:ok, _updated} ->
            flash_message = sweep_group_toggle_message(action)

            {:noreply,
             socket
             |> assign(:sweep_groups, load_sweep_groups(scope))
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
            {:noreply,
             socket
             |> assign(:sweep_groups, load_sweep_groups(scope))
             |> put_flash(:info, "Sweep group deleted")}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to delete sweep group")}
        end
    end
  end

  def handle_event("run_sweep_group", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope

    with :ok <- require_manage_networks(socket),
         {:ok, group} <- fetch_sweep_group(scope, id),
         {:ok, _updated} <- Ash.update(group, %{}, action: :run_now, scope: scope) do
      statuses =
        socket.assigns.sweep_command_statuses
        |> mark_command_sent(group.id, "Sweep command queued")

      {:noreply,
       socket
       |> assign(:sweep_groups, load_sweep_groups(scope))
       |> assign(:sweep_command_statuses, statuses)
       |> put_flash(:info, "Sweep group queued to run now")}
    else
      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, "You are not authorized to run sweep groups")}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Sweep group not found")}

      {:error, reason} ->
        {:noreply,
         socket
         |> put_flash(:error, "Failed to run sweep group: #{format_error(reason)}")}
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

    with :ok <- require_manage_networks(socket),
         {:ok, job} <- fetch_mapper_job(scope, id),
         {:ok, _updated} <- Ash.update(job, %{}, action: :run_now, scope: scope) do
      statuses =
        socket.assigns.mapper_command_statuses
        |> mark_command_sent(job.id, "Discovery command queued")

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
         socket
         |> put_flash(:error, "Failed to run discovery job: #{format_error(reason)}")}
    end
  end

  def handle_event("save_mapper_job", params, socket) do
    scope = socket.assigns.current_scope
    job_params = normalize_mapper_job_params(Map.get(params, "mapper_job", %{}))
    seeds = parse_seeds_text(Map.get(params, "seeds", ""))
    unifi_params = normalize_unifi_params(Map.get(params, "unifi", %{}))

    case save_mapper_job(
           socket.assigns.mapper_job,
           job_params,
           seeds,
           unifi_params,
           scope
         ) do
      {:ok, _job} ->
        {:noreply,
         socket
         |> assign(:mapper_jobs, load_mapper_jobs(scope))
         |> put_flash(:info, "Discovery job saved")
         |> push_navigate(to: ~p"/settings/networks/discovery")}

      {:error, reason} ->
        {:noreply,
         socket
         |> put_flash(:error, "Failed to save discovery job: #{format_error(reason)}")}
    end
  end

  def handle_event("mapper_form_change", params, socket) do
    # Update the form with changed values to trigger conditional rendering
    job_params = Map.get(params, "mapper_job", %{})
    seeds_text = Map.get(params, "seeds", socket.assigns.mapper_seeds_text)

    # Merge changed params into existing form
    current_form_data = socket.assigns.mapper_form.source
    updated_form_data = Map.merge(current_form_data, job_params)
    updated_form = to_form(updated_form_data, as: :mapper_job)

    {:noreply,
     socket
     |> assign(:mapper_form, updated_form)
     |> assign(:mapper_seeds_text, seeds_text)}
  end

  def handle_event("delete_profile", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope

    case load_sweep_profile(scope, id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Scanner profile not found")}

      profile ->
        case Ash.destroy(profile, scope: scope) do
          :ok ->
            {:noreply,
             socket
             |> assign(:sweep_profiles, load_sweep_profiles(scope))
             |> put_flash(:info, "Scanner profile deleted")}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to delete scanner profile")}
        end
    end
  end

  def handle_event("save_group", %{"form" => params}, socket) do
    scope = socket.assigns.current_scope

    require Logger

    params =
      params
      |> normalize_static_targets()

    Logger.debug("[NetworksLive] save_group - params: #{inspect(params)}")

    ash_form =
      socket.assigns.ash_form
      |> Form.validate(params)

    case Form.submit(ash_form, params: params) do
      {:ok, group} ->
        Logger.debug(
          "[NetworksLive] save_group SUCCESS - saved group.target_query: #{inspect(group.target_query)}"
        )

        flash_message = sweep_group_save_message(group.enabled)

        {:noreply,
         socket
         |> assign(:sweep_groups, load_sweep_groups(scope))
         |> put_flash(:info, flash_message)
         |> push_navigate(to: ~p"/settings/networks")}

      {:ok, group, _notifications} ->
        Logger.debug(
          "[NetworksLive] save_group SUCCESS - saved group.target_query: #{inspect(group.target_query)}"
        )

        flash_message = sweep_group_save_message(group.enabled)

        {:noreply,
         socket
         |> assign(:sweep_groups, load_sweep_groups(scope))
         |> put_flash(:info, flash_message)
         |> push_navigate(to: ~p"/settings/networks")}

      {:error, ash_form} ->
        Logger.warning(
          "[NetworksLive] save_group ERROR - form errors: #{inspect(Form.errors(ash_form))}"
        )

        {:noreply,
         socket
         |> assign(:ash_form, ash_form)
         |> assign(:form, to_form(ash_form))}
    end
  end

  def handle_event("save_profile", %{"form" => params}, socket) do
    scope = socket.assigns.current_scope
    params = transform_profile_params(params)

    ash_form =
      socket.assigns.ash_form
      |> Form.validate(params)

    case Form.submit(ash_form, params: params) do
      {:ok, _profile} ->
        {:noreply,
         socket
         |> assign(:sweep_profiles, load_sweep_profiles(scope))
         |> put_flash(:info, "Scanner profile saved")
         |> push_navigate(to: ~p"/settings/networks")}

      {:error, ash_form} ->
        {:noreply,
         socket
         |> assign(:ash_form, ash_form)
         |> assign(:form, to_form(ash_form))}
    end
  end

  def handle_event("validate_cleanup_settings", %{"cleanup" => params}, socket) do
    form =
      socket.assigns.cleanup_form
      |> Form.validate(params)

    {:noreply, assign(socket, :cleanup_form, to_form(form))}
  end

  def handle_event("save_cleanup_settings", %{"cleanup" => params}, socket) do
    scope = socket.assigns.current_scope

    form =
      socket.assigns.cleanup_form
      |> Form.validate(params)

    case Form.submit(form, params: params) do
      {:ok, settings} ->
        _ = DeviceCleanupWorker.ensure_scheduled()
        updated_form = build_cleanup_form(scope, settings)

        {:noreply,
         socket
         |> assign(:cleanup_settings, settings)
         |> assign(:cleanup_form, updated_form)
         |> put_flash(:info, "Inventory cleanup settings saved")}

      {:error, form} ->
        {:noreply,
         socket
         |> assign(:cleanup_form, to_form(form))
         |> put_flash(:error, "Failed to save inventory cleanup settings")}
    end
  end

  def handle_event("run_cleanup_now", _params, socket) do
    scope = socket.assigns.current_scope

    case DeviceCleanupSettings.run_cleanup(scope: scope) do
      {:ok, _} ->
        {:noreply, put_flash(socket, :info, "Cleanup job queued")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to queue cleanup: #{inspect(reason)}")}
    end
  end

  def handle_event("validate_group", %{"form" => params} = payload, socket) do
    scope = socket.assigns.current_scope
    params = normalize_static_targets(params)
    target_query = Map.get(params, "target_query")
    device_count = count_target_devices(scope, target_query)
    builder_event? = Map.has_key?(payload, "builder")

    {parsed_builder, builder_sync} =
      if builder_event? do
        {socket.assigns.builder, socket.assigns.builder_sync}
      else
        parse_target_query_to_builder(target_query)
      end

    ash_form =
      socket.assigns.ash_form
      |> Form.validate(params)

    socket =
      socket
      |> assign(:ash_form, ash_form)
      |> assign(:form, to_form(ash_form))
      |> assign(:target_device_count, device_count)
      |> assign(:builder_sync, builder_sync)

    socket =
      if builder_event? do
        socket
      else
        if builder_sync do
          assign(socket, :builder, parsed_builder)
        else
          socket
        end
      end

    {:noreply, socket}
  end

  def handle_event("validate_profile", %{"form" => params}, socket) do
    params = transform_profile_params(params)

    ash_form =
      socket.assigns.ash_form
      |> Form.validate(params)

    builder_sync = socket.assigns.builder_sync

    socket =
      if Map.has_key?(params, "target_query") do
        target_query = Map.get(params, "target_query")
        {parsed_builder, parsed_sync} = parse_target_query_to_builder(target_query)

        socket = assign(socket, :builder_sync, parsed_sync)

        if builder_sync do
          assign(socket, :builder, parsed_builder)
        else
          socket
        end
      else
        socket
      end

    {:noreply,
     socket
     |> assign(:ash_form, ash_form)
     |> assign(:form, to_form(ash_form))}
  end

  # SRQL builder handlers (mirrors Sysmon targeting UX)
  def handle_event("builder_toggle", _params, socket) do
    builder_open = !socket.assigns.builder_open

    socket =
      if builder_open do
        form_data = form_params(socket.assigns.ash_form)
        target_query = Map.get(form_data, "target_query", "")
        {builder, builder_sync} = parse_target_query_to_builder(target_query)

        socket
        |> assign(:builder_open, true)
        |> assign(:builder, builder)
        |> assign(:builder_sync, builder_sync)
      else
        assign(socket, :builder_open, false)
      end

    {:noreply, socket}
  end

  def handle_event("builder_change", %{"builder" => builder_params}, socket) do
    builder = update_builder(socket.assigns.builder, builder_params)

    socket =
      socket
      |> assign(:builder, builder)
      |> assign(:builder_sync, true)
      |> maybe_sync_builder_to_form()

    {:noreply, socket}
  end

  def handle_event("builder_add_filter", _params, socket) do
    builder = socket.assigns.builder
    config = Catalog.entity("devices")

    filters =
      builder
      |> Map.get("filters", [])
      |> List.wrap()

    next = %{
      "field" => config.default_filter_field,
      "op" => "contains",
      "value" => ""
    }

    updated_builder = Map.put(builder, "filters", filters ++ [next])

    socket =
      socket
      |> assign(:builder, updated_builder)
      |> assign(:builder_sync, true)
      |> maybe_sync_builder_to_form()

    {:noreply, socket}
  end

  def handle_event("builder_remove_filter", %{"idx" => idx_str}, socket) do
    builder = socket.assigns.builder

    filters =
      builder
      |> Map.get("filters", [])
      |> List.wrap()

    index =
      case Integer.parse(idx_str) do
        {i, ""} -> i
        _ -> -1
      end

    updated_filters =
      filters
      |> Enum.with_index()
      |> Enum.reject(fn {_f, i} -> i == index end)
      |> Enum.map(fn {f, _i} -> f end)

    updated_builder = Map.put(builder, "filters", updated_filters)

    socket =
      socket
      |> assign(:builder, updated_builder)
      |> assign(:builder_sync, true)
      |> maybe_sync_builder_to_form()

    {:noreply, socket}
  end

  def handle_event("builder_apply", _params, socket) do
    builder = socket.assigns.builder
    query = build_target_query(builder)

    params =
      socket.assigns.ash_form
      |> form_params()
      |> Map.put("target_query", query)

    ash_form =
      socket.assigns.ash_form
      |> Form.validate(params)

    scope = socket.assigns.current_scope
    device_count = count_target_devices(scope, query)

    {:noreply,
     socket
     |> assign(:ash_form, ash_form)
     |> assign(:form, to_form(ash_form))
     |> assign(:target_device_count, device_count)
     |> assign(:builder_sync, true)}
  end

  defp sweep_group_save_message(true) do
    if ObanSupport.available?() do
      "Sweep group saved"
    else
      "Sweep group saved. Scheduling is deferred until the scheduler is available."
    end
  end

  defp sweep_group_save_message(false), do: "Sweep group saved"

  defp sweep_group_toggle_message(:enable) do
    if ObanSupport.available?() do
      "Sweep group enabled"
    else
      "Sweep group enabled. Scheduling is deferred until the scheduler is available."
    end
  end

  defp sweep_group_toggle_message(:disable), do: "Sweep group disabled"

  @impl true
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
     |> assign(:running_executions, load_running_executions(scope))
     |> assign(:recent_executions, load_recent_executions(scope))}
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

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.settings_shell current_path={@current_path}>
        <.settings_nav current_path={@current_path} />
        <.network_nav current_path={@current_path} />

        <div class="flex flex-wrap items-center justify-between gap-4">
          <div>
            <h1 class="text-2xl font-semibold text-base-content">Network Sweeps</h1>
            <p class="text-sm text-base-content/60">
              Configure network discovery sweeps and scanner profiles.
            </p>
          </div>
        </div>

        <%= if @live_action in [:discovery, :new_mapper_job, :edit_mapper_job] do %>
          <.discovery_panel
            jobs={@mapper_jobs}
            show_form={@show_mapper_form}
            form={@mapper_form}
            seeds_text={@mapper_seeds_text}
            unifi_form={@mapper_unifi_form}
            unifi_present={@mapper_unifi_present}
            mapper_command_statuses={@mapper_command_statuses}
            can_manage_networks={@can_manage_networks}
          />
        <% else %>
          <%= if @show_form in [:new_group, :edit_group] do %>
            <.group_form
              form={@form}
              show_form={@show_form}
              profiles={@sweep_profiles}
              agents={@agents}
              target_device_count={@target_device_count}
              builder_open={@builder_open}
              builder_sync={@builder_sync}
              builder={@builder}
            />
          <% else %>
            <%= if @show_form in [:new_profile, :edit_profile] do %>
              <.profile_form form={@form} show_form={@show_form} />
            <% else %>
              <%= if @show_form == :show_group do %>
                <.group_detail group={@selected_group} />
              <% else %>
                <.tab_navigation
                  active_tab={@active_tab}
                  running_count={
                    length(merge_running_with_progress(@running_executions, @execution_progress))
                  }
                />

                <%= case @active_tab do %>
                  <% :groups -> %>
                    <.sweep_groups_panel
                      groups={@sweep_groups}
                      sweep_command_statuses={@sweep_command_statuses}
                      can_manage_networks={@can_manage_networks}
                    />
                  <% :profiles -> %>
                    <.profiles_panel profiles={@sweep_profiles} />
                  <% :active_scans -> %>
                    <.active_scans_panel
                      running={merge_running_with_progress(@running_executions, @execution_progress)}
                      recent={@recent_executions}
                      groups={@sweep_groups}
                      execution_progress={@execution_progress}
                    />
                  <% :cleanup -> %>
                    <.inventory_cleanup_panel
                      form={@cleanup_form}
                      settings={@cleanup_settings}
                    />
                <% end %>
              <% end %>
            <% end %>
          <% end %>
        <% end %>
      </.settings_shell>
    </Layouts.app>
    """
  end

  # Tab Navigation
  attr :active_tab, :atom, required: true
  attr :running_count, :integer, default: 0

  defp tab_navigation(assigns) do
    ~H"""
    <div class="flex items-center gap-2 border-b border-base-200">
      <button
        phx-click="switch_tab"
        phx-value-tab="groups"
        class={"px-4 py-2 text-sm font-medium border-b-2 -mb-px transition-colors " <>
               if(@active_tab == :groups, do: "border-primary text-primary", else: "border-transparent text-base-content/60 hover:text-base-content")}
      >
        Sweep Groups
      </button>
      <button
        phx-click="switch_tab"
        phx-value-tab="profiles"
        class={"px-4 py-2 text-sm font-medium border-b-2 -mb-px transition-colors " <>
               if(@active_tab == :profiles, do: "border-primary text-primary", else: "border-transparent text-base-content/60 hover:text-base-content")}
      >
        Scanner Profiles
      </button>
      <button
        phx-click="switch_tab"
        phx-value-tab="active_scans"
        class={"px-4 py-2 text-sm font-medium border-b-2 -mb-px transition-colors flex items-center gap-1.5 " <>
               if(@active_tab == :active_scans, do: "border-primary text-primary", else: "border-transparent text-base-content/60 hover:text-base-content")}
      >
        Active Scans
        <span
          :if={@running_count > 0}
          class="inline-flex items-center justify-center px-1.5 py-0.5 text-xs font-semibold rounded-full bg-success text-success-content animate-pulse"
        >
          {@running_count}
        </span>
      </button>
      <button
        phx-click="switch_tab"
        phx-value-tab="cleanup"
        class={"px-4 py-2 text-sm font-medium border-b-2 -mb-px transition-colors " <>
               if(@active_tab == :cleanup, do: "border-primary text-primary", else: "border-transparent text-base-content/60 hover:text-base-content")}
      >
        Inventory Cleanup
      </button>
    </div>
    """
  end

  # Discovery Jobs Panel
  attr :jobs, :list, required: true
  attr :show_form, :any, default: nil
  attr :form, :any, default: nil
  attr :seeds_text, :string, default: ""
  attr :unifi_form, :any, default: nil
  attr :unifi_present, :boolean, default: false
  attr :mapper_command_statuses, :map, default: %{}
  attr :can_manage_networks, :boolean, default: false

  defp discovery_panel(assigns) do
    ~H"""
    <.ui_panel>
      <:header>
        <div class="flex items-center justify-between w-full">
          <div>
            <div class="text-sm font-semibold">Discovery Jobs</div>
            <p class="text-xs text-base-content/60">
              {length(@jobs)} job(s) configured
            </p>
          </div>
          <%= if @show_form in [:new_mapper_job, :edit_mapper_job] do %>
            <.link navigate={~p"/settings/networks/discovery"}>
              <.ui_button variant="ghost" size="sm">Cancel</.ui_button>
            </.link>
          <% else %>
            <.link navigate={~p"/settings/networks/discovery/new"}>
              <.ui_button variant="primary" size="sm">
                <.icon name="hero-plus" class="size-4" /> New Job
              </.ui_button>
            </.link>
          <% end %>
        </div>
      </:header>

      <%= if @show_form in [:new_mapper_job, :edit_mapper_job] do %>
        <.mapper_job_form
          form={@form}
          seeds_text={@seeds_text}
          agents={@agents}
          unifi_form={@unifi_form}
          unifi_present={@unifi_present}
        />
      <% else %>
        <div class="overflow-x-auto">
          <table class="table table-sm">
            <thead>
              <tr class="text-xs uppercase tracking-wide text-base-content/60">
                <th>Status</th>
                <th>Name</th>
                <th>Interval</th>
                <th>Type</th>
                <th>Partition</th>
                <th>Last Run</th>
                <th>Run Status</th>
                <th>Actions</th>
              </tr>
            </thead>
            <tbody>
              <tr :if={@jobs == []}>
                <td colspan="8" class="text-center text-base-content/60 py-8">
                  No discovery jobs configured. Create one to start mapper discovery.
                </td>
              </tr>
              <%= for job <- @jobs do %>
                <tr class="hover:bg-base-200/40">
                  <td>
                    <button
                      phx-click="toggle_mapper_job"
                      phx-value-id={job.id}
                      class="flex items-center gap-1.5 cursor-pointer"
                    >
                      <span class={"size-2 rounded-full #{if job.enabled, do: "bg-success", else: "bg-base-content/30"}"}>
                      </span>
                      <span class="text-xs">{if job.enabled, do: "Enabled", else: "Disabled"}</span>
                    </button>
                  </td>
                  <td>
                    <div class="font-medium">{job.name}</div>
                    <p :if={job.description} class="text-xs text-base-content/60 truncate max-w-xs">
                      {job.description}
                    </p>
                  </td>
                  <td class="text-xs font-mono">Every {job.interval}</td>
                  <td class="text-xs capitalize">{job.discovery_type}</td>
                  <td class="text-xs">{job.partition}</td>
                  <td class="text-xs text-base-content/60">{format_last_run(job.last_run_at)}</td>
                  <td class="text-xs">
                    <%= if status = Map.get(@mapper_command_statuses, job.id) do %>
                      <.ui_badge variant={command_status_variant(status)} size="xs">
                        {command_status_label(status)}
                      </.ui_badge>
                    <% else %>
                      <%= if job.last_run_status do %>
                        <.ui_badge variant={mapper_run_status_variant(job.last_run_status)} size="xs">
                          {mapper_run_status_label(job.last_run_status)}
                        </.ui_badge>
                      <% else %>
                        <span class="text-xs text-base-content/40">—</span>
                      <% end %>
                      <p
                        :if={is_integer(job.last_run_interface_count)}
                        class="text-[10px] text-base-content/50 mt-0.5"
                      >
                        {job.last_run_interface_count} interfaces
                      </p>
                      <p
                        :if={is_binary(job.last_run_error)}
                        class="text-[10px] text-error/80 mt-0.5 truncate max-w-[180px]"
                        title={job.last_run_error}
                      >
                        {job.last_run_error}
                      </p>
                    <% end %>
                  </td>
                  <td>
                    <div class="flex items-center gap-1">
                      <.ui_button
                        :if={@can_manage_networks}
                        id={"run-mapper-job-#{job.id}"}
                        variant="ghost"
                        size="xs"
                        phx-click="run_mapper_job"
                        phx-value-id={job.id}
                      >
                        <.icon name="hero-play" class="size-3" />
                      </.ui_button>
                      <.link navigate={~p"/settings/networks/discovery/#{job.id}/edit"}>
                        <.ui_button variant="ghost" size="xs">
                          <.icon name="hero-pencil" class="size-3" />
                        </.ui_button>
                      </.link>
                      <.ui_button
                        variant="ghost"
                        size="xs"
                        phx-click="delete_mapper_job"
                        phx-value-id={job.id}
                        data-confirm="Are you sure you want to delete this discovery job?"
                      >
                        <.icon name="hero-trash" class="size-3" />
                      </.ui_button>
                    </div>
                  </td>
                </tr>
              <% end %>
            </tbody>
          </table>
        </div>
      <% end %>
    </.ui_panel>
    """
  end

  attr :form, :any, required: true
  attr :seeds_text, :string, default: ""
  attr :agents, :list, default: []
  attr :unifi_form, :any, required: true
  attr :unifi_present, :boolean, default: false

  defp mapper_job_form(assigns) do
    # Get current values for conditional rendering
    discovery_mode = Phoenix.HTML.Form.input_value(assigns.form, :discovery_mode) || "snmp_api"
    partition = Phoenix.HTML.Form.input_value(assigns.form, :partition) || "default"
    current_agent_id = Phoenix.HTML.Form.input_value(assigns.form, :agent_id) || ""

    agent_options = mapper_agent_options(assigns.agents, partition, current_agent_id)

    assigns =
      assigns
      |> assign(:discovery_mode, discovery_mode)
      |> assign(:show_api, discovery_mode in ["api", "snmp_api"])
      |> assign(:agent_options, agent_options)

    ~H"""
    <.form
      for={@form}
      id="mapper-job-form"
      phx-submit="save_mapper_job"
      phx-change="mapper_form_change"
      class="space-y-6"
    >
      <div class="grid gap-4 md:grid-cols-2">
        <.input field={@form[:name]} type="text" label="Job Name" required />
        <.input field={@form[:enabled]} type="checkbox" label="Enabled" />
        <.input field={@form[:description]} type="text" label="Description" />
        <.input field={@form[:interval]} type="text" label="Interval (e.g. 15m, 2h)" required />
        <.input field={@form[:partition]} type="text" label="Partition" required />
        <.input
          field={@form[:agent_id]}
          type="select"
          label="Agent"
          options={@agent_options}
          prompt="Any agent in partition"
        />
        <.input
          field={@form[:discovery_mode]}
          type="select"
          label="Discovery Mode"
          options={[
            {"API & SNMP", "snmp_api"},
            {"SNMP Only", "snmp"},
            {"API Only", "api"}
          ]}
        />
        <.input
          field={@form[:discovery_type]}
          type="select"
          label="Discovery Type"
          options={[
            {"Full", "full"},
            {"Basic", "basic"},
            {"Interfaces", "interfaces"},
            {"Topology", "topology"}
          ]}
        />
        <.input field={@form[:concurrency]} type="number" label="Concurrency" />
        <.input field={@form[:timeout]} type="text" label="Timeout (e.g. 30s)" />
        <.input field={@form[:retries]} type="number" label="Retries" />
      </div>

      <div>
        <label class="text-sm font-medium text-base-content">Seed Targets</label>
        <.input
          name="seeds"
          type="textarea"
          value={@seeds_text}
          label="Seeds (one per line or comma-separated)"
          placeholder="10.0.0.0/24\n10.0.1.10\nhost.example.com"
        />
      </div>

      <div :if={@show_api} class="rounded-xl border border-base-200 p-4 space-y-4">
        <div class="flex items-center justify-between">
          <div>
            <h3 class="text-sm font-semibold">UniFi Controller</h3>
            <p class="text-xs text-base-content/60">API discovery integration.</p>
          </div>
          <span class="text-xs text-base-content/60">
            <%= if @unifi_present do %>
              API key stored
            <% else %>
              No API key saved
            <% end %>
          </span>
        </div>
        <div class="grid gap-4 md:grid-cols-2">
          <.input field={@unifi_form[:name]} type="text" label="Controller Name" />
          <.input
            field={@unifi_form[:base_url]}
            type="text"
            label="Base URL"
            placeholder="https://controller:8443"
          />
          <.input
            field={@unifi_form[:api_key]}
            type="password"
            label="API Key"
            placeholder={if(@unifi_present, do: "stored", else: "required")}
          />
          <.input
            field={@unifi_form[:insecure_skip_verify]}
            type="checkbox"
            label="Skip TLS Verification"
          />
        </div>
      </div>

      <div class="flex items-center gap-2">
        <.ui_button type="submit" variant="primary">Save Discovery Job</.ui_button>
        <.link navigate={~p"/settings/networks/discovery"}>
          <.ui_button variant="ghost">Cancel</.ui_button>
        </.link>
      </div>
    </.form>
    """
  end

  # Sweep Groups Panel
  attr :groups, :list, required: true
  attr :sweep_command_statuses, :map, default: %{}
  attr :can_manage_networks, :boolean, default: false

  defp sweep_groups_panel(assigns) do
    ~H"""
    <.ui_panel>
      <:header>
        <div class="flex items-center justify-between w-full">
          <div>
            <div class="text-sm font-semibold">Sweep Groups</div>
            <p class="text-xs text-base-content/60">
              {length(@groups)} group(s) configured
            </p>
          </div>
          <.link navigate={~p"/settings/networks/groups/new"}>
            <.ui_button variant="primary" size="sm">
              <.icon name="hero-plus" class="size-4" /> New Group
            </.ui_button>
          </.link>
        </div>
      </:header>

      <div class="overflow-x-auto">
        <table class="table table-sm">
          <thead>
            <tr class="text-xs uppercase tracking-wide text-base-content/60">
              <th>Status</th>
              <th>Name</th>
              <th>Schedule</th>
              <th>Partition</th>
              <th>Agent</th>
              <th>Last Run</th>
              <th>Run Status</th>
              <th>Actions</th>
            </tr>
          </thead>
          <tbody>
            <tr :if={@groups == []}>
              <td colspan="8" class="text-center text-base-content/60 py-8">
                No sweep groups configured. Create one to start scanning your network.
              </td>
            </tr>
            <%= for group <- @groups do %>
              <tr class="hover:bg-base-200/40">
                <td>
                  <button
                    phx-click="toggle_group"
                    phx-value-id={group.id}
                    class="flex items-center gap-1.5 cursor-pointer"
                  >
                    <span class={"size-2 rounded-full #{if group.enabled, do: "bg-success", else: "bg-base-content/30"}"}>
                    </span>
                    <span class="text-xs">{if group.enabled, do: "Enabled", else: "Disabled"}</span>
                  </button>
                </td>
                <td>
                  <.link
                    navigate={~p"/settings/networks/groups/#{group.id}"}
                    class="font-medium hover:text-primary"
                  >
                    {group.name}
                  </.link>
                  <p :if={group.description} class="text-xs text-base-content/60 truncate max-w-xs">
                    {group.description}
                  </p>
                </td>
                <td class="font-mono text-xs">
                  {format_schedule(group)}
                </td>
                <td class="text-xs">
                  {group.partition}
                </td>
                <td class="text-xs text-base-content/60">
                  {group.agent_id || "All"}
                </td>
                <td class="text-xs text-base-content/60">
                  {format_last_run(group.last_run_at)}
                </td>
                <td class="text-xs">
                  <%= if status = Map.get(@sweep_command_statuses, group.id) do %>
                    <.ui_badge variant={command_status_variant(status)} size="xs">
                      {command_status_label(status)}
                    </.ui_badge>
                  <% else %>
                    <span class="text-xs text-base-content/40">—</span>
                  <% end %>
                </td>
                <td>
                  <div class="flex items-center gap-1">
                    <.ui_button
                      :if={@can_manage_networks}
                      id={"run-sweep-group-#{group.id}"}
                      variant="ghost"
                      size="xs"
                      phx-click="run_sweep_group"
                      phx-value-id={group.id}
                    >
                      <.icon name="hero-play" class="size-3" />
                    </.ui_button>
                    <.link navigate={~p"/settings/networks/groups/#{group.id}/edit"}>
                      <.ui_button variant="ghost" size="xs">
                        <.icon name="hero-pencil" class="size-3" />
                      </.ui_button>
                    </.link>
                    <.ui_button
                      variant="ghost"
                      size="xs"
                      phx-click="delete_group"
                      phx-value-id={group.id}
                      data-confirm="Are you sure you want to delete this sweep group?"
                    >
                      <.icon name="hero-trash" class="size-3" />
                    </.ui_button>
                  </div>
                </td>
              </tr>
            <% end %>
          </tbody>
        </table>
      </div>
    </.ui_panel>
    """
  end

  # Scanner Profiles Panel
  attr :profiles, :list, required: true

  defp profiles_panel(assigns) do
    ~H"""
    <.ui_panel>
      <:header>
        <div class="flex items-center justify-between w-full">
          <div>
            <div class="text-sm font-semibold">Scanner Profiles</div>
            <p class="text-xs text-base-content/60">
              {length(@profiles)} profile(s) available
            </p>
          </div>
          <.link navigate={~p"/settings/networks/profiles/new"}>
            <.ui_button variant="primary" size="sm">
              <.icon name="hero-plus" class="size-4" /> New Profile
            </.ui_button>
          </.link>
        </div>
      </:header>

      <div class="overflow-x-auto">
        <table class="table table-sm">
          <thead>
            <tr class="text-xs uppercase tracking-wide text-base-content/60">
              <th>Name</th>
              <th>Ports</th>
              <th>Modes</th>
              <th>Settings</th>
              <th>Actions</th>
            </tr>
          </thead>
          <tbody>
            <tr :if={@profiles == []}>
              <td colspan="5" class="text-center text-base-content/60 py-8">
                No scanner profiles configured. Create one to define reusable scan settings.
              </td>
            </tr>
            <%= for profile <- @profiles do %>
              <tr class="hover:bg-base-200/40">
                <td>
                  <div class="font-medium">{profile.name}</div>
                  <p :if={profile.description} class="text-xs text-base-content/60 truncate max-w-xs">
                    {profile.description}
                  </p>
                </td>
                <td class="text-xs font-mono">
                  {format_ports(profile.ports)}
                </td>
                <td>
                  <div class="flex flex-wrap gap-1">
                    <%= for mode <- (profile.sweep_modes || []) do %>
                      <.ui_badge variant="ghost" size="xs">{mode}</.ui_badge>
                    <% end %>
                  </div>
                </td>
                <td class="text-xs">
                  <div>Concurrency: {profile.concurrency}</div>
                  <div>Timeout: {profile.timeout}</div>
                </td>
                <td>
                  <div class="flex items-center gap-1">
                    <.link navigate={~p"/settings/networks/profiles/#{profile.id}/edit"}>
                      <.ui_button variant="ghost" size="xs">
                        <.icon name="hero-pencil" class="size-3" />
                      </.ui_button>
                    </.link>
                    <.ui_button
                      variant="ghost"
                      size="xs"
                      phx-click="delete_profile"
                      phx-value-id={profile.id}
                      data-confirm="Are you sure you want to delete this scanner profile?"
                    >
                      <.icon name="hero-trash" class="size-3" />
                    </.ui_button>
                  </div>
                </td>
              </tr>
            <% end %>
          </tbody>
        </table>
      </div>
    </.ui_panel>
    """
  end

  # Active Scans Panel
  attr :running, :list, required: true
  attr :recent, :list, required: true
  attr :groups, :list, required: true
  attr :execution_progress, :map, default: %{}

  defp active_scans_panel(assigns) do
    # Build a map of group_id -> group for quick lookup
    groups_map = Map.new(assigns.groups, &{&1.id, &1})
    assigns = assign(assigns, :groups_map, groups_map)

    ~H"""
    <div class="space-y-4">
      <!-- Statistics Cards -->
      <.scan_statistics running={@running} recent={@recent} />
      
    <!-- Running Scans -->
      <.ui_panel>
        <:header>
          <div class="flex items-center gap-2">
            <.icon name="hero-play-circle" class="size-5 text-success" />
            <div class="text-sm font-semibold">Running Scans</div>
            <span
              :if={length(@running) > 0}
              class="ml-1 inline-flex items-center justify-center size-5 text-xs font-semibold rounded-full bg-success/20 text-success"
            >
              {length(@running)}
            </span>
          </div>
        </:header>

        <div :if={@running == []} class="py-8 text-center text-base-content/60">
          <.icon name="hero-clock" class="size-8 mx-auto mb-2 opacity-50" />
          <p>No scans currently running</p>
        </div>

        <div :if={@running != []} class="space-y-3">
          <%= for execution <- @running do %>
            <.running_scan_card
              execution={execution}
              group={Map.get(@groups_map, execution.sweep_group_id)}
              progress={
                Map.get(@execution_progress, Map.get(execution, :execution_id) || execution.id)
              }
            />
          <% end %>
        </div>
      </.ui_panel>
      
    <!-- Recent Completions -->
      <.ui_panel>
        <:header>
          <div class="flex items-center gap-2">
            <.icon name="hero-clock" class="size-5 text-base-content/60" />
            <div class="text-sm font-semibold">Recent Completions</div>
          </div>
        </:header>

        <div :if={@recent == []} class="py-8 text-center text-base-content/60">
          <.icon name="hero-document-text" class="size-8 mx-auto mb-2 opacity-50" />
          <p>No recent scan executions</p>
        </div>

        <div :if={@recent != []} class="overflow-x-auto">
          <table class="table table-sm">
            <thead>
              <tr class="text-xs uppercase tracking-wide text-base-content/60">
                <th>Status</th>
                <th>Sweep Group</th>
                <th>Started</th>
                <th>Duration</th>
                <th>Hosts</th>
                <th>Success Rate</th>
                <th>Metrics</th>
              </tr>
            </thead>
            <tbody>
              <%= for execution <- @recent do %>
                <.recent_execution_row
                  execution={execution}
                  group={Map.get(@groups_map, execution.sweep_group_id)}
                />
              <% end %>
            </tbody>
          </table>
        </div>
      </.ui_panel>
    </div>
    """
  end

  # Inventory Cleanup Panel
  attr :form, :any, default: nil
  attr :settings, :any, default: nil

  defp inventory_cleanup_panel(assigns) do
    ~H"""
    <div class="rounded-xl border border-base-200 bg-base-100 p-6 shadow-sm space-y-6">
      <div class="flex flex-wrap items-start justify-between gap-4">
        <div>
          <h3 class="text-lg font-semibold text-base-content">Inventory Cleanup</h3>
          <p class="text-sm text-base-content/60">
            Purge soft-deleted devices after a retention window. Deleted devices can be restored
            if they are discovered again.
          </p>
        </div>
        <div class="flex items-center gap-2">
          <.ui_button
            variant="outline"
            size="sm"
            phx-click="run_cleanup_now"
            phx-confirm="Run cleanup now? This will permanently purge devices past the retention window."
          >
            <.icon name="hero-arrow-path" class="size-4" /> Run cleanup now
          </.ui_button>
        </div>
      </div>

      <div :if={is_nil(@form)} class="alert alert-warning">
        <.icon name="hero-exclamation-triangle" class="size-5" />
        <div>
          <div class="font-semibold">Cleanup settings unavailable</div>
          <div class="text-sm">Unable to load device cleanup settings.</div>
        </div>
      </div>

      <.form
        :if={not is_nil(@form)}
        for={@form}
        id="device-cleanup-form"
        phx-change="validate_cleanup_settings"
        phx-submit="save_cleanup_settings"
        class="grid grid-cols-1 md:grid-cols-2 gap-6"
      >
        <div class="space-y-4">
          <.input field={@form[:enabled]} type="checkbox" label="Enable scheduled cleanup" />
          <.input
            field={@form[:retention_days]}
            type="number"
            label="Retention (days)"
            min="1"
          />
          <.input
            field={@form[:cleanup_interval_minutes]}
            type="number"
            label="Cleanup interval (minutes)"
            min="5"
          />
          <.input
            field={@form[:batch_size]}
            type="number"
            label="Batch size"
            min="100"
          />
        </div>
        <div class="flex items-end">
          <div class="space-y-3">
            <p class="text-sm text-base-content/60">
              Cleanup runs on the configured interval and deletes devices that have been
              soft-deleted longer than the retention period.
            </p>
            <div class="flex gap-2">
              <.ui_button type="submit" variant="primary" size="sm">
                <.icon name="hero-check" class="size-4" /> Save settings
              </.ui_button>
            </div>
          </div>
        </div>
      </.form>
    </div>
    """
  end

  # Statistics Cards Component
  attr :running, :list, required: true
  attr :recent, :list, required: true

  defp scan_statistics(assigns) do
    # Calculate stats from recent executions
    completed_recent = Enum.filter(assigns.recent, &(&1.status == :completed))

    latest_completed = latest_execution(completed_recent)

    total_hosts = if latest_completed, do: latest_completed.hosts_total || 0, else: 0
    available_hosts = if latest_completed, do: latest_completed.hosts_available || 0, else: 0

    avg_success_rate = average_success_rate(completed_recent)

    failed_count = Enum.count(assigns.recent, &(&1.status == :failed))

    # Aggregate scanner metrics from recent completions
    aggregate_metrics = aggregate_scanner_metrics(completed_recent)

    assigns =
      assigns
      |> assign(:total_hosts, total_hosts)
      |> assign(:available_hosts, available_hosts)
      |> assign(:avg_success_rate, avg_success_rate)
      |> assign(:failed_count, failed_count)
      |> assign(:completed_count, length(completed_recent))
      |> assign(:aggregate_metrics, aggregate_metrics)
      |> assign(:latest_completed, latest_completed)

    ~H"""
    <div class="space-y-4">
      <!-- Main Stats -->
      <div class="grid grid-cols-2 md:grid-cols-4 gap-4">
        <div class="bg-base-200/50 rounded-lg p-4">
          <div class="text-xs text-base-content/60 uppercase tracking-wide">Running</div>
          <div class="text-2xl font-bold mt-1 flex items-center gap-2">
            {length(@running)}
            <span :if={length(@running) > 0} class="size-2 rounded-full bg-success animate-pulse">
            </span>
          </div>
        </div>
        <div class="bg-base-200/50 rounded-lg p-4">
          <div class="text-xs text-base-content/60 uppercase tracking-wide">Hosts Scanned</div>
          <div class="text-2xl font-bold mt-1">{@total_hosts}</div>
          <div class="text-xs text-base-content/60">
            {@available_hosts} available
            <%= if @latest_completed do %>
              • {format_last_run(@latest_completed.completed_at || @latest_completed.updated_at)}
            <% end %>
          </div>
        </div>
        <div class="bg-base-200/50 rounded-lg p-4">
          <div class="text-xs text-base-content/60 uppercase tracking-wide">Avg Success Rate</div>
          <div class={"text-2xl font-bold mt-1 #{success_rate_color(@avg_success_rate)}"}>
            {@avg_success_rate}%
          </div>
        </div>
        <div class="bg-base-200/50 rounded-lg p-4">
          <div class="text-xs text-base-content/60 uppercase tracking-wide">Recent Executions</div>
          <div class="text-2xl font-bold mt-1">{@completed_count}</div>
          <div :if={@failed_count > 0} class="text-xs text-error">{@failed_count} failed</div>
        </div>
      </div>
      
    <!-- Scanner Metrics Summary (only if we have metrics) -->
      <div :if={@aggregate_metrics.has_data} class="bg-base-200/30 rounded-lg p-4">
        <div class="flex items-center gap-2 mb-3">
          <.icon name="hero-chart-bar" class="size-4 text-base-content/60" />
          <span class="text-xs text-base-content/60 uppercase tracking-wide">
            Scanner Performance (Recent Scans)
          </span>
        </div>
        <div class="grid grid-cols-2 md:grid-cols-5 gap-4 text-sm">
          <div>
            <div class="text-base-content/60 text-xs">Packets Sent</div>
            <div class="font-semibold font-mono">
              {format_number(@aggregate_metrics.packets_sent)}
            </div>
          </div>
          <div>
            <div class="text-base-content/60 text-xs">Packets Received</div>
            <div class="font-semibold font-mono">
              {format_number(@aggregate_metrics.packets_recv)}
            </div>
          </div>
          <div>
            <div class="text-base-content/60 text-xs">Avg Drop Rate</div>
            <div class={"font-semibold font-mono #{if to_float(@aggregate_metrics.avg_drop_rate) > 1.0, do: "text-warning", else: ""}"}>
              {Float.round(to_float(@aggregate_metrics.avg_drop_rate), 2)}%
            </div>
          </div>
          <div>
            <div class="text-base-content/60 text-xs">Total Retries</div>
            <div class="font-semibold font-mono">
              {format_number(@aggregate_metrics.retries_successful)}/{format_number(
                @aggregate_metrics.retries_attempted
              )}
            </div>
          </div>
          <div>
            <div class="text-base-content/60 text-xs">Rate Deferrals</div>
            <div class={"font-semibold font-mono #{if @aggregate_metrics.rate_limit_deferrals > 0, do: "text-info", else: ""}"}>
              {format_number(@aggregate_metrics.rate_limit_deferrals)}
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp average_success_rate([]), do: 0.0

  defp average_success_rate(executions) do
    executions
    |> Enum.map(&execution_success_rate/1)
    |> Enum.sum()
    |> Kernel./(length(executions))
    |> Float.round(1)
  end

  defp execution_success_rate(execution) do
    case execution.hosts_total do
      total when is_integer(total) and total > 0 ->
        (execution.hosts_available || 0) / total * 100

      _ ->
        0
    end
  end

  defp aggregate_scanner_metrics(executions) do
    executions_with_metrics =
      Enum.filter(executions, fn e ->
        e.scanner_metrics && e.scanner_metrics != %{}
      end)

    if Enum.empty?(executions_with_metrics) do
      %{has_data: false}
    else
      packets_sent =
        Enum.reduce(executions_with_metrics, 0, fn e, acc ->
          acc + (get_in(e.scanner_metrics, ["packets_sent"]) || 0)
        end)

      packets_recv =
        Enum.reduce(executions_with_metrics, 0, fn e, acc ->
          acc + (get_in(e.scanner_metrics, ["packets_recv"]) || 0)
        end)

      retries_attempted =
        Enum.reduce(executions_with_metrics, 0, fn e, acc ->
          acc + (get_in(e.scanner_metrics, ["retries_attempted"]) || 0)
        end)

      retries_successful =
        Enum.reduce(executions_with_metrics, 0, fn e, acc ->
          acc + (get_in(e.scanner_metrics, ["retries_successful"]) || 0)
        end)

      rate_limit_deferrals =
        Enum.reduce(executions_with_metrics, 0, fn e, acc ->
          acc + (get_in(e.scanner_metrics, ["rate_limit_deferrals"]) || 0)
        end)

      # Calculate average drop rate
      drop_rates =
        executions_with_metrics
        |> Enum.map(fn e -> get_in(e.scanner_metrics, ["rx_drop_rate_percent"]) || 0.0 end)

      avg_drop_rate =
        if Enum.empty?(drop_rates) do
          0.0
        else
          Enum.sum(drop_rates) / length(drop_rates)
        end

      %{
        has_data: true,
        packets_sent: packets_sent,
        packets_recv: packets_recv,
        retries_attempted: retries_attempted,
        retries_successful: retries_successful,
        rate_limit_deferrals: rate_limit_deferrals,
        avg_drop_rate: avg_drop_rate
      }
    end
  end

  # Computes progress data for running scan card (extracted to reduce complexity)
  defp compute_scan_progress(execution, progress) do
    started_at = Map.get(execution, :started_at)

    elapsed_ms =
      if started_at, do: DateTime.diff(DateTime.utc_now(), started_at, :millisecond), else: 0

    {hosts_processed, hosts_available, hosts_failed, hosts_total, batch_info} =
      if progress do
        batch =
          if progress.total_batches, do: "Batch #{progress.batch_num}/#{progress.total_batches}"

        {progress.hosts_processed, progress.hosts_available, progress.hosts_failed,
         progress.hosts_total, batch}
      else
        processed = Map.get(execution, :hosts_available, 0) + Map.get(execution, :hosts_failed, 0)

        {processed, Map.get(execution, :hosts_available) || 0,
         Map.get(execution, :hosts_failed) || 0, Map.get(execution, :hosts_total), nil}
      end

    hosts_total_display = compute_hosts_total_display(hosts_total, hosts_processed)

    %{
      elapsed_ms: elapsed_ms,
      hosts_processed: hosts_processed,
      hosts_available: hosts_available,
      hosts_failed: hosts_failed,
      hosts_total: hosts_total,
      hosts_total_display: hosts_total_display,
      batch_info: batch_info,
      has_progress: progress != nil
    }
  end

  defp compute_hosts_total_display(hosts_total, hosts_processed) do
    cond do
      is_number(hosts_total) and hosts_total > 0 -> hosts_total
      is_number(hosts_processed) and hosts_processed > 0 -> hosts_processed
      true -> "—"
    end
  end

  # Running Scan Card Component
  attr :execution, :map, required: true
  attr :group, :map, default: nil
  attr :progress, :map, default: nil

  defp running_scan_card(assigns) do
    progress_data = compute_scan_progress(assigns.execution, assigns.progress)

    assigns =
      assigns
      |> assign(:elapsed_ms, progress_data.elapsed_ms)
      |> assign(:hosts_processed, progress_data.hosts_processed)
      |> assign(:hosts_available, progress_data.hosts_available)
      |> assign(:hosts_failed, progress_data.hosts_failed)
      |> assign(:hosts_total, progress_data.hosts_total)
      |> assign(:hosts_total_display, progress_data.hosts_total_display)
      |> assign(:batch_info, progress_data.batch_info)
      |> assign(:has_progress, progress_data.has_progress)

    ~H"""
    <div class="bg-base-200/30 rounded-lg p-4 border border-base-200">
      <div class="flex items-start justify-between">
        <div class="flex items-center gap-3">
          <div class="relative">
            <span class="loading loading-spinner loading-sm text-success"></span>
          </div>
          <div>
            <div class="font-medium">
              {if @group, do: @group.name, else: "Unknown Group"}
            </div>
            <div class="text-xs text-base-content/60 flex items-center gap-2">
              <span :if={Map.get(@execution, :agent_id)}>
                <.icon name="hero-server" class="size-3 inline" />
                {Map.get(@execution, :agent_id)}
              </span>
              <span>Started {format_relative_time(Map.get(@execution, :started_at))}</span>
            </div>
          </div>
        </div>
        <div class="text-right">
          <div class="text-sm font-mono">{format_duration(@elapsed_ms)}</div>
          <div class="text-xs text-base-content/60">
            <span class="text-success">{@hosts_available}</span>
            <span :if={@hosts_failed > 0} class="text-error ml-1">/ {@hosts_failed} failed</span>
            <span>
              of {@hosts_total_display} hosts
            </span>
          </div>
          <div :if={@batch_info} class="text-xs text-base-content/40 mt-0.5">
            {@batch_info}
          </div>
        </div>
      </div>
      
    <!-- Progress bar with real-time updates -->
      <div class="mt-3">
        <div class="h-1.5 bg-base-300 rounded-full overflow-hidden">
          <div
            class="h-full bg-success transition-all duration-300"
            style={"width: #{batch_progress_percent(@progress)}%"}
          >
          </div>
        </div>
        <div
          :if={@has_progress && @progress.total_batches}
          class="flex justify-between text-xs text-base-content/40 mt-1"
        >
          <span>Processing...</span>
          <span>{batch_progress_percent(@progress)}%</span>
        </div>
      </div>
    </div>
    """
  end

  # Recent Execution Row Component
  attr :execution, :map, required: true
  attr :group, :map, default: nil

  defp recent_execution_row(assigns) do
    has_metrics = assigns.execution.scanner_metrics && assigns.execution.scanner_metrics != %{}
    assigns = assign(assigns, :has_metrics, has_metrics)

    ~H"""
    <tr class="hover:bg-base-200/40">
      <td>
        <.execution_status_badge status={@execution.status} />
      </td>
      <td>
        <div class="font-medium">
          {if @group, do: @group.name, else: "Unknown Group"}
        </div>
        <div :if={@execution.agent_id} class="text-xs text-base-content/60">
          {@execution.agent_id}
        </div>
      </td>
      <td class="text-xs text-base-content/60">
        {format_relative_time(@execution.started_at)}
      </td>
      <td class="font-mono text-xs">
        {format_duration(@execution.duration_ms)}
      </td>
      <td class="text-xs">
        <span :if={@execution.hosts_total}>
          {@execution.hosts_available || 0} / {@execution.hosts_total}
        </span>
        <span :if={!@execution.hosts_total} class="text-base-content/40">—</span>
      </td>
      <td>
        <.success_rate_badge execution={@execution} />
      </td>
      <td>
        <div :if={@has_metrics} class="dropdown dropdown-end">
          <div tabindex="0" role="button" class="btn btn-ghost btn-xs">
            <.icon name="hero-chart-bar" class="size-4" />
          </div>
          <div
            tabindex="0"
            class="dropdown-content z-[1] card card-compact w-80 p-2 shadow bg-base-100 border border-base-200"
          >
            <div class="card-body p-2">
              <h3 class="text-sm font-semibold mb-2">Scanner Metrics</h3>
              <.scanner_metrics_grid metrics={@execution.scanner_metrics} />
            </div>
          </div>
        </div>
        <span :if={!@has_metrics} class="text-base-content/40 text-xs">—</span>
      </td>
    </tr>
    """
  end

  # Scanner Metrics Grid Component
  attr :metrics, :map, required: true

  defp scanner_metrics_grid(assigns) do
    metrics = assigns.metrics || %{}

    assigns =
      assigns
      |> assign(:packets_sent, Map.get(metrics, "packets_sent", 0))
      |> assign(:packets_recv, Map.get(metrics, "packets_recv", 0))
      |> assign(:packets_dropped, Map.get(metrics, "packets_dropped", 0))
      |> assign(:retries_attempted, Map.get(metrics, "retries_attempted", 0))
      |> assign(:retries_successful, Map.get(metrics, "retries_successful", 0))
      |> assign(:rate_limit_deferrals, Map.get(metrics, "rate_limit_deferrals", 0))
      |> assign(:rx_drop_rate_percent, Map.get(metrics, "rx_drop_rate_percent", 0.0))
      |> assign(:port_exhaustion_count, Map.get(metrics, "port_exhaustion_count", 0))

    ~H"""
    <div class="grid grid-cols-2 gap-2 text-xs">
      <div class="bg-base-200/50 rounded p-2">
        <div class="text-base-content/60">Packets Sent</div>
        <div class="font-semibold font-mono">{format_number(@packets_sent)}</div>
      </div>
      <div class="bg-base-200/50 rounded p-2">
        <div class="text-base-content/60">Packets Received</div>
        <div class="font-semibold font-mono">{format_number(@packets_recv)}</div>
      </div>
      <div class="bg-base-200/50 rounded p-2">
        <div class="text-base-content/60">Packets Dropped</div>
        <div class={"font-semibold font-mono #{if @packets_dropped > 0, do: "text-warning", else: ""}"}>
          {format_number(@packets_dropped)}
        </div>
      </div>
      <div class="bg-base-200/50 rounded p-2">
        <div class="text-base-content/60">RX Drop Rate</div>
        <div class={"font-semibold font-mono #{if to_float(@rx_drop_rate_percent) > 1.0, do: "text-warning", else: ""}"}>
          {Float.round(to_float(@rx_drop_rate_percent), 2)}%
        </div>
      </div>
      <div class="bg-base-200/50 rounded p-2">
        <div class="text-base-content/60">Retries</div>
        <div class="font-semibold font-mono">
          {format_number(@retries_successful)}/{format_number(@retries_attempted)}
        </div>
      </div>
      <div class="bg-base-200/50 rounded p-2">
        <div class="text-base-content/60">Rate Limit Deferrals</div>
        <div class={"font-semibold font-mono #{if @rate_limit_deferrals > 0, do: "text-info", else: ""}"}>
          {format_number(@rate_limit_deferrals)}
        </div>
      </div>
      <div :if={@port_exhaustion_count > 0} class="col-span-2 bg-error/10 rounded p-2">
        <div class="text-error/80">Port Exhaustion Events</div>
        <div class="font-semibold font-mono text-error">{format_number(@port_exhaustion_count)}</div>
      </div>
    </div>
    """
  end

  defp format_number(nil), do: "0"
  defp format_number(n) when is_float(n), do: Float.round(n, 2) |> to_string()

  defp format_number(n) when is_integer(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/.{3}/, "\\0,")
    |> String.reverse()
    |> String.trim_leading(",")
  end

  defp format_number(n), do: to_string(n)

  # Convert any number to float for Float.round/2 compatibility
  defp to_float(nil), do: 0.0
  defp to_float(n) when is_float(n), do: n
  defp to_float(n) when is_integer(n), do: n * 1.0
  defp to_float(n) when is_number(n), do: n * 1.0

  # Execution Status Badge
  attr :status, :atom, required: true

  defp execution_status_badge(assigns) do
    ~H"""
    <span class={[
      "inline-flex items-center gap-1 px-2 py-0.5 rounded-full text-xs font-medium",
      status_badge_class(@status)
    ]}>
      <.icon name={status_icon(@status)} class="size-3" />
      {status_label(@status)}
    </span>
    """
  end

  # Success Rate Badge
  attr :execution, :map, required: true

  defp success_rate_badge(assigns) do
    rate =
      if assigns.execution.hosts_total && assigns.execution.hosts_total > 0 do
        ((assigns.execution.hosts_available || 0) / assigns.execution.hosts_total * 100)
        |> Float.round(1)
      else
        nil
      end

    assigns = assign(assigns, :rate, rate)

    ~H"""
    <span :if={@rate} class={"text-xs font-medium #{success_rate_color(@rate)}"}>
      {@rate}%
    </span>
    <span :if={!@rate} class="text-xs text-base-content/40">—</span>
    """
  end

  # Helper functions for Active Scans panel

  defp status_badge_class(:completed), do: "bg-success/20 text-success"
  defp status_badge_class(:failed), do: "bg-error/20 text-error"
  defp status_badge_class(:running), do: "bg-info/20 text-info"
  defp status_badge_class(_), do: "bg-base-200 text-base-content/60"

  defp status_icon(:completed), do: "hero-check-circle"
  defp status_icon(:failed), do: "hero-x-circle"
  defp status_icon(:running), do: "hero-arrow-path"
  defp status_icon(_), do: "hero-clock"

  defp status_label(:completed), do: "Completed"
  defp status_label(:failed), do: "Failed"
  defp status_label(:running), do: "Running"
  defp status_label(:pending), do: "Pending"
  defp status_label(_), do: "Unknown"

  defp success_rate_color(rate) when rate >= 90, do: "text-success"
  defp success_rate_color(rate) when rate >= 70, do: "text-warning"
  defp success_rate_color(_rate), do: "text-error"

  # Calculate progress percentage from batch info
  defp batch_progress_percent(%{batch_num: batch_num, total_batches: total_batches})
       when is_integer(batch_num) and is_integer(total_batches) and total_batches > 0 do
    Float.round(batch_num / total_batches * 100, 1)
  end

  defp batch_progress_percent(_), do: 0

  defp format_relative_time(nil), do: "—"

  defp format_relative_time(%DateTime{} = dt) do
    diff_seconds = DateTime.diff(DateTime.utc_now(), dt, :second)

    cond do
      diff_seconds < 60 -> "#{diff_seconds}s ago"
      diff_seconds < 3600 -> "#{div(diff_seconds, 60)}m ago"
      diff_seconds < 86_400 -> "#{div(diff_seconds, 3600)}h ago"
      true -> Calendar.strftime(dt, "%Y-%m-%d %H:%M")
    end
  end

  defp format_relative_time(_), do: "—"

  defp format_duration(nil), do: "—"
  defp format_duration(ms) when is_integer(ms) and ms < 1000, do: "#{ms}ms"

  defp format_duration(ms) when is_integer(ms) and ms < 60_000,
    do: "#{Float.round(ms / 1000, 1)}s"

  defp format_duration(ms) when is_integer(ms) do
    minutes = div(ms, 60_000)
    seconds = div(rem(ms, 60_000), 1000)
    "#{minutes}m #{seconds}s"
  end

  defp format_duration(_), do: "—"

  # Group Form
  attr :form, :any, required: true
  attr :show_form, :atom, required: true
  attr :profiles, :list, required: true
  attr :agents, :list, default: []
  attr :target_device_count, :integer, default: nil
  attr :builder_open, :boolean, default: false
  attr :builder_sync, :boolean, default: true
  attr :builder, :map, default: %{}

  defp group_form(assigns) do
    assigns = assign(assigns, :config, Catalog.entity("devices"))

    ~H"""
    <.ui_panel>
      <:header>
        <div class="flex items-center justify-between w-full">
          <div class="text-sm font-semibold">
            {if @show_form == :new_group, do: "New Sweep Group", else: "Edit Sweep Group"}
          </div>
          <.link navigate={~p"/settings/networks"}>
            <.ui_button variant="ghost" size="sm">Cancel</.ui_button>
          </.link>
        </div>
      </:header>

      <form id="sweep-group-builder-form" phx-change="builder_change" phx-debounce="200"></form>

      <.form
        for={@form}
        id="sweep-group-form"
        phx-submit="save_group"
        phx-change="validate_group"
        class="space-y-6"
      >
        <!-- Basic Info Section -->
        <div class="space-y-4">
          <h3 class="text-sm font-semibold text-base-content/80 uppercase tracking-wide">
            Basic Information
          </h3>

          <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
            <div>
              <label class="label">
                <span class="label-text">Name</span>
              </label>
              <.input type="text" field={@form[:name]} class="input input-bordered w-full" required />
            </div>
            <div>
              <label class="label">
                <span class="label-text">Partition</span>
              </label>
              <.input
                type="text"
                field={@form[:partition]}
                class="input input-bordered w-full"
                placeholder="default"
              />
            </div>
          </div>

          <div>
            <label class="label">
              <span class="label-text">Description</span>
            </label>
            <.input
              type="textarea"
              field={@form[:description]}
              class="textarea textarea-bordered w-full"
              rows="2"
            />
          </div>
        </div>
        
    <!-- Schedule Section -->
        <div class="space-y-4">
          <h3 class="text-sm font-semibold text-base-content/80 uppercase tracking-wide">Schedule</h3>

          <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
            <div>
              <label class="label">
                <span class="label-text">Scan Interval</span>
              </label>
              <.input
                type="select"
                field={@form[:interval]}
                class="select select-bordered w-full"
                options={[
                  {"5 minutes", "5m"},
                  {"15 minutes", "15m"},
                  {"30 minutes", "30m"},
                  {"1 hour", "1h"},
                  {"2 hours", "2h"},
                  {"6 hours", "6h"},
                  {"12 hours", "12h"},
                  {"24 hours", "24h"}
                ]}
              />
            </div>
            <div>
              <label class="label">
                <span class="label-text">Scanner Profile</span>
              </label>
              <.input
                type="select"
                field={@form[:profile_id]}
                class="select select-bordered w-full"
                options={[{"Default settings", ""} | Enum.map(@profiles, &{&1.name, &1.id})]}
              />
            </div>
          </div>

          <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
            <div>
              <label class="label">
                <span class="label-text">Agent</span>
              </label>
              <.input
                type="select"
                field={@form[:agent_id]}
                class="select select-bordered w-full"
                options={[{"All agents", ""} | Enum.map(@agents, &{agent_display_name(&1), &1.uid})]}
              />
              <label class="label">
                <span class="label-text-alt text-base-content/50">
                  Pin this sweep config to a specific agent
                </span>
              </label>
            </div>
          </div>
        </div>
        
    <!-- Target Criteria Section -->
        <div class="space-y-4">
          <div class="flex flex-col gap-2 md:flex-row md:items-end md:justify-between">
            <div>
              <h3 class="text-sm font-semibold text-base-content/80 uppercase tracking-wide">
                Device Targeting
              </h3>
              <p class="text-xs text-base-content/60">
                SRQL query to select devices for this sweep group.
              </p>
            </div>
          </div>

          <div>
            <label class="label"><span class="label-text">Target Query (SRQL)</span></label>
            <div class="flex items-center gap-2">
              <div class="flex-1">
                <.input
                  type="text"
                  field={@form[:target_query]}
                  class="input input-bordered w-full font-mono text-sm"
                  placeholder="e.g., tags.env:prod hostname:%db%"
                />
              </div>
              <.ui_icon_button
                active={@builder_open}
                aria-label="Toggle query builder"
                title="Query builder"
                phx-click="builder_toggle"
              >
                <.icon name="hero-adjustments-horizontal" class="size-4" />
              </.ui_icon_button>
            </div>
            <label class="label">
              <span class="label-text-alt text-base-content/50">
                SRQL filters to match devices. Examples: <code class="bg-base-200 px-1 rounded">tags.environment:production</code>, <code class="bg-base-200 px-1 rounded">hostname:%prod%</code>,
                <code class="bg-base-200 px-1 rounded">type:Server</code>
              </span>
            </label>
          </div>

          <div :if={@builder_open} class="border border-base-200 rounded-lg p-4 bg-base-100/50">
            <div class="flex items-center justify-between mb-4">
              <div class="text-sm font-semibold">Query Builder</div>
              <div class="flex items-center gap-2">
                <.ui_badge :if={not @builder_sync} size="sm">Not applied</.ui_badge>
                <.ui_button
                  :if={not @builder_sync}
                  size="sm"
                  variant="ghost"
                  type="button"
                  phx-click="builder_apply"
                >
                  Apply to query
                </.ui_button>
              </div>
            </div>

            <div class="flex flex-col gap-4">
              <div class="flex flex-col gap-3">
                <div class="text-xs text-base-content/60 font-medium">
                  Match devices where:
                </div>

                <%= for {filter, idx} <- Enum.with_index(Map.get(@builder, "filters", [])) do %>
                  <div class="flex items-center gap-3">
                    <.query_builder_pill label="Filter">
                      <%= if @config.filter_fields == [] do %>
                        <.ui_inline_input
                          type="text"
                          name={"builder[filters][#{idx}][field]"}
                          value={filter["field"] || ""}
                          placeholder="field"
                          form="sweep-group-builder-form"
                          class="w-40 placeholder:text-base-content/40"
                        />
                      <% else %>
                        <.ui_inline_select
                          name={"builder[filters][#{idx}][field]"}
                          form="sweep-group-builder-form"
                        >
                          <%= for field <- @config.filter_fields do %>
                            <option value={field} selected={filter["field"] == field}>
                              {field}
                            </option>
                          <% end %>
                        </.ui_inline_select>
                      <% end %>

                      <.ui_inline_select
                        name={"builder[filters][#{idx}][op]"}
                        class="text-xs text-base-content/70"
                        form="sweep-group-builder-form"
                      >
                        <option
                          value="contains"
                          selected={(filter["op"] || "contains") == "contains"}
                        >
                          contains
                        </option>
                        <option value="not_contains" selected={filter["op"] == "not_contains"}>
                          does not contain
                        </option>
                        <option value="equals" selected={filter["op"] == "equals"}>
                          equals
                        </option>
                        <option value="not_equals" selected={filter["op"] == "not_equals"}>
                          does not equal
                        </option>
                      </.ui_inline_select>

                      <.ui_inline_input
                        type="text"
                        name={"builder[filters][#{idx}][value]"}
                        value={filter["value"] || ""}
                        placeholder="value"
                        form="sweep-group-builder-form"
                        class="placeholder:text-base-content/40 w-48"
                      />
                    </.query_builder_pill>

                    <.ui_icon_button
                      size="xs"
                      aria-label="Remove filter"
                      title="Remove filter"
                      type="button"
                      phx-click="builder_remove_filter"
                      phx-value-idx={idx}
                    >
                      <.icon name="hero-x-mark" class="size-4" />
                    </.ui_icon_button>
                  </div>
                <% end %>

                <button
                  type="button"
                  class="inline-flex items-center gap-2 rounded-md border border-dashed border-primary/40 px-3 py-2 text-sm text-primary/80 hover:bg-primary/5 w-fit"
                  phx-click="builder_add_filter"
                >
                  <.icon name="hero-plus" class="size-4" /> Add filter
                </button>
              </div>
            </div>
          </div>

          <div :if={@target_device_count != nil} class="flex items-center gap-2">
            <.icon name="hero-device-phone-mobile" class="size-4 text-base-content/60" />
            <span class="text-sm">
              <span class="font-semibold">{@target_device_count}</span>
              <span class="text-base-content/60">device(s) match this query</span>
            </span>
          </div>
        </div>
        
    <!-- Static Targets Section -->
        <div class="space-y-4">
          <h3 class="text-sm font-semibold text-base-content/80 uppercase tracking-wide">
            Static Targets
          </h3>
          <p class="text-xs text-base-content/60">
            IPs, CIDRs, or ranges to always include, regardless of tags.
          </p>
          <.input
            type="textarea"
            field={@form[:static_targets]}
            value={format_static_targets(@form[:static_targets].value)}
            class="textarea textarea-bordered w-full font-mono text-sm"
            rows="3"
            placeholder="10.0.1.0/24&#10;192.168.1.0/24&#10;10.0.0.10-10.0.0.50"
          />
        </div>
        
    <!-- Enable Toggle -->
        <div class="flex items-center gap-2 pt-2">
          <.input type="checkbox" field={@form[:enabled]} class="checkbox checkbox-primary" />
          <label class="label-text">Enable this sweep group</label>
        </div>
        
    <!-- Actions -->
        <div class="flex justify-end gap-2 pt-4 border-t border-base-200">
          <.link navigate={~p"/settings/networks"}>
            <.ui_button variant="ghost">Cancel</.ui_button>
          </.link>
          <.ui_button type="submit" variant="primary">Save Sweep Group</.ui_button>
        </div>
      </.form>
    </.ui_panel>
    """
  end

  # Profile Form
  attr :form, :any, required: true
  attr :show_form, :atom, required: true

  defp profile_form(assigns) do
    ~H"""
    <.ui_panel>
      <:header>
        <div class="flex items-center justify-between w-full">
          <div class="text-sm font-semibold">
            {if @show_form == :new_profile, do: "New Scanner Profile", else: "Edit Scanner Profile"}
          </div>
          <.link navigate={~p"/settings/networks"}>
            <.ui_button variant="ghost" size="sm">Cancel</.ui_button>
          </.link>
        </div>
      </:header>

      <.form for={@form} phx-submit="save_profile" phx-change="validate_profile" class="space-y-4">
        <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
          <div>
            <label class="label">
              <span class="label-text">Name</span>
            </label>
            <.input type="text" field={@form[:name]} class="input input-bordered w-full" required />
          </div>
          <div>
            <label class="label">
              <span class="label-text">Timeout</span>
            </label>
            <.input
              type="select"
              field={@form[:timeout]}
              class="select select-bordered w-full"
              options={[
                {"1 second", "1s"},
                {"3 seconds", "3s"},
                {"5 seconds", "5s"},
                {"10 seconds", "10s"},
                {"30 seconds", "30s"}
              ]}
            />
          </div>
        </div>

        <div>
          <label class="label">
            <span class="label-text">Description</span>
          </label>
          <.input
            type="textarea"
            field={@form[:description]}
            class="textarea textarea-bordered w-full"
            rows="2"
          />
        </div>

        <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
          <div>
            <label class="label">
              <span class="label-text">Ports (comma-separated)</span>
            </label>
            <.input
              type="text"
              field={@form[:ports]}
              value={format_ports_input(@form[:ports].value)}
              class="input input-bordered w-full font-mono"
              placeholder="22, 80, 443, 3389, 8080"
            />
          </div>
          <div>
            <label class="label">
              <span class="label-text">Concurrency</span>
            </label>
            <.input
              type="number"
              field={@form[:concurrency]}
              class="input input-bordered w-full"
              min="1"
              max="500"
            />
          </div>
        </div>

        <div>
          <label class="label">
            <span class="label-text">Sweep Modes</span>
          </label>
          <% selected_modes = Enum.map(@form[:sweep_modes].value || [], &to_string/1) %>
          <div class="flex flex-wrap gap-4">
            <label class="flex items-center gap-2 cursor-pointer">
              <input
                type="checkbox"
                name="form[sweep_modes][]"
                value="icmp"
                class="checkbox"
                checked={Enum.member?(selected_modes, "icmp")}
              />
              <span>ICMP (Ping)</span>
            </label>
            <label class="flex items-center gap-2 cursor-pointer">
              <input
                type="checkbox"
                name="form[sweep_modes][]"
                value="tcp"
                class="checkbox"
                checked={Enum.member?(selected_modes, "tcp")}
              />
              <span>TCP</span>
            </label>
            <label class="flex items-center gap-2 cursor-pointer">
              <input
                type="checkbox"
                name="form[sweep_modes][]"
                value="arp"
                class="checkbox"
                checked={Enum.member?(selected_modes, "arp")}
              />
              <span>ARP</span>
            </label>
          </div>
        </div>

        <div class="flex items-center gap-2">
          <.input type="checkbox" field={@form[:enabled]} class="checkbox checkbox-primary" />
          <label class="label-text">Enabled</label>
        </div>

        <div class="flex justify-end gap-2 pt-4">
          <.link navigate={~p"/settings/networks"}>
            <.ui_button variant="ghost">Cancel</.ui_button>
          </.link>
          <.ui_button type="submit" variant="primary">Save Profile</.ui_button>
        </div>
      </.form>
    </.ui_panel>
    """
  end

  # Group Detail View
  attr :group, :map, required: true

  defp group_detail(assigns) do
    ~H"""
    <div class="space-y-4">
      <div class="flex items-center justify-between">
        <div class="flex items-center gap-3">
          <.link navigate={~p"/settings/networks"}>
            <.ui_button variant="ghost" size="sm">
              <.icon name="hero-arrow-left" class="size-4" />
            </.ui_button>
          </.link>
          <div>
            <h2 class="text-xl font-semibold">{@group.name}</h2>
            <p :if={@group.description} class="text-sm text-base-content/60">{@group.description}</p>
          </div>
        </div>
        <div class="flex items-center gap-2">
          <.link navigate={~p"/settings/networks/groups/#{@group.id}/edit"}>
            <.ui_button variant="outline" size="sm">
              <.icon name="hero-pencil" class="size-4" /> Edit
            </.ui_button>
          </.link>
        </div>
      </div>

      <.ui_panel>
        <:header>
          <div class="text-sm font-semibold">Configuration</div>
        </:header>

        <div class="grid grid-cols-2 md:grid-cols-4 gap-4">
          <div>
            <div class="text-xs text-base-content/60 uppercase">Status</div>
            <div class="flex items-center gap-1.5 mt-1">
              <span class={"size-2 rounded-full #{if @group.enabled, do: "bg-success", else: "bg-base-content/30"}"}>
              </span>
              <span>{if @group.enabled, do: "Enabled", else: "Disabled"}</span>
            </div>
          </div>
          <div>
            <div class="text-xs text-base-content/60 uppercase">Schedule</div>
            <div class="mt-1 font-mono">{format_schedule(@group)}</div>
          </div>
          <div>
            <div class="text-xs text-base-content/60 uppercase">Partition</div>
            <div class="mt-1">{@group.partition}</div>
          </div>
          <div>
            <div class="text-xs text-base-content/60 uppercase">Last Run</div>
            <div class="mt-1">{format_last_run(@group.last_run_at)}</div>
          </div>
        </div>
      </.ui_panel>

      <.ui_panel>
        <:header>
          <div class="text-sm font-semibold">Targets</div>
        </:header>

        <div class="space-y-2">
          <div :if={@group.static_targets != []} class="space-y-1">
            <div class="text-xs text-base-content/60 uppercase">Static Targets</div>
            <div class="flex flex-wrap gap-2">
              <%= for target <- (@group.static_targets || []) do %>
                <.ui_badge variant="ghost" size="sm" class="font-mono">{target}</.ui_badge>
              <% end %>
            </div>
          </div>
          <div :if={@group.target_query not in [nil, ""]} class="space-y-2">
            <div class="text-xs text-base-content/60 uppercase">Target Query (SRQL)</div>
            <div class="font-mono text-sm text-base-content/80 break-words">
              {@group.target_query}
            </div>
          </div>
          <div :if={@group.static_targets == [] and @group.target_query in [nil, ""]}>
            <p class="text-base-content/60">No targets configured.</p>
          </div>
        </div>
      </.ui_panel>
    </div>
    """
  end

  # Helpers

  defp load_sweep_groups(scope) do
    case Ash.read(SweepGroup, scope: scope) do
      {:ok, groups} -> groups
      {:error, _} -> []
    end
  end

  defp load_sweep_group(scope, id) do
    case Ash.get(SweepGroup, id, scope: scope) do
      {:ok, group} -> group
      {:error, _} -> nil
    end
  end

  defp fetch_sweep_group(scope, id) do
    case load_sweep_group(scope, id) do
      nil -> {:error, :not_found}
      group -> {:ok, group}
    end
  end

  defp load_sweep_profiles(scope) do
    case Ash.read(SweepProfile, scope: scope) do
      {:ok, profiles} -> profiles
      {:error, _} -> []
    end
  end

  defp load_agents(scope) do
    require Logger

    case can_manage_networks?(scope) do
      false ->
        []

      true ->
        result = Ash.read(Agent, domain: ServiceRadar.Infrastructure, scope: scope)

        case result do
          {:ok, agents} ->
            Logger.debug("load_agents: loaded #{length(agents)} agents")
            agents

          {:error, reason} ->
            Logger.warning("load_agents: failed to load agents - #{inspect(reason)}")
            []
        end
    end
  end

  defp can_manage_networks?(%{user: %{role: role}}) do
    role in [:admin, :operator]
  end

  defp can_manage_networks?(_), do: false

  defp require_manage_networks(socket) do
    if can_manage_networks?(socket.assigns.current_scope) do
      :ok
    else
      {:error, :unauthorized}
    end
  end

  defp mapper_agent_options(agents, partition, current_agent_id) do
    partition = normalize_partition(partition)

    options =
      agents
      |> Enum.filter(&(agent_supports_mapper?(&1) and agent_partition_matches?(&1, partition)))
      |> Enum.sort_by(&agent_label/1)
      |> Enum.map(&{agent_label(&1), &1.uid})

    append_unknown_agent_option(options, current_agent_id)
  end

  defp normalize_partition(nil), do: "default"
  defp normalize_partition(""), do: "default"
  defp normalize_partition(value), do: value

  defp agent_supports_mapper?(agent) do
    (agent.capabilities || [])
    |> Enum.filter(&(is_binary(&1) || is_atom(&1)))
    |> Enum.map(&to_string/1)
    |> Enum.any?(&(&1 == "mapper"))
  end

  defp agent_partition_matches?(agent, partition) do
    metadata = agent.metadata || %{}
    agent_partition = Map.get(metadata, "partition_id") || "default"
    agent_partition == partition
  end

  defp agent_label(agent) do
    name = Map.get(agent, :name)

    if is_binary(name) and name != "" do
      "#{name} (#{agent.uid})"
    else
      agent.uid
    end
  end

  defp append_unknown_agent_option(options, current_agent_id) do
    current = normalize_agent_id(current_agent_id)

    cond do
      is_nil(current) ->
        options

      Enum.any?(options, fn {_label, value} -> value == current end) ->
        options

      true ->
        options ++ [{"Unknown agent (#{current})", current}]
    end
  end

  defp normalize_agent_id(nil), do: nil

  defp normalize_agent_id(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp normalize_agent_id(value), do: to_string(value)

  defp load_sweep_profile(scope, id) do
    case Ash.get(SweepProfile, id, scope: scope) do
      {:ok, profile} -> profile
      {:error, _} -> nil
    end
  end

  defp load_mapper_jobs(scope) do
    query =
      MapperJob
      |> Ash.Query.for_read(:read)
      |> Ash.Query.load([
        :seeds,
        :unifi_controllers,
        unifi_controllers: [:api_key_present]
      ])

    case Ash.read(query, scope: scope) do
      {:ok, jobs} -> jobs
      {:error, _} -> []
    end
  end

  defp load_mapper_job(scope, id) do
    case Ash.get(MapperJob, id, scope: scope) do
      {:ok, job} ->
        case Ash.load(
               job,
               [
                 :seeds,
                 :unifi_controllers,
                 unifi_controllers: [:api_key_present]
               ],
               scope: scope
             ) do
          {:ok, loaded} -> loaded
          {:error, _} -> job
        end

      {:error, _} ->
        nil
    end
  end

  defp update_command_statuses(socket, event_type, data) do
    socket
    |> update_mapper_command_status(event_type, data)
    |> update_sweep_command_status(event_type, data)
  end

  defp update_mapper_command_status(socket, event_type, data) do
    case Map.get(data, :mapper_job_id) do
      nil ->
        socket

      job_id ->
        statuses =
          socket.assigns.mapper_command_statuses
          |> update_command_status(job_id, event_type, data)

        assign(socket, :mapper_command_statuses, statuses)
    end
  end

  defp update_sweep_command_status(socket, event_type, data) do
    case Map.get(data, :sweep_group_id) do
      nil ->
        socket

      group_id ->
        statuses =
          socket.assigns.sweep_command_statuses
          |> update_command_status(group_id, event_type, data)

        assign(socket, :sweep_command_statuses, statuses)
    end
  end

  defp update_command_status(statuses, key, event_type, data) do
    existing = Map.get(statuses, key, %{})

    updated =
      existing
      |> Map.merge(%{
        message: Map.get(data, :message),
        updated_at: command_event_timestamp(data)
      })
      |> merge_event_status(event_type, data)

    Map.put(statuses, key, updated)
  end

  defp merge_event_status(status, :ack, _data), do: Map.put(status, :state, :ack)

  defp merge_event_status(status, :progress, data) do
    status
    |> Map.put(:state, :progress)
    |> Map.put(:progress_percent, Map.get(data, :progress_percent))
  end

  defp merge_event_status(status, :result, data) do
    state = if Map.get(data, :success), do: :success, else: :error

    status
    |> Map.put(:state, state)
    |> Map.put(:result_payload, Map.get(data, :payload))
  end

  defp merge_event_status(status, _event_type, _data), do: status

  defp command_event_timestamp(data) do
    Map.get(data, :completed_at) ||
      Map.get(data, :updated_at) ||
      Map.get(data, :received_at) ||
      DateTime.utc_now()
  end

  defp mark_command_sent(statuses, key, message) do
    Map.put(statuses, key, %{
      state: :sent,
      message: message,
      updated_at: DateTime.utc_now()
    })
  end

  defp command_status_label(nil), do: "—"
  defp command_status_label(%{state: :sent}), do: "Queued"
  defp command_status_label(%{state: :ack}), do: "Acked"

  defp command_status_label(%{state: :progress, progress_percent: percent})
       when is_integer(percent) do
    "Running #{percent}%"
  end

  defp command_status_label(%{state: :progress}), do: "Running"
  defp command_status_label(%{state: :success}), do: "Completed"
  defp command_status_label(%{state: :error}), do: "Failed"
  defp command_status_label(_), do: "—"

  defp command_status_variant(nil), do: "ghost"
  defp command_status_variant(%{state: :sent}), do: "info"
  defp command_status_variant(%{state: :ack}), do: "info"
  defp command_status_variant(%{state: :progress}), do: "warning"
  defp command_status_variant(%{state: :success}), do: "success"
  defp command_status_variant(%{state: :error}), do: "error"
  defp command_status_variant(_), do: "ghost"

  defp mapper_run_status_label(:success), do: "Success"
  defp mapper_run_status_label(:error), do: "Error"
  defp mapper_run_status_label(_), do: "—"

  defp mapper_run_status_variant(:success), do: "success"
  defp mapper_run_status_variant(:error), do: "error"
  defp mapper_run_status_variant(_), do: "ghost"

  defp load_or_create_cleanup_settings(scope) do
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

  defp build_cleanup_form(_scope, nil), do: nil

  defp build_cleanup_form(scope, settings) do
    settings
    |> Form.for_update(:update, domain: ServiceRadar.Inventory, scope: scope, as: "cleanup")
    |> to_form()
  end

  defp load_running_executions(scope) do
    case Ash.read(SweepGroupExecution, action: :running, scope: scope) do
      {:ok, executions} -> executions
      {:error, _} -> []
    end
  end

  defp load_recent_executions(scope) do
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

  defp format_schedule(group) do
    case group.schedule_type do
      :cron -> group.cron_expression || "—"
      _ -> "Every #{group.interval}"
    end
  end

  defp format_last_run(nil), do: "Never"

  defp format_last_run(%DateTime{} = dt) do
    Calendar.strftime(dt, "%Y-%m-%d %H:%M")
  end

  defp format_last_run(_), do: "—"

  defp merge_running_with_progress(running, progress_map) do
    running = List.wrap(running)
    progress_map = progress_map || %{}

    running_ids =
      running
      |> Enum.map(&(Map.get(&1, :execution_id) || &1.id))
      |> MapSet.new()

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

    (running ++ virtuals)
    |> Enum.sort_by(&latest_execution_time/1, {:desc, DateTime})
  end

  defp latest_execution(executions) do
    Enum.max_by(executions, &latest_execution_time/1, fn -> nil end)
  end

  defp latest_execution_time(execution) do
    Map.get(execution, :completed_at) ||
      Map.get(execution, :updated_at) ||
      Map.get(execution, :started_at) ||
      DateTime.from_unix!(0)
  end

  defp mapper_job_to_form(job) do
    %{
      "name" => job.name,
      "description" => job.description || "",
      "enabled" => job.enabled,
      "interval" => job.interval,
      "partition" => job.partition,
      "agent_id" => job.agent_id || "",
      "discovery_mode" => to_string(job.discovery_mode),
      "discovery_type" => to_string(job.discovery_type),
      "concurrency" => job.concurrency,
      "timeout" => job.timeout,
      "retries" => job.retries
    }
  end

  defp has_secret_value?(struct, field) do
    case Map.get(struct, field) do
      nil -> false
      "" -> false
      value when is_binary(value) -> byte_size(value) > 0
      _ -> false
    end
  end

  defp mapper_unifi_form([]), do: {to_form(%{}, as: :unifi), false}
  defp mapper_unifi_form(%Ash.NotLoaded{}), do: {to_form(%{}, as: :unifi), false}

  defp mapper_unifi_form([controller | _]) do
    form = %{
      "name" => controller.name || "",
      "base_url" => controller.base_url || "",
      "insecure_skip_verify" => controller.insecure_skip_verify || false
    }

    # Check for API key by directly inspecting the struct
    api_key_present = has_secret_value?(controller, :api_key)

    {to_form(form, as: :unifi), api_key_present}
  end

  defp seeds_to_text(seeds) do
    Enum.map_join(seeds, "\n", & &1.seed)
  end

  defp parse_seeds_text(text) do
    text
    |> String.split(~r/[\n,]+/, trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp normalize_mapper_job_params(params) do
    params
    |> normalize_boolean("enabled")
    |> normalize_integer("concurrency")
    |> normalize_integer("retries")
    |> drop_blank(~w(agent_id))
  end

  defp normalize_unifi_params(params) do
    params
    |> normalize_boolean("insecure_skip_verify")
    |> drop_blank(~w(api_key))
  end

  defp normalize_boolean(params, key) do
    case Map.get(params, key) do
      "true" -> Map.put(params, key, true)
      "false" -> Map.put(params, key, false)
      true -> params
      false -> params
      _ -> params
    end
  end

  defp normalize_integer(params, key) do
    case Map.get(params, key) do
      value when is_integer(value) ->
        params

      value when is_binary(value) ->
        case Integer.parse(value) do
          {parsed, _} -> Map.put(params, key, parsed)
          :error -> Map.delete(params, key)
        end

      _ ->
        params
    end
  end

  defp drop_blank(params, keys) do
    Enum.reduce(keys, params, fn key, acc ->
      case Map.get(acc, key) do
        nil -> acc
        "" -> Map.delete(acc, key)
        _ -> acc
      end
    end)
  end

  defp save_mapper_job(job, job_params, seeds, unifi_params, scope) do
    with {:ok, job} <- upsert_mapper_job(job, job_params, scope),
         :ok <- replace_mapper_seeds(job, seeds, scope),
         :ok <- upsert_unifi_controller(job, unifi_params, scope) do
      {:ok, job}
    end
  end

  defp upsert_mapper_job(nil, params, scope) do
    MapperJob
    |> Ash.Changeset.for_create(:create, params)
    |> Ash.create(scope: scope)
  end

  defp upsert_mapper_job(job, params, scope) do
    job
    |> Ash.Changeset.for_update(:update, params)
    |> Ash.update(scope: scope)
  end

  defp replace_mapper_seeds(job, seeds, scope) do
    # Load the seeds relationship if not already loaded
    existing =
      case Ash.load(job, [:seeds], scope: scope) do
        {:ok, loaded} -> loaded.seeds || []
        {:error, _} -> []
      end

    Enum.each(existing, fn seed ->
      _ = Ash.destroy(seed, scope: scope)
    end)

    Enum.reduce_while(seeds, :ok, fn seed, _acc ->
      case MapperSeed
           |> Ash.Changeset.for_create(:create, %{seed: seed, mapper_job_id: job.id})
           |> Ash.create(scope: scope) do
        {:ok, _} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp upsert_unifi_controller(_job, params, _scope) when map_size(params) == 0, do: :ok

  defp upsert_unifi_controller(job, params, scope) do
    base_url = Map.get(params, "base_url") |> to_string() |> String.trim()

    if base_url == "" do
      :ok
    else
      persist_unifi_controller(job, params, scope)
    end
  end

  defp fetch_mapper_job(scope, id) do
    case load_mapper_job(scope, id) do
      nil -> {:error, :not_found}
      job -> {:ok, job}
    end
  end

  defp persist_unifi_controller(job, params, scope) do
    # Load the unifi_controllers relationship if not already loaded
    existing =
      case Ash.load(job, [:unifi_controllers], scope: scope) do
        {:ok, loaded} -> List.first(loaded.unifi_controllers || [])
        {:error, _} -> nil
      end

    result =
      case existing do
        nil ->
          create_params = Map.put(params, "mapper_job_id", job.id)

          MapperUnifiController
          |> Ash.Changeset.for_create(:create, create_params)
          |> Ash.create(scope: scope)

        controller ->
          # Don't include mapper_job_id in update - it's not accepted
          controller
          |> Ash.Changeset.for_update(:update, params)
          |> Ash.update(scope: scope)
      end

    case result do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp format_error({:agent_offline, agent_id}),
    do: "Agent #{agent_id} is offline"

  defp format_error({:agent_partition_mismatch, agent_id, partition}),
    do: "Agent #{agent_id} is not in partition #{partition}"

  defp format_error({:agent_capability_missing, agent_id, capability}),
    do: "Agent #{agent_id} does not support #{capability}"

  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_error(reason), do: inspect(reason)
  defp format_ports([]), do: "—"
  defp format_ports(ports) when length(ports) <= 5, do: Enum.join(ports, ", ")
  defp format_ports(ports), do: "#{length(ports)} ports"

  defp format_ports_input(nil), do: ""
  defp format_ports_input(""), do: ""

  defp format_ports_input(ports) when is_list(ports) do
    Enum.map_join(ports, ", ", &to_string/1)
  end

  defp format_ports_input(value) when is_binary(value), do: value

  defp count_target_devices(_scope, nil), do: nil
  defp count_target_devices(_scope, ""), do: nil

  defp count_target_devices(scope, target_query) when is_binary(target_query) do
    srql_module = srql_module()
    query = String.trim(target_query)

    full_query =
      cond do
        query == "" ->
          ~s|in:devices stats:"count() as total"|

        String.starts_with?(query, "in:") ->
          ~s|#{query} stats:"count() as total"|

        true ->
          ~s|in:devices #{query} stats:"count() as total"|
      end

    case srql_module.query(full_query, %{scope: scope}) do
      {:ok, %{"results" => [%{"total" => count} | _]}} when is_integer(count) ->
        count

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  defp srql_module do
    Application.get_env(:serviceradar_web_ng, :srql_module, ServiceRadarWebNG.SRQL)
  end

  defp default_builder_state do
    config = Catalog.entity("devices")

    %{
      "filters" => [
        %{
          "field" => config.default_filter_field,
          "op" => "contains",
          "value" => ""
        }
      ]
    }
  end

  defp parse_target_query_to_builder(nil), do: {default_builder_state(), true}
  defp parse_target_query_to_builder(""), do: {default_builder_state(), true}

  defp parse_target_query_to_builder(query) when is_binary(query) do
    query = String.trim(query)

    if query == "" do
      {default_builder_state(), true}
    else
      case parse_filters_from_query(query) do
        {:ok, filters} when filters != [] ->
          {%{"filters" => filters}, true}

        _ ->
          {default_builder_state(), false}
      end
    end
  end

  defp parse_filters_from_query(query) do
    known_prefixes = ["in:", "limit:", "sort:", "time:"]

    tokens =
      query
      |> String.split(~r/(?<!\\)\s+/, trim: true)
      |> Enum.reject(fn token ->
        Enum.any?(known_prefixes, &String.starts_with?(token, &1))
      end)

    filters =
      tokens
      |> Enum.map(&parse_filter_token/1)
      |> Enum.reject(&is_nil/1)

    if length(filters) == length(tokens) do
      {:ok, filters}
    else
      {:error, :unsupported_query}
    end
  end

  defp parse_filter_token(token) do
    {field, negated} =
      if String.starts_with?(token, "!") do
        {String.replace_prefix(token, "!", ""), true}
      else
        {token, false}
      end

    case String.split(field, ":", parts: 2) do
      [field_name, value] ->
        field_name = String.trim(field_name)
        value = String.trim(value) |> String.replace("\\ ", " ")

        {op, final_value} = parse_filter_value(field_name, negated, value)

        %{
          "field" => field_name,
          "op" => op,
          "value" => final_value
        }

      _ ->
        nil
    end
  end

  defp parse_filter_value(field, negated, value) do
    cond do
      list_filter_field?(field) ->
        normalized = normalize_list_value(value) |> Enum.join(", ")
        {maybe_negate_op("equals", negated), normalized}

      String.contains?(value, "%") ->
        {maybe_negate_op("contains", negated), unwrap_like(value)}

      true ->
        {maybe_negate_op("equals", negated), value}
    end
  end

  defp maybe_negate_op("equals", true), do: "not_equals"
  defp maybe_negate_op("contains", true), do: "not_contains"
  defp maybe_negate_op(op, _), do: op

  defp unwrap_like("%" <> rest) do
    rest
    |> String.trim_trailing("%")
    |> String.replace("\\ ", " ")
  end

  defp unwrap_like(value), do: value

  defp list_filter_field?(field) when is_binary(field) do
    field in ["discovery_sources"]
  end

  defp list_filter_field?(_), do: false

  defp normalize_list_value(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.trim_leading("(")
    |> String.trim_trailing(")")
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp normalize_list_value(value) when is_list(value) do
    value
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp normalize_list_value(_), do: []

  defp update_builder(builder, params) do
    builder
    |> Map.merge(stringify_params(params))
    |> normalize_builder_filters()
  end

  defp stringify_params(params) do
    Map.new(params, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {to_string(k), v}
    end)
  end

  defp normalize_builder_filters(builder) do
    config = Catalog.entity("devices")

    filters =
      builder
      |> Map.get("filters", %{})
      |> normalize_filters_list(config)

    Map.put(builder, "filters", filters)
  end

  defp normalize_filters_list(filters, config) when is_list(filters) do
    Enum.map(filters, fn filter ->
      field = normalize_filter_field(filter["field"], config)

      %{
        "field" => field,
        "op" => normalize_filter_op(filter["op"], field),
        "value" => filter["value"] || ""
      }
    end)
  end

  defp normalize_filters_list(filters_by_index, config) when is_map(filters_by_index) do
    filters_by_index
    |> Enum.sort_by(fn {k, _} ->
      case Integer.parse(to_string(k)) do
        {i, ""} -> i
        _ -> 0
      end
    end)
    |> Enum.map(fn {_k, v} -> v end)
    |> normalize_filters_list(config)
  end

  defp normalize_filters_list(_, config) do
    [%{"field" => config.default_filter_field, "op" => "contains", "value" => ""}]
  end

  defp normalize_filter_field(nil, config), do: config.default_filter_field
  defp normalize_filter_field("", config), do: config.default_filter_field
  defp normalize_filter_field(field, _config), do: field

  defp normalize_filter_op(op, field) do
    if list_filter_field?(field) do
      case op do
        "not_equals" -> "not_equals"
        "not_contains" -> "not_equals"
        "equals" -> "equals"
        "contains" -> "equals"
        _ -> "equals"
      end
    else
      case op do
        "contains" -> "contains"
        "not_contains" -> "not_contains"
        "equals" -> "equals"
        "not_equals" -> "not_equals"
        _ -> "contains"
      end
    end
  end

  defp build_target_query(builder) do
    filters = Map.get(builder, "filters", [])

    filters
    |> Enum.map(&build_filter_token/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  defp build_filter_token(%{"field" => field, "op" => op, "value" => value}) do
    field = String.trim(field || "")
    value = String.trim(value || "")

    cond do
      field == "" or value == "" ->
        nil

      list_filter_field?(field) ->
        build_list_filter_token(field, op, value)

      true ->
        build_scalar_filter_token(field, op, value)
    end
  end

  defp build_filter_token(_), do: nil

  defp build_list_filter_token(field, op, value) do
    values =
      value
      |> normalize_list_value()
      |> Enum.map(&String.replace(&1, " ", "\\ "))

    token = Enum.join(values, ",")

    case op do
      "not_equals" -> "!#{field}:(#{token})"
      "not_contains" -> "!#{field}:(#{token})"
      _ -> "#{field}:(#{token})"
    end
  end

  defp build_scalar_filter_token(field, op, value) do
    escaped = String.replace(value, " ", "\\ ")

    case op do
      "equals" -> "#{field}:#{escaped}"
      "not_equals" -> "!#{field}:#{escaped}"
      "not_contains" -> "!#{field}:%#{escaped}%"
      _ -> "#{field}:%#{escaped}%"
    end
  end

  defp maybe_sync_builder_to_form(socket) do
    if socket.assigns.builder_sync do
      builder = socket.assigns.builder
      query = build_target_query(builder)

      params =
        socket.assigns.ash_form
        |> form_params()
        |> Map.put("target_query", query)

      ash_form =
        socket.assigns.ash_form
        |> Form.validate(params)

      scope = socket.assigns.current_scope
      device_count = count_target_devices(scope, query)

      socket
      |> assign(:ash_form, ash_form)
      |> assign(:form, to_form(ash_form))
      |> assign(:target_device_count, device_count)
    else
      socket
    end
  end

  defp format_static_targets(targets) when is_list(targets) do
    Enum.join(targets, "\n")
  end

  defp format_static_targets(targets) when is_binary(targets), do: targets
  defp format_static_targets(_), do: ""

  defp normalize_static_targets(params) when is_map(params) do
    case Map.get(params, "static_targets") do
      nil ->
        params

      targets when is_list(targets) ->
        Map.put(params, "static_targets", Enum.map(targets, &String.trim/1))

      targets when is_binary(targets) ->
        parsed =
          targets
          |> String.split(~r/[\n,]+/, trim: true)
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))

        Map.put(params, "static_targets", parsed)

      _ ->
        params
    end
  end

  defp form_params(ash_form) do
    ash_form
    |> Form.params()
    |> Map.new(fn {k, v} -> {to_string(k), v} end)
  end

  # Transform comma-separated ports string to array of integers for Ash
  defp transform_profile_params(params) do
    params
    |> transform_ports_to_array()
  end

  defp transform_ports_to_array(params) do
    case Map.get(params, "ports") do
      nil ->
        params

      "" ->
        Map.put(params, "ports", [])

      value when is_binary(value) ->
        ports =
          value
          |> String.split(",")
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))
          |> Enum.flat_map(&parse_port/1)

        Map.put(params, "ports", ports)

      value when is_list(value) ->
        params

      _ ->
        params
    end
  end

  defp parse_port(port_str) do
    case Integer.parse(port_str) do
      {port, _} when port > 0 and port <= 65_535 -> [port]
      _ -> []
    end
  end

  defp agent_display_name(agent) do
    cond do
      agent.name && agent.name != "" -> agent.name
      agent.uid && agent.uid != "" -> agent.uid
      true -> "Agent #{agent.uid}"
    end
  end
end
