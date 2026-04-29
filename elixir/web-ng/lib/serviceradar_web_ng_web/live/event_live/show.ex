defmodule ServiceRadarWebNGWeb.EventLive.Show do
  @moduledoc false
  use ServiceRadarWebNGWeb, :live_view

  import ServiceRadarWebNGWeb.UIComponents

  alias ServiceRadar.Monitoring.Alert

  require Ash.Query

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Event Details")
     |> assign(:event_id, nil)
     |> assign(:event, nil)
     |> assign(:related, %{log_id: nil, alert: nil})
     |> assign(:error, nil)
     |> assign(:srql, %{enabled: false})}
  end

  @impl true
  def handle_params(%{"event_id" => event_id}, _uri, socket) do
    query =
      "in:events id:\"#{escape_value(event_id)}\" sort:time:desc limit:1"

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

    {:noreply,
     socket
     |> assign(:event_id, event_id)
     |> assign(:event, event)
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
          <.waf_finding_summary :if={waf_event?(@event)} event={@event} />
          <.related_links related={@related} />
          <.event_details event={@event} />
        </div>
      </div>
    </Layouts.app>
    """
  end

  attr :related, :map, required: true

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

  attr :event, :map, required: true

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

  attr :event, :map, required: true

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

  attr :label, :string, required: true
  attr :value, :any, default: nil
  attr :mono, :boolean, default: false

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

  attr :event, :map, required: true

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

    assigns =
      assigns
      |> assign(:other_fields, other_fields)
      |> assign(:other_fields, other_fields)

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

  # Render values inline (not in pre blocks)
  attr :value, :any, default: nil

  defp inline_value(%{value: nil} = assigns) do
    ~H|<span class="text-base-content/40 text-sm">—</span>|
  end

  defp inline_value(%{value: ""} = assigns) do
    ~H|<span class="text-base-content/40 text-sm">—</span>|
  end

  defp inline_value(%{value: value} = assigns) when is_boolean(value) do
    ~H|<span class="text-sm font-mono">{to_string(@value)}</span>|
  end

  defp inline_value(%{value: value} = assigns) when is_number(value) do
    ~H|<span class="text-sm font-mono">{to_string(@value)}</span>|
  end

  defp inline_value(%{value: value} = assigns) when is_map(value) or is_list(value) do
    # For nested objects, show a compact summary
    summary =
      case value do
        m when is_map(m) -> "{#{map_size(m)} fields}"
        l when is_list(l) -> "[#{length(l)} items]"
      end

    assigns = assign(assigns, :summary, summary)

    ~H|<span class="text-sm text-base-content/60">{@summary}</span>|
  end

  defp inline_value(%{value: value} = assigns) when is_binary(value) do
    # Truncate long values
    display =
      if String.length(value) > 100 do
        String.slice(value, 0, 100) <> "…"
      else
        value
      end

    assigns = assign(assigns, :display, display)

    ~H|<span class="text-sm break-words" title={@value}>{@display}</span>|
  end

  defp inline_value(assigns) do
    ~H|<span class="text-sm">{to_string(@value)}</span>|
  end

  # CloudEvents field ordering
  attr :value, :any, default: nil

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
          <span class="font-mono text-xs">{@value}</span>
          """
      end
    else
      ~H"""
      <span>{@value}</span>
      """
    end
  end

  defp format_value(assigns) do
    ~H"""
    <span>{to_string(@value)}</span>
    """
  end

  attr :value, :any, default: nil

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

    Map.get(event, "log_name") == "security.waf.finding" or
      get_in(event, ["metadata", "security_signal", "kind"]) == "waf" or
      (is_map(waf) and map_size(waf) > 0)
  end

  defp waf_event?(_), do: false

  defp waf_payload(event) when is_map(event) do
    unmapped = Map.get(event, "unmapped") || %{}
    attrs = Map.get(unmapped, "log_attributes") || %{}

    Map.get(unmapped, "waf") ||
      Map.get(unmapped, :waf) ||
      Map.get(attrs, "waf") ||
      Map.get(attrs, :waf) ||
      %{}
  end

  defp waf_payload(_), do: %{}

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
      log_id: log_id_from_event(event),
      alert: fetch_alert(event, scope)
    }
  end

  defp log_id_from_event(event) do
    metadata = Map.get(event, "metadata") || Map.get(event, :metadata) || %{}
    serviceradar = Map.get(metadata, "serviceradar") || Map.get(metadata, :serviceradar) || %{}

    Map.get(serviceradar, "source_log_id") || Map.get(serviceradar, :source_log_id)
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
