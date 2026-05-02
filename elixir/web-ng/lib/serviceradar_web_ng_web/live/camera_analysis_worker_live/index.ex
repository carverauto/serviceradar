defmodule ServiceRadarWebNGWeb.CameraAnalysisWorkerLive.Index do
  @moduledoc false
  use ServiceRadarWebNGWeb, :live_view

  alias ServiceRadar.Camera.AnalysisWorkerAlertRouter
  alias ServiceRadarWebNG.CameraAnalysisWorkers
  alias ServiceRadarWebNG.RBAC

  @refresh_interval_ms to_timeout(second: 10)

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    if RBAC.can?(scope, "settings.edge.manage") do
      if connected?(socket), do: schedule_refresh()

      {:ok,
       socket
       |> assign(:page_title, "Camera Analysis Workers")
       |> assign(:srql, %{enabled: false, page_path: "/observability/camera-relays/workers"})
       |> assign(:workers, [])
       |> assign(:summary, empty_summary())
       |> assign(:error, nil)
       |> assign(:refreshed_at, nil)
       |> load_workers()}
    else
      {:ok,
       socket
       |> put_flash(:error, "You don't have permission to access Camera Analysis Workers.")
       |> push_navigate(to: ~p"/dashboard")}
    end
  end

  @impl true
  def handle_info(:refresh_data, socket) do
    schedule_refresh()
    {:noreply, load_workers(socket)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply, load_workers(socket)}
  end

  def handle_event("toggle_enabled", %{"id" => id, "enabled" => enabled}, socket) do
    enabled? = enabled == "true"

    case camera_analysis_workers().set_enabled(id, enabled?, scope: socket.assigns.current_scope) do
      {:ok, _worker} ->
        {:noreply,
         socket
         |> put_flash(:info, if(enabled?, do: "Worker enabled", else: "Worker disabled"))
         |> load_workers()}

      {:error, _reason} ->
        {:noreply, socket |> put_flash(:error, "Failed to update worker") |> load_workers()}
    end
  end

  @impl true
  def handle_params(_params, _uri, %{assigns: %{live_action: :legacy}} = socket) do
    {:noreply, push_navigate(socket, to: ~p"/observability/camera-relays/workers")}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} srql={@srql}>
      <div class="space-y-6">
        <.observability_chrome active_pane="camera-relays" active_subsection="analysis-workers">
          <:actions>
            <button type="button" phx-click="refresh" class="btn btn-primary btn-sm">
              <.icon name="hero-arrow-path" class="size-4" /> Refresh
            </button>
          </:actions>
        </.observability_chrome>

        <div class="flex flex-col gap-4 lg:flex-row lg:items-start lg:justify-between">
          <div class="space-y-2">
            <div class="flex items-center gap-2 text-xs uppercase tracking-[0.24em] text-base-content/50">
              <span class="inline-flex size-2 rounded-full bg-warning"></span> Analysis Ops
            </div>
            <div>
              <h1 class="text-3xl font-semibold tracking-tight text-base-content">
                Camera Analysis Workers
              </h1>
              <p class="mt-1 max-w-2xl text-sm text-base-content/70">
                Registered worker inventory, health state, and bounded failover-relevant runtime status.
              </p>
            </div>
          </div>
        </div>

        <div :if={@error} class="alert alert-warning">
          <.icon name="hero-exclamation-triangle" class="size-5" />
          <span>{@error}</span>
        </div>

        <div class="grid gap-4 md:grid-cols-2 xl:grid-cols-4">
          <.summary_card
            title="Registered"
            value={@summary.total}
            tone="primary"
            icon="hero-circle-stack"
          />
          <.summary_card
            title="Enabled"
            value={@summary.enabled}
            tone="success"
            icon="hero-check-circle"
          />
          <.summary_card title="Healthy" value={@summary.healthy} tone="success" icon="hero-heart" />
          <.summary_card title="Unhealthy" value={@summary.unhealthy} tone="error" icon="hero-bolt" />
          <.summary_card
            title="Flapping"
            value={@summary.flapping}
            tone="warning"
            icon="hero-arrow-path-rounded-square"
          />
          <.summary_card
            title="Alerts"
            value={@summary.alerts}
            tone="error"
            icon="hero-exclamation-circle"
          />
          <.summary_card
            title="Active Assignments"
            value={@summary.active_assignments}
            tone="primary"
            icon="hero-cpu-chip"
          />
        </div>

        <section class="rounded-2xl border border-base-200 bg-base-100 shadow-sm">
          <div class="border-b border-base-200 px-5 py-4">
            <div class="flex items-center justify-between gap-3">
              <div>
                <h2 class="text-lg font-semibold text-base-content">Worker Registry</h2>
                <p class="text-sm text-base-content/60">
                  Authoritative analysis worker state from the platform registry.
                </p>
              </div>
              <span class="badge badge-ghost">{length(@workers)} workers</span>
            </div>
          </div>

          <div :if={@workers == []} class="px-5 py-8 text-sm text-base-content/60">
            No camera analysis workers are registered.
          </div>

          <div :if={@workers != []} class="overflow-x-auto">
            <table class="table">
              <thead>
                <tr>
                  <th>Worker</th>
                  <th>Adapter</th>
                  <th>Capabilities</th>
                  <th>Status</th>
                  <th>Health</th>
                  <th>Failure State</th>
                  <th>Assignments</th>
                  <th>Endpoint</th>
                  <th>Probe</th>
                  <th>Actions</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={worker <- @workers}>
                  <td>
                    <div class="font-medium text-base-content">
                      {worker.display_name || worker.worker_id}
                    </div>
                    <div class="text-xs text-base-content/50 font-mono">{worker.worker_id}</div>
                  </td>
                  <td>
                    <span class="badge badge-ghost">{worker.adapter}</span>
                  </td>
                  <td>
                    <div class="flex flex-wrap gap-1">
                      <span :if={worker.capabilities == []} class="text-xs text-base-content/50">
                        none
                      </span>
                      <span
                        :for={capability <- worker.capabilities}
                        class="badge badge-outline badge-sm"
                      >
                        {capability}
                      </span>
                    </div>
                  </td>
                  <td>
                    <span class={[
                      "badge",
                      if(worker.enabled, do: "badge-success", else: "badge-ghost")
                    ]}>
                      {if(worker.enabled, do: "enabled", else: "disabled")}
                    </span>
                  </td>
                  <td>
                    <div class="space-y-1">
                      <span class={["badge", health_badge_class(worker.health_status)]}>
                        {worker.health_status || "unknown"}
                      </span>
                      <span :if={worker.flapping} class="badge badge-warning">flapping</span>
                      <span :if={worker.alert_active} class="badge badge-error">
                        alert: {worker.alert_state}
                      </span>
                      <div :if={worker.health_reason} class="text-xs text-base-content/50">
                        {worker.health_reason}
                      </div>
                    </div>
                  </td>
                  <td>
                    <div class="text-sm text-base-content">
                      failures: {worker.consecutive_failures || 0}
                    </div>
                    <div class="text-xs text-base-content/50">
                      last failure: {format_datetime(worker.last_failure_at)}
                    </div>
                    <div class="text-xs text-base-content/50">
                      last healthy: {format_datetime(worker.last_healthy_at)}
                    </div>
                    <div class="text-xs text-base-content/50">
                      {flapping_summary(worker)}
                    </div>
                    <div class="text-xs text-base-content/50">
                      {alert_summary(worker)}
                    </div>
                    <div :if={worker.alert_active} class="text-xs text-base-content/50 font-mono">
                      {routed_alert_summary(worker)}
                    </div>
                    <div class="text-xs text-base-content/50">
                      {notification_policy_summary(worker)}
                    </div>
                    <div class="text-xs text-base-content/50">
                      {notification_audit_summary(worker)}
                    </div>
                  </td>
                  <td>
                    <div class="text-sm text-base-content">
                      active: {Map.get(worker, :active_assignment_count, 0)}
                    </div>
                    <div
                      :if={Map.get(worker, :active_assignment_count, 0) == 0}
                      class="text-xs text-base-content/50"
                    >
                      idle
                    </div>
                    <div
                      :for={assignment <- active_assignments(worker)}
                      class="mt-1 rounded-lg border border-base-200 bg-base-200/40 p-2 text-xs text-base-content/70"
                    >
                      <div class="font-mono text-[11px]">
                        {assignment.relay_session_id}/{assignment.branch_id}
                      </div>
                      <div>
                        mode: {assignment.selection_mode || "unknown"}
                      </div>
                      <div :if={assignment.requested_capability}>
                        capability: {assignment.requested_capability}
                      </div>
                    </div>
                  </td>
                  <td>
                    <div
                      class="max-w-xs truncate font-mono text-xs text-base-content/70"
                      title={worker.endpoint_url}
                    >
                      {worker.endpoint_url}
                    </div>
                    <div class="text-xs text-base-content/50">
                      headers: {length(worker.header_keys || [])}
                    </div>
                  </td>
                  <td>
                    <div class="font-mono text-xs text-base-content/70">
                      {worker.health_endpoint_url || worker.health_path || "/health"}
                    </div>
                    <div class="text-xs text-base-content/50">
                      timeout: {worker.health_timeout_ms || "default"} ms
                    </div>
                    <div class="text-xs text-base-content/50">
                      interval: {worker.probe_interval_ms || "default"} ms
                    </div>
                    <div :for={probe <- recent_probes(worker)} class="text-xs text-base-content/50">
                      {probe_status_label(probe)} {probe_reason_suffix(probe)}at {probe_timestamp(
                        probe
                      )}
                    </div>
                  </td>
                  <td>
                    <button
                      type="button"
                      phx-click="toggle_enabled"
                      phx-value-id={worker.id}
                      phx-value-enabled={to_string(!worker.enabled)}
                      class={["btn btn-xs", if(worker.enabled, do: "btn-ghost", else: "btn-primary")]}
                    >
                      {if(worker.enabled, do: "Disable", else: "Enable")}
                    </button>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end

  defp load_workers(socket) do
    case camera_analysis_workers().list_workers(scope: socket.assigns.current_scope) do
      {:ok, workers} ->
        socket
        |> assign(:workers, workers)
        |> assign(:summary, summarize_workers(workers))
        |> assign(:refreshed_at, DateTime.utc_now())
        |> assign(:error, nil)

      {:error, reason} ->
        socket
        |> assign(:workers, [])
        |> assign(:summary, empty_summary())
        |> assign(:error, "Failed to load workers: #{inspect(reason)}")
    end
  end

  defp summarize_workers(workers) do
    %{
      total: length(workers),
      enabled: Enum.count(workers, & &1.enabled),
      healthy: Enum.count(workers, &((&1.health_status || "healthy") == "healthy")),
      unhealthy: Enum.count(workers, &((&1.health_status || "healthy") != "healthy")),
      flapping: Enum.count(workers, &Map.get(&1, :flapping, false)),
      alerts: Enum.count(workers, &Map.get(&1, :alert_active, false)),
      active_assignments: Enum.reduce(workers, 0, &(&2 + Map.get(&1, :active_assignment_count, 0)))
    }
  end

  defp empty_summary do
    %{
      total: 0,
      enabled: 0,
      healthy: 0,
      unhealthy: 0,
      flapping: 0,
      alerts: 0,
      active_assignments: 0
    }
  end

  defp health_badge_class("healthy"), do: "badge-success"
  defp health_badge_class("unhealthy"), do: "badge-error"
  defp health_badge_class(_), do: "badge-ghost"

  defp format_datetime(nil), do: "never"
  defp format_datetime(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S UTC")

  defp recent_probes(worker) do
    worker
    |> Map.get(:recent_probe_results, [])
    |> List.wrap()
    |> Enum.filter(&is_map/1)
    |> Enum.take(3)
  end

  defp active_assignments(worker) do
    worker
    |> Map.get(:active_assignments, [])
    |> List.wrap()
    |> Enum.filter(&is_map/1)
    |> Enum.take(3)
  end

  defp probe_timestamp(probe) do
    Map.get(probe, :checked_at) || Map.get(probe, "checked_at") || "unknown"
  end

  defp probe_status_label(probe) do
    case Map.get(probe, :status) || Map.get(probe, "status") do
      nil -> "unknown"
      status -> to_string(status)
    end
  end

  defp probe_reason_suffix(probe) do
    case Map.get(probe, :reason) || Map.get(probe, "reason") do
      nil -> ""
      "" -> ""
      reason -> "(#{reason}) "
    end
  end

  defp flapping_summary(worker) do
    transition_count = Map.get(worker, :flapping_transition_count, 0)
    window_size = Map.get(worker, :flapping_window_size, 0)
    prefix = if Map.get(worker, :flapping, false), do: "flapping", else: "stable"
    "#{prefix}: #{transition_count} transitions / #{window_size} probes"
  end

  defp alert_summary(worker) do
    if Map.get(worker, :alert_active, false) do
      "alert: #{Map.get(worker, :alert_state) || "active"} (#{Map.get(worker, :alert_reason) || "no reason"})"
    else
      "alert: none"
    end
  end

  defp routed_alert_summary(worker) do
    context = AnalysisWorkerAlertRouter.routed_alert_context(worker)

    case context.routed_alert_key do
      key when is_binary(key) -> "observability key: #{key}"
      _ -> "observability key: unavailable"
    end
  end

  defp notification_policy_summary(worker) do
    context = AnalysisWorkerAlertRouter.notification_policy_context(worker)

    if context.notification_policy_active do
      "notification policy: #{context.notification_policy_path} (#{context.notification_policy_source})"
    else
      "notification policy: inactive"
    end
  end

  defp notification_audit_summary(worker) do
    if Map.get(worker, :notification_audit_active, false) do
      count = Map.get(worker, :notification_audit_notification_count, 0)

      last_notification =
        format_datetime(Map.get(worker, :notification_audit_last_notification_at))

      status = Map.get(worker, :notification_audit_alert_status, "unknown")
      "notification audit: #{count} sent, last #{last_notification}, alert #{status}"
    else
      "notification audit: none"
    end
  end

  defp camera_analysis_workers do
    Application.get_env(
      :serviceradar_web_ng,
      :camera_analysis_workers,
      CameraAnalysisWorkers
    )
  end

  defp schedule_refresh do
    Process.send_after(self(), :refresh_data, @refresh_interval_ms)
  end

  defp summary_card(assigns) do
    ~H"""
    <div class="rounded-2xl border border-base-200 bg-base-100 p-4 shadow-sm">
      <div class="flex items-start justify-between gap-3">
        <div>
          <div class="text-xs uppercase tracking-wide text-base-content/45">{@title}</div>
          <div class="mt-1 text-3xl font-semibold text-base-content">{@value}</div>
        </div>
        <div class={["flex size-10 items-center justify-center rounded-xl", tone_class(@tone)]}>
          <.icon name={@icon} class="size-5" />
        </div>
      </div>
    </div>
    """
  end

  defp tone_class("primary"), do: "bg-primary/10 text-primary"
  defp tone_class("success"), do: "bg-success/10 text-success"
  defp tone_class("error"), do: "bg-error/10 text-error"
  defp tone_class("warning"), do: "bg-warning/10 text-warning"
  defp tone_class(_), do: "bg-base-200 text-base-content"
end
