defmodule ServiceRadarWebNGWeb.OAuthMetadataController do
  @moduledoc """
  RFC 8414 and RFC 9728 discovery documents for MCP OAuth.
  """

  use ServiceRadarWebNGWeb, :controller

  alias ServiceRadarWebNG.Mcp.OAuth
  alias ServiceRadarWebNGWeb.FeatureFlags

  def protected_resource(conn, _params) do
    if FeatureFlags.mcp_enabled?() do
      json(conn, %{
        resource: OAuth.mcp_resource(conn),
        authorization_servers: [OAuth.issuer(conn)],
        bearer_methods_supported: ["header"],
        scopes_supported: OAuth.allowed_scopes()
      })
    else
      conn
      |> put_status(:not_found)
      |> json(%{error: "not_found"})
    end
  end

  def authorization_server(conn, _params) do
    if FeatureFlags.mcp_enabled?() do
      issuer = OAuth.issuer(conn)

      json(conn, %{
        issuer: issuer,
        authorization_endpoint: issuer <> "/oauth/authorize",
        token_endpoint: issuer <> "/oauth/token",
        grant_types_supported: ["authorization_code", "refresh_token", "client_credentials"],
        response_types_supported: ["code"],
        code_challenge_methods_supported: ["S256"],
        token_endpoint_auth_methods_supported: ["none", "client_secret_post", "client_secret_basic"],
        scopes_supported: OAuth.allowed_scopes()
      })
    else
      conn
      |> put_status(:not_found)
      |> json(%{error: "not_found"})
    end
  end
end
