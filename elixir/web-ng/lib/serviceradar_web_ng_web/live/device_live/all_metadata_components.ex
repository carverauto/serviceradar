defmodule ServiceRadarWebNGWeb.DeviceLive.AllMetadataComponents do
  @moduledoc """
  Renders the device's COMPLETE, raw metadata map in a collapsible card.

  DIRE merges every integration a device was seen through into a single flat
  `metadata` map whose keys are source-scoped by prefix (e.g. `armis_*`,
  `netbox_*`, `proxmox_*`, `sweep_*`, `agent_*`, …). Curated views (the
  Discovery Sources and Metadata sections) surface a hand-picked subset; this
  card instead exposes *everything* the device carries so nothing an operator
  might need is hidden.

  It is strictly read-only — it re-presents the `metadata` already loaded on the
  device row, grouped by prefix and sorted alphabetically, collapsed by default.
  Nested (map/list) values are pretty-printed as JSON in a scrollable block;
  scalars render inline. A client-side filter (`AllMetadataCard` hook) and a
  "copy as JSON" button are cosmetic conveniences layered on top.
  """

  use ServiceRadarWebNGWeb, :html

  # Ordered prefix -> {group title, icon}. A metadata key's first underscore
  # token is matched against this table; unmatched keys fall into "Other".
  # Groups render in this order (Other always last); duplicate {title, icon}
  # specs (e.g. integration/sync) merge into one group.
  @prefix_groups [
    {"armis", {"Armis", "hero-shield-check"}},
    {"netbox", {"NetBox", "hero-server-stack"}},
    {"proxmox", {"Proxmox", "hero-cube-transparent"}},
    {"hypervisor", {"Hypervisor", "hero-server-stack"}},
    {"vmware", {"VMware", "hero-server-stack"}},
    {"esxi", {"VMware", "hero-server-stack"}},
    {"vsphere", {"VMware", "hero-server-stack"}},
    {"unifi", {"UniFi", "hero-wifi"}},
    {"mikrotik", {"MikroTik", "hero-cpu-chip"}},
    {"snmp", {"SNMP", "hero-radio"}},
    {"sweep", {"Sweep", "hero-signal"}},
    {"scan", {"Sweep", "hero-signal"}},
    {"agent", {"Agent", "hero-cpu-chip"}},
    {"gateway", {"Agent", "hero-cpu-chip"}},
    {"plugin", {"Agent", "hero-cpu-chip"}},
    {"mapper", {"Discovery", "hero-map"}},
    {"discovery", {"Discovery", "hero-map"}},
    {"camera", {"Camera", "hero-video-camera"}},
    {"manufacturer", {"Camera", "hero-video-camera"}},
    {"integration", {"Integration", "hero-arrow-path-rounded-square"}},
    {"sync", {"Integration", "hero-arrow-path-rounded-square"}},
    {"source", {"Integration", "hero-arrow-path-rounded-square"}}
  ]

  @other_group {"Other", "hero-ellipsis-horizontal-circle"}

  # Tokens that should be fully upper-cased when humanizing a key.
  @acronyms ~w(id ip url uri os mac cpu ram vlan vm dns http https api uid uuid rdp ssh snmp vpn tcp udp asn bgp mtu wan lan sn)

  attr(:device_row, :map, required: true)

  def all_metadata_section(assigns) do
    metadata = row_metadata(assigns.device_row)

    assigns =
      assigns
      |> assign(:groups, build_groups(metadata))
      |> assign(:key_count, map_size(metadata))
      |> assign(:json, pretty_json(metadata))

    ~H"""
    <details
      id="device-all-metadata"
      phx-hook="DetailsState"
      class="group/meta rounded-xl border border-base-200 bg-base-100"
    >
      <summary class="flex cursor-pointer list-none items-center gap-2 px-4 py-3 [&::-webkit-details-marker]:hidden">
        <.icon name="hero-rectangle-stack" class="size-4 shrink-0 text-secondary" />
        <span class="text-sm font-semibold">All Metadata</span>
        <span class="rounded-full bg-secondary/10 px-2 py-0.5 text-[11px] font-semibold text-secondary">
          {@key_count} {if @key_count == 1, do: "key", else: "keys"}
        </span>
        <.icon
          name="hero-chevron-down"
          class="ml-auto size-4 shrink-0 text-base-content/50 transition-transform group-open/meta:rotate-180"
        />
      </summary>

      <div
        :if={@key_count == 0}
        class="border-t border-base-200 px-4 py-6 text-center text-sm text-base-content/50"
      >
        No additional metadata.
      </div>

      <div
        :if={@key_count > 0}
        id="device-all-metadata-body"
        phx-hook="AllMetadataCard"
        data-metadata-json={@json}
        class="border-t border-base-200 p-4 space-y-4"
      >
        <div class="flex flex-wrap items-center gap-2">
          <label class="input input-sm input-bordered flex min-w-[12rem] flex-1 items-center gap-2">
            <.icon name="hero-magnifying-glass" class="size-4 text-base-content/40" />
            <input
              type="text"
              data-metadata-filter-input
              class="grow"
              placeholder="Filter keys…"
              autocomplete="off"
            />
          </label>
          <button type="button" data-metadata-copy class="btn btn-sm btn-ghost gap-1">
            <.icon name="hero-clipboard-document" class="size-4" />
            <span data-metadata-copy-label>Copy JSON</span>
          </button>
        </div>

        <div class="space-y-3">
          <div
            :for={group <- @groups}
            data-metadata-group
            class="min-w-0 overflow-hidden rounded-lg border border-base-200 bg-base-200/20"
          >
            <div class="flex items-center gap-2 border-b border-base-200 px-3 py-2">
              <.icon name={group.icon} class="size-4 shrink-0 text-base-content/60" />
              <span class="text-xs font-semibold text-base-content/70">{group.title}</span>
              <span class="text-[11px] text-base-content/40">{length(group.entries)}</span>
            </div>

            <dl class="divide-y divide-base-200/60">
              <div
                :for={entry <- group.entries}
                data-metadata-row
                data-metadata-search={entry.search}
                class="grid grid-cols-1 gap-1 px-3 py-2 sm:grid-cols-3 sm:gap-3"
              >
                <dt class="min-w-0 sm:col-span-1">
                  <div class="break-words text-sm font-medium text-base-content">{entry.label}</div>
                  <div class="break-all font-mono text-[11px] text-base-content/40">{entry.key}</div>
                </dt>
                <dd class="min-w-0 sm:col-span-2">
                  <pre
                    :if={entry.nested}
                    class="max-h-64 overflow-auto whitespace-pre-wrap break-words rounded bg-base-300/40 p-2 font-mono text-[11px] leading-relaxed text-base-content/80"
                  >{entry.value}</pre>
                  <span
                    :if={not entry.nested}
                    class="block whitespace-pre-wrap break-words text-sm text-base-content/90"
                  >{entry.value}</span>
                </dd>
              </div>
            </dl>
          </div>
        </div>

        <div
          data-metadata-filter-empty
          class="hidden py-4 text-center text-sm text-base-content/50"
        >
          No keys match your filter.
        </div>
      </div>
    </details>
    """
  end

  # ---------------------------------------------------------------------------
  # Metadata sourcing
  # ---------------------------------------------------------------------------

  # Metadata rides on the same device read-model row the Discovery Sources and
  # Metadata sections read (`device_row["metadata"]`); accept string- or
  # atom-keyed rows and fall back to an empty map for anything else.
  defp row_metadata(row) when is_map(row) do
    case Map.get(row, "metadata") || Map.get(row, :metadata) do
      map when is_map(map) -> map
      _ -> %{}
    end
  end

  defp row_metadata(_row), do: %{}

  # ---------------------------------------------------------------------------
  # Grouping
  # ---------------------------------------------------------------------------

  defp build_groups(metadata) when map_size(metadata) == 0, do: []

  defp build_groups(metadata) do
    by_title =
      metadata
      |> Enum.map(fn {key, value} -> build_entry(to_string(key), value) end)
      |> Enum.sort_by(& &1.key)
      |> Enum.group_by(& &1.group_title)

    ordered_group_specs()
    |> Enum.map(fn {title, icon} ->
      case Map.get(by_title, title) do
        nil -> nil
        entries -> %{title: title, icon: icon, entries: entries}
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp ordered_group_specs do
    (Enum.map(@prefix_groups, fn {_prefix, spec} -> spec end) ++ [@other_group])
    |> Enum.uniq()
  end

  defp build_entry(key, value) do
    {title, _icon, stripped} = classify(key)
    nested = nested?(value)
    display = if nested, do: pretty_json(value), else: scalar_to_string(value)
    label = humanize(stripped)

    %{
      key: key,
      label: label,
      group_title: title,
      nested: nested,
      value: display,
      search: String.downcase("#{key} #{label} #{display}")
    }
  end

  defp classify(key) do
    prefix = key |> String.split("_", parts: 2) |> List.first()

    case List.keyfind(@prefix_groups, prefix, 0) do
      {^prefix, {title, icon}} ->
        stripped = String.replace_prefix(key, prefix <> "_", "")
        stripped = if stripped == "", do: key, else: stripped
        {title, icon, stripped}

      _ ->
        {elem(@other_group, 0), elem(@other_group, 1), key}
    end
  end

  # ---------------------------------------------------------------------------
  # Value / label formatting
  # ---------------------------------------------------------------------------

  defp nested?(value) when is_map(value), do: true
  defp nested?(value) when is_list(value), do: true
  defp nested?(_value), do: false

  defp scalar_to_string(nil), do: "—"
  defp scalar_to_string(true), do: "true"
  defp scalar_to_string(false), do: "false"

  defp scalar_to_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> "—"
      _ -> value
    end
  end

  defp scalar_to_string(value) when is_integer(value) or is_float(value), do: to_string(value)
  defp scalar_to_string(value) when is_atom(value), do: to_string(value)
  defp scalar_to_string(value), do: inspect(value)

  defp pretty_json(value) do
    case Jason.encode(value, pretty: true) do
      {:ok, json} -> json
      _ -> inspect(value, pretty: true, limit: :infinity)
    end
  end

  defp humanize(key) when is_binary(key) do
    key
    |> String.split(~r/[_\-\s]+/, trim: true)
    |> Enum.map_join(" ", &capitalize_token/1)
    |> case do
      "" -> key
      humanized -> humanized
    end
  end

  defp humanize(key), do: to_string(key)

  defp capitalize_token(token) do
    if String.downcase(token) in @acronyms do
      String.upcase(token)
    else
      String.capitalize(token)
    end
  end
end
