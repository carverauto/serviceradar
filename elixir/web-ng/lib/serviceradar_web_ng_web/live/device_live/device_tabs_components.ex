defmodule ServiceRadarWebNGWeb.DeviceLive.DeviceTabsComponents do
  @moduledoc false

  use ServiceRadarWebNGWeb, :html

  attr(:device_row, :map, default: nil)
  attr(:active_tab, :string, required: true)
  attr(:software_tab_visible, :boolean, default: false)
  attr(:has_virtualization_guests, :boolean, default: false)
  attr(:has_ifaces, :boolean, default: false)
  attr(:has_flows, :boolean, default: false)
  attr(:details_loading, :boolean, default: false)
  attr(:interface_availability, :atom, default: :unavailable)
  attr(:flow_availability, :atom, default: :unavailable)
  attr(:has_logs, :boolean, default: false)
  attr(:sysmon_presence, :boolean, default: false)
  attr(:active_fingerprint_tab_visible, :boolean, default: false)
  attr(:process_listeners_tab_visible, :boolean, default: false)
  attr(:has_mtr, :boolean, default: false)

  def device_tabs(assigns) do
    ~H"""
    <div
      :if={is_map(@device_row)}
      class="sr-ui-tabs sr-ui-tabs-boxed"
    >
      <button
        type="button"
        phx-click="switch_tab"
        phx-value-tab="details"
        class={["sr-ui-tab", @active_tab == "details" && "sr-ui-tab-active"]}
      >
        <.icon name="hero-document-text" class="size-4 mr-1.5" /> Details
      </button>
      <button
        :if={@software_tab_visible}
        type="button"
        phx-click="switch_tab"
        phx-value-tab="software"
        class={["sr-ui-tab", @active_tab == "software" && "sr-ui-tab-active"]}
      >
        <.icon name="hero-cube" class="size-4 mr-1.5" /> Software
      </button>
      <button
        :if={@has_virtualization_guests}
        type="button"
        phx-click="switch_tab"
        phx-value-tab="guests"
        class={["sr-ui-tab", @active_tab == "guests" && "sr-ui-tab-active"]}
      >
        <.icon name="hero-squares-2x2" class="size-4 mr-1.5" /> Guests
      </button>
      <button
        :if={@has_ifaces or @details_loading}
        type="button"
        phx-click="switch_tab"
        phx-value-tab="interfaces"
        disabled={!@has_ifaces}
        title={availability_title("Interfaces", @interface_availability, @details_loading)}
        class={[
          "tab",
          @active_tab == "interfaces" && "sr-ui-tab-active",
          !@has_ifaces && "opacity-60"
        ]}
      >
        <.ui_spinner :if={!@has_ifaces} size="xs" class="mr-1.5" />
        <.icon :if={@has_ifaces} name="hero-server-stack" class="size-4 mr-1.5" /> Interfaces
      </button>
      <button
        :if={@has_flows or @details_loading}
        type="button"
        phx-click="switch_tab"
        phx-value-tab="flows"
        disabled={!@has_flows}
        title={availability_title("Flows", @flow_availability, @details_loading)}
        class={[
          "tab",
          @active_tab == "flows" && "sr-ui-tab-active",
          !@has_flows && "opacity-60"
        ]}
      >
        <.ui_spinner :if={!@has_flows} size="xs" class="mr-1.5" />
        <.icon :if={@has_flows} name="hero-arrows-right-left" class="size-4 mr-1.5" /> Flows
      </button>
      <button
        :if={@has_logs}
        type="button"
        phx-click="switch_tab"
        phx-value-tab="logs"
        class={["sr-ui-tab", @active_tab == "logs" && "sr-ui-tab-active"]}
      >
        <.icon name="hero-clipboard-document-list" class="size-4 mr-1.5" /> Logs
      </button>
      <button
        :if={@sysmon_presence}
        type="button"
        phx-click="switch_tab"
        phx-value-tab="profiles"
        class={["sr-ui-tab", @active_tab == "profiles" && "sr-ui-tab-active"]}
      >
        <.icon name="hero-cog-6-tooth" class="size-4 mr-1.5" /> Profiles
      </button>
      <button
        :if={@active_fingerprint_tab_visible}
        type="button"
        phx-click="switch_tab"
        phx-value-tab="active-fingerprint"
        class={["sr-ui-tab", @active_tab == "active-fingerprint" && "sr-ui-tab-active"]}
      >
        <.icon name="hero-finger-print" class="size-4 mr-1.5" /> Active Fingerprint
      </button>
      <button
        :if={@process_listeners_tab_visible}
        type="button"
        phx-click="switch_tab"
        phx-value-tab="process-listeners"
        class={["sr-ui-tab", @active_tab == "process-listeners" && "sr-ui-tab-active"]}
      >
        <.icon name="hero-command-line" class="size-4 mr-1.5" /> Process Listeners
      </button>
      <button
        :if={@has_mtr}
        type="button"
        phx-click="switch_tab"
        phx-value-tab="mtr"
        class={["sr-ui-tab", @active_tab == "mtr" && "sr-ui-tab-active"]}
      >
        <.icon name="hero-signal" class="size-4 mr-1.5" /> MTR
      </button>
    </div>
    """
  end

  defp availability_title(label, _availability, true), do: "Checking #{availability_subject(label)} availability"

  defp availability_title(label, :unknown, false) do
    "#{String.capitalize(availability_subject(label))} availability was inconclusive; open to retry"
  end

  defp availability_title(label, _availability, false), do: "Open #{String.downcase(label)}"

  defp availability_subject("Interfaces"), do: "interface"
  defp availability_subject(label), do: String.downcase(label)
end
