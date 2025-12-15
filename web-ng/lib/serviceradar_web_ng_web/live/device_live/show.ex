defmodule ServiceRadarWebNGWeb.DeviceLive.Show do
  use ServiceRadarWebNGWeb, :live_view

  import ServiceRadarWebNGWeb.UIComponents

  alias ServiceRadarWebNGWeb.Dashboard.Engine
  alias ServiceRadarWebNGWeb.Dashboard.Plugins.Table, as: TablePlugin

  @default_limit 50
  @max_limit 200
  @metrics_limit 200
  @availability_window "last_24h"
  @availability_bucket "30m"

  @impl true
  def mount(_params, _session, socket) do
    srql = %{
      enabled: true,
      entity: "devices",
      page_path: nil,
      query: nil,
      draft: nil,
      error: nil,
      viz: nil,
      loading: false,
      builder_available: false,
      builder_open: false,
      builder_supported: false,
      builder_sync: false,
      builder: %{}
    }

    {:ok,
     socket
     |> assign(:page_title, "Device")
     |> assign(:device_id, nil)
     |> assign(:results, [])
     |> assign(:panels, [])
     |> assign(:metric_sections, [])
     |> assign(:sysmon_summary, nil)
     |> assign(:availability, nil)
     |> assign(:healthcheck_summary, nil)
     |> assign(:limit, @default_limit)
     |> assign(:srql, srql)}
  end

  @impl true
  def handle_params(%{"device_id" => device_id} = params, uri, socket) do
    limit = parse_limit(Map.get(params, "limit"), @default_limit, @max_limit)

    default_query =
      "in:devices device_id:\"#{escape_value(device_id)}\" limit:#{limit}"

    query =
      params
      |> Map.get("q", default_query)
      |> to_string()
      |> String.trim()
      |> case do
        "" -> default_query
        other -> other
      end

    srql_module = srql_module()

    {results, error, viz} =
      case srql_module.query(query) do
        {:ok, %{"results" => results} = resp} when is_list(results) ->
          viz =
            case Map.get(resp, "viz") do
              value when is_map(value) -> value
              _ -> nil
            end

          {results, nil, viz}

        {:ok, other} ->
          {[], "unexpected SRQL response: #{inspect(other)}", nil}

        {:error, reason} ->
          {[], "SRQL error: #{format_error(reason)}", nil}
      end

    page_path = uri |> to_string() |> URI.parse() |> Map.get(:path)

    srql =
      socket.assigns.srql
      |> Map.merge(%{
        entity: "devices",
        page_path: page_path,
        query: query,
        draft: query,
        error: error,
        viz: viz,
        loading: false
      })

    srql_response = %{"results" => results, "viz" => viz}

    metric_sections = load_metric_sections(srql_module, device_id)
    sysmon_summary = load_sysmon_summary(srql_module, device_id)
    availability = load_availability(srql_module, device_id)
    healthcheck_summary = load_healthcheck_summary(srql_module, device_id)

    {:noreply,
     socket
     |> assign(:device_id, device_id)
     |> assign(:limit, limit)
     |> assign(:results, results)
     |> assign(:panels, Engine.build_panels(srql_response))
     |> assign(:metric_sections, metric_sections)
     |> assign(:sysmon_summary, sysmon_summary)
     |> assign(:availability, availability)
     |> assign(:healthcheck_summary, healthcheck_summary)
     |> assign(:srql, srql)}
  end

  @impl true
  def handle_event("srql_change", %{"q" => q}, socket) do
    {:noreply, assign(socket, :srql, Map.put(socket.assigns.srql, :draft, to_string(q)))}
  end

  def handle_event("srql_submit", %{"q" => q}, socket) do
    page_path = socket.assigns.srql[:page_path] || "/devices/#{socket.assigns.device_id}"

    query =
      q
      |> to_string()
      |> String.trim()
      |> case do
        "" -> to_string(socket.assigns.srql[:query] || "")
        other -> other
      end

    {:noreply,
     push_patch(socket,
       to: page_path <> "?" <> URI.encode_query(%{"q" => query, "limit" => socket.assigns.limit})
     )}
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    device_row = List.first(Enum.filter(assigns.results, &is_map/1))

    assigns =
      assigns
      |> assign(:device_row, device_row)
      |> assign(
        :metric_sections_to_render,
        Enum.filter(assigns.metric_sections, fn section ->
          is_binary(Map.get(section, :error)) or Map.get(section, :panels, []) != []
        end)
      )

    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} srql={@srql}>
      <div class="mx-auto max-w-7xl p-6">
        <.header>
          Device
          <:subtitle>
            <span class="font-mono text-xs">{@device_id}</span>
          </:subtitle>
          <:actions>
            <.ui_button href={~p"/devices"} variant="ghost" size="sm">Back to devices</.ui_button>
          </:actions>
        </.header>

        <div class="grid grid-cols-1 gap-4">
          <div :if={is_nil(@device_row)} class="text-sm text-base-content/70 p-4">
            No device row returned for this query.
          </div>

          <div
            :if={is_map(@device_row)}
            class="rounded-xl border border-base-200 bg-base-100 shadow-sm p-4"
          >
            <div class="flex flex-wrap gap-x-6 gap-y-2 text-sm">
              <.kv_inline label="Hostname" value={Map.get(@device_row, "hostname")} />
              <.kv_inline label="IP" value={Map.get(@device_row, "ip")} mono />
              <.kv_inline label="Poller" value={Map.get(@device_row, "poller_id")} mono />
              <.kv_inline label="Last Seen" value={Map.get(@device_row, "last_seen")} mono />
              <.kv_inline label="OS" value={Map.get(@device_row, "os_info")} />
              <.kv_inline label="Version" value={Map.get(@device_row, "version_info")} />
            </div>
          </div>

          <.availability_section :if={is_map(@availability)} availability={@availability} />

          <.healthcheck_section :if={is_map(@healthcheck_summary)} summary={@healthcheck_summary} />

          <.sysmon_summary_section :if={is_map(@sysmon_summary)} summary={@sysmon_summary} />

          <%= for section <- @metric_sections_to_render do %>
            <div class="rounded-xl border border-base-200 bg-base-100 shadow-sm">
              <div class="px-4 py-3 border-b border-base-200 flex items-center justify-between gap-3">
                <div class="flex items-center gap-3">
                  <span class="text-sm font-semibold">{section.title}</span>
                  <span class="text-xs text-base-content/50">{section.subtitle}</span>
                </div>
              </div>

              <div :if={is_binary(section.error)} class="px-4 py-3 text-sm text-base-content/70">
                {section.error}
              </div>

              <div :if={is_nil(section.error)}>
                <%= for panel <- section.panels do %>
                  <.live_component
                    module={panel.plugin}
                    id={"device-#{@device_id}-#{section.key}-#{panel.id}"}
                    title={section.title}
                    panel_assigns={Map.put(panel.assigns, :compact, true)}
                  />
                <% end %>
              </div>
            </div>
          <% end %>

          <%= for panel <- @panels do %>
            <.live_component
              module={panel.plugin}
              id={"device-#{panel.id}"}
              title={panel.title}
              panel_assigns={panel.assigns}
            />
          <% end %>
        </div>
      </div>
    </Layouts.app>
    """
  end

  attr :label, :string, required: true
  attr :value, :any, default: nil
  attr :mono, :boolean, default: false

  def kv_inline(assigns) do
    ~H"""
    <div class="flex items-center gap-2">
      <span class="text-base-content/60">{@label}:</span>
      <span class={["text-base-content", @mono && "font-mono text-xs"]}>
        {format_value(@value)}
      </span>
    </div>
    """
  end

  defp format_value(nil), do: "—"
  defp format_value(""), do: "—"
  defp format_value(v) when is_binary(v), do: v
  defp format_value(v), do: to_string(v)

  defp parse_limit(nil, default, _max), do: default

  defp parse_limit(limit, default, max) when is_binary(limit) do
    case Integer.parse(limit) do
      {value, ""} -> parse_limit(value, default, max)
      _ -> default
    end
  end

  defp parse_limit(limit, _default, max) when is_integer(limit) and limit > 0 do
    min(limit, max)
  end

  defp parse_limit(_limit, default, _max), do: default

  defp escape_value(value) when is_binary(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
  end

  defp escape_value(other), do: escape_value(to_string(other))

  defp load_metric_sections(srql_module, device_id) do
    device_id = escape_value(device_id)

    [
      %{
        key: "cpu",
        title: "CPU",
        entity: "cpu_metrics",
        series: nil,
        subtitle: "last 24h · 5m buckets · avg across cores"
      },
      %{
        key: "memory",
        title: "Memory",
        entity: "memory_metrics",
        series: "partition",
        subtitle: "last 24h · 5m buckets · avg"
      },
      %{
        key: "disk",
        title: "Disk",
        entity: "disk_metrics",
        series: "mount_point",
        subtitle: "last 24h · 5m buckets · avg"
      }
    ]
    |> Enum.map(fn spec ->
      query = metric_query(spec.entity, device_id, spec.series)

      base = %{
        key: spec.key,
        title: spec.title,
        subtitle: spec.subtitle,
        query: query,
        panels: [],
        error: nil
      }

      case srql_module.query(query) do
        {:ok, %{"results" => results} = resp} when is_list(results) and results != [] ->
          viz =
            case Map.get(resp, "viz") do
              value when is_map(value) -> value
              _ -> nil
            end

          srql_response = %{"results" => results, "viz" => viz}

          panels =
            srql_response
            |> Engine.build_panels()
            |> prefer_visual_panels(results)

          %{base | panels: panels}

        {:ok, %{"results" => results}} when is_list(results) ->
          base

        {:ok, other} ->
          %{base | error: "unexpected SRQL response: #{inspect(other)}"}

        {:error, reason} ->
          %{base | error: "SRQL error: #{format_error(reason)}"}
      end
    end)
  end

  defp prefer_visual_panels(panels, results) when is_list(panels) do
    has_non_table? = Enum.any?(panels, &(&1.plugin != TablePlugin))

    if results != [] and has_non_table? do
      Enum.reject(panels, &(&1.plugin == TablePlugin))
    else
      panels
    end
  end

  defp prefer_visual_panels(panels, _results), do: panels

  defp metric_query(entity, device_id_escaped, series_field) do
    series_field =
      case series_field do
        nil -> nil
        "" -> nil
        other -> to_string(other) |> String.trim()
      end

    tokens =
      [
        "in:#{entity}",
        "device_id:\"#{device_id_escaped}\"",
        "time:last_24h",
        "bucket:5m",
        "agg:avg",
        "sort:timestamp:desc",
        "limit:#{@metrics_limit}"
      ]

    tokens =
      if is_binary(series_field) and series_field != "" do
        List.insert_at(tokens, 5, "series:#{series_field}")
      else
        tokens
      end

    Enum.join(tokens, " ")
  end

  defp format_error(%Jason.DecodeError{} = err), do: Exception.message(err)
  defp format_error(%ArgumentError{} = err), do: Exception.message(err)
  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)

  # ---------------------------------------------------------------------------
  # Availability Section
  # ---------------------------------------------------------------------------

  attr :availability, :map, required: true

  def availability_section(assigns) do
    uptime_pct = Map.get(assigns.availability, :uptime_pct, 0.0)
    total_checks = Map.get(assigns.availability, :total_checks, 0)
    online_checks = Map.get(assigns.availability, :online_checks, 0)
    offline_checks = Map.get(assigns.availability, :offline_checks, 0)
    segments = Map.get(assigns.availability, :segments, [])

    assigns =
      assigns
      |> assign(:uptime_pct, uptime_pct)
      |> assign(:total_checks, total_checks)
      |> assign(:online_checks, online_checks)
      |> assign(:offline_checks, offline_checks)
      |> assign(:segments, segments)

    ~H"""
    <div class="rounded-xl border border-base-200 bg-base-100 shadow-sm">
      <div class="px-4 py-3 border-b border-base-200">
        <span class="text-sm font-semibold">Availability (24h)</span>
      </div>

      <div class="p-4">
        <div class="flex items-center gap-6 mb-4">
          <div class="flex flex-col">
            <span class="text-3xl font-bold tabular-nums">{format_pct(@uptime_pct)}%</span>
            <span class="text-xs text-base-content/60">Uptime</span>
          </div>
          <div class="flex gap-4 text-sm">
            <div class="flex items-center gap-2">
              <span class="w-3 h-3 rounded-full bg-success"></span>
              <span class="tabular-nums">{@online_checks}</span>
              <span class="text-base-content/60">online</span>
            </div>
            <div class="flex items-center gap-2">
              <span class="w-3 h-3 rounded-full bg-error"></span>
              <span class="tabular-nums">{@offline_checks}</span>
              <span class="text-base-content/60">offline</span>
            </div>
          </div>
        </div>

        <div :if={@segments != []} class="h-6 flex rounded-lg overflow-hidden bg-base-200">
          <%= for seg <- @segments do %>
            <div
              class={["h-full", (seg.available && "bg-success") || "bg-error"]}
              style={"width: #{seg.width}%"}
              title={seg.title}
            />
          <% end %>
        </div>
        <div :if={@segments == []} class="text-sm text-base-content/60">
          No availability data found.
        </div>
      </div>
    </div>
    """
  end

  defp format_pct(value) when is_float(value), do: :erlang.float_to_binary(value, decimals: 1)
  defp format_pct(value) when is_integer(value), do: Integer.to_string(value)
  defp format_pct(_), do: "—"

  # ---------------------------------------------------------------------------
  # Sysmon Summary Section
  # ---------------------------------------------------------------------------

  attr :summary, :map, required: true

  def sysmon_summary_section(assigns) do
    cpu = Map.get(assigns.summary, :cpu, %{})
    memory = Map.get(assigns.summary, :memory, %{})
    disks = Map.get(assigns.summary, :disks, [])
    icmp_rtt = Map.get(assigns.summary, :icmp_rtt)

    assigns =
      assigns
      |> assign(:cpu, cpu)
      |> assign(:memory, memory)
      |> assign(:disks, disks)
      |> assign(:icmp_rtt, icmp_rtt)

    ~H"""
    <div class="rounded-xl border border-base-200 bg-base-100 shadow-sm">
      <div class="px-4 py-3 border-b border-base-200">
        <span class="text-sm font-semibold">System Metrics Overview</span>
      </div>

      <div class="p-4 grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-4">
        <.metric_card
          title="CPU Usage"
          value={format_pct(Map.get(@cpu, :avg_usage, 0.0))}
          suffix="%"
          subtitle={"#{Map.get(@cpu, :core_count, 0)} cores"}
          icon="hero-cpu-chip"
          color={cpu_color(Map.get(@cpu, :avg_usage, 0.0))}
        />

        <.metric_card
          title="Memory"
          value={format_pct(Map.get(@memory, :percent, 0.0))}
          suffix="%"
          subtitle={format_bytes(Map.get(@memory, :used_bytes, 0)) <> " / " <> format_bytes(Map.get(@memory, :total_bytes, 0))}
          icon="hero-rectangle-stack"
          color={memory_color(Map.get(@memory, :percent, 0.0))}
        />

        <.metric_card
          :if={is_number(@icmp_rtt)}
          title="Latency (ICMP)"
          value={format_latency(@icmp_rtt)}
          suffix="ms"
          subtitle="Last check"
          icon="hero-signal"
          color={latency_color(@icmp_rtt)}
        />

        <.metric_card
          :if={@disks != []}
          title="Heaviest Disk"
          value={format_pct(disk_max_percent(@disks))}
          suffix="%"
          subtitle={disk_max_mount(@disks)}
          icon="hero-circle-stack"
          color={disk_color(disk_max_percent(@disks))}
        />
      </div>

      <div :if={@disks != []} class="px-4 pb-4">
        <div class="text-xs font-semibold text-base-content/70 mb-2">Disk Utilization</div>
        <div class="space-y-2">
          <%= for disk <- Enum.take(Enum.sort_by(@disks, & &1.percent, :desc), 5) do %>
            <.disk_bar disk={disk} />
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  attr :title, :string, required: true
  attr :value, :string, required: true
  attr :suffix, :string, default: ""
  attr :subtitle, :string, default: ""
  attr :icon, :string, required: true
  attr :color, :string, default: "primary"

  def metric_card(assigns) do
    ~H"""
    <div class="rounded-lg border border-base-200 bg-base-200/30 p-4">
      <div class="flex items-center gap-2 mb-2">
        <.icon name={@icon} class={["size-4", "text-#{@color}"]} />
        <span class="text-xs text-base-content/70">{@title}</span>
      </div>
      <div class="flex items-baseline gap-1">
        <span class={["text-2xl font-bold tabular-nums", "text-#{@color}"]}>{@value}</span>
        <span class="text-sm text-base-content/60">{@suffix}</span>
      </div>
      <div :if={@subtitle != ""} class="text-xs text-base-content/50 mt-1">{@subtitle}</div>
    </div>
    """
  end

  attr :disk, :map, required: true

  def disk_bar(assigns) do
    pct = Map.get(assigns.disk, :percent, 0.0)
    mount = Map.get(assigns.disk, :mount_point, "?")
    used = format_bytes(Map.get(assigns.disk, :used_bytes, 0))
    total = format_bytes(Map.get(assigns.disk, :total_bytes, 0))
    color = disk_color(pct)

    assigns =
      assigns
      |> assign(:pct, pct)
      |> assign(:mount, mount)
      |> assign(:used, used)
      |> assign(:total, total)
      |> assign(:color, color)

    ~H"""
    <div class="flex items-center gap-3">
      <div class="w-24 truncate text-xs font-mono text-base-content/70" title={@mount}>{@mount}</div>
      <div class="flex-1 h-2 bg-base-200 rounded-full overflow-hidden">
        <div
          class={["h-full rounded-full", "bg-#{@color}"]}
          style={"width: #{min(@pct, 100)}%"}
        />
      </div>
      <div class="w-24 text-right text-xs tabular-nums text-base-content/70">
        {format_pct(@pct)}% <span class="text-base-content/50">({@used})</span>
      </div>
    </div>
    """
  end

  defp cpu_color(pct) when pct >= 90, do: "error"
  defp cpu_color(pct) when pct >= 70, do: "warning"
  defp cpu_color(_), do: "success"

  defp memory_color(pct) when pct >= 90, do: "error"
  defp memory_color(pct) when pct >= 80, do: "warning"
  defp memory_color(_), do: "info"

  defp disk_color(pct) when pct >= 90, do: "error"
  defp disk_color(pct) when pct >= 80, do: "warning"
  defp disk_color(_), do: "primary"

  defp latency_color(ms) when ms >= 200, do: "error"
  defp latency_color(ms) when ms >= 100, do: "warning"
  defp latency_color(_), do: "success"

  defp disk_max_percent([]), do: 0.0

  defp disk_max_percent(disks),
    do: Enum.max_by(disks, & &1.percent, fn -> %{percent: 0.0} end).percent

  defp disk_max_mount([]), do: "—"

  defp disk_max_mount(disks),
    do: Enum.max_by(disks, & &1.percent, fn -> %{mount_point: "—"} end).mount_point

  defp format_bytes(bytes) when is_number(bytes) do
    cond do
      bytes >= 1_099_511_627_776 -> "#{Float.round(bytes / 1_099_511_627_776 * 1.0, 1)} TB"
      bytes >= 1_073_741_824 -> "#{Float.round(bytes / 1_073_741_824 * 1.0, 1)} GB"
      bytes >= 1_048_576 -> "#{Float.round(bytes / 1_048_576 * 1.0, 1)} MB"
      bytes >= 1024 -> "#{Float.round(bytes / 1024 * 1.0, 1)} KB"
      true -> "#{bytes} B"
    end
  end

  defp format_bytes(_), do: "—"

  defp format_latency(ms) when is_float(ms), do: :erlang.float_to_binary(ms, decimals: 1)
  defp format_latency(ms) when is_integer(ms), do: Integer.to_string(ms)
  defp format_latency(_), do: "—"

  # ---------------------------------------------------------------------------
  # Data Loading Functions
  # ---------------------------------------------------------------------------

  defp load_availability(srql_module, device_id) do
    escaped_id = escape_value(device_id)

    query =
      "in:timeseries_metrics metric_type:icmp device_id:\"#{escaped_id}\" " <>
        "time:#{@availability_window} bucket:#{@availability_bucket} agg:count sort:timestamp:asc limit:100"

    case srql_module.query(query) do
      {:ok, %{"results" => rows}} when is_list(rows) and rows != [] ->
        build_availability(rows)

      _ ->
        # Fallback: try healthcheck_results
        fallback_query =
          "in:healthcheck_results device_id:\"#{escaped_id}\" time:#{@availability_window} limit:200"

        case srql_module.query(fallback_query) do
          {:ok, %{"results" => rows}} when is_list(rows) ->
            build_availability_from_healthchecks(rows)

          _ ->
            nil
        end
    end
  end

  defp build_availability(rows) do
    # Each row represents a bucket. If we got ICMP data, the device was online.
    # This is a simplified availability based on metric presence.
    total = length(rows)

    online =
      Enum.count(rows, fn r ->
        is_map(r) and is_number(Map.get(r, "value")) and Map.get(r, "value") > 0
      end)

    offline = total - online

    uptime_pct = if total > 0, do: Float.round(online / total * 100.0, 1), else: 0.0

    segments =
      rows
      |> Enum.filter(&is_map/1)
      |> Enum.map(fn r ->
        value = Map.get(r, "value")
        ts = Map.get(r, "timestamp", "")
        available = is_number(value) and value > 0

        %{
          available: available,
          width: 100.0 / max(length(rows), 1),
          title: "#{ts} - #{if available, do: "Online", else: "Offline"}"
        }
      end)

    %{
      uptime_pct: uptime_pct,
      total_checks: total,
      online_checks: online,
      offline_checks: offline,
      segments: segments
    }
  end

  defp build_availability_from_healthchecks(rows) do
    total = length(rows)

    online =
      Enum.count(rows, fn r ->
        is_map(r) and (Map.get(r, "is_available") == true or Map.get(r, "available") == true)
      end)

    offline = total - online

    uptime_pct = if total > 0, do: Float.round(online / total * 100.0, 1), else: 0.0

    # Build segments (group by time buckets if we have timestamps)
    segments =
      rows
      |> Enum.filter(&is_map/1)
      # Limit segments for display
      |> Enum.take(48)
      |> Enum.map(fn r ->
        available = Map.get(r, "is_available") == true or Map.get(r, "available") == true
        ts = Map.get(r, "timestamp") || Map.get(r, "checked_at", "")

        %{
          available: available,
          width: 100.0 / max(min(length(rows), 48), 1),
          title: "#{ts} - #{if available, do: "Online", else: "Offline"}"
        }
      end)

    %{
      uptime_pct: uptime_pct,
      total_checks: total,
      online_checks: online,
      offline_checks: offline,
      segments: segments
    }
  end

  defp load_sysmon_summary(srql_module, device_id) do
    escaped_id = escape_value(device_id)

    # Load CPU, Memory, Disk metrics in parallel (conceptually - in sequence here)
    cpu_data = load_cpu_summary(srql_module, escaped_id)
    memory_data = load_memory_summary(srql_module, escaped_id)
    disk_data = load_disk_summary(srql_module, escaped_id)
    icmp_rtt = load_icmp_rtt(srql_module, escaped_id)

    if cpu_data || memory_data || disk_data != [] || icmp_rtt do
      %{
        cpu: cpu_data || %{},
        memory: memory_data || %{},
        disks: disk_data || [],
        icmp_rtt: icmp_rtt
      }
    else
      nil
    end
  end

  defp load_cpu_summary(srql_module, escaped_id) do
    query = "in:cpu_metrics device_id:\"#{escaped_id}\" sort:timestamp:desc limit:64"

    case srql_module.query(query) do
      {:ok, %{"results" => rows}} when is_list(rows) and rows != [] ->
        # Get unique cores and calculate average
        values =
          Enum.map(rows, fn r -> extract_numeric(Map.get(r, "value")) end)
          |> Enum.filter(&is_number/1)

        cores =
          rows
          |> Enum.map(fn r -> Map.get(r, "core") || Map.get(r, "cpu_core") end)
          |> Enum.filter(&is_binary/1)
          |> Enum.uniq()
          |> length()

        avg = if values != [], do: Enum.sum(values) / length(values), else: 0.0

        %{
          avg_usage: Float.round(avg * 1.0, 1),
          core_count: max(cores, 1),
          timestamp: Map.get(List.first(rows), "timestamp")
        }

      _ ->
        nil
    end
  end

  defp load_memory_summary(srql_module, escaped_id) do
    query = "in:memory_metrics device_id:\"#{escaped_id}\" sort:timestamp:desc limit:4"

    case srql_module.query(query) do
      {:ok, %{"results" => [row | _]}} when is_map(row) ->
        used = extract_numeric(Map.get(row, "used_bytes") || Map.get(row, "value"))
        total = extract_numeric(Map.get(row, "total_bytes"))

        # Calculate percent if we have both
        pct =
          cond do
            is_number(Map.get(row, "percent")) -> Map.get(row, "percent")
            is_number(used) and is_number(total) and total > 0 -> used / total * 100.0
            true -> 0.0
          end

        %{
          used_bytes: used || 0,
          total_bytes: total || 0,
          percent: Float.round(pct * 1.0, 1),
          timestamp: Map.get(row, "timestamp")
        }

      _ ->
        nil
    end
  end

  defp load_disk_summary(srql_module, escaped_id) do
    query = "in:disk_metrics device_id:\"#{escaped_id}\" sort:timestamp:desc limit:24"

    case srql_module.query(query) do
      {:ok, %{"results" => rows}} when is_list(rows) and rows != [] ->
        # Group by mount point and take the latest for each
        rows
        |> Enum.filter(&is_map/1)
        |> Enum.group_by(fn r ->
          Map.get(r, "mount_point") || Map.get(r, "mount") || "unknown"
        end)
        |> Enum.map(fn {mount, disk_rows} ->
          latest = List.first(disk_rows)
          used = extract_numeric(Map.get(latest, "used_bytes") || Map.get(latest, "value"))
          total = extract_numeric(Map.get(latest, "total_bytes"))

          pct =
            cond do
              is_number(Map.get(latest, "percent")) -> Map.get(latest, "percent")
              is_number(used) and is_number(total) and total > 0 -> used / total * 100.0
              true -> 0.0
            end

          %{
            mount_point: mount,
            used_bytes: used || 0,
            total_bytes: total || 0,
            percent: Float.round(pct * 1.0, 1)
          }
        end)
        |> Enum.sort_by(& &1.percent, :desc)

      _ ->
        []
    end
  end

  defp load_icmp_rtt(srql_module, escaped_id) do
    query =
      "in:timeseries_metrics metric_type:icmp device_id:\"#{escaped_id}\" sort:timestamp:desc limit:1"

    case srql_module.query(query) do
      {:ok, %{"results" => [row | _]}} when is_map(row) ->
        value = extract_numeric(Map.get(row, "value"))

        # Convert from nanoseconds if value is very large
        if is_number(value) do
          if value > 1_000_000.0,
            do: Float.round(value / 1_000_000.0, 2),
            else: Float.round(value * 1.0, 2)
        else
          nil
        end

      _ ->
        nil
    end
  end

  defp extract_numeric(value) when is_number(value), do: value

  defp extract_numeric(value) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {num, ""} -> num
      _ -> nil
    end
  end

  defp extract_numeric(_), do: nil

  # ---------------------------------------------------------------------------
  # Healthcheck Section (GRPC/Service Health)
  # ---------------------------------------------------------------------------

  attr :summary, :map, required: true

  def healthcheck_section(assigns) do
    services = Map.get(assigns.summary, :services, [])
    total = Map.get(assigns.summary, :total, 0)
    available = Map.get(assigns.summary, :available, 0)
    unavailable = Map.get(assigns.summary, :unavailable, 0)
    uptime_pct = if total > 0, do: Float.round(available / total * 100.0, 1), else: 0.0

    assigns =
      assigns
      |> assign(:services, services)
      |> assign(:total, total)
      |> assign(:available, available)
      |> assign(:unavailable, unavailable)
      |> assign(:uptime_pct, uptime_pct)

    ~H"""
    <div class="rounded-xl border border-base-200 bg-base-100 shadow-sm">
      <div class="px-4 py-3 border-b border-base-200 flex items-center justify-between">
        <span class="text-sm font-semibold">Service Health (GRPC)</span>
        <div class="flex items-center gap-4 text-sm">
          <div class="flex items-center gap-2">
            <span class="w-2 h-2 rounded-full bg-success"></span>
            <span class="tabular-nums">{@available}</span>
            <span class="text-base-content/60 text-xs">healthy</span>
          </div>
          <div class="flex items-center gap-2">
            <span class="w-2 h-2 rounded-full bg-error"></span>
            <span class="tabular-nums">{@unavailable}</span>
            <span class="text-base-content/60 text-xs">unhealthy</span>
          </div>
        </div>
      </div>

      <div class="p-4">
        <div :if={@services == []} class="text-sm text-base-content/60">
          No service health data available.
        </div>

        <div :if={@services != []} class="space-y-2">
          <%= for svc <- Enum.take(@services, 10) do %>
            <.healthcheck_row service={svc} />
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  attr :service, :map, required: true

  defp healthcheck_row(assigns) do
    svc = assigns.service
    available = Map.get(svc, :available, false)
    service_name = Map.get(svc, :service_name, "Unknown")
    service_type = Map.get(svc, :service_type, "")
    message = Map.get(svc, :message, "")
    timestamp = Map.get(svc, :timestamp, "")

    assigns =
      assigns
      |> assign(:available, available)
      |> assign(:service_name, service_name)
      |> assign(:service_type, service_type)
      |> assign(:message, message)
      |> assign(:timestamp, timestamp)

    ~H"""
    <div class="flex items-center gap-3 p-2 rounded-lg bg-base-200/30">
      <div class={["w-2.5 h-2.5 rounded-full shrink-0", (@available && "bg-success") || "bg-error"]} />
      <div class="flex-1 min-w-0">
        <div class="flex items-center gap-2">
          <span class="text-sm font-medium truncate">{@service_name}</span>
          <span
            :if={@service_type != ""}
            class="text-xs text-base-content/50 px-1.5 py-0.5 rounded bg-base-200"
          >
            {@service_type}
          </span>
        </div>
        <div :if={@message != ""} class="text-xs text-base-content/60 truncate">{@message}</div>
      </div>
      <div class="text-xs text-base-content/50 shrink-0 font-mono">
        {format_healthcheck_time(@timestamp)}
      </div>
    </div>
    """
  end

  defp format_healthcheck_time(nil), do: ""
  defp format_healthcheck_time(""), do: ""

  defp format_healthcheck_time(ts) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _} -> Calendar.strftime(dt, "%H:%M:%S")
      _ -> ts
    end
  end

  defp format_healthcheck_time(_), do: ""

  defp load_healthcheck_summary(srql_module, device_id) do
    case parse_service_device_id(device_id) do
      {:service, "checker", checker_id} ->
        case parse_checker_identity(checker_id) do
          {:ok, service_name, agent_id} ->
            query =
              "in:services " <>
                "service_name:\"#{escape_value(service_name)}\" " <>
                "agent_id:\"#{escape_value(agent_id)}\" " <>
                "time:last_24h sort:timestamp:desc limit:200"

            case srql_module.query(query) do
              {:ok, %{"results" => rows}} when is_list(rows) and rows != [] ->
                build_healthcheck_summary(rows)

              _ ->
                nil
            end

          :error ->
            nil
        end

      {:service, "agent", agent_id} ->
        query =
          "in:services " <>
            "agent_id:\"#{escape_value(agent_id)}\" " <>
            "time:last_24h sort:timestamp:desc limit:200"

        case srql_module.query(query) do
          {:ok, %{"results" => rows}} when is_list(rows) and rows != [] ->
            build_healthcheck_summary(rows)

          _ ->
            nil
        end

      {:service, "poller", poller_id} ->
        query =
          "in:services " <>
            "poller_id:\"#{escape_value(poller_id)}\" " <>
            "time:last_24h sort:timestamp:desc limit:200"

        case srql_module.query(query) do
          {:ok, %{"results" => rows}} when is_list(rows) and rows != [] ->
            build_healthcheck_summary(rows)

          _ ->
            nil
        end

      {:service, _service_type, service_id} ->
        # Best-effort fallback: show any recent service_status rows matching this service_id as service_name.
        query =
          "in:services " <>
            "service_name:\"#{escape_value(service_id)}\" " <>
            "time:last_24h sort:timestamp:desc limit:200"

        case srql_module.query(query) do
          {:ok, %{"results" => rows}} when is_list(rows) and rows != [] ->
            build_healthcheck_summary(rows)

          _ ->
            nil
        end

      _ ->
        nil
    end
  end

  defp parse_service_device_id(device_id) when is_binary(device_id) do
    case String.split(device_id, ":", parts: 3) do
      ["serviceradar", service_type, service_id] when service_type != "" and service_id != "" ->
        {:service, service_type, service_id}

      _ ->
        :non_service
    end
  end

  defp parse_service_device_id(_), do: :non_service

  defp parse_checker_identity(checker_id) when is_binary(checker_id) do
    case String.split(checker_id, "@", parts: 2) do
      [service_name, agent_id] when service_name != "" and agent_id != "" ->
        {:ok, service_name, agent_id}

      _ ->
        :error
    end
  end

  defp parse_checker_identity(_), do: :error

  defp build_healthcheck_summary(rows) do
    # Group by service_name and take most recent status for each
    services_by_name =
      rows
      |> Enum.filter(&is_map/1)
      |> Enum.reduce(%{}, fn row, acc ->
        service_name = Map.get(row, "service_name") || "Unknown"
        # Keep first (most recent) per service
        Map.put_new(acc, service_name, row)
      end)

    services =
      services_by_name
      |> Map.values()
      |> Enum.map(fn row ->
        %{
          service_name: Map.get(row, "service_name") || "Unknown",
          service_type: Map.get(row, "service_type") || "",
          available: Map.get(row, "available") == true,
          message: Map.get(row, "message") || "",
          timestamp: Map.get(row, "timestamp") || ""
        }
      end)
      |> Enum.sort_by(fn s -> {s.available, s.service_name} end)

    available_count = Enum.count(services, & &1.available)
    unavailable_count = length(services) - available_count

    %{
      services: services,
      total: length(services),
      available: available_count,
      unavailable: unavailable_count
    }
  end

  defp srql_module do
    Application.get_env(:serviceradar_web_ng, :srql_module, ServiceRadarWebNG.SRQL)
  end
end
