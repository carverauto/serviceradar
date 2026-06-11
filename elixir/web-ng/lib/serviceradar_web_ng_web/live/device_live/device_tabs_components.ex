defmodule ServiceRadarWebNGWeb.DeviceLive.DeviceTabsComponents do
  @moduledoc false

  use ServiceRadarWebNGWeb, :html

  attr(:device_row, :map, default: nil)
  attr(:active_tab, :string, required: true)
  attr(:software_tab_visible, :boolean, default: false)
  attr(:has_virtualization_guests, :boolean, default: false)
  attr(:has_ifaces, :boolean, default: false)
  attr(:has_flows, :boolean, default: false)
  attr(:has_logs, :boolean, default: false)
  attr(:sysmon_presence, :boolean, default: false)
  attr(:active_fingerprint_tab_visible, :boolean, default: false)
  attr(:process_listeners_tab_visible, :boolean, default: false)
  attr(:has_mtr, :boolean, default: false)

  def device_tabs(assigns) do
    ~H"""
    <div
      :if={is_map(@device_row)}
      class="tabs tabs-box"
    >
      <button
        type="button"
        phx-click="switch_tab"
        phx-value-tab="details"
        class={["tab", @active_tab == "details" && "tab-active"]}
      >
        <.icon name="hero-document-text" class="size-4 mr-1.5" /> Details
      </button>
      <button
        :if={@software_tab_visible}
        type="button"
        phx-click="switch_tab"
        phx-value-tab="software"
        class={["tab", @active_tab == "software" && "tab-active"]}
      >
        <.icon name="hero-cube" class="size-4 mr-1.5" /> Software
      </button>
      <button
        :if={@has_virtualization_guests}
        type="button"
        phx-click="switch_tab"
        phx-value-tab="guests"
        class={["tab", @active_tab == "guests" && "tab-active"]}
      >
        <.icon name="hero-squares-2x2" class="size-4 mr-1.5" /> Guests
      </button>
      <button
        :if={@has_ifaces}
        type="button"
        phx-click="switch_tab"
        phx-value-tab="interfaces"
        class={["tab", @active_tab == "interfaces" && "tab-active"]}
      >
        <.icon name="hero-server-stack" class="size-4 mr-1.5" /> Interfaces
      </button>
      <button
        :if={@has_flows}
        type="button"
        phx-click="switch_tab"
        phx-value-tab="flows"
        class={["tab", @active_tab == "flows" && "tab-active"]}
      >
        <.icon name="hero-arrows-right-left" class="size-4 mr-1.5" /> Flows
      </button>
      <button
        :if={@has_logs}
        type="button"
        phx-click="switch_tab"
        phx-value-tab="logs"
        class={["tab", @active_tab == "logs" && "tab-active"]}
      >
        <.icon name="hero-clipboard-document-list" class="size-4 mr-1.5" /> Logs
      </button>
      <button
        :if={@sysmon_presence}
        type="button"
        phx-click="switch_tab"
        phx-value-tab="profiles"
        class={["tab", @active_tab == "profiles" && "tab-active"]}
      >
        <.icon name="hero-cog-6-tooth" class="size-4 mr-1.5" /> Profiles
      </button>
      <button
        :if={@active_fingerprint_tab_visible}
        type="button"
        phx-click="switch_tab"
        phx-value-tab="active-fingerprint"
        class={["tab", @active_tab == "active-fingerprint" && "tab-active"]}
      >
        <.icon name="hero-finger-print" class="size-4 mr-1.5" /> Active Fingerprint
      </button>
      <button
        :if={@process_listeners_tab_visible}
        type="button"
        phx-click="switch_tab"
        phx-value-tab="process-listeners"
        class={["tab", @active_tab == "process-listeners" && "tab-active"]}
      >
        <.icon name="hero-command-line" class="size-4 mr-1.5" /> Process Listeners
      </button>
      <button
        :if={@has_mtr}
        type="button"
        phx-click="switch_tab"
        phx-value-tab="mtr"
        class={["tab", @active_tab == "mtr" && "tab-active"]}
      >
        <.icon name="hero-signal" class="size-4 mr-1.5" /> MTR
      </button>
    </div>
    """
  end
end
