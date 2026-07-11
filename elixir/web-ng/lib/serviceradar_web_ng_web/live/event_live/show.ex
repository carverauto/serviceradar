defmodule ServiceRadarWebNGWeb.EventLive.Show do
  @moduledoc false
  use ServiceRadarWebNGWeb, :live_view

  import ServiceRadarWebNGWeb.Observability.SignalDisplayComponents
  import ServiceRadarWebNGWeb.UIComponents

  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Monitoring.Alert
  alias ServiceRadarWebNG.Observability.SignalDisplay
  alias ServiceRadarWebNGWeb.AnomalySeriesKey
  alias ServiceRadarWebNGWeb.Observability.EventDeviceReference

  require Ash.Query

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Event Details")
     |> assign(:event_id, nil)
     |> assign(:event, nil)
     |> assign(:signal_display, nil)
     |> assign(:device_ref, nil)
     |> assign(:related, %{log_id: nil, alert: nil})
     |> assign(:error, nil)
     |> assign(:srql, %{enabled: false})}
  end

  @impl true
  def handle_params(%{"event_id" => event_id}, _uri, socket) do
    query =
      "in:events id:\"#{escape_value(event_id)}\" time:last_24h sort:time:desc limit:1"

    {event, error} =
      case srql_module().query(query) do
        {:ok, %{"results" => [event | _]}} when is_map(event) ->
          {event, nil}

        {:ok, %{"results" => []}} ->
          {nil, "Event not found. Note: Event detail view requires event_id field support."}

        {:ok, _other} ->
          {nil, "Unexpected response format"}

        {:error, reason} ->
          error_msg = format_error(reason)

          if String.contains?(error_msg, "unsupported filter") do
            {nil, "Event detail view is not available - the events entity does not support filtering by id."}
          else
            {nil, "Failed to load event: #{error_msg}"}
          end
      end

    related = build_related(event, socket.assigns.current_scope)

    device_lookup_scope =
      if connected?(socket), do: socket.assigns.current_scope

    signal_display = build_signal_display(event, device_lookup_scope)
    device_ref = build_device_ref(event, socket.assigns.current_scope)

    {:noreply,
     socket
     |> assign(:event_id, event_id)
     |> assign(:event, event)
     |> assign(:signal_display, signal_display)
     |> assign(:device_ref, device_ref)
     |> assign(:related, related)
     |> assign(:error, error)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} srql={@srql}>
      <div class="mx-auto max-w-4xl p-6">
        <.header>
          Event Details
          <:subtitle>
            <span class="font-mono text-xs">{@event_id}</span>
          </:subtitle>
          <:actions>
            <.ui_button href={~p"/events"} variant="ghost" size="sm">
              Back to events
            </.ui_button>
          </:actions>
        </.header>

        <div :if={@error} class="rounded-xl border border-error/30 bg-error/5 p-6 text-center">
          <p class="text-sm text-error">{@error}</p>
        </div>

        <div :if={is_map(@event)} class="space-y-4">
          <.event_summary event={@event} />
          <.affected_device :if={is_map(@device_ref)} device_ref={@device_ref} />
          <.signal_display_panel :if={is_list(@signal_display)} widgets={@signal_display} />
          <.anomaly_detection_summary :if={anomaly_finding?(@event)} event={@event} />
          <.capacity_forecast_summary :if={capacity_forecast_event?(@event)} event={@event} />
          <.waf_finding_summary :if={waf_event?(@event)} event={@event} />
          <.falco_runtime_summary :if={falco_event?(@event)} event={@event} />
          <.related_links related={@related} />
          <.event_details event={@event} />
        </div>
      </div>
    </Layouts.app>
    """
  end

  attr(:related, :map, required: true)

  defp related_links(assigns) do
    log_id = Map.get(assigns.related, :log_id)
    alert = Map.get(assigns.related, :alert)

    assigns =
      assigns
      |> assign(:log_id, log_id)
      |> assign(:alert, alert)

    ~H"""
    <div
      :if={is_binary(@log_id) or is_struct(@alert)}
      class="rounded-xl border border-base-200 bg-base-100 p-6"
    >
      <span class="text-xs text-base-content/50 uppercase tracking-wider block mb-3">
        Related Records
      </span>
      <div class="flex flex-wrap gap-2">
        <.ui_button :if={@log_id} href={~p"/logs/#{@log_id}"} size="sm" variant="ghost">
          View source log
        </.ui_button>
        <.ui_button :if={is_struct(@alert)} href={~p"/alerts/#{@alert.id}"} size="sm" variant="ghost">
          View alert ({@alert.status})
        </.ui_button>
      </div>
    </div>
    """
  end

  attr(:device_ref, :map, required: true)

  defp affected_device(assigns) do
    assigns = assign(assigns, :label, device_ref_label(assigns.device_ref))

    ~H"""
    <div class="rounded-xl border border-primary/30 bg-primary/5 p-6">
      <div class="flex flex-wrap items-center justify-between gap-4">
        <div class="min-w-0">
          <span class="text-xs text-primary uppercase tracking-wider block mb-1">
            Affected Device
          </span>
          <div class="text-sm font-medium truncate">{@label}</div>
          <div :if={@device_ref.guest} class="mt-0.5 text-xs font-mono text-base-content/60">
            Guest {@device_ref.guest}
          </div>
          <div class="mt-0.5 text-xs font-mono text-base-content/40 break-all">
            {@device_ref.uid}
          </div>
        </div>
        <.ui_button navigate={~p"/devices/#{@device_ref.uid}"} variant="primary" size="sm">
          View device →
        </.ui_button>
      </div>
    </div>
    """
  end

  defp device_ref_label(%{hostname: hostname}) when is_binary(hostname) and hostname != "", do: hostname

  defp device_ref_label(%{guest: guest}) when is_binary(guest) and guest != "", do: "Proxmox guest #{guest}"

  defp device_ref_label(%{uid: uid}), do: uid

  defp build_device_ref(event, scope) when is_map(event), do: EventDeviceReference.resolve(event, scope)

  defp build_device_ref(_event, _scope), do: nil

  attr(:event, :map, required: true)

  defp event_summary(assigns) do
    source = event_source(assigns.event)

    assigns = assign(assigns, :source, source)

    ~H"""
    <div class="rounded-xl border border-base-200 bg-base-100 p-6">
      <div class="flex flex-wrap gap-x-8 gap-y-4">
        <div class="flex flex-col gap-1">
          <span class="text-xs text-base-content/50 uppercase tracking-wider">Severity</span>
          <.severity_badge value={Map.get(@event, "severity")} />
        </div>

        <div class="flex flex-col gap-1">
          <span class="text-xs text-base-content/50 uppercase tracking-wider">Time</span>
          <span class="text-sm font-mono">{format_timestamp(@event)}</span>
        </div>

        <div :if={has_value?(@event, "host")} class="flex flex-col gap-1">
          <span class="text-xs text-base-content/50 uppercase tracking-wider">Host</span>
          <span class="text-sm font-mono">{Map.get(@event, "host")}</span>
        </div>

        <div :if={@source != "—"} class="flex flex-col gap-1">
          <span class="text-xs text-base-content/50 uppercase tracking-wider">Source</span>
          <span class="text-sm">{@source}</span>
        </div>
      </div>

      <div :if={has_value?(@event, "short_message")} class="mt-6 pt-6 border-t border-base-200">
        <span class="text-xs text-base-content/50 uppercase tracking-wider block mb-2">Message</span>
        <p class="text-sm whitespace-pre-wrap">{Map.get(@event, "short_message")}</p>
      </div>

      <div
        :if={
          has_value?(@event, "message") and
            Map.get(@event, "message") != Map.get(@event, "short_message")
        }
        class="mt-4"
      >
        <span class="text-xs text-base-content/50 uppercase tracking-wider block mb-2">
          Full Message
        </span>
        <p class="text-sm whitespace-pre-wrap font-mono text-base-content/80 bg-base-200/30 p-3 rounded-lg">
          {Map.get(@event, "message")}
        </p>
      </div>
    </div>
    """
  end

  attr(:event, :map, required: true)

  defp anomaly_detection_summary(assigns) do
    finding = anomaly_detection_payload(assigns.event)
    finding_info = nested_map(assigns.event, ["metadata", "finding_info"])
    series_key = map_value(finding, "series_key")

    assigns =
      assigns
      |> assign(:finding, finding)
      |> assign(:finding_info, finding_info)
      |> assign(:series_key, series_key)
      |> assign(:series_display, AnomalySeriesKey.display(series_key) || series_key)

    ~H"""
    <div class="rounded-xl border border-warning/20 bg-warning/5 p-6">
      <div class="flex items-start justify-between gap-4">
        <div class="min-w-0">
          <span class="text-xs text-warning uppercase tracking-wider block mb-2">
            Anomaly Detection Finding
          </span>
          <h2 class="text-lg font-semibold leading-tight">
            {map_value(@finding_info, "title") || Map.get(@event, "message") ||
              "Anomalous metric behavior detected"}
          </h2>
        </div>
        <.severity_badge value={Map.get(@event, "severity")} />
      </div>

      <div class="mt-5 grid grid-cols-1 sm:grid-cols-2 gap-4">
        <.finding_fact label="Series" value={@series_display} title={@series_key} />
        <.finding_fact label="Metric Class" value={map_value(@finding, "metric_class")} />
        <.finding_fact label="State" value={map_value(@finding, "state")} />
        <.finding_fact label="Score" value={map_value(@finding, "score")} mono />
        <.finding_fact label="Reason" value={map_value(@finding, "reason")} />
        <.finding_fact label="Finding UID" value={map_value(@finding_info, "uid")} mono />
      </div>
    </div>
    """
  end

  attr(:event, :map, required: true)

  defp capacity_forecast_summary(assigns) do
    forecast = capacity_forecast_payload(assigns.event)

    assigns =
      assigns
      |> assign(:forecast, forecast)
      |> assign(:resource, map_value(forecast, "resource_label") || map_value(forecast, "resource_key"))

    ~H"""
    <div class="rounded-xl border border-error/20 bg-error/5 p-6">
      <div class="flex items-start justify-between gap-4">
        <div class="min-w-0">
          <span class="text-xs text-error uppercase tracking-wider block mb-2">
            Capacity Forecast
          </span>
          <h2 class="text-lg font-semibold leading-tight">
            {Map.get(@event, "message") || "Resource projected to cross capacity threshold"}
          </h2>
        </div>
        <.severity_badge value={Map.get(@event, "severity")} />
      </div>

      <div class="mt-5 grid grid-cols-1 sm:grid-cols-2 gap-4">
        <.finding_fact label="Resource" value={@resource} mono />
        <.finding_fact label="Metric" value={map_value(@forecast, "metric_name")} />
        <.finding_fact label="Status" value={map_value(@forecast, "status")} />
        <.finding_fact label="Current" value={map_value(@forecast, "current_value")} mono />
        <.finding_fact label="Projected" value={map_value(@forecast, "projected_value")} mono />
        <.finding_fact label="Threshold" value={map_value(@forecast, "exhaustion_threshold")} mono />
        <.finding_fact
          label="Projected Exhaustion"
          value={map_value(@forecast, "projected_exhaustion_at")}
          mono
        />
        <.finding_fact label="Confidence" value={map_value(@forecast, "confidence")} mono />
      </div>
    </div>
    """
  end

  attr(:label, :string, required: true)
  attr(:value, :any, default: nil)
  attr(:title, :any, default: nil)
  attr(:mono, :boolean, default: false)

  defp finding_fact(assigns) do
    assigns = assign(assigns, :title_value, display_value(assigns.title || assigns.value))

    ~H"""
    <div class="min-w-0">
      <span class="text-xs text-base-content/50 uppercase tracking-wider block mb-1">
        {@label}
      </span>
      <span
        class={[
          "text-sm break-words",
          if(@mono, do: "font-mono break-all", else: nil),
          if(blank?(@value), do: "text-base-content/40", else: nil)
        ]}
        title={@title_value}
      >
        {display_value(@value)}
      </span>
    </div>
    """
  end

  attr(:event, :map, required: true)

  defp falco_runtime_summary(assigns) do
    diagnostics = falco_diagnostics(assigns.event)

    assigns =
      assigns
      |> assign(:diagnostics, diagnostics)
      |> assign(:rule, diagnostic_value(diagnostics, ["rule"]))
      |> assign(:host, diagnostic_value(diagnostics, ["host"]))
      |> assign(:process, diagnostic_value(diagnostics, ["process"]))
      |> assign(:parent_process, diagnostic_value(diagnostics, ["parent_process"]))
      |> assign(:user, diagnostic_value(diagnostics, ["user"]))
      |> assign(:container, diagnostic_value(diagnostics, ["container"]))
      |> assign(:kubernetes, diagnostic_value(diagnostics, ["kubernetes"]))
      |> assign(:attribution, diagnostic_value(diagnostics, ["attribution"]))

    ~H"""
    <div class="rounded-xl border border-error/20 bg-error/5 p-6">
      <div class="flex items-start justify-between gap-4">
        <div class="min-w-0">
          <span class="text-xs text-error uppercase tracking-wider block mb-2">
            Falco Runtime Event
          </span>
          <h2 class="text-lg font-semibold leading-tight">
            {diagnostic_value(@rule, ["name"]) || Map.get(@event, "message") || "Falco rule matched"}
          </h2>
        </div>
        <.severity_badge value={diagnostic_value(@rule, ["priority"]) || Map.get(@event, "severity")} />
      </div>

      <div class="mt-5 grid grid-cols-1 sm:grid-cols-2 gap-4">
        <.diagnostic_fact label="Rule" value={diagnostic_value(@rule, ["name"])} />
        <.diagnostic_fact label="Host" value={diagnostic_value(@host, ["name"])} mono />
        <.diagnostic_fact label="Process" value={diagnostic_value(@process, ["name"])} />
        <.diagnostic_fact label="Parent" value={diagnostic_value(@parent_process, ["name"])} />
        <.diagnostic_fact label="Command" value={diagnostic_value(@process, ["command"])} mono />
        <.diagnostic_fact label="Working Dir" value={diagnostic_value(@process, ["cwd"])} mono />
        <.diagnostic_fact label="Executable" value={diagnostic_value(@process, ["executable"])} mono />
        <.diagnostic_fact
          label="Executable Flags"
          value={diagnostic_value(@process, ["executable_flags"])}
          mono
        />
        <.diagnostic_fact label="User" value={diagnostic_value(@user, ["name"])} />
        <.diagnostic_fact label="Container" value={container_display(@container)} mono />
        <.diagnostic_fact label="Image" value={image_display(@container)} mono />
        <.diagnostic_fact
          label="Kubernetes Namespace"
          value={diagnostic_value(@kubernetes, ["namespace"])}
        />
        <.diagnostic_fact label="Kubernetes Pod" value={diagnostic_value(@kubernetes, ["pod"])} />
        <.diagnostic_fact
          label="Attribution"
          value={attribution_display(@attribution)}
        />
      </div>
    </div>
    """
  end

  attr(:label, :string, required: true)
  attr(:value, :any, default: nil)
  attr(:mono, :boolean, default: false)

  defp diagnostic_fact(assigns) do
    ~H"""
    <div class="min-w-0">
      <span class="text-xs text-base-content/50 uppercase tracking-wider block mb-1">
        {@label}
      </span>
      <span class={[
        "text-sm break-words",
        if(@mono, do: "font-mono", else: nil),
        if(blank?(@value), do: "text-base-content/40", else: nil)
      ]}>
        {display_diagnostic_value(@value)}
      </span>
    </div>
    """
  end

  attr(:event, :map, required: true)

  defp waf_finding_summary(assigns) do
    assigns =
      assigns
      |> assign(:waf, waf_payload(assigns.event))
      |> assign(:src_ip, waf_src_ip(assigns.event))

    ~H"""
    <div class="rounded-xl border border-error/20 bg-error/5 p-6">
      <div class="flex items-start justify-between gap-4">
        <div class="min-w-0">
          <span class="text-xs text-error uppercase tracking-wider block mb-2">
            WAF Finding
          </span>
          <h2 class="text-lg font-semibold leading-tight">
            {waf_value(@waf, "rule_message") || Map.get(@event, "message") || "Coraza rule matched"}
          </h2>
        </div>
        <.severity_badge value={waf_value(@waf, "rule_severity") || Map.get(@event, "severity")} />
      </div>

      <div class="mt-5 grid grid-cols-1 sm:grid-cols-2 gap-4">
        <.waf_fact label="Client IP" value={@src_ip} mono />
        <.waf_fact label="Rule ID" value={waf_value(@waf, "rule_id")} mono />
        <.waf_fact label="Request Path" value={waf_value(@waf, "request_path")} mono />
        <.waf_fact label="Request ID" value={waf_value(@waf, "request_id")} mono />
        <.waf_fact label="Policy" value={waf_value(@waf, "waf_policy")} />
        <.waf_fact label="Source" value={waf_value(@waf, "source")} />
      </div>
    </div>
    """
  end

  attr(:label, :string, required: true)
  attr(:value, :any, default: nil)
  attr(:mono, :boolean, default: false)

  defp waf_fact(assigns) do
    ~H"""
    <div class="min-w-0">
      <span class="text-xs text-base-content/50 uppercase tracking-wider block mb-1">
        {@label}
      </span>
      <span class={[
        "text-sm break-words",
        if(@mono, do: "font-mono", else: nil),
        if(blank?(@value), do: "text-base-content/40", else: nil)
      ]}>
        {display_value(@value)}
      </span>
    </div>
    """
  end

  attr(:event, :map, required: true)

  defp event_details(assigns) do
    # Fields already shown in summary
    summary_fields =
      ~w(id event_id severity severity_id time event_timestamp timestamp host source short_message message activity_name activity_id class_uid category_uid type_uid)

    # Other fields (not summary)
    other_fields =
      assigns.event
      |> Map.keys()
      |> Enum.reject(&(&1 in summary_fields))
      |> Enum.sort()

    assigns = assign(assigns, :other_fields, other_fields)

    ~H"""
    <%!-- Event Details --%>
    <div
      :if={@other_fields != []}
      class="rounded-xl border border-base-200 bg-base-100 p-6"
    >
      <span class="text-xs text-base-content/50 uppercase tracking-wider block mb-4">
        Event Details
      </span>
      <div class="grid grid-cols-1 sm:grid-cols-2 gap-x-6 gap-y-3">
        <%= for field <- @other_fields do %>
          <div class="flex flex-col gap-0.5 min-w-0">
            <span class="text-xs text-base-content/50">{field_label(field)}</span>
            <.format_value value={Map.get(@event, field)} />
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  # CloudEvents field ordering
  attr(:value, :any, default: nil)

  defp format_value(%{value: nil} = assigns) do
    ~H|<span class="text-base-content/40">—</span>|
  end

  defp format_value(%{value: ""} = assigns) do
    ~H|<span class="text-base-content/40">—</span>|
  end

  defp format_value(%{value: value} = assigns) when is_boolean(value) do
    ~H"""
    <.ui_badge variant={if @value, do: "success", else: "error"} size="xs">
      {to_string(@value)}
    </.ui_badge>
    """
  end

  defp format_value(%{value: value} = assigns) when is_map(value) or is_list(value) do
    formatted = Jason.encode!(value, pretty: true)
    assigns = assign(assigns, :formatted, formatted)

    ~H"""
    <pre class="text-xs font-mono bg-base-200/30 p-2 rounded overflow-x-auto max-h-48">{@formatted}</pre>
    """
  end

  defp format_value(%{value: value} = assigns) when is_binary(value) do
    # Check if it looks like JSON
    if String.starts_with?(value, "{") or String.starts_with?(value, "[") do
      case Jason.decode(value) do
        {:ok, decoded} ->
          formatted = Jason.encode!(decoded, pretty: true)
          assigns = assign(assigns, :formatted, formatted)

          ~H"""
          <pre class="text-xs font-mono bg-base-200/30 p-2 rounded overflow-x-auto max-h-48">{@formatted}</pre>
          """

        {:error, _} ->
          ~H"""
          <span class="font-mono text-xs break-all">{@value}</span>
          """
      end
    else
      ~H"""
      <span class="break-all">{@value}</span>
      """
    end
  end

  defp format_value(assigns) do
    ~H"""
    <span class="break-all">{to_string(@value)}</span>
    """
  end

  attr(:value, :any, default: nil)

  defp severity_badge(assigns) do
    variant = severity_variant(assigns.value)
    label = severity_label(assigns.value)

    assigns = assigns |> assign(:variant, variant) |> assign(:label, label)

    ~H"""
    <.ui_badge variant={@variant} size="sm">{@label}</.ui_badge>
    """
  end

  defp severity_variant(value) do
    case normalize_severity(value) do
      s when s in ["critical", "fatal", "error"] -> "error"
      s when s in ["high", "warn", "warning"] -> "warning"
      s when s in ["medium", "info"] -> "info"
      s when s in ["low", "debug", "ok"] -> "success"
      _ -> "ghost"
    end
  end

  defp severity_label(nil), do: "—"
  defp severity_label(""), do: "—"
  defp severity_label(value) when is_binary(value), do: value
  defp severity_label(value), do: to_string(value)

  defp normalize_severity(nil), do: ""
  defp normalize_severity(v) when is_binary(v), do: v |> String.trim() |> String.downcase()
  defp normalize_severity(v), do: v |> to_string() |> normalize_severity()

  @device_ip_paths ~w(
    metadata.security_signal.diagnostics.network.source_ip
    metadata.security_signal.diagnostics.network.destination_ip
    src_endpoint.ip
    dst_endpoint.ip
  )

  defp build_signal_display(event, scope) when is_map(event) do
    case SignalDisplay.render_record(event) do
      {:ok, widgets} -> Enum.map(widgets, &add_device_ip_links(&1, scope))
      :error -> nil
    end
  end

  defp build_signal_display(_event, _scope), do: nil

  defp add_device_ip_links(%{type: type, fields: fields} = widget, scope)
       when type in [:facts, :timeline] and is_list(fields) do
    Map.put(widget, :fields, Enum.map(fields, &add_device_ip_link(&1, scope)))
  end

  defp add_device_ip_links(widget, _scope), do: widget

  defp add_device_ip_link(%{path: path, value: ip} = field, scope) when path in @device_ip_paths and is_binary(ip) do
    if valid_ip?(ip) do
      Map.put(field, :href, device_ip_path(ip, scope))
    else
      field
    end
  end

  defp add_device_ip_link(field, _scope), do: field

  defp device_ip_path(ip, scope) do
    case lookup_device_by_ip(ip, scope) do
      %Device{uid: uid} when is_binary(uid) and uid != "" ->
        ~p"/devices/#{uid}"

      _ ->
        ~p"/devices?#{%{q: ~s(in:devices ip:\"#{escape_value(ip)}\"), limit: 50}}"
    end
  end

  defp lookup_device_by_ip(_ip, nil), do: nil

  defp lookup_device_by_ip(ip, scope) do
    case Device.get_by_ip(ip, false, scope: scope) do
      {:ok, [%Device{} = device | _]} -> device
      {:ok, %{results: [%Device{} = device | _]}} -> device
      _ -> nil
    end
  end

  defp valid_ip?(ip) do
    case :inet.parse_address(String.to_charlist(String.trim(ip))) do
      {:ok, _address} -> true
      {:error, _reason} -> false
    end
  end

  defp format_timestamp(event) do
    ts =
      Map.get(event, "time") || Map.get(event, "event_timestamp") || Map.get(event, "timestamp")

    case parse_timestamp(ts) do
      {:ok, dt} -> Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S UTC")
      _ -> ts || "—"
    end
  end

  defp parse_timestamp(nil), do: :error
  defp parse_timestamp(""), do: :error

  defp parse_timestamp(value) when is_binary(value) do
    value = String.trim(value)

    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} ->
        {:ok, dt}

      {:error, _} ->
        case NaiveDateTime.from_iso8601(value) do
          {:ok, ndt} -> {:ok, DateTime.from_naive!(ndt, "Etc/UTC")}
          {:error, _} -> :error
        end
    end
  end

  defp parse_timestamp(_), do: :error

  defp event_source(event) do
    source =
      Map.get(event, "log_provider") ||
        Map.get(event, "log_name") ||
        Map.get(event, "host") ||
        Map.get(event, "source") ||
        Map.get(event, "uid") ||
        Map.get(event, "device_id") ||
        Map.get(event, "subject")

    case source do
      nil -> "—"
      "" -> "—"
      v when is_binary(v) -> v
      v -> to_string(v)
    end
  end

  defp waf_event?(event) when is_map(event) do
    waf = waf_payload(event)
    signal = security_signal(event)

    Map.get(event, "log_name") == "security.waf.finding" or
      Map.get(signal, "kind") == "waf" or
      log_attribute(event, "event_type") == "waf.finding" or
      meaningful_map?(waf)
  end

  defp waf_event?(_), do: false

  defp falco_event?(event) when is_map(event) do
    signal = get_in(event, ["metadata", "security_signal"]) || %{}
    falco = falco_payload(event)

    Map.get(signal, "source") == "falco" or
      Map.get(signal, "kind") == "runtime" or
      (is_map(falco) and map_size(falco) > 0)
  end

  defp falco_event?(_), do: false

  defp anomaly_finding?(event) when is_map(event) do
    metadata = map_value(event, "metadata") || %{}

    nested_value(metadata, ["service_radar", "source_type"]) == "anomaly_detection" or
      nested_value(metadata, ["security_signal", "source"]) == "anomaly_detection" or
      nested_value(metadata, ["detection_finding", "type"]) == "anomaly" or
      map_value(event, "log_provider") == "anomaly_detection"
  end

  defp anomaly_finding?(_), do: false

  defp capacity_forecast_event?(event) when is_map(event) do
    metadata = map_value(event, "metadata") || %{}
    unmapped = map_value(event, "unmapped") || %{}

    map_value(metadata, "event_type") == "capacity_forecast" or
      map_value(unmapped, "event_type") == "capacity_forecast" or
      map_value(event, "log_provider") == "capacity_forecasting"
  end

  defp capacity_forecast_event?(_), do: false

  defp anomaly_detection_payload(event) when is_map(event) do
    metadata = map_value(event, "metadata") || %{}
    unmapped = map_value(event, "unmapped") || %{}

    map_value(metadata, "detection_finding") ||
      map_value(unmapped, "detection_finding") ||
      map_value(unmapped, "anomaly") ||
      %{}
  end

  defp anomaly_detection_payload(_), do: %{}

  defp capacity_forecast_payload(event) when is_map(event) do
    metadata = map_value(event, "metadata") || %{}
    unmapped = map_value(event, "unmapped") || %{}

    map_value(unmapped, "capacity_forecast") ||
      map_value(metadata, "capacity_forecast") ||
      %{}
  end

  defp capacity_forecast_payload(_), do: %{}

  defp falco_diagnostics(event) when is_map(event) do
    signal = get_in(event, ["metadata", "security_signal"]) || %{}
    falco = falco_payload(event)

    Map.get(signal, "diagnostics") ||
      Map.get(falco, "diagnostics") ||
      %{}
  end

  defp falco_diagnostics(_), do: %{}

  defp falco_payload(event) when is_map(event) do
    unmapped = Map.get(event, "unmapped") || %{}
    attrs = Map.get(unmapped, "log_attributes") || %{}
    attr_falco = Map.get(attrs, "falco") || Map.get(attrs, :falco)

    Map.get(unmapped, "falco") ||
      Map.get(unmapped, :falco) ||
      attr_falco ||
      %{}
  end

  defp falco_payload(_), do: %{}

  defp waf_payload(event) when is_map(event) do
    unmapped = Map.get(event, "unmapped") || %{}
    attrs = Map.get(unmapped, "log_attributes") || %{}

    payload =
      Map.get(unmapped, "waf") ||
        Map.get(unmapped, :waf) ||
        Map.get(attrs, "waf") ||
        Map.get(attrs, :waf)

    meaningful_payload(payload)
  end

  defp waf_payload(_), do: %{}

  defp security_signal(event) when is_map(event) do
    metadata = Map.get(event, "metadata") || Map.get(event, :metadata) || %{}
    signal = Map.get(metadata, "security_signal") || Map.get(metadata, :security_signal) || %{}

    if is_map(signal), do: signal, else: %{}
  end

  defp security_signal(_event), do: %{}

  defp nested_map(map, path) when is_map(map) and is_list(path) do
    case nested_value(map, path) do
      %{} = nested -> nested
      _ -> %{}
    end
  end

  defp nested_map(_, _), do: %{}

  defp nested_value(map, [key]) when is_map(map), do: map_value(map, key)

  defp nested_value(map, [key | rest]) when is_map(map) do
    case map_value(map, key) do
      %{} = nested -> nested_value(nested, rest)
      _ -> nil
    end
  end

  defp nested_value(_, _), do: nil

  defp map_value(map, key) when is_map(map) and is_binary(key) do
    Map.get(map, key) ||
      Enum.find_value(map, fn
        {map_key, value} when is_atom(map_key) ->
          if Atom.to_string(map_key) == key, do: value

        _ ->
          nil
      end)
  end

  defp map_value(_, _), do: nil

  defp log_attribute(event, key) when is_map(event) do
    unmapped = Map.get(event, "unmapped") || Map.get(event, :unmapped) || %{}
    attrs = Map.get(unmapped, "log_attributes") || Map.get(unmapped, :log_attributes) || %{}

    if is_map(attrs), do: Map.get(attrs, key) || Map.get(attrs, log_attribute_atom_key(key))
  end

  defp log_attribute(_event, _key), do: nil

  defp log_attribute_atom_key("event_type"), do: :event_type
  defp log_attribute_atom_key(_key), do: :__unknown__

  defp meaningful_payload(payload) when is_map(payload) do
    payload
    |> Enum.reject(fn {_key, value} -> blank?(value) end)
    |> Map.new()
  end

  defp meaningful_payload(_payload), do: %{}

  defp meaningful_map?(map) when is_map(map), do: Enum.any?(map, fn {_key, value} -> not blank?(value) end)

  defp meaningful_map?(_map), do: false

  defp waf_src_ip(event) do
    waf = waf_payload(event)

    waf_value(waf, "client_ip") ||
      get_in(event, ["src_endpoint", "ip"]) ||
      get_in(event, [:src_endpoint, :ip])
  end

  defp waf_value(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, waf_atom_key(key))
  end

  defp waf_value(_, _), do: nil

  defp waf_atom_key("client_ip"), do: :client_ip
  defp waf_atom_key("request_id"), do: :request_id
  defp waf_atom_key("request_path"), do: :request_path
  defp waf_atom_key("rule_id"), do: :rule_id
  defp waf_atom_key("rule_message"), do: :rule_message
  defp waf_atom_key("rule_severity"), do: :rule_severity
  defp waf_atom_key("source"), do: :source
  defp waf_atom_key("waf_policy"), do: :waf_policy
  defp waf_atom_key(_), do: :__unknown__

  defp display_value(value) when value in [nil, ""], do: "—"
  defp display_value(value) when is_binary(value), do: value
  defp display_value(value), do: to_string(value)

  defp display_diagnostic_value(value) when value in [nil, ""], do: "—"
  defp display_diagnostic_value(value) when is_binary(value), do: value
  defp display_diagnostic_value(value) when is_boolean(value), do: to_string(value)
  defp display_diagnostic_value(value) when is_number(value), do: to_string(value)

  defp display_diagnostic_value(value) when is_list(value) do
    Enum.map_join(value, ", ", &display_diagnostic_value/1)
  end

  defp display_diagnostic_value(value) when is_map(value) do
    Enum.map_join(value, ", ", fn {key, item} ->
      "#{field_label(to_string(key))}: #{display_diagnostic_value(item)}"
    end)
  end

  defp container_display(container) when is_map(container) do
    diagnostic_value(container, ["name"]) || diagnostic_value(container, ["id"])
  end

  defp container_display(_), do: nil

  defp image_display(container) when is_map(container) do
    repository = diagnostic_value(container, ["image_repository"])
    tag = diagnostic_value(container, ["image_tag"])

    cond do
      is_binary(repository) and is_binary(tag) -> "#{repository}:#{tag}"
      is_binary(repository) -> repository
      true -> diagnostic_value(container, ["image"])
    end
  end

  defp image_display(_), do: nil

  defp attribution_display(attribution) when is_map(attribution) do
    status = diagnostic_value(attribution, ["status"])
    missing = diagnostic_value(attribution, ["missing"])

    case {status, missing} do
      {nil, _} -> nil
      {value, []} -> value
      {value, nil} -> value
      {value, missing_values} -> "#{value} (missing #{display_diagnostic_value(missing_values)})"
    end
  end

  defp attribution_display(_), do: nil

  defp diagnostic_value(data, [key]) when is_map(data), do: Map.get(data, key) || Map.get(data, diagnostic_atom_key(key))

  defp diagnostic_value(data, [key | rest]) when is_map(data) do
    case diagnostic_value(data, [key]) do
      %{} = nested -> diagnostic_value(nested, rest)
      _ -> nil
    end
  end

  defp diagnostic_value(_, _), do: nil

  defp diagnostic_atom_key("rule"), do: :rule
  defp diagnostic_atom_key("host"), do: :host
  defp diagnostic_atom_key("process"), do: :process
  defp diagnostic_atom_key("parent_process"), do: :parent_process
  defp diagnostic_atom_key("user"), do: :user
  defp diagnostic_atom_key("container"), do: :container
  defp diagnostic_atom_key("kubernetes"), do: :kubernetes
  defp diagnostic_atom_key("attribution"), do: :attribution
  defp diagnostic_atom_key("name"), do: :name
  defp diagnostic_atom_key("priority"), do: :priority
  defp diagnostic_atom_key("command"), do: :command
  defp diagnostic_atom_key("cwd"), do: :cwd
  defp diagnostic_atom_key("executable"), do: :executable
  defp diagnostic_atom_key("executable_flags"), do: :executable_flags
  defp diagnostic_atom_key("namespace"), do: :namespace
  defp diagnostic_atom_key("pod"), do: :pod
  defp diagnostic_atom_key("status"), do: :status
  defp diagnostic_atom_key("missing"), do: :missing
  defp diagnostic_atom_key("id"), do: :id
  defp diagnostic_atom_key("image"), do: :image
  defp diagnostic_atom_key("image_repository"), do: :image_repository
  defp diagnostic_atom_key("image_tag"), do: :image_tag
  defp diagnostic_atom_key(_), do: :__unknown__

  defp blank?(value), do: value in [nil, ""]

  defp has_value?(map, key) do
    case Map.get(map, key) do
      nil -> false
      "" -> false
      _ -> true
    end
  end

  # Known field label mappings
  @field_labels %{
    # Common fields
    "_remote_addr" => "Remote Address",
    "short_message" => "Message",
    "timestamp" => "Timestamp",
    "event_timestamp" => "Event Time",
    "time" => "Event Time",
    "created_at" => "Created At",
    "updated_at" => "Updated At",
    "trace_id" => "Trace ID",
    "span_id" => "Span ID",
    "host" => "Host",
    "level" => "Level",
    "severity" => "Severity",
    "severity_id" => "Severity ID",
    "class_uid" => "Class UID",
    "category_uid" => "Category UID",
    "type_uid" => "Type UID",
    "activity_id" => "Activity ID",
    "activity_name" => "Activity",
    "status_id" => "Status ID",
    "status_code" => "Status Code",
    "status_detail" => "Status Detail",
    "log_name" => "Log Name",
    "log_provider" => "Log Provider",
    "log_level" => "Log Level",
    "log_version" => "Log Version"
  }

  defp field_label(field) when is_binary(field) do
    case Map.get(@field_labels, field) do
      nil -> humanize_field(field)
      label -> label
    end
  end

  defp field_label(field), do: to_string(field)

  defp humanize_field(field) when is_binary(field) do
    field
    |> String.replace("_", " ")
    |> String.split()
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp escape_value(value) when is_binary(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
  end

  defp escape_value(other), do: escape_value(to_string(other))

  defp format_error(%Jason.DecodeError{} = err), do: Exception.message(err)
  defp format_error(%ArgumentError{} = err), do: Exception.message(err)
  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)

  defp build_related(nil, _scope), do: %{log_id: nil, alert: nil}

  defp build_related(event, scope) when is_map(event) do
    %{
      log_id: event |> log_id_from_event() |> existing_log_id(scope),
      alert: fetch_alert(event, scope)
    }
  end

  defp log_id_from_event(event) do
    metadata = Map.get(event, "metadata") || Map.get(event, :metadata) || %{}
    serviceradar = Map.get(metadata, "serviceradar") || Map.get(metadata, :serviceradar) || %{}

    Map.get(serviceradar, "source_log_id") || Map.get(serviceradar, :source_log_id)
  end

  defp existing_log_id(nil, _scope), do: nil
  defp existing_log_id("", _scope), do: nil

  defp existing_log_id(log_id, scope) when is_binary(log_id) do
    query = "in:logs id:\"#{escape_value(log_id)}\" time:last_24h limit:1"

    case srql_module().query(query, %{scope: scope}) do
      {:ok, %{"results" => [_log | _]}} -> log_id
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp fetch_alert(event, scope) do
    event_id = Map.get(event, "id") || Map.get(event, "event_id")
    event_time = event_time_from_event(event)

    if is_binary(event_id) do
      query =
        Alert
        |> Ash.Query.for_read(:read, %{})
        |> Ash.Query.filter(event_id == ^event_id)
        |> maybe_filter_event_time(event_time)

      case Ash.read(query, scope: scope) do
        {:ok, %Ash.Page.Keyset{results: [alert | _]}} -> alert
        {:ok, [alert | _]} -> alert
        _ -> nil
      end
    end
  end

  defp event_time_from_event(event) do
    case Map.get(event, "time") || Map.get(event, "event_timestamp") ||
           Map.get(event, "timestamp") do
      %DateTime{} = dt -> dt
      value when is_binary(value) -> parse_datetime(value)
      _ -> nil
    end
  end

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp maybe_filter_event_time(query, nil), do: query

  defp maybe_filter_event_time(query, %DateTime{} = event_time) do
    Ash.Query.filter(query, event_time == ^event_time)
  end

  defp srql_module do
    Application.get_env(:serviceradar_web_ng, :srql_module, ServiceRadarWebNG.SRQL)
  end
end
