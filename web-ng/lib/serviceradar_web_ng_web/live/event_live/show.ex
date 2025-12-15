defmodule ServiceRadarWebNGWeb.EventLive.Show do
  use ServiceRadarWebNGWeb, :live_view

  import ServiceRadarWebNGWeb.UIComponents

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Event Details")
     |> assign(:event_id, nil)
     |> assign(:event, nil)
     |> assign(:error, nil)
     |> assign(:srql, %{enabled: false})}
  end

  @impl true
  def handle_params(%{"event_id" => event_id}, _uri, socket) do
    # Try event_id first since id may not be supported
    query = "in:events event_id:\"#{escape_value(event_id)}\" limit:1"

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
            {nil,
             "Event detail view is not available - the events entity does not support ID-based filtering."}
          else
            {nil, "Failed to load event: #{error_msg}"}
          end
      end

    {:noreply,
     socket
     |> assign(:event_id, event_id)
     |> assign(:event, event)
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
          <.event_details event={@event} />
        </div>
      </div>
    </Layouts.app>
    """
  end

  attr :event, :map, required: true

  defp event_summary(assigns) do
    ~H"""
    <div class="rounded-xl border border-base-200 bg-base-100 shadow-sm p-6">
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

        <div :if={has_value?(@event, "source")} class="flex flex-col gap-1">
          <span class="text-xs text-base-content/50 uppercase tracking-wider">Source</span>
          <span class="text-sm">{Map.get(@event, "source")}</span>
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

  defp event_details(assigns) do
    # Fields to show in summary (exclude from details)
    summary_fields =
      ~w(id event_id severity event_timestamp timestamp host source short_message message)

    # Get remaining fields
    detail_fields =
      assigns.event
      |> Map.keys()
      |> Enum.reject(&(&1 in summary_fields))
      |> Enum.sort()

    assigns = assign(assigns, :detail_fields, detail_fields)

    ~H"""
    <div :if={@detail_fields != []} class="rounded-xl border border-base-200 bg-base-100 shadow-sm">
      <div class="px-4 py-3 border-b border-base-200">
        <span class="text-sm font-semibold">Additional Details</span>
      </div>

      <div class="divide-y divide-base-200">
        <%= for field <- @detail_fields do %>
          <div class="px-4 py-3 flex items-start gap-4">
            <span class="text-xs text-base-content/50 w-32 shrink-0 pt-0.5">
              {humanize_field(field)}
            </span>
            <span class="text-sm flex-1 break-all">
              <.format_value value={Map.get(@event, field)} />
            </span>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

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
    variant =
      case normalize_severity(assigns.value) do
        s when s in ["critical", "fatal", "error"] -> "error"
        s when s in ["high", "warn", "warning"] -> "warning"
        s when s in ["medium", "info"] -> "info"
        s when s in ["low", "debug", "ok"] -> "success"
        _ -> "ghost"
      end

    label =
      case assigns.value do
        nil -> "—"
        "" -> "—"
        v when is_binary(v) -> v
        v -> to_string(v)
      end

    assigns = assign(assigns, :variant, variant) |> assign(:label, label)

    ~H"""
    <.ui_badge variant={@variant} size="sm">{@label}</.ui_badge>
    """
  end

  defp normalize_severity(nil), do: ""
  defp normalize_severity(v) when is_binary(v), do: v |> String.trim() |> String.downcase()
  defp normalize_severity(v), do: v |> to_string() |> normalize_severity()

  defp format_timestamp(event) do
    ts = Map.get(event, "event_timestamp") || Map.get(event, "timestamp")

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

  defp has_value?(map, key) do
    case Map.get(map, key) do
      nil -> false
      "" -> false
      _ -> true
    end
  end

  defp humanize_field(field) when is_binary(field) do
    field
    |> String.replace("_", " ")
    |> String.split()
    |> Enum.map(&String.capitalize/1)
    |> Enum.join(" ")
  end

  defp humanize_field(field), do: to_string(field)

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

  defp srql_module do
    Application.get_env(:serviceradar_web_ng, :srql_module, ServiceRadarWebNG.SRQL)
  end
end
