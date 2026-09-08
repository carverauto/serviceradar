defmodule ServiceRadarWebNGWeb.Plugs.McpAshContext do
  @moduledoc """
  Puts the HTTP current_scope into Ash context for MCP tool runs.
  """

  @behaviour Plug

  alias ServiceRadarWebNGWeb.ClientIP

  def init(opts), do: opts

  def call(conn, _opts) do
    context = %{
      scope: conn.assigns[:current_scope],
      oauth_client_id: conn.assigns[:oauth_client_id],
      mcp_ip: ClientIP.get(conn)
    }

    Ash.PlugHelpers.set_context(conn, context)
  end
end
