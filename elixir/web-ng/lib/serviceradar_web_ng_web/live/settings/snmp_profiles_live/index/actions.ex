defmodule ServiceRadarWebNGWeb.Settings.SNMPProfilesLive.Index.Actions do
  @moduledoc false
  use ServiceRadarWebNGWeb, :live_view

  alias AshPhoenix.Form
  alias ServiceRadar.SNMPProfiles.SNMPProfile
  alias ServiceRadarWebNGWeb.Settings.SNMPProfilesLive.Index.Builder
  alias ServiceRadarWebNGWeb.Settings.SNMPProfilesLive.Index.Data
  alias ServiceRadarWebNGWeb.Settings.SNMPProfilesLive.Index.Targeting

  def apply_action(socket, :index, _params) do
    socket
    |> assign(:page_title, "SNMP Profiles")
    |> assign(:show_form, nil)
    |> assign(:ash_form, nil)
    |> assign(:form, nil)
    |> assign(:selected_profile, nil)
    |> assign(:builder_open, false)
    |> assign(:builder, Builder.default_builder_state())
    |> assign(:targets, [])
    |> assign(:show_target_modal, false)
    |> assign(:target_form, nil)
    |> assign(:editing_target, nil)
    |> assign(:target_oids, [])
    |> assign(:show_template_browser, false)
    |> assign(:selected_template_ids, [])
  end

  def apply_action(socket, :new_profile, _params) do
    scope = socket.assigns.current_scope

    ash_form =
      Form.for_create(SNMPProfile, :create, domain: ServiceRadar.SNMPProfiles, scope: scope)

    socket
    |> assign(:page_title, "New SNMP Profile")
    |> assign(:show_form, :new_profile)
    |> assign(:ash_form, ash_form)
    |> assign(:form, to_form(ash_form))
    |> assign(:save_credential_as_reusable, false)
    |> assign(:credential_name, "")
    |> assign(:builder_open, false)
    |> assign(:builder, Builder.default_builder_state())
    |> assign(:builder_sync, true)
    |> assign(:target_device_count, nil)
    |> assign(:target_entity, "devices")
    |> assign(:targets, [])
    |> assign(:show_target_modal, false)
    |> assign(:target_form, nil)
    |> assign(:editing_target, nil)
    |> assign(:target_oids, [])
    |> assign(:show_template_browser, false)
    |> assign(:selected_template_ids, [])
    |> Targeting.assign_target_preview(nil)
  end

  def apply_action(socket, :edit_profile, %{"id" => id}) do
    case Data.load_profile(socket.assigns.current_scope, id) do
      nil ->
        socket
        |> put_flash(:error, "Profile not found")
        |> push_navigate(to: ~p"/settings/snmp")

      profile ->
        scope = socket.assigns.current_scope
        target_query = Targeting.resolve_target_query(profile.target_query, profile.is_default)
        normalized_query = Targeting.normalize_target_query(target_query, profile.is_default)

        ash_form =
          profile
          |> Form.for_update(:update, domain: ServiceRadar.SNMPProfiles, scope: scope)
          |> Builder.maybe_set_target_query(target_query)

        {device_count, target_entity} =
          if is_nil(normalized_query) do
            {nil, "devices"}
          else
            {Targeting.count_target_devices(scope, normalized_query), Targeting.extract_srql_entity(normalized_query)}
          end

        # Parse the existing target_query into builder state if possible
        {builder, builder_sync} = Builder.parse_target_query_to_builder(target_query)

        # Load targets for this profile (legacy, for display only)
        targets = Data.load_profile_targets(scope, profile.id)

        # Load profile's selected OID templates
        selected_template_ids = profile.oid_template_ids || []

        socket
        |> assign(:page_title, "Edit #{profile.name}")
        |> assign(:show_form, :edit_profile)
        |> assign(:selected_profile, profile)
        |> assign(:ash_form, ash_form)
        |> assign(:form, to_form(ash_form))
        |> assign(:save_credential_as_reusable, false)
        |> assign(:credential_name, "")
        |> assign(:target_device_count, device_count)
        |> assign(:target_entity, target_entity)
        |> assign(:builder_open, false)
        |> assign(:builder, builder)
        |> assign(:builder_sync, builder_sync)
        |> assign(:targets, targets)
        |> assign(:selected_template_ids, selected_template_ids)
        |> assign(:show_target_modal, false)
        |> assign(:target_form, nil)
        |> assign(:editing_target, nil)
        |> assign(:target_oids, [])
        |> assign(:show_template_browser, false)
    end
  end
end
