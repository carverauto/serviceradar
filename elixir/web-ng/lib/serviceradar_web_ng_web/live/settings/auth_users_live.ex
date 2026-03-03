defmodule ServiceRadarWebNGWeb.Settings.AuthUsersLive do
  @moduledoc """
  Admin user management view.
  """

  use ServiceRadarWebNGWeb, :live_view

  use Permit.Phoenix.LiveView,
    authorization_module: ServiceRadarWebNG.Authorization,
    resource_module: ServiceRadar.Identity.User

  alias ServiceRadarWebNG.AdminApi
  alias ServiceRadarWebNGWeb.SettingsComponents
  alias Phoenix.LiveView.JS

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    if ServiceRadarWebNG.RBAC.can?(scope, "settings.auth.manage") do
      socket = assign(socket, :page_title, "Auth Users")
      users = list_users(scope)
      role_profiles = list_role_profiles(scope)
      default_profile_id = default_system_profile_id(role_profiles, "viewer")
      active_admin_count = count_active_admins(users)

      {:ok,
       socket
       |> assign(:form, to_form(default_user_form(default_profile_id), as: :user))
       |> assign(:show_add_user_modal, false)
       |> assign(:role_profiles, role_profiles)
       |> assign(:user_count, length(users))
       |> assign(:active_admin_count, active_admin_count)
       |> stream(:users, users, reset: true)}
    else
      {:ok,
       socket
       |> put_flash(:error, "You don't have permission to access Settings.")
       |> push_navigate(to: ~p"/analytics")}
    end
  end

  @impl true
  def handle_event("validate", %{"user" => params}, socket) do
    {:noreply, assign(socket, :form, to_form(params, as: :user))}
  end

  def handle_event("open_add_user_modal", _params, socket) do
    {:noreply, assign(socket, :show_add_user_modal, true)}
  end

  def handle_event("close_add_user_modal", _params, socket) do
    {:noreply, assign(socket, :show_add_user_modal, false)}
  end

  def handle_event("create", %{"user" => params}, socket) do
    scope = socket.assigns.current_scope

    {role, role_profile_id} =
      resolve_access_profile(
        params["role_profile_id"],
        params["role"],
        socket.assigns.role_profiles
      )

    attrs = %{
      email: params["email"],
      display_name: params["display_name"],
      role: role,
      role_profile_id: role_profile_id
    }

    attrs =
      if password = params["password"] do
        if password == "" do
          attrs
        else
          Map.put(attrs, :password, password)
        end
      else
        attrs
      end

    case AdminApi.create_user(scope, attrs) do
      {:ok, _user} ->
        {:noreply, reload_users(socket |> put_flash(:info, "User created"))}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, format_ash_error(error))}
    end
  end

  def handle_event(
        "update_role_profile",
        %{"user_id" => id, "role_profile_id" => profile_id},
        socket
      ) do
    scope = socket.assigns.current_scope
    profile_id = normalize_profile_id(profile_id)

    {role, profile_id} = resolve_access_profile(profile_id, nil, socket.assigns.role_profiles)

    case AdminApi.update_user(scope, id, %{role_profile_id: profile_id, role: role}) do
      {:ok, _updated} ->
        {:noreply,
         socket
         |> put_flash(:info, "Access updated")
         |> reload_users()}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, format_ash_error(error))}
    end
  end

  def handle_event("deactivate", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope

    case AdminApi.deactivate_user(scope, id) do
      {:ok, _updated} ->
        {:noreply,
         socket
         |> put_flash(:info, "User deactivated")
         |> reload_users()}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, format_ash_error(error))}
    end
  end

  def handle_event("reactivate", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope

    case AdminApi.reactivate_user(scope, id) do
      {:ok, _updated} ->
        {:noreply,
         socket
         |> put_flash(:info, "User reactivated")
         |> reload_users()}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, format_ash_error(error))}
    end
  end

  @impl true
  def event_mapping do
    Permit.Phoenix.LiveView.default_event_mapping()
    |> Map.merge(%{
      "update_role_profile" => :update,
      "deactivate" => :update,
      "reactivate" => :update,
      "validate" => :read
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
      |> put_flash(:error, "You don't have permission to access Settings.")
      |> push_navigate(to: ~p"/analytics")

    {:halt, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <SettingsComponents.settings_shell current_path="/settings/auth/users">
        <div class="space-y-8">
          <div class="space-y-4">
            <SettingsComponents.settings_nav
              current_path="/settings/auth/users"
              current_scope={@current_scope}
            />
            <SettingsComponents.auth_nav
              current_path="/settings/auth/users"
              current_scope={@current_scope}
            />
          </div>

          <div class="flex flex-col gap-4 sm:flex-row sm:items-end sm:justify-between">
            <div class="space-y-1">
              <h1 class="text-2xl font-bold">Accounts</h1>
              <p class="text-base opacity-70">
                Assign roles.
              </p>
            </div>
            <div class="flex items-center gap-2">
              <button class="btn btn-primary" phx-click="open_add_user_modal" type="button">
                <.icon name="hero-user-plus" class="size-4" /> Add account
              </button>
              <div class="badge badge-lg badge-neutral">Total {@user_count}</div>
            </div>
          </div>

          <section class="min-w-0">
            <div class="card bg-base-100 border border-base-200">
              <div class="overflow-x-auto">
                <table :if={@user_count > 0} class="table table-zebra w-full">
                  <thead>
                    <tr>
                      <th>Account</th>
                      <th>Access Profile</th>
                      <th>Authentication</th>
                      <th>Last Activity</th>
                      <th class="text-right">Action</th>
                    </tr>
                  </thead>
                  <tbody id="users" phx-update="stream">
                    <tr :for={{id, user} <- @streams.users} id={id} class="group">
                      <td>
                        <button
                          type="button"
                          phx-click={JS.navigate(~p"/settings/auth/users/#{user.id}")}
                          class="flex items-center gap-3 hover:opacity-90 text-left"
                        >
                          <div class="avatar placeholder">
                            <div class="bg-primary/10 text-primary w-10 rounded-full">
                              <span class="text-xs font-bold">{user_initials(user)}</span>
                            </div>
                          </div>
                          <div class="flex flex-col">
                            <div class="font-bold text-sm">{display_name(user)}</div>
                            <div class="text-xs opacity-60 font-mono scale-90 origin-left">
                              {user.email}
                            </div>
                          </div>
                          <%= if user.status != :active do %>
                            <span class="badge badge-warning badge-xs">inactive</span>
                          <% end %>
                        </button>
                      </td>
                      <td>
                        <form phx-change="update_role_profile" class="flex items-center gap-2">
                          <input type="hidden" name="user_id" value={user.id} />
                          <select
                            class={[
                              "select select-bordered select-xs w-full font-medium",
                              is_nil(effective_profile_id(user, @role_profiles)) && "opacity-70"
                            ]}
                            name="role_profile_id"
                          >
                            <%= for {label, id} <- profile_options(@role_profiles) do %>
                              <option
                                value={id}
                                selected={effective_profile_id(user, @role_profiles) == id}
                              >
                                {label}
                              </option>
                            <% end %>
                          </select>
                        </form>
                      </td>
                      <td>
                        <div class="badge badge-ghost badge-sm font-mono text-xs">
                          {password_label(user)}
                        </div>
                      </td>
                      <td class="text-xs font-mono opacity-70 whitespace-nowrap">
                        {format_last_activity(user)}
                      </td>
                      <td class="text-right">
                        <%= if show_actions_menu?(user, @active_admin_count) do %>
                          <div class="dropdown dropdown-end">
                            <button tabindex="0" class="btn btn-ghost btn-xs btn-square">
                              <.icon name="hero-ellipsis-vertical" class="size-4" />
                            </button>
                            <ul
                              tabindex="0"
                              class="dropdown-content z-[1] menu p-2 shadow bg-base-100 rounded-box w-40 border border-base-200"
                            >
                              <%= if user.status == :active do %>
                                <li :if={can_deactivate?(user, @active_admin_count)}>
                                  <button
                                    class="text-error"
                                    phx-click="deactivate"
                                    phx-value-id={user.id}
                                  >
                                    <.icon name="hero-no-symbol" class="size-4" /> Deactivate
                                  </button>
                                </li>
                              <% else %>
                                <li>
                                  <button
                                    class="text-success"
                                    phx-click="reactivate"
                                    phx-value-id={user.id}
                                  >
                                    <.icon name="hero-check-circle" class="size-4" /> Reactivate
                                  </button>
                                </li>
                              <% end %>
                            </ul>
                          </div>
                        <% end %>
                      </td>
                    </tr>
                  </tbody>
                </table>
                <div :if={@user_count == 0} class="p-12 text-center opacity-50 space-y-2">
                  <.icon name="hero-users" class="size-8 mx-auto mb-2" />
                  <p class="font-medium">No accounts found.</p>
                  <p class="text-sm">Create an account to get started.</p>
                </div>
              </div>
            </div>
          </section>
        </div>

        <div
          :if={@show_add_user_modal}
          class="modal modal-open"
          phx-window-keydown="close_add_user_modal"
          phx-key="escape"
        >
          <div class="modal-box">
            <div class="flex items-start justify-between gap-4">
              <div class="space-y-1">
                <h3 class="text-lg font-bold">Add account</h3>
                <p class="text-sm opacity-70">
                  Create a local user and assign a starting role.
                </p>
              </div>
              <button
                class="btn btn-ghost btn-sm btn-square"
                phx-click="close_add_user_modal"
                type="button"
              >
                <.icon name="hero-x-mark" class="size-4" />
              </button>
            </div>

            <div class="mt-6">
              <.form
                for={@form}
                id="user-create-form"
                phx-change="validate"
                phx-submit="create"
                class="space-y-4"
              >
                <.input
                  field={@form[:email]}
                  type="email"
                  label="Email Address"
                  placeholder="user@example.com"
                  required
                  class="input input-bordered w-full"
                />
                <.input
                  field={@form[:display_name]}
                  type="text"
                  label="Display Name"
                  placeholder="Jane Doe"
                  class="input input-bordered w-full"
                />
                <.input
                  field={@form[:role_profile_id]}
                  type="select"
                  label="Access Profile"
                  options={profile_options(@role_profiles)}
                  class="select select-bordered w-full"
                />
                <.input
                  field={@form[:password]}
                  type="password"
                  label="Temporary Password"
                  placeholder="••••••••"
                  class="input input-bordered w-full"
                />

                <div class="modal-action">
                  <button class="btn btn-outline" phx-click="close_add_user_modal" type="button">
                    Cancel
                  </button>
                  <button class="btn btn-primary" type="submit">
                    Create account
                  </button>
                </div>
              </.form>
            </div>
          </div>

          <div class="modal-backdrop">
            <button phx-click="close_add_user_modal" type="button">close</button>
          </div>
        </div>
      </SettingsComponents.settings_shell>
    </Layouts.app>
    """
  end

  defp list_users(scope) do
    case AdminApi.list_users(scope, %{}) do
      {:ok, users} -> users
      {:error, _} -> []
    end
  end

  defp normalize_profile_id(nil), do: nil
  defp normalize_profile_id(""), do: nil
  defp normalize_profile_id(value), do: value

  defp list_role_profiles(scope) do
    case AdminApi.list_role_profiles(scope) do
      {:ok, profiles} -> profiles
      {:error, _} -> []
    end
  end

  defp profile_options(profiles) do
    profiles
    |> Enum.sort_by(fn profile -> {profile.system || false, profile.name} end, :desc)
    |> Enum.map(fn profile ->
      label = if profile.system, do: "#{profile.name} (system)", else: profile.name
      {label, profile.id}
    end)
  end

  defp default_user_form(default_profile_id) do
    %{
      "email" => "",
      "display_name" => "",
      "role_profile_id" => default_profile_id || "",
      "password" => ""
    }
  end

  defp user_initials(user) do
    base = display_name(user)

    base
    |> String.split(~r/\s+/, trim: true)
    |> Enum.take(2)
    |> Enum.map_join(fn segment -> segment |> String.first() |> to_string() end)
    |> String.upcase()
    |> case do
      "" -> "SR"
      initials -> initials
    end
  end

  defp display_name(user) do
    cond do
      is_binary(user.display_name) and user.display_name != "" ->
        user.display_name

      is_binary(user.email) and user.email != "" ->
        user.email
        |> String.split("@")
        |> List.first()
        |> to_string()
        |> String.capitalize()

      true ->
        "Unknown"
    end
  end

  defp password_label(user) do
    # `last_auth_method` is only populated after an auth event; for newly created
    # users we derive a reasonable label from server-provided hints.
    case user.last_auth_method do
      :password ->
        "Local"

      :oidc ->
        "SSO (OIDC)"

      :saml ->
        "SSO (SAML)"

      :gateway ->
        "Gateway"

      :api_token ->
        "API Token"

      :oauth_client ->
        "OAuth"

      _ ->
        cond do
          Map.get(user, :has_password) -> "Local"
          Map.get(user, :has_external_id) -> "SSO"
          true -> "—"
        end
    end
  end

  defp format_last_activity(user) do
    [user.last_login_at, user.authenticated_at]
    |> Enum.find(fn value -> not is_nil(value) end)
    |> format_datetime()
  end

  defp format_datetime(nil), do: "—"

  defp format_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _} -> Calendar.strftime(dt, "%b %d, %Y %H:%M")
      _ -> format_naive_datetime(value)
    end
  end

  defp format_datetime(%DateTime{} = dt), do: Calendar.strftime(dt, "%b %d, %Y %H:%M")

  defp format_datetime(%NaiveDateTime{} = dt),
    do: Calendar.strftime(DateTime.from_naive!(dt, "Etc/UTC"), "%b %d, %Y %H:%M")

  defp format_datetime(_), do: "—"

  defp format_naive_datetime(value) when is_binary(value) do
    case NaiveDateTime.from_iso8601(value) do
      {:ok, ndt} -> Calendar.strftime(DateTime.from_naive!(ndt, "Etc/UTC"), "%b %d, %Y %H:%M")
      _ -> "—"
    end
  end

  defp format_ash_error(%Ash.Error.Invalid{errors: errors}) do
    Enum.map_join(errors, ", ", fn
      %{message: message} -> message
      _ -> "Validation error"
    end)
  end

  defp format_ash_error({:http_error, status, body}) do
    base =
      case body do
        %{"message" => message} when is_binary(message) and message != "" -> message
        %{"error" => error} when is_binary(error) and error != "" -> error
        _ -> "Request failed"
      end

    details = format_http_error_details(body)

    if details != "" do
      "HTTP #{status}: #{base} (#{details})"
    else
      "HTTP #{status}: #{base}"
    end
  end

  defp format_ash_error(_), do: "Unexpected error"

  defp format_http_error_details(%{"details" => list}) when is_list(list) do
    list
    |> Enum.map(&format_http_error_detail_item/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("; ")
  end

  defp format_http_error_details(_), do: ""

  defp format_http_error_detail_item(%{"field" => field, "message" => message}) do
    field = to_string(field)
    message = to_string(message)
    if field != "", do: "#{field}: #{message}", else: message
  end

  defp format_http_error_detail_item(%{"message" => message}), do: to_string(message)
  defp format_http_error_detail_item(other), do: inspect(other)

  defp effective_profile_id(user, profiles) do
    profile_id = Map.get(user, :role_profile_id)

    if is_binary(profile_id) and profile_id != "" do
      profile_id
    else
      role = Map.get(user, :role, :viewer)
      system_name = to_string(role)

      case Enum.find(profiles, &(&1.system_name == system_name)) do
        nil -> nil
        profile -> profile.id
      end
    end
  end

  # Backwards-compat: accept either legacy `role` string or new `role_profile_id`.
  # We always persist both `role` and `role_profile_id` so the app doesn't rely on
  # base role for permissions, but legacy role checks won't accidentally escalate.
  defp resolve_access_profile(profile_id, legacy_role, profiles) do
    profile_id = normalize_profile_id(profile_id)

    if is_binary(profile_id) and profile_id != "" do
      resolve_profile_from_id(profile_id, profiles)
    else
      resolve_profile_from_legacy_role(legacy_role, profiles)
    end
  end

  defp resolve_profile_from_id(profile_id, profiles) do
    case Enum.find(profiles, &(&1.id == profile_id)) do
      nil ->
        {:viewer, nil}

      profile ->
        role = role_from_profile(profile)
        {role, profile.id}
    end
  end

  defp resolve_profile_from_legacy_role(legacy_role, profiles) do
    role = role_from_legacy(legacy_role)
    system_name = to_string(role)

    profile =
      Enum.find(profiles, fn profile ->
        profile.system and to_string(profile.system_name || "") == system_name
      end)

    {role, if(profile, do: profile.id, else: nil)}
  end

  defp role_from_legacy("admin"), do: :admin
  defp role_from_legacy("operator"), do: :operator
  defp role_from_legacy("helpdesk"), do: :helpdesk
  defp role_from_legacy("viewer"), do: :viewer
  defp role_from_legacy(_), do: :viewer

  defp role_from_profile(profile) do
    case to_string(profile.system_name || "") do
      "admin" -> :admin
      "operator" -> :operator
      "helpdesk" -> :helpdesk
      "viewer" -> :viewer
      _ -> :viewer
    end
  end

  defp default_system_profile_id(profiles, system_name) when is_list(profiles) do
    system_name = to_string(system_name || "")

    case Enum.find(profiles, fn profile -> to_string(profile.system_name || "") == system_name end) do
      nil -> nil
      profile -> profile.id
    end
  end

  defp count_active_admins(users) when is_list(users) do
    Enum.count(users, fn user -> user.role == :admin and user.status == :active end)
  end

  defp can_deactivate?(user, active_admin_count) do
    cond do
      user.status != :active ->
        false

      user.role != :admin ->
        true

      # Never offer deactivation for the bootstrap/root account in demo installs.
      to_string(user.email || "") == "root@localhost" ->
        false

      # Last-active-admin protection (server-side also enforces this).
      is_integer(active_admin_count) and active_admin_count <= 1 ->
        false

      true ->
        true
    end
  end

  defp reload_users(socket) do
    scope = socket.assigns.current_scope
    users = list_users(scope)
    active_admin_count = count_active_admins(users)
    default_profile_id = default_system_profile_id(socket.assigns.role_profiles, "viewer")

    socket
    |> assign(:form, to_form(default_user_form(default_profile_id), as: :user))
    |> assign(:show_add_user_modal, false)
    |> assign(:user_count, length(users))
    |> assign(:active_admin_count, active_admin_count)
    |> stream(:users, users, reset: true)
  end

  defp show_actions_menu?(user, active_admin_count) do
    if user.status == :active do
      can_deactivate?(user, active_admin_count)
    else
      true
    end
  end
end
