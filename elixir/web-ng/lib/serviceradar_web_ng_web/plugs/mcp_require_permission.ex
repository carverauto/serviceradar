defmodule ServiceRadarWebNGWeb.Plugs.McpRequirePermission do
  @moduledoc """
  Rejects MCP requests whose authenticated user lacks `settings.mcp.manage`.

  OAuth scope `mcp` is necessary but not sufficient: a custom role profile can
  omit the catalog key so a demo (or other locked-down) account cannot call
  `/mcp` even with a previously issued client credential.
  """

  @behaviour Plug

  import Plug.Conn

  alias ServiceRadar.Identity.Constants
  alias ServiceRadarWebNG.RBAC

  def init(opts), do: opts

  def call(conn, _opts) do
    permission = Constants.mcp_manage_permission()

    case conn.assigns[:current_scope] do
      scope when not is_nil(scope) ->
        if RBAC.can?(scope, permission) do
          conn
        else
          deny(conn)
        end

      _ ->
        deny(conn)
    end
  end

  defp deny(conn) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(
      403,
      Jason.encode!(%{
        error: "forbidden",
        message: "MCP access is not permitted for this account"
      })
    )
    |> halt()
  end
end
