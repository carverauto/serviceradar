defmodule ServiceRadarWebNGWeb.RemoteAccessLive.SSH do
  @moduledoc false
  use ServiceRadarWebNGWeb, :live_view

  alias ServiceRadarWebNG.RBAC

  @remote_access_permission "devices.remote_access.ssh.open"

  @impl true
  def mount(%{"uid" => device_uid}, _session, socket) do
    can_open? = RBAC.can?(socket.assigns.current_scope, @remote_access_permission)

    socket =
      socket
      |> assign(:page_title, "SSH Remote Access")
      |> assign(:device_uid, device_uid)
      |> assign(:can_open?, can_open?)
      |> assign(:allow_remembered_keys?, allow_remembered_keys?())

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="flex h-[calc(100vh-4rem)] min-h-[620px] flex-col bg-base-100">
        <div class="flex min-h-14 items-center gap-3 border-b border-base-300 px-4">
          <.link navigate={~p"/devices/#{@device_uid}"} class="btn btn-ghost btn-sm">
            <.icon name="hero-arrow-left" class="size-4" /> Device
          </.link>
          <div class="min-w-0 flex-1">
            <h1 class="truncate text-sm font-semibold">SSH remote access</h1>
            <p class="truncate text-xs text-base-content/60">{@device_uid}</p>
          </div>
        </div>

        <div :if={!@can_open?} class="flex min-h-0 flex-1 items-center justify-center p-6">
          <div class="max-w-xl rounded border border-error/30 bg-error/10 p-4 text-sm text-error">
            You do not have permission to open SSH remote-access sessions.
          </div>
        </div>

        <.remote_access_ssh_console
          :if={@can_open?}
          id={"remote-access-ssh-console-#{@device_uid}"}
          class="min-h-0 flex-1"
          device_uid={@device_uid}
          title="SSH remote access"
          allow_remembered_keys={@allow_remembered_keys?}
        />
      </div>
    </Layouts.app>
    """
  end

  defp allow_remembered_keys? do
    Application.get_env(:serviceradar_web_ng, :remote_access_browser_key_remember_enabled, false) == true
  end
end
