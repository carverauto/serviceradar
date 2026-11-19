defmodule ServiceRadarWebNGWeb.UserLive.Settings do
  @moduledoc """
  LiveView for user account settings.

  Uses AshPhoenix.Form for form handling with the User Ash resource.
  """
  use ServiceRadarWebNGWeb, :live_view

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Identity.Constants
  alias ServiceRadar.Identity.RoleMappingSupport
  alias ServiceRadar.Identity.RoleProfile
  alias ServiceRadar.Identity.User
  alias ServiceRadar.Identity.UserGroup
  alias ServiceRadar.TimeZone
  alias ServiceRadarWebNG.Accounts
  alias ServiceRadarWebNG.Homepage
  alias ServiceRadarWebNG.RBAC
  alias ServiceRadarWebNGWeb.Auth.ClaimDiagnostics
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
                <div class="text-sm font-semibold">Access</div>
                <p class="text-xs text-sr-muted">
                  Your current role and how you signed in.
                </p>
              </div>
            </:header>

            <dl class="space-y-2 text-sm">
              <div class="flex gap-2">
                <dt class="w-32 shrink-0 text-sr-muted">Role</dt>
                <dd class="text-sr-ink">{format_role(@current_scope.user.role)}</dd>
              </div>
              <%= if @current_scope.user.role_profile_source == :idp and
                     not is_nil(@current_scope.user.role_profile_id) do %>
                <div class="flex gap-2">
                  <dt class="w-32 shrink-0 text-sr-muted">Assigned by</dt>
                  <dd class="text-sr-ink">Role profile assigned by identity provider</dd>
                </div>
              <% end %>
              <%= if auth_label = format_auth_method(@current_scope.user.last_auth_method) do %>
                <div class="flex gap-2">
                  <dt class="w-32 shrink-0 text-sr-muted">Signed in with</dt>
                  <dd class="text-sr-ink">{auth_label}</dd>
                </div>
              <% end %>
            </dl>

            <div :if={@sso_session?} id="sso-sign-in" class="mt-4 space-y-3 border-t border-sr-line pt-4">
              <div>
                <div class="text-sm font-semibold">SSO sign-in</div>
                <p class="text-xs text-sr-muted">
                  What your identity provider sent at sign-in, and which role mappings it matched.
                  Role changes apply at your next sign-in.
                </p>
              </div>

              <p :if={is_nil(@sso_diagnosis)} class="text-xs text-sr-muted">Loading…</p>

              <%= if @sso_diagnosis do %>
                <dl class="space-y-2 text-sm">
                  <div :for={{key, value} <- @sso_diagnosis.identity} class="flex gap-2">
                    <dt class="w-32 shrink-0 text-sr-muted"><code>{key}</code></dt>
                    <dd class="break-all text-sr-ink">{value}</dd>
                  </div>
                  <div :for={{key, values} <- @sso_diagnosis.role_claims} class="flex gap-2">
                    <dt class="w-32 shrink-0 text-sr-muted"><code>{key}</code></dt>
                    <dd class="break-all text-sr-ink">{Enum.join(values, ", ")}</dd>
                  </div>
                  <div :if={@sso_diagnosis.role_claims == []} class="flex gap-2" id="sso-no-role-claims">
                    <dt class="w-32 shrink-0 text-sr-muted">Groups / roles</dt>
                    <dd class="text-sr-ink">None in this token</dd>
                  </div>
                </dl>

                <p :if={@sso_diagnosis.groups_overage?} id="sso-groups-overage" class="text-xs text-warning">
                  Your identity provider left the groups claim out because you are in too many groups,
                  so group mappings cannot match. Use app roles or a narrower groups claim.
                </p>

                <div id="sso-role-mappings" class="text-sm">
                  <div class="text-sr-muted">Role mappings</div>
                  <p :if={@sso_diagnosis.resolution.matched == []} id="sso-no-mapping" class="text-sr-ink">
                    No mapping matched — you received the default role
                    ({format_role(@sso_diagnosis.resolution.role)}).
                    <span :if={@sso_diagnosis.mapping_count > 0} class="text-sr-muted">
                      {@sso_diagnosis.mapping_count} configured.
                    </span>
                  </p>
                  <ul :if={@sso_diagnosis.resolution.matched != []} class="mt-1 space-y-1">
                    <li :for={mapping <- @sso_diagnosis.resolution.matched} class="text-sr-ink">
                      <code>{RoleMappingSupport.get_key(mapping, "source")}</code>
                      = <code>{RoleMappingSupport.get_key(mapping, "value")}</code>
                      → {mapping_grant(mapping, @sso_grant_labels)}
                    </li>
                  </ul>
                </div>
              <% end %>

              <details :if={@sso_raw_claims != []} class="text-xs">
                <summary class="cursor-pointer text-sr-muted">All claims</summary>
                <dl class="mt-2 space-y-1">
                  <div :for={{key, value} <- @sso_raw_claims} class="flex gap-2">
                    <dt class="w-40 shrink-0 text-sr-muted"><code>{key}</code></dt>
                    <dd class="break-all font-mono text-sr-ink">{value}</dd>
                  </div>
                </dl>
              </details>
            </div>
          </.ui_panel>

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

          <.ui_panel>
            <:header>
              <div>
                <div class="text-sm font-semibold">Default homepage</div>
                <p class="text-xs text-sr-muted">
                  Where you land after signing in. Inherit uses your user group's homepage, or the deployment default.
                </p>
              </div>
            </:header>

            <.form for={@homepage_form} id="homepage_form" phx-submit="update_homepage">
              <.input
                field={@homepage_form[:choice]}
                id="user_homepage"
                type="select"
                label="Homepage"
                options={@homepage_options}
              />
              <.button variant="primary" phx-disable-with="Saving...">Save Homepage</.button>
            </.form>
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
      |> assign_homepage(user)
      |> assign_sso_diagnosis(scope)
      |> assign(:trigger_submit, false)
      |> assign(:sudo_at, mount_sudo_at(session))

    {:ok, socket}
  end

  # Dashboard options need a database read, so they load only once the socket
  # is connected; the disconnected render shows the current choice alone.
  defp assign_homepage(socket, user) do
    current = Homepage.encode_choice(ServiceRadar.Identity.Homepage.stored(user.homepage))

    dashboards =
      if connected?(socket), do: Homepage.dashboard_choices(socket.assigns.current_scope), else: []

    options = [{"Inherit (group or deployment default)", ""}] ++ Homepage.page_choices() ++ dashboards

    options =
      if current == "" or List.keymember?(options, current, 1),
        do: options,
        else: options ++ [{"Unavailable dashboard (skipped at sign-in)", current}]

    socket
    |> assign(:homepage_options, options)
    |> assign(:homepage_form, to_form(%{"choice" => current}, as: "homepage"))
  end

  # The claims come from this session; the mappings they resolve against and the
  # names of what they grant are database reads, so those load once connected. The
  # system actor reads them because a viewer may not read authorization settings,
  # which would otherwise show every SSO user "no mapping matched".
  @hidden_claim_keys ~w[service_radar_auth_method nonce at_hash c_hash sid]

  defp assign_sso_diagnosis(socket, scope) do
    claims = scope.identity_claims || %{}
    sso_session? = Map.get(claims, "service_radar_auth_method") == "oidc"

    {diagnosis, labels} =
      if sso_session? and connected?(socket) do
        actor = SystemActor.system(:profile_access_panel)
        diagnosis = ClaimDiagnostics.diagnose(claims, actor: actor)
        {diagnosis, grant_labels(diagnosis, actor)}
      else
        {nil, %{profiles: %{}, groups: %{}}}
      end

    socket
    |> assign(:sso_session?, sso_session?)
    |> assign(:sso_diagnosis, diagnosis)
    |> assign(:sso_grant_labels, labels)
    |> assign(:sso_raw_claims, if(sso_session?, do: raw_claims(claims), else: []))
  end

  defp grant_labels(%{resolution: %{matched: []}}, _actor), do: %{profiles: %{}, groups: %{}}

  defp grant_labels(_diagnosis, actor) do
    %{profiles: names_by_id(RoleProfile, actor), groups: names_by_id(UserGroup, actor)}
  end

  defp names_by_id(resource, actor) do
    case Ash.read(resource, actor: actor) do
      {:ok, records} -> Map.new(records, &{to_string(&1.id), &1.name})
      {:error, _reason} -> %{}
    end
  end

  defp raw_claims(claims) do
    claims
    |> Enum.reject(fn {key, _value} -> key in @hidden_claim_keys end)
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.map(fn {key, value} -> {key, render_claim_value(value)} end)
  end

  defp render_claim_value(value) when is_binary(value), do: value
  defp render_claim_value(value) when is_list(value), do: Enum.map_join(value, ", ", &render_claim_value/1)
  defp render_claim_value(value) when is_map(value), do: Jason.encode!(value)
  defp render_claim_value(nil), do: ""
  defp render_claim_value(value), do: to_string(value)

  defp mapping_grant(mapping, labels) do
    role = RoleMappingSupport.get_key(mapping, "role")
    profile = label_for(labels.profiles, RoleMappingSupport.get_key(mapping, "role_profile_id"))
    group = label_for(labels.groups, RoleMappingSupport.get_key(mapping, "user_group_id"))

    [
      role && "role #{role}",
      profile && "profile #{profile}",
      group && "group #{group}"
    ]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> "nothing"
      parts -> Enum.join(parts, ", ")
    end
  end

  defp label_for(_names, nil), do: nil
  defp label_for(_names, ""), do: nil
  defp label_for(names, id), do: Map.get(names, to_string(id), to_string(id))

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

  def handle_event("update_homepage", %{"homepage" => %{"choice" => choice}}, socket) do
    scope = socket.assigns.current_scope

    with {:ok, homepage} <- Homepage.decode_choice(choice),
         {:ok, updated_user} <- Homepage.set_user_homepage(scope, homepage) do
      {:noreply,
       socket
       |> assign(:current_scope, %{scope | user: updated_user})
       |> assign_homepage(updated_user)
       |> put_flash(:info, "Homepage updated successfully.")}
    else
      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Homepage was not saved: #{homepage_error(reason)}")}
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

  defp format_role(:admin), do: "Admin"
  defp format_role(:operator), do: "Operator"
  defp format_role(:helpdesk), do: "Helpdesk"
  defp format_role(:viewer), do: "Viewer"

  defp format_auth_method(:oidc), do: "SSO (OIDC)"
  defp format_auth_method(:saml), do: "SSO (SAML)"
  defp format_auth_method(:password), do: "Password"
  defp format_auth_method(:gateway), do: "Gateway"
  defp format_auth_method(:api_token), do: "API token"
  defp format_auth_method(:oauth_client), do: "OAuth client"
  defp format_auth_method(nil), do: nil

  defp homepage_error(message) when is_binary(message), do: "homepage " <> message
  defp homepage_error(%{errors: [_ | _] = errors}), do: Enum.map_join(errors, "; ", &Exception.message/1)
  defp homepage_error(reason), do: inspect(reason)
end
