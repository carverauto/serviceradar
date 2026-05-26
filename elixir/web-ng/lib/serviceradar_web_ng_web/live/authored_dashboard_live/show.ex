defmodule ServiceRadarWebNGWeb.AuthoredDashboardLive.Show do
  @moduledoc false
  use ServiceRadarWebNGWeb, :live_view

  alias ServiceRadar.Dashboards.AuthoredDashboard
  alias ServiceRadarWebNG.Dashboards
  alias ServiceRadarWebNG.RBAC

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
            variable_values = dashboard_variable_values(dashboard, current_variable_values)

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

  def handle_event("canvas_add_panel", %{"visualType" => visual_type}, socket) do
    case authorize_panel_edit(socket) do
      :ok ->
        visual_type = canvas_visual_type(visual_type)
        layout = canvas_new_panel_layout(visual_type, socket.assigns.dashboard.panels || [])

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
         {:ok, panels} <- update_canvas_panel_layouts(socket, layouts) do
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
    values = dashboard_variable_values(socket.assigns.dashboard, params)

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
      shell={:operations}
    >
      <div class="mx-auto flex w-full max-w-7xl flex-col gap-6 px-4 py-6 sm:px-6 lg:px-8">
        <section class="flex flex-col gap-3 border-b border-base-300 pb-5 lg:flex-row lg:items-end lg:justify-between">
          <div>
            <p class="text-sm font-medium text-primary">Dashboard</p>
            <h1 class="mt-1 text-2xl font-semibold tracking-normal">
              {if @dashboard, do: @dashboard.title, else: "Loading dashboard"}
            </h1>
            <p class="mt-2 max-w-3xl text-sm text-base-content/65">
              {if @dashboard,
                do: @dashboard.description || "SRQL-authored dashboard",
                else: "Loading saved SRQL panels."}
            </p>
          </div>
          <div class="flex flex-wrap gap-2">
            <button
              :if={dashboard_settings_available?(@dashboard, assigns)}
              type="button"
              class="btn btn-sm btn-primary"
              phx-click="open_settings"
            >
              <.icon name="hero-cog-6-tooth" class="size-4" /> Settings
            </button>
            <.link navigate={~p"/analytics"} class="btn btn-sm">
              <.icon name="hero-pencil-square" class="size-4" /> Dashboard Creator
            </.link>
          </div>
        </section>

        <.variable_bar
          :if={@dashboard && dashboard_variables(@dashboard) != []}
          dashboard={@dashboard}
          values={@variable_values}
        />

        <section
          :if={@settings_open? and dashboard_settings_available?(@dashboard, assigns)}
          class="rounded-lg border border-base-300 bg-base-100"
        >
          <div class="flex flex-col gap-3 border-b border-base-300 px-4 py-3 lg:flex-row lg:items-center lg:justify-between">
            <div>
              <h2 class="text-sm font-semibold">Dashboard Settings</h2>
              <p class="text-xs text-base-content/70">
                Manage SRQL panels, visual choices, email schedules, and dashboard-specific sharing.
              </p>
            </div>
            <button type="button" class="btn btn-xs btn-ghost" phx-click="close_settings">
              <.icon name="hero-x-mark" class="size-4" /> Close
            </button>
          </div>

          <div class="space-y-6 p-4">
            <section
              :if={can_manage_dashboard?(@dashboard, assigns)}
              class="rounded-lg border border-base-300"
            >
              <div class="border-b border-base-300 px-4 py-3">
                <div class="flex flex-col gap-2 sm:flex-row sm:items-center sm:justify-between">
                  <div>
                    <p class="text-xs font-semibold uppercase tracking-normal text-primary">
                      Composite authoring
                    </p>
                    <h3 class="mt-1 text-lg font-semibold tracking-normal">Dashboard Workbench</h3>
                    <p class="text-xs text-base-content/70">
                      Compose SRQL-backed panels, map query output into supported visuals, and arrange the dashboard canvas.
                    </p>
                  </div>
                  <div class="flex flex-wrap gap-2">
                    <button type="button" class="btn btn-sm btn-primary" phx-click="new_panel">
                      <.icon name="hero-plus" class="size-4" /> Add Panel
                    </button>
                    <button type="button" class="btn btn-sm" phx-click="compact_layout">
                      <.icon name="hero-squares-plus" class="size-4" /> Compact Layout
                    </button>
                  </div>
                </div>
              </div>
              <div class="p-4">
                <.dashboard_builder_canvas
                  id={"authored-dashboard-canvas-#{@dashboard.id}"}
                  panels={dashboard_canvas_panels(@dashboard, @panel_results)}
                  visual_options={dashboard_canvas_visual_options()}
                  selected_id={canvas_selected_panel_id(@editing_panel_id, @dashboard)}
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
                  panel={editing_panel(@dashboard, @editing_panel_id)}
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
            :for={panel <- @dashboard.panels || []}
            panel={panel}
            result={Map.get(@panel_results, panel.id)}
            trend={Map.get(@trend_results, panel.id)}
            style={panel_grid_style(panel)}
            expanded_srql?={MapSet.member?(@expanded_srql_panel_ids, panel.id)}
            can_manage?={can_manage_dashboard?(@dashboard, assigns)}
            csv_data_url={panel_csv_export_url(@dashboard, panel, @variable_values)}
          />
        </section>
      </div>
    </Layouts.app>
    """
  end

  attr :dashboard, :any, required: true
  attr :values, :map, default: %{}

  defp variable_bar(assigns) do
    assigns = assign(assigns, :variables, dashboard_variables(assigns.dashboard))

    ~H"""
    <section class="rounded-lg border border-base-300 bg-base-100 px-4 py-3">
      <form phx-change="change_variable" class="flex flex-col gap-3 lg:flex-row lg:items-center">
        <div class="shrink-0">
          <h2 class="text-sm font-semibold">Dashboard Variables</h2>
          <p class="text-xs text-base-content/70">
            Values substitute into panel SRQL before execution.
          </p>
        </div>
        <div class="flex flex-1 flex-wrap gap-3">
          <label :for={variable <- @variables} class="form-control min-w-44">
            <span class="label-text text-xs">{variable.label}</span>
            <select
              :if={variable.options != []}
              name={"variables[#{variable.name}]"}
              class="select select-sm"
            >
              <option
                :for={option <- variable.options}
                value={option}
                selected={Map.get(@values, variable.name, variable.default) == option}
              >
                {option}
              </option>
            </select>
            <input
              :if={variable.options == []}
              name={"variables[#{variable.name}]"}
              class="input input-sm"
              value={Map.get(@values, variable.name, variable.default)}
            />
          </label>
        </div>
      </form>
    </section>
    """
  end

  defp panel_result(%{result: {:ok, preview}} = assigns) do
    assigns =
      assigns
      |> assign(:rows, preview.rows)
      |> assign(:fields, preview.fields)
      |> assign_new(:trend, fn -> nil end)
      |> assign_new(:expanded_srql?, fn -> false end)
      |> assign_new(:can_manage?, fn -> false end)
      |> assign_new(:csv_data_url, fn -> nil end)

    ~H"""
    <article
      class="sr-authored-dashboard-panel rounded-lg border border-base-300 bg-base-100"
      style={@style}
    >
      <div class="flex flex-col gap-2 border-b border-base-300 px-4 py-3 sm:flex-row sm:items-center sm:justify-between">
        <div class="min-w-0">
          <div class="flex flex-wrap items-center gap-2">
            <h2 class="truncate text-sm font-semibold">{@panel.title}</h2>
            <span :if={refresh_interval_label(@panel)} class="badge badge-xs badge-ghost">
              {refresh_interval_label(@panel)}
            </span>
          </div>
          <p class="mt-1 truncate font-mono text-xs text-base-content/65">{@panel.srql_query}</p>
        </div>
        <div class="flex shrink-0 flex-wrap items-center gap-1">
          <span class="badge badge-outline">{@panel.visual_type}</span>
          <button
            type="button"
            class="btn btn-xs btn-ghost"
            phx-click="refresh_panel"
            phx-value-id={@panel.id}
            title="Refresh panel"
          >
            <.icon name="hero-arrow-path" class="size-4" />
          </button>
          <button
            type="button"
            class="btn btn-xs btn-ghost"
            phx-click="toggle_panel_srql"
            phx-value-id={@panel.id}
            title="View SRQL"
          >
            <.icon name="hero-code-bracket-square" class="size-4" />
          </button>
          <button
            :if={@can_manage?}
            type="button"
            class="btn btn-xs btn-ghost"
            phx-click="edit_panel"
            phx-value-id={@panel.id}
            title="Open panel settings"
          >
            <.icon name="hero-pencil-square" class="size-4" />
          </button>
          <a
            :if={@csv_data_url}
            class="btn btn-xs btn-ghost"
            href={@csv_data_url}
            download={"#{safe_filename(@panel.title)}.csv"}
            title="Export CSV"
          >
            <.icon name="hero-arrow-down-tray" class="size-4" />
          </a>
        </div>
      </div>
      <div :if={@expanded_srql?} class="border-b border-base-300 bg-base-200/40 px-4 py-3">
        <pre class="overflow-x-auto whitespace-pre-wrap font-mono text-xs"><%= @panel.srql_query %></pre>
      </div>
      <div class="p-4">
        <.render_visual panel={@panel} rows={@rows} fields={@fields} trend={@trend} />
      </div>
    </article>
    """
  end

  defp panel_result(%{result: {:error, reason}} = assigns) do
    assigns =
      assigns
      |> assign(:message, format_error(reason))
      |> assign_new(:expanded_srql?, fn -> false end)
      |> assign_new(:can_manage?, fn -> false end)

    ~H"""
    <article
      class="sr-authored-dashboard-panel rounded-lg border border-error/30 bg-base-100"
      style={@style}
    >
      <div class="flex flex-col gap-2 border-b border-error/20 px-4 py-3 sm:flex-row sm:items-center sm:justify-between">
        <h2 class="text-sm font-semibold">{@panel.title}</h2>
        <div class="flex shrink-0 flex-wrap items-center gap-1">
          <button
            type="button"
            class="btn btn-xs btn-ghost"
            phx-click="refresh_panel"
            phx-value-id={@panel.id}
            title="Refresh panel"
          >
            <.icon name="hero-arrow-path" class="size-4" />
          </button>
          <button
            type="button"
            class="btn btn-xs btn-ghost"
            phx-click="toggle_panel_srql"
            phx-value-id={@panel.id}
            title="View SRQL"
          >
            <.icon name="hero-code-bracket-square" class="size-4" />
          </button>
          <button
            :if={@can_manage?}
            type="button"
            class="btn btn-xs btn-ghost"
            phx-click="edit_panel"
            phx-value-id={@panel.id}
            title="Open panel settings"
          >
            <.icon name="hero-pencil-square" class="size-4" />
          </button>
        </div>
      </div>
      <div :if={@expanded_srql?} class="border-b border-base-300 bg-base-200/40 px-4 py-3">
        <pre class="overflow-x-auto whitespace-pre-wrap font-mono text-xs"><%= @panel.srql_query %></pre>
      </div>
      <div class="p-4 text-sm text-error">
        Could not preview this query: {@message}
      </div>
    </article>
    """
  end

  defp panel_result(assigns) do
    ~H"""
    <article
      class="sr-authored-dashboard-panel rounded-lg border border-base-300 bg-base-100 p-4 text-sm text-base-content/60"
      style={@style}
    >
      {@panel.title}
    </article>
    """
  end

  defp render_visual(%{panel: %{visual_type: type}} = assigns) when type in [:stat, "stat", :count, "count"] do
    value =
      bound_value(assigns.rows, assigns.panel, "value_field") ||
        stat_value(assigns.rows, assigns.fields)

    assigns =
      assigns
      |> assign(:value, format_value(value))
      |> assign(
        :label,
        visual_label(assigns.panel, first_numeric_field(assigns.fields) || "value")
      )
      |> assign(:unit, display_value(assigns.panel, "unit", ""))
      |> assign(:trend_summary, trend_summary(assigns[:trend]))

    ~H"""
    <div class="flex min-h-32 items-center" role="group" aria-label={"#{@label}: #{@value}#{@unit}"}>
      <div>
        <div class="text-4xl font-semibold tracking-normal">
          {@value}<span class="text-xl">{@unit}</span>
        </div>
        <div class="mt-2 text-sm text-base-content/55">{@label}</div>
        <div :if={@trend_summary} class="mt-2 text-xs text-base-content/60">
          Trend: {@trend_summary}
        </div>
      </div>
    </div>
    """
  end

  defp render_visual(%{panel: %{visual_type: type}} = assigns)
       when type in [:gauge, "gauge", :availability, "availability"] do
    assigns =
      assigns
      |> assign(:chart_panel, chart_panel(assigns.panel))
      |> assign(:chart_rows, chart_rows(assigns.rows))
      |> assign(:chart_fields, chart_fields(assigns.fields))
      |> assign(:trend_summary, trend_summary(assigns[:trend]))

    ~H"""
    <div class="space-y-2">
      <.dashboard_panel_chart
        id={"dashboard-panel-chart-#{@panel.id}"}
        panel={@chart_panel}
        rows={@chart_rows}
        fields={@chart_fields}
        class="min-h-44"
      />
      <div :if={@trend_summary} class="text-xs text-base-content/60">
        Trend: {@trend_summary}
      </div>
    </div>
    """
  end

  defp render_visual(%{panel: %{visual_type: type}} = assigns) when type in [:pivot, "pivot"] do
    assigns = assign(assigns, :pivot, pivot_data(assigns.rows, assigns.panel, assigns.fields))

    ~H"""
    <div class="space-y-2">
      <div class="text-sm font-medium">Pivot Table</div>
      <div class="overflow-x-auto rounded-lg border border-base-300">
        <table class="table table-sm">
          <thead>
            <tr>
              <th>{@pivot.row_label}</th>
              <th :for={column <- @pivot.columns}>{column}</th>
              <th :if={@pivot.show_totals?}>Total</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={row <- @pivot.rows}>
              <th>{row.label}</th>
              <td :for={column <- @pivot.columns}>
                {Map.get(row.values, column, @pivot.empty_value)}
              </td>
              <td :if={@pivot.show_totals?}>{row.total}</td>
            </tr>
          </tbody>
        </table>
        <.empty_rows :if={@pivot.rows == []} />
      </div>
    </div>
    """
  end

  defp render_visual(%{panel: %{visual_type: type}} = assigns) when type in [:bar, "bar", :category, "category"] do
    assigns =
      assigns
      |> assign(:chart_panel, chart_panel(assigns.panel))
      |> assign(:chart_rows, chart_rows(assigns.rows))
      |> assign(:chart_fields, chart_fields(assigns.fields))

    ~H"""
    <.dashboard_panel_chart
      id={"dashboard-panel-chart-#{@panel.id}"}
      panel={@chart_panel}
      rows={@chart_rows}
      fields={@chart_fields}
    />
    """
  end

  defp render_visual(%{panel: %{visual_type: type}} = assigns) when type in [:line, "line", :area, "area"] do
    assigns =
      assigns
      |> assign(:chart_panel, chart_panel(assigns.panel))
      |> assign(:chart_rows, chart_rows(assigns.rows))
      |> assign(:chart_fields, chart_fields(assigns.fields))

    ~H"""
    <.dashboard_panel_chart
      id={"dashboard-panel-chart-#{@panel.id}"}
      panel={@chart_panel}
      rows={@chart_rows}
      fields={@chart_fields}
    />
    """
  end

  defp render_visual(assigns) do
    assigns = assign(assigns, :columns, table_columns(assigns.panel, assigns.fields))

    ~H"""
    <div class="overflow-x-auto rounded-lg border border-base-300">
      <table class="table table-sm">
        <thead>
          <tr>
            <th :for={column <- @columns}>{column.label}</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={row <- Enum.take(@rows, 100)}>
            <td :for={column <- @columns} class="max-w-64 truncate">
              <.table_cell value={table_value(row, column)} renderer={column.renderer} />
            </td>
          </tr>
        </tbody>
      </table>
      <.empty_rows :if={@rows == []} />
    </div>
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

  defp panel_grid_style(panel) do
    layout = panel.layout || %{}
    x = layout |> Map.get("x", 0) |> bounded_integer(0, 11)
    width = layout |> Map.get("w", 12) |> bounded_integer(1, 12 - x)
    y = layout |> Map.get("y", 0) |> bounded_integer(0, 1_000)
    height = layout |> Map.get("h", 4) |> bounded_integer(2, 16)
    order = layout |> Map.get("order", panel.position || 0) |> bounded_integer(0, 1_000)

    "--sr-panel-x: #{x + 1}; --sr-panel-y: #{y + 1}; --sr-panel-w: #{width}; --sr-panel-h: #{height}; --sr-panel-order: #{order};"
  end

  defp bounded_integer(value, min, max) when is_integer(value), do: value |> max(min) |> min(max)

  defp bounded_integer(value, min, max) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> bounded_integer(integer, min, max)
      _ -> min
    end
  end

  defp bounded_integer(value, min, max) when is_float(value), do: value |> round() |> bounded_integer(min, max)
  defp bounded_integer(_value, min, _max), do: min

  defp refresh_interval_label(%{refresh_interval_seconds: seconds}) when is_integer(seconds) and seconds > 0 do
    "Refresh #{format_duration(seconds)}"
  end

  defp refresh_interval_label(_panel), do: nil

  defp format_duration(seconds) when seconds < 60, do: "#{seconds}s"
  defp format_duration(seconds) when seconds < 3_600, do: "#{div(seconds, 60)}m"
  defp format_duration(seconds), do: "#{div(seconds, 3_600)}h"

  defp panel_csv_export_url(dashboard, panel, variable_values) do
    dashboard_ref = Dashboards.authored_dashboard_route_ref(dashboard)
    query = %{vars: Jason.encode!(variable_values || %{})}

    ~p"/dashboard/#{dashboard_ref}/panels/#{panel.id}/export.csv?#{query}"
  end

  defp chart_panel(panel) do
    %{
      id: panel.id,
      title: panel.title || "Panel",
      visual_type: to_string(panel.visual_type || :line),
      data_binding: panel.data_binding || %{},
      display_config: panel.display_config || %{},
      visual_config: panel.visual_config || %{}
    }
  end

  defp chart_rows(rows) do
    rows
    |> List.wrap()
    |> Enum.take(250)
    |> Enum.map(&chart_row/1)
  end

  defp chart_row(row) when is_map(row) do
    Map.new(row, fn {key, value} -> {to_string(key), chart_value(value)} end)
  end

  defp chart_row(_row), do: %{}

  defp chart_fields(fields), do: canvas_fields(fields)

  defp chart_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp chart_value(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp chart_value(value) when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value), do: value
  defp chart_value(value) when is_list(value), do: Enum.map(value, &chart_value/1)

  defp chart_value(value) when is_map(value) do
    Map.new(value, fn {key, nested_value} -> {to_string(key), chart_value(nested_value)} end)
  end

  defp chart_value(value), do: format_value(value)

  defp safe_filename(value) do
    value
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
    |> case do
      "" -> "dashboard-panel"
      filename -> filename
    end
  end

  attr(:form, :any, required: true)
  attr(:panel, :any, default: nil)
  attr(:preview, :any, default: nil)
  attr(:panel_results, :map, default: %{})

  defp panel_form_fields(assigns) do
    assigns =
      assigns
      |> assign(:field_options, panel_field_options(assigns.preview, assigns.panel, assigns.panel_results))
      |> assign(
        :numeric_field_options,
        numeric_panel_field_options(assigns.preview, assigns.panel, assigns.panel_results)
      )
      |> assign(
        :dimension_field_options,
        dimension_panel_field_options(assigns.preview, assigns.panel, assigns.panel_results)
      )
      |> assign(
        :datetime_field_options,
        datetime_panel_field_options(assigns.preview, assigns.panel, assigns.panel_results)
      )
      |> assign(:visual_options, panel_visual_select_options(assigns.preview, assigns.panel))

    ~H"""
    <section class="space-y-4 rounded-lg border border-base-300 bg-base-100 p-4">
      <div>
        <p class="text-xs font-semibold uppercase tracking-normal text-primary">Step 1</p>
        <h3 class="mt-1 text-sm font-semibold">SRQL source</h3>
        <p class="text-xs text-base-content/70">
          Define the dataset query this panel owns. Previewing the query drives the available visuals and field bindings.
        </p>
      </div>

      <div class="grid grid-cols-1 gap-3 sm:grid-cols-2">
        <.input field={@form[:dataset_key]} type="text" label="Dataset key" />
        <.input field={@form[:title]} type="text" label="Panel title" />
      </div>

      <.srql_editor
        id={"authored-panel-srql-editor-#{(@panel && @panel.id) || "new"}"}
        field={@form[:srql_query]}
        label="SRQL Query"
        rich
      />

      <div class="flex flex-wrap items-center gap-2">
        <button type="submit" name="intent" value="preview" class="btn btn-sm">
          <.icon name="hero-play" class="size-4" /> Preview Query
        </button>
        <span :if={!@preview and is_nil(@panel)} class="text-xs text-base-content/70">
          Preview first to unlock compatible visualizations.
        </span>
      </div>
    </section>

    <section class="space-y-4 rounded-lg border border-base-300 bg-base-100 p-4">
      <div>
        <p class="text-xs font-semibold uppercase tracking-normal text-primary">Step 2</p>
        <h3 class="mt-1 text-sm font-semibold">Visualization and bindings</h3>
        <p class="text-xs text-base-content/70">
          Choose a supported visual and map fields from the preview output into labels, values, status, and layout.
        </p>
      </div>

      <div class="grid grid-cols-1 gap-3 sm:grid-cols-2">
        <.input
          field={@form[:visual_type]}
          type="select"
          label="Visualization"
          options={@visual_options}
        />
        <.input
          field={@form[:refresh_interval_seconds]}
          type="number"
          label="Refresh interval seconds"
        />
        <.input field={@form[:position]} type="number" label="Position" />
      </div>

      <.panel_structured_fields
        form={@form}
        field_options={@field_options}
        numeric_field_options={@numeric_field_options}
        dimension_field_options={@dimension_field_options}
        datetime_field_options={@datetime_field_options}
      />

      <div class="flex flex-wrap gap-2 border-t border-base-300 pt-4">
        <button
          type="submit"
          name="intent"
          value="save"
          class="btn btn-sm btn-primary"
          disabled={!@preview and is_nil(@panel)}
        >
          <.icon name="hero-check" class="size-4" /> Save Panel
        </button>
        <button type="button" class="btn btn-sm" phx-click="cancel_panel_edit">
          Cancel
        </button>
      </div>
    </section>
    """
  end

  attr(:form, :any, required: true)
  attr(:field_options, :list, default: [])
  attr(:numeric_field_options, :list, default: [])
  attr(:dimension_field_options, :list, default: [])
  attr(:datetime_field_options, :list, default: [])

  defp panel_structured_fields(assigns) do
    visual = assigns.form |> Phoenix.HTML.Form.input_value(:visual_type) |> to_string()

    assigns =
      assigns
      |> assign(:visual, visual)
      |> assign(:aggregate_options, [
        {"Sum", "sum"},
        {"Average", "avg"},
        {"Minimum", "min"},
        {"Maximum", "max"},
        {"Count", "count"}
      ])

    ~H"""
    <section class="grid grid-cols-1 gap-3 rounded-lg border border-base-300 bg-base-100 p-3 lg:col-span-2 lg:grid-cols-2">
      <div class="lg:col-span-2">
        <h4 class="text-xs font-semibold uppercase tracking-normal text-base-content/60">
          Data bindings
        </h4>
      </div>
      <.input
        :if={@visual in ["stat", "count", "gauge", "line", "area", "bar", "category", "pivot"]}
        field={@form[:value_field]}
        type="select"
        label="Value field"
        options={@numeric_field_options}
      />
      <.input
        :if={@visual in ["availability"]}
        field={@form[:numerator_field]}
        type="select"
        label="Available/OK field"
        options={@numeric_field_options}
      />
      <.input
        :if={@visual in ["availability"]}
        field={@form[:denominator_field]}
        type="select"
        label="Total field"
        options={@numeric_field_options}
      />
      <.input
        :if={
          @visual in [
            "stat",
            "count",
            "gauge",
            "availability",
            "line",
            "area",
            "bar",
            "category",
            "status_list"
          ]
        }
        field={@form[:label_field]}
        type="select"
        label="Label field"
        options={@field_options}
      />
      <.input
        :if={@visual in ["line", "area"]}
        field={@form[:time_field]}
        type="select"
        label="Time field"
        options={@datetime_field_options}
      />
      <.input
        :if={@visual == "status_list"}
        field={@form[:status_field]}
        type="select"
        label="Status field"
        options={@field_options}
      />
      <.input
        :if={@visual == "pivot"}
        field={@form[:row_field]}
        type="select"
        label="Rows"
        options={@dimension_field_options}
      />
      <.input
        :if={@visual == "pivot"}
        field={@form[:column_field]}
        type="select"
        label="Columns"
        options={@dimension_field_options}
      />
      <.input
        :if={@visual == "pivot"}
        field={@form[:aggregate]}
        type="select"
        label="Aggregate"
        options={@aggregate_options}
      />
      <.input
        :if={@visual == "pivot"}
        field={@form[:empty_value]}
        type="text"
        label="Empty value"
      />
    </section>

    <section class="grid grid-cols-1 gap-3 rounded-lg border border-base-300 bg-base-100 p-3 lg:col-span-2 lg:grid-cols-2">
      <div class="lg:col-span-2">
        <h4 class="text-xs font-semibold uppercase tracking-normal text-base-content/60">
          Display
        </h4>
      </div>
      <.input field={@form[:display_label]} type="text" label="Display label" />
      <.input field={@form[:unit]} type="text" label="Unit" />
      <.input field={@form[:caption]} type="text" label="Caption" />
      <.input
        :if={@visual == "table"}
        field={@form[:table_columns]}
        type="text"
        label="Table columns"
      />
    </section>

    <section class="grid grid-cols-2 gap-3 rounded-lg border border-base-300 bg-base-100 p-3 lg:col-span-2 lg:grid-cols-4">
      <div class="col-span-2 lg:col-span-4">
        <h4 class="text-xs font-semibold uppercase tracking-normal text-base-content/60">
          Layout
        </h4>
      </div>
      <.input field={@form[:layout_x]} type="number" label="X" />
      <.input field={@form[:layout_y]} type="number" label="Y" />
      <.input field={@form[:layout_w]} type="number" label="Width" />
      <.input field={@form[:layout_h]} type="number" label="Height" />
    </section>
    """
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

  defp preview_panel_query(scope, panel, variable_values) do
    query = substitute_variables(panel.srql_query, variable_values)
    Dashboards.preview_authored_query(scope, query, limit: 250)
  end

  defp preview_trend_query(scope, panel, variable_values) do
    query =
      panel
      |> Map.get(:visual_config, %{})
      |> Map.get("trend_query")

    case query do
      value when is_binary(value) and value != "" ->
        Dashboards.preview_authored_query(scope, substitute_variables(value, variable_values), limit: 250)

      _ ->
        nil
    end
  end

  defp dashboard_variables(%{variables: variables}) when is_map(variables) do
    variables
    |> Enum.map(fn {name, config} -> dashboard_variable(name, config) end)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(& &1.name)
  end

  defp dashboard_variables(%{variables: variables}) when is_list(variables) do
    variables
    |> Enum.map(fn
      %{"name" => name} = config -> dashboard_variable(name, config)
      %{name: name} = config -> dashboard_variable(name, config)
      name when is_binary(name) -> dashboard_variable(name, %{})
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp dashboard_variables(_dashboard), do: []

  defp dashboard_variable(name, config) when is_binary(name) do
    normalized = normalize_variable_name(name)

    if normalized == "" do
      nil
    else
      config = if is_map(config), do: config, else: %{}
      options = variable_options(config)
      default = variable_default(config, options)

      %{
        name: normalized,
        label: config["label"] || config[:label] || humanize_field(normalized),
        options: options,
        default: default
      }
    end
  end

  defp dashboard_variable(_name, _config), do: nil

  defp dashboard_variable_values(dashboard, current_values) do
    variables = dashboard_variables(dashboard)
    current_values = current_values || %{}

    Map.new(variables, fn variable ->
      value = Map.get(current_values, variable.name) || variable.default || List.first(variable.options) || ""
      {variable.name, to_string(value)}
    end)
  end

  defp variable_options(config) do
    options = config["options"] || config[:options] || []

    options
    |> List.wrap()
    |> Enum.map(&to_string/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp variable_default(config, options) do
    default = config["default"] || config[:default] || List.first(options) || ""
    to_string(default)
  end

  defp normalize_variable_name(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.replace(~r/[^a-zA-Z0-9_-]+/, "_")
  end

  defp substitute_variables(query, values) when is_binary(query) and is_map(values) do
    Regex.replace(~r/\$\{([a-zA-Z][a-zA-Z0-9_-]*)\}/, query, fn _match, name ->
      Map.get(values, name, "")
    end)
  end

  defp substitute_variables(query, _values), do: query

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
    width = layout |> Map.get("w", 4) |> bounded_integer(1, 12)
    height = layout |> Map.get("h", 4) |> bounded_integer(2, 16)
    x = rem(position * width, 12)
    y = div(position * width, 12) * height

    %{"x" => x, "y" => y, "w" => width, "h" => height, "order" => position}
  end

  defp compact_dashboard_panels(socket) do
    panels = socket.assigns.dashboard.panels || []

    panels
    |> Enum.sort_by(&{&1.position, Map.get(&1.layout || %{}, "y", 0), Map.get(&1.layout || %{}, "x", 0)})
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {panel, index}, {:ok, updated} ->
      layout = compact_layout_for_panel(panel, index)

      case Dashboards.update_authored_panel(socket.assigns.current_scope, panel, %{layout: layout, position: index}) do
        {:ok, panel} -> {:cont, {:ok, updated ++ [panel]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp compact_layout_for_panel(panel, index) do
    layout = panel.layout || %{}
    width = layout |> Map.get("w", 4) |> bounded_integer(1, 12)
    height = layout |> Map.get("h", 4) |> bounded_integer(2, 16)
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

  defp dashboard_canvas_visual_options do
    Enum.map(Dashboards.authored_visual_options(), fn option ->
      %{
        type: to_string(option.type),
        label: option.label
      }
    end)
  end

  defp dashboard_canvas_panels(nil, _panel_results), do: []

  defp dashboard_canvas_panels(%{panels: panels}, panel_results) do
    panels
    |> List.wrap()
    |> Enum.map(fn panel ->
      %{
        id: panel.id,
        dataset_key: panel.dataset_key || "primary",
        title: panel.title || "Panel",
        srql_query: panel.srql_query || "",
        visual_type: to_string(panel.visual_type || :table),
        data_binding: panel.data_binding || %{},
        display_config: panel.display_config || %{},
        visual_config: panel.visual_config || %{},
        field_metadata: canvas_field_metadata(panel.field_metadata || %{}),
        layout: panel.layout || %{},
        refresh_interval_seconds: panel.refresh_interval_seconds || 0,
        preview: canvas_panel_preview(Map.get(panel_results || %{}, panel.id), panel)
      }
    end)
  end

  defp dashboard_canvas_panels(_dashboard, _panel_results), do: []

  defp canvas_field_metadata(metadata) do
    %{
      fields: canvas_fields(metadata_fields(metadata)),
      compatible_visuals: Enum.map(panel_compatible_visuals(%{field_metadata: metadata}), &to_string/1)
    }
  end

  defp canvas_panel_preview({:ok, preview}, _panel) when is_map(preview) do
    %{
      fields: canvas_fields(preview_fields(preview)),
      rows: preview |> preview_rows() |> Enum.take(25),
      compatible_visuals: preview |> preview_compatible_visuals() |> Enum.map(&to_string/1)
    }
  end

  defp canvas_panel_preview(_result, panel) do
    %{
      fields: canvas_fields(metadata_fields(panel.field_metadata || %{})),
      rows: [],
      compatible_visuals: panel |> panel_compatible_visuals() |> Enum.map(&to_string/1)
    }
  end

  defp canvas_fields(fields) do
    Enum.map(fields || [], fn field ->
      %{
        name: field_name(field),
        type: field |> field_type() |> to_string(),
        sample: field_sample(field)
      }
    end)
  end

  defp preview_rows(%{rows: rows}) when is_list(rows), do: rows
  defp preview_rows(%{"rows" => rows}) when is_list(rows), do: rows
  defp preview_rows(_preview), do: []

  defp field_sample(%{sample: sample}), do: sample
  defp field_sample(%{"sample" => sample}), do: sample
  defp field_sample(_field), do: nil

  defp canvas_selected_panel_id(id, %{panels: panels}) when is_binary(id) and id != "new" do
    if Enum.any?(panels || [], &(&1.id == id)), do: id, else: ""
  end

  defp canvas_selected_panel_id(_id, _dashboard), do: ""

  defp editing_panel(%{panels: panels}, id) when is_binary(id) and id != "new" do
    Enum.find(panels || [], &(&1.id == id))
  end

  defp editing_panel(_dashboard, _id), do: nil

  defp canvas_visual_type(value) do
    supported = MapSet.new(Dashboards.authored_visual_options(), &to_string(&1.type))

    value = to_string(value || "table")
    if MapSet.member?(supported, value), do: value, else: "table"
  end

  defp canvas_new_panel_layout(visual_type, panels) do
    width = canvas_default_width(visual_type)
    height = canvas_default_height(visual_type)
    position = length(panels || [])

    %{"w" => width, "h" => height}
    |> next_panel_layout(position)
    |> Map.put("order", position)
  end

  defp canvas_default_width(visual_type) when visual_type in ["table", "pivot", "line", "area"], do: 12
  defp canvas_default_width("status_list"), do: 8
  defp canvas_default_width(_visual_type), do: 4

  defp canvas_default_height(visual_type) when visual_type in ["table", "pivot"], do: 8
  defp canvas_default_height(visual_type) when visual_type in ["line", "area", "bar", "category"], do: 6
  defp canvas_default_height(_visual_type), do: 4

  defp update_canvas_panel_layouts(socket, layouts) do
    panels = socket.assigns.dashboard.panels || []
    layout_index = canvas_layout_index(layouts)

    result =
      Enum.reduce_while(panels, {:ok, []}, fn panel, {:ok, updated} ->
        case Map.get(layout_index, panel.id) do
          nil ->
            {:cont, {:ok, updated ++ [panel]}}

          %{layout: layout, position: position} ->
            attrs = %{layout: Map.merge(panel.layout || %{}, layout), position: position}

            case Dashboards.update_authored_panel(socket.assigns.current_scope, panel, attrs) do
              {:ok, panel} -> {:cont, {:ok, updated ++ [panel]}}
              {:error, reason} -> {:halt, {:error, reason}}
            end
        end
      end)

    case result do
      {:ok, panels} -> {:ok, Enum.sort_by(panels, &{&1.position, &1.inserted_at})}
      error -> error
    end
  end

  defp canvas_layout_index(layouts) do
    layouts
    |> Enum.filter(&is_map/1)
    |> Enum.map(fn layout ->
      %{
        id: to_string(layout["id"] || layout[:id] || ""),
        x: integer_value(layout["x"] || layout[:x], 0),
        y: integer_value(layout["y"] || layout[:y], 0),
        w: integer_value(layout["w"] || layout[:w], 12),
        h: integer_value(layout["h"] || layout[:h], 8)
      }
    end)
    |> Enum.reject(&(&1.id == ""))
    |> Enum.sort_by(&{&1.y, &1.x, &1.id})
    |> Enum.with_index()
    |> Map.new(fn {layout, index} ->
      {
        layout.id,
        %{
          position: index,
          layout: %{
            "x" => bounded_integer(layout.x, 0, 11),
            "y" => bounded_integer(layout.y, 0, 1_000),
            "w" => bounded_integer(layout.w, 1, 12),
            "h" => bounded_integer(layout.h, 2, 16),
            "order" => index
          }
        }
      }
    end)
  end

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

  defp panel_visual_select_options(nil, nil), do: all_panel_visual_options()

  defp panel_visual_select_options(preview, panel) do
    compatible =
      preview
      |> preview_compatible_visuals()
      |> case do
        [] -> panel_compatible_visuals(panel)
        visuals -> visuals
      end

    compatible = if compatible == [], do: [:table], else: compatible

    Dashboards.authored_visual_options()
    |> Enum.filter(&(&1.type in compatible))
    |> Enum.map(&{&1.label, to_string(&1.type)})
  end

  defp all_panel_visual_options do
    Enum.map(Dashboards.authored_visual_options(), &{&1.label, to_string(&1.type)})
  end

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

  defp panel_field_options(preview, panel, panel_results) do
    fields = panel_fields(preview, panel, panel_results)
    [{"Auto", ""} | Enum.map(fields, &{field_label(&1), field_name(&1)})]
  end

  defp numeric_panel_field_options(preview, panel, panel_results) do
    fields = Enum.filter(panel_fields(preview, panel, panel_results), &(field_type(&1) == :number))
    [{"Auto", ""} | Enum.map(fields, &{field_label(&1), field_name(&1)})]
  end

  defp dimension_panel_field_options(preview, panel, panel_results) do
    fields =
      Enum.filter(panel_fields(preview, panel, panel_results), &(field_type(&1) in [:string, :boolean, :datetime]))

    [{"Auto", ""} | Enum.map(fields, &{field_label(&1), field_name(&1)})]
  end

  defp datetime_panel_field_options(preview, panel, panel_results) do
    fields = Enum.filter(panel_fields(preview, panel, panel_results), &(field_type(&1) == :datetime))
    [{"Auto", ""} | Enum.map(fields, &{field_label(&1), field_name(&1)})]
  end

  defp panel_fields(preview, panel, panel_results) do
    cond do
      preview_fields(preview) != [] ->
        preview_fields(preview)

      panel && match?({:ok, _}, Map.get(panel_results, panel.id)) ->
        {:ok, result} = Map.get(panel_results, panel.id)
        preview_fields(result)

      panel ->
        metadata_fields(panel.field_metadata || %{})

      true ->
        []
    end
  end

  defp preview_fields(%{fields: fields}) when is_list(fields), do: fields
  defp preview_fields(%{"fields" => fields}) when is_list(fields), do: fields
  defp preview_fields(_preview), do: []

  defp preview_compatible_visuals(%{compatible_visuals: visuals}) when is_list(visuals),
    do: Enum.map(visuals, &visual_atom/1)

  defp preview_compatible_visuals(%{"compatible_visuals" => visuals}) when is_list(visuals),
    do: Enum.map(visuals, &visual_atom/1)

  defp preview_compatible_visuals(_preview), do: []

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

  defp field_label(field), do: "#{humanize_field(field_name(field))} (#{field_type(field)})"

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

  defp empty_rows(assigns) do
    ~H"""
    <div class="flex min-h-24 items-center justify-center text-sm text-base-content/70">
      No rows returned.
    </div>
    """
  end

  attr(:value, :any, default: nil)
  attr(:renderer, :string, default: "text")

  defp table_cell(assigns) do
    assigns = assign(assigns, :cell, table_cell_value(assigns.value, assigns.renderer))

    ~H"""
    <%= case @cell do %>
      <% {:status, text, tone} -> %>
        <span class={["badge badge-sm", status_badge_class(tone)]} title={text}>
          <.icon name={status_icon(tone)} class="size-3" /> {text}
        </span>
      <% {:boolean, true} -> %>
        <span class="badge badge-sm badge-success" title="true">
          <.icon name="hero-check" class="size-3" /> true
        </span>
      <% {:boolean, false} -> %>
        <span class="badge badge-sm badge-error badge-outline" title="false">
          <.icon name="hero-x-mark" class="size-3" /> false
        </span>
      <% {:sparkline, points, title} -> %>
        <svg
          viewBox="0 0 100 24"
          preserveAspectRatio="none"
          class="h-6 w-28 text-primary"
          role="img"
          aria-label="sparkline"
        >
          <polyline points={points} fill="none" stroke="currentColor" stroke-width="2" />
        </svg>
        <span class="sr-only">{title}</span>
      <% {:json, summary, title} -> %>
        <span class="font-mono text-[11px]" title={title}>{summary}</span>
      <% {:text, text, title} -> %>
        <span title={title}>{text}</span>
    <% end %>
    """
  end

  defp table_cell_value(value, renderer) when renderer in ["status", "status_icon", "icon"] do
    text = format_value(value)
    {:status, text, status_tone(value)}
  end

  defp table_cell_value(value, "sparkline") do
    case table_sparkline_points(value) do
      "" -> {:text, format_value(value), format_value(value)}
      points -> {:sparkline, points, format_value(value)}
    end
  end

  defp table_cell_value(value, "boolean_icon") when is_boolean(value), do: {:boolean, value}
  defp table_cell_value(value, _renderer) when is_boolean(value), do: {:boolean, value}

  defp table_cell_value(value, "json_summary") when is_map(value) or is_list(value) do
    {:json, json_summary(value), json_title(value)}
  end

  defp table_cell_value(value, _renderer) when is_map(value) or is_list(value) do
    {:json, json_summary(value), json_title(value)}
  end

  defp table_cell_value(value, _renderer) when is_binary(value) do
    case decode_json_cell(value) do
      {:ok, decoded} -> {:json, json_summary(decoded), json_title(decoded)}
      :error -> text_cell(value)
    end
  end

  defp table_cell_value(value, _renderer) do
    value |> format_value() |> text_cell()
  end

  defp text_cell(text), do: {:text, text, text}

  defp decode_json_cell(value) do
    value = String.trim(value)

    if String.starts_with?(value, ["{", "["]) do
      case Jason.decode(value) do
        {:ok, decoded} when is_map(decoded) or is_list(decoded) -> {:ok, decoded}
        _ -> :error
      end
    else
      :error
    end
  end

  defp json_summary(value) when is_map(value) do
    keys = value |> Map.keys() |> Enum.map(&to_string/1)

    case keys do
      [] ->
        "0 fields"

      keys ->
        visible = keys |> Enum.take(3) |> Enum.join(", ")
        extra = max(length(keys) - 3, 0)
        suffix = if extra > 0, do: " +#{extra}", else: ""
        "#{length(keys)} #{plural_label("field", length(keys))}: #{visible}#{suffix}"
    end
  end

  defp json_summary(value) when is_list(value), do: "#{length(value)} #{plural_label("item", length(value))}"

  defp plural_label(label, 1), do: label
  defp plural_label(label, _count), do: label <> "s"

  defp json_title(value) do
    case Jason.encode(value) do
      {:ok, encoded} -> encoded
      _ -> inspect(value)
    end
  end

  defp default_renderer(%{type: :boolean}), do: "boolean_icon"

  defp default_renderer(%{name: name}) when name in ["status", "state", "health", "availability"], do: "status"

  defp default_renderer(%{sample: sample}) when is_map(sample) or is_list(sample), do: "json_summary"

  defp default_renderer(_field), do: "text"

  defp table_columns(panel, fields) do
    configured =
      panel
      |> Map.get(:display_config, %{})
      |> Map.get("table_columns", [])

    columns =
      configured
      |> Enum.filter(&is_map/1)
      |> Enum.reject(&(&1["visible"] == false))
      |> Enum.map(fn column ->
        %{
          field: column["field"] || column[:field],
          path: column["path"] || column[:path],
          label: column["label"] || humanize_field(column["field"] || column[:field]),
          renderer: column["renderer"] || "text"
        }
      end)
      |> Enum.reject(&is_nil(&1.field))

    case columns do
      [] ->
        Enum.map(fields, fn field ->
          %{
            field: field.name,
            path: nil,
            label: humanize_field(field.name),
            renderer: default_renderer(field)
          }
        end)

      columns ->
        columns
    end
  end

  defp table_value(row, %{field: field, path: path}) do
    value = Map.get(row, field)

    case path do
      path when is_binary(path) and path != "" -> value_at_path(value, path)
      _ -> value
    end
  end

  defp value_at_path(value, path) when is_map(value) and is_binary(path) do
    path
    |> String.split(".", trim: true)
    |> Enum.reduce(value, fn key, acc ->
      case acc do
        map when is_map(map) -> Map.get(map, key)
        _ -> nil
      end
    end)
  rescue
    ArgumentError -> nil
  end

  defp value_at_path(value, _path), do: value

  defp stat_value([row | _], fields) do
    key = first_numeric_field(fields)
    if key, do: Map.get(row, key)
  end

  defp stat_value(_rows, _fields), do: "No data"

  defp bound_value([row | _], panel, key) do
    field = binding_value(panel, key)
    if is_binary(field) and field != "", do: Map.get(row, field)
  end

  defp bound_value(_rows, _panel, _key), do: nil

  defp pivot_data(rows, panel, fields) do
    binding = panel.data_binding || %{}
    row_field = binding["row_field"] || first_string_field(fields)
    column_field = binding["column_field"] || status_field(fields) || first_string_field(fields)
    value_field = binding["value_field"] || first_numeric_field(fields)
    aggregate = binding["aggregate"] || "sum"
    empty_value = binding["empty_value"] || "0"

    grouped =
      Enum.reduce(rows, %{}, fn row, acc ->
        row_key = format_value(Map.get(row, row_field))
        column_key = format_value(Map.get(row, column_field))
        value = numeric(Map.get(row, value_field)) || 0

        update_in(acc, [Access.key(row_key, %{}), Access.key(column_key, [])], &[value | &1])
      end)

    columns =
      grouped
      |> Map.values()
      |> Enum.flat_map(&Map.keys/1)
      |> Enum.uniq()
      |> Enum.sort()

    pivot_rows =
      grouped
      |> Enum.sort_by(fn {label, _values} -> label end)
      |> Enum.map(fn {label, values_by_column} ->
        values =
          Map.new(columns, fn column ->
            values = Map.get(values_by_column, column, [])
            {column, aggregate_values(values, aggregate)}
          end)

        %{label: label, values: values, total: aggregate_values(Map.values(values), "sum")}
      end)

    %{
      row_label: humanize_field(row_field || "row"),
      columns: columns,
      rows: pivot_rows,
      empty_value: empty_value,
      show_totals?: true
    }
  end

  defp aggregate_values([], _aggregate), do: 0
  defp aggregate_values(values, "count"), do: length(values)
  defp aggregate_values(values, "avg"), do: Enum.sum(values) / max(length(values), 1)
  defp aggregate_values(values, "max"), do: Enum.max(values, fn -> 0 end)
  defp aggregate_values(values, "min"), do: Enum.min(values, fn -> 0 end)
  defp aggregate_values(values, _aggregate), do: Enum.sum(values)

  defp trend_summary({:ok, %{rows: rows, fields: fields}}) do
    value_key = first_numeric_field(fields)

    values =
      rows
      |> Enum.map(fn row -> numeric(Map.get(row, value_key)) end)
      |> Enum.reject(&is_nil/1)

    case values do
      [first | rest] when rest != [] ->
        last = List.last(rest)
        delta = last - first
        "#{format_value(first)} -> #{format_value(last)} (#{signed_number(delta)})"

      [single] ->
        format_value(single)

      _ ->
        nil
    end
  end

  defp trend_summary(_trend), do: nil

  defp signed_number(value) when is_number(value) and value >= 0, do: "+#{format_value(value)}"
  defp signed_number(value), do: format_value(value)

  defp visual_label(panel, fallback) do
    display_value(panel, "label", panel.title || fallback)
  end

  defp display_value(panel, key, fallback) do
    case panel.display_config || %{} do
      %{^key => value} when is_binary(value) and value != "" -> value
      _ -> fallback
    end
  end

  defp binding_value(panel, key) do
    case panel.data_binding || %{} do
      %{^key => value} when is_binary(value) -> value
      _ -> nil
    end
  end

  defp humanize_field(nil), do: ""

  defp humanize_field(value) do
    value
    |> to_string()
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  defp table_sparkline_points(values) when is_list(values) do
    values =
      values
      |> Enum.map(&numeric/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.take(40)

    case values do
      [] ->
        ""

      [_single] ->
        "0,12 100,12"

      values ->
        min_value = Enum.min(values)
        max_value = Enum.max(values)
        spread = max(max_value - min_value, 1.0)
        last_index = max(length(values) - 1, 1)

        values
        |> Enum.with_index()
        |> Enum.map_join(" ", fn {value, index} ->
          x = index / last_index * 100
          y = 24 - (value - min_value) / spread * 20 - 2
          "#{Float.round(x, 2)},#{Float.round(y, 2)}"
        end)
    end
  end

  defp table_sparkline_points(_value), do: ""

  defp status_tone(value) do
    value =
      value
      |> format_value()
      |> String.downcase()

    cond do
      value in ["ok", "up", "true", "healthy", "online", "available", "ready", "success"] -> :success
      value in ["warn", "warning", "degraded", "partial"] -> :warning
      value in ["fail", "failed", "false", "down", "critical", "error", "offline", "unavailable"] -> :error
      true -> :neutral
    end
  end

  defp status_badge_class(:success), do: "badge-success"
  defp status_badge_class(:warning), do: "badge-warning"
  defp status_badge_class(:error), do: "badge-error"
  defp status_badge_class(_tone), do: "badge-outline"

  defp status_icon(:success), do: "hero-check-circle"
  defp status_icon(:warning), do: "hero-exclamation-triangle"
  defp status_icon(:error), do: "hero-x-circle"
  defp status_icon(_tone), do: "hero-question-mark-circle"

  defp first_numeric_field(fields), do: first_field_of_type(fields, :number)
  defp first_string_field(fields), do: first_field_of_type(fields, :string)

  defp first_field_of_type(fields, type) do
    Enum.find_value(fields, fn field ->
      if field_type(field) == type, do: field_name(field)
    end)
  end

  defp numeric(value) when is_integer(value), do: value * 1.0
  defp numeric(value) when is_float(value), do: value

  defp numeric(value) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {number, ""} -> number
      _ -> nil
    end
  end

  defp numeric(_value), do: nil

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
