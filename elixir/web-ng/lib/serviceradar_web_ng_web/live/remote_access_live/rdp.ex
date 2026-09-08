defmodule ServiceRadarWebNGWeb.RemoteAccessLive.RDP do
  @moduledoc false
  use ServiceRadarWebNGWeb, :live_view

  alias ServiceRadarWebNG.RBAC
  alias ServiceRadarWebNGWeb.DeviceLive.RemoteAccessData
  alias ServiceRadarWebNGWeb.FeatureFlags

  @remote_access_permission "devices.remote_access.rdp.open"

  @impl true
  def mount(%{"uid" => device_uid}, _session, socket) do
    feature_enabled? = FeatureFlags.remote_access_desktop_rdp_enabled?()
    can_open? = feature_enabled? and RBAC.can?(socket.assigns.current_scope, @remote_access_permission)

    socket =
      socket
      |> assign(:page_title, "RDP Remote Access")
      |> assign(:device_uid, device_uid)
      |> assign(:feature_enabled?, feature_enabled?)
      |> assign(:can_open?, can_open?)
      |> assign(:target, nil)
      |> assign(:load_state, initial_load_state(feature_enabled?, can_open?))

    if connected?(socket) and can_open? do
      {:ok, load_target(socket)}
    else
      {:ok, socket}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="flex h-[calc(100vh-4rem)] min-h-[620px] flex-col bg-sr-surface">
        <div class="flex min-h-14 items-center gap-3 border-b border-sr-line px-4">
          <.ui_button navigate={~p"/devices/#{@device_uid}"} size="sm" variant="ghost">
            <.icon name="hero-arrow-left" class="size-4" /> Device
          </.ui_button>
          <div class="min-w-0 flex-1">
            <h1 class="truncate text-sm font-semibold">RDP remote access</h1>
            <p class="truncate text-xs text-sr-muted">
              {target_label(@target, @device_uid)}
            </p>
          </div>
        </div>

        <div
          :if={@load_state != :ready}
          class="flex min-h-0 flex-1 items-center justify-center p-6"
        >
          <div
            id="rdp-launch-availability"
            role={if @load_state == :loading, do: "status", else: "alert"}
            class={[
              "alert max-w-xl",
              @load_state == :loading && "alert-info",
              @load_state == :disabled && "alert-warning",
              @load_state in [:forbidden, :unavailable] && "alert-error"
            ]}
          >
            <span :if={@load_state == :loading} class="sr-ui-spinner sr-ui-spinner-sm"></span>
            <span>{load_state_message(@load_state)}</span>
          </div>
        </div>

        <.remote_access_desktop_session
          :if={@load_state == :ready and is_map(@target)}
          id={"remote-access-rdp-#{@device_uid}"}
          class="min-h-0 flex-1"
          desktop_target_id={Map.fetch!(@target, "id")}
          device_uid={@device_uid}
          title={target_label(@target, "RDP remote access")}
        />
      </div>
    </Layouts.app>
    """
  end

  defp load_target(socket) do
    case RemoteAccessData.rdp_target_for_device(socket.assigns.current_scope, socket.assigns.device_uid) do
      {:ok, target} ->
        socket
        |> assign(:target, target)
        |> assign(:load_state, :ready)

      {:error, reason} when reason in [:disabled, :forbidden, :not_found, :unavailable] ->
        socket
        |> assign(:target, nil)
        |> assign(:load_state, reason)
    end
  end

  defp initial_load_state(false, _can_open?), do: :disabled
  defp initial_load_state(true, false), do: :forbidden
  defp initial_load_state(true, true), do: :loading

  defp load_state_message(:loading), do: "Loading the authorized RDP target…"
  defp load_state_message(:disabled), do: "RDP remote access is not enabled for this deployment."
  defp load_state_message(:forbidden), do: "You do not have permission to open RDP remote-access sessions."
  defp load_state_message(:not_found), do: "No enabled RDP target is authorized for this device."
  defp load_state_message(:unavailable), do: "The authorized RDP target could not be loaded."
  defp load_state_message(:ready), do: "RDP target ready."

  defp target_label(%{"label" => label}, _fallback) when is_binary(label) and label != "", do: label
  defp target_label(_target, fallback), do: fallback
end
