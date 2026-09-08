defmodule ServiceRadarWebNGWeb.Settings.SNMPProfilesLive.Index.Events do
  @moduledoc false

  alias ServiceRadarWebNGWeb.Settings.SNMPProfilesLive.Index.Events.Builder
  alias ServiceRadarWebNGWeb.Settings.SNMPProfilesLive.Index.Events.CustomTemplates
  alias ServiceRadarWebNGWeb.Settings.SNMPProfilesLive.Index.Events.Profiles
  alias ServiceRadarWebNGWeb.Settings.SNMPProfilesLive.Index.Events.ProfileTemplates
  alias ServiceRadarWebNGWeb.Settings.SNMPProfilesLive.Index.Events.TargetOids
  alias ServiceRadarWebNGWeb.Settings.SNMPProfilesLive.Index.Events.Targets
  alias ServiceRadarWebNGWeb.Settings.SNMPProfilesLive.Index.Events.TemplateBrowser

  @profile_events ~w(validate_profile save_profile toggle_profile delete_profile set_default clear_default)
  @builder_events ~w(builder_toggle builder_change builder_add_filter builder_remove_filter builder_apply)
  @profile_template_events ~w(toggle_template remove_template)
  @target_events ~w(open_target_modal edit_target close_target_modal toggle_password_visibility validate_target save_target delete_target test_connection)
  @target_oid_events ~w(add_oid remove_oid update_oid)
  @template_browser_events ~w(open_template_browser close_template_browser select_vendor search_templates add_template_oids add_custom_template_oids copy_template_to_custom)
  @custom_template_events ~w(open_custom_template_modal edit_custom_template close_custom_template_modal validate_custom_template save_custom_template delete_custom_template add_template_oid remove_template_oid update_template_oid)

  def handle_event(event, params, socket) when event in @profile_events, do: Profiles.handle_event(event, params, socket)

  def handle_event(event, params, socket) when event in @builder_events, do: Builder.handle_event(event, params, socket)

  def handle_event(event, params, socket) when event in @profile_template_events,
    do: ProfileTemplates.handle_event(event, params, socket)

  def handle_event(event, params, socket) when event in @target_events, do: Targets.handle_event(event, params, socket)

  def handle_event(event, params, socket) when event in @target_oid_events,
    do: TargetOids.handle_event(event, params, socket)

  def handle_event(event, params, socket) when event in @template_browser_events,
    do: TemplateBrowser.handle_event(event, params, socket)

  def handle_event(event, params, socket) when event in @custom_template_events,
    do: CustomTemplates.handle_event(event, params, socket)
end
