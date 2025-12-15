defmodule ServiceRadarWebNGWeb.DeviceLive.Show do
  use ServiceRadarWebNGWeb, :live_view

  import ServiceRadarWebNGWeb.UIComponents

  alias ServiceRadarWebNGWeb.Dashboard.Engine

  @default_limit 50
  @max_limit 200

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

    {:noreply,
     socket
     |> assign(:device_id, device_id)
     |> assign(:limit, limit)
     |> assign(:results, results)
     |> assign(:panels, Engine.build_panels(srql_response))
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

        <div class="grid grid-cols-1 gap-6">
          <.ui_panel>
            <:header>
              <div class="min-w-0">
                <div class="text-sm font-semibold">Overview</div>
                <div class="text-xs text-base-content/70">Basic identity and current status.</div>
              </div>
            </:header>

            <div :if={is_nil(@device_row)} class="text-sm text-base-content/70">
              No device row returned for this query.
            </div>

            <div :if={is_map(@device_row)} class="grid grid-cols-1 md:grid-cols-2 gap-4">
              <.kv label="Hostname" value={Map.get(@device_row, "hostname")} />
              <.kv label="IP" value={Map.get(@device_row, "ip")} mono />
              <.kv label="Poller" value={Map.get(@device_row, "poller_id")} mono />
              <.kv label="Last Seen" value={Map.get(@device_row, "last_seen")} mono />
              <.kv label="OS" value={Map.get(@device_row, "os_info")} />
              <.kv label="Version" value={Map.get(@device_row, "version_info")} />
            </div>
          </.ui_panel>

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

  def kv(assigns) do
    ~H"""
    <div class="rounded-xl border border-base-200 bg-base-100 px-4 py-3">
      <div class="text-xs font-semibold text-base-content/70 mb-1">{@label}</div>
      <div class={["text-sm text-base-content truncate", @mono && "font-mono text-xs"]}>
        {format_value(@value)}
      </div>
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

  defp format_error(%Jason.DecodeError{} = err), do: Exception.message(err)
  defp format_error(%ArgumentError{} = err), do: Exception.message(err)
  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)

  defp srql_module do
    Application.get_env(:serviceradar_web_ng, :srql_module, ServiceRadarWebNG.SRQL)
  end
end
