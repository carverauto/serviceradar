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
      role_mappings = if mappings, do: mappings_from_params(mappings), else: socket.assigns.role_mappings

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

  def handle_event("toggle_permission", %{"profile_id" => profile_id, "permission" => permission}, socket) do
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

  def handle_event("toggle_section", %{"profile_id" => profile_id, "section" => section_id}, socket) do
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
      base_permissions = permissions_from_clone(socket.assigns.profiles, socket.assigns.clone_source_id)

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
               |> assign(:dirty_profiles, MapSet.delete(socket.assigns.dirty_profiles, profile.id))
               |> put_flash(:info, "Role profile deleted")}

            {:error, error} ->
              {:noreply, put_flash(socket, :error, format_ash_error(error))}
          end
      end
    end
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :filtered_catalog, filter_catalog(assigns.catalog, assigns.filter))

    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <SettingsComponents.settings_shell current_path="/settings/auth/access">
        <div class="space-y-6">
          <div class="space-y-4">
            <SettingsComponents.settings_nav current_path="/settings/auth/access" current_scope={@current_scope} />
            <SettingsComponents.auth_nav current_path="/settings/auth/access" current_scope={@current_scope} />
          </div>

          <section class="relative overflow-hidden rounded-[28px] bg-slate-950 text-white shadow-xl">
            <div class="absolute inset-0 bg-[radial-gradient(circle_at_top,_rgba(56,189,248,0.2),_transparent_55%)]"></div>
            <div class="absolute -left-24 -bottom-24 h-56 w-56 rounded-full bg-emerald-400/20 blur-3xl"></div>
            <div class="absolute -right-24 -top-24 h-56 w-56 rounded-full bg-indigo-500/25 blur-3xl"></div>
            <div class="relative z-10 grid gap-6 px-6 py-8 md:px-8 lg:grid-cols-[1.1fr_0.9fr]">
              <div class="space-y-4">
                <span class="inline-flex items-center gap-2 rounded-full border border-white/20 bg-white/10 px-3 py-1 text-[11px] uppercase tracking-[0.3em] text-white/70">
                  RBAC Control Plane
                </span>
                <h1 class="text-2xl font-semibold tracking-tight md:text-3xl">Access Control</h1>
                <p class="text-sm text-white/70">
                  Shape what each role can view, deploy, and change across ServiceRadar with granular permission
                  profiles.
                </p>
                <div class="flex flex-wrap items-center gap-2">
                  <.link
                    navigate={~p"/settings/auth/users"}
                    class="inline-flex items-center justify-center rounded-full border border-white/20 bg-white/10 px-4 py-2 text-xs font-semibold text-white transition hover:-translate-y-0.5 hover:bg-white/20"
                  >
                    Manage Users
                  </.link>
                  <button
                    class="inline-flex items-center justify-center rounded-full bg-white px-4 py-2 text-xs font-semibold text-slate-900 transition hover:-translate-y-0.5 hover:bg-slate-100"
                    phx-click="open_new_profile"
                  >
                    New Profile
                  </button>
                </div>
              </div>
              <div class="grid gap-3 sm:grid-cols-2">
                <div class="rounded-2xl border border-white/15 bg-white/5 p-4 backdrop-blur">
                  <div class="text-[11px] uppercase tracking-[0.2em] text-white/60">Roles</div>
                  <div class="mt-2 text-2xl font-semibold">3</div>
                  <p class="text-xs text-white/60 mt-1">Viewer, operator, admin.</p>
                </div>
                <div class="rounded-2xl border border-white/15 bg-white/5 p-4 backdrop-blur">
                  <div class="text-[11px] uppercase tracking-[0.2em] text-white/60">Profiles</div>
                  <div class="mt-2 text-2xl font-semibold">{length(@profiles)}</div>
                  <p class="text-xs text-white/60 mt-1">Cloneable baseline profiles.</p>
                </div>
                <div class="rounded-2xl border border-white/15 bg-white/5 p-4 backdrop-blur">
                  <div class="text-[11px] uppercase tracking-[0.2em] text-white/60">Permissions</div>
                  <div class="mt-2 text-2xl font-semibold">{catalog_permission_count(@catalog)}</div>
                  <p class="text-xs text-white/60 mt-1">Across every subsystem.</p>
                </div>
                <div class="rounded-2xl border border-white/15 bg-white/5 p-4 backdrop-blur">
                  <div class="text-[11px] uppercase tracking-[0.2em] text-white/60">Mappings</div>
                  <div class="mt-2 text-2xl font-semibold">{length(@role_mappings)}</div>
                  <p class="text-xs text-white/60 mt-1">IdP claim-based rules.</p>
                </div>
              </div>
            </div>
          </section>

          <div class="grid gap-6 xl:grid-cols-[minmax(0,1fr)_minmax(0,1.6fr)]">
            <section class="space-y-4">
              <div class="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
                <div class="flex flex-wrap items-start justify-between gap-4">
                  <div>
                    <div class="text-xs uppercase tracking-[0.2em] text-slate-400">Authorization</div>
                    <h2 class="text-lg font-semibold text-slate-900">Sign-in role mapping</h2>
                    <p class="text-sm text-slate-500 mt-1">
                      Map identity claims to the default viewer/operator/admin roles. Custom profiles can override
                      per-user access.
                    </p>
                  </div>
                  <span class="inline-flex items-center rounded-full border border-slate-200 bg-slate-50 px-3 py-1 text-[11px] font-semibold uppercase tracking-wide text-slate-500">
                    Default role
                  </span>
                </div>

                <.form
                  :if={@can_auth}
                  for={@auth_form}
                  id="authorization-form"
                  phx-change="validate_auth"
                  phx-submit="save_auth"
                  class="mt-6 space-y-6"
                >
                  <.input
                    field={@auth_form[:default_role]}
                    type="select"
                    label="Default Role"
                    options={[{"Viewer", "viewer"}, {"Operator", "operator"}, {"Admin", "admin"}]}
                    wrapper_class="space-y-1"
                    label_class="text-xs font-semibold uppercase tracking-wide text-slate-500"
                    class="w-full rounded-xl border border-slate-200 bg-white px-3 py-2 text-sm text-slate-900 focus:border-slate-400 focus:outline-none"
                  />

                  <div class="space-y-3">
                    <div class="flex items-center justify-between">
                      <div class="text-xs font-semibold uppercase tracking-wide text-slate-400">
                        Role Mappings
                      </div>
                      <button
                        type="button"
                        class="inline-flex items-center justify-center rounded-full border border-slate-200 bg-white px-3 py-1 text-xs font-semibold text-slate-600 transition hover:border-slate-300 hover:text-slate-900"
                        phx-click="add_mapping"
                      >
                        Add Mapping
                      </button>
                    </div>

                    <div class="grid grid-cols-[120px_140px_1fr_140px_auto] gap-2 text-[11px] uppercase tracking-wide text-slate-400">
                      <div>Source</div>
                      <div>Claim</div>
                      <div>Value</div>
                      <div>Role</div>
                      <div></div>
                    </div>

                    <div class="space-y-2">
                      <%= for {mapping, index} <- Enum.with_index(@role_mappings) do %>
                        <div class="grid grid-cols-[120px_140px_1fr_140px_auto] items-center gap-2 rounded-2xl border border-slate-200 bg-slate-50/60 p-3">
                          <select
                            name={"mappings[#{index}][source]"}
                            class="h-10 w-full rounded-xl border border-slate-200 bg-white px-3 text-sm text-slate-800 focus:border-slate-400 focus:outline-none"
                            value={mapping["source"]}
                          >
                            <option value="groups">groups</option>
                            <option value="email_domain">email_domain</option>
                            <option value="email">email</option>
                            <option value="claim">claim</option>
                          </select>

                          <input
                            type="text"
                            name={"mappings[#{index}][claim]"}
                            class="h-10 w-full rounded-xl border border-slate-200 bg-white px-3 text-sm text-slate-800 focus:border-slate-400 focus:outline-none disabled:border-slate-200 disabled:bg-slate-100 disabled:text-slate-400"
                            placeholder="claim key"
                            value={mapping["claim"] || ""}
                            disabled={mapping["source"] != "claim"}
                          />

                          <input
                            type="text"
                            name={"mappings[#{index}][value]"}
                            class="h-10 w-full rounded-xl border border-slate-200 bg-white px-3 text-sm text-slate-800 focus:border-slate-400 focus:outline-none"
                            placeholder={mapping_placeholder(mapping["source"])}
                            value={mapping["value"] || ""}
                          />

                          <select
                            name={"mappings[#{index}][role]"}
                            class="h-10 w-full rounded-xl border border-slate-200 bg-white px-3 text-sm text-slate-800 focus:border-slate-400 focus:outline-none"
                            value={mapping["role"]}
                          >
                            <option value="viewer">viewer</option>
                            <option value="operator">operator</option>
                            <option value="admin">admin</option>
                          </select>

                          <button
                            type="button"
                            class="inline-flex h-10 items-center justify-center rounded-xl border border-slate-200 bg-white px-3 text-[11px] font-semibold text-slate-600 transition hover:border-slate-300 hover:text-slate-900"
                            phx-click="remove_mapping"
                            phx-value-index={index}
                          >
                            Remove
                          </button>
                        </div>
                      <% end %>

                      <%= if @role_mappings == [] do %>
                        <div class="rounded-2xl border border-dashed border-slate-200 bg-white px-4 py-6 text-xs text-slate-500">
                          No mappings yet. Add a mapping to assign roles based on IdP claims.
                        </div>
                      <% end %>
                    </div>
                  </div>

                  <div class="flex items-center justify-between gap-3">
                    <div class="text-xs text-slate-500">
                      Changes apply immediately on the next login.
                    </div>
                    <button
                      class="inline-flex items-center justify-center rounded-full bg-slate-900 px-4 py-2 text-xs font-semibold text-white transition hover:-translate-y-0.5 hover:bg-slate-800"
                      type="submit"
                    >
                      Save Mapping
                    </button>
                  </div>
                </.form>

                <div :if={!@can_auth} class="mt-4 text-xs text-slate-500">
                  You do not have permission to edit authorization settings.
                </div>
              </div>
            </section>

            <section class="space-y-4">
              <div class="flex flex-wrap items-start justify-between gap-4">
                <div>
                  <div class="text-xs uppercase tracking-[0.2em] text-slate-400">Role Profiles</div>
                  <h2 class="text-lg font-semibold text-slate-900">Permissions grid</h2>
                  <p class="text-sm text-slate-500 mt-1">
                    Built-in profiles are clone-only. Customize copies and assign them directly to users.
                  </p>
                </div>
                <div class="flex flex-wrap items-center gap-2">
                  <.link
                    navigate={~p"/settings/auth/users"}
                    class="inline-flex items-center justify-center rounded-full border border-slate-200 bg-white px-3 py-1.5 text-xs font-semibold text-slate-600 transition hover:border-slate-300 hover:text-slate-900"
                  >
                    Assign Users
                  </.link>
                  <button
                    class="inline-flex items-center justify-center rounded-full bg-slate-900 px-3 py-1.5 text-xs font-semibold text-white transition hover:-translate-y-0.5 hover:bg-slate-800"
                    phx-click="open_new_profile"
                  >
                    New Profile
                  </button>
                </div>
              </div>

              <div class="grid gap-3 md:grid-cols-3">
                <%= for role <- ~w(viewer operator admin) do %>
                  <div class="rounded-3xl border border-slate-200 bg-white p-4 shadow-sm transition hover:-translate-y-0.5 hover:shadow-md">
                    <div class="flex items-center justify-between">
                      <div class="text-xs uppercase tracking-wide text-slate-400">{role}</div>
                      <span class="inline-flex items-center rounded-full border border-slate-200 bg-slate-50 px-2 py-0.5 text-[10px] font-semibold uppercase text-slate-500">
                        Built-in
                      </span>
                    </div>
                    <div class="mt-3 text-lg font-semibold text-slate-900">
                      {role_profile_name(@profiles, role)}
                    </div>
                    <div class="text-xs text-slate-500 mt-1">
                      Default profile for {role} role.
                    </div>
                    <button
                      class="mt-4 inline-flex items-center justify-center rounded-full border border-slate-200 bg-white px-3 py-1 text-[11px] font-semibold text-slate-600 transition hover:border-slate-300 hover:text-slate-900"
                      phx-click="open_new_profile"
                      phx-value-clone-source-id={role_profile_id(@profiles, role)}
                    >
                      Clone & Customize
                    </button>
                  </div>
                <% end %>
              </div>

              <div class="flex flex-wrap items-center justify-between gap-3">
                <div class="relative w-full max-w-xs">
                  <.icon
                    name="hero-magnifying-glass"
                    class="pointer-events-none absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-slate-400"
                  />
                  <input
                    type="text"
                    name="filter"
                    value={@filter}
                    placeholder="Filter permissions"
                    class="h-10 w-full rounded-full border border-slate-200 bg-white pl-9 pr-4 text-sm text-slate-800 focus:border-slate-400 focus:outline-none"
                    phx-change="filter_permissions"
                    phx-debounce="300"
                  />
                </div>
                <div class="text-xs text-slate-500">
                  Showing {catalog_permission_count(@filtered_catalog)} permissions
                </div>
              </div>

              <div class="rounded-3xl border border-slate-200 bg-white shadow-sm">
                <div class="overflow-auto max-h-[70vh]">
                  <div class="min-w-[780px]">
                    <div class="sticky top-0 z-10 border-b border-slate-200 bg-white/95 backdrop-blur">
                      <div
                        class="grid gap-3 px-4 py-3 text-xs font-semibold uppercase tracking-wide text-slate-500"
                        style={"grid-template-columns: #{@grid_template}"}
                      >
                        <div>Permission</div>
                        <%= for profile <- @profiles do %>
                          <div class="rounded-2xl border border-slate-200 bg-slate-50 px-3 py-2">
                            <div class="text-sm font-semibold text-slate-900">{profile.name}</div>
                            <div class="text-[11px] text-slate-400">
                              {profile.system && "Built-in" || "Custom"}
                            </div>
                            <div class="mt-2 flex flex-wrap items-center gap-1">
                              <button
                                class="inline-flex items-center justify-center rounded-full border border-slate-200 bg-white px-2 py-1 text-[11px] font-semibold text-slate-600 transition hover:border-slate-300 hover:text-slate-900"
                                phx-click="open_new_profile"
                                phx-value-clone-source-id={profile.id}
                              >
                                Clone
                              </button>
                              <button
                                :if={!profile.system}
                                class="inline-flex items-center justify-center rounded-full border border-slate-200 bg-white px-2 py-1 text-[11px] font-semibold text-slate-600 transition hover:border-slate-300 hover:text-slate-900"
                                phx-click="delete_profile"
                                phx-value-profile-id={profile.id}
                              >
                                Delete
                              </button>
                              <button
                                :if={MapSet.member?(@dirty_profiles, profile.id)}
                                class="inline-flex items-center justify-center rounded-full bg-slate-900 px-2 py-1 text-[11px] font-semibold text-white transition hover:-translate-y-0.5 hover:bg-slate-800"
                                phx-click="save_profile"
                                phx-value-profile-id={profile.id}
                              >
                                Save
                              </button>
                            </div>
                          </div>
                        <% end %>
                      </div>
                    </div>

                    <div class="divide-y divide-slate-200">
                      <%= for section <- @filtered_catalog do %>
                        <div class="bg-slate-50/70 px-4 py-2">
                          <div class="grid items-center gap-3" style={"grid-template-columns: #{@grid_template}"}>
                            <div class="text-xs font-semibold uppercase tracking-wide text-slate-500">
                              {section_label(section)}
                            </div>
                            <%= for profile <- @profiles do %>
                              <label class="flex items-center gap-2 text-xs text-slate-500">
                                <input
                                  type="checkbox"
                                  class="h-4 w-4 rounded border-slate-300 accent-slate-900"
                                  checked={section_all_selected?(profile, section)}
                                  disabled={profile.system}
                                  phx-click="toggle_section"
                                  phx-value-profile-id={profile.id}
                                  phx-value-section={section_id(section)}
                                />
                                <span>All</span>
                              </label>
                            <% end %>
                          </div>
                        </div>
                        <%= for permission <- section_permissions(section) do %>
                          <div class="px-4 py-3 transition hover:bg-slate-50/60">
                            <div class="grid items-center gap-3" style={"grid-template-columns: #{@grid_template}"}>
                              <div>
                                <div class="text-sm font-medium text-slate-900">
                                  {permission_label(permission)}
                                </div>
                                <div class="text-xs text-slate-500">
                                  {permission_description(permission)}
                                </div>
                                <div class="text-[11px] font-mono text-slate-400">
                                  {permission_key(permission)}
                                </div>
                              </div>
                              <%= for profile <- @profiles do %>
                                <div class={permission_cell_class(profile, permission_key(permission))}>
                                  <input
                                    type="checkbox"
                                    class="h-4 w-4 rounded border-slate-300 accent-slate-900"
                                    checked={permission_assigned?(profile, permission_key(permission))}
                                    disabled={profile.system}
                                    phx-click="toggle_permission"
                                    phx-value-profile-id={profile.id}
                                    phx-value-permission={permission_key(permission)}
                                  />
                                </div>
                              <% end %>
                            </div>
                          </div>
                        <% end %>
                      <% end %>
                    </div>
                  </div>
                </div>
              </div>

              <div :if={@show_new_profile_form} class="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
                <h3 class="text-base font-semibold text-slate-900">Create Role Profile</h3>
                <.form for={@new_profile_form} id="new-profile-form" phx-submit="create_profile" class="mt-4 space-y-3">
                  <.input
                    field={@new_profile_form[:name]}
                    type="text"
                    label="Profile Name"
                    required
                    wrapper_class="space-y-1"
                    label_class="text-xs font-semibold uppercase tracking-wide text-slate-500"
                    class="w-full rounded-xl border border-slate-200 bg-white px-3 py-2 text-sm text-slate-900 focus:border-slate-400 focus:outline-none"
                  />
                  <.input
                    field={@new_profile_form[:description]}
                    type="text"
                    label="Description"
                    wrapper_class="space-y-1"
                    label_class="text-xs font-semibold uppercase tracking-wide text-slate-500"
                    class="w-full rounded-xl border border-slate-200 bg-white px-3 py-2 text-sm text-slate-900 focus:border-slate-400 focus:outline-none"
                  />
                  <div class="text-xs text-slate-500">
                    Permissions are copied from the selected profile (if any). You can edit them after creation.
                  </div>
                  <div class="flex items-center gap-2">
                    <button
                      type="button"
                      class="inline-flex items-center justify-center rounded-full border border-slate-200 bg-white px-3 py-1.5 text-xs font-semibold text-slate-600 transition hover:border-slate-300 hover:text-slate-900"
                      phx-click="close_new_profile"
                    >
                      Cancel
                    </button>
                    <button
                      type="submit"
                      class="inline-flex items-center justify-center rounded-full bg-slate-900 px-3 py-1.5 text-xs font-semibold text-white transition hover:-translate-y-0.5 hover:bg-slate-800"
                    >
                      Create
                    </button>
                  </div>
                </.form>
              </div>
            </section>
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
        "source" => normalize_string(Map.get(mapping, "source") || Map.get(mapping, :source) || "groups"),
        "value" => Map.get(mapping, "value") || Map.get(mapping, :value) || "",
        "role" => normalize_string(Map.get(mapping, "role") || Map.get(mapping, :role) || "viewer"),
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
  defp maybe_assign_mappings(socket, mappings), do: assign(socket, :role_mappings, mappings_from_params(mappings))

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

  defp permission_cell_class(profile, permission) do
    base = "flex justify-center rounded-xl border p-2 transition"
    state = if permission_assigned?(profile, permission), do: "border-emerald-200 bg-emerald-50", else: "border-slate-200 bg-white"
    locked = if profile.system, do: "opacity-60", else: "hover:-translate-y-0.5 hover:border-slate-300 hover:shadow-sm"
    Enum.join([base, state, locked], " ")
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

  defp permission_label(permission), do: Map.get(permission, :label) || Map.get(permission, "label") || ""

  defp permission_description(permission) do
    Map.get(permission, :description) || Map.get(permission, "description") || ""
  end

  defp permission_key(permission), do: Map.get(permission, :key) || Map.get(permission, "key") || ""

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
