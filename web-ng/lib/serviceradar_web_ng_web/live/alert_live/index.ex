defmodule ServiceRadarWebNGWeb.AlertLive.Index do
  use ServiceRadarWebNGWeb, :live_view

  import ServiceRadarWebNGWeb.UIComponents

  alias Phoenix.LiveView.JS
  alias ServiceRadarWebNGWeb.SRQL.Page, as: SRQLPage

  @default_limit 25
  @max_limit 200

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Alerts")
     |> assign(:alerts, [])
     |> assign(:summary, %{
       total: 0,
       pending: 0,
       acknowledged: 0,
       resolved: 0,
       escalated: 0,
       suppressed: 0
     })
     |> assign(:limit, @default_limit)
     |> SRQLPage.init("alerts", default_limit: @default_limit)}
  end

  @impl true
  def handle_params(params, uri, socket) do
    socket =
      socket
      |> SRQLPage.load_list(params, uri, :alerts,
        default_limit: @default_limit,
        max_limit: @max_limit
      )

    {:noreply, assign(socket, :summary, compute_summary(socket.assigns.alerts))}
  end

  @impl true
  def handle_event("srql_change", params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_change", params)}
  end

  def handle_event("srql_submit", params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_submit", params, fallback_path: "/alerts")}
  end

  def handle_event("srql_builder_toggle", _params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_toggle", %{}, entity: "alerts")}
  end

  def handle_event("srql_builder_change", params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_change", params)}
  end

  def handle_event("srql_builder_apply", _params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_apply", %{})}
  end

  def handle_event("srql_builder_run", _params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_run", %{}, fallback_path: "/alerts")}
  end

  def handle_event("srql_builder_add_filter", params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_add_filter", params, entity: "alerts")}
  end

  def handle_event("srql_builder_remove_filter", params, socket) do
    {:noreply,
     SRQLPage.handle_event(socket, "srql_builder_remove_filter", params, entity: "alerts")}
  end

  @impl true
  def render(assigns) do
    pagination = get_in(assigns, [:srql, :pagination]) || %{}
    assigns = assign(assigns, :pagination, pagination)

    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} srql={@srql}>
      <div class="mx-auto max-w-7xl p-6">
        <div class="space-y-4">
          <.alert_summary summary={@summary} />

          <.ui_panel>
            <:header>
              <div class="min-w-0">
                <div class="text-sm font-semibold">Alert Stream</div>
                <div class="text-xs text-base-content/70">
                  Click any alert to view full details.
                </div>
              </div>
            </:header>

            <.alerts_table id="alerts" alerts={@alerts} />

            <div class="mt-4 pt-4 border-t border-base-200">
              <.ui_pagination
                prev_cursor={Map.get(@pagination, "prev_cursor")}
                next_cursor={Map.get(@pagination, "next_cursor")}
                base_path="/alerts"
                query={Map.get(@srql, :query, "")}
                limit={@limit}
                result_count={length(@alerts)}
              />
            </div>
          </.ui_panel>
        </div>
      </div>
    </Layouts.app>
    """
  end

  attr :summary, :map, required: true

  defp alert_summary(assigns) do
    assigns =
      assigns
      |> assign(:total, assigns.summary.total)
      |> assign(:pending, assigns.summary.pending)
      |> assign(:acknowledged, assigns.summary.acknowledged)
      |> assign(:resolved, assigns.summary.resolved)
      |> assign(:escalated, assigns.summary.escalated)
      |> assign(:suppressed, assigns.summary.suppressed)

    ~H"""
    <div class="rounded-xl border border-base-200 bg-base-100 shadow-sm p-4">
      <div class="flex items-center justify-between mb-3">
        <div class="text-xs text-base-content/50 uppercase tracking-wider">
          Alert Status Overview
        </div>
        <div class="flex items-center gap-1">
          <.link patch={~p"/alerts"} class="btn btn-ghost btn-xs">All Alerts</.link>
          <.link
            patch={~p"/alerts?#{%{q: "in:alerts status:pending time:last_7d sort:timestamp:desc"}}"}
            class="btn btn-ghost btn-xs text-warning"
          >
            Pending
          </.link>
        </div>
      </div>
      <div class="grid grid-cols-2 sm:grid-cols-3 lg:grid-cols-6 gap-3">
        <.status_stat label="Pending" count={@pending} tone="warning" />
        <.status_stat label="Acked" count={@acknowledged} tone="info" />
        <.status_stat label="Resolved" count={@resolved} tone="success" />
        <.status_stat label="Escalated" count={@escalated} tone="error" />
        <.status_stat label="Suppressed" count={@suppressed} tone="neutral" />
        <.status_stat label="Total" count={@total} tone="ghost" />
      </div>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :count, :integer, required: true
  attr :tone, :string, required: true

  defp status_stat(assigns) do
    assigns = assign(assigns, :tone, tone_class(assigns.tone))

    ~H"""
    <div class="rounded-lg border border-base-200 bg-base-200/40 p-3">
      <div class="text-xs text-base-content/60">{@label}</div>
      <div class={["text-xl font-bold", @tone]}>{@count}</div>
    </div>
    """
  end

  defp tone_class("warning"), do: "text-warning"
  defp tone_class("info"), do: "text-info"
  defp tone_class("success"), do: "text-success"
  defp tone_class("error"), do: "text-error"
  defp tone_class(_), do: "text-base-content"

  attr :id, :string, required: true
  attr :alerts, :list, default: []

  defp alerts_table(assigns) do
    ~H"""
    <div class="overflow-x-auto">
      <table id={@id} class="table table-sm table-zebra w-full">
        <thead>
          <tr>
            <th class="whitespace-nowrap text-xs font-semibold text-base-content/70 bg-base-200/60 w-40">
              Time
            </th>
            <th class="whitespace-nowrap text-xs font-semibold text-base-content/70 bg-base-200/60 w-24">
              Severity
            </th>
            <th class="whitespace-nowrap text-xs font-semibold text-base-content/70 bg-base-200/60 w-28">
              Status
            </th>
            <th class="whitespace-nowrap text-xs font-semibold text-base-content/70 bg-base-200/60">
              Title
            </th>
          </tr>
        </thead>
        <tbody>
          <tr :if={@alerts == []}>
            <td colspan="4" class="text-sm text-base-content/60 py-8 text-center">
              No alerts found.
            </td>
          </tr>

          <%= for {alert, idx} <- Enum.with_index(@alerts) do %>
            <tr
              id={"#{@id}-row-#{idx}"}
              class="hover:bg-base-200/40 cursor-pointer transition-colors"
              phx-click={JS.navigate(~p"/alerts/#{alert_id(alert)}")}
            >
              <td class="whitespace-nowrap text-xs font-mono">{format_timestamp(alert)}</td>
              <td class="whitespace-nowrap text-xs">
                <.severity_badge value={Map.get(alert, "severity")} />
              </td>
              <td class="whitespace-nowrap text-xs">
                <.status_badge value={Map.get(alert, "status")} />
              </td>
              <td class="text-xs truncate max-w-[36rem]" title={alert_title(alert)}>
                {alert_title(alert)}
              </td>
            </tr>
          <% end %>
        </tbody>
      </table>
    </div>
    """
  end

  attr :value, :any, default: nil

  defp severity_badge(assigns) do
    variant = severity_variant(assigns.value)
    label = severity_label(assigns.value)

    assigns = assign(assigns, :variant, variant) |> assign(:label, label)

    ~H"""
    <.ui_badge variant={@variant} size="xs">{@label}</.ui_badge>
    """
  end

  defp severity_variant(value) do
    case normalize_severity(value) do
      s when s in ["emergency", "critical"] -> "error"
      s when s in ["warning"] -> "warning"
      s when s in ["info"] -> "info"
      _ -> "ghost"
    end
  end

  defp severity_label(nil), do: "—"
  defp severity_label(""), do: "—"
  defp severity_label(value) when is_binary(value), do: value
  defp severity_label(value), do: to_string(value)

  defp normalize_severity(nil), do: ""
  defp normalize_severity(v) when is_binary(v), do: v |> String.trim() |> String.downcase()
  defp normalize_severity(v), do: v |> to_string() |> normalize_severity()

  attr :value, :any, default: nil

  defp status_badge(assigns) do
    variant = status_variant(assigns.value)
    label = status_label(assigns.value)

    assigns = assign(assigns, :variant, variant) |> assign(:label, label)

    ~H"""
    <.ui_badge variant={@variant} size="xs">{@label}</.ui_badge>
    """
  end

  defp status_variant(value) do
    case normalize_status(value) do
      "pending" -> "warning"
      "acknowledged" -> "info"
      "resolved" -> "success"
      "escalated" -> "error"
      "suppressed" -> "ghost"
      _ -> "ghost"
    end
  end

  defp status_label(nil), do: "—"
  defp status_label(""), do: "—"
  defp status_label(value) when is_binary(value), do: String.capitalize(value)
  defp status_label(value), do: value |> to_string() |> String.capitalize()

  defp normalize_status(nil), do: ""
  defp normalize_status(v) when is_binary(v), do: String.downcase(v)
  defp normalize_status(v), do: v |> to_string() |> normalize_status()

  defp alert_id(alert) do
    Map.get(alert, "id") || Map.get(alert, "alert_id") || "unknown"
  end

  defp alert_title(alert) do
    Map.get(alert, "title") || Map.get(alert, "description") || "Alert"
  end

  defp format_timestamp(alert) do
    ts = Map.get(alert, "triggered_at") || Map.get(alert, "timestamp")

    case parse_timestamp(ts) do
      {:ok, dt} -> Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")
      _ -> ts || "—"
    end
  end

  defp parse_timestamp(nil), do: :error

  defp parse_timestamp(%DateTime{} = dt), do: {:ok, dt}

  defp parse_timestamp(ts) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _} -> {:ok, dt}
      _ -> :error
    end
  end

  defp parse_timestamp(_), do: :error

  defp compute_summary(alerts) when is_list(alerts) do
    Enum.reduce(alerts, %{total: 0, pending: 0, acknowledged: 0, resolved: 0, escalated: 0, suppressed: 0}, fn alert, acc ->
      status = normalize_status(Map.get(alert, "status"))

      acc
      |> Map.update!(:total, &(&1 + 1))
      |> increment_status(status)
    end)
  end

  defp compute_summary(_), do: %{total: 0, pending: 0, acknowledged: 0, resolved: 0, escalated: 0, suppressed: 0}

  defp increment_status(acc, "pending"), do: Map.update!(acc, :pending, &(&1 + 1))
  defp increment_status(acc, "acknowledged"), do: Map.update!(acc, :acknowledged, &(&1 + 1))
  defp increment_status(acc, "resolved"), do: Map.update!(acc, :resolved, &(&1 + 1))
  defp increment_status(acc, "escalated"), do: Map.update!(acc, :escalated, &(&1 + 1))
  defp increment_status(acc, "suppressed"), do: Map.update!(acc, :suppressed, &(&1 + 1))
  defp increment_status(acc, _), do: acc
end
