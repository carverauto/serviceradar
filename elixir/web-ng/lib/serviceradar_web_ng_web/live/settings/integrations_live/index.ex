defmodule ServiceRadarWebNGWeb.Settings.IntegrationsLive.Index do
  @moduledoc """
  LiveView for managing integration sources (Armis, SNMP, etc.).

  Integration sources are stored in Postgres and delivered to sync services
  via gateway-config updates.
  """
  use ServiceRadarWebNGWeb, :live_view

  alias Ash.Page.Keyset
  alias ServiceRadar.AgentConfig.DependencyDiagnostics
  alias ServiceRadar.CompositeChecks.CompositeCheck
  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.Infrastructure.Partition
  alias ServiceRadar.Integrations
  alias ServiceRadar.Integrations.ArmisNorthboundLedger
  alias ServiceRadar.Integrations.ArmisNorthboundRunWorker
  alias ServiceRadar.Integrations.IntegrationSource
  alias ServiceRadar.Integrations.IntegrationUpdateRun
  alias ServiceRadar.Integrations.MapboxSettings
  alias ServiceRadarWebNG.RBAC
  alias ServiceRadarWebNGWeb.Settings.Shell

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
        |> assign(:available_credentials, list_available_credentials(actor))
        |> assign(:partitions, partitions)
        |> assign(:partition_options, build_partition_options(partitions))
        |> assign(:agents, agents)
        |> assign(:agent_index, agent_index)
        |> assign(:agent_options, agent_options)
        |> assign(:composite_check_options, composite_check_options(socket))
        |> assign(:sync_agent_available, sync_agent_available)
        |> assign(:show_create_modal, false)
        |> assign(:show_edit_modal, false)
        |> assign(:show_details_modal, false)
        |> assign(:selected_source, nil)
        |> assign(:selected_source_runs, [])
        |> assign(:selected_source_target_examples, [])
        |> assign(:selected_source_config_diagnostics, [])
        |> assign(:create_form, build_create_form(actor))
        |> assign(:edit_form, nil)
        |> assign(:filter_type, nil)
        |> assign(:filter_enabled, nil)
        # Query management for forms
        |> assign(:form_queries, [default_query()])
        |> assign(:form_network_blacklist, "")
        |> assign(:form_custom_fields, "")
        |> assign(:mapbox_settings, load_mapbox_settings(actor))
        |> assign(:mapbox_form, mapbox_settings_to_form(load_mapbox_settings(actor)))
        |> assign(:prefix_tag_preview_ip, "")
        |> assign(:prefix_tag_preview_result, nil)
        |> assign(:prefix_tag_preview_error, nil)

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
        runs = list_recent_update_runs(source.id, actor)

        socket
        |> assign(:selected_source, source)
        |> assign(:selected_source_runs, runs)
        |> assign(:selected_source_target_examples, list_target_examples(runs))
        |> assign(:selected_source_config_diagnostics, list_config_diagnostics(source.id))
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
        form_custom_fields = Enum.join(source.custom_fields || [], ", ")

        socket
        |> assign(:selected_source, source)
        |> assign(:edit_form, build_edit_form(source, actor))
        |> assign(:form_queries, form_queries)
        |> assign(:form_network_blacklist, form_blacklist)
        |> assign(:form_custom_fields, form_custom_fields)
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
       |> assign(:composite_check_options, composite_check_options(socket))
       |> assign(:form_queries, [default_query()])
       |> assign(:form_network_blacklist, "")
       |> assign(:form_custom_fields, "")}
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

  def handle_event("prefix_tag_preview", params, socket) do
    # Rebuild current authority — cached mount permissions are not evidence.
    case RBAC.authorize_current(socket.assigns.current_scope, ["settings.integrations.manage"]) do
      {:error, _} ->
        {:noreply,
         socket
         |> put_flash(:error, "Not authorized to manage integrations")
         |> redirect(to: ~p"/settings/profile")}

      {:ok, scope} ->
        socket = assign(socket, :current_scope, scope)

        ip =
          params
          |> Map.get("ip", params |> Map.get("prefix_tag_preview", %{}) |> Map.get("ip", ""))
          |> to_string()
          |> String.trim()

        if ip == "" do
          {:noreply,
           socket
           |> assign(:prefix_tag_preview_ip, "")
           |> assign(:prefix_tag_preview_result, nil)
           |> assign(:prefix_tag_preview_error, "Enter an IP address")}
        else
          case preview_prefix_tags(ip) do
            {:ok, chain} ->
              {:noreply,
               socket
               |> assign(:prefix_tag_preview_ip, ip)
               |> assign(:prefix_tag_preview_result, chain)
               |> assign(:prefix_tag_preview_error, nil)}

            {:error, reason} ->
              {:noreply,
               socket
               |> assign(:prefix_tag_preview_ip, ip)
               |> assign(:prefix_tag_preview_result, nil)
               |> assign(:prefix_tag_preview_error, reason)}
          end
        end
    end
  end

  def handle_event("close_create_modal", _params, socket) do
    actor = get_actor(socket)

    {:noreply,
     socket
     |> assign(:show_create_modal, false)
     |> assign(:create_form, build_create_form(actor))
     |> assign(:form_queries, [default_query()])
     |> assign(:form_network_blacklist, "")
     |> assign(:form_custom_fields, "")}
  end

  def handle_event("close_edit_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_edit_modal, false)
     |> assign(:selected_source, nil)
     |> assign(:edit_form, nil)
     |> assign(:form_queries, [default_query()])
     |> assign(:form_network_blacklist, "")
     |> assign(:form_custom_fields, "")}
  end

  def handle_event("close_details_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_details_modal, false)
     |> assign(:selected_source, nil)
     |> assign(:selected_source_runs, [])
     |> assign(:selected_source_target_examples, [])
     |> assign(:selected_source_config_diagnostics, [])}
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

  def handle_event("update_custom_fields", params, socket) do
    value = params["value"] || params["custom_fields_text"] || ""
    {:noreply, assign(socket, :form_custom_fields, value)}
  end

  def handle_event("create_source", %{"form" => form_params} = event_params, socket) do
    actor = get_actor(socket)

    if sync_agent_available?(actor) do
      # Handle credentials JSON if provided
      params =
        form_params
        |> merge_auxiliary_form_params(event_params)
        |> parse_credentials_json()

      # Add queries from form_queries assign
      queries = build_queries_for_submit(socket.assigns.form_queries)
      params = Map.put(params, "queries", queries)

      # Add network_blacklist from textarea
      blacklist =
        parse_network_blacklist(Map.get(params, "network_blacklist_text", socket.assigns.form_network_blacklist))

      params = Map.put(params, "network_blacklist", blacklist)
      params = put_composite_setting(params, %{})
      params = put_fact_authority_setting(params)

      params =
        Map.put(
          params,
          "custom_fields",
          parse_custom_fields(Map.get(params, "custom_fields_text", socket.assigns.form_custom_fields))
        )

      form = AshPhoenix.Form.validate(socket.assigns.create_form.source, params)

      case AshPhoenix.Form.submit(form, params: params, actor: actor) do
        {:ok, source} ->
          _ = sync_fact_authority(source, params, actor)

          {:noreply,
           socket
           |> assign(:show_create_modal, false)
           |> assign(:sources, list_sources(actor))
           |> assign(:create_form, build_create_form(actor))
           |> assign(:form_custom_fields, "")
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

  def handle_event("update_source", %{"form" => form_params} = event_params, socket) do
    actor = get_actor(socket)
    existing_credentials = source_credentials(socket.assigns.selected_source)

    # Handle credentials JSON if provided
    params =
      form_params
      |> merge_auxiliary_form_params(event_params)
      |> parse_credentials_json(existing_credentials)

    # Add queries from form_queries assign
    queries = build_queries_for_submit(socket.assigns.form_queries)
    params = Map.put(params, "queries", queries)

    # Add network_blacklist from textarea
    blacklist =
      parse_network_blacklist(Map.get(params, "network_blacklist_text", socket.assigns.form_network_blacklist))

    params = Map.put(params, "network_blacklist", blacklist)
    params = put_composite_setting(params, Map.get(socket.assigns.selected_source || %{}, :settings))
    params = put_fact_authority_setting(params)

    params =
      Map.put(
        params,
        "custom_fields",
        parse_custom_fields(Map.get(params, "custom_fields_text", socket.assigns.form_custom_fields))
      )

    form = AshPhoenix.Form.validate(socket.assigns.edit_form.source, params)

    case AshPhoenix.Form.submit(form, params: params, actor: actor) do
      {:ok, source} ->
        _ = sync_fact_authority(source, params, actor)

        {:noreply,
         socket
         |> assign(:show_edit_modal, false)
         |> assign(:selected_source, nil)
         |> assign(:edit_form, nil)
         |> assign(:sources, list_sources(actor))
         |> assign(:form_queries, [default_query()])
         |> assign(:form_network_blacklist, "")
         |> assign(:form_custom_fields, "")
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
             |> assign(:sources, list_sources(actor, active_filters(socket)))
             |> assign(
               :selected_source,
               refresh_selected_source(socket.assigns.selected_source, actor)
             )
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
             |> put_flash(:info, "Integration source deleted")
             |> assign(:sources, list_sources(actor, active_filters(socket)))
             |> assign(:show_details_modal, false)
             |> assign(:show_edit_modal, false)
             |> assign(:selected_source, nil)
             |> push_navigate(to: ~p"/settings/networks/integrations")}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Failed to delete source: #{format_ash_error(reason)}")}
        end

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Integration source not found")}
    end
  end

  def handle_event("run_northbound_now", %{"id" => id}, socket) do
    actor = get_actor(socket)

    case get_source(id, actor) do
      {:ok, %{source_type: :armis} = source} ->
        case ArmisNorthboundRunWorker.enqueue_now(source.id) do
          {:ok, _job} ->
            refreshed = refresh_selected_source(socket.assigns.selected_source, actor)
            runs = list_recent_update_runs(source.id, actor)

            {:noreply,
             socket
             |> put_flash(:info, "Queued Armis northbound run for #{source.name}")
             |> assign(:selected_source, refreshed)
             |> assign(:selected_source_runs, runs)
             |> assign(:selected_source_target_examples, list_target_examples(runs))
             |> assign(:sources, list_sources(actor, active_filters(socket)))}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Failed to queue Armis northbound run: #{inspect(reason)}")}
        end

      {:ok, _source} ->
        {:noreply, put_flash(socket, :error, "Northbound run is only available for Armis sources")}

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

  defp preview_prefix_tags(ip) when is_binary(ip) do
    # Local trie only — no DB hop. Failures are soft (empty chain / error string).
    chain = ServiceRadar.PrefixTags.Store.lookup(ip)
    {:ok, chain}
  rescue
    e -> {:error, Exception.message(e)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_path="/settings/networks/integrations"
      page_title={@page_title}
    >
      <Shell.settings_chrome
        current_path="/settings/networks/integrations"
        current_scope={@current_scope}
        active_view={@settings_active_view}
        active_category={@settings_active_category}
        breadcrumbs={@settings_breadcrumbs}
        nav_tree={@settings_nav_tree}
        palette={@settings_palette}
        stats={@settings_stats}
      >
        <div class="flex flex-wrap items-center justify-between gap-4">
          <div>
            <h1 class="text-2xl font-semibold text-sr-ink">Integration Sources</h1>
            <p class="text-sm text-sr-muted">
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
              <p class="text-xs text-sr-muted">
                Register an agent before adding integrations.
              </p>
            <% end %>
          </div>
        </div>

        <div class="mt-4">
          <div class="sr-ui-tabs sr-ui-tabs-boxed">
            <.link
              patch={~p"/settings/networks/integrations?tab=crm_ipam"}
              class={["sr-ui-tab", @settings_tab == "crm_ipam" && "sr-ui-tab-active"]}
            >
              CRM/IPAM
            </.link>
            <.link
              patch={~p"/settings/networks/integrations?tab=mapbox"}
              class={["sr-ui-tab", @settings_tab == "mapbox" && "sr-ui-tab-active"]}
            >
              Mapbox
            </.link>
          </div>
        </div>

        <.ui_panel :if={@settings_tab == "crm_ipam"}>
          <:header>
            <div>
              <div class="text-sm font-semibold">Sources</div>
              <p class="text-xs text-sr-muted">
                {@sources |> length()} source(s)
              </p>
            </div>
            <div class="flex gap-2">
              <select
                name="source_type"
                class={ui_field_class(size: "sm")}
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
                class={ui_field_class(size: "sm")}
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
              <div class="rounded-xl border border-dashed border-sr-line bg-sr-surface p-8 text-center">
                <div class="text-sm font-semibold text-sr-ink">No integration sources</div>
                <p class="mt-1 text-xs text-sr-muted">
                  Create a new integration source to connect to external data sources.
                </p>
              </div>
            <% else %>
              <table class={ui_table_class(size: "sm")}>
                <thead>
                  <tr class="text-xs uppercase tracking-wide text-sr-muted">
                    <th>Name</th>
                    <th>Type</th>
                    <th>Partition</th>
                    <th>Agent</th>
                    <th>Endpoint</th>
                    <th>Discovery</th>
                    <th>Northbound</th>
                    <th></th>
                  </tr>
                </thead>
                <tbody>
                  <%= for source <- @sources do %>
                    <tr class="hover:bg-sr-subtle/30">
                      <td>
                        <div class="font-medium">{source.name}</div>
                        <div class="text-xs text-sr-muted font-mono">
                          {String.slice(source.id, 0, 8)}...
                        </div>
                      </td>
                      <td>
                        <.source_type_badge type={source.source_type} />
                      </td>
                      <td class="text-xs text-sr-muted">
                        {source.partition || "-"}
                      </td>
                      <td class="text-xs text-sr-muted">
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
                          <span class="text-xs text-sr-muted">Auto-assign</span>
                        <% end %>
                      </td>
                      <td class="text-xs text-sr-muted max-w-[200px] truncate">
                        {source.endpoint}
                      </td>
                      <td>
                        <.status_badge enabled={source.enabled} result={source.last_sync_result} />
                        <%= if error_message = visible_error_message(source.last_error_message) do %>
                          <div
                            class="text-xs text-error/80 max-w-[180px] truncate"
                            title={error_message}
                          >
                            {error_message}
                          </div>
                        <% end %>
                        <div class="mt-1 text-xs text-sr-muted">
                          <.user_time
                            id={"settings-integration-source-#{source.id}-last-sync-at"}
                            value={source.last_sync_at}
                            timezone={@current_scope.user.timezone || "Etc/UTC"}
                            style={:compact}
                            fallback="-"
                          />
                        </div>
                      </td>
                      <td>
                        <%= if armis_source?(source) do %>
                          <.northbound_status_badge
                            enabled={source.northbound_enabled}
                            status={source.northbound_status}
                            result={source.northbound_last_result}
                          />
                          <div class="mt-1 text-xs text-sr-muted">
                            <.user_time
                              id={"settings-integration-source-#{source.id}-northbound-last-run-at"}
                              value={source.northbound_last_run_at}
                              timezone={@current_scope.user.timezone || "Etc/UTC"}
                              style={:compact}
                              fallback="-"
                            />
                          </div>
                          <div class="mt-1 text-xs text-sr-muted">
                            {source.northbound_last_updated_count || 0} updated
                            <span class="mx-1">•</span>
                            {source.northbound_last_skipped_count || 0} skipped
                          </div>
                          <div class="mt-1 max-w-[180px] truncate text-xs text-sr-muted">
                            {availability_source_display(source)}
                          </div>
                          <%= if source.northbound_last_error_message do %>
                            <div
                              class="text-xs text-error/80 max-w-[180px] truncate"
                              title={source.northbound_last_error_message}
                            >
                              {source.northbound_last_error_message}
                            </div>
                          <% end %>
                        <% else %>
                          <span class="text-xs text-sr-muted">-</span>
                        <% end %>
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

        <.ui_panel :if={@settings_tab == "crm_ipam"}>
          <:header>
            <div>
              <div class="text-sm font-semibold">Prefix tag preview</div>
              <p class="text-xs text-sr-muted">
                Look up what tags an IP would receive from the local node's prefix-tag trie
                (same chain flow enrichment applies when enabled).
              </p>
            </div>
          </:header>

          <form phx-submit="prefix_tag_preview" class="flex flex-wrap items-end gap-2">
            <div class="grow min-w-48">
              <label class="text-xs uppercase tracking-wider text-sr-muted">IP address</label>
              <input
                type="text"
                name="ip"
                value={@prefix_tag_preview_ip}
                placeholder="10.1.2.3"
                class={ui_field_class(size: "sm", mono: true, class: "w-full")}
                autocomplete="off"
              />
            </div>
            <.ui_button type="submit" size="sm" variant="primary">Preview</.ui_button>
          </form>

          <div
            :if={@prefix_tag_preview_error}
            class={ui_alert_class(variant: "warning", class: "mt-3 text-sm")}
          >
            {@prefix_tag_preview_error}
          </div>

          <div :if={is_list(@prefix_tag_preview_result)} class="mt-3 space-y-2">
            <%= if @prefix_tag_preview_result == [] do %>
              <p class="text-sm text-sr-muted">No matching prefixes for this address.</p>
            <% else %>
              <div class="text-xs uppercase tracking-wider text-sr-muted">
                Most-specific first
              </div>
              <div class="space-y-2">
                <div
                  :for={match <- @prefix_tag_preview_result}
                  class="rounded-lg border border-sr-line bg-sr-subtle/30 p-2"
                >
                  <div class="font-mono text-xs text-sr-muted">
                    {Map.get(match, :prefix) || Map.get(match, "prefix") || "—"}
                    <.ui_badge
                      :if={src = Map.get(match, :source) || Map.get(match, "source")}
                      size="xs"
                      variant="ghost"
                      class="ml-2"
                    >
                      {src}
                    </.ui_badge>
                  </div>
                  <div class="mt-1 flex flex-wrap gap-1">
                    <.ui_badge
                      :for={
                        tag <-
                          List.wrap(Map.get(match, :tags) || Map.get(match, "tags") || [])
                      }
                      size="xs"
                      variant="outline"
                      class="font-mono"
                    >
                      {tag}
                    </.ui_badge>
                  </div>
                </div>
              </div>
            <% end %>
          </div>
        </.ui_panel>

        <.ui_panel :if={@settings_tab == "mapbox"}>
          <:header>
            <div>
              <div class="text-sm font-semibold">Mapbox</div>
              <p class="text-xs text-sr-muted">
                Configure the Mapbox token and map styles used for flow maps and dashboard packages.
              </p>
            </div>
          </:header>

          <%= if @mapbox_form do %>
            <form phx-submit="mapbox_save" class="space-y-4">
              <label class="flex items-center gap-2 text-sm">
                <input
                  type="checkbox"
                  class={ui_toggle_class()}
                  name="mapbox[enabled]"
                  value="true"
                  checked={truthy_param?(Map.get(@mapbox_form.source, "enabled"))}
                />
                <span>Enable Mapbox maps</span>
              </label>

              <div class="grid grid-cols-1 lg:grid-cols-2 gap-4">
                <div>
                  <div class="text-xs uppercase tracking-wider text-sr-muted mb-1">
                    Style (Light)
                  </div>
                  <input
                    type="text"
                    name="mapbox[style_light]"
                    value={
                      Map.get(@mapbox_form.source, "style_light") ||
                        "mapbox://styles/mapbox/light-v11"
                    }
                    class={ui_field_class(class: "w-full")}
                    placeholder="mapbox://styles/..."
                  />
                </div>
                <div>
                  <div class="text-xs uppercase tracking-wider text-sr-muted mb-1">
                    Style (Dark)
                  </div>
                  <input
                    type="text"
                    name="mapbox[style_dark]"
                    value={
                      Map.get(@mapbox_form.source, "style_dark") || "mapbox://styles/mapbox/dark-v11"
                    }
                    class={ui_field_class(class: "w-full")}
                    placeholder="mapbox://styles/..."
                  />
                </div>
              </div>

              <div>
                <div class="text-xs uppercase tracking-wider text-sr-muted mb-1">
                  Access token
                </div>
                <input
                  type="password"
                  name="mapbox[access_token]"
                  value=""
                  class={ui_field_class(mono: true, class: "w-full")}
                  placeholder="pk.... (leave blank to keep existing)"
                  autocomplete="off"
                />
                <div class="mt-1 flex items-center gap-2 text-xs text-sr-muted">
                  <span>
                    Saved:
                    <%= if @mapbox_settings && Map.get(@mapbox_settings, :access_token_present) do %>
                      <.ui_badge size="xs" variant="success">yes</.ui_badge>
                    <% else %>
                      <.ui_badge size="xs" variant="ghost">no</.ui_badge>
                    <% end %>
                  </span>
                  <label class="flex items-center gap-2">
                    <input
                      type="checkbox"
                      class={ui_checkbox_class(size: "xs")}
                      name="mapbox[clear_access_token]"
                      value="true"
                    />
                    <span>Clear token</span>
                  </label>
                </div>
              </div>

              <div class="flex items-center justify-end gap-2">
                <.ui_button type="submit" size="sm" variant="primary">Save</.ui_button>
              </div>
            </form>
          <% else %>
            <div class="text-sm text-sr-muted">Mapbox settings are unavailable.</div>
          <% end %>
        </.ui_panel>
      </Shell.settings_chrome>

      <.create_modal
        :if={@show_create_modal}
        available_credentials={@available_credentials}
        form={@create_form}
        partition_options={@partition_options}
        agent_options={@agent_options}
        form_queries={@form_queries}
        form_network_blacklist={@form_network_blacklist}
        form_custom_fields={@form_custom_fields}
        composite_settings={%{}}
        composite_check_options={@composite_check_options}
      />
      <.edit_modal
        :if={@show_edit_modal}
        available_credentials={@available_credentials}
        form={@edit_form}
        source={@selected_source}
        partition_options={@partition_options}
        agent_options={@agent_options}
        form_queries={@form_queries}
        form_network_blacklist={@form_network_blacklist}
        form_custom_fields={@form_custom_fields}
        composite_settings={composite_settings(@selected_source)}
        composite_check_options={@composite_check_options}
      />
      <.details_modal
        :if={@show_details_modal}
        source={@selected_source}
        agent_index={@agent_index}
        selected_source_runs={@selected_source_runs}
        selected_source_config_diagnostics={@selected_source_config_diagnostics}
        timezone={@current_scope.user.timezone || "Etc/UTC"}
      />
    </Layouts.app>
    """
  end

  defp create_modal(assigns) do
    ~H"""
    <dialog id="create_modal" class="sr-ui-modal sr-ui-modal-open" phx-hook="DialogTopLayer">
      <div class="sr-ui-modal-box sr-ui-modal-box-md">
        <form method="dialog">
          <.ui_icon_button
            phx-click="close_create_modal"
            size="sm"
            variant="ghost"
            class="absolute right-2 top-2"
          >
            x
          </.ui_icon_button>
        </form>

        <h3 class="text-lg font-bold">Create Integration Source</h3>
        <p class="py-2 text-sm text-sr-muted">
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

          <div class="grid grid-cols-2 gap-4">
            <.input
              field={@form[:discovery_interval_seconds]}
              type="number"
              label="Discovery Interval (sec)"
              placeholder="3600"
            />

            <.input
              field={@form[:page_size]}
              type="number"
              label="Page Size"
              placeholder="100"
            />
          </div>
          <p class="text-xs text-sr-muted -mt-2">
            Discovery imports devices from the integration. Network sweep scheduling is configured separately.
          </p>

          <%= if armis_source_type?(@form[:source_type].value) do %>
            <div class="grid grid-cols-2 gap-4">
              <.input
                field={@form[:northbound_availability_source_agent_id]}
                type="select"
                label="Northbound Availability Source"
                options={@agent_options}
                prompt="Use canonical device availability"
              />
            </div>

            <.composite_export_fields
              composite={@composite_settings}
              composite_check_options={@composite_check_options}
            />
          <% end %>

          <div class="sr-ui-divider text-xs text-sr-muted">Credentials</div>

          <.dynamic_credentials_fields
            form={@form}
            source_type={@form[:source_type].value || :armis}
            mode={:create}
            credentials={%{}}
            available_credentials={@available_credentials}
            selected_credential_id={nil}
          />

          <.armis_northbound_fields
            :if={armis_source?(@form[:source_type].value || :armis)}
            form={@form}
            custom_fields_value={@form_custom_fields}
          />

          <.fact_authority_fields selected={[]} />

          <div class="sr-ui-divider text-xs text-sr-muted">Queries</div>

          <div class="space-y-3">
            <%= for query <- @form_queries do %>
              <div class="p-3 bg-sr-subtle rounded-lg space-y-2">
                <div class="flex items-center justify-between">
                  <span class="text-xs font-semibold text-sr-muted">Query</span>
                  <.ui_button
                    type="button"
                    phx-click="remove_query"
                    phx-value-id={query["id"]}
                    size="xs"
                    variant="ghost"
                    class="text-error"
                  >
                    <.icon name="hero-trash" class="size-3" /> Remove
                  </.ui_button>
                </div>
                <div class="grid grid-cols-2 gap-2">
                  <div class="flex flex-col gap-1.5">
                    <label class="flex items-center justify-between gap-2 py-1">
                      <span class="text-xs font-medium text-sr-ink">Label</span>
                    </label>
                    <input
                      type="text"
                      class={ui_field_class(size: "sm", class: "w-full")}
                      placeholder="e.g., all_devices"
                      value={query["label"]}
                      phx-blur="update_query"
                      phx-value-id={query["id"]}
                      phx-value-field="label"
                    />
                  </div>
                  <div class="flex flex-col gap-1.5">
                    <label class="flex items-center justify-between gap-2 py-1">
                      <span class="text-xs font-medium text-sr-ink">Query (AQL)</span>
                    </label>
                    <input
                      type="text"
                      class={ui_field_class(size: "sm", mono: true, class: "w-full")}
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

            <.ui_button type="button" phx-click="add_query" size="sm" variant="outline" class="w-full">
              <.icon name="hero-plus" class="size-4" /> Add Query
            </.ui_button>
          </div>

          <%= if shows_network_blacklist?(@form[:source_type].value) do %>
            <div class="sr-ui-divider text-xs text-sr-muted">Network Settings</div>

            <div class="flex flex-col gap-1.5">
              <label class="flex items-center justify-between gap-2">
                <span class="text-sm font-medium text-sr-ink">Network Blacklist</span>
              </label>
              <textarea
                name="network_blacklist_text"
                class={ui_field_class(mono: true, class: "w-full min-h-24 py-2.5 text-sm")}
                rows="3"
                placeholder="10.0.0.0/8&#10;172.16.0.0/12&#10;192.168.0.0/16"
                phx-blur="update_network_blacklist"
              ><%= @form_network_blacklist %></textarea>
              <label class="flex items-center justify-between gap-2">
                <span class="text-xs text-sr-muted">
                  One CIDR per line - networks to exclude from discovery
                </span>
              </label>
            </div>
          <% end %>

          <div class="sr-ui-modal-action">
            <.ui_button type="button" phx-click="close_create_modal" size="sm" variant="neutral">
              Cancel
            </.ui_button>
            <.ui_button type="submit" size="sm" variant="primary">Create Source</.ui_button>
          </div>
        </.form>
      </div>
      <form method="dialog" class="sr-ui-modal-backdrop">
        <button phx-click="close_create_modal">close</button>
      </form>
    </dialog>
    """
  end

  defp edit_modal(assigns) do
    ~H"""
    <dialog id="edit_modal" class="sr-ui-modal sr-ui-modal-open" phx-hook="DialogTopLayer">
      <div class="sr-ui-modal-box sr-ui-modal-box-md">
        <form method="dialog">
          <.ui_icon_button
            phx-click="close_edit_modal"
            size="sm"
            variant="ghost"
            class="absolute right-2 top-2"
          >
            x
          </.ui_icon_button>
        </form>

        <h3 class="text-lg font-bold">Edit Integration Source</h3>
        <p class="py-2 text-sm text-sr-muted">
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
            <div class="flex flex-col gap-1.5">
              <label class="flex items-center justify-between gap-2">
                <span class="text-sm font-medium text-sr-ink">Source Type</span>
              </label>
              <input
                type="text"
                class={ui_field_class(class: "w-full bg-sr-subtle")}
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

          <div class="grid grid-cols-2 gap-4">
            <.input
              field={@form[:discovery_interval_seconds]}
              type="number"
              label="Discovery Interval (sec)"
            />

            <.input
              field={@form[:page_size]}
              type="number"
              label="Page Size"
            />
          </div>
          <p class="text-xs text-sr-muted -mt-2">
            Discovery imports devices from the integration. Network sweep scheduling is configured separately.
          </p>

          <%= if armis_source?(@source) do %>
            <div class="grid grid-cols-2 gap-4">
              <.input
                field={@form[:northbound_availability_source_agent_id]}
                type="select"
                label="Northbound Availability Source"
                options={@agent_options}
                prompt="Use canonical device availability"
              />
            </div>

            <.composite_export_fields
              composite={@composite_settings}
              composite_check_options={@composite_check_options}
            />
          <% end %>

          <div class="sr-ui-divider text-xs text-sr-muted">Credentials</div>

          <.dynamic_credentials_fields
            form={@form}
            source_type={(@source && @source.source_type) || :armis}
            mode={:edit}
            credentials={source_credentials(@source)}
            available_credentials={@available_credentials}
            selected_credential_id={@source && @source.credential_secret_id}
          />

          <.armis_northbound_fields
            :if={armis_source?((@source && @source.source_type) || :armis)}
            form={@form}
            custom_fields_value={@form_custom_fields}
          />

          <.fact_authority_fields selected={fact_authority_selected(@source)} />

          <div class="sr-ui-divider text-xs text-sr-muted">Queries</div>

          <div class="space-y-3">
            <%= for query <- @form_queries do %>
              <div class="p-3 bg-sr-subtle rounded-lg space-y-2">
                <div class="flex items-center justify-between">
                  <span class="text-xs font-semibold text-sr-muted">Query</span>
                  <.ui_button
                    type="button"
                    phx-click="remove_query"
                    phx-value-id={query["id"]}
                    size="xs"
                    variant="ghost"
                    class="text-error"
                  >
                    <.icon name="hero-trash" class="size-3" /> Remove
                  </.ui_button>
                </div>
                <div class="grid grid-cols-2 gap-2">
                  <div class="flex flex-col gap-1.5">
                    <label class="flex items-center justify-between gap-2 py-1">
                      <span class="text-xs font-medium text-sr-ink">Label</span>
                    </label>
                    <input
                      type="text"
                      class={ui_field_class(size: "sm", class: "w-full")}
                      placeholder="e.g., all_devices"
                      value={query["label"]}
                      phx-blur="update_query"
                      phx-value-id={query["id"]}
                      phx-value-field="label"
                    />
                  </div>
                  <div class="flex flex-col gap-1.5">
                    <label class="flex items-center justify-between gap-2 py-1">
                      <span class="text-xs font-medium text-sr-ink">Query (AQL)</span>
                    </label>
                    <input
                      type="text"
                      class={ui_field_class(size: "sm", mono: true, class: "w-full")}
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

            <.ui_button type="button" phx-click="add_query" size="sm" variant="outline" class="w-full">
              <.icon name="hero-plus" class="size-4" /> Add Query
            </.ui_button>
          </div>

          <%= if shows_network_blacklist?(@source && @source.source_type) do %>
            <div class="sr-ui-divider text-xs text-sr-muted">Network Settings</div>

            <div class="flex flex-col gap-1.5">
              <label class="flex items-center justify-between gap-2">
                <span class="text-sm font-medium text-sr-ink">Network Blacklist</span>
              </label>
              <textarea
                name="network_blacklist_text"
                class={ui_field_class(mono: true, class: "w-full min-h-24 py-2.5 text-sm")}
                rows="3"
                placeholder="10.0.0.0/8&#10;172.16.0.0/12&#10;192.168.0.0/16"
                phx-blur="update_network_blacklist"
              ><%= @form_network_blacklist %></textarea>
              <label class="flex items-center justify-between gap-2">
                <span class="text-xs text-sr-muted">
                  One CIDR per line - networks to exclude from discovery
                </span>
              </label>
            </div>
          <% end %>

          <div class="sr-ui-modal-action">
            <.ui_button type="button" phx-click="close_edit_modal" size="sm" variant="neutral">
              Cancel
            </.ui_button>
            <.ui_button type="submit" size="sm" variant="primary">Update Source</.ui_button>
          </div>
        </.form>
      </div>
      <form method="dialog" class="sr-ui-modal-backdrop">
        <button phx-click="close_edit_modal">close</button>
      </form>
    </dialog>
    """
  end

  defp details_modal(assigns) do
    ~H"""
    <dialog id="details_modal" class="sr-ui-modal sr-ui-modal-open" phx-hook="DialogTopLayer">
      <div class="sr-ui-modal-box sr-ui-modal-box-md">
        <form method="dialog">
          <.ui_icon_button
            phx-click="close_details_modal"
            size="sm"
            variant="ghost"
            class="absolute right-2 top-2"
          >
            x
          </.ui_icon_button>
        </form>

        <h3 class="text-lg font-bold">Integration Source Details</h3>

        <div class="mt-4 space-y-4">
          <div class="grid grid-cols-2 gap-4">
            <div>
              <div class="text-xs uppercase tracking-wide text-sr-muted">Name</div>
              <div class="font-medium">{@source.name}</div>
            </div>
            <div>
              <div class="text-xs uppercase tracking-wide text-sr-muted">Status</div>
              <.status_badge enabled={@source.enabled} result={@source.last_sync_result} />
            </div>
            <div>
              <div class="text-xs uppercase tracking-wide text-sr-muted">Type</div>
              <.source_type_badge type={@source.source_type} />
            </div>
            <div>
              <div class="text-xs uppercase tracking-wide text-sr-muted">
                Discovery Interval
              </div>
              <div>{format_interval(@source.discovery_interval_seconds)}</div>
            </div>
          </div>

          <div>
            <div class="text-xs uppercase tracking-wide text-sr-muted mb-1">Endpoint</div>
            <code class="text-sm font-mono bg-sr-subtle p-2 rounded block">{@source.endpoint}</code>
          </div>

          <div>
            <div class="text-xs uppercase tracking-wide text-sr-muted mb-1">Source ID</div>
            <code class="text-sm font-mono bg-sr-subtle p-2 rounded block">{@source.id}</code>
          </div>

          <%= if armis_source?(@source) do %>
            <div class="sr-ui-divider">Credentials</div>

            <div class="grid grid-cols-2 gap-4">
              <div>
                <div class="text-xs uppercase tracking-wide text-sr-muted">API Key</div>
                <div class="mt-2">
                  <.ui_badge
                    variant={
                      if credential_present?(source_credentials(@source), ["api_key"]),
                        do: "success",
                        else: "ghost"
                    }
                    size="xs"
                  >
                    {if credential_present?(source_credentials(@source), ["api_key"]),
                      do: "Saved",
                      else: "Not saved"}
                  </.ui_badge>
                </div>
              </div>
              <div>
                <div class="text-xs uppercase tracking-wide text-sr-muted">API Secret</div>
                <div class="mt-2">
                  <.ui_badge
                    variant={
                      if credential_present?(source_credentials(@source), ["api_secret", "secret_key"]),
                         do: "success",
                         else: "ghost"
                    }
                    size="xs"
                  >
                    {if credential_present?(source_credentials(@source), ["api_secret", "secret_key"]),
                        do: "Saved",
                        else: "Not saved"}
                  </.ui_badge>
                </div>
              </div>
            </div>
          <% end %>

          <%= if @source.partition do %>
            <div>
              <div class="text-xs uppercase tracking-wide text-sr-muted mb-1">Partition</div>
              <code class="text-sm font-mono bg-sr-subtle p-2 rounded block">
                {@source.partition}
              </code>
            </div>
          <% end %>

          <%= if @source.agent_id && @source.agent_id != "" do %>
            <div>
              <div class="text-xs uppercase tracking-wide text-sr-muted mb-1">Agent ID</div>
              <% agent = Map.get(@agent_index, @source.agent_id) %>
              <div class="flex flex-col gap-2">
                <code class="text-sm font-mono bg-sr-subtle p-2 rounded block">
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

          <div class="sr-ui-divider">Discovery Status</div>

          <div class="grid grid-cols-3 gap-4">
            <div class="stat bg-sr-subtle rounded-lg p-3">
              <div class="sr-ui-stat-title text-xs">Total Syncs</div>
              <div class="sr-ui-stat-value text-lg">{@source.total_syncs || 0}</div>
            </div>
            <div class="stat bg-sr-subtle rounded-lg p-3">
              <div class="sr-ui-stat-title text-xs">Last Device Count</div>
              <div class="sr-ui-stat-value text-lg">{@source.last_device_count || 0}</div>
            </div>
            <div class="stat bg-sr-subtle rounded-lg p-3">
              <div class="sr-ui-stat-title text-xs">Consecutive Failures</div>
              <div class="sr-ui-stat-value text-lg">{@source.consecutive_failures || 0}</div>
            </div>
          </div>

          <%= if @source.last_sync_at do %>
            <div>
              <div class="text-xs uppercase tracking-wide text-sr-muted mb-1">Last Sync</div>
              <div class="text-sm">
                <.user_time
                  id={"settings-integration-source-details-#{@source.id}-last-sync-at"}
                  value={@source.last_sync_at}
                  timezone={@timezone}
                  style={:compact}
                  fallback="-"
                />
              </div>
            </div>
          <% end %>

          <%= if @source.enabled && is_nil(@source.last_sync_at) do %>
            <div class={ui_alert_class(variant: "info", class: "text-sm")}>
              <.icon name="hero-information-circle" class="size-5" />
              <div>
                <div class="font-medium">This source has never run.</div>
                <div class="text-xs text-sr-muted">
                  Confirm the assigned agent is connected and the sync runtime is enabled.
                </div>
              </div>
            </div>
          <% end %>

          <div class="sr-ui-divider">Agent Config Dispatch</div>

          <%= if @selected_source_config_diagnostics == [] do %>
            <div class="rounded-lg border border-dashed border-sr-line bg-sr-surface p-4 text-sm text-sr-muted">
              No recent config dispatch recorded for this source.
            </div>
          <% else %>
            <div class="sr-ui-table-shell">
              <table class={ui_table_class(size: "sm")}>
                <thead>
                  <tr class="text-xs uppercase tracking-wide text-sr-muted">
                    <th>Recorded</th>
                    <th>Config</th>
                    <th>Action</th>
                    <th>Agents</th>
                    <th>Result</th>
                  </tr>
                </thead>
                <tbody>
                  <%= for diagnostic <- @selected_source_config_diagnostics do %>
                    <tr>
                      <td class="text-xs text-sr-muted">
                        <.user_time
                          id={
                            "settings-integration-diagnostic-#{diagnostic_dom_id(diagnostic)}-recorded-at"
                          }
                          value={Map.get(diagnostic, :recorded_at)}
                          timezone={@timezone}
                          style={:compact}
                          fallback="-"
                        />
                      </td>
                      <td class="text-xs text-sr-muted">
                        {Map.get(diagnostic, :config_type)}
                      </td>
                      <td class="text-xs text-sr-muted">
                        {Map.get(diagnostic, :action_type)}
                      </td>
                      <td class="text-xs text-sr-muted">
                        {format_affected_agents(Map.get(diagnostic, :affected_agents))}
                      </td>
                      <td class="text-xs text-sr-muted">
                        {format_dispatch_result(Map.get(diagnostic, :result))}
                      </td>
                    </tr>
                  <% end %>
                </tbody>
              </table>
            </div>
          <% end %>

          <%= if error_message = visible_error_message(@source.last_error_message) do %>
            <div class={ui_alert_class(variant: "error", class: "text-sm")}>
              <.icon name="hero-exclamation-circle" class="size-5" />
              <span>{error_message}</span>
            </div>
          <% end %>

          <%= if armis_source?(@source) do %>
            <div class="sr-ui-divider">Armis Northbound</div>
            <% latest_run = List.first(@selected_source_runs) %>

            <div class="grid grid-cols-2 gap-4">
              <div>
                <div class="text-xs uppercase tracking-wide text-sr-muted">Enabled</div>
                <div class="mt-1">
                  <.ui_badge
                    variant={if @source.northbound_enabled, do: "success", else: "ghost"}
                    size="xs"
                  >
                    {if @source.northbound_enabled, do: "Enabled", else: "Disabled"}
                  </.ui_badge>
                </div>
              </div>
              <div>
                <div class="text-xs uppercase tracking-wide text-sr-muted">Status</div>
                <div class="mt-1">
                  <.northbound_status_badge
                    enabled={@source.northbound_enabled}
                    status={@source.northbound_status}
                    result={@source.northbound_last_result}
                  />
                </div>
              </div>
              <div>
                <div class="text-xs uppercase tracking-wide text-sr-muted">Cadence</div>
                <div>{format_interval(@source.northbound_interval_seconds)}</div>
              </div>
              <div>
                <div class="text-xs uppercase tracking-wide text-sr-muted">
                  Custom Property
                </div>
                <div class="font-mono text-sm">{custom_fields_display(@source.custom_fields)}</div>
              </div>
              <div>
                <div class="text-xs uppercase tracking-wide text-sr-muted">
                  Availability Source
                </div>
                <div class="font-mono text-sm">{availability_source_display(@source)}</div>
              </div>
            </div>

            <div id="armis-reconciliation-statuses" class="grid grid-cols-2 gap-3 md:grid-cols-4">
              <div class="rounded-lg border border-sr-line bg-sr-subtle p-3">
                <div class="text-xs uppercase tracking-wide text-sr-muted">Inbound transport</div>
                <div class="mt-1">
                  <.status_badge
                    enabled={@source.enabled}
                    result={@source.last_result}
                  />
                </div>
              </div>
              <div class="rounded-lg border border-sr-line bg-sr-subtle p-3">
                <div class="text-xs uppercase tracking-wide text-sr-muted">Snapshot accounting</div>
                <div class="mt-1">
                  <.ui_badge
                    variant={if exact_accounting?(latest_run), do: "success", else: "warning"}
                    size="xs"
                  >
                    {if exact_accounting?(latest_run), do: "Exact", else: "Unavailable"}
                  </.ui_badge>
                </div>
              </div>
              <div class="rounded-lg border border-sr-line bg-sr-subtle p-3">
                <div class="text-xs uppercase tracking-wide text-sr-muted">Northbound transport</div>
                <div class="mt-1">
                  <%= if latest_run do %>
                    <.run_status_badge status={latest_run.status} />
                  <% else %>
                    <.ui_badge variant="ghost" size="xs">Never run</.ui_badge>
                  <% end %>
                </div>
              </div>
              <div class="rounded-lg border border-sr-line bg-sr-subtle p-3">
                <div class="text-xs uppercase tracking-wide text-sr-muted">Reconciliation</div>
                <div class="mt-1">
                  <.reconciliation_status_badge status={
                    if latest_run, do: latest_run.reconciliation_status, else: :unavailable
                  } />
                </div>
              </div>
            </div>

            <div>
              <div class="text-xs uppercase tracking-wide text-sr-muted mb-1">Last Run</div>
              <div class="text-sm">
                <.user_time
                  id={"settings-integration-source-details-#{@source.id}-northbound-last-run-at"}
                  value={@source.northbound_last_run_at}
                  timezone={@timezone}
                  style={:compact}
                  fallback="-"
                />
              </div>
            </div>
            <%= if exact_accounting?(latest_run) do %>
              <div
                id="armis-reconciliation-funnel"
                class="space-y-3 rounded-xl border border-sr-line bg-sr-surface p-4"
              >
                <div class="flex flex-wrap items-start justify-between gap-3">
                  <div>
                    <div class="text-sm font-semibold text-sr-ink">Collection reconciliation</div>
                    <div class="text-xs text-sr-muted">
                      One disposition for every distinct Armis ID in this completed collection.
                    </div>
                  </div>
                  <div class="text-right text-xs text-sr-muted">
                    <div title={latest_run.collection_id}>
                      Collection
                      <span class="font-mono">{short_collection_id(latest_run.collection_id)}</span>
                    </div>
                    <div class="flex items-center justify-end gap-1">
                      <span>Observed</span>
                      <.user_time
                        id={"settings-integration-run-#{latest_run.id}-collection-observed-at"}
                        value={latest_run.collection_observed_at}
                        timezone={@timezone}
                        style={:compact}
                        fallback="-"
                      />
                    </div>
                    <.ui_button
                      id="armis-run-target-export"
                      href={~p"/settings/networks/integrations/runs/#{latest_run.id}/export.csv"}
                      size="xs"
                      variant="outline"
                      class="mt-2"
                    >
                      Export ledger
                    </.ui_button>
                  </div>
                </div>

                <div class="stat bg-sr-subtle rounded-lg p-3">
                  <div class="sr-ui-stat-title text-xs">Raw rows</div>
                  <div class="sr-ui-stat-value text-lg">{latest_run.raw_rows || 0}</div>
                  <div class="sr-ui-stat-desc text-xs text-sr-muted">
                    {latest_run.excluded_rows || 0} policy-excluded + {latest_run.invalid_rows ||
                      0} invalid + {latest_run.valid_occurrences || 0} valid occurrences
                  </div>
                </div>

                <div class="grid grid-cols-2 gap-3">
                  <div class="stat bg-sr-subtle rounded-lg p-3">
                    <div class="sr-ui-stat-title text-xs">Distinct Armis IDs</div>
                    <div class="sr-ui-stat-value text-lg">{latest_run.distinct_source_ids || 0}</div>
                    <div class="sr-ui-stat-desc text-xs text-sr-muted">
                      {latest_run.duplicate_occurrences || 0} repeated occurrences collapsed
                    </div>
                  </div>
                  <div class="stat bg-sr-subtle rounded-lg p-3">
                    <div class="sr-ui-stat-title text-xs">Conflicting repeats</div>
                    <div class="sr-ui-stat-value text-lg">
                      {latest_run.conflicting_duplicate_ids || 0}
                    </div>
                    <div class="sr-ui-stat-desc text-xs text-sr-muted">Withheld by source ID</div>
                  </div>
                </div>

                <div class="grid grid-cols-2 gap-3">
                  <div class="stat bg-sr-subtle rounded-lg p-3">
                    <div class="sr-ui-stat-title text-xs">Eligible IDs</div>
                    <div class="sr-ui-stat-value text-lg">{latest_run.eligible_count || 0}</div>
                  </div>
                  <div class="stat bg-sr-subtle rounded-lg p-3">
                    <div class="sr-ui-stat-title text-xs">Withheld IDs</div>
                    <div class="sr-ui-stat-value text-lg">{latest_run.withheld_count || 0}</div>
                  </div>
                </div>

                <div class="grid grid-cols-3 gap-3">
                  <div class="stat bg-sr-subtle rounded-lg p-3">
                    <div class="sr-ui-stat-title text-xs">Accepted by Armis</div>
                    <div class="sr-ui-stat-value text-lg">{latest_run.accepted_count || 0}</div>
                  </div>
                  <div class="stat bg-sr-subtle rounded-lg p-3">
                    <div class="sr-ui-stat-title text-xs">Failed IDs</div>
                    <div class="sr-ui-stat-value text-lg">{latest_run.failed_count || 0}</div>
                  </div>
                  <div class="stat bg-sr-subtle rounded-lg p-3">
                    <div class="sr-ui-stat-title text-xs">Unattempted IDs</div>
                    <div class="sr-ui-stat-value text-lg">{latest_run.unattempted_count || 0}</div>
                  </div>
                </div>

                <p class="text-xs text-sr-muted">
                  Accepted means the Armis bulk endpoint returned success; it is not a downstream read-after-write verification.
                </p>

                <%= if examples = run_population_examples(latest_run, :duplicate_source_id_examples) do %>
                  <details id="armis-duplicate-examples" class="rounded-lg border border-sr-line p-3">
                    <summary class="cursor-pointer text-sm font-medium text-sr-ink">
                      Repeated source-ID examples ({length(examples)})
                    </summary>
                    <div class="mt-2 flex flex-wrap gap-2">
                      <%= for source_id <- examples do %>
                        <.ui_badge variant="outline" size="xs">{source_id}</.ui_badge>
                      <% end %>
                    </div>
                  </details>
                <% end %>

                <%= if examples = run_population_examples(latest_run, :invalid_row_examples) do %>
                  <details id="armis-invalid-examples" class="rounded-lg border border-sr-line p-3">
                    <summary class="cursor-pointer text-sm font-medium text-sr-ink">
                      Invalid row examples ({length(examples)})
                    </summary>
                    <ul class="mt-2 space-y-1 font-mono text-xs text-sr-muted">
                      <%= for example <- examples do %>
                        <li>{example}</li>
                      <% end %>
                    </ul>
                  </details>
                <% end %>

                <%= if reasons = run_withheld_reason_counts(latest_run) do %>
                  <div id="armis-withheld-reasons" class="border-t border-sr-line pt-3">
                    <div class="mb-2 text-xs uppercase tracking-wide text-sr-muted">
                      Withheld reasons
                    </div>
                    <div class="flex flex-wrap gap-2">
                      <%= for {reason, count} <- reasons do %>
                        <.ui_badge variant="warning" size="xs">
                          {humanize_reason(reason)}: {count}
                        </.ui_badge>
                      <% end %>
                    </div>
                  </div>
                <% end %>

                <%= if @selected_source_target_examples != [] do %>
                  <div id="armis-disposition-examples" class="space-y-2 border-t border-sr-line pt-3">
                    <div class="text-xs uppercase tracking-wide text-sr-muted">
                      Disposition examples
                    </div>
                    <%= for {group, examples} <- @selected_source_target_examples do %>
                      <details class="rounded-lg border border-sr-line p-3">
                        <summary class="cursor-pointer text-sm font-medium text-sr-ink">
                          {humanize_reason(group)} ({target_group_count(latest_run, group)})
                        </summary>
                        <div class="mt-2 overflow-x-auto">
                          <table class={ui_table_class(size: "xs")}>
                            <thead>
                              <tr>
                                <th>Armis ID</th><th>Canonical device</th>
                              </tr>
                            </thead>
                            <tbody>
                              <%= for example <- examples do %>
                                <tr>
                                  <td class="font-mono text-xs">{example.source_object_id}</td>
                                  <td class="font-mono text-xs text-sr-muted">
                                    {example.canonical_device_uid || "—"}
                                  </td>
                                </tr>
                              <% end %>
                            </tbody>
                          </table>
                        </div>
                      </details>
                    <% end %>
                  </div>
                <% end %>
              </div>
            <% else %>
              <div
                id="armis-accounting-unavailable"
                class={ui_alert_class(variant: "warning", class: "text-sm")}
              >
                <.icon name="hero-exclamation-triangle" class="size-5" />
                <div>
                  <div class="font-medium">Collection accounting unavailable</div>
                  <div class="text-xs text-sr-muted">
                    Legacy runs are still visible, but their inventory and update totals are not presented as an exact reconciliation.
                  </div>
                </div>
              </div>
            <% end %>

            <%= if @source.northbound_last_error_message do %>
              <div class={ui_alert_class(variant: "error", class: "text-sm")}>
                <.icon name="hero-exclamation-circle" class="size-5" />
                <span>{@source.northbound_last_error_message}</span>
              </div>
            <% end %>

            <div>
              <div class="mb-2 text-xs uppercase tracking-wide text-sr-muted">Recent Runs</div>
              <%= if @selected_source_runs == [] do %>
                <div class="rounded-lg border border-dashed border-sr-line bg-sr-surface p-4 text-sm text-sr-muted">
                  No northbound runs recorded yet.
                </div>
              <% else %>
                <div class="sr-ui-table-shell">
                  <table class={ui_table_class(size: "sm")}>
                    <thead>
                      <tr class="text-xs uppercase tracking-wide text-sr-muted">
                        <th>Started</th>
                        <th>Status</th>
                        <th>Source</th>
                        <th title="Composite check exported by this run">Composite</th>
                        <th>Accepted</th>
                        <th>Withheld</th>
                        <th>Failed</th>
                        <th>Unattempted</th>
                        <th>Reconciliation</th>
                      </tr>
                    </thead>
                    <tbody>
                      <%= for run <- @selected_source_runs do %>
                        <tr>
                          <td class="text-xs text-sr-muted">
                            <.user_time
                              id={"settings-integration-run-#{run.id}-started-at"}
                              value={run.started_at}
                              timezone={@timezone}
                              style={:compact}
                              fallback="-"
                            />
                          </td>
                          <td><.run_status_badge status={run.status} /></td>
                          <td class="font-mono text-xs text-sr-muted">
                            {run_availability_source_display(run)}
                          </td>
                          <td class="text-xs text-sr-muted" data-run-composite={run.id}>
                            <%= case run_composite_display(run) do %>
                              <% nil -> %>
                                <span class="text-sr-muted">—</span>
                              <% {slug, form} -> %>
                                <span class="font-mono">{slug}</span>
                                <span class="ml-1 text-sr-muted">({form})</span>
                            <% end %>
                          </td>
                          <td class="text-xs text-sr-muted">
                            {run_accepted_count(run)}
                          </td>
                          <td class="text-xs text-sr-muted">
                            {run_withheld_count(run)}
                          </td>
                          <td class="text-xs text-sr-muted">
                            {run_failed_count(run)}
                            <%= if run.error_message do %>
                              <div
                                class="max-w-[220px] truncate text-error/80"
                                title={run.error_message}
                              >
                                {run.error_message}
                              </div>
                            <% end %>
                          </td>
                          <td class="text-xs text-sr-muted">{run.unattempted_count || 0}</td>
                          <td>
                            <.reconciliation_status_badge status={run.reconciliation_status} />
                          </td>
                        </tr>
                      <% end %>
                    </tbody>
                  </table>
                </div>
              <% end %>
            </div>
          <% end %>
        </div>

        <div class="sr-ui-modal-action">
          <.ui_button
            :if={armis_source?(@source)}
            type="button"
            phx-click="run_northbound_now"
            phx-value-id={@source.id}
            size="sm"
            variant="outline"
          >
            Run Northbound Now
          </.ui_button>
          <.ui_button
            type="button"
            phx-click="delete_source"
            phx-value-id={@source.id}
            data-confirm="Are you sure you want to delete this integration source? This cannot be undone."
            size="sm"
            variant="outline"
          >
            Delete
          </.ui_button>
          <.ui_button
            variant="ghost"
            navigate={~p"/settings/networks/integrations/#{@source.id}/edit"}
          >
            Edit
          </.ui_button>
          <.ui_button type="button" phx-click="close_details_modal" size="sm" variant="neutral">
            Close
          </.ui_button>
        </div>
      </div>
      <form method="dialog" class="sr-ui-modal-backdrop">
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

  defp northbound_status_badge(assigns) do
    {variant, label} =
      cond do
        not assigns.enabled -> {"ghost", "Disabled"}
        assigns.status == :running -> {"info", "Running"}
        assigns.result == :success -> {"success", "Success"}
        assigns.result == :partial -> {"warning", "Partial"}
        assigns.result in [:failed, :timeout] -> {"error", "Failed"}
        true -> {"ghost", "Idle"}
      end

    assigns = assigns |> assign(:variant, variant) |> assign(:label, label)

    ~H"""
    <.ui_badge variant={@variant} size="xs">{@label}</.ui_badge>
    """
  end

  defp run_status_badge(assigns) do
    {variant, label} =
      case assigns.status do
        :running -> {"info", "Running"}
        :success -> {"success", "Success"}
        :partial -> {"warning", "Partial"}
        :failed -> {"error", "Failed"}
        :timeout -> {"error", "Timeout"}
        _ -> {"ghost", "Unknown"}
      end

    assigns = assigns |> assign(:variant, variant) |> assign(:label, label)

    ~H"""
    <.ui_badge variant={@variant} size="xs">{@label}</.ui_badge>
    """
  end

  defp reconciliation_status_badge(assigns) do
    {variant, label} =
      case assigns.status do
        :reconciled -> {"success", "Reconciled"}
        :degraded -> {"warning", "Degraded"}
        :failed -> {"error", "Failed"}
        :pending -> {"info", "Pending"}
        _ -> {"ghost", "Unavailable"}
      end

    assigns = assigns |> assign(:variant, variant) |> assign(:label, label)

    ~H"""
    <.ui_badge variant={@variant} size="xs">{@label}</.ui_badge>
    """
  end

  defp exact_accounting?(nil), do: false

  defp exact_accounting?(run) do
    is_binary(Map.get(run, :collection_id)) and Map.get(run, :collection_id) != "" and
      Map.get(run, :reconciliation_status) != :unavailable
  end

  defp short_collection_id(nil), do: "-"

  defp short_collection_id(collection_id) do
    collection_id = to_string(collection_id)
    if String.length(collection_id) > 12, do: String.slice(collection_id, 0, 12) <> "…", else: collection_id
  end

  defp run_withheld_reason_counts(run) do
    metadata = Map.get(run, :metadata) || %{}

    metadata
    |> metadata_value(:withheld_reason_counts)
    |> case do
      reasons when is_map(reasons) and map_size(reasons) > 0 ->
        reasons
        |> Enum.filter(fn {_reason, count} -> is_integer(count) and count > 0 end)
        |> Enum.sort_by(fn {reason, _count} -> to_string(reason) end)
        |> case do
          [] -> nil
          values -> values
        end

      _ ->
        nil
    end
  end

  defp run_population_examples(run, key) do
    metadata = Map.get(run, :metadata) || %{}

    with collection when is_map(collection) <- metadata_value(metadata, :collection),
         examples when is_list(examples) <- metadata_value(collection, key),
         examples = examples |> Enum.filter(&is_binary/1) |> Enum.take(100),
         true <- examples != [] do
      examples
    else
      _ -> nil
    end
  end

  defp target_group_count(run, group) do
    case to_string(group) do
      "failed" ->
        run.failed_count || 0

      "unattempted" ->
        run.unattempted_count || 0

      reason ->
        run
        |> run_withheld_reason_counts()
        |> List.wrap()
        |> Enum.find_value(0, fn {candidate, count} ->
          if to_string(candidate) == reason, do: count
        end)
    end
  end

  defp humanize_reason(reason) do
    reason
    |> to_string()
    |> String.replace("_", " ")
  end

  defp run_accepted_count(run) do
    if exact_accounting?(run), do: run.accepted_count || 0, else: run.updated_count || 0
  end

  defp run_withheld_count(run) do
    if exact_accounting?(run), do: run.withheld_count || 0, else: run.skipped_count || 0
  end

  defp run_failed_count(run) do
    if exact_accounting?(run), do: run.failed_count || 0, else: run.error_count || 0
  end

  defp armis_source?(%{source_type: :armis}), do: true
  defp armis_source?("armis"), do: true
  defp armis_source?(:armis), do: true
  defp armis_source?(_), do: false

  # {label, slug} for the composite export picker.
  #
  # Non-enabled checks are LISTED but labelled with their state rather than
  # hidden. CompositeNorthboundValues.for_devices/3 exports nothing for a check
  # that is not enabled, so hiding drafts would leave an operator unable to find
  # the check they just built, while offering them unlabelled would let them
  # save an export that silently publishes nothing.
  defp composite_check_options(socket) do
    require Ash.Query

    scope = socket.assigns[:current_scope]

    CompositeCheck
    |> Ash.Query.for_read(:read, %{}, scope: scope)
    |> Ash.Query.sort(name: :asc)
    |> Ash.read()
    |> case do
      {:ok, checks} ->
        Enum.map(checks, fn check ->
          label =
            if check.state == :enabled do
              check.name
            else
              "#{check.name} (#{check.state} - exports nothing until enabled)"
            end

          {label, check.slug}
        end)

      {:error, _reason} ->
        []
    end
  end

  defp armis_source_type?(type) when type in [:armis, "armis"], do: true
  defp armis_source_type?(_), do: false

  attr(:composite, :map, default: %{})
  attr(:composite_check_options, :list, default: [])

  @doc false
  # The three values are one selection, not three settings: composite_export/1
  # requires all of them and reads a half-configured export as "not configured".
  # Rendering them as one block is what makes that legible -- three fields
  # scattered through the form would let an operator fill two and see nothing
  # happen with no indication why.
  defp composite_export_fields(assigns) do
    ~H"""
    <div class="space-y-3">
      <div class="sr-ui-divider text-xs text-sr-muted">Composite check export</div>

      <p class="text-xs text-sr-muted">
        Publishes an enabled composite check's result to its own Armis custom field,
        alongside availability. All three values are required — leaving the check
        blank disables the export.
      </p>

      <div class="grid grid-cols-3 gap-4">
        <div class="flex flex-col gap-1.5">
          <label class="text-sm font-medium text-sr-ink">Composite check</label>
          <select
            name="composite_check_slug"
            class={ui_field_class(class: "w-full text-sm")}
          >
            <option value="">No composite export</option>
            <option
              :for={{label, slug} <- @composite_check_options}
              value={slug}
              selected={@composite["check_slug"] == slug}
            >
              {label}
            </option>
          </select>
        </div>

        <div class="flex flex-col gap-1.5">
          <label class="text-sm font-medium text-sr-ink">Value</label>
          <select name="composite_value_form" class={ui_field_class(class: "w-full text-sm")}>
            <option value="verdict" selected={@composite["value_form"] != "status"}>
              verdict
            </option>
            <option value="status" selected={@composite["value_form"] == "status"}>
              status
            </option>
          </select>
        </div>

        <div class="flex flex-col gap-1.5">
          <label class="text-sm font-medium text-sr-ink">Armis custom field</label>
          <input
            type="text"
            name="composite_custom_field"
            value={@composite["custom_field"]}
            class={ui_field_class(mono: true, class: "w-full text-sm")}
            placeholder="sr_isolation"
            autocomplete="off"
          />
        </div>
      </div>
    </div>
    """
  end

  # settings["composite"] as the form reads it. String keys throughout: the
  # attribute is a plain :map and the runner reads string keys, so normalising
  # here keeps the form and the reader speaking the same shape.
  defp composite_settings(nil), do: %{}

  defp composite_settings(source) do
    source
    |> Map.get(:settings)
    |> case do
      settings when is_map(settings) -> Map.get(settings, "composite")
      _other -> nil
    end
    |> case do
      composite when is_map(composite) ->
        Map.new(composite, fn {k, v} -> {to_string(k), v} end)

      _other ->
        %{}
    end
  end

  # Merged into the source's existing settings rather than replacing them: this
  # form owns one key, and a wholesale write would silently drop any other
  # source-specific setting stored alongside it.
  defp put_composite_setting(params, existing_settings) do
    slug = params |> Map.get("composite_check_slug", "") |> to_string() |> String.trim()
    form = params |> Map.get("composite_value_form", "") |> to_string() |> String.trim()
    field = params |> Map.get("composite_custom_field", "") |> to_string() |> String.trim()

    base =
      case existing_settings do
        settings when is_map(settings) -> Map.new(settings, fn {k, v} -> {to_string(k), v} end)
        _other -> %{}
      end

    settings =
      if slug == "" do
        Map.delete(base, "composite")
      else
        Map.put(base, "composite", %{
          "check_slug" => slug,
          "value_form" => if(form == "status", do: "status", else: "verdict"),
          "custom_field" => field
        })
      end

    params
    |> Map.put("settings", settings)
    |> Map.drop(["composite_check_slug", "composite_value_form", "composite_custom_field"])
  end

  defp put_fact_authority_setting(params) do
    keys =
      params
      |> Map.get("fact_authority", [])
      |> List.wrap()
      |> Enum.map(&to_string/1)
      |> Enum.filter(&(&1 in ["switch_port_attachment", "vlan_uid"]))

    settings =
      params
      |> Map.get("settings", %{})
      |> case do
        map when is_map(map) -> Map.new(map, fn {k, v} -> {to_string(k), v} end)
        _ -> %{}
      end
      |> Map.put("fact_authority", keys)

    params
    |> Map.put("settings", settings)
    |> Map.delete("fact_authority")
  end

  defp refresh_selected_source(nil, _actor), do: nil

  defp refresh_selected_source(%{id: id}, actor) do
    case get_source(id, actor) do
      {:ok, source} -> source
      _ -> nil
    end
  end

  defp active_filters(socket) do
    %{}
    |> maybe_put_filter(:source_type, socket.assigns.filter_type)
    |> maybe_put_filter(:enabled, socket.assigns.filter_enabled)
  end

  defp maybe_put_filter(filters, _key, nil), do: filters
  defp maybe_put_filter(filters, _key, ""), do: filters
  defp maybe_put_filter(filters, key, value), do: Map.put(filters, key, value)

  defp diagnostic_dom_id(diagnostic) do
    identity =
      Map.get(diagnostic, :id) ||
        Enum.map_join(
          [
            Map.get(diagnostic, :resource_id),
            Map.get(diagnostic, :config_type),
            Map.get(diagnostic, :action_type),
            Map.get(diagnostic, :recorded_at)
          ],
          "-",
          &to_string/1
        )

    identity
    |> to_string()
    |> String.replace(~r/[^a-zA-Z0-9_-]+/, "-")
    |> String.trim("-")
  end

  defp format_affected_agents(:all_online), do: "All online"
  defp format_affected_agents([]), do: "None"
  defp format_affected_agents(agent_ids) when is_list(agent_ids), do: Enum.join(agent_ids, ", ")
  defp format_affected_agents(_), do: "-"

  defp format_dispatch_result(:ok), do: "Pushed"
  defp format_dispatch_result({:error, _reason}), do: "Failed"
  defp format_dispatch_result(_), do: "-"

  defp visible_error_message(nil), do: nil

  defp visible_error_message(message) when is_binary(message) do
    message = String.trim(message)

    cond do
      message == "" -> nil
      stale_utc_datetime_error?(message) -> nil
      true -> message
    end
  end

  defp visible_error_message(_), do: nil

  defp stale_utc_datetime_error?(message) do
    String.contains?(message, ":utc_datetime expects microseconds to be empty") and
      String.contains?(message, "DateTime.truncate(utc_datetime, :second)")
  end

  defp format_interval(nil), do: "5 minutes"

  defp format_interval(seconds) when is_integer(seconds) do
    cond do
      seconds >= 3600 -> "#{div(seconds, 3600)} hour(s)"
      seconds >= 60 -> "#{div(seconds, 60)} minute(s)"
      true -> "#{seconds} second(s)"
    end
  end

  defp custom_fields_display(fields) when is_list(fields) and fields != [] do
    Enum.join(fields, ", ")
  end

  defp custom_fields_display(_), do: "-"

  defp availability_source_display(source) do
    source
    |> Map.get(:northbound_availability_source_agent_id)
    |> case do
      agent_id when is_binary(agent_id) and agent_id != "" -> agent_id
      _ -> "canonical"
    end
  end

  defp run_availability_source_display(run) do
    metadata = Map.get(run, :metadata) || %{}

    Map.get(metadata, "availability_source_agent_id") ||
      Map.get(metadata, :availability_source_agent_id) ||
      Map.get(metadata, "availability_source") ||
      Map.get(metadata, :availability_source) ||
      "canonical"
  end

  # Read from the run's own metadata, never from the source's current settings:
  # this column describes what *that* run exported, and reading the live
  # selection would retroactively relabel history the moment an operator
  # changes it.
  #
  # Both key forms are checked because an Ash `:map` attribute comes back from
  # the database with string keys but arrives with atoms in-process — the same
  # reason `run_availability_source_display/1` does it.
  defp run_composite_display(run) do
    metadata = Map.get(run, :metadata) || %{}

    slug = metadata_value(metadata, :composite_check_slug)
    form = metadata_value(metadata, :composite_value_form)

    if is_binary(slug) and slug != "" and is_binary(form) and form != "" do
      {slug, form}
    end
  end

  defp metadata_value(metadata, key) do
    Map.get(metadata, Atom.to_string(key)) || Map.get(metadata, key)
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

  # Credentials an integration source can bind instead of holding its own
  # encrypted copy. IntegrationSource has carried `credential_secret_id` and
  # sync_config_generator has branched on it for some time; nothing in this UI
  # could set it, so in practice every source stored a private copy and the
  # shared inventory was unreachable from here.
  #
  # Unfiltered: an integration source's credential shape is provider-specific
  # (Armis v1 key+secret, Armis v3 OAuth, NetBox token) and is not expressed as
  # one credential_kind, so there is nothing to filter on without guessing. A
  # failed load leaves the list empty, which renders per-source entry exactly as
  # before rather than breaking the page.
  defp list_available_credentials(actor) do
    ServiceRadar.Credentials.NetworkCredentialSecret
    |> Ash.Query.for_read(:read, %{}, actor: actor)
    |> Ash.Query.sort(name: :asc)
    |> Ash.read(actor: actor)
    |> case do
      {:ok, secrets} -> secrets
      _ -> []
    end
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
    query =
      IntegrationSource
      |> Ash.Query.for_read(:by_id, %{id: id})
      |> Ash.Query.load([:credentials_encrypted, :credentials])

    case Ash.read_one(query, actor: actor) do
      {:ok, nil} -> {:error, :not_found}
      result -> result
    end
  end

  defp list_recent_update_runs(source_id, actor) do
    source_id
    |> IntegrationUpdateRun.list_recent_by_source(actor: actor)
    |> case do
      {:ok, %Keyset{results: results}} -> results
      {:ok, results} when is_list(results) -> results
      _ -> []
    end
  rescue
    _ -> []
  end

  defp list_target_examples([latest_run | _]) do
    if exact_accounting?(latest_run) do
      case ArmisNorthboundLedger.examples(latest_run.id, per_group: 5) do
        {:ok, rows} ->
          rows
          |> Enum.group_by(fn row -> row.reason || row.outcome end)
          |> Enum.sort_by(fn {group, _rows} -> group end)

        {:error, _reason} ->
          []
      end
    else
      []
    end
  rescue
    _ -> []
  end

  defp list_target_examples(_runs), do: []

  defp list_config_diagnostics(source_id) do
    source_id = to_string(source_id)

    DependencyDiagnostics.recent()
    |> Enum.filter(fn diagnostic ->
      diagnostic[:dependency_id] == :integration_source_sync_config &&
        to_string(diagnostic[:resource_id]) == source_id
    end)
    |> Enum.take(5)
  rescue
    _ -> []
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
    |> normalize_blank_param("northbound_availability_source_agent_id")
  end

  defp normalize_blank_param(params, key) do
    case Map.get(params, key) do
      "" -> Map.put(params, key, nil)
      _ -> params
    end
  end

  # Parse credentials from either structured fields or JSON
  # Structured fields take precedence over JSON
  defp merge_auxiliary_form_params(form_params, event_params) do
    event_params
    |> Map.take([
      "cred_api_key",
      "cred_api_secret",
      "cred_v3_client_id",
      "cred_v3_client_secret",
      "cred_v3_vendor_id",
      "cred_snmp_version",
      "cred_community",
      "cred_netbox_url",
      "cred_netbox_token",
      "cred_netbox_verify_ssl",
      "cred_credential_secret_id",
      "credentials_json",
      "composite_check_slug",
      "composite_value_form",
      "composite_custom_field"
    ])
    |> Map.merge(form_params)
  end

  defp parse_credentials_json(params, existing_credentials \\ %{}) do
    params = apply_selected_integration_credential(params)
    existing_credentials = stringify_credentials(existing_credentials)

    cond do
      # Armis: v1 api_key + api_secret, plus v3 OAuth client credentials.
      armis_credential_fields_present?(params) ->
        creds = existing_credentials
        creds = maybe_add_cred(creds, "api_key", params["cred_api_key"])
        creds = maybe_add_cred(creds, "api_secret", params["cred_api_secret"])
        creds = maybe_add_cred(creds, "client_id", params["cred_v3_client_id"])
        creds = maybe_add_cred(creds, "client_secret", params["cred_v3_client_secret"])
        creds = maybe_add_cred(creds, "vendor_id", params["cred_v3_vendor_id"])

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

  # Folds the reusable-credential select into the attribute the source actually
  # persists, and drops the form-only key so it never reaches the changeset.
  #
  # A blank selection clears the binding rather than being ignored: the select is
  # the only control for it, so leaving it blank has to mean "not using a shared
  # credential" -- otherwise a source could never be unbound once bound. The
  # per-source encrypted fields are left untouched either way, so clearing the
  # binding falls back to whatever was already stored.
  defp apply_selected_integration_credential(params) do
    case Map.pop(params, "cred_credential_secret_id") do
      {nil, params} ->
        params

      {value, params} when is_binary(value) ->
        case String.trim(value) do
          "" -> Map.put(params, "credential_secret_id", nil)
          id -> Map.put(params, "credential_secret_id", id)
        end

      {_other, params} ->
        params
    end
  end

  defp armis_credential_fields_present?(params) do
    Enum.any?(
      [
        "cred_api_key",
        "cred_api_secret",
        "cred_v3_client_id",
        "cred_v3_client_secret",
        "cred_v3_vendor_id"
      ],
      &has_cred_field?(params, &1)
    )
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

  defp stringify_credentials(credentials) when is_map(credentials) do
    Map.new(credentials, fn {key, value} -> {to_string(key), value} end)
  end

  defp stringify_credentials(_), do: %{}

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

  defp parse_custom_fields(text) when is_binary(text) do
    text
    |> String.split([",", "\n"])
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp parse_custom_fields(_), do: []

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
  attr(:credentials, :map, default: %{})

  attr(:available_credentials, :list,
    default: [],
    doc: "Reusable credentials from the shared inventory. Empty renders per-source entry only."
  )

  attr(:selected_credential_id, :any, default: nil)

  defp dynamic_credentials_fields(assigns) do
    assigns =
      assigns
      |> assign(:api_key_present?, credential_present?(assigns.credentials, ["api_key"]))
      |> assign(
        :v3_client_id_value,
        credential_value(assigns.credentials, ["client_id", "v3_client_id"])
      )
      |> assign(
        :v3_vendor_id_value,
        credential_value(assigns.credentials, ["vendor_id", "v3_vendor_id"])
      )
      |> assign(
        :api_secret_present?,
        credential_present?(assigns.credentials, ["api_secret", "secret_key"])
      )
      |> assign(
        :v3_client_secret_present?,
        credential_present?(assigns.credentials, ["client_secret", "v3_client_secret"])
      )

    ~H"""
    <div :if={@available_credentials != []} class="space-y-1.5 mb-3">
      <label class="flex items-center justify-between gap-2">
        <span class="text-sm font-medium text-sr-ink">Reusable credential</span>
      </label>
      <select name="cred_credential_secret_id" class={ui_field_class(class: "w-full")}>
        <option value="" selected={@selected_credential_id in [nil, ""]}>
          — enter credentials below —
        </option>
        <option
          :for={secret <- @available_credentials}
          value={secret.id}
          selected={to_string(secret.id) == to_string(@selected_credential_id)}
        >
          {secret.name} ({secret.provider})
        </option>
      </select>
      <p class="text-xs text-sr-muted">
        <%= if @selected_credential_id in [nil, ""] do %>
          Stored on this source only. Choose a reusable credential to share one secret
          across sources.
        <% else %>
          Resolved through the credential broker. The fields below are ignored while one
          is selected.
        <% end %>
      </p>
    </div>

    <%= case @source_type do %>
      <% :armis -> %>
        <div class="space-y-3">
          <div class="flex flex-col gap-1.5">
            <label class="flex items-center justify-between gap-2">
              <span class="text-sm font-medium text-sr-ink">API Key</span>
            </label>
            <input
              type="password"
              name="cred_api_key"
              class={ui_field_class(mono: true, class: "w-full text-sm")}
              placeholder={
                if @mode == :edit and @api_key_present? do
                  "Saved key; leave empty to keep existing"
                else
                  "Enter your Armis API key"
                end
              }
              autocomplete="off"
            />
            <%= if @mode == :edit do %>
              <label class="flex items-center justify-between gap-2">
                <span class="text-xs text-sr-muted">
                  API key:
                  <.ui_badge size="xs" variant={if(@api_key_present?, do: "success", else: "ghost")}>
                    {if @api_key_present?, do: "saved", else: "not saved"}
                  </.ui_badge>
                </span>
              </label>
            <% end %>
          </div>
          <div class="flex flex-col gap-1.5">
            <label class="flex items-center justify-between gap-2">
              <span class="text-sm font-medium text-sr-ink">API Secret</span>
            </label>
            <input
              type="password"
              name="cred_api_secret"
              class={ui_field_class(mono: true, class: "w-full text-sm")}
              placeholder={
                cond do
                  @mode == :edit and @api_secret_present? ->
                    "Saved secret; leave empty to keep existing"

                  @mode == :edit ->
                    "Enter your Armis API secret"

                  true ->
                    "Enter your Armis API secret"
                end
              }
              autocomplete="off"
            />
            <%= if @mode == :edit do %>
              <label class="flex items-center justify-between gap-2">
                <span class="text-xs text-sr-muted">
                  API secret:
                  <.ui_badge
                    size="xs"
                    variant={if(@api_secret_present?, do: "success", else: "ghost")}
                  >
                    {if @api_secret_present?, do: "saved", else: "not saved"}
                  </.ui_badge>
                </span>
              </label>
            <% end %>
          </div>
          <div class="sr-ui-divider my-2">V3 OAuth</div>
          <div class="flex flex-col gap-1.5">
            <label class="flex items-center justify-between gap-2">
              <span class="text-sm font-medium text-sr-ink">Client ID</span>
            </label>
            <input
              type="text"
              name="cred_v3_client_id"
              value={@v3_client_id_value}
              class={ui_field_class(mono: true, class: "w-full text-sm")}
              placeholder="Enter the Armis V3 client ID"
              autocomplete="off"
            />
          </div>
          <div class="flex flex-col gap-1.5">
            <label class="flex items-center justify-between gap-2">
              <span class="text-sm font-medium text-sr-ink">Client Secret</span>
            </label>
            <input
              type="password"
              name="cred_v3_client_secret"
              class={ui_field_class(mono: true, class: "w-full text-sm")}
              placeholder={
                cond do
                  @mode == :edit and @v3_client_secret_present? ->
                    "Saved secret; leave empty to keep existing"

                  @mode == :edit ->
                    "Enter the Armis V3 client secret"

                  true ->
                    "Enter the Armis V3 client secret"
                end
              }
              autocomplete="off"
            />
            <%= if @mode == :edit do %>
              <label class="flex items-center justify-between gap-2">
                <span class="text-xs text-sr-muted">
                  V3 client secret:
                  <.ui_badge
                    size="xs"
                    variant={if(@v3_client_secret_present?, do: "success", else: "ghost")}
                  >
                    {if @v3_client_secret_present?, do: "saved", else: "not saved"}
                  </.ui_badge>
                </span>
              </label>
            <% end %>
          </div>
          <div class="flex flex-col gap-1.5">
            <label class="flex items-center justify-between gap-2">
              <span class="text-sm font-medium text-sr-ink">Vendor ID</span>
            </label>
            <input
              type="text"
              name="cred_v3_vendor_id"
              value={@v3_vendor_id_value}
              class={ui_field_class(mono: true, class: "w-full text-sm")}
              placeholder="Enter the Armis V3 vendor ID"
              autocomplete="off"
            />
          </div>
          <label class="flex items-center justify-between gap-2">
            <span class="text-xs text-sr-muted">
              Credentials will be encrypted at rest
            </span>
          </label>
        </div>
      <% :snmp -> %>
        <div class="space-y-3">
          <div class="grid grid-cols-2 gap-3">
            <div class="flex flex-col gap-1.5">
              <label class="flex items-center justify-between gap-2">
                <span class="text-sm font-medium text-sr-ink">SNMP Version</span>
              </label>
              <select name="cred_snmp_version" class={ui_field_class(class: "w-full")}>
                <option value="v2c">SNMPv2c</option>
                <option value="v3">SNMPv3</option>
              </select>
            </div>
            <div class="flex flex-col gap-1.5">
              <label class="flex items-center justify-between gap-2">
                <span class="text-sm font-medium text-sr-ink">Community String</span>
              </label>
              <input
                type="password"
                name="cred_community"
                class={ui_field_class(mono: true, class: "w-full text-sm")}
                placeholder={
                  if @mode == :edit, do: "Leave empty to keep existing", else: "e.g., public"
                }
              />
            </div>
          </div>
          <label class="flex items-center justify-between gap-2">
            <span class="text-xs text-sr-muted">
              For SNMPv3, use the SNMP Profiles section under Network settings
            </span>
          </label>
        </div>
      <% :netbox -> %>
        <div class="space-y-3">
          <div class="flex flex-col gap-1.5">
            <label class="flex items-center justify-between gap-2">
              <span class="text-sm font-medium text-sr-ink">Netbox URL</span>
            </label>
            <input
              type="url"
              name="cred_netbox_url"
              class={ui_field_class(mono: true, class: "w-full text-sm")}
              placeholder="https://netbox.example.com"
            />
            <label class="flex items-center justify-between gap-2">
              <span class="text-xs text-sr-muted">
                Full URL to your Netbox instance (including https://)
              </span>
            </label>
          </div>
          <div class="flex flex-col gap-1.5">
            <label class="flex items-center justify-between gap-2">
              <span class="text-sm font-medium text-sr-ink">API Token</span>
            </label>
            <input
              type="password"
              name="cred_netbox_token"
              class={ui_field_class(mono: true, class: "w-full text-sm")}
              placeholder={
                if @mode == :edit,
                  do: "Leave empty to keep existing",
                  else: "Enter your Netbox API token"
              }
            />
            <label class="flex items-center justify-between gap-2">
              <span class="text-xs text-sr-muted">
                Generate a token in Netbox: Admin → API Tokens
              </span>
            </label>
          </div>
          <div class="flex flex-col gap-1.5">
            <label class="flex items-center justify-between gap-2">
              <span class="text-sm font-medium text-sr-ink">Verify SSL</span>
            </label>
            <select name="cred_netbox_verify_ssl" class={ui_field_class(class: "w-full")}>
              <option value="true">Yes (recommended)</option>
              <option value="false">No (for self-signed certs)</option>
            </select>
          </div>
        </div>
      <% :custom -> %>
        <div class="space-y-3">
          <div class="flex flex-col gap-1.5">
            <label class="flex items-center justify-between gap-2">
              <span class="text-sm font-medium text-sr-ink">Credentials (JSON)</span>
            </label>
            <textarea
              name="credentials_json"
              class={ui_field_class(mono: true, class: "w-full min-h-24 py-2.5 text-sm")}
              rows="3"
              placeholder='{"api_key": "your-key", "api_secret": "your-secret"}'
            ></textarea>
            <label class="flex items-center justify-between gap-2">
              <span class="text-xs text-sr-muted">
                {if @mode == :edit, do: "Leave empty to keep existing credentials. ", else: ""}Credentials will be encrypted at rest
              </span>
            </label>
          </div>
        </div>
      <% _ -> %>
        <div class="space-y-3">
          <div class="flex flex-col gap-1.5">
            <label class="flex items-center justify-between gap-2">
              <span class="text-sm font-medium text-sr-ink">Credentials (JSON)</span>
            </label>
            <textarea
              name="credentials_json"
              class={ui_field_class(mono: true, class: "w-full min-h-24 py-2.5 text-sm")}
              rows="3"
              placeholder={credential_placeholder(@source_type)}
            ></textarea>
            <label class="flex items-center justify-between gap-2">
              <span class="text-xs text-sr-muted">
                {if @mode == :edit, do: "Leave empty to keep existing credentials. ", else: ""}Credentials will be encrypted at rest
              </span>
            </label>
          </div>
        </div>
    <% end %>
    """
  end

  attr :selected, :list, default: []

  defp fact_authority_fields(assigns) do
    ~H"""
    <div class="sr-ui-divider text-xs text-sr-muted">Source fact authority</div>
    <p class="text-xs text-sr-muted">
      When Armis and another inventory source disagree, this source can win for the selected facts.
      Plugin packages cannot set this.
    </p>
    <div class="space-y-2">
      <label class="flex items-center gap-3 text-sm">
        <input
          type="checkbox"
          name="form[fact_authority][]"
          value="switch_port_attachment"
          class={ui_toggle_class()}
          checked={"switch_port_attachment" in @selected}
        />
        <span>This source wins for switch port</span>
      </label>
      <label class="flex items-center gap-3 text-sm">
        <input
          type="checkbox"
          name="form[fact_authority][]"
          value="vlan_uid"
          class={ui_toggle_class()}
          checked={"vlan_uid" in @selected}
        />
        <span>This source wins for VLAN</span>
      </label>
    </div>
    """
  end

  defp fact_authority_selected(%{settings: settings}) when is_map(settings) do
    settings
    |> Map.get("fact_authority", Map.get(settings, :fact_authority, []))
    |> List.wrap()
    |> Enum.map(&to_string/1)
  end

  defp fact_authority_selected(_source), do: []

  defp sync_fact_authority(source, params, actor) do
    keys =
      params
      |> Map.get("fact_authority", Map.get(params, :fact_authority, []))
      |> List.wrap()
      |> Enum.map(&to_string/1)

    ServiceRadar.Inventory.SourceFacts.Catalog.sync(
      "integration_source",
      to_string(source.id),
      to_string(source.source_type),
      to_string(source.id),
      keys,
      actor: actor
    )
  end

  attr(:form, :any, required: true)
  attr(:custom_fields_value, :string, default: "")

  defp armis_northbound_fields(assigns) do
    ~H"""
    <div class="sr-ui-divider text-xs text-sr-muted">Armis Northbound</div>

    <div class="space-y-4 rounded-xl border border-sr-line bg-sr-surface/70 p-4">
      <label class="flex items-center gap-3 text-sm">
        <input type="hidden" name="form[northbound_enabled]" value="false" />
        <input
          type="checkbox"
          name="form[northbound_enabled]"
          value="true"
          class={ui_toggle_class()}
          checked={truthy(@form[:northbound_enabled].value)}
        />
        <span>Enable northbound Armis availability updates</span>
      </label>

      <div class="grid grid-cols-1 gap-4 md:grid-cols-2">
        <.input
          field={@form[:northbound_interval_seconds]}
          type="number"
          label="Northbound Interval (sec)"
          placeholder="3600"
        />

        <div class="flex flex-col gap-1.5">
          <label class="flex items-center justify-between gap-2">
            <span class="text-sm font-medium text-sr-ink">Armis Custom Property / Tag</span>
          </label>
          <input
            type="text"
            name="custom_fields_text"
            class={ui_field_class(mono: true, class: "w-full text-sm")}
            value={@custom_fields_value}
            placeholder="availability"
            phx-blur="update_custom_fields"
          />
          <label class="flex items-center justify-between gap-2">
            <span class="text-xs text-sr-muted">
              The updater uses the first configured value as the target property in Armis.
            </span>
          </label>
        </div>
      </div>
    </div>
    """
  end

  defp credential_placeholder(:syslog), do: ~s({"syslog_host": "0.0.0.0", "syslog_port": 514})

  defp credential_placeholder(:netbox), do: ~s({"url": "https://netbox.example.com", "token": "your-api-token"})

  defp credential_placeholder(:nmap), do: ~s({"timing_template": "T4", "extra_args": ""})
  defp credential_placeholder(_), do: ~s({"api_key": "your-key", "api_secret": "your-secret"})

  defp source_credentials(%{credentials: credentials}) when is_map(credentials), do: credentials
  defp source_credentials(_), do: %{}

  defp credential_value(credentials, keys) when is_map(credentials) and is_list(keys) do
    Enum.find_value(keys, &credential_value(credentials, &1))
  end

  defp credential_value(credentials, key) when is_map(credentials) do
    value = Map.get(credentials, key) || Map.get(credentials, credential_atom_key(key))

    case value do
      value when is_binary(value) -> value
      nil -> nil
      value -> to_string(value)
    end
  end

  defp credential_value(_, _), do: nil

  defp credential_atom_key("api_key"), do: :api_key
  defp credential_atom_key("api_secret"), do: :api_secret
  defp credential_atom_key("secret_key"), do: :secret_key
  defp credential_atom_key("client_id"), do: :client_id
  defp credential_atom_key("v3_client_id"), do: :v3_client_id
  defp credential_atom_key("client_secret"), do: :client_secret
  defp credential_atom_key("v3_client_secret"), do: :v3_client_secret
  defp credential_atom_key("vendor_id"), do: :vendor_id
  defp credential_atom_key("v3_vendor_id"), do: :v3_vendor_id
  defp credential_atom_key(_), do: nil

  defp credential_present?(credentials, keys) when is_map(credentials) and is_list(keys) do
    Enum.any?(keys, fn key ->
      case credential_value(credentials, key) do
        nil -> false
        "" -> false
        value -> String.trim(value) != ""
      end
    end)
  end

  defp credential_present?(_, _), do: false
end
