defmodule ServiceRadarWebNGWeb.Settings.AuditLive.EventShow do
  @moduledoc """
  Settings -> Audit -> Event details.
  """

  use ServiceRadarWebNGWeb, :live_view

  import Ash.Expr

  alias ServiceRadar.Identity.RBAC
  alias ServiceRadar.Security.SecurityEvent
  alias ServiceRadarWebNGWeb.Settings.Shell

  require Ash.Query

  on_mount {ServiceRadarWebNGWeb.UserAuth, :require_authenticated}

  @impl true
  def mount(%{"event_id" => event_id}, _session, socket) do
    {permissions, ash_actor} = permissions_and_actor(socket)
    can_view? = can_view?(permissions)

    socket =
      socket
      |> assign(:page_title, "Settings -> Audit -> Event")
      |> assign(:current_path, "/settings/audit/events")
      |> assign(:permissions, permissions)
      |> assign(:ash_actor, ash_actor)
      |> assign(:can_view?, can_view?)
      |> assign(:event, nil)
      |> assign(:load_error, nil)

    {:ok, load_event(socket, event_id)}
  end

  defp permissions_and_actor(socket) do
    case socket.assigns[:current_scope] do
      %{user: %{} = user} ->
        perms = RBAC.permissions_for_user(user)
        {perms, build_actor(user, perms)}

      _ ->
        {MapSet.new(), nil}
    end
  end

  defp build_actor(user, perms) do
    %{user | role: pick_role(perms)}
  rescue
    _ -> user
  end

  defp pick_role(perms) do
    cond do
      MapSet.member?(perms, "settings.audit.manage") -> :admin
      MapSet.member?(perms, "settings.audit.view") -> :operator
      true -> :viewer
    end
  end

  defp can_view?(perms) do
    MapSet.member?(perms, "settings.audit.view") or
      MapSet.member?(perms, "settings.audit.manage")
  end

  defp load_event(%{assigns: %{can_view?: false}} = socket, _event_id), do: socket

  defp load_event(socket, event_id) do
    query =
      SecurityEvent
      |> Ash.Query.for_read(:read, %{}, actor: socket.assigns.ash_actor)
      |> Ash.Query.filter(expr(id == ^event_id))
      |> Ash.Query.limit(1)

    case Ash.read(query, actor: socket.assigns.ash_actor) do
      {:ok, [event | _]} -> assign(socket, :event, event)
      {:ok, []} -> assign(socket, :load_error, "Security event not found.")
      {:error, reason} -> assign(socket, :load_error, "Failed to load event: #{inspect(reason)}")
    end
  rescue
    _ -> assign(socket, :load_error, "Failed to load event.")
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} current_path={@current_path}>
      <Shell.settings_chrome
        settings_ui={@settings_ui}
        current_path={@current_path}
        current_scope={@current_scope}
        active_view={@settings_active_view}
        active_category={@settings_active_category}
        breadcrumbs={@settings_breadcrumbs}
        nav_tree={@settings_nav_tree}
        palette={@settings_palette}
        stats={@settings_stats}
        legacy_subnav={:none}
      >
        <header class="space-y-2">
          <.link navigate={~p"/settings/audit/events"} class="link link-hover text-sm">
            Back to audit events
          </.link>
          <h1 class="text-2xl font-semibold">Audit Event Details</h1>
        </header>

        <%= cond do %>
          <% not @can_view? -> %>
            <p class="text-sm text-error">
              You need <code>settings.audit.view</code> to see security events.
            </p>
          <% @load_error -> %>
            <p class="text-sm text-error">{@load_error}</p>
          <% @event -> %>
            <div class="grid gap-4 lg:grid-cols-[360px,1fr]">
              <section class="rounded-lg border border-base-200 bg-base-100 p-4">
                <dl class="grid gap-3 text-sm">
                  <div>
                    <dt class="text-xs uppercase text-base-content/50">ID</dt>
                    <dd class="font-mono text-xs break-all">{@event.id}</dd>
                  </div>
                  <div>
                    <dt class="text-xs uppercase text-base-content/50">Time</dt>
                    <dd class="font-mono text-xs">{format_dt(@event.occurred_at)}</dd>
                  </div>
                  <div>
                    <dt class="text-xs uppercase text-base-content/50">Kind</dt>
                    <dd>{@event.kind}</dd>
                  </div>
                  <div>
                    <dt class="text-xs uppercase text-base-content/50">Severity</dt>
                    <dd>{@event.severity}</dd>
                  </div>
                  <div>
                    <dt class="text-xs uppercase text-base-content/50">Actor</dt>
                    <dd class="font-mono text-xs">{@event.actor_id || "-"}</dd>
                  </div>
                  <div>
                    <dt class="text-xs uppercase text-base-content/50">IP</dt>
                    <dd class="font-mono text-xs">{@event.ip || "-"}</dd>
                  </div>
                  <div>
                    <dt class="text-xs uppercase text-base-content/50">Route</dt>
                    <dd class="font-mono text-xs break-all">{@event.route || "-"}</dd>
                  </div>
                  <div :if={@event.correlation_id}>
                    <dt class="text-xs uppercase text-base-content/50">Correlation ID</dt>
                    <dd class="font-mono text-xs break-all">{@event.correlation_id}</dd>
                  </div>
                </dl>
              </section>

              <section class="rounded-lg border border-base-200 bg-base-100 p-4">
                <h2 class="text-sm font-semibold">Details</h2>
                <pre class="mt-3 max-h-[70vh] overflow-auto rounded bg-base-200/60 p-3 text-xs leading-relaxed"><%= pretty_details(@event.details) %></pre>
              </section>
            </div>
        <% end %>
      </Shell.settings_chrome>
    </Layouts.app>
    """
  end

  defp format_dt(nil), do: "-"

  defp format_dt(%DateTime{} = dt) do
    Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S UTC")
  end

  defp pretty_details(details) when is_map(details) do
    Jason.encode!(details, pretty: true)
  rescue
    _ -> inspect(details, pretty: true)
  end

  defp pretty_details(details), do: inspect(details, pretty: true)
end
