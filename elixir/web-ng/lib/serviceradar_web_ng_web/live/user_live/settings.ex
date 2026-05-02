defmodule ServiceRadarWebNGWeb.UserLive.Settings do
  @moduledoc """
  LiveView for user account settings.

  Uses AshPhoenix.Form for form handling with the User Ash resource.
  """
  use ServiceRadarWebNGWeb, :live_view

  alias ServiceRadar.Identity.Constants
  alias ServiceRadarWebNG.Accounts
  alias ServiceRadarWebNG.RBAC

  on_mount {ServiceRadarWebNGWeb.UserAuth, :require_sudo_mode}

  @password_manage_permission Constants.password_manage_permission()

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_path="/settings/profile"
      page_title="Settings"
    >
      <div class="mx-auto w-full max-w-4xl p-6 space-y-6">
        <div>
          <h1 class="text-2xl font-semibold text-base-content">Account Settings</h1>
          <p class="text-sm text-base-content/60">
            Manage your login email and account profile settings.
          </p>
        </div>

        <.ui_panel>
          <:header>
            <div>
              <div class="text-sm font-semibold">Email</div>
              <p class="text-xs text-base-content/60">
                Update the email used to sign in to ServiceRadar.
              </p>
            </div>
          </:header>

          <.form
            for={@email_form}
            id="email_form"
            phx-submit="update_email"
            phx-change="validate_email"
          >
            <.input
              field={@email_form[:email]}
              type="email"
              label="Email"
              autocomplete="username"
              required
            />
            <%= if has_password?(@current_scope.user) do %>
              <.input
                field={@email_form[:current_password]}
                type="password"
                label="Current password"
                autocomplete="current-password"
                required
              />
            <% end %>
            <.button variant="primary" phx-disable-with="Changing...">Change Email</.button>
          </.form>
        </.ui_panel>

        <%= if @can_change_password do %>
          <.ui_panel>
            <:header>
              <div>
                <div class="text-sm font-semibold">Password</div>
                <p class="text-xs text-base-content/60">
                  Rotate your password and confirm the new credentials.
                </p>
              </div>
            </:header>

            <.form
              for={@password_form}
              id="password_form"
              action={~p"/users/update-password"}
              method="post"
              phx-change="validate_password"
              phx-submit="update_password"
              phx-trigger-action={@trigger_submit}
            >
              <input
                name="user[email]"
                type="hidden"
                id="hidden_user_email"
                autocomplete="username"
                value={@current_email}
              />
              <.input
                field={@password_form[:current_password]}
                type="password"
                label="Current password"
                autocomplete="current-password"
              />
              <.input
                field={@password_form[:password]}
                type="password"
                label="New password"
                autocomplete="new-password"
                required
              />
              <.input
                field={@password_form[:password_confirmation]}
                type="password"
                label="Confirm new password"
                autocomplete="new-password"
              />
              <.button variant="primary" phx-disable-with="Saving...">
                Save Password
              </.button>
            </.form>
          </.ui_panel>
        <% end %>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(%{"token" => token}, _session, socket) do
    socket =
      case Accounts.update_user_email(socket.assigns.current_scope.user, token) do
        {:ok, _user} ->
          put_flash(socket, :info, "Email changed successfully.")

        {:error, _} ->
          put_flash(socket, :error, "Email change link is invalid or it has expired.")
      end

    {:ok, push_navigate(socket, to: ~p"/settings/profile")}
  end

  def mount(_params, session, socket) do
    scope = socket.assigns.current_scope
    user = scope.user
    can_change_password = RBAC.can?(scope, @password_manage_permission)
    email_ash_form = build_email_form(user, scope)
    password_ash_form = if can_change_password, do: build_password_form(user, scope)

    socket =
      socket
      |> assign(:can_change_password, can_change_password)
      |> assign(:current_email, user.email)
      |> assign(:email_ash_form, email_ash_form)
      |> assign(:password_ash_form, password_ash_form)
      |> assign(:email_form, to_form(email_ash_form))
      |> assign(:password_form, if(password_ash_form, do: to_form(password_ash_form)))
      |> assign(:trigger_submit, false)
      |> assign(:sudo_at, mount_sudo_at(session))

    {:ok, socket}
  end

  defp mount_sudo_at(session) do
    case session["sudo_authenticated_at"] do
      at when is_integer(at) -> DateTime.from_unix!(at)
      _ -> nil
    end
  end

  defp has_password?(user) do
    user.hashed_password != nil && user.hashed_password != ""
  end

  # Build AshPhoenix.Form for email update
  defp build_email_form(user, scope) do
    AshPhoenix.Form.for_update(user, :update_email,
      domain: ServiceRadar.Identity,
      as: "user",
      scope: scope
    )
  end

  # Build AshPhoenix.Form for password change
  defp build_password_form(user, scope) do
    AshPhoenix.Form.for_update(user, :change_password,
      domain: ServiceRadar.Identity,
      as: "user",
      scope: scope
    )
  end

  @impl true
  def handle_event("validate_email", %{"user" => user_params}, socket) do
    ash_form = AshPhoenix.Form.validate(socket.assigns.email_ash_form, user_params)

    {:noreply,
     socket
     |> assign(:email_ash_form, ash_form)
     |> assign(:email_form, to_form(ash_form))}
  end

  def handle_event("update_email", %{"user" => user_params}, socket) do
    user = socket.assigns.current_scope.user

    if Accounts.sudo_mode?(user, socket.assigns.sudo_at) do
      ash_form = AshPhoenix.Form.validate(socket.assigns.email_ash_form, user_params)

      case AshPhoenix.Form.submit(ash_form, params: user_params) do
        {:ok, _updated_user} ->
          # Email verification could use Guardian tokens in the future
          info = "Email updated successfully."
          {:noreply, put_flash(socket, :info, info)}

        {:error, ash_form} ->
          {:noreply,
           socket
           |> assign(:email_ash_form, ash_form)
           |> assign(:email_form, to_form(ash_form))}
      end
    else
      {:noreply,
       socket
       |> put_flash(:error, "Sudo mode required. Please re-authenticate.")
       |> push_navigate(to: ~p"/settings/profile")}
    end
  end

  def handle_event("validate_password", _params, %{assigns: %{can_change_password: false}} = socket) do
    {:noreply, socket}
  end

  def handle_event("validate_password", %{"user" => user_params}, socket) do
    ash_form = AshPhoenix.Form.validate(socket.assigns.password_ash_form, user_params)

    {:noreply,
     socket
     |> assign(:password_ash_form, ash_form)
     |> assign(:password_form, to_form(ash_form))}
  end

  def handle_event("update_password", _params, %{assigns: %{can_change_password: false}} = socket) do
    {:noreply,
     socket
     |> put_flash(:error, "You are not allowed to change the password for this account.")
     |> push_navigate(to: ~p"/settings/profile")}
  end

  def handle_event("update_password", %{"user" => user_params}, socket) do
    user = socket.assigns.current_scope.user

    if Accounts.sudo_mode?(user, socket.assigns.sudo_at) do
      ash_form = AshPhoenix.Form.validate(socket.assigns.password_ash_form, user_params)

      # Important: do not submit the Ash action here.
      # The browser POSTs to UserSessionController, which performs the password
      # change and then revokes sessions/tokens.
      if ash_form.valid? do
        {:noreply,
         socket
         |> assign(:password_ash_form, ash_form)
         |> assign(:password_form, to_form(ash_form))
         |> assign(:trigger_submit, true)}
      else
        {:noreply,
         socket
         |> assign(:password_ash_form, ash_form)
         |> assign(:password_form, to_form(ash_form))
         |> assign(:trigger_submit, false)}
      end
    else
      {:noreply,
       socket
       |> put_flash(:error, "Sudo mode required. Please re-authenticate.")
       |> push_navigate(to: ~p"/settings/profile")}
    end
  end
end
