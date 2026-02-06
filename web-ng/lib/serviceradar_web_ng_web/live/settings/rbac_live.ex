defmodule ServiceRadarWebNGWeb.Settings.RbacLive do
  @moduledoc """
  RBAC policy editor.

  Displays a per-profile permission grid with catalog sections as column groups,
  resources as sub-columns, and actions as rows.
  """

  use ServiceRadarWebNGWeb, :live_view

  use Permit.Phoenix.LiveView,
    authorization_module: ServiceRadarWebNG.Authorization,
    resource_module: ServiceRadar.Identity.RoleProfile

  require Ash.Query

  alias ServiceRadar.Identity.RBAC
  alias ServiceRadar.Identity.RoleProfile
  alias ServiceRadarWebNG.RBAC, as: WebRBAC
  alias ServiceRadarWebNGWeb.SettingsComponents

  @action_order ~w(view create update delete manage manage_queries bulk_edit bulk_delete import export run)

  # ── Mount ─────────────────────────────────────────────────────

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    if not WebRBAC.can?(scope, "settings.rbac.manage") do
      {:ok,
       socket
       |> put_flash(:error, "Admin access required")
       |> redirect(to: ~p"/settings/profile")}
    else
      {profiles, profile_flash} = load_role_profiles(scope)
      catalog = RBAC.catalog()
      grid = build_permission_grid(catalog)
      active_profile_id = profiles |> List.first() |> then(&(&1 && &1.id))
      active_section = grid.resource_groups |> List.first() |> then(&(&1 && &1.section))

      {:ok,
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
       |> maybe_put_flash(profile_flash)}
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
    name = (params["name"] || "") |> String.trim()

    cond do
      profile == nil ->
        {:noreply, socket}

      profile.system ->
        {:noreply, socket}

      name == "" ->
        {:noreply, put_flash(socket, :error, "Name is required")}

      true ->
        case update_role_profile(scope, profile, %{name: name}) do
          {:ok, updated} ->
            {:noreply,
             socket
             |> assign(:profiles, replace_profile(socket.assigns.profiles, updated))
             |> assign(:renaming_profile_id, nil)
             |> put_flash(:info, "Profile renamed")}

          {:error, error} ->
            {:noreply, put_flash(socket, :error, format_ash_error(error))}
        end
    end
  end

  def handle_event(
        "toggle_permission",
        %{"profile-id" => profile_id, "permission" => permission},
        socket
      ) do
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

  def handle_event(
        "toggle_resource",
        %{"profile-id" => profile_id, "resource" => resource},
        socket
      ) do
    profile = find_profile(socket.assigns.profiles, profile_id)

    if profile == nil or profile_locked?(profile) do
      {:noreply, socket}
    else
      keys = resource_permission_keys(socket.assigns.grid, resource)
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
      keys = action_permission_keys(socket.assigns.grid, action)
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

  def handle_event(
        "set_profile_permissions",
        %{"profile-id" => profile_id, "mode" => mode},
        socket
      ) do
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

    case create_role_profile(scope, attrs) do
      {:ok, profile} ->
        {:noreply,
         socket
         |> assign(:profiles, socket.assigns.profiles ++ [profile])
         |> assign(:active_profile_id, profile.id)
         |> assign(:show_new_profile_modal, false)
         |> assign(:clone_source_id, nil)
         |> put_flash(:info, "Role profile created")}

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
        case delete_role_profile(scope, profile.id) do
          :ok ->
            {:noreply,
             socket
             |> assign(:profiles, Enum.reject(socket.assigns.profiles, &(&1.id == profile.id)))
             |> assign(:dirty_profiles, MapSet.delete(socket.assigns.dirty_profiles, profile.id))
             |> assign(:confirm_delete_profile, nil)
             |> put_flash(:info, "Role profile deleted")}

          {:ok, _} ->
            {:noreply,
             socket
             |> assign(:profiles, Enum.reject(socket.assigns.profiles, &(&1.id == profile.id)))
             |> assign(:dirty_profiles, MapSet.delete(socket.assigns.dirty_profiles, profile.id))
             |> assign(:confirm_delete_profile, nil)
             |> put_flash(:info, "Role profile deleted")}

          {:error, error} ->
            {:noreply, put_flash(socket, :error, format_ash_error(error))}
        end
    end
  end

  # ── Permit callbacks ──────────────────────────────────────────

  @impl true
  def event_mapping do
    Permit.Phoenix.LiveView.default_event_mapping()
    |> Map.merge(%{
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
      "close_delete_profile" => :read
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
      cond do
        assigns.active_profile_id ->
          find_profile(assigns.filtered_profiles, assigns.active_profile_id)

        true ->
          List.first(assigns.filtered_profiles)
      end

    assigns = assign(assigns, :active_profile, active_profile)

    assigns =
      assign(assigns, :section_grid, section_grid(assigns.grid, assigns.active_section))

    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <SettingsComponents.settings_shell current_path="/settings/auth/rbac">
        <div class="space-y-4">
          <div class="space-y-2">
            <SettingsComponents.settings_nav
              current_path="/settings/auth/rbac"
              current_scope={@current_scope}
            />
            <SettingsComponents.auth_nav
              current_path="/settings/auth/rbac"
              current_scope={@current_scope}
            />
          </div>

          <div class="flex flex-wrap items-start justify-between gap-4">
            <div class="space-y-1">
              <div class="badge badge-outline">Policy Editor</div>
              <h1 class="text-2xl font-semibold">RBAC</h1>
              <p class="text-sm text-base-content/60">
                Edit role profiles using a compact permissions grid. Built-in profiles are clone-only.
              </p>
            </div>

            <div class="flex items-center gap-2">
              <button :if={@has_dirty?} class="btn btn-primary btn-sm" phx-click="save_all">
                Save all
              </button>
              <button class="btn btn-primary btn-sm gap-1" phx-click="open_new_profile">
                Create <.icon name="hero-plus-mini" class="h-4 w-4" />
              </button>
            </div>
          </div>

          <div class="flex flex-wrap items-center justify-between gap-4">
            <label class="input input-bordered input-sm flex items-center gap-2 w-full max-w-sm">
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
              <span class="text-xs font-semibold uppercase tracking-wider text-base-content/60">
                Profiles
              </span>
              <div class="flex flex-wrap gap-2">
                <button
                  :for={profile <- @filtered_profiles}
                  type="button"
                  class={[
                    "btn btn-xs",
                    @active_profile && profile.id == @active_profile.id && "btn-primary",
                    @active_profile && profile.id != @active_profile.id && "btn-ghost"
                  ]}
                  phx-click="select_profile"
                  phx-value-profile-id={profile.id}
                >
                  {profile.name}
                </button>
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

            <div :if={@filtered_profiles == []} class="w-full text-center py-16 text-base-content/50">
              <.icon name="hero-shield-exclamation" class="h-12 w-12 mx-auto mb-3 opacity-30" />
              <p class="text-sm">No profiles match your filter.</p>
            </div>
          </div>
        </div>

        <.new_profile_modal :if={@show_new_profile_modal} form={@new_profile_form} />
        <.delete_profile_modal :if={@confirm_delete_profile} profile={@confirm_delete_profile} />
      </SettingsComponents.settings_shell>
    </Layouts.app>
    """
  end

  # ── Component: profile_card ───────────────────────────────────

  attr :profile, :map, required: true
  attr :grid, :map, required: true
  attr :dirty, :boolean, default: false
  attr :renaming_profile_id, :any, default: nil
  attr :rename_form, :any, required: true
  attr :sections, :list, required: true
  attr :active_section, :string, default: nil

  defp profile_card(assigns) do
    assigns = assign(assigns, :unmapped, unmapped_permissions(assigns.profile, assigns.grid))
    assigns = assign(assigns, :locked, profile_locked?(assigns.profile))
    assigns = assign(assigns, :renaming?, assigns.renaming_profile_id == assigns.profile.id)

    ~H"""
    <div class="rounded-xl border border-base-200 bg-base-100 shadow-sm">
      <%!-- Card header --%>
      <div class="flex items-center justify-between gap-3 px-5 py-3 border-b border-base-200">
        <div class="flex items-center gap-3">
          <%= if @renaming? do %>
            <.form for={@rename_form} phx-submit="rename_profile" class="flex items-center gap-2">
              <input type="hidden" name="profile_id" value={@profile.id} />
              <input
                type="text"
                name={@rename_form[:name].name}
                value={@rename_form[:name].value}
                class="input input-bordered input-sm w-56"
                autocomplete="off"
              />
              <button type="submit" class="btn btn-primary btn-xs">Save</button>
              <button type="button" class="btn btn-ghost btn-xs" phx-click="cancel_rename_profile">
                Cancel
              </button>
            </.form>
          <% else %>
            <%= if @profile.system do %>
              <span class={["badge gap-1", profile_badge_class(@profile)]}>
                {@profile.name}
              </span>
            <% else %>
              <button
                type="button"
                class={["badge gap-1 cursor-text hover:opacity-80", profile_badge_class(@profile)]}
                phx-click="start_rename_profile"
                phx-value-profile-id={@profile.id}
                title="Click to rename"
              >
                {@profile.name}
              </button>
            <% end %>
          <% end %>
          <span class="text-sm text-base-content/50">
            {profile_identifier(@profile)}
          </span>
          <span :if={@dirty} class="badge badge-warning badge-sm gap-1">unsaved</span>
        </div>
        <div class="flex items-center gap-2">
          <div class={["join", @locked && "opacity-50"]}>
            <button
              type="button"
              class="btn btn-xs join-item"
              disabled={@locked}
              phx-click="set_profile_permissions"
              phx-value-profile-id={@profile.id}
              phx-value-mode="all"
            >
              All
            </button>
            <button
              type="button"
              class="btn btn-xs join-item"
              disabled={@locked}
              phx-click="set_profile_permissions"
              phx-value-profile-id={@profile.id}
              phx-value-mode="none"
            >
              None
            </button>
          </div>
          <button
            :if={@dirty}
            class="btn btn-primary btn-xs"
            phx-click="save_profile"
            phx-value-profile-id={@profile.id}
          >
            Save
          </button>
          <div class="dropdown dropdown-end">
            <div tabindex="0" role="button" class="btn btn-ghost btn-sm btn-square">
              <.icon name="hero-ellipsis-vertical" class="h-5 w-5" />
            </div>
            <ul
              tabindex="0"
              class="dropdown-content z-[1] menu p-2 shadow-lg bg-base-100 rounded-box w-44 border border-base-200"
            >
              <li>
                <button phx-click="open_new_profile" phx-value-clone-source-id={@profile.id}>
                  <.icon name="hero-document-duplicate" class="h-4 w-4" /> Clone
                </button>
              </li>
              <li :if={!@profile.system}>
                <button
                  phx-click="open_delete_profile"
                  phx-value-profile-id={@profile.id}
                  class="text-error"
                >
                  <.icon name="hero-trash" class="h-4 w-4" /> Delete
                </button>
              </li>
            </ul>
          </div>
        </div>
      </div>

      <%!-- Section switcher --%>
      <div class="px-5 pt-4">
        <div class="flex flex-wrap items-center gap-2">
          <span class="text-xs font-semibold uppercase tracking-wider text-base-content/60">
            Section
          </span>
          <div class="flex flex-wrap gap-2">
            <button
              :for={section <- @sections}
              type="button"
              class={[
                "btn btn-xs",
                section.key == @active_section && "btn-primary",
                section.key != @active_section && "btn-ghost"
              ]}
              phx-click="select_section"
              phx-value-section={section.key}
            >
              {section.label}
            </button>
          </div>
        </div>
      </div>

      <%!-- Permission grid --%>
      <div class="max-h-[70vh] overflow-auto">
        <table class="table table-sm table-pin-rows">
          <thead>
            <tr>
              <th
                rowspan={if has_sub_columns?(@grid), do: 2, else: 1}
                class="min-w-[100px] sticky left-0 z-20 bg-base-100 border-r border-base-200"
              >
                <span class="text-xs font-semibold uppercase tracking-wider text-base-content/60">
                  Action
                </span>
              </th>
              <%= for group <- @grid.resource_groups do %>
                <%= if length(group.resources) == 1 do %>
                  <th
                    rowspan={if has_sub_columns?(@grid), do: 2, else: 1}
                    class={[
                      "text-center text-xs font-semibold normal-case min-w-[80px] border-l border-base-200",
                      !@locked && "cursor-pointer hover:bg-base-200/50"
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
                    class="text-center text-[11px] font-bold uppercase tracking-wider bg-base-200/40 border-l border-base-200"
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
                        idx == 0 && "border-l border-base-200",
                        !@locked && "cursor-pointer hover:bg-base-200/50"
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
              <tr class="hover:bg-base-200/30">
                <td
                  class={[
                    "font-medium text-sm bg-base-100 sticky left-0 z-10 border-r border-base-200",
                    !@locked && "cursor-pointer hover:bg-base-200/50"
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
                        class={[
                          "checkbox checkbox-sm",
                          permission_checked?(@profile, resource.key, action) && "checkbox-primary"
                        ]}
                        checked={permission_checked?(@profile, resource.key, action)}
                        disabled={@locked}
                        phx-click="toggle_permission"
                        phx-value-profile-id={@profile.id}
                        phx-value-permission={"#{resource.key}.#{action}"}
                      />
                    <% end %>
                  </td>
                <% end %>
              </tr>
            <% end %>
          </tbody>
        </table>
      </div>

      <div :if={@unmapped != []} class="px-5 py-4 border-t border-base-200 bg-base-200/30">
        <div class="text-xs font-semibold uppercase tracking-wide text-base-content/60">
          Unmapped permissions
        </div>
        <div class="text-xs text-base-content/60">
          These permissions exist on the profile but are not present in the current RBAC catalog.
        </div>
        <div class="mt-2 flex flex-wrap gap-2">
          <span :for={perm <- @unmapped} class="badge badge-outline font-mono text-[11px]">
            {perm}
          </span>
        </div>
      </div>
    </div>
    """
  end

  # ── Component: new_profile_modal ──────────────────────────────

  attr :form, :any, required: true

  defp new_profile_modal(assigns) do
    ~H"""
    <dialog class="modal modal-open">
      <div class="modal-box">
        <h3 class="text-lg font-bold">Create Role Profile</h3>
        <p class="py-2 text-sm text-base-content/60">
          Create a custom profile. Permissions are copied from the selected source (if any).
        </p>
        <.form for={@form} id="new-profile-form" phx-submit="create_profile" class="space-y-4">
          <.input field={@form[:name]} type="text" label="Profile Name" required />
          <.input field={@form[:description]} type="text" label="Description" />
          <div class="modal-action">
            <button type="button" class="btn btn-ghost" phx-click="close_new_profile">Cancel</button>
            <button type="submit" class="btn btn-primary">Create</button>
          </div>
        </.form>
      </div>
      <div class="modal-backdrop">
        <button type="button" phx-click="close_new_profile">close</button>
      </div>
    </dialog>
    """
  end

  # ── Component: delete_profile_modal ───────────────────────────

  attr :profile, :map, required: true

  defp delete_profile_modal(assigns) do
    ~H"""
    <dialog class="modal modal-open">
      <div class="modal-box">
        <h3 class="text-lg font-bold">Delete Role Profile?</h3>
        <p class="py-2 text-sm text-base-content/60">
          This will permanently delete <span class="font-semibold">{@profile.name}</span>.
          Users assigned to this profile will fall back to their role defaults.
        </p>
        <div class="modal-action">
          <button type="button" class="btn btn-ghost" phx-click="close_delete_profile">Cancel</button>
          <button
            type="button"
            class="btn btn-error"
            phx-click="delete_profile"
            phx-value-profile-id={@profile.id}
          >
            Delete
          </button>
        </div>
      </div>
      <div class="modal-backdrop">
        <button type="button" phx-click="close_delete_profile">close</button>
      </div>
    </dialog>
    """
  end

  # ── Grid building ─────────────────────────────────────────────

  defp build_permission_grid(catalog) do
    resource_groups =
      Enum.map(catalog, fn section ->
        section_key = sect_id(section)
        perms = sect_permissions(section)

        resources =
          perms
          |> Enum.map(fn perm ->
            {resource, _action} = split_permission_key(perm_key(perm))
            resource
          end)
          |> Enum.uniq()
          |> then(fn resources ->
            has_sub_resources? = Enum.any?(resources, &(&1 != section_key))

            Enum.map(resources, fn res ->
              label =
                cond do
                  res == section_key and has_sub_resources? -> "All"
                  true -> resource_short_label(res, section_key)
                end

              %{key: res, label: label}
            end)
          end)

        %{
          section: section_key,
          label: sect_label(section),
          resources: resources
        }
      end)

    sections =
      Enum.map(resource_groups, fn group ->
        %{key: group.section, label: group.label}
      end)

    flat_resources = Enum.flat_map(resource_groups, & &1.resources)

    all_permissions = Enum.flat_map(catalog, &sect_permissions/1)

    actions =
      all_permissions
      |> Enum.map(fn perm ->
        {_res, action} = split_permission_key(perm_key(perm))
        action
      end)
      |> Enum.uniq()
      |> Enum.sort_by(&action_sort_index/1)

    valid_permissions = MapSet.new(Enum.map(all_permissions, &perm_key/1))

    # Pre-compute group boundary indices for left-border styling
    group_starts =
      resource_groups
      |> Enum.reduce({0, MapSet.new()}, fn group, {offset, acc} ->
        {offset + length(group.resources), MapSet.put(acc, offset)}
      end)
      |> elem(1)

    %{
      sections: sections,
      resource_groups: resource_groups,
      flat_resources: flat_resources,
      actions: actions,
      valid_permissions: valid_permissions,
      group_starts: group_starts
    }
  end

  defp split_permission_key(key) do
    parts = String.split(key, ".")

    case parts do
      [single] ->
        {single, ""}

      _ ->
        action = List.last(parts)
        resource = parts |> Enum.drop(-1) |> Enum.join(".")
        {resource, action}
    end
  end

  defp action_sort_index(action) do
    case Enum.find_index(@action_order, &(&1 == action)) do
      nil -> 999
      i -> i
    end
  end

  defp resource_short_label(resource_key, section_key) do
    if resource_key == section_key do
      section_key
    else
      resource_key
      |> String.replace_prefix(section_key <> ".", "")
      |> String.replace("_profiles", "")
      |> String.replace("_", " ")
    end
  end

  # ── Grid helpers ──────────────────────────────────────────────

  defp permission_exists?(grid, resource_key, action) do
    MapSet.member?(grid.valid_permissions, "#{resource_key}.#{action}")
  end

  defp permission_checked?(profile, resource_key, action) do
    "#{resource_key}.#{action}" in (profile.permissions || [])
  end

  defp has_sub_columns?(grid) do
    Enum.any?(grid.resource_groups, fn group -> length(group.resources) > 1 end)
  end

  defp group_border_class(grid, resource_index) do
    if MapSet.member?(grid.group_starts, resource_index),
      do: "border-l border-base-200",
      else: nil
  end

  defp resource_permission_keys(grid, resource) do
    grid.valid_permissions
    |> MapSet.to_list()
    |> Enum.filter(fn key ->
      {res, _action} = split_permission_key(key)
      res == resource
    end)
  end

  defp action_permission_keys(grid, action) do
    grid.valid_permissions
    |> MapSet.to_list()
    |> Enum.filter(fn key ->
      {_res, act} = split_permission_key(key)
      act == action
    end)
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

    permissions =
      if MapSet.member?(permissions, permission) do
        MapSet.delete(permissions, permission)
      else
        MapSet.put(permissions, permission)
      end

    %{profile | permissions: MapSet.to_list(permissions)}
  end

  defp toggle_permissions_bulk(profile, keys) do
    permissions = MapSet.new(profile.permissions || [])
    all_selected = Enum.all?(keys, &MapSet.member?(permissions, &1))

    updated =
      if all_selected do
        Enum.reduce(keys, permissions, fn key, acc -> MapSet.delete(acc, key) end)
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

  defp profile_badge_class(profile) do
    case to_string(profile.system_name || "") do
      "admin" -> "badge-error"
      "operator" -> "badge-warning"
      "viewer" -> "badge-info"
      _ -> "badge-secondary"
    end
  end

  defp profile_identifier(profile) do
    cond do
      profile.system_name ->
        profile.system_name

      true ->
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
      {:ok, profiles} -> {profiles, nil}
      {:error, error} -> {[], format_ash_error(error)}
    end
  end

  defp create_role_profile(scope, attrs) do
    RoleProfile
    |> Ash.Changeset.for_create(:create, attrs, scope: scope)
    |> Ash.create(scope: scope)
  end

  defp delete_role_profile(scope, id) do
    with {:ok, profile} <- Ash.get(RoleProfile, id, scope: scope) do
      Ash.destroy(profile, scope: scope)
    end
  end

  defp persist_profile(socket, scope, profile) do
    result =
      with {:ok, record} <- Ash.get(RoleProfile, profile.id, scope: scope),
           {:ok, updated} <-
             record
             |> Ash.Changeset.for_update(:update, %{permissions: profile.permissions},
               scope: scope
             )
             |> Ash.update(scope: scope) do
        {:ok, updated}
      end

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

  defp update_role_profile(scope, profile, attrs) do
    with {:ok, record} <- Ash.get(RoleProfile, profile.id, scope: scope) do
      record
      |> Ash.Changeset.for_update(:update, attrs, scope: scope)
      |> Ash.update(scope: scope)
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

  defp format_ash_error({:http_error, status, body}) do
    message =
      case body do
        %{"error" => error} -> error
        %{"message" => error} -> error
        _ -> "Request failed"
      end

    "HTTP #{status}: #{message}"
  end

  defp format_ash_error(_), do: "Unexpected error"

  defp section_grid(%{} = grid, section_key) do
    section_key = to_string(section_key || "")

    group =
      Enum.find(grid.resource_groups, fn group ->
        to_string(group.section) == section_key
      end) || List.first(grid.resource_groups)

    group = group || %{section: "", label: "", resources: []}

    group_starts = MapSet.new([0])

    %{
      grid
      | resource_groups: [group],
        flat_resources: group.resources,
        group_starts: group_starts
    }
    |> Map.put(:active_section, group.section)
  end
end
