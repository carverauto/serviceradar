defmodule ServiceRadarWebNGWeb.NetflowLive.Visualize.View.FlowModal.Endpoints do
  @moduledoc false
  use ServiceRadarWebNGWeb, :html

  import ServiceRadarWebNGWeb.NetflowLive.Visualize.FlowAccess
  import ServiceRadarWebNGWeb.NetflowLive.Visualize.Format, only: [iso2_flag_emoji: 1]

  alias ServiceRadarWebNGWeb.Components.PrefixTagChips

  attr(:flow, :map, required: true)
  attr(:context, :map, required: true)
  attr(:rdns_map, :map, default: %{})

  def render(assigns) do
    ~H"""
    <% src_geo = Map.get(@context, :src_geo) %>
    <% dst_geo = Map.get(@context, :dst_geo) %>
    <% attribution = flow_attribution(@flow) %>

    <.attribution_card attribution={attribution} />
    <.endpoint_card flow={@flow} context={@context} rdns_map={@rdns_map} side={:src} geo={src_geo} />
    <.endpoint_card flow={@flow} context={@context} rdns_map={@rdns_map} side={:dst} geo={dst_geo} />
    """
  end

  attr(:attribution, :map, required: true)

  def attribution_card(assigns) do
    ~H"""
    <div
      :if={Map.get(@attribution, :attributed?)}
      class="p-3 rounded-lg border border-success/25 bg-success/5 md:col-span-2"
    >
      <div class="flex flex-wrap items-center gap-2">
        <.ui_badge size="sm" variant="success">Attributed</.ui_badge>
        <span class="text-xs text-sr-muted">Agent</span>
        <span class="font-mono text-xs">{display_value(Map.get(@attribution, :agent_id))}</span>
        <span class="text-xs text-sr-muted">Process</span>
        <span class="font-mono text-xs">{display_value(Map.get(@attribution, :process_label))}</span>
        <span class="text-xs text-sr-muted">UID</span>
        <span class="font-mono text-xs">{display_value(Map.get(@attribution, :uid))}</span>
      </div>
      <div class="mt-2 grid gap-2 md:grid-cols-2">
        <div>
          <div class="text-[10px] uppercase tracking-wider text-sr-muted">Command</div>
          <div class="truncate font-mono text-xs" title={Map.get(@attribution, :cmdline)}>
            {display_value(Map.get(@attribution, :cmdline))}
          </div>
        </div>
        <div>
          <div class="text-[10px] uppercase tracking-wider text-sr-muted">Container</div>
          <div class="truncate font-mono text-xs" title={Map.get(@attribution, :container_id)}>
            {display_value(Map.get(@attribution, :container_id))}
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr(:flow, :map, required: true)
  attr(:context, :map, required: true)
  attr(:rdns_map, :map, default: %{})
  attr(:side, :atom, required: true)
  attr(:geo, :any, default: nil)

  def endpoint_card(assigns) do
    ocsf = flow_get(assigns.flow, ["ocsf_payload"]) || %{}
    prefix = to_string(assigns.side)
    label = if assigns.side == :src, do: "Source", else: "Destination"

    ip = flow_get(assigns.flow, ["#{prefix}_endpoint_ip", "#{prefix}_ip"])

    device_uid =
      case assigns.side do
        :src -> Map.get(assigns.context, :src_device_uid)
        :dst -> Map.get(assigns.context, :dst_device_uid)
      end

    cc =
      flow_get(assigns.flow, ["#{prefix}_country_iso2"]) ||
        (is_map(assigns.geo) && Map.get(assigns.geo, :country_iso2))

    if_uid = flow_get_in(ocsf, ["#{prefix}_endpoint", "interface_uid"])
    mac = flow_get(assigns.flow, ["#{prefix}_mac"]) || flow_get_in(ocsf, ["unmapped", "#{prefix}_mac"])

    mac_vendor =
      flow_get(assigns.flow, ["#{prefix}_mac_vendor"]) ||
        flow_get_in(ocsf, ["enrichment", "#{prefix}_mac_vendor"])

    provider =
      flow_get(assigns.flow, ["#{prefix}_hosting_provider"]) ||
        flow_get_in(ocsf, ["enrichment", "#{prefix}_hosting_provider"])

    prefix_tags =
      PrefixTagChips.normalize_tags(
        flow_get(assigns.flow, ["#{prefix}_prefix_tags"]) ||
          flow_get_in(ocsf, ["enrichment", "#{prefix}_prefix_tags"]),
        0
      )

    port = flow_get(assigns.flow, ["#{prefix}_endpoint_port", "#{prefix}_port"])
    hostname = Map.get(assigns.rdns_map || %{}, ip)

    assigns =
      assigns
      |> assign(:label, label)
      |> assign(:ip, ip)
      |> assign(:cc, cc)
      |> assign(:device_uid, device_uid)
      |> assign(:if_uid, if_uid)
      |> assign(:mac, mac)
      |> assign(:mac_vendor, mac_vendor)
      |> assign(:provider, provider)
      |> assign(:prefix_tags, prefix_tags)
      |> assign(:port, port)
      |> assign(:hostname, hostname)

    ~H"""
    <div class="p-3 rounded-lg border border-sr-line bg-sr-subtle/30">
      <div class="text-xs uppercase tracking-wider text-sr-muted">{@label}</div>
      <div class="mt-1 font-mono text-sm flex items-baseline gap-1 min-w-0">
        <span :if={is_binary(@cc) and String.length(@cc) == 2} class="text-sm leading-none">
          {iso2_flag_emoji(@cc)}
        </span>
        <.link
          :if={is_binary(@device_uid) and @device_uid != ""}
          navigate={~p"/devices/#{@device_uid}"}
          class="min-w-0 truncate hover:underline"
          title={@ip}
        >
          {@ip || "—"}
        </.link>
        <span
          :if={not (is_binary(@device_uid) and @device_uid != "")}
          class="min-w-0 truncate"
        >
          {@ip || "—"}
        </span>
        <span class="shrink-0 text-sr-muted">
          {if @port, do: ":#{@port}", else: ""}
        </span>
      </div>
      <div
        :if={@hostname}
        class="mt-0.5 text-[11px] text-sr-muted font-mono truncate"
        title={@hostname}
      >
        {@hostname}
      </div>
      <div class="mt-1 text-[11px] text-sr-muted space-y-0.5">
        <div :if={is_binary(@if_uid) and @if_uid != ""}>
          if_uid: <span class="font-mono">{@if_uid}</span>
        </div>
        <div>
          mac:
          <%= if is_binary(@mac) and @mac != "" do %>
            <.link
              :if={is_binary(@device_uid) and @device_uid != ""}
              navigate={~p"/devices/#{@device_uid}"}
              class="font-mono hover:underline"
              title="Open device"
            >
              {@mac}
            </.link>
            <span
              :if={not (is_binary(@device_uid) and @device_uid != "")}
              class="font-mono"
            >
              {@mac}
            </span>
          <% else %>
            <span class="font-mono text-sr-muted">n/a</span>
          <% end %>
        </div>
        <div :if={is_binary(@mac_vendor) and @mac_vendor != ""}>
          vendor: <span class="font-mono">{@mac_vendor}</span>
        </div>
        <div :if={is_binary(@provider) and @provider != ""}>
          provider: <span class="font-mono">{@provider}</span>
        </div>
        <PrefixTagChips.static tags={@prefix_tags} wrapper_class="flex flex-wrap gap-1 pt-1" />
      </div>
    </div>
    """
  end
end
