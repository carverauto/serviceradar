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

          <div class="flex flex-wrap items-center justify-between gap-4">
            <div>
              <h1 class="text-2xl font-semibold tracking-tight text-slate-900">Accounts</h1>
              <p class="text-sm text-slate-500">
                Assign roles and access profiles without touching raw JSON.
              </p>
            </div>
            <div class="flex items-center gap-2">
              <span class="inline-flex items-center rounded-full border border-slate-200 bg-white px-3 py-1 text-[11px] font-semibold uppercase tracking-wide text-slate-500">
                Total {@user_count}
              </span>
            </div>
          </div>

          <div class="grid gap-6 lg:grid-cols-[1.6fr_0.9fr]">
            <section class="space-y-4">
              <div class="overflow-hidden rounded-3xl border border-slate-200 bg-white shadow-sm">
                <div class="border-b border-slate-200 bg-slate-50/70 px-4 py-3">
                  <div class="grid grid-cols-[minmax(180px,1.2fr)_minmax(180px,1fr)_minmax(140px,0.7fr)_minmax(180px,0.9fr)_minmax(120px,0.7fr)_minmax(160px,0.9fr)_minmax(160px,1fr)] gap-3 text-[11px] font-semibold uppercase tracking-[0.2em] text-slate-400">
                    <div>Account</div>
                    <div>Email</div>
                    <div>Role</div>
                    <div>Access</div>
                    <div>Password</div>
                    <div>Last Activity</div>
                    <div class="text-right">Action</div>
                  </div>
                </div>

                <div id="users" phx-update="stream" class="divide-y divide-slate-200">
                  <div class="hidden px-4 py-8 text-sm text-slate-500 only:block">
                    No users yet.
                  </div>

                  <div
                    :for={{id, user} <- @streams.users}
                    id={id}
                    class="grid grid-cols-[minmax(180px,1.2fr)_minmax(180px,1fr)_minmax(140px,0.7fr)_minmax(180px,0.9fr)_minmax(120px,0.7fr)_minmax(160px,0.9fr)_minmax(160px,1fr)] items-center gap-3 px-4 py-4 text-sm transition hover:bg-slate-50/70"
                  >
                    <div class="flex items-center gap-3">
                      <div class="flex h-10 w-10 items-center justify-center rounded-full bg-slate-900 text-xs font-semibold uppercase text-white">
                        {user_initials(user)}
                      </div>
                      <div>
                        <div class="font-medium text-slate-900">
                          {display_name(user)}
                        </div>
                        <div class={["mt-1 inline-flex items-center rounded-full px-2 py-0.5 text-[11px] font-semibold uppercase", status_class(user.status)]}>
                          {user.status}
                        </div>
                      </div>
                    </div>

                    <div class="text-sm text-slate-600">{user.email}</div>

                    <div>
                      <select
                        class="h-9 w-full rounded-full border border-slate-200 bg-white px-3 text-sm text-slate-700 focus:border-slate-400 focus:outline-none"
                        phx-change="update_role"
                        phx-value-id={user.id}
                        name="role"
                        value={user.role}
                      >
                        <option value="viewer">viewer</option>
                        <option value="operator">operator</option>
                        <option value="admin">admin</option>
                      </select>
                    </div>

                    <div>
                      <select
                        class="h-9 w-full rounded-full border border-slate-200 bg-white px-3 text-sm text-slate-700 focus:border-slate-400 focus:outline-none"
                        phx-change="update_role_profile"
                        phx-value-id={user.id}
                        name="role_profile_id"
                        value={user.role_profile_id || ""}
                      >
                        <option value="">Use role default</option>
                        <%= for {label, id} <- profile_options(@role_profiles) do %>
                          <option value={id}>{label}</option>
                        <% end %>
                      </select>
                    </div>

                    <div class="text-xs font-semibold uppercase tracking-wide text-slate-500">
                      {password_label(user)}
                    </div>

                    <div class="text-xs text-slate-500">
                      {format_last_activity(user)}
                    </div>

                    <div class="flex items-center justify-end gap-2">
                      <%= if user.status == :active do %>
                        <button
                          class="inline-flex items-center justify-center rounded-full border border-slate-200 bg-white px-3 py-1 text-xs font-semibold text-slate-600 transition hover:border-slate-300 hover:text-slate-900"
                          phx-click="deactivate"
                          phx-value-id={user.id}
                        >
                          Deactivate
                        </button>
                      <% else %>
                        <button
                          class="inline-flex items-center justify-center rounded-full border border-slate-200 bg-white px-3 py-1 text-xs font-semibold text-slate-600 transition hover:border-slate-300 hover:text-slate-900"
                          phx-click="reactivate"
                          phx-value-id={user.id}
                        >
                          Reactivate
                        </button>
                      <% end %>
                    </div>
                  </div>
                </div>
              </div>
            </section>

            <section class="space-y-4">
              <div class="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
                <div>
                  <h2 class="text-lg font-semibold text-slate-900">Add Account</h2>
                  <p class="text-sm text-slate-500">
                    Create a local operator or admin and assign a starting role.
                  </p>
                </div>

                <.form for={@form} id="user-create-form" phx-change="validate" phx-submit="create" class="mt-4 space-y-3">
                  <.input
                    field={@form[:email]}
                    type="email"
                    label="Email"
                    required
                    wrapper_class="space-y-1"
                    label_class="text-xs font-semibold uppercase tracking-wide text-slate-500"
                    class="w-full rounded-xl border border-slate-200 bg-white px-3 py-2 text-sm text-slate-900 focus:border-slate-400 focus:outline-none"
                  />
                  <.input
                    field={@form[:display_name]}
                    type="text"
                    label="Display Name"
                    wrapper_class="space-y-1"
                    label_class="text-xs font-semibold uppercase tracking-wide text-slate-500"
                    class="w-full rounded-xl border border-slate-200 bg-white px-3 py-2 text-sm text-slate-900 focus:border-slate-400 focus:outline-none"
                  />
                  <.input
                    field={@form[:role]}
                    type="select"
                    label="Role"
                    options={[{"viewer", "viewer"}, {"operator", "operator"}, {"admin", "admin"}]}
                    wrapper_class="space-y-1"
                    label_class="text-xs font-semibold uppercase tracking-wide text-slate-500"
                    class="w-full rounded-xl border border-slate-200 bg-white px-3 py-2 text-sm text-slate-900 focus:border-slate-400 focus:outline-none"
                  />
                  <.input
                    field={@form[:password]}
                    type="password"
                    label="Temporary Password"
                    wrapper_class="space-y-1"
                    label_class="text-xs font-semibold uppercase tracking-wide text-slate-500"
                    class="w-full rounded-xl border border-slate-200 bg-white px-3 py-2 text-sm text-slate-900 focus:border-slate-400 focus:outline-none"
                  />

                  <button
                    class="mt-2 inline-flex w-full items-center justify-center rounded-full bg-slate-900 px-4 py-2 text-xs font-semibold text-white transition hover:-translate-y-0.5 hover:bg-slate-800"
                    type="submit"
                  >
                    Create Account
                  </button>
                </.form>
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

  defp status_class(:active), do: "border border-emerald-200 bg-emerald-50 text-emerald-600"
  defp status_class(:inactive), do: "border border-amber-200 bg-amber-50 text-amber-600"
  defp status_class(_), do: "border border-slate-200 bg-slate-50 text-slate-500"

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
