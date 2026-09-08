defmodule ServiceRadarWebNGWeb.Plugs.McpWwwAuthenticate do
  @moduledoc """
  Adds RFC 9728 `WWW-Authenticate` on MCP 401/403 responses so clients
  can discover the authorization server.
  """

  @behaviour Plug

  import Plug.Conn

  alias ServiceRadarWebNG.Mcp.OAuth

  def init(opts), do: opts

  def call(conn, _opts) do
    register_before_send(conn, &maybe_challenge/1)
  end

  defp maybe_challenge(%{status: 401} = conn) do
    put_resp_header(conn, "www-authenticate", OAuth.www_authenticate(conn))
  end

  defp maybe_challenge(%{status: 403} = conn) do
    put_resp_header(
      conn,
      "www-authenticate",
      OAuth.www_authenticate(conn, error: "insufficient_scope", scope: "mcp")
    )
  end

  defp maybe_challenge(conn), do: conn
end
