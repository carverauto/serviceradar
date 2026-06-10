defmodule ServiceRadarWebNGWeb.SecurityLive.Index do
  @moduledoc false
  use ServiceRadarWebNGWeb, :live_view

  alias ServiceRadar.Inventory.Device
  alias ServiceRadarWebNG.Dashboards

  require Ash.Query

  @finding_limit 100
  @scan_limit 80
  @dns_activity_limit 80
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
      |> assign(:source_signals, [])
      |> assign(:summary, empty_summary())

    if connected?(socket), do: send(self(), :load_security)

    {:ok, socket}
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
       |> assign(:source_signals, source_signals)
       |> assign(:summary, build_summary(findings, scan_activity, dns_activity))}
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
                <.metric_tile label="Active findings" value={@summary.finding_count} tone="error" />
                <.metric_tile label="Critical/high" value={@summary.priority_count} tone="warning" />
                <.metric_tile label="Scan events" value={@summary.scan_count} tone="info" />
                <.metric_tile label="Failed scans" value={@summary.failed_scan_count} tone="error" />
                <.metric_tile label="DNS activity" value={@summary.dns_activity_count} tone="info" />
                <.metric_tile label="DNS blocks" value={@summary.dns_block_count} tone="warning" />
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

  defp metric_tile(assigns) do
    ~H"""
    <div class={["rounded-lg border bg-slate-900/80 p-4", metric_border(@tone)]}>
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
      <div :for={item <- @severity_counts} class="grid grid-cols-[6rem_1fr_3rem] items-center gap-3">
        <span class="text-sm font-medium">{item.label}</span>
        <div class="h-3 overflow-hidden rounded-full bg-white/10">
          <div
            class={["h-full rounded-full", severity_bar_class(item.label)]}
            style={"width: #{item.percent}%"}
          />
        </div>
        <span class="text-right text-sm tabular-nums text-slate-300">{item.count}</span>
      </div>
    </div>
    """
  end

  attr :item, :map, required: true

  defp class_chip(assigns) do
    ~H"""
    <div class="rounded-lg border border-white/10 bg-white/5 p-4">
      <div class="text-sm font-semibold">{@item.label}</div>
      <div class="mt-2 text-2xl font-semibold tabular-nums">{@item.count}</div>
    </div>
    """
  end

  attr :signal, :map, required: true

  defp source_signal_card(assigns) do
    ~H"""
    <div class="min-w-0 rounded-lg border border-white/10 bg-white/5 p-4">
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
            <.device_link row={@signal.row} />
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
          <.link
            :if={value(@signal.row, "id")}
            navigate={~p"/events/#{value(@signal.row, "id")}"}
            class="link link-hover"
          >
            {value(@signal.row, "short_message") || value(@signal.row, "message") ||
              value(@signal.row, "id")}
          </.link>
          <span :if={!value(@signal.row, "id")}>
            {value(@signal.row, "short_message") || value(@signal.row, "message") || "-"}
          </span>
        </div>
      </div>

      <div :if={!@signal.row} class="mt-3 text-xs text-slate-500">
        No row returned by <code>{@signal.query}</code>
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
              {value(row, "short_message") || value(row, "message") || "-"}
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
          </tr>
        </thead>
        <tbody>
          <tr :if={@rows == []}>
            <td colspan="5" class="py-8 text-center text-sm text-slate-300">
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
      %{label: label, count: count, percent: Float.round(count * 100 / total, 1)}
    end
  end

  defp class_counts(rows) do
    rows
    |> Enum.map(&(&1 |> value("class_uid") |> class_label()))
    |> Enum.frequencies()
    |> Enum.map(fn {label, count} -> %{label: label, count: count} end)
    |> Enum.sort_by(& &1.count, :desc)
  end

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

  defp format_error(reason), do: "Security data is unavailable: #{inspect(reason)}"
end
