defmodule ServiceRadarWebNGWeb.Settings.AuditLive.Lockouts do
  @moduledoc """
  Settings → Audit → Lockouts.

  Lists active and recently cleared `ServiceRadar.Security.AuthLockout`
  rows. Users with `settings.audit.manage` may clear a lockout; the
  action goes through `ServiceRadar.Security.Lockouts.unlock/3` which
  emits a `:lockout_cleared` SecurityEvent.
  """

  use ServiceRadarWebNGWeb, :live_view

  alias ServiceRadar.Identity.RBAC
  alias ServiceRadar.Security.AuthLockout
  alias ServiceRadar.Security.Lockouts
  alias ServiceRadarWebNGWeb.Settings.Shell

  on_mount {ServiceRadarWebNGWeb.UserAuth, :require_authenticated}

  @impl true
  def mount(_params, _session, socket) do
    {permissions, ash_actor, user} = permissions_actor_user(socket)

    socket =
      socket
      |> assign(:page_title, "Settings → Audit → Lockouts")
      |> assign(:current_path, "/settings/audit/lockouts")
      |> assign(:permissions, permissions)
      |> assign(:ash_actor, ash_actor)
      |> assign(:current_user, user)
      |> assign(:can_view?, MapSet.member?(permissions, "settings.audit.view"))
      |> assign(:can_manage?, MapSet.member?(permissions, "settings.audit.manage"))
      |> load_lockouts()

    {:ok, socket}
  end

  @impl true
  def handle_event("unlock", %{"id" => id}, socket) do
    if socket.assigns.can_manage? do
      case Enum.find(socket.assigns.lockouts, &(&1.id == id)) do
        nil ->
          {:noreply, put_flash(socket, :error, "Lockout not found.")}

        lockout ->
          admin_id = admin_id(socket)

          case Lockouts.unlock(lockout, admin_id, "manual_unlock") do
            {:ok, _} ->
              {:noreply,
               socket
               |> put_flash(:info, "Lockout cleared for #{lockout.actor_id}.")
               |> load_lockouts()}

            {:error, error} ->
              {:noreply, put_flash(socket, :error, "Unlock failed: #{inspect(error)}")}
          end
      end
    else
      {:noreply, put_flash(socket, :error, "Missing settings.audit.manage permission.")}
    end
  end

  defp permissions_actor_user(socket) do
    case socket.assigns[:current_scope] do
      %{user: %{} = user} ->
        perms = RBAC.permissions_for_user(user)
        {perms, build_actor(user, perms), user}

      _ ->
        {MapSet.new(), nil, nil}
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

  defp admin_id(%{assigns: %{current_user: %{id: id}}}), do: to_string(id)
  defp admin_id(_), do: "unknown"

  defp load_lockouts(socket) do
    if socket.assigns.can_view? do
      case AuthLockout.list(actor: socket.assigns.ash_actor) do
        {:ok, rows} -> assign(socket, :lockouts, Enum.sort_by(rows, & &1.locked_at, :desc))
        _ -> assign(socket, :lockouts, [])
      end
    else
      assign(socket, :lockouts, [])
    end
  rescue
    _ -> assign(socket, :lockouts, [])
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} current_path={@current_path}>
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
        <header class="space-y-1">
          <h1 class="text-2xl font-semibold">Audit · Lockouts</h1>
          <p class="text-sm text-sr-muted">
            Active and recently cleared account lockouts.
            <span :if={@can_manage?}>Click <em>Unlock</em> to clear a lockout.</span>
          </p>
        </header>

        <%= if @can_view? do %>
          <div class="overflow-x-auto rounded-lg border border-sr-line bg-sr-surface">
            <table class="min-w-full text-sm text-sr-ink">
              <thead class="bg-sr-subtle/70 text-sr-muted">
                <tr>
                  <th class="px-4 py-2 text-left">Actor</th>
                  <th class="px-4 py-2 text-left">Locked at</th>
                  <th class="px-4 py-2 text-left">Expires</th>
                  <th class="px-4 py-2 text-left">Reason</th>
                  <th class="px-4 py-2 text-left">Status</th>
                  <th class="px-4 py-2"></th>
                </tr>
              </thead>
              <tbody class="divide-y divide-sr-line">
                <%= for lockout <- @lockouts do %>
                  <tr class="hover:bg-sr-subtle/40">
                    <td class="px-4 py-2 font-mono text-xs">{lockout.actor_id}</td>
                    <td class="px-4 py-2 font-mono text-xs">
                      <.user_time
                        id={"settings-audit-lockout-#{lockout.id}-locked-at"}
                        value={lockout.locked_at}
                        timezone={@current_scope.user.timezone || "Etc/UTC"}
                        style={:compact}
                        fallback="—"
                      />
                    </td>
                    <td class="px-4 py-2 font-mono text-xs">
                      <.user_time
                        id={"settings-audit-lockout-#{lockout.id}-expires-at"}
                        value={lockout.expires_at}
                        timezone={@current_scope.user.timezone || "Etc/UTC"}
                        style={:compact}
                        fallback="—"
                      />
                    </td>
                    <td class="px-4 py-2">{lockout.reason || "—"}</td>
                    <td class="px-4 py-2">{status_label(lockout)}</td>
                    <td class="px-4 py-2">
                      <%= if @can_manage? and active?(lockout) do %>
                        <button
                          type="button"
                          class="ui-button"
                          phx-click="unlock"
                          phx-value-id={lockout.id}
                          data-confirm="Clear this lockout?"
                        >
                          Unlock
                        </button>
                      <% end %>
                    </td>
                  </tr>
                <% end %>
                <%= if Enum.empty?(@lockouts) do %>
                  <tr>
                    <td colspan="6" class="px-4 py-8 text-center text-sr-muted">
                      No lockouts on record.
                    </td>
                  </tr>
                <% end %>
              </tbody>
            </table>
          </div>
        <% else %>
          <p class="text-sm text-error">
            You need <code>settings.audit.view</code> to see lockouts.
          </p>
        <% end %>
      </Shell.settings_chrome>
    </Layouts.app>
    """
  end

  defp active?(%AuthLockout{cleared_at: nil} = lockout) do
    case lockout.expires_at do
      nil -> true
      dt -> DateTime.after?(dt, DateTime.utc_now())
    end
  end

  defp active?(_), do: false

  defp status_label(lockout) do
    cond do
      lockout.cleared_at -> "Cleared"
      active?(lockout) -> "Active"
      true -> "Expired"
    end
  end
end
