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
      <div class="flex items-center justify-center h-full text-base-content/50">
        <span class="loading loading-spinner loading-lg"></span>
        <span class="ml-3">Loading decision editor...</span>
      </div>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :device_uid, :string, required: true
  attr :create_path, :string, default: "/api/remote-access/sessions"
  attr :title, :string, default: "SSH remote access"
  attr :allow_remembered_keys, :boolean, default: false
  attr :allow_skip_verify_host_key_policy, :boolean, default: false
  attr :allow_target_host_override, :boolean, default: false
  attr :allow_target_port_override, :boolean, default: false
  attr :approval_id, :string, default: ""
  attr :class, :string, default: ""

  def remote_access_ssh_console(assigns) do
    assigns =
      assign(assigns, :props, %{
        deviceUid: assigns.device_uid,
        createPath: assigns.create_path,
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
      <div class="flex h-full min-h-[320px] items-center justify-center text-sm text-base-content/60">
        <span class="loading loading-spinner loading-sm"></span>
        <span class="ml-3">Loading SSH console...</span>
      </div>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :session, :map, required: true
  attr :title, :string, default: "RDP remote access"
  attr :class, :string, default: ""

  def remote_access_desktop_session(assigns) do
    assigns =
      assign(assigns, :props, %{
        session: assigns.session,
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
      <div class="flex h-full min-h-[420px] items-center justify-center text-sm text-base-content/60">
        <span class="loading loading-spinner loading-sm"></span>
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
      <div class="flex h-full min-h-[320px] items-center justify-center text-sm text-base-content/60">
        <span class="loading loading-spinner loading-sm"></span>
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
      <div class="flex h-full min-h-[320px] items-center justify-center text-sm text-base-content/60">
        <span class="loading loading-spinner loading-sm"></span>
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
      assigns
      |> assign(:props, %{
        sessionId: assigns.session_id,
        ticket: assigns.ticket,
        websocketPath: assigns.websocket_path,
        title: assigns.title,
        subtitle: assigns.subtitle
      })
      |> assign(:render_props, %{
        sessionId: assigns.session_id,
        ticket: "",
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
      {react_component(%{
        component: "RemoteConsoleTerminal",
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
  attr :title, :string, default: "Proxmox console"
  attr :subtitle, :string, default: ""
  attr :class, :string, default: ""

  def proxmox_console_terminal(assigns), do: remote_console_terminal(assigns)
end
