defmodule ServiceRadarWebNGWeb.RemoteAccessLive.Targets do
  @moduledoc false
  use ServiceRadarWebNGWeb, :live_view

  alias ServiceRadar.Edge.RemoteAccessApplicationTarget
  alias ServiceRadar.Edge.RemoteAccessTcpTarget
  alias ServiceRadarWebNG.RBAC
  alias ServiceRadarWebNGWeb.FeatureFlags

  require Ash.Query

  @app_permission "devices.remote_access.app.open"
  @tcp_permission "devices.remote_access.tcp.open"

  @impl true
  def mount(_params, _session, socket) do
    app_enabled? = FeatureFlags.remote_access_app_enabled?()
    tcp_enabled? = FeatureFlags.remote_access_tcp_enabled?()
    can_open_app? = app_enabled? and RBAC.can?(socket.assigns.current_scope, @app_permission)
    can_open_tcp? = tcp_enabled? and RBAC.can?(socket.assigns.current_scope, @tcp_permission)

    socket =
      socket
      |> assign(:page_title, "Remote Access Targets")
      |> assign(:app_enabled?, app_enabled?)
      |> assign(:tcp_enabled?, tcp_enabled?)
      |> assign(:can_open_app?, can_open_app?)
      |> assign(:can_open_tcp?, can_open_tcp?)
      |> assign(:application_targets, [])
      |> assign(:tcp_targets, [])
      |> assign(:targets_error, nil)

    if connected?(socket) do
      {:ok, load_targets(socket)}
    else
      {:ok, socket}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-7xl p-6">
        <nav class="mb-4 text-sm ">
          <ul>
            <li><.link navigate={~p"/devices"}>Devices</.link></li>
            <li class="text-sr-muted">Remote access targets</li>
          </ul>
        </nav>

        <.header>
          Remote access targets
          <:subtitle>
            Registered application and TCP targets that can be reached through an edge agent.
          </:subtitle>
        </.header>

        <div :if={@targets_error} class={ui_alert_class(variant: "error", class: "mt-4 text-sm")}>
          {@targets_error}
        </div>

        <div class="mt-6 grid grid-cols-1 gap-6 xl:grid-cols-2">
          <section class="space-y-3">
            <div class="flex items-center justify-between gap-3">
              <h2 class="text-base font-semibold">Applications</h2>
              <.ui_badge size="sm" variant="outline">{length(@application_targets)}</.ui_badge>
            </div>

            <div class="sr-ui-table-shell">
              <table class={ui_table_class(size: "sm")}>
                <thead>
                  <tr>
                    <th>Name</th>
                    <th>Upstream</th>
                    <th class="w-28 text-right">Action</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :if={@application_targets == []}>
                    <td colspan="3" class="text-sr-muted">
                      No registered application targets are visible.
                    </td>
                  </tr>
                  <tr :for={target <- @application_targets}>
                    <td>
                      <div class="font-medium">{target.name}</div>
                      <div class="font-mono text-xs text-sr-muted">{target.device_uid}</div>
                    </td>
                    <td class="font-mono text-xs">
                      {target.upstream_scheme}://{target.upstream_host}:{target.upstream_port}
                    </td>
                    <td class="text-right">
                      <.ui_button
                        :if={@can_open_app? and target.enabled}
                        navigate={~p"/remote-access/applications/#{target.id}"}
                        size="xs"
                        variant="primary"
                      >
                        Open
                      </.ui_button>
                      <.ui_badge
                        :if={!(@can_open_app? and target.enabled)}
                        size="sm"
                        variant="ghost"
                      >
                        unavailable
                      </.ui_badge>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          </section>

          <section class="space-y-3">
            <div class="flex items-center justify-between gap-3">
              <h2 class="text-base font-semibold">TCP targets</h2>
              <.ui_badge size="sm" variant="outline">{length(@tcp_targets)}</.ui_badge>
            </div>

            <div class="sr-ui-table-shell">
              <table class={ui_table_class(size: "sm")}>
                <thead>
                  <tr>
                    <th>Name</th>
                    <th>Endpoint</th>
                    <th class="w-40 text-right">Browser workflow</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :if={@tcp_targets == []}>
                    <td colspan="3" class="text-sr-muted">
                      No registered TCP targets are visible.
                    </td>
                  </tr>
                  <tr :for={target <- @tcp_targets}>
                    <td>
                      <div class="font-medium">{target.name}</div>
                      <div class="font-mono text-xs text-sr-muted">{target.protocol_name}</div>
                    </td>
                    <td class="font-mono text-xs">{target.upstream_host}:{target.upstream_port}</td>
                    <td class="text-right">
                      <.ui_button
                        :if={@can_open_tcp? and target.enabled and tcp_browser_workflow?(target)}
                        navigate={~p"/remote-access/tcp-targets/#{target.id}"}
                        size="xs"
                        variant="soft"
                      >
                        Open
                      </.ui_button>
                      <.ui_badge
                        :if={(!@can_open_tcp? or !target.enabled) and tcp_browser_workflow?(target)}
                        size="sm"
                        variant="ghost"
                      >
                        unavailable
                      </.ui_badge>
                      <.ui_badge :if={!tcp_browser_workflow?(target)} size="sm" variant="ghost">
                        none
                      </.ui_badge>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          </section>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp load_targets(socket) do
    with {:ok, application_targets} <-
           maybe_read_targets(
             RemoteAccessApplicationTarget,
             socket.assigns.current_scope,
             socket.assigns.can_open_app?
           ),
         {:ok, tcp_targets} <-
           maybe_read_targets(RemoteAccessTcpTarget, socket.assigns.current_scope, socket.assigns.can_open_tcp?) do
      socket
      |> assign(:application_targets, application_targets)
      |> assign(:tcp_targets, tcp_targets)
      |> assign(:targets_error, nil)
    else
      {:error, error} ->
        assign(socket, :targets_error, "Failed to load remote access targets: #{Exception.message(error)}")
    end
  end

  defp maybe_read_targets(_resource, _scope, false), do: {:ok, []}
  defp maybe_read_targets(resource, scope, true), do: read_targets(resource, scope)

  defp read_targets(resource, scope) do
    resource
    |> Ash.Query.for_read(:read, %{})
    |> Ash.Query.sort(name: :asc)
    |> Ash.read(scope: scope)
  end

  defp tcp_browser_workflow?(target) do
    metadata = target.metadata || %{}

    present?(Map.get(metadata, "browser_renderer")) or present?(Map.get(metadata, "client_workflow"))
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(value), do: not is_nil(value)
end
