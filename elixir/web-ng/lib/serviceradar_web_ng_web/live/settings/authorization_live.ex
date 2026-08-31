defmodule ServiceRadarWebNGWeb.Settings.AuthorizationLive do
  @moduledoc """
  Admin authorization settings view (default role + role mappings).
  """

  use ServiceRadarWebNGWeb, :live_view

  use Permit.Phoenix.LiveView,
    authorization_module: ServiceRadarWebNGWeb.Authorization,
    resource_module: ServiceRadar.Identity.AuthorizationSettings

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Identity.RoleMapping
  alias ServiceRadar.Identity.RoleProfile
  alias ServiceRadar.Identity.UserGroup
  alias ServiceRadarWebNG.AdminApi
  alias ServiceRadarWebNGWeb.Auth.OIDCStrategy
  alias ServiceRadarWebNGWeb.SettingsComponents

  @impl true
  def mount(_params, _session, socket) do
    socket = assign(socket, :page_title, "Authorization Settings")
    scope = socket.assigns.current_scope

    {settings, settings_flash} =
      case get_or_create_settings(scope) do
        {:ok, settings} -> {settings, nil}
        {:error, error} -> {%{default_role: :viewer, role_mappings: []}, format_ash_error(error)}
      end

    {:ok,
     socket
     |> assign(:settings, settings)
     |> assign(:form, to_form(settings_form(settings), as: :settings))
     |> assign(:json_error, nil)
     |> assign(:dry_run_claims, "")
     |> assign(:dry_run_result, nil)
     |> assign(:dry_run_error, nil)
     |> assign(:role_profiles, list_role_profiles(scope))
     |> assign(:user_groups, list_user_groups(scope))
     |> assign(:groups_scope_warning, groups_scope_warning(settings))
     |> maybe_put_flash(settings_flash)}
  end

  @impl true
  def handle_event("validate", %{"settings" => params}, socket) do
    {:noreply, assign(socket, :form, to_form(params, as: :settings))}
  end

  # A mapping can be checked without attempting a sign-in. Before this, the only
  # way to find out why a mapping did or did not apply was to log in as somebody
  # and see what happened.
  def handle_event("dry_run", %{"dry_run" => %{"claims" => claims_json}}, socket) do
    socket = assign(socket, :dry_run_claims, claims_json)

    case decode_claims(claims_json) do
      {:ok, claims} ->
        resolution = RoleMapping.resolve(claims, actor: scope_actor(socket.assigns.current_scope))

        {:noreply,
         socket
         |> assign(:dry_run_result, resolution)
         |> assign(:dry_run_error, nil)}

      {:error, message} ->
        {:noreply,
         socket
         |> assign(:dry_run_result, nil)
         |> assign(:dry_run_error, message)}
    end
  end

  def handle_event("save", %{"settings" => params}, socket) do
    scope = socket.assigns.current_scope

    with {:ok, attrs} <- normalize_attrs(params),
         {:ok, updated} <- AdminApi.update_authorization_settings(scope, attrs) do
      {:noreply,
       socket
       |> assign(:settings, updated)
       |> assign(:form, to_form(settings_form(updated), as: :settings))
       |> assign(:json_error, nil)
       |> put_flash(:info, "Authorization settings updated")}
    else
      {:error, :invalid_role} ->
        {:noreply, put_flash(socket, :error, "Default role must be viewer, helpdesk, operator, or admin")}

      {:error, :invalid_json} ->
        {:noreply, assign(socket, :json_error, "Role mappings must be valid JSON")}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, format_ash_error(error))}
    end
  end

  @impl true
  def event_mapping do
    Map.merge(Permit.Phoenix.LiveView.default_event_mapping(), %{"save" => :update, "validate" => :read})
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
      <SettingsComponents.settings_shell current_path="/settings/auth/authorization">
        <div class="space-y-4">
          <SettingsComponents.settings_nav
            current_path="/settings/auth/authorization"
            current_scope={@current_scope}
          />
          <SettingsComponents.auth_nav
            current_path="/settings/auth/authorization"
            current_scope={@current_scope}
          />
        </div>

        <div class="grid gap-6 lg:grid-cols-[1fr,1fr]">
          <section class="space-y-4">
            <div>
              <h1 class="text-xl font-semibold">Authorization</h1>
              <p class="text-sm text-sr-muted">
                Control default roles and IdP role mapping behavior.
              </p>
            </div>

            <.form for={@form} id="authorization-form" phx-change="validate" phx-submit="save">
              <div class="space-y-4">
                <.input
                  field={@form[:default_role]}
                  type="select"
                  label="Default Role"
                  options={[
                    {"viewer", "viewer"},
                    {"helpdesk", "helpdesk"},
                    {"operator", "operator"},
                    {"admin", "admin"}
                  ]}
                />

                <div>
                  <label class="flex items-center justify-between gap-2">
                    <span class="text-sm font-medium text-sr-ink">Role Mappings (JSON)</span>
                  </label>
                  <textarea
                    name="settings[role_mappings]"
                    class={ui_field_class(class: "w-full min-h-[200px] py-2.5")}
                  ><%= @form[:role_mappings].value %></textarea>
                  <%= if @json_error do %>
                    <div class="text-xs text-error mt-2">{@json_error}</div>
                  <% else %>
                    <div class="text-xs text-sr-muted mt-2">
                      A JSON array of mapping objects. Each must grant at least one of <code>role</code>,
                      <code>role_profile_id</code>
                      or <code>user_group_id</code>.
                      When several mappings match, profiles and groups union and the
                      highest matched role wins.
                    </div>
                  <% end %>

                  <div
                    :if={@groups_scope_warning}
                    class="mt-2 rounded-xl border border-warning/30 bg-warning/5 p-3 text-xs text-sr-muted"
                  >
                    {@groups_scope_warning}
                  </div>
                </div>

                <%!--
                  The editor is raw JSON, so ids have to be pasted. Listing them
                  here is what keeps that from being a hunt through another page.
                --%>
                <details class="rounded-xl border border-sr-line p-3">
                  <summary class="cursor-pointer text-xs font-medium text-sr-ink">
                    Available role profiles and user groups
                  </summary>
                  <div class="mt-3 grid gap-4 sm:grid-cols-2">
                    <div>
                      <div class="text-xs font-medium text-sr-ink">Role profiles</div>
                      <ul class="mt-1 space-y-1">
                        <li :for={profile <- @role_profiles} class="text-xs text-sr-muted">
                          <span class="font-medium">{profile.name}</span>
                          <code class="ml-1 select-all">{profile.id}</code>
                        </li>
                        <li :if={@role_profiles == []} class="text-xs text-sr-muted">
                          None defined.
                        </li>
                      </ul>
                    </div>
                    <div>
                      <div class="text-xs font-medium text-sr-ink">User groups</div>
                      <ul class="mt-1 space-y-1">
                        <li :for={group <- @user_groups} class="text-xs text-sr-muted">
                          <span class="font-medium">{group.name}</span>
                          <code class="ml-1 select-all">{group.id}</code>
                        </li>
                        <li :if={@user_groups == []} class="text-xs text-sr-muted">None defined.</li>
                      </ul>
                    </div>
                  </div>
                </details>
              </div>

              <div class="mt-6">
                <.ui_button type="submit" size="sm" variant="primary">Save Settings</.ui_button>
              </div>
            </.form>

            <div class="mt-8 border-t border-sr-line pt-6">
              <div class="text-sm font-semibold text-sr-ink">Test a claim set</div>
              <p class="mt-1 text-xs text-sr-muted">
                Paste the claims an identity provider would send and see exactly what they
                would grant, without signing anyone in.
              </p>

              <form id="dry-run-form" phx-submit="dry_run" class="mt-3 space-y-3">
                <textarea
                  name="dry_run[claims]"
                  placeholder={~s({"email": "user@example.com", "groups": ["SR-Plugin-Authors"]})}
                  class={ui_field_class(class: "w-full min-h-[120px] py-2.5 font-mono")}
                ><%= @dry_run_claims %></textarea>
                <.ui_button type="submit" size="sm" variant="ghost">Resolve</.ui_button>
              </form>

              <div
                :if={@dry_run_error}
                class="mt-3 rounded-xl border border-error/30 bg-error/5 p-3 text-xs text-error"
              >
                {@dry_run_error}
              </div>

              <div
                :if={@dry_run_result}
                class="mt-3 space-y-2 rounded-xl border border-sr-line p-3 text-xs"
              >
                <div>
                  <span class="text-sr-muted">Resolved role:</span>
                  <span class="font-medium text-sr-ink">{@dry_run_result.role}</span>
                  <span :if={@dry_run_result.matched == []} class="text-sr-muted">
                    (no mapping matched; this is the configured default)
                  </span>
                </div>
                <div :if={@dry_run_result.role_profile_ids != []}>
                  <span class="text-sr-muted">Role profiles:</span>
                  <code>{Enum.join(@dry_run_result.role_profile_ids, ", ")}</code>
                </div>
                <div :if={@dry_run_result.user_group_ids != []}>
                  <span class="text-sr-muted">User groups:</span>
                  <code>{Enum.join(@dry_run_result.user_group_ids, ", ")}</code>
                </div>
                <div>
                  <span class="text-sr-muted">Matched mappings:</span>
                  <span :if={@dry_run_result.matched == []} class="text-sr-ink">none</span>
                  <ul :if={@dry_run_result.matched != []} class="mt-1 space-y-1">
                    <li :for={mapping <- @dry_run_result.matched} class="text-sr-ink">
                      <code>{Map.get(mapping, "source")}</code>
                      = <code>{Map.get(mapping, "value")}</code>
                    </li>
                  </ul>
                </div>
              </div>
            </div>
          </section>

          <section class="space-y-4">
            <div class="rounded-xl border border-sr-line bg-sr-surface p-4">
              <h2 class="text-sm font-semibold">Example Mapping</h2>
              <p class="text-xs text-sr-muted mt-1">
                Use IdP claims to assign roles automatically.
              </p>
              <pre class="mt-3 rounded-lg bg-sr-subtle/60 p-3 text-xs" phx-no-curly-interpolation>
                [
                  {"source": "groups", "value": "Network Ops", "role": "operator"},
                  {"source": "email_domain", "value": "example.com", "role": "admin"}
                ]
              </pre>
              <p class="text-xs text-sr-muted mt-3">
                Precedence is <span class="font-medium">first match</span>: the first mapping whose
                claim matches a user wins, so list the most privileged roles first (admin-first) to
                avoid a broader rule shadowing a narrower one.
              </p>
            </div>
          </section>
        </div>
      </SettingsComponents.settings_shell>
    </Layouts.app>
    """
  end

  defp get_or_create_settings(scope) do
    AdminApi.get_authorization_settings(scope)
  end

  defp normalize_attrs(params) do
    with {:ok, default_role} <- normalize_role(params["default_role"]),
         {:ok, role_mappings} <- decode_role_mappings(params["role_mappings"]) do
      attrs = %{}

      attrs =
        if is_nil(default_role) do
          attrs
        else
          Map.put(attrs, :default_role, default_role)
        end

      attrs = Map.put(attrs, :role_mappings, role_mappings)

      {:ok, attrs}
    end
  end

  defp normalize_role(nil), do: {:ok, nil}
  defp normalize_role(""), do: {:ok, nil}
  defp normalize_role("viewer"), do: {:ok, :viewer}
  defp normalize_role("helpdesk"), do: {:ok, :helpdesk}
  defp normalize_role("operator"), do: {:ok, :operator}
  defp normalize_role("admin"), do: {:ok, :admin}
  defp normalize_role(_), do: {:error, :invalid_role}

  defp decode_claims(""), do: {:error, "Paste a JSON object of claims"}

  defp decode_claims(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, claims} when is_map(claims) -> {:ok, claims}
      {:ok, _other} -> {:error, "Claims must be a JSON object"}
      {:error, error} -> {:error, "Invalid JSON: " <> Exception.message(error)}
    end
  end

  defp decode_claims(_json), do: {:error, "Paste a JSON object of claims"}

  defp scope_actor(%{user: user}) when not is_nil(user), do: user
  defp scope_actor(_scope), do: SystemActor.system(:authorization_settings_dry_run)

  defp list_role_profiles(scope) do
    case Ash.read(RoleProfile, actor: scope_actor(scope)) do
      {:ok, profiles} -> Enum.sort_by(profiles, & &1.name)
      {:error, _reason} -> []
    end
  end

  defp list_user_groups(scope) do
    case Ash.read(UserGroup, actor: scope_actor(scope)) do
      {:ok, groups} -> Enum.sort_by(groups, & &1.name)
      {:error, _reason} -> []
    end
  end

  # A `groups` mapping with the groups scope unrequested silently matches
  # nothing and falls through to the default role, which looks like a broken
  # mapping rather than a missing scope.
  defp groups_scope_warning(settings) do
    mappings = Map.get(settings, :role_mappings) || []
    uses_groups? = Enum.any?(mappings, &(Map.get(&1, "source") == "groups"))

    if uses_groups? and not groups_scope_requested?() do
      "One or more mappings match on group claims, but the configured OIDC scopes do not " <>
        "request \"groups\". Those mappings will never match. Add the scope in " <>
        "Settings -> Authentication."
    end
  end

  defp groups_scope_requested? do
    Enum.any?(OIDCStrategy.scopes(), &(&1 in ["groups", "roles"]))
  rescue
    _error -> true
  end

  defp decode_role_mappings(nil), do: {:ok, []}
  defp decode_role_mappings(""), do: {:ok, []}

  defp decode_role_mappings(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} when is_list(decoded) -> {:ok, decoded}
      _ -> {:error, :invalid_json}
    end
  end

  defp settings_form(settings) do
    %{
      "default_role" => Atom.to_string(settings.default_role || :viewer),
      "role_mappings" => Jason.encode!(settings.role_mappings || [], pretty: true)
    }
  end

  defp maybe_put_flash(socket, nil), do: socket
  defp maybe_put_flash(socket, message), do: put_flash(socket, :error, message)

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
