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
     |> assign(:metric_form, to_form(%{}, as: :metric))
     |> assign(:metric_modal_open, false)
     |> assign(:metric_modal_metric, nil)
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

  def handle_event("open_metric_modal", %{"metric" => metric_name}, socket) do
    if metric_name == "Unknown" do
      {:noreply, socket}
    else
      config = metric_threshold_config(socket.assigns.settings, metric_name)
      form = to_form(metric_form_values(metric_name, config), as: :metric)

      {:noreply,
       socket
       |> assign(:metric_form, form)
       |> assign(:metric_modal_metric, metric_name)
       |> assign(:metric_modal_open, true)}
    end
  end

  def handle_event("close_metric_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:metric_modal_open, false)
     |> assign(:metric_modal_metric, nil)}
  end

  def handle_event("save_metric_settings", %{"metric" => params}, socket) do
    device_uid = socket.assigns.device_uid
    interface_uid = socket.assigns.interface_uid
    scope = socket.assigns.current_scope
    metric_name = params["name"] || params["metric"]

    if is_nil(metric_name) or metric_name == "" do
      {:noreply, put_flash(socket, :error, "Metric name is required")}
    else
      current_settings = socket.assigns.settings
      thresholds = settings_map_value(current_settings, :metric_thresholds)
      selected_metrics = settings_list_value(current_settings, :metrics_selected)
      updated_config = build_metric_config(params)

      updated_thresholds = Map.put(thresholds, metric_name, updated_config)

      selected_metrics =
        if config_enabled?(updated_config) and metric_name not in selected_metrics do
          Enum.sort([metric_name | selected_metrics])
        else
          selected_metrics
        end

      attrs = %{
        metric_thresholds: updated_thresholds,
        metrics_selected: selected_metrics,
        metrics_enabled: selected_metrics != []
      }

      case upsert_interface_setting(scope, device_uid, interface_uid, attrs) do
        {:ok, updated_settings} ->
          {:noreply,
           socket
           |> assign(:settings, updated_settings)
           |> assign(:metric_modal_open, false)
           |> assign(:metric_modal_metric, nil)
           |> put_flash(:info, "Metric settings saved")}

        {:error, _reason} ->
          {:noreply, put_flash(socket, :error, "Failed to save metric settings")}
      end
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
                          Enable collection per metric and configure event/alert settings.
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
                        event_enabled={
                          metric_event_enabled?(metric_threshold_config(@settings, metric))
                        }
                        alert_enabled={
                          metric_alert_enabled?(metric_threshold_config(@settings, metric))
                        }
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

          <.metric_settings_modal
            :if={@metric_modal_open}
            form={@metric_form}
            metric_name={@metric_modal_metric}
          />
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
  attr :event_enabled, :boolean, default: false
  attr :alert_enabled, :boolean, default: false

  defp available_metric_card(assigns) do
    ~H"""
    <div class={[
      "p-3 rounded-lg border transition",
      @enabled && "border-success bg-success/5",
      !@enabled && "bg-base-200/50 border-base-300 hover:border-primary/50"
    ]}>
      <div class="flex items-start justify-between gap-3">
        <div
          class="flex items-center gap-2 flex-1 cursor-pointer"
          role="button"
          tabindex="0"
          phx-click="open_metric_modal"
          phx-value-metric={metric_raw_name(@metric)}
        >
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
        <button
          type="button"
          class={[
            "btn btn-xs",
            @enabled && "btn-success",
            !@enabled && "btn-ghost"
          ]}
          phx-click="toggle_metric"
          phx-value-metric={metric_raw_name(@metric)}
        >
          {if @enabled, do: "Collecting", else: "Enable"}
        </button>
      </div>
      <div
        class="mt-2 flex items-center justify-between cursor-pointer"
        role="button"
        tabindex="0"
        phx-click="open_metric_modal"
        phx-value-metric={metric_raw_name(@metric)}
      >
        <div class="flex items-center gap-2 text-xs">
          <span class={[
            "badge badge-xs gap-1",
            @event_enabled && "badge-info",
            !@event_enabled && "badge-ghost"
          ]}>
            <.icon name="hero-bolt" class="size-3" /> Event
          </span>
          <span class={[
            "badge badge-xs gap-1",
            @alert_enabled && "badge-success",
            !@alert_enabled && "badge-ghost"
          ]}>
            <.icon name="hero-bell-alert" class="size-3" /> Alert
          </span>
        </div>
        <span class="text-xs text-base-content/50">
          {metric_category_label(@metric)}
        </span>
      </div>
    </div>
    """
  end

  attr :form, :any, required: true
  attr :metric_name, :string, required: true

  defp metric_settings_modal(assigns) do
    ~H"""
    <dialog class="modal modal-open">
      <div class="modal-box max-w-3xl">
        <form method="dialog">
          <button
            class="btn btn-sm btn-circle btn-ghost absolute right-2 top-2"
            phx-click="close_metric_modal"
          >
            x
          </button>
        </form>

        <h3 class="text-lg font-bold">Configure {@metric_name} metric</h3>
        <p class="text-sm text-base-content/60 mt-1">
          Tune event creation and alert promotion for this metric.
        </p>

        <.form
          for={@form}
          id="metric-settings-form"
          phx-submit="save_metric_settings"
          class="space-y-6 mt-4"
        >
          <input type="hidden" name="metric[name]" value={@metric_name} />

          <div class="space-y-3">
            <div class="flex items-center justify-between">
              <div>
                <span class="text-sm font-semibold">Event Threshold</span>
                <p class="text-xs text-base-content/50">
                  Create an event when this metric crosses the threshold.
                </p>
              </div>
              <input
                type="checkbox"
                name="metric[enabled]"
                value="true"
                class="toggle toggle-info"
                checked={@form[:enabled].value}
              />
            </div>

            <div class="grid grid-cols-1 md:grid-cols-3 gap-4">
              <div class="form-control">
                <label class="label">
                  <span class="label-text text-xs">Comparison</span>
                </label>
                <select name="metric[comparison]" class="select select-bordered select-sm w-full">
                  <option value="">Select condition</option>
                  <option value="gt" selected={@form[:comparison].value == "gt"}>
                    Greater than (&gt;)
                  </option>
                  <option value="gte" selected={@form[:comparison].value == "gte"}>
                    Greater or equal (&ge;)
                  </option>
                  <option value="lt" selected={@form[:comparison].value == "lt"}>
                    Less than (&lt;)
                  </option>
                  <option value="lte" selected={@form[:comparison].value == "lte"}>
                    Less or equal (&le;)
                  </option>
                  <option value="eq" selected={@form[:comparison].value == "eq"}>
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
                  name="metric[value]"
                  value={@form[:value].value}
                  placeholder="e.g., 80"
                  class="input input-bordered input-sm w-full"
                />
              </div>
              <div class="form-control">
                <label class="label">
                  <span class="label-text text-xs">Duration (seconds)</span>
                </label>
                <input
                  type="number"
                  name="metric[duration_seconds]"
                  value={@form[:duration_seconds].value}
                  placeholder="0"
                  min="0"
                  class="input input-bordered input-sm w-full"
                />
              </div>
            </div>

            <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
              <div class="form-control">
                <label class="label">
                  <span class="label-text text-xs">Event Severity</span>
                </label>
                <select name="metric[event_severity]" class="select select-bordered select-sm w-full">
                  <option value="info" selected={@form[:event_severity].value == "info"}>
                    Info
                  </option>
                  <option value="warning" selected={@form[:event_severity].value == "warning"}>
                    Warning
                  </option>
                  <option value="critical" selected={@form[:event_severity].value == "critical"}>
                    Critical
                  </option>
                  <option value="emergency" selected={@form[:event_severity].value == "emergency"}>
                    Emergency
                  </option>
                </select>
              </div>
              <div class="form-control">
                <label class="label">
                  <span class="label-text text-xs">Event Message</span>
                </label>
                <input
                  type="text"
                  name="metric[event_message]"
                  value={@form[:event_message].value}
                  placeholder="Optional message override"
                  class="input input-bordered input-sm w-full"
                />
              </div>
            </div>
          </div>

          <div class="divider text-xs text-base-content/50">Alert Promotion</div>

          <div class="space-y-3">
            <div class="flex items-center justify-between">
              <div>
                <span class="text-sm font-semibold">Enable Alerts</span>
                <p class="text-xs text-base-content/50">
                  Promote metric events into alerts when thresholds are met.
                </p>
              </div>
              <input
                type="checkbox"
                name="metric[alert_enabled]"
                value="true"
                class="toggle toggle-success"
                checked={@form[:alert_enabled].value}
              />
            </div>

            <div class="grid grid-cols-1 md:grid-cols-3 gap-4">
              <div class="form-control">
                <label class="label">
                  <span class="label-text text-xs">Event Count</span>
                </label>
                <input
                  type="number"
                  name="metric[alert_threshold]"
                  value={@form[:alert_threshold].value}
                  min="1"
                  class="input input-bordered input-sm w-full"
                />
              </div>
              <div class="form-control">
                <label class="label">
                  <span class="label-text text-xs">Window (seconds)</span>
                </label>
                <input
                  type="number"
                  name="metric[alert_window_seconds]"
                  value={@form[:alert_window_seconds].value}
                  min="60"
                  class="input input-bordered input-sm w-full"
                />
              </div>
              <div class="form-control">
                <label class="label">
                  <span class="label-text text-xs">Cooldown (seconds)</span>
                </label>
                <input
                  type="number"
                  name="metric[alert_cooldown_seconds]"
                  value={@form[:alert_cooldown_seconds].value}
                  min="60"
                  class="input input-bordered input-sm w-full"
                />
              </div>
            </div>

            <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
              <div class="form-control">
                <label class="label">
                  <span class="label-text text-xs">Renotify (seconds)</span>
                </label>
                <input
                  type="number"
                  name="metric[alert_renotify_seconds]"
                  value={@form[:alert_renotify_seconds].value}
                  min="300"
                  class="input input-bordered input-sm w-full"
                />
              </div>
              <div class="form-control">
                <label class="label">
                  <span class="label-text text-xs">Alert Severity</span>
                </label>
                <select name="metric[alert_severity]" class="select select-bordered select-sm w-full">
                  <option value="info" selected={@form[:alert_severity].value == "info"}>
                    Info
                  </option>
                  <option value="warning" selected={@form[:alert_severity].value == "warning"}>
                    Warning
                  </option>
                  <option value="critical" selected={@form[:alert_severity].value == "critical"}>
                    Critical
                  </option>
                  <option value="emergency" selected={@form[:alert_severity].value == "emergency"}>
                    Emergency
                  </option>
                </select>
              </div>
            </div>

            <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
              <div class="form-control">
                <label class="label">
                  <span class="label-text text-xs">Alert Title</span>
                </label>
                <input
                  type="text"
                  name="metric[alert_title]"
                  value={@form[:alert_title].value}
                  placeholder="Optional title override"
                  class="input input-bordered input-sm w-full"
                />
              </div>
              <div class="form-control">
                <label class="label">
                  <span class="label-text text-xs">Alert Description</span>
                </label>
                <input
                  type="text"
                  name="metric[alert_description]"
                  value={@form[:alert_description].value}
                  placeholder="Optional description override"
                  class="input input-bordered input-sm w-full"
                />
              </div>
            </div>
          </div>

          <div class="modal-action">
            <button type="button" class="btn btn-ghost" phx-click="close_metric_modal">
              Cancel
            </button>
            <button type="submit" class="btn btn-primary">
              <.icon name="hero-check" class="size-4" /> Save Settings
            </button>
          </div>
        </.form>
      </div>
      <form method="dialog" class="modal-backdrop">
        <button phx-click="close_metric_modal">close</button>
      </form>
    </dialog>
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

  defp settings_map_value(nil, _key), do: %{}

  defp settings_map_value(settings, key) when is_struct(settings),
    do: normalize_map(Map.get(settings, key))

  defp settings_map_value(settings, key) when is_map(settings),
    do: normalize_map(Map.get(settings, key))

  defp settings_map_value(_, _), do: %{}

  defp normalize_map(value) when is_map(value), do: value
  defp normalize_map(_), do: %{}

  # Metric settings helpers
  defp metric_threshold_config(settings, metric) do
    metric_name =
      case metric do
        %{} -> metric_raw_name(metric)
        name -> name
      end

    thresholds = settings_map_value(settings, :metric_thresholds)
    Map.get(thresholds, metric_name) || Map.get(thresholds, to_string(metric_name)) || %{}
  end

  defp metric_event_enabled?(config) do
    config_enabled?(config)
  end

  defp metric_alert_enabled?(config) do
    alert = config_value(config, :alert)
    config_enabled?(config) and config_bool(alert, :enabled, false)
  end

  defp metric_form_values(metric_name, config) do
    alert = config_value(config, :alert, %{})
    event = config_value(config, :event, %{})

    %{
      "name" => metric_name,
      "enabled" => config_bool(config, :enabled, true),
      "comparison" => config_value(config, :comparison, ""),
      "value" => config_value(config, :value, ""),
      "duration_seconds" => config_value(config, :duration_seconds, 0),
      "event_severity" => config_value(event, :severity, "warning"),
      "event_message" => config_value(event, :message, ""),
      "alert_enabled" => config_bool(alert, :enabled, false),
      "alert_threshold" => config_value(alert, :threshold, 1),
      "alert_window_seconds" => config_value(alert, :window_seconds, 300),
      "alert_cooldown_seconds" => config_value(alert, :cooldown_seconds, 300),
      "alert_renotify_seconds" => config_value(alert, :renotify_seconds, 21_600),
      "alert_severity" => config_value(alert, :severity, "warning"),
      "alert_title" => config_value(alert, :title, ""),
      "alert_description" => config_value(alert, :description, "")
    }
  end

  defp build_metric_config(params) do
    event = %{}
    event = maybe_put(event, "severity", blank_to_nil(params["event_severity"]))
    event = maybe_put(event, "message", blank_to_nil(params["event_message"]))

    alert = %{
      "enabled" => param_bool(params["alert_enabled"], false),
      "threshold" => parse_int(params["alert_threshold"]) || 1,
      "window_seconds" => parse_int(params["alert_window_seconds"]) || 300,
      "cooldown_seconds" => parse_int(params["alert_cooldown_seconds"]) || 300,
      "renotify_seconds" => parse_int(params["alert_renotify_seconds"]) || 21_600,
      "severity" => blank_to_nil(params["alert_severity"]),
      "title" => blank_to_nil(params["alert_title"]),
      "description" => blank_to_nil(params["alert_description"])
    }

    %{
      "enabled" => param_bool(params["enabled"], true),
      "comparison" => blank_to_nil(params["comparison"]),
      "value" => parse_number(params["value"]),
      "duration_seconds" => parse_int(params["duration_seconds"]) || 0,
      "severity" => blank_to_nil(params["event_severity"]),
      "event" => compact_map(event),
      "alert" => compact_map(alert)
    }
  end

  defp config_enabled?(config) do
    enabled = config_bool(config, :enabled, true)
    comparison = config_value(config, :comparison)
    value = config_value(config, :value)

    enabled and comparison not in ["", nil] and not is_nil(value)
  end

  defp config_value(config, key, default \\ nil) when is_map(config) do
    Map.get(config, key) || Map.get(config, Atom.to_string(key)) || default
  end

  defp config_value(_, _key, default), do: default

  defp config_bool(config, key, default) when is_map(config) do
    case config_value(config, key) do
      nil -> default
      value when is_boolean(value) -> value
      value when is_binary(value) -> String.downcase(value) in ["true", "1", "yes", "on"]
      value -> !!value
    end
  end

  defp config_bool(_config, _key, default), do: default

  defp param_bool(nil, default), do: default
  defp param_bool("true", _default), do: true
  defp param_bool("on", _default), do: true
  defp param_bool(true, _default), do: true
  defp param_bool(false, _default), do: false
  defp param_bool(_value, default), do: default

  defp parse_int(nil), do: nil
  defp parse_int(""), do: nil

  defp parse_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} -> int
      :error -> nil
    end
  end

  defp parse_int(value) when is_integer(value), do: value
  defp parse_int(_), do: nil

  defp parse_number(nil), do: nil
  defp parse_number(""), do: nil

  defp parse_number(value) when is_binary(value) do
    case Float.parse(value) do
      {float, _} -> float
      :error -> nil
    end
  end

  defp parse_number(value) when is_number(value), do: value
  defp parse_number(_), do: nil

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp compact_map(map) do
    map
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  # Threshold label helpers
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
