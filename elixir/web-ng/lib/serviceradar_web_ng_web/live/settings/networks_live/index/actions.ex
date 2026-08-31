defmodule ServiceRadarWebNGWeb.Settings.NetworksLive.Index.Actions do
  @moduledoc false
  use ServiceRadarWebNGWeb, :live_view

  import ServiceRadarWebNGWeb.Settings.NetworksLive.Index.Data
  import ServiceRadarWebNGWeb.Settings.NetworksLive.Index.MapperForms

  alias AshPhoenix.Form
  alias ServiceRadar.SweepJobs.SweepGroup
  alias ServiceRadar.SweepJobs.SweepProfile
  alias ServiceRadar.SweepJobs.SweepProfile.BannerGrab
  alias ServiceRadarWebNGWeb.Live.Settings.NetworksLive.AgentPicker
  alias ServiceRadarWebNGWeb.Settings.NetworksLive.FormComponents
  alias ServiceRadarWebNGWeb.Settings.NetworksLive.TargetBuilder

  def apply_action(socket, :index, _params) do
    socket
    |> assign(:page_title, "Network Sweeps")
    |> assign(:current_path, "/settings/networks")
    |> assign(:show_form, nil)
    |> assign(:ash_form, nil)
    |> assign(:selected_group, nil)
    |> assign(:selected_profile, nil)
  end

  def apply_action(socket, :new_group, _params) do
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
    |> assign(:builder, TargetBuilder.default_builder_state())
    |> assign(:builder_sync, true)
    |> assign(:last_target_query, nil)
    |> initialize_agent_picker(scope, [])
  end

  def apply_action(socket, :edit_group, %{"id" => id}) do
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
        {builder, builder_sync} = TargetBuilder.parse_target_query_to_builder(group.target_query)

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
        |> assign(:last_target_query, group.target_query)
        |> initialize_agent_picker(scope, group.agent_ids || [])
    end
  end

  def apply_action(socket, :discovery, _params) do
    scope = socket.assigns.current_scope

    socket
    |> assign(:page_title, "Discovery Jobs")
    |> assign(:current_path, "/settings/networks/discovery")
    |> assign(:show_form, nil)
    |> assign(:show_mapper_form, nil)
    |> assign(:mapper_job, nil)
    |> assign(:mapper_form, nil)
    |> assign(:mapper_seeds_text, "")
    |> assign(:mapper_unifi_form, empty_unifi_form())
    |> assign(:mapper_unifi_present, false)
    |> assign(:mapper_mikrotik_form, empty_mikrotik_form())
    |> assign(:mapper_mikrotik_present, false)
    |> assign(:mapper_mikrotik, empty_mikrotik_fields())
    |> assign(:mapper_agents, load_mapper_agents(scope))
  end

  def apply_action(socket, :new_mapper_job, _params) do
    scope = socket.assigns.current_scope

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
    |> assign(:mapper_unifi_form, empty_unifi_form())
    |> assign(:mapper_unifi_present, false)
    |> assign(:mapper_mikrotik_form, empty_mikrotik_form())
    |> assign(:mapper_mikrotik_present, false)
    |> assign(:mapper_mikrotik, empty_mikrotik_fields())
    |> assign(:mapper_agents, load_mapper_agents(scope))
  end

  def apply_action(socket, :edit_mapper_job, %{"id" => id}) do
    scope = socket.assigns.current_scope

    case load_mapper_job(scope, id) do
      nil ->
        socket
        |> put_flash(:error, "Discovery job not found")
        |> push_navigate(to: ~p"/settings/networks/discovery")

      job ->
        {unifi_form, unifi_present} = mapper_unifi_form(job.unifi_controllers)
        {mikrotik_form, mikrotik_present} = mapper_mikrotik_form(job.mikrotik_controllers)
        mikrotik = mapper_mikrotik_fields(job.mikrotik_controllers)

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
        |> assign(:mapper_mikrotik_form, mikrotik_form)
        |> assign(:mapper_mikrotik_present, mikrotik_present)
        |> assign(:mapper_mikrotik, Map.put(mikrotik, :password_present, mikrotik_present))
        |> assign(:mapper_agents, load_mapper_agents(scope, job.agent_id))
    end
  end

  def apply_action(socket, :show_group, %{"id" => id}) do
    case load_sweep_group(socket.assigns.current_scope, id) do
      nil ->
        socket
        |> put_flash(:error, "Sweep group not found")
        |> push_navigate(to: ~p"/settings/networks")

      group ->
        scope = socket.assigns.current_scope

        summary_agents =
          if connected?(socket), do: load_sweep_group_summary_agents(scope, [group]), else: %{}

        socket
        |> assign(:page_title, group.name)
        |> assign(:current_path, "/settings/networks")
        |> assign(:show_form, :show_group)
        |> assign(:selected_group, group)
        |> assign(:sweep_group_summary_agents, summary_agents)
    end
  end

  def apply_action(socket, :new_profile, _params) do
    scope = socket.assigns.current_scope

    ash_form =
      Form.for_create(SweepProfile, :create, domain: ServiceRadar.SweepJobs, scope: scope)

    socket
    |> assign(:page_title, "New Scanner Profile")
    |> assign(:current_path, "/settings/networks")
    |> assign(:show_form, :new_profile)
    |> assign(:ash_form, ash_form)
    |> assign(:form, to_form(ash_form))
    |> assign(:banner_grab_draft, BannerGrab.default_input())
    |> assign(:banner_preview_device_count, count_target_devices(scope, "in:devices"))
  end

  def apply_action(socket, :edit_profile, %{"id" => id}) do
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
        |> assign(:banner_grab_draft, FormComponents.banner_grab_to_map(profile.banner_grab))
        |> assign(:banner_preview_device_count, count_target_devices(scope, "in:devices"))
    end
  end

  defp initialize_agent_picker(socket, scope, agent_ids) do
    picker = AgentPicker.new(agent_ids)

    summary_agent =
      case picker.committed |> MapSet.to_list() |> Enum.sort() do
        [uid] -> if connected?(socket), do: load_agent_by_uid(scope, uid)
        _ -> nil
      end

    socket
    |> assign(:agent_picker, picker)
    |> assign(:agent_picker_open, false)
    |> assign(:agent_picker_selected_rows, [])
    |> assign(:agent_picker_summary_agent, summary_agent)
  end
end
