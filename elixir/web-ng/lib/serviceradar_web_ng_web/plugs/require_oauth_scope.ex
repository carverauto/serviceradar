defmodule ServiceRadarWebNGWeb.Plugs.RequireOauthScope do
  @moduledoc """
  Gates a route on the bearer JWT's `scopes` claim — the OAuth-style scope set
  minted at login time, not the live RBAC permission catalog.

  Two callers compose against this plug:

    * a CLI session JWT carrying `scopes: ["dashboard.publish"]` (the
      cli-device-auth flow). For this path the plug reads
      `conn.assigns[:oauth_token_scope]` (set by `Plugs.ApiAuth`) and rejects
      with HTTP 403 + `{"error":"insufficient_scope","required": <scope>}` if
      the required scope isn't present.

    * a session-authenticated browser request with no `oauth_token_scope`
      assign (the existing Settings → Dashboard Packages LiveView upload
      modal). For this path the plug accepts an optional `:fallback_permission`
      RBAC key. If the assign is absent and the user holds the fallback
      permission, the request passes; otherwise it 403s.

  This is a defense-in-depth layer: the controller still does its own RBAC
  check on the operation-specific permission. The plug exists so a leaked CLI
  session whose scopes claim never granted publish capability cannot reach the
  multipart parser at all — the body is never read on a scope failure.
  """

  @behaviour Plug

  import Plug.Conn

  alias ServiceRadarWebNG.RBAC

  require Logger

  @impl true
  def init(opts) do
    scope = Keyword.fetch!(opts, :scope)

    if !(is_binary(scope) and scope != "") do
      raise ArgumentError, "RequireOauthScope expects :scope to be a non-empty string"
    end

    fallback = Keyword.get(opts, :fallback_permission)

    if fallback != nil and not is_binary(fallback) do
      raise ArgumentError, "RequireOauthScope :fallback_permission must be a string or nil"
    end

    %{scope: scope, fallback_permission: fallback}
  end

  @impl true
  def call(conn, %{scope: required_scope, fallback_permission: fallback}) do
    cond do
      bearer_has_scope?(conn, required_scope) ->
        conn

      bearer_present?(conn) ->
        # Bearer was used but the scope is missing. Don't fall through to the
        # session/RBAC path — the bearer is the authoritative authn surface
        # for this request.
        deny_insufficient_scope(conn, required_scope)

      session_has_fallback?(conn, fallback) ->
        conn

      true ->
        # Neither a scoped bearer nor a fallback-permitted session.
        deny_insufficient_scope(conn, required_scope)
    end
  end

  defp bearer_present?(%Plug.Conn{assigns: %{oauth_token_scope: value}}) when is_binary(value), do: true

  defp bearer_present?(_), do: false

  defp bearer_has_scope?(%Plug.Conn{assigns: %{oauth_token_scope: value}}, required) when is_binary(value) do
    value
    |> String.split(~r/\s+/, trim: true)
    |> Enum.member?(required)
  end

  defp bearer_has_scope?(_, _), do: false

  defp session_has_fallback?(_conn, nil), do: false

  defp session_has_fallback?(conn, permission) when is_binary(permission) do
    case conn.assigns[:current_scope] do
      nil -> false
      scope -> RBAC.can?(scope, permission)
    end
  end

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
