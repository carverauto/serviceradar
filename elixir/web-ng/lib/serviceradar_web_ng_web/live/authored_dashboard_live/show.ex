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
      |> assign(:settings_open?, false)
      |> assign(:editing_panel_id, nil)
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

    socket =
      if connected?(socket) do
        start_async(socket, {:load_dashboard, dashboard_id}, fn ->
          with {:ok, %AuthoredDashboard{} = dashboard} <-
                 Dashboards.get_authored_dashboard(scope, dashboard_id, load: [:panels, :report_schedules]) do
            panels = Enum.sort_by(dashboard.panels || [], &{&1.position, &1.inserted_at})

            results =
              Map.new(panels, fn panel ->
                {panel.id, Dashboards.preview_authored_query(scope, panel.srql_query, limit: 250)}
              end)

            access = load_access_controls(scope, dashboard, access_assigns)

            {:ok, dashboard, panels, results, access}
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
  def handle_async({:load_dashboard, _dashboard_id}, {:ok, {:ok, dashboard, panels, results, access}}, socket) do
    dashboard = Map.put(dashboard, :panels, panels)

    {:noreply,
     socket
     |> assign(:dashboard, dashboard)
     |> assign(:panel_results, results)
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
        {:noreply,
         socket
         |> assign(:editing_panel_id, panel.id)
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
     |> assign(:panel_params, default_panel_params())
     |> assign_panel_form()}
  end

  def handle_event("validate_panel", %{"panel" => params}, socket) do
    {:noreply,
     socket
     |> assign(:panel_params, merge_params(socket.assigns.panel_params, params))
     |> assign_panel_form()}
  end

  def handle_event("save_panel", %{"panel" => params}, socket) do
    panel =
      Enum.find(
        socket.assigns.dashboard.panels || [],
        &(&1.id == socket.assigns.editing_panel_id)
      )

    params = merge_params(socket.assigns.panel_params, params)

    with :ok <- authorize_panel_edit(socket),
         {:ok, panel} <- require_record(panel),
         {:ok, _panel} <-
           Dashboards.update_authored_panel(
             socket.assigns.current_scope,
             panel,
             panel_attrs(params)
           ) do
      {:noreply,
       socket
       |> put_flash(:info, "Panel updated")
       |> assign(:editing_panel_id, nil)
       |> assign(:panel_params, default_panel_params())
       |> reload_dashboard_panels()
       |> assign_panel_form()}
    else
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

        <section
          :if={@settings_open? and dashboard_settings_available?(@dashboard, assigns)}
          class="rounded-lg border border-base-300 bg-base-100"
        >
          <div class="flex flex-col gap-3 border-b border-base-300 px-4 py-3 lg:flex-row lg:items-center lg:justify-between">
            <div>
              <h2 class="text-sm font-semibold">Dashboard Settings</h2>
              <p class="text-xs text-base-content/55">
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
              <div class="border-b border-base-300 px-3 py-2">
                <h3 class="text-sm font-semibold">Panels</h3>
                <p class="text-xs text-base-content/55">
                  SRQL queries and visualizations that make up this dashboard.
                </p>
              </div>
              <div class="divide-y divide-base-200">
                <div
                  :for={panel <- @dashboard.panels || []}
                  class="space-y-3 p-3"
                >
                  <div class="grid grid-cols-1 gap-3 lg:grid-cols-[1fr_auto]">
                    <div class="min-w-0">
                      <div class="flex flex-wrap items-center gap-2">
                        <span class="text-sm font-medium">{panel.title}</span>
                        <span class="badge badge-sm badge-outline">{panel.visual_type}</span>
                      </div>
                      <p class="mt-1 truncate font-mono text-xs text-base-content/55">
                        {panel.srql_query}
                      </p>
                    </div>
                    <button
                      type="button"
                      class="btn btn-xs"
                      phx-click="edit_panel"
                      phx-value-id={panel.id}
                    >
                      <.icon name="hero-pencil-square" class="size-4" /> Edit
                    </button>
                  </div>

                  <.form
                    :if={@editing_panel_id == panel.id}
                    for={@panel_form}
                    as={:panel}
                    phx-change="validate_panel"
                    phx-submit="save_panel"
                    class="grid grid-cols-1 gap-3 rounded-lg border border-base-300 bg-base-200/30 p-3 lg:grid-cols-2"
                  >
                    <.input field={@panel_form[:dataset_key]} type="text" label="Dataset key" />
                    <.input field={@panel_form[:title]} type="text" label="Title" />
                    <.input
                      field={@panel_form[:visual_type]}
                      type="select"
                      label="Visualization"
                      options={visual_select_options()}
                    />
                    <div class="lg:col-span-2">
                      <.input field={@panel_form[:srql_query]} type="textarea" label="SRQL Query" />
                    </div>
                    <.input
                      field={@panel_form[:refresh_interval_seconds]}
                      type="number"
                      label="Refresh interval seconds"
                    />
                    <.input field={@panel_form[:position]} type="number" label="Position" />
                    <div class="lg:col-span-2">
                      <.input
                        field={@panel_form[:data_binding_json]}
                        type="textarea"
                        label="Data binding JSON"
                      />
                    </div>
                    <div class="lg:col-span-2">
                      <.input
                        field={@panel_form[:display_config_json]}
                        type="textarea"
                        label="Display config JSON"
                      />
                    </div>
                    <div class="lg:col-span-2">
                      <.input
                        field={@panel_form[:visual_config_json]}
                        type="textarea"
                        label="Visual config JSON"
                      />
                    </div>
                    <div class="lg:col-span-2">
                      <.input field={@panel_form[:layout_json]} type="textarea" label="Layout JSON" />
                    </div>
                    <div class="flex flex-wrap gap-2 lg:col-span-2">
                      <button type="submit" class="btn btn-sm btn-primary">
                        <.icon name="hero-check" class="size-4" /> Save Panel
                      </button>
                      <button type="button" class="btn btn-sm" phx-click="cancel_panel_edit">
                        Cancel
                      </button>
                    </div>
                  </.form>
                </div>
              </div>
            </section>

            <section
              :if={can_share_dashboard?(@dashboard, assigns)}
              class="rounded-lg border border-base-300"
            >
              <div class="flex flex-col gap-2 border-b border-base-300 px-3 py-2 sm:flex-row sm:items-center sm:justify-between">
                <div>
                  <h3 class="text-sm font-semibold">Sharing</h3>
                  <p class="text-xs text-base-content/55">
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
                        <div class="mt-1 font-mono text-xs text-base-content/55">
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
                    <p class="mt-2 text-xs text-base-content/55">
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
          class="grid grid-cols-1 gap-4 xl:grid-cols-2"
        >
          <.panel_result
            :for={panel <- @dashboard.panels || []}
            panel={panel}
            result={Map.get(@panel_results, panel.id)}
          />
        </section>
      </div>
    </Layouts.app>
    """
  end

  defp panel_result(%{result: {:ok, preview}} = assigns) do
    assigns =
      assigns
      |> assign(:rows, preview.rows)
      |> assign(:fields, preview.fields)

    ~H"""
    <article class="rounded-lg border border-base-300 bg-base-100">
      <div class="flex flex-col gap-2 border-b border-base-300 px-4 py-3 sm:flex-row sm:items-center sm:justify-between">
        <div class="min-w-0">
          <h2 class="truncate text-sm font-semibold">{@panel.title}</h2>
          <p class="mt-1 truncate font-mono text-xs text-base-content/45">{@panel.srql_query}</p>
        </div>
        <span class="badge badge-outline">{@panel.visual_type}</span>
      </div>
      <div class="p-4">
        <.render_visual panel={@panel} rows={@rows} fields={@fields} />
      </div>
    </article>
    """
  end

  defp panel_result(%{result: {:error, reason}} = assigns) do
    assigns = assign(assigns, :message, format_error(reason))

    ~H"""
    <article class="rounded-lg border border-error/30 bg-base-100">
      <div class="border-b border-error/20 px-4 py-3">
        <h2 class="text-sm font-semibold">{@panel.title}</h2>
      </div>
      <div class="p-4 text-sm text-error">{@message}</div>
    </article>
    """
  end

  defp panel_result(assigns) do
    ~H"""
    <article class="rounded-lg border border-base-300 bg-base-100 p-4 text-sm text-base-content/60">
      {@panel.title}
    </article>
    """
  end

  defp render_visual(%{panel: %{visual_type: type}} = assigns) when type in [:stat, "stat"] do
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

    ~H"""
    <div class="flex min-h-32 items-center">
      <div>
        <div class="text-4xl font-semibold tracking-normal">
          {@value}<span class="text-xl">{@unit}</span>
        </div>
        <div class="mt-2 text-sm text-base-content/55">{@label}</div>
      </div>
    </div>
    """
  end

  defp render_visual(%{panel: %{visual_type: type}} = assigns)
       when type in [:gauge, "gauge", :availability, "availability"] do
    assigns = assign(assigns, :gauge, gauge_data(assigns.rows, assigns.panel, assigns.fields))

    ~H"""
    <div class="flex min-h-44 flex-col justify-center gap-3">
      <div class="flex items-baseline justify-between gap-3">
        <div>
          <div class="text-sm font-medium">{@gauge.label}</div>
          <div class="mt-1 text-xs text-base-content/55">{@gauge.caption}</div>
        </div>
        <div class="text-3xl font-semibold tracking-normal">
          {@gauge.display}<span class="text-lg">{@gauge.unit}</span>
        </div>
      </div>
      <progress class="progress progress-primary h-4" value={@gauge.percent} max="100"></progress>
      <div class="flex justify-between text-xs text-base-content/55">
        <span>{@gauge.numerator_label}: {@gauge.numerator}</span>
        <span>{@gauge.denominator_label}: {@gauge.denominator}</span>
      </div>
    </div>
    """
  end

  defp render_visual(%{panel: %{visual_type: type}} = assigns) when type in [:bar, "bar", :category, "category"] do
    assigns = assign(assigns, :bars, bars(assigns.rows, assigns.fields))

    ~H"""
    <div class="space-y-3">
      <div :for={bar <- @bars} class="space-y-1">
        <div class="flex items-center justify-between gap-3 text-xs">
          <span class="truncate">{bar.label}</span>
          <span class="font-mono text-base-content/60">{bar.value}</span>
        </div>
        <progress class="progress progress-primary h-2" value={bar.percent} max="100"></progress>
      </div>
      <.empty_rows :if={@bars == []} />
    </div>
    """
  end

  defp render_visual(%{panel: %{visual_type: type}} = assigns) when type in [:line, "line", :area, "area"] do
    assigns = assign(assigns, :points, sparkline_points(assigns.rows, assigns.fields))

    ~H"""
    <div class="h-48 rounded-lg border border-base-200 bg-base-200/30 p-3">
      <svg
        viewBox="0 0 100 40"
        preserveAspectRatio="none"
        class="h-full w-full"
        role="img"
        aria-label="Time series"
      >
        <polyline
          :if={@points != ""}
          points={@points}
          fill="none"
          stroke="currentColor"
          stroke-width="2"
          class="text-primary"
        />
      </svg>
      <.empty_rows :if={@points == ""} />
    </div>
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

  defp default_panel_params do
    %{
      "dataset_key" => "primary",
      "title" => "",
      "srql_query" => "",
      "visual_type" => "table",
      "data_binding_json" => "{}",
      "display_config_json" => "{}",
      "visual_config_json" => "{}",
      "layout_json" => "{}",
      "refresh_interval_seconds" => "0",
      "position" => "0"
    }
  end

  defp panel_to_params(panel) do
    %{
      "dataset_key" => panel.dataset_key || "primary",
      "title" => panel.title || "",
      "srql_query" => panel.srql_query || "",
      "visual_type" => to_string(panel.visual_type || :table),
      "data_binding_json" => Jason.encode!(panel.data_binding || %{}, pretty: true),
      "display_config_json" => Jason.encode!(panel.display_config || %{}, pretty: true),
      "visual_config_json" => Jason.encode!(panel.visual_config || %{}, pretty: true),
      "layout_json" => Jason.encode!(panel.layout || %{}, pretty: true),
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
        {panel.id, Dashboards.preview_authored_query(socket.assigns.current_scope, panel.srql_query, limit: 250)}
      end)

    socket
    |> assign(:dashboard, Map.put(dashboard, :panels, panels))
    |> assign(:panel_results, results)
  end

  defp reload_dashboard_panels(socket), do: socket

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
      data_binding: json_map(params["data_binding_json"]),
      display_config: json_map(params["display_config_json"]),
      visual_config: json_map(params["visual_config_json"]),
      layout: json_map(params["layout_json"]),
      refresh_interval_seconds: integer_value(params["refresh_interval_seconds"], 0),
      position: integer_value(params["position"], 0)
    }
  end

  defp json_map(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} when is_map(decoded) -> decoded
      _ -> %{}
    end
  end

  defp json_map(_value), do: %{}

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

  defp access_select_options, do: [{"View", "view"}, {"Edit", "edit"}]

  defp visual_select_options do
    Enum.map(Dashboards.authored_visual_options(), &{&1.label, to_string(&1.type)})
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
    <div class="flex min-h-24 items-center justify-center text-sm text-base-content/55">
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
    {:json, json_summary(value), inspect(value)}
  end

  defp table_cell_value(value, _renderer) when is_map(value) or is_list(value) do
    {:json, json_summary(value), inspect(value)}
  end

  defp table_cell_value(value, _renderer) do
    text = format_value(value)
    {:text, text, text}
  end

  defp json_summary(value) when is_map(value) do
    keys = value |> Map.keys() |> Enum.map(&to_string/1) |> Enum.take(3)
    "{#{Enum.join(keys, ", ")}}"
  end

  defp json_summary(value) when is_list(value), do: "[#{length(value)} items]"

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

  defp gauge_data(rows, panel, fields) do
    binding = panel.data_binding || %{}
    row = List.first(rows) || %{}

    numerator_field =
      binding["numerator_field"] || binding["value_field"] || first_numeric_field(fields)

    denominator_field = binding["denominator_field"]
    numerator = numeric(Map.get(row, numerator_field)) || 0.0
    denominator = numeric(Map.get(row, denominator_field)) || 100.0
    percent = if denominator > 0, do: numerator / denominator * 100, else: numerator
    percent = percent |> max(0.0) |> min(100.0)

    %{
      label: visual_label(panel, "Gauge"),
      caption: display_value(panel, "caption", ""),
      unit: display_value(panel, "unit", "%"),
      display: :erlang.float_to_binary(percent, decimals: 1),
      percent: percent,
      numerator: format_value(numerator),
      denominator: format_value(denominator),
      numerator_label: humanize_field(numerator_field || "value"),
      denominator_label: humanize_field(denominator_field || "total")
    }
  end

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

  defp bars(rows, fields) do
    label_key = first_string_field(fields)
    value_key = first_numeric_field(fields)

    values =
      if label_key && value_key do
        rows
        |> Enum.take(12)
        |> Enum.map(fn row ->
          %{label: format_value(Map.get(row, label_key)), value: numeric(Map.get(row, value_key))}
        end)
      else
        []
      end

    max_value = values |> Enum.map(& &1.value) |> Enum.max(fn -> 0 end)

    Enum.map(values, fn item ->
      percent = if max_value > 0, do: item.value / max_value * 100, else: 0
      Map.put(item, :percent, percent)
    end)
  end

  defp sparkline_points(rows, fields) do
    value_key = first_numeric_field(fields)

    values =
      rows
      |> Enum.take(80)
      |> Enum.map(fn row -> numeric(Map.get(row, value_key)) end)
      |> Enum.reject(&is_nil/1)

    case values do
      [] ->
        ""

      [_single] ->
        "0,20 100,20"

      values ->
        min_value = Enum.min(values)
        max_value = Enum.max(values)
        spread = max(max_value - min_value, 1.0)
        last_index = max(length(values) - 1, 1)

        values
        |> Enum.with_index()
        |> Enum.map_join(" ", fn {value, index} ->
          x = index / last_index * 100
          y = 40 - (value - min_value) / spread * 36 - 2
          "#{Float.round(x, 2)},#{Float.round(y, 2)}"
        end)
    end
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
      if field.type == type, do: field.name
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
