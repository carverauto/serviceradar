defmodule ServiceRadarWebNGWeb.SecurityLive.Index do
  @moduledoc false
  use ServiceRadarWebNGWeb, :live_view

  alias ServiceRadar.Monitoring.OcsfEvent
  alias ServiceRadar.Observability.TrivyFinding

  require Ash.Query

  @security_overview_query "in:security_findings sort:time:desc limit:25"
  @critical_severities MapSet.new(["critical", "fatal", "high"])

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "Security")
      |> assign(:security_overview, empty_security_overview(:loading))
      |> assign(:selected_trivy_finding_uuid, nil)
      |> assign(:selected_detection_event_id, nil)
      |> assign(:selected_trivy_finding, nil)
      |> assign(:selected_detection, nil)

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply,
     socket
     |> assign(:selected_trivy_finding_uuid, clean_param(Map.get(params, "finding")))
     |> assign(:selected_detection_event_id, clean_param(Map.get(params, "detection")))
     |> assign_security_overview()
     |> assign_selected_security_details()}
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
      <div class="sr-security-page mx-auto w-full max-w-7xl min-w-0 space-y-6 overflow-x-hidden pb-24 font-sans lg:pb-0">
        <section class="overflow-hidden rounded-sr-surface border border-sr-line bg-sr-surface text-sr-ink shadow-sr-surface">
          <div class="grid gap-0 lg:grid-cols-[1.05fr_0.95fr]">
            <div class="p-6 sm:p-8">
              <p class="sr-security-eyebrow text-error">Security</p>
              <h1 class="mt-2 text-sr-ink">
                Security analytics workbench
              </h1>
              <p class="mt-3 max-w-2xl text-sm leading-relaxed text-sr-muted">
                Start from the packaged security dashboard for scanner coverage, findings, and DNS activity. Use scoped event links for raw investigation without loading duplicate dashboard frames on this page.
              </p>

              <div class="mt-6 flex flex-wrap gap-2">
                <.ui_button navigate={~p"/dashboards/security-findings"} size="sm" variant="primary">
                  <.icon name="hero-squares-2x2" class="size-4" /> Security Findings
                </.ui_button>
                <.ui_button
                  navigate={observability_href("in:security_findings sort:time:desc limit:100")}
                  size="sm"
                  variant="outline"
                  class="border-sr-line-strong text-sr-ink hover:border-sr-brand hover:bg-sr-brand/10 hover:text-sr-brand"
                >
                  <.icon name="hero-arrow-top-right-on-square" class="size-4" /> Raw Findings
                </.ui_button>
                <.ui_button
                  navigate={~p"/settings/security/vulnerability-feeds"}
                  size="sm"
                  variant="ghost"
                  class="text-sr-muted hover:bg-sr-subtle hover:text-sr-ink"
                >
                  <.icon name="hero-cog-6-tooth" class="size-4" /> Advisory Feeds
                </.ui_button>
              </div>
            </div>

            <div class="border-t border-sr-line bg-sr-subtle/50 p-6 lg:border-l lg:border-t-0">
              <div class="grid gap-3 sm:grid-cols-2">
                <.workflow_card
                  title="Posture dashboard"
                  description="Coverage, severity, class, source, and package panels from the bundled dashboard package."
                  href={~p"/dashboards/security-findings"}
                  icon="hero-chart-bar-square"
                />
                <.workflow_card
                  title="Scanner findings"
                  description="OCSF Finding rows from Trivy, Bumblebee, Falco, endpoint inventory, and add-on sources."
                  href={observability_href("in:security_findings sort:time:desc limit:100")}
                  icon="hero-shield-exclamation"
                />
                <.workflow_card
                  title="Scan activity"
                  description="OCSF Scan Activity rows that explain scanner runs separately from finding outcomes."
                  href={observability_href("in:scan_activity sort:time:desc limit:80")}
                  icon="hero-magnifying-glass-circle"
                />
                <.workflow_card
                  title="DNS activity"
                  description="PowerDNS RPZ and policy events normalized as OCSF DNS Activity rows."
                  href={observability_href("in:dns_activity source:powerdns sort:time:desc limit:80")}
                  icon="hero-globe-alt"
                />
              </div>
            </div>
          </div>
        </section>

        <div class="grid gap-6 xl:grid-cols-2">
          <.selected_trivy_finding_panel finding={@selected_trivy_finding} />
          <.selected_detection_panel detection={@selected_detection} />
        </div>

        <.security_overview_panel
          overview={@security_overview}
          timezone={@current_scope.user.timezone || "Etc/UTC"}
        />

        <section class="rounded-sr-surface border border-sr-line bg-sr-surface p-5 text-sr-ink shadow-sr-surface">
          <div class="flex flex-wrap items-center justify-between gap-3">
            <div>
              <h2 class="text-sr-ink">Investigation Shortcuts</h2>
              <p class="text-xs leading-relaxed text-sr-muted">
                Scoped views for common security analytics pivots
              </p>
            </div>
            <.ui_button
              navigate={~p"/dashboards"}
              size="xs"
              variant="ghost"
              class="text-sr-muted hover:bg-sr-subtle hover:text-sr-ink"
            >
              Dashboard &amp; Report Library
            </.ui_button>
          </div>

          <div class="mt-4 grid gap-3 md:grid-cols-2 xl:grid-cols-4">
            <.query_shortcut
              label="Critical and high findings"
              query="in:security_findings severity:Critical sort:time:desc limit:100"
            />
            <.query_shortcut
              label="Trivy vulnerabilities"
              query="in:security_findings source:trivy sort:time:desc limit:100"
            />
            <.query_shortcut
              label="Failed scans"
              query="in:scan_activity status:Failure sort:time:desc limit:80"
            />
            <.query_shortcut
              label="DNS blocks"
              query="in:dns_activity source:powerdns sort:time:desc limit:80"
            />
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end

  attr(:overview, :map, required: true)
  attr(:timezone, :string, required: true)

  defp security_overview_panel(assigns) do
    ~H"""
    <section class="rounded-sr-surface border border-sr-line bg-sr-surface p-5 text-sr-ink shadow-sr-surface">
      <div class="flex flex-wrap items-start justify-between gap-3">
        <div>
          <h2 class="text-sr-ink">Live Posture</h2>
          <p class="text-xs leading-relaxed text-sr-muted">
            Recent security findings from the latest indexed rows
          </p>
        </div>
        <.ui_button
          navigate={observability_href(@overview.query)}
          size="xs"
          variant="ghost"
          class="text-sr-muted hover:bg-sr-subtle hover:text-sr-ink"
        >
          Open findings
        </.ui_button>
      </div>

      <div class="mt-4 grid gap-3 md:grid-cols-3">
        <.security_metric label="Recent findings" value={@overview.total} />
        <.security_metric label="Critical / High" value={@overview.critical_high} tone="error" />
        <.security_metric
          label="Active sources"
          value={Enum.count(@overview.source_counts)}
          tone="info"
        />
      </div>

      <div
        :if={@overview.status == :error}
        class="mt-4 rounded-md border border-warning/30 bg-warning/10 p-3 text-sm text-warning"
      >
        Security findings query failed; see logs for the SRQL error.
      </div>

      <div
        :if={@overview.status != :error}
        class="mt-4 grid gap-4 xl:grid-cols-[1fr_1.35fr]"
      >
        <div class="grid gap-3 sm:grid-cols-2 xl:grid-cols-1">
          <.security_count_list title="Severity" rows={@overview.severity_counts} />
          <.security_count_list title="Source" rows={@overview.source_counts} />
        </div>

        <div class="min-w-0 rounded-sr-control border border-sr-line bg-sr-subtle/40">
          <div class="border-b border-sr-line px-4 py-3">
            <h3 class="text-sr-ink">Critical / High Findings</h3>
          </div>
          <div :if={@overview.recent == []} class="px-4 py-6 text-sm text-sr-muted">
            No critical or high findings in the latest indexed rows.
          </div>
          <div :if={@overview.recent != []} class="divide-y divide-sr-line">
            <.recent_security_finding
              :for={finding <- @overview.recent}
              finding={finding}
              timezone={@timezone}
            />
          </div>
        </div>
      </div>
    </section>
    """
  end

  attr(:label, :string, required: true)
  attr(:value, :any, required: true)
  attr(:tone, :string, default: "base")

  defp security_metric(assigns) do
    ~H"""
    <div class="rounded-sr-control border border-sr-line bg-sr-subtle/40 p-4">
      <div class="sr-security-eyebrow text-sr-muted">{@label}</div>
      <div class={["sr-security-metric-value mt-2", metric_tone_class(@tone)]}>
        {@value}
      </div>
    </div>
    """
  end

  attr(:title, :string, required: true)
  attr(:rows, :list, default: [])

  defp security_count_list(assigns) do
    ~H"""
    <div class="rounded-sr-control border border-sr-line bg-sr-subtle/40 p-4">
      <h3 class="text-sr-ink">{@title}</h3>
      <div :if={@rows == []} class="mt-3 text-sm text-sr-muted">No findings</div>
      <div :if={@rows != []} class="mt-3 space-y-2">
        <div :for={row <- @rows} class="flex items-center justify-between gap-3 text-sm">
          <span class="truncate text-sr-muted">{row.label}</span>
          <span class="font-semibold tabular-nums tracking-tight text-sr-ink">{row.count}</span>
        </div>
      </div>
    </div>
    """
  end

  attr(:finding, :map, required: true)
  attr(:timezone, :string, required: true)

  defp recent_security_finding(assigns) do
    ~H"""
    <.link
      navigate={~p"/events/#{@finding.event_id}"}
      class="block min-w-0 px-4 py-3 transition hover:bg-sr-subtle focus:outline-none focus-visible:ring-2 focus-visible:ring-inset focus-visible:ring-sr-focus"
      aria-label={"View event details for #{@finding.title}"}
    >
      <div class="flex flex-wrap items-start justify-between gap-2">
        <div class="min-w-0">
          <div class="truncate text-sm font-semibold tracking-tight text-sr-ink">
            {@finding.title}
          </div>
          <div class="mt-1 flex flex-wrap gap-x-3 gap-y-1 font-mono text-[11px] text-sr-muted">
            <span>{@finding.source}</span>
            <span :if={@finding.resource}>{@finding.resource}</span>
            <.security_finding_time
              :if={@finding.time}
              id={security_finding_time_id(@finding)}
              value={@finding.time}
              timezone={@timezone}
            />
          </div>
        </div>
        <span class={["px-1.5 py-0.5 text-[0.65rem]", severity_badge_class(@finding.severity)]}>
          {@finding.severity || "Unknown"}
        </span>
      </div>
    </.link>
    """
  end

  attr :id, :string, required: true
  attr :value, :any, required: true
  attr :timezone, :string, required: true

  def security_finding_time(assigns) do
    ~H"""
    <.user_time
      id={@id}
      value={@value}
      timezone={@timezone}
      style={:compact}
      fallback="—"
    />
    """
  end

  defp security_finding_time_id(finding) do
    identity = finding.event_id || :erlang.phash2(finding)
    "security-recent-finding-#{identity}-time"
  end

  attr(:title, :string, required: true)
  attr(:description, :string, required: true)
  attr(:href, :string, required: true)
  attr(:icon, :string, required: true)

  defp workflow_card(assigns) do
    ~H"""
    <.link
      navigate={@href}
      class="block min-w-0 rounded-sr-control border border-sr-line bg-sr-raised p-4 transition hover:-translate-y-0.5 hover:border-sr-brand/50 hover:bg-sr-subtle focus:outline-none focus-visible:ring-2 focus-visible:ring-sr-focus"
    >
      <div class="flex items-start gap-3">
        <span class="rounded-sr-small border border-sr-line bg-sr-subtle p-2 text-sr-brand">
          <.icon name={@icon} class="size-5" />
        </span>
        <div class="min-w-0">
          <div class="text-sm font-semibold tracking-tight text-sr-ink">{@title}</div>
          <p class="mt-1 text-xs leading-relaxed text-sr-muted">{@description}</p>
        </div>
      </div>
    </.link>
    """
  end

  attr(:label, :string, required: true)
  attr(:query, :string, required: true)

  defp query_shortcut(assigns) do
    ~H"""
    <.link
      navigate={observability_href(@query)}
      class="block rounded-sr-control border border-sr-line bg-sr-subtle/50 p-4 transition hover:border-sr-brand/50 hover:bg-sr-subtle focus:outline-none focus-visible:ring-2 focus-visible:ring-sr-focus"
    >
      <div class="text-sm font-semibold tracking-tight text-sr-ink">{@label}</div>
      <code class="mt-2 block truncate font-mono text-[11px] text-sr-muted">{@query}</code>
    </.link>
    """
  end

  attr(:finding, :any, default: nil)

  defp selected_trivy_finding_panel(assigns) do
    ~H"""
    <section
      :if={@finding}
      id="trivy-finding-detail"
      class="min-w-0 rounded-sr-surface border border-warning/35 bg-sr-surface p-5 text-sr-ink shadow-sr-surface"
    >
      <div class="flex flex-wrap items-start justify-between gap-3">
        <div class="min-w-0">
          <p class="text-[11px] font-semibold uppercase tracking-wider text-warning">
            Vulnerability Finding
          </p>
          <h2 class="mt-2 text-lg font-semibold tracking-tight text-sr-ink">
            {@finding.finding_id || short_uuid(@finding.finding_uuid)}
          </h2>
          <p class="mt-1 line-clamp-2 text-sm text-sr-muted">
            {@finding.title || @finding.description || "No finding title provided"}
          </p>
        </div>
        <span class={["px-2 py-0.5 text-xs", severity_badge_class(@finding.severity_text)]}>
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
        <.ui_button
          :for={reference <- Enum.take(finding_references(@finding), 3)}
          href={reference}
          size="xs"
          variant="outline"
          class="border-sr-line-strong text-sr-ink hover:border-sr-brand hover:bg-sr-brand/10 hover:text-sr-brand"
          target="_blank"
          rel="noopener noreferrer"
        >
          Reference
        </.ui_button>
        <.ui_button navigate={~p"/events/#{@finding.event_uuid}"} size="xs" variant="ghost">
          Raw report
        </.ui_button>
        <.ui_button patch={~p"/security"} size="xs" variant="ghost">
          Clear selection
        </.ui_button>
      </div>
    </section>
    """
  end

  attr(:detection, :any, default: nil)

  defp selected_detection_panel(assigns) do
    assigns =
      assigns
      |> assign(:evidence, detection_evidence(assigns.detection || %{}))
      |> assign(:detection_id, if(is_map(assigns.detection), do: value(assigns.detection, "id")))

    ~H"""
    <section
      :if={@detection}
      id="runtime-detection-detail"
      class="min-w-0 rounded-sr-surface border border-error/35 bg-sr-surface p-5 text-sr-ink shadow-sr-surface"
    >
      <div class="flex flex-wrap items-start justify-between gap-3">
        <div class="min-w-0">
          <p class="text-[11px] font-semibold uppercase tracking-wider text-error">
            Runtime Detection Evidence
          </p>
          <h2 class="mt-2 text-lg font-semibold tracking-tight text-sr-ink">
            {@evidence.rule || value(@detection, "short_message") || value(@detection, "message") ||
              "Detection"}
          </h2>
          <p class="mt-1 line-clamp-2 text-sm text-sr-muted">
            {value(@detection, "short_message") || value(@detection, "message") ||
              "No detection message provided"}
          </p>
        </div>
        <span class={["px-2 py-0.5 text-xs", severity_badge(@detection)]}>
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
        <.ui_button
          :if={@detection_id}
          navigate={~p"/events/#{@detection_id}"}
          size="xs"
          variant="ghost"
        >
          Raw event
        </.ui_button>
        <.ui_button patch={~p"/security"} size="xs" variant="ghost">
          Clear selection
        </.ui_button>
      </div>
    </section>
    """
  end

  attr(:label, :string, required: true)
  attr(:value, :any, default: nil)
  attr(:mono, :boolean, default: false)

  defp security_fact(assigns) do
    ~H"""
    <div class="min-w-0 rounded-sr-small border border-sr-line bg-sr-subtle/40 p-3">
      <div class="text-[11px] font-semibold uppercase tracking-wider text-sr-muted">
        {@label}
      </div>
      <div class={[
        "mt-1 truncate text-sm tracking-tight text-sr-ink",
        if(@mono, do: "font-mono text-[13px]", else: nil),
        if(blank?(@value), do: "text-sr-muted", else: nil)
      ]}>
        {display_value(@value)}
      </div>
    </div>
    """
  end

  defp assign_security_overview(socket) do
    if connected?(socket) do
      assign(socket, :security_overview, load_security_overview(socket.assigns.current_scope))
    else
      assign(socket, :security_overview, empty_security_overview(:loading))
    end
  end

  defp assign_selected_security_details(socket) do
    if connected?(socket) do
      socket
      |> assign(:selected_trivy_finding, selected_trivy_finding(socket.assigns))
      |> assign(:selected_detection, selected_detection(socket.assigns))
    else
      socket
      |> assign(:selected_trivy_finding, nil)
      |> assign(:selected_detection, nil)
    end
  end

  defp selected_trivy_finding(%{selected_trivy_finding_uuid: nil}), do: nil

  defp selected_trivy_finding(%{selected_trivy_finding_uuid: selected, current_scope: scope}) do
    case Ash.get(TrivyFinding, selected, scope: scope) do
      {:ok, finding} -> finding
      _ -> nil
    end
  end

  defp selected_detection(%{selected_detection_event_id: nil}), do: nil

  defp selected_detection(%{selected_detection_event_id: selected, current_scope: scope}) do
    OcsfEvent
    |> Ash.Query.filter(id == ^selected)
    |> Ash.Query.sort(time: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read(scope: scope)
    |> case do
      {:ok, [event | _]} -> event
      {:ok, %{results: [event | _]}} -> event
      _ -> nil
    end
  end

  defp load_security_overview(scope) do
    case srql_module().query(@security_overview_query, %{scope: scope}) do
      {:ok, %{"results" => rows}} when is_list(rows) ->
        build_security_overview(rows)

      {:ok, %{results: rows}} when is_list(rows) ->
        build_security_overview(rows)

      _ ->
        empty_security_overview(:error)
    end
  end

  defp build_security_overview(rows) when is_list(rows) do
    critical_high_rows =
      Enum.filter(rows, &(normalized_severity(&1) in @critical_severities))

    recent =
      critical_high_rows
      |> Enum.map(&security_finding_row/1)
      |> Enum.sort_by(&severity_rank(&1.severity))
      |> Enum.take(5)

    %{
      status: :ready,
      query: @security_overview_query,
      total: length(rows),
      critical_high: length(critical_high_rows),
      severity_counts: count_rows(rows, &severity_label_for_row/1),
      source_counts: count_rows(rows, &source_label/1),
      recent: recent
    }
  end

  defp empty_security_overview(status) do
    %{
      status: status,
      query: @security_overview_query,
      total: 0,
      critical_high: 0,
      severity_counts: [],
      source_counts: [],
      recent: []
    }
  end

  defp count_rows(rows, label_fun) do
    rows
    |> Enum.map(label_fun)
    |> Enum.reject(&blank?/1)
    |> Enum.frequencies()
    |> Enum.map(fn {label, count} -> %{label: label, count: count} end)
    |> Enum.sort_by(&{-&1.count, &1.label})
    |> Enum.take(5)
  end

  defp security_finding_row(row) do
    %{
      event_id: value(row, "id"),
      title:
        value(row, "finding_title") || value(row, "message") || value(row, "short_message") ||
          value(row, "finding_uid") || value(row, "id") || "Security finding",
      severity: severity_label_for_row(row),
      source: source_label(row),
      resource: resource_label(row),
      time: value(row, "time") || value(row, "event_timestamp")
    }
  end

  defp severity_label_for_row(row), do: row |> value("severity") |> severity_label()

  defp normalized_severity(row), do: row |> value("severity") |> normalize_string()

  defp source_label(row) do
    value(row, "source") ||
      value(row, "log_provider") ||
      nested_value(row, ["metadata", "service_radar", "source_type"]) ||
      "unknown"
  end

  defp resource_label(row) do
    nested_value(row, ["metadata", "service_radar", "resource_name"]) ||
      nested_value(row, ["metadata", "service_radar", "owner_ref"]) ||
      nested_value(row, ["metadata", "service_radar", "namespace"]) ||
      nested_value(row, ["device", "name"]) ||
      nested_value(row, ["device", "uid"])
  end

  defp clean_param(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp clean_param(_value), do: nil

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

  defp nested_value(value, []), do: value

  defp nested_value(%{} = row, [key | rest]) do
    row
    |> value(key)
    |> nested_value(rest)
  end

  defp nested_value(_row, _path), do: nil

  defp known_atom_key("device"), do: :device
  defp known_atom_key("event_timestamp"), do: :event_timestamp
  defp known_atom_key("finding_title"), do: :finding_title
  defp known_atom_key("finding_uid"), do: :finding_uid
  defp known_atom_key("id"), do: :id
  defp known_atom_key("log_provider"), do: :log_provider
  defp known_atom_key("message"), do: :message
  defp known_atom_key("metadata"), do: :metadata
  defp known_atom_key("name"), do: :name
  defp known_atom_key("namespace"), do: :namespace
  defp known_atom_key("owner_ref"), do: :owner_ref
  defp known_atom_key("raw_data"), do: :raw_data
  defp known_atom_key("resource_name"), do: :resource_name
  defp known_atom_key("service_radar"), do: :service_radar
  defp known_atom_key("severity"), do: :severity
  defp known_atom_key("short_message"), do: :short_message
  defp known_atom_key("source"), do: :source
  defp known_atom_key("source_type"), do: :source_type
  defp known_atom_key("time"), do: :time
  defp known_atom_key("uid"), do: :uid
  defp known_atom_key("unmapped"), do: :unmapped
  defp known_atom_key(_), do: nil

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
        is_map(acc) and Map.has_key?(acc, key) ->
          {:cont, Map.get(acc, key)}

        is_map(acc) and Map.has_key?(acc, existing_atom_key(key)) ->
          {:cont, Map.get(acc, existing_atom_key(key))}

        true ->
          {:halt, nil}
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

  defp first_present(values), do: Enum.find(values, &(not blank?(&1)))

  defp first_map(values), do: Enum.find(values, &is_map/1) || %{}

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

  defp severity_badge(row), do: severity_badge_class(value(row, "severity"))
  defp severity_badge_class(value), do: value |> severity_label() |> severity_tone()

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

  # Severity palette: Critical=red, High=orange (not amber), Medium=amber, Low=green.
  defp severity_tone("Critical"), do: "sr-sev-critical"
  defp severity_tone("High"), do: "sr-sev-high"
  defp severity_tone("Medium"), do: "sr-sev-medium"
  defp severity_tone("Low"), do: "sr-sev-low"
  defp severity_tone(_), do: "sr-sev-unknown"

  defp severity_rank("Critical"), do: 0
  defp severity_rank("Fatal"), do: 0
  defp severity_rank("High"), do: 1
  defp severity_rank("Medium"), do: 2
  defp severity_rank("Low"), do: 3
  defp severity_rank(_severity), do: 4

  defp metric_tone_class("error"), do: "text-error"
  defp metric_tone_class("info"), do: "text-info"
  defp metric_tone_class(_tone), do: "text-sr-ink"

  defp normalize_string(value) when is_binary(value), do: value |> String.trim() |> String.downcase()

  defp normalize_string(_), do: ""

  defp blank?(value), do: is_nil(value) or value == ""

  defp display_value(value) when is_binary(value) and value != "", do: value
  defp display_value(value) when is_integer(value), do: Integer.to_string(value)
  defp display_value(value) when is_float(value), do: Float.to_string(value)
  defp display_value(_value), do: "-"

  defp short_uuid(value) when is_binary(value), do: String.slice(value, 0, 8)
  defp short_uuid(value), do: value |> to_string() |> short_uuid()

  defp srql_module do
    Application.get_env(:serviceradar_web_ng, :srql_module, ServiceRadarWebNG.SRQL)
  end

  defp observability_href(query), do: ~p"/observability/events?#{%{q: query}}"
end
