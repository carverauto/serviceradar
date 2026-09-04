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
     |> assign(:source_filter, nil)
     |> assign(:load_error, nil)
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
      {:noreply,
       push_patch(socket, to: ThreatIntelLinks.investigation_path(ip: ip, source: socket.assigns.source_filter))}
    else
      {:noreply, put_flash(socket, :error, "Not authorized")}
    end
  end

  def handle_event("retry", _params, socket) do
    if RBAC.can?(socket.assigns.current_scope, @permission) do
      {:noreply,
       load_page(socket, %{
         "ip" => socket.assigns.selected_ip,
         "source" => socket.assigns.source_filter
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
          <div>
            <p class="text-sm font-medium text-error">Security</p>
            <h1 class="text-2xl font-semibold text-base-content">Threat Intel</h1>
            <p class="mt-1 max-w-2xl text-sm text-base-content/70">
              Current cache matches are live endpoint-to-indicator memberships, not flow counts
              and not imported inventory. Historical retrohunt evidence stays on settings.
            </p>
          </div>
          <div class="flex flex-wrap gap-2">
            <.link navigate={~p"/security"} class="btn btn-sm btn-ghost">Security overview</.link>
            <.link href={ThreatIntelLinks.settings_path()} class="btn btn-sm btn-outline">
              Manage feeds
            </.link>
          </div>
        </div>

        <div :if={@load_error} class="alert alert-error" data-testid="threat-intel-error">
          <span>{@load_error}</span>
          <button type="button" class="btn btn-sm" phx-click="retry">Retry</button>
        </div>

        <div class="grid gap-6 lg:grid-cols-[minmax(0,1.1fr)_minmax(0,0.9fr)]">
          <section class="card bg-base-100 shadow-sm border border-base-300">
            <div class="card-body p-0">
              <div class="flex items-center justify-between border-b border-base-300 px-4 py-3">
                <h2 class="card-title text-base">Current matches</h2>
                <span class="text-xs text-base-content/60">{length(@matches)} endpoints</span>
              </div>
              <div :if={@loading} class="p-4 text-sm text-base-content/60">Loading matches…</div>
              <div
                :if={not @loading and @matches == [] and is_nil(@load_error)}
                class="p-4 text-sm text-base-content/60"
                data-testid="threat-intel-empty"
              >
                No current NetFlow IOC matches.
              </div>
              <table :if={@matches != []} class="table table-sm">
                <thead>
                  <tr>
                    <th>Observed IP</th>
                    <th>Indicator matches</th>
                    <th>Max sev</th>
                    <th>Evaluated</th>
                  </tr>
                </thead>
                <tbody>
                  <tr
                    :for={match <- @matches}
                    class={[@selected_ip == match.observed_ip && "bg-base-200", "cursor-pointer"]}
                    phx-click="select_ip"
                    phx-value-ip={match.observed_ip}
                    data-testid={"threat-intel-row-#{match.observed_ip}"}
                  >
                    <td class="font-mono">{match.observed_ip}</td>
                    <td>{match.indicator_match_count}</td>
                    <td>{match.max_severity || "—"}</td>
                    <td>
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
          </section>

          <section class="card bg-base-100 shadow-sm border border-base-300">
            <div class="card-body">
              <h2 class="card-title text-base">Match detail</h2>
              <p :if={!@selected_ip} class="text-sm text-base-content/60">
                Select an endpoint to resolve the overlapping indicators.
              </p>
              <div :if={@selected_ip} class="space-y-3">
                <p class="font-mono text-sm">{@selected_ip}</p>
                <div class="flex flex-wrap gap-2">
                  <.link
                    href={ThreatIntelLinks.device_path(@selected_ip)}
                    class="btn btn-xs btn-ghost"
                  >
                    Inventory
                  </.link>
                  <.link
                    href={flow_pivot(@selected_ip)}
                    class="btn btn-xs btn-ghost"
                  >
                    View flows
                  </.link>
                  <.link
                    href={attributed_flow_pivot(@selected_ip)}
                    class="btn btn-xs btn-ghost"
                  >
                    View attributed flows
                  </.link>
                </div>
                <ul class="space-y-2">
                  <li :if={@indicators == []} class="text-sm text-base-content/60">
                    Provider context not available for this endpoint, or no active indicator still contains it.
                  </li>
                  <li :for={indicator <- @indicators} class="rounded-box border border-base-300 p-3">
                    <div class="font-medium">{indicator.label || indicator.indicator}</div>
                    <div class="text-xs text-base-content/60">
                      {indicator.source} · {indicator.indicator} · sev {indicator.severity || "—"}
                    </div>
                  </li>
                </ul>
              </div>
            </div>
          </section>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp load_page(socket, params) do
    scope = socket.assigns.current_scope
    selected_ip = blank_to_nil(params["ip"] || params[:ip])
    source = blank_to_nil(params["source"] || params[:source])

    case ThreatIntelInvestigation.list_current_matches(scope, source: source) do
      {:ok, matches} ->
        socket =
          socket
          |> assign(:matches, matches)
          |> assign(:selected_ip, selected_ip)
          |> assign(:source_filter, source)
          |> assign(:load_error, nil)
          |> assign(:loading, false)

        load_indicators(socket, selected_ip)

      {:error, reason} ->
        socket
        |> assign(:matches, [])
        |> assign(:indicators, [])
        |> assign(:load_error, load_error_message(:matches, reason))
        |> assign(:loading, false)
    end
  end

  defp load_indicators(socket, nil), do: assign(socket, :indicators, [])

  defp load_indicators(socket, ip) do
    case ThreatIntelInvestigation.indicators_for_ip(socket.assigns.current_scope, ip) do
      {:ok, indicators} -> assign(socket, :indicators, indicators)
      {:error, reason} -> assign(socket, :load_error, load_error_message(:indicators, reason))
    end
  end

  defp load_error_message(_kind, :invalid_ip), do: "The selected IP address is not valid."

  defp load_error_message(kind, reason) do
    Logger.warning("threat intel investigation #{kind} failed: #{inspect(reason)}")

    case kind do
      :matches -> "Failed to load current matches."
      :indicators -> "Failed to load indicators."
    end
  end

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(_), do: nil

  defp flow_pivot(ip) do
    "/observability/netflows?" <>
      URI.encode_query(%{
        "view" => "explorer",
        "q" => ~s(in:flows threat_observed_ip:#{ip} time:last_24h sort:time:desc)
      })
  end

  defp attributed_flow_pivot(ip) do
    "/observability/flows/attributed?" <>
      URI.encode_query(%{
        "q" => ~s(in:attributed_flows threat_observed_ip:#{ip} time:last_24h sort:time:desc)
      })
  end

  defp dom_id(ip), do: ip |> to_string() |> String.replace(~r/[^A-Za-z0-9]/, "-")
end
