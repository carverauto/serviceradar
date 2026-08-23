defmodule ServiceRadarWebNGWeb.DeviceLive.IndexRefresh do
  @moduledoc false
  use ServiceRadarWebNGWeb, :live_view

  alias ServiceRadarWebNG.RuntimeLimits
  alias ServiceRadarWebNG.TenantUsage
  alias ServiceRadarWebNGWeb.DeviceLive.IndexData
  alias ServiceRadarWebNGWeb.SRQL.Page, as: SRQLPage

  require Logger

  @default_limit 20
  @max_limit 100
  @device_pubsub_refresh_debounce_ms 1_000

  # Keep page/cursor so a later PubSub refresh reloads the same list window
  # instead of jumping back to the head.
  def remember_list_params(socket, params, uri) when is_map(params) do
    socket
    |> assign(:last_params, params)
    |> assign(:last_uri, uri)
  end

  def refresh_devices(socket, opts \\ []) do
    params =
      opts
      |> Keyword.get(:list_params, Map.get(socket.assigns, :last_params, %{}))
      |> IndexData.include_inactive_inventory_params()

    uri = Map.get(socket.assigns, :last_uri, "/devices")
    preserve_async_data? = Keyword.get(opts, :preserve_async_data?, false)
    stats_loaded? = Map.get(socket.assigns, :device_stats_loaded, false)

    {default_limit, max_limit} = list_limits(socket)

    socket =
      socket
      |> SRQLPage.load_list(params, uri, :devices,
        default_limit: default_limit,
        max_limit: max_limit
      )
      |> assign_managed_device_limit_advisory()

    scope = Map.get(socket.assigns, :current_scope)
    query = Map.get(socket.assigns.srql || %{}, :query, "")
    current_page = Map.get(socket.assigns, :pagination_page) || IndexData.parse_page_param(params)
    token = System.unique_integer([:positive])

    socket =
      socket
      |> assign(
        device_enrichment_token: token,
        current_page: current_page,
        device_enrichment_task: nil,
        device_stats_task: nil,
        device_stats_loading: not (preserve_async_data? and stats_loaded?)
      )
      |> maybe_clear_async_device_data(preserve_async_data?)

    if connected?(socket) do
      socket
      |> start_device_enrichment_task(token, scope, query, socket.assigns.devices)
      |> start_device_stats_task(token, scope)
    else
      socket
    end
  end

  def schedule_device_refresh(socket) do
    if socket.assigns[:device_refresh_timer] do
      socket
    else
      timer =
        Process.send_after(
          self(),
          :refresh_devices_from_pubsub,
          @device_pubsub_refresh_debounce_ms
        )

      assign(socket, :device_refresh_timer, timer)
    end
  end

  def cancel_device_refresh_timer(socket) do
    if timer = socket.assigns[:device_refresh_timer] do
      Process.cancel_timer(timer)
    end

    assign(socket, :device_refresh_timer, nil)
  end

  defp maybe_clear_async_device_data(socket, true), do: socket

  defp maybe_clear_async_device_data(socket, false) do
    assign(socket,
      icmp_sparklines: %{},
      icmp_error: nil,
      effective_availability_by_device: %{},
      snmp_presence: %{},
      sysmon_presence: %{},
      sysmon_profiles_by_device: %{},
      total_device_count: nil
    )
  end

  def log_device_task_exit(kind, {:shutdown, :cancel}) do
    Logger.debug("Device #{kind} task canceled")
  end

  def log_device_task_exit(kind, :shutdown) do
    Logger.debug("Device #{kind} task shut down")
  end

  def log_device_task_exit(kind, reason) do
    Logger.warning("Device #{kind} task failed: #{inspect(reason)}")
  end

  defp assign_managed_device_limit_advisory(socket) do
    case RuntimeLimits.managed_device_limit() do
      limit when is_integer(limit) ->
        managed_device_count = TenantUsage.managed_device_count()

        socket
        |> assign(:managed_device_limit, limit)
        |> assign(:managed_device_count, managed_device_count)
        |> assign(:managed_device_limit_exceeded, managed_device_count > limit)

      _ ->
        socket
        |> assign(:managed_device_limit, nil)
        |> assign(:managed_device_count, nil)
        |> assign(:managed_device_limit_exceeded, false)
    end
  end

  defp start_device_enrichment_task(socket, token, scope, query, devices) do
    task = {:device_enrichment, token}

    socket
    |> assign(:device_enrichment_task, task)
    |> start_async(task, fn -> IndexData.build_device_enrichments(scope, query, devices) end)
  end

  defp start_device_stats_task(socket, token, scope) do
    task = {:device_stats, token}

    socket
    |> assign(:device_stats_task, task)
    |> start_async(task, fn ->
      srql = srql_module()
      IndexData.load_device_stats(srql, scope)
    end)
  end

  def clear_task_ref(socket, key, ref) do
    case Map.get(socket.assigns, key) do
      %Task{ref: ^ref} -> assign(socket, key, nil)
      ^ref -> assign(socket, key, nil)
      _ -> socket
    end
  end

  def task_ref(%Task{ref: ref}), do: ref
  def task_ref(_), do: nil

  defp srql_module do
    Application.get_env(:serviceradar_web_ng, :srql_module, ServiceRadarWebNG.SRQL)
  end

  def apply_device_enrichments(socket, token, enrichments) do
    if socket.assigns[:device_enrichment_token] == token do
      {:noreply,
       assign(socket,
         icmp_sparklines: enrichments.icmp_sparklines,
         icmp_error: enrichments.icmp_error,
         effective_availability_by_device: enrichments.effective_availability_by_device,
         snmp_presence: enrichments.snmp_presence,
         sysmon_presence: enrichments.sysmon_presence,
         sysmon_profiles_by_device: enrichments.sysmon_profiles_by_device,
         agent_device_uids: enrichments.agent_device_uids,
         composite_verdicts_by_device: enrichments.composite_verdicts_by_device,
         total_device_count: enrichments.total_device_count
       )}
    else
      {:noreply, socket}
    end
  end

  def apply_device_stats(socket, token, stats) do
    if socket.assigns[:device_enrichment_token] == token do
      {:noreply,
       assign(socket,
         device_stats: stats,
         device_stats_loading: false,
         device_stats_loaded: true
       )}
    else
      {:noreply, socket}
    end
  end

  defp list_limits(%{assigns: %{live_action: :new_devices}}) do
    {200, 200}
  end

  defp list_limits(_socket), do: {@default_limit, @max_limit}
end
