defmodule ServiceRadarWebNGWeb.InterfaceLive.Show do
  @moduledoc """
  LiveView for displaying detailed interface information.
  """
  use ServiceRadarWebNGWeb, :live_view

  alias ServiceRadarWebNGWeb.Dashboard.Engine
  alias ServiceRadarWebNGWeb.Dashboard.Plugins.Table, as: TablePlugin
  alias ServiceRadarWebNGWeb.Helpers.InterfaceTypes
  alias ServiceRadar.Inventory.InterfaceSettings

  @snmp_metrics_limit 3600

  @impl true
  def mount(_params, _session, socket) do
    srql = %{
      enabled: true,
      entity: "interfaces",
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
     |> assign(:page_title, "Interface Details")
     |> assign(:interface, nil)
     |> assign(:device, nil)
     |> assign(:settings, nil)
     |> assign(:srql, srql)
     |> assign(:metric_form, to_form(%{}, as: :metric))
     |> assign(:metric_modal_open, false)
     |> assign(:metric_modal_metric, nil)
     |> assign(:group_modal_open, false)
     |> assign(:group_modal_group, nil)
     |> assign(:group_form, to_form(%{}, as: :group))
     |> assign(:loading, true)
     |> assign(:error, nil)
     |> assign(:metrics, %{panels: [], error: nil, message: nil})}
  end

  @impl true
  def handle_params(
        %{"device_uid" => device_uid, "interface_uid" => interface_uid} = params,
        uri,
        socket
      ) do
    scope = socket.assigns.current_scope
    srql_module = Application.get_env(:serviceradar_web_ng, :srql_module, ServiceRadarWebNG.SRQL)

    # Load interface data
    {interface, error} = load_interface(srql_module, device_uid, interface_uid, scope)

    # Load device data for breadcrumb
    {device, _device_error} = load_device(srql_module, device_uid, scope)

    # Load interface settings (favorites, metrics enabled)
    settings = load_interface_settings(scope, device_uid, interface_uid)

    # Load metrics for this interface
    metrics = load_interface_metrics(srql_module, device_uid, interface, settings, scope)

    page_title =
      if interface do
        interface_name(interface)
      else
        "Interface Details"
      end

    default_query =
      "in:interfaces device_id:\"#{escape_value(device_uid)}\" " <>
        "interface_uid:\"#{escape_value(interface_uid)}\" latest:true limit:1"

    query =
      params
      |> Map.get("q", default_query)
      |> to_string()
      |> String.trim()
      |> case do
        "" -> default_query
        other -> other
      end

    page_path =
      uri
      |> to_string()
      |> URI.parse()
      |> Map.get(:path)

    srql =
      socket.assigns.srql
      |> Map.put(:query, query)
      |> Map.put(:draft, query)
      |> Map.put(:error, nil)
      |> Map.put(:loading, false)
      |> Map.put(:page_path, page_path)

    {:noreply,
     socket
     |> assign(:device_uid, device_uid)
     |> assign(:interface_uid, interface_uid)
     |> assign(:interface, interface)
     |> assign(:device, device)
     |> assign(:settings, settings)
     |> assign(:srql, srql)
     |> assign(:loading, false)
     |> assign(:error, error)
     |> assign(:metrics, metrics)
     |> assign(:page_title, page_title)}
  end

  @impl true
  def handle_event("srql_change", %{"q" => q}, socket) do
    {:noreply, assign(socket, :srql, Map.put(socket.assigns.srql, :draft, to_string(q)))}
  end

  def handle_event("srql_submit", %{"q" => q}, socket) do
    page_path =
      socket.assigns.srql[:page_path] ||
        "/devices/#{socket.assigns.device_uid}/interfaces/#{socket.assigns.interface_uid}"

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
       to: page_path <> "?" <> URI.encode_query(%{"q" => query})
     )}
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
          srql_module =
            Application.get_env(:serviceradar_web_ng, :srql_module, ServiceRadarWebNG.SRQL)

          metrics =
            load_interface_metrics(
              srql_module,
              device_uid,
              socket.assigns.interface,
              updated_settings,
              scope
            )

          {:noreply,
           socket
           |> assign(:settings, updated_settings)
           |> assign(:metrics, metrics)}

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
      interface = socket.assigns.interface
      form = to_form(metric_form_values(metric_name, config, interface), as: :metric)

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

  def handle_event("update_threshold_form", %{"metric" => params}, socket) do
    # Update form with new values when threshold type changes
    form = to_form(params, as: :metric)
    {:noreply, assign(socket, :metric_form, form)}
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

  # Chart Group Management Events
  def handle_event("open_group_modal", params, socket) do
    group_id = params["group_id"]
    groups = settings_list_value(socket.assigns.settings, :metric_groups)

    {group, form_values} =
      if group_id do
        group = Enum.find(groups, &(&1["id"] == group_id))

        if group do
          {group,
           %{
             "id" => group["id"],
             "name" => group["name"],
             "metrics" => group["metrics"] || []
           }}
        else
          {nil, new_group_form_values()}
        end
      else
        {nil, new_group_form_values()}
      end

    form = to_form(form_values, as: :group)

    {:noreply,
     socket
     |> assign(:group_form, form)
     |> assign(:group_modal_group, group)
     |> assign(:group_modal_open, true)}
  end

  def handle_event("close_group_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:group_modal_open, false)
     |> assign(:group_modal_group, nil)}
  end

  def handle_event("update_group_form", %{"group" => params}, socket) do
    form = to_form(params, as: :group)
    {:noreply, assign(socket, :group_form, form)}
  end

  def handle_event("save_group", %{"group" => params}, socket) do
    group_name = String.trim(params["name"] || "")

    if group_name == "" do
      {:noreply, put_flash(socket, :error, "Group name is required")}
    else
      save_group_with_name(socket, params, group_name)
    end
  end

  def handle_event("delete_group", %{"group_id" => group_id}, socket) do
    device_uid = socket.assigns.device_uid
    interface_uid = socket.assigns.interface_uid
    scope = socket.assigns.current_scope
    current_settings = socket.assigns.settings
    groups = settings_list_value(current_settings, :metric_groups)

    updated_groups = Enum.reject(groups, &(&1["id"] == group_id))
    attrs = %{metric_groups: updated_groups}

    case upsert_interface_setting(scope, device_uid, interface_uid, attrs) do
      {:ok, updated_settings} ->
        {:noreply,
         socket
         |> assign(:settings, updated_settings)
         |> put_flash(:info, "Chart group deleted")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Failed to delete chart group")}
    end
  end

  defp save_group_with_name(socket, params, group_name) do
    device_uid = socket.assigns.device_uid
    interface_uid = socket.assigns.interface_uid
    scope = socket.assigns.current_scope
    current_settings = socket.assigns.settings
    groups = settings_list_value(current_settings, :metric_groups)

    group_id = params["id"]
    metrics = parse_metrics_from_params(params["metrics"])
    updated_groups = update_or_create_group(groups, group_id, group_name, metrics)

    attrs = %{metric_groups: updated_groups}

    case upsert_interface_setting(scope, device_uid, interface_uid, attrs) do
      {:ok, updated_settings} ->
        {:noreply,
         socket
         |> assign(:settings, updated_settings)
         |> assign(:group_modal_open, false)
         |> assign(:group_modal_group, nil)
         |> put_flash(:info, "Chart group saved")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Failed to save chart group")}
    end
  end

  defp parse_metrics_from_params(metrics) when is_map(metrics) do
    metrics
    |> Enum.filter(fn {_k, v} -> v == "true" or v == true end)
    |> Enum.map(fn {k, _v} -> k end)
    |> Enum.sort()
  end

  defp parse_metrics_from_params(metrics) when is_list(metrics), do: Enum.sort(metrics)
  defp parse_metrics_from_params(_), do: []

  defp update_or_create_group(groups, group_id, group_name, metrics)
       when is_binary(group_id) and group_id != "" do
    Enum.map(groups, fn g ->
      if g["id"] == group_id,
        do: %{"id" => group_id, "name" => group_name, "metrics" => metrics},
        else: g
    end)
  end

  defp update_or_create_group(groups, _group_id, group_name, metrics) do
    new_group = %{
      "id" => Ecto.UUID.generate(),
      "name" => group_name,
      "metrics" => metrics
    }

    groups ++ [new_group]
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} srql={@srql} hide_breadcrumb={true}>
      <div class="container mx-auto px-4 py-6 max-w-6xl">
        <%!-- Breadcrumb --%>
        <nav class="text-sm breadcrumbs mb-4">
          <ul>
            <li><.link navigate={~p"/devices"}>Devices</.link></li>
            <li>
              <.link navigate={~p"/devices/#{@device_uid}"}>
                {if @device, do: device_name(@device), else: "Device"}
              </.link>
            </li>
            <li>
              <.link navigate={~p"/devices/#{@device_uid}?tab=interfaces"}>Interfaces</.link>
            </li>
            <li class="text-base-content/70">{@interface_uid}</li>
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

          <%!-- Metrics Graphs Section (positioned at top, below header) --%>
          <div
            :if={@metrics.panels != [] || @metrics.error || @metrics.message}
            class="card bg-base-100 border border-base-200 shadow-sm"
          >
            <div class="card-body">
              <h2 class="card-title text-lg">
                <.icon name="hero-chart-bar" class="size-5 text-primary" /> Metrics History
              </h2>

              <%!-- Error state --%>
              <div :if={@metrics.error} class="py-4">
                <div class="alert alert-error alert-sm">
                  <.icon name="hero-exclamation-triangle" class="size-4" />
                  <span class="text-sm">{@metrics.error}</span>
                </div>
              </div>

              <%!-- Empty-state message --%>
              <div :if={@metrics.message && @metrics.panels == [] && !@metrics.error} class="py-4">
                <div class="alert alert-info alert-sm">
                  <.icon name="hero-information-circle" class="size-4" />
                  <span class="text-sm">{@metrics.message}</span>
                </div>
              </div>

              <%!-- Metrics panels --%>
              <div :if={@metrics.panels != []} class="space-y-4">
                <%= for {panel, idx} <- Enum.with_index(@metrics.panels) do %>
                  <.live_component
                    module={panel.plugin}
                    id={"interface-detail-metrics-#{@interface_uid}-#{panel.id}-#{idx}"}
                    title={panel.title || "Metrics"}
                    panel_assigns={Map.put(panel.assigns, :compact, false)}
                  />
                <% end %>
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
                    value_title={Map.get(@interface, "if_type_name")}
                  />
                  <.property_row label="ifIndex" value={Map.get(@interface, "if_index")} />
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

            <%!-- Metrics Collection --%>
            <div class="card bg-base-100 border border-base-200 shadow-sm lg:col-span-2">
              <div class="card-body">
                <h2 class="card-title text-lg">
                  <.icon name="hero-chart-bar" class="size-5 text-primary" /> Metrics Collection
                </h2>
                <div class="divide-y divide-base-200">
                  <% selected_metrics = settings_list_value(@settings, :metrics_selected) %>
                  <% metrics_enabled = settings_value(@settings, :metrics_enabled) and selected_metrics != [] %>
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
                  <% normalized_metrics =
                    if available_metrics, do: Enum.filter(available_metrics, &is_map/1), else: [] %>
                  <%!-- Available Metrics Section --%>
                  <div :if={normalized_metrics != []} class="py-3 space-y-3">
                    <h3 class="text-sm font-medium">Available Metrics</h3>
                    <div class="grid grid-cols-1 sm:grid-cols-2 gap-2">
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
                  <div :if={normalized_metrics == []} class="py-3">
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
                  <%!-- Chart Groups Section --%>
                  <% metric_groups = settings_list_value(@settings, :metric_groups) %>
                  <div class="py-3 space-y-3 border-t border-base-200">
                    <div class="flex items-center justify-between">
                      <div>
                        <h3 class="text-sm font-medium">Composite Charts</h3>
                        <p class="text-xs text-base-content/50">
                          Group metrics together to display on a single chart.
                        </p>
                      </div>
                      <button
                        type="button"
                        class="btn btn-xs btn-primary"
                        phx-click="open_group_modal"
                      >
                        <.icon name="hero-plus-mini" class="size-3" /> New Group
                      </button>
                    </div>
                    <div :if={metric_groups != []} class="space-y-2">
                      <.chart_group_card
                        :for={group <- metric_groups}
                        group={group}
                        available_metrics={normalized_metrics}
                      />
                    </div>
                    <div :if={metric_groups == []} class="text-xs text-base-content/50">
                      No chart groups configured. Create a group to combine multiple metrics on a single chart.
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
            interface={@interface}
          />

          <.chart_group_modal
            :if={@group_modal_open}
            form={@group_form}
            group={@group_modal_group}
            available_metrics={Map.get(@interface, "available_metrics") || []}
            selected_metrics={settings_list_value(@settings, :metrics_selected)}
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
  attr :value_title, :string, default: nil

  defp property_row(assigns) do
    ~H"""
    <div class="py-3 flex justify-between gap-4">
      <span class="text-sm text-base-content/70 shrink-0">{@label}</span>
      <span
        class={[
          "text-sm text-right",
          @monospace && "font-mono",
          is_nil(@value) || (@value == "" && "text-base-content/40")
        ]}
        title={@value_title}
      >
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

  attr :group, :map, required: true
  attr :available_metrics, :list, default: []

  defp chart_group_card(assigns) do
    metrics = assigns.group["metrics"] || []
    metric_count = length(metrics)

    # Get display names for metrics
    metric_labels =
      metrics
      |> Enum.take(3)
      |> Enum.map(fn metric_name ->
        case Enum.find(assigns.available_metrics, &(metric_raw_name(&1) == metric_name)) do
          nil -> metric_name
          metric -> metric_display_name(metric)
        end
      end)

    remaining = max(0, metric_count - 3)

    assigns =
      assigns
      |> assign(:metric_count, metric_count)
      |> assign(:metric_labels, metric_labels)
      |> assign(:remaining, remaining)

    ~H"""
    <div class="flex items-center justify-between p-3 rounded-lg bg-base-200/50 border border-base-300">
      <div class="flex-1 min-w-0">
        <div class="flex items-center gap-2">
          <.icon name="hero-chart-bar-square" class="size-4 text-primary" />
          <span class="text-sm font-medium">{@group["name"]}</span>
          <span class="badge badge-xs badge-ghost">{@metric_count} metrics</span>
        </div>
        <div :if={@metric_labels != []} class="text-xs text-base-content/50 mt-1 truncate">
          {Enum.join(@metric_labels, ", ")}<span :if={@remaining > 0}> +{@remaining} more</span>
        </div>
        <div :if={@metric_labels == []} class="text-xs text-warning mt-1">
          No metrics selected
        </div>
      </div>
      <div class="flex items-center gap-1">
        <button
          type="button"
          class="btn btn-xs btn-ghost"
          phx-click="open_group_modal"
          phx-value-group_id={@group["id"]}
          title="Edit group"
        >
          <.icon name="hero-pencil" class="size-3" />
        </button>
        <button
          type="button"
          class="btn btn-xs btn-ghost text-error"
          phx-click="delete_group"
          phx-value-group_id={@group["id"]}
          data-confirm="Delete this chart group?"
          title="Delete group"
        >
          <.icon name="hero-trash" class="size-3" />
        </button>
      </div>
    </div>
    """
  end

  attr :form, :any, required: true
  attr :group, :map, default: nil
  attr :available_metrics, :list, default: []
  attr :selected_metrics, :list, default: []

  defp chart_group_modal(assigns) do
    # Normalize available metrics
    available_metrics =
      assigns.available_metrics
      |> Enum.filter(&is_map/1)
      |> Enum.map(fn m ->
        name = metric_raw_name(m)
        display = metric_display_name(m)
        category = Map.get(m, "category") || Map.get(m, :category) || "unknown"
        %{name: name, display: display, category: category}
      end)
      |> Enum.sort_by(& &1.display)

    # Get currently selected metrics in the group
    group_metrics = assigns.form[:metrics].value || []

    group_metrics =
      cond do
        is_list(group_metrics) ->
          group_metrics

        is_map(group_metrics) ->
          Enum.filter(Map.keys(group_metrics), &(group_metrics[&1] == "true"))

        true ->
          []
      end

    is_editing = assigns.group != nil

    assigns =
      assigns
      |> assign(:available_metrics, available_metrics)
      |> assign(:group_metrics, group_metrics)
      |> assign(:is_editing, is_editing)

    ~H"""
    <dialog class="modal modal-open">
      <div class="modal-box max-w-xl">
        <form method="dialog">
          <button
            class="btn btn-sm btn-circle btn-ghost absolute right-2 top-2"
            phx-click="close_group_modal"
          >
            x
          </button>
        </form>

        <h3 class="text-lg font-bold">
          {if @is_editing, do: "Edit Chart Group", else: "Create Chart Group"}
        </h3>
        <p class="text-sm text-base-content/60 mt-1">
          Select metrics to display together on a single chart.
        </p>

        <.form
          for={@form}
          id="chart-group-form"
          phx-submit="save_group"
          phx-change="update_group_form"
          class="space-y-4 mt-4"
        >
          <input type="hidden" name="group[id]" value={@form[:id].value} />

          <div class="form-control">
            <label class="label">
              <span class="label-text font-medium">Group Name</span>
            </label>
            <input
              type="text"
              name="group[name]"
              value={@form[:name].value}
              placeholder="e.g., Traffic, Errors, etc."
              class="input input-bordered w-full"
              required
            />
          </div>

          <div class="form-control">
            <label class="label">
              <span class="label-text font-medium">Metrics</span>
              <span class="label-text-alt text-base-content/50">
                Select compatible metrics to combine
              </span>
            </label>
            <div class="border border-base-300 rounded-lg p-3 max-h-64 overflow-y-auto space-y-1">
              <div
                :if={@available_metrics == []}
                class="text-sm text-base-content/50 py-2 text-center"
              >
                No metrics available. Enable metric discovery first.
              </div>
              <label
                :for={metric <- @available_metrics}
                class={[
                  "flex items-center gap-3 p-2 rounded-lg cursor-pointer hover:bg-base-200 transition",
                  metric.name in @group_metrics && "bg-primary/10"
                ]}
              >
                <input
                  type="checkbox"
                  name={"group[metrics][#{metric.name}]"}
                  value="true"
                  checked={metric.name in @group_metrics}
                  class="checkbox checkbox-sm checkbox-primary"
                />
                <div class="flex-1 min-w-0">
                  <span class="text-sm font-medium">{metric.display}</span>
                  <span class="text-xs text-base-content/50 ml-2">({metric.name})</span>
                </div>
                <span class="badge badge-xs badge-ghost">{metric.category}</span>
              </label>
            </div>
            <div class="label">
              <span class="label-text-alt text-base-content/50">
                Tip: Combine metrics with the same unit (e.g., inbound + outbound traffic)
              </span>
            </div>
          </div>

          <div class="modal-action">
            <button type="button" class="btn btn-ghost" phx-click="close_group_modal">
              Cancel
            </button>
            <button type="submit" class="btn btn-primary">
              <.icon name="hero-check" class="size-4" />
              {if @is_editing, do: "Update Group", else: "Create Group"}
            </button>
          </div>
        </.form>
      </div>
      <form method="dialog" class="modal-backdrop">
        <button phx-click="close_group_modal">close</button>
      </form>
    </dialog>
    """
  end

  attr :form, :any, required: true
  attr :metric_name, :string, required: true
  attr :interface, :map, default: nil

  defp metric_settings_modal(assigns) do
    # Extract interface speed for percentage threshold context
    interface_speed_bps = interface_speed_bps(assigns.interface)

    assigns =
      assigns
      |> assign(:interface_speed_bps, interface_speed_bps)
      |> assign(:has_speed_data, is_number(interface_speed_bps) and interface_speed_bps > 0)

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
          phx-change="update_threshold_form"
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

            <%!-- Threshold Type Selector --%>
            <div class="form-control">
              <label class="label">
                <span class="label-text text-xs font-medium">Threshold Type</span>
                <span :if={!@has_speed_data} class="label-text-alt text-warning text-xs">
                  <.icon name="hero-exclamation-triangle-mini" class="size-3" />
                  Interface speed unknown
                </span>
              </label>
              <div class="flex gap-2">
                <label class={[
                  "flex-1 btn btn-sm",
                  @form[:threshold_type].value != "percentage" && "btn-primary",
                  @form[:threshold_type].value == "percentage" && "btn-ghost"
                ]}>
                  <input
                    type="radio"
                    name="metric[threshold_type]"
                    value="absolute"
                    class="hidden"
                    checked={@form[:threshold_type].value != "percentage"}
                  />
                  <.icon name="hero-cube" class="size-4" /> Absolute (bytes/sec)
                </label>
                <label class={[
                  "flex-1 btn btn-sm",
                  @form[:threshold_type].value == "percentage" && "btn-primary",
                  @form[:threshold_type].value != "percentage" && "btn-ghost",
                  !@has_speed_data && "btn-disabled opacity-50"
                ]}>
                  <input
                    type="radio"
                    name="metric[threshold_type]"
                    value="percentage"
                    class="hidden"
                    checked={@form[:threshold_type].value == "percentage"}
                    disabled={!@has_speed_data}
                  />
                  <.icon name="hero-chart-pie" class="size-4" /> Percentage (% of speed)
                </label>
              </div>
              <div :if={@has_speed_data} class="label">
                <span class="label-text-alt text-xs text-base-content/50">
                  Interface speed: {format_bps(@interface_speed_bps) || "Unknown"}
                </span>
              </div>
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
                  <span class="label-text text-xs">
                    {threshold_value_label(@form[:threshold_type].value)}
                  </span>
                </label>
                <div class="join w-full">
                  <input
                    type="number"
                    name="metric[value]"
                    value={@form[:value].value}
                    placeholder={threshold_placeholder(@form[:threshold_type].value)}
                    min={if @form[:threshold_type].value == "percentage", do: "0", else: nil}
                    max={if @form[:threshold_type].value == "percentage", do: "100", else: nil}
                    step={if @form[:threshold_type].value == "percentage", do: "1", else: "any"}
                    class="input input-bordered input-sm w-full join-item"
                  />
                  <span class="btn btn-sm btn-ghost join-item pointer-events-none">
                    {threshold_unit(@form[:threshold_type].value)}
                  </span>
                </div>
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
        "badge badge-sm gap-1 min-w-[4.5rem] justify-center",
        oper_status_class(@oper_status)
      ]}>
        <.icon name={oper_status_icon(@oper_status)} class="size-3" />
        {oper_status_text(@oper_status)}
      </span>
      <span
        :if={@admin_status}
        class={[
          "badge badge-sm badge-outline gap-1 min-w-[5rem] justify-center",
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

  defp load_interface_metrics(_srql_module, _device_uid, nil, _settings, _scope) do
    %{panels: [], error: nil, message: nil}
  end

  defp load_interface_metrics(srql_module, device_uid, interface, settings, scope) do
    metrics_enabled = settings_value(settings, :metrics_enabled)
    selected_metrics = settings_list_value(settings, :metrics_selected)
    if_index = Map.get(interface, "if_index")

    if not metrics_enabled or selected_metrics == [] do
      %{panels: [], error: nil, message: "Metrics collection is disabled for this interface."}
    else
      if is_nil(if_index) do
        %{panels: [], error: nil, message: "Interface has no if_index for SNMP metrics"}
      else
        # Use agg:max to pull the latest counter values per bucket.
        # Rate deltas are calculated client-side for SNMP counter metrics.
        query =
          "in:snmp_metrics device_id:\"#{escape_value(device_uid)}\" if_index:#{if_index} " <>
            "time:last_24h bucket:5m agg:max series:metric_name limit:#{@snmp_metrics_limit}"

        # Get interface speed for proper graph scaling (bps -> bytes per second)
        if_speed_bps = Map.get(interface, "speed_bps") || Map.get(interface, "if_speed")
        if_speed_bytes_per_sec = if is_number(if_speed_bps), do: if_speed_bps / 8, else: nil

        # Get user-defined metric groups for composite charts
        metric_groups = settings_list_value(settings, :metric_groups)

        case srql_module.query(query, %{scope: scope}) do
          {:ok, %{"results" => results} = response} when is_list(results) and results != [] ->
            panels = build_metrics_panels(response, if_speed_bytes_per_sec, metric_groups)
            %{panels: panels, error: nil, message: nil}

          {:ok, %{"results" => []}} ->
            %{panels: [], error: nil, message: "No metrics data available yet"}

          {:error, reason} ->
            %{panels: [], error: "Failed to load metrics: #{inspect(reason)}", message: nil}

          _ ->
            %{panels: [], error: nil, message: nil}
        end
      end
    end
  end

  # Build panels for interface metrics with speed scaling and combined chart mode
  # Takes the full SRQL response (including viz) to properly handle series grouping
  # If metric_groups is provided and non-empty, group panels according to user configuration
  defp build_metrics_panels(srql_response, max_speed_bytes_per_sec, metric_groups)

  defp build_metrics_panels(srql_response, max_speed_bytes_per_sec, []) do
    # No user-defined groups - build individual panels for each metric
    Engine.build_panels(srql_response)
    |> Enum.reject(&(&1.plugin == TablePlugin))
    |> Enum.map(fn panel ->
      assigns =
        panel.assigns
        |> Map.put(:max_speed_bytes_per_sec, max_speed_bytes_per_sec)
        |> Map.put(:rate_mode, :counter)

      %{panel | assigns: assigns}
    end)
  end

  defp build_metrics_panels(srql_response, max_speed_bytes_per_sec, metric_groups) do
    results = Map.get(srql_response, "results", [])

    if results == [] do
      []
    else
      # Build panels for each user-defined group
      grouped_panels =
        metric_groups
        |> Enum.filter(fn group ->
          metrics = group["metrics"] || []
          metrics != []
        end)
        |> Enum.map(fn group ->
          build_grouped_panel(group, results, max_speed_bytes_per_sec)
        end)
        |> Enum.filter(&(&1 != nil))

      # Get all metrics that are in groups
      grouped_metric_names =
        metric_groups
        |> Enum.flat_map(fn g -> g["metrics"] || [] end)
        |> MapSet.new()

      # Build panels for ungrouped metrics
      ungrouped_results =
        Enum.filter(results, fn result ->
          metric_name = Map.get(result, "metric_name") || Map.get(result, :metric_name)
          metric_name not in grouped_metric_names
        end)

      ungrouped_panels =
        build_ungrouped_panels(srql_response, ungrouped_results, max_speed_bytes_per_sec)

      grouped_panels ++ ungrouped_panels
    end
  end

  defp build_ungrouped_panels(_srql_response, [], _max_speed_bytes_per_sec), do: []

  defp build_ungrouped_panels(srql_response, ungrouped_results, max_speed_bytes_per_sec) do
    ungrouped_response = Map.put(srql_response, "results", ungrouped_results)

    Engine.build_panels(ungrouped_response)
    |> Enum.reject(&(&1.plugin == TablePlugin))
    |> Enum.map(&add_panel_assigns(&1, max_speed_bytes_per_sec))
  end

  defp add_panel_assigns(panel, max_speed_bytes_per_sec) do
    assigns =
      panel.assigns
      |> Map.put(:max_speed_bytes_per_sec, max_speed_bytes_per_sec)
      |> Map.put(:chart_mode, :combined)
      |> Map.put(:rate_mode, :counter)

    %{panel | assigns: assigns}
  end

  # Build a single panel for a group of metrics
  defp build_grouped_panel(group, results, max_speed_bytes_per_sec) do
    group_name = group["name"] || "Combined Chart"
    group_metrics = group["metrics"] || []

    # Filter results to only include metrics in this group
    group_results = filter_results_by_metrics(results, group_metrics)

    if group_results == [] do
      nil
    else
      series = build_series_from_results(group_results)

      %{
        id: "group-#{group["id"]}",
        plugin: ServiceRadarWebNGWeb.Dashboard.Plugins.Timeseries,
        title: group_name,
        assigns: %{
          series: series,
          max_speed_bytes_per_sec: max_speed_bytes_per_sec,
          chart_mode: :combined,
          group_id: group["id"],
          rate_mode: :counter
        }
      }
    end
  end

  defp filter_results_by_metrics(results, group_metrics) do
    Enum.filter(results, fn result ->
      metric_name = Map.get(result, "metric_name") || Map.get(result, :metric_name)
      metric_name in group_metrics
    end)
  end

  defp build_series_from_results(group_results) do
    group_results
    |> Enum.map(&extract_metric_point/1)
    |> Enum.group_by(& &1.name)
    |> Enum.map(&format_series/1)
  end

  defp extract_metric_point(result) do
    %{
      name: Map.get(result, "metric_name") || Map.get(result, :metric_name),
      time: Map.get(result, "time") || Map.get(result, :time),
      value: Map.get(result, "value") || Map.get(result, :value)
    }
  end

  defp format_series({name, points}) do
    data =
      points
      |> Enum.map(fn p -> %{time: p.time, value: p.value} end)
      |> Enum.sort_by(& &1.time)

    %{name: format_metric_series_name(name), data: data}
  end

  # Format metric name for display in chart legend
  defp format_metric_series_name(name) when is_binary(name) do
    case name do
      "ifInOctets" -> "Inbound"
      "ifOutOctets" -> "Outbound"
      "ifHCInOctets" -> "Inbound (64-bit)"
      "ifHCOutOctets" -> "Outbound (64-bit)"
      "ifInErrors" -> "In Errors"
      "ifOutErrors" -> "Out Errors"
      "ifInDiscards" -> "In Discards"
      "ifOutDiscards" -> "Out Discards"
      "ifInUcastPkts" -> "In Packets"
      "ifOutUcastPkts" -> "Out Packets"
      _ -> name
    end
  end

  defp format_metric_series_name(name), do: to_string(name)

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

  defp metric_form_values(metric_name, config, interface) do
    alert = config_value(config, :alert, %{})
    event = config_value(config, :event, %{})

    # Default to percentage for traffic metrics when interface has speed data
    # and threshold_type hasn't been explicitly set
    default_threshold_type =
      case config_value(config, :threshold_type) do
        nil ->
          if traffic_metric?(metric_name) and has_interface_speed?(interface) do
            "percentage"
          else
            "absolute"
          end

        existing ->
          existing
      end

    %{
      "name" => metric_name,
      "enabled" => config_bool(config, :enabled, true),
      "threshold_type" => default_threshold_type,
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

  # Check if metric is a traffic/bytes metric that makes sense for percentage thresholds
  defp traffic_metric?(name) when is_binary(name) do
    name in ["ifInOctets", "ifOutOctets", "ifHCInOctets", "ifHCOutOctets"]
  end

  defp traffic_metric?(_), do: false

  defp has_interface_speed?(nil), do: false

  defp has_interface_speed?(interface) when is_map(interface) do
    speed = interface_speed_bps(interface)
    is_number(speed) and speed > 0
  end

  defp has_interface_speed?(_), do: false

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
      "threshold_type" => blank_to_nil(params["threshold_type"]) || "absolute",
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

  defp config_value(config, key, default \\ nil)

  defp config_value(config, key, default) when is_map(config) do
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

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp compact_map(map) do
    map
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  # Group form helpers
  defp new_group_form_values do
    %{
      "id" => "",
      "name" => "",
      "metrics" => []
    }
  end

  # Threshold type UI helpers
  defp interface_speed_bps(nil), do: nil

  defp interface_speed_bps(interface) when is_map(interface) do
    speed_bps = Map.get(interface, "speed_bps") || Map.get(interface, :speed_bps)
    if_speed = Map.get(interface, "if_speed") || Map.get(interface, :if_speed)
    speed_bps || if_speed
  end

  defp threshold_value_label("percentage"), do: "Threshold (%)"
  defp threshold_value_label(_), do: "Threshold Value"

  defp threshold_placeholder("percentage"), do: "e.g., 80"
  defp threshold_placeholder(_), do: "e.g., 10000000"

  defp threshold_unit("percentage"), do: "%"
  defp threshold_unit(_), do: "B/s"

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
