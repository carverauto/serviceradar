defmodule ServiceRadarWebNGWeb.Settings.AuthorizationLive do
  @moduledoc """
  Admin authorization settings view (default role + role mappings).
  """

  use ServiceRadarWebNGWeb, :live_view

  use Permit.Phoenix.LiveView,
    authorization_module: ServiceRadarWebNGWeb.Authorization,
    resource_module: ServiceRadar.Identity.AuthorizationSettings

  alias ServiceRadar.Identity.AuthSettings
  alias ServiceRadar.Identity.MappedUserGroups
  alias ServiceRadar.Identity.RoleMapping
  alias ServiceRadar.Identity.RoleMappingSupport
  alias ServiceRadar.Identity.RoleProfile
  alias ServiceRadar.Identity.UserGroup
  alias ServiceRadarWebNG.AdminApi
  alias ServiceRadarWebNGWeb.Auth.OIDCStrategy
  alias ServiceRadarWebNGWeb.Settings.Shell

  @auth_manage_permission "settings.auth.manage"
  @built_in_roles ~w(viewer helpdesk operator admin)
  @empty_mapping %{
    "source" => "groups",
    "value" => "",
    "claim" => "",
    "role" => "",
    "role_profile_id" => "",
    "user_group_id" => ""
  }

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    if ServiceRadarWebNG.RBAC.can?(scope, @auth_manage_permission) do
      socket = assign(socket, :page_title, "Authorization Settings")
      sso_auto_provision = sso_auto_provision?(scope)

      {settings, settings_flash} =
        case get_or_create_settings(scope) do
          {:ok, settings} -> {settings, nil}
          {:error, error} -> {%{default_role: :viewer, role_mappings: []}, format_ash_error(error)}
        end

      if connected?(socket) do
        MappedUserGroups.ensure_from_settings()
      end

      {:ok,
       socket
       |> assign(:settings, settings)
       |> assign(:form, to_form(settings_form(settings, sso_auto_provision), as: :settings))
       |> assign(:mapping_rows, mapping_rows(settings))
       |> assign(:mapping_error, nil)
       |> assign(:dry_run_claims, "")
       |> assign(:dry_run_result, nil)
       |> assign(:dry_run_error, nil)
       |> assign(:role_profiles, list_role_profiles(scope))
       |> assign(:user_groups, list_user_groups(scope))
       |> assign(:groups_claim_notices, groups_claim_notices(settings))
       |> maybe_put_flash(settings_flash)}
    else
      {:ok,
       socket
       |> put_flash(:error, "You don't have permission to access Settings.")
       |> push_navigate(to: ~p"/dashboard")}
    end
  end

  @impl true
  def handle_event("validate", %{"settings" => params}, socket) do
    {:noreply,
     socket
     |> assign(:form, to_form(params, as: :settings))
     |> assign(:mapping_rows, params_to_rows(params))
     |> assign(:mapping_error, nil)}
  end

  def handle_event("add_mapping", _params, socket) do
    {:noreply, assign(socket, :mapping_rows, socket.assigns.mapping_rows ++ [@empty_mapping])}
  end

  def handle_event("remove_mapping", %{"idx" => idx}, socket) do
    rows =
      case Integer.parse(idx) do
        {index, ""} -> List.delete_at(socket.assigns.mapping_rows, index)
        _ -> socket.assigns.mapping_rows
      end

    rows = if rows == [], do: [@empty_mapping], else: rows
    {:noreply, assign(socket, :mapping_rows, rows)}
  end

  # A mapping can be checked without attempting a sign-in. Before this, the only
  # way to find out why a mapping did or did not apply was to log in as somebody
  # and see what happened.
  def handle_event("dry_run", %{"dry_run" => %{"claims" => claims_json}}, socket) do
    socket = assign(socket, :dry_run_claims, claims_json)

    with %{user: actor} when not is_nil(actor) <- socket.assigns.current_scope,
         {:ok, claims} <- decode_claims(claims_json) do
      resolution = RoleMapping.resolve(claims, actor: actor)

      {:noreply,
       socket
       |> assign(:dry_run_result, resolution)
       |> assign(:dry_run_error, nil)}
    else
      {:error, message} ->
        {:noreply,
         socket
         |> assign(:dry_run_result, nil)
         |> assign(:dry_run_error, message)}

      _unauthenticated ->
        {:noreply,
         socket
         |> assign(:dry_run_result, nil)
         |> assign(:dry_run_error, "Not authorized")}
    end
  end

  def handle_event("save", %{"settings" => params}, socket) do
    scope = socket.assigns.current_scope
    sso_auto_provision = truthy?(params["sso_auto_provision"])
    rows = params_to_rows(params)

    with {:ok, mappings} <- rows_to_mappings(rows),
         {:ok, attrs} <- normalize_attrs(params, mappings),
         {:ok, _auth_settings} <- persist_sso_auto_provision(scope, sso_auto_provision),
         {:ok, updated} <- AdminApi.update_authorization_settings(scope, attrs) do
      MappedUserGroups.ensure_from_settings()

      {:noreply,
       socket
       |> assign(:settings, updated)
       |> assign(:form, to_form(settings_form(updated, sso_auto_provision), as: :settings))
       |> assign(:mapping_rows, mapping_rows(updated))
       |> assign(:mapping_error, nil)
       |> assign(:user_groups, list_user_groups(scope))
       |> assign(:groups_claim_notices, groups_claim_notices(updated))
       |> put_flash(:info, "Authorization settings updated")}
    else
      {:error, :invalid_role} ->
        {:noreply, put_flash(socket, :error, "Default role must be viewer, helpdesk, operator, or admin")}

      {:error, {:invalid_mapping, index, message}} ->
        {:noreply,
         socket
         |> assign(:mapping_rows, rows)
         |> assign(:mapping_error, "Mapping #{index + 1}: #{message}")}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, format_ash_error(error))}
    end
  end

  @impl true
  def event_mapping do
    Map.merge(Permit.Phoenix.LiveView.default_event_mapping(), %{
      "save" => :update,
      "validate" => :read,
      "dry_run" => :read,
      "add_mapping" => :read,
      "remove_mapping" => :read
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
      |> put_flash(:error, "You don't have permission to access Settings.")
      |> push_navigate(to: ~p"/dashboard")

    {:halt, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <Shell.settings_chrome
        current_path="/settings/auth/authorization"
        current_scope={@current_scope}
        active_view={@settings_active_view}
        active_category={@settings_active_category}
        breadcrumbs={@settings_breadcrumbs}
        nav_tree={@settings_nav_tree}
        palette={@settings_palette}
        stats={@settings_stats}
      >
        <div class="grid gap-6 lg:grid-cols-[minmax(0,1.4fr),minmax(18rem,0.8fr)]">
          <section class="space-y-4">
            <div>
              <h1 class="text-2xl font-semibold text-sr-ink">Authorization</h1>
              <p class="text-sm text-sr-muted">
                Who gets a local account on first SSO login, the default built-in role,
                and how identity-provider groups map onto roles, permission sets, and
                user groups.
              </p>
            </div>

            <.form for={@form} id="authorization-form" phx-change="validate" phx-submit="save">
              <div class="space-y-4">
                <div class="rounded-xl border border-sr-line p-4">
                  <label class="flex items-start justify-between gap-4">
                    <div>
                      <div class="text-sm font-semibold text-sr-ink">
                        Create accounts on first SSO login
                      </div>
                      <p class="mt-1 text-xs text-sr-muted">
                        If an identity-provider user has no local account, create one instead of
                        denying sign-in. The account gets the default role below unless a mapping
                        grants more. Same switch as <.link
                          navigate={~p"/settings/authentication"}
                          class="text-sr-brand hover:underline"
                        >
                          Authentication
                        </.link>.
                      </p>
                    </div>
                    <input type="hidden" name="settings[sso_auto_provision]" value="false" />
                    <input
                      type="checkbox"
                      name="settings[sso_auto_provision]"
                      value="true"
                      checked={@form[:sso_auto_provision].value in [true, "true"]}
                      class={ui_toggle_class(class: "toggle-warning")}
                    />
                  </label>
                </div>

                <.input
                  field={@form[:default_role]}
                  type="select"
                  label="Default built-in role"
                  options={Enum.map(built_in_roles(), &{&1, &1})}
                />
                <p class="text-xs text-sr-muted -mt-2">
                  One of viewer, helpdesk, operator, or admin. Named sets such as <code>demo</code>
                  are <span class="font-medium">role profiles</span>
                  — grant those on a mapping row below, not here.
                </p>

                <div>
                  <div class="flex items-center justify-between gap-2">
                    <span class="text-sm font-medium text-sr-ink">Mappings</span>
                    <.ui_button type="button" size="xs" variant="ghost" phx-click="add_mapping">
                      Add mapping
                    </.ui_button>
                  </div>
                  <p class="mt-1 text-xs text-sr-muted">
                    Each row matches one claim (usually an IdP group) and can grant a built-in
                    role, a role profile, a user group, or any combination.
                  </p>

                  <div :if={@mapping_error} class="mt-2 text-xs text-error">{@mapping_error}</div>

                  <div
                    :for={notice <- @groups_claim_notices}
                    class="mt-2 rounded-xl border border-warning/30 bg-warning/5 p-3 text-xs text-sr-muted"
                  >
                    {notice}
                  </div>

                  <div id="mapping-rows" class="mt-3 space-y-3">
                    <.mapping_editor_row
                      :for={{row, index} <- Enum.with_index(@mapping_rows)}
                      index={index}
                      row={row}
                      role_profiles={@role_profiles}
                      user_groups={@user_groups}
                    />
                  </div>
                </div>
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
                  <span class="text-sr-ink">
                    {Enum.map_join(
                      @dry_run_result.role_profile_ids,
                      ", ",
                      &profile_label(&1, @role_profiles)
                    )}
                  </span>
                </div>
                <div :if={@dry_run_result.user_group_ids != []}>
                  <span class="text-sr-muted">User groups:</span>
                  <span class="text-sr-ink">
                    {Enum.map_join(
                      @dry_run_result.user_group_ids,
                      ", ",
                      &group_label(&1, @user_groups)
                    )}
                  </span>
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
              <h2 class="text-sm font-semibold">Roles versus role profiles</h2>
              <p class="text-xs text-sr-muted mt-2">
                A <span class="font-medium text-sr-ink">built-in role</span>
                is one of four rungs: viewer, helpdesk, operator, admin. They cannot be
                edited. Use a role when the person should have that whole rung.
              </p>
              <p class="text-xs text-sr-muted mt-2">
                A <span class="font-medium text-sr-ink">role profile</span>
                is a named permission set from
                <.link navigate={~p"/settings/auth/rbac"} class="text-sr-brand hover:underline">
                  Policy Editor
                </.link>
                — for example <code>demo</code>
                or Plugin Authors. Map an IdP group to a profile when the team should
                get a specific capability without becoming operator.
              </p>
              <p class="text-xs text-sr-muted mt-2">
                To grant <code>demo</code>
                to an Authentik/Entra group: Add mapping → match <code>groups</code>
                → paste the group name or object ID → Role profile → <code>demo</code>. Leave the built-in role on None unless they also
                need a rung on that ladder.
              </p>
            </div>

            <div class="rounded-xl border border-sr-line bg-sr-surface p-4">
              <h2 class="text-sm font-semibold">How matching works</h2>
              <p class="text-xs text-sr-muted mt-2">
                Every matching row contributes. Profiles and user groups union. The
                highest matched built-in role wins. Mapping order does not matter.
              </p>
              <p class="text-xs text-sr-muted mt-2">
                Entra's <code>groups</code>
                claim is group object IDs by default, not display names. Authentik
                emits group names when the groups scope is requested.
              </p>
            </div>
          </section>
        </div>
      </Shell.settings_chrome>
    </Layouts.app>
    """
  end

  attr :index, :integer, required: true
  attr :row, :map, required: true
  attr :role_profiles, :list, required: true
  attr :user_groups, :list, required: true

  def mapping_editor_row(assigns) do
    ~H"""
    <div class="rounded-xl border border-sr-line p-3 space-y-3">
      <div class="flex items-center justify-between gap-2">
        <span class="text-xs font-medium text-sr-ink">Match</span>
        <.ui_button
          type="button"
          size="xs"
          variant="ghost"
          phx-click="remove_mapping"
          phx-value-idx={Integer.to_string(@index)}
        >
          Remove
        </.ui_button>
      </div>

      <div class="grid gap-3 sm:grid-cols-2">
        <label class="block">
          <span class="text-xs text-sr-muted">Source</span>
          <select
            name={"settings[mappings][#{@index}][source]"}
            class={ui_field_class(size: "sm", class: "mt-1")}
          >
            <option
              :for={{label, value} <- source_options()}
              value={value}
              selected={@row["source"] == value}
            >
              {label}
            </option>
          </select>
        </label>

        <label class="block">
          <span class="text-xs text-sr-muted">Value</span>
          <input
            type="text"
            name={"settings[mappings][#{@index}][value]"}
            value={@row["value"]}
            placeholder={value_placeholder(@row["source"])}
            class={ui_field_class(size: "sm", class: "mt-1", mono: true)}
          />
        </label>
      </div>

      <label :if={@row["source"] == "claim"} class="block">
        <span class="text-xs text-sr-muted">Claim name</span>
        <input
          type="text"
          name={"settings[mappings][#{@index}][claim]"}
          value={@row["claim"]}
          placeholder="department"
          class={ui_field_class(size: "sm", class: "mt-1", mono: true)}
        />
      </label>
      <input
        :if={@row["source"] != "claim"}
        type="hidden"
        name={"settings[mappings][#{@index}][claim]"}
        value={@row["claim"]}
      />

      <div class="text-xs font-medium text-sr-ink">Grant</div>
      <div class="grid gap-3 sm:grid-cols-3">
        <label class="block">
          <span class="text-xs text-sr-muted">Built-in role</span>
          <select
            name={"settings[mappings][#{@index}][role]"}
            class={ui_field_class(size: "sm", class: "mt-1")}
          >
            <option value="" selected={@row["role"] == ""}>None</option>
            <option :for={role <- built_in_roles()} value={role} selected={@row["role"] == role}>
              {role}
            </option>
          </select>
        </label>

        <label class="block">
          <span class="text-xs text-sr-muted">Role profile</span>
          <select
            name={"settings[mappings][#{@index}][role_profile_id]"}
            class={ui_field_class(size: "sm", class: "mt-1")}
          >
            <option value="" selected={@row["role_profile_id"] == ""}>None</option>
            <option
              :for={profile <- @role_profiles}
              value={profile.id}
              selected={@row["role_profile_id"] == to_string(profile.id)}
            >
              {profile.name}
            </option>
          </select>
        </label>

        <label class="block">
          <span class="text-xs text-sr-muted">User group</span>
          <select
            name={"settings[mappings][#{@index}][user_group_id]"}
            class={ui_field_class(size: "sm", class: "mt-1")}
          >
            <option value="" selected={@row["user_group_id"] == ""}>None</option>
            <option
              :for={group <- @user_groups}
              value={group.id}
              selected={@row["user_group_id"] == to_string(group.id)}
            >
              {group.name}
            </option>
          </select>
        </label>
      </div>
    </div>
    """
  end

  defp get_or_create_settings(scope) do
    AdminApi.get_authorization_settings(scope)
  end

  defp sso_auto_provision?(scope) do
    case scope do
      %{user: user} when not is_nil(user) ->
        case AuthSettings.get_settings(actor: user) do
          {:ok, %{sso_auto_provision: true}} -> true
          _ -> false
        end

      _ ->
        false
    end
  end

  defp persist_sso_auto_provision(scope, enabled) when is_boolean(enabled) do
    user = scope.user

    case AuthSettings.get_settings(actor: user) do
      {:ok, %{sso_auto_provision: ^enabled} = settings} ->
        {:ok, settings}

      {:ok, %{} = settings} ->
        AuthSettings.update(settings, %{sso_auto_provision: enabled}, actor: user)

      {:ok, nil} ->
        {:error, :auth_settings_unavailable}

      {:error, error} ->
        {:error, error}
    end
  end

  defp truthy?(value) when value in [true, "true", "on", "1"], do: true
  defp truthy?(values) when is_list(values), do: Enum.any?(values, &truthy?/1)
  defp truthy?(_value), do: false

  defp normalize_attrs(params, mappings) do
    with {:ok, default_role} <- normalize_role(params["default_role"]) do
      attrs =
        if is_nil(default_role) do
          %{role_mappings: mappings}
        else
          %{default_role: default_role, role_mappings: mappings}
        end

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

  defp list_role_profiles(scope) do
    case Ash.read(RoleProfile, scope: scope) do
      {:ok, profiles} -> Enum.sort_by(profiles, & &1.name)
      {:error, _reason} -> []
    end
  end

  defp list_user_groups(scope) do
    case Ash.read(UserGroup, scope: scope) do
      {:ok, groups} -> Enum.sort_by(groups, & &1.name)
      {:error, _reason} -> []
    end
  end

  defp mapping_rows(settings) do
    case Map.get(settings, :role_mappings) || [] do
      [] -> [@empty_mapping]
      mappings -> Enum.map(mappings, &mapping_to_row/1)
    end
  end

  defp mapping_to_row(mapping) do
    source =
      case stringify(RoleMappingSupport.get_key(mapping, "source")) do
        "" -> "groups"
        value -> value
      end

    %{
      "source" => source,
      "value" => stringify(RoleMappingSupport.get_key(mapping, "value")),
      "claim" => stringify(RoleMappingSupport.get_key(mapping, "claim")),
      "role" => stringify(RoleMappingSupport.get_key(mapping, "role")),
      "role_profile_id" => stringify(RoleMappingSupport.get_key(mapping, "role_profile_id")),
      "user_group_id" => stringify(RoleMappingSupport.get_key(mapping, "user_group_id"))
    }
  end

  defp params_to_rows(%{"mappings" => mappings}) when is_map(mappings) do
    mappings
    |> Enum.sort_by(fn {idx, _} ->
      case Integer.parse(idx) do
        {int, ""} -> int
        _ -> 0
      end
    end)
    |> Enum.map(fn {_idx, row} -> mapping_to_row(row) end)
  end

  defp params_to_rows(_params), do: [@empty_mapping]

  defp rows_to_mappings(rows) do
    rows
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {row, index}, {:ok, acc} ->
      case row_to_mapping(row) do
        :skip -> {:cont, {:ok, acc}}
        {:ok, mapping} -> {:cont, {:ok, acc ++ [mapping]}}
        {:error, message} -> {:halt, {:error, {:invalid_mapping, index, message}}}
      end
    end)
  end

  defp row_to_mapping(row) do
    source = String.trim(row["source"] || "")
    value = String.trim(row["value"] || "")
    claim = String.trim(row["claim"] || "")
    role = String.trim(row["role"] || "")
    profile_id = String.trim(row["role_profile_id"] || "")
    group_id = String.trim(row["user_group_id"] || "")
    blank_grants? = role == "" and profile_id == "" and group_id == ""

    cond do
      value == "" and blank_grants? and (source != "claim" or claim == "") ->
        :skip

      value == "" ->
        {:error, "value is required"}

      blank_grants? ->
        {:error, "choose a built-in role, a role profile, or a user group"}

      source == "claim" and claim == "" ->
        {:error, "claim name is required"}

      true ->
        mapping =
          %{"source" => source, "value" => value}
          |> maybe_put("claim", if(source == "claim", do: claim))
          |> maybe_put("role", empty_to_nil(role))
          |> maybe_put("role_profile_id", empty_to_nil(profile_id))
          |> maybe_put("user_group_id", empty_to_nil(group_id))

        {:ok, mapping}
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp empty_to_nil(""), do: nil
  defp empty_to_nil(value), do: value

  defp stringify(nil), do: ""
  defp stringify(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify(value) when is_binary(value), do: value
  defp stringify(value), do: to_string(value)

  defp built_in_roles, do: @built_in_roles

  defp source_options do
    [
      {"IdP group", "groups"},
      {"Email domain", "email_domain"},
      {"Email address", "email"},
      {"Named claim", "claim"}
    ]
  end

  defp value_placeholder("email_domain"), do: "example.com"
  defp value_placeholder("email"), do: "user@example.com"
  defp value_placeholder("claim"), do: "claim value"
  defp value_placeholder(_), do: "group name or Entra object ID"

  defp profile_label(id, profiles) do
    case Enum.find(profiles, &(to_string(&1.id) == to_string(id))) do
      nil -> id
      profile -> profile.name
    end
  end

  defp group_label(id, groups) do
    case Enum.find(groups, &(to_string(&1.id) == to_string(id))) do
      nil -> id
      group -> group.name
    end
  end

  # Groups mappings fail closed when the claim never arrives. Authentik and
  # similar providers emit it only if the `groups` scope is requested. Entra
  # does not have a groups scope at all — membership is added under Token
  # configuration and the claim is object IDs. Treating those as the same
  # problem made Entra look unconfigured when it was working as designed.
  defp groups_claim_notices(settings) do
    mappings = Map.get(settings, :role_mappings) || []
    uses_groups? = Enum.any?(mappings, &(Map.get(&1, "source") == "groups"))

    if uses_groups? do
      entra =
        "Microsoft Entra emits a groups claim only after Token configuration adds it; " <>
          "there is no groups scope. The claim contains group object IDs by default, " <>
          "not display names. Users in ~150+ groups hit overage and send no groups claim."

      scope =
        if groups_scope_requested?() do
          nil
        else
          "Authentik and similar providers need the groups scope under Settings -> " <>
            "Authentication; without it those mappings will never match."
        end

      Enum.reject([scope, entra], &is_nil/1)
    else
      []
    end
  end

  defp groups_scope_requested? do
    Enum.any?(OIDCStrategy.scopes(), &(&1 in ["groups", "roles"]))
  rescue
    _error -> true
  end

  defp settings_form(settings, sso_auto_provision) do
    %{
      "default_role" => Atom.to_string(settings.default_role || :viewer),
      "sso_auto_provision" => sso_auto_provision
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

  defp format_ash_error(:auth_settings_unavailable), do: "Authentication settings are not configured"

  defp format_ash_error(_), do: "Unexpected error"
end
