defmodule ServiceRadarWebNGWeb.DeviceLive.DiscoverySourcesComponents do
  @moduledoc """
  Renders the full list of discovery integrations/sources a (DIRE-merged) device
  was seen through.

  A merged device carries an authoritative `discovery_sources` array (e.g.
  `["agent", "awx", "sweep", "hypervisor_enrichment"]`) plus a single flat,
  merged `metadata` map whose keys are source-scoped by prefix. This section is a
  concise, information-dense summary of *which integrations discovered this
  device* — every source is rendered as a compact chip rather than a full card.
  Sources that carry meaningful scoped metadata surface a short curated summary
  on hover (a `data-tip` tooltip) so operators can drill in without duplicating
  the full "All Metadata" card below it. It is strictly read-only — it
  re-presents data already loaded on the device row.
  """

  use ServiceRadarWebNGWeb, :html

  import ServiceRadarWebNGWeb.DeviceLive.IntegrationLogos, only: [wordmark: 1]

  attr(:device_row, :map, required: true)
  attr(:source_observations, :list, default: [])
  attr(:timezone, :string, default: "Etc/UTC")

  def discovery_sources_section(assigns) do
    metadata = row_metadata(assigns.device_row)
    chips = source_chips(assigns.device_row, metadata)
    observations = Enum.filter(assigns.source_observations, &is_map/1)

    assigns =
      assigns
      |> assign(:source_chips, chips)
      |> assign(:has_sources, chips != [])
      |> assign(:source_observations, observations)
      |> assign(:has_source_observations, observations != [])

    ~H"""
    <div
      :if={@has_sources or @has_source_observations}
      class="rounded-xl border border-sr-line bg-sr-surface"
    >
      <div class="px-4 py-3 border-b border-sr-line flex items-center gap-2">
        <.icon name="hero-arrow-path-rounded-square" class="size-4 text-secondary" />
        <span class="text-sm font-semibold">Discovery Sources</span>
        <span class="rounded-full bg-secondary/10 px-2 py-0.5 text-[11px] font-semibold text-secondary">
          {length(@source_chips)}
        </span>
      </div>

      <div :if={@has_sources} class="flex flex-wrap gap-2 p-4">
        <span
          :for={chip <- @source_chips}
          class={[
            "inline-flex max-w-full items-center gap-1.5 rounded-full border px-2.5 py-1 text-xs font-medium",
            chip.tip &&
              "sr-ui-tooltip sr-ui-tooltip-bottom cursor-help border-secondary/30 bg-secondary/5 text-sr-ink/90 hover:border-secondary/50",
            !chip.tip && "border-sr-line bg-sr-subtle/40 text-sr-muted"
          ]}
          data-tip={chip.tip}
        >
          <.wordmark :if={chip.logo} name={chip.logo} class="h-3.5 w-auto" />
          <.icon
            :if={is_nil(chip.logo)}
            name={chip.icon}
            class={[
              "size-3.5 shrink-0",
              chip.tip && "text-secondary/80",
              !chip.tip && "text-sr-muted"
            ]}
          />
          <span :if={is_nil(chip.logo)} class="truncate">{chip.label}</span>
          <.user_time
            :if={chip.timestamp}
            id={"discovery-source-#{chip.key}-discovery-time"}
            value={chip.timestamp}
            timezone={@timezone}
            style={:compact}
            fallback="—"
            class="font-mono text-[10px]"
          />
          <span
            :if={chip.item_count > 0}
            class="rounded-full bg-secondary/15 px-1.5 text-[10px] font-semibold leading-4 text-secondary"
          >
            {chip.item_count}
          </span>
        </span>
      </div>

      <div :if={@has_source_observations} class="overflow-x-auto border-t border-sr-line">
        <table class={ui_table_class(size: "sm", class: "w-full")}>
          <thead>
            <tr>
              <th>Source</th>
              <th>Instance / Object</th>
              <th>State</th>
              <th>Last observed</th>
              <th>Collection</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={observation <- @source_observations}>
              <td class="font-medium">{source_display(observation)}</td>
              <td>
                <div class="font-mono text-xs">
                  {observation_value(observation, "source_instance")}
                </div>
                <div class="font-mono text-xs text-sr-muted">
                  {observation_value(observation, "source_object_id")}
                </div>
                <div
                  :for={item <- observation_metadata_items(observation)}
                  class="text-xs text-sr-muted"
                >
                  <span class="font-medium">{item.label}:</span> {item.value}
                </div>
              </td>
              <td>
                <.ui_badge size="sm" variant={source_state_variant(observation)}>
                  {source_state(observation)}
                </.ui_badge>
              </td>
              <td class="font-mono text-xs">
                <.user_time
                  id={observation_time_id(observation)}
                  value={observation_value(observation, "last_observed_at")}
                  timezone={@timezone}
                  style={:compact}
                  fallback="—"
                />
              </td>
              <td class="font-mono text-xs">
                {observation_value(observation, "collection_id")}
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Source enumeration
  # ---------------------------------------------------------------------------

  defp source_chips(row, metadata) do
    row
    |> discovery_sources()
    |> Enum.map(&source_chip(&1, metadata, row))
  end

  # Read the authoritative discovery_sources array (string or atom keyed), fall
  # back to the metadata "source"/"integration_type" hints when the array is
  # absent so single-source devices still render a card.
  defp discovery_sources(row) when is_map(row) do
    row
    |> Map.get("discovery_sources", Map.get(row, :discovery_sources))
    |> normalize_source_list()
    |> case do
      [] -> fallback_sources(row)
      sources -> sources
    end
  end

  defp discovery_sources(_row), do: []

  defp normalize_source_list(list) when is_list(list) do
    list
    |> Enum.map(&normalize_source/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  # Some transports hand back a Postgres text-array literal (e.g. "{agent,awx}")
  # rather than a decoded list; accept both so the section renders either way.
  defp normalize_source_list(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.trim_leading("{")
    |> String.trim_trailing("}")
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim(&1, "\""))
    |> normalize_source_list()
  end

  defp normalize_source_list(_), do: []

  defp normalize_source(value) when is_binary(value), do: value |> String.trim() |> String.downcase()

  defp normalize_source(value) when is_atom(value) and not is_nil(value),
    do: value |> Atom.to_string() |> String.downcase()

  defp normalize_source(_value), do: ""

  defp fallback_sources(row) do
    metadata = row_metadata(row)

    [metadata_lookup(metadata, "source"), metadata_lookup(metadata, "integration_type")]
    |> Enum.map(&normalize_source/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp source_chip(source, metadata, row) do
    {label, icon} = source_label_icon(source)
    items = source_items(source, metadata, row)
    timestamp = source_timestamp(source, metadata)

    %{
      key: source,
      label: label,
      icon: icon,
      logo: source_logo(source),
      item_count: length(items) + if(timestamp, do: 1, else: 0),
      timestamp: timestamp,
      tip: chip_tip(items)
    }
  end

  defp source_timestamp("sighting", metadata), do: metadata_lookup(metadata, "discovery_time")
  defp source_timestamp(_source, _metadata), do: nil

  defp source_logo("armis"), do: :armis
  defp source_logo("netbox"), do: :netbox
  defp source_logo(source) when source in ["proxmox", "proxmox-api", "proxmox_candidate"], do: :proxmox
  defp source_logo(source) when source in ["awx", "ansible"], do: :ansible
  defp source_logo(_source), do: nil

  # Concise "Label: value · Label: value" summary surfaced on hover for sources
  # that carry curated scoped metadata. `nil` for sources with none, which keeps
  # the chip a plain (non-tooltip) badge rather than spending space on filler.
  defp chip_tip([]), do: nil

  defp chip_tip(items) do
    Enum.map_join(items, " · ", fn %{label: label, value: value} -> "#{label}: #{value}" end)
  end

  # ---------------------------------------------------------------------------
  # Per-source labels / icons
  # ---------------------------------------------------------------------------

  defp source_label_icon("agent"), do: {"Agent", "hero-cpu-chip"}
  defp source_label_icon("awx"), do: {"AWX / Ansible", "hero-command-line"}
  defp source_label_icon("ansible"), do: {"AWX / Ansible", "hero-command-line"}
  defp source_label_icon("armis"), do: {"Armis", "hero-shield-check"}
  defp source_label_icon("netbox"), do: {"NetBox", "hero-server-stack"}
  defp source_label_icon("unifi"), do: {"UniFi", "hero-wifi"}
  defp source_label_icon("mikrotik"), do: {"MikroTik", "hero-cpu-chip"}
  defp source_label_icon("proxmox"), do: {"Proxmox", "hero-cube-transparent"}
  defp source_label_icon("proxmox-api"), do: {"Proxmox", "hero-cube-transparent"}
  defp source_label_icon("proxmox_candidate"), do: {"Proxmox", "hero-cube-transparent"}
  defp source_label_icon("hypervisor_enrichment"), do: {"Hypervisor Enrichment", "hero-server-stack"}
  defp source_label_icon("hypervisor"), do: {"Hypervisor Enrichment", "hero-server-stack"}
  defp source_label_icon("vmware"), do: {"VMware", "hero-server-stack"}
  defp source_label_icon("esxi"), do: {"VMware ESXi", "hero-server-stack"}
  defp source_label_icon("vsphere"), do: {"VMware vSphere", "hero-server-stack"}
  defp source_label_icon("hyperv"), do: {"Hyper-V", "hero-server-stack"}
  defp source_label_icon("kvm"), do: {"KVM", "hero-server-stack"}
  defp source_label_icon("mapper"), do: {"Network Mapper", "hero-map"}
  defp source_label_icon("network_discovery"), do: {"Network Discovery", "hero-map"}
  defp source_label_icon("sighting"), do: {"Sighting", "hero-eye"}
  defp source_label_icon("sweep"), do: {"Sweep", "hero-signal"}
  defp source_label_icon("camera_plugin"), do: {"Camera", "hero-video-camera"}
  defp source_label_icon("camera"), do: {"Camera", "hero-video-camera"}
  defp source_label_icon("snmp"), do: {"SNMP", "hero-radio"}
  # Acronym casing humanize/1 cannot infer: it title-cases each word, so
  # "netprobe-mdns" renders as "Netprobe Mdns". mDNS is a protocol name, not a
  # word. Both separator spellings are listed because SourcePolicy accepts both.
  defp source_label_icon("netprobe-mdns"), do: {"Netprobe mDNS", "hero-arrow-path-rounded-square"}
  defp source_label_icon("netprobe_mdns"), do: {"Netprobe mDNS", "hero-arrow-path-rounded-square"}
  defp source_label_icon("passive-mdns"), do: {"Passive mDNS", "hero-arrow-path-rounded-square"}
  defp source_label_icon("passive_mdns"), do: {"Passive mDNS", "hero-arrow-path-rounded-square"}
  defp source_label_icon("mdns"), do: {"mDNS", "hero-arrow-path-rounded-square"}
  defp source_label_icon("unknown"), do: {"Unknown", "hero-question-mark-circle"}
  defp source_label_icon(source), do: {humanize(source), "hero-arrow-path-rounded-square"}

  # ---------------------------------------------------------------------------
  # Per-source curated metadata
  # ---------------------------------------------------------------------------

  defp source_items("agent", metadata, row) do
    build_items([
      {"Agent ID", row_value(row, "agent_id"), mono: true},
      {"Gateway", row_value(row, "gateway_id"), mono: true},
      {"Plugin source", metadata_lookup(metadata, "plugin_discovery_source")}
    ])
  end

  defp source_items(source, metadata, _row) when source in ["awx", "ansible"] do
    build_items([
      {"Query label", metadata_lookup(metadata, "query_label")},
      {"Sync service", metadata_lookup(metadata, "sync_service_id"), mono: true},
      {"Source device ID", metadata_first(metadata, ["source_device_id", "integration_id"]), mono: true}
    ])
  end

  defp source_items("armis", metadata, _row) do
    build_items([
      {"Device ID", metadata_first(metadata, ["armis_device_id", "source_device_id", "integration_id"]), mono: true},
      {"Category", metadata_first(metadata, ["armis_category", "category"])},
      {"Risk level", metadata_lookup(metadata, "armis_risk_level")}
    ])
  end

  defp source_items("netbox", metadata, _row) do
    build_items([
      {"Device ID", metadata_lookup(metadata, "netbox_device_id"), mono: true},
      {"Role", metadata_first(metadata, ["device_role", "role", "device_role_name"])},
      {"Status", metadata_first(metadata, ["status", "device_status"])}
    ])
  end

  defp source_items("unifi", metadata, _row) do
    build_items([
      {"Controller", metadata_lookup(metadata, "controller_name")},
      {"Role", metadata_lookup(metadata, "device_role")}
    ])
  end

  defp source_items("mikrotik", metadata, _row) do
    build_items([
      {"API names", metadata_lookup(metadata, "mikrotik_api_names")}
    ])
  end

  defp source_items(source, metadata, _row) when source in ["proxmox", "proxmox-api", "proxmox_candidate"] do
    build_items([
      {"Service", metadata_lookup(metadata, "proxmox_candidate_service")},
      {"Node", metadata_first(metadata, ["proxmox_node", "node", "proxmox_candidate_title"])}
    ])
  end

  defp source_items(source, metadata, _row) when source in ["hypervisor_enrichment", "hypervisor"] do
    build_items([
      {"Provider", metadata_first(metadata, ["provider", "hypervisor_provider"])},
      {"Node", metadata_first(metadata, ["proxmox_node", "node"])},
      {"Integration", metadata_lookup(metadata, "integration_type")}
    ])
  end

  defp source_items(source, metadata, _row) when source in ["mapper", "network_discovery"] do
    build_items([
      {"Mapper job", metadata_lookup(metadata, "mapper_job_name")},
      {"Discovery ID", metadata_lookup(metadata, "discovery_id"), mono: true}
    ])
  end

  defp source_items("sighting", metadata, _row) do
    build_items([
      {"Discovery ID", metadata_lookup(metadata, "discovery_id"), mono: true}
    ])
  end

  defp source_items("sweep", metadata, _row) do
    build_items([
      {"Available", metadata_lookup(metadata, "scan_available_count")},
      {"Availability", metadata_lookup(metadata, "scan_availability_percent")}
    ])
  end

  defp source_items(source, metadata, _row) when source in ["camera_plugin", "camera"] do
    build_items([
      {"Manufacturer", metadata_lookup(metadata, "manufacturer")},
      {"Model", metadata_lookup(metadata, "model")}
    ])
  end

  # Generic fallback: surface the integration hints when present.
  defp source_items(_source, metadata, _row) do
    build_items([
      {"Integration", metadata_lookup(metadata, "integration_type")},
      {"Sync service", metadata_lookup(metadata, "sync_service_id"), mono: true}
    ])
  end

  defp source_display(observation) do
    case observation_value(observation, "source_label") do
      label when is_binary(label) and label != "" -> label
      _ -> observation |> observation_value("source") |> normalize_source() |> source_label_icon() |> elem(0)
    end
  end

  defp observation_metadata_items(observation) do
    metadata = observation_value(observation, "metadata") || %{}

    observation
    |> observation_value("metadata_fields")
    |> List.wrap()
    |> Enum.reduce([], fn field, items ->
      value = metadata |> metadata_lookup(field["key"]) |> format_value()

      if value in [nil, ""] do
        items
      else
        items ++ [%{label: field["label"] || humanize(field["key"]), value: value}]
      end
    end)
  end

  defp source_state(observation) do
    if observation_value(observation, "present") == true, do: "Current", else: "Absent"
  end

  defp source_state_variant(observation) do
    if observation_value(observation, "present") == true, do: "success", else: "warning"
  end

  defp observation_value(observation, key) when is_map(observation) do
    map_value(observation, key)
  end

  defp observation_time_id(observation) do
    identity =
      {
        observation_value(observation, "source"),
        observation_value(observation, "source_instance"),
        observation_value(observation, "source_object_id"),
        observation_value(observation, "collection_id")
      }

    "discovery-source-observation-#{:erlang.phash2(identity)}-last-observed"
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp build_items(specs) do
    specs
    |> Enum.map(&normalize_item/1)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_item({label, value}), do: normalize_item({label, value, []})

  defp normalize_item({label, value, opts}) do
    case format_value(value) do
      nil -> nil
      formatted -> %{label: label, value: formatted, mono: Keyword.get(opts, :mono, false)}
    end
  end

  defp format_value(nil), do: nil
  defp format_value(""), do: nil
  defp format_value(value) when is_binary(value), do: if(String.trim(value) == "", do: nil, else: value)
  defp format_value(value) when is_boolean(value), do: if(value, do: "Yes", else: "No")
  defp format_value(value) when is_integer(value) or is_float(value), do: to_string(value)
  defp format_value(value) when is_atom(value), do: to_string(value)
  defp format_value(_value), do: nil

  defp humanize(source) when is_binary(source) do
    source
    |> String.split(~r/[_\-\s]+/, trim: true)
    |> Enum.map_join(" ", &String.capitalize/1)
    |> case do
      "" -> "Source"
      value -> value
    end
  end

  defp humanize(_source), do: "Source"

  defp row_value(row, key) when is_map(row) and is_binary(key) do
    map_value(row, key)
  end

  defp row_value(_row, _key), do: nil

  defp row_metadata(row) when is_map(row) do
    case Map.get(row, "metadata") || Map.get(row, :metadata) do
      map when is_map(map) -> map
      _ -> %{}
    end
  end

  defp row_metadata(_row), do: %{}

  defp metadata_lookup(metadata, key) when is_map(metadata) and is_binary(key) do
    map_value(metadata, key)
  end

  defp metadata_lookup(_metadata, _key), do: nil

  defp metadata_first(metadata, keys) when is_map(metadata) and is_list(keys) do
    Enum.find_value(keys, fn key ->
      case metadata_lookup(metadata, key) do
        value when value in [nil, ""] -> nil
        value -> value
      end
    end)
  end

  defp metadata_first(_metadata, _keys), do: nil

  defp map_value(map, key) when is_map(map) and is_binary(key) do
    case Map.fetch(map, key) do
      {:ok, value} ->
        value

      :error ->
        Enum.reduce_while(map, nil, fn
          {candidate, value}, _acc when is_atom(candidate) ->
            if Atom.to_string(candidate) == key,
              do: {:halt, value},
              else: {:cont, nil}

          _entry, _acc ->
            {:cont, nil}
        end)
    end
  end
end
