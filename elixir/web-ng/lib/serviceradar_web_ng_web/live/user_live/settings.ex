defmodule ServiceRadarWebNGWeb.UserLive.Settings do
  @moduledoc """
  LiveView for user account settings.

  Uses AshPhoenix.Form for form handling with the User Ash resource.
  """
  use ServiceRadarWebNGWeb, :live_view

  alias ServiceRadar.Identity.Constants
  alias ServiceRadar.Identity.User
  alias ServiceRadar.TimeZone
  alias ServiceRadarWebNG.Accounts
  alias ServiceRadarWebNG.RBAC
  alias ServiceRadarWebNGWeb.Settings.Shell

  # Viewing the profile must not require sudo mode. Sensitive submits
  # re-check sudo: the password POST in UserSessionController.update_password/2
  # and the email change via Accounts.sudo_mode?/2 in handle_event/3 below.
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
      <Shell.settings_chrome
        current_path="/settings/profile"
        current_scope={@current_scope}
        active_view={@settings_active_view}
        active_category={@settings_active_category}
        breadcrumbs={@settings_breadcrumbs}
        nav_tree={@settings_nav_tree}
        palette={@settings_palette}
        stats={@settings_stats}
      >
        <div class="mx-auto w-full max-w-4xl p-6 space-y-6">
          <div>
            <h1 class="text-2xl font-semibold text-sr-ink">Account Settings</h1>
            <p class="text-sm text-sr-muted">
              Manage your login email and account profile settings.
            </p>
          </div>

          <%= if @idp_managed_identity do %>
            <.ui_panel>
              <:header>
                <div>
                  <div class="text-sm font-semibold">Email</div>
                  <p class="text-xs text-sr-muted">
                    This address is managed by your identity provider and cannot
                    be changed in ServiceRadar.
                  </p>
                </div>
              </:header>

              <p class="text-sm font-mono text-sr-ink">{@current_email}</p>
            </.ui_panel>

            <.ui_panel>
              <:header>
                <div>
                  <div class="text-sm font-semibold">Password</div>
                  <p class="text-xs text-sr-muted">
                    Password for this account is managed by your identity provider.
                  </p>
                </div>
              </:header>

              <p class="text-sm text-sr-muted">
                Sign in through SSO to change it there. ServiceRadar will not
                accept a password change for an identity-provider account.
              </p>
            </.ui_panel>
          <% else %>
            <.ui_panel>
              <:header>
                <div>
                  <div class="text-sm font-semibold">Email</div>
                  <p class="text-xs text-sr-muted">
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
                    id="email_current_password"
                    type="password"
                    label="Current password"
                    autocomplete="current-password"
                    required
                  />
                <% end %>
                <.button variant="primary" phx-disable-with="Changing...">Change Email</.button>
              </.form>
            </.ui_panel>
          <% end %>

          <.ui_panel>
            <:header>
              <div>
                <div class="text-sm font-semibold">Timezone</div>
                <p class="text-xs text-sr-muted">
                  Choose the timezone used to display timestamps in ServiceRadar.
                </p>
              </div>
            </:header>

            <p :if={@timezone_catalog_warning} class="mb-3 text-sm text-amber-700" role="status">
              {@timezone_catalog_warning}
            </p>

            <.form
              for={@timezone_form}
              id="timezone_form"
              phx-submit="update_timezone"
            >
              <div class="relative mb-3">
                <.input
                  field={@timezone_form[:timezone]}
                  id="user_timezone"
                  type="text"
                  label="Display timezone"
                  phx-hook="TimezoneSelect"
                  data-options-id="timezone_catalog"
                  data-current-timezone={@current_scope.user.timezone}
                  autocomplete="off"
                  role="combobox"
                  aria-autocomplete="list"
                  aria-controls="timezone_catalog"
                  aria-expanded="false"
                  aria-haspopup="listbox"
                  placeholder="Search, e.g. America/Chicago"
                  wrapper_class="grid gap-1.5"
                  required
                />
                <ul
                  id="timezone_catalog"
                  role="listbox"
                  aria-label="Timezones"
                  class="sr-ui-dropdown-menu absolute left-0 right-0 top-full z-[var(--sr-z-menu)] mt-1.5 hidden max-h-64 w-full overflow-y-auto rounded-sr-surface border border-sr-line bg-sr-raised p-1.5 shadow-sr-raised"
                >
                  <li :for={zone <- @timezone_catalog}>
                    <button
                      type="button"
                      role="option"
                      id={"timezone-option-#{String.replace(zone, "/", "-")}"}
                      tabindex="-1"
                      data-timezone={zone}
                      aria-selected="false"
                      class="flex w-full items-center rounded-sr-control px-3 py-2 text-left text-sm text-sr-ink outline-none hover:bg-sr-subtle"
                    >
                      {zone}
                    </button>
                  </li>
                  <li
                    data-timezone-empty
                    class="hidden px-3 py-2 text-sm text-sr-muted"
                    hidden
                  >
                    No matching timezones.
                  </li>
                </ul>
              </div>
              <.button variant="primary" phx-disable-with="Saving...">Save Timezone</.button>
            </.form>

            <div class="mt-4 text-sm text-sr-muted">
              Preview:
              <.user_time
                id="timezone-preview"
                value={@timezone_preview_at}
                timezone={@current_scope.user.timezone}
                style={:full}
              />
            </div>
          </.ui_panel>

          <%= if not @idp_managed_identity and @can_change_password and has_password?(@current_scope.user) do %>
            <.ui_panel>
              <:header>
                <div>
                  <div class="text-sm font-semibold">Password</div>
                  <p class="text-xs text-sr-muted">
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
                  id="password_current_password"
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
      </Shell.settings_chrome>
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
    idp_managed_identity = User.idp_managed_identity?(user)
    can_change_password = not idp_managed_identity and RBAC.can?(scope, @password_manage_permission)
    email_ash_form = if !idp_managed_identity, do: build_email_form(user, scope)
    password_ash_form = if can_change_password, do: build_password_form(user, scope)
    timezone_ash_form = build_timezone_form(user, scope)
    {timezone_catalog, timezone_catalog_warning} = timezone_catalog(socket, user)

    socket =
      socket
      |> assign(:idp_managed_identity, idp_managed_identity)
      |> assign(:can_change_password, can_change_password)
      |> assign(:current_email, user.email)
      |> assign(:email_ash_form, email_ash_form)
      |> assign(:password_ash_form, password_ash_form)
      |> assign(:timezone_ash_form, timezone_ash_form)
      |> assign(:email_form, if(email_ash_form, do: to_form(email_ash_form)))
      |> assign(:password_form, if(password_ash_form, do: to_form(password_ash_form)))
      |> assign(:timezone_form, to_form(timezone_ash_form))
      |> assign(:timezone_catalog, timezone_catalog)
      |> assign(:timezone_catalog_warning, timezone_catalog_warning)
      |> assign(:timezone_preview_at, DateTime.utc_now())
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

  defp build_timezone_form(user, scope) do
    AshPhoenix.Form.for_update(user, :update_timezone_preference,
      domain: ServiceRadar.Identity,
      as: "timezone_preference",
      scope: scope
    )
  end

  defp timezone_catalog(socket, user) do
    extras = [user.timezone]

    if connected?(socket) do
      case TimeZone.profile_timezones() do
        {:ok, zones} ->
          {TimeZone.profile_picker_zones(zones, extras), nil}

        {:error, :catalog_unavailable} ->
          {TimeZone.profile_picker_zones([], extras), "Timezone choices are temporarily unavailable."}
      end
    else
      {TimeZone.profile_picker_zones([], extras), nil}
    end
  end

  @impl true
  def handle_event("validate_email", _params, %{assigns: %{idp_managed_identity: true}} = socket) do
    {:noreply, socket}
  end

  def handle_event("validate_email", %{"user" => user_params}, socket) do
    ash_form = AshPhoenix.Form.validate(socket.assigns.email_ash_form, user_params)

    {:noreply,
     socket
     |> assign(:email_ash_form, ash_form)
     |> assign(:email_form, to_form(ash_form))}
  end

  def handle_event("update_email", _params, %{assigns: %{idp_managed_identity: true}} = socket) do
    {:noreply,
     socket
     |> put_flash(:error, "Email for this account is managed by your identity provider.")
     |> push_navigate(to: ~p"/settings/profile")}
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

  def handle_event("update_timezone", %{"timezone_preference" => params}, socket) do
    ash_form = AshPhoenix.Form.validate(socket.assigns.timezone_ash_form, params)

    case AshPhoenix.Form.submit(ash_form, params: params) do
      {:ok, updated_user} ->
        updated_scope = %{socket.assigns.current_scope | user: updated_user}
        timezone_ash_form = build_timezone_form(updated_user, updated_scope)

        {:noreply,
         socket
         |> assign(:current_scope, updated_scope)
         |> assign(:timezone_ash_form, timezone_ash_form)
         |> assign(:timezone_form, to_form(timezone_ash_form))
         |> put_flash(:info, "Timezone updated successfully.")}

      {:error, timezone_ash_form} ->
        {:noreply,
         socket
         |> assign(:timezone_ash_form, timezone_ash_form)
         |> assign(:timezone_form, to_form(timezone_ash_form))}
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
