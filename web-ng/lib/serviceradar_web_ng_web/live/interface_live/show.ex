defmodule ServiceRadarWebNGWeb.InterfaceLive.Show do
  @moduledoc """
  LiveView for displaying detailed interface information.
  """
  use ServiceRadarWebNGWeb, :live_view

  alias ServiceRadarWebNGWeb.Helpers.InterfaceTypes

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Interface Details")
     |> assign(:interface, nil)
     |> assign(:device, nil)
     |> assign(:loading, true)
     |> assign(:error, nil)}
  end

  @impl true
  def handle_params(%{"device_uid" => device_uid, "interface_uid" => interface_uid}, _uri, socket) do
    scope = socket.assigns.current_scope
    srql_module = Application.get_env(:serviceradar_web_ng, :srql_module, ServiceRadarWebNG.SRQL)

    # Load interface data
    {interface, error} = load_interface(srql_module, device_uid, interface_uid, scope)

    # Load device data for breadcrumb
    {device, _device_error} = load_device(srql_module, device_uid, scope)

    page_title =
      if interface do
        interface_name(interface)
      else
        "Interface Details"
      end

    {:noreply,
     socket
     |> assign(:device_uid, device_uid)
     |> assign(:interface_uid, interface_uid)
     |> assign(:interface, interface)
     |> assign(:device, device)
     |> assign(:loading, false)
     |> assign(:error, error)
     |> assign(:page_title, page_title)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="container mx-auto px-4 py-6 max-w-6xl">
      <%!-- Breadcrumb --%>
      <nav class="text-sm breadcrumbs mb-4">
        <ul>
          <li><.link navigate={~p"/devices"}>Devices</.link></li>
          <li :if={@device}>
            <.link navigate={~p"/devices/#{@device_uid}"}>
              {device_name(@device)}
            </.link>
          </li>
          <li :if={!@device}>
            <.link navigate={~p"/devices/#{@device_uid}"}>Device</.link>
          </li>
          <li class="text-base-content/70">
            {if @interface, do: interface_name(@interface), else: "Interface"}
          </li>
        </ul>
      </nav>

      <%!-- Loading State --%>
      <div :if={@loading} class="flex items-center justify-center py-12">
        <span class="loading loading-spinner loading-lg text-primary"></span>
      </div>

      <%!-- Error State --%>
      <div :if={@error && !@loading} class="alert alert-error mb-4">
        <.icon name="hero-exclamation-triangle" class="size-5" />
        <span>{@error}</span>
      </div>

      <%!-- Interface Details --%>
      <div :if={@interface && !@loading} class="space-y-6">
        <%!-- Header Card --%>
        <div class="card bg-base-100 border border-base-200 shadow-sm">
          <div class="card-body">
            <div class="flex items-start justify-between">
              <div>
                <h1 class="text-2xl font-bold">{interface_name(@interface)}</h1>
                <p :if={interface_description(@interface)} class="text-base-content/70 mt-1">
                  {interface_description(@interface)}
                </p>
              </div>
              <div class="flex gap-2">
                <.interface_status_badge
                  oper_status={Map.get(@interface, "if_oper_status")}
                  admin_status={Map.get(@interface, "if_admin_status")}
                />
              </div>
            </div>
          </div>
        </div>

        <%!-- Properties Grid --%>
        <div class="grid grid-cols-1 lg:grid-cols-2 gap-6">
          <%!-- Basic Information --%>
          <div class="card bg-base-100 border border-base-200 shadow-sm">
            <div class="card-body">
              <h2 class="card-title text-lg">
                <.icon name="hero-information-circle" class="size-5 text-primary" />
                Basic Information
              </h2>
              <div class="divide-y divide-base-200">
                <.property_row label="Interface ID" value={format_interface_id(@interface)} />
                <.property_row label="Name" value={Map.get(@interface, "if_name")} />
                <.property_row label="Description" value={Map.get(@interface, "if_descr")} />
                <.property_row label="Alias" value={Map.get(@interface, "if_alias")} />
                <.property_row
                  label="Type"
                  value={InterfaceTypes.humanize(Map.get(@interface, "if_type_name"))}
                />
                <.property_row label="Interface UID" value={@interface_uid} monospace />
              </div>
            </div>
          </div>

          <%!-- Network Information --%>
          <div class="card bg-base-100 border border-base-200 shadow-sm">
            <div class="card-body">
              <h2 class="card-title text-lg">
                <.icon name="hero-globe-alt" class="size-5 text-primary" />
                Network Information
              </h2>
              <div class="divide-y divide-base-200">
                <.property_row label="MAC Address" value={Map.get(@interface, "if_phys_address")} monospace />
                <.property_row label="IP Addresses" value={format_ip_list(@interface)} monospace />
                <.property_row label="Speed" value={format_speed(@interface)} />
                <.property_row label="Duplex" value={Map.get(@interface, "duplex")} />
                <.property_row label="MTU" value={Map.get(@interface, "if_mtu")} />
              </div>
            </div>
          </div>

          <%!-- SNMP Information --%>
          <div class="card bg-base-100 border border-base-200 shadow-sm">
            <div class="card-body">
              <h2 class="card-title text-lg">
                <.icon name="hero-server" class="size-5 text-primary" />
                SNMP Information
              </h2>
              <div class="divide-y divide-base-200">
                <.property_row label="ifIndex" value={Map.get(@interface, "if_index")} />
                <.property_row label="ifType (numeric)" value={Map.get(@interface, "if_type")} />
                <.property_row label="ifType (name)" value={Map.get(@interface, "if_type_name")} />
              </div>
            </div>
          </div>

          <%!-- Metrics Collection --%>
          <div class="card bg-base-100 border border-base-200 shadow-sm">
            <div class="card-body">
              <h2 class="card-title text-lg">
                <.icon name="hero-chart-bar" class="size-5 text-primary" />
                Metrics Collection
              </h2>
              <div class="divide-y divide-base-200">
                <% metrics_enabled = Map.get(@interface, "metrics_enabled", false) %>
                <div class="py-3 flex items-center justify-between">
                  <span class="text-sm text-base-content/70">Collection Status</span>
                  <span class={[
                    "badge badge-sm",
                    if(metrics_enabled, do: "badge-success", else: "badge-ghost")
                  ]}>
                    {if metrics_enabled, do: "Enabled", else: "Disabled"}
                  </span>
                </div>
                <div class="py-3">
                  <p class="text-sm text-base-content/50">
                    Metrics collection can be enabled via the interfaces bulk edit feature.
                    When enabled, interface utilization metrics will be collected and displayed.
                  </p>
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>

      <%!-- Not Found State --%>
      <div :if={!@interface && !@loading && !@error} class="text-center py-12">
        <.icon name="hero-question-mark-circle" class="size-16 text-base-content/30 mx-auto" />
        <h3 class="text-lg font-semibold mt-4">Interface Not Found</h3>
        <p class="text-base-content/70 mt-2">
          The requested interface could not be found.
        </p>
        <.link navigate={~p"/devices/#{@device_uid}"} class="btn btn-primary mt-4">
          Back to Device
        </.link>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Components
  # ---------------------------------------------------------------------------

  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :monospace, :boolean, default: false

  defp property_row(assigns) do
    ~H"""
    <div class="py-3 flex justify-between gap-4">
      <span class="text-sm text-base-content/70 shrink-0">{@label}</span>
      <span class={[
        "text-sm text-right",
        @monospace && "font-mono",
        is_nil(@value) || @value == "" && "text-base-content/40"
      ]}>
        {format_value(@value)}
      </span>
    </div>
    """
  end

  attr :oper_status, :any, required: true
  attr :admin_status, :any, required: true

  defp interface_status_badge(assigns) do
    ~H"""
    <div class="flex gap-2">
      <span class={[
        "badge badge-sm gap-1",
        oper_status_class(@oper_status)
      ]}>
        <.icon name={oper_status_icon(@oper_status)} class="size-3" />
        {oper_status_text(@oper_status)}
      </span>
      <span :if={@admin_status} class={[
        "badge badge-sm badge-outline gap-1",
        admin_status_class(@admin_status)
      ]}>
        <.icon name={admin_status_icon(@admin_status)} class="size-3" />
        {admin_status_text(@admin_status)}
      </span>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp load_interface(srql_module, device_uid, interface_uid, scope) do
    query =
      "in:interfaces device_id:\"#{escape_value(device_uid)}\" " <>
        "interface_uid:\"#{escape_value(interface_uid)}\" latest:true limit:1"

    case srql_module.query(query, %{scope: scope}) do
      {:ok, %{"results" => [result | _]}} when is_map(result) ->
        {result, nil}

      {:ok, %{"results" => []}} ->
        {nil, nil}

      {:ok, _} ->
        {nil, nil}

      {:error, reason} ->
        {nil, "Failed to load interface: #{inspect(reason)}"}
    end
  end

  defp load_device(srql_module, device_uid, scope) do
    query = "in:devices uid:\"#{escape_value(device_uid)}\" limit:1"

    case srql_module.query(query, %{scope: scope}) do
      {:ok, %{"results" => [result | _]}} when is_map(result) ->
        {result, nil}

      _ ->
        {nil, nil}
    end
  end

  defp escape_value(value) when is_binary(value) do
    String.replace(value, "\"", "\\\"")
  end

  defp interface_name(iface) do
    Map.get(iface, "if_name") ||
      Map.get(iface, "if_descr") ||
      Map.get(iface, "if_alias") ||
      "Unknown Interface"
  end

  defp interface_description(iface) do
    name = interface_name(iface)
    descr = Map.get(iface, "if_descr")

    if descr && descr != name, do: descr, else: nil
  end

  defp device_name(device) do
    Map.get(device, "name") ||
      Map.get(device, "hostname") ||
      Map.get(device, "ip") ||
      "Device"
  end

  defp format_interface_id(iface) do
    case Map.get(iface, "if_index") do
      nil -> Map.get(iface, "interface_uid")
      idx when is_integer(idx) -> Integer.to_string(idx)
      idx -> idx
    end
  end

  defp format_ip_list(iface) do
    case Map.get(iface, "ip_addresses", []) do
      list when is_list(list) and list != [] -> Enum.join(list, ", ")
      _ -> nil
    end
  end

  defp format_speed(iface) do
    bps = Map.get(iface, "speed_bps") || Map.get(iface, "if_speed")
    format_bps(bps)
  end

  defp format_bps(nil), do: nil

  defp format_bps(bps) when is_number(bps) do
    cond do
      bps >= 1_000_000_000_000 -> "#{Float.round(bps / 1_000_000_000_000 * 1.0, 1)} Tbps"
      bps >= 1_000_000_000 -> "#{Float.round(bps / 1_000_000_000 * 1.0, 1)} Gbps"
      bps >= 1_000_000 -> "#{Float.round(bps / 1_000_000 * 1.0, 1)} Mbps"
      bps >= 1_000 -> "#{Float.round(bps / 1_000 * 1.0, 1)} Kbps"
      true -> "#{bps} bps"
    end
  end

  defp format_value(nil), do: "—"
  defp format_value(""), do: "—"
  defp format_value(value) when is_list(value), do: Enum.join(value, ", ")
  defp format_value(value), do: to_string(value)

  # Status styling functions
  defp oper_status_class(1), do: "badge-success"
  defp oper_status_class(2), do: "badge-error"
  defp oper_status_class(3), do: "badge-warning"
  defp oper_status_class(_), do: "badge-ghost"

  defp oper_status_icon(1), do: "hero-arrow-up-circle"
  defp oper_status_icon(2), do: "hero-arrow-down-circle"
  defp oper_status_icon(3), do: "hero-beaker"
  defp oper_status_icon(_), do: "hero-question-mark-circle"

  defp oper_status_text(1), do: "Up"
  defp oper_status_text(2), do: "Down"
  defp oper_status_text(3), do: "Testing"
  defp oper_status_text(_), do: "Unknown"

  defp admin_status_class(1), do: "border-success text-success"
  defp admin_status_class(2), do: "border-warning text-warning"
  defp admin_status_class(3), do: "border-info text-info"
  defp admin_status_class(_), do: "border-base-content/30 text-base-content/50"

  defp admin_status_icon(1), do: "hero-check-circle"
  defp admin_status_icon(2), do: "hero-pause-circle"
  defp admin_status_icon(3), do: "hero-beaker"
  defp admin_status_icon(_), do: "hero-question-mark-circle"

  defp admin_status_text(1), do: "Enabled"
  defp admin_status_text(2), do: "Disabled"
  defp admin_status_text(3), do: "Testing"
  defp admin_status_text(_), do: "Unknown"
end
