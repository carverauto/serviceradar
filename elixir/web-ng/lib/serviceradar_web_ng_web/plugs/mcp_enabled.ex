defmodule ServiceRadarWebNGWeb.Plugs.McpEnabled do
  @moduledoc """
  Returns 404 when the MCP server is not enabled.
  """

  @behaviour Plug

  import Plug.Conn

  alias ServiceRadarWebNGWeb.FeatureFlags

  def init(opts), do: opts

  def call(conn, _opts) do
    if FeatureFlags.mcp_enabled?() do
      conn
    else
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(404, Jason.encode!(%{error: "not_found"}))
      |> halt()
    end
  end
end
