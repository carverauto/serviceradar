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
