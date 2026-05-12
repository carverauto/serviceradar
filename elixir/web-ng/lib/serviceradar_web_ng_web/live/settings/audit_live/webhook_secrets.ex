defmodule ServiceRadarWebNGWeb.Settings.AuditLive.WebhookSecrets do
  @moduledoc """
  Settings → Audit → Webhook Secrets.

  Lists `ServiceRadar.Security.WebhookSecret` rows grouped by source.
  Users with `settings.audit.manage` can rotate a secret — entering
  a new value supersedes the current active record with a grace
  window (default 300s) so callers can roll their config without
  an outage.
  """

  use ServiceRadarWebNGWeb, :live_view

  alias ServiceRadar.Identity.RBAC
  alias ServiceRadar.Security.WebhookSecret
  alias ServiceRadarWebNGWeb.SettingsComponents

  on_mount {ServiceRadarWebNGWeb.UserAuth, :require_authenticated}

  @impl true
  def mount(_params, _session, socket) do
    {permissions, ash_actor} = permissions_and_actor(socket)

    socket =
      socket
      |> assign(:page_title, "Settings → Audit → Webhook Secrets")
      |> assign(:current_path, "/settings/audit/webhook-secrets")
      |> assign(:permissions, permissions)
      |> assign(:ash_actor, ash_actor)
      |> assign(:can_view?, MapSet.member?(permissions, "settings.audit.view"))
      |> assign(:can_manage?, MapSet.member?(permissions, "settings.audit.manage"))
      |> assign(:rotation, %{open?: false, source_name: nil, secret: "", grace_seconds: "300"})
      |> load_secrets()

    {:ok, socket}
  end

  @impl true
  def handle_event("open-rotation", %{"source" => source_name}, socket) do
    if socket.assigns.can_manage? do
      {:noreply,
       assign(socket, :rotation, %{
         open?: true,
         source_name: source_name,
         secret: "",
         grace_seconds: "300"
       })}
    else
      {:noreply, put_flash(socket, :error, "Missing settings.audit.manage permission.")}
    end
  end

  def handle_event("cancel-rotation", _params, socket) do
    {:noreply,
     assign(socket, :rotation, %{open?: false, source_name: nil, secret: "", grace_seconds: "300"})}
  end

  def handle_event(
        "rotate",
        %{"source_name" => source_name, "secret" => secret, "grace_seconds" => grace},
        socket
      ) do
    cond do
      not socket.assigns.can_manage? ->
        {:noreply, put_flash(socket, :error, "Missing settings.audit.manage permission.")}

      String.trim(secret) == "" ->
        {:noreply, put_flash(socket, :error, "Secret value is required.")}

      true ->
        grace = parse_grace(grace)
        actor = socket.assigns.ash_actor

        case WebhookSecret.rotate_secret(source_name, secret, grace, actor: actor) do
          {:ok, _new} ->
            {:noreply,
             socket
             |> put_flash(:info, "Rotated secret for #{source_name} (grace #{grace}s).")
             |> assign(:rotation, %{open?: false, source_name: nil, secret: "", grace_seconds: "300"})
             |> load_secrets()}

          {:error, error} ->
            {:noreply, put_flash(socket, :error, "Rotation failed: #{inspect(error)}")}
        end
    end
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

  defp parse_grace(value) do
    case Integer.parse(to_string(value)) do
      {n, _} when n > 0 -> n
      _ -> 300
    end
  end

  defp load_secrets(socket) do
    if socket.assigns.can_view? do
      case WebhookSecret.list(actor: socket.assigns.ash_actor) do
        {:ok, rows} -> assign(socket, :secrets, group_by_source(rows))
        _ -> assign(socket, :secrets, [])
      end
    else
      assign(socket, :secrets, [])
    end
  rescue
    _ -> assign(socket, :secrets, [])
  end

  defp group_by_source(rows) do
    rows
    |> Enum.group_by(& &1.source_name)
    |> Enum.map(fn {name, secrets} ->
      %{
        source_name: name,
        active: Enum.find(secrets, & &1.active?),
        superseded: Enum.reject(secrets, & &1.active?)
      }
    end)
    |> Enum.sort_by(& &1.source_name)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <SettingsComponents.settings_shell current_path={@current_path}>
      <SettingsComponents.settings_nav
        current_path={@current_path}
        current_scope={@current_scope}
      />

      <header class="space-y-1">
        <h1 class="text-2xl font-semibold">Audit · Webhook Secrets</h1>
        <p class="text-sm text-zinc-500">
          Per-source HMAC secrets used by the WebhookSignature plug.
          Rotation supersedes the current active secret with a grace window.
        </p>
      </header>

      <%= if @can_view? do %>
        <div class="space-y-4">
          <%= for group <- @secrets do %>
            <div class="rounded-lg border border-zinc-200 dark:border-zinc-700 p-4 space-y-2">
              <div class="flex items-center justify-between">
                <div>
                  <h2 class="font-semibold">{group.source_name}</h2>
                  <p class="text-xs text-zinc-500">
                    Last used: {format_dt((group.active || %{}).last_used_at)}
                  </p>
                </div>
                <%= if @can_manage? do %>
                  <button
                    type="button"
                    class="ui-button"
                    phx-click="open-rotation"
                    phx-value-source={group.source_name}
                  >
                    Rotate
                  </button>
                <% end %>
              </div>

              <%= if length(group.superseded) > 0 do %>
                <p class="text-xs text-zinc-500">
                  {length(group.superseded)} superseded record(s) — accepted until their grace window expires.
                </p>
              <% end %>
            </div>
          <% end %>

          <%= if Enum.empty?(@secrets) do %>
            <p class="text-sm text-zinc-500">No webhook secrets configured.</p>
          <% end %>
        </div>

        <%= if @rotation.open? do %>
          <form
            phx-submit="rotate"
            class="space-y-3 rounded-lg border border-zinc-200 dark:border-zinc-700 p-4"
          >
            <h3 class="font-semibold">Rotate secret for {@rotation.source_name}</h3>
            <input type="hidden" name="source_name" value={@rotation.source_name} />

            <label class="block text-sm">
              <span class="block mb-1">New secret</span>
              <input type="password" name="secret" class="ui-input w-full" required />
            </label>

            <label class="block text-sm">
              <span class="block mb-1">Grace window (seconds)</span>
              <input
                type="number"
                name="grace_seconds"
                value={@rotation.grace_seconds}
                min="1"
                class="ui-input w-32"
              />
            </label>

            <div class="flex gap-2">
              <button type="submit" class="ui-button-primary">Rotate</button>
              <button type="button" class="ui-button" phx-click="cancel-rotation">Cancel</button>
            </div>
          </form>
        <% end %>
      <% else %>
        <p class="text-sm text-red-600">
          You need <code>settings.audit.view</code> to see webhook secrets.
        </p>
      <% end %>
    </SettingsComponents.settings_shell>
    """
  end

  defp format_dt(nil), do: "—"
  defp format_dt(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M UTC")
end
