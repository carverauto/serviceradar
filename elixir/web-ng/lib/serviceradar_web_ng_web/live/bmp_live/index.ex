defmodule ServiceRadarWebNGWeb.BmpLive.Index do
  @moduledoc false
  use ServiceRadarWebNGWeb, :live_view

  import ServiceRadarWebNGWeb.UIComponents

  alias ServiceRadar.Observability.CausalPubSub
  alias ServiceRadarWebNGWeb.SRQL.Page, as: SRQLPage

  @default_limit 50
  @max_limit 200
  @refresh_debounce_ms 5_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(ServiceRadar.PubSub, CausalPubSub.topic())
    end

    {:ok,
     socket
     |> assign(:page_title, "BMP Events")
     |> assign(:bmp_events, [])
     |> assign(:limit, @default_limit)
     |> assign(:summary, empty_summary())
     |> assign(:bmp_live?, false)
     |> assign(:current_params, %{})
     |> stream(:bmp_events, [], dom_id: &bmp_event_dom_id/1)
     |> SRQLPage.init("bmp_events", default_limit: @default_limit)}
  end

  @impl true
  def handle_params(params, uri, socket) do
    live? = next_bmp_live_state(socket, params)

    socket = SRQLPage.load_list(socket, params, uri, :bmp_events, default_limit: @default_limit, max_limit: @max_limit)

    summary = compute_summary(socket.assigns.bmp_events)

    {:noreply,
     socket
     |> stream(:bmp_events, socket.assigns.bmp_events, reset: true, dom_id: &bmp_event_dom_id/1)
     |> assign(:summary, summary)
     |> assign(:bmp_live?, live?)
     |> assign(:current_params, params)}
  end

  # Live tailing survives only on the head of the same result set: a cursor
  # (or paged position) means the operator navigated, so the tail turns off.
  defp next_bmp_live_state(socket, params) do
    cond do
      has_cursor_param?(params) -> false
      Map.get(socket.assigns, :pagination_page, 1) > 1 -> false
      true -> Map.get(socket.assigns, :bmp_live?, false)
    end
  end

  defp has_cursor_param?(params) when is_map(params) do
    value = Map.get(params, "cursor")
    is_binary(value) and String.trim(value) != ""
  end

  defp has_cursor_param?(_), do: false

  @impl true
  def handle_event("srql_change", params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_change", params)}
  end

  def handle_event("srql_submit", params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_submit", params, fallback_path: "/observability/bmp")}
  end

  def handle_event("srql_reset", params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_reset", params, fallback_path: "/observability/bmp")}
  end

  def handle_event("srql_builder_toggle", _params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_toggle", %{}, entity: "bmp_events")}
  end

  def handle_event("srql_builder_change", params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_change", params)}
  end

  def handle_event("srql_builder_apply", _params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_apply", %{})}
  end

  def handle_event("srql_builder_run", _params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_run", %{}, fallback_path: "/observability/bmp")}
  end

  def handle_event("srql_builder_add_filter", params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_add_filter", params, entity: "bmp_events")}
  end

  def handle_event("srql_builder_remove_filter", params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_remove_filter", params, entity: "bmp_events")}
  end

  def handle_event("srql_paginate", params, socket) do
    socket =
      socket
      # Paging is session position — drop live tailing.
      |> assign(:bmp_live?, false)
      |> then(fn sock ->
        SRQLPage.handle_event(sock, "srql_paginate", params,
          list_assign_key: :bmp_events,
          default_limit: @default_limit,
          max_limit: @max_limit
        )
      end)

    summary = compute_summary(socket.assigns.bmp_events)

    {:noreply,
     socket
     |> stream(:bmp_events, socket.assigns.bmp_events, reset: true, dom_id: &bmp_event_dom_id/1)
     |> assign(:summary, summary)}
  end

  def handle_event("toggle_bmp_live", _params, socket) do
    socket = assign(socket, :bmp_live?, !Map.get(socket.assigns, :bmp_live?, false))

    {:noreply,
     if(Map.get(socket.assigns, :bmp_live?, false),
       do: refresh_bmp_head(socket),
       else: socket
     )}
  end

  @impl true
  def handle_info({:causal_signal_ingested, _event}, socket) do
    # Causal signal batches carry BMP routing rows, so an ingest pulse can
    # surface newly arrived BMP events — but only while live tailing is on.
    {:noreply, maybe_schedule_live_refresh(socket)}
  end

  @impl true
  def handle_info({:debounced_refresh}, socket) do
    socket = assign(socket, :_refresh_timer, nil)
    {:noreply, maybe_refresh_head(socket)}
  end

  defp maybe_schedule_live_refresh(socket) do
    if Map.get(socket.assigns, :bmp_live?, false) and
         is_nil(Map.get(socket.assigns, :_refresh_timer)) do
      timer = Process.send_after(self(), {:debounced_refresh}, @refresh_debounce_ms)
      assign(socket, :_refresh_timer, timer)
    else
      socket
    end
  end

  defp maybe_refresh_head(socket) do
    if Map.get(socket.assigns, :bmp_live?, false) do
      refresh_bmp_head(socket)
    else
      socket
    end
  end

  # Live refresh reuses the active query and drops cursor/page position so the
  # tail returns to the head of the result set.
  defp refresh_bmp_head(socket) do
    query = socket.assigns |> Map.get(:srql, %{}) |> Map.get(:query, "")

    params =
      socket.assigns
      |> Map.get(:current_params, %{})
      |> Map.put("q", query)
      |> Map.drop(["limit", "cursor", "page"])

    uri = socket.assigns |> Map.get(:srql, %{}) |> Map.get(:page_path, "/observability/bmp")

    socket =
      SRQLPage.load_list(socket, params, uri, :bmp_events,
        default_limit: @default_limit,
        max_limit: @max_limit
      )

    summary = compute_summary(socket.assigns.bmp_events)

    socket
    |> stream(:bmp_events, socket.assigns.bmp_events, reset: true, dom_id: &bmp_event_dom_id/1)
    |> assign(:summary, summary)
  end

  @impl true
  def render(assigns) do
    pagination = get_in(assigns, [:srql, :pagination]) || %{}
    assigns = assign(assigns, :pagination, pagination)

    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} srql={@srql}>
      <div class="sr-observability-page mx-auto max-w-7xl space-y-4 p-6 font-sans">
        <.observability_chrome active_pane="bmp" />

        <div class="flex flex-wrap items-end justify-between gap-3">
          <div class="min-w-0">
            <h1 class="font-sans text-xl font-semibold tracking-tight text-sr-ink">
              BMP Routing Events
            </h1>
            <p class="mt-0.5 text-sm text-sr-muted">
              Raw routing telemetry from <code class="font-mono text-[12px] text-sr-ink/80">platform.bmp_routing_events</code>.
            </p>
          </div>
          <.ui_button href={~p"/observability/events"} variant="outline" size="sm">
            Curated Events
          </.ui_button>
        </div>

        <.summary_cards summary={@summary} />

        <.ui_panel>
          <:header>
            <div class="min-w-0">
              <div class="text-sm font-semibold tracking-tight text-sr-ink">BMP Stream</div>
              <div class="text-xs leading-relaxed text-sr-muted">
                {if @bmp_live?,
                  do: "Streaming newest BMP routing updates.",
                  else: "Newest BMP routing events first."}
              </div>
            </div>
            <div class="flex flex-wrap items-center justify-end gap-2">
              <div class="text-xs text-sr-muted tabular-nums">
                {length(@bmp_events)} row{if length(@bmp_events) == 1, do: "", else: "s"}
              </div>
              <.live_toggle_button
                id="bmp-live-toggle"
                toggle_event="toggle_bmp_live"
                live?={@bmp_live?}
                start_title="Start live BMP streaming"
                pause_title="Pause live BMP streaming"
              />
            </div>
          </:header>

          <div class="sr-ui-table-shell">
            <table class={ui_table_class(size: "sm", zebra: true)}>
              <thead>
                <tr>
                  <th>Time</th>
                  <th>Type</th>
                  <th>Severity</th>
                  <th>Router</th>
                  <th>Peer</th>
                  <th>Prefix</th>
                  <th>Message</th>
                </tr>
              </thead>
              <tbody id="bmp-events" phx-update="stream">
                <tr :if={length(@bmp_events) == 0}>
                  <td colspan="7" class="text-center text-sr-muted py-8">
                    No BMP events found.
                  </td>
                </tr>
                <%= for {dom_id, event} <- @streams.bmp_events do %>
                  <tr id={dom_id}>
                    <td class="whitespace-nowrap text-xs">
                      <.bmp_event_time
                        id={"#{dom_id}-time"}
                        value={event["time"] || event[:time]}
                        timezone={@current_scope.user.timezone || "Etc/UTC"}
                      />
                    </td>
                    <td>
                      <.ui_badge size="sm" variant="ghost">
                        {event["event_type"] || event[:event_type] || "unknown"}
                      </.ui_badge>
                    </td>
                    <td>{event["severity_id"] || event[:severity_id] || "—"}</td>
                    <td>{event["router_ip"] || event[:router_ip] || "—"}</td>
                    <td>{event["peer_ip"] || event[:peer_ip] || "—"}</td>
                    <td>{event["prefix"] || event[:prefix] || "—"}</td>
                    <td class="max-w-xl truncate">{event["message"] || event[:message] || "—"}</td>
                  </tr>
                <% end %>
              </tbody>
            </table>
          </div>

          <div class="mt-4 pt-4 border-t border-sr-line">
            <.ui_pagination
              prev_cursor={Map.get(@pagination, "prev_cursor")}
              next_cursor={Map.get(@pagination, "next_cursor")}
              limit={@limit}
              current_page={Map.get(assigns, :pagination_page, 1)}
              result_count={length(@bmp_events)}
            />
          </div>
        </.ui_panel>
      </div>
    </Layouts.app>
    """
  end

  attr :id, :string, required: true
  attr :value, :any, required: true
  attr :timezone, :string, required: true

  def bmp_event_time(assigns) do
    ~H"""
    <.user_time
      id={@id}
      value={@value}
      timezone={@timezone}
      style={:compact}
      fallback="—"
    />
    """
  end

  # Live on/off toggle matching the observability logs live-feed pattern.
  attr(:id, :string, required: true)
  attr(:toggle_event, :string, required: true)
  attr(:live?, :boolean, default: false)
  attr(:start_title, :string, required: true)
  attr(:pause_title, :string, required: true)

  defp live_toggle_button(assigns) do
    assigns =
      assigns
      |> assign(:toggle_title, if(assigns.live?, do: assigns.pause_title, else: assigns.start_title))
      |> assign(:toggle_badge_variant, if(assigns.live?, do: "success", else: "ghost"))
      |> assign(:toggle_variant, if(assigns.live?, do: "primary", else: "outline"))
      # The badge id drops the button's "-toggle" suffix so `id="bmp-live-toggle"`
      # renders badge `id="bmp-live-status"`, matching the established convention.
      |> assign(:toggle_badge_id, String.replace_suffix(assigns.id, "-toggle", "-status"))

    ~H"""
    <.ui_button
      id={@id}
      phx-click={@toggle_event}
      variant={@toggle_variant}
      size="xs"
      active={@live?}
      class="rounded-full gap-2"
      title={@toggle_title}
    >
      <span class="text-xs font-medium">Live</span>
      <.ui_badge id={@toggle_badge_id} size="xs" variant={@toggle_badge_variant}>
        {if @live?, do: "On", else: "Off"}
      </.ui_badge>
    </.ui_button>
    """
  end

  attr :summary, :map, required: true

  defp summary_cards(assigns) do
    total = Map.get(assigns.summary, :total, 0)

    cards = [
      %{
        title: "Total",
        value: total,
        tone: "neutral",
        icon: "hero-queue-list",
        query: "in:bmp_events time:last_24h sort:time:desc"
      },
      %{
        title: "Updates",
        value: Map.get(assigns.summary, :route_update, 0),
        tone: "info",
        icon: "hero-arrow-path",
        query: "in:bmp_events event_type:route_update time:last_24h sort:time:desc"
      },
      %{
        title: "Withdraws",
        value: Map.get(assigns.summary, :route_withdraw, 0),
        tone: "warning",
        icon: "hero-minus-circle",
        query: "in:bmp_events event_type:route_withdraw time:last_24h sort:time:desc"
      },
      %{
        title: "Peer Up",
        value: Map.get(assigns.summary, :peer_up, 0),
        tone: "success",
        icon: "hero-signal",
        query: "in:bmp_events event_type:peer_up time:last_24h sort:time:desc"
      },
      %{
        title: "Peer Down",
        value: Map.get(assigns.summary, :peer_down, 0),
        tone: "error",
        icon: "hero-signal-slash",
        query: "in:bmp_events event_type:peer_down time:last_24h sort:time:desc"
      },
      %{
        title: "High+",
        value: Map.get(assigns.summary, :high_or_higher, 0),
        tone: "critical",
        icon: "hero-exclamation-triangle",
        query: "in:bmp_events severity_id:>=4 time:last_24h sort:time:desc"
      }
    ]

    assigns =
      assigns
      |> assign(:total, total)
      |> assign(:cards, cards)

    ~H"""
    <div class="grid grid-cols-2 gap-2.5 sm:grid-cols-3 lg:grid-cols-6">
      <.summary_card
        :for={card <- @cards}
        title={card.title}
        value={card.value}
        total={@total}
        tone={card.tone}
        icon={card.icon}
        query={card.query}
      />
    </div>
    """
  end

  attr :title, :string, required: true
  attr :value, :integer, required: true
  attr :total, :integer, required: true
  attr :tone, :string, required: true
  attr :icon, :string, required: true
  attr :query, :string, required: true

  defp summary_card(assigns) do
    pct =
      cond do
        assigns.title == "Total" -> 100
        assigns.total > 0 -> min(100, round(assigns.value / assigns.total * 100))
        true -> 0
      end

    assigns = assign(assigns, :pct, pct)

    ~H"""
    <.link
      patch={~p"/observability/bmp?#{%{q: @query}}"}
      class={[
        "group relative min-w-0 overflow-hidden rounded-sr-surface border border-sr-line bg-sr-surface p-3.5 shadow-sr-surface transition-[transform,box-shadow,border-color,background-color] duration-200 ease-sr-out",
        "hover:-translate-y-px hover:border-sr-line-strong hover:shadow-sr-raised",
        "focus:outline-none focus-visible:ring-2 focus-visible:ring-sr-focus focus-visible:ring-offset-2 focus-visible:ring-offset-sr-canvas",
        summary_tone_ring(@tone)
      ]}
    >
      <div class="flex items-start justify-between gap-2">
        <div class="min-w-0">
          <div class="truncate text-[11px] font-semibold uppercase tracking-wider text-sr-muted">
            {@title}
          </div>
          <div class="mt-1.5 font-sans text-2xl font-semibold tracking-tight tabular-nums text-sr-ink group-hover:text-sr-brand">
            {format_stat(@value)}
          </div>
        </div>
        <span class={[
          "inline-flex size-8 shrink-0 items-center justify-center rounded-sr-control border",
          summary_icon_class(@tone)
        ]}>
          <.icon name={@icon} class="size-4" />
        </span>
      </div>

      <div class="mt-3 flex items-center justify-between gap-2">
        <div class="h-1 min-w-0 flex-1 overflow-hidden rounded-full bg-sr-control/80">
          <div
            class={["h-full rounded-full transition-[width] duration-300", summary_bar_class(@tone)]}
            style={"width: #{@pct}%"}
          >
          </div>
        </div>
        <span class="shrink-0 font-mono text-[10px] tabular-nums text-sr-muted">
          {if @title == "Total", do: "page", else: "#{@pct}%"}
        </span>
      </div>
    </.link>
    """
  end

  # Explicit brand tones — daisy info/warning/error colors no longer resolve.
  defp summary_tone_ring("info"), do: "hover:border-sky-500/35"
  defp summary_tone_ring("warning"), do: "hover:border-amber-400/40"
  defp summary_tone_ring("success"), do: "hover:border-emerald-500/35"
  defp summary_tone_ring("error"), do: "hover:border-rose-500/40"
  defp summary_tone_ring("critical"), do: "hover:border-rose-500/45"
  defp summary_tone_ring(_), do: "hover:border-sr-brand/30"

  defp summary_icon_class("info"), do: "border-sky-500/25 bg-sky-500/10 text-sky-400"
  defp summary_icon_class("warning"), do: "border-amber-400/30 bg-amber-400/10 text-amber-400"
  defp summary_icon_class("success"), do: "border-emerald-500/25 bg-emerald-500/10 text-emerald-400"
  defp summary_icon_class("error"), do: "border-rose-500/30 bg-rose-500/10 text-rose-400"
  defp summary_icon_class("critical"), do: "border-rose-500/35 bg-rose-500/12 text-rose-300"
  defp summary_icon_class(_), do: "border-sr-line bg-sr-subtle text-sr-muted"

  defp summary_bar_class("info"), do: "bg-sky-400"
  defp summary_bar_class("warning"), do: "bg-amber-400"
  defp summary_bar_class("success"), do: "bg-emerald-400"
  defp summary_bar_class("error"), do: "bg-rose-400"
  defp summary_bar_class("critical"), do: "bg-rose-500"
  defp summary_bar_class(_), do: "bg-sr-brand"

  defp format_stat(n) when is_integer(n) and n >= 1_000_000, do: "#{Float.round(n / 1_000_000 * 1.0, 1)}M"
  defp format_stat(n) when is_integer(n) and n >= 1_000, do: "#{Float.round(n / 1_000 * 1.0, 1)}k"
  defp format_stat(n) when is_integer(n), do: Integer.to_string(n)
  defp format_stat(_), do: "0"

  defp compute_summary(events) when is_list(events) do
    Enum.reduce(events, empty_summary(), fn event, acc ->
      event_type = to_string(event["event_type"] || event[:event_type] || "")
      severity = parse_int(event["severity_id"] || event[:severity_id])

      acc
      |> Map.update!(:total, &(&1 + 1))
      |> bump_type(event_type)
      |> bump_high_severity(severity)
    end)
  end

  defp compute_summary(_), do: empty_summary()

  defp bump_type(acc, "route_update"), do: Map.update!(acc, :route_update, &(&1 + 1))
  defp bump_type(acc, "route_withdraw"), do: Map.update!(acc, :route_withdraw, &(&1 + 1))
  defp bump_type(acc, "peer_up"), do: Map.update!(acc, :peer_up, &(&1 + 1))
  defp bump_type(acc, "peer_down"), do: Map.update!(acc, :peer_down, &(&1 + 1))
  defp bump_type(acc, _), do: acc

  defp bump_high_severity(acc, severity) when is_integer(severity) and severity >= 4,
    do: Map.update!(acc, :high_or_higher, &(&1 + 1))

  defp bump_high_severity(acc, _), do: acc

  defp parse_int(value) when is_integer(value), do: value

  defp parse_int(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} -> parsed
      _ -> nil
    end
  end

  defp parse_int(_), do: nil

  defp empty_summary do
    %{
      total: 0,
      route_update: 0,
      route_withdraw: 0,
      peer_up: 0,
      peer_down: 0,
      high_or_higher: 0
    }
  end

  defp bmp_event_dom_id(event) do
    id = event["id"] || event[:id] || System.unique_integer([:positive])
    "bmp-event-#{id}"
  end
end
