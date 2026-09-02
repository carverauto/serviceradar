defmodule ServiceRadarWebNGWeb.DeviceLive.Index do
  @moduledoc false
  use ServiceRadarWebNGWeb, :live_view

  import ServiceRadarWebNGWeb.DeviceLive.IndexRefresh,
    only: [
      apply_device_enrichments: 3,
      apply_device_stats: 3,
      cancel_device_refresh_timer: 1,
      clear_task_ref: 3,
      log_device_task_exit: 2,
      refresh_devices: 2,
      remember_list_params: 3,
      schedule_device_refresh: 1,
      task_ref: 1
    ]

  alias ServiceRadar.Inventory.DevicePubSub
  alias ServiceRadarWebNG.Dashboards.SystemReports
  alias ServiceRadarWebNGWeb.CompositeChecks.Catalog, as: CompositeCatalog
  alias ServiceRadarWebNGWeb.DeviceLive.IndexData
  alias ServiceRadarWebNGWeb.DeviceLive.IndexEvents
  alias ServiceRadarWebNGWeb.DeviceLive.IndexView
  alias ServiceRadarWebNGWeb.SRQL.Page, as: SRQLPage

  require Logger

  Module.register_attribute(__MODULE__, :sobelow_skip, accumulate: true)

  @default_limit 20

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      DevicePubSub.subscribe()
    end

    {:ok,
     socket
     |> assign(:page_title, page_title(socket.assigns.live_action))
     |> assign(:devices, [])
     |> assign(:icmp_sparklines, %{})
     |> assign(:icmp_error, nil)
     |> assign(:effective_availability_by_device, %{})
     |> assign(:snmp_presence, %{})
     |> assign(:sysmon_presence, %{})
     |> assign(:sysmon_profiles_by_device, %{})
     |> assign(:agent_device_uids, MapSet.new())
     |> assign(:device_enrichment_task, nil)
     |> assign(:device_stats_task, nil)
     |> assign(:device_refresh_timer, nil)
     |> assign(:limit, @default_limit)
     |> assign(:total_device_count, nil)
     |> assign(:managed_device_count, nil)
     |> assign(:managed_device_limit, nil)
     |> assign(:managed_device_limit_exceeded, false)
     |> assign(:current_page, 1)
     # Device stats for cards
     |> assign(:device_stats, IndexData.default_device_stats())
     |> assign(:device_stats_loading, true)
     |> assign(:device_stats_loaded, false)
     # Bulk selection
     |> assign(:selected_devices, MapSet.new())
     |> assign(:select_all_matching, false)
     |> assign(:total_matching_count, nil)
     |> assign(:northbound_device_actions, [])
     |> assign(:northbound_device_actions_loading, connected?(socket))
     |> assign(:show_northbound_action_modal, false)
     |> assign(:northbound_action_form, to_form(%{}, as: :action))
     |> assign(:northbound_action_error, nil)
     |> assign(:northbound_launch_action, nil)
     |> assign(:show_bulk_edit_modal, false)
     |> assign(:show_bulk_delete_modal, false)
     |> assign(:show_bulk_availability_source_modal, false)
     |> assign(:bulk_edit_form, to_form(%{"tags" => ""}, as: :bulk))
     |> assign(:availability_source_form, to_form(%{"agent_id" => ""}, as: :availability_source))
     |> assign(
       :availability_source_agent_options,
       IndexData.load_availability_source_agent_options(socket.assigns.current_scope)
     )
     |> assign(:breakdown_modal, nil)
     |> assign(:breakdown_search, "")
     # Enabled composite checks and their authored verdicts, for the verdict
     # filter. Loaded once on mount: checks change on operator action, not on
     # every device refresh.
     |> assign(
       :composite_checks,
       CompositeCatalog.enabled_with_verdicts(scope: socket.assigns.current_scope)
     )
     |> assign(:composite_verdicts_by_device, %{})
     # Device management modals
     |> assign(:show_add_device_modal, false)
     |> assign(:show_import_modal, false)
     |> assign(:add_device_form, to_form(%{}, as: :device))
     # CSV import
     |> assign(:csv_preview, nil)
     |> assign(:csv_errors, [])
     |> assign(:csv_warnings, [])
     |> assign(:import_status, nil)
     |> assign(:import_partition, "default")
     |> assign(:import_partition_error, nil)
     |> assign(:import_partition_options, [{"Default", "default"}])
     |> allow_upload(:csv_file,
       accept: ~w(.csv),
       max_entries: 1,
       max_file_size: 5_000_000
     )
     |> SRQLPage.init("devices", default_limit: @default_limit)
     |> IndexEvents.maybe_load_northbound_device_actions()}
  end

  @impl true
  def handle_params(params, uri, socket) do
    params = maybe_put_new_devices_query(socket.assigns.live_action, params)

    {:noreply,
     socket
     |> cancel_device_refresh_timer()
     |> remember_list_params(params, uri)
     |> refresh_devices(list_params: params)}
  end

  @impl true
  def handle_info({:device_created, _uid, _device}, socket) do
    {:noreply, schedule_device_refresh(socket)}
  end

  def handle_info({:device_updated, _uid, _device}, socket) do
    {:noreply, schedule_device_refresh(socket)}
  end

  def handle_info({:device_deleted, _uid}, socket) do
    {:noreply, schedule_device_refresh(socket)}
  end

  def handle_info(:refresh_devices_from_pubsub, socket) do
    {:noreply,
     socket
     |> assign(:device_refresh_timer, nil)
     |> refresh_devices(preserve_async_data?: true)}
  end

  def handle_info({:device_enrichments_loaded, token, enrichments}, socket) do
    # Backward compatibility path for previous message format.
    apply_device_enrichments(socket, token, enrichments)
  end

  def handle_info({:device_stats_loaded, token, stats}, socket) do
    # Backward compatibility path for previous message format.
    apply_device_stats(socket, token, stats)
  end

  def handle_info({ref, {:device_enrichments_loaded, token, enrichments}}, socket) do
    socket = clear_task_ref(socket, :device_enrichment_task, ref)
    Process.demonitor(ref, [:flush])
    apply_device_enrichments(socket, token, enrichments)
  end

  def handle_info({ref, {:device_stats_loaded, token, stats}}, socket) do
    socket = clear_task_ref(socket, :device_stats_task, ref)
    Process.demonitor(ref, [:flush])
    apply_device_stats(socket, token, stats)
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, socket) do
    cond do
      task_ref(socket.assigns[:device_stats_task]) == ref ->
        log_device_task_exit(:stats, reason)

        {:noreply,
         socket
         |> assign(:device_stats_task, nil)
         |> assign(:device_stats_loading, false)}

      task_ref(socket.assigns[:device_enrichment_task]) == ref ->
        log_device_task_exit(:enrichment, reason)
        {:noreply, assign(socket, :device_enrichment_task, nil)}

      true ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_async({:device_enrichment, token}, {:ok, enrichments}, socket) do
    socket = clear_task_ref(socket, :device_enrichment_task, {:device_enrichment, token})
    apply_device_enrichments(socket, token, enrichments)
  end

  def handle_async({:device_enrichment, token}, {:exit, reason}, socket) do
    log_device_task_exit(:enrichment, reason)

    socket = clear_task_ref(socket, :device_enrichment_task, {:device_enrichment, token})

    {:noreply, socket}
  end

  def handle_async({:device_stats, token}, {:ok, stats}, socket) do
    socket = clear_task_ref(socket, :device_stats_task, {:device_stats, token})
    apply_device_stats(socket, token, stats)
  end

  def handle_async({:device_stats, token}, {:exit, reason}, socket) do
    log_device_task_exit(:stats, reason)

    socket =
      socket
      |> clear_task_ref(:device_stats_task, {:device_stats, token})
      |> assign(:device_stats_loading, false)

    {:noreply, socket}
  end

  def handle_async(:northbound_device_actions, {:ok, actions}, socket) when is_list(actions) do
    {:noreply,
     socket
     |> assign(:northbound_device_actions, actions)
     |> assign(:northbound_device_actions_loading, false)}
  end

  def handle_async(:northbound_device_actions, {:exit, reason}, socket) do
    Logger.warning("Failed to load northbound device actions: #{inspect(reason)}")

    {:noreply,
     socket
     |> assign(:northbound_device_actions, [])
     |> assign(:northbound_device_actions_loading, false)}
  end

  @impl true
  def handle_event(event, params, socket), do: IndexEvents.handle_event(event, params, socket)

  @impl true
  def render(assigns), do: IndexView.render(assigns)

  defp page_title(:new_devices), do: "New devices"
  defp page_title(_live_action), do: "Devices"

  defp maybe_put_new_devices_query(:new_devices, params) do
    query = Map.get(params, "q")

    if is_binary(query) and String.trim(query) != "" do
      params
    else
      Map.put(params, "q", SystemReports.new_devices_query())
    end
  end

  defp maybe_put_new_devices_query(_live_action, params), do: params
end
