defmodule ServiceRadarWebNGWeb.ProxmoxConsoleLive.Show do
  @moduledoc false
  use ServiceRadarWebNGWeb, :live_view

  alias ServiceRadar.Edge.ProxmoxConsoleSession
  alias ServiceRadar.Edge.ProxmoxConsoleSessions
  alias ServiceRadarWebNG.RBAC

  @console_permission "devices.console.open"
  @default_cols 120
  @default_rows 34

  @impl true
  def mount(%{"uid" => device_uid}, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "Proxmox Console")
      |> assign(:device_uid, device_uid)
      |> assign(:session, nil)
      |> assign(:ticket, nil)
      |> assign(:websocket_path, nil)
      |> assign(:console_error, nil)
      |> assign(:loading, true)

    if connected?(socket) do
      {:ok, open_console(socket)}
    else
      {:ok, socket}
    end
  end

  @impl true
  def handle_event("close_console", _params, socket) do
    case socket.assigns.session do
      %ProxmoxConsoleSession{id: id} ->
        _ = ProxmoxConsoleSessions.request_close(id, reason: "operator_closed", scope: socket.assigns.current_scope)

      _session ->
        :ok
    end

    {:noreply, push_navigate(socket, to: ~p"/devices/#{socket.assigns.device_uid}")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="flex h-[calc(100vh-4rem)] min-h-[560px] flex-col bg-base-100">
        <div class="flex min-h-14 items-center gap-3 border-b border-base-300 px-4">
          <.link navigate={~p"/devices/#{@device_uid}"} class="btn btn-ghost btn-sm">
            <.icon name="hero-arrow-left" class="size-4" /> Device
          </.link>
          <div class="min-w-0 flex-1">
            <h1 class="truncate text-sm font-semibold">Proxmox console</h1>
            <p class="truncate text-xs text-base-content/60">{@device_uid}</p>
          </div>
          <button
            :if={@session}
            type="button"
            class="btn btn-outline btn-sm"
            phx-click="close_console"
          >
            <.icon name="hero-x-mark" class="size-4" /> Close
          </button>
        </div>

        <div
          :if={@loading}
          class="flex min-h-0 flex-1 items-center justify-center text-sm text-base-content/60"
        >
          Preparing console session...
        </div>

        <div :if={@console_error} class="flex min-h-0 flex-1 items-center justify-center p-6">
          <div class="max-w-xl rounded border border-error/30 bg-error/10 p-4 text-sm text-error">
            {@console_error}
          </div>
        </div>

        <div
          :if={@session && @ticket && @websocket_path}
          id={"proxmox-console-terminal-#{@session.id}"}
          class="min-h-0 flex-1"
          phx-hook="ProxmoxConsoleTerminal"
          phx-update="ignore"
          data-session-id={@session.id}
          data-ticket={@ticket}
          data-websocket-path={@websocket_path}
          data-title={"#{format_target_kind(@session.target_kind)} console"}
          data-subtitle={"#{format_console_mode(@session.console_mode)} via #{@session.agent_id}"}
        >
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp open_console(socket) do
    if RBAC.can?(socket.assigns.current_scope, @console_permission) do
      request = %{cols: @default_cols, rows: @default_rows}

      case ProxmoxConsoleSessions.request_open(socket.assigns.device_uid, request, scope: socket.assigns.current_scope) do
        {:ok, %{session: %ProxmoxConsoleSession{} = session, ticket: ticket}} ->
          socket
          |> assign(:session, session)
          |> assign(:ticket, ticket)
          |> assign(:websocket_path, websocket_path(session))
          |> assign(:loading, false)
          |> assign(:console_error, nil)

        {:error, reason} ->
          socket
          |> assign(:loading, false)
          |> assign(:console_error, format_error(reason))
      end
    else
      socket
      |> assign(:loading, false)
      |> assign(:console_error, "You do not have permission to open Proxmox consoles.")
    end
  end

  defp websocket_path(%ProxmoxConsoleSession{id: id}), do: "/v1/proxmox/console-sessions/#{id}/stream"

  defp format_target_kind(value) when is_atom(value), do: value |> Atom.to_string() |> format_target_kind()

  defp format_target_kind("pve_host"), do: "PVE host"
  defp format_target_kind("qemu_guest"), do: "QEMU guest"
  defp format_target_kind("lxc_guest"), do: "LXC guest"
  defp format_target_kind(value) when is_binary(value), do: value
  defp format_target_kind(_value), do: "Proxmox"

  defp format_console_mode(value) when is_atom(value), do: value |> Atom.to_string() |> format_console_mode()
  defp format_console_mode("proxmox_termproxy"), do: "termproxy"
  defp format_console_mode("proxmox_vncwebsocket"), do: "VNC websocket"
  defp format_console_mode(value) when is_binary(value), do: value
  defp format_console_mode(_value), do: "console"

  defp format_error(:unsupported_console_target),
    do: "This device is not currently recognized as a Proxmox host, VM, or LXC target."

  defp format_error(:unsupported_console_mode), do: "The requested Proxmox console mode is not supported for this target."
  defp format_error(:no_console_credential_rule), do: "No scoped Proxmox console credential rule matched this device."

  defp format_error(:credential_rule_scope_denied),
    do: "The selected Proxmox credential rule does not allow this device scope."

  defp format_error(:credential_rule_target_denied),
    do: "The selected Proxmox credential rule SRQL does not match this device."

  defp format_error(:missing_agent_scope), do: "The Proxmox console credential rule must be scoped to an agent."
  defp format_error(:device_not_found), do: "The console target device was not found."
  defp format_error(%Ash.Error.Forbidden{}), do: "You do not have permission to open this Proxmox console."
  defp format_error(_reason), do: "Unable to prepare the Proxmox console session."
end
