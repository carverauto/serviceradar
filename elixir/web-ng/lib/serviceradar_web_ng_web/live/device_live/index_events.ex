defmodule ServiceRadarWebNGWeb.DeviceLive.IndexEvents do
  @moduledoc false

  alias ServiceRadarWebNGWeb.DeviceLive.IndexEvents.BulkAvailability
  alias ServiceRadarWebNGWeb.DeviceLive.IndexEvents.BulkDelete
  alias ServiceRadarWebNGWeb.DeviceLive.IndexEvents.BulkTags
  alias ServiceRadarWebNGWeb.DeviceLive.IndexEvents.DeviceManagement
  alias ServiceRadarWebNGWeb.DeviceLive.IndexEvents.Navigation
  alias ServiceRadarWebNGWeb.DeviceLive.IndexEvents.Northbound
  alias ServiceRadarWebNGWeb.DeviceLive.IndexEvents.Selection

  @navigation_events ~w(
    srql_change
    srql_submit
    srql_reset
    srql_paginate
    srql_builder_toggle
    srql_builder_change
    srql_builder_apply
    srql_builder_run
    toggle_include_deleted
    open_breakdown_modal
    close_breakdown_modal
    breakdown_search
    srql_builder_add_filter
    srql_builder_remove_filter
  )

  @device_management_events ~w(
    open_add_device_modal
    close_add_device_modal
    open_import_modal
    close_import_modal
    validate_csv
    set_import_partition
    preview_csv
    import_csv
    validate_device
    save_device
  )

  @selection_events ~w(
    toggle_device_select
    toggle_select_all
    clear_selection
    launch_ansible_for_selection
    open_bulk_edit_modal
    open_bulk_delete_modal
    open_bulk_availability_source_modal
    close_bulk_edit_modal
    close_bulk_delete_modal
    close_bulk_availability_source_modal
    toggle_select_all_matching
  )

  @northbound_events ~w(
    run_action_for_selection
    close_northbound_action_modal
    northbound_action_change
    launch_northbound_action
  )

  def handle_event(event, params, socket) when event in @navigation_events do
    Navigation.handle_event(event, params, socket)
  end

  def handle_event(event, params, socket) when event in @device_management_events do
    DeviceManagement.handle_event(event, params, socket)
  end

  def handle_event(event, params, socket) when event in @selection_events do
    Selection.handle_event(event, params, socket)
  end

  def handle_event(event, params, socket) when event in @northbound_events do
    Northbound.handle_event(event, params, socket)
  end

  def handle_event("apply_bulk_tags", params, socket) do
    BulkTags.handle_event("apply_bulk_tags", params, socket)
  end

  def handle_event("apply_bulk_availability_source", params, socket) do
    BulkAvailability.handle_event("apply_bulk_availability_source", params, socket)
  end

  def handle_event(event, params, socket) when event in ~w(bulk_delete_devices confirm_bulk_delete) do
    BulkDelete.handle_event(event, params, socket)
  end

  def maybe_load_northbound_device_actions(socket) do
    Northbound.maybe_load_northbound_device_actions(socket)
  end
end
