defmodule ServiceRadarWebNGWeb.Settings.CliSessionsLive do
  @moduledoc """
  Settings → CLI sessions page.

  Lists every CLI-issued JWT (Guardian `typ: "api"`) for the signed-in
  user. Admins (`cli.session.read_any`) see every user's sessions plus a
  "User" column. Revoke buttons fire
  `ServiceRadarWebNG.Auth.CliSessions.revoke/2` which:

  1. flips the `cli_sessions.status` row to `:revoked` (visible here on
     reload),
  2. writes a `RevokedToken` entry via
     `ServiceRadarWebNG.Auth.TokenRevocation` so the existing Guardian
     verify hook rejects subsequent API requests bearing the JWT.

  RBAC plumbing on `cli.session.{read_own,revoke_own,read_any,revoke_any}`
  lands fully in proposal §12; today the page checks `current_scope.user`
  and lets the resource policies enforce per-row authorization.
  """

  use ServiceRadarWebNGWeb, :live_view

  alias ServiceRadar.Identity.CliSession
  alias ServiceRadar.Identity.RBAC
  alias ServiceRadarWebNG.Auth.CliSessions, as: CliSessionsContext
  alias ServiceRadarWebNGWeb.Settings.Shell

  on_mount {ServiceRadarWebNGWeb.UserAuth, :require_authenticated}

  @perm_read_own "cli.session.read_own"
  @perm_read_any "cli.session.read_any"
  @perm_revoke_own "cli.session.revoke_own"
  @perm_revoke_any "cli.session.revoke_any"

  @impl true
  def mount(_params, _session, socket) do
    {permissions, ash_actor} =
      case socket.assigns[:current_scope] do
        %{user: %{} = user} ->
          perms = RBAC.permissions_for_user(user)
          {perms, build_actor(user, perms)}

        _ ->
          {MapSet.new(), nil}
      end

    socket =
      socket
      |> assign(:page_title, "CLI Sessions")
      |> assign(:current_path, "/settings/cli-sessions")
      |> assign(:permissions, permissions)
      |> assign(:ash_actor, ash_actor)
      |> assign(:can_read_any?, MapSet.member?(permissions, @perm_read_any))
      |> assign(:can_read_own?, MapSet.member?(permissions, @perm_read_own))
      |> assign(:can_revoke_any?, MapSet.member?(permissions, @perm_revoke_any))
      |> assign(:can_revoke_own?, MapSet.member?(permissions, @perm_revoke_own))
      |> load_sessions()

    {:ok, socket}
  end

  @impl true
  def handle_event("revoke", %{"jti" => jti}, socket) do
    actor = current_actor(socket)

    with %CliSession{} = session <- Enum.find(socket.assigns.sessions, &(&1.jti == jti)),
         :ok <- ensure_can_revoke(session, socket) do
      case CliSessionsContext.revoke(session, actor: actor) do
        {:ok, _updated} ->
          {:noreply,
           socket
           |> put_flash(:info, "CLI session revoked.")
           |> load_sessions()}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Failed to revoke: #{inspect(reason)}")}
      end
    else
      nil ->
        {:noreply, put_flash(socket, :error, "Session no longer present.")}

      {:error, :forbidden} ->
        {:noreply, put_flash(socket, :error, "Your role does not allow revoking this CLI session.")}
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
        <div class="mx-auto w-full max-w-5xl p-6 space-y-6">
          <header>
            <h1 class="text-2xl font-semibold text-sr-ink">CLI Sessions</h1>
            <p class="text-sm text-sr-muted">
              Each row is a long-lived bearer token issued to
              <code class="font-mono">serviceradar-cli</code>
              after you approved a device-code authorization. Revoking a row stops
              the holder of that token from making any further API calls.
            </p>
          </header>

          <%= if Enum.empty?(@sessions) do %>
            <div class={ui_alert_class("info")}>
              <span>
                No active CLI sessions. Run
                <code class="font-mono">serviceradar-cli auth login --instance &lt;url&gt;</code>
                to create one.
              </span>
            </div>
          <% else %>
            <div class="sr-ui-table-shell">
              <table class={ui_table_class(zebra: true)}>
                <thead>
                  <tr>
                    <%= if @show_user_column? do %>
                      <th>User</th>
                    <% end %>
                    <th>Client</th>
                    <th>Scope</th>
                    <th>Issued</th>
                    <th>Last used</th>
                    <th>Expires</th>
                    <th>Status</th>
                    <th class="text-right">Actions</th>
                  </tr>
                </thead>
                <tbody>
                  <%= for session <- @sessions do %>
                    <tr>
                      <%= if @show_user_column? do %>
                        <td class="font-mono text-xs">{session.user_id}</td>
                      <% end %>
                      <td>{session.client_id}</td>
                      <td class="font-mono text-xs">{session.scope}</td>
                      <td>
                        <.user_time
                          id={"settings-cli-session-#{session.jti}-issued-at"}
                          value={session.issued_at}
                          timezone={@current_scope.user.timezone || "Etc/UTC"}
                          style={:compact}
                          fallback="—"
                        />
                      </td>
                      <td>
                        <.user_time
                          id={"settings-cli-session-#{session.jti}-last-used-at"}
                          value={session.last_used_at}
                          timezone={@current_scope.user.timezone || "Etc/UTC"}
                          style={:compact}
                          fallback="—"
                        />
                      </td>
                      <td>
                        <.user_time
                          id={"settings-cli-session-#{session.jti}-expires-at"}
                          value={session.expires_at}
                          timezone={@current_scope.user.timezone || "Etc/UTC"}
                          style={:compact}
                          fallback="—"
                        />
                      </td>
                      <td>
                        <.ui_badge size="sm" variant={status_badge_variant(session.status)}>
                          {Atom.to_string(session.status)}
                        </.ui_badge>
                      </td>
                      <td class="text-right">
                        <%= if session.status == :active and can_revoke_session?(session, assigns) do %>
                          <.ui_button
                            type="button"
                            phx-click="revoke"
                            phx-value-jti={session.jti}
                            data-confirm="Revoke this CLI session? Any open serviceradar-cli will receive 401s on its next API call."
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

  ## Helpers

  defp load_sessions(socket) do
    actor = current_actor(socket)

    {sessions, show_user_column?} =
      cond do
        is_nil(actor) ->
          {[], false}

        socket.assigns[:can_read_any?] ->
          case CliSessionsContext.list_all(actor: actor) do
            {:ok, rows} -> {sort_sessions(rows), true}
            _ -> {[], false}
          end

        socket.assigns[:can_read_own?] ->
          case CliSessionsContext.list_active_for_user(actor.id, actor: actor) do
            {:ok, rows} -> {sort_sessions(rows), false}
            _ -> {[], false}
          end

        true ->
          {[], false}
      end

    socket
    |> assign(:sessions, sessions)
    |> assign(:show_user_column?, show_user_column?)
  end

  defp sort_sessions(rows) do
    Enum.sort_by(rows, & &1.issued_at, {:desc, DateTime})
  end

  defp current_actor(%{assigns: %{ash_actor: %{} = actor}}), do: actor
  defp current_actor(%{assigns: %{current_scope: %{user: %{id: _} = user}}}), do: user
  defp current_actor(_), do: nil

  defp build_actor(user, permissions) do
    %{
      id: user.id,
      role: Map.get(user, :role),
      email: Map.get(user, :email),
      permissions: permissions
    }
  end

  defp ensure_can_revoke(%CliSession{user_id: user_id}, socket) do
    cond do
      socket.assigns[:can_revoke_any?] ->
        :ok

      socket.assigns[:can_revoke_own?] && current_user_id(socket) == user_id ->
        :ok

      true ->
        {:error, :forbidden}
    end
  end

  defp current_user_id(%{assigns: %{current_scope: %{user: %{id: id}}}}), do: id
  defp current_user_id(_), do: nil

  # Template-side helper. Receives the LiveView's `assigns` map directly so
  # the `@socket.assigns[...]` access pattern (which fails in change-tracking
  # mode) is avoided.
  defp can_revoke_session?(%CliSession{user_id: user_id}, assigns) do
    cond do
      assigns[:can_revoke_any?] ->
        true

      assigns[:can_revoke_own?] and assigns[:current_scope] != nil and
        assigns[:current_scope].user != nil and assigns[:current_scope].user.id == user_id ->
        true

      true ->
        false
    end
  end

  defp status_badge_variant(:active), do: "success"
  defp status_badge_variant(:revoked), do: "error"
  defp status_badge_variant(:expired), do: "ghost"
  defp status_badge_variant(_), do: "ghost"
end
