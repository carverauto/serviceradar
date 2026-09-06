defmodule ServiceRadarWebNGWeb.ProxmoxConsoleLive.Show do
  @moduledoc false
  use ServiceRadarWebNGWeb, :live_view

  alias ServiceRadar.Edge.ProxmoxConsoleSession
  alias ServiceRadar.Edge.ProxmoxConsoleSessions
  alias ServiceRadarWebNG.RBAC

  @console_permissions ["devices.console.open", "devices.console.credentials.use"]
  @default_cols 120
  @default_rows 34

  @impl true
  def mount(%{"uid" => device_uid}, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "Remote Console")
      |> assign(:device_uid, device_uid)
      |> assign(:console_request, %{})
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
    if can_use_console?(socket.assigns.current_scope) do
      case socket.assigns.session do
        %ProxmoxConsoleSession{id: id} ->
          _ =
            console_session_manager().request_close(id,
              reason: "operator_closed",
              scope: socket.assigns.current_scope
            )

        _session ->
          :ok
      end
    end

    {:noreply, push_navigate(socket, to: ~p"/devices/#{socket.assigns.device_uid}")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="flex h-[calc(100vh-4rem)] min-h-[560px] flex-col bg-sr-surface">
        <div class="flex min-h-14 items-center gap-3 border-b border-sr-line px-4">
          <.ui_button navigate={~p"/devices/#{@device_uid}"} size="sm" variant="ghost">
            <.icon name="hero-arrow-left" class="size-4" /> Device
          </.ui_button>
          <div class="min-w-0 flex-1">
            <h1 class="truncate text-sm font-semibold">Remote console</h1>
            <p class="truncate text-xs text-sr-muted">{@device_uid}</p>
          </div>
          <.ui_button
            :if={@session}
            type="button"
            phx-click="close_console"
            size="sm"
            variant="outline"
          >
            <.icon name="hero-x-mark" class="size-4" /> Close
          </.ui_button>
        </div>

        <div
          :if={@loading}
          class="flex min-h-0 flex-1 items-center justify-center text-sm text-sr-muted"
        >
          Preparing console session...
        </div>

        <div :if={@console_error} class="flex min-h-0 flex-1 items-center justify-center p-6">
          <div class="max-w-xl rounded border border-error/30 bg-error/10 p-4 text-sm text-error">
            {@console_error}
          </div>
        </div>

        <.remote_console_terminal
          :if={@session && @ticket && @websocket_path}
          id={"remote-console-terminal-#{@session.id}"}
          class="min-h-0 flex-1"
          session_id={@session.id}
          ticket={@ticket}
          websocket_path={@websocket_path}
          title={"#{format_target_kind(@session.target_kind)} console"}
          subtitle={"#{format_console_mode(@session.console_mode)} via #{@session.agent_id}"}
        />
      </div>
    </Layouts.app>
    """
  end

  defp open_console(socket) do
    if can_use_console?(socket.assigns.current_scope) do
      request = Map.merge(%{cols: @default_cols, rows: @default_rows}, socket.assigns.console_request)
      scope = socket.assigns.current_scope
      device_uid = socket.assigns.device_uid

      case console_session_manager().request_open(device_uid, request, scope: scope) do
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
      |> assign(:console_error, "You do not have permission to open remote consoles.")
    end
  end

  defp websocket_path(%ProxmoxConsoleSession{id: id}), do: "/v1/proxmox/console-sessions/#{id}/stream"

  defp console_session_manager do
    Application.get_env(
      :serviceradar_web_ng,
      :proxmox_console_session_manager,
      ProxmoxConsoleSessions
    )
  end

  defp can_use_console?(scope), do: Enum.all?(@console_permissions, &RBAC.can?(scope, &1))

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

  defp format_error(:proxmox_tls_verification_required),
    do: "The matching Proxmox credential rule must verify TLS to open a native console."

  defp format_error(:unsupported_console_mode), do: "The requested console mode is not supported for this target."
  defp format_error(:no_console_credential_rule), do: "No scoped console credential rule matched this device."

  defp format_error(:credential_rule_scope_denied),
    do: "The selected Proxmox credential rule does not allow this device scope."

  defp format_error(:credential_rule_target_denied),
    do: "The selected Proxmox credential rule SRQL does not match this device."

  defp format_error(:ambiguous_console_target), do: "The device matches more than one Proxmox cluster identity."

  defp format_error(:console_inventory_unavailable),
    do: "Authoritative Proxmox console inventory is currently unavailable."

  defp format_error(:console_controller_not_found), do: "The owning Proxmox controller could not be resolved."

  defp format_error(:console_controller_endpoint_missing),
    do: "The owning Proxmox controller has no usable management endpoint."

  defp format_error(reason) when reason in [:controller_origin_mismatch, :invalid_controller_origin],
    do: "The owning Proxmox controller origin is invalid for its authoritative endpoint."

  defp format_error(reason) when reason in [:console_assignment_unavailable, :ambiguous_console_assignment],
    do: "No unique active Proxmox console assignment is available on the owning edge agent."

  defp format_error(reason)
       when reason in [:credential_use_policy_missing, :credential_use_policy_invalid, :credential_use_policy_denied],
       do: "The console credential policy does not authorize this user."

  defp format_error(:missing_agent_scope), do: "The console credential rule must be scoped to an agent."
  defp format_error(:device_not_found), do: "The console target device was not found."
  defp format_error(%Ash.Error.Forbidden{}), do: "You do not have permission to open this remote console."
  defp format_error(_reason), do: "Unable to prepare the remote console session."
end
