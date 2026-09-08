defmodule ServiceRadarWebNGWeb.Settings.McpSessionsLive do
  @moduledoc """
  Settings → MCP Sessions. Lists and revokes MCP authorization-code grants.
  """

  use ServiceRadarWebNGWeb, :live_view

  alias ServiceRadar.Identity.Constants
  alias ServiceRadar.Identity.McpOAuthGrant
  alias ServiceRadarWebNG.Mcp.OAuth.Server
  alias ServiceRadarWebNG.RBAC
  alias ServiceRadarWebNGWeb.FeatureFlags
  alias ServiceRadarWebNGWeb.Settings.Shell

  @mcp_manage_permission Constants.mcp_manage_permission()

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    if RBAC.can?(scope, @mcp_manage_permission) do
      socket =
        socket
        |> assign(:page_title, "MCP Sessions")
        |> assign(:current_path, "/settings/mcp-sessions")
        |> load_grants()

      {:ok, socket}
    else
      {:ok,
       socket
       |> put_flash(:error, "You don't have permission to manage MCP sessions.")
       |> push_navigate(to: ~p"/dashboard")}
    end
  end

  @impl true
  def handle_event("revoke", %{"id" => id}, socket) do
    user = socket.assigns.current_scope.user

    grant = Enum.find(socket.assigns.grants, &(to_string(&1.id) == id))

    cond do
      is_nil(grant) ->
        {:noreply, put_flash(socket, :error, "Grant not found.")}

      grant.user_id != user.id ->
        {:noreply, put_flash(socket, :error, "You cannot revoke this grant.")}

      true ->
        Server.revoke_grant(grant)
        {:noreply, socket |> put_flash(:info, "MCP grant revoked.") |> load_grants()}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_path={@current_path}
      page_title={@page_title}
    >
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
        <div class="mx-auto w-full max-w-4xl p-6 space-y-6">
          <header>
            <h1 class="text-2xl font-semibold text-sr-ink">MCP Sessions</h1>
            <p class="text-sm text-sr-muted">
              Native MCP clients (Codex, Claude Code, Grok) receive a grant after
              you approve them in the browser. Revoking a grant invalidates its
              refresh tokens; the client must sign in through SSO again.
            </p>
          </header>

          <%= unless FeatureFlags.mcp_enabled?() do %>
            <div class={ui_alert_class("info")}>
              <span>MCP is disabled on this deployment.</span>
            </div>
          <% end %>

          <%= if Enum.empty?(@grants) do %>
            <div class={ui_alert_class("info")}>
              <span>
                No MCP grants yet. Point an MCP client at <code class="font-mono">/mcp</code>
                and complete the SSO login.
              </span>
            </div>
          <% else %>
            <div class="sr-ui-table-shell">
              <table class={ui_table_class(zebra: true)}>
                <thead>
                  <tr>
                    <th>Client</th>
                    <th>Scopes</th>
                    <th>Sign-in</th>
                    <th>Granted</th>
                    <th>Status</th>
                    <th class="text-right">Actions</th>
                  </tr>
                </thead>
                <tbody>
                  <%= for grant <- @grants do %>
                    <tr>
                      <td class="font-mono text-sm">{grant.client_id}</td>
                      <td class="font-mono text-xs">{grant.scope}</td>
                      <td class="text-sm">{grant.auth_method}</td>
                      <td class="text-sm">
                        <.user_time
                          id={"settings-mcp-grant-#{grant.id}-inserted-at"}
                          value={grant.inserted_at}
                          timezone={@current_scope.user.timezone || "Etc/UTC"}
                          style={:compact}
                          fallback="—"
                        />
                      </td>
                      <td>
                        <.ui_badge
                          size="sm"
                          variant={if is_nil(grant.revoked_at), do: "success", else: "neutral"}
                        >
                          {if is_nil(grant.revoked_at), do: "active", else: "revoked"}
                        </.ui_badge>
                      </td>
                      <td class="text-right">
                        <%= if is_nil(grant.revoked_at) do %>
                          <.ui_button
                            type="button"
                            phx-click="revoke"
                            phx-value-id={grant.id}
                            data-confirm="Revoke this MCP grant? The client will have to sign in again."
                            size="sm"
                            variant="ghost"
                            class="text-error"
                          >
                            Revoke
                          </.ui_button>
                        <% end %>
                      </td>
                    </tr>
                  <% end %>
                </tbody>
              </table>
            </div>
          <% end %>
        </div>
      </Shell.settings_chrome>
    </Layouts.app>
    """
  end

  defp load_grants(socket) do
    user = socket.assigns.current_scope.user

    grants =
      case McpOAuthGrant.list_by_user(user.id, actor: user) do
        {:ok, rows} -> Enum.sort_by(rows, & &1.inserted_at, {:desc, DateTime})
        _ -> []
      end

    assign(socket, :grants, grants)
  end
end
