defmodule ServiceRadarWebNGWeb.AuthoredDashboardLive.Index do
  @moduledoc false
  use ServiceRadarWebNGWeb, :live_view

  alias ServiceRadarWebNG.Dashboards
  alias ServiceRadarWebNG.RBAC
  alias ServiceRadarWebNGWeb.SRQL.Builder, as: SRQLBuilder
  alias ServiceRadarWebNGWeb.SRQL.Catalog

  @current_path "/analytics"
  @default_query ~s|in:services time:last_1h sort:timestamp:desc limit:25|
  @visibility_options [{"Private", "private"}, {"Shared", "shared"}, {"Public", "public"}]

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    socket =
      socket
      |> assign(:page_title, "Analytics")
      |> assign(:current_path, @current_path)
      |> assign(:dashboards, [])
      |> assign(:users, [])
      |> assign(:user_groups, [])
      |> assign(:user_group_memberships, [])
      |> assign(:loading_dashboards?, connected?(socket))
      |> assign(:loading_access?, connected?(socket))
      |> assign(:default_query, @default_query)
      |> assign(:preview, nil)
      |> assign(:pending_panels, [])
      |> assign(:selected_pending_panel_id, "")
      |> assign(:selected_visuals, [:table])
      |> assign(:visual_options, Dashboards.authored_visual_options())
      |> assign_dashboard_builder(default_dashboard_params()["srql_query"])
      |> assign(:visibility_options, @visibility_options)
      |> assign(:can_manage?, can_manage?(scope))
      |> assign(:can_manage_groups?, can_manage_groups?(scope))
      |> assign(:can_view_share_principals?, can_view_share_principals?(scope))
      |> assign(:dashboard_params, default_dashboard_params())
      |> assign(:group_params, default_group_params())
      |> assign(:membership_params, default_membership_params())
      |> assign_form()
      |> assign_group_forms()

    access_assigns = access_assigns(socket.assigns)

    socket =
      if connected?(socket) do
        socket
        |> start_async(:load_dashboards, fn ->
          Dashboards.list_authored_dashboards(scope, %{status: [:draft, :active]})
        end)
        |> start_async(:load_access_controls, fn ->
          load_access_controls(scope, access_assigns)
        end)
      else
        socket
      end

    {:ok, socket}
  end

  @impl true
  def handle_async(:load_dashboards, {:ok, dashboards}, socket) do
    {:noreply, assign(socket, dashboards: dashboards, loading_dashboards?: false)}
  end

  def handle_async(:load_dashboards, {:exit, reason}, socket) do
    {:noreply,
     socket
     |> assign(:loading_dashboards?, false)
     |> put_flash(:error, "Could not load dashboards: #{format_error(reason)}")}
  end

  def handle_async(:load_access_controls, {:ok, access}, socket) do
    {:noreply,
     socket
     |> assign(access)
     |> assign(:loading_access?, false)
     |> assign_group_forms()}
  end

  def handle_async(:load_access_controls, {:exit, reason}, socket) do
    {:noreply,
     socket
     |> assign(:loading_access?, false)
     |> put_flash(:error, "Could not load access controls: #{format_error(reason)}")}
  end

  @impl true
  def handle_event("validate", %{"dashboard" => params}, socket) do
    params = merge_params(socket.assigns.dashboard_params, params)

    {:noreply,
     socket
     |> assign(:dashboard_params, params)
     |> assign(:preview, nil)
     |> assign_dashboard_builder(params["srql_query"])
     |> assign_form()}
  end

  def handle_event("preview", %{"dashboard" => params}, socket) do
    preview_query(socket, merge_params(socket.assigns.dashboard_params, params))
  end

  def handle_event("preview", _params, socket) do
    preview_query(socket, socket.assigns.dashboard_params)
  end

  def handle_event("save", %{"dashboard" => params}, socket) do
    scope = socket.assigns.current_scope
    params = merge_params(socket.assigns.dashboard_params, params)

    with :ok <- authorize_manage(socket),
         {:ok, dashboard_attrs, panel_attrs} <- attrs_from_params(scope, params, socket.assigns.pending_panels),
         {:ok, {dashboard, _panels}} <-
           Dashboards.create_authored_dashboard_with_panels(scope, dashboard_attrs, panel_attrs) do
      {:noreply,
       socket
       |> put_flash(:info, "Saved dashboard")
       |> push_navigate(to: ~p"/dashboard/#{Dashboards.authored_dashboard_route_ref(dashboard)}")}
    else
      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:dashboard_params, params)
         |> assign_form()
         |> put_flash(:error, "Save failed: #{format_error(reason)}")}
    end
  end

  def handle_event("add_panel", %{"dashboard" => params}, socket) do
    scope = socket.assigns.current_scope
    params = merge_params(socket.assigns.dashboard_params, params)

    case authorize_manage(socket) do
      :ok ->
        case panel_entry_from_params(scope, params, length(socket.assigns.pending_panels)) do
          {:ok, panel} ->
            {:noreply,
             socket
             |> assign(:pending_panels, socket.assigns.pending_panels ++ [panel])
             |> assign(:selected_pending_panel_id, panel.id)
             |> assign(:dashboard_params, next_panel_params(params, length(socket.assigns.pending_panels) + 1))
             |> assign(:preview, nil)
             |> assign(:selected_visuals, [:table])
             |> assign_dashboard_builder(@default_query)
             |> assign_form()}

          {:error, reason} ->
            {:noreply,
             socket
             |> assign(:dashboard_params, params)
             |> assign_form()
             |> put_flash(:error, "Panel add failed: #{format_error(reason)}")}
        end

      {:error, _reason} ->
        deny_manage(socket)
    end
  end

  def handle_event("add_panel", _params, socket) do
    handle_event("add_panel", %{"dashboard" => socket.assigns.dashboard_params}, socket)
  end

  def handle_event("remove_panel", %{"id" => id}, socket) do
    case authorize_manage(socket) do
      :ok ->
        panels =
          socket.assigns.pending_panels
          |> Enum.reject(&(&1.id == id))
          |> Enum.with_index()
          |> Enum.map(&position_pending_panel/1)

        selected_id =
          if Enum.any?(panels, &(&1.id == socket.assigns.selected_pending_panel_id)) do
            socket.assigns.selected_pending_panel_id
          else
            panels |> List.first() |> then(&((&1 && &1.id) || ""))
          end

        {:noreply, assign(socket, pending_panels: panels, selected_pending_panel_id: selected_id)}

      {:error, _reason} ->
        deny_manage(socket)
    end
  end

  def handle_event("canvas_add_panel", %{"visualType" => visual}, socket) do
    add_canvas_panel(socket, visual)
  end

  def handle_event("canvas_add_panel", %{"visual" => visual}, socket) do
    add_canvas_panel(socket, visual)
  end

  def handle_event("canvas_add_panel", _params, socket) do
    add_canvas_panel(socket, "table")
  end

  def handle_event("canvas_select_panel", %{"id" => id}, socket) do
    case authorize_manage(socket) do
      :ok -> {:noreply, assign(socket, :selected_pending_panel_id, id)}
      {:error, _reason} -> deny_manage(socket)
    end
  end

  def handle_event("canvas_update_panel", %{"id" => id, "panel" => params}, socket) when is_map(params) do
    scope = socket.assigns.current_scope

    case authorize_manage(socket) do
      :ok ->
        case Enum.find(socket.assigns.pending_panels, &(&1.id == id)) do
          nil ->
            {:noreply, put_flash(socket, :error, "Panel not found")}

          existing ->
            params = merge_params(pending_panel_params(existing), params)

            case panel_entry_from_params(scope, params, existing.position) do
              {:ok, panel} ->
                panel = %{panel | id: existing.id, layout: existing.layout, position: existing.position}
                panels = replace_pending_panel(socket.assigns.pending_panels, panel)

                {:noreply,
                 socket
                 |> assign(:pending_panels, panels)
                 |> assign(:selected_pending_panel_id, panel.id)
                 |> assign(:dashboard_params, params)
                 |> assign_form()}

              {:error, reason} ->
                {:noreply, put_flash(socket, :error, "Panel update failed: #{format_error(reason)}")}
            end
        end

      {:error, _reason} ->
        deny_manage(socket)
    end
  end

  def handle_event("canvas_layout_change", %{"layouts" => layouts}, socket) when is_list(layouts) do
    case authorize_manage(socket) do
      :ok ->
        layouts_by_id =
          layouts
          |> Enum.map(&normalize_canvas_layout/1)
          |> Enum.reject(&is_nil/1)
          |> Map.new()

        panels =
          socket.assigns.pending_panels
          |> Enum.map(fn panel ->
            case Map.get(layouts_by_id, panel.id) do
              nil ->
                panel

              layout ->
                %{panel | layout: Map.merge(panel.layout || %{}, layout)}
            end
          end)
          |> Enum.sort_by(fn panel ->
            {Map.get(panel.layout || %{}, "y", 0), Map.get(panel.layout || %{}, "x", 0), panel.position}
          end)
          |> Enum.with_index()
          |> Enum.map(fn {panel, position} ->
            layout = Map.put(panel.layout || %{}, "order", position)
            %{panel | layout: layout, position: position}
          end)

        {:noreply, assign(socket, :pending_panels, panels)}

      {:error, _reason} ->
        deny_manage(socket)
    end
  end

  def handle_event("reorder_panels", %{"ids" => ids}, socket) when is_list(ids) do
    case authorize_manage(socket) do
      :ok ->
        panels_by_id = Map.new(socket.assigns.pending_panels, &{&1.id, &1})

        panels =
          ids
          |> Enum.map(&Map.get(panels_by_id, &1))
          |> Enum.reject(&is_nil/1)
          |> Kernel.++(Enum.reject(socket.assigns.pending_panels, &(&1.id in ids)))
          |> Enum.with_index()
          |> Enum.map(&position_pending_panel/1)

        {:noreply, assign(socket, :pending_panels, panels)}

      {:error, _reason} ->
        deny_manage(socket)
    end
  end

  def handle_event("move_panel", %{"id" => id, "direction" => direction}, socket) do
    case authorize_manage(socket) do
      :ok ->
        panels = move_pending_panel(socket.assigns.pending_panels, id, direction)
        {:noreply, assign(socket, :pending_panels, panels)}

      {:error, _reason} ->
        deny_manage(socket)
    end
  end

  def handle_event("validate_group", %{"group" => params}, socket) do
    {:noreply,
     socket
     |> assign(:group_params, merge_params(socket.assigns.group_params, params))
     |> assign_group_forms()}
  end

  def handle_event("validate_membership", %{"membership" => params}, socket) do
    {:noreply,
     socket
     |> assign(:membership_params, merge_params(socket.assigns.membership_params, params))
     |> assign_group_forms()}
  end

  def handle_event("create_group", %{"group" => params}, socket) do
    scope = socket.assigns.current_scope
    params = merge_params(socket.assigns.group_params, params)

    with :ok <- authorize_manage_groups(socket),
         {:ok, _group} <- Dashboards.create_user_group(scope, params) do
      {:noreply,
       socket
       |> put_flash(:info, "User group created")
       |> assign(:group_params, default_group_params())
       |> reload_access_controls()}
    else
      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:group_params, params)
         |> assign_group_forms()
         |> put_flash(:error, "Group create failed: #{format_error(reason)}")}
    end
  end

  def handle_event("add_group_member", %{"membership" => params}, socket) do
    scope = socket.assigns.current_scope
    params = merge_params(socket.assigns.membership_params, params)

    with :ok <- authorize_manage_groups(socket),
         {:ok, _membership} <- Dashboards.add_user_group_member(scope, params) do
      {:noreply,
       socket
       |> put_flash(:info, "Group member added")
       |> assign(:membership_params, default_membership_params())
       |> reload_access_controls()}
    else
      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:membership_params, params)
         |> assign_group_forms()
         |> put_flash(:error, "Add member failed: #{format_error(reason)}")}
    end
  end

  def handle_event("archive", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope

    with :ok <- authorize_manage(socket),
         {:ok, dashboard} <- Dashboards.get_authored_dashboard(scope, id, load: []),
         {:ok, _dashboard} <- Dashboards.archive_authored_dashboard(scope, dashboard) do
      {:noreply,
       socket
       |> put_flash(:info, "Archived dashboard")
       |> assign(
         :dashboards,
         Dashboards.list_authored_dashboards(scope, %{status: [:draft, :active]})
       )}
    else
      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Archive failed: #{format_error(reason)}")}
    end
  end

  def handle_event("srql_builder_toggle", _params, socket) do
    {:noreply, assign(socket, :dashboard_builder_open?, !socket.assigns.dashboard_builder_open?)}
  end

  def handle_event("srql_builder_change", %{"builder" => params}, socket) do
    builder = SRQLBuilder.update(socket.assigns.dashboard_builder, params)
    query = SRQLBuilder.build(builder)

    dashboard_params =
      socket.assigns.dashboard_params
      |> Map.put("srql_query", query)
      |> Map.put("builder_state", builder)

    {:noreply,
     socket
     |> assign(:dashboard_builder, builder)
     |> assign(:dashboard_builder_supported?, true)
     |> assign(:dashboard_builder_sync?, true)
     |> assign(:dashboard_params, dashboard_params)
     |> assign(:preview, nil)
     |> assign_form()}
  end

  def handle_event("srql_builder_add_filter", _params, socket) do
    builder = socket.assigns.dashboard_builder
    filters = Map.get(builder, "filters", []) || []
    entity = Map.get(builder, "entity", "services")
    field = default_builder_filter_field(entity)

    next = %{"field" => field, "op" => "contains", "value" => ""}
    update_dashboard_builder(socket, Map.put(builder, "filters", filters ++ [next]))
  end

  def handle_event("srql_builder_remove_filter", %{"idx" => idx}, socket) do
    builder = socket.assigns.dashboard_builder
    index = parse_int(idx, -1)

    filters =
      builder
      |> Map.get("filters", [])
      |> Enum.with_index()
      |> Enum.reject(fn {_filter, i} -> i == index end)
      |> Enum.map(fn {filter, _i} -> filter end)

    update_dashboard_builder(socket, Map.put(builder, "filters", filters))
  end

  def handle_event("srql_builder_apply", _params, socket) do
    update_dashboard_builder(socket, socket.assigns.dashboard_builder)
  end

  def handle_event("srql_builder_run", _params, socket) do
    query = SRQLBuilder.build(socket.assigns.dashboard_builder)
    preview_query(socket, Map.put(socket.assigns.dashboard_params, "srql_query", query))
  end

  defp add_canvas_panel(socket, visual) do
    scope = socket.assigns.current_scope
    position = length(socket.assigns.pending_panels)

    params =
      Map.merge(socket.assigns.dashboard_params, %{
        "dataset_key" => dataset_key("dataset_#{position + 1}", position),
        "panel_title" => default_panel_title(visual, position),
        "srql_query" => @default_query,
        "visual_type" => to_string(visual),
        "unit" => default_unit(to_string(visual)),
        "trend_query" => ""
      })

    case authorize_manage(socket) do
      :ok ->
        case panel_entry_from_params(scope, params, position) do
          {:ok, panel} ->
            {:noreply,
             socket
             |> assign(:pending_panels, socket.assigns.pending_panels ++ [panel])
             |> assign(:selected_pending_panel_id, panel.id)
             |> assign(:dashboard_params, next_panel_params(params, position + 1))
             |> assign(:preview, nil)
             |> assign_form()}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Panel add failed: #{format_error(reason)}")}
        end

      {:error, _reason} ->
        deny_manage(socket)
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
      <div class="mx-auto flex w-full max-w-none flex-col gap-6 px-4 py-6 sm:px-6 lg:px-8">
        <section class="flex flex-col gap-3 border-b border-base-300 pb-5 lg:flex-row lg:items-end lg:justify-between">
          <div>
            <p class="text-sm font-medium text-primary">Analytics</p>
            <h1 class="mt-1 text-2xl font-semibold tracking-normal">Dashboard Creator</h1>
            <p class="mt-2 max-w-3xl text-sm text-base-content/65">
              Build saved dashboards from bounded SRQL queries and render them at stable dashboard URLs.
            </p>
          </div>
          <.link navigate={~p"/dashboard"} class="btn btn-sm btn-ghost">
            <.icon name="hero-squares-2x2" class="size-4" /> Operations
          </.link>
        </section>

        <div class="grid grid-cols-1 gap-6 xl:grid-cols-[minmax(0,0.95fr)_minmax(440px,1.05fr)]">
          <section class="rounded-lg border border-base-300 bg-base-100">
            <div class="border-b border-base-300 px-4 py-3">
              <h2 class="text-sm font-semibold">Saved Dashboards</h2>
              <p class="text-xs text-base-content/55">
                Opened by ID through /dashboard/:dashboard_id.
              </p>
            </div>
            <div class="divide-y divide-base-200">
              <div :if={@loading_dashboards?} class="p-4 text-sm text-base-content/60">
                Loading dashboards...
              </div>
              <div
                :if={!@loading_dashboards? and @dashboards == []}
                class="p-4 text-sm text-base-content/60"
              >
                No authored dashboards yet.
              </div>
              <div
                :for={dashboard <- @dashboards}
                class="flex flex-col gap-3 p-4 sm:flex-row sm:items-center sm:justify-between"
              >
                <div class="min-w-0">
                  <div class="flex flex-wrap items-center gap-2">
                    <.link
                      navigate={~p"/dashboard/#{Dashboards.authored_dashboard_route_ref(dashboard)}"}
                      class="font-medium hover:text-primary"
                    >
                      {dashboard.title}
                    </.link>
                    <span class="badge badge-sm badge-outline">{dashboard.status}</span>
                    <span class="badge badge-sm">{dashboard.visibility}</span>
                  </div>
                  <p class="mt-1 truncate text-xs text-base-content/55">
                    {dashboard.description || "No description"}
                  </p>
                  <p class="mt-1 font-mono text-xs text-base-content/45">
                    /dashboard/{Dashboards.authored_dashboard_route_ref(dashboard)}
                  </p>
                </div>
                <div class="flex shrink-0 gap-2">
                  <.link
                    navigate={~p"/dashboard/#{Dashboards.authored_dashboard_route_ref(dashboard)}"}
                    class="btn btn-xs"
                  >
                    <.icon name="hero-arrow-top-right-on-square" class="size-4" /> Open
                  </.link>
                  <button
                    :if={@can_manage?}
                    type="button"
                    class="btn btn-xs btn-error btn-outline"
                    phx-click="archive"
                    phx-value-id={dashboard.id}
                  >
                    <.icon name="hero-archive-box" class="size-4" /> Archive
                  </button>
                </div>
              </div>
            </div>
          </section>

          <section class="rounded-lg border border-base-300 bg-base-100">
            <div class="border-b border-base-300 px-4 py-3">
              <h2 class="text-sm font-semibold">New Dashboard</h2>
              <p class="text-xs text-base-content/55">
                Add one or more SRQL-backed panels, then save them as a dashboard.
              </p>
            </div>

            <.form
              id="dashboard-metadata-form"
              for={@dashboard_form}
              as={:dashboard}
              phx-change="validate"
              phx-submit="save"
              class="space-y-4 p-4"
            >
              <.input field={@dashboard_form[:title]} type="text" label="Title" />
              <.input field={@dashboard_form[:description]} type="text" label="Description" />
              <.input
                field={@dashboard_form[:visibility]}
                type="select"
                label="Visibility"
                options={@visibility_options}
              />

              <div class="flex flex-wrap gap-2">
                <button
                  type="button"
                  class="btn btn-sm"
                  phx-click="canvas_add_panel"
                  phx-value-visual="table"
                  disabled={!@can_manage?}
                >
                  <.icon name="hero-plus" class="size-4" /> Add Panel
                </button>
                <button type="submit" class="btn btn-sm btn-primary" disabled={!@can_manage?}>
                  <.icon name="hero-bookmark-square" class="size-4" /> Save Dashboard
                </button>
              </div>
            </.form>

            <div class="border-t border-base-300 p-4">
              <.dashboard_builder_canvas
                id="authored-dashboard-builder-canvas"
                panels={canvas_panels(@pending_panels)}
                visual_options={canvas_visual_options(@visual_options)}
                selected_id={@selected_pending_panel_id}
                can_manage={@can_manage?}
                default_query={@default_query}
              />
            </div>
          </section>

          <section
            :if={@can_manage_groups? or @can_view_share_principals?}
            class="rounded-lg border border-base-300 bg-base-100 xl:col-span-2"
          >
            <div class="border-b border-base-300 px-4 py-3">
              <h2 class="text-sm font-semibold">User Groups</h2>
              <p class="text-xs text-base-content/55">
                Reusable groups for dashboard sharing and future access-controlled features.
              </p>
            </div>

            <div
              :if={@loading_access?}
              class="p-4 text-sm text-base-content/60"
            >
              Loading groups...
            </div>

            <div :if={!@loading_access?} class="grid grid-cols-1 gap-6 p-4 lg:grid-cols-[1fr_360px]">
              <div class="space-y-3">
                <div
                  :if={@user_groups == []}
                  class="rounded-lg border border-dashed border-base-300 p-4 text-sm text-base-content/60"
                >
                  No user groups have been created yet.
                </div>

                <article
                  :for={group <- @user_groups}
                  class="rounded-lg border border-base-300 p-4"
                >
                  <div class="flex flex-col gap-2 sm:flex-row sm:items-start sm:justify-between">
                    <div>
                      <h3 class="text-sm font-semibold">{group.name}</h3>
                      <p class="mt-1 text-xs text-base-content/55">
                        {group.description || "No description"}
                      </p>
                    </div>
                    <span class="badge badge-outline">
                      {membership_count(@user_group_memberships, group.id)} members
                    </span>
                  </div>
                  <div class="mt-3 flex flex-wrap gap-2">
                    <span
                      :for={membership <- memberships_for(@user_group_memberships, group.id)}
                      class="badge badge-ghost"
                    >
                      {user_label(membership.user)}
                    </span>
                  </div>
                </article>
              </div>

              <div :if={@can_manage_groups?} class="space-y-4">
                <.form
                  for={@group_form}
                  as={:group}
                  phx-change="validate_group"
                  phx-submit="create_group"
                  class="space-y-3"
                >
                  <.input field={@group_form[:name]} type="text" label="Group name" />
                  <.input field={@group_form[:description]} type="text" label="Description" />
                  <button type="submit" class="btn btn-sm btn-primary">
                    <.icon name="hero-user-group" class="size-4" /> Create Group
                  </button>
                </.form>

                <.form
                  for={@membership_form}
                  as={:membership}
                  phx-change="validate_membership"
                  phx-submit="add_group_member"
                  class="space-y-3 border-t border-base-300 pt-4"
                >
                  <.input
                    field={@membership_form[:group_id]}
                    type="select"
                    label="Group"
                    options={group_select_options(@user_groups)}
                  />
                  <.input
                    field={@membership_form[:user_id]}
                    type="select"
                    label="User"
                    options={user_select_options(@users)}
                  />
                  <button
                    type="submit"
                    class="btn btn-sm"
                    disabled={@user_groups == [] or @users == []}
                  >
                    <.icon name="hero-user-plus" class="size-4" /> Add Member
                  </button>
                </.form>
              </div>
            </div>
          </section>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp preview_query(socket, params) do
    case Dashboards.preview_authored_query(socket.assigns.current_scope, params["srql_query"]) do
      {:ok, preview} ->
        selected_visuals = preview.compatible_visuals

        params =
          Map.put(params, "visual_type", selected_visual(params["visual_type"], selected_visuals))

        {:noreply,
         socket
         |> assign(:dashboard_params, params)
         |> assign(:preview, {:ok, preview})
         |> assign(:selected_visuals, selected_visuals)
         |> assign_form()}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:dashboard_params, params)
         |> assign(:preview, {:error, reason})
         |> assign(:selected_visuals, [:table])
         |> assign_form()}
    end
  end

  defp canvas_visual_options(options) do
    Enum.map(options, fn option ->
      %{
        type: to_string(option.type),
        label: option.label,
        description: option.description
      }
    end)
  end

  defp canvas_panels(panels) do
    Enum.map(panels, fn panel ->
      %{
        id: panel.id,
        title: panel.title,
        dataset_key: panel.dataset_key,
        srql_query: panel.srql_query,
        visual_type: to_string(panel.visual_type),
        trend_query: panel.trend_query,
        data_binding: panel.data_binding || %{},
        display_config: panel.display_config || %{},
        visual_config: panel.visual_config || %{},
        field_metadata: panel.field_metadata || %{},
        preview: panel[:preview],
        layout: panel.layout || %{},
        position: panel.position || 0
      }
    end)
  end

  defp preview_snapshot(preview) do
    %{
      row_count: Map.get(preview, :row_count, length(Map.get(preview, :rows, []))),
      rows: Enum.take(Map.get(preview, :rows, []), 12),
      fields: Enum.map(Map.get(preview, :fields, []), &field_snapshot/1),
      compatible_visuals: Enum.map(Map.get(preview, :compatible_visuals, []), &to_string/1)
    }
  end

  defp field_snapshot(field) do
    %{
      name: field_value(field, :name),
      type: field |> field_value(:type) |> to_string(),
      sample: field_value(field, :sample)
    }
  end

  defp field_value(field, key) when is_map(field), do: Map.get(field, key) || Map.get(field, to_string(key))
  defp field_value(field, key), do: Map.get(field, key)

  defp pending_panel_params(panel) do
    %{
      "dataset_key" => panel.dataset_key,
      "panel_title" => panel.title,
      "srql_query" => panel.srql_query,
      "visual_type" => to_string(panel.visual_type),
      "unit" => get_in(panel.display_config || %{}, ["unit"]) || "",
      "trend_query" => panel.trend_query || get_in(panel.visual_config || %{}, ["trend_query"]) || ""
    }
  end

  defp replace_pending_panel(panels, replacement) do
    Enum.map(panels, fn
      panel when panel.id == replacement.id -> replacement
      panel -> panel
    end)
  end

  defp normalize_canvas_layout(%{"id" => id} = layout) when is_binary(id) do
    {id,
     %{
       "x" => integer_layout_value(layout["x"], 0),
       "y" => integer_layout_value(layout["y"], 0),
       "w" => integer_layout_value(layout["w"], 4),
       "h" => integer_layout_value(layout["h"], 4)
     }}
  end

  defp normalize_canvas_layout(_layout), do: nil

  defp integer_layout_value(value, _default) when is_integer(value), do: max(value, 0)

  defp integer_layout_value(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> max(integer, 0)
      _ -> default
    end
  end

  defp integer_layout_value(value, _default) when is_float(value), do: value |> round() |> max(0)
  defp integer_layout_value(_value, default), do: default

  defp attrs_from_params(scope, params, pending_panels) do
    title = required(params["title"], :title)

    with {:ok, title} <- title,
         {:ok, panel_attrs} <- panel_attrs_for_save(scope, params, pending_panels) do
      {:ok,
       %{
         title: title,
         description: optional(params["description"]),
         status: :active,
         visibility: normalize_visibility(params["visibility"])
       }, panel_attrs}
    end
  end

  defp panel_attrs_for_save(_scope, _params, pending_panels) when is_list(pending_panels) and pending_panels != [] do
    {:ok, Enum.map(pending_panels, &pending_panel_to_attrs/1)}
  end

  defp panel_attrs_for_save(scope, params, _pending_panels) do
    with {:ok, panel} <- panel_entry_from_params(scope, params, 0) do
      {:ok, [pending_panel_to_attrs(panel)]}
    end
  end

  defp panel_entry_from_params(scope, params, position) do
    panel_title = required(params["panel_title"], :panel_title)
    query = required(params["srql_query"], :srql_query)

    with {:ok, panel_title} <- panel_title,
         {:ok, query} <- query,
         {:ok, preview} <- Dashboards.preview_authored_query(scope, query) do
      visual = selected_visual(params["visual_type"], preview.compatible_visuals)
      dataset_key = dataset_key(params["dataset_key"], position)
      trend_query = optional(params["trend_query"])
      preview = preview_snapshot(preview)

      {:ok,
       %{
         id: "pending-#{System.unique_integer([:positive])}",
         title: panel_title,
         dataset_key: dataset_key,
         srql_query: query,
         builder_state: params["builder_state"] || %{},
         visual_type: visual,
         trend_query: trend_query,
         data_binding: default_data_binding(preview, visual, dataset_key),
         display_config: default_display_config(params, preview, visual, panel_title),
         visual_config: default_visual_config(params, visual, trend_query),
         field_metadata: %{
           fields: preview.fields,
           compatible_visuals: preview.compatible_visuals
         },
         preview: preview,
         layout: default_panel_layout(position, visual),
         position: position
       }}
    end
  end

  defp pending_panel_to_attrs(panel) do
    Map.take(panel, [
      :title,
      :dataset_key,
      :srql_query,
      :builder_state,
      :visual_type,
      :data_binding,
      :display_config,
      :visual_config,
      :field_metadata,
      :layout,
      :position
    ])
  end

  defp default_dashboard_params do
    %{
      "title" => "Untitled dashboard",
      "description" => "",
      "visibility" => "private",
      "dataset_key" => "primary",
      "panel_title" => "Recent service checks",
      "srql_query" => @default_query,
      "visual_type" => "table",
      "unit" => "",
      "trend_query" => ""
    }
  end

  defp next_panel_params(params, panel_number) do
    params
    |> Map.put("dataset_key", "dataset_#{panel_number + 1}")
    |> Map.put("panel_title", "Panel #{panel_number + 1}")
    |> Map.put("srql_query", @default_query)
    |> Map.put("visual_type", "table")
    |> Map.put("unit", "")
    |> Map.put("trend_query", "")
    |> Map.delete("builder_state")
  end

  defp move_pending_panel(panels, id, direction) do
    index = Enum.find_index(panels, &(&1.id == id))

    target =
      case direction do
        "up" when is_integer(index) -> max(index - 1, 0)
        "down" when is_integer(index) -> min(index + 1, length(panels) - 1)
        _ -> index
      end

    if is_integer(index) and is_integer(target) and index != target do
      panel = Enum.at(panels, index)

      panels
      |> List.delete_at(index)
      |> List.insert_at(target, panel)
      |> Enum.with_index()
      |> Enum.map(&position_pending_panel/1)
    else
      panels
    end
  end

  defp position_pending_panel({panel, position}) do
    existing_layout =
      case panel.layout do
        layout when is_map(layout) -> layout
        _ -> %{}
      end

    layout =
      position
      |> default_panel_layout(panel.visual_type)
      |> Map.merge(existing_layout)
      |> Map.put("y", position)
      |> Map.put("order", position)

    %{panel | position: position, layout: layout}
  end

  defp default_group_params do
    %{"name" => "", "description" => ""}
  end

  defp default_membership_params do
    %{"group_id" => "", "user_id" => "", "role" => "member"}
  end

  defp assign_form(socket) do
    assign(socket, :dashboard_form, to_form(socket.assigns.dashboard_params, as: :dashboard))
  end

  defp assign_group_forms(socket) do
    socket
    |> assign(:group_form, to_form(socket.assigns.group_params, as: :group))
    |> assign(:membership_form, to_form(socket.assigns.membership_params, as: :membership))
  end

  defp assign_dashboard_builder(socket, query) do
    {supported?, sync?, builder} = dashboard_builder(query)

    socket
    |> assign(:dashboard_builder, builder)
    |> assign(:dashboard_builder_supported?, supported?)
    |> assign(:dashboard_builder_sync?, sync?)
    |> assign(:dashboard_builder_open?, false)
  end

  defp dashboard_builder(query) do
    case SRQLBuilder.parse(query || "") do
      {:ok, builder} -> {true, true, builder}
      {:error, _reason} -> {false, false, SRQLBuilder.default_state("services", 25)}
    end
  end

  defp update_dashboard_builder(socket, builder) do
    builder = SRQLBuilder.update(builder, %{})
    query = SRQLBuilder.build(builder)

    dashboard_params =
      socket.assigns.dashboard_params
      |> Map.put("srql_query", query)
      |> Map.put("builder_state", builder)

    {:noreply,
     socket
     |> assign(:dashboard_builder, builder)
     |> assign(:dashboard_builder_supported?, true)
     |> assign(:dashboard_builder_sync?, true)
     |> assign(:dashboard_params, dashboard_params)
     |> assign(:preview, nil)
     |> assign_form()}
  end

  defp default_builder_filter_field(entity) do
    Catalog.entity(entity).default_filter_field || ""
  end

  defp default_data_binding(preview, visual, dataset_key) do
    fields = preview.fields || []
    numeric = first_field_of_type(fields, :number)
    string = first_field_of_type(fields, :string)
    datetime = first_field_of_type(fields, :datetime)

    status =
      Enum.find_value(fields, fn field ->
        if field.name in ~w(status state health severity), do: field.name
      end)

    case visual do
      "availability" ->
        %{
          "dataset" => dataset_key,
          "numerator_field" => field_named(fields, "ok") || numeric,
          "denominator_field" => field_named(fields, "total"),
          "label_field" => string
        }

      "line" ->
        %{
          "dataset" => dataset_key,
          "time_field" => datetime,
          "value_field" => numeric,
          "label_field" => string
        }

      "area" ->
        %{
          "dataset" => dataset_key,
          "time_field" => datetime,
          "value_field" => numeric,
          "label_field" => string
        }

      "bar" ->
        %{"dataset" => dataset_key, "label_field" => string, "value_field" => numeric}

      "category" ->
        %{"dataset" => dataset_key, "label_field" => string, "value_field" => numeric}

      "status_list" ->
        %{"dataset" => dataset_key, "label_field" => string, "status_field" => status}

      "pivot" ->
        %{
          "dataset" => dataset_key,
          "row_field" => string,
          "column_field" => status || string,
          "value_field" => numeric,
          "aggregate" => "sum",
          "empty_value" => "0"
        }

      _ ->
        %{"dataset" => dataset_key, "value_field" => numeric, "label_field" => string}
    end
  end

  defp default_display_config(params, preview, visual, panel_title) do
    Map.reject(
      %{
        "label" => panel_title,
        "unit" => optional(params["unit"]) || default_unit(visual),
        "table_columns" => default_table_columns(preview.fields),
        "caption" => optional(params["caption"])
      },
      fn {_key, value} -> is_nil(value) end
    )
  end

  defp default_visual_config(_params, visual, trend_query) when visual in ["stat", "count", "gauge", "availability"] do
    Map.reject(
      %{
        "thresholds" => [
          %{"label" => "warning", "value" => 70, "tone" => "warning"},
          %{"label" => "critical", "value" => 90, "tone" => "error"}
        ],
        "trend_query" => trend_query
      },
      fn {_key, value} -> is_nil(value) or value == "" end
    )
  end

  defp default_visual_config(_params, _visual, _trend_query), do: %{}

  defp default_panel_layout(position, visual) do
    width =
      case to_string(visual) do
        visual when visual in ["table", "pivot", "line", "area"] -> 12
        "status_list" -> 8
        _ -> 4
      end

    per_row = max(div(12, width), 1)

    height =
      case to_string(visual) do
        visual when visual in ["table", "pivot"] -> 8
        visual when visual in ["line", "area", "bar", "category"] -> 6
        _ -> 4
      end

    %{
      "x" => rem(position, per_row) * width,
      "y" => div(position, per_row) * height,
      "w" => width,
      "h" => height,
      "order" => position
    }
  end

  defp dataset_key(value, position) do
    value =
      value
      |> optional()
      |> case do
        nil -> "dataset_#{position + 1}"
        other -> other
      end

    value
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_]+/, "_")
    |> String.trim("_")
    |> case do
      "" -> "dataset_#{position + 1}"
      other -> other
    end
  end

  defp default_table_columns(fields) do
    Enum.map(fields || [], fn field ->
      %{
        "field" => field.name,
        "label" => humanize_field(field.name),
        "renderer" => default_renderer(field),
        "visible" => true
      }
    end)
  end

  defp default_renderer(%{type: :boolean}), do: "boolean_icon"
  defp default_renderer(%{type: :datetime}), do: "time"
  defp default_renderer(%{type: :number}), do: "number"

  defp default_renderer(%{sample: sample}) when is_map(sample) or is_list(sample), do: "json_summary"

  defp default_renderer(_field), do: "text"

  defp default_unit("availability"), do: "%"
  defp default_unit("gauge"), do: "%"
  defp default_unit(_visual), do: ""

  defp default_panel_title(visual, position) do
    visual
    |> to_string()
    |> humanize_field()
    |> Kernel.<>(" Panel #{position + 1}")
  end

  defp first_field_of_type(fields, type) do
    Enum.find_value(fields, fn field -> if field.type == type, do: field.name end)
  end

  defp field_named(fields, name) do
    Enum.find_value(fields, fn field -> if field.name == name, do: field.name end)
  end

  defp humanize_field(value) do
    value
    |> to_string()
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  defp load_access_controls(scope, assigns) do
    users =
      if assigns.can_view_share_principals? do
        Dashboards.list_share_principals(scope)
      else
        []
      end

    {groups, memberships} =
      if assigns.can_manage_groups? or assigns.can_view_share_principals? do
        {Dashboards.list_user_groups(scope), Dashboards.list_user_group_memberships(scope)}
      else
        {[], []}
      end

    %{
      users: users,
      user_groups: groups,
      user_group_memberships: memberships
    }
  end

  defp reload_access_controls(socket) do
    access = load_access_controls(socket.assigns.current_scope, access_assigns(socket.assigns))

    socket
    |> assign(access)
    |> assign_group_forms()
  end

  defp access_assigns(assigns) do
    Map.take(assigns, [:can_view_share_principals?, :can_manage_groups?])
  end

  defp merge_params(current, incoming) do
    Map.merge(current || %{}, incoming || %{})
  end

  defp selected_visual(value, compatible) when is_binary(value) do
    if Enum.any?(compatible, &(Atom.to_string(&1) == value)) do
      value
    else
      compatible |> List.first(:table) |> Atom.to_string()
    end
  end

  defp selected_visual(value, compatible) when is_atom(value), do: selected_visual(Atom.to_string(value), compatible)

  defp selected_visual(_value, compatible), do: compatible |> List.first(:table) |> Atom.to_string()

  defp parse_int(value, default) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {int, ""} -> int
      _ -> default
    end
  end

  defp parse_int(value, _default) when is_integer(value), do: value
  defp parse_int(_value, default), do: default

  defp required(value, field) do
    case optional(value) do
      nil -> {:error, {:required, field}}
      value -> {:ok, value}
    end
  end

  defp optional(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp optional(_value), do: nil

  defp can_manage?(scope), do: RBAC.can?(scope, "analytics.dashboards.create")
  defp can_manage_groups?(scope), do: RBAC.can?(scope, "identity.user_groups.manage")

  defp can_view_share_principals?(scope), do: RBAC.can?(scope, "analytics.share_principals.view")

  defp normalize_visibility(value) when value in ~w(private shared public), do: value
  defp normalize_visibility(_value), do: "private"

  defp authorize_manage(socket) do
    if socket.assigns.can_manage?, do: :ok, else: {:error, :forbidden}
  end

  defp deny_manage(socket) do
    {:noreply, put_flash(socket, :error, "Not authorized to manage dashboards")}
  end

  defp authorize_manage_groups(socket) do
    if socket.assigns.can_manage_groups?, do: :ok, else: {:error, :forbidden}
  end

  defp group_select_options(groups) do
    Enum.map(groups, &{&1.name, &1.id})
  end

  defp user_select_options(users) do
    Enum.map(users, &{user_label(&1), &1.id})
  end

  defp memberships_for(memberships, group_id) do
    Enum.filter(memberships, &(&1.group_id == group_id))
  end

  defp membership_count(memberships, group_id), do: memberships |> memberships_for(group_id) |> length()

  defp user_label(%{display_name: name, email: email}) when is_binary(name) and name != "" do
    "#{name} <#{email}>"
  end

  defp user_label(%{email: %Ash.CiString{} = email}), do: to_string(email)
  defp user_label(%{email: email}) when is_binary(email), do: email
  defp user_label(_user), do: "Unknown user"

  defp format_error({:required, field}), do: "#{field} is required"
  defp format_error(:empty_query), do: "SRQL query is required"
  defp format_error(:forbidden), do: "Not authorized to manage analytics dashboards"
  defp format_error({:reserved_dashboard_slug, slug}), do: "Dashboard slug #{slug} is reserved"

  defp format_error({:route_ref_dashboard_slug, slug}),
    do: "Dashboard slug #{slug} conflicts with generated dashboard IDs"

  defp format_error({:invalid_dashboard_slug, slug}),
    do: "Dashboard slug #{slug} must start with a letter and use only letters, numbers, and dashes"

  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)
end
