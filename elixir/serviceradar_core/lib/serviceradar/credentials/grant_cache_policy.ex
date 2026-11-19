defmodule ServiceRadar.Credentials.GrantCachePolicy do
  @moduledoc """
  Decides whether an agent may keep a broker grant's resolved material in
  memory, and for how long.

  Core makes this decision when it builds a grant's scope or issues the grant.
  The grant stores it as `cache_mode` and `cache_ttl_seconds`, and the wire
  payload carries it as `"cache"`. Agents cache in memory only, and also clamp
  the TTL to the grant's expiry and to the lease returned by the resolve call.

  * A Proxmox host-authority consumer gets `:memory_ttl` by default. The agent
    host injects the credential into the request, so the material never enters
    guest memory.
  * Every other consumer follows the secret's `cache_policy`, and only
    `:memory_ttl` enables caching. `:encrypted_ttl` does not: agents have no
    encrypted cache, so such a grant falls back to no cache.
  * The TTL is the secret's `cache_ttl_seconds`, defaulting to and capped at
    300 seconds, and never longer than the grant's own TTL.

  A grant that caches trades two things for the saved resolutions. A rotated
  or disabled secret reaches the agent only after the cached copy expires.
  Swapping a rule to another secret takes effect at once, because the swap
  changes the binding id and therefore the cache key. And a cache hit makes no
  resolve call, so core audits each resolution, not each use.
  """

  alias ServiceRadar.Credentials.NetworkCredentialSecret
  alias ServiceRadar.Plugins.ProxmoxHostAuthority

  require Ash.Query

  @max_ttl_seconds 300
  @default_grant_ttl_seconds 300

  @type cache_attrs :: %{
          cache_mode: :no_cache | :memory_ttl,
          cache_ttl_seconds: pos_integer() | nil
        }

  @doc "The longest TTL any grant may allow an agent to cache material for."
  @spec max_ttl_seconds() :: pos_integer()
  def max_ttl_seconds, do: @max_ttl_seconds

  @doc """
  The cache attributes for a grant with the scope in `attrs`, backed by
  `secret`. Pass `nil` when the secret is unknown or could not be read.
  """
  @spec cache_attrs(map(), map() | nil) :: cache_attrs()
  def cache_attrs(attrs, secret) when is_map(attrs) do
    if cacheable?(attrs, secret) do
      %{cache_mode: :memory_ttl, cache_ttl_seconds: ttl_seconds(attrs, secret)}
    else
      %{cache_mode: :no_cache, cache_ttl_seconds: nil}
    end
  end

  @doc "Merges `cache_attrs/2` into `attrs`."
  @spec put(map(), map() | nil) :: map()
  def put(attrs, secret) when is_map(attrs), do: Map.merge(attrs, cache_attrs(attrs, secret))

  @doc """
  Loads only the cache-policy fields of a network credential secret. Returns
  `nil` when there is no secret id or the secret cannot be read.
  """
  @spec load_secret(term(), keyword()) :: map() | nil
  def load_secret(nil, _opts), do: nil

  def load_secret(secret_id, opts) do
    NetworkCredentialSecret
    |> Ash.Query.for_read(:by_id, %{id: secret_id}, opts)
    |> Ash.Query.select([:id, :cache_policy, :cache_ttl_seconds])
    |> Ash.read_one(opts)
    |> case do
      {:ok, %NetworkCredentialSecret{} = secret} -> secret
      _ -> nil
    end
  end

  @doc "The query a caller can pass to `load:` to fetch a secret's cache policy."
  @spec secret_query() :: Ash.Query.t()
  def secret_query,
    do: Ash.Query.select(NetworkCredentialSecret, [:id, :cache_policy, :cache_ttl_seconds])

  @doc """
  The wire form of a grant's cache policy, or `nil` when the grant must not be
  cached. The TTL is clamped again here so that a stored value can never exceed
  the maximum or the grant's own TTL.
  """
  @spec payload(map()) :: map() | nil
  def payload(grant_or_attrs) when is_map(grant_or_attrs) do
    if value(grant_or_attrs, :cache_mode) in [:memory_ttl, "memory_ttl"] do
      ttl =
        Enum.min([
          positive_int(value(grant_or_attrs, :cache_ttl_seconds), @max_ttl_seconds),
          @max_ttl_seconds,
          positive_int(value(grant_or_attrs, :ttl_seconds), @default_grant_ttl_seconds)
        ])

      %{"mode" => "memory_ttl", "ttl_seconds" => ttl}
    end
  end

  defp cacheable?(attrs, secret) do
    ProxmoxHostAuthority.host_injected_consumer?(
      value(attrs, :consumer_kind),
      value(attrs, :consumer_id)
    ) or secret_cache_policy(secret) == :memory_ttl
  end

  defp ttl_seconds(attrs, secret) do
    Enum.min([
      positive_int(secret_value(secret, :cache_ttl_seconds), @max_ttl_seconds),
      @max_ttl_seconds,
      positive_int(value(attrs, :ttl_seconds), @default_grant_ttl_seconds)
    ])
  end

  defp secret_cache_policy(secret) do
    case secret_value(secret, :cache_policy) do
      policy when is_atom(policy) -> policy
      "memory_ttl" -> :memory_ttl
      _other -> :no_cache
    end
  end

  defp secret_value(%{} = secret, key), do: value(secret, key)
  defp secret_value(_secret, _key), do: nil

  defp positive_int(value, _default) when is_integer(value) and value > 0, do: value

  defp positive_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} when int > 0 -> int
      _ -> default
    end
  end

  defp positive_int(_value, default), do: default

  defp value(map, key), do: Map.get(map, key) || Map.get(map, to_string(key))
end
