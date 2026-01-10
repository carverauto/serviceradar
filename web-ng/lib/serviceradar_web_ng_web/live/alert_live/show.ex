defmodule ServiceRadarWebNGWeb.AlertLive.Show do
  use ServiceRadarWebNGWeb, :live_view

  import ServiceRadarWebNGWeb.UIComponents

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Alert Details")
     |> assign(:alert_id, nil)
     |> assign(:alert, nil)
     |> assign(:error, nil)
     |> assign(:srql, %{enabled: false})}
  end

  @impl true
  def handle_params(%{"alert_id" => alert_id}, _uri, socket) do
    query = "in:alerts id:\"#{escape_value(alert_id)}\" limit:1"

    {alert, error} =
      case srql_module().query(query) do
        {:ok, %{"results" => [alert | _]}} when is_map(alert) ->
          {alert, nil}

        {:ok, %{"results" => []}} ->
          {nil, "Alert not found."}

        {:ok, _other} ->
          {nil, "Unexpected response format"}

        {:error, reason} ->
          {nil, "Failed to load alert: #{format_error(reason)}"}
      end

    {:noreply,
     socket
     |> assign(:alert_id, alert_id)
     |> assign(:alert, alert)
     |> assign(:error, error)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} srql={@srql}>
      <div class="mx-auto max-w-4xl p-6">
        <.header>
          Alert Details
          <:subtitle>
            <span class="font-mono text-xs">{@alert_id}</span>
          </:subtitle>
          <:actions>
            <.ui_button href={~p"/alerts"} variant="ghost" size="sm">
              Back to alerts
            </.ui_button>
          </:actions>
        </.header>

        <div :if={@error} class="rounded-xl border border-error/30 bg-error/5 p-6 text-center">
          <p class="text-sm text-error">{@error}</p>
        </div>

        <div :if={is_map(@alert)} class="space-y-4">
          <.alert_summary alert={@alert} />
          <.alert_links alert={@alert} />
          <.alert_details alert={@alert} />
        </div>
      </div>
    </Layouts.app>
    """
  end

  attr :alert, :map, required: true

  defp alert_summary(assigns) do
    ~H"""
    <div class="rounded-xl border border-base-200 bg-base-100 shadow-sm p-6">
      <div class="flex flex-wrap gap-x-8 gap-y-4 items-start">
        <div class="flex flex-col gap-1">
          <span class="text-xs text-base-content/50 uppercase tracking-wider">Severity</span>
          <.severity_badge value={Map.get(@alert, "severity")} />
        </div>

        <div class="flex flex-col gap-1">
          <span class="text-xs text-base-content/50 uppercase tracking-wider">Status</span>
          <.status_badge value={Map.get(@alert, "status")} />
        </div>

        <div class="flex flex-col gap-1">
          <span class="text-xs text-base-content/50 uppercase tracking-wider">Triggered</span>
          <span class="text-sm font-mono">{format_timestamp(@alert)}</span>
        </div>
      </div>

      <div class="mt-6 pt-6 border-t border-base-200 space-y-3">
        <div>
          <span class="text-xs text-base-content/50 uppercase tracking-wider block mb-1">Title</span>
          <p class="text-sm font-semibold">{Map.get(@alert, "title") || "Alert"}</p>
        </div>
        <div :if={has_value?(@alert, "description")}>
          <span class="text-xs text-base-content/50 uppercase tracking-wider block mb-1">
            Description
          </span>
          <p class="text-sm whitespace-pre-wrap">{Map.get(@alert, "description")}</p>
        </div>
      </div>
    </div>
    """
  end

  attr :alert, :map, required: true

  defp alert_links(assigns) do
    event_id = Map.get(assigns.alert, "event_id")

    assigns = assign(assigns, :event_id, event_id)

    ~H"""
    <div
      :if={is_binary(@event_id)}
      class="rounded-xl border border-base-200 bg-base-100 shadow-sm p-6"
    >
      <span class="text-xs text-base-content/50 uppercase tracking-wider block mb-3">
        Related Records
      </span>
      <div class="flex flex-wrap gap-2">
        <.ui_button :if={@event_id} href={~p"/events/#{@event_id}"} size="sm" variant="ghost">
          View triggering event
        </.ui_button>
      </div>
    </div>
    """
  end

  attr :alert, :map, required: true

  defp alert_details(assigns) do
    detail_fields =
      ~w(source_type source_id service_check_id device_uid agent_uid metric_name metric_value threshold_value comparison event_id event_time)

    metadata = Map.get(assigns.alert, "metadata") || %{}

    assigns =
      assigns
      |> assign(:detail_fields, detail_fields)
      |> assign(:metadata, metadata)

    ~H"""
    <div class="rounded-xl border border-base-200 bg-base-100 shadow-sm p-6 space-y-6">
      <div>
        <span class="text-xs text-base-content/50 uppercase tracking-wider block mb-3">
          Alert Fields
        </span>
        <div class="grid grid-cols-1 sm:grid-cols-2 gap-x-6 gap-y-3">
          <%= for field <- @detail_fields do %>
            <div class="flex flex-col gap-0.5 min-w-0">
              <span class="text-xs text-base-content/50">{field_label(field)}</span>
              <.inline_value value={Map.get(@alert, field)} />
            </div>
          <% end %>
        </div>
      </div>

      <div :if={is_map(@metadata) and map_size(@metadata) > 0}>
        <span class="text-xs text-base-content/50 uppercase tracking-wider block mb-3">
          Metadata
        </span>
        <div class="grid grid-cols-1 sm:grid-cols-2 gap-x-6 gap-y-3">
          <%= for {field, value} <- Enum.sort(@metadata) do %>
            <div class="flex flex-col gap-0.5 min-w-0">
              <span class="text-xs text-base-content/50">{field_label(field)}</span>
              <.inline_value value={value} />
            </div>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

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
    summary =
      case value do
        m when is_map(m) -> "{#{map_size(m)} fields}"
        l when is_list(l) -> "[#{length(l)} items]"
      end

    assigns = assign(assigns, :summary, summary)

    ~H|<span class="text-sm font-mono">{@summary}</span>|
  end

  defp inline_value(%{value: _value} = assigns) do
    ~H|<span class="text-sm font-mono">{to_string(@value)}</span>|
  end

  attr :value, :any, default: nil

  defp severity_badge(assigns) do
    variant = severity_variant(assigns.value)
    label = severity_label(assigns.value)

    assigns = assign(assigns, :variant, variant) |> assign(:label, label)

    ~H"""
    <.ui_badge variant={@variant} size="xs">{@label}</.ui_badge>
    """
  end

  defp severity_variant(value) do
    case normalize_severity(value) do
      s when s in ["emergency", "critical"] -> "error"
      s when s in ["warning"] -> "warning"
      s when s in ["info"] -> "info"
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

  attr :value, :any, default: nil

  defp status_badge(assigns) do
    variant = status_variant(assigns.value)
    label = status_label(assigns.value)

    assigns = assign(assigns, :variant, variant) |> assign(:label, label)

    ~H"""
    <.ui_badge variant={@variant} size="xs">{@label}</.ui_badge>
    """
  end

  defp status_variant(value) do
    case normalize_status(value) do
      "pending" -> "warning"
      "acknowledged" -> "info"
      "resolved" -> "success"
      "escalated" -> "error"
      "suppressed" -> "ghost"
      _ -> "ghost"
    end
  end

  defp status_label(nil), do: "—"
  defp status_label(""), do: "—"
  defp status_label(value) when is_binary(value), do: String.capitalize(value)
  defp status_label(value), do: value |> to_string() |> String.capitalize()

  defp normalize_status(nil), do: ""
  defp normalize_status(v) when is_binary(v), do: String.downcase(v)
  defp normalize_status(v), do: v |> to_string() |> normalize_status()

  defp format_timestamp(alert) do
    ts = Map.get(alert, "triggered_at") || Map.get(alert, "timestamp")

    case parse_timestamp(ts) do
      {:ok, dt} -> Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")
      _ -> ts || "—"
    end
  end

  defp parse_timestamp(nil), do: :error

  defp parse_timestamp(%DateTime{} = dt), do: {:ok, dt}

  defp parse_timestamp(ts) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _} -> {:ok, dt}
      _ -> :error
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

  defp field_label(field) when is_binary(field), do: humanize_field(field)
  defp field_label(field), do: to_string(field)

  defp humanize_field(field) when is_binary(field) do
    field
    |> String.replace("_", " ")
    |> String.split()
    |> Enum.map_join(" ", &String.capitalize/1)
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
