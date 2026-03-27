defmodule ServiceRadarWebNGWeb.CameraRelayLive.Index do
  @moduledoc false
  use ServiceRadarWebNGWeb, :live_view

  alias ServiceRadar.Camera.RelaySession
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.IdentityReconciler
  alias ServiceRadarWebNG.CameraRelayHealth

  require Ash.Query
  require Logger

  @refresh_interval_ms to_timeout(second: 5)
  @recent_terminal_limit 50
  @session_expiry_grace_seconds 15
  @session_fallback_freshness_seconds 120

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: schedule_refresh()

    {:ok,
     socket
     |> assign(:page_title, "Camera Relay Operations")
     |> assign(:srql, %{enabled: false, page_path: "/observability/camera-relays"})
     |> assign(:filters, %{active: "all", terminal: "all"})
     |> assign(:active_sessions, [])
     |> assign(:terminal_sessions, [])
     |> assign(:terminal_breakdown, [])
     |> assign(:summary, empty_summary())
     |> assign(:relay_health_active_alerts, [])
     |> assign(:relay_health_recent_events, [])
     |> assign(:refreshed_at, nil)
     |> assign(:error, nil)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    socket =
      socket
      |> assign(:filters, parse_filters(params))
      |> load_sessions()

    {:noreply, socket}
  end

  @impl true
  def handle_info(:refresh_data, socket) do
    schedule_refresh()
    {:noreply, load_sessions(socket)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply, load_sessions(socket)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} srql={@srql}>
      <div class="space-y-6">
        <div class="flex flex-col gap-4 lg:flex-row lg:items-start lg:justify-between">
          <div class="space-y-2">
            <div class="flex items-center gap-2 text-xs uppercase tracking-[0.24em] text-base-content/50">
              <span class="inline-flex size-2 rounded-full bg-success"></span> Relay Ops
            </div>
            <div>
              <h1 class="text-3xl font-semibold tracking-tight text-base-content">
                Camera Relay Operations
              </h1>
              <p class="mt-1 max-w-2xl text-sm text-base-content/70">
                Live relay visibility for active sessions, viewer load, and recent shutdown reasons.
              </p>
            </div>
          </div>

          <div class="flex flex-wrap items-center gap-2">
            <.link href={~p"/observability"} class="btn btn-ghost btn-sm">
              <.icon name="hero-arrow-left" class="size-4" /> Observability
            </.link>
            <button type="button" phx-click="refresh" class="btn btn-primary btn-sm">
              <.icon name="hero-arrow-path" class="size-4" /> Refresh
            </button>
          </div>
        </div>

        <div class="rounded-xl border border-base-200 bg-base-100 p-2">
          <div class="flex flex-wrap gap-2">
            <.link
              navigate={~p"/observability?#{%{tab: "logs"}}"}
              class="btn btn-sm btn-ghost rounded-lg"
            >
              <.icon name="hero-rectangle-stack" class="size-4" /> Logs
            </.link>
            <.link
              navigate={~p"/observability?#{%{tab: "traces"}}"}
              class="btn btn-sm btn-ghost rounded-lg"
            >
              <.icon name="hero-clock" class="size-4" /> Traces
            </.link>
            <.link
              navigate={~p"/observability?#{%{tab: "metrics"}}"}
              class="btn btn-sm btn-ghost rounded-lg"
            >
              <.icon name="hero-chart-bar" class="size-4" /> Metrics
            </.link>
            <.link
              navigate={~p"/observability?#{%{tab: "events"}}"}
              class="btn btn-sm btn-ghost rounded-lg"
            >
              <.icon name="hero-bell-alert" class="size-4" /> Events
            </.link>
            <.link
              navigate={~p"/observability?#{%{tab: "alerts"}}"}
              class="btn btn-sm btn-ghost rounded-lg"
            >
              <.icon name="hero-exclamation-triangle" class="size-4" /> Alerts
            </.link>
            <.link navigate={~p"/flows"} class="btn btn-sm btn-ghost rounded-lg">
              <.icon name="hero-arrow-path" class="size-4" /> Flows
            </.link>
            <.link navigate={~p"/observability/bmp"} class="btn btn-sm btn-ghost rounded-lg">
              <.icon name="hero-arrows-right-left" class="size-4" /> BMP
            </.link>
            <.link navigate={~p"/observability/bgp"} class="btn btn-sm btn-ghost rounded-lg">
              <.icon name="hero-globe-alt" class="size-4" /> BGP Routing
            </.link>
            <.link
              navigate={~p"/observability/camera-relays"}
              class="btn btn-sm btn-primary rounded-lg"
            >
              <.icon name="hero-video-camera" class="size-4" /> Camera Relays
            </.link>
            <.link
              navigate={~p"/observability/camera-analysis-workers"}
              class="btn btn-sm btn-ghost rounded-lg"
            >
              <.icon name="hero-cpu-chip" class="size-4" /> Analysis Workers
            </.link>
          </div>
        </div>

        <div :if={@error} class="alert alert-warning">
          <.icon name="hero-exclamation-triangle" class="size-5" />
          <span>{@error}</span>
        </div>

        <div class="grid gap-4 md:grid-cols-2 xl:grid-cols-6">
          <.summary_card
            title="Live Sessions"
            value={@summary.live_sessions}
            tone="success"
            icon="hero-video-camera"
            params={filter_params(@filters, %{active: "active"})}
          />
          <.summary_card
            title="Opening"
            value={@summary.opening_sessions}
            tone="warning"
            icon="hero-arrow-path"
            params={filter_params(@filters, %{active: "opening"})}
          />
          <.summary_card
            title="Closing"
            value={@summary.closing_sessions}
            tone="warning"
            icon="hero-stop-circle"
            params={filter_params(@filters, %{active: "closing"})}
          />
          <.summary_card
            title="Active Viewers"
            value={@summary.active_viewers}
            tone="primary"
            icon="hero-user-group"
          />
          <.summary_card
            title="Recent Failures"
            value={@summary.recent_failures}
            tone="error"
            icon="hero-bolt"
            params={filter_params(@filters, %{terminal: "failed"})}
          />
          <.summary_card
            title="Health Alerts"
            value={length(@relay_health_active_alerts)}
            tone="error"
            icon="hero-exclamation-circle"
          />
        </div>

        <section class="grid gap-6 xl:grid-cols-2">
          <article class="rounded-2xl border border-base-200 bg-base-100 shadow-sm">
            <div class="border-b border-base-200 px-5 py-4">
              <div class="flex items-center justify-between gap-3">
                <div>
                  <h2 class="text-lg font-semibold text-base-content">Active Relay Health Alerts</h2>
                  <p class="text-sm text-base-content/60">
                    Threshold alerts driven by relay failure bursts, saturation denials, and churn.
                  </p>
                </div>
                <span class="badge badge-ghost">{length(@relay_health_active_alerts)} active</span>
              </div>
            </div>

            <div class="divide-y divide-base-200">
              <div
                :if={@relay_health_active_alerts == []}
                class="px-5 py-10 text-center text-sm text-base-content/60"
              >
                No active relay health alerts.
              </div>

              <article :for={alert <- @relay_health_active_alerts} class="px-5 py-4">
                <div class="flex items-start justify-between gap-3">
                  <div class="min-w-0 space-y-1">
                    <div class="flex flex-wrap items-center gap-2">
                      <span class="font-medium text-base-content">{alert.title}</span>
                      <span class={alert_badge_class(alert.severity)}>
                        {String.capitalize(alert.severity || "unknown")}
                      </span>
                      <span class={status_badge_class(alert.status)}>
                        {format_status(alert.status)}
                      </span>
                    </div>
                    <div class="text-sm text-base-content/60">{alert.description}</div>
                    <div class="text-xs text-base-content/50">
                      {display_value(alert.log_name)} · notifications={alert.notification_count}
                    </div>
                  </div>

                  <div class="shrink-0 text-right text-xs text-base-content/50">
                    <div>{format_datetime(alert.triggered_at)}</div>
                    <div>{format_datetime(alert.last_notification_at)}</div>
                  </div>
                </div>

                <div class="mt-3 flex flex-wrap gap-2">
                  <.link navigate={~p"/alerts/#{alert.id}"} class="btn btn-ghost btn-xs">
                    View alert
                  </.link>
                </div>
              </article>
            </div>
          </article>

          <article class="rounded-2xl border border-base-200 bg-base-100 shadow-sm">
            <div class="border-b border-base-200 px-5 py-4">
              <div class="flex items-center justify-between gap-3">
                <div>
                  <h2 class="text-lg font-semibold text-base-content">Recent Relay Health Signals</h2>
                  <p class="text-sm text-base-content/60">
                    Structured relay-health events feeding the alert templates and event stream.
                  </p>
                </div>
                <span class="badge badge-ghost">{length(@relay_health_recent_events)} recent</span>
              </div>
            </div>

            <div class="divide-y divide-base-200">
              <div
                :if={@relay_health_recent_events == []}
                class="px-5 py-10 text-center text-sm text-base-content/60"
              >
                No recent relay health signals.
              </div>

              <article :for={event <- @relay_health_recent_events} class="px-5 py-4">
                <div class="flex items-start justify-between gap-3">
                  <div class="min-w-0 space-y-1">
                    <div class="flex flex-wrap items-center gap-2">
                      <span class="font-medium text-base-content">{event.message}</span>
                      <span class={event_badge_class(event.relay_health_kind)}>
                        {entry_label(event.relay_health_kind)}
                      </span>
                    </div>
                    <div class="text-sm text-base-content/60">
                      session={display_value(event.relay_session_id)} · gateway={display_value(
                        event.gateway_id
                      )}
                    </div>
                    <div class="text-xs text-base-content/50">
                      {display_value(event.log_name)} · reason={display_value(
                        event.reason || event.status_detail
                      )}
                    </div>
                  </div>

                  <div class="shrink-0 text-right text-xs text-base-content/50">
                    <div>{format_datetime(event.time)}</div>
                    <div>{display_value(event.severity)}</div>
                  </div>
                </div>

                <div class="mt-3 flex flex-wrap gap-2">
                  <.link navigate={~p"/events/#{event.id}"} class="btn btn-ghost btn-xs">
                    View event
                  </.link>
                </div>
              </article>
            </div>
          </article>
        </section>

        <section class="rounded-2xl border border-base-200 bg-base-100 shadow-sm">
          <div class="border-b border-base-200 px-5 py-4">
            <div class="flex items-center justify-between gap-3">
              <div>
                <h2 class="text-lg font-semibold text-base-content">Terminal Outcome Breakdown</h2>
                <p class="text-sm text-base-content/60">
                  Quick drill-down for the most common recent relay shutdown classes.
                </p>
              </div>
              <span class="badge badge-ghost">{length(@terminal_breakdown)} kinds</span>
            </div>
          </div>

          <div class="flex flex-wrap gap-3 px-5 py-4">
            <div :if={@terminal_breakdown == []} class="text-sm text-base-content/60">
              No terminal relay outcomes yet.
            </div>

            <.link
              :for={entry <- @terminal_breakdown}
              patch={
                ~p"/observability/camera-relays?#{filter_params(@filters, %{terminal: entry.kind})}"
              }
              class="group rounded-xl border border-base-200 bg-base-50 px-4 py-3 transition hover:border-primary/30 hover:bg-primary/5"
            >
              <div class="text-xs uppercase tracking-wide text-base-content/45">
                {entry_label(entry.kind)}
              </div>
              <div class="mt-1 flex items-baseline gap-2">
                <span class="text-2xl font-semibold text-base-content">{entry.count}</span>
                <span class="text-xs text-base-content/50">recent sessions</span>
              </div>
            </.link>
          </div>
        </section>

        <div class="grid gap-6 xl:grid-cols-[minmax(0,1.4fr)_minmax(0,1fr)]">
          <section class="rounded-2xl border border-base-200 bg-base-100 shadow-sm">
            <div class="border-b border-base-200 px-5 py-4">
              <div class="flex items-center justify-between gap-3">
                <div>
                  <h2 class="text-lg font-semibold text-base-content">Active Relay Sessions</h2>
                  <p class="text-sm text-base-content/60">
                    Requested, opening, active, and closing sessions across the deployment.
                  </p>
                </div>
                <span class="badge badge-ghost">{length(@active_sessions)} sessions</span>
              </div>
              <div class="mt-3 flex flex-wrap gap-2">
                <.filter_chip
                  label="All"
                  value="all"
                  current={@filters.active}
                  params={filter_params(@filters, %{active: "all"})}
                />
                <.filter_chip
                  label="Requested"
                  value="requested"
                  current={@filters.active}
                  params={filter_params(@filters, %{active: "requested"})}
                />
                <.filter_chip
                  label="Opening"
                  value="opening"
                  current={@filters.active}
                  params={filter_params(@filters, %{active: "opening"})}
                />
                <.filter_chip
                  label="Active"
                  value="active"
                  current={@filters.active}
                  params={filter_params(@filters, %{active: "active"})}
                />
                <.filter_chip
                  label="Closing"
                  value="closing"
                  current={@filters.active}
                  params={filter_params(@filters, %{active: "closing"})}
                />
              </div>
            </div>

            <div class="overflow-x-auto">
              <table class="table table-zebra">
                <thead>
                  <tr>
                    <th>Camera</th>
                    <th>Status</th>
                    <th>Agent</th>
                    <th>Gateway</th>
                    <th>Viewers</th>
                    <th>Actions</th>
                    <th>Updated</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :if={@active_sessions == []}>
                    <td colspan="7" class="py-10 text-center text-sm text-base-content/60">
                      No live relay sessions right now.
                    </td>
                  </tr>
                  <tr :for={session <- @active_sessions}>
                    <td>
                      <div class="space-y-1">
                        <div class="font-medium text-base-content">{camera_label(session)}</div>
                        <div class="text-xs text-base-content/55">
                          {profile_label(session)}
                        </div>
                        <div :if={device_uid(session)} class="text-xs">
                          <.link
                            navigate={~p"/devices/#{device_uid(session)}"}
                            class="link link-hover text-primary"
                          >
                            View device
                          </.link>
                        </div>
                      </div>
                    </td>
                    <td>
                      <span class={status_badge_class(session.status)}>
                        {format_status(session.status)}
                      </span>
                    </td>
                    <td class="font-mono text-xs">{session.agent_id}</td>
                    <td class="font-mono text-xs">{session.gateway_id}</td>
                    <td>{Map.get(session, :viewer_count, 0)}</td>
                    <td>
                      <.session_log_links session={session} />
                    </td>
                    <td class="text-xs text-base-content/60">
                      {format_datetime(session.updated_at)}
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          </section>

          <section class="rounded-2xl border border-base-200 bg-base-100 shadow-sm">
            <div class="border-b border-base-200 px-5 py-4">
              <div class="flex items-center justify-between gap-3">
                <div>
                  <h2 class="text-lg font-semibold text-base-content">Recent Terminal Sessions</h2>
                  <p class="text-sm text-base-content/60">
                    Most recent closed and failed relay sessions with normalized termination details.
                  </p>
                </div>
                <span class="badge badge-ghost">last 50</span>
              </div>
              <div class="mt-3 flex flex-wrap gap-2">
                <.filter_chip
                  label="All"
                  value="all"
                  current={@filters.terminal}
                  params={filter_params(@filters, %{terminal: "all"})}
                />
                <.filter_chip
                  label="Failures"
                  value="failed"
                  current={@filters.terminal}
                  params={filter_params(@filters, %{terminal: "failed"})}
                />
                <.filter_chip
                  label="Viewer Idle"
                  value="viewer_idle"
                  current={@filters.terminal}
                  params={filter_params(@filters, %{terminal: "viewer_idle"})}
                />
                <.filter_chip
                  label="Manual Stop"
                  value="manual_stop"
                  current={@filters.terminal}
                  params={filter_params(@filters, %{terminal: "manual_stop"})}
                />
                <.filter_chip
                  label="Drain"
                  value="transport_drain"
                  current={@filters.terminal}
                  params={filter_params(@filters, %{terminal: "transport_drain"})}
                />
                <.filter_chip
                  label="Source Done"
                  value="source_complete"
                  current={@filters.terminal}
                  params={filter_params(@filters, %{terminal: "source_complete"})}
                />
                <.filter_chip
                  label="Closed"
                  value="closed"
                  current={@filters.terminal}
                  params={filter_params(@filters, %{terminal: "closed"})}
                />
              </div>
            </div>

            <div class="divide-y divide-base-200">
              <div
                :if={@terminal_sessions == []}
                class="px-5 py-10 text-center text-sm text-base-content/60"
              >
                No terminal relay sessions yet.
              </div>

              <article :for={session <- @terminal_sessions} class="px-5 py-4">
                <div class="flex items-start justify-between gap-3">
                  <div class="min-w-0 space-y-1">
                    <div class="flex flex-wrap items-center gap-2">
                      <span class="font-medium text-base-content">{camera_label(session)}</span>
                      <span class={status_badge_class(session.status)}>
                        {format_status(session.status)}
                      </span>
                    </div>
                    <div class="text-sm text-base-content/60">{profile_label(session)}</div>
                    <div class="text-xs text-base-content/50">
                      termination={display_value(Map.get(session, :termination_kind))} · viewers={Map.get(
                        session,
                        :viewer_count,
                        0
                      )}
                    </div>
                  </div>
                  <div class="shrink-0 text-right text-xs text-base-content/50">
                    <div>{format_datetime(session.closed_at || session.updated_at)}</div>
                    <div class="font-mono">{session.gateway_id}</div>
                  </div>
                </div>

                <div class="mt-3 grid gap-2 text-xs text-base-content/65">
                  <div>
                    <span class="font-semibold text-base-content/75">Close reason:</span>
                    {display_value(Map.get(session, :close_reason))}
                  </div>
                  <div>
                    <span class="font-semibold text-base-content/75">Failure reason:</span>
                    {display_value(Map.get(session, :failure_reason))}
                  </div>
                </div>

                <div class="mt-3">
                  <.session_log_links session={session} />
                </div>
              </article>
            </div>
          </section>
        </div>

        <div class="flex items-center gap-2 text-xs text-base-content/45">
          <span :if={is_struct(@refreshed_at, DateTime)} class="font-mono">
            Updated {Calendar.strftime(@refreshed_at, "%H:%M:%S")}
          </span>
          <span :if={is_struct(@refreshed_at, DateTime)}>·</span>
          <span>Auto-refresh 5s</span>
        </div>
      </div>
    </Layouts.app>
    """
  end

  attr(:title, :string, required: true)
  attr(:value, :integer, required: true)
  attr(:tone, :string, default: "neutral")
  attr(:icon, :string, default: "hero-chart-bar")
  attr(:params, :map, default: nil)

  defp summary_card(assigns) do
    ~H"""
    <%= if is_map(@params) do %>
      <.link
        patch={~p"/observability/camera-relays?#{@params}"}
        class={[
          "block rounded-2xl border bg-base-100 p-4 shadow-sm transition hover:shadow-md",
          tone_border(@tone)
        ]}
      >
        <div class="flex items-center justify-between gap-3">
          <div>
            <div class="text-xs uppercase tracking-wide text-base-content/50">{@title}</div>
            <div class={["mt-2 text-3xl font-semibold tracking-tight", tone_value(@tone)]}>
              {@value}
            </div>
          </div>
          <div class={["rounded-xl p-3", tone_bg(@tone)]}>
            <.icon name={@icon} class={["size-5", tone_icon(@tone)]} />
          </div>
        </div>
      </.link>
    <% else %>
      <div class={["rounded-2xl border bg-base-100 p-4 shadow-sm", tone_border(@tone)]}>
        <div class="flex items-center justify-between gap-3">
          <div>
            <div class="text-xs uppercase tracking-wide text-base-content/50">{@title}</div>
            <div class={["mt-2 text-3xl font-semibold tracking-tight", tone_value(@tone)]}>
              {@value}
            </div>
          </div>
          <div class={["rounded-xl p-3", tone_bg(@tone)]}>
            <.icon name={@icon} class={["size-5", tone_icon(@tone)]} />
          </div>
        </div>
      </div>
    <% end %>
    """
  end

  attr(:label, :string, required: true)
  attr(:value, :string, required: true)
  attr(:current, :string, required: true)
  attr(:params, :map, required: true)

  defp filter_chip(assigns) do
    active? = assigns.current == assigns.value
    assigns = assign(assigns, :active?, active?)

    ~H"""
    <.link
      patch={~p"/observability/camera-relays?#{@params}"}
      class={[
        "btn btn-xs rounded-full",
        @active? && "btn-primary",
        not @active? && "btn-ghost"
      ]}
    >
      {@label}
    </.link>
    """
  end

  attr(:session, :map, required: true)

  defp session_log_links(assigns) do
    ~H"""
    <div class="flex flex-wrap gap-2">
      <.link navigate={relay_logs_href(@session)} class="btn btn-ghost btn-xs">
        Relay Logs
      </.link>
      <.link
        :if={present?(Map.get(@session, :agent_id))}
        navigate={agent_logs_href(@session)}
        class="btn btn-ghost btn-xs"
      >
        Agent Logs
      </.link>
      <.link
        :if={present?(Map.get(@session, :gateway_id))}
        navigate={gateway_logs_href(@session)}
        class="btn btn-ghost btn-xs"
      >
        Gateway Logs
      </.link>
    </div>
    """
  end

  defp load_sessions(socket) do
    scope = socket.assigns.current_scope

    case fetch_sessions(scope) do
      {:ok, active_sessions, terminal_sessions} ->
        active_sessions = filter_current_sessions(active_sessions)
        relay_health = fetch_relay_health(scope)

        filtered_active_sessions =
          filter_active_sessions(active_sessions, socket.assigns.filters.active)

        filtered_terminal_sessions =
          filter_terminal_sessions(terminal_sessions, socket.assigns.filters.terminal)

        socket
        |> assign(:active_sessions, filtered_active_sessions)
        |> assign(:terminal_sessions, filtered_terminal_sessions)
        |> assign(:terminal_breakdown, build_terminal_breakdown(terminal_sessions))
        |> assign(:summary, build_summary(active_sessions, terminal_sessions))
        |> assign(:relay_health_active_alerts, Map.get(relay_health, :active_alerts, []))
        |> assign(:relay_health_recent_events, Map.get(relay_health, :recent_events, []))
        |> assign(:refreshed_at, DateTime.utc_now())
        |> assign(:error, nil)

      {:error, reason} ->
        Logger.warning("Failed to load camera relay operations page: #{inspect(reason)}")

        socket
        |> assign(:active_sessions, [])
        |> assign(:terminal_sessions, [])
        |> assign(:terminal_breakdown, [])
        |> assign(:summary, empty_summary())
        |> assign(:relay_health_active_alerts, [])
        |> assign(:relay_health_recent_events, [])
        |> assign(:refreshed_at, DateTime.utc_now())
        |> assign(:error, "Failed to load camera relay session data")
    end
  end

  defp fetch_relay_health(scope) do
    case relay_health_source().overview(scope: scope) do
      {:ok, overview} ->
        overview

      {:error, reason} ->
        Logger.warning("Failed to load relay health context: #{inspect(reason)}")
        %{active_alerts: [], recent_events: []}
    end
  end

  defp fetch_sessions(scope) do
    active_query =
      RelaySession
      |> Ash.Query.for_read(:read, %{}, scope: scope)
      |> Ash.Query.filter(status in [:requested, :opening, :active, :closing])
      |> Ash.Query.sort(inserted_at: :desc)
      |> Ash.Query.load([:termination_kind, :camera_source, :stream_profile])

    terminal_query =
      RelaySession
      |> Ash.Query.for_read(:read, %{}, scope: scope)
      |> Ash.Query.filter(status in [:closed, :failed])
      |> Ash.Query.sort(updated_at: :desc)
      |> Ash.Query.limit(@recent_terminal_limit)
      |> Ash.Query.load([:termination_kind, :camera_source, :stream_profile])

    with {:ok, active_sessions} <- Ash.read(active_query, scope: scope),
         {:ok, terminal_sessions} <- Ash.read(terminal_query, scope: scope) do
      {active_sessions, terminal_sessions} =
        resolve_session_device_links(active_sessions, terminal_sessions, scope)

      {:ok, active_sessions, terminal_sessions}
    end
  end

  defp resolve_session_device_links(active_sessions, terminal_sessions, scope) do
    sessions = active_sessions ++ terminal_sessions
    {candidate_uids, candidate_macs} = collect_device_link_candidates(sessions)

    case read_linkable_devices(candidate_uids, candidate_macs, scope) do
      {:ok, devices} ->
        uid_index = Map.new(devices, &{&1.uid, &1.uid})

        mac_index =
          Map.new(devices, fn device ->
            {normalize_mac(device.mac), device.uid}
          end)

        {
          Enum.map(active_sessions, &put_resolved_device_uid(&1, uid_index, mac_index)),
          Enum.map(terminal_sessions, &put_resolved_device_uid(&1, uid_index, mac_index))
        }

      {:error, reason} ->
        Logger.warning("Failed to resolve camera relay device links: #{inspect(reason)}")

        {
          Enum.map(active_sessions, &Map.put(&1, :resolved_device_uid, nil)),
          Enum.map(terminal_sessions, &Map.put(&1, :resolved_device_uid, nil))
        }
    end
  end

  defp collect_device_link_candidates(sessions) do
    sessions
    |> Enum.reduce({MapSet.new(), MapSet.new()}, fn session, {uids, macs} ->
      {candidate_uids, candidate_macs} = session_device_link_candidates(session)

      {
        Enum.reduce(candidate_uids, uids, &MapSet.put(&2, &1)),
        Enum.reduce(candidate_macs, macs, &MapSet.put(&2, &1))
      }
    end)
    |> then(fn {uids, macs} -> {MapSet.to_list(uids), MapSet.to_list(macs)} end)
  end

  defp session_device_link_candidates(session) do
    source = Map.get(session, :camera_source)
    raw_device_uid = source_device_uid(source)

    {
      Enum.filter([raw_device_uid], &present?/1),
      [
        normalize_mac(raw_device_uid),
        normalize_mac(source_identity_mac(source))
      ]
      |> Enum.filter(&present?/1)
      |> Enum.uniq()
    }
  end

  defp read_linkable_devices([], [], _scope), do: {:ok, []}

  defp read_linkable_devices(candidate_uids, candidate_macs, scope) do
    query =
      Device
      |> Ash.Query.for_read(:read, %{}, scope: scope)
      |> filter_linkable_devices(candidate_uids, candidate_macs)

    case Ash.read(query, scope: scope) do
      {:ok, %Ash.Page.Keyset{results: results}} -> {:ok, results}
      {:ok, results} when is_list(results) -> {:ok, results}
      other -> other
    end
  end

  defp filter_linkable_devices(query, candidate_uids, candidate_macs)
       when candidate_uids != [] and candidate_macs != [] do
    Ash.Query.filter(query, uid in ^candidate_uids or mac in ^candidate_macs)
  end

  defp filter_linkable_devices(query, candidate_uids, _candidate_macs)
       when candidate_uids != [] do
    Ash.Query.filter(query, uid in ^candidate_uids)
  end

  defp filter_linkable_devices(query, _candidate_uids, candidate_macs)
       when candidate_macs != [] do
    Ash.Query.filter(query, mac in ^candidate_macs)
  end

  defp put_resolved_device_uid(session, uid_index, mac_index) do
    Map.put(
      session,
      :resolved_device_uid,
      resolve_session_device_uid(session, uid_index, mac_index)
    )
  end

  defp resolve_session_device_uid(session, uid_index, mac_index) do
    source = Map.get(session, :camera_source)
    raw_device_uid = source_device_uid(source)

    Map.get(uid_index, raw_device_uid) ||
      Map.get(mac_index, normalize_mac(raw_device_uid)) ||
      Map.get(mac_index, normalize_mac(source_identity_mac(source)))
  end

  defp build_summary(active_sessions, terminal_sessions) do
    %{
      live_sessions: Enum.count(active_sessions, &(normalize_status(&1.status) == "active")),
      opening_sessions:
        Enum.count(active_sessions, &(normalize_status(&1.status) in ["requested", "opening"])),
      closing_sessions: Enum.count(active_sessions, &(normalize_status(&1.status) == "closing")),
      active_viewers: Enum.reduce(active_sessions, 0, &(&2 + Map.get(&1, :viewer_count, 0))),
      recent_failures: Enum.count(terminal_sessions, &(normalize_status(&1.status) == "failed"))
    }
  end

  defp empty_summary do
    %{
      live_sessions: 0,
      opening_sessions: 0,
      closing_sessions: 0,
      active_viewers: 0,
      recent_failures: 0
    }
  end

  defp filter_current_sessions(sessions, now \\ DateTime.utc_now()) do
    Enum.filter(sessions, &current_session?(&1, now))
  end

  defp current_session?(session, now) do
    case Map.get(session, :lease_expires_at) do
      %DateTime{} = lease_expires_at ->
        DateTime.compare(
          lease_expires_at,
          DateTime.add(now, -@session_expiry_grace_seconds, :second)
        ) ==
          :gt

      _other ->
        recent_session_update?(session, now)
    end
  end

  defp recent_session_update?(session, now) do
    freshness_cutoff = DateTime.add(now, -@session_fallback_freshness_seconds, :second)

    session
    |> session_activity_timestamps()
    |> Enum.any?(&(DateTime.compare(&1, freshness_cutoff) == :gt))
  end

  defp session_activity_timestamps(session) do
    [:updated_at, :activated_at, :opened_at, :inserted_at]
    |> Enum.map(&Map.get(session, &1))
    |> Enum.filter(&match?(%DateTime{}, &1))
  end

  defp build_terminal_breakdown(sessions) do
    sessions
    |> Enum.map(&(Map.get(&1, :termination_kind) || "closed"))
    |> Enum.frequencies()
    |> Enum.sort_by(fn {kind, count} -> {-count, kind} end)
    |> Enum.map(fn {kind, count} -> %{kind: kind, count: count} end)
  end

  defp schedule_refresh do
    Process.send_after(self(), :refresh_data, @refresh_interval_ms)
  end

  defp parse_filters(params) when is_map(params) do
    %{
      active: normalize_active_filter(Map.get(params, "active")),
      terminal: normalize_terminal_filter(Map.get(params, "terminal"))
    }
  end

  defp parse_filters(_params), do: %{active: "all", terminal: "all"}

  defp filter_params(filters, overrides) do
    filters
    |> Map.merge(overrides)
    |> Enum.reject(fn {_key, value} -> value in [nil, "", "all"] end)
    |> Map.new()
  end

  defp filter_active_sessions(sessions, "all"), do: sessions

  defp filter_active_sessions(sessions, status) do
    Enum.filter(sessions, &(normalize_status(&1.status) == status))
  end

  defp filter_terminal_sessions(sessions, "all"), do: sessions

  defp filter_terminal_sessions(sessions, "failed"),
    do: Enum.filter(sessions, &(normalize_status(&1.status) == "failed"))

  defp filter_terminal_sessions(sessions, "closed") do
    Enum.filter(sessions, &(normalize_status(&1.status) == "closed"))
  end

  defp filter_terminal_sessions(sessions, termination_kind) do
    Enum.filter(sessions, fn session ->
      Map.get(session, :termination_kind) == termination_kind
    end)
  end

  defp normalize_active_filter(value) when value in ["requested", "opening", "active", "closing"],
    do: value

  defp normalize_active_filter(_value), do: "all"

  defp normalize_terminal_filter(value)
       when value in [
              "failed",
              "viewer_idle",
              "manual_stop",
              "transport_drain",
              "source_complete",
              "closed"
            ], do: value

  defp normalize_terminal_filter(_value), do: "all"

  defp camera_label(session) do
    source = Map.get(session, :camera_source)

    cond do
      is_map(source) and present?(Map.get(source, :display_name)) -> source.display_name
      is_map(source) and present?(Map.get(source, :vendor_camera_id)) -> source.vendor_camera_id
      true -> session.camera_source_id
    end
  end

  defp profile_label(session) do
    profile = Map.get(session, :stream_profile)

    if is_map(profile) and present?(Map.get(profile, :profile_name)) do
      profile.profile_name
    else
      session.stream_profile_id
    end
  end

  defp device_uid(session) do
    Map.get(session, :resolved_device_uid)
  end

  defp source_device_uid(%{device_uid: device_uid}) when is_binary(device_uid),
    do: String.trim(device_uid)

  defp source_device_uid(_source), do: nil

  defp source_identity_mac(%{metadata: metadata}) when is_map(metadata) do
    metadata
    |> Map.get("identity", Map.get(metadata, :identity))
    |> case do
      identity when is_map(identity) -> Map.get(identity, "mac", Map.get(identity, :mac))
      _ -> nil
    end
  end

  defp source_identity_mac(_source), do: nil

  defp normalize_mac(value) when is_binary(value), do: IdentityReconciler.normalize_mac(value)
  defp normalize_mac(_value), do: nil

  defp status_badge_class(status) do
    normalized = normalize_status(status)

    base = "badge badge-sm border"

    case normalized do
      "active" -> "#{base} border-success/30 bg-success/10 text-success"
      "requested" -> "#{base} border-warning/30 bg-warning/10 text-warning"
      "opening" -> "#{base} border-warning/30 bg-warning/10 text-warning"
      "closing" -> "#{base} border-warning/30 bg-warning/10 text-warning"
      "closed" -> "#{base} border-base-300 bg-base-200 text-base-content/70"
      "failed" -> "#{base} border-error/30 bg-error/10 text-error"
      _ -> "#{base} border-base-300 bg-base-200 text-base-content/70"
    end
  end

  defp format_status(status) do
    status
    |> normalize_status()
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  defp normalize_status(status) when is_atom(status), do: Atom.to_string(status)
  defp normalize_status(status) when is_binary(status), do: status
  defp normalize_status(_status), do: "unknown"

  defp format_datetime(%DateTime{} = datetime),
    do: Calendar.strftime(datetime, "%Y-%m-%d %H:%M:%S UTC")

  defp format_datetime(_datetime), do: "n/a"

  defp display_value(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: "n/a", else: trimmed
  end

  defp display_value(nil), do: "n/a"
  defp display_value(value), do: to_string(value)

  defp relay_logs_href(session) do
    observability_logs_href(relay_session_id: Map.get(session, :id))
  end

  defp agent_logs_href(session) do
    observability_logs_href(
      relay_session_id: Map.get(session, :id),
      agent_id: Map.get(session, :agent_id)
    )
  end

  defp gateway_logs_href(session) do
    observability_logs_href(
      relay_session_id: Map.get(session, :id),
      gateway_id: Map.get(session, :gateway_id)
    )
  end

  defp observability_logs_href(filters) when is_list(filters) do
    clauses =
      Enum.flat_map(filters, fn
        {field, value} when field in [:relay_session_id, :agent_id, :gateway_id] ->
          case escaped_query_value(value) do
            nil -> []
            escaped -> ["#{field}:\"#{escaped}\""]
          end

        _other ->
          []
      end)

    q =
      ["in:logs" | clauses] ++
        ["time:last_24h", "sort:timestamp:desc", "limit:50"]

    "/observability?" <> URI.encode_query(%{tab: "logs", q: Enum.join(q, " "), limit: 50})
  end

  defp escaped_query_value(value) when is_binary(value) do
    trimmed = String.trim(value)

    if trimmed == "" do
      nil
    else
      trimmed
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")
    end
  end

  defp escaped_query_value(value) when is_nil(value), do: nil
  defp escaped_query_value(value), do: value |> to_string() |> escaped_query_value()

  defp entry_label("viewer_idle"), do: "Viewer Idle"
  defp entry_label("viewer_idle_termination"), do: "Viewer Idle"
  defp entry_label("manual_stop"), do: "Manual Stop"
  defp entry_label("transport_drain"), do: "Transport Drain"
  defp entry_label("source_complete"), do: "Source Complete"
  defp entry_label("failure"), do: "Failure"
  defp entry_label("session_failure"), do: "Session Failure"
  defp entry_label("gateway_saturation_denial"), do: "Gateway Saturation"
  defp entry_label("closed"), do: "Closed"

  defp entry_label(value) when is_binary(value),
    do: value |> String.replace("_", " ") |> String.capitalize()

  defp entry_label(_value), do: "Unknown"

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false

  defp tone_border("error"), do: "border-error/25"
  defp tone_border("warning"), do: "border-warning/25"
  defp tone_border("success"), do: "border-success/25"
  defp tone_border("primary"), do: "border-primary/25"
  defp tone_border(_tone), do: "border-base-200"

  defp tone_bg("error"), do: "bg-error/10"
  defp tone_bg("warning"), do: "bg-warning/10"
  defp tone_bg("success"), do: "bg-success/10"
  defp tone_bg("primary"), do: "bg-primary/10"
  defp tone_bg(_tone), do: "bg-base-200"

  defp tone_icon("error"), do: "text-error"
  defp tone_icon("warning"), do: "text-warning"
  defp tone_icon("success"), do: "text-success"
  defp tone_icon("primary"), do: "text-primary"
  defp tone_icon(_tone), do: "text-base-content"

  defp tone_value("error"), do: "text-error"
  defp tone_value("warning"), do: "text-warning"
  defp tone_value("success"), do: "text-success"
  defp tone_value("primary"), do: "text-primary"
  defp tone_value(_tone), do: "text-base-content"

  defp alert_badge_class("critical"),
    do: "badge badge-sm border border-error/30 bg-error/10 text-error"

  defp alert_badge_class("warning"),
    do: "badge badge-sm border border-warning/30 bg-warning/10 text-warning"

  defp alert_badge_class("info"), do: "badge badge-sm border border-info/30 bg-info/10 text-info"

  defp alert_badge_class(_severity),
    do: "badge badge-sm border border-base-300 bg-base-200 text-base-content/70"

  defp event_badge_class("session_failure"),
    do: "badge badge-sm border border-error/30 bg-error/10 text-error"

  defp event_badge_class("gateway_saturation_denial"),
    do: "badge badge-sm border border-warning/30 bg-warning/10 text-warning"

  defp event_badge_class("viewer_idle_termination"),
    do: "badge badge-sm border border-base-300 bg-base-200 text-base-content/70"

  defp event_badge_class(_kind),
    do: "badge badge-sm border border-base-300 bg-base-200 text-base-content/70"

  defp relay_health_source do
    Application.get_env(
      :serviceradar_web_ng,
      :camera_relay_health_source,
      CameraRelayHealth
    )
  end
end
