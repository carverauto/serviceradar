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

  @impl true
  def mount(_params, _session, socket) do
    socket = assign(socket, :page_title, "Auth Users")
    users = list_users(socket.assigns.current_scope)
    role_profiles = list_role_profiles(socket.assigns.current_scope)

    {:ok,
     socket
     |> assign(:form, to_form(default_user_form(), as: :user))
     |> assign(:role_profiles, role_profiles)
     |> assign(:user_count, length(users))
     |> stream(:users, users, reset: true)}
  end

  @impl true
  def handle_event("validate", %{"user" => params}, socket) do
    {:noreply, assign(socket, :form, to_form(params, as: :user))}
  end

  def handle_event("create", %{"user" => params}, socket) do
    scope = socket.assigns.current_scope

    attrs = %{
      email: params["email"],
      display_name: params["display_name"],
      role: normalize_role(params["role"])
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
      {:ok, user} ->
        {:noreply,
         socket
         |> put_flash(:info, "User created")
         |> assign(:form, to_form(default_user_form(), as: :user))
         |> assign(:user_count, socket.assigns.user_count + 1)
         |> stream_insert(:users, user, at: 0)}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, format_ash_error(error))}
    end
  end

  def handle_event("update_role", %{"id" => id, "role" => role}, socket) do
    scope = socket.assigns.current_scope

    case AdminApi.update_user(scope, id, %{role: normalize_role(role)}) do
      {:ok, updated} ->
        {:noreply,
         socket
         |> put_flash(:info, "Role updated")
         |> stream_insert(:users, updated)}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, format_ash_error(error))}
    end
  end

  def handle_event("update_role_profile", %{"id" => id, "role_profile_id" => profile_id}, socket) do
    scope = socket.assigns.current_scope
    profile_id = normalize_profile_id(profile_id)

    case AdminApi.update_user(scope, id, %{role_profile_id: profile_id}) do
      {:ok, updated} ->
        {:noreply,
         socket
         |> put_flash(:info, "Role profile updated")
         |> stream_insert(:users, updated)}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, format_ash_error(error))}
    end
  end

  def handle_event("deactivate", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope

    case AdminApi.deactivate_user(scope, id) do
      {:ok, updated} ->
        {:noreply,
         socket
         |> put_flash(:info, "User deactivated")
         |> stream_insert(:users, updated)}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, format_ash_error(error))}
    end
  end

  def handle_event("reactivate", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope

    case AdminApi.reactivate_user(scope, id) do
      {:ok, updated} ->
        {:noreply,
         socket
         |> put_flash(:info, "User reactivated")
         |> stream_insert(:users, updated)}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, format_ash_error(error))}
    end
  end

  @impl true
  def event_mapping do
    Permit.Phoenix.LiveView.default_event_mapping()
    |> Map.merge(%{
      "update_role" => :update,
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
      |> put_flash(:error, "Admin access required")
      |> push_navigate(to: ~p"/settings/profile")

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
                Assign roles and access profiles without touching raw JSON.
              </p>
            </div>
            <div class="flex items-center gap-2">
              <.link navigate={~p"/settings/auth/access"} class="btn btn-outline">
                <.icon name="hero-shield-check" class="size-4" /> Access Control
              </.link>
              <div class="badge badge-lg badge-neutral">Total {@user_count}</div>
            </div>
          </div>

          <div class="grid gap-8 xl:grid-cols-[1fr_400px]">
            <section class="min-w-0">
              <div class="card bg-base-100 shadow-sm border border-base-200">
                <div class="overflow-x-auto">
                  <table :if={@user_count > 0} class="table table-zebra w-full">
                    <thead>
                      <tr>
                        <th>Account</th>
                        <th>Role</th>
                        <th>Access Profile</th>
                        <th>Authentication</th>
                        <th>Last Activity</th>
                        <th class="text-right">Action</th>
                      </tr>
                    </thead>
                    <tbody id="users" phx-update="stream">
                      <tr :for={{id, user} <- @streams.users} id={id} class="group">
                        <td>
                          <div class="flex items-center gap-3">
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
                          </div>
                        </td>
                        <td>
                          <select
                            class="select select-bordered select-xs w-full max-w-[120px] font-medium"
                            phx-change="update_role"
                            phx-value-id={user.id}
                            name="role"
                          >
                            <option value="viewer" selected={user.role == :viewer}>Viewer</option>
                            <option value="operator" selected={user.role == :operator}>
                              Operator
                            </option>
                            <option value="admin" selected={user.role == :admin}>Admin</option>
                          </select>
                        </td>
                        <td>
                          <div class="flex items-center gap-2">
                            <select
                              class={[
                                "select select-bordered select-xs w-full font-medium",
                                (is_nil(user.role_profile_id) or user.role_profile_id == "") &&
                                  "opacity-70"
                              ]}
                              phx-change="update_role_profile"
                              phx-value-id={user.id}
                              name="role_profile_id"
                            >
                              <option
                                value=""
                                selected={is_nil(user.role_profile_id) or user.role_profile_id == ""}
                              >
                                (Role Default)
                              </option>
                              <%= for {label, id} <- profile_options(@role_profiles) do %>
                                <option value={id} selected={user.role_profile_id == id}>
                                  {label}
                                </option>
                              <% end %>
                            </select>
                            <.link
                              :if={user.role_profile_id && user.role_profile_id != ""}
                              navigate={~p"/settings/auth/access?filter=#{user.role_profile_id}"}
                              class="btn btn-xs btn-ghost btn-square"
                              data-tip="View permissions"
                            >
                              <.icon name="hero-arrow-top-right-on-square" class="size-3" />
                            </.link>
                          </div>
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
                          <div class="dropdown dropdown-end">
                            <button tabindex="0" class="btn btn-ghost btn-xs btn-square">
                              <.icon name="hero-ellipsis-vertical" class="size-4" />
                            </button>
                            <ul
                              tabindex="0"
                              class="dropdown-content z-[1] menu p-2 shadow bg-base-100 rounded-box w-40 border border-base-200"
                            >
                              <%= if user.status == :active do %>
                                <li>
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

            <section class="space-y-6">
              <div class="card bg-base-100 shadow-sm border border-base-200 sticky top-6">
                <div class="card-body">
                  <div class="flex items-center gap-3 mb-2">
                    <div class="p-2 bg-primary/10 rounded-lg text-primary">
                      <.icon name="hero-user-plus" class="size-5" />
                    </div>
                    <h2 class="card-title text-lg">Add Account</h2>
                  </div>
                  <p class="text-sm opacity-70 mb-4">
                    Create a local operator or admin and assign a starting role.
                  </p>

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
                      field={@form[:role]}
                      type="select"
                      label="Role"
                      options={[{"Viewer", "viewer"}, {"Operator", "operator"}, {"Admin", "admin"}]}
                      class="select select-bordered w-full"
                    />
                    <.input
                      field={@form[:password]}
                      type="password"
                      label="Temporary Password"
                      placeholder="••••••••"
                      class="input input-bordered w-full"
                    />

                    <div class="card-actions justify-end mt-4">
                      <button class="btn btn-primary btn-block" type="submit">
                        Create Account
                      </button>
                    </div>
                  </.form>
                </div>
              </div>
            </section>
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

  defp normalize_role(nil), do: :viewer
  defp normalize_role(""), do: :viewer
  defp normalize_role("viewer"), do: :viewer
  defp normalize_role("operator"), do: :operator
  defp normalize_role("admin"), do: :admin
  defp normalize_role(role) when is_atom(role), do: role
  defp normalize_role(_), do: :viewer

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
      label = if profile.system, do: "#{profile.name} (built-in)", else: profile.name
      {label, profile.id}
    end)
  end

  defp default_user_form do
    %{
      "email" => "",
      "display_name" => "",
      "role" => "viewer",
      "password" => ""
    }
  end

  defp user_initials(user) do
    base = display_name(user)

    base
    |> String.split(~r/\s+/, trim: true)
    |> Enum.take(2)
    |> Enum.map(fn segment -> segment |> String.first() |> to_string() end)
    |> Enum.join()
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
    case user.last_auth_method do
      :password -> "Local"
      :oidc -> "SSO (OIDC)"
      :saml -> "SSO (SAML)"
      :gateway -> "Gateway"
      :api_token -> "API Token"
      :oauth_client -> "OAuth"
      _ -> "—"
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
