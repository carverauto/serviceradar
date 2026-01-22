defmodule ServiceRadarWebNGWeb.InterfaceLive.Show do
  @moduledoc """
  LiveView for displaying detailed interface information.
  """
  use ServiceRadarWebNGWeb, :live_view

  alias ServiceRadarWebNGWeb.Helpers.InterfaceTypes
  alias ServiceRadar.Inventory.InterfaceSettings

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Interface Details")
     |> assign(:interface, nil)
     |> assign(:device, nil)
     |> assign(:settings, nil)
     |> assign(:threshold_form, to_form(%{}, as: :threshold))
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

    # Load interface settings (favorites, metrics enabled)
    settings = load_interface_settings(scope, device_uid, interface_uid)

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
     |> assign(:settings, settings)
     |> assign(:loading, false)
     |> assign(:error, error)
     |> assign(:page_title, page_title)}
  end

  @impl true
  def handle_event("toggle_metric", %{"metric" => metric_name}, socket) do
    device_uid = socket.assigns.device_uid
    interface_uid = socket.assigns.interface_uid
    scope = socket.assigns.current_scope
    current_settings = socket.assigns.settings
    selected_metrics = settings_list_value(current_settings, :metrics_selected)

    if metric_name == "Unknown" do
      {:noreply, socket}
    else
      updated_metrics =
        if metric_name in selected_metrics do
          List.delete(selected_metrics, metric_name)
        else
          Enum.uniq([metric_name | selected_metrics])
        end

      updated_metrics = Enum.sort(updated_metrics)

      attrs =
        if updated_metrics == [] do
          %{metrics_selected: updated_metrics, metrics_enabled: false}
        else
          %{metrics_selected: updated_metrics, metrics_enabled: true}
        end

      case upsert_interface_setting(scope, device_uid, interface_uid, attrs) do
        {:ok, updated_settings} ->
          {:noreply, assign(socket, :settings, updated_settings)}

        {:error, _reason} ->
          {:noreply, put_flash(socket, :error, "Failed to update metric selection")}
      end
    end
  end

  def handle_event("toggle_favorite", _params, socket) do
    device_uid = socket.assigns.device_uid
    interface_uid = socket.assigns.interface_uid
    scope = socket.assigns.current_scope
    current_settings = socket.assigns.settings
    current_favorited = settings_value(current_settings, :favorited)

    case upsert_interface_setting(scope, device_uid, interface_uid, %{
           favorited: not current_favorited
         }) do
      {:ok, updated_settings} ->
        {:noreply,
         socket
         |> assign(:settings, updated_settings)
         |> put_flash(
           :info,
           if(current_favorited, do: "Removed from favorites", else: "Added to favorites")
         )}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Failed to update favorite status")}
    end
  end

  def handle_event("toggle_threshold", _params, socket) do
    device_uid = socket.assigns.device_uid
    interface_uid = socket.assigns.interface_uid
    scope = socket.assigns.current_scope
    current_settings = socket.assigns.settings
    current_enabled = settings_value(current_settings, :threshold_enabled)

    case upsert_interface_setting(scope, device_uid, interface_uid, %{
           threshold_enabled: not current_enabled
         }) do
      {:ok, updated_settings} ->
        {:noreply,
         socket
         |> assign(:settings, updated_settings)
         |> put_flash(
           :info,
           if(current_enabled,
             do: "Threshold alerting disabled",
             else: "Threshold alerting enabled"
           )
         )}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Failed to update threshold setting")}
    end
  end

  def handle_event("update_threshold", %{"threshold" => params}, socket) do
    # Just update the form state, don't persist yet
    {:noreply, assign(socket, :threshold_form, to_form(params, as: :threshold))}
  end

  def handle_event("save_threshold", %{"threshold" => params}, socket) do
    device_uid = socket.assigns.device_uid
    interface_uid = socket.assigns.interface_uid
    scope = socket.assigns.current_scope

    # Parse and validate the threshold values
    attrs = %{
      threshold_metric: parse_threshold_metric(params["metric"]),
      threshold_comparison: parse_threshold_comparison(params["comparison"]),
      threshold_value: parse_threshold_value(params["value"]),
      threshold_duration_seconds: parse_threshold_duration(params["duration"]),
      threshold_severity: parse_threshold_severity(params["severity"])
    }

    case upsert_interface_setting(scope, device_uid, interface_uid, attrs) do
      {:ok, updated_settings} ->
        {:noreply,
         socket
         |> assign(:settings, updated_settings)
         |> put_flash(:info, "Threshold configuration saved")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Failed to save threshold configuration")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
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
                <div class="flex gap-2 items-center">
                  <% is_favorited = settings_value(@settings, :favorited) %>
                  <button
                    type="button"
                    class={[
                      "btn btn-ghost btn-sm",
                      if(is_favorited, do: "text-warning", else: "text-base-content/30")
                    ]}
                    phx-click="toggle_favorite"
                    title={if is_favorited, do: "Remove from favorites", else: "Add to favorites"}
                  >
                    <.icon
                      name={if is_favorited, do: "hero-star-solid", else: "hero-star"}
                      class="size-5"
                    />
                  </button>
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
                  <.icon name="hero-globe-alt" class="size-5 text-primary" /> Network Information
                </h2>
                <div class="divide-y divide-base-200">
                  <.property_row
                    label="MAC Address"
                    value={Map.get(@interface, "if_phys_address")}
                    monospace
                  />
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
                  <.icon name="hero-server" class="size-5 text-primary" /> SNMP Information
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
                  <.icon name="hero-chart-bar" class="size-5 text-primary" /> Metrics Collection
                </h2>
                <div class="divide-y divide-base-200">
                  <% selected_metrics = settings_list_value(@settings, :metrics_selected) %>
                  <% metrics_enabled = selected_metrics != [] %>
                  <% available_metrics = Map.get(@interface, "available_metrics") %>
                  <div class="py-3">
                    <div class="flex items-start justify-between gap-4">
                      <div>
                        <span class="text-sm font-medium">Metrics Collection</span>
                        <p class="text-xs text-base-content/50 mt-0.5">
                          Click a metric below to enable or disable its collection.
                        </p>
                      </div>
                      <span class={[
                        "badge badge-sm",
                        metrics_enabled && "badge-success",
                        !metrics_enabled && "badge-ghost"
                      ]}>
                        {if metrics_enabled, do: "Enabled", else: "Disabled"}
                      </span>
                    </div>
                    <p :if={selected_metrics == []} class="text-xs text-warning mt-2">
                      Select at least one metric to enable collection.
                    </p>
                  </div>
                  <%!-- Available Metrics Section --%>
                  <div :if={available_metrics && length(available_metrics) > 0} class="py-3 space-y-3">
                    <% normalized_metrics = Enum.filter(available_metrics, &is_map/1) %>
                    <h3 class="text-sm font-medium">Available Metrics</h3>
                    <div :if={normalized_metrics != []} class="grid grid-cols-1 sm:grid-cols-2 gap-2">
                      <.available_metric_card
                        :for={metric <- normalized_metrics}
                        metric={metric}
                        enabled={metric_selected?(metric, selected_metrics)}
                      />
                    </div>
                  </div>
                  <div :if={!available_metrics || available_metrics == []} class="py-3">
                    <div class="flex items-start gap-2 text-base-content/50">
                      <.icon name="hero-question-mark-circle" class="size-4 mt-0.5" />
                      <div>
                        <span class="text-sm">Available metrics unknown</span>
                        <p class="text-xs mt-0.5">
                          Metric discovery not yet performed. Run a discovery scan to detect available metrics.
                        </p>
                      </div>
                    </div>
                  </div>
                </div>
              </div>
            </div>
          </div>

          <%!-- Threshold Configuration (full width) --%>
          <div class="card bg-base-100 border border-base-200 shadow-sm">
            <div class="card-body">
              <h2 class="card-title text-lg">
                <.icon name="hero-bell-alert" class="size-5 text-primary" /> Threshold Alerting
              </h2>

              <% threshold_enabled = settings_value(@settings, :threshold_enabled) %>
              <% threshold_metric = settings_value(@settings, :threshold_metric) %>
              <% threshold_comparison = settings_value(@settings, :threshold_comparison) %>
              <% threshold_value = settings_value(@settings, :threshold_value) %>
              <% threshold_duration = settings_value(@settings, :threshold_duration_seconds) || 0 %>
              <% threshold_severity = settings_value(@settings, :threshold_severity) || :warning %>

              <div class="divide-y divide-base-200">
                <div class="py-3 flex items-center justify-between">
                  <div>
                    <span class="text-sm font-medium">Enable Threshold Alerts</span>
                    <p class="text-xs text-base-content/50 mt-0.5">
                      Generate alerts when interface metrics exceed configured thresholds
                    </p>
                  </div>
                  <input
                    type="checkbox"
                    class="toggle toggle-warning"
                    checked={threshold_enabled}
                    phx-click="toggle_threshold"
                  />
                </div>

                <div :if={threshold_enabled} class="py-4 space-y-4">
                  <.form
                    for={@threshold_form}
                    phx-change="update_threshold"
                    phx-submit="save_threshold"
                    class="space-y-4"
                  >
                    <div class="grid grid-cols-1 md:grid-cols-3 gap-4">
                      <div class="form-control">
                        <label class="label">
                          <span class="label-text text-xs">Metric</span>
                        </label>
                        <select
                          name="threshold[metric]"
                          class="select select-bordered select-sm w-full"
                        >
                          <option value="" disabled selected={!threshold_metric}>
                            Select metric
                          </option>
                          <option value="utilization" selected={threshold_metric == :utilization}>
                            Utilization %
                          </option>
                          <option value="bandwidth_in" selected={threshold_metric == :bandwidth_in}>
                            Bandwidth In
                          </option>
                          <option value="bandwidth_out" selected={threshold_metric == :bandwidth_out}>
                            Bandwidth Out
                          </option>
                          <option value="errors" selected={threshold_metric == :errors}>
                            Errors
                          </option>
                        </select>
                      </div>

                      <div class="form-control">
                        <label class="label">
                          <span class="label-text text-xs">Condition</span>
                        </label>
                        <select
                          name="threshold[comparison]"
                          class="select select-bordered select-sm w-full"
                        >
                          <option value="" disabled selected={!threshold_comparison}>
                            Select condition
                          </option>
                          <option value="gt" selected={threshold_comparison == :gt}>
                            Greater than (&gt;)
                          </option>
                          <option value="gte" selected={threshold_comparison == :gte}>
                            Greater or equal (&ge;)
                          </option>
                          <option value="lt" selected={threshold_comparison == :lt}>
                            Less than (&lt;)
                          </option>
                          <option value="lte" selected={threshold_comparison == :lte}>
                            Less or equal (&le;)
                          </option>
                          <option value="eq" selected={threshold_comparison == :eq}>
                            Equal to (=)
                          </option>
                        </select>
                      </div>

                      <div class="form-control">
                        <label class="label">
                          <span class="label-text text-xs">Value</span>
                        </label>
                        <input
                          type="number"
                          name="threshold[value]"
                          value={threshold_value}
                          placeholder="e.g., 80"
                          class="input input-bordered input-sm w-full"
                        />
                      </div>
                    </div>

                    <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
                      <div class="form-control">
                        <label class="label">
                          <span class="label-text text-xs">Duration (seconds)</span>
                        </label>
                        <input
                          type="number"
                          name="threshold[duration]"
                          value={threshold_duration}
                          placeholder="0"
                          min="0"
                          class="input input-bordered input-sm w-full"
                        />
                        <label class="label">
                          <span class="label-text-alt text-xs text-base-content/50">
                            How long threshold must be exceeded before alerting (0 = immediate)
                          </span>
                        </label>
                      </div>

                      <div class="form-control">
                        <label class="label">
                          <span class="label-text text-xs">Alert Severity</span>
                        </label>
                        <select
                          name="threshold[severity]"
                          class="select select-bordered select-sm w-full"
                        >
                          <option value="info" selected={threshold_severity == :info}>Info</option>
                          <option value="warning" selected={threshold_severity == :warning}>
                            Warning
                          </option>
                          <option value="critical" selected={threshold_severity == :critical}>
                            Critical
                          </option>
                          <option value="emergency" selected={threshold_severity == :emergency}>
                            Emergency
                          </option>
                        </select>
                      </div>
                    </div>

                    <div class="flex justify-end">
                      <button type="submit" class="btn btn-primary btn-sm">
                        <.icon name="hero-check" class="size-4" /> Save Threshold
                      </button>
                    </div>
                  </.form>

                  <div
                    :if={threshold_metric && threshold_comparison && threshold_value}
                    class="alert alert-info alert-sm"
                  >
                    <.icon name="hero-information-circle" class="size-4" />
                    <span class="text-sm">
                      Alert (<strong>{threshold_severity}</strong>) when
                      <strong>{threshold_metric_label(threshold_metric)}</strong>
                      is <strong>{threshold_comparison_label(threshold_comparison)}</strong>
                      <strong>
                        {threshold_value}{if threshold_metric == :utilization, do: "%", else: ""}
                      </strong>
                      {if threshold_duration > 0, do: " for #{threshold_duration} seconds", else: ""}
                    </span>
                  </div>
                </div>

                <div :if={!threshold_enabled} class="py-3">
                  <p class="text-sm text-base-content/50">
                    Enable threshold alerting to receive notifications when this interface's
                    metrics exceed configured limits.
                  </p>
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
    </Layouts.app>
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
        is_nil(@value) || (@value == "" && "text-base-content/40")
      ]}>
        {format_value(@value)}
      </span>
    </div>
    """
  end

  attr :metric, :map, required: true
  attr :enabled, :boolean, default: false

  defp available_metric_card(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="toggle_metric"
      phx-value-metric={metric_raw_name(@metric)}
      class={[
        "flex items-center justify-between p-2 rounded-lg border transition",
        @enabled && "border-success bg-success/10",
        !@enabled && "bg-base-200/50 border-base-300 hover:border-primary/50"
      ]}
      title={if @enabled, do: "Disable metric collection", else: "Enable metric collection"}
    >
      <div class="flex items-center gap-2">
        <.icon name={metric_category_icon(@metric)} class="size-4 text-primary" />
        <div>
          <span class="text-sm font-medium">{metric_display_name(@metric)}</span>
          <span
            :if={metric_supports_64bit?(@metric)}
            class="ml-1 badge badge-xs badge-success"
            title="64-bit counter available"
          >
            64-bit
          </span>
        </div>
      </div>
      <span class="text-xs text-base-content/50 badge badge-ghost badge-sm">
        {metric_category_label(@metric)}
      </span>
    </button>
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
      <span
        :if={@admin_status}
        class={[
          "badge badge-sm badge-outline gap-1",
          admin_status_class(@admin_status)
        ]}
      >
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

  # Interface settings helpers
  defp load_interface_settings(_scope, nil, _interface_uid), do: nil
  defp load_interface_settings(_scope, _device_uid, nil), do: nil

  defp load_interface_settings(scope, device_uid, interface_uid) do
    case InterfaceSettings.get_by_interface(device_uid, interface_uid, scope: scope) do
      {:ok, settings} -> settings
      {:error, _} -> nil
    end
  end

  defp upsert_interface_setting(_scope, nil, _interface_uid, _attrs), do: {:error, :no_device}
  defp upsert_interface_setting(_scope, _device_uid, nil, _attrs), do: {:error, :no_interface}

  defp upsert_interface_setting(scope, device_uid, interface_uid, attrs) do
    InterfaceSettings.upsert(device_uid, interface_uid, attrs, scope: scope)
  end

  defp settings_value(nil, _key), do: false
  defp settings_value(settings, key) when is_struct(settings), do: Map.get(settings, key, false)
  defp settings_value(settings, key) when is_map(settings), do: Map.get(settings, key, false)
  defp settings_value(_, _), do: false

  defp settings_list_value(nil, _key), do: []

  defp settings_list_value(settings, key) when is_struct(settings),
    do: normalize_list(Map.get(settings, key))

  defp settings_list_value(settings, key) when is_map(settings),
    do: normalize_list(Map.get(settings, key))

  defp settings_list_value(_, _), do: []

  defp normalize_list(value) when is_list(value), do: value
  defp normalize_list(_), do: []

  # Threshold parsing helpers
  defp parse_threshold_metric(""), do: nil
  defp parse_threshold_metric(nil), do: nil
  defp parse_threshold_metric("utilization"), do: :utilization
  defp parse_threshold_metric("bandwidth_in"), do: :bandwidth_in
  defp parse_threshold_metric("bandwidth_out"), do: :bandwidth_out
  defp parse_threshold_metric("errors"), do: :errors
  defp parse_threshold_metric(_), do: nil

  defp parse_threshold_comparison(""), do: nil
  defp parse_threshold_comparison(nil), do: nil
  defp parse_threshold_comparison("gt"), do: :gt
  defp parse_threshold_comparison("gte"), do: :gte
  defp parse_threshold_comparison("lt"), do: :lt
  defp parse_threshold_comparison("lte"), do: :lte
  defp parse_threshold_comparison("eq"), do: :eq
  defp parse_threshold_comparison(_), do: nil

  defp parse_threshold_value(""), do: nil
  defp parse_threshold_value(nil), do: nil

  defp parse_threshold_value(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} -> int
      :error -> nil
    end
  end

  defp parse_threshold_value(value) when is_integer(value), do: value
  defp parse_threshold_value(_), do: nil

  defp parse_threshold_duration(""), do: 0
  defp parse_threshold_duration(nil), do: 0

  defp parse_threshold_duration(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} -> max(0, int)
      :error -> 0
    end
  end

  defp parse_threshold_duration(value) when is_integer(value), do: max(0, value)
  defp parse_threshold_duration(_), do: 0

  defp parse_threshold_severity("info"), do: :info
  defp parse_threshold_severity("warning"), do: :warning
  defp parse_threshold_severity("critical"), do: :critical
  defp parse_threshold_severity("emergency"), do: :emergency
  defp parse_threshold_severity(_), do: :warning

  # Threshold label helpers
  defp threshold_metric_label(:utilization), do: "Utilization"
  defp threshold_metric_label(:bandwidth_in), do: "Bandwidth In"
  defp threshold_metric_label(:bandwidth_out), do: "Bandwidth Out"
  defp threshold_metric_label(:errors), do: "Errors"
  defp threshold_metric_label(_), do: "Unknown"

  defp threshold_comparison_label(:gt), do: "greater than"
  defp threshold_comparison_label(:gte), do: "greater than or equal to"
  defp threshold_comparison_label(:lt), do: "less than"
  defp threshold_comparison_label(:lte), do: "less than or equal to"
  defp threshold_comparison_label(:eq), do: "equal to"
  defp threshold_comparison_label(_), do: ""

  # Available metrics helpers
  defp metric_display_name(metric) when is_map(metric) do
    name = Map.get(metric, "name") || Map.get(metric, :name) || "Unknown"
    # Convert OID names to human-readable format
    case name do
      "ifInOctets" -> "Inbound Traffic"
      "ifOutOctets" -> "Outbound Traffic"
      "ifInErrors" -> "Inbound Errors"
      "ifOutErrors" -> "Outbound Errors"
      "ifInDiscards" -> "Inbound Discards"
      "ifOutDiscards" -> "Outbound Discards"
      "ifInUcastPkts" -> "Inbound Packets"
      "ifOutUcastPkts" -> "Outbound Packets"
      _ -> name
    end
  end

  defp metric_display_name(_), do: "Unknown"

  defp metric_raw_name(metric) when is_map(metric) do
    Map.get(metric, "name") || Map.get(metric, :name) || "Unknown"
  end

  defp metric_raw_name(_), do: "Unknown"

  defp metric_supports_64bit?(metric) when is_map(metric) do
    Map.get(metric, "supports_64bit") || Map.get(metric, :supports_64bit) || false
  end

  defp metric_supports_64bit?(_), do: false

  defp metric_category_icon(metric) when is_map(metric) do
    category = Map.get(metric, "category") || Map.get(metric, :category) || "unknown"

    case category do
      "traffic" -> "hero-arrow-trending-up"
      "errors" -> "hero-exclamation-triangle"
      "packets" -> "hero-cube"
      "environmental" -> "hero-cpu-chip"
      "status" -> "hero-signal"
      _ -> "hero-chart-bar"
    end
  end

  defp metric_category_icon(_), do: "hero-chart-bar"

  defp metric_category_label(metric) when is_map(metric) do
    category = Map.get(metric, "category") || Map.get(metric, :category) || "unknown"

    case category do
      "traffic" -> "Traffic"
      "errors" -> "Errors"
      "packets" -> "Packets"
      "environmental" -> "Environmental"
      "status" -> "Status"
      _ -> "Metric"
    end
  end

  defp metric_category_label(_), do: "Metric"

  defp metric_selected?(metric, selected_metrics) when is_map(metric) do
    metric_name = metric_raw_name(metric)
    metric_name != "Unknown" and metric_name in selected_metrics
  end

  defp metric_selected?(_metric, _selected_metrics), do: false
end
