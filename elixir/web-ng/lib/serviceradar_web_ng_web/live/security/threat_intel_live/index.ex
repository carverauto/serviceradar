defmodule ServiceRadarWebNGWeb.Security.ThreatIntelLive.Index do
  @moduledoc """
  Operator investigation for current IP/CIDR threat-intel matches.
  """

  use ServiceRadarWebNGWeb, :live_view

  alias ServiceRadar.Observability.ThreatIntelInvestigation
  alias ServiceRadarWebNGWeb.Observability.ThreatIntelLinks

  require Logger

  @permission "observability.netflow.view"

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Threat Intel")
     |> assign(:matches, [])
     |> assign(:indicators, [])
     |> assign(:selected_ip, nil)
     |> assign(:selected_match, nil)
     |> assign(:source_filter, nil)
     |> assign(:show_stale, false)
     |> assign(:matches_error, nil)
     |> assign(:indicator_error, nil)
     |> assign(:indicator_state, :idle)
     |> assign(:loading, true)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    scope = socket.assigns.current_scope

    cond do
      not RBAC.can?(scope, @permission) ->
        {:noreply,
         socket
         |> put_flash(:error, "Not authorized to view threat intelligence matches")
         |> push_navigate(to: ~p"/dashboard")}

      not connected?(socket) ->
        {:noreply, assign(socket, :loading, true)}

      true ->
        {:noreply, load_page(socket, params)}
    end
  end

  @impl true
  def handle_event("select_ip", %{"ip" => ip}, socket) do
    if RBAC.can?(socket.assigns.current_scope, @permission) do
      {:noreply, push_patch(socket, to: investigation_path(socket, ip))}
    else
      {:noreply, put_flash(socket, :error, "Not authorized")}
    end
  end

  def handle_event("retry", _params, socket) do
    if RBAC.can?(socket.assigns.current_scope, @permission) do
      {:noreply,
       load_page(socket, %{
         "ip" => socket.assigns.selected_ip,
         "source" => socket.assigns.source_filter,
         "stale" => if(socket.assigns.show_stale, do: "true")
       })}
    else
      {:noreply, put_flash(socket, :error, "Not authorized")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_path="/security/threat-intel"
      page_title={@page_title}
    >
      <div class="mx-auto w-full max-w-7xl space-y-6 p-4 sm:p-6">
        <div class="flex flex-wrap items-end justify-between gap-3">
          <div class="min-w-0">
            <p class="text-sm font-medium text-sr-brand">Security</p>
            <h1 class="text-2xl font-semibold text-sr-ink">Threat Intel</h1>
            <p class="mt-1 max-w-2xl text-sm text-sr-muted">
              Current cache matches are live endpoint-to-indicator memberships, not flow counts
              and not imported inventory. Historical retrohunt evidence stays on settings.
            </p>
          </div>
          <div class="flex flex-wrap gap-2">
            <.ui_button navigate={~p"/security"} variant="ghost" size="sm">
              Security overview
            </.ui_button>
            <.ui_button href={ThreatIntelLinks.settings_path()} variant="outline" size="sm">
              Manage feeds
            </.ui_button>
          </div>
        </div>

        <.ui_alert
          :if={@matches_error}
          variant="error"
          id="threat-intel-matches-error"
          data-testid="threat-intel-error"
        >
          <div class="flex flex-wrap items-center justify-between gap-3">
            <span>{@matches_error}</span>
            <.ui_button
              type="button"
              phx-click="retry"
              variant="outline"
              size="sm"
              id="threat-intel-matches-retry"
            >
              Retry
            </.ui_button>
          </div>
        </.ui_alert>

        <div class="grid gap-6 lg:grid-cols-[minmax(0,1.1fr)_minmax(0,0.9fr)]">
          <.ui_panel id="threat-intel-matches">
            <:header>
              <div class="min-w-0">
                <h2 class="text-base font-semibold text-sr-ink">Current matches</h2>
                <p class="text-xs text-sr-muted">{length(@matches)} endpoints</p>
              </div>
              <.ui_button
                href={stale_toggle_path(assigns)}
                variant="ghost"
                size="sm"
                id="threat-intel-stale-toggle"
              >
                {if @show_stale, do: "Hide stale", else: "Show stale"}
              </.ui_button>
            </:header>
            <div :if={@loading} class="p-4 text-sm text-sr-muted">Loading matches…</div>
            <div
              :if={not @loading and @matches == [] and is_nil(@matches_error)}
              class="p-4 text-sm text-sr-muted"
              data-testid="threat-intel-empty"
            >
              No current NetFlow IOC matches.
            </div>
            <div :if={@matches != []} class="overflow-x-auto">
              <table class="w-full min-w-[36rem] text-left text-sm">
                <thead class="border-b border-sr-line text-xs uppercase tracking-wide text-sr-muted">
                  <tr>
                    <th class="px-4 py-2 font-medium">Observed IP</th>
                    <th class="px-4 py-2 font-medium">Indicator matches</th>
                    <th class="px-4 py-2 font-medium">Max sev</th>
                    <th class="px-4 py-2 font-medium">Evaluated</th>
                  </tr>
                </thead>
                <tbody>
                  <tr
                    :for={match <- @matches}
                    class={[
                      "cursor-pointer border-b border-sr-line last:border-b-0 hover:bg-sr-subtle",
                      @selected_ip == match.observed_ip && "bg-sr-subtle"
                    ]}
                    phx-click="select_ip"
                    phx-value-ip={match.observed_ip}
                    data-testid={"threat-intel-row-#{match.observed_ip}"}
                  >
                    <td class="px-4 py-3 font-mono text-sr-ink">
                      <span class="break-all">{match.observed_ip}</span>
                      <span
                        :if={match.stale}
                        class="ml-2 inline-flex rounded-sr-control border border-amber-500/40 px-1.5 py-0.5 text-[10px] font-semibold uppercase tracking-wide text-amber-800 dark:text-amber-200"
                      >
                        Stale
                      </span>
                    </td>
                    <td class="px-4 py-3 text-sr-ink">{match.indicator_match_count}</td>
                    <td class="px-4 py-3 text-sr-ink">{match.max_severity || "—"}</td>
                    <td class="px-4 py-3 text-sr-muted">
                      <.user_time
                        :if={match.evaluated_at}
                        id={"threat-intel-evaluated-#{dom_id(match.observed_ip)}"}
                        value={match.evaluated_at}
                        timezone="Etc/UTC"
                        style={:compact}
                      />
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          </.ui_panel>

          <.ui_panel id="threat-intel-detail">
            <:header>
              <h2 class="text-base font-semibold text-sr-ink">Match detail</h2>
            </:header>
            <p :if={!@selected_ip} class="text-sm text-sr-muted">
              Select an endpoint to resolve the overlapping indicators.
            </p>
            <div :if={@selected_ip} class="space-y-3">
              <p class="break-all font-mono text-sm text-sr-ink">{@selected_ip}</p>
              <p
                :if={@selected_match && @selected_match.stale}
                class="text-sm text-amber-800 dark:text-amber-200"
              >
                Stale cache row. It is past its expiry and is hidden from the default list.
              </p>
              <.ui_alert
                :if={@indicator_error}
                variant="error"
                id="threat-intel-indicator-error"
                data-testid="threat-intel-indicator-error"
              >
                <div class="flex flex-wrap items-center justify-between gap-3">
                  <span>{@indicator_error}</span>
                  <.ui_button
                    type="button"
                    phx-click="retry"
                    variant="outline"
                    size="sm"
                    id="threat-intel-indicator-retry"
                  >
                    Retry
                  </.ui_button>
                </div>
              </.ui_alert>
              <div :if={@indicator_state in [:ready, :missing]} class="flex flex-wrap gap-2">
                <.ui_button
                  id="threat-intel-inventory-link"
                  href={ThreatIntelLinks.device_path(@selected_ip)}
                  variant="ghost"
                  size="xs"
                >
                  Inventory
                </.ui_button>
                <.ui_button
                  id="threat-intel-flow-link"
                  href={ThreatIntelLinks.flow_path(@selected_ip)}
                  variant="ghost"
                  size="xs"
                >
                  View flows
                </.ui_button>
                <.ui_button
                  id="threat-intel-attributed-flow-link"
                  href={ThreatIntelLinks.attributed_flow_path(@selected_ip)}
                  variant="ghost"
                  size="xs"
                >
                  View attributed flows
                </.ui_button>
              </div>
              <p
                :if={@indicator_state == :missing}
                class="text-sm text-sr-muted"
                data-testid="threat-intel-detail-notice"
              >
                {detail_notice(@selected_match)}
              </p>
              <ul :if={@indicator_state == :ready} class="space-y-2">
                <li
                  :for={indicator <- @indicators}
                  class="rounded-sr-surface border border-sr-line p-3"
                  data-testid="threat-intel-indicator"
                >
                  <div class="font-medium text-sr-ink">{indicator.label || indicator.indicator}</div>
                  <div class="break-all text-xs text-sr-muted">
                    {indicator.source} · {indicator.indicator} · sev {indicator.severity || "—"}
                  </div>
                </li>
              </ul>
              <p
                :if={@indicator_state == :ready}
                class="text-sm text-sr-muted"
                data-testid="threat-intel-provider-context"
              >
                Provider context not available.
              </p>
            </div>
          </.ui_panel>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp load_page(socket, params) do
    scope = socket.assigns.current_scope
    selected_ip = blank_to_nil(params["ip"] || params[:ip])
    source = blank_to_nil(params["source"] || params[:source])
    show_stale = truthy?(params["stale"] || params[:stale])

    case ThreatIntelInvestigation.list_current_matches(scope, source: source, stale: show_stale) do
      {:ok, matches} ->
        socket
        |> assign(:matches, matches)
        |> assign(:selected_ip, selected_ip)
        |> assign(:selected_match, Enum.find(matches, &(&1.observed_ip == selected_ip)))
        |> assign(:source_filter, source)
        |> assign(:show_stale, show_stale)
        |> assign(:matches_error, nil)
        |> assign(:loading, false)
        |> load_indicators(selected_ip)

      {:error, reason} ->
        socket
        |> assign(:matches, [])
        |> assign(:indicators, [])
        |> assign(:selected_ip, selected_ip)
        |> assign(:selected_match, nil)
        |> assign(:source_filter, source)
        |> assign(:show_stale, show_stale)
        |> assign(:matches_error, load_error_message(:matches, reason))
        |> assign(:indicator_error, nil)
        |> assign(:indicator_state, :idle)
        |> assign(:loading, false)
    end
  end

  defp load_indicators(socket, nil) do
    socket
    |> assign(:indicators, [])
    |> assign(:indicator_error, nil)
    |> assign(:indicator_state, :idle)
  end

  defp load_indicators(socket, ip) do
    case ThreatIntelInvestigation.indicators_for_ip(socket.assigns.current_scope, ip) do
      {:ok, indicators} ->
        socket
        |> assign(:indicators, indicators)
        |> assign(:indicator_error, nil)
        |> assign(:indicator_state, if(indicators == [], do: :missing, else: :ready))

      {:error, :invalid_ip} ->
        socket
        |> assign(:indicators, [])
        |> assign(:indicator_error, "The selected IP address is not valid.")
        |> assign(:indicator_state, :invalid)

      {:error, reason} ->
        socket
        |> assign(:indicators, [])
        |> assign(:indicator_error, load_error_message(:indicators, reason))
        |> assign(:indicator_state, :error)
    end
  end

  defp load_error_message(kind, reason) do
    Logger.warning("threat intel investigation #{kind} failed: #{inspect(reason)}")

    cond do
      timeout?(reason) and kind == :matches -> "The current-match query timed out."
      timeout?(reason) and kind == :indicators -> "The indicator query timed out."
      kind == :matches -> "Failed to load current matches."
      kind == :indicators -> "Failed to load indicators."
    end
  end

  defp timeout?(%{postgres: %{code: :query_canceled}}), do: true
  defp timeout?(%DBConnection.ConnectionError{reason: reason}) when reason in [:timeout, :queue_timeout], do: true
  defp timeout?(%{errors: errors}) when is_list(errors), do: Enum.any?(errors, &timeout?/1)
  defp timeout?(%{error: error}) when not is_nil(error), do: timeout?(error)
  defp timeout?(_reason), do: false

  defp detail_notice(%{stale: true}), do: "This cache row is stale, and no active indicator still contains this endpoint."

  defp detail_notice(%{}), do: "No active indicator still contains this endpoint."

  defp detail_notice(_match), do: "This endpoint is not a current match, and no active indicator contains it."

  defp investigation_path(socket, ip) do
    params = [ip: ip, source: socket.assigns.source_filter]
    params = if socket.assigns.show_stale, do: Keyword.put(params, :stale, true), else: params
    ThreatIntelLinks.investigation_path(params)
  end

  defp stale_toggle_path(assigns) do
    params = [ip: assigns.selected_ip, source: assigns.source_filter]

    params =
      if assigns.show_stale do
        params
      else
        Keyword.put(params, :stale, true)
      end

    ThreatIntelLinks.investigation_path(params)
  end

  defp truthy?(value) when value in [true, "true", "1"], do: true
  defp truthy?(_value), do: false

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(_), do: nil

  defp dom_id(ip), do: ip |> to_string() |> String.replace(~r/[^A-Za-z0-9]/, "-")
end
