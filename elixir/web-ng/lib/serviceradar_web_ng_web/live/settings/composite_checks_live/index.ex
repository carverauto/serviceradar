defmodule ServiceRadarWebNGWeb.Settings.CompositeChecksLive.Index do
  @moduledoc """
  LiveView for authoring composite service checks.

  A composite check derives one verdict per device from signals other subsystems
  already produce — per-agent reachability and device metadata facts. It never
  probes, so the sweeps that feed it are authored in Networks and shown here as
  read-only context.

  Sited under Networks beside Availability Sources and Visibility Profiles: all
  three scope a device population with SRQL and select agents, and composite
  checks consume exactly what the sweeps configured there produce.
  """

  use ServiceRadarWebNGWeb, :live_view

  alias ServiceRadar.CompositeChecks.CompositeCheck
  alias ServiceRadarWebNG.RBAC
  alias ServiceRadarWebNGWeb.Settings.Shell

  require Ash.Query

  @current_path "/settings/networks/composite-checks"
  @view_permission "composite_checks.view"
  @manage_permission "composite_checks.manage"
  @evaluate_permission "composite_checks.evaluate"

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    if RBAC.can?(scope, @view_permission) do
      {:ok,
       socket
       |> assign(:page_title, "Composite Checks")
       |> assign(:current_path, @current_path)
       |> assign(:can_manage, RBAC.can?(scope, @manage_permission))
       |> assign(:can_evaluate, RBAC.can?(scope, @evaluate_permission))
       |> assign(:checks, list_checks(socket))}
    else
      {:ok,
       socket
       |> put_flash(:error, "You do not have access to Composite Checks")
       |> push_navigate(to: ~p"/settings/profile")}
    end
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    assign(socket, :page_title, "Composite Checks")
  end

  defp apply_action(socket, :new, _params) do
    if socket.assigns.can_manage do
      assign(socket, :page_title, "New Composite Check")
    else
      forbid(socket)
    end
  end

  defp apply_action(socket, :edit, _params) do
    if socket.assigns.can_manage do
      assign(socket, :page_title, "Edit Composite Check")
    else
      forbid(socket)
    end
  end

  defp forbid(socket) do
    socket
    |> put_flash(:error, "You do not have permission to manage composite checks")
    |> push_patch(to: @current_path)
  end

  # Reads run in mount, which LiveView calls twice — once disconnected for the
  # static render and again on connect. Loading a bounded settings list in both
  # is what the sibling settings views do; anything expensive belongs behind
  # `connected?/1`.
  defp list_checks(socket) do
    CompositeCheck
    |> Ash.Query.for_read(:read, %{}, scope: socket.assigns.current_scope)
    |> Ash.Query.sort(name: :asc)
    |> Ash.read()
    |> case do
      {:ok, checks} -> checks
      {:error, _reason} -> []
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <Shell.settings_chrome
        current_path={@current_path}
        current_scope={@current_scope}
        active_view={@settings_active_view}
        active_category={@settings_active_category}
        breadcrumbs={@settings_breadcrumbs}
        nav_tree={@settings_nav_tree}
        palette={@settings_palette}
        stats={@settings_stats}
      >
        <div class="space-y-6">
          <header class="flex items-start justify-between gap-4">
            <div>
              <h1 class="text-xl font-semibold text-sr-ink">Composite Checks</h1>
              <p class="mt-1 max-w-2xl text-sm text-sr-ink-muted">
                Prove a device is isolated by combining what several agents can reach with the
                configuration NCO reports. Checks read existing sweep results; they never probe.
              </p>
            </div>
            <.link
              :if={@can_manage}
              navigate={~p"/settings/networks/composite-checks/new"}
              class="shrink-0"
            >
              <.button>New check</.button>
            </.link>
          </header>

          <div :if={@checks == []} class="rounded-sr-control border border-sr-border p-8 text-center">
            <.icon name="hero-shield-check" class="mx-auto size-8 text-sr-ink-muted" />
            <p class="mt-3 text-sm font-medium text-sr-ink">No composite checks yet</p>
            <p class="mx-auto mt-1 max-w-md text-sm text-sr-ink-muted">
              A composite check needs at least two vantage points: one agent expected to reach the
              device, and one expected to be blocked. Without a reachable vantage point a
              powered-off device looks exactly like a perfectly isolated one.
            </p>
          </div>

          <ul :if={@checks != []} class="space-y-2">
            <li
              :for={check <- @checks}
              class="rounded-sr-control border border-sr-border bg-sr-surface p-4"
            >
              <div class="flex items-center justify-between gap-4">
                <div class="min-w-0">
                  <p class="truncate text-sm font-medium text-sr-ink">{check.name}</p>
                  <p class="mt-0.5 truncate font-mono text-xs text-sr-ink-muted">
                    {check.scope_query}
                  </p>
                </div>
                <span class="shrink-0 text-xs text-sr-ink-muted">{check.state}</span>
              </div>
            </li>
          </ul>
        </div>
      </Shell.settings_chrome>
    </Layouts.app>
    """
  end
end
