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

    {:ok,
     socket
     |> assign(:form, to_form(default_user_form(), as: :user))
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
        <div class="space-y-4">
          <SettingsComponents.settings_nav current_path="/settings/auth/users" current_scope={@current_scope} />
          <SettingsComponents.auth_nav current_path="/settings/auth/users" />
        </div>

        <div class="grid gap-6 lg:grid-cols-[1.2fr,0.8fr]">
          <section class="space-y-4">
            <div class="flex items-center justify-between">
              <div>
                <h1 class="text-xl font-semibold">Users</h1>
                <p class="text-sm text-base-content/60">
                  Manage access for your ServiceRadar instance.
                </p>
              </div>
            </div>

            <div class="overflow-hidden rounded-xl border border-base-200 bg-base-100">
              <div id="users" phx-update="stream" class="divide-y divide-base-200">
                <div class="hidden px-4 py-6 text-sm text-base-content/60 only:block">
                  No users yet.
                </div>

                <div
                  :for={{id, user} <- @streams.users}
                  id={id}
                  class="grid grid-cols-[1.2fr,0.8fr,0.6fr,0.6fr,0.8fr] items-center gap-4 px-4 py-3"
                >
                  <div class="space-y-1">
                    <div class="font-medium">{user.display_name || "Unnamed"}</div>
                    <div class="text-xs text-base-content/60">{user.email}</div>
                  </div>
                  <div class="text-sm text-base-content/70">{user.last_auth_method || "-"}</div>
                  <div class="text-sm capitalize">{user.role}</div>
                  <div class={["text-xs font-semibold uppercase", status_class(user.status)]}>
                    {user.status}
                  </div>
                  <div class="flex items-center justify-end gap-2">
                    <select
                      class="select select-bordered select-sm"
                      phx-change="update_role"
                      phx-value-id={user.id}
                      name="role"
                      value={user.role}
                    >
                      <option value="viewer">viewer</option>
                      <option value="operator">operator</option>
                      <option value="admin">admin</option>
                    </select>

                    <%= if user.status == :active do %>
                      <button
                        class="btn btn-ghost btn-xs"
                        phx-click="deactivate"
                        phx-value-id={user.id}
                      >
                        Deactivate
                      </button>
                    <% else %>
                      <button
                        class="btn btn-ghost btn-xs"
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
            <div>
              <h2 class="text-lg font-semibold">Add User</h2>
              <p class="text-sm text-base-content/60">
                Create a local account for an operator or admin.
              </p>
            </div>

            <.form for={@form} id="user-create-form" phx-change="validate" phx-submit="create">
              <div class="space-y-3">
                <.input field={@form[:email]} type="email" label="Email" required />
                <.input field={@form[:display_name]} type="text" label="Display Name" />
                <.input
                  field={@form[:role]}
                  type="select"
                  label="Role"
                  options={[{"viewer", "viewer"}, {"operator", "operator"}, {"admin", "admin"}]}
                />
                <.input field={@form[:password]} type="password" label="Temporary Password" />
              </div>

              <div class="mt-4">
                <button class="btn btn-primary w-full" type="submit">
                  Create User
                </button>
              </div>
            </.form>
          </section>
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

  defp default_user_form do
    %{
      "email" => "",
      "display_name" => "",
      "role" => "viewer",
      "password" => ""
    }
  end

  defp status_class(:active), do: "text-success"
  defp status_class(:inactive), do: "text-warning"
  defp status_class(_), do: "text-base-content/60"

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
