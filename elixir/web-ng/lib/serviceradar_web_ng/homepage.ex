defmodule ServiceRadarWebNG.Homepage do
  @moduledoc """
  Resolves where an authenticated user lands (`add-configurable-default-homepage`).

  Precedence (D2), first match wins:

    1. a sanitized `return_to` / deep link (decided by the caller)
    2. the user's own homepage
    3. the best group homepage (D3: lowest `homepage_priority`, then
       case-insensitive name, then id)
    4. the deployment default from `AuthorizationSettings`
    5. `/dashboard`

  A `dashboard` candidate passes only if the target is readable *as the
  signing-in user* right now; otherwise the resolver moves on. Group
  candidates are checked in rank order, so an unreadable high-priority group
  never hides a readable lower one. Only an explicitly chosen user homepage
  that falls through is reported, so the caller can flash a notice.

  The stored preference rows are read with a system actor; the dashboard
  check is always made with the user's own scope.

  Also owns the single-string encoding the settings forms use for a homepage
  choice (`encode_choice/1` / `decode_choice/1`) and the picker options.
  """

  use Boundary,
    top_level?: true,
    deps: [ServiceRadarWebNG, ServiceRadarWebNG.Dashboards],
    exports: :all

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Identity.AuthorizationSettings
  alias ServiceRadar.Identity.Homepage
  alias ServiceRadar.Identity.User
  alias ServiceRadar.Identity.UserGroup
  alias ServiceRadar.Identity.UserGroupMembership
  alias ServiceRadarWebNG.Dashboards

  require Ash.Query

  @fallback_path "/dashboard"
  @overview_path "/dashboard"
  @dashboards_index_path "/dashboards"

  @type result :: %{
          path: String.t(),
          source: :user | :group | :deployment | :fallback,
          user_homepage_unavailable?: boolean()
        }

  @doc "The path used when nothing else applies."
  @spec fallback_path() :: String.t()
  def fallback_path, do: @fallback_path

  @doc """
  Resolves the landing path for `scope.user`, ignoring any return path.
  """
  @spec resolve(term()) :: result()
  def resolve(%{user: %{id: _} = user} = scope) do
    user_homepage = Homepage.stored(Map.get(user, :homepage))

    case candidate_path(user_homepage, scope) do
      {:ok, path} ->
        %{path: path, source: :user, user_homepage_unavailable?: false}

      :error ->
        user_unavailable? = not is_nil(user_homepage)

        scope
        |> inherited(user)
        |> Map.put(:user_homepage_unavailable?, user_unavailable?)
    end
  end

  def resolve(_scope), do: %{path: @fallback_path, source: :fallback, user_homepage_unavailable?: false}

  @doc """
  The path a homepage leads to for `scope`, or `:error` when it is unset or
  its dashboard is not readable by `scope` at this moment.
  """
  @spec candidate_path(Homepage.t() | nil, term()) :: {:ok, String.t()} | :error
  def candidate_path(nil, _scope), do: :error
  def candidate_path(%{"kind" => "overview"}, _scope), do: {:ok, @overview_path}
  def candidate_path(%{"kind" => "dashboards_index"}, _scope), do: {:ok, @dashboards_index_path}

  def candidate_path(%{"kind" => "dashboard"} = homepage, scope) do
    case Homepage.load_target(homepage, scope: scope) do
      {:ok, {:authored, dashboard}} ->
        {:ok, "/dashboard/" <> segment(Dashboards.authored_dashboard_route_ref(dashboard))}

      {:ok, {:package, instance}} ->
        {:ok, "/dashboards/" <> segment(instance.route_slug)}

      :error ->
        :error
    end
  end

  def candidate_path(_homepage, _scope), do: :error

  defp inherited(scope, user) do
    with :error <- group_path(scope, user),
         :error <- deployment_path(scope) do
      %{path: @fallback_path, source: :fallback}
    else
      {:ok, path, source} -> %{path: path, source: source}
    end
  end

  defp group_path(scope, user) do
    user
    |> ranked_group_homepages()
    |> Enum.find_value(:error, fn homepage ->
      case candidate_path(homepage, scope) do
        {:ok, path} -> {:ok, path, :group}
        :error -> nil
      end
    end)
  end

  @doc """
  The user's group homepages in D3 rank order (priority, lower(name), id).
  """
  @spec ranked_group_homepages(map()) :: [Homepage.t()]
  def ranked_group_homepages(%{id: user_id}) do
    UserGroupMembership
    |> Ash.Query.for_read(:by_user, %{user_id: user_id})
    |> Ash.Query.load(:group)
    |> Ash.read(actor: system_actor())
    |> case do
      {:ok, memberships} ->
        memberships
        |> Enum.map(& &1.group)
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq_by(& &1.id)
        |> Enum.map(&{&1, Homepage.stored(&1.homepage)})
        |> Enum.reject(fn {_group, homepage} -> is_nil(homepage) end)
        |> Enum.sort_by(fn {group, _homepage} -> group_rank(group) end)
        |> Enum.map(fn {_group, homepage} -> homepage end)

      {:error, _reason} ->
        []
    end
  end

  @doc "D3 sort key for a group."
  @spec group_rank(map()) :: {integer(), String.t(), String.t()}
  def group_rank(group) do
    {group.homepage_priority || 100, String.downcase(group.name || ""), to_string(group.id)}
  end

  defp deployment_path(scope) do
    case deployment_homepage() do
      nil ->
        :error

      homepage ->
        case candidate_path(homepage, scope) do
          {:ok, path} -> {:ok, path, :deployment}
          :error -> :error
        end
    end
  end

  @doc "The deployment default homepage, or nil."
  @spec deployment_homepage() :: Homepage.t() | nil
  def deployment_homepage do
    case AuthorizationSettings.get_settings(actor: system_actor()) do
      {:ok, %AuthorizationSettings{default_homepage: homepage}} -> Homepage.stored(homepage)
      _other -> nil
    end
  end

  ## Writing

  @doc "Sets (or clears, with nil) the acting user's own homepage."
  @spec set_user_homepage(term(), Homepage.t() | map() | nil) :: {:ok, User.t()} | {:error, term()}
  def set_user_homepage(%{user: %User{} = user} = scope, homepage) do
    User.update_homepage_preference(user, homepage, scope: scope)
  end

  def set_user_homepage(%{user: %{id: id}} = scope, homepage) when is_binary(id) do
    with {:ok, user} <- User.get_by_id(id, scope: scope) do
      User.update_homepage_preference(user, homepage, scope: scope)
    end
  end

  def set_user_homepage(_scope, _homepage), do: {:error, :unauthenticated}

  @doc """
  Sets (or clears) a user group's homepage and tie-break priority. Requires
  `identity.user_groups.manage`, enforced by the resource policy.
  """
  @spec set_group_homepage(
          term(),
          String.t(),
          Homepage.t() | map() | nil,
          integer() | String.t() | nil
        ) :: {:ok, UserGroup.t()} | {:error, term()}
  def set_group_homepage(scope, group_id, homepage, priority) when is_binary(group_id) do
    with {:ok, group} <- Ash.get(UserGroup, group_id, scope: scope) do
      priority = if priority in [nil, ""], do: group.homepage_priority, else: priority

      group
      |> Ash.Changeset.for_update(
        :update_homepage,
        %{homepage: homepage, homepage_priority: priority},
        scope: scope
      )
      |> Ash.update()
    end
  end

  def set_group_homepage(_scope, _group_id, _homepage, _priority), do: {:error, :not_found}

  @doc """
  Sets (or clears) the deployment default homepage. Requires the
  authorization-settings manage permission, enforced by the resource policy.
  """
  @spec set_deployment_homepage(term(), Homepage.t() | map() | nil) ::
          {:ok, AuthorizationSettings.t()} | {:error, term()}
  def set_deployment_homepage(scope, homepage) do
    AuthorizationSettings.save_default_homepage(homepage, scope: scope)
  end

  @doc """
  True when a dashboard homepage set for an audience (a group, or everyone
  when `group_id` is nil) is not visible to that whole audience: the
  dashboard is not public and, for a group, not granted to it (D4). Members
  who cannot open it fall through at sign-in, so this only warns.
  """
  @spec audience_gap?(term(), Homepage.t() | nil, String.t() | nil) :: boolean()
  def audience_gap?(scope, homepage, group_id) do
    case Homepage.load_target(homepage || %{}, scope: scope) do
      {:ok, {_type, %{visibility: :public}}} ->
        false

      {:ok, {_type, _target}} when is_nil(group_id) ->
        true

      {:ok, {:authored, dashboard}} ->
        not granted_to_group?(fn -> Dashboards.list_authored_access_grants(scope, dashboard.id) end, group_id)

      {:ok, {:package, instance}} ->
        not granted_to_group?(fn -> Dashboards.list_instance_access_grants(scope, instance.id) end, group_id)

      :error ->
        false
    end
  end

  defp granted_to_group?(list_grants, group_id) do
    list_grants.() |> List.wrap() |> Enum.any?(&(Map.get(&1, :subject_group_id) == group_id))
  rescue
    _error -> false
  end

  ## Form choices

  @doc """
  Encodes a homepage as the single string a `<select>` submits:
  `""` (inherit), `"overview"`, `"dashboards_index"`, `"authored:<uuid>"` or
  `"package:<slug>"`.
  """
  @spec encode_choice(Homepage.t() | nil) :: String.t()
  def encode_choice(nil), do: ""
  def encode_choice(%{"kind" => "dashboard", "target_type" => type, "target_id" => id}), do: type <> ":" <> id
  def encode_choice(%{"kind" => kind}), do: kind
  def encode_choice(_homepage), do: ""

  @doc "Decodes `encode_choice/1` output; anything else is an error, never a path."
  @spec decode_choice(term()) :: {:ok, Homepage.t() | nil} | {:error, String.t()}
  def decode_choice(value) when value in [nil, ""], do: {:ok, nil}

  def decode_choice(value) when is_binary(value) do
    case String.split(value, ":", parts: 2) do
      [kind] when kind in ["overview", "dashboards_index"] ->
        Homepage.normalize(%{"kind" => kind})

      [type, id] when type in ["authored", "package"] ->
        Homepage.normalize(%{"kind" => "dashboard", "target_type" => type, "target_id" => id})

      _other ->
        {:error, "has an unsupported kind"}
    end
  end

  def decode_choice(_value), do: {:error, "has an unsupported kind"}

  @doc """
  Dashboard picker options readable by `scope`, as `{label, choice}` pairs:
  the two fixed pages followed by every authored dashboard and enabled
  package instance the actor can open.
  """
  @spec dashboard_choices(term()) :: [{String.t(), String.t()}]
  def dashboard_choices(scope) do
    authored =
      scope
      |> Dashboards.list_authored_dashboards(%{status: [:draft, :active], limit: 200})
      |> Enum.map(&{"Dashboard: " <> (&1.title || &1.slug || to_string(&1.id)), "authored:" <> to_string(&1.id)})

    packages =
      [scope: scope]
      |> Dashboards.enabled_package_instances()
      |> Enum.map(fn instance ->
        {"Dashboard: " <> (instance.name || instance.route_slug), "package:" <> instance.route_slug}
      end)

    Enum.sort_by(authored ++ packages, fn {label, _choice} -> String.downcase(label) end)
  end

  @doc "The fixed (non-dashboard) homepage choices."
  @spec page_choices() :: [{String.t(), String.t()}]
  def page_choices, do: [{"Overview", "overview"}, {"Dashboards list", "dashboards_index"}]

  @doc "A short human label for a stored homepage, for cards and summaries."
  @spec describe(Homepage.t() | nil, [{String.t(), String.t()}]) :: String.t()
  def describe(nil, _choices), do: "None"

  def describe(homepage, choices) do
    choice = encode_choice(homepage)

    case List.keyfind(page_choices() ++ choices, choice, 1) do
      {label, _choice} -> label
      nil -> "Dashboard you cannot open"
    end
  end

  defp segment(value), do: URI.encode(to_string(value), &URI.char_unreserved?/1)

  defp system_actor, do: SystemActor.system(:homepage_resolution)
end
