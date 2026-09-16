defmodule ServiceRadarWebNGWeb.Plugs.RequireConfigurationScope do
  @moduledoc """
  Intersects configuration API access with the authenticated token's capability.

  Runs after ApiAuth and ConfineNarrowScope. Controllers still enforce each
  operation's RBAC permission. A user access token retains its user's authority;
  an API token must also grant the requested method. Existing narrow grants
  remain confined to their explicit route allowlist.
  """

  @behaviour Plug

  import Plug.Conn

  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNGWeb.Auth.NarrowScopes

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%{assigns: %{current_scope: %Scope{user: %{status: :active}}}} = conn, _opts) do
    if permitted?(conn) do
      conn
    else
      reject(conn, 403, "insufficient_scope", "Token scope does not permit this configuration action")
    end
  end

  def call(conn, _opts) do
    reject(conn, 401, "unauthorized", "An active user-bound credential is required")
  end

  defp permitted?(%{assigns: %{api_token_scope: scope}} = conn) when scope in [:read, :write, :admin] do
    scope_allows?(Atom.to_string(scope), conn)
  end

  defp permitted?(%{assigns: %{api_token_scope: scope}} = conn) when scope in ["read", "write", "admin"] do
    scope_allows?(scope, conn)
  end

  defp permitted?(%{assigns: %{api_token_scope: _}}), do: false

  defp permitted?(%{assigns: %{oauth_token_scope: scope}} = conn) do
    scope
    |> NarrowScopes.parse()
    |> Enum.any?(&scope_allows?(&1, conn))
  end

  # ApiAuth marks even an empty API bearer scope. Only an authenticated user
  # access token can reach this clause on the configuration API pipeline.
  defp permitted?(conn), do: conn.assigns[:api_key_auth] != true

  defp scope_allows?(scope, _conn) when scope in ["write", "admin"], do: true
  defp scope_allows?("read", conn), do: conn.method in ["GET", "HEAD", "OPTIONS"]

  defp scope_allows?(scope, conn) do
    scope not in NarrowScopes.coarse() and
      NarrowScopes.allowed?([scope], conn.method, conn.request_path)
  end

  defp reject(conn, status, error, message) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(%{error: error, message: message}))
    |> halt()
  end
end
