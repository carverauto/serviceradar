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
  alias ServiceRadarWebNG.Auth.CliSessions, as: CliSessionsContext

  on_mount {ServiceRadarWebNGWeb.UserAuth, :require_authenticated}

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "CLI Sessions")
      |> assign(:current_path, "/settings/cli-sessions")
      |> load_sessions()

    {:ok, socket}
  end

  @impl true
  def handle_event("revoke", %{"jti" => jti}, socket) do
    actor = current_actor(socket)

    case Enum.find(socket.assigns.sessions, &(&1.jti == jti)) do
      nil ->
        {:noreply, put_flash(socket, :error, "Session no longer present.")}

      %CliSession{} = session ->
        case CliSessionsContext.revoke(session, actor: actor) do
          {:ok, _updated} ->
            {:noreply,
             socket
             |> put_flash(:info, "CLI session revoked.")
             |> load_sessions()}

          {:error, reason} ->
            {:noreply,
             put_flash(socket, :error, "Failed to revoke: #{inspect(reason)}")}
        end
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
      <div class="mx-auto w-full max-w-5xl p-6 space-y-6">
        <header>
          <h1 class="text-2xl font-semibold text-base-content">CLI Sessions</h1>
          <p class="text-sm text-base-content/70">
            Each row is a long-lived bearer token issued to <code class="font-mono">serviceradar-cli</code>
            after you approved a device-code authorization. Revoking a row stops
            the holder of that token from making any further API calls.
          </p>
        </header>

        <%= if Enum.empty?(@sessions) do %>
          <div class="alert alert-info">
            <span>
              No active CLI sessions. Run <code class="font-mono">serviceradar-cli auth login --instance &lt;url&gt;</code>
              to create one.
            </span>
          </div>
        <% else %>
          <div class="overflow-x-auto">
            <table class="table table-zebra">
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
                    <td>{format_timestamp(session.issued_at)}</td>
                    <td>{format_timestamp(session.last_used_at)}</td>
                    <td>{format_timestamp(session.expires_at)}</td>
                    <td>
                      <span class={status_badge_class(session.status)}>
                        {Atom.to_string(session.status)}
                      </span>
                    </td>
                    <td class="text-right">
                      <%= if session.status == :active do %>
                        <button
                          type="button"
                          phx-click="revoke"
                          phx-value-jti={session.jti}
                          data-confirm="Revoke this CLI session? Any open serviceradar-cli will receive 401s on its next API call."
                          class="btn btn-sm btn-ghost text-error"
                        >
                          Revoke
                        </button>
                      <% end %>
                    </td>
                  </tr>
                <% end %>
              </tbody>
            </table>
          </div>
        <% end %>
      </div>
    </Layouts.app>
    """
  end

  ## Helpers

  defp load_sessions(socket) do
    actor = current_actor(socket)
    show_admin? = admin?(socket)

    {sessions, show_user_column?} =
      cond do
        is_nil(actor) ->
          {[], false}

        show_admin? ->
          case CliSessionsContext.list_all(actor: actor) do
            {:ok, rows} -> {sort_sessions(rows), true}
            _ -> {[], false}
          end

        true ->
          case CliSessionsContext.list_active_for_user(actor.id, actor: actor) do
            {:ok, rows} -> {sort_sessions(rows), false}
            _ -> {[], false}
          end
      end

    socket
    |> assign(:sessions, sessions)
    |> assign(:show_user_column?, show_user_column?)
  end

  defp sort_sessions(rows) do
    Enum.sort_by(rows, & &1.issued_at, {:desc, DateTime})
  end

  defp current_actor(%{assigns: %{current_scope: %{user: %{id: _} = user}}}), do: user
  defp current_actor(%{assigns: %{ash_actor: actor}}) when not is_nil(actor), do: actor
  defp current_actor(_), do: nil

  defp admin?(%{assigns: %{current_scope: %{user: %{role: role}}}}) when role in [:admin, "admin"], do: true
  defp admin?(_), do: false

  defp format_timestamp(nil), do: "—"

  defp format_timestamp(%DateTime{} = dt) do
    Calendar.strftime(dt, "%Y-%m-%d %H:%M UTC")
  end

  defp format_timestamp(_), do: "—"

  defp status_badge_class(:active), do: "badge badge-success badge-outline"
  defp status_badge_class(:revoked), do: "badge badge-error badge-outline"
  defp status_badge_class(:expired), do: "badge badge-ghost badge-outline"
  defp status_badge_class(_), do: "badge badge-ghost"
end
