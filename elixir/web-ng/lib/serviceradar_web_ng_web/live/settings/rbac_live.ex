defmodule ServiceRadarWebNGWeb.Settings.RbacLive do
  @moduledoc """
  RBAC policy editor.

  Displays a per-profile permission grid with catalog sections as column groups,
  resources as sub-columns, and actions as rows.
  """

  use ServiceRadarWebNGWeb, :live_view

  use Permit.Phoenix.LiveView,
    authorization_module: ServiceRadarWebNGWeb.Authorization,
    resource_module: ServiceRadar.Identity.RoleProfile

  alias Phoenix.LiveView.AsyncResult
  alias ServiceRadar.Identity.GroupPolicy
  alias ServiceRadar.Identity.RBAC
  alias ServiceRadar.Identity.RBAC.Catalog
  alias ServiceRadar.Identity.RoleProfile
  alias ServiceRadar.Identity.RoleProfilePolicy
  alias ServiceRadarWebNG.Dashboards.GroupAccess
  alias ServiceRadarWebNG.RBAC, as: WebRBAC
  alias ServiceRadarWebNGWeb.Settings.RbacLive.Components
  alias ServiceRadarWebNGWeb.Settings.RbacLive.DashboardAudience
  alias ServiceRadarWebNGWeb.Settings.RbacLive.PolicyData
  alias ServiceRadarWebNGWeb.Settings.Shell

  require Ash.Query
  require Logger

  # ── Mount ─────────────────────────────────────────────────────

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    if WebRBAC.can?(scope, "settings.rbac.manage") do
      {profiles, profile_flash} = load_role_profiles(scope)
      catalog = RBAC.catalog()
      grid = build_permission_grid(catalog)
      active_profile_id = profiles |> List.first() |> then(&(&1 && &1.id))
      active_section = grid.resource_groups |> List.first() |> then(&(&1 && &1.section))

      socket =
        socket
        |> assign(:page_title, "Policy Editor")
        |> assign(:profiles, profiles)
        |> assign(:catalog, catalog)
        |> assign(:grid, grid)
        |> assign(:filter, "")
        |> assign(:active_profile_id, active_profile_id)
        |> assign(:active_section, active_section)
        |> assign(:dirty_profiles, MapSet.new())
        |> assign(:show_new_profile_modal, false)
        |> assign(:new_profile_form, to_form(default_profile_form(), as: :profile))
        |> assign(:clone_source_id, nil)
        |> assign(:confirm_delete_profile, nil)
        |> assign(:renaming_profile_id, nil)
        |> assign(:rename_form, to_form(%{"name" => ""}, as: :profile))
        |> assign(:group_profile_assignments, AsyncResult.loading())
        |> assign(:group_profile_generation, 0)
        |> assign(:dashboard_audience, DashboardAudience.new())
        |> attach_hook(
          :refresh_dashboard_group_tokens,
          :after_render,
          &queue_dashboard_group_refresh/1
        )
        |> stream(:rbac_authored_dashboards, [])
        |> stream(:rbac_package_dashboards, [])
        |> maybe_put_flash(profile_flash)

      socket = if connected?(socket), do: load_group_profiles(socket), else: socket

      {:ok, socket}
    else
      {:ok,
       socket
       |> put_flash(:error, "Admin access required")
       |> redirect(to: ~p"/settings/profile")}
    end
  end

  # ── Events ────────────────────────────────────────────────────

  @impl true
  def handle_event("filter_policies", %{"filter" => value}, socket) do
    filter = value || ""
    filtered = filter_profiles(socket.assigns.profiles, filter)

    active_profile_id =
      if socket.assigns.active_profile_id &&
           Enum.any?(filtered, &(&1.id == socket.assigns.active_profile_id)) do
        socket.assigns.active_profile_id
      else
        filtered |> List.first() |> then(&(&1 && &1.id))
      end

    {:noreply,
     socket
     |> assign(:filter, filter)
     |> assign(:active_profile_id, active_profile_id)}
  end

  def handle_event("select_profile", %{"profile-id" => profile_id}, socket) do
    {:noreply,
     socket
     |> assign(:active_profile_id, profile_id)
     |> assign(:renaming_profile_id, nil)}
  end

  def handle_event("select_section", %{"section" => section}, socket) do
    {:noreply, assign(socket, :active_section, section)}
  end

  def handle_event("start_rename_profile", %{"profile-id" => profile_id}, socket) do
    profile = find_profile(socket.assigns.profiles, profile_id)

    cond do
      profile == nil ->
        {:noreply, socket}

      profile.system ->
        {:noreply, socket}

      true ->
        {:noreply,
         socket
         |> assign(:renaming_profile_id, profile.id)
         |> assign(:rename_form, to_form(%{"name" => profile.name || ""}, as: :profile))}
    end
  end

  def handle_event("cancel_rename_profile", _params, socket) do
    {:noreply, assign(socket, :renaming_profile_id, nil)}
  end

  def handle_event("rename_profile", %{"profile" => params, "profile_id" => profile_id}, socket) do
    scope = socket.assigns.current_scope
    profile = find_profile(socket.assigns.profiles, profile_id)
    name = String.trim(params["name"] || "")

    cond do
      profile == nil ->
        {:noreply, socket}

      profile.system ->
        {:noreply, socket}

      name == "" ->
        {:noreply, put_flash(socket, :error, "Name is required")}

      true ->
        case RoleProfilePolicy.update(scope, profile.id, %{name: name}) do
          {:ok, updated} ->
            {:noreply,
             socket
             |> assign(
               :profiles,
               replace_profile(socket.assigns.profiles, %{
                 updated
                 | permissions: profile.permissions
               })
             )
             |> assign(:renaming_profile_id, nil)
             |> put_flash(:info, "Profile renamed")
             |> load_group_profiles()}

          {:error, error} ->
            {:noreply, put_flash(socket, :error, format_ash_error(error))}
        end
    end
  end

  def handle_event("toggle_permission", %{"profile-id" => profile_id, "permission" => permission}, socket) do
    profile = find_profile(socket.assigns.profiles, profile_id)

    if profile == nil or profile_locked?(profile) do
      {:noreply, socket}
    else
      updated = toggle_permission(profile, permission)

      {:noreply,
       socket
       |> assign(:profiles, replace_profile(socket.assigns.profiles, updated))
       |> assign(:dirty_profiles, MapSet.put(socket.assigns.dirty_profiles, updated.id))}
    end
  end

  def handle_event("toggle_resource", %{"profile-id" => profile_id, "resource" => resource}, socket) do
    profile = find_profile(socket.assigns.profiles, profile_id)

    if profile == nil or profile_locked?(profile) do
      {:noreply, socket}
    else
      keys =
        socket.assigns.grid
        |> section_grid(socket.assigns.active_section)
        |> resource_permission_keys(resource)

      updated = toggle_permissions_bulk(profile, keys)

      {:noreply,
       socket
       |> assign(:profiles, replace_profile(socket.assigns.profiles, updated))
       |> assign(:dirty_profiles, MapSet.put(socket.assigns.dirty_profiles, updated.id))}
    end
  end

  def handle_event("toggle_action", %{"profile-id" => profile_id, "action" => action}, socket) do
    profile = find_profile(socket.assigns.profiles, profile_id)

    if profile == nil or profile_locked?(profile) do
      {:noreply, socket}
    else
      keys =
        socket.assigns.grid
        |> section_grid(socket.assigns.active_section)
        |> action_permission_keys(action)

      updated = toggle_permissions_bulk(profile, keys)

      {:noreply,
       socket
       |> assign(:profiles, replace_profile(socket.assigns.profiles, updated))
       |> assign(:dirty_profiles, MapSet.put(socket.assigns.dirty_profiles, updated.id))}
    end
  end

  def handle_event("save_profile", %{"profile-id" => profile_id}, socket) do
    scope = socket.assigns.current_scope
    profile = find_profile(socket.assigns.profiles, profile_id)

    if profile == nil do
      {:noreply, socket}
    else
      {:noreply, persist_profile(socket, scope, profile)}
    end
  end

  def handle_event("save_all", _params, socket) do
    scope = socket.assigns.current_scope

    socket =
      Enum.reduce(MapSet.to_list(socket.assigns.dirty_profiles), socket, fn profile_id, acc ->
        profile = find_profile(acc.assigns.profiles, profile_id)

        if profile == nil do
          acc
        else
          persist_profile(acc, scope, profile)
        end
      end)

    {:noreply, socket}
  end

  def handle_event("set_profile_permissions", %{"profile-id" => profile_id, "mode" => mode}, socket) do
    profile = find_profile(socket.assigns.profiles, profile_id)

    if profile == nil or profile_locked?(profile) do
      {:noreply, socket}
    else
      permissions =
        case mode do
          "all" -> MapSet.to_list(socket.assigns.grid.valid_permissions)
          "none" -> []
          _ -> profile.permissions || []
        end

      updated = %{profile | permissions: permissions}

      {:noreply,
       socket
       |> assign(:profiles, replace_profile(socket.assigns.profiles, updated))
       |> assign(:dirty_profiles, MapSet.put(socket.assigns.dirty_profiles, updated.id))}
    end
  end

  def handle_event("open_new_profile", params, socket) do
    clone_source_id = Map.get(params, "clone-source-id")

    {:noreply,
     socket
     |> assign(:show_new_profile_modal, true)
     |> assign(:clone_source_id, clone_source_id)
     |> assign(:new_profile_form, to_form(default_profile_form(), as: :profile))}
  end

  def handle_event("close_new_profile", _params, socket) do
    {:noreply, assign(socket, :show_new_profile_modal, false)}
  end

  def handle_event("create_profile", %{"profile" => params}, socket) do
    scope = socket.assigns.current_scope

    base_permissions =
      permissions_from_clone(socket.assigns.profiles, socket.assigns.clone_source_id)

    attrs = %{
      name: Map.get(params, "name"),
      description: Map.get(params, "description"),
      permissions: base_permissions
    }

    case RoleProfilePolicy.create(scope, attrs) do
      {:ok, profile} ->
        {:noreply,
         socket
         |> assign(:profiles, socket.assigns.profiles ++ [profile])
         |> assign(:active_profile_id, profile.id)
         |> assign(:show_new_profile_modal, false)
         |> assign(:clone_source_id, nil)
         |> put_flash(:info, "Role profile created")
         |> load_group_profiles()}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, format_ash_error(error))}
    end
  end

  def handle_event("open_delete_profile", %{"profile-id" => profile_id}, socket) do
    profile = find_profile(socket.assigns.profiles, profile_id)

    cond do
      profile == nil -> {:noreply, socket}
      profile.system -> {:noreply, put_flash(socket, :error, "System profiles cannot be deleted")}
      true -> {:noreply, assign(socket, :confirm_delete_profile, profile)}
    end
  end

  def handle_event("close_delete_profile", _params, socket) do
    {:noreply, assign(socket, :confirm_delete_profile, nil)}
  end

  def handle_event("delete_profile", %{"profile-id" => profile_id}, socket) do
    scope = socket.assigns.current_scope
    profile = find_profile(socket.assigns.profiles, profile_id)

    cond do
      profile == nil ->
        {:noreply, socket}

      profile.system ->
        {:noreply, put_flash(socket, :error, "System profiles cannot be deleted")}

      true ->
        case RoleProfilePolicy.delete(scope, profile.id) do
          {:ok, _deleted_profile} ->
            {:noreply,
             socket
             |> assign(:profiles, Enum.reject(socket.assigns.profiles, &(&1.id == profile.id)))
             |> assign(:dirty_profiles, MapSet.delete(socket.assigns.dirty_profiles, profile.id))
             |> assign(:confirm_delete_profile, nil)
             |> put_flash(:info, "Role profile deleted")
             |> load_group_profiles()}

          {:error, error} ->
            {:noreply, put_flash(socket, :error, format_ash_error(error))}
        end
    end
  end

  def handle_event("retry_group_profiles", _params, socket) do
    {:noreply, load_group_profiles(socket)}
  end

  def handle_event("assign_group_profile", params, socket) do
    with {:ok, data} <- current_group_profile_data(socket),
         {:ok, {group_id, profile_id}} <-
           PolicyData.resolve_assignment(
             data,
             socket.assigns.group_profile_generation,
             params
           ),
         {:ok, _group} <- GroupPolicy.assign(socket.assigns.current_scope, group_id, profile_id) do
      {:noreply,
       socket
       |> put_flash(:info, "Group role profile updated")
       |> load_group_profiles()}
    else
      {:error, :stale} ->
        {:noreply, stale_group_profile_data(socket)}

      {:error, reason} ->
        Logger.warning("RBAC group profile assignment failed: #{inspect(reason)}")

        {:noreply,
         socket
         |> put_flash(
           :error,
           "Group assignment could not be updated. Reloaded the latest values."
         )
         |> load_group_profiles()}
    end
  end

  def handle_event("clear_group_profile", params, socket) do
    with {:ok, data} <- current_group_profile_data(socket),
         {:ok, {group_id, nil}} <-
           PolicyData.resolve_clear(data, socket.assigns.group_profile_generation, params),
         {:ok, _group} <- GroupPolicy.clear(socket.assigns.current_scope, group_id) do
      {:noreply,
       socket
       |> put_flash(:info, "Group role profile cleared")
       |> load_group_profiles()}
    else
      {:error, :stale} ->
        {:noreply, stale_group_profile_data(socket)}

      {:error, reason} ->
        Logger.warning("RBAC group profile clear failed: #{inspect(reason)}")

        {:noreply,
         socket
         |> put_flash(
           :error,
           "Group assignment could not be updated. Reloaded the latest values."
         )
         |> load_group_profiles()}
    end
  end

  def handle_event("select_dashboard_audience_group", params, socket) do
    safe_params = Map.take(params, ["group-token"])

    with {:ok, data} <- current_group_profile_data(socket),
         {:ok, {group_id, nil}} <-
           PolicyData.resolve_clear(
             data,
             socket.assigns.group_profile_generation,
             safe_params
           ),
         %{name: group_name} <-
           Enum.find(data.groups, &(to_string(&1.id) == group_id)),
         group_token when is_binary(group_token) <- Map.get(safe_params, "group-token") do
      audience =
        DashboardAudience.select_group(
          socket.assigns.dashboard_audience,
          group_token,
          group_id,
          group_name
        )

      {:noreply,
       socket
       |> assign(:dashboard_audience, audience)
       |> stream(:rbac_authored_dashboards, [], reset: true)
       |> stream(:rbac_package_dashboards, [], reset: true)
       |> start_dashboard_audience_request(:authored, :first)
       |> start_dashboard_audience_request(:package, :first)}
    else
      _reason ->
        {:noreply,
         socket
         |> put_flash(:error, "Dashboard audience changed. Reloaded the latest values.")
         |> load_group_profiles()}
    end
  end

  def handle_event("retry_authored_dashboard_audience", _params, socket) do
    {:noreply, start_dashboard_audience_request(socket, :authored, :first)}
  end

  def handle_event("previous_authored_dashboard_audience", _params, socket) do
    {:noreply, start_dashboard_audience_request(socket, :authored, :previous)}
  end

  def handle_event("next_authored_dashboard_audience", _params, socket) do
    {:noreply, start_dashboard_audience_request(socket, :authored, :next)}
  end

  def handle_event("retry_package_dashboard_audience", _params, socket) do
    {:noreply, start_dashboard_audience_request(socket, :package, :first)}
  end

  def handle_event("previous_package_dashboard_audience", _params, socket) do
    {:noreply, start_dashboard_audience_request(socket, :package, :previous)}
  end

  def handle_event("next_package_dashboard_audience", _params, socket) do
    {:noreply, start_dashboard_audience_request(socket, :package, :next)}
  end

  def handle_event("ensure_authored_dashboard_group_view", params, socket) do
    {:noreply, mutate_dashboard_audience(socket, :authored, :ensure, params)}
  end

  def handle_event("revoke_authored_dashboard_group_view", params, socket) do
    {:noreply, mutate_dashboard_audience(socket, :authored, :revoke, params)}
  end

  def handle_event("ensure_package_dashboard_group_view", params, socket) do
    {:noreply, mutate_dashboard_audience(socket, :package, :ensure, params)}
  end

  def handle_event("revoke_package_dashboard_group_view", params, socket) do
    {:noreply, mutate_dashboard_audience(socket, :package, :revoke, params)}
  end

  @impl true
  def handle_async({:dashboard_audience, source, request_ref}, {:ok, {epoch, result}}, socket)
      when source in [:authored, :package] do
    {:noreply, accept_dashboard_audience_result(socket, source, epoch, request_ref, result)}
  end

  def handle_async({:dashboard_audience, source, request_ref}, {:exit, reason}, socket)
      when source in [:authored, :package] do
    Logger.warning("RBAC #{source} dashboard audience load failed: #{inspect(reason)}")

    {:noreply,
     accept_dashboard_audience_result(
       socket,
       source,
       socket.assigns.dashboard_audience.epoch,
       request_ref,
       {:error, :load_failed}
     )}
  end

  @impl true
  def handle_info({:refresh_dashboard_group_tokens, generation}, socket) do
    with ^generation <- socket.assigns.group_profile_generation,
         {:ok, data} <- current_group_profile_data(socket),
         {:ok, _current} <- PolicyData.accept_generation(generation, data),
         group_id when is_binary(group_id) <- socket.assigns.dashboard_audience.group_id do
      case dashboard_group(
             socket.assigns.group_profile_assignments,
             generation,
             socket.assigns.dashboard_audience
           ) do
        %{token: token} ->
          {:ok, audience} =
            DashboardAudience.sync_group_token(socket.assigns.dashboard_audience, token, group_id)

          {:noreply,
           socket
           |> assign(:dashboard_audience, audience)
           |> start_dashboard_audience_request(:authored, :first)
           |> start_dashboard_audience_request(:package, :first)}

        nil ->
          {:noreply,
           socket
           |> assign(:dashboard_audience, %{
             DashboardAudience.new()
             | epoch: socket.assigns.dashboard_audience.epoch + 1
           })
           |> stream(:rbac_authored_dashboards, [], reset: true)
           |> stream(:rbac_package_dashboards, [], reset: true)}
      end
    else
      _ -> {:noreply, socket}
    end
  end

  # ── Permit callbacks ──────────────────────────────────────────

  @impl true
  def event_mapping do
    Map.merge(Permit.Phoenix.LiveView.default_event_mapping(), %{
      "select_profile" => :read,
      "select_section" => :read,
      "start_rename_profile" => :update,
      "cancel_rename_profile" => :read,
      "rename_profile" => :update,
      "toggle_permission" => :update,
      "toggle_resource" => :update,
      "toggle_action" => :update,
      "save_profile" => :update,
      "save_all" => :update,
      "set_profile_permissions" => :update,
      "create_profile" => :create,
      "delete_profile" => :delete,
      "open_delete_profile" => :delete,
      "filter_policies" => :read,
      "open_new_profile" => :read,
      "close_new_profile" => :read,
      "close_delete_profile" => :read,
      "retry_group_profiles" => :read,
      "assign_group_profile" => :update,
      "clear_group_profile" => :update,
      "select_dashboard_audience_group" => :read,
      "retry_authored_dashboard_audience" => :read,
      "previous_authored_dashboard_audience" => :read,
      "next_authored_dashboard_audience" => :read,
      "retry_package_dashboard_audience" => :read,
      "previous_package_dashboard_audience" => :read,
      "next_package_dashboard_audience" => :read,
      "ensure_authored_dashboard_group_view" => :update,
      "revoke_authored_dashboard_group_view" => :update,
      "ensure_package_dashboard_group_view" => :update,
      "revoke_package_dashboard_group_view" => :update
    })
  end

  @impl true
  def skip_preload do
    [:index, :read, :create, :update, :delete]
  end

  @impl true
  def handle_unauthorized(_action, socket) do
    socket =
      socket
      |> put_flash(:error, "Admin access required")
      |> push_navigate(to: ~p"/settings/profile")

    {:halt, socket}
  end

  # ── Render ────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns, :filtered_profiles, filter_profiles(assigns.profiles, assigns.filter))

    assigns = assign(assigns, :has_dirty?, MapSet.size(assigns.dirty_profiles) > 0)

    active_profile =
      if assigns.active_profile_id do
        find_profile(assigns.filtered_profiles, assigns.active_profile_id)
      else
        List.first(assigns.filtered_profiles)
      end

    assigns = assign(assigns, :active_profile, active_profile)

    assigns =
      assign(
        assigns,
        :dashboard_group,
        dashboard_group(
          assigns.group_profile_assignments,
          assigns.group_profile_generation,
          assigns.dashboard_audience
        )
      )

    assigns =
      assign(assigns, :section_grid, section_grid(assigns.grid, assigns.active_section))

    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <Shell.settings_chrome
        current_path="/settings/auth/rbac"
        current_scope={@current_scope}
        active_view={@settings_active_view}
        active_category={@settings_active_category}
        breadcrumbs={@settings_breadcrumbs}
        nav_tree={@settings_nav_tree}
        palette={@settings_palette}
        stats={@settings_stats}
      >
        <div class="space-y-4">
          <div class="flex flex-wrap items-start justify-between gap-4">
            <div class="space-y-1">
              <.ui_badge size="sm" variant="outline">Policy Editor</.ui_badge>
              <h1 class="text-2xl font-semibold">RBAC</h1>
              <p class="text-sm text-sr-muted">
                Edit role profiles using a compact permissions grid. Built-in profiles are clone-only.
              </p>
            </div>

            <div class="flex items-center gap-2">
              <.ui_button :if={@has_dirty?} phx-click="save_all" size="sm" variant="primary">
                Save all
              </.ui_button>
              <.ui_button phx-click="open_new_profile" size="sm" variant="primary" class="gap-1">
                Create <.icon name="hero-plus-mini" class="h-4 w-4" />
              </.ui_button>
            </div>
          </div>

          <Components.group_profile_controls
            result={@group_profile_assignments}
            selected_group_id={@dashboard_audience.group_id}
          />

          <Components.dashboard_audience
            :if={@dashboard_group}
            audience={@dashboard_audience}
            group_token={@dashboard_group.token}
            group_name={@dashboard_group.name}
            authored_rows={@streams.rbac_authored_dashboards}
            package_rows={@streams.rbac_package_dashboards}
          />

          <div class="flex flex-wrap items-center justify-between gap-4">
            <label class="flex min-h-9 w-full max-w-sm items-center gap-2 rounded-sr-control border border-sr-line bg-sr-control px-3 shadow-sr-control">
              <.icon name="hero-magnifying-glass" class="h-4 w-4 opacity-50" />
              <input
                type="search"
                name="filter"
                value={@filter}
                placeholder="Filter profiles"
                phx-change="filter_policies"
                phx-debounce="300"
                class="grow"
              />
            </label>
          </div>

          <div class="space-y-4">
            <div :if={@filtered_profiles != []} class="flex flex-wrap items-center gap-2">
              <span class="text-xs font-semibold uppercase tracking-wider text-sr-muted">
                Profiles
              </span>
              <div class="flex flex-wrap gap-2">
                <.ui_button
                  :for={profile <- @filtered_profiles}
                  type="button"
                  size="xs"
                  variant={
                    if(@active_profile && profile.id == @active_profile.id,
                      do: "primary",
                      else: "ghost"
                    )
                  }
                  active={@active_profile && profile.id == @active_profile.id}
                  phx-click="select_profile"
                  phx-value-profile-id={profile.id}
                >
                  {profile.name}
                </.ui_button>
              </div>
            </div>

            <div :if={@active_profile} class="w-full max-w-5xl">
              <.profile_card
                profile={@active_profile}
                grid={@section_grid}
                dirty={MapSet.member?(@dirty_profiles, @active_profile.id)}
                renaming_profile_id={@renaming_profile_id}
                rename_form={@rename_form}
                sections={@grid.sections}
                active_section={@section_grid.active_section}
              />
            </div>

            <div :if={@filtered_profiles == []} class="w-full text-center py-16 text-sr-muted">
              <.icon name="hero-shield-exclamation" class="h-12 w-12 mx-auto mb-3 opacity-30" />
              <p class="text-sm">No profiles match your filter.</p>
            </div>
          </div>
        </div>

        <.new_profile_modal :if={@show_new_profile_modal} form={@new_profile_form} />
        <.delete_profile_modal :if={@confirm_delete_profile} profile={@confirm_delete_profile} />
      </Shell.settings_chrome>
    </Layouts.app>
    """
  end

  # ── Component: profile_card ───────────────────────────────────

  attr(:profile, :map, required: true)
  attr(:grid, :map, required: true)
  attr(:dirty, :boolean, default: false)
  attr(:renaming_profile_id, :any, default: nil)
  attr(:rename_form, :any, required: true)
  attr(:sections, :list, required: true)
  attr(:active_section, :string, default: nil)

  defp profile_card(assigns) do
    assigns = assign(assigns, :unmapped, unmapped_permissions(assigns.profile, assigns.grid))
    assigns = assign(assigns, :locked, profile_locked?(assigns.profile))
    assigns = assign(assigns, :renaming?, assigns.renaming_profile_id == assigns.profile.id)

    ~H"""
    <div class="rounded-xl border border-sr-line bg-sr-surface">
      <%!-- Card header --%>
      <div class="flex items-center justify-between gap-3 px-5 py-3 border-b border-sr-line">
        <div class="flex items-center gap-3">
          <%= if @renaming? do %>
            <.form for={@rename_form} phx-submit="rename_profile" class="flex items-center gap-2">
              <input type="hidden" name="profile_id" value={@profile.id} />
              <input
                type="text"
                name={@rename_form[:name].name}
                value={@rename_form[:name].value}
                class={ui_field_class(size: "sm", class: "w-56")}
                autocomplete="off"
              />
              <.ui_button type="submit" size="xs" variant="primary">Save</.ui_button>
              <.ui_button type="button" phx-click="cancel_rename_profile" size="xs" variant="ghost">
                Cancel
              </.ui_button>
            </.form>
          <% else %>
            <%= if @profile.system do %>
              <.ui_badge size="sm" variant={profile_badge_variant(@profile)}>
                {@profile.name}
              </.ui_badge>
            <% else %>
              <button
                type="button"
                class="cursor-text hover:opacity-80"
                phx-click="start_rename_profile"
                phx-value-profile-id={@profile.id}
                title="Click to rename"
              >
                <.ui_badge size="sm" variant={profile_badge_variant(@profile)}>
                  {@profile.name}
                </.ui_badge>
              </button>
            <% end %>
          <% end %>
          <span class="text-sm text-sr-muted">
            {profile_identifier(@profile)}
          </span>
          <.ui_badge :if={@dirty} size="sm" variant="warning">unsaved</.ui_badge>
        </div>
        <div class="flex items-center gap-2">
          <div class={ui_join_class(class: @locked && "opacity-50")}>
            <.ui_button
              type="button"
              disabled={@locked}
              phx-click="set_profile_permissions"
              phx-value-profile-id={@profile.id}
              phx-value-mode="all"
              size="xs"
              variant="neutral"
            >
              All
            </.ui_button>
            <.ui_button
              type="button"
              disabled={@locked}
              phx-click="set_profile_permissions"
              phx-value-profile-id={@profile.id}
              phx-value-mode="none"
              size="xs"
              variant="neutral"
            >
              None
            </.ui_button>
          </div>
          <.ui_button
            :if={@dirty}
            phx-click="save_profile"
            phx-value-profile-id={@profile.id}
            size="xs"
            variant="primary"
          >
            Save
          </.ui_button>
          <.ui_dropdown align="end">
            <:trigger>
              <.ui_icon_button size="sm" variant="ghost" aria-label="Profile actions">
                <.icon name="hero-ellipsis-vertical" class="size-5" />
              </.ui_icon_button>
            </:trigger>
            <:item>
              <button
                type="button"
                phx-click="open_new_profile"
                phx-value-clone-source-id={@profile.id}
              >
                <.icon name="hero-document-duplicate" class="size-4" /> Clone
              </button>
            </:item>
            <:item :if={!@profile.system}>
              <button
                type="button"
                phx-click="open_delete_profile"
                phx-value-profile-id={@profile.id}
                class="text-error"
              >
                <.icon name="hero-trash" class="size-4" /> Delete
              </button>
            </:item>
          </.ui_dropdown>
        </div>
      </div>

      <%!-- Section switcher --%>
      <div class="px-5 pt-4">
        <div class="flex flex-wrap items-center gap-2">
          <span class="text-xs font-semibold uppercase tracking-wider text-sr-muted">
            Section
          </span>
          <div class="flex flex-wrap gap-2">
            <.ui_button
              :for={section <- @sections}
              type="button"
              size="xs"
              variant={if(section.key == @active_section, do: "primary", else: "ghost")}
              active={section.key == @active_section}
              phx-click="select_section"
              phx-value-section={section.key}
            >
              {section.label}
            </.ui_button>
          </div>
        </div>
      </div>

      <%!-- Permission grid --%>
      <div class="max-h-[70vh] overflow-auto">
        <table class={ui_table_class(size: "sm")}>
          <thead>
            <tr>
              <th
                rowspan={if has_sub_columns?(@grid), do: 2, else: 1}
                class="min-w-[100px] sticky left-0 z-20 bg-sr-surface border-r border-sr-line"
              >
                <span class="text-xs font-semibold uppercase tracking-wider text-sr-muted">
                  Action
                </span>
              </th>
              <%= for group <- @grid.resource_groups do %>
                <%= if length(group.resources) == 1 do %>
                  <th
                    rowspan={if has_sub_columns?(@grid), do: 2, else: 1}
                    class={[
                      "text-center text-xs font-semibold normal-case min-w-[80px] border-l border-sr-line",
                      !@locked && "cursor-pointer hover:bg-sr-subtle/50"
                    ]}
                    phx-click={if(!@locked, do: "toggle_resource")}
                    phx-value-profile-id={@profile.id}
                    phx-value-resource={hd(group.resources).key}
                    title={"Toggle all #{group.label} permissions"}
                  >
                    {group.label}
                  </th>
                <% else %>
                  <th
                    colspan={length(group.resources)}
                    class="text-center text-[11px] font-bold uppercase tracking-wider bg-sr-subtle/40 border-l border-sr-line"
                  >
                    {group.label}
                  </th>
                <% end %>
              <% end %>
            </tr>
            <%= if has_sub_columns?(@grid) do %>
              <tr>
                <%= for group <- @grid.resource_groups, length(group.resources) > 1 do %>
                  <%= for {resource, idx} <- Enum.with_index(group.resources) do %>
                    <th
                      class={[
                        "text-center text-xs font-medium normal-case min-w-[80px]",
                        idx == 0 && "border-l border-sr-line",
                        !@locked && "cursor-pointer hover:bg-sr-subtle/50"
                      ]}
                      phx-click={if(!@locked, do: "toggle_resource")}
                      phx-value-profile-id={@profile.id}
                      phx-value-resource={resource.key}
                      title={"Toggle all #{resource.label} permissions"}
                    >
                      {resource.label}
                    </th>
                  <% end %>
                <% end %>
              </tr>
            <% end %>
          </thead>
          <tbody>
            <%= for action <- @grid.actions do %>
              <tr class="hover:bg-sr-subtle/30">
                <td
                  class={[
                    "font-medium text-sm bg-sr-surface sticky left-0 z-10 border-r border-sr-line",
                    !@locked && "cursor-pointer hover:bg-sr-subtle/50"
                  ]}
                  phx-click={if(!@locked, do: "toggle_action")}
                  phx-value-profile-id={@profile.id}
                  phx-value-action={action}
                  title={"Toggle #{humanize_action(action)} for all resources"}
                >
                  {humanize_action(action)}
                </td>
                <%= for {resource, r_idx} <- Enum.with_index(@grid.flat_resources) do %>
                  <td class={[
                    "text-center",
                    group_border_class(@grid, r_idx)
                  ]}>
                    <%= if permission_exists?(@grid, resource.key, action) do %>
                      <input
                        type="checkbox"
                        class={ui_checkbox_class()}
                        checked={permission_checked?(@profile, @grid, resource.key, action)}
                        disabled={@locked}
                        phx-click="toggle_permission"
                        phx-value-profile-id={@profile.id}
                        phx-value-permission={permission_key(@grid, resource.key, action)}
                      />
                    <% end %>
                  </td>
                <% end %>
              </tr>
            <% end %>
          </tbody>
        </table>
      </div>

      <div :if={@unmapped != []} class="px-5 py-4 border-t border-sr-line bg-sr-subtle/30">
        <div class="text-xs font-semibold uppercase tracking-wide text-sr-muted">
          Unmapped permissions
        </div>
        <div class="text-xs text-sr-muted">
          These permissions exist on the profile but are not present in the current RBAC catalog.
        </div>
        <div class="mt-2 flex flex-wrap gap-2">
          <.ui_badge :for={perm <- @unmapped} size="xs" variant="outline" class="font-mono">
            {perm}
          </.ui_badge>
        </div>
      </div>
    </div>
    """
  end

  # ── Component: new_profile_modal ──────────────────────────────

  attr(:form, :any, required: true)

  defp new_profile_modal(assigns) do
    ~H"""
    <dialog
      id="rbac-create-profile-modal"
      class="sr-ui-modal sr-ui-modal-open"
      phx-hook="DialogTopLayer"
    >
      <div class="sr-ui-modal-box">
        <h3 class="text-lg font-bold">Create Role Profile</h3>
        <p class="py-2 text-sm text-sr-muted">
          Create a custom profile. Permissions are copied from the selected source (if any).
        </p>
        <.form for={@form} id="new-profile-form" phx-submit="create_profile" class="space-y-4">
          <.input field={@form[:name]} type="text" label="Profile Name" required />
          <.input field={@form[:description]} type="text" label="Description" />
          <div class="sr-ui-modal-action">
            <.ui_button type="button" phx-click="close_new_profile" size="sm" variant="ghost">
              Cancel
            </.ui_button>
            <.ui_button type="submit" size="sm" variant="primary">Create</.ui_button>
          </div>
        </.form>
      </div>
      <div class="sr-ui-modal-backdrop">
        <button type="button" phx-click="close_new_profile">close</button>
      </div>
    </dialog>
    """
  end

  # ── Component: delete_profile_modal ───────────────────────────

  attr(:profile, :map, required: true)

  defp delete_profile_modal(assigns) do
    ~H"""
    <dialog
      id="rbac-delete-profile-modal"
      class="sr-ui-modal sr-ui-modal-open"
      phx-hook="DialogTopLayer"
    >
      <div class="sr-ui-modal-box">
        <h3 class="text-lg font-bold">Delete Role Profile?</h3>
        <p class="py-2 text-sm text-sr-muted">
          This will permanently delete <span class="font-semibold">{@profile.name}</span>.
          Users assigned to this profile will fall back to their role defaults.
        </p>
        <div class="sr-ui-modal-action">
          <.ui_button type="button" phx-click="close_delete_profile" size="sm" variant="ghost">
            Cancel
          </.ui_button>
          <.ui_button
            type="button"
            phx-click="delete_profile"
            phx-value-profile-id={@profile.id}
            size="sm"
            variant="danger"
          >
            Delete
          </.ui_button>
        </div>
      </div>
      <div class="sr-ui-modal-backdrop">
        <button type="button" phx-click="close_delete_profile">close</button>
      </div>
    </dialog>
    """
  end

  # ── Grid building ─────────────────────────────────────────────

  defp build_permission_grid(catalog) do
    resource_groups =
      Enum.map(catalog, fn section ->
        visible = Enum.reject(section.permissions, &Map.get(&1, :alias_of))
        resources = build_section_resources(visible)
        actions = section_actions(visible)
        cells = Map.new(visible, &{{&1.resource, &1.action}, &1.key})

        %{
          section: sect_id(section),
          label: sect_label(section),
          resources: resources,
          actions: actions,
          cells: cells
        }
      end)

    sections =
      Enum.map(resource_groups, fn group ->
        %{key: group.section, label: group.label}
      end)

    first = List.first(resource_groups) || %{resources: [], actions: [], cells: %{}}

    valid_permissions =
      catalog
      |> Enum.flat_map(&sect_permissions/1)
      |> MapSet.new(&perm_key/1)

    %{
      sections: sections,
      resource_groups: resource_groups,
      flat_resources: first.resources,
      actions: first.actions,
      cells: first.cells,
      valid_permissions: valid_permissions,
      group_starts: MapSet.new([0])
    }
  end

  defp build_section_resources(perms) do
    perms
    |> Enum.map(& &1.resource)
    |> Enum.uniq()
    |> Enum.map(fn resource_key ->
      %{key: resource_key, label: Catalog.resource_label(resource_key)}
    end)
  end

  defp section_actions(perms) do
    declared = perms |> Enum.map(& &1.action) |> Enum.uniq()
    declared_set = MapSet.new(declared)
    vocab = Catalog.action_order()
    vocab_set = MapSet.new(vocab)

    Enum.filter(vocab, &MapSet.member?(declared_set, &1)) ++
      Enum.filter(declared, &(&1 not in vocab_set))
  end

  # ── Grid helpers ──────────────────────────────────────────────

  defp permission_exists?(grid, resource_key, action) do
    Map.has_key?(grid.cells, {resource_key, action})
  end

  defp permission_key(grid, resource_key, action) do
    Map.get(grid.cells, {resource_key, action})
  end

  defp permission_checked?(profile, grid, resource_key, action) do
    case permission_key(grid, resource_key, action) do
      nil -> false
      key -> Catalog.holds?(profile.permissions || [], key)
    end
  end

  defp has_sub_columns?(grid) do
    Enum.any?(grid.resource_groups, fn group -> length(group.resources) > 1 end)
  end

  defp group_border_class(grid, resource_index) do
    if MapSet.member?(grid.group_starts, resource_index),
      do: "border-l border-sr-line"
  end

  defp resource_permission_keys(grid, resource) do
    for {{res, _action}, key} <- grid.cells, res == resource, do: key
  end

  defp action_permission_keys(grid, action) do
    for {{_res, act}, key} <- grid.cells, act == action, do: key
  end

  defp humanize_action(action), do: String.replace(action, "_", " ")

  # ── Profile helpers ───────────────────────────────────────────

  defp find_profile(profiles, profile_id) do
    Enum.find(profiles, fn profile ->
      profile.id == profile_id or profile.id == to_string(profile_id)
    end)
  end

  defp replace_profile(profiles, updated) do
    Enum.map(profiles, fn profile -> if profile.id == updated.id, do: updated, else: profile end)
  end

  defp toggle_permission(profile, permission) do
    permissions = MapSet.new(profile.permissions || [])
    equivalents = Catalog.equivalent_keys(permission)
    held? = Enum.any?(equivalents, &MapSet.member?(permissions, &1))

    permissions =
      if held? do
        Enum.reduce(equivalents, permissions, fn key, acc -> MapSet.delete(acc, key) end)
      else
        MapSet.put(permissions, permission)
      end

    %{profile | permissions: MapSet.to_list(permissions)}
  end

  defp toggle_permissions_bulk(profile, keys) do
    permissions = MapSet.new(profile.permissions || [])
    expanded = keys |> Enum.flat_map(&Catalog.equivalent_keys/1) |> Enum.uniq()
    all_selected = Enum.all?(keys, &Catalog.holds?(permissions, &1))

    updated =
      if all_selected do
        Enum.reduce(expanded, permissions, fn key, acc -> MapSet.delete(acc, key) end)
      else
        Enum.reduce(keys, permissions, fn key, acc -> MapSet.put(acc, key) end)
      end

    %{profile | permissions: MapSet.to_list(updated)}
  end

  defp filter_profiles(profiles, filter) do
    filter = String.trim(filter || "")

    if filter == "" do
      profiles
    else
      downcased = String.downcase(filter)

      Enum.filter(profiles, fn profile ->
        name = String.downcase(profile.name || "")
        sys = String.downcase(to_string(profile.system_name || ""))
        String.contains?(name, downcased) or String.contains?(sys, downcased)
      end)
    end
  end

  defp permissions_from_clone(_profiles, nil), do: []

  defp permissions_from_clone(profiles, clone_source_id) do
    case find_profile(profiles, clone_source_id) do
      nil -> []
      profile -> profile.permissions || []
    end
  end

  defp unmapped_permissions(profile, grid) do
    (profile.permissions || [])
    |> Enum.reject(&MapSet.member?(grid.valid_permissions, &1))
    |> Enum.sort()
  end

  defp profile_badge_variant(profile) do
    case to_string(profile.system_name || "") do
      "admin" -> "error"
      "operator" -> "warning"
      "viewer" -> "info"
      _ -> "ghost"
    end
  end

  defp profile_identifier(profile) do
    if profile.system_name do
      profile.system_name
    else
      profile.name |> to_string() |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "_")
    end
  end

  # ── Catalog accessors ─────────────────────────────────────────

  defp sect_id(section), do: Map.get(section, :section) || Map.get(section, "section") || ""
  defp sect_label(section), do: Map.get(section, :label) || Map.get(section, "label") || ""

  defp sect_permissions(section) do
    Map.get(section, :permissions) || Map.get(section, "permissions") || []
  end

  defp perm_key(permission), do: Map.get(permission, :key) || Map.get(permission, "key") || ""

  # ── Formatting ────────────────────────────────────────────────

  defp default_profile_form, do: %{"name" => "", "description" => ""}

  defp maybe_put_flash(socket, nil), do: socket
  defp maybe_put_flash(socket, message), do: put_flash(socket, :error, message)

  defp load_role_profiles(scope) do
    query =
      RoleProfile
      |> Ash.Query.for_read(:read, %{}, scope: scope)
      |> Ash.Query.sort(system: :desc, name: :asc)

    case Ash.read(query, scope: scope) do
      {:ok, profiles} ->
        {profiles, nil}

      {:error, error} ->
        {[], format_ash_error(error)}
    end
  end

  defp load_group_profiles(socket) do
    scope = socket.assigns.current_scope
    generation = socket.assigns.group_profile_generation + 1

    socket
    |> cancel_async(:group_profile_assignments)
    |> assign(:group_profile_generation, generation)
    |> assign_async(
      :group_profile_assignments,
      fn ->
        case PolicyData.load_group_profiles(scope) do
          {:ok, data} ->
            {:ok, %{group_profile_assignments: Map.put(data, :generation, generation)}}

          {:error, reason} ->
            Logger.warning("RBAC group profile load failed: #{inspect(reason)}")
            {:error, :group_profile_load_failed}
        end
      end,
      reset: true
    )
  end

  # assign_async owns loading/failure state. Observe only its accepted generation;
  # after_render cannot emit a diff, so a message owns the subsequent stream refresh.
  defp queue_dashboard_group_refresh(socket) do
    generation = socket.assigns.group_profile_generation

    with true <- connected?(socket),
         true <- socket.private[:dashboard_group_generation] != generation,
         {:ok, data} <- current_group_profile_data(socket),
         {:ok, _current} <- PolicyData.accept_generation(generation, data) do
      if is_binary(socket.assigns.dashboard_audience.group_id) do
        send(self(), {:refresh_dashboard_group_tokens, generation})
      end

      put_private(socket, :dashboard_group_generation, generation)
    else
      _ -> socket
    end
  end

  defp current_group_profile_data(%{assigns: %{group_profile_assignments: async_result}}) do
    case async_result do
      %AsyncResult{ok?: true, result: data} -> {:ok, data}
      _result -> {:error, :stale}
    end
  end

  defp stale_group_profile_data(socket) do
    socket
    |> put_flash(:error, "Group assignments changed. Reloaded the latest values.")
    |> load_group_profiles()
  end

  defp start_dashboard_audience_request(socket, source, direction) when source in [:authored, :package] do
    audience = socket.assigns.dashboard_audience
    request_ref = Integer.to_string(System.unique_integer([:positive, :monotonic]))

    case DashboardAudience.start_request(audience, source, direction, request_ref) do
      {:ok, requested, selector, epoch} ->
        scope = socket.assigns.current_scope
        group_id = requested.group_id

        socket
        |> assign(:dashboard_audience, requested)
        |> start_async({:dashboard_audience, source, request_ref}, fn ->
          {epoch, GroupAccess.page(scope, {:policy_editor, source}, group_id, selector)}
        end)

      {:error, :stale, _unchanged} ->
        socket
    end
  end

  defp accept_dashboard_audience_result(socket, source, epoch, request_ref, result) do
    case DashboardAudience.accept_result(
           socket.assigns.dashboard_audience,
           source,
           epoch,
           request_ref,
           result
         ) do
      {:replace, audience, rows} ->
        socket
        |> assign(:dashboard_audience, audience)
        |> stream(dashboard_stream(source), rows, reset: true)

      {:preserve, audience} ->
        log_dashboard_audience_error(source, result)
        assign(socket, :dashboard_audience, audience)

      {:ignore, _audience} ->
        socket
    end
  end

  defp mutate_dashboard_audience(socket, source, operation, params)
       when source in [:authored, :package] and operation in [:ensure, :revoke] do
    safe_params = Map.take(params, ["group-token", "row-token"])
    audience = socket.assigns.dashboard_audience

    with {:ok, data} <- current_group_profile_data(socket),
         {:ok, {group_id, nil}} <-
           PolicyData.resolve_clear(
             data,
             socket.assigns.group_profile_generation,
             safe_params
           ),
         group_token when is_binary(group_token) <- Map.get(safe_params, "group-token"),
         row_token when is_binary(row_token) <- Map.get(safe_params, "row-token"),
         {:ok, synced} <- DashboardAudience.sync_group_token(audience, group_token, group_id),
         {:ok, expected} <- DashboardAudience.resolve_row(synced, source, row_token),
         {:ok, _result} <-
           run_dashboard_audience_mutation(
             socket.assigns.current_scope,
             source,
             operation,
             expected
           ) do
      socket
      |> assign(:dashboard_audience, synced)
      |> put_flash(:info, "Dashboard audience updated")
      |> start_dashboard_audience_request(source, :first)
    else
      {:error, reason} ->
        Logger.warning("RBAC #{source} dashboard audience mutation failed: #{inspect(reason)}")

        socket
        |> put_flash(
          :error,
          "Dashboard audience could not be updated. Reloaded the latest values."
        )
        |> start_dashboard_audience_request(source, :first)

      _reason ->
        socket
        |> put_flash(
          :error,
          "Dashboard audience could not be updated. Reloaded the latest values."
        )
        |> start_dashboard_audience_request(source, :first)
    end
  end

  defp run_dashboard_audience_mutation(scope, source, :ensure, expected) do
    GroupAccess.ensure_group_view(
      scope,
      {:policy_editor, source},
      expected.target_id,
      expected.group_id,
      expected_fingerprint: expected.fingerprint
    )
  end

  defp run_dashboard_audience_mutation(scope, source, :revoke, expected) do
    GroupAccess.revoke_group_view(
      scope,
      {:policy_editor, source},
      expected.target_id,
      expected.group_id,
      expected_fingerprint: expected.fingerprint
    )
  end

  defp dashboard_group(%AsyncResult{ok?: true, result: data}, generation, audience) do
    with {:ok, current} <- PolicyData.accept_generation(generation, data),
         group_id when is_binary(group_id) <- audience.group_id,
         {token, ^group_id} <-
           Enum.find(current.group_tokens, fn {_token, id} -> id == group_id end),
         %{name: name} <- Enum.find(current.groups, &(to_string(&1.id) == group_id)) do
      %{token: token, name: name}
    else
      _ -> nil
    end
  end

  defp dashboard_group(%AsyncResult{ok?: false}, _generation, %{group_token: token, group_id: group_id, group_name: name})
       when is_binary(token) and is_binary(group_id) and is_binary(name) do
    %{token: token, name: name}
  end

  defp dashboard_group(_result, _generation, _audience), do: nil

  defp dashboard_stream(:authored), do: :rbac_authored_dashboards
  defp dashboard_stream(:package), do: :rbac_package_dashboards

  defp log_dashboard_audience_error(source, {:error, reason}) do
    Logger.warning("RBAC #{source} dashboard audience load failed: #{inspect(reason)}")
  end

  defp log_dashboard_audience_error(source, unexpected) do
    Logger.warning("RBAC #{source} dashboard audience load returned: #{inspect(unexpected)}")
  end

  defp persist_profile(socket, scope, profile) do
    result = RoleProfilePolicy.update(scope, profile.id, %{permissions: profile.permissions})

    case result do
      {:ok, updated} ->
        socket
        |> assign(:profiles, replace_profile(socket.assigns.profiles, updated))
        |> assign(:dirty_profiles, MapSet.delete(socket.assigns.dirty_profiles, updated.id))
        |> put_flash(:info, "Role profile updated")

      {:error, error} ->
        put_flash(socket, :error, format_ash_error(error))
    end
  end

  defp profile_locked?(profile) do
    profile.system && to_string(profile.system_name || "") == "admin"
  end

  defp format_ash_error(%Ash.Error.Invalid{errors: errors}) do
    Enum.map_join(errors, ", ", fn
      %{message: message} -> message
      _ -> "Validation error"
    end)
  end

  defp format_ash_error(_), do: "Unexpected error"

  defp section_grid(%{} = grid, section_key) do
    section_key = to_string(section_key || "")

    group =
      Enum.find(grid.resource_groups, fn group ->
        to_string(group.section) == section_key
      end) || List.first(grid.resource_groups)

    group =
      group ||
        %{section: "", label: "", resources: [], actions: [], cells: %{}}

    Map.put(
      %{
        grid
        | resource_groups: [group],
          flat_resources: group.resources,
          actions: group.actions,
          cells: group.cells,
          group_starts: MapSet.new([0])
      },
      :active_section,
      group.section
    )
  end
end
