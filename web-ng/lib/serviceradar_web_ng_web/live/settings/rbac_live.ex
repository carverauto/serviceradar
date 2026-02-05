defmodule ServiceRadarWebNGWeb.Settings.RbacLive do
  @moduledoc """
  RBAC policy editor for role profiles.
  """

  use ServiceRadarWebNGWeb, :live_view
  use Permit.Phoenix.LiveView,
    authorization_module: ServiceRadarWebNG.Authorization,
    resource_module: ServiceRadar.Identity.RoleProfile

  alias ServiceRadarWebNG.AdminApi
  alias ServiceRadarWebNGWeb.SettingsComponents

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    {profiles, profile_flash} =
      case AdminApi.list_role_profiles(scope) do
        {:ok, list} -> {list, nil}
        {:error, error} -> {[], format_ash_error(error)}
      end

    {catalog, catalog_flash} =
      case AdminApi.get_rbac_catalog(scope) do
        {:ok, list} -> {list, nil}
        {:error, error} -> {[], format_ash_error(error)}
      end

    {:ok,
     socket
     |> assign(:page_title, "RBAC")
     |> assign(:profiles, profiles)
     |> assign(:catalog, catalog)
     |> assign(:filter, "")
     |> assign(:dirty_profiles, MapSet.new())
     |> assign(:show_new_profile_modal, false)
     |> assign(:new_profile_form, to_form(default_profile_form(), as: :profile))
     |> assign(:clone_source_id, nil)
     |> maybe_put_flash(profile_flash)
     |> maybe_put_flash(catalog_flash)}
  end

  @impl true
  def handle_event("filter_permissions", %{"filter" => value}, socket) do
    {:noreply, assign(socket, :filter, value || "")}
  end

  def handle_event("toggle_permission", %{"profile_id" => profile_id, "permission" => permission}, socket) do
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

  def handle_event("save_profile", %{"profile_id" => profile_id}, socket) do
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

  def handle_event("open_new_profile", params, socket) do
    clone_source_id = Map.get(params, "clone_source_id")

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

    base_permissions = permissions_from_clone(socket.assigns.profiles, socket.assigns.clone_source_id)

    attrs = %{
      name: Map.get(params, "name"),
      description: Map.get(params, "description"),
      permissions: base_permissions
    }

    case AdminApi.create_role_profile(scope, attrs) do
      {:ok, profile} ->
        {:noreply,
         socket
         |> assign(:profiles, socket.assigns.profiles ++ [profile])
         |> assign(:show_new_profile_modal, false)
         |> assign(:clone_source_id, nil)
         |> put_flash(:info, "Role profile created")}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, format_ash_error(error))}
    end
  end

  def handle_event("delete_profile", %{"profile_id" => profile_id}, socket) do
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
            {:noreply,
             socket
             |> assign(:profiles, Enum.reject(socket.assigns.profiles, &(&1.id == profile.id)))
             |> assign(:dirty_profiles, MapSet.delete(socket.assigns.dirty_profiles, profile.id))
             |> put_flash(:info, "Role profile deleted")}

          {:error, error} ->
            {:noreply, put_flash(socket, :error, format_ash_error(error))}
        end
    end
  end

  @impl true
  def event_mapping do
    Permit.Phoenix.LiveView.default_event_mapping()
    |> Map.merge(%{
      "toggle_permission" => :update,
      "save_profile" => :update,
      "create_profile" => :create,
      "delete_profile" => :delete,
      "filter_permissions" => :read
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

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns, :filtered_catalog, filter_catalog(assigns.catalog, assigns.filter))

    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <SettingsComponents.settings_shell current_path="/settings/auth/rbac">
        <div class="space-y-4">
          <SettingsComponents.settings_nav current_path="/settings/auth/rbac" current_scope={@current_scope} />
          <SettingsComponents.auth_nav current_path="/settings/auth/rbac" current_scope={@current_scope} />
        </div>

        <div class="flex flex-wrap items-center justify-between gap-3">
          <div>
            <h1 class="text-xl font-semibold">RBAC Policy Editor</h1>
            <p class="text-sm text-base-content/60">
              Configure role profiles and permissions for each section of the platform.
            </p>
          </div>
          <button class="btn btn-primary" phx-click="open_new_profile">
            New Profile
          </button>
        </div>

        <div class="mt-6 space-y-4">
          <div class="flex flex-wrap items-center gap-3">
            <input
              type="text"
              name="filter"
              value={@filter}
              placeholder="Filter permissions"
              class="input input-bordered input-sm w-full max-w-xs"
              phx-change="filter_permissions"
            />
            <div class="text-xs text-base-content/60">
              Showing {catalog_permission_count(@filtered_catalog)} permissions
            </div>
          </div>

          <div class="overflow-x-auto rounded-xl border border-base-200">
            <table class="table table-sm">
              <thead>
                <tr>
                  <th class="min-w-[260px]">Permission</th>
                  <%= for profile <- @profiles do %>
                    <th class="min-w-[160px]">
                      <div class="flex flex-col gap-2">
                        <div class="flex items-center justify-between">
                          <div class="space-y-1">
                            <div class="text-sm font-semibold">
                              {profile.name}
                            </div>
                            <div class="text-xs text-base-content/60">
                              {profile.system && "Built-in" || "Custom"}
                            </div>
                          </div>
                          <div class="flex items-center gap-1">
                            <button
                              class="btn btn-ghost btn-xs"
                              phx-click="open_new_profile"
                              phx-value-clone-source-id={profile.id}
                            >
                              Clone
                            </button>
                            <button
                              :if={!profile.system}
                              class="btn btn-ghost btn-xs"
                              phx-click="delete_profile"
                              phx-value-profile-id={profile.id}
                            >
                              Delete
                            </button>
                          </div>
                        </div>
                        <div class="flex items-center gap-2">
                          <button
                            :if={MapSet.member?(@dirty_profiles, profile.id)}
                            class="btn btn-primary btn-xs"
                            phx-click="save_profile"
                            phx-value-profile-id={profile.id}
                          >
                            Save
                          </button>
                          <span :if={MapSet.member?(@dirty_profiles, profile.id)} class="text-xs text-warning">
                            Unsaved changes
                          </span>
                        </div>
                      </div>
                    </th>
                  <% end %>
                </tr>
              </thead>
              <tbody>
                <%= for section <- @filtered_catalog do %>
                  <tr class="bg-base-200/50">
                    <td colspan={Enum.count(@profiles) + 1} class="text-xs font-semibold uppercase">
                      {section_label(section)}
                    </td>
                  </tr>
                  <%= for permission <- section_permissions(section) do %>
                    <tr>
                      <td>
                        <div class="text-sm font-medium">{permission_label(permission)}</div>
                        <div class="text-xs text-base-content/60">{permission_description(permission)}</div>
                        <div class="text-[11px] text-base-content/40 font-mono">{permission_key(permission)}</div>
                      </td>
                      <%= for profile <- @profiles do %>
                        <td>
                          <input
                            type="checkbox"
                            class="checkbox checkbox-sm"
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

        <%= if @show_new_profile_modal do %>
          <dialog class="modal modal-open">
            <div class="modal-box">
              <h3 class="font-semibold text-lg">Create Role Profile</h3>
              <.form for={@new_profile_form} id="new-profile-form" phx-submit="create_profile" class="mt-4 space-y-4">
                <.input field={@new_profile_form[:name]} type="text" label="Profile Name" required />
                <.input field={@new_profile_form[:description]} type="text" label="Description" />
                <div class="text-xs text-base-content/60">
                  Permissions are copied from the selected profile (if any). You can edit them after creation.
                </div>
                <div class="modal-action">
                  <button type="button" class="btn btn-ghost" phx-click="close_new_profile">
                    Cancel
                  </button>
                  <button type="submit" class="btn btn-primary">Create</button>
                </div>
              </.form>
            </div>
          </dialog>
        <% end %>
      </SettingsComponents.settings_shell>
    </Layouts.app>
    """
  end

  defp default_profile_form do
    %{"name" => "", "description" => ""}
  end

  defp permissions_from_clone(_profiles, nil), do: []

  defp permissions_from_clone(profiles, clone_source_id) do
    case find_profile(profiles, clone_source_id) do
      nil -> []
      profile -> profile.permissions || []
    end
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

  defp permission_assigned?(profile, permission) do
    permission in (profile.permissions || [])
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

            String.contains?(label, String.downcase(filter)) or String.contains?(key, String.downcase(filter))
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
