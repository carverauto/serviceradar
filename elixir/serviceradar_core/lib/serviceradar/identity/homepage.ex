defmodule ServiceRadar.Identity.Homepage do
  @moduledoc """
  The typed homepage choice shared by users, user groups and the deployment
  default (`add-configurable-default-homepage`, D1).

  A homepage is never a URL. It is one of:

    * `%{"kind" => "overview"}` - the overview dashboard
    * `%{"kind" => "dashboards_index"}` - the dashboards list
    * `%{"kind" => "dashboard", "target_type" => "authored" | "package", "target_id" => id}`

  where `target_id` is an authored dashboard UUID or a dashboard package route
  slug. The web layer derives the redirect path from this value, so nothing a
  client submits is ever redirected to. `nil` means "inherit".

  Values are stored as string-keyed maps in `jsonb`. `normalize/1` is the only
  way a value enters storage; `stored/1` reads one back and turns anything that
  no longer parses into `nil`, so a corrupt row degrades to "inherit" instead of
  breaking sign-in.
  """

  alias ServiceRadar.Dashboards.AuthoredDashboard
  alias ServiceRadar.Dashboards.DashboardInstance

  require Ash.Query

  @kinds ~w(overview dashboards_index dashboard)
  @target_types ~w(authored package)
  @allowed_keys ~w(kind target_type target_id)
  @package_slug ~r/\A[A-Za-z0-9][A-Za-z0-9_.-]{0,127}\z/

  @type t :: %{required(String.t()) => String.t()}

  @doc "The allowed homepage kinds."
  @spec kinds() :: [String.t()]
  def kinds, do: @kinds

  @doc """
  Validates and canonicalizes a submitted homepage.

  Accepts atom or string keys and values. Unknown keys, unknown kinds, a
  target on a non-dashboard kind, or a malformed target are rejected.
  """
  @spec normalize(term()) :: {:ok, t() | nil} | {:error, String.t()}
  def normalize(nil), do: {:ok, nil}

  def normalize(value) when is_map(value) do
    with {:ok, fields} <- stringify(value),
         :ok <- reject_unknown_keys(fields),
         {:ok, kind} <- fetch_kind(fields) do
      normalize_kind(kind, fields)
    end
  end

  def normalize(_value), do: {:error, "must be a homepage choice"}

  @doc "Reads a stored homepage, returning `nil` for absent or unparseable values."
  @spec stored(term()) :: t() | nil
  def stored(value) do
    case normalize(value) do
      {:ok, homepage} -> homepage
      {:error, _reason} -> nil
    end
  end

  @doc "True when the homepage points at a specific dashboard."
  @spec dashboard?(t() | nil) :: boolean()
  def dashboard?(%{"kind" => "dashboard"}), do: true
  def dashboard?(_homepage), do: false

  @doc """
  Loads the dashboard a `dashboard` homepage points at, as whoever `opts`
  names (`actor:` or `scope:`).

  Returns `{:ok, {:authored, dashboard}}` or `{:ok, {:package, instance}}`
  only when the target exists, is not archived or disabled, and the actor's
  read policy allows it. Any other outcome, including a forbidden read, is
  `:error`: callers fall through rather than distinguish "gone" from
  "not yours".
  """
  @spec load_target(t(), keyword()) ::
          {:ok, {:authored, AuthoredDashboard.t()} | {:package, DashboardInstance.t()}} | :error
  def load_target(%{"kind" => "dashboard", "target_type" => "authored", "target_id" => id}, opts) do
    AuthoredDashboard
    |> Ash.Query.for_read(:by_id, %{id: id})
    |> Ash.read_one(authorized(opts))
    |> case do
      {:ok, %AuthoredDashboard{status: status} = dashboard} when status != :archived ->
        {:ok, {:authored, dashboard}}

      _other ->
        :error
    end
  end

  def load_target(%{"kind" => "dashboard", "target_type" => "package", "target_id" => slug}, opts) do
    DashboardInstance
    |> Ash.Query.for_read(:enabled)
    |> Ash.Query.filter(route_slug == ^slug)
    |> Ash.Query.limit(1)
    |> Ash.read_one(authorized(opts))
    |> case do
      {:ok, %DashboardInstance{} = instance} -> {:ok, {:package, instance}}
      _other -> :error
    end
  end

  def load_target(_homepage, _opts), do: :error

  # The read is the authorization check, so it must never run unauthorized.
  defp authorized(opts), do: Keyword.put(opts, :authorize?, true)

  defp stringify(value) do
    Enum.reduce_while(value, {:ok, %{}}, fn {key, field_value}, {:ok, acc} ->
      case {string_key(key), string_value(field_value)} do
        {{:ok, key}, {:ok, field_value}} -> {:cont, {:ok, Map.put(acc, key, field_value)}}
        _invalid -> {:halt, {:error, "must be a homepage choice"}}
      end
    end)
  end

  defp string_key(key) when is_binary(key), do: {:ok, key}
  defp string_key(key) when is_atom(key), do: {:ok, Atom.to_string(key)}
  defp string_key(_key), do: :error

  defp string_value(nil), do: {:ok, nil}
  defp string_value(value) when is_binary(value), do: {:ok, String.trim(value)}
  defp string_value(value) when is_atom(value), do: {:ok, Atom.to_string(value)}
  defp string_value(_value), do: :error

  defp reject_unknown_keys(fields) do
    case Map.keys(fields) -- @allowed_keys do
      [] -> :ok
      _unknown -> {:error, "has unsupported fields"}
    end
  end

  defp fetch_kind(%{"kind" => kind}) when kind in @kinds, do: {:ok, kind}
  defp fetch_kind(_fields), do: {:error, "has an unsupported kind"}

  defp normalize_kind("dashboard", fields) do
    with {:ok, target_type} <- fetch_target_type(fields),
         {:ok, target_id} <- fetch_target_id(target_type, Map.get(fields, "target_id")) do
      {:ok, %{"kind" => "dashboard", "target_type" => target_type, "target_id" => target_id}}
    end
  end

  defp normalize_kind(kind, fields) do
    if blank?(Map.get(fields, "target_type")) and blank?(Map.get(fields, "target_id")) do
      {:ok, %{"kind" => kind}}
    else
      {:error, "only a dashboard homepage takes a target"}
    end
  end

  defp fetch_target_type(%{"target_type" => target_type}) when target_type in @target_types,
    do: {:ok, target_type}

  defp fetch_target_type(_fields), do: {:error, "needs an authored or package dashboard target"}

  defp fetch_target_id("authored", id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, "has an invalid dashboard target"}
    end
  end

  defp fetch_target_id("package", slug) when is_binary(slug) do
    if Regex.match?(@package_slug, slug),
      do: {:ok, slug},
      else: {:error, "has an invalid dashboard target"}
  end

  defp fetch_target_id(_target_type, _id), do: {:error, "has an invalid dashboard target"}

  defp blank?(value), do: value in [nil, ""]
end
