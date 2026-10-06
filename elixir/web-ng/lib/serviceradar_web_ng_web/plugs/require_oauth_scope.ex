defmodule ServiceRadarWebNGWeb.Plugs.RequireOauthScope do
  @moduledoc """
  Gates a route on the bearer JWT's `scopes` claim — the OAuth-style scope set
  minted at login time, not the live RBAC permission catalog.

  A CLI session JWT carries the required scope in its `scopes` claim. The plug
  reads `conn.assigns[:oauth_token_scope]` (set by `Plugs.ApiAuth`) and rejects
  with HTTP 403 + `{"error":"insufficient_scope","required": <scope>}` if the
  required scope is absent.

  This is a defense-in-depth layer: the controller still does its own RBAC
  check on the operation-specific permission. The plug exists so a leaked CLI
  session whose scopes claim never granted publish capability cannot reach the
  multipart parser at all — the body is never read on a scope failure.
  """

  @behaviour Plug

  import Plug.Conn

  @impl true
  def init(opts) do
    scope = Keyword.fetch!(opts, :scope)

    if !(is_binary(scope) and scope != "") do
      raise ArgumentError, "RequireOauthScope expects :scope to be a non-empty string"
    end

    %{scope: scope}
  end

  @impl true
  def call(conn, %{scope: required_scope}) do
    if bearer_has_scope?(conn, required_scope) do
      conn
    else
      deny_insufficient_scope(conn, required_scope)
    end
  end

  defp bearer_has_scope?(%Plug.Conn{assigns: %{oauth_token_scope: value}}, required) when is_binary(value) do
    value
    |> String.split(~r/\s+/, trim: true)
    |> Enum.member?(required)
  end

  defp bearer_has_scope?(_, _), do: false

  defp deny_insufficient_scope(conn, required_scope) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(
      403,
      Jason.encode!(%{error: "insufficient_scope", required: required_scope})
    )
    |> halt()
  end
end
