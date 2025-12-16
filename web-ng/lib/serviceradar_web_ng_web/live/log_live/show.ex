defmodule ServiceRadarWebNGWeb.LogLive.Show do
  use ServiceRadarWebNGWeb, :live_view

  import ServiceRadarWebNGWeb.UIComponents

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Log Details")
     |> assign(:log_id, nil)
     |> assign(:log, nil)
     |> assign(:error, nil)
     |> assign(:srql, %{enabled: false})}
  end

  @impl true
  def handle_params(%{"log_id" => log_id}, _uri, socket) do
    # Try log_id first, then fall back to checking if it matches any unique identifier
    query = "in:logs log_id:\"#{escape_value(log_id)}\" limit:1"

    {log, error} =
      case srql_module().query(query) do
        {:ok, %{"results" => [log | _]}} when is_map(log) ->
          {log, nil}

        {:ok, %{"results" => []}} ->
          # Try alternate query without filter - just return not found
          # The logs entity doesn't support id/log_id filtering consistently
          {nil, "Log entry not found. Note: Log detail view requires log_id field support."}

        {:ok, _other} ->
          {nil, "Unexpected response format"}

        {:error, reason} ->
          # If log_id filter not supported, show helpful message
          error_msg = format_error(reason)

          if String.contains?(error_msg, "unsupported filter") do
            {nil,
             "Log detail view is not available - the logs entity does not support ID-based filtering."}
          else
            {nil, "Failed to load log: #{error_msg}"}
          end
      end

    {:noreply,
     socket
     |> assign(:log_id, log_id)
     |> assign(:log, log)
     |> assign(:error, error)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} srql={@srql}>
      <div class="mx-auto max-w-4xl p-6">
        <.header>
          Log Entry
          <:subtitle>
            <span class="font-mono text-xs">{@log_id}</span>
          </:subtitle>
          <:actions>
            <.ui_button href={~p"/observability?#{%{tab: "logs"}}"} variant="ghost" size="sm">
              Back to logs
            </.ui_button>
          </:actions>
        </.header>

        <div :if={@error} class="rounded-xl border border-error/30 bg-error/5 p-6 text-center">
          <p class="text-sm text-error">{@error}</p>
        </div>

        <div :if={is_map(@log)} class="space-y-4">
          <.log_summary log={@log} />
          <.log_body log={@log} />
          <.log_details log={@log} />
        </div>
      </div>
    </Layouts.app>
    """
  end

  attr :log, :map, required: true

  defp log_summary(assigns) do
    ~H"""
    <div class="rounded-xl border border-base-200 bg-base-100 shadow-sm p-6">
      <div class="flex flex-wrap gap-x-8 gap-y-4">
        <div class="flex flex-col gap-1">
          <span class="text-xs text-base-content/50 uppercase tracking-wider">Level</span>
          <.severity_badge value={Map.get(@log, "severity_text")} />
        </div>

        <div class="flex flex-col gap-1">
          <span class="text-xs text-base-content/50 uppercase tracking-wider">Time</span>
          <span class="text-sm font-mono">{format_timestamp(@log)}</span>
        </div>

        <div :if={has_value?(@log, "service_name")} class="flex flex-col gap-1">
          <span class="text-xs text-base-content/50 uppercase tracking-wider">Service</span>
          <span class="text-sm">{Map.get(@log, "service_name")}</span>
        </div>

        <div :if={has_value?(@log, "scope_name")} class="flex flex-col gap-1">
          <span class="text-xs text-base-content/50 uppercase tracking-wider">Scope</span>
          <span class="text-sm font-mono">{Map.get(@log, "scope_name")}</span>
        </div>

        <div :if={has_value?(@log, "trace_id")} class="flex flex-col gap-1">
          <span class="text-xs text-base-content/50 uppercase tracking-wider">Trace ID</span>
          <span class="text-xs font-mono text-base-content/70">{Map.get(@log, "trace_id")}</span>
        </div>

        <div :if={has_value?(@log, "span_id")} class="flex flex-col gap-1">
          <span class="text-xs text-base-content/50 uppercase tracking-wider">Span ID</span>
          <span class="text-xs font-mono text-base-content/70">{Map.get(@log, "span_id")}</span>
        </div>
      </div>
    </div>
    """
  end

  attr :log, :map, required: true

  defp log_body(assigns) do
    body = Map.get(assigns.log, "body") || Map.get(assigns.log, "message") || ""

    is_json =
      String.starts_with?(String.trim(body), "{") or String.starts_with?(String.trim(body), "[")

    formatted_body =
      if is_json do
        case Jason.decode(body) do
          {:ok, decoded} -> Jason.encode!(decoded, pretty: true)
          {:error, _} -> body
        end
      else
        body
      end

    assigns =
      assigns
      |> assign(:body, body)
      |> assign(:formatted_body, formatted_body)
      |> assign(:is_json, is_json)

    ~H"""
    <div :if={@body != ""} class="rounded-xl border border-base-200 bg-base-100 shadow-sm">
      <div class="px-4 py-3 border-b border-base-200">
        <span class="text-sm font-semibold">Message Body</span>
      </div>

      <div class="p-4">
        <pre class={[
          "text-sm whitespace-pre-wrap break-all",
          @is_json && "font-mono text-xs bg-base-200/30 p-4 rounded-lg overflow-x-auto"
        ]}>{@formatted_body}</pre>
      </div>
    </div>
    """
  end

  attr :log, :map, required: true

  defp log_details(assigns) do
    # Fields shown in summary or body (exclude from details)
    summary_fields =
      ~w(id log_id severity_text severity_number timestamp observed_timestamp service_name scope_name trace_id span_id body message)

    # Get remaining fields
    detail_fields =
      assigns.log
      |> Map.keys()
      |> Enum.reject(&(&1 in summary_fields))
      |> Enum.sort()

    assigns = assign(assigns, :detail_fields, detail_fields)

    ~H"""
    <div :if={@detail_fields != []} class="rounded-xl border border-base-200 bg-base-100 shadow-sm">
      <div class="px-4 py-3 border-b border-base-200">
        <span class="text-sm font-semibold">Additional Metadata</span>
      </div>

      <div class="divide-y divide-base-200">
        <%= for field <- @detail_fields do %>
          <div class="px-4 py-3 flex items-start gap-4">
            <span class="text-xs text-base-content/50 w-36 shrink-0 pt-0.5">
              {humanize_field(field)}
            </span>
            <span class="text-sm flex-1 break-all">
              <.format_value value={Map.get(@log, field)} />
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
        s when s in ["low", "debug", "trace", "ok"] -> "success"
        _ -> "ghost"
      end

    label =
      case assigns.value do
        nil -> "—"
        "" -> "—"
        v when is_binary(v) -> String.upcase(v)
        v -> v |> to_string() |> String.upcase()
      end

    assigns = assign(assigns, :variant, variant) |> assign(:label, label)

    ~H"""
    <.ui_badge variant={@variant} size="sm">{@label}</.ui_badge>
    """
  end

  defp normalize_severity(nil), do: ""
  defp normalize_severity(v) when is_binary(v), do: v |> String.trim() |> String.downcase()
  defp normalize_severity(v), do: v |> to_string() |> normalize_severity()

  defp format_timestamp(log) do
    ts = Map.get(log, "timestamp") || Map.get(log, "observed_timestamp")

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
