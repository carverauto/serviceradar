defmodule ServiceRadarWebNGWeb.ReactComponents do
  @moduledoc """
  Phoenix components for rendering React components.

  This module provides helper functions for client-side React components
  like the GoRules JDM editor. Components are rendered on the client
  via LiveView hooks due to complex browser dependencies.

  ## Usage

      <.jdm_editor
        id="my-editor"
        definition={@rule.jdm_definition}
        read_only={!@can_edit}
      />

  """
  use Phoenix.Component

  import Phoenix.ReactServer.Helper
  import ServiceRadarWebNGWeb.UIComponents, only: [ui_spinner: 1]

  @doc """
  Renders the GoRules JDM editor for Zen rule definitions.

  The editor uses ReactFlow, Monaco Editor, and other browser-dependent libraries,
  so it's rendered entirely on the client via a LiveView hook.

  ## Attributes

  * `:id` - Required. Unique identifier for the editor container (used for hydration)
  * `:definition` - The JDM JSON definition to edit (map or nil for empty)
  * `:read_only` - If true, the editor is read-only (default: false)
  * `:class` - Additional CSS classes for the container

  ## Examples

      <.jdm_editor
        id="zen-rule-editor"
        definition={@rule.jdm_definition}
        read_only={false}
      />

  """
  attr :id, :string, required: true
  attr :panels, :list, default: []
  attr :visual_options, :list, default: []
  attr :selected_id, :string, default: ""
  attr :can_manage, :boolean, default: false
  attr :timezone, :string, default: "Etc/UTC"
  attr :class, :string, default: ""

  def dashboard_builder_canvas(assigns) do
    assigns =
      assign(assigns, :props, %{
        panels: assigns.panels,
        visualOptions: assigns.visual_options,
        selectedId: assigns.selected_id,
        canManage: assigns.can_manage,
        timezone: assigns.timezone || "Etc/UTC"
      })

    ~H"""
    <div
      id={@id}
      class={["min-h-[520px] w-full", @class]}
      phx-update="ignore"
      phx-hook="DashboardBuilderCanvas"
      data-props={Jason.encode!(@props)}
    >
      <div class="flex min-h-[520px] items-center justify-center rounded-lg border border-dashed border-sr-line text-sm text-sr-muted">
        <.ui_spinner size="sm" />
        <span class="ml-3">Loading dashboard canvas...</span>
      </div>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :panel, :map, required: true
  attr :rows, :list, default: []
  attr :fields, :list, default: []
  attr :trend, :map, default: nil
  attr :timezone, :string, default: "Etc/UTC"
  attr :class, :string, default: ""

  def dashboard_panel_chart(assigns) do
    assigns =
      assign(assigns, :props, %{
        panel: dashboard_panel_chart_props(assigns.panel),
        rows: assigns.rows,
        fields: assigns.fields,
        trend: assigns.trend,
        timezone: assigns.timezone || "Etc/UTC"
      })

    ~H"""
    <div
      id={@id}
      class={["h-full min-h-0 w-full", @class]}
      phx-update="ignore"
      phx-hook="DashboardPanelChart"
      data-props={Jason.encode!(@props)}
    >
      <div class="flex h-full min-h-24 items-center justify-center rounded-lg border border-dashed border-sr-line text-sm text-sr-muted">
        <.ui_spinner size="sm" />
        <span class="ml-3">Loading chart...</span>
      </div>
    </div>
    """
  end

  defp dashboard_panel_chart_props(panel) do
    %{
      id: panel.id,
      title: panel.title,
      srql_query: Map.get(panel, :srql_query) || Map.get(panel, "srql_query"),
      visual_type: panel.visual_type,
      data_binding: panel.data_binding || %{},
      display_config: panel.display_config || %{},
      visual_config: panel.visual_config || %{}
    }
  end

  attr :id, :string, required: true
  attr :definition, :map, default: nil
  attr :read_only, :boolean, default: false
  attr :class, :string, default: ""

  def jdm_editor(assigns) do
    assigns =
      assign(assigns, :props, %{
        definition: assigns[:definition],
        readOnly: assigns[:read_only]
      })

    ~H"""
    <div
      id={@id}
      class={["jdm-editor-container h-full w-full", @class]}
      phx-update="ignore"
      phx-hook="JdmEditorHook"
      data-props={Jason.encode!(@props)}
    >
      <div class="flex items-center justify-center h-full text-sr-muted">
        <.ui_spinner size="lg" />
        <span class="ml-3">Loading decision editor...</span>
      </div>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :device_uid, :string, required: true
  attr :create_path, :string, default: "/api/remote-access/sessions"
  attr :ssh_options_path, :string, default: nil
  attr :title, :string, default: "SSH remote access"
  attr :allow_remembered_keys, :boolean, default: false
  attr :allow_skip_verify_host_key_policy, :boolean, default: false
  attr :allow_target_host_override, :boolean, default: false
  attr :allow_target_port_override, :boolean, default: false
  attr :approval_id, :string, default: ""
  attr :class, :string, default: ""

  def remote_access_ssh_console(assigns) do
    ssh_options_path =
      assigns.ssh_options_path || default_ssh_options_path(assigns.device_uid)

    assigns =
      assign(assigns, :props, %{
        deviceUid: assigns.device_uid,
        createPath: assigns.create_path,
        sshOptionsPath: ssh_options_path,
        approvalId: assigns.approval_id,
        title: assigns.title,
        allowRememberedKeys: assigns.allow_remembered_keys,
        allowSkipVerifyHostKeyPolicy: assigns.allow_skip_verify_host_key_policy,
        allowTargetHostOverride: assigns.allow_target_host_override,
        allowTargetPortOverride: assigns.allow_target_port_override
      })

    ~H"""
    <div
      id={@id}
      class={["h-full min-h-0 w-full", @class]}
      phx-update="ignore"
      phx-hook="RemoteAccessSSHConsole"
      data-props={Jason.encode!(@props)}
    >
      <div class="flex h-full min-h-[320px] items-center justify-center text-sm text-sr-muted">
        <.ui_spinner size="sm" />
        <span class="ml-3">Loading SSH console...</span>
      </div>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :session, :map, default: nil
  attr :desktop_target_id, :string, default: ""
  attr :device_uid, :string, default: ""
  attr :approval_id, :string, default: ""
  attr :create_path, :string, default: "/api/remote-access/sessions"
  attr :title, :string, default: "RDP remote access"
  attr :class, :string, default: ""

  def remote_access_desktop_session(assigns) do
    assigns =
      assign(assigns, :props, %{
        session: assigns.session,
        desktopTargetId: assigns.desktop_target_id,
        deviceUid: assigns.device_uid,
        approvalId: assigns.approval_id,
        createPath: assigns.create_path,
        title: assigns.title
      })

    ~H"""
    <div
      id={@id}
      class={["h-full min-h-0 w-full", @class]}
      phx-update="ignore"
      phx-hook="RemoteAccessDesktopSession"
      data-props={Jason.encode!(@props)}
    >
      <div class="flex h-full min-h-[420px] items-center justify-center text-sm text-sr-muted">
        <.ui_spinner size="sm" />
        <span class="ml-3">Loading RDP session...</span>
      </div>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :target_id, :string, required: true
  attr :create_path, :string, default: "/api/remote-access/app-sessions"
  attr :title, :string, default: "Application access"
  attr :class, :string, default: ""

  def remote_access_application(assigns) do
    assigns =
      assign(assigns, :props, %{
        targetId: assigns.target_id,
        createPath: assigns.create_path,
        title: assigns.title
      })

    ~H"""
    <div
      id={@id}
      class={["h-full min-h-0 w-full", @class]}
      phx-update="ignore"
      phx-hook="RemoteAccessApplication"
      data-props={Jason.encode!(@props)}
    >
      <div class="flex h-full min-h-[320px] items-center justify-center text-sm text-sr-muted">
        <.ui_spinner size="sm" />
        <span class="ml-3">Loading application access...</span>
      </div>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :target_id, :string, required: true
  attr :create_path, :string, default: "/api/remote-access/tcp-sessions"
  attr :title, :string, default: "TCP remote access"
  attr :workflow, :string, default: ""
  attr :class, :string, default: ""

  def remote_access_tcp_text(assigns) do
    assigns =
      assign(assigns, :props, %{
        targetId: assigns.target_id,
        createPath: assigns.create_path,
        title: assigns.title,
        workflow: assigns.workflow
      })

    ~H"""
    <div
      id={@id}
      class={["h-full min-h-0 w-full", @class]}
      phx-update="ignore"
      phx-hook="RemoteAccessTCPText"
      data-props={Jason.encode!(@props)}
    >
      <div class="flex h-full min-h-[320px] items-center justify-center text-sm text-sr-muted">
        <.ui_spinner size="sm" />
        <span class="ml-3">Loading TCP access...</span>
      </div>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :session_id, :string, required: true
  attr :ticket, :string, required: true
  attr :websocket_path, :string, required: true
  attr :title, :string, default: "Remote access"
  attr :subtitle, :string, default: ""
  attr :stream_label, :string, default: "Remote access"
  attr :close_label, :string, default: "Remote access session"
  attr :class, :string, default: ""

  def remote_access_terminal(assigns) do
    assigns =
      assigns
      |> assign(:props, %{
        sessionId: assigns.session_id,
        ticket: assigns.ticket,
        websocketPath: assigns.websocket_path,
        title: assigns.title,
        subtitle: assigns.subtitle,
        streamLabel: assigns.stream_label,
        closeLabel: assigns.close_label
      })
      |> assign(:render_props, %{
        sessionId: assigns.session_id,
        ticket: "",
        websocketPath: assigns.websocket_path,
        title: assigns.title,
        subtitle: assigns.subtitle,
        streamLabel: assigns.stream_label,
        closeLabel: assigns.close_label
      })

    ~H"""
    <div
      id={@id}
      class={["h-full min-h-0 w-full", @class]}
      phx-update="ignore"
      phx-hook="RemoteAccessTerminal"
      data-props={Jason.encode!(@props)}
    >
      {react_component(%{
        component: "RemoteAccessTerminal",
        props: @render_props,
        static: false
      })}
    </div>
    """
  end

  attr :id, :string, required: true
  attr :session_id, :string, required: true
  attr :ticket, :string, required: true
  attr :websocket_path, :string, required: true
  attr :title, :string, default: "Remote console"
  attr :subtitle, :string, default: ""
  attr :class, :string, default: ""

  def remote_console_terminal(assigns) do
    assigns =
      assign(assigns, :props, %{
        sessionId: assigns.session_id,
        ticket: assigns.ticket,
        websocketPath: assigns.websocket_path,
        title: assigns.title,
        subtitle: assigns.subtitle
      })

    ~H"""
    <div
      id={@id}
      class={["h-full min-h-0 w-full", @class]}
      phx-update="ignore"
      phx-hook="RemoteConsoleTerminal"
      data-props={Jason.encode!(@props)}
    >
      <div class="flex h-full min-h-[320px] items-center justify-center text-sm text-sr-muted">
        <.ui_spinner size="sm" />
        <span class="ml-3">Loading remote console...</span>
      </div>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :session_id, :string, required: true
  attr :ticket, :string, required: true
  attr :websocket_path, :string, required: true
  attr :title, :string, default: "Proxmox console"
  attr :subtitle, :string, default: ""
  attr :class, :string, default: ""

  def proxmox_console_terminal(assigns), do: remote_console_terminal(assigns)

  defp default_ssh_options_path(device_uid) when is_binary(device_uid) do
    "/api/remote-access/devices/#{URI.encode(device_uid, &URI.char_unreserved?/1)}/ssh-options"
  end
end
