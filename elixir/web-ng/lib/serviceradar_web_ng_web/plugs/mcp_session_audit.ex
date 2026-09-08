defmodule ServiceRadarWebNGWeb.Plugs.McpSessionAudit do
  @moduledoc """
  Records MCP initialize and scope-denial events.
  """

  @behaviour Plug

  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.Mcp.Audit
  alias ServiceRadarWebNGWeb.ClientIP

  def init(opts), do: opts

  def call(conn, _opts) do
    Plug.Conn.register_before_send(conn, &audit_on_send/1)
  end

  # Plug.Conn.send_resp/3 runs before_send *before* halt/1, so 401/403
  # from ApiAuth / RequireOauthScope still have halted: false here.
  defp audit_on_send(%{status: status} = conn) when status in [401, 403] do
    Audit.auth_failed(Keyword.put(base_opts(conn), :error, "http_#{status}"))
    conn
  end

  defp audit_on_send(%{status: status} = conn) when status in 200..299 do
    if initialize_request?(conn) do
      Audit.session_initialized(base_opts(conn))
    end

    conn
  end

  defp audit_on_send(conn), do: conn

  defp initialize_request?(conn) do
    params = conn.body_params || %{}
    params["method"] == "initialize" or get_in(params, ["_json", "method"]) == "initialize"
  end

  defp base_opts(conn) do
    actor_id =
      case conn.assigns[:current_scope] do
        %Scope{user: %{id: id}} -> to_string(id)
        _ -> nil
      end

    [
      actor_id: actor_id,
      oauth_client_id: conn.assigns[:oauth_client_id],
      ip: ClientIP.get(conn)
    ]
  end
end
