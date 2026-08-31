defmodule ServiceRadarWebNGWeb.Settings.AuthUserLive.Show do
  @moduledoc """
  Admin user detail page.

  This is intentionally separate from the Accounts table so admins can inspect
  and edit an account without cramming everything into one row.
  """

  use ServiceRadarWebNGWeb, :live_view

  use Permit.Phoenix.LiveView,
    authorization_module: ServiceRadarWebNGWeb.Authorization,
    resource_module: ServiceRadar.Identity.User

  alias ServiceRadar.Identity.User
  alias ServiceRadar.Identity.UserAuthEvent
  alias ServiceRadarWebNG.AdminApi
  alias ServiceRadarWebNGWeb.Settings.Shell

  @event_page_limit 50

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    scope = socket.assigns.current_scope

    if ServiceRadarWebNG.RBAC.can?(scope, "settings.auth.manage") do
      role_profiles =
        case AdminApi.list_role_profiles(scope) do
          {:ok, profiles} -> profiles
          {:error, _} -> []
        end

      socket =
        socket
        |> assign(:page_title, "Account")
        |> assign(:role_profiles, role_profiles)
        |> assign(:editing, false)
        |> assign(:form, to_form(%{}, as: :user))
        |> assign(:show_password_modal, false)
        |> assign(:password_form, to_form(%{"password" => ""}, as: :password))
        |> assign(:events_page, nil)
        |> assign(:events, [])
        |> assign(:role_mapping_event, nil)

      case AdminApi.get_user(scope, id) do
        {:ok, user} ->
          {events, events_page} = load_events(scope, user.id, nil, nil)

          {:ok,
           socket
           |> assign(:user, user)
           |> assign(:form, to_form(default_form(user, role_profiles), as: :user))
           |> assign(:events, events)
           |> assign(:events_page, events_page)
           |> assign(:role_mapping_event, load_role_mapping_event(scope, user.id))}

        {:error, error} ->
          {:ok,
           socket
           |> put_flash(:error, user_load_error_message(error))
           |> push_navigate(to: ~p"/settings/auth/users")}
      end
    else
      {:ok,
       socket
       |> put_flash(:error, "You don't have permission to access Settings.")
       |> push_navigate(to: ~p"/dashboard")}
    end
  end

  @impl true
  def handle_event("toggle_edit", _params, socket) do
    editing = not socket.assigns.editing
    user = socket.assigns.user

    socket =
      socket
      |> assign(:editing, editing)
      |> assign(:form, to_form(default_form(user, socket.assigns.role_profiles), as: :user))

    {:noreply, socket}
  end

  def handle_event("validate", %{"user" => params}, socket) do
    {:noreply, assign(socket, :form, to_form(params, as: :user))}
  end

  def handle_event("save", %{"user" => params}, socket) do
    scope = socket.assigns.current_scope
    user = socket.assigns.user

    display_name = Map.get(params, "display_name")
    role_profile_id = normalize_profile_id(Map.get(params, "role_profile_id"))

    attrs =
      %{display_name: display_name}
      |> maybe_put(:role_profile_id, role_profile_id)
      |> derive_role_from_profile(role_profile_id, socket.assigns.role_profiles)

    case AdminApi.update_user(scope, user.id, attrs) do
      {:ok, updated} ->
        {:noreply,
         socket
         |> put_flash(:info, "Account updated")
         |> assign(:user, updated)
         |> assign(:editing, false)
         |> assign(:form, to_form(default_form(updated, socket.assigns.role_profiles), as: :user))}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, format_ash_error(error))}
    end
  end

  def handle_event("events_next", _params, socket) do
    scope = socket.assigns.current_scope
    user = socket.assigns.user
    page = socket.assigns.events_page

    after_token = if page, do: Map.get(page, :after)
    {events, page} = load_events(scope, user.id, after_token, nil)

    {:noreply, socket |> assign(:events, events) |> assign(:events_page, page)}
  end

  def handle_event("events_prev", _params, socket) do
    scope = socket.assigns.current_scope
    user = socket.assigns.user
    page = socket.assigns.events_page

    before_token = if page, do: Map.get(page, :before)
    {events, page} = load_events(scope, user.id, nil, before_token)

    {:noreply, socket |> assign(:events, events) |> assign(:events_page, page)}
  end

  def handle_event("deactivate", _params, socket) do
    scope = socket.assigns.current_scope
    user = socket.assigns.user

    case AdminApi.deactivate_user(scope, user.id) do
      {:ok, updated} ->
        {:noreply, socket |> put_flash(:info, "User deactivated") |> assign(:user, updated)}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, format_ash_error(error))}
    end
  end

  def handle_event("reactivate", _params, socket) do
    scope = socket.assigns.current_scope
    user = socket.assigns.user

    case AdminApi.reactivate_user(scope, user.id) do
      {:ok, updated} ->
        {:noreply, socket |> put_flash(:info, "User reactivated") |> assign(:user, updated)}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, format_ash_error(error))}
    end
  end

  def handle_event("toggle_local_login", _params, socket) do
    scope = socket.assigns.current_scope
    user = socket.assigns.user

    if ServiceRadarWebNG.RBAC.can?(scope, "settings.auth.manage") do
      enabled = not (user.local_login_enabled == true)

      case AdminApi.set_user_local_login(scope, user.id, enabled) do
        {:ok, updated} ->
          message =
            if enabled,
              do: "Local password login enabled",
              else: "Local password login disabled (SSO-only)"

          {:noreply,
           socket
           |> put_flash(:info, message)
           |> assign(:user, updated)}

        {:error, error} ->
          {:noreply, put_flash(socket, :error, format_ash_error(error))}
      end
    else
      {:noreply, put_flash(socket, :error, "You don't have permission to manage authentication.")}
    end
  end

  def handle_event("open_password_modal", _params, socket) do
    if ServiceRadarWebNG.RBAC.can?(socket.assigns.current_scope, "settings.auth.manage") do
      {:noreply,
       socket
       |> assign(:show_password_modal, true)
       |> assign(:password_form, to_form(%{"password" => ""}, as: :password))}
    else
      {:noreply, put_flash(socket, :error, "You don't have permission to manage authentication.")}
    end
  end

  def handle_event("close_password_modal", _params, socket) do
    {:noreply, assign(socket, :show_password_modal, false)}
  end

  def handle_event("set_password", %{"password" => params}, socket) do
    scope = socket.assigns.current_scope
    user = socket.assigns.user
    password = to_string(params["password"] || "")

    cond do
      not ServiceRadarWebNG.RBAC.can?(scope, "settings.auth.manage") ->
        {:noreply, put_flash(socket, :error, "You don't have permission to manage authentication.")}

      String.length(password) < 12 ->
        {:noreply, put_flash(socket, :error, "Password must be at least 12 characters")}

      true ->
        result =
          with {:ok, record} <- Ash.get(User, user.id, scope: scope),
               {:ok, _updated} <-
                 record
                 |> Ash.Changeset.for_update(:admin_set_password, %{password: password}, scope: scope)
                 |> Ash.update(scope: scope) do
            :ok
          end

        case result do
          :ok ->
            {:noreply,
             socket
             |> put_flash(:info, "Password updated")
             |> assign(:show_password_modal, false)}

          {:error, error} ->
            {:noreply, put_flash(socket, :error, format_ash_error(error))}
        end
    end
  end

  @impl true
  def event_mapping do
    Map.merge(Permit.Phoenix.LiveView.default_event_mapping(), %{
      "toggle_edit" => :update,
      "validate" => :read,
      "save" => :update,
      "deactivate" => :update,
      "reactivate" => :update,
      "events_next" => :read,
      "events_prev" => :read,
      "open_password_modal" => :update,
      "close_password_modal" => :read,
      "set_password" => :update,
      "toggle_local_login" => :update
    })
  end

  @impl true
  def skip_preload do
    # Permit.Phoenix.LiveView uses Permit.Ecto preloading by default for singular actions like :show.
    # This app uses Ash resources (not Ecto schemas) and loads the record in mount/3 via AdminApi,
    # so we must skip preloading to avoid a false :not_found and a 404.
    [:index, :show, :edit, :read, :create, :update, :delete]
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
      <Shell.settings_chrome
        current_path="/settings/auth/users"
        current_scope={@current_scope}
        active_view={@settings_active_view}
        active_category={@settings_active_category}
        breadcrumbs={@settings_breadcrumbs}
        nav_tree={@settings_nav_tree}
        palette={@settings_palette}
        stats={@settings_stats}
      >
        <div class="space-y-6">
          <div class="flex flex-wrap items-start justify-between gap-4">
            <div class="space-y-1">
              <div class="flex items-center gap-2">
                <.ui_button navigate={~p"/settings/auth/users"} size="xs" variant="ghost">
                  <.icon name="hero-arrow-left" class="size-4" /> Back
                </.ui_button>
                <.ui_badge size="sm" variant="outline">Account</.ui_badge>
              </div>
              <h1 class="text-2xl font-semibold">{@user.email}</h1>
              <p class="text-sm opacity-70">View and edit access for this account.</p>
            </div>

            <div class="flex items-center gap-2">
              <.ui_button type="button" phx-click="toggle_edit" size="sm" variant="ghost">
                <.icon name="hero-pencil-square" class="size-4" />
                {if @editing, do: "Cancel", else: "Edit"}
              </.ui_button>
              <.ui_button
                :if={@user.status == :active}
                type="button"
                phx-click="deactivate"
                size="sm"
                variant="outline"
              >
                Deactivate
              </.ui_button>
              <.ui_button
                :if={@user.status != :active}
                type="button"
                phx-click="reactivate"
                size="sm"
                variant="outline"
              >
                Reactivate
              </.ui_button>
            </div>
          </div>

          <div class="grid grid-cols-1 lg:grid-cols-2 gap-6">
            <div class="sr-ui-card bg-sr-surface border border-sr-line">
              <div class="sr-ui-card-body space-y-4">
                <h2 class="sr-ui-card-title text-base">Profile</h2>

                <.form
                  for={@form}
                  id="user-detail-form"
                  phx-change="validate"
                  phx-submit="save"
                  class="space-y-4"
                >
                  <.input
                    field={@form[:display_name]}
                    type="text"
                    label="Display name"
                    disabled={!@editing}
                    class={ui_field_class(class: "w-full")}
                  />

                  <.input
                    field={@form[:role_profile_id]}
                    type="select"
                    label="Access profile"
                    disabled={!@editing}
                    options={profile_options(@role_profiles)}
                    class={ui_field_class(class: "w-full")}
                  />

                  <div class="grid grid-cols-2 gap-3 text-sm">
                    <div class="space-y-1">
                      <div class="text-xs opacity-60 font-semibold uppercase tracking-wide">
                        Status
                      </div>
                      <div class="font-mono">{to_string(@user.status || "—")}</div>
                    </div>
                    <div class="space-y-1">
                      <div class="text-xs opacity-60 font-semibold uppercase tracking-wide">
                        Last login
                      </div>
                      <div class="font-mono">
                        <.user_time
                          id={"settings-auth-user-#{@user.id}-last-login-at"}
                          value={canonical_datetime(@user.last_login_at)}
                          timezone={@current_scope.user.timezone || "Etc/UTC"}
                          style={:compact}
                          fallback="—"
                        />
                      </div>
                    </div>
                  </div>

                  <.ui_button :if={@editing} type="submit" size="sm" variant="primary">
                    Save changes
                  </.ui_button>
                </.form>

                <div class="sr-ui-divider"></div>

                <div class="flex items-center justify-between gap-3">
                  <div>
                    <div class="text-sm font-semibold">Security</div>
                    <div class="text-xs opacity-60">Set a temporary password for this account.</div>
                  </div>
                  <.ui_button
                    type="button"
                    phx-click="open_password_modal"
                    size="sm"
                    variant="outline"
                  >
                    Set password
                  </.ui_button>
                </div>

                <div class="flex items-center justify-between gap-3">
                  <div>
                    <div class="text-sm font-semibold">Local password login</div>
                    <div class="text-xs opacity-60">
                      Allow this account to sign in with a password when SSO is enforced.
                      SSO-only accounts should leave this off.
                    </div>
                  </div>
                  <input
                    type="checkbox"
                    class={ui_toggle_class()}
                    phx-click="toggle_local_login"
                    checked={@user.local_login_enabled == true}
                    aria-label="Local password login enabled"
                  />
                </div>
              </div>
            </div>

            <div :if={@role_mapping_event} class="sr-ui-card bg-sr-surface border border-sr-line">
              <div class="sr-ui-card-body space-y-4">
                <div class="flex items-center justify-between gap-3">
                  <h2 class="sr-ui-card-title text-base">Access from group mappings</h2>
                  <.user_time
                    id={"settings-auth-user-role-mapping-#{@role_mapping_event.id}-inserted-at"}
                    value={canonical_datetime(@role_mapping_event.inserted_at)}
                    timezone={@current_scope.user.timezone || "Etc/UTC"}
                    style={:compact}
                    fallback="—"
                    class="text-xs opacity-60 font-mono"
                  />
                </div>

                <div class="text-xs opacity-70">
                  Applied at this user's last single sign-on. Removing them from a mapped group
                  revokes what it granted at their next sign-in. A role profile or group an
                  operator assigned by hand is not shown here and is never revoked automatically.
                </div>

                <div class="text-sm">
                  Resolved role:
                  <span class="font-mono">
                    {@role_mapping_event.metadata["resolved_role"]}
                  </span>
                </div>

                <div class="sr-ui-table-shell">
                  <table class={ui_table_class(size: "sm", zebra: true)}>
                    <thead>
                      <tr>
                        <th>Matched on</th>
                        <th>Granted</th>
                      </tr>
                    </thead>
                    <tbody>
                      <tr :for={mapping <- mapping_summaries(@role_mapping_event)}>
                        <td class="text-sm font-mono">{mapping_match(mapping)}</td>
                        <td class="text-sm font-mono">{mapping_grant(mapping)}</td>
                      </tr>
                      <tr :if={mapping_summaries(@role_mapping_event) == []}>
                        <td colspan="2" class="text-center opacity-60 py-6">
                          No mapping details recorded.
                        </td>
                      </tr>
                    </tbody>
                  </table>
                </div>
              </div>
            </div>

            <div class="sr-ui-card bg-sr-surface border border-sr-line">
              <div class="sr-ui-card-body space-y-4">
                <div class="flex items-center justify-between gap-3">
                  <h2 class="sr-ui-card-title text-base">Login history</h2>
                  <div class={ui_join_class()}>
                    <.ui_button
                      type="button"
                      phx-click="events_prev"
                      disabled={is_nil(@events_page) or is_nil(@events_page.before)}
                      title="Newer"
                      size="xs"
                      variant="neutral"
                    >
                      <.icon name="hero-chevron-left" class="size-4" />
                    </.ui_button>
                    <.ui_button
                      type="button"
                      phx-click="events_next"
                      disabled={is_nil(@events_page) or not @events_page.more?}
                      title="Older"
                      size="xs"
                      variant="neutral"
                    >
                      <.icon name="hero-chevron-right" class="size-4" />
                    </.ui_button>
                  </div>
                </div>

                <div class="sr-ui-table-shell">
                  <table class={ui_table_class(size: "sm", zebra: true)}>
                    <thead>
                      <tr>
                        <th>Time</th>
                        <th>Event</th>
                        <th>Method</th>
                        <th>IP</th>
                      </tr>
                    </thead>
                    <tbody>
                      <tr :for={event <- @events}>
                        <td class="whitespace-nowrap font-mono text-xs opacity-80">
                          <.user_time
                            id={"settings-auth-user-event-#{event.id}-inserted-at"}
                            value={canonical_datetime(event.inserted_at)}
                            timezone={@current_scope.user.timezone || "Etc/UTC"}
                            style={:compact}
                            fallback="—"
                          />
                        </td>
                        <td class="text-sm">{event.event_type}</td>
                        <td class="text-sm font-mono">{blank_to_dash(event.auth_method)}</td>
                        <td class="text-sm font-mono">{blank_to_dash(event.ip)}</td>
                      </tr>
                      <tr :if={@events == []}>
                        <td colspan="4" class="text-center opacity-60 py-6">
                          No login events yet.
                        </td>
                      </tr>
                    </tbody>
                  </table>
                </div>
              </div>
            </div>
          </div>
        </div>

        <.ui_modal
          id="set-password-modal"
          open={@show_password_modal}
          on_cancel="close_password_modal"
          phx-window-keydown="close_password_modal"
          phx-key="escape"
        >
          <:title>Set password</:title>

          <p class="text-sm text-sr-muted">
            This sets a new local password for <span class="font-mono text-sr-ink">{@user.email}</span>.
          </p>

          <.form
            for={@password_form}
            id="set-password-form"
            phx-submit="set_password"
            class="space-y-4"
          >
            <.input
              field={@password_form[:password]}
              type="password"
              label="New password"
              placeholder="min 12 characters"
              required
              class={ui_field_class(class: "w-full")}
            />

            <div class="flex justify-end gap-2 pt-1">
              <.ui_button phx-click="close_password_modal" type="button" size="sm" variant="outline">
                Cancel
              </.ui_button>
              <.ui_button type="submit" size="sm" variant="primary">
                Update password
              </.ui_button>
            </div>
          </.form>
        </.ui_modal>
      </Shell.settings_chrome>
    </Layouts.app>
    """
  end

  defp default_form(user, role_profiles) do
    %{
      "display_name" => user.display_name || "",
      "role_profile_id" => effective_profile_id(user, role_profiles) || ""
    }
  end

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

  defp profile_options(profiles) do
    profiles
    |> Enum.sort_by(fn profile -> {profile.system || false, profile.name} end, :desc)
    |> Enum.map(fn profile ->
      label = if profile.system, do: "#{profile.name} (system)", else: profile.name
      {label, profile.id}
    end)
  end

  defp normalize_profile_id(nil), do: nil
  defp normalize_profile_id(""), do: nil
  defp normalize_profile_id(value), do: value

  defp maybe_put(attrs, _key, nil), do: attrs
  defp maybe_put(attrs, _key, ""), do: attrs
  defp maybe_put(attrs, key, value), do: Map.put(attrs, key, value)

  defp derive_role_from_profile(attrs, nil, _profiles), do: attrs

  defp derive_role_from_profile(attrs, role_profile_id, profiles) when is_binary(role_profile_id) do
    role =
      case Enum.find(profiles, &(&1.id == role_profile_id)) do
        %{system: true, system_name: "admin"} -> :admin
        %{system: true, system_name: "operator"} -> :operator
        %{system: true, system_name: "helpdesk"} -> :helpdesk
        %{system: true, system_name: "viewer"} -> :viewer
        _ -> :viewer
      end

    Map.put(attrs, :role, role)
  end

  defp canonical_datetime(nil), do: nil

  defp canonical_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _} -> dt
      _ -> canonical_naive_datetime(value)
    end
  end

  defp canonical_datetime(%DateTime{} = dt), do: dt

  defp canonical_datetime(%NaiveDateTime{} = dt), do: DateTime.from_naive!(dt, "Etc/UTC")

  defp canonical_datetime(_), do: nil

  defp canonical_naive_datetime(value) do
    case NaiveDateTime.from_iso8601(value) do
      {:ok, ndt} -> DateTime.from_naive!(ndt, "Etc/UTC")
      _ -> nil
    end
  end

  defp blank_to_dash(nil), do: "—"
  defp blank_to_dash(""), do: "—"
  defp blank_to_dash(value), do: value

  # What the identity provider last granted this user, and which mappings did it.
  # The events feed shows that a role_mapping event happened but not what was in
  # it, which is the half that answers "why does this user have this access".
  defp load_role_mapping_event(scope, user_id) do
    case UserAuthEvent.latest_of_type(user_id, "role_mapping", scope: scope) do
      {:ok, [event | _]} -> event
      _ -> nil
    end
  end

  defp mapping_summaries(nil), do: []

  defp mapping_summaries(event) do
    case event.metadata do
      %{"matched" => matched} when is_list(matched) -> matched
      _ -> []
    end
  end

  defp mapping_grant(%{} = mapping) do
    [
      mapping["role"] && "role #{mapping["role"]}",
      mapping["role_profile_id"] && "profile #{mapping["role_profile_id"]}",
      mapping["user_group_id"] && "group #{mapping["user_group_id"]}"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(", ")
  end

  defp mapping_grant(_mapping), do: ""

  defp mapping_match(%{} = mapping) do
    case mapping["source"] do
      "claim" -> "#{mapping["claim"]} = #{mapping["value"]}"
      source -> "#{source} = #{mapping["value"]}"
    end
  end

  defp mapping_match(_mapping), do: ""

  defp load_events(scope, user_id, after_token, before_token) do
    query = Ash.Query.for_read(UserAuthEvent, :for_user, %{user_id: user_id}, scope: scope)

    page_opts =
      [limit: @event_page_limit]
      |> maybe_put_page(:after, after_token)
      |> maybe_put_page(:before, before_token)

    case Ash.read(query, scope: scope, page: page_opts) do
      {:ok, %Ash.Page.Keyset{} = page} -> {page.results, page}
      {:ok, results} when is_list(results) -> {results, nil}
      {:error, _} -> {[], nil}
    end
  end

  defp maybe_put_page(opts, _key, nil), do: opts
  defp maybe_put_page(opts, _key, ""), do: opts
  defp maybe_put_page(opts, key, value), do: Keyword.put(opts, key, value)

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

  defp user_load_error_message({:http_error, 404, _}), do: "User not found"
  defp user_load_error_message({:http_error, 403, _}), do: "Not authorized"

  defp user_load_error_message({:http_error, status, _}) when is_integer(status),
    do: "Failed to load user (HTTP #{status})"

  defp user_load_error_message(_), do: "Failed to load user"
end
