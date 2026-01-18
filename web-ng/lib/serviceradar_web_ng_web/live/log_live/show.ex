defmodule ServiceRadarWebNGWeb.LogLive.Show do
  use ServiceRadarWebNGWeb, :live_view

  import ServiceRadarWebNGWeb.UIComponents

  alias ServiceRadarWebNGWeb.Components.PromotionRuleBuilder

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Log Details")
     |> assign(:log_id, nil)
     |> assign(:log, nil)
     |> assign(:error, nil)
     |> assign(:srql, %{enabled: false})
     |> assign(:show_rule_builder, false)}
  end

  @impl true
  def handle_params(%{"log_id" => log_id}, _uri, socket) do
    # Convert binary UUID to string format if needed
    log_id = normalize_uuid(log_id)

    # Use 'id' field (not 'log_id') to filter logs
    query = "in:logs id:\"#{escape_value(log_id)}\" limit:1"

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
  def handle_event("open_rule_builder", _params, socket) do
    {:noreply, assign(socket, :show_rule_builder, true)}
  end

  @impl true
  def handle_info({:rule_builder_closed}, socket) do
    {:noreply, assign(socket, :show_rule_builder, false)}
  end

  def handle_info({:rule_created, rule}, socket) do
    {:noreply,
     socket
     |> assign(:show_rule_builder, false)
     |> put_flash(
       :info,
       "Rule \"#{rule.name}\" created successfully. View it in Settings > Rules."
     )}
  end

  def handle_info({:rule_creation_failed, reason}, socket) do
    {:noreply,
     socket
     |> put_flash(:error, "Failed to create rule: #{format_error(reason)}")}
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
            <.ui_button
              :if={is_map(@log) and can_create_rules?(@current_scope)}
              phx-click="open_rule_builder"
              variant="primary"
              size="sm"
            >
              <.icon name="hero-bolt" class="w-4 h-4" /> Create Event Rule
            </.ui_button>
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
      
    <!-- Rule Builder Modal -->
      <.live_component
        :if={@show_rule_builder}
        module={PromotionRuleBuilder}
        id="rule-builder"
        log={@log}
        current_scope={@current_scope}
      />
    </Layouts.app>
    """
  end

  # RBAC check - only operators and admins can create rules
  defp can_create_rules?(%{user: %{role: role}}) when role in [:operator, :admin], do: true
  defp can_create_rules?(_), do: false

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

    # Parse attributes fields if present for structured display
    parsed_attributes = parse_attributes(Map.get(assigns.log, "attributes"))
    parsed_resource_attributes = parse_attributes(Map.get(assigns.log, "resource_attributes"))

    assigns =
      assigns
      |> assign(:detail_fields, detail_fields)
      |> assign(:parsed_attributes, parsed_attributes)
      |> assign(:parsed_resource_attributes, parsed_resource_attributes)

    ~H"""
    <div :if={@detail_fields != []} class="rounded-xl border border-base-200 bg-base-100 shadow-sm">
      <div class="px-4 py-3 border-b border-base-200">
        <span class="text-sm font-semibold">Additional Metadata</span>
      </div>

      <div class="divide-y divide-base-200">
        <%= for field <- @detail_fields do %>
          <%= if field == "attributes" and is_map(@parsed_attributes) do %>
            <.parsed_attributes_section attributes={@parsed_attributes} title="Attributes" />
          <% else %>
            <%= if field == "resource_attributes" and is_map(@parsed_resource_attributes) do %>
              <.parsed_attributes_section
                attributes={@parsed_resource_attributes}
                title="Resource Attributes"
              />
            <% else %>
              <div class="px-4 py-3 flex items-start gap-4">
                <span class="text-xs text-base-content/50 w-36 shrink-0 pt-0.5">
                  {humanize_field(field)}
                </span>
                <span class="text-sm flex-1 break-all">
                  <.format_value value={Map.get(@log, field)} />
                </span>
              </div>
            <% end %>
          <% end %>
        <% end %>
      </div>
    </div>
    """
  end

  attr :attributes, :map, required: true
  attr :title, :string, default: "Attributes"

  defp parsed_attributes_section(assigns) do
    ~H"""
    <div class="px-4 py-3">
      <span class="text-xs text-base-content/50 uppercase tracking-wider">{@title}</span>
      <div class="mt-2 space-y-2">
        <%= for {section, values} <- @attributes do %>
          <div class="pl-2 border-l-2 border-base-300">
            <span class="text-xs font-medium text-base-content/70">{section}</span>
            <div class="mt-1 grid grid-cols-[auto,1fr] gap-x-4 gap-y-1">
              <%= for {key, value} <- flatten_attribute_values(values) do %>
                <span class="text-xs text-base-content/50">{key}</span>
                <span class="text-sm break-all">{format_attribute_value(value)}</span>
              <% end %>
            </div>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  # Parse attribute strings into structured maps
  # Handles: already-parsed maps, JSON strings, key={json},key2={json} format, key=value format
  defp parse_attributes(nil), do: nil
  defp parse_attributes(""), do: nil
  defp parse_attributes(value) when is_map(value), do: value

  defp parse_attributes(value) when is_binary(value) do
    value = String.trim(value)

    cond do
      # Try JSON first
      String.starts_with?(value, "{") or String.starts_with?(value, "[") ->
        case Jason.decode(value) do
          {:ok, decoded} when is_map(decoded) -> decoded
          _ -> parse_key_value_format(value)
        end

      # Try key={json},key2={json} or key=value format
      String.contains?(value, "=") ->
        parse_key_value_format(value)

      true ->
        nil
    end
  end

  defp parse_attributes(_), do: nil

  # Parse formats like: attributes={"error":"nats: no heartbeat"},resource={"service.name":"foo"}
  # or simpler: key=value,key2=value2
  defp parse_key_value_format(value) do
    # Match pattern: word={...} or word=value
    # This regex captures: key followed by = and either {json} or plain value until next key= or end
    result =
      ~r/(\w+)=(\{[^}]*\}|[^,]+?)(?=,\w+=|$)/
      |> Regex.scan(value)
      |> Enum.reduce(%{}, fn
        [_full, key, json_value], acc when binary_part(json_value, 0, 1) == "{" ->
          case Jason.decode(json_value) do
            {:ok, decoded} -> Map.put(acc, key, decoded)
            _ -> Map.put(acc, key, json_value)
          end

        [_full, key, plain_value], acc ->
          Map.put(acc, key, String.trim(plain_value))
      end)

    if map_size(result) > 0, do: result, else: nil
  end

  defp flatten_attribute_values(values) when is_map(values) do
    Enum.flat_map(values, fn
      {k, v} when is_map(v) ->
        Enum.map(v, fn {nested_k, nested_v} -> {"#{k}.#{nested_k}", nested_v} end)

      {k, v} ->
        [{k, v}]
    end)
    |> Enum.sort_by(fn {k, _} -> k end)
  end

  defp flatten_attribute_values(value), do: [{"value", value}]

  defp format_attribute_value(value) when is_binary(value), do: value
  defp format_attribute_value(value) when is_number(value), do: to_string(value)
  defp format_attribute_value(value) when is_boolean(value), do: to_string(value)
  defp format_attribute_value(value) when is_map(value), do: Jason.encode!(value)
  defp format_attribute_value(value) when is_list(value), do: Jason.encode!(value)
  defp format_attribute_value(nil), do: "—"
  defp format_attribute_value(value), do: inspect(value)

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

    assigns = assign(assigns, :variant, variant) |> assign(:label, label)

    ~H"""
    <.ui_badge variant={@variant} size="sm">{@label}</.ui_badge>
    """
  end

  defp severity_variant(value) do
    case normalize_severity(value) do
      s when s in ["critical", "fatal", "error"] -> "error"
      s when s in ["high", "warn", "warning"] -> "warning"
      s when s in ["medium", "info"] -> "info"
      s when s in ["low", "debug", "trace", "ok"] -> "success"
      _ -> "ghost"
    end
  end

  defp severity_label(nil), do: "—"
  defp severity_label(""), do: "—"
  defp severity_label(value) when is_binary(value), do: String.upcase(value)

  defp severity_label(value) do
    value
    |> to_string()
    |> String.upcase()
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

  # Convert raw 16-byte binary UUID to string format, or return as-is if already a string
  defp normalize_uuid(<<_::binary-size(16)>> = bin) do
    uuid_to_string(bin)
  end

  defp normalize_uuid(id) when is_binary(id), do: id
  defp normalize_uuid(_), do: "unknown"

  defp uuid_to_string(<<a::32, b::16, c::16, d::16, e::48>>) do
    [a, b, c, d, e]
    |> Enum.map(&Integer.to_string(&1, 16))
    |> Enum.map(&String.downcase/1)
    |> Enum.zip([8, 4, 4, 4, 12])
    |> Enum.map_join("-", fn {hex, len} -> String.pad_leading(hex, len, "0") end)
  end

  defp uuid_to_string(_), do: "unknown"
end
