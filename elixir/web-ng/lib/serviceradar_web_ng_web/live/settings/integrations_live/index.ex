defmodule ServiceRadarWebNGWeb.Settings.IntegrationsLive.Index do
  @moduledoc """
  LiveView for managing integration sources (Armis, SNMP, etc.).

  Integration sources are stored in Postgres and delivered to sync services
  via gateway-config updates.
  """
  use ServiceRadarWebNGWeb, :live_view

  import ServiceRadarWebNGWeb.SettingsComponents

  alias Ash.Page.Keyset
  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.Infrastructure.Partition
  alias ServiceRadar.Integrations
  alias ServiceRadar.Integrations.IntegrationSource
  alias ServiceRadar.Integrations.MapboxSettings
  alias ServiceRadarWebNG.RBAC

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    if RBAC.can?(scope, "settings.integrations.manage") do
      actor = get_actor(socket)
      partitions = list_partitions(actor)
      agents = list_agents(actor)
      agent_index = build_agent_index(agents)
      agent_options = build_agent_options(agents)
      sync_agent_available = sync_agent_available?(actor)

      socket =
        socket
        |> assign(:page_title, "Integration Sources")
        |> assign(:settings_tab, "crm_ipam")
        |> assign(:sources, list_sources(actor))
        |> assign(:partitions, partitions)
        |> assign(:partition_options, build_partition_options(partitions))
        |> assign(:agents, agents)
        |> assign(:agent_index, agent_index)
        |> assign(:agent_options, agent_options)
        |> assign(:sync_agent_available, sync_agent_available)
        |> assign(:show_create_modal, false)
        |> assign(:show_edit_modal, false)
        |> assign(:show_details_modal, false)
        |> assign(:selected_source, nil)
        |> assign(:create_form, build_create_form(actor))
        |> assign(:edit_form, nil)
        |> assign(:filter_type, nil)
        |> assign(:filter_enabled, nil)
        # Query management for forms
        |> assign(:form_queries, [default_query()])
        |> assign(:form_network_blacklist, "")
        |> assign(:mapbox_settings, load_mapbox_settings(actor))
        |> assign(:mapbox_form, mapbox_settings_to_form(load_mapbox_settings(actor)))

      {:ok, socket}
    else
      {:ok,
       socket
       |> put_flash(:error, "Not authorized to manage integrations")
       |> redirect(to: ~p"/settings/profile")}
    end
  end

  defp default_query do
    %{
      "id" => System.unique_integer([:positive]),
      "label" => "",
      "query" => "",
      "sweep_modes" => []
    }
  end

  defp toggle_sweep_mode_for_query(query, target_id, mode) do
    if query["id"] == target_id do
      modes = Map.get(query, "sweep_modes", [])
      Map.put(query, "sweep_modes", toggle_mode(modes, mode))
    else
      query
    end
  end

  defp toggle_mode(modes, mode) do
    if mode in modes, do: List.delete(modes, mode), else: modes ++ [mode]
  end

  @impl true
  def handle_params(params, _url, socket) do
    settings_tab = normalize_settings_tab(Map.get(params, "tab"))

    socket =
      socket
      |> assign(:settings_tab, settings_tab)
      |> then(fn s ->
        # Keep Mapbox settings up to date when navigating tabs.
        if settings_tab == "mapbox" do
          settings = load_mapbox_settings(get_actor(s))

          s
          |> assign(:mapbox_settings, settings)
          |> assign(:mapbox_form, mapbox_settings_to_form(settings))
        else
          s
        end
      end)

    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params), do: socket

  defp apply_action(socket, :new, _params) do
    actor = get_actor(socket)

    if sync_agent_available?(actor) do
      assign(socket, :show_create_modal, true)
    else
      socket
      |> put_flash(:error, "Install and register an agent before adding integrations.")
      |> push_navigate(to: ~p"/settings/networks/integrations")
    end
  end

  defp apply_action(socket, :show, %{"id" => id}) do
    actor = get_actor(socket)

    case get_source(id, actor) do
      {:ok, source} ->
        socket
        |> assign(:selected_source, source)
        |> assign(:show_details_modal, true)

      {:error, _} ->
        socket
        |> put_flash(:error, "Integration source not found")
        |> push_navigate(to: ~p"/settings/networks/integrations")
    end
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    actor = get_actor(socket)

    case get_source(id, actor) do
      {:ok, source} ->
        # Convert source queries to form_queries format with IDs
        form_queries = source_queries_to_form(source.queries)
        # Convert network_blacklist array to textarea format
        form_blacklist = Enum.join(source.network_blacklist || [], "\n")

        socket
        |> assign(:selected_source, source)
        |> assign(:edit_form, build_edit_form(source, actor))
        |> assign(:form_queries, form_queries)
        |> assign(:form_network_blacklist, form_blacklist)
        |> assign(:show_edit_modal, true)

      {:error, _} ->
        socket
        |> put_flash(:error, "Integration source not found")
        |> push_navigate(to: ~p"/settings/networks/integrations")
    end
  end

  defp source_queries_to_form(nil), do: [default_query()]
  defp source_queries_to_form([]), do: [default_query()]

  defp source_queries_to_form(queries) when is_list(queries) do
    Enum.map(queries, fn q ->
      %{
        "id" => System.unique_integer([:positive]),
        "label" => q["label"] || Map.get(q, :label, ""),
        "query" => q["query"] || Map.get(q, :query, ""),
        "sweep_modes" => q["sweep_modes"] || Map.get(q, :sweep_modes, [])
      }
    end)
  end

  @impl true
  def handle_event("open_create_modal", _params, socket) do
    actor = get_actor(socket)

    if sync_agent_available?(actor) do
      agents = list_agents(actor)
      agent_index = build_agent_index(agents)
      agent_options = build_agent_options(agents)

      {:noreply,
       socket
       |> assign(:show_create_modal, true)
       |> assign(:create_form, build_create_form(actor))
       |> assign(:agents, agents)
       |> assign(:agent_index, agent_index)
       |> assign(:agent_options, agent_options)
       |> assign(:form_queries, [default_query()])
       |> assign(:form_network_blacklist, "")}
    else
      {:noreply, put_flash(socket, :error, "Install and register an agent before adding integrations.")}
    end
  end

  @impl true
  def handle_event("mapbox_save", %{"mapbox" => params}, socket) do
    actor = get_actor(socket)
    record = socket.assigns.mapbox_settings || load_mapbox_settings(actor)
    update_params = build_mapbox_update_params(params)

    result =
      case record do
        %MapboxSettings{} ->
          MapboxSettings.update_settings(record, update_params, actor: actor)

        _ ->
          MapboxSettings.create(update_params, actor: actor)
      end

    case result do
      {:ok, %MapboxSettings{} = updated} ->
        {:noreply,
         socket
         |> put_flash(:info, "Mapbox settings saved")
         |> assign(:mapbox_settings, updated)
         |> assign(:mapbox_form, mapbox_settings_to_form(updated))}

      {:error, err} ->
        {:noreply, put_flash(socket, :error, "Failed to save Mapbox settings: #{format_ash_error(err)}")}
    end
  end

  def handle_event("close_create_modal", _params, socket) do
    actor = get_actor(socket)

    {:noreply,
     socket
     |> assign(:show_create_modal, false)
     |> assign(:create_form, build_create_form(actor))
     |> assign(:form_queries, [default_query()])
     |> assign(:form_network_blacklist, "")}
  end

  def handle_event("close_edit_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_edit_modal, false)
     |> assign(:selected_source, nil)
     |> assign(:edit_form, nil)
     |> assign(:form_queries, [default_query()])
     |> assign(:form_network_blacklist, "")}
  end

  def handle_event("close_details_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_details_modal, false)
     |> assign(:selected_source, nil)}
  end

  def handle_event("validate_create", %{"form" => params}, socket) do
    form =
      socket.assigns.create_form.source
      |> AshPhoenix.Form.validate(params)
      |> to_form()

    {:noreply, assign(socket, :create_form, form)}
  end

  def handle_event("validate_edit", %{"form" => params}, socket) do
    form =
      socket.assigns.edit_form.source
      |> AshPhoenix.Form.validate(params)
      |> to_form()

    {:noreply, assign(socket, :edit_form, form)}
  end

  # Query management events
  def handle_event("add_query", _params, socket) do
    queries = socket.assigns.form_queries ++ [default_query()]
    {:noreply, assign(socket, :form_queries, queries)}
  end

  def handle_event("remove_query", %{"id" => id_str}, socket) do
    case Integer.parse(id_str) do
      {id, ""} ->
        queries = Enum.reject(socket.assigns.form_queries, &(&1["id"] == id))
        # Ensure at least one query remains
        queries = if queries == [], do: [default_query()], else: queries
        {:noreply, assign(socket, :form_queries, queries)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("update_query", %{"id" => id_str, "field" => field, "value" => value}, socket) do
    case Integer.parse(id_str) do
      {id, ""} ->
        queries = update_query_field(socket.assigns.form_queries, id, field, value)
        {:noreply, assign(socket, :form_queries, queries)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("toggle_sweep_mode", %{"id" => id_str, "mode" => mode}, socket) do
    case Integer.parse(id_str) do
      {id, ""} ->
        queries =
          Enum.map(socket.assigns.form_queries, &toggle_sweep_mode_for_query(&1, id, mode))

        {:noreply, assign(socket, :form_queries, queries)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("update_network_blacklist", params, socket) do
    # Handle both direct value and form params
    value = params["value"] || params["network_blacklist_text"] || ""
    {:noreply, assign(socket, :form_network_blacklist, value)}
  end

  def handle_event("create_source", %{"form" => params}, socket) do
    actor = get_actor(socket)

    if sync_agent_available?(actor) do
      # Handle credentials JSON if provided
      params = parse_credentials_json(params)

      # Add queries from form_queries assign
      queries = build_queries_for_submit(socket.assigns.form_queries)
      params = Map.put(params, "queries", queries)

      # Add network_blacklist from textarea
      blacklist = parse_network_blacklist(socket.assigns.form_network_blacklist)
      params = Map.put(params, "network_blacklist", blacklist)

      form = AshPhoenix.Form.validate(socket.assigns.create_form.source, params)

      case AshPhoenix.Form.submit(form, params: params, actor: actor) do
        {:ok, _source} ->
          {:noreply,
           socket
           |> assign(:show_create_modal, false)
           |> assign(:sources, list_sources(actor))
           |> assign(:create_form, build_create_form(actor))
           |> put_flash(:info, "Integration source created successfully")}

        {:error, form} ->
          {:noreply,
           socket
           |> assign(:create_form, to_form(form))
           |> put_flash(:error, "Failed to create integration source")}
      end
    else
      {:noreply, put_flash(socket, :error, "Install and register an agent before adding integrations.")}
    end
  end

  def handle_event("update_source", %{"form" => params}, socket) do
    actor = get_actor(socket)

    # Handle credentials JSON if provided
    params = parse_credentials_json(params)

    # Add queries from form_queries assign
    queries = build_queries_for_submit(socket.assigns.form_queries)
    params = Map.put(params, "queries", queries)

    # Add network_blacklist from textarea
    blacklist = parse_network_blacklist(socket.assigns.form_network_blacklist)
    params = Map.put(params, "network_blacklist", blacklist)

    form = AshPhoenix.Form.validate(socket.assigns.edit_form.source, params)

    case AshPhoenix.Form.submit(form, params: params, actor: actor) do
      {:ok, _source} ->
        {:noreply,
         socket
         |> assign(:show_edit_modal, false)
         |> assign(:selected_source, nil)
         |> assign(:edit_form, nil)
         |> assign(:sources, list_sources(actor))
         |> assign(:form_queries, [default_query()])
         |> assign(:form_network_blacklist, "")
         |> put_flash(:info, "Integration source updated successfully")}

      {:error, form} ->
        {:noreply,
         socket
         |> assign(:edit_form, to_form(form))
         |> put_flash(:error, "Failed to update integration source")}
    end
  end

  def handle_event("toggle_enabled", %{"id" => id}, socket) do
    actor = get_actor(socket)

    case get_source(id, actor) do
      {:ok, source} ->
        action = if source.enabled, do: :disable, else: :enable

        case source
             |> Ash.Changeset.for_update(action, %{})
             |> Ash.update(actor: actor) do
          {:ok, _} ->
            {:noreply,
             socket
             |> assign(:sources, list_sources(actor))
             |> put_flash(:info, "Integration source #{action}d")}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to toggle integration source")}
        end

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Integration source not found")}
    end
  end

  def handle_event("delete_source", %{"id" => id}, socket) do
    actor = get_actor(socket)

    case get_source(id, actor) do
      {:ok, source} ->
        case Ash.destroy(source, actor: actor) do
          :ok ->
            {:noreply,
             socket
             |> assign(:show_details_modal, false)
             |> assign(:selected_source, nil)
             |> assign(:sources, list_sources(actor))
             |> put_flash(:info, "Integration source deleted")}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to delete integration source")}
        end

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Integration source not found")}
    end
  end

  def handle_event("filter", params, socket) do
    actor = get_actor(socket)

    source_type = Map.get(params, "source_type", "")
    enabled = Map.get(params, "enabled", "")

    filters = %{}
    filters = if source_type == "", do: filters, else: Map.put(filters, :source_type, source_type)
    filters = if enabled == "", do: filters, else: Map.put(filters, :enabled, enabled == "true")

    {:noreply,
     socket
     |> assign(:filter_type, if(source_type == "", do: nil, else: source_type))
     |> assign(:filter_enabled, if(enabled == "", do: nil, else: enabled == "true"))
     |> assign(:sources, list_sources(actor, filters))}
  end

  defp update_query_field(queries, id, field, value) do
    Enum.map(queries, fn q ->
      if q["id"] == id, do: Map.put(q, field, value), else: q
    end)
  end

  defp normalize_settings_tab(nil), do: "crm_ipam"
  defp normalize_settings_tab(""), do: "crm_ipam"

  defp normalize_settings_tab(value) when is_binary(value) do
    case String.downcase(String.trim(value)) do
      "mapbox" -> "mapbox"
      "crm_ipam" -> "crm_ipam"
      _ -> "crm_ipam"
    end
  end

  defp normalize_settings_tab(_), do: "crm_ipam"

  defp load_mapbox_settings(actor) do
    case MapboxSettings.get_settings(actor: actor) do
      {:ok, %MapboxSettings{} = settings} ->
        settings

      _ ->
        case MapboxSettings.create(%{}, actor: actor) do
          {:ok, %MapboxSettings{} = settings} -> settings
          _ -> nil
        end
    end
  end

  defp mapbox_settings_to_form(nil), do: nil

  defp mapbox_settings_to_form(%MapboxSettings{} = settings) do
    to_form(
      %{
        "enabled" => truthy(settings.enabled),
        "style_light" => settings.style_light || "mapbox://styles/mapbox/light-v11",
        "style_dark" => settings.style_dark || "mapbox://styles/mapbox/dark-v11",
        "clear_access_token" => false
      },
      as: "mapbox"
    )
  end

  defp build_mapbox_update_params(params) when is_map(params) do
    base = %{
      enabled: truthy_param?(Map.get(params, "enabled")),
      style_light: params |> Map.get("style_light") |> to_string() |> String.trim(),
      style_dark: params |> Map.get("style_dark") |> to_string() |> String.trim(),
      clear_access_token: truthy_param?(Map.get(params, "clear_access_token"))
    }

    token = Map.get(params, "access_token")

    if is_binary(token) and String.trim(token) != "" do
      Map.put(base, :access_token, String.trim(token))
    else
      base
    end
  end

  defp build_mapbox_update_params(_), do: %{}

  defp truthy(true), do: true
  defp truthy("true"), do: true
  defp truthy("1"), do: true
  defp truthy(_), do: false

  defp truthy_param?(true), do: true
  defp truthy_param?("true"), do: true
  defp truthy_param?("1"), do: true
  defp truthy_param?("on"), do: true
  defp truthy_param?(_), do: false

  defp format_ash_error(%Ash.Error.Invalid{errors: errors}) do
    Enum.map_join(errors, ", ", fn
      %{message: message} -> message
      _ -> "Validation error"
    end)
  end

  defp format_ash_error(_), do: "Unexpected error"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.settings_shell current_path="/settings/networks/integrations">
        <.settings_nav current_path="/settings/networks/integrations" current_scope={@current_scope} />
        <.network_nav current_path="/settings/networks/integrations" current_scope={@current_scope} />

        <div class="flex flex-wrap items-center justify-between gap-4">
          <div>
            <h1 class="text-2xl font-semibold text-base-content">Integration Sources</h1>
            <p class="text-sm text-base-content/60">
              Manage data source integrations (Armis, SNMP, Syslog, etc.)
            </p>
          </div>
          <div class="flex flex-col items-end gap-2">
            <.ui_button
              :if={RBAC.can?(@current_scope, "settings.integrations.manage")}
              variant="primary"
              size="sm"
              phx-click="open_create_modal"
              disabled={not @sync_agent_available}
            >
              <.icon name="hero-plus" class="size-4" /> New Source
            </.ui_button>
            <%= if not @sync_agent_available do %>
              <p class="text-xs text-base-content/60">
                Register an agent before adding integrations.
              </p>
            <% end %>
          </div>
        </div>

        <div class="mt-4">
          <div class="tabs tabs-boxed">
            <.link
              patch={~p"/settings/networks/integrations?tab=crm_ipam"}
              class={["tab", @settings_tab == "crm_ipam" && "tab-active"]}
            >
              CRM/IPAM
            </.link>
            <.link
              patch={~p"/settings/networks/integrations?tab=mapbox"}
              class={["tab", @settings_tab == "mapbox" && "tab-active"]}
            >
              Mapbox
            </.link>
          </div>
        </div>

        <.ui_panel :if={@settings_tab == "crm_ipam"}>
          <:header>
            <div>
              <div class="text-sm font-semibold">Sources</div>
              <p class="text-xs text-base-content/60">
                {@sources |> length()} source(s)
              </p>
            </div>
            <div class="flex gap-2">
              <select
                name="source_type"
                class="select select-sm select-bordered"
                phx-change="filter"
              >
                <option value="">All Types</option>
                <option value="armis" selected={@filter_type == "armis"}>Armis</option>
                <option value="snmp" selected={@filter_type == "snmp"}>SNMP</option>
                <option value="syslog" selected={@filter_type == "syslog"}>Syslog</option>
                <option value="netbox" selected={@filter_type == "netbox"}>Netbox</option>
                <option value="custom" selected={@filter_type == "custom"}>Custom</option>
              </select>
              <select
                name="enabled"
                class="select select-sm select-bordered"
                phx-change="filter"
              >
                <option value="">All Status</option>
                <option value="true" selected={@filter_enabled == true}>Enabled</option>
                <option value="false" selected={@filter_enabled == false}>Disabled</option>
              </select>
            </div>
          </:header>

          <div class="overflow-x-auto">
            <%= if @sources == [] do %>
              <div class="rounded-xl border border-dashed border-base-200 bg-base-100 p-8 text-center">
                <div class="text-sm font-semibold text-base-content">No integration sources</div>
                <p class="mt-1 text-xs text-base-content/60">
                  Create a new integration source to connect to external data sources.
                </p>
              </div>
            <% else %>
              <table class="table table-sm">
                <thead>
                  <tr class="text-xs uppercase tracking-wide text-base-content/60">
                    <th>Name</th>
                    <th>Type</th>
                    <th>Partition</th>
                    <th>Agent</th>
                    <th>Endpoint</th>
                    <th>Status</th>
                    <th>Last Sync</th>
                    <th></th>
                  </tr>
                </thead>
                <tbody>
                  <%= for source <- @sources do %>
                    <tr class="hover:bg-base-200/30">
                      <td>
                        <div class="font-medium">{source.name}</div>
                        <div class="text-xs text-base-content/60 font-mono">
                          {String.slice(source.id, 0, 8)}...
                        </div>
                      </td>
                      <td>
                        <.source_type_badge type={source.source_type} />
                      </td>
                      <td class="text-xs text-base-content/70">
                        {source.partition || "-"}
                      </td>
                      <td class="text-xs text-base-content/70">
                        <%= if source.agent_id && source.agent_id != "" do %>
                          <% agent = Map.get(@agent_index, source.agent_id) %>
                          <div class="font-medium">
                            {agent_display_name(agent, source.agent_id)}
                          </div>
                          <div class="mt-1">
                            <%= if agent do %>
                              <.agent_status_badge agent={agent} />
                            <% else %>
                              <.ui_badge variant="ghost" size="xs">Unknown</.ui_badge>
                            <% end %>
                          </div>
                        <% else %>
                          <span class="text-xs text-base-content/60">Auto-assign</span>
                        <% end %>
                      </td>
                      <td class="text-xs text-base-content/70 max-w-[200px] truncate">
                        {source.endpoint}
                      </td>
                      <td>
                        <.status_badge enabled={source.enabled} result={source.last_sync_result} />
                        <%= if source.last_error_message do %>
                          <div
                            class="text-xs text-error/80 max-w-[180px] truncate"
                            title={source.last_error_message}
                          >
                            {source.last_error_message}
                          </div>
                        <% end %>
                      </td>
                      <td class="text-xs text-base-content/70">
                        {format_datetime(source.last_sync_at)}
                      </td>
                      <td>
                        <div class="flex gap-1">
                          <.ui_button
                            variant="ghost"
                            size="xs"
                            navigate={~p"/settings/networks/integrations/#{source.id}"}
                          >
                            View
                          </.ui_button>
                          <.ui_button
                            variant="ghost"
                            size="xs"
                            navigate={~p"/settings/networks/integrations/#{source.id}/edit"}
                          >
                            Edit
                          </.ui_button>
                          <.ui_button
                            variant="ghost"
                            size="xs"
                            phx-click="toggle_enabled"
                            phx-value-id={source.id}
                          >
                            {if source.enabled, do: "Disable", else: "Enable"}
                          </.ui_button>
                        </div>
                      </td>
                    </tr>
                  <% end %>
                </tbody>
              </table>
            <% end %>
          </div>
        </.ui_panel>

        <.ui_panel :if={@settings_tab == "mapbox"}>
          <:header>
            <div>
              <div class="text-sm font-semibold">Mapbox</div>
              <p class="text-xs text-base-content/60">
                Configure the Mapbox token and map style used for flow details maps.
              </p>
            </div>
          </:header>

          <%= if @mapbox_form do %>
            <form phx-submit="mapbox_save" class="space-y-4">
              <label class="flex items-center gap-2 text-sm">
                <input
                  type="checkbox"
                  class="toggle toggle-primary"
                  name="mapbox[enabled]"
                  value="true"
                  checked={truthy_param?(Map.get(@mapbox_form.source, "enabled"))}
                />
                <span>Enable Mapbox maps</span>
              </label>

              <div class="grid grid-cols-1 lg:grid-cols-2 gap-4">
                <div>
                  <div class="text-xs uppercase tracking-wider text-base-content/60 mb-1">
                    Style (Light)
                  </div>
                  <input
                    type="text"
                    name="mapbox[style_light]"
                    value={
                      Map.get(@mapbox_form.source, "style_light") ||
                        "mapbox://styles/mapbox/light-v11"
                    }
                    class="input input-bordered w-full"
                    placeholder="mapbox://styles/..."
                  />
                </div>
                <div>
                  <div class="text-xs uppercase tracking-wider text-base-content/60 mb-1">
                    Style (Dark)
                  </div>
                  <input
                    type="text"
                    name="mapbox[style_dark]"
                    value={
                      Map.get(@mapbox_form.source, "style_dark") || "mapbox://styles/mapbox/dark-v11"
                    }
                    class="input input-bordered w-full"
                    placeholder="mapbox://styles/..."
                  />
                </div>
              </div>

              <div>
                <div class="text-xs uppercase tracking-wider text-base-content/60 mb-1">
                  Access token
                </div>
                <input
                  type="password"
                  name="mapbox[access_token]"
                  value=""
                  class="input input-bordered w-full font-mono"
                  placeholder="pk.... (leave blank to keep existing)"
                  autocomplete="off"
                />
                <div class="mt-1 flex items-center gap-2 text-xs text-base-content/60">
                  <span>
                    Saved:
                    <%= if @mapbox_settings && Map.get(@mapbox_settings, :access_token_present) do %>
                      <span class="badge badge-xs badge-success">yes</span>
                    <% else %>
                      <span class="badge badge-xs">no</span>
                    <% end %>
                  </span>
                  <label class="flex items-center gap-2">
                    <input
                      type="checkbox"
                      class="checkbox checkbox-xs"
                      name="mapbox[clear_access_token]"
                      value="true"
                    />
                    <span>Clear token</span>
                  </label>
                </div>
              </div>

              <div class="flex items-center justify-end gap-2">
                <button type="submit" class="btn btn-primary btn-sm">Save</button>
              </div>
            </form>
          <% else %>
            <div class="text-sm text-base-content/60">Mapbox settings are unavailable.</div>
          <% end %>
        </.ui_panel>
      </.settings_shell>

      <.create_modal
        :if={@show_create_modal}
        form={@create_form}
        partition_options={@partition_options}
        agent_options={@agent_options}
        form_queries={@form_queries}
        form_network_blacklist={@form_network_blacklist}
      />
      <.edit_modal
        :if={@show_edit_modal}
        form={@edit_form}
        source={@selected_source}
        partition_options={@partition_options}
        agent_options={@agent_options}
        form_queries={@form_queries}
        form_network_blacklist={@form_network_blacklist}
      />
      <.details_modal
        :if={@show_details_modal}
        source={@selected_source}
        agent_index={@agent_index}
      />
    </Layouts.app>
    """
  end

  defp create_modal(assigns) do
    ~H"""
    <dialog id="create_modal" class="modal modal-open">
      <div class="modal-box max-w-2xl">
        <form method="dialog">
          <button
            class="btn btn-sm btn-circle btn-ghost absolute right-2 top-2"
            phx-click="close_create_modal"
          >
            x
          </button>
        </form>

        <h3 class="text-lg font-bold">Create Integration Source</h3>
        <p class="py-2 text-sm text-base-content/70">
          Configure a new data source integration.
        </p>

        <.form
          for={@form}
          id="create_source_form"
          phx-change="validate_create"
          phx-submit="create_source"
          class="space-y-4 mt-4"
        >
          <div class="grid grid-cols-2 gap-4">
            <.input
              field={@form[:name]}
              type="text"
              label="Name"
              placeholder="e.g., Production Armis"
              required
            />

            <.input
              field={@form[:source_type]}
              type="select"
              label="Source Type"
              options={[
                {"Armis", :armis},
                {"SNMP", :snmp},
                {"Syslog", :syslog},
                {"Netbox", :netbox},
                {"Custom", :custom}
              ]}
            />
          </div>

          <.input
            field={@form[:endpoint]}
            type="text"
            label="Endpoint URL"
            placeholder="https://api.armis.com"
            required
          />

          <div class="grid grid-cols-2 gap-4">
            <.input
              field={@form[:partition]}
              type="select"
              label="Partition"
              options={@partition_options}
              prompt="Select a partition..."
            />

            <.input
              field={@form[:agent_id]}
              type="select"
              label="Agent"
              options={@agent_options}
              prompt="Auto-assign to any connected agent"
            />
          </div>

          <.input
            field={@form[:gateway_id]}
            type="text"
            label="Gateway ID (Optional)"
            placeholder="Gateway to assign this source to"
          />

          <div class="grid grid-cols-3 gap-4">
            <.input
              field={@form[:poll_interval_seconds]}
              type="number"
              label="Poll Interval (sec)"
              placeholder="300"
            />

            <.input
              field={@form[:discovery_interval_seconds]}
              type="number"
              label="Discovery Interval (sec)"
              placeholder="3600"
            />

            <.input
              field={@form[:sweep_interval_seconds]}
              type="number"
              label="Sweep Interval (sec)"
              placeholder="3600"
            />
          </div>
          <p class="text-xs text-base-content/60 -mt-2">
            Poll: fetch updates • Discovery: full device scan • Sweep: network scan
          </p>

          <div class="divider text-xs text-base-content/60">Credentials</div>

          <.dynamic_credentials_fields
            form={@form}
            source_type={@form[:source_type].value || :armis}
            mode={:create}
          />

          <div class="divider text-xs text-base-content/60">Queries</div>

          <div class="space-y-3">
            <%= for query <- @form_queries do %>
              <div class="p-3 bg-base-200 rounded-lg space-y-2">
                <div class="flex items-center justify-between">
                  <span class="text-xs font-semibold text-base-content/60">Query</span>
                  <button
                    type="button"
                    class="btn btn-ghost btn-xs text-error"
                    phx-click="remove_query"
                    phx-value-id={query["id"]}
                  >
                    <.icon name="hero-trash" class="size-3" /> Remove
                  </button>
                </div>
                <div class="grid grid-cols-2 gap-2">
                  <div class="form-control">
                    <label class="label py-1">
                      <span class="label-text text-xs">Label</span>
                    </label>
                    <input
                      type="text"
                      class="input input-bordered input-sm w-full"
                      placeholder="e.g., all_devices"
                      value={query["label"]}
                      phx-blur="update_query"
                      phx-value-id={query["id"]}
                      phx-value-field="label"
                    />
                  </div>
                  <div class="form-control">
                    <label class="label py-1">
                      <span class="label-text text-xs">Query (AQL)</span>
                    </label>
                    <input
                      type="text"
                      class="input input-bordered input-sm w-full font-mono"
                      placeholder="in:devices"
                      value={query["query"]}
                      phx-blur="update_query"
                      phx-value-id={query["id"]}
                      phx-value-field="query"
                    />
                  </div>
                </div>
              </div>
            <% end %>

            <button
              type="button"
              class="btn btn-outline btn-sm w-full"
              phx-click="add_query"
            >
              <.icon name="hero-plus" class="size-4" /> Add Query
            </button>
          </div>

          <%= if shows_network_blacklist?(@form[:source_type].value) do %>
            <div class="divider text-xs text-base-content/60">Network Settings</div>

            <div class="form-control">
              <label class="label">
                <span class="label-text">Network Blacklist</span>
              </label>
              <textarea
                name="network_blacklist_text"
                class="textarea textarea-bordered w-full font-mono text-sm"
                rows="3"
                placeholder="10.0.0.0/8&#10;172.16.0.0/12&#10;192.168.0.0/16"
                phx-blur="update_network_blacklist"
              ><%= @form_network_blacklist %></textarea>
              <label class="label">
                <span class="label-text-alt text-base-content/60">
                  One CIDR per line - networks to exclude from discovery
                </span>
              </label>
            </div>
          <% end %>

          <div class="modal-action">
            <button type="button" class="btn" phx-click="close_create_modal">Cancel</button>
            <button type="submit" class="btn btn-primary">Create Source</button>
          </div>
        </.form>
      </div>
      <form method="dialog" class="modal-backdrop">
        <button phx-click="close_create_modal">close</button>
      </form>
    </dialog>
    """
  end

  defp edit_modal(assigns) do
    ~H"""
    <dialog id="edit_modal" class="modal modal-open">
      <div class="modal-box max-w-2xl">
        <form method="dialog">
          <button
            class="btn btn-sm btn-circle btn-ghost absolute right-2 top-2"
            phx-click="close_edit_modal"
          >
            x
          </button>
        </form>

        <h3 class="text-lg font-bold">Edit Integration Source</h3>
        <p class="py-2 text-sm text-base-content/70">
          Update the integration source configuration.
        </p>

        <.form
          for={@form}
          id="edit_source_form"
          phx-change="validate_edit"
          phx-submit="update_source"
          class="space-y-4 mt-4"
        >
          <div class="grid grid-cols-2 gap-4">
            <.input field={@form[:name]} type="text" label="Name" required />
            <div class="form-control">
              <label class="label">
                <span class="label-text">Source Type</span>
              </label>
              <input
                type="text"
                class="input input-bordered w-full bg-base-200"
                value={@source.source_type}
                disabled
              />
            </div>
          </div>

          <.input
            field={@form[:endpoint]}
            type="text"
            label="Endpoint URL"
            required
          />

          <div class="grid grid-cols-2 gap-4">
            <.input
              field={@form[:partition]}
              type="select"
              label="Partition"
              options={@partition_options}
              prompt="Select a partition..."
            />

            <.input
              field={@form[:agent_id]}
              type="select"
              label="Agent"
              options={@agent_options}
              prompt="Auto-assign to any connected agent"
            />
          </div>

          <.input field={@form[:gateway_id]} type="text" label="Gateway ID (Optional)" />

          <div class="grid grid-cols-3 gap-4">
            <.input
              field={@form[:poll_interval_seconds]}
              type="number"
              label="Poll Interval (sec)"
            />

            <.input
              field={@form[:discovery_interval_seconds]}
              type="number"
              label="Discovery Interval (sec)"
            />

            <.input
              field={@form[:sweep_interval_seconds]}
              type="number"
              label="Sweep Interval (sec)"
            />
          </div>
          <p class="text-xs text-base-content/60 -mt-2">
            Poll: fetch updates • Discovery: full device scan • Sweep: network scan
          </p>

          <div class="divider text-xs text-base-content/60">Credentials</div>

          <.dynamic_credentials_fields
            form={@form}
            source_type={(@source && @source.source_type) || :armis}
            mode={:edit}
          />

          <div class="divider text-xs text-base-content/60">Queries</div>

          <div class="space-y-3">
            <%= for query <- @form_queries do %>
              <div class="p-3 bg-base-200 rounded-lg space-y-2">
                <div class="flex items-center justify-between">
                  <span class="text-xs font-semibold text-base-content/60">Query</span>
                  <button
                    type="button"
                    class="btn btn-ghost btn-xs text-error"
                    phx-click="remove_query"
                    phx-value-id={query["id"]}
                  >
                    <.icon name="hero-trash" class="size-3" /> Remove
                  </button>
                </div>
                <div class="grid grid-cols-2 gap-2">
                  <div class="form-control">
                    <label class="label py-1">
                      <span class="label-text text-xs">Label</span>
                    </label>
                    <input
                      type="text"
                      class="input input-bordered input-sm w-full"
                      placeholder="e.g., all_devices"
                      value={query["label"]}
                      phx-blur="update_query"
                      phx-value-id={query["id"]}
                      phx-value-field="label"
                    />
                  </div>
                  <div class="form-control">
                    <label class="label py-1">
                      <span class="label-text text-xs">Query (AQL)</span>
                    </label>
                    <input
                      type="text"
                      class="input input-bordered input-sm w-full font-mono"
                      placeholder="in:devices"
                      value={query["query"]}
                      phx-blur="update_query"
                      phx-value-id={query["id"]}
                      phx-value-field="query"
                    />
                  </div>
                </div>
              </div>
            <% end %>

            <button
              type="button"
              class="btn btn-outline btn-sm w-full"
              phx-click="add_query"
            >
              <.icon name="hero-plus" class="size-4" /> Add Query
            </button>
          </div>

          <%= if shows_network_blacklist?(@source && @source.source_type) do %>
            <div class="divider text-xs text-base-content/60">Network Settings</div>

            <div class="form-control">
              <label class="label">
                <span class="label-text">Network Blacklist</span>
              </label>
              <textarea
                name="network_blacklist_text"
                class="textarea textarea-bordered w-full font-mono text-sm"
                rows="3"
                placeholder="10.0.0.0/8&#10;172.16.0.0/12&#10;192.168.0.0/16"
                phx-blur="update_network_blacklist"
              ><%= @form_network_blacklist %></textarea>
              <label class="label">
                <span class="label-text-alt text-base-content/60">
                  One CIDR per line - networks to exclude from discovery
                </span>
              </label>
            </div>
          <% end %>

          <div class="modal-action">
            <button type="button" class="btn" phx-click="close_edit_modal">Cancel</button>
            <button type="submit" class="btn btn-primary">Update Source</button>
          </div>
        </.form>
      </div>
      <form method="dialog" class="modal-backdrop">
        <button phx-click="close_edit_modal">close</button>
      </form>
    </dialog>
    """
  end

  defp details_modal(assigns) do
    ~H"""
    <dialog id="details_modal" class="modal modal-open">
      <div class="modal-box max-w-2xl">
        <form method="dialog">
          <button
            class="btn btn-sm btn-circle btn-ghost absolute right-2 top-2"
            phx-click="close_details_modal"
          >
            x
          </button>
        </form>

        <h3 class="text-lg font-bold">Integration Source Details</h3>

        <div class="mt-4 space-y-4">
          <div class="grid grid-cols-2 gap-4">
            <div>
              <div class="text-xs uppercase tracking-wide text-base-content/60">Name</div>
              <div class="font-medium">{@source.name}</div>
            </div>
            <div>
              <div class="text-xs uppercase tracking-wide text-base-content/60">Status</div>
              <.status_badge enabled={@source.enabled} result={@source.last_sync_result} />
            </div>
            <div>
              <div class="text-xs uppercase tracking-wide text-base-content/60">Type</div>
              <.source_type_badge type={@source.source_type} />
            </div>
            <div>
              <div class="text-xs uppercase tracking-wide text-base-content/60">Poll Interval</div>
              <div>{format_interval(@source.poll_interval_seconds)}</div>
            </div>
          </div>

          <div>
            <div class="text-xs uppercase tracking-wide text-base-content/60 mb-1">Endpoint</div>
            <code class="text-sm font-mono bg-base-200 p-2 rounded block">{@source.endpoint}</code>
          </div>

          <div>
            <div class="text-xs uppercase tracking-wide text-base-content/60 mb-1">Source ID</div>
            <code class="text-sm font-mono bg-base-200 p-2 rounded block">{@source.id}</code>
          </div>

          <%= if @source.partition do %>
            <div>
              <div class="text-xs uppercase tracking-wide text-base-content/60 mb-1">Partition</div>
              <code class="text-sm font-mono bg-base-200 p-2 rounded block">{@source.partition}</code>
            </div>
          <% end %>

          <%= if @source.agent_id && @source.agent_id != "" do %>
            <div>
              <div class="text-xs uppercase tracking-wide text-base-content/60 mb-1">Agent ID</div>
              <% agent = Map.get(@agent_index, @source.agent_id) %>
              <div class="flex flex-col gap-2">
                <code class="text-sm font-mono bg-base-200 p-2 rounded block">
                  {@source.agent_id}
                </code>
                <%= if agent do %>
                  <.agent_status_badge agent={agent} />
                <% else %>
                  <.ui_badge variant="ghost" size="xs">Unknown</.ui_badge>
                <% end %>
              </div>
            </div>
          <% end %>

          <%= if @source.gateway_id do %>
            <div>
              <div class="text-xs uppercase tracking-wide text-base-content/60 mb-1">Gateway ID</div>
              <code class="text-sm font-mono bg-base-200 p-2 rounded block">
                {@source.gateway_id}
              </code>
            </div>
          <% end %>

          <div class="divider">Sync Statistics</div>

          <div class="grid grid-cols-3 gap-4">
            <div class="stat bg-base-200 rounded-lg p-3">
              <div class="stat-title text-xs">Total Syncs</div>
              <div class="stat-value text-lg">{@source.total_syncs || 0}</div>
            </div>
            <div class="stat bg-base-200 rounded-lg p-3">
              <div class="stat-title text-xs">Last Device Count</div>
              <div class="stat-value text-lg">{@source.last_device_count || 0}</div>
            </div>
            <div class="stat bg-base-200 rounded-lg p-3">
              <div class="stat-title text-xs">Consecutive Failures</div>
              <div class="stat-value text-lg">{@source.consecutive_failures || 0}</div>
            </div>
          </div>

          <%= if @source.last_sync_at do %>
            <div>
              <div class="text-xs uppercase tracking-wide text-base-content/60 mb-1">Last Sync</div>
              <div class="text-sm">{format_datetime(@source.last_sync_at)}</div>
            </div>
          <% end %>

          <%= if @source.enabled && is_nil(@source.last_sync_at) do %>
            <div class="alert alert-info text-sm">
              <.icon name="hero-information-circle" class="size-5" />
              <div>
                <div class="font-medium">This source has never run.</div>
                <div class="text-xs text-base-content/70">
                  Confirm the assigned agent is connected and the sync runtime is enabled.
                </div>
              </div>
            </div>
          <% end %>

          <%= if @source.last_error_message do %>
            <div class="alert alert-error text-sm">
              <.icon name="hero-exclamation-circle" class="size-5" />
              <span>{@source.last_error_message}</span>
            </div>
          <% end %>
        </div>

        <div class="modal-action">
          <button
            type="button"
            class="btn btn-error btn-outline"
            phx-click="delete_source"
            phx-value-id={@source.id}
            data-confirm="Are you sure you want to delete this integration source? This cannot be undone."
          >
            Delete
          </button>
          <.ui_button
            variant="ghost"
            navigate={~p"/settings/networks/integrations/#{@source.id}/edit"}
          >
            Edit
          </.ui_button>
          <button type="button" class="btn" phx-click="close_details_modal">Close</button>
        </div>
      </div>
      <form method="dialog" class="modal-backdrop">
        <button phx-click="close_details_modal">close</button>
      </form>
    </dialog>
    """
  end

  defp source_type_badge(assigns) do
    variant =
      case assigns.type do
        :armis -> "info"
        :snmp -> "success"
        :syslog -> "warning"
        :netbox -> "info"
        :nmap -> "error"
        :custom -> "ghost"
        _ -> "ghost"
      end

    assigns = assign(assigns, :variant, variant)

    ~H"""
    <.ui_badge variant={@variant} size="xs">{@type}</.ui_badge>
    """
  end

  defp status_badge(assigns) do
    {variant, label} =
      cond do
        not assigns.enabled -> {"ghost", "Disabled"}
        assigns.result == :success -> {"success", "Healthy"}
        assigns.result == :partial -> {"warning", "Partial"}
        assigns.result in [:failed, :timeout] -> {"error", "Failed"}
        is_nil(assigns.result) -> {"info", "Never Run"}
        true -> {"ghost", "Unknown"}
      end

    assigns = assigns |> assign(:variant, variant) |> assign(:label, label)

    ~H"""
    <.ui_badge variant={@variant} size="xs">{@label}</.ui_badge>
    """
  end

  defp format_datetime(nil), do: "-"

  defp format_datetime(%DateTime{} = dt) do
    Calendar.strftime(dt, "%Y-%m-%d %H:%M")
  end

  defp format_interval(nil), do: "5 minutes"

  defp format_interval(seconds) when is_integer(seconds) do
    cond do
      seconds >= 3600 -> "#{div(seconds, 3600)} hour(s)"
      seconds >= 60 -> "#{div(seconds, 60)} minute(s)"
      true -> "#{seconds} second(s)"
    end
  end

  # Data access helpers

  defp list_partitions(actor) do
    Partition
    |> Ash.Query.for_read(:enabled)
    |> Ash.read!(actor: actor)
  rescue
    _ -> []
  end

  defp build_partition_options(partitions) do
    # Always include a "default" option for agents that haven't been assigned
    default_option = [{"Default", "default"}]

    partition_options =
      partitions
      |> Enum.map(fn p -> {p.name || p.slug, p.slug} end)
      |> Enum.sort_by(&elem(&1, 0))

    default_option ++ partition_options
  end

  defp list_agents(actor) do
    Agent
    |> Ash.Query.for_read(:read)
    |> Ash.Query.sort([:name, :uid])
    |> Ash.read(actor: actor)
    |> case do
      {:ok, %Keyset{results: results}} -> results
      {:ok, results} when is_list(results) -> results
      _ -> []
    end
  rescue
    _ -> []
  end

  defp build_agent_options(agents) do
    agents
    |> Enum.map(fn agent ->
      label = "#{agent_display_name(agent, agent.uid)} - #{agent_status_label(agent)}"
      {label, agent.uid}
    end)
    |> Enum.sort_by(&elem(&1, 0))
  end

  defp build_agent_index(agents) do
    Map.new(agents, fn agent -> {agent.uid, agent} end)
  end

  defp list_sources(actor, filters \\ %{}) do
    case Map.get(filters, :source_type) do
      nil ->
        IntegrationSource
        |> Ash.Query.for_read(:read)
        |> maybe_filter_enabled(filters)
        |> Ash.read!(actor: actor)

      type ->
        type_atom = if is_binary(type), do: String.to_existing_atom(type), else: type

        IntegrationSource
        |> Ash.Query.for_read(:by_type, %{source_type: type_atom})
        |> maybe_filter_enabled(filters)
        |> Ash.read!(actor: actor)
    end
  rescue
    _ -> []
  end

  defp sync_agent_available?(actor) do
    Agent
    |> Ash.Query.for_read(:connected)
    |> Ash.Query.limit(1)
    |> Ash.read(actor: actor)
    |> case do
      {:ok, %Keyset{results: results}} -> results != []
      {:ok, results} when is_list(results) -> results != []
      _ -> false
    end
  rescue
    _ -> false
  end

  defp maybe_filter_enabled(query, %{enabled: value}) when is_boolean(value) do
    require Ash.Query

    Ash.Query.filter(query, enabled: value)
  end

  defp maybe_filter_enabled(query, _), do: query

  defp get_source(id, actor) do
    IntegrationSource.get_by_id(id, actor: actor)
  end

  defp build_create_form(actor) do
    IntegrationSource
    |> AshPhoenix.Form.for_create(:create,
      domain: Integrations,
      actor: actor,
      transform_params: fn _form, params, _action ->
        # Convert source_type string to atom
        params =
          case params["source_type"] do
            type when is_binary(type) and type != "" ->
              Map.put(params, "source_type", String.to_existing_atom(type))

            _ ->
              params
          end

        normalize_optional_params(params)
      end
    )
    |> to_form()
  end

  defp build_edit_form(source, actor) do
    source
    |> AshPhoenix.Form.for_update(:update,
      domain: Integrations,
      actor: actor,
      transform_params: fn _form, params, _action ->
        normalize_optional_params(params)
      end
    )
    |> to_form()
  end

  defp normalize_optional_params(params) do
    params
    |> normalize_blank_param("agent_id")
    |> normalize_blank_param("gateway_id")
    |> normalize_blank_param("partition")
  end

  defp normalize_blank_param(params, key) do
    case Map.get(params, key) do
      "" -> Map.put(params, key, nil)
      _ -> params
    end
  end

  # Parse credentials from either structured fields or JSON
  # Structured fields take precedence over JSON
  defp parse_credentials_json(params) do
    cond do
      # Armis: api_key + api_secret
      has_cred_field?(params, "cred_api_key") or has_cred_field?(params, "cred_api_secret") ->
        creds = %{}
        creds = maybe_add_cred(creds, "api_key", params["cred_api_key"])
        creds = maybe_add_cred(creds, "api_secret", params["cred_api_secret"])

        if map_size(creds) > 0 do
          Map.put(params, "credentials", creds)
        else
          params
        end

      # SNMP: version + community
      has_cred_field?(params, "cred_snmp_version") or has_cred_field?(params, "cred_community") ->
        creds = %{}
        creds = maybe_add_cred(creds, "version", params["cred_snmp_version"])
        creds = maybe_add_cred(creds, "community", params["cred_community"])

        if map_size(creds) > 0 do
          Map.put(params, "credentials", creds)
        else
          params
        end

      # Netbox: url + token + verify_ssl
      has_cred_field?(params, "cred_netbox_url") or has_cred_field?(params, "cred_netbox_token") ->
        creds = %{}
        creds = maybe_add_cred(creds, "url", params["cred_netbox_url"])
        creds = maybe_add_cred(creds, "token", params["cred_netbox_token"])
        creds = maybe_add_cred(creds, "verify_ssl", params["cred_netbox_verify_ssl"] == "true")

        if map_size(creds) > 0 do
          Map.put(params, "credentials", creds)
        else
          params
        end

      # Fallback to JSON parsing for custom/other types
      true ->
        parse_json_field(params, "credentials_json", "credentials")
    end
  end

  defp has_cred_field?(params, key) do
    case Map.get(params, key) do
      nil -> false
      "" -> false
      _ -> true
    end
  end

  defp maybe_add_cred(creds, _key, nil), do: creds
  defp maybe_add_cred(creds, _key, ""), do: creds
  defp maybe_add_cred(creds, key, value), do: Map.put(creds, key, value)

  defp parse_json_field(params, json_key, target_key) do
    case Map.get(params, json_key) do
      json when is_binary(json) and json != "" ->
        case Jason.decode(json) do
          {:ok, decoded} -> Map.put(params, target_key, decoded)
          {:error, _} -> params
        end

      _ ->
        params
    end
  end

  # Convert form_queries assign to format expected by the API
  defp build_queries_for_submit(form_queries) do
    form_queries
    |> Enum.filter(fn q ->
      # Only include queries with at least a label or query text
      (q["label"] && q["label"] != "") || (q["query"] && q["query"] != "")
    end)
    |> Enum.map(fn q ->
      %{
        "label" => q["label"] || "",
        "query" => q["query"] || "",
        "sweep_modes" => q["sweep_modes"] || []
      }
    end)
  end

  # Convert network blacklist textarea (one CIDR per line) to array
  defp parse_network_blacklist(text) when is_binary(text) do
    text
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp parse_network_blacklist(_), do: []

  # Source types that support network blacklist (discovery-based integrations)
  defp shows_network_blacklist?(:armis), do: true
  defp shows_network_blacklist?(:netbox), do: true
  defp shows_network_blacklist?(:nmap), do: true
  defp shows_network_blacklist?(:custom), do: true
  defp shows_network_blacklist?("armis"), do: true
  defp shows_network_blacklist?("netbox"), do: true
  defp shows_network_blacklist?("nmap"), do: true
  defp shows_network_blacklist?("custom"), do: true
  defp shows_network_blacklist?(_), do: false

  defp agent_display_name(nil, fallback), do: fallback || "Unknown"
  defp agent_display_name(agent, _fallback), do: agent.name || agent.uid

  defp agent_status_label(agent) do
    cond do
      agent.status == :connected and agent.is_healthy -> "Connected"
      agent.status == :connected -> "Unhealthy"
      agent.status == :degraded -> "Degraded"
      agent.status == :disconnected -> "Disconnected"
      agent.status == :unavailable -> "Unavailable"
      agent.status == :connecting -> "Connecting"
      true -> "Unknown"
    end
  end

  defp agent_status_variant(agent) do
    cond do
      agent.status == :connected and agent.is_healthy -> "success"
      agent.status == :connected -> "warning"
      agent.status == :degraded -> "warning"
      agent.status == :disconnected -> "error"
      agent.status == :unavailable -> "error"
      agent.status == :connecting -> "info"
      true -> "ghost"
    end
  end

  defp agent_status_badge(assigns) do
    variant = agent_status_variant(assigns.agent)
    label = agent_status_label(assigns.agent)
    assigns = assigns |> assign(:variant, variant) |> assign(:label, label)

    ~H"""
    <.ui_badge variant={@variant} size="xs">{@label}</.ui_badge>
    """
  end

  defp get_actor(socket) do
    case socket.assigns[:current_scope] do
      %{user: user} when not is_nil(user) -> user
      _ -> nil
    end
  end

  # Dynamic credential fields based on source type
  attr(:form, :any, required: true)
  attr(:source_type, :atom, required: true)
  attr(:mode, :atom, default: :create)

  defp dynamic_credentials_fields(assigns) do
    ~H"""
    <%= case @source_type do %>
      <% :armis -> %>
        <div class="space-y-3">
          <div class="form-control">
            <label class="label">
              <span class="label-text">API Key</span>
            </label>
            <input
              type="text"
              name="cred_api_key"
              class="input input-bordered w-full font-mono text-sm"
              placeholder="Enter your Armis API key"
            />
          </div>
          <div class="form-control">
            <label class="label">
              <span class="label-text">API Secret</span>
            </label>
            <input
              type="password"
              name="cred_api_secret"
              class="input input-bordered w-full font-mono text-sm"
              placeholder={
                if @mode == :edit,
                  do: "Leave empty to keep existing",
                  else: "Enter your Armis API secret"
              }
            />
          </div>
          <label class="label">
            <span class="label-text-alt text-base-content/60">
              Credentials will be encrypted at rest
            </span>
          </label>
        </div>
      <% :snmp -> %>
        <div class="space-y-3">
          <div class="grid grid-cols-2 gap-3">
            <div class="form-control">
              <label class="label">
                <span class="label-text">SNMP Version</span>
              </label>
              <select name="cred_snmp_version" class="select select-bordered w-full">
                <option value="v2c">SNMPv2c</option>
                <option value="v3">SNMPv3</option>
              </select>
            </div>
            <div class="form-control">
              <label class="label">
                <span class="label-text">Community String</span>
              </label>
              <input
                type="password"
                name="cred_community"
                class="input input-bordered w-full font-mono text-sm"
                placeholder={
                  if @mode == :edit, do: "Leave empty to keep existing", else: "e.g., public"
                }
              />
            </div>
          </div>
          <label class="label">
            <span class="label-text-alt text-base-content/60">
              For SNMPv3, use the SNMP Profiles section under Network settings
            </span>
          </label>
        </div>
      <% :netbox -> %>
        <div class="space-y-3">
          <div class="form-control">
            <label class="label">
              <span class="label-text">Netbox URL</span>
            </label>
            <input
              type="url"
              name="cred_netbox_url"
              class="input input-bordered w-full font-mono text-sm"
              placeholder="https://netbox.example.com"
            />
            <label class="label">
              <span class="label-text-alt text-base-content/60">
                Full URL to your Netbox instance (including https://)
              </span>
            </label>
          </div>
          <div class="form-control">
            <label class="label">
              <span class="label-text">API Token</span>
            </label>
            <input
              type="password"
              name="cred_netbox_token"
              class="input input-bordered w-full font-mono text-sm"
              placeholder={
                if @mode == :edit,
                  do: "Leave empty to keep existing",
                  else: "Enter your Netbox API token"
              }
            />
            <label class="label">
              <span class="label-text-alt text-base-content/60">
                Generate a token in Netbox: Admin → API Tokens
              </span>
            </label>
          </div>
          <div class="form-control">
            <label class="label">
              <span class="label-text">Verify SSL</span>
            </label>
            <select name="cred_netbox_verify_ssl" class="select select-bordered w-full">
              <option value="true">Yes (recommended)</option>
              <option value="false">No (for self-signed certs)</option>
            </select>
          </div>
        </div>
      <% :custom -> %>
        <div class="space-y-3">
          <div class="form-control">
            <label class="label">
              <span class="label-text">Credentials (JSON)</span>
            </label>
            <textarea
              name="credentials_json"
              class="textarea textarea-bordered w-full font-mono text-sm"
              rows="3"
              placeholder='{"api_key": "your-key", "api_secret": "your-secret"}'
            ></textarea>
            <label class="label">
              <span class="label-text-alt text-base-content/60">
                {if @mode == :edit, do: "Leave empty to keep existing credentials. ", else: ""}Credentials will be encrypted at rest
              </span>
            </label>
          </div>
        </div>
      <% _ -> %>
        <div class="space-y-3">
          <div class="form-control">
            <label class="label">
              <span class="label-text">Credentials (JSON)</span>
            </label>
            <textarea
              name="credentials_json"
              class="textarea textarea-bordered w-full font-mono text-sm"
              rows="3"
              placeholder={credential_placeholder(@source_type)}
            ></textarea>
            <label class="label">
              <span class="label-text-alt text-base-content/60">
                {if @mode == :edit, do: "Leave empty to keep existing credentials. ", else: ""}Credentials will be encrypted at rest
              </span>
            </label>
          </div>
        </div>
    <% end %>
    """
  end

  defp credential_placeholder(:syslog), do: ~s({"syslog_host": "0.0.0.0", "syslog_port": 514})

  defp credential_placeholder(:netbox), do: ~s({"url": "https://netbox.example.com", "token": "your-api-token"})

  defp credential_placeholder(:nmap), do: ~s({"timing_template": "T4", "extra_args": ""})
  defp credential_placeholder(_), do: ~s({"api_key": "your-key", "api_secret": "your-secret"})
end
