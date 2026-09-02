defmodule ServiceRadarWebNGWeb.DeviceLive.VisibilityComponents do
  @moduledoc false

  use ServiceRadarWebNGWeb, :html

  import ServiceRadarWebNGWeb.DeviceLive.IntegrationLogos, only: [wordmark: 1]
  import ServiceRadarWebNGWeb.DeviceLive.ProcessTablePagination, only: [search_bar: 1, paginator: 1]

  alias ServiceRadarWebNG.RBAC
  alias ServiceRadarWebNGWeb.DeviceLive.DeviceStateData
  alias ServiceRadarWebNGWeb.DeviceLive.ProcessTablePagination

  @dpi_protocols [
    {"http1", "HTTP/1"},
    {"http2", "HTTP/2"},
    {"tls", "TLS"},
    {"dns", "DNS"},
    {"ssh", "SSH"},
    {"ftp", "FTP"},
    {"quic", "QUIC"},
    {"mqtt", "MQTT"},
    {"bittorrent", "BitTorrent"}
  ]
  @active_fingerprint_protocols [
    {"ssh", "SSH"},
    {"http", "HTTP"},
    {"smb", "SMB"},
    {"ftp", "FTP"},
    {"telnet", "Telnet"},
    {"smtp", "SMTP"},
    {"ntp", "NTP"},
    {"rdp", "RDP"},
    {"dns", "DNS"}
  ]

  # ---------------------------------------------------------------------------
  # Metadata Summary Section
  # ---------------------------------------------------------------------------

  attr(:device_row, :map, required: true)
  attr(:timezone, :string, default: "Etc/UTC")

  def metadata_summary_section(assigns) do
    groups = metadata_summary_groups(assigns.device_row)

    assigns =
      assigns
      |> assign(:metadata_groups, groups)
      |> assign(:has_metadata_summary, groups != [])

    ~H"""
    <div :if={@has_metadata_summary} class="rounded-xl border border-sr-line bg-sr-surface">
      <div class="px-4 py-3 border-b border-sr-line">
        <div class="flex items-center gap-2">
          <.icon name="hero-circle-stack" class="size-4 text-secondary" />
          <span class="text-sm font-semibold">Metadata</span>
        </div>
      </div>

      <div class="p-4 space-y-4">
        <div
          :if={@metadata_groups != []}
          class="grid grid-cols-1 md:grid-cols-2 xl:grid-cols-3 gap-3"
        >
          <div
            :for={group <- @metadata_groups}
            class="min-w-0 rounded-lg border border-sr-line bg-sr-subtle/20 p-3"
          >
            <div class="mb-2 flex items-center gap-2">
              <.wordmark :if={group.logo} name={group.logo} class="h-4 w-auto" />
              <.icon :if={is_nil(group.logo)} name={group.icon} class="size-4 text-sr-muted" />
              <span :if={is_nil(group.logo)} class="text-xs font-semibold text-sr-muted">
                {group.title}
              </span>
            </div>

            <div class="space-y-1.5 text-sm">
              <.metadata_kv
                :for={item <- group.items}
                label={item.label}
                value={item.value}
                mono={item.mono}
                href={Map.get(item, :href)}
                external_href={Map.get(item, :external_href)}
                timezone={@timezone}
                time_id={
                  "device-metadata-#{visibility_device_key(@device_row)}-#{time_key(group.title)}-#{time_key(item.label)}"
                }
              />
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr(:label, :string, required: true)
  attr(:value, :any, required: true)
  attr(:mono, :boolean, default: false)
  attr(:href, :string, default: nil)
  attr(:external_href, :string, default: nil)
  attr(:timezone, :string, default: "Etc/UTC")
  attr(:time_id, :string, default: nil)

  def metadata_kv(assigns) do
    ~H"""
    <div class="flex items-start justify-between gap-3">
      <span class="shrink-0 text-xs text-sr-muted">{@label}</span>
      <.link
        :if={@href}
        navigate={@href}
        class={[
          "min-w-0 text-right text-sm font-medium text-sr-brand hover:underline break-words",
          @mono && "font-mono text-xs"
        ]}
        title={format_metadata_value(@value)}
      >
        {@value}
      </.link>
      <a
        :if={@external_href}
        href={@external_href}
        target="_blank"
        rel="noopener noreferrer"
        class={[
          "min-w-0 text-right text-sm font-medium text-sr-brand hover:underline break-words",
          @mono && "font-mono text-xs"
        ]}
        title={format_metadata_value(@value)}
      >
        {@value}
      </a>
      <span
        :if={
          is_nil(@href) and is_nil(@external_href) and
            not match?(%DateTime{}, @value) and not match?(%NaiveDateTime{}, @value)
        }
        class={[
          "min-w-0 text-right text-sm font-medium text-sr-ink break-words",
          @mono && "font-mono text-xs"
        ]}
        title={format_metadata_value(@value)}
      >
        {format_metadata_value(@value)}
      </span>
      <.user_time
        :if={
          is_nil(@href) and is_nil(@external_href) and
            (match?(%DateTime{}, @value) or match?(%NaiveDateTime{}, @value))
        }
        id={@time_id || "device-metadata-#{time_key(@label)}"}
        value={@value}
        timezone={@timezone}
        style={:compact}
        class="min-w-0 text-right text-sm font-medium text-sr-ink break-words font-mono text-xs"
      />
    </div>
    """
  end

  attr(:device_row, :map, required: true)
  attr(:timezone, :string, default: "Etc/UTC")

  def network_visibility_section(assigns) do
    fingerprints = passive_fingerprint_rows(assigns.device_row)
    dpi_rows = dpi_rows(assigns.device_row)

    assigns =
      assigns
      |> assign(:fingerprints, fingerprints)
      |> assign(:dpi_rows, dpi_rows)
      |> assign(:has_fingerprints, fingerprints != [])
      |> assign(:has_dpi, dpi_rows != [])

    ~H"""
    <div :if={@has_fingerprints or @has_dpi} class="rounded-xl border border-sr-line bg-sr-surface">
      <div class="px-4 py-3 border-b border-sr-line">
        <div class="flex items-center gap-2">
          <.icon name="hero-eye" class="size-4 text-sr-brand" />
          <span class="text-sm font-semibold">Network Visibility</span>
          <.ui_badge :if={@has_fingerprints} size="sm" variant="ghost">
            Passive fingerprint
          </.ui_badge>
          <.ui_badge :if={@has_dpi} size="sm" variant="info">DPI</.ui_badge>
        </div>
      </div>

      <div class="p-4 grid grid-cols-1 md:grid-cols-3 gap-3">
        <div
          :for={fingerprint <- @fingerprints}
          class="rounded-lg border border-sr-line bg-sr-subtle/20 p-3"
        >
          <div class="mb-2 flex items-center justify-between gap-2">
            <span class="text-xs font-semibold uppercase tracking-wide text-sr-muted">
              {fingerprint.protocol}
            </span>
            <.ui_badge :if={fingerprint.source} size="xs" variant="ghost">
              {fingerprint.source}
            </.ui_badge>
          </div>
          <div class="space-y-1.5 text-sm">
            <.metadata_kv
              :for={item <- fingerprint.items}
              label={item.label}
              value={item.value}
              mono={item.mono}
              timezone={@timezone}
              time_id={
                "device-visibility-#{visibility_device_key(@device_row)}-#{time_key(fingerprint.protocol)}-#{time_key(item.label)}"
              }
            />
          </div>
        </div>

        <div :for={dpi <- @dpi_rows} class="rounded-lg border border-sr-line bg-sr-subtle/20 p-3">
          <div class="mb-2 flex items-center justify-between gap-2">
            <span class="text-xs font-semibold uppercase tracking-wide text-sr-muted">
              DPI {dpi.protocol}
            </span>
            <.ui_badge :if={dpi.source} size="xs" variant="info">
              {dpi.source}
            </.ui_badge>
          </div>
          <div class="space-y-1.5 text-sm">
            <.metadata_kv
              :for={item <- dpi.items}
              label={item.label}
              value={item.value}
              mono={item.mono}
              timezone={@timezone}
              time_id={
                "device-visibility-#{visibility_device_key(@device_row)}-dpi-#{time_key(dpi.protocol)}-#{time_key(item.label)}"
              }
            />
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr(:device_row, :map, required: true)
  attr(:timezone, :string, default: "Etc/UTC")

  def active_fingerprint_tab_content(assigns) do
    summary = active_fingerprint_summary(assigns.device_row)
    rows = active_fingerprint_rows(assigns.device_row)

    assigns =
      assigns
      |> assign(:summary, summary)
      |> assign(:rows, rows)
      |> assign(:has_summary, summary.items != [])
      |> assign(:has_rows, rows != [])

    ~H"""
    <div class="space-y-4">
      <div :if={@has_summary} class="rounded-xl border border-sr-line bg-sr-surface">
        <div class="px-4 py-3 border-b border-sr-line">
          <div class="flex flex-wrap items-center gap-2">
            <.icon name="hero-finger-print" class="size-4 text-sr-brand" />
            <span class="text-sm font-semibold">Active OS fingerprint</span>
            <.ui_badge :if={@summary.source} size="sm" variant="ghost">
              {@summary.source}
            </.ui_badge>
          </div>
        </div>
        <div class="p-4 grid grid-cols-1 md:grid-cols-2 xl:grid-cols-3 gap-3">
          <.metadata_kv
            :for={item <- @summary.items}
            label={item.label}
            value={item.value}
            mono={item.mono}
            timezone={@timezone}
            time_id={
              "device-active-fingerprint-#{visibility_device_key(@device_row)}-summary-#{time_key(item.label)}"
            }
          />
        </div>
      </div>

      <div class="rounded-xl border border-sr-line bg-sr-surface">
        <div class="px-4 py-3 border-b border-sr-line">
          <div class="flex flex-wrap items-center gap-2">
            <.icon name="hero-server-stack" class="size-4 text-sr-brand" />
            <span class="text-sm font-semibold">Banner-grab matches</span>
            <.ui_badge :if={@has_rows} size="sm" variant="info">{length(@rows)}</.ui_badge>
          </div>
        </div>

        <div :if={!@has_rows} class="p-6 text-sm text-sr-muted">
          No active banner fingerprint evidence has been recorded for this device.
        </div>

        <div :if={@has_rows} class="overflow-x-auto">
          <table class={ui_table_class(size: "sm")}>
            <thead>
              <tr class="text-xs uppercase tracking-wide text-sr-muted">
                <th>Protocol</th>
                <th>Port</th>
                <th>Product</th>
                <th>Version</th>
                <th>OS / Vendor</th>
                <th>Source</th>
                <th>Last observed</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={row <- @rows}>
                <td>
                  <.ui_badge size="sm" variant="ghost">{row.protocol}</.ui_badge>
                </td>
                <td class="font-mono text-xs">{row.port}</td>
                <td>{row.product}</td>
                <td>{row.version}</td>
                <td>{row.os}</td>
                <td class="text-xs">{row.source}</td>
                <td class="text-xs font-mono">
                  <.user_time
                    id={"device-active-fingerprint-#{visibility_device_key(@device_row)}-#{time_key(row.protocol)}-observed-at"}
                    value={row.observed_at}
                    timezone={@timezone}
                    style={:compact}
                  />
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
    </div>
    """
  end

  attr(:device_row, :map, required: true)
  attr(:search, :string, default: "")
  attr(:page, :integer, default: 1)
  attr(:timezone, :string, default: "Etc/UTC")

  def process_listeners_tab_content(assigns) do
    snapshot = process_listener_snapshot(assigns.device_row)
    rows = Map.get(snapshot, :entries, [])

    pagination =
      ProcessTablePagination.paginate(rows, assigns.search, assigns.page, fields: &process_listener_search_fields/1)

    assigns =
      assigns
      |> assign(:snapshot, snapshot)
      |> assign(:rows, pagination.rows)
      |> assign(:pagination, pagination)
      |> assign(:row_count, pagination.total)
      |> assign(:agent_host, agent_device?(assigns.device_row))

    ~H"""
    <div class="rounded-xl border border-sr-line bg-sr-surface">
      <div class="border-b border-sr-line px-4 py-3">
        <div class="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
          <div class="flex items-center gap-2">
            <.icon name="hero-command-line" class="size-4 text-sr-brand" />
            <span class="text-sm font-semibold">Process Listeners</span>
            <.ui_badge :if={@row_count > 0} size="sm" variant="ghost">
              {@row_count} sockets
            </.ui_badge>
          </div>
          <div
            :if={metadata_present?(@snapshot.fingerprint) or metadata_present?(@snapshot.observed_at)}
            class="flex flex-wrap items-center gap-2 text-xs text-sr-muted"
          >
            <span :if={metadata_present?(@snapshot.fingerprint)} class="font-mono">
              {@snapshot.fingerprint}
            </span>
            <.user_time
              :if={metadata_present?(@snapshot.observed_at)}
              id={"device-process-listeners-#{visibility_device_key(@device_row)}-observed-at"}
              value={@snapshot.observed_at}
              timezone={@timezone}
              style={:compact}
              class="font-mono"
            />
          </div>
        </div>

        <div :if={@row_count > 0} class="mt-3">
          <.search_bar
            id="process-listeners-search"
            event="process_listeners_search"
            search={@search}
            placeholder="Search by process, PID, protocol…"
            total={@pagination.total}
            filtered_total={@pagination.filtered_total}
            filtered?={@pagination.filtered?}
            unit="sockets"
          />
        </div>
      </div>

      <div :if={not @agent_host and @row_count == 0} class="px-4 py-8 text-sm text-sr-muted">
        Process listener snapshots are available on devices linked to a ServiceRadar agent.
      </div>

      <div :if={@agent_host and @row_count == 0} class="px-4 py-8 text-sm text-sr-muted">
        No local process listener snapshot has been reported for this agent host yet.
      </div>

      <div
        :if={@row_count > 0 and @pagination.filtered_total == 0}
        class="px-4 py-8 text-sm text-sr-muted"
      >
        No process listeners match the current search.
      </div>

      <div :if={@pagination.filtered_total > 0} class="overflow-x-auto">
        <table class={ui_table_class(size: "sm")}>
          <thead>
            <tr>
              <th>Endpoint</th>
              <th>Protocol</th>
              <th>Process</th>
              <th>PID</th>
              <th>UID/GID</th>
              <th>Container</th>
              <th>Command</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={row <- @rows}>
              <td class="font-mono text-xs">{process_listener_endpoint(row)}</td>
              <td>
                <.ui_badge size="sm" variant="outline" class="uppercase">
                  {default_display(row.transport_protocol)}
                </.ui_badge>
              </td>
              <td class="font-medium">{default_display(row.comm)}</td>
              <td class="font-mono text-xs">
                {default_display(row.pid)}
                <span :if={row.tgid != nil and row.tgid != row.pid} class="text-sr-muted">
                  / {row.tgid}
                </span>
              </td>
              <td class="font-mono text-xs">{process_listener_uid_gid(row)}</td>
              <td class="font-mono text-xs">{process_listener_container(row.container_id)}</td>
              <td class="max-w-xl break-words font-mono text-xs">
                {process_listener_cmdline(row.redacted_cmdline)}
              </td>
            </tr>
          </tbody>
        </table>
      </div>

      <.paginator
        page={@pagination.page}
        page_count={@pagination.page_count}
        range_start={@pagination.range_start}
        range_end={@pagination.range_end}
        filtered_total={@pagination.filtered_total}
        prev_event="process_listeners_prev_page"
        next_event="process_listeners_next_page"
        unit="sockets"
      />
    </div>
    """
  end

  defp process_listener_search_fields(row) when is_map(row) do
    [
      row.comm,
      row.pid,
      row.tgid,
      row.transport_protocol,
      row.local_ip,
      row.local_port,
      row.container_id,
      process_listener_cmdline(row.redacted_cmdline)
    ]
  end

  defp process_listener_search_fields(_row), do: []

  defp metadata_summary_groups(row) do
    metadata = row_metadata(row)
    sources = metadata_discovery_source_set(row)

    Enum.reject(
      [
        metadata_group("Integration", "hero-arrow-path-rounded-square", [
          metadata_item("Type", metadata_lookup(metadata, "integration_type")),
          metadata_item("Query label", metadata_lookup(metadata, "query_label")),
          metadata_item("Sync service", metadata_lookup(metadata, "sync_service_id"),
            mono: true,
            href: metadata_lookup(metadata, "sync_service_path")
          ),
          metadata_item("Sync run", metadata_lookup(metadata, "sync_run_id"), mono: true),
          metadata_item(
            "Source device ID",
            metadata_first_value(metadata, ["source_device_id", "integration_id"]),
            mono: true
          )
        ]),
        metadata_vendor_group(
          "UniFi",
          "hero-wifi",
          metadata,
          [
            metadata_item("Controller", metadata_lookup(metadata, "controller_name")),
            metadata_item("Role", metadata_lookup(metadata, "device_role")),
            metadata_item("Bridge ports", metadata_lookup(metadata, "bridge_port_count"))
          ],
          ["controller_name", "controller_url", "unifi_api_names", "unifi_api_urls"]
        ),
        metadata_group("SNMP", "hero-radio", [
          metadata_item("Name", metadata_first_value(metadata, ["snmp_name", "sys_name"])),
          metadata_item(
            "Location",
            metadata_first_value(metadata, ["snmp_location", "sys_location"])
          ),
          metadata_item(
            "Contact",
            metadata_first_value(metadata, ["snmp_owner", "sys_owner", "sys_contact"])
          ),
          metadata_item("Object ID", metadata_lookup(metadata, "sys_object_id"), mono: true),
          metadata_item(
            "Uptime",
            metadata_uptime(metadata_first_value(metadata, ["uptime", "sys_uptime", "snmp_uptime"]))
          ),
          metadata_item(
            "Description",
            metadata_first_value(metadata, ["snmp_description", "sys_descr"])
          )
        ]),
        metadata_vendor_group(
          "MikroTik",
          "hero-cpu-chip",
          metadata,
          [
            metadata_item("API names", metadata_lookup(metadata, "mikrotik_api_names"))
          ],
          ["mikrotik_api_names", "mikrotik_api_urls"]
        ),
        proxmox_metadata_group(metadata),
        metadata_group("Discovery", "hero-map", [
          metadata_item("Discovery ID", metadata_lookup(metadata, "discovery_id"), mono: true),
          metadata_item(
            "Discovery time",
            metadata_timestamp(metadata_lookup(metadata, "discovery_time")),
            mono: true
          ),
          metadata_item("Mapper job", metadata_lookup(metadata, "mapper_job_name")),
          metadata_item("Mapper job ID", metadata_lookup(metadata, "mapper_job_id"), mono: true)
        ]),
        metadata_group("Classification", "hero-tag", [
          metadata_item("Source", metadata_lookup(metadata, "classification_source")),
          metadata_item("Confidence", metadata_lookup(metadata, "classification_confidence")),
          metadata_item("Reason", metadata_lookup(metadata, "classification_reason"))
        ]),
        armis_metadata_group(metadata, sources),
        netbox_metadata_group(metadata, sources),
        device_descriptor_group(metadata),
        metadata_group("Sweep", "hero-signal", [
          metadata_item("Available count", metadata_lookup(metadata, "scan_available_count")),
          metadata_item("Unavailable count", metadata_lookup(metadata, "scan_unavailable_count")),
          metadata_item("Availability", metadata_lookup(metadata, "scan_availability_percent"))
        ])
      ],
      &(&1.items == [])
    )
  end

  defp metadata_group(title, icon, items, opts \\ []) do
    %{
      title: title,
      icon: icon,
      logo: Keyword.get(opts, :logo),
      items: Enum.reject(items, &is_nil/1)
    }
  end

  defp metadata_vendor_group(title, icon, metadata, items, source_keys) do
    if metadata_source_evidence?(metadata, source_keys) do
      metadata_group(title, icon, items)
    else
      metadata_group(title, icon, [])
    end
  end

  defp proxmox_metadata_group(metadata) when is_map(metadata) do
    if proxmox_metadata_evidence?(metadata) do
      metadata_group(
        "Proxmox",
        "hero-cube-transparent",
        [
          metadata_item("Candidate", metadata_lookup(metadata, "proxmox_candidate")),
          metadata_item("Evidence", metadata_lookup(metadata, "proxmox_candidate_evidence")),
          metadata_item("Service", metadata_lookup(metadata, "proxmox_candidate_service")),
          metadata_item("Port", metadata_lookup(metadata, "proxmox_candidate_port")),
          metadata_item("Title", metadata_lookup(metadata, "proxmox_candidate_title"))
        ],
        logo: :proxmox
      )
    else
      metadata_group("Proxmox", "hero-cube-transparent", [], logo: :proxmox)
    end
  end

  defp proxmox_metadata_group(_metadata), do: metadata_group("Proxmox", "hero-cube-transparent", [], logo: :proxmox)

  defp proxmox_metadata_evidence?(metadata) when is_map(metadata) do
    truthy?(metadata_lookup(metadata, "proxmox_candidate")) or
      metadata_present?(metadata_lookup(metadata, "proxmox_candidate_evidence")) or
      metadata_source_evidence?(metadata, ["proxmox_candidate", "proxmox_api"])
  end

  # ---------------------------------------------------------------------------
  # Integration-provenance gating
  #
  # Armis/NetBox cards must only render for devices that genuinely came from
  # those systems. Provenance is proven by a source-specific metadata key
  # (e.g. `armis_device_id`, `netbox_device_id`), an `integration_type` match,
  # or membership in the device's authoritative `discovery_sources` array — NOT
  # by generic look-alike fields (`source_device_id`, `device_role`, `status`,
  # `device_type`) that every discovery source populates. Those generic fields
  # are surfaced under the neutral "Device" group instead, so the label always
  # matches reality.
  # ---------------------------------------------------------------------------

  defp armis_metadata_group(metadata, sources) when is_map(metadata) do
    if integration_provenance?(metadata, sources, "armis", ["armis_device_id", "armis_id"]) do
      metadata_group(
        "Armis",
        "hero-shield-check",
        [
          metadata_item(
            "Device ID",
            metadata_first_value(metadata, ["armis_device_id", "armis_id"]),
            mono: true,
            external_href: metadata_lookup(metadata, "armis_device_url")
          ),
          metadata_item(
            "Type",
            metadata_first_value(metadata, ["armis_type", "device_type", "type"])
          ),
          metadata_item(
            "Category",
            metadata_first_value(metadata, ["armis_category", "category"])
          ),
          metadata_item(
            "Boundaries",
            metadata_first_value(metadata, ["armis_boundary_names", "boundary_names"])
          ),
          metadata_item("Risk level", metadata_lookup(metadata, "armis_risk_level")),
          metadata_item(
            "Risk score",
            metadata_first_value(metadata, ["armis_risk_score", "risk_score"])
          ),
          metadata_item(
            "Tags",
            metadata_first_value(metadata, ["armis_tags", "source_tags", "tags"])
          ),
          metadata_item(
            "Visibility",
            metadata_first_value(metadata, ["armis_visibility", "visibility"])
          ),
          metadata_item(
            "Purdue level",
            metadata_first_value(metadata, ["armis_purdue_level", "purdue_level"])
          ),
          metadata_item(
            "Serial numbers",
            metadata_first_value(metadata, [
              "armis_serial_numbers",
              "serial_numbers",
              "serial_number"
            ])
          )
        ],
        logo: :armis
      )
    else
      metadata_group("Armis", "hero-shield-check", [], logo: :armis)
    end
  end

  defp armis_metadata_group(_metadata, _sources), do: metadata_group("Armis", "hero-shield-check", [], logo: :armis)

  defp netbox_metadata_group(metadata, sources) when is_map(metadata) do
    netbox_keys = ["netbox_device_id", "netbox_id", "netbox_role", "netbox_device_type", "netbox_tags"]

    if integration_provenance?(metadata, sources, "netbox", netbox_keys) do
      metadata_group(
        "NetBox",
        "hero-server-stack",
        [
          metadata_item(
            "Device ID",
            metadata_first_value(metadata, ["netbox_device_id", "netbox_id"]),
            mono: true
          ),
          metadata_item(
            "Site",
            summarize_json_metadata(metadata_first_value(metadata, ["site", "site_name", "site_slug"]))
          ),
          metadata_item(
            "Tenant",
            summarize_json_metadata(metadata_first_value(metadata, ["tenant", "tenant_name", "account"]))
          ),
          metadata_item(
            "Role",
            metadata_first_value(metadata, ["netbox_role", "device_role", "role", "device_role_name"])
          ),
          metadata_item("Status", metadata_first_value(metadata, ["status", "device_status"])),
          metadata_item(
            "Platform",
            metadata_first_value(metadata, ["platform", "platform_name"])
          ),
          metadata_item(
            "Rack",
            summarize_json_metadata(metadata_first_value(metadata, ["rack", "rack_name"]))
          ),
          metadata_item(
            "Location",
            summarize_json_metadata(metadata_first_value(metadata, ["location", "location_name"]))
          ),
          metadata_item("Tags", metadata_first_value(metadata, ["netbox_tags", "tags"]))
        ],
        logo: :netbox
      )
    else
      metadata_group("NetBox", "hero-server-stack", [], logo: :netbox)
    end
  end

  defp netbox_metadata_group(_metadata, _sources), do: metadata_group("NetBox", "hero-server-stack", [], logo: :netbox)

  # Neutral home for generic device descriptors that any discovery source may
  # populate. These are NOT integration provenance, so they never imply Armis /
  # NetBox / etc. — they simply describe the device. Hardware/OS and identity
  # fields live here too so we do not split the same facts across a second
  # "Inventory" card.
  defp device_descriptor_group(metadata) when is_map(metadata) do
    metadata_group("Device", "hero-computer-desktop", [
      metadata_item(
        "Role",
        metadata_first_value(metadata, ["device_role", "role", "device_role_name"])
      ),
      metadata_item("Type", metadata_first_value(metadata, ["device_type", "type"])),
      metadata_item("Status", metadata_first_value(metadata, ["status", "device_status"])),
      metadata_item("Manufacturer", metadata_lookup(metadata, "manufacturer")),
      metadata_item("Model", metadata_lookup(metadata, "model")),
      metadata_item("OS", metadata_lookup(metadata, "operating_system")),
      metadata_item("Identity source", metadata_lookup(metadata, "identity_source")),
      metadata_item("Identity state", metadata_lookup(metadata, "identity_state"))
    ])
  end

  defp device_descriptor_group(_metadata), do: metadata_group("Device", "hero-computer-desktop", [])

  defp integration_provenance?(metadata, sources, name, specific_keys) when is_map(metadata) and is_list(specific_keys) do
    MapSet.member?(sources, name) or
      integration_type_matches?(metadata, name) or
      Enum.any?(specific_keys, fn key -> metadata_present?(metadata_lookup(metadata, key)) end)
  end

  defp integration_provenance?(_metadata, _sources, _name, _specific_keys), do: false

  defp integration_type_matches?(metadata, name) when is_map(metadata) do
    case metadata_lookup(metadata, "integration_type") do
      value when is_binary(value) -> String.downcase(value) == name
      _ -> false
    end
  end

  defp integration_type_matches?(_metadata, _name), do: false

  # Build the authoritative set of discovery sources for this device from the
  # top-level `discovery_sources` array (DIRE-merged). Accepts a decoded list,
  # atom values, or a raw Postgres text-array literal ("{armis,sweep}").
  defp metadata_discovery_source_set(row) when is_map(row) do
    row
    |> Map.get("discovery_sources", Map.get(row, :discovery_sources))
    |> normalize_discovery_sources()
    |> MapSet.new()
  end

  defp metadata_discovery_source_set(_row), do: MapSet.new()

  defp normalize_discovery_sources(list) when is_list(list) do
    list
    |> Enum.map(&normalize_discovery_source/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp normalize_discovery_sources(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.trim_leading("{")
    |> String.trim_trailing("}")
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim(&1, "\""))
    |> normalize_discovery_sources()
  end

  defp normalize_discovery_sources(_value), do: []

  defp normalize_discovery_source(value) when is_binary(value), do: value |> String.trim() |> String.downcase()

  defp normalize_discovery_source(value) when is_atom(value) and not is_nil(value),
    do: value |> Atom.to_string() |> String.downcase()

  defp normalize_discovery_source(_value), do: ""

  defp metadata_source_evidence?(metadata, source_keys) when is_map(metadata) and is_list(source_keys) do
    metadata
    |> metadata_source_names()
    |> Enum.any?(fn source ->
      Enum.any?(source_keys, fn key -> String.contains?(source, metadata_source_token(key)) end)
    end)
  end

  defp metadata_source_evidence?(_metadata, _source_keys), do: false

  defp metadata_source_names(metadata) when is_map(metadata) do
    metadata
    |> Map.take(["source", "classification_source", "integration_type", "identity_source"])
    |> Map.values()
    |> Enum.flat_map(&metadata_source_name_values/1)
    |> Enum.map(&String.downcase/1)
  end

  defp metadata_source_name_values(value) when is_binary(value), do: [value]

  defp metadata_source_name_values(values) when is_list(values) do
    values
    |> Enum.map(&to_string/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp metadata_source_name_values(_), do: []

  defp metadata_source_token(key) when is_binary(key) do
    key
    |> String.split("_", parts: 2)
    |> List.first()
  end

  defp metadata_item(label, value, opts \\ []) do
    if metadata_present?(value) do
      %{
        label: label,
        value:
          if(match?(%DateTime{}, value) or match?(%NaiveDateTime{}, value),
            do: value,
            else: format_metadata_value(value)
          ),
        mono: Keyword.get(opts, :mono, false),
        href: Keyword.get(opts, :href),
        external_href: Keyword.get(opts, :external_href)
      }
    end
  end

  defp passive_fingerprint_rows(row) when is_map(row) do
    metadata = row_metadata(row)
    nested = metadata_lookup(metadata, "passive_fingerprint") || %{}
    os_payload = passive_os_payload(row, metadata)

    Enum.reject(
      [
        passive_protocol_row("TCP", passive_protocol_payload(metadata, nested, "tcp"), [
          metadata_item("OS family", passive_value(metadata, nested, "tcp", "os_family")),
          metadata_item("OS name", passive_value(metadata, nested, "tcp", "os_name")),
          metadata_item("Signature", passive_value(metadata, nested, "tcp", "signature"), mono: true),
          metadata_item("Confidence", passive_value(metadata, nested, "tcp", "confidence")),
          metadata_item("OS source", metadata_lookup(os_payload, "source"))
        ]),
        passive_protocol_row("TLS", passive_protocol_payload(metadata, nested, "tls"), [
          metadata_item("JA4", passive_value(metadata, nested, "tls", "ja4"), mono: true),
          metadata_item("JA4S", passive_value(metadata, nested, "tls", "ja4s"), mono: true),
          metadata_item("SNI", passive_value(metadata, nested, "tls", "sni_redacted"))
        ]),
        passive_protocol_row("HTTP", passive_protocol_payload(metadata, nested, "http"), [
          metadata_item("Server", passive_value(metadata, nested, "http", "server")),
          metadata_item("User agent", passive_value(metadata, nested, "http", "user_agent")),
          metadata_item("Accept language", passive_value(metadata, nested, "http", "accept_language"))
        ])
      ],
      &is_nil/1
    )
  end

  defp passive_fingerprint_rows(_row), do: []

  defp active_fingerprint_summary(row) when is_map(row) do
    payload = active_os_payload(row)

    items =
      Enum.reject(
        [
          metadata_item("OS family", metadata_lookup(payload, "family")),
          metadata_item("OS name", metadata_lookup(payload, "name")),
          metadata_item("Version range", metadata_lookup(payload, "version_range")),
          metadata_item("Confidence", metadata_lookup(payload, "confidence")),
          metadata_item("Last observed", metadata_timestamp(metadata_lookup(payload, "observed_at")), mono: true)
        ],
        &is_nil/1
      )

    %{source: metadata_lookup(payload, "source"), items: items}
  end

  defp active_fingerprint_summary(_row), do: %{source: nil, items: []}

  defp active_fingerprint_rows(row) when is_map(row) do
    metadata = row_metadata(row)
    active = active_fingerprint_payload(row)
    recog = active_recog_payload(active)
    observed_at = active_observed_at(row, active)

    @active_fingerprint_protocols
    |> Enum.map(fn {protocol, label} ->
      active_protocol_row(
        label,
        active_protocol_payload(metadata, recog, protocol),
        metadata,
        protocol,
        observed_at
      )
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp active_fingerprint_rows(_row), do: []

  defp active_protocol_row(label, payload, metadata, protocol, observed_at) do
    product = active_value(metadata, payload, protocol, "product")
    version = active_value(metadata, payload, protocol, "version")
    os_family = active_value(metadata, payload, protocol, "os_family")
    vendor = active_value(metadata, payload, protocol, "vendor")

    if Enum.any?([product, version, os_family, vendor], &metadata_present?/1) do
      %{
        protocol: label,
        port: format_metadata_value(active_value(metadata, payload, protocol, "port")),
        product: format_metadata_value(product),
        version: format_metadata_value(version),
        os: active_os_label(os_family, vendor),
        source: format_metadata_value(active_row_source(metadata, payload, protocol)),
        observed_at: metadata_timestamp(active_observed_at(metadata, payload, protocol)) || observed_at
      }
    end
  end

  defp active_os_label(os_family, vendor) do
    [vendor, os_family]
    |> Enum.filter(&metadata_present?/1)
    |> Enum.map_join(" / ", &format_metadata_value/1)
    |> case do
      "" -> "—"
      value -> value
    end
  end

  defp active_fingerprint_payload(row) do
    metadata = row_metadata(row)

    case metadata_lookup(metadata, "active_fingerprint") do
      payload when is_map(payload) -> payload
      _ -> %{}
    end
  end

  defp active_recog_payload(active) when is_map(active) do
    case metadata_lookup(active, "recog") do
      payload when is_map(payload) -> payload
      _ -> %{}
    end
  end

  defp active_recog_payload(_active), do: %{}

  defp active_protocol_payload(metadata, recog, protocol) do
    case Map.get(recog, protocol) || metadata_lookup(metadata, "active_fingerprint.recog.#{protocol}") do
      payload when is_map(payload) -> payload
      _ -> %{}
    end
  end

  defp active_value(metadata, payload, protocol, key) do
    metadata_lookup(payload, key) ||
      metadata_lookup(metadata, "active_fingerprint.recog.#{protocol}.#{key}")
  end

  defp active_row_source(metadata, payload, protocol) do
    [
      active_value(metadata, payload, protocol, "source") ||
        metadata_lookup(metadata, "active_fingerprint.source") ||
        "sweep_active",
      source_context("profile", active_source_context(metadata, payload, protocol, "profile_id")),
      source_context("sweep", active_source_context(metadata, payload, protocol, "sweep_cycle"))
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" / ")
  end

  defp active_source_context(metadata, payload, protocol, key) do
    active_value(metadata, payload, protocol, key) ||
      active_value(metadata, payload, protocol, String.replace(key, "_id", "")) ||
      metadata_lookup(metadata, "active_fingerprint.#{key}")
  end

  defp source_context(_label, nil), do: nil
  defp source_context(_label, ""), do: nil
  defp source_context(label, value), do: "#{label}: #{format_metadata_value(value)}"

  defp active_observed_at(row, active) when is_map(row) do
    metadata = row_metadata(row)

    metadata_timestamp(metadata_lookup(active, "observed_at")) ||
      metadata_timestamp(metadata_lookup(active_os_payload(row), "observed_at")) ||
      metadata_timestamp(metadata_lookup(metadata, "active_fingerprint.observed_at"))
  end

  defp active_observed_at(metadata, payload, protocol) do
    active_value(metadata, payload, protocol, "observed_at")
  end

  defp active_os_payload(row) do
    active = active_fingerprint_payload(row)
    os = Map.get(row, "os") || Map.get(row, "os_info") || %{}

    cond do
      is_map(active) and is_map(metadata_lookup(active, "os")) ->
        metadata_lookup(active, "os")

      is_map(os) and is_map(metadata_lookup(os, "active_fingerprint")) ->
        metadata_lookup(os, "active_fingerprint")

      true ->
        %{}
    end
  end

  defp dpi_rows(row) when is_map(row) do
    metadata = row_metadata(row)
    nested = metadata_lookup(metadata, "dpi") || %{}

    @dpi_protocols
    |> Enum.map(fn {protocol, label} ->
      dpi_protocol_row(
        label,
        dpi_protocol_payload(nested, protocol),
        [
          metadata_item("Count", dpi_value(metadata, nested, protocol, "count")),
          metadata_item("Confidence", dpi_value(metadata, nested, protocol, "confidence")),
          metadata_item(
            "Last observed",
            metadata_timestamp(dpi_value(metadata, nested, protocol, "last_observed_at")),
            mono: true
          )
        ],
        metadata
      )
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp dpi_rows(_row), do: []

  defp passive_protocol_row(protocol, payload, items) do
    items = Enum.reject(items, &is_nil/1)

    if items == [] do
      nil
    else
      %{
        protocol: protocol,
        source: metadata_lookup(payload, "source"),
        items: items
      }
    end
  end

  defp dpi_protocol_row(protocol, payload, items, metadata) do
    items = Enum.reject(items, &is_nil/1)

    if items == [] do
      nil
    else
      %{
        protocol: protocol,
        source: metadata_lookup(payload, "source") || metadata_lookup(metadata, "dpi.source"),
        items: items
      }
    end
  end

  defp dpi_protocol_payload(nested, protocol) when is_map(nested) do
    case Map.get(nested, protocol) || Map.get(nested, dpi_protocol_atom(protocol)) do
      payload when is_map(payload) -> payload
      _ -> %{}
    end
  end

  defp dpi_protocol_atom("http1"), do: :http1
  defp dpi_protocol_atom("http2"), do: :http2
  defp dpi_protocol_atom("tls"), do: :tls
  defp dpi_protocol_atom("dns"), do: :dns
  defp dpi_protocol_atom("ssh"), do: :ssh
  defp dpi_protocol_atom("ftp"), do: :ftp
  defp dpi_protocol_atom("quic"), do: :quic
  defp dpi_protocol_atom("mqtt"), do: :mqtt
  defp dpi_protocol_atom("bittorrent"), do: :bittorrent
  defp dpi_protocol_atom(_), do: nil

  defp dpi_value(metadata, nested, protocol, key) do
    metadata_lookup(dpi_protocol_payload(nested, protocol), key) ||
      metadata_lookup(metadata, "dpi.#{protocol}.#{key}")
  end

  defp passive_protocol_payload(_metadata, nested, protocol) when is_map(nested) do
    case Map.get(nested, protocol) || Map.get(nested, passive_protocol_atom(protocol)) do
      payload when is_map(payload) -> payload
      _ -> %{}
    end
  end

  defp passive_protocol_atom("tcp"), do: :tcp
  defp passive_protocol_atom("tls"), do: :tls
  defp passive_protocol_atom("http"), do: :http
  defp passive_protocol_atom(_), do: nil

  defp passive_value(metadata, nested, protocol, key) do
    metadata_lookup(passive_protocol_payload(metadata, nested, protocol), key) ||
      metadata_lookup(metadata, "passive_fingerprint.#{protocol}.#{key}")
  end

  defp passive_os_payload(row, metadata) do
    os = Map.get(row, "os") || Map.get(row, "os_info") || %{}

    case os do
      %{} = os_map -> metadata_lookup(os_map, "passive_fingerprint") || %{}
      _ -> metadata_lookup(metadata, "os.passive_fingerprint") || %{}
    end
  end

  def active_fingerprint_tab_visible?(row, scope) when is_map(row) do
    can_view_active_fingerprint?(scope) and
      (active_fingerprint_summary(row).items != [] or active_fingerprint_rows(row) != [])
  end

  def active_fingerprint_tab_visible?(_row, _scope), do: false

  def process_listeners_tab_visible?(row) when is_map(row) do
    agent_device?(row) or process_listener_rows(row) != []
  end

  def process_listeners_tab_visible?(_row), do: false

  defp process_listener_snapshot(row) when is_map(row) do
    metadata = row_metadata(row)

    payload =
      metadata
      |> metadata_lookup("local_processes")
      |> decode_metadata_payload()

    entries =
      payload
      |> process_listener_payload_entries(metadata)
      |> Enum.map(&process_listener_entry/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.sort_by(fn row ->
        {row.transport_protocol || "", row.local_ip || "", row.local_port || 0, row.pid || 0}
      end)

    %{
      fingerprint:
        metadata_lookup(payload, "fingerprint") ||
          metadata_lookup(metadata, "local_processes.fingerprint"),
      observed_at: process_listener_observed_at(payload, metadata),
      entries: entries
    }
  end

  defp process_listener_snapshot(_row), do: %{fingerprint: nil, observed_at: nil, entries: []}

  defp process_listener_rows(row), do: row |> process_listener_snapshot() |> Map.get(:entries, [])

  defp process_listener_payload_entries(payload, metadata) when is_map(payload) do
    entries =
      metadata_lookup(payload, "entries") ||
        metadata_lookup(metadata, "local_processes.entries") ||
        []

    entries
    |> decode_metadata_payload()
    |> List.wrap()
  end

  defp process_listener_payload_entries(payload, _metadata) when is_list(payload), do: payload
  defp process_listener_payload_entries(_payload, _metadata), do: []

  defp process_listener_entry(entry) when is_map(entry) do
    %{
      local_ip: process_listener_value(entry, ["local_ip", "localIp"]),
      local_port: process_listener_integer(process_listener_value(entry, ["local_port", "localPort"])),
      transport_protocol:
        entry
        |> process_listener_value(["transport_protocol", "transportProtocol"])
        |> process_listener_protocol(),
      pid: process_listener_integer(process_listener_value(entry, ["pid"])),
      tgid: process_listener_integer(process_listener_value(entry, ["tgid"])),
      uid: process_listener_integer(process_listener_value(entry, ["uid"])),
      gid: process_listener_integer(process_listener_value(entry, ["gid"])),
      comm: process_listener_value(entry, ["comm"]),
      redacted_cmdline:
        entry
        |> process_listener_value(["redacted_cmdline", "redactedCmdline"])
        |> process_listener_cmdline_parts(),
      container_id: process_listener_value(entry, ["container_id", "containerId"])
    }
  end

  defp process_listener_entry(_entry), do: nil

  defp process_listener_value(map, keys) when is_map(map) and is_list(keys) do
    Enum.find_value(keys, fn key ->
      Map.get(map, key) || process_listener_atom_value(map, key)
    end)
  end

  defp process_listener_atom_value(map, key) when is_binary(key) do
    Map.get(map, String.to_existing_atom(key))
  rescue
    ArgumentError -> nil
  end

  defp process_listener_integer(value) when is_integer(value), do: value

  defp process_listener_integer(value) when is_binary(value) do
    value
    |> String.trim()
    |> Integer.parse()
    |> case do
      {integer, ""} -> integer
      _ -> nil
    end
  end

  defp process_listener_integer(_value), do: nil

  defp process_listener_protocol(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.upcase()
  end

  defp process_listener_protocol(_value), do: nil

  defp process_listener_observed_at(payload, metadata) do
    value =
      metadata_lookup(payload, "observed_at") ||
        metadata_lookup(metadata, "local_processes.observed_at") ||
        process_listener_unix_nano_timestamp(
          metadata_lookup(payload, "observed_at_unix_nano") ||
            metadata_lookup(payload, "observedAtUnixNano") ||
            metadata_lookup(metadata, "local_processes.observed_at_unix_nano")
        )

    metadata_timestamp(value)
  end

  defp process_listener_unix_nano_timestamp(nil), do: nil

  defp process_listener_unix_nano_timestamp(value) when is_binary(value) do
    value
    |> String.trim()
    |> Integer.parse()
    |> case do
      {integer, ""} -> process_listener_unix_nano_timestamp(integer)
      _ -> nil
    end
  end

  defp process_listener_unix_nano_timestamp(value) when is_integer(value) do
    case DateTime.from_unix(value, :nanosecond) do
      {:ok, dt} -> dt
      _ -> nil
    end
  end

  defp process_listener_unix_nano_timestamp(_value), do: nil

  defp process_listener_cmdline_parts(value) when is_list(value) do
    value
    |> Enum.map(&to_string/1)
    |> Enum.reject(&(String.trim(&1) == ""))
  end

  defp process_listener_cmdline_parts(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} -> process_listener_cmdline_parts(decoded)
      _ -> [value]
    end
  end

  defp process_listener_cmdline_parts(_value), do: []

  defp process_listener_endpoint(row) do
    ip = row.local_ip || "—"
    port = row.local_port || "—"

    if is_binary(ip) and String.contains?(ip, ":") do
      "[#{ip}]:#{port}"
    else
      "#{ip}:#{port}"
    end
  end

  defp process_listener_uid_gid(row) do
    uid = row.uid || "—"
    gid = row.gid || "—"
    "#{uid}/#{gid}"
  end

  defp process_listener_container(nil), do: "—"
  defp process_listener_container(""), do: "—"
  defp process_listener_container(value) when is_binary(value), do: String.slice(value, 0, 12)
  defp process_listener_container(value), do: to_string(value)

  defp process_listener_cmdline([]), do: "—"
  defp process_listener_cmdline(parts) when is_list(parts), do: Enum.join(parts, " ")
  defp process_listener_cmdline(value), do: default_display(value)

  defp decode_metadata_payload(nil), do: %{}
  defp decode_metadata_payload(value) when is_map(value) or is_list(value), do: value

  defp decode_metadata_payload(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} -> decoded
      _ -> %{}
    end
  end

  defp decode_metadata_payload(_value), do: %{}

  def metadata_lookup(metadata, key) when is_map(metadata) do
    Map.get(metadata, key)
  end

  def metadata_lookup(_metadata, _key), do: nil

  defp metadata_timestamp(nil), do: nil

  defp metadata_timestamp(value) do
    case parse_datetime(value) do
      {:ok, %DateTime{} = datetime} -> datetime
      _ -> value
    end
  end

  defp metadata_uptime(nil), do: nil

  defp metadata_uptime(value) when is_binary(value) do
    value
    |> String.trim()
    |> Integer.parse()
    |> case do
      {integer, ""} -> metadata_uptime(integer)
      _ -> value
    end
  end

  defp metadata_uptime(value) when is_number(value) and value >= 0 do
    value
    |> Kernel./(100)
    |> Float.round()
    |> trunc()
    |> metadata_duration()
  end

  defp metadata_uptime(value), do: value

  defp metadata_duration(seconds) when is_integer(seconds) do
    days = div(seconds, 86_400)
    hours = seconds |> rem(86_400) |> div(3_600)
    minutes = seconds |> rem(3_600) |> div(60)

    [
      if(days > 0, do: "#{days}d"),
      if(hours > 0, do: "#{hours}h"),
      if(minutes > 0, do: "#{minutes}m")
    ]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> "#{seconds}s"
      parts -> Enum.join(parts, " ")
    end
  end

  defp metadata_present?(nil), do: false

  defp metadata_present?(value) when is_binary(value) do
    String.trim(value) not in ["", "nil", "null"]
  end

  defp metadata_present?(value) when is_list(value), do: value != []
  defp metadata_present?(value) when is_map(value), do: map_size(value) > 0
  defp metadata_present?(_value), do: true

  defp format_metadata_value(nil), do: "—"
  defp format_metadata_value(""), do: "—"
  defp format_metadata_value(true), do: "Yes"
  defp format_metadata_value(false), do: "No"

  defp format_metadata_value(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.slice(0, 160)
  end

  defp format_metadata_value(value) when is_number(value), do: to_string(value)

  defp format_metadata_value(value) when is_list(value) do
    values =
      value
      |> Enum.map(&format_metadata_value/1)
      |> Enum.reject(&(&1 in ["", "—"]))

    shown = Enum.take(values, 4)
    suffix = if length(values) > 4, do: " +#{length(values) - 4}", else: ""

    Enum.join(shown, ", ") <> suffix
  end

  defp format_metadata_value(value) when is_map(value), do: "#{map_size(value)} fields"
  defp format_metadata_value(value), do: value |> to_string() |> String.slice(0, 160)

  defp row_metadata(row) when is_map(row) do
    case Map.get(row, "metadata") || Map.get(row, :metadata) do
      map when is_map(map) -> map
      _ -> %{}
    end
  end

  defp row_metadata(_row), do: %{}

  defp can_view_active_fingerprint?(scope), do: RBAC.can?(scope, "networks.sweeps.banner_grab")

  # Agent status comes from the ocsf_agents linkage resolved at load time
  # (DeviceStateData.tag_agent_device/2); the OCSF agent_list column is dead.
  defp agent_device?(row), do: DeviceStateData.agent?(row)

  defp default_display(nil), do: "—"
  defp default_display(""), do: "—"
  defp default_display(value), do: value

  defp truthy?(value), do: value in [true, "true", "on", "1", 1]

  defp metadata_first_value(metadata, keys) when is_map(metadata) and is_list(keys) do
    Enum.find_value(keys, fn key ->
      case Map.get(metadata, key) do
        value when value in [nil, ""] -> nil
        value -> value
      end
    end)
  end

  defp summarize_json_metadata(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} -> summarize_metadata_value(decoded)
      _ -> value
    end
  end

  defp summarize_json_metadata(value), do: summarize_metadata_value(value)

  defp summarize_metadata_value(value) when is_list(value) do
    case value do
      [] -> nil
      [%{} | _] -> "#{length(value)} items"
      _ -> Enum.map_join(value, ", ", &to_string/1)
    end
  end

  defp summarize_metadata_value(value) when is_map(value) do
    cond do
      map_size(value) == 0 -> nil
      is_binary(value["name"]) -> value["name"]
      is_binary(value["display"]) -> value["display"]
      true -> "#{map_size(value)} fields"
    end
  end

  defp summarize_metadata_value(value), do: value

  defp parse_datetime(%DateTime{} = dt), do: {:ok, dt}

  defp parse_datetime(%NaiveDateTime{} = ndt) do
    DateTime.from_naive(ndt, "Etc/UTC")
  end

  defp parse_datetime(value) when is_binary(value) do
    with {:error, _} <- DateTime.from_iso8601(value),
         {:ok, naive} <- NaiveDateTime.from_iso8601(value) do
      {:ok, DateTime.from_naive!(naive, "Etc/UTC")}
    else
      {:ok, datetime, _offset} -> {:ok, datetime}
      {:error, _} -> {:error, :invalid_datetime}
    end
  end

  defp parse_datetime(_), do: {:error, :invalid_datetime}

  defp visibility_device_key(row) do
    time_key(Map.get(row, "uid") || Map.get(row, "device_uid") || Map.get(row, "id") || "device")
  end

  defp time_key(value) do
    value
    |> to_string()
    |> String.replace(~r/[^a-zA-Z0-9_-]+/, "-")
    |> String.trim("-")
  end
end
