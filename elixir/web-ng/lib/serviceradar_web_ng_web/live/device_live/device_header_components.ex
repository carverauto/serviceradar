defmodule ServiceRadarWebNGWeb.DeviceLive.DeviceHeaderComponents do
  @moduledoc false

  use ServiceRadarWebNGWeb, :html

  attr(:active_tab, :string, required: true)
  attr(:device_uid, :string, required: true)
  attr(:device_display_name, :string, required: true)
  attr(:agent_device, :boolean, default: false)
  attr(:device_deleted, :boolean, default: false)
  attr(:device_active, :any, default: nil)
  attr(:device_ansible_managed, :boolean, default: false)
  attr(:can_run_ansible, :boolean, default: false)
  attr(:can_console, :boolean, default: false)
  attr(:can_remote_access, :boolean, default: false)
  attr(:can_remote_access_app, :boolean, default: false)
  attr(:can_manage_rdp_targets, :boolean, default: false)
  attr(:can_edit, :boolean, default: false)
  attr(:can_manage, :boolean, default: false)
  attr(:editing, :boolean, default: false)
  attr(:proxmox_console_target, :boolean, default: false)
  attr(:proxmox_console_path, :string, default: nil)
  attr(:proxmox_console_action_label, :string, default: "Open console")
  attr(:rdp_launch_path, :string, default: nil)
  attr(:rdp_enable_path, :string, default: nil)
  attr(:devices_return_path, :string, default: "/devices")

  def device_show_header(assigns) do
    ~H"""
    <%!-- Breadcrumb --%>
    <nav class="text-sm  mb-4">
      <ul>
        <li><.link navigate={@devices_return_path}>Devices</.link></li>
        <li :if={@active_tab == "details"}>
          <span class="text-sr-muted">{@device_display_name}</span>
        </li>
        <li :if={@active_tab != "details"}>
          <.link navigate={~p"/devices/#{@device_uid}"}>{@device_display_name}</.link>
        </li>
        <li :if={@active_tab == "interfaces"} class="text-sr-muted">Interfaces</li>
        <li :if={@active_tab == "software"} class="text-sr-muted">Software</li>
        <li :if={@active_tab == "flows"} class="text-sr-muted">Flows</li>
        <li :if={@active_tab == "logs"} class="text-sr-muted">Logs</li>
        <li :if={@active_tab == "profiles"} class="text-sr-muted">Profiles</li>
        <li :if={@active_tab == "active-fingerprint"} class="text-sr-muted">
          Active Fingerprint
        </li>
        <li :if={@active_tab == "process-listeners"} class="text-sr-muted">
          Process Listeners
        </li>
        <li :if={@active_tab == "sysmon"} class="text-sr-muted">System Monitor</li>
        <li :if={@active_tab == "mtr"} class="text-sr-muted">MTR Diagnostics</li>
      </ul>
    </nav>

    <.header>
      Device
      <:subtitle>
        <span class="flex items-center gap-2">
          <span class="font-mono text-xs">{@device_uid}</span>
          <span
            :if={@agent_device}
            data-testid="device-agent-pill"
            class="inline-flex items-center gap-1 rounded-full bg-amber-400/15 px-2 py-0.5 text-[11px] font-semibold text-amber-400"
          >
            <.icon name="hero-bolt" class="size-3 text-amber-400" /> Agent
          </span>
          <span
            :if={@device_deleted}
            class="inline-flex items-center gap-1 rounded-full bg-sr-subtle px-2 py-0.5 text-[11px] font-semibold text-sr-muted"
          >
            <.icon name="hero-archive-box" class="size-3" /> Deleted
          </span>
          <span
            :if={@device_active == false}
            class="inline-flex items-center gap-1 rounded-full bg-warning/15 px-2 py-0.5 text-[11px] font-semibold text-warning"
          >
            <.icon name="hero-pause-circle" class="size-3" /> Out of service
          </span>
        </span>
      </:subtitle>
      <:actions>
        <.ui_button
          :if={@can_run_ansible and not @device_deleted and @device_ansible_managed}
          href={~p"/ansible/launch?devices=#{@device_uid}"}
          variant="primary"
          size="sm"
        >
          <.icon name="hero-play" class="size-4" /> Launch Playbook
        </.ui_button>
        <.ui_button
          :if={
            @can_console and not @device_deleted and
              @proxmox_console_target
          }
          href={@proxmox_console_path}
          variant="outline"
          size="sm"
        >
          <.icon name="hero-command-line" class="size-4" />
          {@proxmox_console_action_label}
        </.ui_button>
        <.ui_button
          :if={@can_remote_access and not @device_deleted}
          href={~p"/devices/#{@device_uid}/remote-access/ssh"}
          variant="outline"
          size="sm"
        >
          <.icon name="hero-key" class="size-4" /> SSH
        </.ui_button>
        <.ui_button
          :if={@can_remote_access_app and not @device_deleted}
          href={~p"/remote-access/targets"}
          variant="outline"
          size="sm"
        >
          <.icon name="hero-window" class="size-4" /> Apps
        </.ui_button>
        <.ui_button
          :if={not is_nil(@rdp_launch_path) and not @device_deleted}
          id="device-rdp-launch-action"
          href={@rdp_launch_path}
          variant="outline"
          size="sm"
        >
          <.icon name="hero-computer-desktop" class="size-4" /> RDP
        </.ui_button>
        <.ui_button
          :if={is_nil(@rdp_launch_path) and @can_manage_rdp_targets and not @device_deleted}
          id="device-rdp-enable-action"
          href={@rdp_enable_path}
          variant="outline"
          size="sm"
        >
          <.icon name="hero-computer-desktop" class="size-4" /> Enable RDP
        </.ui_button>
        <.ui_button
          :if={@can_edit and not @editing}
          phx-click="toggle_edit"
          variant="outline"
          size="sm"
        >
          <.icon name="hero-pencil" class="size-4" /> Edit
        </.ui_button>
        <.ui_button
          :if={@can_manage and @device_deleted}
          phx-click="restore_device"
          variant="outline"
          size="sm"
          phx-confirm="Restore this device to the active inventory?"
        >
          <.icon name="hero-arrow-path" class="size-4" /> Restore
        </.ui_button>
        <.ui_button
          :if={@can_manage and not @device_deleted and @device_active == false}
          phx-click="mark_device_active"
          variant="outline"
          size="sm"
          phx-confirm="Return this device to service?"
        >
          <.icon name="hero-play-circle" class="size-4" /> In service
        </.ui_button>
        <.ui_button
          :if={@can_manage and not @device_deleted and @device_active != false}
          phx-click="mark_device_inactive"
          variant="outline"
          size="sm"
          phx-confirm="Mark this device out of service? Operational events and alerts for it will be suppressed."
        >
          <.icon name="hero-pause-circle" class="size-4" /> Out of service
        </.ui_button>
        <.ui_button
          :if={@can_manage and not @device_deleted}
          phx-click="delete_device"
          variant="danger"
          size="sm"
          phx-confirm="Delete this device? It will be hidden from inventory but can be restored later."
        >
          <.icon name="hero-trash" class="size-4" /> Delete
        </.ui_button>
        <.ui_button navigate={@devices_return_path} variant="ghost" size="sm">
          Back to devices
        </.ui_button>
      </:actions>
    </.header>
    """
  end
end
