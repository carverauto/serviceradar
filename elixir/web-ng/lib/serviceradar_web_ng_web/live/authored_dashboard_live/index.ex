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
         {:ok, dashboard_attrs} <- attrs_from_params(params),
         {:ok, dashboard} <- Dashboards.create_authored_dashboard(scope, dashboard_attrs) do
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
        <section class="flex flex-col gap-3 border-b border-sr-line pb-5 lg:flex-row lg:items-end lg:justify-between">
          <div>
            <p class="text-sm font-medium text-sr-brand">Analytics</p>
            <h1 class="mt-1 text-2xl font-semibold tracking-normal">Dashboard Creator</h1>
            <p class="mt-2 max-w-3xl text-sm text-sr-ink/65">
              Build saved dashboards from bounded SRQL queries and render them at stable dashboard URLs.
            </p>
          </div>
          <.ui_button navigate={~p"/dashboard"} size="sm" variant="ghost">
            <.icon name="hero-squares-2x2" class="size-4" /> Operations
          </.ui_button>
        </section>

        <div class="grid grid-cols-1 gap-6 xl:grid-cols-[minmax(0,0.95fr)_minmax(440px,1.05fr)]">
          <section class="rounded-lg border border-sr-line bg-sr-surface">
            <div class="border-b border-sr-line px-4 py-3">
              <h2 class="text-sm font-semibold">Saved Dashboards</h2>
              <p class="text-xs text-sr-ink/55">
                Opened by ID through /dashboard/:dashboard_id.
              </p>
            </div>
            <div class="divide-y divide-sr-line">
              <div :if={@loading_dashboards?} class="p-4 text-sm text-sr-muted">
                Loading dashboards...
              </div>
              <div
                :if={!@loading_dashboards? and @dashboards == []}
                class="p-4 text-sm text-sr-muted"
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
                      class="font-medium hover:text-sr-brand"
                    >
                      {dashboard.title}
                    </.link>
                    <.ui_badge size="sm" variant="outline">{dashboard.status}</.ui_badge>
                    <.ui_badge size="sm" variant="ghost">{dashboard.visibility}</.ui_badge>
                  </div>
                  <p class="mt-1 truncate text-xs text-sr-ink/55">
                    {dashboard.description || "No description"}
                  </p>
                  <p class="mt-1 font-mono text-xs text-sr-ink/45">
                    /dashboard/{Dashboards.authored_dashboard_route_ref(dashboard)}
                  </p>
                </div>
                <div class="flex shrink-0 gap-2">
                  <.ui_button
                    navigate={~p"/dashboard/#{Dashboards.authored_dashboard_route_ref(dashboard)}"}
                    size="xs"
                    variant="neutral"
                  >
                    <.icon name="hero-arrow-top-right-on-square" class="size-4" /> Open
                  </.ui_button>
                  <.ui_button
                    :if={@can_manage?}
                    type="button"
                    phx-click="archive"
                    phx-value-id={dashboard.id}
                    size="xs"
                    variant="outline"
                  >
                    <.icon name="hero-archive-box" class="size-4" /> Archive
                  </.ui_button>
                </div>
              </div>
            </div>
          </section>

          <section class="rounded-lg border border-sr-line bg-sr-surface">
            <div class="border-b border-sr-line px-4 py-3">
              <h2 class="text-sm font-semibold">New Dashboard</h2>
              <p class="text-xs text-sr-ink/55">
                Create the dashboard first, then add SRQL-backed panels from its settings.
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

              <div class="flex flex-wrap items-center gap-2">
                <.ui_button type="submit" disabled={!@can_manage?} size="sm" variant="primary">
                  <.icon name="hero-bookmark-square" class="size-4" /> Create Dashboard
                </.ui_button>
                <span class="text-xs text-sr-ink/55">
                  Panels are added after save so they can be tied to this dashboard.
                </span>
              </div>
            </.form>
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

  defp attrs_from_params(params) do
    title = required(params["title"], :title)

    with {:ok, title} <- title do
      {:ok,
       %{
         title: title,
         description: optional(params["description"]),
         status: :active,
         visibility: normalize_visibility(params["visibility"])
       }}
    end
  end

  defp default_dashboard_params do
    %{
      "title" => "",
      "description" => "",
      "visibility" => "private"
    }
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

  defp authorize_manage_groups(socket) do
    if socket.assigns.can_manage_groups?, do: :ok, else: {:error, :forbidden}
  end

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
