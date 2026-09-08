defmodule ServiceRadarWebNGWeb.AuthoredDashboardLive.Show do
  @moduledoc false
  use ServiceRadarWebNGWeb, :live_view

  import ServiceRadarWebNGWeb.AuthoredDashboardLive.PanelComponents
  import ServiceRadarWebNGWeb.AuthoredDashboardLive.PanelComposerComponents
  import ServiceRadarWebNGWeb.AuthoredDashboardLive.VariableComponents
  import ServiceRadarWebNGWeb.AuthoredDashboardLive.WorkbenchComponents

  alias ServiceRadarWebNG.Dashboards
  alias ServiceRadarWebNG.Dashboards.SystemReports
  alias ServiceRadarWebNGWeb.AuthoredDashboardLive.AccessControls
  alias ServiceRadarWebNGWeb.AuthoredDashboardLive.CanvasState
  alias ServiceRadarWebNGWeb.AuthoredDashboardLive.DashboardVariables
  alias ServiceRadarWebNGWeb.AuthoredDashboardLive.LayoutHelpers
  alias ServiceRadarWebNGWeb.AuthoredDashboardLive.PanelParams
  alias ServiceRadarWebNGWeb.AuthoredDashboardLive.ReportSchedules
  alias ServiceRadarWebNGWeb.AuthoredDashboardLive.RuntimeData
  alias ServiceRadarWebNGWeb.AuthoredDashboardLive.SourceQueries

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "Dashboard")
      |> assign(:current_path, nil)
      |> assign(:dashboard, nil)
      |> assign(:access_grants, [])
      |> assign(:user_groups, [])
      |> assign(:users, [])
      |> assign(:panel_results, %{})
      |> assign(:trend_results, %{})
      |> assign(:variable_values, %{})
      |> assign(:expanded_srql_panel_ids, MapSet.new())
      |> assign(:clone_targets, [])
      |> assign(:clone_target_id, "")
      |> assign(:settings_open?, false)
      |> assign(:editing_panel_id, nil)
      |> assign(:panel_preview, nil)
      |> assign(:source_query_params, SourceQueries.default_params())
      |> assign(:source_query_preview, nil)
      |> assign(:can_edit?, AccessControls.can_edit?(socket.assigns.current_scope))
      |> assign(:can_share?, AccessControls.can_share?(socket.assigns.current_scope))
      |> assign(:can_schedule_reports?, AccessControls.can_schedule_reports?(socket.assigns.current_scope))
      |> assign(:can_view_groups?, AccessControls.can_view_groups?(socket.assigns.current_scope))
      |> assign(
        :can_view_share_principals?,
        AccessControls.can_view_share_principals?(socket.assigns.current_scope)
      )
      |> assign(:user_grant_params, AccessControls.default_user_grant_params())
      |> assign(:group_grant_params, AccessControls.default_group_grant_params())
      |> assign(:report_schedule_params, ReportSchedules.default_params())
      |> assign(:panel_params, PanelParams.default())
      |> assign(:loading?, connected?(socket))
      |> assign_grant_forms()
      |> assign_report_schedule_form()
      |> assign_source_query_form()
      |> assign_panel_form()

    {:ok, socket}
  end

  @impl true
  def handle_params(%{"dashboard_id" => dashboard_id}, _uri, socket) do
    scope = socket.assigns.current_scope
    access_assigns = AccessControls.assigns(socket.assigns)
    current_variable_values = socket.assigns.variable_values

    socket =
      if connected?(socket) do
        start_async(socket, {:load_dashboard, dashboard_id}, fn ->
          RuntimeData.load_dashboard(scope, dashboard_id, current_variable_values, access_assigns)
        end)
      else
        socket
      end

    {:noreply, assign(socket, :current_path, "/dashboard/#{dashboard_id}")}
  end

  def handle_params(_params, _uri, socket) do
    {:noreply, push_navigate(socket, to: ~p"/analytics")}
  end

  @impl true
  def handle_async(
        {:load_dashboard, _dashboard_id},
        {:ok, {:ok, dashboard, panels, results, trends, variable_values, access, clone_targets}},
        socket
      ) do
    dashboard = Map.put(dashboard, :panels, panels)

    if new_devices_report?(dashboard) do
      {:noreply, push_navigate(socket, to: ~p"/dashboard/new-devices")}
    else
      {:noreply,
       socket
       |> assign(:dashboard, dashboard)
       |> assign(:panel_results, results)
       |> assign(:trend_results, trends)
       |> assign(:variable_values, variable_values)
       |> assign(:clone_targets, clone_targets)
       |> assign(:clone_target_id, RuntimeData.default_clone_target_id(clone_targets))
       |> assign(access)
       |> assign(:page_title, dashboard.title)
       |> assign(:loading?, false)
       |> assign_grant_forms()
       |> assign_panel_form()}
    end
  end

  def handle_async({:load_dashboard, _dashboard_id}, {:ok, {:error, :not_found}}, socket) do
    {:noreply,
     socket
     |> assign(:loading?, false)
     |> put_flash(:error, "Dashboard not found")
     |> push_navigate(to: ~p"/analytics")}
  end

  def handle_async({:load_dashboard, _dashboard_id}, {:ok, {:error, reason}}, socket) do
    {:noreply,
     socket
     |> assign(:loading?, false)
     |> put_flash(:error, "Could not load dashboard: #{format_error(reason)}")}
  end

  def handle_async({:load_dashboard, _dashboard_id}, {:exit, reason}, socket) do
    {:noreply,
     socket
     |> assign(:loading?, false)
     |> put_flash(:error, "Could not load dashboard: #{format_error(reason)}")}
  end

  @impl true
  def handle_event("validate_user_grant", %{"grant" => params}, socket) do
    {:noreply,
     socket
     |> assign(:user_grant_params, merge_params(socket.assigns.user_grant_params, params))
     |> assign_grant_forms()}
  end

  def handle_event("open_settings", _params, socket) do
    if AccessControls.settings_available?(socket.assigns.dashboard, socket.assigns) do
      {:noreply, assign(socket, :settings_open?, true)}
    else
      {:noreply, put_flash(socket, :error, "Not authorized to manage dashboard settings")}
    end
  end

  def handle_event("close_settings", _params, socket) do
    {:noreply, assign(socket, :settings_open?, false)}
  end

  def handle_event("edit_panel", %{"id" => id}, socket) do
    panel = Enum.find(socket.assigns.dashboard.panels || [], &(&1.id == id))

    case require_record(panel) do
      {:ok, panel} ->
        panel_preview = PanelParams.preview_from_result(Map.get(socket.assigns.panel_results, panel.id), panel)

        {:noreply,
         socket
         |> assign(:settings_open?, true)
         |> assign(:editing_panel_id, panel.id)
         |> assign(:panel_preview, panel_preview)
         |> assign(:panel_params, PanelParams.from_panel(panel))
         |> assign_panel_form()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Panel not found: #{format_error(reason)}")}
    end
  end

  def handle_event("cancel_panel_edit", _params, socket) do
    {:noreply,
     socket
     |> assign(:editing_panel_id, nil)
     |> assign(:panel_preview, nil)
     |> assign(:panel_params, PanelParams.default())
     |> assign_panel_form()}
  end

  def handle_event("new_panel", _params, socket) do
    case AccessControls.authorize_panel_edit(socket) do
      :ok ->
        {:noreply,
         socket
         |> assign(:settings_open?, true)
         |> assign(:editing_panel_id, "new")
         |> assign(:panel_preview, nil)
         |> assign(:panel_params, PanelParams.default())
         |> assign_panel_form()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Panel create failed: #{format_error(reason)}")}
    end
  end

  def handle_event("validate_source_query", %{"source_query" => params}, socket) do
    {:noreply,
     socket
     |> assign(:source_query_params, merge_params(socket.assigns.source_query_params, params))
     |> assign_source_query_form()}
  end

  def handle_event("apply_source_template", %{"key" => key}, socket) do
    case SourceQueries.template_query(key) do
      nil ->
        {:noreply, socket}

      query ->
        params = Map.put(socket.assigns.source_query_params, "srql_query", query)

        {:noreply,
         socket
         |> assign(:source_query_params, params)
         |> assign_source_query_form()}
    end
  end

  def handle_event("load_source_query", %{"id" => id}, socket) do
    case SourceQueries.find_source(socket.assigns.dashboard, id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Source query not found")}

      source ->
        {:noreply,
         socket
         |> assign(:source_query_params, SourceQueries.source_params(source))
         |> assign(:source_query_preview, nil)
         |> assign_source_query_form()
         |> put_flash(:info, "Source query loaded")}
    end
  end

  def handle_event("remove_source_query", %{"id" => id}, socket) do
    source = SourceQueries.find_source(socket.assigns.dashboard, id)

    with :ok <- AccessControls.authorize_panel_edit(socket),
         {:ok, source} <- require_record(source),
         0 <- source.panel_count,
         {:ok, dashboard} <- SourceQueries.remove_source(socket.assigns.current_scope, socket.assigns.dashboard, id) do
      {:noreply,
       socket
       |> assign(:dashboard, dashboard)
       |> put_flash(:info, "Source query removed")}
    else
      count when is_integer(count) ->
        {:noreply, put_flash(socket, :error, "Remove linked panels before deleting this source")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Source query removal failed: #{format_error(reason)}")}
    end
  end

  def handle_event("run_source_query", %{"source_query" => params}, socket) do
    with :ok <- AccessControls.authorize_panel_edit(socket),
         params = merge_params(socket.assigns.source_query_params, params),
         {:ok, preview} <-
           Dashboards.preview_authored_query(socket.assigns.current_scope, params["srql_query"]) do
      source = SourceQueries.source_from_preview(params, preview)
      preview = Map.put(preview, :outputs, source.outputs)

      {:noreply,
       socket
       |> assign(:source_query_params, params)
       |> assign(:source_query_preview, preview)
       |> assign_source_query_form()
       |> put_flash(:info, "Source query preview loaded")}
    else
      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:source_query_preview, nil)
         |> put_flash(:error, "Source query preview failed: #{format_error(reason)}")}
    end
  end

  def handle_event("create_source_output", %{"visual-type" => visual_type}, socket) do
    with :ok <- AccessControls.authorize_panel_edit(socket),
         %{source_query_preview: preview, dashboard: %{}} <- socket.assigns,
         true <- is_map(preview),
         source = SourceQueries.source_from_preview(socket.assigns.source_query_params, preview),
         {:ok, dashboard} <-
           SourceQueries.persist_source(socket.assigns.current_scope, socket.assigns.dashboard, source),
         attrs =
           SourceQueries.panel_attrs_from_output(dashboard, source, visual_type, socket.assigns.source_query_params),
         {:ok, panel} <- Dashboards.create_authored_panel(socket.assigns.current_scope, attrs) do
      panels =
        dashboard.panels
        |> List.wrap()
        |> Kernel.++([panel])
        |> Enum.sort_by(&{&1.position, &1.inserted_at})

      dashboard = %{dashboard | panels: panels}

      {:noreply,
       socket
       |> assign(:dashboard, dashboard)
       |> assign(:editing_panel_id, panel.id)
       |> assign(:panel_params, PanelParams.from_panel(panel))
       |> assign(:panel_preview, preview)
       |> assign_panel_form()
       |> put_flash(:info, "Added #{SourceQueries.humanize_field(visual_type)} output to the canvas")}
    else
      false ->
        {:noreply, put_flash(socket, :error, "Run a source query before adding an output")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Output creation failed: #{format_error(reason)}")}

      _ ->
        {:noreply, put_flash(socket, :error, "Run a source query before adding an output")}
    end
  end

  def handle_event("canvas_add_panel", %{"visualType" => visual_type}, socket) do
    case AccessControls.authorize_panel_edit(socket) do
      :ok ->
        visual_type = CanvasState.visual_type(visual_type)
        layout = CanvasState.new_panel_layout(visual_type, socket.assigns.dashboard.panels || [])

        params =
          Map.merge(PanelParams.default(), %{
            "title" => "#{SourceQueries.humanize_field(visual_type)} Panel",
            "visual_type" => visual_type,
            "layout_x" => to_string(Map.get(layout, "x", 0)),
            "layout_y" => to_string(Map.get(layout, "y", 0)),
            "layout_w" => to_string(Map.get(layout, "w", 12)),
            "layout_h" => to_string(Map.get(layout, "h", 8)),
            "position" => to_string(length(socket.assigns.dashboard.panels || []))
          })

        {:noreply,
         socket
         |> assign(:settings_open?, true)
         |> assign(:editing_panel_id, "new")
         |> assign(:panel_preview, nil)
         |> assign(:panel_params, params)
         |> assign_panel_form()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Panel create failed: #{format_error(reason)}")}
    end
  end

  def handle_event("canvas_select_panel", %{"id" => id}, socket) do
    handle_event("edit_panel", %{"id" => id}, socket)
  end

  def handle_event("canvas_layout_change", %{"layouts" => layouts}, socket) when is_list(layouts) do
    with :ok <- AccessControls.authorize_panel_edit(socket),
         {:ok, panels} <-
           CanvasState.update_panel_layouts(
             socket.assigns.current_scope,
             socket.assigns.dashboard.panels || [],
             layouts
           ) do
      dashboard = Map.put(socket.assigns.dashboard, :panels, panels)

      socket =
        socket
        |> assign(:dashboard, dashboard)
        |> maybe_refresh_editing_panel_params(panels)

      {:noreply, socket}
    else
      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Layout update failed: #{format_error(reason)}")}
    end
  end

  def handle_event("canvas_layout_change", _params, socket), do: {:noreply, socket}

  def handle_event("validate_panel", %{"panel" => params}, socket) do
    {:noreply,
     socket
     |> assign(:panel_params, merge_params(socket.assigns.panel_params, params))
     |> assign_panel_form()}
  end

  def handle_event("preview_panel_edit", %{"panel" => params}, socket) do
    params = merge_params(socket.assigns.panel_params, params)
    preview_panel_edit(socket, params)
  end

  def handle_event("preview_panel_edit", _params, socket) do
    preview_panel_edit(socket, socket.assigns.panel_params)
  end

  def handle_event("submit_panel_form", %{"intent" => "preview", "panel" => params}, socket) do
    params = merge_params(socket.assigns.panel_params, params)
    preview_panel_edit(socket, params)
  end

  def handle_event("submit_panel_form", %{"panel" => params}, socket) do
    handle_event("save_panel", %{"panel" => params}, socket)
  end

  def handle_event("change_variable", %{"variables" => params}, socket) do
    values = DashboardVariables.values(socket.assigns.dashboard, params)

    {:noreply,
     socket
     |> assign(:variable_values, values)
     |> reload_dashboard_panels()}
  end

  def handle_event("refresh_panel", %{"id" => id}, socket) do
    panel = Enum.find(socket.assigns.dashboard.panels || [], &(&1.id == id))
    variables = DashboardVariables.list(socket.assigns.dashboard)

    case require_record(panel) do
      {:ok, panel} ->
        result =
          RuntimeData.preview_panel_query(
            socket.assigns.current_scope,
            panel,
            socket.assigns.variable_values,
            variables
          )

        trend =
          RuntimeData.preview_trend_query(
            socket.assigns.current_scope,
            panel,
            socket.assigns.variable_values,
            variables
          )

        {:noreply,
         socket
         |> assign(:panel_results, Map.put(socket.assigns.panel_results, panel.id, result))
         |> assign(:trend_results, Map.put(socket.assigns.trend_results, panel.id, trend))
         |> put_flash(:info, "Panel refreshed")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Panel refresh failed: #{format_error(reason)}")}
    end
  end

  def handle_event("toggle_panel_srql", %{"id" => id}, socket) do
    expanded =
      if MapSet.member?(socket.assigns.expanded_srql_panel_ids, id) do
        MapSet.delete(socket.assigns.expanded_srql_panel_ids, id)
      else
        MapSet.put(socket.assigns.expanded_srql_panel_ids, id)
      end

    {:noreply, assign(socket, :expanded_srql_panel_ids, expanded)}
  end

  def handle_event("duplicate_panel", %{"id" => id}, socket) do
    panel = Enum.find(socket.assigns.dashboard.panels || [], &(&1.id == id))

    with :ok <- AccessControls.authorize_panel_edit(socket),
         {:ok, panel} <- require_record(panel),
         {:ok, _panel} <-
           Dashboards.create_authored_panel(
             socket.assigns.current_scope,
             PanelParams.duplicate_attrs(panel, socket.assigns.dashboard)
           ) do
      {:noreply,
       socket
       |> put_flash(:info, "Panel duplicated")
       |> reload_dashboard_panels()}
    else
      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Panel duplicate failed: #{format_error(reason)}")}
    end
  end

  def handle_event("delete_panel", %{"id" => id}, socket) do
    panel = Enum.find(socket.assigns.dashboard.panels || [], &(&1.id == id))

    with :ok <- AccessControls.authorize_panel_edit(socket),
         {:ok, panel} <- require_record(panel),
         :ok <- Dashboards.delete_authored_panel(socket.assigns.current_scope, panel) do
      socket =
        if socket.assigns.editing_panel_id == id do
          socket
          |> assign(:editing_panel_id, nil)
          |> assign(:panel_preview, nil)
          |> assign(:panel_params, PanelParams.default())
          |> assign_panel_form()
        else
          socket
        end

      {:noreply,
       socket
       |> put_flash(:info, "Panel deleted")
       |> reload_dashboard_panels()}
    else
      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Panel delete failed: #{format_error(reason)}")}
    end
  end

  def handle_event("clone_panel", %{"panel_id" => id, "target_dashboard_id" => target_dashboard_id}, socket) do
    panel = Enum.find(socket.assigns.dashboard.panels || [], &(&1.id == id))

    with :ok <- AccessControls.authorize_panel_edit(socket),
         {:ok, panel} <- require_record(panel),
         {:ok, target} <-
           Dashboards.get_authored_dashboard(socket.assigns.current_scope, target_dashboard_id, load: [:panels]),
         {:ok, _panel} <-
           Dashboards.create_authored_panel(
             socket.assigns.current_scope,
             PanelParams.duplicate_attrs(panel, target)
           ) do
      {:noreply, put_flash(socket, :info, "Panel cloned to #{target.title}")}
    else
      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Panel clone failed: #{format_error(reason)}")}
    end
  end

  def handle_event("clone_target", %{"target_dashboard_id" => target_dashboard_id}, socket) do
    {:noreply, assign(socket, :clone_target_id, target_dashboard_id)}
  end

  def handle_event("compact_layout", _params, socket) do
    with :ok <- AccessControls.authorize_panel_edit(socket),
         {:ok, panels} <-
           CanvasState.compact_panel_layouts(
             socket.assigns.current_scope,
             socket.assigns.dashboard.panels || []
           ) do
      dashboard = Map.put(socket.assigns.dashboard, :panels, panels)

      {:noreply,
       socket
       |> assign(:dashboard, dashboard)
       |> put_flash(:info, "Dashboard layout compacted")}
    else
      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Layout compact failed: #{format_error(reason)}")}
    end
  end

  def handle_event("save_panel", %{"panel" => params}, socket) do
    panel =
      Enum.find(
        socket.assigns.dashboard.panels || [],
        &(&1.id == socket.assigns.editing_panel_id)
      )

    params = merge_params(socket.assigns.panel_params, params)

    save_result =
      if socket.assigns.editing_panel_id == "new" do
        with :ok <- AccessControls.authorize_panel_edit(socket) do
          attrs =
            params
            |> PanelParams.attrs()
            |> Map.put(:dashboard_id, socket.assigns.dashboard.id)

          Dashboards.create_authored_panel(socket.assigns.current_scope, attrs)
        end
      else
        with :ok <- AccessControls.authorize_panel_edit(socket),
             {:ok, panel} <- require_record(panel) do
          Dashboards.update_authored_panel(socket.assigns.current_scope, panel, PanelParams.attrs(params))
        end
      end

    case save_result do
      {:ok, _panel} ->
        {:noreply,
         socket
         |> put_flash(:info, if(socket.assigns.editing_panel_id == "new", do: "Panel created", else: "Panel updated"))
         |> assign(:editing_panel_id, nil)
         |> assign(:panel_preview, nil)
         |> assign(:panel_params, PanelParams.default())
         |> reload_dashboard_panels()
         |> assign_panel_form()}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:panel_params, params)
         |> assign_panel_form()
         |> put_flash(:error, "Panel update failed: #{format_error(reason)}")}
    end
  end

  def handle_event("validate_group_grant", %{"grant" => params}, socket) do
    {:noreply,
     socket
     |> assign(:group_grant_params, merge_params(socket.assigns.group_grant_params, params))
     |> assign_grant_forms()}
  end

  def handle_event("grant_user", %{"grant" => params}, socket) do
    params = merge_params(socket.assigns.user_grant_params, params)

    with :ok <- AccessControls.authorize_share(socket),
         {:ok, _grant} <-
           Dashboards.grant_authored_dashboard_to_user(
             socket.assigns.current_scope,
             Map.put(params, "dashboard_id", socket.assigns.dashboard.id)
           ) do
      {:noreply,
       socket
       |> put_flash(:info, "User access updated")
       |> assign(:user_grant_params, AccessControls.default_user_grant_params())
       |> reload_access_controls()}
    else
      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:user_grant_params, params)
         |> assign_grant_forms()
         |> put_flash(:error, "User grant failed: #{format_error(reason)}")}
    end
  end

  def handle_event("grant_group", %{"grant" => params}, socket) do
    params = merge_params(socket.assigns.group_grant_params, params)

    with :ok <- AccessControls.authorize_share(socket),
         {:ok, _grant} <-
           Dashboards.grant_authored_dashboard_to_group(
             socket.assigns.current_scope,
             Map.put(params, "dashboard_id", socket.assigns.dashboard.id)
           ) do
      {:noreply,
       socket
       |> put_flash(:info, "Group access updated")
       |> assign(:group_grant_params, AccessControls.default_group_grant_params())
       |> reload_access_controls()}
    else
      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:group_grant_params, params)
         |> assign_grant_forms()
         |> put_flash(:error, "Group grant failed: #{format_error(reason)}")}
    end
  end

  def handle_event("revoke_grant", %{"id" => id}, socket) do
    grant = Enum.find(socket.assigns.access_grants, &(&1.id == id))

    with :ok <- AccessControls.authorize_share(socket),
         {:ok, grant} <- require_record(grant),
         :ok <- Dashboards.revoke_authored_access_grant(socket.assigns.current_scope, grant) do
      {:noreply, socket |> put_flash(:info, "Access revoked") |> reload_access_controls()}
    else
      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Revoke failed: #{format_error(reason)}")}
    end
  end

  def handle_event("validate_report_schedule", %{"schedule" => params}, socket) do
    {:noreply,
     socket
     |> assign(
       :report_schedule_params,
       merge_params(socket.assigns.report_schedule_params, params)
     )
     |> assign_report_schedule_form()}
  end

  def handle_event("create_report_schedule", %{"schedule" => params}, socket) do
    params = merge_params(socket.assigns.report_schedule_params, params)

    attrs = ReportSchedules.attrs(params, socket.assigns.dashboard.id)

    with :ok <- AccessControls.authorize_report_schedule(socket),
         {:ok, _schedule} <-
           Dashboards.create_authored_report_schedule(socket.assigns.current_scope, attrs) do
      {:noreply,
       socket
       |> put_flash(:info, "Report schedule created")
       |> assign(:report_schedule_params, ReportSchedules.default_params())
       |> reload_report_schedules()
       |> assign_report_schedule_form()}
    else
      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:report_schedule_params, params)
         |> assign_report_schedule_form()
         |> put_flash(:error, "Schedule create failed: #{format_error(reason)}")}
    end
  end

  def handle_event("toggle_report_schedule", %{"id" => id}, socket) do
    schedule = Enum.find(socket.assigns.dashboard.report_schedules || [], &(&1.id == id))

    attrs = ReportSchedules.toggle_attrs(schedule)

    with :ok <- AccessControls.authorize_report_schedule(socket),
         {:ok, schedule} <- require_record(schedule),
         {:ok, _schedule} <-
           Dashboards.update_authored_report_schedule(
             socket.assigns.current_scope,
             schedule,
             attrs
           ) do
      {:noreply, socket |> put_flash(:info, "Report schedule updated") |> reload_report_schedules()}
    else
      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Schedule update failed: #{format_error(reason)}")}
    end
  end

  def handle_event("delete_report_schedule", %{"id" => id}, socket) do
    schedule = Enum.find(socket.assigns.dashboard.report_schedules || [], &(&1.id == id))

    with :ok <- AccessControls.authorize_report_schedule(socket),
         {:ok, schedule} <- require_record(schedule),
         :ok <- Dashboards.delete_authored_report_schedule(socket.assigns.current_scope, schedule) do
      {:noreply, socket |> put_flash(:info, "Report schedule deleted") |> reload_report_schedules()}
    else
      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Schedule delete failed: #{format_error(reason)}")}
    end
  end

  defp preview_panel_edit(socket, params) do
    case Dashboards.preview_authored_query(socket.assigns.current_scope, params["srql_query"]) do
      {:ok, preview} ->
        requested_visual = to_string(params["visual_type"] || "table")
        visual = PanelParams.selected_visual(params["visual_type"], preview.compatible_visuals)
        params = PanelParams.default_binding_params(params, preview, visual)
        flash_message = PanelParams.preview_flash(requested_visual, visual)

        {:noreply,
         socket
         |> assign(:panel_params, Map.put(params, "visual_type", visual))
         |> assign(:panel_preview, preview)
         |> assign_panel_form()
         |> put_flash(:info, flash_message)}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:panel_params, params)
         |> assign(:panel_preview, nil)
         |> assign_panel_form()
         |> put_flash(:error, "Panel preview failed: #{format_error(reason)}")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_path={@current_path}
      page_title={if @dashboard, do: @dashboard.title, else: "Dashboard"}
      shell={:operations}
    >
      <div class="mx-auto flex w-full max-w-7xl flex-col gap-4 px-4 py-4 sm:px-6 lg:px-8">
        <.variable_bar
          :if={@dashboard && DashboardVariables.list(@dashboard) != []}
          dashboard={@dashboard}
          values={@variable_values}
        />

        <.dashboard_workbench
          dashboard={@dashboard}
          settings_open?={@settings_open?}
          source_query_form={@source_query_form}
          source_query_preview={@source_query_preview}
          panel_results={@panel_results}
          editing_panel_id={@editing_panel_id}
          access_grants={@access_grants}
          user_grant_form={@user_grant_form}
          group_grant_form={@group_grant_form}
          users={@users}
          user_groups={@user_groups}
          can_view_groups?={@can_view_groups?}
          report_schedule_form={@report_schedule_form}
          current_scope={@current_scope}
          can_edit?={@can_edit?}
          can_share?={@can_share?}
          can_schedule_reports?={@can_schedule_reports?}
        />

        <.panel_composer_modal
          dashboard={@dashboard}
          editing_panel_id={@editing_panel_id}
          panel_form={@panel_form}
          panel_preview={@panel_preview}
          panel_results={@panel_results}
          clone_targets={@clone_targets}
          clone_target_id={@clone_target_id}
        />

        <div
          :if={@loading?}
          class="rounded-lg border border-sr-line bg-sr-surface p-6 text-sm text-sr-muted"
        >
          Loading dashboard panels...
        </div>

        <div
          :if={(!@loading? and @dashboard) && Enum.empty?(@dashboard.panels || [])}
          class="rounded-lg border border-sr-line bg-sr-surface p-6 text-sm text-sr-muted"
        >
          This dashboard does not have any panels yet.
        </div>

        <section
          :if={!@loading? and @dashboard}
          class="sr-authored-dashboard-grid grid grid-cols-1 gap-4 lg:grid-cols-12"
        >
          <.panel_result
            :for={entry <- LayoutHelpers.dashboard_panel_entries(@dashboard)}
            panel={entry.panel}
            result={Map.get(@panel_results, entry.panel.id)}
            trend={Map.get(@trend_results, entry.panel.id)}
            style={entry.style}
            expanded_srql?={MapSet.member?(@expanded_srql_panel_ids, entry.panel.id)}
            can_manage?={AccessControls.can_manage?(@dashboard, assigns)}
            csv_data_url={panel_csv_export_url(@dashboard, entry.panel, @variable_values)}
            timezone={@current_scope.user.timezone || "Etc/UTC"}
          />
        </section>

        <footer
          :if={!@loading? and @dashboard}
          class="flex flex-wrap items-center justify-between gap-3 border-t border-sr-line pt-4 text-xs text-sr-ink/55"
        >
          <span class="truncate">
            {@dashboard.description || "SRQL-authored dashboard"}
          </span>
          <div class="flex flex-wrap gap-2">
            <.ui_button
              :if={AccessControls.settings_available?(@dashboard, assigns) and !@settings_open?}
              type="button"
              phx-click="open_settings"
              size="xs"
              variant="primary"
            >
              <.icon name="hero-cog-6-tooth" class="size-4" /> Settings
            </.ui_button>
            <.ui_button
              :if={AccessControls.settings_available?(@dashboard, assigns) and @settings_open?}
              type="button"
              phx-click="close_settings"
              size="xs"
              variant="neutral"
            >
              <.icon name="hero-x-mark" class="size-4" /> Close Settings
            </.ui_button>
            <.ui_button navigate={~p"/analytics"} size="xs" variant="neutral">
              <.icon name="hero-pencil-square" class="size-4" /> Dashboard Creator
            </.ui_button>
          </div>
        </footer>
      </div>
    </Layouts.app>
    """
  end

  defp new_devices_report?(dashboard) do
    dashboard.slug == SystemReports.new_devices_slug() or
      Map.get(dashboard.metadata || %{}, "report_kind") == "new_devices"
  end

  defp panel_csv_export_url(dashboard, panel, variable_values) do
    dashboard_ref = Dashboards.authored_dashboard_route_ref(dashboard)
    query = %{vars: Jason.encode!(variable_values || %{})}

    ~p"/dashboard/#{dashboard_ref}/panels/#{panel.id}/export.csv?#{query}"
  end

  defp assign_grant_forms(socket) do
    socket
    |> assign(:user_grant_form, to_form(socket.assigns.user_grant_params, as: :grant))
    |> assign(:group_grant_form, to_form(socket.assigns.group_grant_params, as: :grant))
  end

  defp assign_report_schedule_form(socket) do
    assign(
      socket,
      :report_schedule_form,
      to_form(socket.assigns.report_schedule_params, as: :schedule)
    )
  end

  defp assign_source_query_form(socket) do
    assign(socket, :source_query_form, to_form(socket.assigns.source_query_params, as: :source_query))
  end

  defp assign_panel_form(socket) do
    assign(socket, :panel_form, to_form(socket.assigns.panel_params, as: :panel))
  end

  defp reload_access_controls(%{assigns: %{dashboard: dashboard}} = socket) do
    access =
      AccessControls.load(
        socket.assigns.current_scope,
        dashboard,
        AccessControls.assigns(socket.assigns)
      )

    socket
    |> assign(access)
    |> assign_grant_forms()
  end

  defp reload_access_controls(socket), do: socket

  defp reload_report_schedules(%{assigns: %{dashboard: %{id: dashboard_id} = dashboard}} = socket) do
    schedules =
      Dashboards.list_authored_report_schedules(socket.assigns.current_scope, dashboard_id)

    assign(socket, :dashboard, Map.put(dashboard, :report_schedules, schedules))
  end

  defp reload_report_schedules(socket), do: socket

  defp reload_dashboard_panels(%{assigns: %{dashboard: %{id: dashboard_id} = dashboard}} = socket) do
    panels = Dashboards.list_authored_panels(socket.assigns.current_scope, dashboard_id)
    variables = DashboardVariables.list(dashboard)

    results =
      RuntimeData.panel_results(socket.assigns.current_scope, panels, socket.assigns.variable_values, variables)

    trends =
      RuntimeData.trend_results(socket.assigns.current_scope, panels, socket.assigns.variable_values, variables)

    socket
    |> assign(:dashboard, Map.put(dashboard, :panels, panels))
    |> assign(:panel_results, results)
    |> assign(:trend_results, trends)
  end

  defp reload_dashboard_panels(socket), do: socket

  defp merge_params(current, incoming), do: Map.merge(current || %{}, incoming || %{})

  defp require_record(nil), do: {:error, :not_found}
  defp require_record(record), do: {:ok, record}

  defp maybe_refresh_editing_panel_params(socket, panels) do
    case socket.assigns.editing_panel_id do
      id when is_binary(id) and id != "new" ->
        case Enum.find(panels, &(&1.id == id)) do
          nil ->
            socket

          panel ->
            socket
            |> assign(:panel_params, PanelParams.from_panel(panel))
            |> assign_panel_form()
        end

      _ ->
        socket
    end
  end

  defp format_error(:forbidden), do: "Not authorized to share dashboards"
  defp format_error(:not_found), do: "Record not found"
  defp format_error({:reserved_dashboard_slug, slug}), do: "Dashboard slug #{slug} is reserved"

  defp format_error({:route_ref_dashboard_slug, slug}),
    do: "Dashboard slug #{slug} conflicts with generated dashboard IDs"

  defp format_error({:invalid_dashboard_slug, slug}),
    do: "Dashboard slug #{slug} must start with a letter and use only letters, numbers, and dashes"

  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)
end
