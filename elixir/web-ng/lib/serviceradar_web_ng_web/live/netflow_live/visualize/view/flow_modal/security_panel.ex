defmodule ServiceRadarWebNGWeb.NetflowLive.Visualize.View.FlowModal.SecurityPanel do
  @moduledoc false
  use ServiceRadarWebNGWeb, :html

  import ServiceRadarWebNGWeb.NetflowLive.Visualize.AsnLookup, only: [asn_rir_hint: 1]

  import ServiceRadarWebNGWeb.NetflowLive.Visualize.FlowContext,
    only: [threat_severity_badge_variant: 1, threat_sources: 1]

  import ServiceRadarWebNGWeb.NetflowLive.Visualize.Format, only: [to_int: 1]
  import ServiceRadarWebNGWeb.NetflowLive.Visualize.Params, only: [normalize_optional_string: 1]

  alias ServiceRadarWebNGWeb.NetflowLive.Visualize.View.FlowModal.SecurityPanel.NetworkInfo

  attr(:context, :map, required: true)
  attr(:arin_lookup, :map, default: %{})

  def render(assigns) do
    ~H"""
    <div class="p-3 rounded-lg border border-sr-line bg-sr-subtle/30">
      <div class="text-xs uppercase tracking-wider text-sr-muted">
        Security and Enrichment
      </div>

      <div class="mt-3 space-y-3 text-xs">
        <div>
          <div class="font-semibold">GeoIP / ASN</div>
          <.netflow_geoip_asn_line
            side="Source"
            geo={Map.get(@context, :src_geo)}
            arin_lookup={@arin_lookup}
          />
          <.netflow_geoip_asn_line
            side="Dest"
            geo={Map.get(@context, :dst_geo)}
            arin_lookup={@arin_lookup}
          />
        </div>

        <.arin_lookup_card arin_lookup={@arin_lookup} />
        <.threat_intel context={@context} />
        <.port_findings context={@context} />
        <NetworkInfo.ipinfo_block context={@context} arin_lookup={@arin_lookup} />
        <NetworkInfo.rdns_block context={@context} />
      </div>
    </div>
    """
  end

  attr(:arin_lookup, :map, default: %{})

  def arin_lookup_card(assigns) do
    ~H"""
    <div>
      <div class="font-semibold">ARIN ASN lookup</div>
      <div class="mt-1 text-sr-muted">Click any AS number to load ARIN Whois details.</div>
      <div
        :if={is_binary(Map.get(@arin_lookup, :error)) and Map.get(@arin_lookup, :error) != ""}
        class="mt-2 text-error"
      >
        {Map.get(@arin_lookup, :error)}
      </div>
      <%= if data = Map.get(@arin_lookup, :data) do %>
        <div class="mt-2 rounded-lg border border-sr-line bg-sr-subtle/30 p-2">
          <div class="flex items-center justify-between gap-2">
            <div class="font-mono text-[11px] text-sr-ink/90">
              {data.handle} {if is_binary(data.name), do: "- #{data.name}", else: ""}
            </div>
            <.ui_badge
              :if={is_binary(data.source) and data.source != ""}
              size="xs"
              variant="outline"
            >
              {data.source}
            </.ui_badge>
          </div>
          <div class="mt-2 max-h-48 overflow-y-auto space-y-1 font-mono text-[11px] text-sr-muted pr-1">
            <div :if={is_binary(data.org_name) and data.org_name != ""}>
              org: {data.org_name}
              <span :if={is_binary(data.org_handle) and data.org_handle != ""}>
                ({data.org_handle})
              </span>
            </div>
            <div :if={is_binary(data.range) and data.range != ""}>range: {data.range}</div>
            <div :if={is_binary(data.registration_date) and data.registration_date != ""}>
              registered: {data.registration_date}
            </div>
            <div :if={is_binary(data.update_date) and data.update_date != ""}>
              updated: {data.update_date}
            </div>
            <div :if={is_binary(data.comment) and data.comment != ""}>comment: {data.comment}</div>
            <.external_ref label="rdap" href={Map.get(data, :rdap_ref)} />
            <.external_ref label="whois" href={Map.get(data, :ref)} />
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  attr(:context, :map, required: true)

  def threat_intel(assigns) do
    ~H"""
    <div>
      <div class="font-semibold">Threat intel</div>
      <.threat_line label="Source" match={Map.get(@context, :src_threat)} />
      <.threat_line label="Dest" match={Map.get(@context, :dst_threat)} />
    </div>
    """
  end

  attr(:context, :map, required: true)

  def port_findings(assigns) do
    ~H"""
    <div>
      <div class="font-semibold">Port scan</div>
      <%= if scan = Map.get(@context, :src_port_scan) do %>
        <div class="mt-1 text-sr-muted">
          <.ui_badge size="xs" variant="error">flagged</.ui_badge>
          <span class="ml-2 font-mono">{scan.unique_ports} unique ports</span>
        </div>
      <% else %>
        <div class="mt-1 text-sr-muted">
          <.ui_badge size="xs" variant="ghost">not flagged</.ui_badge>
        </div>
      <% end %>
    </div>

    <div :if={anomaly = Map.get(@context, :dst_port_anomaly)}>
      <div class="font-semibold">Port anomaly</div>
      <div class="mt-1 text-sr-muted">
        <.ui_badge size="xs" variant="error">anomalous</.ui_badge>
        <span class="ml-2 font-mono">
          {anomaly.current_bytes} vs baseline {anomaly.baseline_bytes}
        </span>
      </div>
    </div>
    """
  end

  attr(:label, :string, required: true)
  attr(:match, :any, default: nil)

  def threat_line(assigns) do
    ~H"""
    <div class="mt-1 text-sr-muted">
      {@label}:
      <%= if @match do %>
        <.ui_badge size="xs" variant="warning" class="ml-2">match</.ui_badge>
        <span class="ml-2 font-mono">{@match.match_count} indicators</span>
        <.ui_badge
          :if={@match.max_severity}
          size="xs"
          variant={threat_severity_badge_variant(@match.max_severity)}
          class="ml-2"
        >
          severity {@match.max_severity}
        </.ui_badge>
        <.ui_badge :for={source <- threat_sources(@match)} size="xs" variant="outline" class="ml-1">
          {source}
        </.ui_badge>
      <% else %>
        <.ui_badge size="xs" variant="ghost" class="ml-2">none</.ui_badge>
      <% end %>
    </div>
    """
  end

  attr(:label, :string, required: true)
  attr(:href, :string, default: nil)

  def external_ref(assigns) do
    ~H"""
    <div :if={is_binary(@href) and @href != ""}>
      {@label}:
      <a href={@href} target="_blank" rel="noopener noreferrer" class="text-sr-brand hover:underline">
        {@href}
      </a>
    </div>
    """
  end

  attr(:side, :string, required: true)
  attr(:geo, :any, default: nil)
  attr(:arin_lookup, :map, default: %{})

  def netflow_geoip_asn_line(assigns) do
    {location_label, as_number, as_name, country_code} = geo_asn(assigns.geo)

    assigns =
      assigns
      |> assign(:location_label, if(location_label == "", do: "n/a", else: location_label))
      |> assign(:as_number, as_number)
      |> assign(:as_name, as_name)
      |> assign(:country_code, country_code)
      |> assign(:asn_selected, Map.get(assigns.arin_lookup || %{}, :asn))

    ~H"""
    <div class="mt-1 text-sr-muted">
      {@side}: <span class="font-mono">{@location_label}</span>
      <button
        :if={is_integer(@as_number) and @as_number > 0}
        type="button"
        phx-click="netflow_lookup_asn"
        phx-value-asn={@as_number}
        phx-value-rir-hint={asn_rir_hint(@country_code)}
        class={[
          "ml-2 font-mono underline decoration-dotted underline-offset-2 hover:text-sr-brand",
          @asn_selected == @as_number && "text-sr-brand"
        ]}
      >
        AS{@as_number}
      </button>
      <span :if={is_binary(@as_name) and @as_name != ""} class="ml-2 font-mono text-sr-muted">
        {@as_name}
      </span>
    </div>
    """
  end

  defp geo_asn(geo) when is_map(geo) do
    location =
      [Map.get(geo, :country_code), Map.get(geo, :country_name)]
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.join(" ")

    {location, to_int(Map.get(geo, :as_number)), normalize_optional_string(Map.get(geo, :as_name)),
     normalize_optional_string(Map.get(geo, :country_code))}
  end

  defp geo_asn(_geo), do: {"", nil, nil, nil}
end
