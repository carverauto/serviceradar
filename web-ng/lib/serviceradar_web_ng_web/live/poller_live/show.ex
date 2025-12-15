defmodule ServiceRadarWebNGWeb.PollerLive.Show do
  use ServiceRadarWebNGWeb, :live_view

  import ServiceRadarWebNGWeb.UIComponents

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Poller Details")
     |> assign(:poller_id, nil)
     |> assign(:poller, nil)
     |> assign(:error, nil)
     |> assign(:srql, %{enabled: false})}
  end

  @impl true
  def handle_params(%{"poller_id" => poller_id}, _uri, socket) do
    query = "in:pollers poller_id:\"#{escape_value(poller_id)}\" limit:1"

    {poller, error} =
      case srql_module().query(query) do
        {:ok, %{"results" => [poller | _]}} when is_map(poller) ->
          {poller, nil}

        {:ok, %{"results" => []}} ->
          {nil, "Poller not found"}

        {:ok, _other} ->
          {nil, "Unexpected response format"}

        {:error, reason} ->
          {nil, "Failed to load poller: #{format_error(reason)}"}
      end

    {:noreply,
     socket
     |> assign(:poller_id, poller_id)
     |> assign(:poller, poller)
     |> assign(:error, error)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} srql={@srql}>
      <div class="mx-auto max-w-4xl p-6">
        <.header>
          Poller Details
          <:subtitle>
            <span class="font-mono text-xs">{@poller_id}</span>
          </:subtitle>
          <:actions>
            <.ui_button href={~p"/pollers"} variant="ghost" size="sm">
              Back to pollers
            </.ui_button>
          </:actions>
        </.header>

        <div :if={@error} class="rounded-xl border border-error/30 bg-error/5 p-6 text-center">
          <p class="text-sm text-error">{@error}</p>
        </div>

        <div :if={is_map(@poller)} class="space-y-4">
          <.poller_summary poller={@poller} />
          <.poller_details poller={@poller} />
        </div>
      </div>
    </Layouts.app>
    """
  end

  attr :poller, :map, required: true

  defp poller_summary(assigns) do
    ~H"""
    <div class="rounded-xl border border-base-200 bg-base-100 shadow-sm p-6">
      <div class="flex flex-wrap gap-x-8 gap-y-4">
        <div class="flex flex-col gap-1">
          <span class="text-xs text-base-content/50 uppercase tracking-wider">Status</span>
          <.status_badge active={Map.get(@poller, "is_active")} />
        </div>

        <div class="flex flex-col gap-1">
          <span class="text-xs text-base-content/50 uppercase tracking-wider">Poller ID</span>
          <span class="text-sm font-mono">{Map.get(@poller, "poller_id") || "—"}</span>
        </div>

        <div :if={has_value?(@poller, "address")} class="flex flex-col gap-1">
          <span class="text-xs text-base-content/50 uppercase tracking-wider">Address</span>
          <span class="text-sm font-mono">{Map.get(@poller, "address")}</span>
        </div>

        <div :if={has_value?(@poller, "last_seen")} class="flex flex-col gap-1">
          <span class="text-xs text-base-content/50 uppercase tracking-wider">Last Seen</span>
          <span class="text-sm font-mono">{format_timestamp(@poller, "last_seen")}</span>
        </div>

        <div :if={has_value?(@poller, "created_at")} class="flex flex-col gap-1">
          <span class="text-xs text-base-content/50 uppercase tracking-wider">Created</span>
          <span class="text-sm font-mono">{format_timestamp(@poller, "created_at")}</span>
        </div>
      </div>
    </div>
    """
  end

  attr :poller, :map, required: true

  defp poller_details(assigns) do
    # Fields shown in summary (exclude from details)
    summary_fields = ~w(id poller_id is_active address last_seen created_at updated_at)

    # Get remaining fields, excluding empty maps
    detail_fields =
      assigns.poller
      |> Map.keys()
      |> Enum.reject(&(&1 in summary_fields))
      |> Enum.reject(fn key ->
        value = Map.get(assigns.poller, key)
        is_map(value) and map_size(value) == 0
      end)
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
            <span class="text-xs text-base-content/50 w-36 shrink-0 pt-0.5">
              {humanize_field(field)}
            </span>
            <span class="text-sm flex-1 break-all">
              <.format_value value={Map.get(@poller, field)} />
            </span>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  attr :value, :any, default: nil

  defp format_value(%{value: nil} = assigns) do
    ~H"<span class='text-base-content/40'>—</span>"
  end

  defp format_value(%{value: ""} = assigns) do
    ~H"<span class='text-base-content/40'>—</span>"
  end

  defp format_value(%{value: value} = assigns) when is_boolean(value) do
    ~H"""
    <.ui_badge variant={if @value, do: "success", else: "error"} size="xs">
      {to_string(@value)}
    </.ui_badge>
    """
  end

  defp format_value(%{value: value} = assigns) when is_map(value) and map_size(value) == 0 do
    ~H"<span class='text-base-content/40'>—</span>"
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

  attr :active, :any, default: nil

  defp status_badge(assigns) do
    {label, variant} =
      case assigns.active do
        true -> {"Active", "success"}
        false -> {"Inactive", "error"}
        _ -> {"Unknown", "ghost"}
      end

    assigns = assign(assigns, :label, label) |> assign(:variant, variant)

    ~H"""
    <.ui_badge variant={@variant} size="sm">{@label}</.ui_badge>
    """
  end

  defp format_timestamp(poller, field) do
    ts = Map.get(poller, field)

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
      {:ok, dt, _offset} -> {:ok, dt}
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
