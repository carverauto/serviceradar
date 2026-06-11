defmodule ServiceRadarWebNGWeb.SecurityLive.Index do
  @moduledoc false
  use ServiceRadarWebNGWeb, :live_view

  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Observability.TrivyFinding
  alias ServiceRadarWebNG.Dashboards

  require Ash.Query

  @finding_limit 100
  @scan_limit 80
  @dns_activity_limit 80
  @trivy_finding_limit 50
  @source_signal_queries [
    %{
      label: "Trivy findings",
      source: "trivy",
      kind: "Finding",
      query: "in:security_findings source:trivy sort:time:desc limit:1"
    },
    %{
      label: "Trivy scan",
      source: "trivy",
      kind: "Scan Activity",
      query: "in:scan_activity source:trivy sort:time:desc limit:1"
    },
    %{
      label: "Bumblebee finding",
      source: "bumblebee",
      kind: "Finding",
      query: "in:security_findings source:bumblebee sort:time:desc limit:1"
    },
    %{
      label: "Bumblebee scan",
      source: "bumblebee",
      kind: "Scan Activity",
      query: "in:scan_activity source:bumblebee sort:time:desc limit:1"
    },
    %{
      label: "Falco detection",
      source: "falco",
      kind: "Finding",
      query: "in:security_findings source:falco sort:time:desc limit:1"
    },
    %{
      label: "Endpoint inventory",
      source: "endpoint_inventory",
      kind: "Finding",
      query: "in:security_findings source:endpoint_inventory sort:time:desc limit:1"
    },
    %{
      label: "PowerDNS DNS",
      source: "powerdns",
      kind: "DNS Activity",
      query: "in:dns_activity source:powerdns sort:time:desc limit:1"
    }
  ]

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "Security")
      |> assign(:loading?, connected?(socket))
      |> assign(:load_error, nil)
      |> assign(:findings, [])
      |> assign(:scan_activity, [])
      |> assign(:dns_activity, [])
      |> assign(:trivy_findings, [])
      |> assign(:source_signals, [])
      |> assign(:selected_trivy_finding_uuid, nil)
      |> assign(:selected_detection_event_id, nil)
      |> assign(:selected_trivy_finding, nil)
      |> assign(:selected_detection, nil)
      |> assign(:summary, empty_summary())

    if connected?(socket), do: send(self(), :load_security)

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply,
     socket
     |> assign(:selected_trivy_finding_uuid, clean_param(Map.get(params, "finding")))
     |> assign(:selected_detection_event_id, clean_param(Map.get(params, "detection")))
     |> assign_selected_security_details()}
  end

  @impl true
  def handle_info(:load_security, socket) do
    scope = socket.assigns.current_scope

    with {:ok, findings_preview} <-
           Dashboards.preview_authored_query(
             scope,
             "in:security_findings sort:time:desc limit:#{@finding_limit}",
             limit: @finding_limit
           ),
         {:ok, scans_preview} <-
           Dashboards.preview_authored_query(
             scope,
             "in:scan_activity sort:time:desc limit:#{@scan_limit}",
             limit: @scan_limit
           ),
         {:ok, dns_preview} <-
           Dashboards.preview_authored_query(
             scope,
             "in:dns_activity sort:time:desc limit:#{@dns_activity_limit}",
             limit: @dns_activity_limit
           ) do
      findings = Map.get(findings_preview, :rows, [])
      scan_activity = Map.get(scans_preview, :rows, [])
      dns_activity = Map.get(dns_preview, :rows, [])
      source_signals = source_signal_rows(scope)
      trivy_findings = trivy_finding_rows(scope)

      source_signal_event_rows =
        source_signals
        |> Enum.map(& &1.row)
        |> Enum.reject(&is_nil/1)

      device_index =
        security_device_index(findings ++ scan_activity ++ dns_activity ++ source_signal_event_rows, scope)

      findings = Enum.map(findings, &put_resolved_device(&1, device_index))
      scan_activity = Enum.map(scan_activity, &put_resolved_device(&1, device_index))
      dns_activity = Enum.map(dns_activity, &put_resolved_device(&1, device_index))
      source_signals = Enum.map(source_signals, &put_resolved_source_signal(&1, device_index))

      {:noreply,
       socket
       |> assign(:loading?, false)
       |> assign(:load_error, nil)
       |> assign(:findings, findings)
       |> assign(:scan_activity, scan_activity)
       |> assign(:dns_activity, dns_activity)
       |> assign(:trivy_findings, trivy_findings)
       |> assign(:source_signals, source_signals)
       |> assign(:summary, build_summary(findings, scan_activity, dns_activity))
       |> assign_selected_security_details()}
    else
      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:loading?, false)
         |> assign(:load_error, format_error(reason))
         |> assign(:summary, empty_summary())}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_path="/security"
      page_title={@page_title}
    >
      <div class="mx-auto w-full max-w-7xl min-w-0 space-y-6 overflow-x-hidden pb-24 lg:pb-0">
        <section class="rounded-lg border border-white/10 bg-slate-950/70 text-slate-100 overflow-hidden">
          <div class="grid gap-0 lg:grid-cols-[1.1fr_0.9fr]">
            <div class="p-6 sm:p-8">
              <p class="text-xs font-semibold uppercase tracking-[0.22em] text-error">Security</p>
              <h1 class="mt-2 text-3xl font-semibold tracking-normal text-slate-100">
                Scanner posture and active findings
              </h1>
              <p class="mt-3 max-w-2xl text-sm leading-6 text-slate-300">
                OCSF scan activity, findings, and DNS security activity from Bumblebee, Falco, Trivy, endpoint package discovery, and PowerDNS.
              </p>

              <div class="mt-6 flex flex-wrap gap-2">
                <.link navigate={~p"/dashboards"} class="btn btn-sm btn-primary">
                  <.icon name="hero-squares-2x2" class="size-4" /> Browse Dashboards
                </.link>
                <.link
                  navigate={
                    ~p"/observability?#{%{tab: "events", q: "in:security_findings sort:time:desc"}}"
                  }
                  class="btn btn-sm btn-outline border-white/20 text-slate-100 hover:border-info hover:bg-info hover:text-info-content"
                >
                  <.icon name="hero-arrow-top-right-on-square" class="size-4" /> Raw Findings
                </.link>
              </div>
            </div>

            <div class="border-t border-white/10 bg-white/5 p-6 lg:border-l lg:border-t-0">
              <div class="grid grid-cols-2 gap-3 xl:grid-cols-3">
                <.metric_tile
                  label="Active findings"
                  value={@summary.finding_count}
                  tone="error"
                  href={observability_href("in:security_findings sort:time:desc limit:100")}
                />
                <.metric_tile
                  label="Critical/high"
                  value={@summary.priority_count}
                  tone="warning"
                  href={observability_href("in:security_findings sort:time:desc limit:100")}
                />
                <.metric_tile
                  label="Scan events"
                  value={@summary.scan_count}
                  tone="info"
                  href={observability_href("in:scan_activity sort:time:desc limit:80")}
                />
                <.metric_tile
                  label="Failed scans"
                  value={@summary.failed_scan_count}
                  tone="error"
                  href={observability_href("in:scan_activity status:Failure sort:time:desc limit:80")}
                />
                <.metric_tile
                  label="DNS activity"
                  value={@summary.dns_activity_count}
                  tone="info"
                  href={observability_href("in:dns_activity sort:time:desc limit:80")}
                />
                <.metric_tile
                  label="DNS blocks"
                  value={@summary.dns_block_count}
                  tone="warning"
                  href={observability_href("in:dns_activity source:powerdns sort:time:desc limit:80")}
                />
              </div>
            </div>
          </div>
        </section>

        <div :if={@loading?} class="rounded-lg border border-white/10 bg-slate-950/70 p-8">
          <div class="flex items-center gap-3 text-sm text-slate-300">
            <span class="loading loading-spinner loading-sm"></span> Loading security signals...
          </div>
        </div>

        <div :if={@load_error} class="alert alert-error">
          <.icon name="hero-exclamation-triangle" class="size-5" />
          <span>{@load_error}</span>
        </div>

        <div :if={!@loading? && is_nil(@load_error)} class="grid gap-6 xl:grid-cols-[0.9fr_1.1fr]">
          <section class="min-w-0 rounded-lg border border-white/10 bg-slate-950/70 p-5 text-slate-100 xl:col-span-2">
            <div class="flex items-center justify-between gap-3">
              <div>
                <h2 class="text-base font-semibold">Scanner Signal Coverage</h2>
                <p class="text-xs text-slate-400">
                  Latest source-scoped OCSF rows from each scanner and add-on
                </p>
              </div>
            </div>
            <div class="mt-4 grid gap-3 md:grid-cols-2 xl:grid-cols-4">
              <.source_signal_card :for={signal <- @source_signals} signal={signal} />
            </div>
          </section>

          <section class="min-w-0 rounded-lg border border-white/10 bg-slate-950/70 p-5 text-slate-100">
            <div class="flex items-center justify-between gap-3">
              <div>
                <h2 class="text-base font-semibold">Finding Severity</h2>
                <p class="text-xs text-slate-400">Latest OCSF findings from security add-ons</p>
              </div>
            </div>
            <.severity_bars severity_counts={@summary.severity_counts} total={@summary.finding_count} />
          </section>

          <section class="min-w-0 rounded-lg border border-white/10 bg-slate-950/70 p-5 text-slate-100">
            <h2 class="text-base font-semibold">Finding Classes</h2>
            <div class="mt-4 grid gap-3 sm:grid-cols-2">
              <.class_chip :for={item <- @summary.class_counts} item={item} />
            </div>
          </section>
        </div>

        <div :if={!@loading? && is_nil(@load_error)} class="grid gap-6 xl:grid-cols-2">
          <.selected_trivy_finding_panel finding={@selected_trivy_finding} />
          <.selected_detection_panel detection={@selected_detection} />
        </div>

        <div :if={!@loading? && is_nil(@load_error)} class="grid gap-6 xl:grid-cols-2">
          <section class="min-w-0 rounded-lg border border-white/10 bg-slate-950/70 text-slate-100 xl:col-span-2">
            <div class="flex items-center justify-between gap-3 border-b border-white/10 p-5">
              <div>
                <h2 class="text-base font-semibold">Trivy Vulnerabilities</h2>
                <p class="text-xs text-slate-400">
                  Normalized vulnerability rows extracted from Trivy reports
                </p>
              </div>
              <.link
                navigate={
                  observability_href("in:security_findings source:trivy sort:time:desc limit:100")
                }
                class="btn btn-xs btn-ghost text-slate-300 hover:text-slate-100"
              >
                Open Trivy Events
              </.link>
            </div>
            <.trivy_findings_table rows={@trivy_findings} />
          </section>

          <section class="min-w-0 rounded-lg border border-white/10 bg-slate-950/70 text-slate-100">
            <div class="border-b border-white/10 p-5">
              <h2 class="text-base font-semibold">Recent Scan Activity</h2>
              <p class="text-xs text-slate-400">
                OCSF Scan Activity, separate from finding outcomes
              </p>
            </div>
            <.scan_activity_table rows={@scan_activity} />
          </section>

          <section class="min-w-0 rounded-lg border border-white/10 bg-slate-950/70 text-slate-100">
            <div class="border-b border-white/10 p-5">
              <h2 class="text-base font-semibold">Active Findings</h2>
              <p class="text-xs text-slate-400">
                Normalized OCSF Findings with device/event drill-downs
              </p>
            </div>
            <.findings_table rows={@findings} />
          </section>
        </div>

        <section
          :if={!@loading? && is_nil(@load_error)}
          class="min-w-0 rounded-lg border border-white/10 bg-slate-950/70 text-slate-100"
        >
          <div class="border-b border-white/10 p-5">
            <h2 class="text-base font-semibold">DNS Security Activity</h2>
            <p class="text-xs text-slate-400">
              OCSF DNS Activity from PowerDNS RPZ and DNS policy enforcement
            </p>
          </div>
          <.dns_activity_table rows={@dns_activity} />
        </section>
      </div>
    </Layouts.app>
    """
  end

  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :tone, :string, default: "neutral"
  attr :href, :string, default: nil

  defp metric_tile(assigns) do
    ~H"""
    <.link
      :if={@href}
      navigate={@href}
      class={[
        "block rounded-lg border bg-slate-900/80 p-4 transition hover:-translate-y-0.5 hover:bg-slate-900 hover:shadow-lg focus:outline-none focus:ring-2 focus:ring-info/60",
        metric_border(@tone)
      ]}
    >
      <div class="text-xs font-medium uppercase tracking-wide text-slate-400">{@label}</div>
      <div class="mt-2 text-3xl font-semibold tabular-nums text-slate-100">{@value}</div>
    </.link>
    <div
      :if={!@href}
      class={["rounded-lg border bg-slate-900/80 p-4", metric_border(@tone)]}
    >
      <div class="text-xs font-medium uppercase tracking-wide text-slate-400">{@label}</div>
      <div class="mt-2 text-3xl font-semibold tabular-nums text-slate-100">{@value}</div>
    </div>
    """
  end

  attr :severity_counts, :list, required: true
  attr :total, :integer, required: true

  defp severity_bars(assigns) do
    ~H"""
    <div class="mt-5 space-y-3">
      <div :if={@total == 0} class="rounded-lg bg-white/5 p-4 text-sm text-slate-300">
        No OCSF security findings are present in the selected window.
      </div>
      <.link
        :for={item <- @severity_counts}
        navigate={observability_href(item.query)}
        class="grid grid-cols-[6rem_1fr_3rem] items-center gap-3 rounded-md p-1 transition hover:bg-white/5 focus:outline-none focus:ring-2 focus:ring-info/60"
      >
        <span class="text-sm font-medium">{item.label}</span>
        <div class="h-3 overflow-hidden rounded-full bg-white/10">
          <div
            class={["h-full rounded-full", severity_bar_class(item.label)]}
            style={"width: #{item.percent}%"}
          />
        </div>
        <span class="text-right text-sm tabular-nums text-slate-300">{item.count}</span>
      </.link>
    </div>
    """
  end

  attr :item, :map, required: true

  defp class_chip(assigns) do
    ~H"""
    <.link
      navigate={observability_href(@item.query)}
      class="block rounded-lg border border-white/10 bg-white/5 p-4 transition hover:-translate-y-0.5 hover:bg-white/10 focus:outline-none focus:ring-2 focus:ring-info/60"
    >
      <div class="text-sm font-semibold">{@item.label}</div>
      <div class="mt-2 text-2xl font-semibold tabular-nums">{@item.count}</div>
    </.link>
    """
  end

  attr :signal, :map, required: true

  defp source_signal_card(assigns) do
    assigns = assign(assigns, href: source_signal_href(assigns.signal))

    ~H"""
    <.link
      navigate={@href}
      class="block min-w-0 rounded-lg border border-white/10 bg-white/5 p-4 transition hover:-translate-y-0.5 hover:border-info/40 hover:bg-white/10 focus:outline-none focus:ring-2 focus:ring-info/60"
    >
      <div class="flex items-start justify-between gap-3">
        <div class="min-w-0">
          <div class="truncate text-sm font-semibold">{@signal.label}</div>
          <div class="mt-1 text-xs text-slate-400">{@signal.kind}</div>
        </div>
        <span class={["badge badge-sm", if(@signal.row, do: "badge-success", else: "badge-ghost")]}>
          {if @signal.row, do: "present", else: "missing"}
        </span>
      </div>

      <div :if={@signal.row} class="mt-3 space-y-2 text-xs text-slate-300">
        <div class="flex items-center justify-between gap-3">
          <span class="text-slate-500">Source</span>
          <span class="badge badge-ghost badge-sm">{source_label(@signal.row)}</span>
        </div>
        <div class="flex items-center justify-between gap-3">
          <span class="text-slate-500">Device</span>
          <span class="max-w-36 truncate font-mono text-[0.72rem]">
            {device_label(@signal.row) || "-"}
          </span>
        </div>
        <div class="flex items-center justify-between gap-3">
          <span class="text-slate-500">Class</span>
          <span>{class_label(value(@signal.row, "class_uid"))}</span>
        </div>
        <div class="flex items-center justify-between gap-3">
          <span class="text-slate-500">Time</span>
          <span>{short_time(event_time(@signal.row))}</span>
        </div>
        <div class="line-clamp-2 text-slate-200">
          {value(@signal.row, "short_message") || value(@signal.row, "message") ||
            value(@signal.row, "id") || "-"}
        </div>
      </div>

      <div :if={!@signal.row} class="mt-3 text-xs text-slate-500">
        <div class="line-clamp-3 text-slate-400">{source_signal_missing_message(@signal)}</div>
        <code class="mt-2 block truncate text-[0.68rem] text-slate-500">{@signal.query}</code>
      </div>
    </.link>
    """
  end

  attr :finding, :any, default: nil

  defp selected_trivy_finding_panel(assigns) do
    ~H"""
    <section
      :if={@finding}
      id="trivy-finding-detail"
      class="min-w-0 rounded-lg border border-warning/30 bg-slate-950/80 p-5 text-slate-100"
    >
      <div class="flex flex-wrap items-start justify-between gap-3">
        <div class="min-w-0">
          <p class="text-xs font-semibold uppercase tracking-[0.18em] text-warning">
            Vulnerability Finding
          </p>
          <h2 class="mt-2 text-lg font-semibold leading-tight">
            {@finding.finding_id || short_uuid(@finding.finding_uuid)}
          </h2>
          <p class="mt-1 line-clamp-2 text-sm text-slate-300">
            {@finding.title || @finding.description || "No finding title provided"}
          </p>
        </div>
        <span class={["badge badge-sm", severity_badge_class(@finding.severity_text)]}>
          {@finding.severity_text || "Unknown"}
        </span>
      </div>

      <div class="mt-5 grid gap-3 sm:grid-cols-2">
        <.security_fact label="Package" value={@finding.package_name || @finding.target} mono />
        <.security_fact label="Package PURL" value={@finding.package_purl} mono />
        <.security_fact label="Installed" value={@finding.installed_version} mono />
        <.security_fact label="Fixed In" value={@finding.fixed_version} mono />
        <.security_fact label="Status" value={@finding.status} />
        <.security_fact label="Image" value={image_reference(@finding)} mono />
        <.security_fact label="Resource" value={@finding.resource_name || @finding.pod_name} mono />
        <.security_fact
          label="Namespace"
          value={
            @finding.resource_namespace || @finding.pod_namespace || @finding.namespace ||
              @finding.cluster_id
          }
          mono
        />
        <.security_fact label="Node" value={@finding.node_name || @finding.host_ip} mono />
        <.security_fact label="Container" value={@finding.container_name} mono />
        <.security_fact label="Owner" value={owner_reference(@finding)} mono />
      </div>

      <div class="mt-5 flex flex-wrap gap-2">
        <a
          :for={reference <- Enum.take(finding_references(@finding), 3)}
          href={reference}
          target="_blank"
          rel="noopener noreferrer"
          class="btn btn-xs btn-outline border-white/20 text-slate-100 hover:border-info hover:bg-info hover:text-info-content"
        >
          Reference
        </a>
        <.link navigate={~p"/events/#{@finding.event_uuid}"} class="btn btn-xs btn-ghost">
          Raw report
        </.link>
        <.link patch={~p"/security"} class="btn btn-xs btn-ghost">
          Clear selection
        </.link>
      </div>
    </section>
    """
  end

  attr :detection, :map, default: nil

  defp selected_detection_panel(assigns) do
    assigns =
      assigns
      |> assign(:evidence, detection_evidence(assigns.detection || %{}))
      |> assign(:detection_id, if(is_map(assigns.detection), do: value(assigns.detection, "id")))

    ~H"""
    <section
      :if={@detection}
      id="runtime-detection-detail"
      class="min-w-0 rounded-lg border border-error/30 bg-slate-950/80 p-5 text-slate-100"
    >
      <div class="flex flex-wrap items-start justify-between gap-3">
        <div class="min-w-0">
          <p class="text-xs font-semibold uppercase tracking-[0.18em] text-error">
            Runtime Detection Evidence
          </p>
          <h2 class="mt-2 text-lg font-semibold leading-tight">
            {@evidence.rule || value(@detection, "short_message") || value(@detection, "message") ||
              "Detection"}
          </h2>
          <p class="mt-1 line-clamp-2 text-sm text-slate-300">
            {value(@detection, "short_message") || value(@detection, "message") ||
              "No detection message provided"}
          </p>
        </div>
        <span class={["badge badge-sm", severity_badge(@detection)]}>
          {value(@detection, "severity") || "Unknown"}
        </span>
      </div>

      <div class="mt-5 grid gap-3 sm:grid-cols-2">
        <.security_fact label="Host" value={@evidence.host} mono />
        <.security_fact label="Process" value={@evidence.process} />
        <.security_fact label="Command" value={@evidence.command} mono />
        <.security_fact label="User" value={@evidence.user} />
        <.security_fact label="Container" value={@evidence.container} mono />
        <.security_fact label="Image" value={@evidence.image} mono />
        <.security_fact label="Kubernetes" value={@evidence.kubernetes} mono />
        <.security_fact label="File/Network" value={@evidence.object} mono />
      </div>

      <div class="mt-5 flex flex-wrap gap-2">
        <.link
          :if={@detection_id}
          navigate={~p"/events/#{@detection_id}"}
          class="btn btn-xs btn-ghost"
        >
          Raw event
        </.link>
        <.link patch={~p"/security"} class="btn btn-xs btn-ghost">
          Clear selection
        </.link>
      </div>
    </section>
    """
  end

  attr :label, :string, required: true
  attr :value, :any, default: nil
  attr :mono, :boolean, default: false

  defp security_fact(assigns) do
    ~H"""
    <div class="min-w-0 rounded-md border border-white/10 bg-white/5 p-3">
      <div class="text-[0.68rem] font-semibold uppercase tracking-wide text-slate-500">
        {@label}
      </div>
      <div class={[
        "mt-1 truncate text-sm text-slate-100",
        if(@mono, do: "font-mono", else: nil),
        if(blank?(@value), do: "text-slate-500", else: nil)
      ]}>
        {display_value(@value)}
      </div>
    </div>
    """
  end

  attr :rows, :list, required: true

  defp scan_activity_table(assigns) do
    ~H"""
    <div class="max-w-full overflow-x-auto">
      <table class="table table-sm text-slate-100 [&_th]:text-slate-300 [&_td]:text-slate-100">
        <thead>
          <tr>
            <th>Time</th>
            <th>Source</th>
            <th>Activity</th>
            <th>Status</th>
            <th>Message</th>
          </tr>
        </thead>
        <tbody>
          <tr :if={@rows == []}>
            <td colspan="5" class="py-8 text-center text-sm text-slate-300">
              No scan activity found. This does not mean the environment is clean.
            </td>
          </tr>
          <tr :for={row <- Enum.take(@rows, 12)}>
            <td class="whitespace-nowrap text-xs">{short_time(event_time(row))}</td>
            <td><span class="badge badge-ghost badge-sm">{source_label(row)}</span></td>
            <td>{value(row, "activity_name") || "Unknown"}</td>
            <td>
              <span class={["badge badge-sm", status_badge(row)]}>
                {value(row, "status") || "Unknown"}
              </span>
            </td>
            <td class="max-w-sm truncate">
              <.link
                :if={value(row, "id")}
                navigate={~p"/events/#{value(row, "id")}"}
                class="link link-hover"
              >
                {value(row, "short_message") || value(row, "message") || value(row, "id")}
              </.link>
              <span :if={!value(row, "id")}>
                {value(row, "short_message") || value(row, "message") || "-"}
              </span>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  attr :rows, :list, required: true

  defp trivy_findings_table(assigns) do
    ~H"""
    <div class="max-w-full overflow-x-auto">
      <table class="table table-sm text-slate-100 [&_th]:text-slate-300 [&_td]:text-slate-100">
        <thead>
          <tr>
            <th>Severity</th>
            <th>CVE</th>
            <th>Package / Target</th>
            <th>Installed</th>
            <th>Fixed</th>
            <th>Resource</th>
            <th>Observed</th>
            <th></th>
          </tr>
        </thead>
        <tbody>
          <tr :if={@rows == []}>
            <td colspan="8" class="py-8 text-center text-sm text-slate-300">
              No normalized Trivy vulnerability rows found.
            </td>
          </tr>
          <tr :for={finding <- Enum.take(@rows, 20)}>
            <td>
              <span class={["badge badge-sm", severity_badge_class(finding.severity_text)]}>
                {finding.severity_text || "Unknown"}
              </span>
            </td>
            <td class="font-mono text-xs">
              {finding.finding_id || short_uuid(finding.finding_uuid)}
              <div :if={finding.status} class="mt-1 text-[11px] text-slate-400">
                {finding.status}
              </div>
            </td>
            <td class="max-w-sm">
              <div class="truncate font-medium">
                {finding.package_name || finding.target || "-"}
              </div>
              <div class="line-clamp-2 text-xs text-slate-400">
                {finding.title || finding.description || "-"}
              </div>
              <a
                :if={first_reference(finding)}
                href={first_reference(finding)}
                target="_blank"
                rel="noopener noreferrer"
                class="mt-1 inline-flex text-xs text-info hover:underline"
              >
                Reference
              </a>
            </td>
            <td class="font-mono text-xs">{finding.installed_version || "-"}</td>
            <td class="font-mono text-xs">{finding.fixed_version || "-"}</td>
            <td class="max-w-xs truncate">
              <div>{finding.resource_name || finding.pod_name || "-"}</div>
              <div class="text-xs text-slate-400">
                {finding.namespace || finding.cluster_id || "-"}
              </div>
            </td>
            <td class="whitespace-nowrap text-xs">{short_time(finding.observed_at)}</td>
            <td class="text-right">
              <.link
                patch={~p"/security?#{%{finding: finding.finding_uuid}}"}
                class="btn btn-ghost btn-xs"
              >
                Inspect
              </.link>
              <.link navigate={~p"/events/#{finding.event_uuid}"} class="btn btn-ghost btn-xs">
                Raw
              </.link>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  attr :rows, :list, required: true

  defp findings_table(assigns) do
    ~H"""
    <div class="max-w-full overflow-x-auto">
      <table class="table table-sm text-slate-100 [&_th]:text-slate-300 [&_td]:text-slate-100">
        <thead>
          <tr>
            <th>Severity</th>
            <th>Class</th>
            <th>Source</th>
            <th>Device</th>
            <th>Finding</th>
            <th></th>
          </tr>
        </thead>
        <tbody>
          <tr :if={@rows == []}>
            <td colspan="6" class="py-8 text-center text-sm text-slate-300">
              No active OCSF findings found in the selected window.
            </td>
          </tr>
          <tr :for={row <- Enum.take(@rows, 12)}>
            <td>
              <span class={["badge badge-sm", severity_badge(row)]}>
                {value(row, "severity") || "Unknown"}
              </span>
            </td>
            <td>{class_label(value(row, "class_uid"))}</td>
            <td><span class="badge badge-ghost badge-sm">{source_label(row)}</span></td>
            <td class="font-mono text-xs">
              <.device_link row={row} />
            </td>
            <td class="max-w-sm">
              <.link
                :if={value(row, "id")}
                navigate={~p"/events/#{value(row, "id")}"}
                class="link link-hover"
              >
                <span class="line-clamp-2">
                  {value(row, "short_message") || value(row, "message") || value(row, "id")}
                </span>
              </.link>
              <span :if={!value(row, "id")}>
                {value(row, "short_message") || value(row, "message") || "-"}
              </span>
              <div :if={detection_drilldown?(row)} class="mt-1 line-clamp-1 text-xs text-slate-400">
                {detection_evidence_summary(row)}
              </div>
            </td>
            <td class="text-right">
              <.link
                :if={detection_drilldown?(row)}
                patch={~p"/security?#{%{detection: value(row, "id")}}"}
                class="btn btn-ghost btn-xs"
              >
                Evidence
              </.link>
              <.link
                :if={value(row, "id")}
                navigate={~p"/events/#{value(row, "id")}"}
                class="btn btn-ghost btn-xs"
              >
                Raw
              </.link>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  attr :rows, :list, required: true

  defp dns_activity_table(assigns) do
    ~H"""
    <div class="max-w-full overflow-x-auto">
      <table class="table table-sm text-slate-100 [&_th]:text-slate-300 [&_td]:text-slate-100">
        <thead>
          <tr>
            <th>Time</th>
            <th>Source</th>
            <th>Query</th>
            <th>Rule</th>
            <th>Action</th>
            <th>Message</th>
          </tr>
        </thead>
        <tbody>
          <tr :if={@rows == []}>
            <td colspan="6" class="py-8 text-center text-sm text-slate-300">
              No OCSF DNS Activity found in the selected window.
            </td>
          </tr>
          <tr :for={row <- Enum.take(@rows, 16)}>
            <td class="whitespace-nowrap text-xs">{short_time(event_time(row))}</td>
            <td><span class="badge badge-ghost badge-sm">{source_label(row)}</span></td>
            <td class="max-w-xs truncate font-mono text-xs">{dns_query(row) || "-"}</td>
            <td class="max-w-48 truncate">{dns_rule_name(row) || "-"}</td>
            <td>
              <span class={["badge badge-sm", dns_action_badge(row)]}>
                {dns_action(row) || value(row, "activity_name") || "DNS"}
              </span>
            </td>
            <td class="max-w-md truncate">
              <.link
                :if={value(row, "id")}
                navigate={~p"/events/#{value(row, "id")}"}
                class="link link-hover"
              >
                {value(row, "short_message") || value(row, "message") || value(row, "id")}
              </.link>
              <span :if={!value(row, "id")}>
                {value(row, "short_message") || value(row, "message") || "-"}
              </span>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  attr :row, :map, required: true

  defp device_link(assigns) do
    assigns =
      assign(assigns,
        device_uid: resolved_device_uid(assigns.row),
        label: device_label(assigns.row) || "-"
      )

    ~H"""
    <.link
      :if={@device_uid}
      navigate={~p"/devices/#{@device_uid}"}
      class="link link-hover"
    >
      {@label}
    </.link>
    <span :if={!@device_uid}>{@label}</span>
    """
  end

  defp build_summary(findings, scans, dns_activity) do
    severity_counts = severity_counts(findings)
    class_counts = class_counts(findings)

    %{
      finding_count: length(findings),
      scan_count: length(scans),
      dns_activity_count: length(dns_activity),
      dns_block_count: Enum.count(dns_activity, &dns_block?/1),
      failed_scan_count: Enum.count(scans, &(value(&1, "status_id") in [2, "2"])),
      priority_count:
        Enum.count(findings, fn row ->
          severity = normalize_string(value(row, "severity"))
          severity in ["critical", "high"]
        end),
      severity_counts: severity_counts,
      class_counts: class_counts
    }
  end

  defp source_signal_rows(scope) do
    Enum.map(@source_signal_queries, fn signal ->
      row =
        case Dashboards.preview_authored_query(scope, signal.query, limit: 1) do
          {:ok, preview} -> preview |> Map.get(:rows, []) |> List.first()
          {:error, _reason} -> nil
        end

      Map.put(signal, :row, row)
    end)
  end

  defp assign_selected_security_details(socket) do
    socket
    |> assign(:selected_trivy_finding, selected_trivy_finding(socket.assigns))
    |> assign(:selected_detection, selected_detection(socket.assigns))
  end

  defp selected_trivy_finding(%{selected_trivy_finding_uuid: nil}), do: nil

  defp selected_trivy_finding(%{selected_trivy_finding_uuid: selected, trivy_findings: findings}) do
    Enum.find(findings || [], &(to_string(&1.finding_uuid) == selected))
  end

  defp selected_trivy_finding(_assigns), do: nil

  defp selected_detection(%{selected_detection_event_id: nil}), do: nil

  defp selected_detection(%{selected_detection_event_id: selected, findings: findings}) do
    Enum.find(findings || [], &(value(&1, "id") == selected))
  end

  defp selected_detection(_assigns), do: nil

  defp clean_param(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp clean_param(_value), do: nil

  defp put_resolved_source_signal(%{row: nil} = signal, _device_index), do: signal

  defp put_resolved_source_signal(%{row: row} = signal, device_index) do
    %{signal | row: put_resolved_device(row, device_index)}
  end

  defp empty_summary do
    %{
      finding_count: 0,
      scan_count: 0,
      dns_activity_count: 0,
      dns_block_count: 0,
      failed_scan_count: 0,
      priority_count: 0,
      severity_counts: severity_counts([]),
      class_counts: []
    }
  end

  defp severity_counts(rows) do
    counts =
      rows
      |> Enum.map(&(value(&1, "severity") || "Unknown"))
      |> Enum.frequencies_by(&severity_label/1)

    total = max(length(rows), 1)

    for label <- ["Critical", "High", "Medium", "Low", "Informational", "Unknown"] do
      count = Map.get(counts, label, 0)

      %{
        label: label,
        count: count,
        percent: Float.round(count * 100 / total, 1),
        query: severity_query(label)
      }
    end
  end

  defp class_counts(rows) do
    rows
    |> Enum.map(&(&1 |> value("class_uid") |> class_label()))
    |> Enum.frequencies()
    |> Enum.map(fn {label, count} -> %{label: label, count: count, query: class_query(label)} end)
    |> Enum.sort_by(& &1.count, :desc)
  end

  defp trivy_finding_rows(scope) do
    TrivyFinding
    |> Ash.Query.for_read(:recent, %{})
    |> Ash.Query.limit(@trivy_finding_limit)
    |> Ash.read(scope: scope)
    |> case do
      {:ok, %{results: findings}} -> findings
      {:ok, findings} when is_list(findings) -> findings
      _ -> []
    end
  end

  defp first_reference(%{references: [reference | _]}) when is_binary(reference), do: reference
  defp first_reference(_finding), do: nil

  defp finding_references(%{references: references}) when is_list(references) do
    Enum.filter(references, &is_binary/1)
  end

  defp finding_references(_finding), do: []

  defp image_reference(%{image_repository: repository} = finding) when is_binary(repository) and repository != "" do
    case finding.image_tag do
      tag when is_binary(tag) and tag != "" -> "#{repository}:#{tag}"
      _ -> repository
    end
  end

  defp image_reference(%{image_digest: digest}) when is_binary(digest) and digest != "", do: digest
  defp image_reference(_finding), do: nil

  defp owner_reference(%{owner_kind: kind, owner_name: name})
       when is_binary(kind) and kind != "" and is_binary(name) and name != "" do
    "#{kind}/#{name}"
  end

  defp owner_reference(%{owner_name: name}) when is_binary(name) and name != "", do: name
  defp owner_reference(_finding), do: nil

  defp value(%{} = row, key), do: Map.get(row, key) || Map.get(row, known_atom_key(key))
  defp value(_, _key), do: nil

  defp known_atom_key("activity_name"), do: :activity_name
  defp known_atom_key("class_uid"), do: :class_uid
  defp known_atom_key("device"), do: :device
  defp known_atom_key("event_timestamp"), do: :event_timestamp
  defp known_atom_key("id"), do: :id
  defp known_atom_key("log_provider"), do: :log_provider
  defp known_atom_key("message"), do: :message
  defp known_atom_key("metadata"), do: :metadata
  defp known_atom_key("raw_data"), do: :raw_data
  defp known_atom_key("severity"), do: :severity
  defp known_atom_key("short_message"), do: :short_message
  defp known_atom_key("source"), do: :source
  defp known_atom_key("source_device_uid"), do: :source_device_uid
  defp known_atom_key("status"), do: :status
  defp known_atom_key("status_id"), do: :status_id
  defp known_atom_key("time"), do: :time
  defp known_atom_key("unmapped"), do: :unmapped
  defp known_atom_key(_), do: nil

  defp source_label(row) do
    metadata = value(row, "metadata") || %{}
    unmapped = value(row, "unmapped") || %{}
    service_radar = service_radar_metadata(metadata)

    Map.get(service_radar, "source_type") ||
      Map.get(service_radar, "addon_id") ||
      get_in(metadata, ["source"]) ||
      Map.get(unmapped, "source_type") ||
      value(row, "log_provider") ||
      value(row, "source") ||
      "unknown"
  end

  defp device_label(row) do
    device = value(row, "device") || %{}
    metadata = value(row, "metadata") || %{}
    service_radar = service_radar_metadata(metadata)

    value(row, "resolved_device_name") ||
      value(row, "source_device_uid") ||
      Map.get(service_radar, "device_uid") ||
      Map.get(device, "name") ||
      Map.get(device, "hostname") ||
      Map.get(device, "uid")
  end

  defp resolved_device_uid(row) do
    value(row, "resolved_device_uid")
  end

  defp security_device_index(rows, scope) do
    candidates =
      rows
      |> Enum.map(&device_candidate_values/1)
      |> merge_device_candidates()

    if empty_device_candidates?(candidates) do
      %{}
    else
      devices =
        Device
        |> Ash.Query.filter(
          uid in ^candidates.uids or
            hostname in ^candidates.hostnames or
            name in ^candidates.names or
            ip in ^candidates.ips or
            agent_id in ^candidates.agent_ids
        )
        |> Ash.Query.sort(is_active: :desc, last_seen_time: :desc, modified_time: :desc, uid: :asc)
        |> Ash.read(scope: scope)
        |> case do
          {:ok, %{results: devices}} -> devices
          {:ok, devices} when is_list(devices) -> devices
          _ -> []
        end

      Enum.reduce(devices, %{}, fn device, acc ->
        acc
        |> put_device_index(device.uid, device)
        |> put_device_index(device.hostname, device)
        |> put_device_index(device.name, device)
        |> put_device_index(device.ip, device)
        |> put_device_index(device.agent_id, device)
      end)
    end
  end

  defp put_resolved_device(row, device_index) do
    candidates = device_candidate_values(row)

    candidate =
      Enum.find_value(
        candidates.uids ++ candidates.agent_ids ++ candidates.hostnames ++ candidates.names ++ candidates.ips,
        &Map.get(device_index, &1)
      )

    case candidate do
      %Device{} = device ->
        row
        |> Map.put("resolved_device_uid", device.uid)
        |> Map.put("resolved_device_name", device.name || device.hostname || device.uid)

      _ ->
        row
    end
  end

  defp device_candidate_values(row) do
    device = value(row, "device") || %{}
    metadata = value(row, "metadata") || %{}
    unmapped = value(row, "unmapped") || %{}
    raw = raw_data(row)
    raw_metadata = Map.get(raw, "metadata") || %{}
    raw_device = Map.get(raw, "device") || %{}
    raw_unmapped = Map.get(raw, "unmapped") || %{}
    raw_correlation = Map.get(raw, "correlation") || %{}

    raw_output_fields =
      %{}
      |> Map.merge(normalized_map(Map.get(raw, "output_fields")))
      |> Map.merge(normalized_map(Map.get(raw, "custom_fields")))
      |> Map.merge(normalized_map(Map.get(raw, "templated_fields")))

    service_radar =
      first_map([
        service_radar_metadata(metadata),
        service_radar_metadata(raw_metadata)
      ])

    %{
      uids:
        clean_candidates([
          value(row, "source_device_uid"),
          Map.get(service_radar, "device_uid"),
          Map.get(service_radar, "device_id"),
          get_in(service_radar, ["device", "id"]),
          Map.get(raw_output_fields, "service_radar.device_uid"),
          Map.get(raw_output_fields, "service_radar.device.uid"),
          Map.get(raw_output_fields, "service_radar.device_id"),
          Map.get(raw_output_fields, "serviceradar.device_uid"),
          Map.get(raw_output_fields, "serviceradar.device.uid"),
          Map.get(raw_output_fields, "serviceradar.device_id"),
          Map.get(device, "uid"),
          Map.get(raw_device, "uid"),
          Map.get(raw_correlation, "device_uid"),
          Map.get(raw_correlation, "device_id"),
          Map.get(unmapped, "device_uid"),
          Map.get(raw_unmapped, "device_uid")
        ]),
      agent_ids:
        clean_candidates([
          Map.get(service_radar, "agent_id"),
          Map.get(raw_correlation, "agent_id"),
          Map.get(raw_output_fields, "service_radar.agent_id"),
          Map.get(raw_output_fields, "serviceradar.agent_id"),
          Map.get(raw_output_fields, "agent_id"),
          Map.get(unmapped, "agent_id"),
          Map.get(raw_unmapped, "agent_id")
        ]),
      hostnames:
        clean_candidates([
          Map.get(service_radar, "device_hostname"),
          Map.get(service_radar, "source_instance"),
          Map.get(metadata, "hostname"),
          Map.get(device, "hostname"),
          Map.get(raw_device, "hostname"),
          Map.get(raw_correlation, "node_name"),
          Map.get(raw_correlation, "hostname"),
          Map.get(raw_output_fields, "k8s.node.name"),
          Map.get(raw_output_fields, "host.name"),
          Map.get(raw_output_fields, "evt.hostname"),
          Map.get(raw, "hostname")
        ]),
      names:
        clean_candidates([
          Map.get(device, "name"),
          Map.get(raw_device, "name")
        ]),
      ips:
        clean_candidates([
          Map.get(service_radar, "device_ip"),
          Map.get(service_radar, "source_ip"),
          Map.get(device, "ip"),
          Map.get(raw_device, "ip"),
          Map.get(raw_correlation, "host_ip"),
          Map.get(raw_correlation, "pod_ip"),
          Map.get(raw_output_fields, "service_radar.device_ip"),
          Map.get(raw_output_fields, "service_radar.source_ip"),
          Map.get(raw_output_fields, "serviceradar.device_ip"),
          Map.get(raw_output_fields, "serviceradar.source_ip"),
          Map.get(raw_output_fields, "host.ip"),
          Map.get(raw_output_fields, "evt.host.ip")
        ])
    }
  end

  defp merge_device_candidates(candidates) do
    Enum.reduce(candidates, empty_device_candidate_map(), fn candidate, acc ->
      %{
        uids: Enum.uniq(acc.uids ++ candidate.uids),
        agent_ids: Enum.uniq(acc.agent_ids ++ candidate.agent_ids),
        hostnames: Enum.uniq(acc.hostnames ++ candidate.hostnames),
        names: Enum.uniq(acc.names ++ candidate.names),
        ips: Enum.uniq(acc.ips ++ candidate.ips)
      }
    end)
  end

  defp empty_device_candidate_map, do: %{uids: [], agent_ids: [], hostnames: [], names: [], ips: []}

  defp empty_device_candidates?(candidates) do
    candidates.uids == [] and candidates.agent_ids == [] and candidates.hostnames == [] and
      candidates.names == [] and candidates.ips == []
  end

  defp put_device_index(acc, value, %Device{} = device) do
    case normalize_candidate(value) do
      nil ->
        acc

      candidate ->
        case Map.get(acc, candidate) do
          nil -> Map.put(acc, candidate, device)
          %Device{uid: uid} when uid == device.uid -> acc
          %Device{} -> acc
          :ambiguous -> acc
        end
    end
  end

  defp clean_candidates(values) do
    values
    |> Enum.map(&normalize_candidate/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp normalize_candidate(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp normalize_candidate(value) when is_integer(value), do: Integer.to_string(value)
  defp normalize_candidate(value) when is_float(value), do: Float.to_string(value)
  defp normalize_candidate(_), do: nil

  defp first_map(values) do
    Enum.find(values, %{}, &is_map/1)
  end

  defp normalized_map(value) when is_map(value), do: value
  defp normalized_map(_value), do: %{}

  defp service_radar_metadata(metadata) when is_map(metadata) do
    first_map([
      Map.get(metadata, "service_radar"),
      Map.get(metadata, :service_radar),
      Map.get(metadata, "serviceradar"),
      Map.get(metadata, :serviceradar)
    ])
  end

  defp service_radar_metadata(_metadata), do: %{}

  defp source_signal_missing_message(%{source: "trivy", kind: "Finding"}) do
    "No Trivy vulnerability finding rows are available yet. Verify the Trivy sidecar is publishing reports and that report ingestion extracted child findings."
  end

  defp source_signal_missing_message(%{source: "trivy"}) do
    "No Trivy scan activity is available yet. Verify the Trivy sidecar or operator is installed and forwarding scan reports."
  end

  defp source_signal_missing_message(%{source: "falco"}) do
    "No Falco runtime detections are available yet. Verify Falco/sidekick forwarding and the detection display contract."
  end

  defp source_signal_missing_message(%{source: "endpoint_inventory"}) do
    "No endpoint inventory vulnerability findings are available yet. Enable a scanner profile and central vulnerability matching."
  end

  defp source_signal_missing_message(%{source: "powerdns"}) do
    "No PowerDNS DNS activity is available yet. Verify the PowerDNS add-on is assigned and emitting OCSF DNS Activity."
  end

  defp source_signal_missing_message(%{source: "bumblebee", kind: "Finding"}) do
    "No Bumblebee findings are available yet. Verify the scanner add-on is assigned to eligible non-Kubernetes agents and emitting generic findings."
  end

  defp source_signal_missing_message(%{source: "bumblebee"}) do
    "No Bumblebee scan activity is available yet. Verify the scanner add-on can fetch its catalog through agent-gateway and report Scan Activity."
  end

  defp source_signal_missing_message(_signal), do: "No normalized security row is available for this source yet."

  defp detection_drilldown?(row) do
    class_label(value(row, "class_uid")) == "Detection" or source_label(row) == "falco" or
      map_size(detection_diagnostics(row)) > 0
  end

  defp detection_evidence_summary(row) do
    evidence = detection_evidence(row)

    [
      evidence.rule && "rule #{evidence.rule}",
      evidence.process && "process #{evidence.process}",
      evidence.container && "container #{evidence.container}",
      evidence.kubernetes && "k8s #{evidence.kubernetes}"
    ]
    |> Enum.reject(&blank?/1)
    |> Enum.join(" · ")
    |> case do
      "" -> "Runtime evidence available"
      summary -> summary
    end
  end

  defp detection_evidence(row) when is_map(row) do
    diagnostics = detection_diagnostics(row)
    container = diagnostic_value(diagnostics, ["container"])
    kubernetes = diagnostic_value(diagnostics, ["kubernetes"])
    process = diagnostic_value(diagnostics, ["process"])
    parent = diagnostic_value(diagnostics, ["parent_process"])
    user = diagnostic_value(diagnostics, ["user"])
    host = diagnostic_value(diagnostics, ["host"])
    rule = diagnostic_value(diagnostics, ["rule"])
    file = diagnostic_value(diagnostics, ["file"])
    network = diagnostic_value(diagnostics, ["network"])

    %{
      rule: diagnostic_value(rule, ["name"]) || diagnostic_value(diagnostics, ["rule_name"]),
      host: diagnostic_value(host, ["name"]) || diagnostic_value(diagnostics, ["host_name"]),
      process:
        diagnostic_value(process, ["name"]) ||
          diagnostic_value(parent, ["name"]) ||
          diagnostic_value(diagnostics, ["process_name"]),
      command: diagnostic_value(process, ["command"]) || diagnostic_value(diagnostics, ["command"]),
      user: diagnostic_value(user, ["name"]) || diagnostic_value(diagnostics, ["user_name"]),
      container: container_display(container),
      image: image_display(container),
      kubernetes: kubernetes_display(kubernetes),
      object: detection_object_display(file, network)
    }
  end

  defp detection_evidence(_row), do: %{}

  defp detection_diagnostics(row) when is_map(row) do
    raw = raw_data(row)
    metadata = value(row, "metadata") || %{}
    unmapped = value(row, "unmapped") || %{}

    first_map([
      Map.get(raw, "diagnostics"),
      get_in(raw, ["security_signal", "diagnostics"]),
      get_in(raw, ["metadata", "security_signal", "diagnostics"]),
      get_in(metadata, ["security_signal", "diagnostics"]),
      Map.get(unmapped, "diagnostics")
    ])
  end

  defp detection_diagnostics(_row), do: %{}

  defp diagnostic_value(value, path) when is_map(value) and is_list(path) do
    Enum.reduce_while(path, value, fn key, acc ->
      cond do
        is_map(acc) and Map.has_key?(acc, key) -> {:cont, Map.get(acc, key)}
        is_map(acc) and Map.has_key?(acc, existing_atom_key(key)) -> {:cont, Map.get(acc, existing_atom_key(key))}
        true -> {:halt, nil}
      end
    end)
  end

  defp diagnostic_value(_value, _path), do: nil

  defp existing_atom_key(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end

  defp container_display(container) when is_map(container) do
    first_present([
      diagnostic_value(container, ["name"]),
      diagnostic_value(container, ["id"])
    ])
  end

  defp container_display(_container), do: nil

  defp image_display(container) when is_map(container) do
    image = diagnostic_value(container, ["image"])

    cond do
      is_binary(image) ->
        image

      is_map(image) ->
        repository = diagnostic_value(image, ["repository"]) || diagnostic_value(image, ["name"])
        tag = diagnostic_value(image, ["tag"])
        if blank?(tag), do: repository, else: "#{repository}:#{tag}"

      true ->
        nil
    end
  end

  defp image_display(_container), do: nil

  defp kubernetes_display(kubernetes) when is_map(kubernetes) do
    namespace = diagnostic_value(kubernetes, ["namespace"])
    pod = diagnostic_value(kubernetes, ["pod"])

    case {namespace, pod} do
      {nil, nil} -> nil
      {nil, pod} -> pod
      {namespace, nil} -> namespace
      {namespace, pod} -> "#{namespace}/#{pod}"
    end
  end

  defp kubernetes_display(_kubernetes), do: nil

  defp detection_object_display(file, network) do
    first_present([
      diagnostic_value(file || %{}, ["path"]),
      diagnostic_value(network || %{}, ["destination"]),
      diagnostic_value(network || %{}, ["dst"])
    ])
  end

  defp first_present(values) do
    Enum.find(values, &(not blank?(&1)))
  end

  defp class_label(2002), do: "Vulnerability"
  defp class_label("2002"), do: "Vulnerability"
  defp class_label(2003), do: "Compliance"
  defp class_label("2003"), do: "Compliance"
  defp class_label(2004), do: "Detection"
  defp class_label("2004"), do: "Detection"
  defp class_label(2007), do: "Application Posture"
  defp class_label("2007"), do: "Application Posture"
  defp class_label(4003), do: "DNS Activity"
  defp class_label("4003"), do: "DNS Activity"
  defp class_label(_), do: "Finding"

  defp severity_label(value) do
    case normalize_string(value) do
      "critical" -> "Critical"
      "fatal" -> "Critical"
      "high" -> "High"
      "medium" -> "Medium"
      "low" -> "Low"
      "informational" -> "Informational"
      "info" -> "Informational"
      _ -> "Unknown"
    end
  end

  defp normalize_string(value) when is_binary(value), do: value |> String.trim() |> String.downcase()
  defp normalize_string(_), do: ""

  defp blank?(value), do: is_nil(value) or value == ""

  defp display_value(value) when is_binary(value) and value != "", do: value
  defp display_value(value) when is_integer(value), do: Integer.to_string(value)
  defp display_value(value) when is_float(value), do: Float.to_string(value)
  defp display_value(_value), do: "-"

  defp short_time(%DateTime{} = value), do: Calendar.strftime(value, "%m-%d %H:%M")
  defp short_time(value) when is_binary(value), do: value |> String.replace("T", " ") |> String.slice(0, 16)
  defp short_time(_), do: "-"

  defp event_time(row), do: value(row, "event_timestamp") || value(row, "time")

  defp severity_badge(row), do: severity_badge_class(value(row, "severity"))
  defp severity_badge_class(value), do: value |> severity_label() |> severity_tone()
  defp severity_tone("Critical"), do: "badge-error"
  defp severity_tone("High"), do: "badge-warning"
  defp severity_tone("Medium"), do: "badge-info"
  defp severity_tone("Low"), do: "badge-success"
  defp severity_tone(_), do: "badge-ghost"

  defp severity_bar_class("Critical"), do: "bg-error"
  defp severity_bar_class("High"), do: "bg-warning"
  defp severity_bar_class("Medium"), do: "bg-info"
  defp severity_bar_class("Low"), do: "bg-success"
  defp severity_bar_class(_), do: "bg-base-content/30"

  defp status_badge(row) do
    case value(row, "status_id") do
      2 -> "badge-error"
      "2" -> "badge-error"
      _ -> "badge-success"
    end
  end

  defp dns_query(row), do: raw_value(row, ["query", "hostname"])

  defp dns_rule_name(row), do: raw_value(row, ["firewall_rule", "name"])

  defp dns_action(row) do
    raw_value(row, ["firewall_rule", "type"]) ||
      raw_value(row, ["action"]) ||
      raw_value(row, ["rcode"]) ||
      value(row, "status")
  end

  defp dns_block?(row) do
    action = normalize_string(dns_action(row))

    action in ["nxdomain", "blocked", "block", "sinkhole", "refused"] ||
      String.contains?(normalize_string(value(row, "short_message") || value(row, "message")), "rpz")
  end

  defp dns_action_badge(row) do
    if dns_block?(row), do: "badge-warning", else: "badge-info"
  end

  defp raw_value(row, path) do
    row
    |> raw_data()
    |> get_in(path)
  end

  defp raw_data(row) do
    case Map.get(row, "raw_data") || Map.get(row, :raw_data) do
      raw when is_map(raw) ->
        raw

      raw when is_binary(raw) ->
        case Jason.decode(raw) do
          {:ok, decoded} when is_map(decoded) -> decoded
          _ -> %{}
        end

      _ ->
        %{}
    end
  end

  defp metric_border("error"), do: "border-error/30"
  defp metric_border("warning"), do: "border-warning/30"
  defp metric_border("info"), do: "border-info/30"
  defp metric_border(_), do: "border-base-300"

  defp source_signal_href(%{row: row, query: query}) when is_map(row) and is_binary(query) do
    case value(row, "id") do
      id when is_binary(id) and id != "" -> ~p"/events/#{id}"
      _ -> observability_href(query)
    end
  end

  defp source_signal_href(%{row: row}) when is_map(row) do
    case value(row, "id") do
      id when is_binary(id) and id != "" -> ~p"/events/#{id}"
      _ -> observability_href("in:events sort:time:desc limit:100")
    end
  end

  defp source_signal_href(%{query: query}) when is_binary(query), do: observability_href(query)

  defp source_signal_href(_signal), do: observability_href("in:security_findings sort:time:desc limit:100")

  defp observability_href(query), do: ~p"/observability?#{%{tab: "events", q: query}}"

  defp severity_query("Unknown"), do: "in:security_findings sort:time:desc limit:100"
  defp severity_query(label), do: "in:security_findings severity:#{label} sort:time:desc limit:100"

  defp class_query("Vulnerability"), do: "in:security_findings class_uid:2002 sort:time:desc limit:100"
  defp class_query("Compliance"), do: "in:security_findings class_uid:2003 sort:time:desc limit:100"
  defp class_query("Detection"), do: "in:security_findings class_uid:2004 sort:time:desc limit:100"
  defp class_query("Application Posture"), do: "in:security_findings class_uid:2007 sort:time:desc limit:100"
  defp class_query(_label), do: "in:security_findings sort:time:desc limit:100"

  defp short_uuid(value) when is_binary(value), do: String.slice(value, 0, 8)
  defp short_uuid(value), do: value |> to_string() |> short_uuid()

  defp format_error(reason), do: "Security data is unavailable: #{inspect(reason)}"
end
