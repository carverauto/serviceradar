defmodule ServiceRadarWebNGWeb.Settings.AccessControlLive do
  @moduledoc """
  Unified access control page for authorization settings and RBAC profiles.
  """

  use ServiceRadarWebNGWeb, :live_view

  alias ServiceRadarWebNG.AdminApi
  alias ServiceRadarWebNG.RBAC
  alias ServiceRadarWebNGWeb.SettingsComponents

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope
    can_auth = RBAC.can?(scope, "settings.auth.manage")
    can_rbac = RBAC.can?(scope, "settings.rbac.manage")

    if not (can_auth or can_rbac) do
      {:ok,
       socket
       |> put_flash(:error, "Admin access required")
       |> redirect(to: ~p"/settings/profile")}
    else
      {settings, settings_flash} = load_authorization_settings(scope, can_auth)
      {profiles, profiles_flash} = load_role_profiles(scope, can_rbac)
      {catalog, catalog_flash} = load_catalog(scope, can_rbac)

      {:ok,
       socket
       |> assign(:page_title, "Access Control")
       |> assign(:can_auth, can_auth)
       |> assign(:can_rbac, can_rbac)
       |> assign(:settings, settings)
       |> assign(:auth_form, to_form(settings_form(settings), as: :settings))
       |> assign(:role_mappings, normalize_role_mappings(settings.role_mappings || []))
       |> assign(:profiles, profiles)
       |> assign(:catalog, catalog)
       |> assign(:filter, "")
       |> assign(:dirty_profiles, MapSet.new())
       |> assign(:show_new_profile_form, false)
       |> assign(:new_profile_form, to_form(default_profile_form(), as: :profile))
       |> assign(:clone_source_id, nil)
       |> assign(:confirm_delete_profile, nil)
       |> assign(:grid_template, grid_template(profiles))
       |> maybe_put_flash(settings_flash)
       |> maybe_put_flash(profiles_flash)
       |> maybe_put_flash(catalog_flash)}
    end
  end

  @impl true
  def handle_event("validate_auth", %{"settings" => params} = payload, socket) do
    mappings = Map.get(payload, "mappings")

    socket =
      socket
      |> assign(:auth_form, to_form(params, as: :settings))
      |> maybe_assign_mappings(mappings)

    {:noreply, socket}
  end

  def handle_event("save_auth", %{"settings" => params} = payload, socket) do
    if not socket.assigns.can_auth do
      {:noreply, put_flash(socket, :error, "Not authorized to update authorization settings")}
    else
      scope = socket.assigns.current_scope
      mappings = Map.get(payload, "mappings")

      role_mappings =
        if mappings, do: mappings_from_params(mappings), else: socket.assigns.role_mappings

      with {:ok, attrs} <- normalize_auth_attrs(params, role_mappings),
           {:ok, updated} <- AdminApi.update_authorization_settings(scope, attrs) do
        {:noreply,
         socket
         |> assign(:settings, updated)
         |> assign(:auth_form, to_form(settings_form(updated), as: :settings))
         |> assign(:role_mappings, normalize_role_mappings(updated.role_mappings || []))
         |> put_flash(:info, "Authorization settings updated")}
      else
        {:error, :invalid_role} ->
          {:noreply, put_flash(socket, :error, "Default role must be viewer, operator, or admin")}

        {:error, error} ->
          {:noreply, put_flash(socket, :error, format_ash_error(error))}
      end
    end
  end

  def handle_event("add_mapping", _params, socket) do
    mapping = %{"source" => "groups", "value" => "", "role" => "viewer", "claim" => ""}
    {:noreply, assign(socket, :role_mappings, socket.assigns.role_mappings ++ [mapping])}
  end

  def handle_event("remove_mapping", %{"index" => index}, socket) do
    idx = parse_index(index)

    mappings =
      socket.assigns.role_mappings
      |> Enum.with_index()
      |> Enum.reject(fn {_mapping, current} -> current == idx end)
      |> Enum.map(&elem(&1, 0))

    {:noreply, assign(socket, :role_mappings, mappings)}
  end

  def handle_event("filter_permissions", %{"filter" => value}, socket) do
    {:noreply, assign(socket, :filter, value || "")}
  end

  def handle_event(
        "toggle_permission",
        %{"profile_id" => profile_id, "permission" => permission},
        socket
      ) do
    if not socket.assigns.can_rbac do
      {:noreply, put_flash(socket, :error, "Not authorized to edit role profiles")}
    else
      profile = find_profile(socket.assigns.profiles, profile_id)

      if profile == nil or profile.system do
        {:noreply, socket}
      else
        updated = toggle_permission(profile, permission)

        {:noreply,
         socket
         |> assign(:profiles, replace_profile(socket.assigns.profiles, updated))
         |> assign(:dirty_profiles, MapSet.put(socket.assigns.dirty_profiles, updated.id))}
      end
    end
  end

  def handle_event(
        "toggle_section",
        %{"profile_id" => profile_id, "section" => section_id},
        socket
      ) do
    if not socket.assigns.can_rbac do
      {:noreply, put_flash(socket, :error, "Not authorized to edit role profiles")}
    else
      profile = find_profile(socket.assigns.profiles, profile_id)
      section = find_section(socket.assigns.catalog, section_id)

      if profile == nil or profile.system or section == nil do
        {:noreply, socket}
      else
        updated = toggle_section_permissions(profile, section)

        {:noreply,
         socket
         |> assign(:profiles, replace_profile(socket.assigns.profiles, updated))
         |> assign(:dirty_profiles, MapSet.put(socket.assigns.dirty_profiles, updated.id))}
      end
    end
  end

  def handle_event("save_profile", %{"profile_id" => profile_id}, socket) do
    if not socket.assigns.can_rbac do
      {:noreply, put_flash(socket, :error, "Not authorized to edit role profiles")}
    else
      scope = socket.assigns.current_scope
      profile = find_profile(socket.assigns.profiles, profile_id)

      if profile == nil do
        {:noreply, socket}
      else
        case AdminApi.update_role_profile(scope, profile.id, %{permissions: profile.permissions}) do
          {:ok, updated} ->
            {:noreply,
             socket
             |> assign(:profiles, replace_profile(socket.assigns.profiles, updated))
             |> assign(:dirty_profiles, MapSet.delete(socket.assigns.dirty_profiles, updated.id))
             |> put_flash(:info, "Role profile updated")}

          {:error, error} ->
            {:noreply, put_flash(socket, :error, format_ash_error(error))}
        end
      end
    end
  end

  def handle_event("open_new_profile", params, socket) do
    clone_source_id = Map.get(params, "clone_source_id")

    {:noreply,
     socket
     |> assign(:show_new_profile_form, true)
     |> assign(:clone_source_id, clone_source_id)
     |> assign(:new_profile_form, to_form(default_profile_form(), as: :profile))}
  end

  def handle_event("close_new_profile", _params, socket) do
    {:noreply, assign(socket, :show_new_profile_form, false)}
  end

  def handle_event("create_profile", %{"profile" => params}, socket) do
    if not socket.assigns.can_rbac do
      {:noreply, put_flash(socket, :error, "Not authorized to edit role profiles")}
    else
      scope = socket.assigns.current_scope

      base_permissions =
        permissions_from_clone(socket.assigns.profiles, socket.assigns.clone_source_id)

      attrs = %{
        name: Map.get(params, "name"),
        description: Map.get(params, "description"),
        permissions: base_permissions
      }

      case AdminApi.create_role_profile(scope, attrs) do
        {:ok, profile} ->
          profiles = socket.assigns.profiles ++ [profile]

          {:noreply,
           socket
           |> assign(:profiles, profiles)
           |> assign(:grid_template, grid_template(profiles))
           |> assign(:show_new_profile_form, false)
           |> assign(:clone_source_id, nil)
           |> put_flash(:info, "Role profile created")}

        {:error, error} ->
          {:noreply, put_flash(socket, :error, format_ash_error(error))}
      end
    end
  end

  def handle_event("delete_profile", %{"profile_id" => profile_id}, socket) do
    if not socket.assigns.can_rbac do
      {:noreply, put_flash(socket, :error, "Not authorized to edit role profiles")}
    else
      scope = socket.assigns.current_scope
      profile = find_profile(socket.assigns.profiles, profile_id)

      cond do
        profile == nil ->
          {:noreply, socket}

        profile.system ->
          {:noreply, put_flash(socket, :error, "System profiles cannot be deleted")}

        true ->
          case AdminApi.delete_role_profile(scope, profile.id) do
            {:ok, _} ->
              profiles = Enum.reject(socket.assigns.profiles, &(&1.id == profile.id))

              {:noreply,
               socket
               |> assign(:profiles, profiles)
               |> assign(:grid_template, grid_template(profiles))
               |> assign(
                 :dirty_profiles,
                 MapSet.delete(socket.assigns.dirty_profiles, profile.id)
               )
               |> assign(:confirm_delete_profile, nil)
               |> put_flash(:info, "Role profile deleted")}

            {:error, error} ->
              {:noreply, put_flash(socket, :error, format_ash_error(error))}
          end
      end
    end
  end

  def handle_event("open_delete_profile", %{"profile_id" => profile_id}, socket) do
    profile = find_profile(socket.assigns.profiles, profile_id)

    cond do
      not socket.assigns.can_rbac ->
        {:noreply, put_flash(socket, :error, "Not authorized to edit role profiles")}

      profile == nil ->
        {:noreply, socket}

      profile.system ->
        {:noreply, put_flash(socket, :error, "System profiles cannot be deleted")}

      true ->
        {:noreply, assign(socket, :confirm_delete_profile, profile)}
    end
  end

  def handle_event("close_delete_profile", _params, socket) do
    {:noreply, assign(socket, :confirm_delete_profile, nil)}
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :filtered_catalog, filter_catalog(assigns.catalog, assigns.filter))

    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <SettingsComponents.settings_shell current_path="/settings/auth/access">
        <div class="space-y-6">
          <div class="space-y-4">
            <SettingsComponents.settings_nav
              current_path="/settings/auth/access"
              current_scope={@current_scope}
            />
            <SettingsComponents.auth_nav
              current_path="/settings/auth/access"
              current_scope={@current_scope}
            />
          </div>

          <div class="card bg-neutral text-neutral-content shadow-sm">
            <div class="card-body gap-6">
              <div class="flex flex-col gap-4 lg:flex-row lg:items-center lg:justify-between">
                <div class="space-y-2">
                  <div class="badge badge-outline">RBAC Control Plane</div>
                  <h1 class="card-title text-2xl">Access Control</h1>
                  <p class="text-sm opacity-80">
                    Define how roles map to permissions and what users can see or change.
                  </p>
                </div>
                <div class="card-actions">
                  <.link navigate={~p"/settings/auth/users"} class="btn btn-sm btn-outline">
                    Manage Users
                  </.link>
                  <button class="btn btn-sm btn-primary" phx-click="open_new_profile">
                    New Profile
                  </button>
                </div>
              </div>

              <div class="stats stats-vertical lg:stats-horizontal bg-neutral/40 text-neutral-content">
                <div class="stat">
                  <div class="stat-title opacity-70">Roles</div>
                  <div class="stat-value text-xl">3</div>
                  <div class="stat-desc opacity-70">viewer, operator, admin</div>
                </div>
                <div class="stat">
                  <div class="stat-title opacity-70">Profiles</div>
                  <div class="stat-value text-xl">{length(@profiles)}</div>
                  <div class="stat-desc opacity-70">built-in and custom</div>
                </div>
                <div class="stat">
                  <div class="stat-title opacity-70">Permissions</div>
                  <div class="stat-value text-xl">{catalog_permission_count(@catalog)}</div>
                  <div class="stat-desc opacity-70">across the catalog</div>
                </div>
                <div class="stat">
                  <div class="stat-title opacity-70">Mappings</div>
                  <div class="stat-value text-xl">{length(@role_mappings)}</div>
                  <div class="stat-desc opacity-70">IdP claim rules</div>
                </div>
              </div>
            </div>
          </div>

          <div class="grid gap-6 xl:grid-cols-[minmax(0,1fr)_minmax(0,1.6fr)]">
            <section>
              <div class="card bg-base-100 shadow-sm border border-base-200">
                <div class="card-body gap-6">
                  <div class="flex items-start justify-between gap-4">
                    <div>
                      <h2 class="card-title">Sign-in Role Mapping</h2>
                      <p class="text-sm opacity-70">
                        Map identity claims to viewer/operator/admin. Custom profiles can override access per user.
                      </p>
                    </div>
                    <div class="badge badge-outline">Authorization</div>
                  </div>

                  <.form
                    :if={@can_auth}
                    for={@auth_form}
                    id="authorization-form"
                    phx-change="validate_auth"
                    phx-submit="save_auth"
                    class="space-y-5"
                  >
                    <.input
                      field={@auth_form[:default_role]}
                      type="select"
                      label="Default Role"
                      options={[{"viewer", "viewer"}, {"operator", "operator"}, {"admin", "admin"}]}
                      class="w-full select select-bordered"
                    />

                    <div class="divider divider-start">Role mappings</div>

                    <div class="flex items-center justify-between gap-3">
                      <div class="text-sm font-semibold">Rules</div>
                      <button type="button" class="btn btn-sm btn-outline" phx-click="add_mapping">
                        Add Mapping
                      </button>
                    </div>

                    <div class="hidden md:grid md:grid-cols-5 gap-2 text-xs opacity-70">
                      <div>Source</div>
                      <div>Claim</div>
                      <div>Value</div>
                      <div>Role</div>
                      <div></div>
                    </div>

                    <div class="space-y-2">
                      <%= for {mapping, index} <- Enum.with_index(@role_mappings) do %>
                        <div class="join join-vertical md:join-horizontal w-full">
                          <select
                            name={"mappings[#{index}][source]"}
                            class="select select-bordered select-sm join-item w-full"
                          >
                            <option value="groups" selected={mapping["source"] == "groups"}>
                              groups
                            </option>
                            <option
                              value="email_domain"
                              selected={mapping["source"] == "email_domain"}
                            >
                              email_domain
                            </option>
                            <option value="email" selected={mapping["source"] == "email"}>
                              email
                            </option>
                            <option value="claim" selected={mapping["source"] == "claim"}>
                              claim
                            </option>
                          </select>

                          <input
                            type="text"
                            name={"mappings[#{index}][claim]"}
                            class="input input-bordered input-sm join-item w-full"
                            placeholder="claim key"
                            value={mapping["claim"] || ""}
                            disabled={mapping["source"] != "claim"}
                          />

                          <input
                            type="text"
                            name={"mappings[#{index}][value]"}
                            class="input input-bordered input-sm join-item w-full"
                            placeholder={mapping_placeholder(mapping["source"])}
                            value={mapping["value"] || ""}
                          />

                          <select
                            name={"mappings[#{index}][role]"}
                            class="select select-bordered select-sm join-item w-full"
                          >
                            <option value="viewer" selected={mapping["role"] == "viewer"}>
                              viewer
                            </option>
                            <option value="operator" selected={mapping["role"] == "operator"}>
                              operator
                            </option>
                            <option value="admin" selected={mapping["role"] == "admin"}>admin</option>
                          </select>

                          <button
                            type="button"
                            class="btn btn-sm btn-ghost join-item"
                            phx-click="remove_mapping"
                            phx-value-index={index}
                          >
                            Remove
                          </button>
                        </div>
                      <% end %>

                      <%= if @role_mappings == [] do %>
                        <div class="text-sm opacity-70">
                          No mappings yet. Add a mapping to assign roles based on IdP claims.
                        </div>
                      <% end %>
                    </div>

                    <div class="card-actions justify-end">
                      <button class="btn btn-primary" type="submit">Save Mapping</button>
                    </div>
                  </.form>

                  <div :if={!@can_auth} class="text-sm opacity-70">
                    You do not have permission to edit authorization settings.
                  </div>
                </div>
              </div>
            </section>

            <section class="space-y-4">
              <div class="flex flex-wrap items-end justify-between gap-4">
                <div>
                  <h2 class="text-lg font-semibold">Role Profiles and Permissions</h2>
                  <p class="text-sm opacity-70">
                    Built-in profiles are clone-only. Customize copies and assign them to users.
                  </p>
                </div>
                <div class="flex items-center gap-2">
                  <.link navigate={~p"/settings/auth/users"} class="btn btn-sm btn-outline">
                    Assign Users
                  </.link>
                  <button class="btn btn-sm btn-primary" phx-click="open_new_profile">
                    New Profile
                  </button>
                </div>
              </div>

              <div class="grid gap-3 md:grid-cols-3">
                <%= for role <- ~w(viewer operator admin) do %>
                  <div class="card bg-base-100 shadow-sm border border-base-200">
                    <div class="card-body gap-3">
                      <div class="flex items-center justify-between">
                        <div class="text-sm font-semibold capitalize">{role}</div>
                        <div class="badge badge-outline">Built-in</div>
                      </div>
                      <div class="text-lg font-semibold">{role_profile_name(@profiles, role)}</div>
                      <div class="card-actions">
                        <button
                          class="btn btn-xs btn-outline"
                          phx-click="open_new_profile"
                          phx-value-clone-source-id={role_profile_id(@profiles, role)}
                        >
                          Clone and customize
                        </button>
                      </div>
                    </div>
                  </div>
                <% end %>
              </div>

              <div class="alert alert-info">
                <div>
                  <h3 class="font-bold">Legend</h3>
                  <div class="text-sm">
                    <span class="font-semibold">Role</span>
                    is the coarse label users receive at login (viewer/operator/admin).
                    <span class="font-semibold">Profile</span>
                    is the actual permission set. Users can be assigned a custom profile to override the role defaults.
                  </div>
                </div>
              </div>

              <div class="flex flex-wrap items-center justify-between gap-3">
                <label class="input input-bordered input-sm w-full max-w-xs">
                  <.icon name="hero-magnifying-glass" class="h-[1em] opacity-50" />
                  <input
                    type="search"
                    name="filter"
                    value={@filter}
                    placeholder="Filter permissions"
                    phx-change="filter_permissions"
                    phx-debounce="300"
                  />
                </label>
                <div class="text-xs opacity-70">
                  Showing {catalog_permission_count(@filtered_catalog)} permissions
                </div>
              </div>

              <div class="overflow-auto max-h-[70vh] rounded-box border border-base-content/5 bg-base-100">
                <div class="overflow-x-auto">
                  <table class="table table-sm table-pin-rows table-pin-cols">
                    <thead>
                      <tr>
                        <th class="min-w-[320px]">Permission</th>
                        <%= for profile <- @profiles do %>
                          <th class="min-w-[220px]">
                            <div class="flex flex-col gap-2">
                              <div class="flex items-center justify-between gap-2">
                                <span class="font-semibold">{profile.name}</span>
                                <span class={[
                                  "badge badge-xs",
                                  (profile.system && "badge-neutral") || "badge-outline"
                                ]}>
                                  {(profile.system && "Built-in") || "Custom"}
                                </span>
                              </div>
                              <div class="flex flex-wrap items-center gap-1">
                                <button
                                  class="btn btn-xs btn-outline"
                                  phx-click="open_new_profile"
                                  phx-value-clone-source-id={profile.id}
                                >
                                  Clone
                                </button>
                                <button
                                  :if={!profile.system}
                                  class="btn btn-xs btn-ghost"
                                  phx-click="open_delete_profile"
                                  phx-value-profile-id={profile.id}
                                >
                                  Delete
                                </button>
                                <button
                                  :if={MapSet.member?(@dirty_profiles, profile.id)}
                                  class="btn btn-xs btn-primary"
                                  phx-click="save_profile"
                                  phx-value-profile-id={profile.id}
                                >
                                  Save
                                </button>
                              </div>
                            </div>
                          </th>
                        <% end %>
                      </tr>
                    </thead>
                    <tbody>
                      <%= for section <- @filtered_catalog do %>
                        <tr class="bg-base-200/60">
                          <th class="font-semibold">{section_label(section)}</th>
                          <%= for profile <- @profiles do %>
                            <td class="text-center">
                              <label class="label cursor-pointer justify-center gap-2">
                                <span class="text-xs opacity-70">All</span>
                                <input
                                  type="checkbox"
                                  class="checkbox checkbox-xs"
                                  checked={section_all_selected?(profile, section)}
                                  disabled={profile.system}
                                  phx-click="toggle_section"
                                  phx-value-profile-id={profile.id}
                                  phx-value-section={section_id(section)}
                                />
                              </label>
                            </td>
                          <% end %>
                        </tr>
                        <%= for permission <- section_permissions(section) do %>
                          <tr>
                            <th>
                              <div class="font-medium">{permission_label(permission)}</div>
                              <div class="text-xs opacity-70">
                                {permission_description(permission)}
                              </div>
                              <div class="text-xs font-mono opacity-60">
                                {permission_key(permission)}
                              </div>
                            </th>
                            <%= for profile <- @profiles do %>
                              <td class="text-center">
                                <input
                                  type="checkbox"
                                  class={[
                                    "checkbox checkbox-sm",
                                    permission_assigned?(profile, permission_key(permission)) &&
                                      "checkbox-success"
                                  ]}
                                  checked={permission_assigned?(profile, permission_key(permission))}
                                  disabled={profile.system}
                                  phx-click="toggle_permission"
                                  phx-value-profile-id={profile.id}
                                  phx-value-permission={permission_key(permission)}
                                />
                              </td>
                            <% end %>
                          </tr>
                        <% end %>
                      <% end %>
                    </tbody>
                  </table>
                </div>
              </div>
            </section>
          </div>

          <div :if={@show_new_profile_form} class="modal modal-open">
            <div class="modal-box">
              <h3 class="text-lg font-bold">Create Role Profile</h3>
              <p class="py-2 text-sm opacity-70">
                Create a custom profile. Permissions are copied from the selected profile (if any).
              </p>

              <.form
                for={@new_profile_form}
                id="new-profile-form"
                phx-submit="create_profile"
                class="space-y-3"
              >
                <.input
                  field={@new_profile_form[:name]}
                  type="text"
                  label="Profile Name"
                  required
                  class="w-full input input-bordered"
                />
                <.input
                  field={@new_profile_form[:description]}
                  type="text"
                  label="Description"
                  class="w-full input input-bordered"
                />

                <div class="modal-action">
                  <button type="button" class="btn btn-ghost" phx-click="close_new_profile">
                    Cancel
                  </button>
                  <button type="submit" class="btn btn-primary">Create</button>
                </div>
              </.form>
            </div>
            <div class="modal-backdrop">
              <button type="button" phx-click="close_new_profile">close</button>
            </div>
          </div>

          <div :if={@confirm_delete_profile} class="modal modal-open">
            <div class="modal-box">
              <h3 class="text-lg font-bold">Delete Role Profile?</h3>
              <p class="py-2 text-sm opacity-70">
                This will permanently delete <span class="font-semibold">{@confirm_delete_profile.name}</span>.
                Users assigned to this profile will fall back to their role defaults.
              </p>
              <div class="modal-action">
                <button type="button" class="btn btn-ghost" phx-click="close_delete_profile">
                  Cancel
                </button>
                <button
                  type="button"
                  class="btn btn-error"
                  phx-click="delete_profile"
                  phx-value-profile-id={@confirm_delete_profile.id}
                >
                  Delete
                </button>
              </div>
            </div>
            <div class="modal-backdrop">
              <button type="button" phx-click="close_delete_profile">close</button>
            </div>
          </div>
        </div>
      </SettingsComponents.settings_shell>
    </Layouts.app>
    """
  end

  defp load_authorization_settings(scope, true) do
    case AdminApi.get_authorization_settings(scope) do
      {:ok, settings} -> {settings, nil}
      {:error, error} -> {%{default_role: :viewer, role_mappings: []}, format_ash_error(error)}
    end
  end

  defp load_authorization_settings(_scope, false) do
    {%{default_role: :viewer, role_mappings: []}, nil}
  end

  defp load_role_profiles(scope, true) do
    case AdminApi.list_role_profiles(scope) do
      {:ok, list} -> {list, nil}
      {:error, error} -> {[], format_ash_error(error)}
    end
  end

  defp load_role_profiles(_scope, false), do: {[], nil}

  defp load_catalog(scope, true) do
    case AdminApi.get_rbac_catalog(scope) do
      {:ok, list} -> {list, nil}
      {:error, error} -> {[], format_ash_error(error)}
    end
  end

  defp load_catalog(_scope, false), do: {[], nil}

  defp settings_form(settings) do
    %{
      "default_role" => Atom.to_string(settings.default_role || :viewer)
    }
  end

  defp normalize_auth_attrs(params, role_mappings) do
    with {:ok, default_role} <- normalize_role(params["default_role"]) do
      attrs = %{}

      attrs =
        if is_nil(default_role) do
          attrs
        else
          Map.put(attrs, :default_role, default_role)
        end

      attrs = Map.put(attrs, :role_mappings, role_mappings || [])

      {:ok, attrs}
    end
  end

  defp normalize_role(nil), do: {:ok, nil}
  defp normalize_role(""), do: {:ok, nil}
  defp normalize_role("viewer"), do: {:ok, :viewer}
  defp normalize_role("operator"), do: {:ok, :operator}
  defp normalize_role("admin"), do: {:ok, :admin}
  defp normalize_role(_), do: {:error, :invalid_role}

  defp normalize_role_mappings(mappings) when is_list(mappings) do
    mappings
    |> Enum.filter(&is_map/1)
    |> Enum.map(fn mapping ->
      %{
        "source" =>
          normalize_string(Map.get(mapping, "source") || Map.get(mapping, :source) || "groups"),
        "value" => Map.get(mapping, "value") || Map.get(mapping, :value) || "",
        "role" =>
          normalize_string(Map.get(mapping, "role") || Map.get(mapping, :role) || "viewer"),
        "claim" => Map.get(mapping, "claim") || Map.get(mapping, :claim) || ""
      }
    end)
  end

  defp normalize_role_mappings(_), do: []

  defp default_profile_form do
    %{"name" => "", "description" => ""}
  end

  defp grid_template(profiles) do
    columns = ["minmax(260px, 1.1fr)" | Enum.map(profiles, fn _ -> "minmax(160px, 1fr)" end)]
    Enum.join(columns, " ")
  end

  defp permissions_from_clone(_profiles, nil), do: []

  defp permissions_from_clone(profiles, clone_source_id) do
    case find_profile(profiles, clone_source_id) do
      nil -> []
      profile -> profile.permissions || []
    end
  end

  defp mappings_from_params(mappings) when is_map(mappings) do
    mappings
    |> Enum.sort_by(fn {index, _} -> parse_index(index) end)
    |> Enum.map(fn {_index, attrs} ->
      source = Map.get(attrs, "source") || "groups"
      claim = Map.get(attrs, "claim") || ""

      claim =
        if source == "claim" do
          claim
        else
          ""
        end

      %{
        "source" => source,
        "value" => Map.get(attrs, "value") || "",
        "role" => Map.get(attrs, "role") || "viewer",
        "claim" => claim
      }
    end)
  end

  defp mappings_from_params(_), do: []

  defp parse_index(value) when is_integer(value), do: value

  defp parse_index(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} -> int
      :error -> 0
    end
  end

  defp mapping_placeholder("groups"), do: "Network Ops"
  defp mapping_placeholder("email_domain"), do: "example.com"
  defp mapping_placeholder("email"), do: "user@example.com"
  defp mapping_placeholder("claim"), do: "claim value"
  defp mapping_placeholder(_), do: "value"

  defp maybe_assign_mappings(socket, nil), do: socket

  defp maybe_assign_mappings(socket, mappings),
    do: assign(socket, :role_mappings, mappings_from_params(mappings))

  defp normalize_string(value) when is_binary(value), do: value
  defp normalize_string(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_string(_), do: ""

  defp role_profile_name(profiles, role) do
    case role_profile_for_role(profiles, role) do
      nil -> "No profile"
      profile -> profile.name
    end
  end

  defp role_profile_id(profiles, role) do
    case role_profile_for_role(profiles, role) do
      nil -> nil
      profile -> profile.id
    end
  end

  defp role_profile_for_role(profiles, role) do
    Enum.find(profiles, fn profile ->
      profile.system_name == role or profile.system_name == to_string(role)
    end)
  end

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

  defp toggle_section_permissions(profile, section) do
    keys = section_permissions(section) |> Enum.map(&permission_key/1)
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

  defp permission_assigned?(profile, permission) do
    permission in (profile.permissions || [])
  end

  defp section_all_selected?(profile, section) do
    keys = section_permissions(section) |> Enum.map(&permission_key/1)
    permissions = MapSet.new(profile.permissions || [])
    keys != [] and Enum.all?(keys, &MapSet.member?(permissions, &1))
  end

  defp find_section(catalog, section_id) do
    Enum.find(catalog, fn section -> section_id(section) == section_id end)
  end

  defp filter_catalog(catalog, filter) do
    filter = String.trim(filter || "")

    if filter == "" do
      catalog
    else
      Enum.flat_map(catalog, fn section ->
        permissions =
          section_permissions(section)
          |> Enum.filter(fn permission ->
            label = permission_label(permission) |> String.downcase()
            key = permission_key(permission) |> String.downcase()

            String.contains?(label, String.downcase(filter)) or
              String.contains?(key, String.downcase(filter))
          end)

        if permissions == [] do
          []
        else
          [Map.put(section, :permissions, permissions)]
        end
      end)
    end
  end

  defp section_label(section), do: Map.get(section, :label) || Map.get(section, "label") || ""

  defp section_id(section), do: Map.get(section, :section) || Map.get(section, "section") || ""

  defp section_permissions(section) do
    Map.get(section, :permissions) || Map.get(section, "permissions") || []
  end

  defp permission_label(permission),
    do: Map.get(permission, :label) || Map.get(permission, "label") || ""

  defp permission_description(permission) do
    Map.get(permission, :description) || Map.get(permission, "description") || ""
  end

  defp permission_key(permission),
    do: Map.get(permission, :key) || Map.get(permission, "key") || ""

  defp catalog_permission_count(catalog) do
    catalog
    |> Enum.flat_map(&section_permissions/1)
    |> Enum.count()
  end

  defp maybe_put_flash(socket, nil), do: socket
  defp maybe_put_flash(socket, message), do: put_flash(socket, :error, message)

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
end
