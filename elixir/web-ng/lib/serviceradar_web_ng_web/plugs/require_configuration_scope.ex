defmodule ServiceRadarWebNGWeb.Plugs.RequireConfigurationScope do
  @moduledoc """
  Intersects user-bound API access with the authenticated token's capability.

  Runs after ApiAuth and ConfineNarrowScope. Controllers still enforce each
  operation's RBAC permission. A user access token retains its user's authority;
  an API token must also grant the requested method. Existing narrow grants
  remain confined to their explicit route allowlist. UserAuth applies this gate
  to verified API bearer tokens before an actor reaches controllers or Ash
  JSON:API, and the `:api_key_auth` pipeline applies it to every route it
  authenticates. Audited read-only POST endpoints are passed as decoded path
  segments in `:read_only_post_paths`; configuration routes have no exceptions.
  `:path_prefixes` confines API grants to data routes, so they cannot authorize a
  browser flow that mints credentials with the owner's broader permissions.
  `:allow_api_key_auth` keeps legacy static keys reachable on the general
  pipeline; the configuration pipeline leaves it disabled so static keys
  cannot provision.
  """

  @behaviour Plug

  import Plug.Conn

  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNGWeb.Auth.NarrowScopes

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%{assigns: %{current_scope: %Scope{user: %{status: :active}}}} = conn, opts) do
    if path_allowed?(conn, opts) and permitted?(conn, opts) do
      conn
    else
      reject(conn, 403, "insufficient_scope", "Token scope does not permit this API action")
    end
  end

  def call(%{assigns: %{current_scope: %Scope{user: nil}, api_key_auth: true}} = conn, opts) do
    if Keyword.get(opts, :allow_api_key_auth, false) do
      conn
    else
      reject(conn, 401, "unauthorized", "An active user-bound credential is required")
    end
  end

  def call(conn, _opts) do
    reject(conn, 401, "unauthorized", "An active user-bound credential is required")
  end

  defp permitted?(%{assigns: %{api_token_scope: scope}} = conn, opts) when scope in [:read, :write, :admin] do
    scope_allows?(Atom.to_string(scope), conn, opts)
  end

  defp permitted?(%{assigns: %{api_token_scope: scope}} = conn, opts) when scope in ["read", "write", "admin"] do
    scope_allows?(scope, conn, opts)
  end

  defp permitted?(%{assigns: %{api_token_scope: _}}, _opts), do: false

  defp permitted?(%{assigns: %{oauth_token_scope: scope}} = conn, opts) do
    scope
    |> NarrowScopes.parse()
    |> Enum.any?(&scope_allows?(&1, conn, opts))
  end

  # ApiAuth marks even an empty API bearer scope. Only an authenticated user
  # access token can reach this clause on the configuration API pipeline.
  defp permitted?(conn, opts) do
    if Keyword.get(opts, :allow_api_key_auth, false) do
      true
    else
      conn.assigns[:api_key_auth] != true
    end
  end

  defp path_allowed?(conn, opts) do
    case Keyword.get(opts, :path_prefixes) do
      nil ->
        true

      prefixes ->
        path = Enum.map(conn.path_info, &URI.decode/1)
        Enum.any?(prefixes, &(Enum.take(path, length(&1)) == &1))
    end
  end

  defp scope_allows?(scope, _conn, _opts) when scope in ["write", "admin"], do: true

  defp scope_allows?("read", conn, opts) do
    conn.method in ["GET", "HEAD", "OPTIONS"] or read_only_post?(conn, opts)
  end

  defp scope_allows?(scope, conn, _opts) do
    scope not in NarrowScopes.coarse() and
      NarrowScopes.allowed?([scope], conn.method, conn.request_path)
  end

  defp read_only_post?(%{method: "POST"} = conn, opts) do
    path = Enum.map(conn.path_info, &URI.decode/1)
    path in Keyword.get(opts, :read_only_post_paths, [])
  end

  defp read_only_post?(_conn, _opts), do: false

  defp reject(conn, status, error, message) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(%{error: error, message: message}))
    |> halt()
  end
end
