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
      |> assign(:loading?, connected?(socket))
      |> assign_grant_forms()
      |> assign_report_schedule_form()

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
                 Dashboards.get_authored_dashboard(scope, dashboard_id,
                   load: [:panels, :report_schedules]
                 ) do
            panels = Enum.sort_by(dashboard.panels || [], &{&1.position, &1.inserted_at})

            results =
              Map.new(panels, fn panel ->
                {panel.id, Dashboards.preview_authored_query(scope, panel.srql_query, limit: 250)}
              end)

            access = load_access_controls(scope, dashboard.id, access_assigns)

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
  def handle_async(
        {:load_dashboard, _dashboard_id},
        {:ok, {:ok, dashboard, panels, results, access}},
        socket
      ) do
    dashboard = Map.put(dashboard, :panels, panels)

    {:noreply,
     socket
     |> assign(:dashboard, dashboard)
     |> assign(:panel_results, results)
     |> assign(access)
     |> assign(:page_title, dashboard.title)
     |> assign(:loading?, false)
     |> assign_grant_forms()}
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
          <.link navigate={~p"/analytics"} class="btn btn-sm">
            <.icon name="hero-pencil-square" class="size-4" /> Dashboard Creator
          </.link>
        </section>

        <section
          :if={@dashboard and @can_share?}
          class="rounded-lg border border-base-300 bg-base-100"
        >
          <div class="flex flex-col gap-3 border-b border-base-300 px-4 py-3 lg:flex-row lg:items-center lg:justify-between">
            <div>
              <h2 class="text-sm font-semibold">Sharing</h2>
              <p class="text-xs text-base-content/55">
                Visibility is {@dashboard.visibility}; explicit grants can add users or reusable groups.
              </p>
            </div>
            <span class="badge badge-outline">{length(@access_grants)} grants</span>
          </div>

          <div class="grid grid-cols-1 gap-6 p-4 lg:grid-cols-[1fr_360px]">
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

        <section
          :if={@dashboard and @can_schedule_reports?}
          class="rounded-lg border border-base-300 bg-base-100"
        >
          <div class="border-b border-base-300 px-4 py-3">
            <h2 class="text-sm font-semibold">Email Reports</h2>
            <p class="text-xs text-base-content/55">
              One scanner job picks up due schedules and enqueues delivery attempts.
            </p>
          </div>

          <div class="grid grid-cols-1 gap-6 p-4 lg:grid-cols-[1fr_360px]">
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
                  <span class="badge badge-outline">
                    {schedule.last_status || if(schedule.enabled, do: "enabled", else: "disabled")}
                  </span>
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
    value = stat_value(assigns.rows, assigns.fields)
    assigns = assign(assigns, :value, value)

    ~H"""
    <div class="flex min-h-32 items-center">
      <div>
        <div class="text-4xl font-semibold tracking-normal">{@value}</div>
        <div class="mt-2 text-sm text-base-content/55">{first_numeric_field(@fields) || "value"}</div>
      </div>
    </div>
    """
  end

  defp render_visual(%{panel: %{visual_type: type}} = assigns)
       when type in [:bar, "bar", :category, "category"] do
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

  defp render_visual(%{panel: %{visual_type: type}} = assigns)
       when type in [:line, "line", :area, "area"] do
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
    ~H"""
    <div class="overflow-x-auto rounded-lg border border-base-300">
      <table class="table table-sm">
        <thead>
          <tr>
            <th :for={field <- @fields}>{field.name}</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={row <- Enum.take(@rows, 100)}>
            <td :for={field <- @fields} class="max-w-64 truncate">
              {format_value(Map.get(row, field.name))}
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

  defp load_access_controls(scope, dashboard_id, assigns) do
    access_grants =
      if assigns.can_share? do
        Dashboards.list_authored_access_grants(scope, dashboard_id)
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

  defp reload_access_controls(%{assigns: %{dashboard: %{id: dashboard_id}}} = socket) do
    access =
      load_access_controls(
        socket.assigns.current_scope,
        dashboard_id,
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

  defp access_assigns(assigns) do
    Map.take(assigns, [:can_share?, :can_view_groups?, :can_view_share_principals?])
  end

  defp merge_params(current, incoming), do: Map.merge(current || %{}, incoming || %{})

  defp can_share?(scope), do: RBAC.can?(scope, "analytics.dashboards.share")
  defp can_schedule_reports?(scope), do: RBAC.can?(scope, "analytics.reports.schedule")
  defp can_view_groups?(scope), do: RBAC.can?(scope, "identity.user_groups.view")

  defp can_view_share_principals?(scope),
    do: RBAC.can?(scope, "analytics.share_principals.view")

  defp authorize_share(socket) do
    if socket.assigns.can_share?, do: :ok, else: {:error, :forbidden}
  end

  defp authorize_report_schedule(socket) do
    if socket.assigns.can_schedule_reports?, do: :ok, else: {:error, :forbidden}
  end

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

  defp stat_value([row | _], fields) do
    key = first_numeric_field(fields)
    format_value(if key, do: Map.get(row, key))
  end

  defp stat_value(_rows, _fields), do: "No data"

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
  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)
end
