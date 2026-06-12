defmodule ServiceRadarWebNGWeb.SecurityLive.Index do
  @moduledoc false
  use ServiceRadarWebNGWeb, :live_view

  alias ServiceRadar.Monitoring.OcsfEvent
  alias ServiceRadar.Observability.TrivyFinding

  require Ash.Query

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "Security")
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
      <div class="mx-auto w-full max-w-7xl min-w-0 space-y-6 overflow-x-hidden pb-24 lg:pb-0">
        <section class="rounded-lg border border-white/10 bg-slate-950/70 text-slate-100 overflow-hidden">
          <div class="grid gap-0 lg:grid-cols-[1.05fr_0.95fr]">
            <div class="p-6 sm:p-8">
              <p class="text-xs font-semibold uppercase tracking-[0.22em] text-error">Security</p>
              <h1 class="mt-2 text-3xl font-semibold tracking-normal text-slate-100">
                Security analytics workbench
              </h1>
              <p class="mt-3 max-w-2xl text-sm leading-6 text-slate-300">
                Start from the packaged security dashboard for scanner coverage, findings, and DNS activity. Use scoped event links for raw investigation without loading duplicate dashboard frames on this page.
              </p>

              <div class="mt-6 flex flex-wrap gap-2">
                <.link navigate={~p"/dashboards/security-findings"} class="btn btn-sm btn-primary">
                  <.icon name="hero-squares-2x2" class="size-4" /> Security Findings
                </.link>
                <.link
                  navigate={observability_href("in:security_findings sort:time:desc limit:100")}
                  class="btn btn-sm btn-outline border-white/20 text-slate-100 hover:border-info hover:bg-info hover:text-info-content"
                >
                  <.icon name="hero-arrow-top-right-on-square" class="size-4" /> Raw Findings
                </.link>
                <.link
                  navigate={~p"/settings/security/vulnerability-feeds"}
                  class="btn btn-sm btn-ghost"
                >
                  <.icon name="hero-cog-6-tooth" class="size-4" /> Advisory Feeds
                </.link>
              </div>
            </div>

            <div class="border-t border-white/10 bg-white/5 p-6 lg:border-l lg:border-t-0">
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

        <section class="rounded-lg border border-white/10 bg-slate-950/70 p-5 text-slate-100">
          <div class="flex flex-wrap items-center justify-between gap-3">
            <div>
              <h2 class="text-base font-semibold">Investigation Shortcuts</h2>
              <p class="text-xs text-slate-400">
                Scoped views for common security analytics pivots
              </p>
            </div>
            <.link navigate={~p"/dashboards"} class="btn btn-xs btn-ghost text-slate-300">
              Dashboard Library
            </.link>
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

  attr :title, :string, required: true
  attr :description, :string, required: true
  attr :href, :string, required: true
  attr :icon, :string, required: true

  defp workflow_card(assigns) do
    ~H"""
    <.link
      navigate={@href}
      class="block min-w-0 rounded-lg border border-white/10 bg-slate-900/80 p-4 transition hover:-translate-y-0.5 hover:border-info/40 hover:bg-slate-900 focus:outline-none focus:ring-2 focus:ring-info/60"
    >
      <div class="flex items-start gap-3">
        <span class="rounded-md bg-white/10 p-2 text-info">
          <.icon name={@icon} class="size-5" />
        </span>
        <div class="min-w-0">
          <div class="text-sm font-semibold text-slate-100">{@title}</div>
          <p class="mt-1 text-xs leading-5 text-slate-400">{@description}</p>
        </div>
      </div>
    </.link>
    """
  end

  attr :label, :string, required: true
  attr :query, :string, required: true

  defp query_shortcut(assigns) do
    ~H"""
    <.link
      navigate={observability_href(@query)}
      class="block rounded-lg border border-white/10 bg-white/5 p-4 transition hover:border-info/40 hover:bg-white/10 focus:outline-none focus:ring-2 focus:ring-info/60"
    >
      <div class="text-sm font-semibold">{@label}</div>
      <code class="mt-2 block truncate text-[0.68rem] text-slate-500">{@query}</code>
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

  attr :detection, :any, default: nil

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

  defp known_atom_key("id"), do: :id
  defp known_atom_key("message"), do: :message
  defp known_atom_key("metadata"), do: :metadata
  defp known_atom_key("raw_data"), do: :raw_data
  defp known_atom_key("severity"), do: :severity
  defp known_atom_key("short_message"), do: :short_message
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

  defp severity_tone("Critical"), do: "badge-error"
  defp severity_tone("High"), do: "badge-warning"
  defp severity_tone("Medium"), do: "badge-info"
  defp severity_tone("Low"), do: "badge-success"
  defp severity_tone(_), do: "badge-ghost"

  defp normalize_string(value) when is_binary(value), do: value |> String.trim() |> String.downcase()
  defp normalize_string(_), do: ""

  defp blank?(value), do: is_nil(value) or value == ""

  defp display_value(value) when is_binary(value) and value != "", do: value
  defp display_value(value) when is_integer(value), do: Integer.to_string(value)
  defp display_value(value) when is_float(value), do: Float.to_string(value)
  defp display_value(_value), do: "-"

  defp short_uuid(value) when is_binary(value), do: String.slice(value, 0, 8)
  defp short_uuid(value), do: value |> to_string() |> short_uuid()

  defp observability_href(query), do: ~p"/observability?#{%{tab: "events", q: query}}"
end
