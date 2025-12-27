defmodule ServiceRadarWebNGWeb.UserLive.Settings do
  @moduledoc """
  LiveView for user account settings.

  Uses AshPhoenix.Form for form handling with the User Ash resource.
  """
  use ServiceRadarWebNGWeb, :live_view

  on_mount {ServiceRadarWebNGWeb.UserAuth, :require_sudo_mode}

  alias ServiceRadarWebNG.Accounts

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="text-center">
        <.header>
          Account Settings
          <:subtitle>Manage your account email address and password settings</:subtitle>
        </.header>
      </div>

      <.form for={@email_form} id="email_form" phx-submit="update_email" phx-change="validate_email">
        <.input
          field={@email_form[:email]}
          type="email"
          label="Email"
          autocomplete="username"
          required
        />
        <.button variant="primary" phx-disable-with="Changing...">Change Email</.button>
      </.form>

      <div class="divider" />

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

    {:ok, push_navigate(socket, to: ~p"/users/settings")}
  end

  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user
    email_ash_form = build_email_form(user)
    password_ash_form = build_password_form(user)

    socket =
      socket
      |> assign(:current_email, user.email)
      |> assign(:email_ash_form, email_ash_form)
      |> assign(:password_ash_form, password_ash_form)
      |> assign(:email_form, to_form(email_ash_form))
      |> assign(:password_form, to_form(password_ash_form))
      |> assign(:trigger_submit, false)

    {:ok, socket}
  end

  # Build AshPhoenix.Form for email update
  defp build_email_form(user) do
    AshPhoenix.Form.for_update(user, :update_email,
      domain: ServiceRadar.Identity,
      as: "user",
      actor: user
    )
  end

  # Build AshPhoenix.Form for password change
  defp build_password_form(user) do
    AshPhoenix.Form.for_update(user, :change_password,
      domain: ServiceRadar.Identity,
      as: "user",
      actor: user
    )
  end

  @impl true
  def handle_event("validate_email", %{"user" => user_params}, socket) do
    ash_form =
      socket.assigns.email_ash_form
      |> AshPhoenix.Form.validate(user_params)

    {:noreply,
     socket
     |> assign(:email_ash_form, ash_form)
     |> assign(:email_form, to_form(ash_form))}
  end

  def handle_event("update_email", %{"user" => user_params}, socket) do
    user = socket.assigns.current_scope.user
    true = Accounts.sudo_mode?(user)

    ash_form =
      socket.assigns.email_ash_form
      |> AshPhoenix.Form.validate(user_params)

    case AshPhoenix.Form.submit(ash_form, params: user_params) do
      {:ok, _updated_user} ->
        # Note: AshAuthentication's confirmation add-on handles email verification
        # For now, show a success message
        info = "Email updated successfully."
        {:noreply, socket |> put_flash(:info, info)}

      {:error, ash_form} ->
        {:noreply,
         socket
         |> assign(:email_ash_form, ash_form)
         |> assign(:email_form, to_form(ash_form))}
    end
  end

  def handle_event("validate_password", %{"user" => user_params}, socket) do
    ash_form =
      socket.assigns.password_ash_form
      |> AshPhoenix.Form.validate(user_params)

    {:noreply,
     socket
     |> assign(:password_ash_form, ash_form)
     |> assign(:password_form, to_form(ash_form))}
  end

  def handle_event("update_password", %{"user" => user_params}, socket) do
    user = socket.assigns.current_scope.user
    true = Accounts.sudo_mode?(user)

    ash_form =
      socket.assigns.password_ash_form
      |> AshPhoenix.Form.validate(user_params)

    case AshPhoenix.Form.submit(ash_form, params: user_params) do
      {:ok, _updated_user} ->
        # Trigger the form submit action for session handling
        {:noreply,
         socket
         |> assign(:password_ash_form, ash_form)
         |> assign(:password_form, to_form(ash_form))
         |> assign(:trigger_submit, true)}

      {:error, ash_form} ->
        {:noreply,
         socket
         |> assign(:password_ash_form, ash_form)
         |> assign(:password_form, to_form(ash_form))}
    end
  end
end
