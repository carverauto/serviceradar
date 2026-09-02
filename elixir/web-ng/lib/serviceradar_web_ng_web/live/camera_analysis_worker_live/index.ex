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
      <div class="sr-observability-page space-y-6 font-sans">
        <.observability_chrome active_pane="camera-relays" active_subsection="analysis-workers">
          <:actions>
            <.ui_button type="button" phx-click="refresh" size="sm" variant="primary">
              <.icon name="hero-arrow-path" class="size-4" /> Refresh
            </.ui_button>
          </:actions>
        </.observability_chrome>

        <div class="flex flex-col gap-4 lg:flex-row lg:items-start lg:justify-between">
          <div class="space-y-2">
            <div class="flex items-center gap-2 text-xs uppercase tracking-[0.24em] text-sr-muted">
              <span class="inline-flex size-2 rounded-full bg-warning"></span> Analysis Ops
            </div>
            <div>
              <h1 class="text-3xl font-semibold tracking-tight text-sr-ink">
                Camera Analysis Workers
              </h1>
              <p class="mt-1 max-w-2xl text-sm text-sr-muted">
                Registered worker inventory, health state, and bounded failover-relevant runtime status.
              </p>
            </div>
          </div>
        </div>

        <div :if={@error} class={ui_alert_class("warning")}>
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

        <section class="rounded-2xl border border-sr-line bg-sr-surface shadow-sm">
          <div class="border-b border-sr-line px-5 py-4">
            <div class="flex items-center justify-between gap-3">
              <div>
                <h2 class="text-lg font-semibold text-sr-ink">Worker Registry</h2>
                <p class="text-sm text-sr-muted">
                  Authoritative analysis worker state from the platform registry.
                </p>
              </div>
              <.ui_badge size="sm" variant="ghost">{length(@workers)} workers</.ui_badge>
            </div>
          </div>

          <div :if={@workers == []} class="px-5 py-8 text-sm text-sr-muted">
            No camera analysis workers are registered.
          </div>

          <div :if={@workers != []} class="overflow-x-auto">
            <table class={ui_table_class()}>
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
                    <div class="font-medium text-sr-ink">
                      {worker.display_name || worker.worker_id}
                    </div>
                    <div class="text-xs text-sr-muted font-mono">{worker.worker_id}</div>
                  </td>
                  <td>
                    <.ui_badge size="sm" variant="ghost">{worker.adapter}</.ui_badge>
                  </td>
                  <td>
                    <div class="flex flex-wrap gap-1">
                      <span :if={worker.capabilities == []} class="text-xs text-sr-muted">
                        none
                      </span>
                      <.ui_badge
                        :for={capability <- worker.capabilities}
                        size="sm"
                        variant="outline"
                      >
                        {capability}
                      </.ui_badge>
                    </div>
                  </td>
                  <td>
                    <.ui_badge
                      size="sm"
                      variant={if(worker.enabled, do: "success", else: "ghost")}
                    >
                      {if(worker.enabled, do: "enabled", else: "disabled")}
                    </.ui_badge>
                  </td>
                  <td>
                    <div class="space-y-1">
                      <.ui_badge size="sm" variant={health_badge_variant(worker.health_status)}>
                        {worker.health_status || "unknown"}
                      </.ui_badge>
                      <.ui_badge :if={worker.flapping} size="sm" variant="warning">
                        flapping
                      </.ui_badge>
                      <.ui_badge :if={worker.alert_active} size="sm" variant="error">
                        alert: {worker.alert_state}
                      </.ui_badge>
                      <div :if={worker.health_reason} class="text-xs text-sr-muted">
                        {worker.health_reason}
                      </div>
                    </div>
                  </td>
                  <td>
                    <div class="text-sm text-sr-ink">
                      failures: {worker.consecutive_failures || 0}
                    </div>
                    <div class="text-xs text-sr-muted">
                      last failure:
                      <.user_time
                        id={"camera-analysis-worker-#{worker.id}-last-failure-at"}
                        value={worker.last_failure_at}
                        timezone={@current_scope.user.timezone || "Etc/UTC"}
                        style={:compact}
                        fallback="never"
                      />
                    </div>
                    <div class="text-xs text-sr-muted">
                      last healthy:
                      <.user_time
                        id={"camera-analysis-worker-#{worker.id}-last-healthy-at"}
                        value={worker.last_healthy_at}
                        timezone={@current_scope.user.timezone || "Etc/UTC"}
                        style={:compact}
                        fallback="never"
                      />
                    </div>
                    <div class="text-xs text-sr-muted">
                      {flapping_summary(worker)}
                    </div>
                    <div class="text-xs text-sr-muted">
                      {alert_summary(worker)}
                    </div>
                    <div :if={worker.alert_active} class="text-xs text-sr-muted font-mono">
                      {routed_alert_summary(worker)}
                    </div>
                    <div class="text-xs text-sr-muted">
                      {notification_policy_summary(worker)}
                    </div>
                    <div
                      :if={Map.get(worker, :notification_audit_active, false)}
                      class="text-xs text-sr-muted"
                    >
                      notification audit: {Map.get(
                        worker,
                        :notification_audit_notification_count,
                        0
                      )} sent, last
                      <.user_time
                        id={"camera-analysis-worker-#{worker.id}-last-notification-at"}
                        value={Map.get(worker, :notification_audit_last_notification_at)}
                        timezone={@current_scope.user.timezone || "Etc/UTC"}
                        style={:compact}
                        fallback="never"
                      />, alert {Map.get(worker, :notification_audit_alert_status, "unknown")}
                    </div>
                    <div
                      :if={not Map.get(worker, :notification_audit_active, false)}
                      class="text-xs text-sr-muted"
                    >
                      notification audit: none
                    </div>
                  </td>
                  <td>
                    <div class="text-sm text-sr-ink">
                      active: {Map.get(worker, :active_assignment_count, 0)}
                    </div>
                    <div
                      :if={Map.get(worker, :active_assignment_count, 0) == 0}
                      class="text-xs text-sr-muted"
                    >
                      idle
                    </div>
                    <div
                      :for={assignment <- active_assignments(worker)}
                      class="mt-1 rounded-lg border border-sr-line bg-sr-subtle/40 p-2 text-xs text-sr-muted"
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
                      class="max-w-xs truncate font-mono text-xs text-sr-muted"
                      title={worker.endpoint_url}
                    >
                      {worker.endpoint_url}
                    </div>
                    <div class="text-xs text-sr-muted">
                      headers: {length(worker.header_keys || [])}
                    </div>
                  </td>
                  <td>
                    <div class="font-mono text-xs text-sr-muted">
                      {worker.health_endpoint_url || worker.health_path || "/health"}
                    </div>
                    <div class="text-xs text-sr-muted">
                      timeout: {worker.health_timeout_ms || "default"} ms
                    </div>
                    <div class="text-xs text-sr-muted">
                      interval: {worker.probe_interval_ms || "default"} ms
                    </div>
                    <div
                      :for={{probe, probe_idx} <- Enum.with_index(recent_probes(worker))}
                      class="text-xs text-sr-muted"
                    >
                      {probe_status_label(probe)} {probe_reason_suffix(probe)}at
                      <.user_time
                        id={"camera-analysis-worker-#{worker.id}-probe-#{probe_identity(probe, probe_idx)}-checked-at"}
                        value={probe_timestamp(probe)}
                        timezone={@current_scope.user.timezone || "Etc/UTC"}
                        style={:compact}
                        fallback="unknown"
                      />
                    </div>
                  </td>
                  <td>
                    <.ui_button
                      type="button"
                      phx-click="toggle_enabled"
                      phx-value-id={worker.id}
                      phx-value-enabled={to_string(!worker.enabled)}
                      size="xs"
                      variant={if(worker.enabled, do: "ghost", else: "primary")}
                    >
                      {if(worker.enabled, do: "Disable", else: "Enable")}
                    </.ui_button>
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

  defp health_badge_variant("healthy"), do: "success"
  defp health_badge_variant("unhealthy"), do: "error"
  defp health_badge_variant(_), do: "ghost"

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

  defp probe_identity(probe, index) do
    identity =
      Enum.find(
        [Map.get(probe, :id), Map.get(probe, "id"), probe_timestamp(probe)],
        &(&1 not in [nil, "", "unknown"])
      )

    case identity do
      value when value in [nil, "", "unknown"] -> index
      %DateTime{} = value -> DateTime.to_unix(value, :microsecond)
      value -> value |> to_string() |> String.replace(~r/[^a-zA-Z0-9_-]+/, "-")
    end
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
    <div class="rounded-2xl border border-sr-line bg-sr-surface p-4 shadow-sm">
      <div class="flex items-start justify-between gap-3">
        <div>
          <div class="text-xs uppercase tracking-wide text-sr-ink/45">{@title}</div>
          <div class="mt-1 text-3xl font-semibold text-sr-ink">{@value}</div>
        </div>
        <div class={["flex size-10 items-center justify-center rounded-xl", tone_class(@tone)]}>
          <.icon name={@icon} class="size-5" />
        </div>
      </div>
    </div>
    """
  end

  defp tone_class("primary"), do: "bg-sr-brand/10 text-sr-brand"
  defp tone_class("success"), do: "bg-success/10 text-success"
  defp tone_class("error"), do: "bg-error/10 text-error"
  defp tone_class("warning"), do: "bg-warning/10 text-warning"
  defp tone_class(_), do: "bg-sr-subtle text-sr-ink"
end
