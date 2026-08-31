defmodule ServiceRadarWebNGWeb.Settings.NetworksLive.Index do
  @moduledoc """
  LiveView for managing network sweep configuration.

  Provides UI for:
  - Sweep Groups: User-configured scan jobs with schedules and targeting
  - Scanner Profiles: Admin-managed scan configuration templates
  - Active Scans: Real-time view of running sweeps
  """
  use ServiceRadarWebNGWeb, :live_view

  import ServiceRadarWebNGWeb.Settings.NetworksLive.Index.Data
  import ServiceRadarWebNGWeb.Settings.NetworksLive.Index.Executions
  import ServiceRadarWebNGWeb.Settings.NetworksLive.Index.MapperForms

  alias ServiceRadar.AgentCommands.PubSub, as: AgentCommandsPubSub
  alias ServiceRadar.SweepJobs.SweepPubSub
  alias ServiceRadarWebNGWeb.Live.Settings.NetworksLive.AgentPicker
  alias ServiceRadarWebNGWeb.Settings.NetworksLive.Index.Actions
  alias ServiceRadarWebNGWeb.Settings.NetworksLive.Index.Events
  alias ServiceRadarWebNGWeb.Settings.NetworksLive.Index.Infos
  alias ServiceRadarWebNGWeb.Settings.NetworksLive.Index.View

  @refresh_interval to_timeout(second: 15)

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope
    cleanup_settings = load_or_create_cleanup_settings(scope)
    cleanup_form = build_cleanup_form(scope, cleanup_settings)
    can_manage_networks = can_manage_networks?(scope)

    if can_manage_networks do
      sweep_groups = load_sweep_groups(scope)

      sweep_group_summary_agents =
        if connected?(socket) and socket.assigns.live_action == :index do
          load_sweep_group_summary_agents(scope, sweep_groups)
        else
          %{}
        end

      if connected?(socket) do
        SweepPubSub.subscribe()
        AgentCommandsPubSub.subscribe()
        :timer.send_interval(@refresh_interval, self(), :refresh_active_scans)
      end

      socket =
        socket
        |> assign(:page_title, "Network Sweeps")
        |> assign(:current_path, "/settings/networks")
        |> assign(:active_tab, :groups)
        |> assign(:sweep_groups, sweep_groups)
        |> assign(:sweep_group_summary_agents, sweep_group_summary_agents)
        |> assign(:sweep_profiles, load_sweep_profiles(scope))
        |> assign(:running_executions, load_running_executions(scope))
        |> assign(:recent_executions, load_recent_executions(scope))
        |> assign(:execution_progress, %{})
        |> assign(:selected_group, nil)
        |> assign(:selected_profile, nil)
        |> assign(:show_form, nil)
        |> assign(:ash_form, nil)
        |> assign(:form, nil)
        |> assign(:target_device_count, nil)
        |> assign(:builder_open, false)
        |> assign(:builder, ServiceRadarWebNGWeb.Settings.NetworksLive.TargetBuilder.default_builder_state())
        |> assign(:builder_sync, true)
        |> assign(:last_target_query, nil)
        |> assign(:show_mapper_form, nil)
        |> assign(:mapper_jobs, load_mapper_jobs(scope))
        |> assign(:mapper_agents, [])
        |> assign(:agent_picker, AgentPicker.new([]))
        |> assign(:agent_picker_open, false)
        |> assign(:agent_picker_selected_rows, [])
        |> assign(:agent_picker_summary_agent, nil)
        |> assign(:can_manage_networks, can_manage_networks)
        |> assign(:mapper_job, nil)
        |> assign(:mapper_form, nil)
        |> assign(:mapper_seeds_text, "")
        |> assign(:mapper_unifi_form, empty_unifi_form())
        |> assign(:mapper_unifi_present, false)
        |> assign(:mapper_mikrotik_form, empty_mikrotik_form())
        |> assign(:mapper_mikrotik_present, false)
        |> assign(:mapper_mikrotik, empty_mikrotik_fields())
        |> assign(:mapper_command_statuses, %{})
        |> assign(:sweep_command_statuses, %{})
        |> assign(:cleanup_settings, cleanup_settings)
        |> assign(:cleanup_form, cleanup_form)
        |> assign(:can_enable_banner_grab, can_enable_banner_grab?(scope))
        |> assign(:banner_preview_device_count, nil)

      {:ok, socket}
    else
      {:ok,
       socket
       |> put_flash(:error, "Not authorized to manage network settings")
       |> redirect(to: ~p"/settings/profile")}
    end
  end

  @impl true
  def handle_params(params, _url, socket),
    do: {:noreply, Actions.apply_action(socket, socket.assigns.live_action, params)}

  @impl true
  def handle_event(event, params, socket), do: Events.handle_event(event, params, socket)

  @impl true
  def handle_info(message, socket), do: Infos.handle_info(message, socket)

  @impl true
  def render(assigns), do: View.render(assigns)
end
