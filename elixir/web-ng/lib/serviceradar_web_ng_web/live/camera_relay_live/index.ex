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
      <div class="sr-observability-page space-y-6 font-sans">
        <.observability_chrome active_pane="camera-relays" active_subsection="operations">
          <:actions>
            <.ui_button type="button" phx-click="refresh" size="sm" variant="primary">
              <.icon name="hero-arrow-path" class="size-4" /> Refresh
            </.ui_button>
          </:actions>
        </.observability_chrome>

        <div class="flex flex-col gap-4 lg:flex-row lg:items-start lg:justify-between">
          <div class="space-y-2">
            <div class="flex items-center gap-2 text-xs uppercase tracking-[0.24em] text-sr-muted">
              <span class="inline-flex size-2 rounded-full bg-success"></span> Relay Ops
            </div>
            <div>
              <h1 class="text-3xl font-semibold tracking-tight text-sr-ink">
                Camera Relay Operations
              </h1>
              <p class="mt-1 max-w-2xl text-sm text-sr-muted">
                Live relay visibility for active sessions, viewer load, and recent shutdown reasons.
              </p>
            </div>
          </div>
        </div>

        <div :if={@error} class={ui_alert_class("warning")}>
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
          <article class="rounded-2xl border border-sr-line bg-sr-surface shadow-sm">
            <div class="border-b border-sr-line px-5 py-4">
              <div class="flex items-center justify-between gap-3">
                <div>
                  <h2 class="text-lg font-semibold text-sr-ink">Active Relay Health Alerts</h2>
                  <p class="text-sm text-sr-muted">
                    Threshold alerts driven by relay failure bursts, saturation denials, and churn.
                  </p>
                </div>
                <.ui_badge size="sm" variant="ghost">
                  {length(@relay_health_active_alerts)} active
                </.ui_badge>
              </div>
            </div>

            <div class="divide-y divide-sr-line">
              <div
                :if={@relay_health_active_alerts == []}
                class="px-5 py-10 text-center text-sm text-sr-muted"
              >
                No active relay health alerts.
              </div>

              <article :for={alert <- @relay_health_active_alerts} class="px-5 py-4">
                <div class="flex items-start justify-between gap-3">
                  <div class="min-w-0 space-y-1">
                    <div class="flex flex-wrap items-center gap-2">
                      <span class="font-medium text-sr-ink">{alert.title}</span>
                      <.ui_badge size="sm" variant={alert_badge_variant(alert.severity)}>
                        {String.capitalize(alert.severity || "unknown")}
                      </.ui_badge>
                      <.ui_badge size="sm" variant={status_badge_variant(alert.status)}>
                        {format_status(alert.status)}
                      </.ui_badge>
                    </div>
                    <div class="text-sm text-sr-muted">{alert.description}</div>
                    <div class="text-xs text-sr-muted">
                      {display_value(alert.log_name)} · notifications={alert.notification_count}
                    </div>
                  </div>

                  <div class="shrink-0 text-right text-xs text-sr-muted">
                    <div>
                      <.user_time
                        id={"camera-relay-alert-#{alert.id}-triggered-at"}
                        value={alert.triggered_at}
                        timezone={@current_scope.user.timezone || "Etc/UTC"}
                        style={:compact}
                        fallback="n/a"
                      />
                    </div>
                    <div>
                      <.user_time
                        id={"camera-relay-alert-#{alert.id}-last-notification-at"}
                        value={alert.last_notification_at}
                        timezone={@current_scope.user.timezone || "Etc/UTC"}
                        style={:compact}
                        fallback="n/a"
                      />
                    </div>
                  </div>
                </div>

                <div class="mt-3 flex flex-wrap gap-2">
                  <.ui_button navigate={~p"/alerts/#{alert.id}"} size="xs" variant="ghost">
                    View alert
                  </.ui_button>
                </div>
              </article>
            </div>
          </article>

          <article class="rounded-2xl border border-sr-line bg-sr-surface shadow-sm">
            <div class="border-b border-sr-line px-5 py-4">
              <div class="flex items-center justify-between gap-3">
                <div>
                  <h2 class="text-lg font-semibold text-sr-ink">Recent Relay Health Signals</h2>
                  <p class="text-sm text-sr-muted">
                    Structured relay-health events feeding the alert templates and event stream.
                  </p>
                </div>
                <.ui_badge size="sm" variant="ghost">
                  {length(@relay_health_recent_events)} recent
                </.ui_badge>
              </div>
            </div>

            <div class="divide-y divide-sr-line">
              <div
                :if={@relay_health_recent_events == []}
                class="px-5 py-10 text-center text-sm text-sr-muted"
              >
                No recent relay health signals.
              </div>

              <article :for={event <- @relay_health_recent_events} class="px-5 py-4">
                <div class="flex items-start justify-between gap-3">
                  <div class="min-w-0 space-y-1">
                    <div class="flex flex-wrap items-center gap-2">
                      <span class="font-medium text-sr-ink">{event.message}</span>
                      <.ui_badge size="sm" variant={event_badge_variant(event.relay_health_kind)}>
                        {entry_label(event.relay_health_kind)}
                      </.ui_badge>
                    </div>
                    <div class="text-sm text-sr-muted">
                      session={display_value(event.relay_session_id)} · gateway={display_value(
                        event.gateway_id
                      )}
                    </div>
                    <div class="text-xs text-sr-muted">
                      {display_value(event.log_name)} · reason={display_value(
                        event.reason || event.status_detail
                      )}
                    </div>
                  </div>

                  <div class="shrink-0 text-right text-xs text-sr-muted">
                    <div>
                      <.user_time
                        id={"camera-relay-event-#{event.id}-time"}
                        value={event.time}
                        timezone={@current_scope.user.timezone || "Etc/UTC"}
                        style={:compact}
                        fallback="n/a"
                      />
                    </div>
                    <div>{display_value(event.severity)}</div>
                  </div>
                </div>

                <div class="mt-3 flex flex-wrap gap-2">
                  <.ui_button navigate={~p"/events/#{event.id}"} size="xs" variant="ghost">
                    View event
                  </.ui_button>
                </div>
              </article>
            </div>
          </article>
        </section>

        <section class="rounded-2xl border border-sr-line bg-sr-surface shadow-sm">
          <div class="border-b border-sr-line px-5 py-4">
            <div class="flex items-center justify-between gap-3">
              <div>
                <h2 class="text-lg font-semibold text-sr-ink">Terminal Outcome Breakdown</h2>
                <p class="text-sm text-sr-muted">
                  Quick drill-down for the most common recent relay shutdown classes.
                </p>
              </div>
              <.ui_badge size="sm" variant="ghost">
                {length(@terminal_breakdown)} kinds
              </.ui_badge>
            </div>
          </div>

          <div class="flex flex-wrap gap-3 px-5 py-4">
            <div :if={@terminal_breakdown == []} class="text-sm text-sr-muted">
              No terminal relay outcomes yet.
            </div>

            <.link
              :for={entry <- @terminal_breakdown}
              patch={
                ~p"/observability/camera-relays?#{filter_params(@filters, %{terminal: entry.kind})}"
              }
              class="group rounded-xl border border-sr-line bg-base-50 px-4 py-3 transition hover:border-sr-brand/30 hover:bg-sr-brand/5"
            >
              <div class="text-xs uppercase tracking-wide text-sr-ink/45">
                {entry_label(entry.kind)}
              </div>
              <div class="mt-1 flex items-baseline gap-2">
                <span class="text-2xl font-semibold text-sr-ink">{entry.count}</span>
                <span class="text-xs text-sr-muted">recent sessions</span>
              </div>
            </.link>
          </div>
        </section>

        <div class="grid gap-6 xl:grid-cols-[minmax(0,1.4fr)_minmax(0,1fr)]">
          <section class="rounded-2xl border border-sr-line bg-sr-surface shadow-sm">
            <div class="border-b border-sr-line px-5 py-4">
              <div class="flex items-center justify-between gap-3">
                <div>
                  <h2 class="text-lg font-semibold text-sr-ink">Active Relay Sessions</h2>
                  <p class="text-sm text-sr-muted">
                    Requested, opening, active, and closing sessions across the deployment.
                  </p>
                </div>
                <.ui_badge size="sm" variant="ghost">
                  {length(@active_sessions)} sessions
                </.ui_badge>
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

            <div class="sr-ui-table-shell">
              <table class={ui_table_class(zebra: true)}>
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
                    <td colspan="7" class="py-10 text-center text-sm text-sr-muted">
                      No live relay sessions right now.
                    </td>
                  </tr>
                  <tr :for={session <- @active_sessions}>
                    <td>
                      <div class="space-y-1">
                        <div class="font-medium text-sr-ink">{camera_label(session)}</div>
                        <div class="text-xs text-sr-ink/55">
                          {profile_label(session)}
                        </div>
                        <div :if={device_uid(session)} class="text-xs">
                          <.link
                            navigate={~p"/devices/#{device_uid(session)}"}
                            class="text-sr-brand hover:underline text-sr-brand"
                          >
                            View device
                          </.link>
                        </div>
                      </div>
                    </td>
                    <td>
                      <.ui_badge size="sm" variant={status_badge_variant(session.status)}>
                        {format_status(session.status)}
                      </.ui_badge>
                    </td>
                    <td class="font-mono text-xs">{session.agent_id}</td>
                    <td class="font-mono text-xs">{session.gateway_id}</td>
                    <td>{Map.get(session, :viewer_count, 0)}</td>
                    <td>
                      <.session_log_links session={session} />
                    </td>
                    <td class="text-xs text-sr-muted">
                      <.user_time
                        id={"camera-relay-session-#{session.id}-updated-at"}
                        value={session.updated_at}
                        timezone={@current_scope.user.timezone || "Etc/UTC"}
                        style={:compact}
                        fallback="n/a"
                      />
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          </section>

          <section class="rounded-2xl border border-sr-line bg-sr-surface shadow-sm">
            <div class="border-b border-sr-line px-5 py-4">
              <div class="flex items-center justify-between gap-3">
                <div>
                  <h2 class="text-lg font-semibold text-sr-ink">Recent Terminal Sessions</h2>
                  <p class="text-sm text-sr-muted">
                    Most recent closed and failed relay sessions with normalized termination details.
                  </p>
                </div>
                <.ui_badge size="sm" variant="ghost">last 50</.ui_badge>
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

            <div class="divide-y divide-sr-line">
              <div
                :if={@terminal_sessions == []}
                class="px-5 py-10 text-center text-sm text-sr-muted"
              >
                No terminal relay sessions yet.
              </div>

              <article :for={session <- @terminal_sessions} class="px-5 py-4">
                <div class="flex items-start justify-between gap-3">
                  <div class="min-w-0 space-y-1">
                    <div class="flex flex-wrap items-center gap-2">
                      <span class="font-medium text-sr-ink">{camera_label(session)}</span>
                      <.ui_badge size="sm" variant={status_badge_variant(session.status)}>
                        {format_status(session.status)}
                      </.ui_badge>
                    </div>
                    <div class="text-sm text-sr-muted">{profile_label(session)}</div>
                    <div class="text-xs text-sr-muted">
                      termination={display_value(Map.get(session, :termination_kind))} · viewers={Map.get(
                        session,
                        :viewer_count,
                        0
                      )}
                    </div>
                  </div>
                  <div class="shrink-0 text-right text-xs text-sr-muted">
                    <div>
                      <.user_time
                        id={"camera-relay-session-#{session.id}-closed-at"}
                        value={session.closed_at || session.updated_at}
                        timezone={@current_scope.user.timezone || "Etc/UTC"}
                        style={:compact}
                        fallback="n/a"
                      />
                    </div>
                    <div class="font-mono">{session.gateway_id}</div>
                  </div>
                </div>

                <div class="mt-3 grid gap-2 text-xs text-sr-ink/65">
                  <div>
                    <span class="font-semibold text-sr-ink/75">Close reason:</span>
                    {display_value(Map.get(session, :close_reason))}
                  </div>
                  <div>
                    <span class="font-semibold text-sr-ink/75">Failure reason:</span>
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

        <div class="flex items-center gap-2 text-xs text-sr-ink/45">
          <span :if={is_struct(@refreshed_at, DateTime)} class="font-mono">
            Updated
            <.user_time
              id="camera-relay-refreshed-at"
              value={@refreshed_at}
              timezone={@current_scope.user.timezone || "Etc/UTC"}
              style={:time}
            />
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
          "block rounded-2xl border bg-sr-surface p-4 shadow-sm transition hover:shadow-md",
          tone_border(@tone)
        ]}
      >
        <div class="flex items-center justify-between gap-3">
          <div>
            <div class="text-xs uppercase tracking-wide text-sr-muted">{@title}</div>
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
      <div class={["rounded-2xl border bg-sr-surface p-4 shadow-sm", tone_border(@tone)]}>
        <div class="flex items-center justify-between gap-3">
          <div>
            <div class="text-xs uppercase tracking-wide text-sr-muted">{@title}</div>
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
    <.ui_button
      patch={~p"/observability/camera-relays?#{@params}"}
      size="xs"
      variant={if @active?, do: "primary", else: "ghost"}
      class="rounded-full"
    >
      {@label}
    </.ui_button>
    """
  end

  attr(:session, :map, required: true)

  defp session_log_links(assigns) do
    ~H"""
    <div class="flex flex-wrap gap-2">
      <.ui_button navigate={relay_logs_href(@session)} size="xs" variant="ghost">
        Relay Logs
      </.ui_button>
      <.ui_button
        :if={present?(Map.get(@session, :agent_id))}
        navigate={agent_logs_href(@session)}
        size="xs"
        variant="ghost"
      >
        Agent Logs
      </.ui_button>
      <.ui_button
        :if={present?(Map.get(@session, :gateway_id))}
        navigate={gateway_logs_href(@session)}
        size="xs"
        variant="ghost"
      >
        Gateway Logs
      </.ui_button>
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

  defp filter_linkable_devices(query, candidate_uids, _candidate_macs) when candidate_uids != [] do
    Ash.Query.filter(query, uid in ^candidate_uids)
  end

  defp filter_linkable_devices(query, _candidate_uids, candidate_macs) when candidate_macs != [] do
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
      opening_sessions: Enum.count(active_sessions, &(normalize_status(&1.status) in ["requested", "opening"])),
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
        DateTime.after?(
          lease_expires_at,
          DateTime.add(now, -@session_expiry_grace_seconds, :second)
        )

      _other ->
        recent_session_update?(session, now)
    end
  end

  defp recent_session_update?(session, now) do
    freshness_cutoff = DateTime.add(now, -@session_fallback_freshness_seconds, :second)

    session
    |> session_activity_timestamps()
    |> Enum.any?(&DateTime.after?(&1, freshness_cutoff))
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

  defp filter_terminal_sessions(sessions, "failed"), do: Enum.filter(sessions, &(normalize_status(&1.status) == "failed"))

  defp filter_terminal_sessions(sessions, "closed") do
    Enum.filter(sessions, &(normalize_status(&1.status) == "closed"))
  end

  defp filter_terminal_sessions(sessions, termination_kind) do
    Enum.filter(sessions, fn session ->
      Map.get(session, :termination_kind) == termination_kind
    end)
  end

  defp normalize_active_filter(value) when value in ["requested", "opening", "active", "closing"], do: value

  defp normalize_active_filter(_value), do: "all"

  defp normalize_terminal_filter(value)
       when value in ["failed", "viewer_idle", "manual_stop", "transport_drain", "source_complete", "closed"], do: value

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

  defp source_device_uid(%{device_uid: device_uid}) when is_binary(device_uid), do: String.trim(device_uid)

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

  defp status_badge_variant(status) do
    case normalize_status(status) do
      "active" -> "success"
      "requested" -> "warning"
      "opening" -> "warning"
      "closing" -> "warning"
      "closed" -> "ghost"
      "failed" -> "error"
      _ -> "ghost"
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

    "/observability/logs?" <> URI.encode_query(%{q: Enum.join(q, " ")})
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

  defp entry_label(value) when is_binary(value), do: value |> String.replace("_", " ") |> String.capitalize()

  defp entry_label(_value), do: "Unknown"

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false

  defp tone_border("error"), do: "border-error/25"
  defp tone_border("warning"), do: "border-warning/25"
  defp tone_border("success"), do: "border-success/25"
  defp tone_border("primary"), do: "border-sr-brand/25"
  defp tone_border(_tone), do: "border-sr-line"

  defp tone_bg("error"), do: "bg-error/10"
  defp tone_bg("warning"), do: "bg-warning/10"
  defp tone_bg("success"), do: "bg-success/10"
  defp tone_bg("primary"), do: "bg-sr-brand/10"
  defp tone_bg(_tone), do: "bg-sr-subtle"

  defp tone_icon("error"), do: "text-error"
  defp tone_icon("warning"), do: "text-warning"
  defp tone_icon("success"), do: "text-success"
  defp tone_icon("primary"), do: "text-sr-brand"
  defp tone_icon(_tone), do: "text-sr-ink"

  defp tone_value("error"), do: "text-error"
  defp tone_value("warning"), do: "text-warning"
  defp tone_value("success"), do: "text-success"
  defp tone_value("primary"), do: "text-sr-brand"
  defp tone_value(_tone), do: "text-sr-ink"

  defp alert_badge_variant("critical"), do: "error"
  defp alert_badge_variant("warning"), do: "warning"
  defp alert_badge_variant("info"), do: "info"
  defp alert_badge_variant(_severity), do: "ghost"

  defp event_badge_variant("session_failure"), do: "error"
  defp event_badge_variant("gateway_saturation_denial"), do: "warning"
  defp event_badge_variant("viewer_idle_termination"), do: "ghost"
  defp event_badge_variant(_kind), do: "ghost"

  defp relay_health_source do
    Application.get_env(
      :serviceradar_web_ng,
      :camera_relay_health_source,
      CameraRelayHealth
    )
  end
end
