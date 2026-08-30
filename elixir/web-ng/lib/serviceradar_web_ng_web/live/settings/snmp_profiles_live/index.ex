defmodule ServiceRadarWebNGWeb.Settings.SNMPProfilesLive.Index do
  @moduledoc """
  LiveView for managing SNMP profiles configuration.

  SNMP profiles use SRQL targeting, reusable OID templates, and profile-level
  credentials with per-device overrides.
  """
  use ServiceRadarWebNGWeb, :live_view

  alias ServiceRadarWebNG.RBAC
  alias ServiceRadarWebNGWeb.Settings.SNMPProfilesLive.Index.Actions
  alias ServiceRadarWebNGWeb.Settings.SNMPProfilesLive.Index.Builder
  alias ServiceRadarWebNGWeb.Settings.SNMPProfilesLive.Index.Data
  alias ServiceRadarWebNGWeb.Settings.SNMPProfilesLive.Index.Events
  alias ServiceRadarWebNGWeb.Settings.SNMPProfilesLive.Index.Infos
  alias ServiceRadarWebNGWeb.Settings.SNMPProfilesLive.Index.Provenance
  alias ServiceRadarWebNGWeb.Settings.SNMPProfilesLive.Index.View

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    if RBAC.can?(scope, "settings.snmp_profiles.manage") do
      {profiles, profile_target_counts} = Data.load_profiles_with_counts(scope)

      socket =
        socket
        |> assign(:page_title, "SNMP Profiles")
        |> assign(:profiles, profiles)
        |> assign(:profile_target_counts, profile_target_counts)
        |> assign(:profile_package_names, Provenance.load_package_names(scope, profiles))
        |> assign(:selected_profile, nil)
        |> assign(:show_form, nil)
        |> assign(:ash_form, nil)
        |> assign(:form, nil)
        |> assign(:target_device_count, nil)
        |> assign(:target_entity, "devices")
        |> assign(:builder_open, false)
        |> assign(:builder, Builder.default_builder_state())
        |> assign(:builder_sync, true)
        |> assign(:targets, [])
        |> assign(:show_target_modal, false)
        |> assign(:target_form, nil)
        |> assign(:editing_target, nil)
        |> assign(:show_password, false)
        |> assign(:test_connection_result, nil)
        |> assign(:test_connection_loading, false)
        |> assign(:target_oids, [])
        |> assign(:show_template_browser, false)
        |> assign(:template_search, "")
        |> assign(:selected_vendor, "standard")
        |> assign(:show_custom_template_modal, false)
        |> assign(:custom_template_form, nil)
        |> assign(:custom_template_oids, [])
        |> assign(:editing_custom_template, nil)
        |> Data.assign_custom_templates(scope)
        |> assign(:snmp_credentials, Data.load_snmp_credentials(scope))
        |> assign(:available_templates, Data.load_all_templates(scope))
        |> assign(:selected_template_ids, [])
        |> assign(:agents, Data.load_agents(scope))
        |> assign(:save_credential_as_reusable, false)
        |> assign(:credential_name, "")

      {:ok, socket}
    else
      {:ok,
       socket
       |> put_flash(:error, "You do not have access to SNMP profiles")
       |> push_navigate(to: ~p"/settings/profile")}
    end
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, Actions.apply_action(socket, socket.assigns.live_action, params)}
  end

  @impl true
  def handle_event(event, params, socket), do: Events.handle_event(event, params, socket)

  @impl true
  def handle_info(message, socket), do: Infos.handle_info(message, socket)

  @impl true
  def render(assigns), do: View.render(assigns)
end
