defmodule ServiceRadarWebNGWeb.Settings.NetworksLive.Index.Events do
  @moduledoc false
  alias ServiceRadarWebNGWeb.Settings.NetworksLive.Index.EventHandlers.AgentPicker
  alias ServiceRadarWebNGWeb.Settings.NetworksLive.Index.EventHandlers.Builder
  alias ServiceRadarWebNGWeb.Settings.NetworksLive.Index.EventHandlers.Groups
  alias ServiceRadarWebNGWeb.Settings.NetworksLive.Index.EventHandlers.Mapper
  alias ServiceRadarWebNGWeb.Settings.NetworksLive.Index.EventHandlers.ProfileCleanup

  def handle_event(event, params, socket)
      when event in [
             "agent_picker_open",
             "agent_picker_cancel",
             "agent_picker_search",
             "agent_picker_retry",
             "agent_picker_next",
             "agent_picker_previous",
             "agent_picker_toggle",
             "agent_picker_show_browse",
             "agent_picker_show_selected",
             "agent_picker_selected_next",
             "agent_picker_selected_previous",
             "agent_picker_selected_retry",
             "agent_picker_remove",
             "agent_picker_clear",
             "agent_picker_apply",
             "agent_picker_use_all"
           ] do
    AgentPicker.handle_event(event, params, socket)
  end

  def handle_event(event, params, socket)
      when event in [
             "switch_tab",
             "toggle_group",
             "delete_group",
             "run_sweep_group",
             "toggle_mapper_job",
             "delete_mapper_job",
             "run_mapper_job"
           ] do
    Groups.handle_event(event, params, socket)
  end

  def handle_event(event, params, socket) when event in ["save_mapper_job", "mapper_form_change"] do
    Mapper.handle_event(event, params, socket)
  end

  def handle_event(event, params, socket)
      when event in [
             "delete_profile",
             "save_group",
             "save_profile",
             "validate_cleanup_settings",
             "save_cleanup_settings",
             "run_cleanup_now",
             "validate_group",
             "validate_profile"
           ] do
    ProfileCleanup.handle_event(event, params, socket)
  end

  def handle_event(event, params, socket)
      when event in ["builder_toggle", "builder_change", "builder_add_filter", "builder_remove_filter", "builder_apply"] do
    Builder.handle_event(event, params, socket)
  end
end
