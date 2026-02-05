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
        <div class="space-y-6">
          <div class="space-y-4">
            <SettingsComponents.settings_nav current_path="/settings/auth/users" current_scope={@current_scope} />
            <SettingsComponents.auth_nav current_path="/settings/auth/users" current_scope={@current_scope} />
          </div>

          <div class="flex flex-col gap-3 sm:flex-row sm:items-end sm:justify-between">
            <div class="space-y-1">
              <h1 class="text-2xl font-semibold">Accounts</h1>
              <p class="text-sm opacity-70">Assign roles and access profiles without touching raw JSON.</p>
            </div>
            <div class="flex items-center gap-2">
              <.link navigate={~p"/settings/auth/access"} class="btn btn-sm btn-outline">Access Control</.link>
              <span class="badge badge-outline">Total {@user_count}</span>
            </div>
          </div>

          <div class="grid gap-6 lg:grid-cols-[1.6fr_0.9fr]">
            <section class="space-y-3">
              <div class="overflow-x-auto rounded-box border border-base-content/5 bg-base-100">
                <%= if @user_count == 0 do %>
                  <div class="p-6 text-sm opacity-70">No users yet.</div>
                <% else %>
                  <table class="table table-zebra">
                    <thead>
                      <tr>
                        <th>Account</th>
                        <th>Email</th>
                        <th>Role</th>
                        <th>Access</th>
                        <th>Password</th>
                        <th>Last activity</th>
                        <th class="text-right">Action</th>
                      </tr>
                    </thead>
                    <tbody id="users" phx-update="stream">
                      <tr :for={{id, user} <- @streams.users} id={id}>
                        <td>
                          <div class="flex items-center gap-3">
                            <div class="avatar placeholder">
                              <div class="bg-neutral text-neutral-content w-10 rounded-full">
                                <span class="text-xs">{user_initials(user)}</span>
                              </div>
                            </div>
                            <div class="space-y-1">
                              <div class="font-semibold">{display_name(user)}</div>
                              <span class={status_class(user.status)}>{user.status}</span>
                            </div>
                          </div>
                        </td>
                        <td class="text-sm opacity-70">{user.email}</td>
                        <td>
                          <select
                            class="select select-bordered select-sm w-full"
                            phx-change="update_role"
                            phx-value-id={user.id}
                            name="role"
                          >
                            <option value="viewer" selected={user.role == :viewer}>viewer</option>
                            <option value="operator" selected={user.role == :operator}>operator</option>
                            <option value="admin" selected={user.role == :admin}>admin</option>
                          </select>
                        </td>
                        <td>
                          <select
                            class="select select-bordered select-sm w-full"
                            phx-change="update_role_profile"
                            phx-value-id={user.id}
                            name="role_profile_id"
                          >
                            <option value="" selected={is_nil(user.role_profile_id) or user.role_profile_id == ""}>
                              Use role default
                            </option>
                            <%= for {label, id} <- profile_options(@role_profiles) do %>
                              <option value={id} selected={user.role_profile_id == id}>{label}</option>
                            <% end %>
                          </select>
                        </td>
                        <td>
                          <span class="badge badge-ghost">{password_label(user)}</span>
                        </td>
                        <td class="text-xs opacity-70">{format_last_activity(user)}</td>
                        <td class="text-right">
                          <%= if user.status == :active do %>
                            <button class="btn btn-xs btn-ghost" phx-click="deactivate" phx-value-id={user.id}>
                              Deactivate
                            </button>
                          <% else %>
                            <button class="btn btn-xs btn-ghost" phx-click="reactivate" phx-value-id={user.id}>
                              Reactivate
                            </button>
                          <% end %>
                        </td>
                      </tr>
                    </tbody>
                  </table>
                <% end %>
              </div>
            </section>

            <section class="space-y-3">
              <div class="card bg-base-100 shadow-sm border border-base-content/5">
                <div class="card-body">
                  <h2 class="card-title">Add Account</h2>
                  <p class="text-sm opacity-70">Create a local operator or admin and assign a starting role.</p>

                  <.form for={@form} id="user-create-form" phx-change="validate" phx-submit="create" class="mt-2">
                    <.input field={@form[:email]} type="email" label="Email" required class="w-full input input-bordered" />
                    <.input field={@form[:display_name]} type="text" label="Display Name" class="w-full input input-bordered" />
                    <.input
                      field={@form[:role]}
                      type="select"
                      label="Role"
                      options={[{"viewer", "viewer"}, {"operator", "operator"}, {"admin", "admin"}]}
                      class="w-full select select-bordered"
                    />
                    <.input field={@form[:password]} type="password" label="Temporary Password" class="w-full input input-bordered" />

                    <div class="card-actions justify-end mt-3">
                      <button class="btn btn-primary btn-block" type="submit">Create Account</button>
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

  defp status_class(:active), do: "badge badge-success badge-sm"
  defp status_class(:inactive), do: "badge badge-warning badge-sm"
  defp status_class(_), do: "badge badge-ghost badge-sm"

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
  defp format_datetime(%NaiveDateTime{} = dt), do: Calendar.strftime(DateTime.from_naive!(dt, "Etc/UTC"), "%b %d, %Y %H:%M")
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
