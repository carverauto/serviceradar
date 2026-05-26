defmodule ServiceRadarWebNGWeb.AuthoredDashboardLive.Show do
  @moduledoc false
  use ServiceRadarWebNGWeb, :live_view

  import ServiceRadarWebNGWeb.AuthoredDashboardLive.PanelComponents
  import ServiceRadarWebNGWeb.AuthoredDashboardLive.PanelFormComponents
  import ServiceRadarWebNGWeb.AuthoredDashboardLive.SourceQueryComponents
  import ServiceRadarWebNGWeb.AuthoredDashboardLive.VariableComponents

  alias ServiceRadar.Dashboards.AuthoredDashboard
  alias ServiceRadarWebNG.Dashboards
  alias ServiceRadarWebNG.RBAC
  alias ServiceRadarWebNGWeb.AuthoredDashboardLive.CanvasState
  alias ServiceRadarWebNGWeb.AuthoredDashboardLive.DashboardVariables
  alias ServiceRadarWebNGWeb.AuthoredDashboardLive.LayoutHelpers
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
      |> assign(:can_edit?, can_edit?(socket.assigns.current_scope))
      |> assign(:can_share?, can_share?(socket.assigns.current_scope))
      |> assign(:can_schedule_reports?, can_schedule_reports?(socket.assigns.current_scope))
      |> assign(:can_view_groups?, can_view_groups?(socket.assigns.current_scope))
      |> assign(
        :can_view_share_principals?,
        can_view_share_principals?(socket.assigns.current_scope)
      )
      |> assign(:user_grant_params, default_user_grant_params())
      |> assign(:group_grant_params, default_group_grant_params())
      |> assign(:report_schedule_params, default_report_schedule_params())
      |> assign(:panel_params, default_panel_params())
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
    access_assigns = access_assigns(socket.assigns)
    current_variable_values = socket.assigns.variable_values

    socket =
      if connected?(socket) do
        start_async(socket, {:load_dashboard, dashboard_id}, fn ->
          with {:ok, %AuthoredDashboard{} = dashboard} <-
                 Dashboards.get_authored_dashboard(scope, dashboard_id, load: [:panels, :report_schedules]) do
            panels = Enum.sort_by(dashboard.panels || [], &{&1.position, &1.inserted_at})
            variable_values = DashboardVariables.values(dashboard, current_variable_values)

            results =
              Map.new(panels, fn panel ->
                {panel.id, preview_panel_query(scope, panel, variable_values)}
              end)

            trends =
              Map.new(panels, fn panel ->
                {panel.id, preview_trend_query(scope, panel, variable_values)}
              end)

            access = load_access_controls(scope, dashboard, access_assigns)
            clone_targets = load_clone_targets(scope, dashboard)

            {:ok, dashboard, panels, results, trends, variable_values, access, clone_targets}
          end
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

    {:noreply,
     socket
     |> assign(:dashboard, dashboard)
     |> assign(:panel_results, results)
     |> assign(:trend_results, trends)
     |> assign(:variable_values, variable_values)
     |> assign(:clone_targets, clone_targets)
     |> assign(:clone_target_id, default_clone_target_id(clone_targets))
     |> assign(access)
     |> assign(:page_title, dashboard.title)
     |> assign(:loading?, false)
     |> assign_grant_forms()
     |> assign_panel_form()}
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
    if dashboard_settings_available?(socket.assigns.dashboard, socket.assigns) do
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
        panel_preview = panel_preview_from_result(Map.get(socket.assigns.panel_results, panel.id), panel)

        {:noreply,
         socket
         |> assign(:settings_open?, true)
         |> assign(:editing_panel_id, panel.id)
         |> assign(:panel_preview, panel_preview)
         |> assign(:panel_params, panel_to_params(panel))
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
     |> assign(:panel_params, default_panel_params())
     |> assign_panel_form()}
  end

  def handle_event("new_panel", _params, socket) do
    case authorize_panel_edit(socket) do
      :ok ->
        {:noreply,
         socket
         |> assign(:settings_open?, true)
         |> assign(:editing_panel_id, "new")
         |> assign(:panel_preview, nil)
         |> assign(:panel_params, default_panel_params())
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

  def handle_event("run_source_query", %{"source_query" => params}, socket) do
    with :ok <- authorize_panel_edit(socket),
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
    with :ok <- authorize_panel_edit(socket),
         %{source_query_preview: preview, dashboard: %{}} <- socket.assigns,
         true <- is_map(preview),
         source = SourceQueries.source_from_preview(socket.assigns.source_query_params, preview),
         {:ok, dashboard} <- persist_source_query(socket, source),
         attrs = SourceQueries.panel_attrs_from_output(dashboard, source, visual_type, socket.assigns.source_query_params),
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
       |> assign(:panel_params, panel_to_params(panel))
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
    case authorize_panel_edit(socket) do
      :ok ->
        visual_type = CanvasState.visual_type(visual_type)
        layout = CanvasState.new_panel_layout(visual_type, socket.assigns.dashboard.panels || [])

        params =
          Map.merge(default_panel_params(), %{
            "title" => "#{humanize_field(visual_type)} Panel",
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
    with :ok <- authorize_panel_edit(socket),
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

    case require_record(panel) do
      {:ok, panel} ->
        result = preview_panel_query(socket.assigns.current_scope, panel, socket.assigns.variable_values)
        trend = preview_trend_query(socket.assigns.current_scope, panel, socket.assigns.variable_values)

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

    with :ok <- authorize_panel_edit(socket),
         {:ok, panel} <- require_record(panel),
         {:ok, _panel} <-
           Dashboards.create_authored_panel(
             socket.assigns.current_scope,
             duplicate_panel_attrs(panel, socket.assigns.dashboard)
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

    with :ok <- authorize_panel_edit(socket),
         {:ok, panel} <- require_record(panel),
         :ok <- Dashboards.delete_authored_panel(socket.assigns.current_scope, panel) do
      socket =
        if socket.assigns.editing_panel_id == id do
          socket
          |> assign(:editing_panel_id, nil)
          |> assign(:panel_preview, nil)
          |> assign(:panel_params, default_panel_params())
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

    with :ok <- authorize_panel_edit(socket),
         {:ok, panel} <- require_record(panel),
         {:ok, target} <-
           Dashboards.get_authored_dashboard(socket.assigns.current_scope, target_dashboard_id, load: [:panels]),
         {:ok, _panel} <-
           Dashboards.create_authored_panel(
             socket.assigns.current_scope,
             duplicate_panel_attrs(panel, target)
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
    with :ok <- authorize_panel_edit(socket),
         {:ok, panels} <- compact_dashboard_panels(socket) do
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
        with :ok <- authorize_panel_edit(socket) do
          attrs =
            params
            |> panel_attrs()
            |> Map.put(:dashboard_id, socket.assigns.dashboard.id)

          Dashboards.create_authored_panel(socket.assigns.current_scope, attrs)
        end
      else
        with :ok <- authorize_panel_edit(socket),
             {:ok, panel} <- require_record(panel) do
          Dashboards.update_authored_panel(socket.assigns.current_scope, panel, panel_attrs(params))
        end
      end

    case save_result do
      {:ok, _panel} ->
        {:noreply,
         socket
         |> put_flash(:info, if(socket.assigns.editing_panel_id == "new", do: "Panel created", else: "Panel updated"))
         |> assign(:editing_panel_id, nil)
         |> assign(:panel_preview, nil)
         |> assign(:panel_params, default_panel_params())
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

    with :ok <- authorize_share(socket),
         {:ok, _grant} <-
           Dashboards.grant_authored_dashboard_to_user(
             socket.assigns.current_scope,
             Map.put(params, "dashboard_id", socket.assigns.dashboard.id)
           ) do
      {:noreply,
       socket
       |> put_flash(:info, "User access updated")
       |> assign(:user_grant_params, default_user_grant_params())
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

    with :ok <- authorize_share(socket),
         {:ok, _grant} <-
           Dashboards.grant_authored_dashboard_to_group(
             socket.assigns.current_scope,
             Map.put(params, "dashboard_id", socket.assigns.dashboard.id)
           ) do
      {:noreply,
       socket
       |> put_flash(:info, "Group access updated")
       |> assign(:group_grant_params, default_group_grant_params())
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

    with :ok <- authorize_share(socket),
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

    attrs =
      params
      |> Map.put("dashboard_id", socket.assigns.dashboard.id)
      |> Map.put("recipients", recipients(params["recipients"]))

    with :ok <- authorize_report_schedule(socket),
         {:ok, _schedule} <-
           Dashboards.create_authored_report_schedule(socket.assigns.current_scope, attrs) do
      {:noreply,
       socket
       |> put_flash(:info, "Report schedule created")
       |> assign(:report_schedule_params, default_report_schedule_params())
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

    attrs =
      case schedule do
        %{enabled: true} -> %{enabled: false}
        %{enabled: false} -> %{enabled: true}
        _ -> %{}
      end

    with :ok <- authorize_report_schedule(socket),
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

    with :ok <- authorize_report_schedule(socket),
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
        visual = selected_panel_visual(params["visual_type"], preview.compatible_visuals)
        params = default_panel_binding_params(params, preview, visual)
        flash_message = panel_preview_flash(requested_visual, visual)

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

        <section
          :if={@settings_open? and dashboard_settings_available?(@dashboard, assigns)}
          class="rounded-lg border border-slate-800/80 bg-[#0b1220]/90 text-slate-100 shadow-xl shadow-cyan-950/10 backdrop-blur-md"
        >
          <div class="flex flex-col gap-3 border-b border-slate-800/80 px-4 py-3 lg:flex-row lg:items-center lg:justify-between">
            <div>
              <p class="text-xs font-semibold uppercase tracking-normal text-cyan-400">
                Dashboard Workbench
              </p>
              <h2 class="mt-1 text-lg font-semibold tracking-normal text-slate-100">
                Compose and arrange panels
              </h2>
              <p class="text-xs text-slate-400">
                Map SRQL output into supported visuals, then drag and resize panels on the canvas.
              </p>
            </div>
            <div class="flex flex-wrap gap-2">
              <button
                :if={can_manage_dashboard?(@dashboard, assigns)}
                type="button"
                class="btn btn-sm btn-primary"
                phx-click="new_panel"
              >
                <.icon name="hero-plus" class="size-4" /> Add Panel
              </button>
              <button
                :if={can_manage_dashboard?(@dashboard, assigns)}
                type="button"
                class="btn btn-sm"
                phx-click="compact_layout"
              >
                <.icon name="hero-squares-plus" class="size-4" /> Compact Layout
              </button>
              <button type="button" class="btn btn-sm btn-ghost" phx-click="close_settings">
                <.icon name="hero-x-mark" class="size-4" /> Close
              </button>
            </div>
          </div>

          <div class="space-y-6 p-4">
            <section
              :if={can_manage_dashboard?(@dashboard, assigns)}
              class="rounded-lg border border-slate-800/80 bg-slate-950/40"
            >
              <div class="space-y-4 p-4">
                <.source_query_workbench
                  form={@source_query_form}
                  preview={@source_query_preview}
                  source_queries={SourceQueries.source_queries(@dashboard)}
                  templates={SourceQueries.templates()}
                  can_manage?={can_manage_dashboard?(@dashboard, assigns)}
                />

                <.dashboard_builder_canvas
                  id={"authored-dashboard-canvas-#{@dashboard.id}"}
                  panels={CanvasState.panels(@dashboard, @panel_results)}
                  visual_options={CanvasState.visual_options()}
                  selected_id={CanvasState.selected_panel_id(@editing_panel_id, @dashboard)}
                  can_manage={can_manage_dashboard?(@dashboard, assigns)}
                />
              </div>
            </section>

            <section
              :if={can_share_dashboard?(@dashboard, assigns)}
              class="rounded-lg border border-base-300"
            >
              <div class="flex flex-col gap-2 border-b border-base-300 px-3 py-2 sm:flex-row sm:items-center sm:justify-between">
                <div>
                  <h3 class="text-sm font-semibold">Sharing</h3>
                  <p class="text-xs text-base-content/70">
                    Visibility is {@dashboard.visibility}; explicit grants add users or reusable groups.
                  </p>
                </div>
                <span class="badge badge-outline">{length(@access_grants)} grants</span>
              </div>

              <div class="grid grid-cols-1 gap-6 p-3 lg:grid-cols-[1fr_360px]">
                <div class="space-y-3">
                  <div
                    :if={@access_grants == []}
                    class="rounded-lg border border-dashed border-base-300 p-4 text-sm text-base-content/60"
                  >
                    No explicit sharing grants yet.
                  </div>

                  <div
                    :for={grant <- @access_grants}
                    class="flex flex-col gap-3 rounded-lg border border-base-300 p-3 sm:flex-row sm:items-center sm:justify-between"
                  >
                    <div>
                      <div class="text-sm font-medium">{grant_label(grant)}</div>
                      <div class="mt-1 flex flex-wrap gap-2">
                        <span class="badge badge-sm">{grant.subject_type}</span>
                        <span class="badge badge-sm badge-outline">{grant.access}</span>
                      </div>
                    </div>
                    <button
                      type="button"
                      class="btn btn-xs btn-error btn-outline"
                      phx-click="revoke_grant"
                      phx-value-id={grant.id}
                    >
                      <.icon name="hero-trash" class="size-4" /> Revoke
                    </button>
                  </div>
                </div>

                <div class="space-y-4">
                  <.form
                    for={@user_grant_form}
                    as={:grant}
                    phx-change="validate_user_grant"
                    phx-submit="grant_user"
                    class="space-y-3"
                  >
                    <.input
                      field={@user_grant_form[:subject_user_id]}
                      type="select"
                      label="User"
                      options={user_select_options(@users)}
                    />
                    <.input
                      field={@user_grant_form[:access]}
                      type="select"
                      id="user_grant_access"
                      label="Access"
                      options={access_select_options()}
                    />
                    <button type="submit" class="btn btn-sm" disabled={@users == []}>
                      <.icon name="hero-user-plus" class="size-4" /> Grant User
                    </button>
                  </.form>

                  <.form
                    :if={@can_view_groups?}
                    for={@group_grant_form}
                    as={:grant}
                    phx-change="validate_group_grant"
                    phx-submit="grant_group"
                    class="space-y-3 border-t border-base-300 pt-4"
                  >
                    <.input
                      field={@group_grant_form[:subject_group_id]}
                      type="select"
                      label="Group"
                      options={group_select_options(@user_groups)}
                    />
                    <.input
                      field={@group_grant_form[:access]}
                      type="select"
                      id="group_grant_access"
                      label="Access"
                      options={access_select_options()}
                    />
                    <button type="submit" class="btn btn-sm" disabled={@user_groups == []}>
                      <.icon name="hero-user-group" class="size-4" /> Grant Group
                    </button>
                  </.form>
                </div>
              </div>
            </section>

            <section
              :if={can_schedule_dashboard?(@dashboard, assigns)}
              class="rounded-lg border border-base-300"
            >
              <div class="border-b border-base-300 px-3 py-2">
                <h3 class="text-sm font-semibold">Email Reports</h3>
                <p class="text-xs text-base-content/55">
                  One scanner job picks up due schedules and enqueues delivery attempts.
                </p>
              </div>

              <div class="grid grid-cols-1 gap-6 p-3 lg:grid-cols-[1fr_360px]">
                <div class="space-y-3">
                  <div
                    :if={(@dashboard.report_schedules || []) == []}
                    class="rounded-lg border border-dashed border-base-300 p-4 text-sm text-base-content/60"
                  >
                    No report schedules yet.
                  </div>

                  <div
                    :for={schedule <- @dashboard.report_schedules || []}
                    class="rounded-lg border border-base-300 p-3"
                  >
                    <div class="flex flex-col gap-2 sm:flex-row sm:items-center sm:justify-between">
                      <div>
                        <div class="text-sm font-medium">{schedule.name}</div>
                        <div class="mt-1 font-mono text-xs text-base-content/70">
                          {schedule.cron} · {schedule.timezone}
                        </div>
                      </div>
                      <div class="flex items-center gap-2">
                        <span class="badge badge-outline">
                          {schedule.last_status ||
                            if(schedule.enabled, do: "enabled", else: "disabled")}
                        </span>
                        <button
                          type="button"
                          class="btn btn-xs btn-ghost"
                          phx-click="toggle_report_schedule"
                          phx-value-id={schedule.id}
                        >
                          <.icon
                            name={if(schedule.enabled, do: "hero-pause", else: "hero-play")}
                            class="size-4"
                          />
                        </button>
                        <button
                          type="button"
                          class="btn btn-xs btn-ghost text-error"
                          phx-click="delete_report_schedule"
                          phx-value-id={schedule.id}
                        >
                          <.icon name="hero-trash" class="size-4" />
                        </button>
                      </div>
                    </div>
                    <p class="mt-2 text-xs text-base-content/70">
                      Next due: {format_value(schedule.next_due_at)}
                    </p>
                  </div>
                </div>

                <.form
                  for={@report_schedule_form}
                  as={:schedule}
                  phx-change="validate_report_schedule"
                  phx-submit="create_report_schedule"
                  class="space-y-3"
                >
                  <.input field={@report_schedule_form[:name]} type="text" label="Name" />
                  <.input field={@report_schedule_form[:cron]} type="text" label="Cron" />
                  <.input field={@report_schedule_form[:timezone]} type="text" label="Timezone" />
                  <.input
                    field={@report_schedule_form[:recipients]}
                    type="textarea"
                    label="Recipients"
                  />
                  <button type="submit" class="btn btn-sm btn-primary">
                    <.icon name="hero-envelope" class="size-4" /> Schedule Report
                  </button>
                </.form>
              </div>
            </section>
          </div>
        </section>

        <dialog
          :if={@editing_panel_id}
          id="dashboard-panel-composer-modal"
          class="modal modal-open"
        >
          <div class="modal-box flex max-h-[90vh] w-11/12 max-w-6xl flex-col overflow-hidden p-0">
            <div class="flex flex-col gap-3 border-b border-base-300 bg-base-100 px-5 py-4 sm:flex-row sm:items-center sm:justify-between">
              <div>
                <p class="text-xs font-semibold uppercase tracking-normal text-primary">
                  SRQL panel composer
                </p>
                <h2 class="mt-1 text-lg font-semibold tracking-normal">
                  {if @editing_panel_id == "new", do: "Create New Panel", else: "Edit Panel"}
                </h2>
                <p class="text-xs text-base-content/70">
                  Write the panel query, preview its output, then choose one of the compatible visualizations and bind fields.
                </p>
              </div>
              <button type="button" class="btn btn-sm btn-ghost" phx-click="cancel_panel_edit">
                <.icon name="hero-x-mark" class="size-4" /> Close
              </button>
            </div>

            <div class="overflow-y-auto bg-base-200/40 p-4">
              <.form
                for={@panel_form}
                as={:panel}
                phx-change="validate_panel"
                phx-submit="submit_panel_form"
                class="grid grid-cols-1 gap-4 lg:grid-cols-2"
              >
                <.panel_form_fields
                  form={@panel_form}
                  panel={CanvasState.editing_panel(@dashboard, @editing_panel_id)}
                  preview={@panel_preview}
                  panel_results={@panel_results}
                />
              </.form>

              <div
                :if={@editing_panel_id != "new"}
                class="mt-4 flex flex-wrap items-center gap-2 rounded-lg border border-base-300 bg-base-100 p-3"
              >
                <button
                  type="button"
                  class="btn btn-sm"
                  phx-click="duplicate_panel"
                  phx-value-id={@editing_panel_id}
                >
                  <.icon name="hero-document-duplicate" class="size-4" /> Duplicate
                </button>
                <button
                  type="button"
                  class="btn btn-sm btn-error btn-outline"
                  phx-click="delete_panel"
                  phx-value-id={@editing_panel_id}
                >
                  <.icon name="hero-trash" class="size-4" /> Delete
                </button>
                <form
                  phx-change="clone_target"
                  phx-submit="clone_panel"
                  class="ml-auto flex flex-wrap items-center gap-2"
                >
                  <input type="hidden" name="panel_id" value={@editing_panel_id} />
                  <select
                    name="target_dashboard_id"
                    class="select select-sm"
                    disabled={@clone_targets == []}
                  >
                    <option
                      :for={target <- @clone_targets}
                      value={target.id}
                      selected={target.id == @clone_target_id}
                    >
                      {target.title}
                    </option>
                  </select>
                  <button type="submit" class="btn btn-sm" disabled={@clone_targets == []}>
                    <.icon name="hero-arrow-up-on-square-stack" class="size-4" /> Clone
                  </button>
                </form>
              </div>
            </div>
          </div>
          <form method="dialog" class="modal-backdrop">
            <button type="button" phx-click="cancel_panel_edit">close</button>
          </form>
        </dialog>

        <div
          :if={@loading?}
          class="rounded-lg border border-base-300 bg-base-100 p-6 text-sm text-base-content/60"
        >
          Loading dashboard panels...
        </div>

        <div
          :if={(!@loading? and @dashboard) && Enum.empty?(@dashboard.panels || [])}
          class="rounded-lg border border-base-300 bg-base-100 p-6 text-sm text-base-content/60"
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
            can_manage?={can_manage_dashboard?(@dashboard, assigns)}
            csv_data_url={panel_csv_export_url(@dashboard, entry.panel, @variable_values)}
          />
        </section>

        <footer
          :if={!@loading? and @dashboard}
          class="flex flex-wrap items-center justify-between gap-3 border-t border-base-300 pt-4 text-xs text-base-content/55"
        >
          <span class="truncate">
            {@dashboard.description || "SRQL-authored dashboard"}
          </span>
          <div class="flex flex-wrap gap-2">
            <button
              :if={dashboard_settings_available?(@dashboard, assigns) and !@settings_open?}
              type="button"
              class="btn btn-xs btn-primary"
              phx-click="open_settings"
            >
              <.icon name="hero-cog-6-tooth" class="size-4" /> Settings
            </button>
            <button
              :if={dashboard_settings_available?(@dashboard, assigns) and @settings_open?}
              type="button"
              class="btn btn-xs"
              phx-click="close_settings"
            >
              <.icon name="hero-x-mark" class="size-4" /> Close Settings
            </button>
            <.link navigate={~p"/analytics"} class="btn btn-xs">
              <.icon name="hero-pencil-square" class="size-4" /> Dashboard Creator
            </.link>
          </div>
        </footer>
      </div>
    </Layouts.app>
    """
  end

  defp default_user_grant_params do
    %{"subject_user_id" => "", "access" => "view"}
  end

  defp default_group_grant_params do
    %{"subject_group_id" => "", "access" => "view"}
  end

  defp default_report_schedule_params do
    %{
      "name" => "Daily dashboard report",
      "cron" => "0 8 * * *",
      "timezone" => "UTC",
      "recipients" => ""
    }
  end

  defp panel_csv_export_url(dashboard, panel, variable_values) do
    dashboard_ref = Dashboards.authored_dashboard_route_ref(dashboard)
    query = %{vars: Jason.encode!(variable_values || %{})}

    ~p"/dashboard/#{dashboard_ref}/panels/#{panel.id}/export.csv?#{query}"
  end

  defp default_panel_params do
    %{
      "dataset_key" => "primary",
      "title" => "",
      "srql_query" => "",
      "visual_type" => "table",
      "value_field" => "",
      "numerator_field" => "",
      "denominator_field" => "",
      "label_field" => "",
      "row_field" => "",
      "column_field" => "",
      "time_field" => "",
      "status_field" => "",
      "aggregate" => "sum",
      "empty_value" => "0",
      "display_label" => "",
      "unit" => "",
      "caption" => "",
      "table_columns" => "",
      "trend_mode" => "",
      "trend_lookback_days" => "30",
      "trend_query" => "",
      "layout_x" => "0",
      "layout_y" => "0",
      "layout_w" => "12",
      "layout_h" => "8",
      "refresh_interval_seconds" => "0",
      "position" => "0"
    }
  end

  defp panel_to_params(panel) do
    binding = panel.data_binding || %{}
    display = panel.display_config || %{}
    visual = panel.visual_config || %{}
    layout = panel.layout || %{}

    %{
      "dataset_key" => panel.dataset_key || "primary",
      "title" => panel.title || "",
      "srql_query" => panel.srql_query || "",
      "visual_type" => to_string(panel.visual_type || :table),
      "value_field" => map_value(binding, "value_field"),
      "numerator_field" => map_value(binding, "numerator_field"),
      "denominator_field" => map_value(binding, "denominator_field"),
      "label_field" => map_value(binding, "label_field"),
      "row_field" => map_value(binding, "row_field"),
      "column_field" => map_value(binding, "column_field"),
      "time_field" => map_value(binding, "time_field"),
      "status_field" => map_value(binding, "status_field"),
      "aggregate" => map_value(binding, "aggregate", "sum"),
      "empty_value" => map_value(binding, "empty_value", "0"),
      "display_label" => map_value(display, "label"),
      "unit" => map_value(display, "unit"),
      "caption" => map_value(display, "caption"),
      "table_columns" => table_columns_text(map_value(display, "table_columns", [])),
      "trend_mode" => map_value(visual, "trend_mode"),
      "trend_lookback_days" => to_string(map_value(visual, "trend_lookback_days", 30)),
      "trend_query" => map_value(visual, "trend_query"),
      "layout_x" => to_string(map_value(layout, "x", 0)),
      "layout_y" => to_string(map_value(layout, "y", 0)),
      "layout_w" => to_string(map_value(layout, "w", 12)),
      "layout_h" => to_string(map_value(layout, "h", 8)),
      "refresh_interval_seconds" => to_string(panel.refresh_interval_seconds || 0),
      "position" => to_string(panel.position || 0)
    }
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

  defp load_access_controls(scope, dashboard, assigns) do
    access_grants =
      if dashboard_settings_available?(dashboard, Map.put(assigns, :current_scope, scope)) do
        Dashboards.list_authored_access_grants(scope, dashboard.id)
      else
        []
      end

    user_groups =
      if assigns.can_view_groups? do
        Dashboards.list_user_groups(scope)
      else
        []
      end

    users =
      if assigns.can_view_share_principals? do
        Dashboards.list_share_principals(scope)
      else
        []
      end

    %{access_grants: access_grants, user_groups: user_groups, users: users}
  end

  defp reload_access_controls(%{assigns: %{dashboard: dashboard}} = socket) do
    access =
      load_access_controls(
        socket.assigns.current_scope,
        dashboard,
        access_assigns(socket.assigns)
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

    results =
      Map.new(panels, fn panel ->
        {panel.id, preview_panel_query(socket.assigns.current_scope, panel, socket.assigns.variable_values)}
      end)

    trends =
      Map.new(panels, fn panel ->
        {panel.id, preview_trend_query(socket.assigns.current_scope, panel, socket.assigns.variable_values)}
      end)

    socket
    |> assign(:dashboard, Map.put(dashboard, :panels, panels))
    |> assign(:panel_results, results)
    |> assign(:trend_results, trends)
  end

  defp reload_dashboard_panels(socket), do: socket

  defp persist_source_query(socket, source) do
    dashboard = socket.assigns.dashboard
    metadata = SourceQueries.upsert_source_metadata(dashboard.metadata || %{}, source)

    case Dashboards.update_authored_dashboard(socket.assigns.current_scope, dashboard, %{metadata: metadata}) do
      {:ok, updated_dashboard} -> {:ok, %{updated_dashboard | panels: dashboard.panels || []}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp preview_panel_query(scope, panel, variable_values) do
    query = DashboardVariables.substitute(panel.srql_query, variable_values)
    Dashboards.preview_authored_query(scope, query, limit: 250)
  end

  defp preview_trend_query(scope, panel, variable_values) do
    query =
      panel
      |> Map.get(:visual_config, %{})
      |> Map.get("trend_query")

    case query do
      value when is_binary(value) and value != "" ->
        Dashboards.preview_authored_query(scope, DashboardVariables.substitute(value, variable_values), limit: 250)

      _ ->
        nil
    end
  end

  defp load_clone_targets(scope, dashboard) do
    scope
    |> Dashboards.list_authored_dashboards(%{status: [:draft, :active], limit: 200})
    |> Enum.reject(&(&1.id == dashboard.id))
    |> Enum.sort_by(&String.downcase(&1.title || ""))
  end

  defp default_clone_target_id([target | _]), do: target.id
  defp default_clone_target_id(_targets), do: ""

  defp duplicate_panel_attrs(panel, dashboard) do
    panels = Map.get(dashboard, :panels, []) || []
    position = length(panels)

    %{
      dashboard_id: dashboard.id,
      dataset_key: unique_dataset_key(panel.dataset_key || "panel", panels),
      title: "#{panel.title} Copy",
      srql_query: panel.srql_query,
      builder_state: panel.builder_state || %{},
      visual_type: panel.visual_type,
      data_binding: panel.data_binding || %{},
      display_config: panel.display_config || %{},
      visual_config: panel.visual_config || %{},
      field_metadata: panel.field_metadata || %{},
      layout: next_panel_layout(panel.layout || %{}, position),
      refresh_interval_seconds: panel.refresh_interval_seconds || 0,
      position: position,
      metadata: panel.metadata || %{}
    }
  end

  defp unique_dataset_key(base, panels) do
    existing = MapSet.new(Enum.map(panels, &(&1.dataset_key || "")))
    root = base |> to_string() |> String.replace(~r/[^a-zA-Z0-9_]+/, "_") |> String.trim("_")
    root = if root == "", do: "panel", else: root

    1
    |> Stream.iterate(&(&1 + 1))
    |> Enum.find_value(fn index ->
      candidate = "#{root}_copy_#{index}"
      if MapSet.member?(existing, candidate), do: nil, else: candidate
    end)
  end

  defp next_panel_layout(layout, position) do
    width = layout |> Map.get("w", 4) |> LayoutHelpers.bounded_integer(1, 12)
    height = layout |> Map.get("h", 4) |> LayoutHelpers.bounded_integer(2, 16)
    x = rem(position * width, 12)
    y = div(position * width, 12) * height

    %{"x" => x, "y" => y, "w" => width, "h" => height, "order" => position}
  end

  defp compact_dashboard_panels(socket) do
    panels =
      Enum.sort_by(
        socket.assigns.dashboard.panels || [],
        &{&1.position, Map.get(&1.layout || %{}, "y", 0), Map.get(&1.layout || %{}, "x", 0)}
      )

    indexed_panels = Enum.with_index(panels)

    layouts =
      indexed_panels
      |> Map.new(fn {panel, index} -> {panel.id, compact_layout_for_panel(panel, index)} end)
      |> LayoutHelpers.fill_final_orphan_layout(panels)

    Enum.reduce_while(indexed_panels, {:ok, []}, fn {panel, index}, {:ok, updated} ->
      layout = layouts |> Map.fetch!(panel.id) |> Map.put("order", index)

      case Dashboards.update_authored_panel(socket.assigns.current_scope, panel, %{layout: layout, position: index}) do
        {:ok, panel} -> {:cont, {:ok, updated ++ [panel]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp compact_layout_for_panel(panel, index) do
    layout = panel.layout || %{}
    width = layout |> Map.get("w", 4) |> LayoutHelpers.bounded_integer(1, 12)
    height = layout |> Map.get("h", 4) |> LayoutHelpers.bounded_integer(2, 16)
    x = rem(index * width, 12)
    y = div(index * width, 12) * height

    Map.merge(layout, %{"x" => x, "y" => y, "w" => width, "h" => height, "order" => index})
  end

  defp access_assigns(assigns) do
    assigns
    |> Map.take([:can_edit?, :can_share?, :can_view_groups?, :can_view_share_principals?])
    |> Map.put_new(:current_scope, Map.get(assigns, :current_scope))
  end

  defp merge_params(current, incoming), do: Map.merge(current || %{}, incoming || %{})

  defp dashboard_settings_available?(nil, _assigns), do: false

  defp dashboard_settings_available?(dashboard, assigns) do
    can_manage_dashboard?(dashboard, assigns) or can_share_dashboard?(dashboard, assigns) or
      can_schedule_dashboard?(dashboard, assigns)
  end

  defp can_manage_dashboard?(nil, _assigns), do: false

  defp can_manage_dashboard?(dashboard, assigns) do
    dashboard_owner?(dashboard, Map.get(assigns, :current_scope)) or
      Map.get(assigns, :can_edit?, false)
  end

  defp can_share_dashboard?(nil, _assigns), do: false

  defp can_share_dashboard?(dashboard, assigns) do
    can_manage_dashboard?(dashboard, assigns) and Map.get(assigns, :can_share?, false)
  end

  defp can_schedule_dashboard?(nil, _assigns), do: false

  defp can_schedule_dashboard?(dashboard, assigns) do
    can_manage_dashboard?(dashboard, assigns) and Map.get(assigns, :can_schedule_reports?, false)
  end

  defp dashboard_owner?(%{owner_id: owner_id}, %{user: %{id: user_id}})
       when not is_nil(owner_id) and not is_nil(user_id) do
    to_string(owner_id) == to_string(user_id)
  end

  defp dashboard_owner?(_dashboard, _scope), do: false

  defp can_edit?(scope), do: RBAC.can?(scope, "analytics.dashboards.edit")
  defp can_share?(scope), do: RBAC.can?(scope, "analytics.dashboards.share")
  defp can_schedule_reports?(scope), do: RBAC.can?(scope, "analytics.reports.schedule")
  defp can_view_groups?(scope), do: RBAC.can?(scope, "identity.user_groups.view")

  defp can_view_share_principals?(scope), do: RBAC.can?(scope, "analytics.share_principals.view")

  defp authorize_share(socket) do
    if can_share_dashboard?(socket.assigns.dashboard, socket.assigns),
      do: :ok,
      else: {:error, :forbidden}
  end

  defp authorize_panel_edit(socket) do
    if can_manage_dashboard?(socket.assigns.dashboard, socket.assigns),
      do: :ok,
      else: {:error, :forbidden}
  end

  defp authorize_report_schedule(socket) do
    if can_schedule_dashboard?(socket.assigns.dashboard, socket.assigns),
      do: :ok,
      else: {:error, :forbidden}
  end

  defp panel_attrs(params) do
    %{
      dataset_key: params["dataset_key"],
      title: params["title"],
      srql_query: params["srql_query"],
      visual_type: params["visual_type"],
      data_binding: panel_data_binding(params),
      display_config: panel_display_config(params),
      visual_config: panel_visual_config(params),
      layout: panel_layout(params),
      refresh_interval_seconds: integer_value(params["refresh_interval_seconds"], 0),
      position: integer_value(params["position"], 0)
    }
  end

  defp panel_data_binding(params) do
    [
      "value_field",
      "numerator_field",
      "denominator_field",
      "label_field",
      "row_field",
      "column_field",
      "time_field",
      "status_field",
      "aggregate",
      "empty_value"
    ]
    |> Enum.reduce(%{}, fn key, acc -> put_present(acc, key, params[key]) end)
    |> Map.put("dataset", params["dataset_key"] || "primary")
  end

  defp panel_display_config(params) do
    %{}
    |> put_present("label", params["display_label"])
    |> put_present("unit", params["unit"])
    |> put_present("caption", params["caption"])
    |> put_table_columns(params["table_columns"])
  end

  defp panel_visual_config(params) do
    %{}
    |> put_present("trend_mode", params["trend_mode"])
    |> put_present("trend_lookback_days", params["trend_lookback_days"])
    |> put_present("trend_query", params["trend_query"])
  end

  defp panel_layout(params) do
    %{
      "x" => integer_value(params["layout_x"], 0),
      "y" => integer_value(params["layout_y"], 0),
      "w" => integer_value(params["layout_w"], 12),
      "h" => integer_value(params["layout_h"], 8)
    }
  end

  defp put_present(map, _key, value) when value in [nil, ""], do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp put_table_columns(map, value) when is_binary(value) do
    columns =
      value
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.map(fn field ->
        %{"field" => field, "label" => humanize_field(field), "renderer" => "text", "visible" => true}
      end)

    if columns == [], do: map, else: Map.put(map, "table_columns", columns)
  end

  defp put_table_columns(map, _value), do: map

  defp map_value(map, key, default \\ "")

  defp map_value(map, key, default) when is_map(map) do
    Map.get(map, key, default)
  end

  defp map_value(_map, _key, default), do: default

  defp table_columns_text(columns) when is_list(columns) do
    columns
    |> Enum.filter(&is_map/1)
    |> Enum.map(&(Map.get(&1, "field") || Map.get(&1, :field)))
    |> Enum.reject(&is_nil/1)
    |> Enum.join(", ")
  end

  defp table_columns_text(_columns), do: ""

  defp integer_value(value, default) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {int, ""} -> int
      _ -> default
    end
  end

  defp integer_value(value, _default) when is_integer(value), do: value
  defp integer_value(_value, default), do: default

  defp require_record(nil), do: {:error, :not_found}
  defp require_record(record), do: {:ok, record}

  defp recipients(value) when is_binary(value) do
    value
    |> String.split([",", "\n"], trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp recipients(value) when is_list(value), do: Enum.filter(value, &is_binary/1)
  defp recipients(_value), do: []

  defp maybe_refresh_editing_panel_params(socket, panels) do
    case socket.assigns.editing_panel_id do
      id when is_binary(id) and id != "new" ->
        case Enum.find(panels, &(&1.id == id)) do
          nil ->
            socket

          panel ->
            socket
            |> assign(:panel_params, panel_to_params(panel))
            |> assign_panel_form()
        end

      _ ->
        socket
    end
  end

  defp access_select_options, do: [{"View", "view"}, {"Edit", "edit"}]

  defp selected_panel_visual(value, compatible) do
    compatible = Enum.map(compatible || [:table], &to_string/1)
    value = to_string(value || "table")

    if value in compatible do
      value
    else
      List.first(compatible) || "table"
    end
  end

  defp default_panel_binding_params(params, preview, _visual) do
    fields = preview_fields(preview)

    defaults =
      %{}
      |> maybe_default("value_field", first_field_of_type(fields, :number))
      |> maybe_default("numerator_field", availability_numerator_field(fields))
      |> maybe_default("denominator_field", field_named(fields, "total"))
      |> maybe_default("label_field", first_field_of_type(fields, :string))
      |> maybe_default("row_field", first_field_of_type(fields, :string))
      |> maybe_default("column_field", status_field(fields) || first_field_of_type(fields, :string))
      |> maybe_default("time_field", first_field_of_type(fields, :datetime))
      |> maybe_default("status_field", status_field(fields))
      |> maybe_default("aggregate", "sum")
      |> maybe_default("empty_value", "0")

    Map.merge(params, defaults, fn _key, current, default -> if current in [nil, ""], do: default, else: current end)
  end

  defp panel_preview_flash(visual, visual), do: "Panel query preview loaded"

  defp panel_preview_flash(requested, fallback) do
    "Panel query preview loaded; switched from #{humanize_field(requested)} to #{humanize_field(fallback)} " <>
      "because this query does not support the selected visualization."
  end

  defp maybe_default(map, _key, nil), do: map
  defp maybe_default(map, key, value), do: Map.put(map, key, value)

  defp panel_preview_from_result({:ok, preview}, _panel) when is_map(preview), do: preview
  defp panel_preview_from_result(_result, panel), do: panel_preview_from_metadata(panel)

  defp panel_preview_from_metadata(nil), do: nil

  defp panel_preview_from_metadata(panel) do
    metadata = panel.field_metadata || %{}

    %{
      fields: metadata_fields(metadata),
      compatible_visuals: panel_compatible_visuals(panel),
      rows: [],
      row_count: 0
    }
  end

  defp preview_fields(%{fields: fields}) when is_list(fields), do: fields
  defp preview_fields(%{"fields" => fields}) when is_list(fields), do: fields
  defp preview_fields(_preview), do: []

  defp panel_compatible_visuals(nil), do: []

  defp panel_compatible_visuals(panel) do
    panel
    |> Map.get(:field_metadata, %{})
    |> case do
      %{"compatible_visuals" => visuals} when is_list(visuals) -> Enum.map(visuals, &visual_atom/1)
      %{compatible_visuals: visuals} when is_list(visuals) -> Enum.map(visuals, &visual_atom/1)
      _ -> []
    end
  end

  defp metadata_fields(%{"fields" => fields}) when is_list(fields), do: fields
  defp metadata_fields(%{fields: fields}) when is_list(fields), do: fields
  defp metadata_fields(_metadata), do: []

  defp visual_atom(value) when is_atom(value), do: value
  defp visual_atom("table"), do: :table
  defp visual_atom("stat"), do: :stat
  defp visual_atom("count"), do: :count
  defp visual_atom("gauge"), do: :gauge
  defp visual_atom("availability"), do: :availability
  defp visual_atom("line"), do: :line
  defp visual_atom("area"), do: :area
  defp visual_atom("bar"), do: :bar
  defp visual_atom("category"), do: :category
  defp visual_atom("status_list"), do: :status_list
  defp visual_atom("pivot"), do: :pivot
  defp visual_atom(_value), do: :table

  defp field_name(%{name: name}), do: to_string(name)
  defp field_name(%{"name" => name}), do: to_string(name)
  defp field_name(field) when is_binary(field), do: field
  defp field_name(_field), do: ""

  defp field_type(%{type: type}) when is_atom(type), do: type
  defp field_type(%{type: type}) when is_binary(type), do: field_type(type)
  defp field_type(%{"type" => type}) when is_binary(type), do: field_type(type)
  defp field_type("number"), do: :number
  defp field_type("datetime"), do: :datetime
  defp field_type("boolean"), do: :boolean
  defp field_type("string"), do: :string
  defp field_type(_field), do: :string

  defp availability_numerator_field(fields), do: field_named(fields, "ok") || field_named(fields, "available")

  defp field_named(fields, name) do
    Enum.find_value(fields, fn field ->
      if field_name(field) == name, do: name
    end)
  end

  defp status_field(fields) do
    Enum.find_value(fields, fn field ->
      name = field_name(field)
      if name in ["status", "state", "health", "result", "severity", "severity_label"], do: name
    end)
  end

  defp group_select_options(groups) do
    Enum.map(groups, &{&1.name, &1.id})
  end

  defp user_select_options(users) do
    Enum.map(users, &{user_label(&1), &1.id})
  end

  defp grant_label(%{subject_type: :user, subject_user: user}), do: user_label(user)
  defp grant_label(%{subject_type: "user", subject_user: user}), do: user_label(user)
  defp grant_label(%{subject_type: :group, subject_group: group}), do: group_label(group)
  defp grant_label(%{subject_type: "group", subject_group: group}), do: group_label(group)
  defp grant_label(_grant), do: "Unknown principal"

  defp group_label(%{name: name}) when is_binary(name) and name != "", do: name
  defp group_label(_group), do: "Unknown group"

  defp user_label(%{display_name: name, email: email}) when is_binary(name) and name != "" do
    "#{name} <#{email}>"
  end

  defp user_label(%{email: %Ash.CiString{} = email}), do: to_string(email)
  defp user_label(%{email: email}) when is_binary(email), do: email
  defp user_label(_user), do: "Unknown user"

  defp humanize_field(nil), do: ""

  defp humanize_field(value) do
    value
    |> to_string()
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  defp first_field_of_type(fields, type) do
    Enum.find_value(fields, fn field ->
      if field_type(field) == type, do: field_name(field)
    end)
  end

  defp format_value(%DateTime{} = value), do: Calendar.strftime(value, "%Y-%m-%d %H:%M:%S")
  defp format_value(%NaiveDateTime{} = value), do: Calendar.strftime(value, "%Y-%m-%d %H:%M:%S")
  defp format_value(value) when is_binary(value), do: value
  defp format_value(value) when is_integer(value), do: Integer.to_string(value)
  defp format_value(value) when is_float(value), do: :erlang.float_to_binary(value, decimals: 2)
  defp format_value(value) when is_boolean(value), do: to_string(value)
  defp format_value(nil), do: ""
  defp format_value(value), do: inspect(value)

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
