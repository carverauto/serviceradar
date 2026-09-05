defmodule ServiceRadarWebNGWeb.DeviceLive.EndpointInventoryComponents do
  @moduledoc false

  use ServiceRadarWebNGWeb, :html

  alias ServiceRadarWebNGWeb.DeviceLive.EndpointInventoryFindings
  alias ServiceRadarWebNGWeb.DeviceLive.EndpointInventoryMatchGroups

  @stale_scan_seconds 26 * 60 * 60

  attr(:scan, :any, default: nil)
  attr(:scans, :list, default: [])
  attr(:packages, :list, default: [])
  attr(:package_total, :integer, default: 0)
  attr(:package_page, :integer, default: 1)
  attr(:package_page_size, :integer, default: 100)
  attr(:stored_package_count, :integer, default: 0)
  attr(:artifacts, :list, default: [])
  attr(:vulnerability_assessments, :any, default: %{})
  attr(:cpe_catalog_current, :boolean, default: true)
  attr(:error, :string, default: nil)
  attr(:loading, :boolean, default: false)
  attr(:has_inventory, :boolean, default: false)
  attr(:show_controls, :boolean, default: false)
  attr(:device_row, :map, default: nil)
  attr(:query_form, :any, required: true)
  attr(:cohort_form, :any, required: true)
  attr(:package_filter_form, :any, required: true)
  attr(:live_query_result, :map, default: nil)
  attr(:cohort_query_result, :map, default: nil)
  attr(:command_notice, :string, default: nil)
  attr(:command_error, :string, default: nil)
  attr(:query_running, :boolean, default: false)
  attr(:force_refresh_running, :boolean, default: false)
  attr(:cohort_running, :boolean, default: false)
  attr(:timezone, :string, default: "Etc/UTC")

  def endpoint_inventory_section(assigns) do
    page_packages = assigns.packages || []
    page_size = max(assigns.package_page_size || 100, 1)
    total = assigns.package_total || length(page_packages)
    stored_total = assigns.stored_package_count || total
    page = max(assigns.package_page || 1, 1)
    total_pages = max(1, ceil(total / page_size))
    page = min(page, total_pages)
    first_row = if total == 0, do: 0, else: (page - 1) * page_size + 1
    last_row = min(page * page_size, total)

    assigns =
      assigns
      |> assign(:package_filter_params, form_params(assigns.package_filter_form))
      # `@packages` is already the server-side filtered + paginated page.
      |> assign(:page_packages, page_packages)
      |> assign(:package_total, total)
      |> assign(:stored_package_count, stored_total)
      |> assign(:current_page, page)
      |> assign(:total_pages, total_pages)
      |> assign(:first_row, first_row)
      |> assign(:last_row, last_row)
      |> assign(:scan_count, length(assigns.scans || []))
      |> assign(:risk_score, device_value(assigns.device_row, "risk_score"))
      |> assign(:risk_level, device_value(assigns.device_row, "risk_level"))
      |> assign(
        :software_state,
        software_state(assigns.scan, stored_total, assigns.has_inventory, assigns.show_controls)
      )

    ~H"""
    <section
      :if={@has_inventory or @show_controls or is_binary(@error) or field(@software_state, :show)}
      class="rounded-lg border border-sr-line bg-sr-surface shadow-sm"
    >
      <div class="flex flex-col gap-3 border-b border-sr-line px-4 py-3 md:flex-row md:items-center md:justify-between">
        <div>
          <h2 class="text-sm font-semibold text-sr-ink">Endpoint Software</h2>
          <p class="text-xs text-sr-muted">
            {@stored_package_count} current package rows | {@scan_count} scans
          </p>
        </div>
        <div class="flex flex-wrap items-center gap-2">
          <.scan_status_badge scan={@scan} />
          <.risk_badge risk_level={@risk_level} risk_score={@risk_score} />
        </div>
      </div>

      <div :if={is_binary(@error)} class="px-4 py-3 text-sm text-error">
        {@error}
      </div>

      <.software_state_notice state={@software_state} />

      <.ui_alert
        :if={@cpe_catalog_current == false}
        variant="warning"
        class="mx-4 mt-4"
        data-testid="cpe-catalog-notice"
      >
        CPE catalog is not current. Version-accurate NVD matches are unavailable; KEV name
        matches are lower confidence.
      </.ui_alert>

      <div
        :if={inventory_row_mismatch?(@scan, @stored_package_count)}
        class="mx-4 mt-4 rounded border border-warning/40 bg-warning/10 px-3 py-2 text-sm text-warning-content"
      >
        The latest scan reported {inventory_count(@scan, @stored_package_count)} packages, but only {@stored_package_count} current package rows are stored. Check ingest, row retention, and source diagnostics before treating this inventory as complete.
      </div>

      <div class="grid gap-4 p-4 lg:grid-cols-[minmax(0,0.9fr)_minmax(0,1.1fr)]">
        <div class="space-y-4">
          <div class="grid grid-cols-2 gap-3">
            <.summary_stat label="Packages" value={inventory_count(@scan, @stored_package_count)} />
            <.summary_stat label="Scans" value={@scan_count} />
            <.summary_stat label="Risk Score" value={risk_score_display(@risk_score)} />
            <.summary_stat label="Risk Level" value={risk_level_display(@risk_level)} />
            <.summary_stat label="Managers" value={map_size(manager_counts(@scan))} />
            <.summary_stat label="Last Success">
              <.user_time
                id={"endpoint-inventory-scan-#{record_dom_id(@scan, "scan")}-last-success-summary"}
                value={field(@scan, :last_successful_scan_at)}
                timezone={@timezone}
                style={:compact}
                fallback={timestamp_fallback(field(@scan, :last_successful_scan_at))}
              />
            </.summary_stat>
          </div>

          <div class="sr-ui-table-shell">
            <table class={ui_table_class(size: "sm")}>
              <tbody>
                <.scan_row label="State" value={field(@scan, :state)} />
                <.scan_row label="Coverage" value={field(@scan, :coverage_state)} />
                <.scan_row label="Agent" value={field(@scan, :agent_id)} mono />
                <.scan_row label="Collector" value={collector_label(@scan)} />
                <.scan_row label="Last Scan" mono>
                  <.user_time
                    id={"endpoint-inventory-scan-#{record_dom_id(@scan, "scan")}-last-scan-at"}
                    value={field(@scan, :last_scan_at)}
                    timezone={@timezone}
                    style={:full}
                    fallback={timestamp_fallback(field(@scan, :last_scan_at))}
                  />
                </.scan_row>
                <.scan_row label="Last Success" mono>
                  <.user_time
                    id={"endpoint-inventory-scan-#{record_dom_id(@scan, "scan")}-last-successful-scan-at"}
                    value={field(@scan, :last_successful_scan_at)}
                    timezone={@timezone}
                    style={:full}
                    fallback={timestamp_fallback(field(@scan, :last_successful_scan_at))}
                  />
                </.scan_row>
                <.scan_row label="Last Changed" mono>
                  <.user_time
                    id={"endpoint-inventory-scan-#{record_dom_id(@scan, "scan")}-last-changed-scan-at"}
                    value={field(@scan, :last_changed_scan_at)}
                    timezone={@timezone}
                    style={:full}
                    fallback={timestamp_fallback(field(@scan, :last_changed_scan_at))}
                  />
                </.scan_row>
                <.scan_row label="Upload Reason" value={field(@scan, :upload_reason)} />
                <.scan_row
                  label="Unchanged"
                  value={field(@scan, :unchanged_scan_count) || 0}
                />
                <.scan_row
                  label="Package Hash"
                  value={truncate_hash(field(@scan, :package_set_hash))}
                  mono
                />
                <.scan_row
                  label="Artifact Hash"
                  value={truncate_hash(field(@scan, :artifact_hash))}
                  mono
                />
                <.scan_row
                  label="Config Hash"
                  value={truncate_hash(field(@scan, :config_hash))}
                  mono
                />
                <.scan_row
                  :if={field(@scan, :package_set_hash_mismatch)}
                  label="Hash Check"
                  value="Mismatch"
                />
              </tbody>
            </table>
          </div>

          <div class="rounded border border-sr-line p-3">
            <div class="flex flex-wrap items-center justify-between gap-2">
              <h3 class="text-xs font-semibold uppercase text-sr-muted">Source Diagnostics</h3>
              <div :if={enabled_sources(@scan) != []} class="flex flex-wrap gap-1">
                <.ui_badge
                  :for={source <- enabled_sources(@scan)}
                  size="xs"
                  variant="outline"
                >
                  {source}
                </.ui_badge>
              </div>
            </div>

            <div
              :if={source_summaries(@scan) == []}
              class="mt-3 rounded bg-sr-subtle/40 px-3 py-2 text-xs text-sr-muted"
            >
              No source diagnostics were reported with this scan.
            </div>

            <div
              :if={source_summaries(@scan) != []}
              class="mt-3 overflow-hidden rounded border border-sr-line"
            >
              <table class={ui_table_class(size: "xs")}>
                <thead>
                  <tr>
                    <th>Source</th>
                    <th>State</th>
                    <th>Packages</th>
                    <th>Reason</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={source <- source_summaries(@scan)}>
                    <td class="font-mono">{field(source, :source) || field(source, :name) || "-"}</td>
                    <td>
                      <.ui_badge size="xs" variant={source_state_class(field(source, :state))}>
                        {field(source, :state) || "unknown"}
                      </.ui_badge>
                    </td>
                    <td class="font-mono">{field(source, :package_count) || 0}</td>
                    <td class="max-w-52 truncate text-sr-muted">
                      {field(source, :reason) || field(source, :error) ||
                        field(source, :skipped_reason) || "-"}
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          </div>

          <div :if={manager_counts(@scan) != %{}} class="rounded border border-sr-line p-3">
            <h3 class="text-xs font-semibold uppercase text-sr-muted">Package Managers</h3>
            <div class="mt-3 flex flex-wrap gap-2">
              <.ui_badge
                :for={{manager, count} <- manager_count_entries(@scan)}
                size="sm"
                variant="outline"
                class="gap-1"
              >
                <span class="font-mono">{manager}</span>
                <span>{count}</span>
              </.ui_badge>
            </div>
          </div>

          <div class="rounded border border-sr-line p-3">
            <div class="mb-3 flex items-center justify-between gap-2">
              <h3 class="text-xs font-semibold uppercase text-sr-muted">Live Query</h3>
              <span :if={@command_notice} class="text-xs text-success">{@command_notice}</span>
            </div>

            <div
              :if={@command_error}
              class="mb-3 rounded border border-error/30 bg-error/10 px-3 py-2 text-xs text-error"
            >
              {@command_error}
            </div>

            <.form for={@query_form} phx-submit="endpoint_inventory_query" class="grid gap-2">
              <div class="grid gap-2 md:grid-cols-2">
                <.input field={@query_form[:name]} label="Package" placeholder="nginx" />
                <.input field={@query_form[:package_manager]} label="Manager" placeholder="dpkg" />
                <.input field={@query_form[:version]} label="Version" />
                <.input
                  field={@query_form[:agent_id]}
                  label="Agent"
                  placeholder={field(@scan, :agent_id) || "agent id"}
                />
              </div>
              <.input field={@query_form[:purl_canonical]} label="Canonical PURL" />
              <.input field={@query_form[:cpe]} label="CPE" />
              <div class="flex flex-wrap items-center gap-2">
                <.input
                  field={@query_form[:mode]}
                  type="select"
                  label="Mode"
                  options={[{"Exists", "exists"}, {"Detail", "detail"}]}
                />
                <.ui_button
                  type="submit"
                  name="action"
                  value="query"
                  disabled={@query_running}
                  size="sm"
                  variant="primary"
                >
                  <.icon name="hero-magnifying-glass" class="h-4 w-4" /> Check
                </.ui_button>
                <.ui_button
                  type="submit"
                  name="action"
                  value="force_refresh"
                  disabled={@force_refresh_running}
                  size="sm"
                  variant="outline"
                >
                  <.icon name="hero-arrow-path" class="h-4 w-4" /> Refresh
                </.ui_button>
              </div>
            </.form>

            <.live_query_result result={@live_query_result} />
          </div>

          <div class="rounded border border-sr-line p-3">
            <h3 class="mb-3 text-xs font-semibold uppercase text-sr-muted">Cohort Query</h3>
            <.form for={@cohort_form} phx-submit="endpoint_inventory_cohort_query" class="grid gap-2">
              <div class="grid gap-2 md:grid-cols-2">
                <.input field={@cohort_form[:name]} label="Package" placeholder="nginx" />
                <.input field={@cohort_form[:package_manager]} label="Manager" placeholder="dpkg" />
                <.input field={@cohort_form[:version]} label="Version" />
                <.input
                  field={@cohort_form[:mode]}
                  type="select"
                  label="Mode"
                  options={[{"Count", "count"}, {"Exists", "exists"}, {"Detail", "detail"}]}
                />
              </div>
              <.input field={@cohort_form[:purl_canonical]} label="Canonical PURL" />
              <.input field={@cohort_form[:cpe]} label="CPE" />
              <div class="grid gap-2 md:grid-cols-[0.55fr_1fr_auto] md:items-end">
                <.input
                  field={@cohort_form[:cohort]}
                  type="select"
                  label="Targets"
                  options={[{"Connected", "connected"}, {"Custom", "custom"}]}
                />
                <.input
                  field={@cohort_form[:agent_ids]}
                  label="Agents"
                  placeholder="agent-a, agent-b"
                />
                <.ui_button type="submit" disabled={@cohort_running} size="sm" variant="soft">
                  <.icon name="hero-users" class="h-4 w-4" /> Query
                </.ui_button>
              </div>
            </.form>

            <.cohort_query_result result={@cohort_query_result} />
          </div>

          <div :if={@artifacts != []} class="overflow-hidden rounded border border-sr-line">
            <table class={ui_table_class(size: "sm")}>
              <thead>
                <tr>
                  <th>Artifact</th>
                  <th>Size</th>
                  <th>Uploaded</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={artifact <- @artifacts}>
                  <td class="max-w-64 truncate font-mono text-xs">{field(artifact, :object_key)}</td>
                  <td class="font-mono text-xs">{format_bytes(field(artifact, :size_bytes))}</td>
                  <td class="font-mono text-xs">
                    <.user_time
                      id={"endpoint-inventory-artifact-#{record_dom_id(artifact, "artifact")}-uploaded-at"}
                      value={field(artifact, :uploaded_at)}
                      timezone={@timezone}
                      style={:full}
                      fallback={timestamp_fallback(field(artifact, :uploaded_at))}
                    />
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>

        <div class="space-y-4">
          <.vulnerability_assessments_sections
            assessment_pages={@vulnerability_assessments}
            loading={@loading}
            timezone={@timezone}
          />

          <div class="overflow-hidden rounded border border-sr-line">
            <div class="border-b border-sr-line bg-sr-subtle/30 p-3">
              <div class="flex flex-col gap-1 md:flex-row md:items-center md:justify-between">
                <div>
                  <h3 class="text-xs font-semibold uppercase text-sr-muted">
                    Current Packages
                  </h3>
                  <p class="text-xs text-sr-muted">
                    {package_range_label(@first_row, @last_row, @package_total)}
                    <span :if={package_filters_active?(@package_filter_params)}>
                      (of {@stored_package_count} total)
                    </span>
                  </p>
                </div>
                <.ui_badge
                  :if={package_filters_active?(@package_filter_params)}
                  size="sm"
                  variant="info"
                >
                  Filtered
                </.ui_badge>
              </div>

              <.form
                for={@package_filter_form}
                id="endpoint-inventory-package-filter"
                phx-change="endpoint_inventory_package_filter"
                class="mt-3 grid gap-2 md:grid-cols-5"
              >
                <.input
                  field={@package_filter_form[:q]}
                  label="Package"
                  placeholder="name, version, coordinate"
                  phx-debounce="300"
                />
                <.input
                  field={@package_filter_form[:package_manager]}
                  label="Manager"
                  placeholder="dpkg"
                  phx-debounce="300"
                />
                <.input
                  field={@package_filter_form[:version]}
                  label="Version"
                  phx-debounce="300"
                />
                <.input
                  field={@package_filter_form[:purl]}
                  label="PURL"
                  phx-debounce="300"
                />
                <.input
                  field={@package_filter_form[:cpe]}
                  label="CPE"
                  phx-debounce="300"
                />
              </.form>
            </div>

            <table class={ui_table_class(size: "sm")}>
              <thead>
                <tr>
                  <th>Package</th>
                  <th>Version</th>
                  <th>Manager</th>
                  <th>Coordinate</th>
                </tr>
              </thead>
              <tbody>
                <tr :if={@package_total == 0 and @stored_package_count == 0}>
                  <td colspan="4" class="py-6 text-center text-sm text-sr-muted">
                    {field(@software_state, :empty_message)}
                  </td>
                </tr>
                <tr :if={@package_total == 0 and @stored_package_count > 0}>
                  <td colspan="4" class="py-6 text-center text-sm text-sr-muted">
                    No package rows match the current filters.
                  </td>
                </tr>
                <tr
                  :for={package <- @page_packages}
                  class="cursor-pointer hover"
                  phx-click="endpoint_inventory_open_package"
                  phx-value-ref={field(package, :id)}
                  title="View package details"
                >
                  <td class="font-medium">{field(package, :name)}</td>
                  <td class="font-mono text-xs">{empty_dash(field(package, :version))}</td>
                  <td>
                    <.ui_badge size="sm" variant="outline">
                      {field(package, :package_manager)}
                    </.ui_badge>
                  </td>
                  <td class="max-w-80 truncate font-mono text-xs">
                    {field(package, :purl_canonical) || field(package, :purl) ||
                      List.first(field(package, :cpes) || []) || "-"}
                  </td>
                </tr>
              </tbody>
            </table>

            <div
              :if={@total_pages > 1}
              class="flex items-center justify-between gap-2 border-t border-sr-line bg-sr-subtle/30 px-3 py-2"
            >
              <span class="text-xs text-sr-muted">
                Page {@current_page} of {@total_pages}
              </span>
              <div class={ui_join_class()}>
                <.ui_button
                  type="button"
                  phx-click="endpoint_inventory_package_page"
                  phx-value-page={@current_page - 1}
                  disabled={@current_page <= 1}
                  size="xs"
                  variant="neutral"
                >
                  <.icon name="hero-chevron-left" class="h-3 w-3" /> Prev
                </.ui_button>
                <.ui_button
                  type="button"
                  phx-click="endpoint_inventory_package_page"
                  phx-value-page={@current_page + 1}
                  disabled={@current_page >= @total_pages}
                  size="xs"
                  variant="neutral"
                >
                  Next <.icon name="hero-chevron-right" class="h-3 w-3" />
                </.ui_button>
              </div>
            </div>
          </div>
        </div>
      </div>
    </section>
    """
  end

  attr(:show, :boolean, default: false)
  attr(:package, :any, default: nil)
  attr(:assessment_details, :map, default: %{})
  attr(:cpe_catalog_current, :boolean, default: true)
  attr(:timezone, :string, default: "Etc/UTC")

  @doc """
  Detail modal for a single Current Packages row. Renders the full package
  coordinate plus every assessment state scoped to this device + package.
  """
  def endpoint_inventory_package_modal(assigns) do
    details = assigns.assessment_details || %{}

    findings =
      EndpointInventoryFindings.partition(
        field(details, :assessments) || [],
        field(details, :supporting_matches) || []
      )

    sections = assessment_sections(findings)
    finding_count = sections |> Enum.flat_map(& &1.findings) |> length()

    assigns =
      assigns
      |> assign(:assessment_sections, sections)
      |> assign(:finding_count, finding_count)

    ~H"""
    <div
      :if={@show and @package}
      class="sr-ui-modal sr-ui-modal-open"
      data-testid="endpoint-package-modal"
    >
      <div class="sr-ui-modal-box sr-ui-modal-box-lg">
        <div class="mb-3 flex items-start justify-between gap-3">
          <div>
            <h3 class="text-lg font-bold">{field(@package, :name) || "Package"}</h3>
            <p class="font-mono text-xs text-sr-muted">
              {empty_dash(field(@package, :version))}
            </p>
          </div>
          <.ui_button
            type="button"
            phx-click="endpoint_inventory_close_package"
            size="sm"
            variant="ghost"
          >
            Close
          </.ui_button>
        </div>

        <div class="sr-ui-table-shell">
          <table class={ui_table_class(size: "sm")}>
            <tbody>
              <.detail_row label="Name" value={field(@package, :name)} />
              <.detail_row label="Version" value={field(@package, :version)} mono />
              <.detail_row label="Manager" value={field(@package, :package_manager)} />
              <.detail_row label="Ecosystem" value={field(@package, :ecosystem)} />
              <.detail_row label="Architecture" value={field(@package, :architecture)} mono />
              <.detail_row label="PURL" value={field(@package, :purl_canonical)} mono />
              <.detail_row
                :if={
                  field(@package, :purl) && field(@package, :purl) != field(@package, :purl_canonical)
                }
                label="PURL (raw)"
                value={field(@package, :purl)}
                mono
              />
              <.detail_row label="CPEs" value={cpe_display(field(@package, :cpes))} mono />
              <.detail_row label="Source" value={field(@package, :source)} />
              <.detail_row label="Coordinate" value={coordinate_display(@package)} mono />
              <.detail_row label="First Seen" mono>
                <.user_time
                  id={"endpoint-inventory-package-#{record_dom_id(@package, "package")}-inserted-at"}
                  value={field(@package, :inserted_at)}
                  timezone={@timezone}
                  style={:full}
                  fallback={timestamp_fallback(field(@package, :inserted_at))}
                />
              </.detail_row>
              <.detail_row label="Last Seen" mono>
                <.user_time
                  id={"endpoint-inventory-package-#{record_dom_id(@package, "package")}-updated-at"}
                  value={field(@package, :updated_at)}
                  timezone={@timezone}
                  style={:full}
                  fallback={timestamp_fallback(field(@package, :updated_at))}
                />
              </.detail_row>
              <.detail_row label="Scan Ref" value={field(@package, :scan_ref)} mono />
            </tbody>
          </table>
        </div>

        <div class="mt-4">
          <div class="mb-2 flex items-center justify-between gap-2">
            <h4 class="text-xs font-semibold uppercase text-sr-muted">
              Vulnerability Assessments
            </h4>
            <div :if={@finding_count > 0} class="flex flex-wrap gap-1">
              <.ui_badge
                :for={section <- @assessment_sections}
                :if={section.total > 0}
                size="sm"
                variant={section.variant}
              >
                {section.total} {section.short_label}
              </.ui_badge>
            </div>
          </div>

          <.ui_alert
            :if={@cpe_catalog_current == false}
            variant="warning"
            class="mb-3"
            data-testid="cpe-catalog-notice"
          >
            CPE catalog is not current. Supporting NVD coordinate evidence may be incomplete;
            applicability below remains the persisted assessment decision.
          </.ui_alert>

          <div
            :if={@finding_count == 0}
            class="rounded border border-sr-line bg-sr-subtle/40 px-3 py-4 text-center text-sm text-sr-muted"
          >
            No vulnerability assessments for this package.
          </div>

          <div :if={@finding_count > 0} class="space-y-4">
            <section :for={section <- @assessment_sections} :if={section.findings != []}>
              <div class="mb-2 flex items-center justify-between gap-2">
                <h5 class="text-xs font-semibold text-sr-ink">{section.title}</h5>
                <span class="text-xs text-sr-muted">{section.total}</span>
              </div>
              <div class="space-y-3">
                <.cve_finding_card :for={finding <- section.findings} finding={finding} />
              </div>
            </section>
          </div>
        </div>
      </div>
      <div class="sr-ui-modal-backdrop" phx-click="endpoint_inventory_close_package"></div>
    </div>
    """
  end

  attr(:show, :boolean, default: false)
  attr(:group, :any, default: nil)
  attr(:match, :any, default: nil)
  attr(:timezone, :string, default: "Etc/UTC")

  @doc """
  Detail modal for a consolidated Vulnerability Matches package row.
  One unique CVE uses the full advisory layout; several CVEs list cards.
  """
  def endpoint_inventory_match_modal(assigns) do
    group = assigns.group || EndpointInventoryMatchGroups.wrap_match(assigns.match)
    advisories = (group && group.advisories) || []
    single? = length(advisories) == 1
    primary = if single?, do: hd(advisories).primary
    advisory = match_advisory(primary)

    assigns =
      assign(assigns,
        group: group,
        advisories: advisories,
        single?: single?,
        match: primary,
        advisory: advisory,
        links: advisory_links(primary),
        canonical_links: canonical_advisory_links(primary),
        kev_action: kev_required_action(advisory),
        kev_due: kev_due_date(advisory),
        kev_ransomware: kev_ransomware(advisory),
        kev_product: kev_vendor_product(advisory),
        match_note: assessment_explanation(primary),
        source_label: source_label(group && group.sources)
      )

    ~H"""
    <.ui_modal
      :if={@show and @group}
      id="endpoint-inventory-match-modal"
      size="lg"
      on_cancel="endpoint_inventory_close_match"
      data-testid="endpoint-match-modal"
    >
      <:title>
        <%= if @single? do %>
          {field(@match, :cve_id) || field(@match, :advisory_id) || "Advisory"}
        <% else %>
          {@group.package_name || "Package"}
        <% end %>
      </:title>

      <p class="text-xs text-sr-muted">
        {@group.package_name}
        <span class="font-mono">{@group.installed_version}</span>
        <span :if={not @single?}>
          · {@group.advisory_count} {if @group.advisory_count == 1,
            do: "advisory",
            else: "advisories"}
        </span>
      </p>

      <div :if={@single? and @canonical_links != []} class="flex flex-wrap gap-x-3 gap-y-1">
        <a
          :for={link <- @canonical_links}
          href={link.url}
          target="_blank"
          rel="noopener noreferrer"
          class="link link-hover inline-flex items-center gap-1 text-sm text-sr-brand"
        >
          <.icon name="hero-arrow-top-right-on-square" class="h-3 w-3" />
          {link.label}
        </a>
      </div>

      <div :if={@single?} class="flex flex-wrap items-center gap-1">
        <.ui_badge size="sm" variant={vulnerability_severity_class(field(@match, :severity))}>
          {vulnerability_severity(@match)}
        </.ui_badge>
        <.ui_badge :if={field(@match, :kev)} size="sm" variant="error">KEV</.ui_badge>
        <.ui_badge :if={field(@match, :exploit_available)} size="sm" variant="warning">
          Exploit
        </.ui_badge>
        <.ui_badge size="sm" variant={assessment_state_variant(@match)}>
          {assessment_state_label(@match)}
        </.ui_badge>
        <span class="ml-auto font-mono text-xs text-sr-muted">
          CVSS {cvss_display(field(@match, :cvss_score))}
        </span>
      </div>

      <div :if={match_cwes(@match) != []} class="flex flex-wrap gap-1">
        <a
          :for={cwe <- match_cwes(@match)}
          href={cwe_url(cwe)}
          target="_blank"
          rel="noopener noreferrer"
          class="link link-hover"
        >
          <.ui_badge size="xs" variant="outline">{cwe}</.ui_badge>
        </a>
      </div>

      <div :if={@single?} class="flex flex-wrap gap-1">
        <.ui_badge :for={feed <- @group.sources} size="xs" variant="ghost">
          {feed.provider}{feed_suffix(feed.feed_key)}
        </.ui_badge>
      </div>

      <p :if={@single? and advisory_title(@advisory)} class="text-sm font-medium text-sr-ink">
        {advisory_title(@advisory)}
      </p>

      <.ui_alert :if={@single? and @kev_action} variant="warning">
        <div>
          <div class="font-semibold">CISA required action</div>
          <p class="mt-1 text-sm">{@kev_action}</p>
          <p :if={@kev_due} class="mt-1 text-xs">Due {@kev_due}</p>
          <p :if={@kev_ransomware} class="mt-1 text-xs">
            Known ransomware use: {@kev_ransomware}
          </p>
        </div>
      </.ui_alert>

      <p
        :if={@single? and advisory_description(@advisory)}
        class="max-h-48 overflow-y-auto whitespace-pre-wrap text-sm text-sr-muted"
      >
        {advisory_description(@advisory)}
      </p>

      <.ui_alert :if={@single? and @match_note} variant="info">
        {@match_note}
      </.ui_alert>

      <div :if={@single?} class="sr-ui-table-shell">
        <table class={ui_table_class(size: "sm")}>
          <tbody>
            <.detail_row label="Package" value={@group.package_name} />
            <.detail_row label="Installed" value={@group.installed_version} mono />
            <.detail_row label="Fixed version" value={fixed_versions_display(@group)} mono />
            <.detail_row label="Authority" value={field(@match, :authority)} mono />
            <.detail_row label="Applicability" value={assessment_state_label(@match)} />
            <.detail_row label="Distro / release" value={distro_release(@match)} mono />
            <.detail_row label="Freshness" value={freshness_label(@match)} />
            <.detail_row label="Decision reason" value={assessment_reason(@match)} />
            <.detail_row :if={@kev_product} label="KEV product" value={@kev_product} />
            <.detail_row label="Coordinate" value={match_coordinate(@match)} mono />
            <.detail_row label="Supporting feeds" value={@source_label} mono />
            <.detail_row label="Authority as of" mono>
              <.user_time
                id={"endpoint-inventory-assessment-#{record_dom_id(@match, "assessment")}-authority-as-of"}
                value={field(@match, :authority_as_of)}
                timezone={@timezone}
                style={:full}
                fallback={timestamp_fallback(field(@match, :authority_as_of))}
              />
            </.detail_row>
            <.detail_row
              :if={advisory_cvss_vector(@advisory) || match_cvss_vector(@match)}
              label="CVSS vector"
              value={advisory_cvss_vector(@advisory) || match_cvss_vector(@match)}
              mono
            />
            <.detail_row
              :if={match_cwes(@match) != []}
              label="CWE"
              value={Enum.join(match_cwes(@match), ", ")}
            />
            <.detail_row label="Published" mono>
              <.user_time
                id={"endpoint-inventory-match-#{record_dom_id(@match, "match")}-advisory-published-at"}
                value={advisory_published_at(@advisory)}
                timezone={@timezone}
                style={:full}
                fallback={timestamp_fallback(advisory_published_at(@advisory))}
              />
            </.detail_row>
            <.detail_row label="First seen" mono>
              <.user_time
                id={"endpoint-inventory-match-#{record_dom_id(@match, "match")}-first-seen-at"}
                value={field(@match, :first_seen_at)}
                timezone={@timezone}
                style={:full}
                fallback={timestamp_fallback(field(@match, :first_seen_at))}
              />
            </.detail_row>
            <.detail_row label="Last seen" mono>
              <.user_time
                id={"endpoint-inventory-match-#{record_dom_id(@match, "match")}-last-seen-at"}
                value={field(@match, :last_seen_at)}
                timezone={@timezone}
                style={:full}
                fallback={timestamp_fallback(field(@match, :last_seen_at))}
              />
            </.detail_row>
          </tbody>
        </table>
      </div>

      <div :if={@single? and @links != []} class="flex flex-col gap-1">
        <div class="text-[0.65rem] font-semibold uppercase text-sr-muted">References</div>
        <a
          :for={link <- @links}
          href={link.url}
          target="_blank"
          rel="noopener noreferrer"
          class="link link-hover inline-flex items-center gap-1 text-sm text-sr-brand"
        >
          <.icon name="hero-arrow-top-right-on-square" class="h-3 w-3" />
          {link.label}
        </a>
      </div>

      <div :if={not @single?} class="space-y-3">
        <.vulnerability_match_card
          :for={advisory <- @advisories}
          match={advisory.primary}
          feeds={advisory.feeds}
          timezone={@timezone}
        />
      </div>
    </.ui_modal>
    """
  end

  attr(:match, :any, required: true)
  attr(:feeds, :list, default: [])
  attr(:timezone, :string, required: true)

  defp vulnerability_match_card(assigns) do
    assigns =
      assign(assigns,
        advisory: match_advisory(assigns.match),
        links: advisory_links(assigns.match),
        feeds: assigns.feeds || []
      )

    ~H"""
    <div class="rounded border border-sr-line p-3">
      <div class="flex flex-wrap items-center justify-between gap-2">
        <div class="flex flex-wrap items-center gap-1">
          <.ui_badge size="sm" variant={vulnerability_severity_class(field(@match, :severity))}>
            {vulnerability_severity(@match)}
          </.ui_badge>
          <.ui_badge :if={field(@match, :kev)} size="sm" variant="error">KEV</.ui_badge>
          <.ui_badge :if={field(@match, :exploit_available)} size="sm" variant="warning">
            Exploit
          </.ui_badge>
          <.ui_badge size="sm" variant={assessment_state_variant(@match)}>
            {assessment_state_label(@match)}
          </.ui_badge>
          <.ui_badge :for={feed <- @feeds} size="xs" variant="ghost">
            {feed.provider}{feed_suffix(feed.feed_key)}
          </.ui_badge>
        </div>
        <span class="font-mono text-xs text-sr-muted">
          CVSS {cvss_display(field(@match, :cvss_score))}
        </span>
      </div>

      <div :if={match_cwes(@match) != []} class="mt-2 flex flex-wrap gap-1">
        <a
          :for={cwe <- match_cwes(@match)}
          href={cwe_url(cwe)}
          target="_blank"
          rel="noopener noreferrer"
          class="link link-hover"
        >
          <.ui_badge size="xs" variant="outline">{cwe}</.ui_badge>
        </a>
      </div>

      <div class="mt-2 font-medium">
        {field(@match, :cve_id) || field(@match, :advisory_id) || "Advisory"}
        <span
          :if={
            field(@match, :cve_id) && field(@match, :advisory_id) &&
              field(@match, :cve_id) != field(@match, :advisory_id)
          }
          class="ml-1 font-mono text-xs text-sr-muted"
        >
          ({field(@match, :advisory_id)})
        </span>
      </div>

      <p :if={advisory_title(@advisory)} class="mt-1 text-sm text-sr-ink">
        {advisory_title(@advisory)}
      </p>

      <p
        :if={advisory_description(@advisory)}
        class="mt-2 max-h-40 overflow-y-auto whitespace-pre-wrap text-xs text-sr-muted"
      >
        {advisory_description(@advisory)}
      </p>

      <div class="mt-2 grid gap-x-4 gap-y-1 text-xs sm:grid-cols-2">
        <div>
          <span class="text-sr-muted">Package:</span>
          <span class="font-medium">{vulnerability_package_name(@match)}</span>
        </div>
        <div>
          <span class="text-sr-muted">Installed:</span>
          <span class="font-mono">{vulnerability_installed_version(@match)}</span>
        </div>
        <div>
          <span class="text-sr-muted">Fixed version:</span>
          <span class="font-mono">{empty_dash(authoritative_fixed_version(@match))}</span>
        </div>
        <div>
          <span class="text-sr-muted">Coordinate:</span>
          <span class="font-mono">{match_coordinate(@match)}</span>
        </div>
        <div>
          <span class="text-sr-muted">Authority:</span>
          <span class="font-mono">
            {empty_dash(field(@match, :authority))}
          </span>
        </div>
        <div>
          <span class="text-sr-muted">Freshness:</span>
          <span>{freshness_label(@match)}</span>
        </div>
        <div class="sm:col-span-2">
          <span class="text-sr-muted">Decision reason:</span>
          <span>{assessment_reason(@match)}</span>
        </div>
        <div :if={advisory_cvss_vector(@advisory)}>
          <span class="text-sr-muted">CVSS vector:</span>
          <span class="font-mono">{advisory_cvss_vector(@advisory)}</span>
        </div>
        <div>
          <span class="text-sr-muted">First seen:</span>
          <.user_time
            id={"endpoint-inventory-match-card-#{record_dom_id(@match, "match")}-first-seen-at"}
            value={field(@match, :first_seen_at)}
            timezone={@timezone}
            style={:full}
            fallback={timestamp_fallback(field(@match, :first_seen_at))}
          />
        </div>
        <div>
          <span class="text-sr-muted">Last seen:</span>
          <.user_time
            id={"endpoint-inventory-match-card-#{record_dom_id(@match, "match")}-last-seen-at"}
            value={field(@match, :last_seen_at)}
            timezone={@timezone}
            style={:full}
            fallback={timestamp_fallback(field(@match, :last_seen_at))}
          />
        </div>
      </div>

      <div :if={@links != []} class="mt-3 flex flex-col gap-1">
        <div class="text-[0.65rem] font-semibold uppercase text-sr-muted">References</div>
        <a
          :for={link <- @links}
          href={link.url}
          target="_blank"
          rel="noopener noreferrer"
          class="inline-flex items-center gap-1 text-xs text-info hover:underline"
        >
          <.icon name="hero-arrow-top-right-on-square" class="h-3 w-3" />
          {link.label}
        </a>
      </div>
    </div>
    """
  end

  attr(:finding, :map, required: true)

  defp cve_finding_card(assigns) do
    ~H"""
    <div
      class="rounded border border-sr-line p-3"
      data-testid="cve-finding"
      data-cve={field(@finding, :cve_id) || field(@finding, :advisory_id)}
    >
      <div class="flex flex-wrap items-center justify-between gap-2">
        <div class="flex flex-wrap items-center gap-1">
          <.ui_badge size="sm" variant={vulnerability_severity_class(field(@finding, :severity))}>
            {vulnerability_severity(@finding)}
          </.ui_badge>
          <.ui_badge :if={field(@finding, :kev)} size="sm" variant="error">KEV</.ui_badge>
          <.ui_badge :if={field(@finding, :exploit_available)} size="sm" variant="warning">
            Exploit
          </.ui_badge>
          <.ui_badge size="sm" variant={assessment_state_variant(@finding)}>
            {assessment_state_label(@finding)}
          </.ui_badge>
        </div>
        <span class="font-mono text-xs text-sr-muted">
          CVSS {empty_dash(field(@finding, :cvss_score))}
        </span>
      </div>

      <div :if={(field(@finding, :cwes) || []) != []} class="mt-2 flex flex-wrap gap-1">
        <.ui_badge :for={cwe <- field(@finding, :cwes) || []} size="xs" variant="outline">
          {cwe}
        </.ui_badge>
      </div>

      <div class="mt-2 font-medium">
        {field(@finding, :cve_id) || field(@finding, :advisory_id) || "Advisory"}
        <span
          :if={
            field(@finding, :cve_id) && field(@finding, :advisory_id) &&
              field(@finding, :cve_id) != field(@finding, :advisory_id)
          }
          class="ml-1 font-mono text-xs text-sr-muted"
        >
          ({field(@finding, :advisory_id)})
        </span>
      </div>

      <p :if={field(@finding, :description)} class="mt-1 line-clamp-3 text-xs text-sr-muted">
        {field(@finding, :description)}
      </p>

      <div class="mt-2 grid gap-x-4 gap-y-1 text-xs sm:grid-cols-2">
        <div :if={authoritative_fixed_version(@finding)}>
          <span class="text-sr-muted">Fixed version:</span>
          <span class="font-mono">{authoritative_fixed_version(@finding)}</span>
        </div>
        <div>
          <span class="text-sr-muted">Installed:</span>
          <span class="font-mono">{empty_dash(field(@finding, :installed_version))}</span>
        </div>
        <div :if={field(@finding, :due_date)}>
          <span class="text-sr-muted">CISA due:</span>
          <span>{field(@finding, :due_date)}</span>
        </div>
        <div :if={field(@finding, :epss_score)}>
          <span class="text-sr-muted">EPSS:</span>
          <span class="font-mono">{format_epss(field(@finding, :epss_score))}</span>
        </div>
        <div>
          <span class="text-sr-muted">Authority:</span>
          <span class="font-mono">
            {empty_dash(field(@finding, :authority))}
          </span>
        </div>
        <div>
          <span class="text-sr-muted">Distro / release:</span>
          <span class="font-mono">{distro_release(@finding)}</span>
        </div>
        <div>
          <span class="text-sr-muted">Freshness:</span>
          <span>{freshness_label(@finding)}</span>
        </div>
        <div class="sm:col-span-2">
          <span class="text-sr-muted">Decision reason:</span>
          <span>{assessment_reason(@finding)}</span>
        </div>
        <div :if={unknown_terms_label(@finding)} class="sm:col-span-2">
          <span class="text-sr-muted">Unknown environment:</span>
          <span class="font-mono">{unknown_terms_label(@finding)}</span>
        </div>
      </div>

      <a
        :for={url <- advisory_reference_urls(@finding)}
        href={url}
        target="_blank"
        rel="noopener noreferrer"
        class="mt-2 inline-flex items-center gap-1 text-xs text-info hover:underline"
      >
        <.icon name="hero-arrow-top-right-on-square" class="h-3 w-3" />
        {url}
      </a>
    </div>
    """
  end

  attr(:label, :string, required: true)
  attr(:value, :any, default: nil)
  attr(:mono, :boolean, default: false)
  slot(:inner_block)

  defp detail_row(assigns) do
    ~H"""
    <tr>
      <th class="w-36 text-xs text-sr-muted">{@label}</th>
      <td class={["break-all text-xs", @mono && "font-mono"]}>
        <%= if @inner_block == [] do %>
          {empty_dash(@value)}
        <% else %>
          {render_slot(@inner_block)}
        <% end %>
      </td>
    </tr>
    """
  end

  attr(:label, :string, required: true)
  attr(:value, :any, default: nil)
  slot(:inner_block)

  defp summary_stat(assigns) do
    ~H"""
    <div class="rounded border border-sr-line bg-sr-subtle/30 px-3 py-2">
      <div class="text-[0.65rem] font-semibold uppercase text-sr-muted">{@label}</div>
      <div class="mt-1 truncate text-sm font-semibold">
        <%= if @inner_block == [] do %>
          {empty_dash(@value)}
        <% else %>
          {render_slot(@inner_block)}
        <% end %>
      </div>
    </div>
    """
  end

  attr(:assessment_pages, :any, default: %{})
  attr(:loading, :boolean, default: false)
  attr(:timezone, :string, default: "Etc/UTC")

  defp vulnerability_assessments_sections(assigns) do
    sections = assessment_sections(assigns.assessment_pages || %{})
    confirmed = Enum.find(sections, &(&1.key == :confirmed))

    assigns =
      assigns
      |> assign(:assessment_sections, sections)
      |> assign(:confirmed_total, confirmed.total)

    ~H"""
    <div class="space-y-4" data-testid="vulnerability-assessment-sections">
      <div class="flex flex-wrap items-center gap-2 px-1 text-xs text-sr-muted">
        <span>{@confirmed_total} confirmed</span>
        <span
          :for={section <- @assessment_sections}
          :if={section.key != :confirmed and section.total > 0}
        >
          · {section.total} {section.short_label}
        </span>
      </div>

      <.vulnerability_assessment_section
        :for={section <- @assessment_sections}
        :if={section.key == :confirmed or section.total > 0}
        section={section}
        loading={@loading}
        timezone={@timezone}
      />
    </div>
    """
  end

  attr(:section, :map, required: true)
  attr(:loading, :boolean, default: false)
  attr(:timezone, :string, default: "Etc/UTC")

  defp vulnerability_assessment_section(assigns) do
    ~H"""
    <section
      class="overflow-hidden rounded border border-sr-line"
      data-section={@section.key}
      data-testid={"vulnerability-section-#{@section.key}"}
    >
      <div class="border-b border-sr-line bg-sr-subtle/30 p-3">
        <div class="flex flex-col gap-1 md:flex-row md:items-center md:justify-between">
          <div>
            <h3 class="text-xs font-semibold uppercase text-sr-muted">{@section.title}</h3>
            <p class="text-xs text-sr-muted">
              {@section.total} {@section.short_label}
              <span :if={@section.truncated?}>· showing first {length(@section.findings)}</span>
            </p>
          </div>
          <.ui_badge :if={@section.total > 0} size="sm" variant={@section.variant}>
            {@section.badge}
          </.ui_badge>
        </div>
      </div>

      <table class={ui_table_class(size: "sm")}>
        <thead>
          <tr>
            <th>Priority</th>
            <th>Advisory</th>
            <th>Package</th>
            <th>Applicability</th>
            <th>Versions</th>
            <th>Freshness</th>
          </tr>
        </thead>
        <tbody>
          <tr :if={@loading and @section.key == :confirmed and @section.total == 0}>
            <td colspan="6" class="py-6 text-center text-sm text-sr-muted">
              Loading vulnerability assessments…
            </td>
          </tr>
          <tr :if={not @loading and @section.key == :confirmed and @section.total == 0}>
            <td colspan="6" class="py-6 text-center text-sm text-sr-muted">
              No confirmed vulnerabilities.
            </td>
          </tr>
          <tr
            :for={finding <- @section.findings}
            class="cursor-pointer hover"
            phx-click="endpoint_inventory_open_match"
            phx-value-id={field(finding, :id)}
            data-testid="cve-finding"
            data-assessment-id={field(finding, :id)}
            data-cve={field(finding, :cve_id)}
            title="View assessment details"
          >
            <td>
              <div class="flex flex-wrap gap-1">
                <.ui_badge size="xs" variant={vulnerability_severity_class(field(finding, :severity))}>
                  {vulnerability_severity(finding)}
                </.ui_badge>
                <.ui_badge :if={field(finding, :kev)} size="xs" variant="error">KEV</.ui_badge>
                <.ui_badge :if={field(finding, :exploit_available)} size="xs" variant="warning">
                  Exploit
                </.ui_badge>
              </div>
              <div class="mt-1 font-mono text-[0.65rem] text-sr-muted">
                CVSS {empty_dash(field(finding, :cvss_score))}
              </div>
            </td>
            <td>
              <div class="font-medium">{field(finding, :cve_id) || field(finding, :advisory_id)}</div>
              <.ui_badge size="xs" variant={assessment_state_variant(finding)} class="mt-1">
                {assessment_state_label(finding)}
              </.ui_badge>
            </td>
            <td class="max-w-48">
              <div class="truncate font-medium">{vulnerability_package_name(finding)}</div>
              <div class="truncate font-mono text-xs text-sr-muted">{distro_release(finding)}</div>
            </td>
            <td class="max-w-56 text-xs">
              <div class="font-mono">{empty_dash(field(finding, :authority))}</div>
              <div class="mt-1 line-clamp-2 text-sr-muted">{assessment_reason(finding)}</div>
              <div
                :if={unknown_terms_label(finding)}
                class="mt-1 line-clamp-2 font-mono text-sr-muted"
              >
                Unknown environment: {unknown_terms_label(finding)}
              </div>
            </td>
            <td class="text-xs">
              <div class="font-mono">{empty_dash(field(finding, :installed_version))}</div>
              <div :if={authoritative_fixed_version(finding)} class="mt-1 font-mono text-sr-muted">
                fix {authoritative_fixed_version(finding)}
              </div>
            </td>
            <td class="text-xs">
              <div>{freshness_label(finding)}</div>
              <.user_time
                id={"endpoint-inventory-assessment-#{record_dom_id(finding, "assessment")}-authority-table"}
                value={field(finding, :authority_as_of)}
                timezone={@timezone}
                style={:compact}
                fallback={timestamp_fallback(field(finding, :authority_as_of))}
              />
            </td>
          </tr>
        </tbody>
      </table>
    </section>
    """
  end

  attr(:label, :string, required: true)
  attr(:value, :any, default: nil)
  attr(:mono, :boolean, default: false)
  slot(:inner_block)

  defp scan_row(assigns) do
    ~H"""
    <tr>
      <th class="w-32 text-xs text-sr-muted">{@label}</th>
      <td class={["text-xs", @mono && "font-mono"]}>
        <%= if @inner_block == [] do %>
          {empty_dash(@value)}
        <% else %>
          {render_slot(@inner_block)}
        <% end %>
      </td>
    </tr>
    """
  end

  attr(:result, :map, default: nil)

  defp live_query_result(assigns) do
    ~H"""
    <div :if={is_map(@result)} class="mt-3 rounded bg-sr-subtle/40 p-3">
      <div class="grid grid-cols-2 gap-2 text-xs md:grid-cols-4">
        <.result_stat label="Matched" value={bool_display(field(@result, :matched))} />
        <.result_stat label="Matches" value={field(@result, :match_count) || 0} />
        <.result_stat label="Freshness" value={freshness_verdict(field(@result, :freshness))} />
        <.result_stat label="Hash" value={truncate_hash(field(@result, :package_set_hash))} mono />
      </div>
      <div
        :if={result_packages(@result) != []}
        class="mt-3 overflow-hidden rounded border border-sr-line"
      >
        <table class={ui_table_class(size: "xs")}>
          <thead>
            <tr>
              <th>Package</th>
              <th>Version</th>
              <th>Manager</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={package <- result_packages(@result)}>
              <td>{field(package, :name)}</td>
              <td class="font-mono">{empty_dash(field(package, :version))}</td>
              <td>{field(package, :package_manager)}</td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>
    """
  end

  attr(:result, :map, default: nil)

  defp cohort_query_result(assigns) do
    ~H"""
    <div :if={is_map(@result)} class="mt-3 rounded bg-sr-subtle/40 p-3">
      <% coverage = field(@result, :coverage) || %{} %>
      <div class="grid grid-cols-2 gap-2 text-xs md:grid-cols-5">
        <.result_stat label="Targeted" value={field(coverage, :targeted) || 0} />
        <.result_stat label="Answered" value={field(coverage, :answered) || 0} />
        <.result_stat label="Offline" value={field(coverage, :offline) || 0} />
        <.result_stat label="Expired" value={field(coverage, :expired) || 0} />
        <.result_stat label="Pending" value={field(coverage, :pending) || 0} />
      </div>
      <div
        :if={cohort_results(@result) != []}
        class="mt-3 overflow-hidden rounded border border-sr-line"
      >
        <table class={ui_table_class(size: "xs")}>
          <thead>
            <tr>
              <th>Agent</th>
              <th>Device</th>
              <th>Matched</th>
              <th>Freshness</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={row <- cohort_results(@result)}>
              <td class="font-mono">{field(row, :agent_id)}</td>
              <td class="font-mono">{field(row, :device_uid)}</td>
              <td>{bool_display(field(row, :matched))}</td>
              <td>{freshness_verdict(field(row, :freshness))}</td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>
    """
  end

  attr(:label, :string, required: true)
  attr(:value, :any, required: true)
  attr(:mono, :boolean, default: false)

  defp result_stat(assigns) do
    ~H"""
    <div class="rounded border border-sr-line bg-sr-surface px-2 py-1">
      <div class="text-[0.62rem] font-semibold uppercase text-sr-muted">{@label}</div>
      <div class={["truncate font-semibold", @mono && "font-mono"]}>{empty_dash(@value)}</div>
    </div>
    """
  end

  attr(:state, :map, required: true)

  defp software_state_notice(assigns) do
    ~H"""
    <div
      :if={field(@state, :show)}
      class={[
        "mx-4 mt-4 rounded border px-3 py-2 text-sm",
        software_state_class(field(@state, :tone))
      ]}
      data-testid="endpoint-software-state"
    >
      <div class="flex flex-wrap items-center gap-2">
        <.ui_badge size="sm" variant={software_state_badge_class(field(@state, :tone))}>
          {field(@state, :label)}
        </.ui_badge>
        <span class="font-medium">{field(@state, :title)}</span>
      </div>
      <p class="mt-1 text-xs opacity-80">{field(@state, :detail)}</p>
    </div>
    """
  end

  attr(:scan, :any, default: nil)

  defp scan_status_badge(assigns) do
    ~H"""
    <.ui_badge size="sm" variant={scan_status_class(field(@scan, :state))}>
      {empty_dash(field(@scan, :state))}
    </.ui_badge>
    """
  end

  attr(:risk_level, :any, default: nil)
  attr(:risk_score, :any, default: nil)

  defp risk_badge(assigns) do
    ~H"""
    <span class={["px-2 py-0.5 text-xs", risk_class(@risk_level, @risk_score)]}>
      {risk_level_display(@risk_level)} {risk_score_suffix(@risk_score)}
    </span>
    """
  end

  defp form_params(%Phoenix.HTML.Form{params: params}) when is_map(params), do: params
  defp form_params(_form), do: %{}

  defp package_filters_active?(params) when is_map(params) do
    Enum.any?(["q", "package_manager", "version", "purl", "cpe"], fn key ->
      not blank?(Map.get(params, key))
    end)
  end

  defp package_filters_active?(_params), do: false

  defp package_range_label(_first, _last, 0), do: "No packages"

  defp package_range_label(first, last, total) do
    "Showing #{first}-#{last} of #{total}"
  end

  defp software_state(nil, _packages, false, false) do
    %{
      show: true,
      tone: :warning,
      label: "No agent",
      title: "No enrolled endpoint inventory agent",
      detail: "Endpoint inventory cannot run until this device is associated with an enrolled agent.",
      empty_message: "No enrolled endpoint inventory agent or package inventory is available for this device."
    }
  end

  defp software_state(nil, _packages, _has_inventory, true) do
    %{
      show: true,
      tone: :info,
      label: "No scan",
      title: "No endpoint inventory scan yet",
      detail:
        "This device has an agent identity, but no endpoint inventory scan has been ingested. Reconcile the endpoint inventory profile or refresh after the add-on checks in.",
      empty_message: "Endpoint inventory is available for this device, but no scan has reported yet."
    }
  end

  defp software_state(scan, stored_count, _has_inventory, _show_controls) do
    state = scan |> field(:state) |> normalized_state()
    coverage = scan |> field(:coverage_state) |> normalized_state()
    loaded_count = stored_count || 0

    cond do
      state == "disabled" or coverage == "disabled" ->
        %{
          show: true,
          tone: :warning,
          label: "Disabled",
          title: "Endpoint inventory is disabled",
          detail: "The latest inventory state says this collector is disabled for the device.",
          empty_message: "Endpoint inventory is disabled for this device."
        }

      state in ["scan_failed", "failed"] or coverage == "failed" ->
        reason =
          diagnostic_reason(scan) ||
            "Check source diagnostics and collector logs for the failure reason."

        %{
          show: true,
          tone: :error,
          label: "Failed",
          title: "Latest endpoint inventory scan failed",
          detail: reason,
          empty_message: "The latest endpoint inventory scan failed before package rows were accepted."
        }

      coverage == "partial" ->
        reason =
          diagnostic_reason(scan) ||
            "At least one enabled source did not complete, so the package set may be incomplete."

        %{
          show: true,
          tone: :warning,
          label: "Partial",
          title: "Latest endpoint inventory scan is partial",
          detail: reason,
          empty_message:
            if(loaded_count == 0,
              do: "The latest endpoint inventory scan is partial and produced no current package rows.",
              else: "The latest endpoint inventory scan is partial; loaded rows may be incomplete."
            )
        }

      state in ["not_scanned", "not_supported"] or
          coverage in ["not_scanned", "no_supported_package_source"] ->
        %{
          show: true,
          tone: :warning,
          label: "Unsupported",
          title: "No supported package source found",
          detail:
            diagnostic_reason(scan) ||
              "The scanner did not report a supported package source for this device.",
          empty_message: "Endpoint inventory has not found a supported package source on this device."
        }

      coverage == "unknown" ->
        %{
          show: true,
          tone: :warning,
          label: "Unknown",
          title: "Endpoint inventory coverage is unknown",
          detail:
            "The latest payload did not include generic source diagnostics, so the UI cannot prove whether the scan was complete.",
          empty_message: "No current package rows are available and scan coverage is unknown."
        }

      stale_scan?(scan) ->
        %{
          show: true,
          tone: :warning,
          label: "Stale",
          title: "Latest successful scan is stale",
          detail: "The latest successful endpoint inventory scan is older than 26 hours.",
          empty_message: "No current package rows are available and the latest successful scan is stale."
        }

      loaded_count == 0 and coverage == "complete" ->
        %{
          show: true,
          tone: :info,
          label: "Empty",
          title: "Scan completed with no package rows",
          detail: "The scanner reported complete coverage, but no current package rows were loaded for this device.",
          empty_message: "The latest endpoint inventory scan completed, but it did not report current package rows."
        }

      true ->
        %{
          show: false,
          tone: :success,
          label: "Complete",
          title: "Endpoint inventory is current",
          detail: "The latest endpoint inventory scan completed successfully.",
          empty_message: "No current package rows are available for the latest endpoint inventory scan."
        }
    end
  end

  defp diagnostic_reason(scan) do
    scan
    |> source_summaries()
    |> Enum.find_value(fn source ->
      source_state = normalized_state(field(source, :state))

      if source_state in ["failed", "error", "partial", "skipped", "missing", "unsupported"] do
        field(source, :reason) || field(source, :error) || field(source, :skipped_reason)
      end
    end)
  end

  defp stale_scan?(scan) do
    case field(scan, :last_successful_scan_at) || field(scan, :last_scan_at) do
      %DateTime{} = scanned_at ->
        DateTime.diff(DateTime.utc_now(), scanned_at, :second) > @stale_scan_seconds

      _ ->
        false
    end
  end

  defp normalized_state(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
  end

  defp normalized_state(value) when is_atom(value), do: value |> Atom.to_string() |> normalized_state()

  defp normalized_state(_value), do: nil

  defp software_state_class(:error), do: "border-error/40 bg-error/10 text-error"
  defp software_state_class(:warning), do: "border-warning/40 bg-warning/10 text-warning"
  defp software_state_class(:info), do: "border-info/40 bg-info/10 text-info"
  defp software_state_class(_tone), do: "border-success/40 bg-success/10 text-success"

  defp software_state_badge_class(:error), do: "error"
  defp software_state_badge_class(:warning), do: "warning"
  defp software_state_badge_class(:info), do: "info"
  defp software_state_badge_class(_tone), do: "success"

  defp field(nil, _field), do: nil

  defp field(%{} = row, field) do
    cond do
      Map.has_key?(row, field) -> Map.get(row, field)
      Map.has_key?(row, to_string(field)) -> Map.get(row, to_string(field))
      true -> nil
    end
  end

  defp field(_row, _field), do: nil

  defp device_value(nil, _key), do: nil

  defp device_value(%{} = row, "risk_score"), do: Map.get(row, "risk_score") || Map.get(row, :risk_score)

  defp device_value(%{} = row, "risk_level"), do: Map.get(row, "risk_level") || Map.get(row, :risk_level)

  defp device_value(%{} = row, key), do: Map.get(row, key)
  defp device_value(_row, _key), do: nil

  defp inventory_count(scan, fallback), do: field(scan, :package_count) || fallback || 0

  defp inventory_row_mismatch?(scan, loaded_count) do
    reported_count = field(scan, :package_count)
    is_integer(reported_count) and reported_count > loaded_count
  end

  defp collector_label(scan) do
    [field(scan, :collector_name), field(scan, :collector_version)]
    |> Enum.reject(&blank?/1)
    |> Enum.join(" ")
    |> case do
      "" -> nil
      value -> value
    end
  end

  defp enabled_sources(scan), do: scan |> field(:enabled_sources) |> string_list()

  defp source_summaries(scan) do
    case field(scan, :source_summaries) do
      values when is_list(values) -> Enum.filter(values, &is_map/1)
      _ -> []
    end
  end

  defp manager_counts(scan) do
    case field(scan, :manager_counts) do
      counts when is_map(counts) -> counts
      _ -> %{}
    end
  end

  defp manager_count_entries(scan) do
    scan
    |> manager_counts()
    |> Enum.map(fn {manager, count} -> {to_string(manager), count} end)
    |> Enum.sort_by(fn {manager, _count} -> manager end)
  end

  defp string_list(values) when is_list(values) do
    values
    |> Enum.map(&to_string/1)
    |> Enum.reject(&blank?/1)
  end

  defp string_list(_values), do: []

  defp result_packages(result), do: field(result, :packages) || []
  defp cohort_results(result), do: field(result, :results) || []

  defp bool_display(true), do: "yes"
  defp bool_display(false), do: "no"
  defp bool_display(nil), do: "-"

  defp freshness_verdict(%{} = freshness), do: field(freshness, :verdict) || "unknown"
  defp freshness_verdict(value) when is_binary(value), do: value
  defp freshness_verdict(_value), do: "unknown"

  defp risk_score_display(nil), do: "-"
  defp risk_score_display(value), do: to_string(value)

  defp risk_level_display(nil), do: "Unknown"
  defp risk_level_display(""), do: "Unknown"
  defp risk_level_display(value), do: to_string(value)

  defp risk_score_suffix(nil), do: ""
  defp risk_score_suffix(value), do: "(#{value})"

  defp risk_class("Critical", _score), do: "sr-sev-critical"
  defp risk_class("High", _score), do: "sr-sev-high"
  defp risk_class("Medium", _score), do: "sr-sev-medium"
  defp risk_class("Low", _score), do: "sr-sev-low"
  defp risk_class(_level, score) when is_integer(score) and score >= 80, do: "sr-sev-critical"
  defp risk_class(_level, score) when is_integer(score) and score >= 50, do: "sr-sev-high"
  defp risk_class(_level, _score), do: "sr-sev-unknown"

  defp assessment_sections(partitions) do
    Enum.map(
      [
        %{
          key: :confirmed,
          title: "Confirmed vulnerabilities",
          short_label: "confirmed",
          badge: "Actionable",
          variant: "error"
        },
        %{
          key: :candidates,
          title: "Unverified candidates",
          short_label: "candidates",
          badge: "Review",
          variant: "outline"
        },
        %{key: :history, title: "History", short_label: "historical", badge: "Resolved", variant: "ghost"}
      ],
      fn definition ->
        page = field(partitions, definition.key) || %{}
        rows = assessment_page_rows(page)

        findings =
          if Enum.all?(rows, &(not is_nil(field(&1, :state_label)))),
            do: rows,
            else: EndpointInventoryFindings.group(rows)

        total = field(page, :total) || length(findings)

        Map.merge(definition, %{
          findings: findings,
          total: total,
          truncated?: field(page, :truncated?) == true or total > length(findings)
        })
      end
    )
  end

  defp assessment_page_rows(rows) when is_list(rows), do: rows
  defp assessment_page_rows(%{} = page), do: field(page, :rows) || []
  defp assessment_page_rows(_page), do: []

  defp assessment_state_label(assessment) do
    field(assessment, :state_label) ||
      cond do
        actionable_assessment?(assessment) ->
          "Confirmed affected"

        field(assessment, :status) == "resolved" ->
          "Resolved · #{humanize_assessment_value(field(assessment, :disposition))}"

        field(assessment, :assessment) == "candidate" ->
          "Unverified candidate"

        true ->
          "Needs review"
      end
  end

  defp assessment_state_variant(assessment) do
    cond do
      actionable_assessment?(assessment) -> "error"
      field(assessment, :status) == "resolved" -> "ghost"
      true -> "outline"
    end
  end

  defp actionable_assessment?(assessment) do
    field(assessment, :status) == "active" and
      field(assessment, :assessment) == "confirmed" and
      field(assessment, :disposition) == "affected"
  end

  defp assessment_reason(assessment) do
    value =
      if field(assessment, :status) == "resolved" do
        field(assessment, :transition_reason) || field(assessment, :applicability_reason)
      else
        field(assessment, :applicability_reason)
      end

    value || "No decision reason recorded"
  end

  defp assessment_explanation(nil), do: nil

  defp assessment_explanation(assessment) do
    case unknown_terms_label(assessment) do
      nil -> assessment_reason(assessment)
      terms -> "#{assessment_reason(assessment)}. Unknown environment: #{terms}"
    end
  end

  defp freshness_label(assessment) do
    assessment
    |> field(:freshness)
    |> case do
      nil -> "Unknown"
      value -> value |> to_string() |> String.capitalize()
    end
  end

  defp distro_release(assessment) do
    [field(assessment, :package_namespace), field(assessment, :package_release)]
    |> Enum.reject(&blank?/1)
    |> Enum.join(" / ")
    |> empty_dash()
  end

  defp authoritative_fixed_version(assessment) do
    fixed_version = field(assessment, :fixed_version)

    if not blank?(fixed_version) and
         (actionable_assessment?(assessment) or
            (field(assessment, :status) == "resolved" and
               field(assessment, :assessment) == "confirmed")) do
      fixed_version
    end
  end

  defp unknown_terms_label(assessment) do
    assessment
    |> field(:unknown_terms)
    |> List.wrap()
    |> Enum.map(&unknown_term_label/1)
    |> Enum.reject(&blank?/1)
    |> Enum.join(", ")
    |> case do
      "" -> nil
      label -> label
    end
  end

  defp unknown_term_label(term) when is_binary(term), do: term

  defp unknown_term_label(%{} = term) do
    field(term, :criteria) || field(term, :cpe) || field(term, :reason) || inspect(term)
  end

  defp unknown_term_label(term), do: to_string(term)

  defp humanize_assessment_value(nil), do: "unknown"

  defp humanize_assessment_value(value) do
    value
    |> to_string()
    |> String.replace("_", " ")
  end

  defp vulnerability_severity(match) do
    match
    |> field(:severity)
    |> severity_label()
  end

  defp severity_label(nil), do: "Unknown"
  defp severity_label(""), do: "Unknown"

  defp severity_label(value) do
    value
    |> to_string()
    |> String.upcase()
  end

  defp fixed_versions_display(%{fixed_versions: versions}) when is_list(versions) do
    case Enum.reject(versions, &blank?/1) do
      [] -> "-"
      list -> Enum.join(list, ", ")
    end
  end

  defp fixed_versions_display(_group), do: "-"

  defp source_label(feeds) when is_list(feeds) do
    feeds
    |> Enum.map(fn feed ->
      "#{feed.provider || "-"}#{feed_suffix(feed.feed_key)}"
    end)
    |> Enum.reject(&blank?/1)
    |> Enum.join(", ")
    |> case do
      "" -> "-"
      value -> value
    end
  end

  defp source_label(_feeds), do: "-"

  defp match_cwes(match) do
    direct = List.wrap(field(match, :cwes))

    from_meta =
      case field(match, :metadata) do
        %{"cwes" => cwes} -> List.wrap(cwes)
        %{cwes: cwes} -> List.wrap(cwes)
        _ -> []
      end

    from_advisory = ServiceRadar.Inventory.AdvisoryFeeds.Cwes.from_advisory(match_advisory(match))

    (direct ++ from_meta ++ from_advisory)
    |> Enum.map(&to_string/1)
    |> Enum.filter(&String.starts_with?(&1, "CWE-"))
    |> Enum.uniq()
  end

  defp match_cvss_vector(match) do
    case field(match, :metadata) do
      %{"cvss_vector" => vector} when is_binary(vector) -> vector
      %{cvss_vector: vector} when is_binary(vector) -> vector
      _ -> nil
    end
  end

  defp cwe_url("CWE-" <> id = cwe) do
    case Integer.parse(id) do
      {num, ""} -> "https://cwe.mitre.org/data/definitions/#{num}.html"
      _ -> "https://cwe.mitre.org/data/definitions/#{cwe}.html"
    end
  end

  defp cwe_url(cwe), do: "https://cwe.mitre.org/data/definitions/#{cwe}.html"

  defp cvss_display(nil), do: "-"
  defp cvss_display(""), do: "-"
  defp cvss_display(score) when is_float(score), do: :erlang.float_to_binary(score, decimals: 1)
  defp cvss_display(score) when is_integer(score), do: "#{score}.0"
  defp cvss_display(score), do: to_string(score)

  defp vulnerability_severity_class(value) when is_binary(value) do
    case String.downcase(value) do
      "critical" -> "error"
      "high" -> "warning"
      "medium" -> "info"
      "low" -> "success"
      _ -> "ghost"
    end
  end

  defp vulnerability_severity_class(_value), do: "ghost"

  defp vulnerability_package_name(match) do
    name =
      field(match, :package_name) ||
        match
        |> vulnerability_package()
        |> field(:name)

    empty_dash(name)
  end

  defp vulnerability_installed_version(match) do
    version =
      field(match, :installed_version) ||
        match
        |> field(:version_evidence)
        |> field(:installed_version)

    package_manager =
      field(match, :package_manager) ||
        match
        |> vulnerability_package()
        |> field(:package_manager)

    [package_manager, version]
    |> Enum.reject(&blank?/1)
    |> Enum.join(" ")
    |> case do
      "" -> "-"
      value -> value
    end
  end

  defp vulnerability_package(match) do
    match
    |> field(:evidence)
    |> field(:package)
    |> case do
      %{} = package -> package
      _ -> %{}
    end
  end

  defp cpe_display(cpes) when is_list(cpes) do
    cpes
    |> Enum.reject(&blank?/1)
    |> case do
      [] -> nil
      values -> Enum.join(values, ", ")
    end
  end

  defp cpe_display(_cpes), do: nil

  defp coordinate_display(package) do
    field(package, :purl_canonical) || field(package, :purl) ||
      List.first(field(package, :cpes) || [])
  end

  defp match_coordinate(match) do
    type = field(match, :coordinate_type)
    value = field(match, :coordinate_value) || field(match, :package_purl)

    [type, value]
    |> Enum.reject(&blank?/1)
    |> Enum.join(": ")
    |> case do
      "" -> "-"
      coordinate -> coordinate
    end
  end

  defp feed_suffix(nil), do: ""
  defp feed_suffix(""), do: ""
  defp feed_suffix(feed_key), do: " / #{feed_key}"

  defp format_epss(value) when is_float(value) and value <= 1.0 do
    :erlang.float_to_binary(Float.round(value * 100, 1), decimals: 1) <> "%"
  end

  defp format_epss(value) when is_integer(value) and value <= 1 do
    format_epss(value * 1.0)
  end

  defp format_epss(value) when is_number(value) do
    :erlang.float_to_binary(value / 1, decimals: 1) <> "%"
  end

  defp format_epss(value), do: empty_dash(value)

  defp advisory_reference_urls(match) do
    match
    |> field(:advisory)
    |> case do
      %{} = advisory -> field(advisory, :references)
      _ -> nil
    end
    |> List.wrap()
    |> Enum.filter(&reference_url?/1)
    |> Enum.take(5)
  end

  defp match_advisory(match) do
    case field(match, :advisory) do
      %{} = advisory -> advisory
      _ -> %{}
    end
  end

  defp advisory_title(advisory) do
    case field(advisory, :title) do
      value when is_binary(value) ->
        trimmed = String.trim(value)
        cve = field(advisory, :cve_id)

        cond do
          trimmed == "" -> nil
          is_binary(cve) and trimmed == cve -> nil
          true -> trimmed
        end

      _ ->
        nil
    end
  end

  defp advisory_description(advisory) do
    case field(advisory, :description) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          trimmed -> trimmed
        end

      _ ->
        nil
    end
  end

  defp advisory_cvss_vector(advisory) do
    case field(advisory, :cvss_vector) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          trimmed -> trimmed
        end

      _ ->
        nil
    end
  end

  defp advisory_links(nil), do: []

  defp advisory_links(match) do
    stored =
      match
      |> match_advisory()
      |> field(:references)
      |> List.wrap()
      |> Enum.flat_map(&expand_reference_urls/1)
      |> Enum.map(&%{url: &1, label: reference_label(&1)})

    (stored ++ canonical_advisory_links(match))
    |> Enum.uniq_by(& &1.url)
    |> Enum.take(8)
  end

  defp expand_reference_urls(value) when is_binary(value) do
    value
    |> String.split(~r/[\s,;]+/, trim: true)
    |> Enum.filter(&reference_url?/1)
  end

  defp expand_reference_urls(_value), do: []

  defp advisory_published_at(advisory) do
    field(advisory, :published_at) || raw_string(advisory, ["dateAdded", "date_added"])
  end

  defp kev_required_action(advisory) do
    raw_string(advisory, ["requiredAction", "required_action"])
  end

  defp kev_due_date(advisory) do
    raw_string(advisory, ["dueDate", "due_date"])
  end

  defp kev_ransomware(advisory) do
    raw_string(advisory, ["knownRansomwareCampaignUse", "known_ransomware_campaign_use"])
  end

  defp kev_vendor_product(advisory) do
    vendor = raw_string(advisory, ["vendorProject", "vendor_project", "vendor"])
    product = raw_string(advisory, ["product"])

    [vendor, product]
    |> Enum.reject(&blank?/1)
    |> Enum.join(" / ")
    |> case do
      "" -> nil
      value -> value
    end
  end

  defp raw_string(advisory, keys) when is_list(keys) do
    raw =
      case field(advisory, :raw) do
        %{} = map -> map
        _ -> %{}
      end

    Enum.find_value(keys, fn key ->
      case field(raw, key) do
        value when is_binary(value) ->
          case String.trim(value) do
            "" -> nil
            trimmed -> trimmed
          end

        _ ->
          nil
      end
    end)
  end

  defp canonical_advisory_links(match) do
    cve = field(match, :cve_id)

    cve_links =
      if is_binary(cve) and String.starts_with?(cve, "CVE-") do
        [
          %{url: "https://nvd.nist.gov/vuln/detail/#{cve}", label: "NVD · #{cve}"},
          %{url: "https://www.cve.org/CVERecord?id=#{cve}", label: "CVE.org · #{cve}"}
        ]
      else
        []
      end

    kev_links =
      if field(match, :kev) do
        [
          %{
            url: "https://www.cisa.gov/known-exploited-vulnerabilities-catalog",
            label: "CISA KEV catalog"
          }
        ]
      else
        []
      end

    cve_links ++ kev_links
  end

  defp reference_label(url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) -> host
      _ -> url
    end
  end

  defp reference_url?(value) when is_binary(value) do
    String.starts_with?(value, "http://") or String.starts_with?(value, "https://")
  end

  defp reference_url?(_value), do: false

  defp scan_status_class("scanned"), do: "success"
  defp scan_status_class("upload_deferred"), do: "warning"
  defp scan_status_class("scan_failed"), do: "error"
  defp scan_status_class(_state), do: "ghost"

  defp source_state_class(state) when is_binary(state) do
    case String.downcase(state) do
      "scanned" -> "success"
      "complete" -> "success"
      "partial" -> "warning"
      "skipped" -> "warning"
      "missing" -> "warning"
      "error" -> "error"
      "failed" -> "error"
      _ -> "ghost"
    end
  end

  defp source_state_class(_state), do: "ghost"

  defp truncate_hash(nil), do: nil

  defp truncate_hash(value) when is_binary(value) and byte_size(value) > 18, do: String.slice(value, 0, 18) <> "..."

  defp truncate_hash(value), do: value

  defp empty_dash(nil), do: "-"
  defp empty_dash(""), do: "-"
  defp empty_dash(value), do: value

  defp blank?(nil), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: false

  defp record_dom_id(record, kind) do
    identity =
      field(record, :id) ||
        field(record, :scan_id) ||
        field(record, :cve_id) ||
        field(record, :advisory_id) ||
        field(record, :object_key) ||
        field(record, :purl_canonical) ||
        field(record, :purl)

    case dom_id_fragment(identity) do
      "" -> "#{kind}-#{:erlang.phash2(record)}"
      fragment -> fragment
    end
  end

  defp dom_id_fragment(value) when is_binary(value) or is_atom(value) or is_integer(value) do
    value
    |> to_string()
    |> String.replace(~r/[^A-Za-z0-9_-]+/, "-")
    |> String.trim("-")
  end

  defp dom_id_fragment(_value), do: ""

  defp timestamp_fallback(nil), do: "-"
  defp timestamp_fallback(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp timestamp_fallback(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp timestamp_fallback(value) when is_binary(value), do: value
  defp timestamp_fallback(_value), do: "-"

  defp format_bytes(bytes) when is_integer(bytes) and bytes >= 1_073_741_824,
    do: "#{Float.round(bytes / 1_073_741_824, 1)} GiB"

  defp format_bytes(bytes) when is_integer(bytes) and bytes >= 1_048_576, do: "#{Float.round(bytes / 1_048_576, 1)} MiB"

  defp format_bytes(bytes) when is_integer(bytes) and bytes >= 1024, do: "#{Float.round(bytes / 1024, 1)} KiB"

  defp format_bytes(bytes) when is_integer(bytes), do: "#{bytes} B"
  defp format_bytes(_bytes), do: "-"
end
