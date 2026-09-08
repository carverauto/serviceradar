defmodule ServiceRadarWebNGWeb.Plugs.McpRequireUser do
  @moduledoc """
  Rejects MCP requests authenticated as an identity-less legacy API key.
  """

  @behaviour Plug

  import Plug.Conn

  alias ServiceRadarWebNG.Accounts.Scope

  def init(opts), do: opts

  def call(conn, _opts) do
    case conn.assigns[:current_scope] do
      %Scope{user: user} when not is_nil(user) ->
        conn

      _ ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(401, Jason.encode!(%{error: "unauthorized", message: "MCP requires a user-bound API credential"}))
        |> halt()
    end
  end
end
