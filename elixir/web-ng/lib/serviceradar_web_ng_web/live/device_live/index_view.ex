defmodule ServiceRadarWebNGWeb.DeviceLive.IndexView do
  @moduledoc false
  use ServiceRadarWebNGWeb, :html

  import ServiceRadarWebNGWeb.DeviceLive.IndexView.Breakdown, only: [breakdown_modal: 1]

  import ServiceRadarWebNGWeb.DeviceLive.IndexView.BulkModals,
    only: [bulk_availability_source_modal: 1, bulk_delete_modal: 1, bulk_edit_modal: 1]

  import ServiceRadarWebNGWeb.DeviceLive.IndexView.DeviceModal, only: [add_device_modal: 1]
  import ServiceRadarWebNGWeb.DeviceLive.IndexView.ImportModal, only: [import_csv_modal: 1]
  import ServiceRadarWebNGWeb.DeviceLive.IndexView.Stats, only: [device_stats_cards: 1]
  import ServiceRadarWebNGWeb.NorthboundActionComponents, only: [northbound_action_modal: 1]

  alias ServiceRadarWebNGWeb.DeviceLive.AwxApplicability
  alias ServiceRadarWebNGWeb.DeviceLive.IndexView.BulkActions
  alias ServiceRadarWebNGWeb.DeviceLive.IndexView.Filters
  alias ServiceRadarWebNGWeb.DeviceLive.IndexView.Header
  alias ServiceRadarWebNGWeb.DeviceLive.IndexView.Table

  def render(assigns) do
    pagination = get_in(assigns, [:srql, :pagination]) || %{}
    selected_count = MapSet.size(assigns.selected_devices)

    # Check if all visible devices are selected
    visible_uids =
      assigns.devices
      |> Enum.filter(&is_map/1)
      |> Enum.map(fn row -> Map.get(row, "uid") || Map.get(row, "id") end)
      |> Enum.filter(&is_binary/1)
      |> MapSet.new()

    all_selected =
      MapSet.size(visible_uids) > 0 and MapSet.subset?(visible_uids, assigns.selected_devices)

    # Compute effective count (either selected or all matching)
    effective_count =
      if assigns.select_all_matching do
        assigns.total_matching_count || 0
      else
        selected_count
      end

    run_task_disabled? =
      assigns.northbound_device_actions_loading or assigns.northbound_device_actions == [] or
        effective_count == 0

    run_task_title =
      cond do
        assigns.northbound_device_actions_loading ->
          "Checking configured task integrations"

        assigns.northbound_device_actions == [] ->
          "No launchable task integrations are configured"

        selected_count == 0 ->
          "Select at least one device"

        true ->
          "Run task for selected devices"
      end

    assigns =
      assigns
      |> assign(:pagination, pagination)
      |> assign(:selected_count, selected_count)
      |> assign(:effective_count, effective_count)
      |> assign(:all_selected, all_selected)
      |> assign(:run_task_disabled?, run_task_disabled?)
      |> assign(:run_task_title, run_task_title)

    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} srql={@srql}>
      <div class="mx-auto max-w-7xl p-6">
        <Header.render {assigns} />

        <.device_stats_cards
          stats={@device_stats}
          loading={@device_stats_loading}
        />

        <Filters.render {assigns} />
        <BulkActions.render {assigns} />
        <Table.render {assigns} />
      </div>

      <!-- Add Device Modal -->
      <.add_device_modal :if={@show_add_device_modal} form={@add_device_form} />

      <!-- Import CSV Modal -->
      <.import_csv_modal
        :if={@show_import_modal}
        uploads={@uploads}
        csv_preview={@csv_preview}
        csv_errors={@csv_errors}
      />

      <!-- Bulk Edit Modal -->
      <.bulk_edit_modal
        :if={@show_bulk_edit_modal}
        form={@bulk_edit_form}
        selected_count={@effective_count}
      />

      <!-- Bulk Delete Modal -->
      <.bulk_delete_modal
        :if={@show_bulk_delete_modal}
        selected_count={@effective_count}
      />

      <.bulk_availability_source_modal
        :if={@show_bulk_availability_source_modal}
        form={@availability_source_form}
        agent_options={@availability_source_agent_options}
        selected_count={@effective_count}
      />

      <.northbound_action_modal
        :if={@show_northbound_action_modal}
        id="northbound_action_modal"
        title="Run Task"
        subtitle={"#{@effective_count} selected device(s)"}
        form={@northbound_action_form}
        actions={launchable_northbound_actions(@northbound_device_actions)}
        action={@northbound_launch_action}
        error={@northbound_action_error}
        applicability={northbound_applicability_summary(@northbound_awx_applicability)}
        ansible_vars={@northbound_ansible_vars}
        ansible_var_values={@northbound_ansible_var_values}
        raw_extra_vars_open={@northbound_raw_extra_vars_open}
        raw_extra_vars={@northbound_raw_extra_vars}
        toggle_raw_event="toggle_northbound_raw_extra_vars"
        close_event="close_northbound_action_modal"
        change_event="northbound_action_change"
        submit_event="launch_northbound_action"
      />

      <.breakdown_modal
        :if={@breakdown_modal}
        modal={@breakdown_modal}
        search={@breakdown_search}
      />
    </Layouts.app>
    """
  end

  defp launchable_northbound_actions(actions) when is_list(actions), do: actions
  defp launchable_northbound_actions(_actions), do: []

  defp northbound_applicability_summary(%AwxApplicability{} = applicability) do
    %{
      applicable_count: AwxApplicability.applicable_count(applicability),
      total_count: applicability.total,
      non_applicable: applicability.non_applicable
    }
  end

  defp northbound_applicability_summary(_), do: nil
end
