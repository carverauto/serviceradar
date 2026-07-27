defmodule ServiceRadarWebNGWeb.RemoteAccessLive.Application do
  @moduledoc false
  use ServiceRadarWebNGWeb, :live_view

  alias ServiceRadarWebNG.RBAC
  alias ServiceRadarWebNGWeb.FeatureFlags

  @remote_access_permission "devices.remote_access.app.open"

  @impl true
  def mount(%{"target_id" => target_id}, _session, socket) do
    feature_enabled? = FeatureFlags.remote_access_app_enabled?()
    can_open? = feature_enabled? and RBAC.can?(socket.assigns.current_scope, @remote_access_permission)

    socket =
      socket
      |> assign(:page_title, "Application Remote Access")
      |> assign(:target_id, target_id)
      |> assign(:feature_enabled?, feature_enabled?)
      |> assign(:can_open?, can_open?)

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="flex h-[calc(100vh-4rem)] min-h-[620px] flex-col bg-sr-surface">
        <div class="flex min-h-14 items-center gap-3 border-b border-sr-line px-4">
          <.ui_button navigate={~p"/remote-access/targets"} size="sm" variant="ghost">
            <.icon name="hero-arrow-left" class="size-4" /> Targets
          </.ui_button>
          <div class="min-w-0 flex-1">
            <h1 class="truncate text-sm font-semibold">Application remote access</h1>
            <p class="truncate font-mono text-xs text-sr-muted">{@target_id}</p>
          </div>
        </div>

        <div :if={!@can_open?} class="flex min-h-0 flex-1 items-center justify-center p-6">
          <div class="max-w-xl rounded border border-error/30 bg-error/10 p-4 text-sm text-error">
            <%= if @feature_enabled? do %>
              You do not have permission to open application remote-access sessions.
            <% else %>
              Application remote access is not enabled for this deployment.
            <% end %>
          </div>
        </div>

        <.remote_access_application
          :if={@can_open?}
          id={"remote-access-application-#{@target_id}"}
          class="min-h-0 flex-1"
          target_id={@target_id}
          title="Application remote access"
        />
      </div>
    </Layouts.app>
    """
  end
end
