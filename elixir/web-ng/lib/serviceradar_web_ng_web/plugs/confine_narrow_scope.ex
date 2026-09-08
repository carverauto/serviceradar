defmodule ServiceRadarWebNGWeb.Plugs.ConfineNarrowScope do
  @moduledoc """
  Confines a narrow-scoped bearer token to the routes its scope was granted for.

  Mounted in the `:api_key_auth` pipeline, immediately after `Plugs.ApiAuth`, so
  every route authenticated by that pipeline is covered by construction rather
  than by remembering to mount a per-route plug. `Plugs.RequireOauthScope` stays
  where it is: it states a route's requirement and handles the session-fallback
  case, while this plug enforces the complementary rule that a narrow token may
  reach *nothing else*.

  The distinction matters because the two plugs fail in opposite directions. A
  route without `RequireOauthScope` is open to any authenticated token; a route
  absent from `NarrowScopes` is closed to narrow tokens. Adding a route
  therefore cannot accidentally widen a CLI token's reach.

  Coarse client-credential scopes (`read`, `write`, `admin`, `mcp`), API keys and
  browser sessions pass through untouched -- see `NarrowScopes` for why
  tightening those is deliberately out of scope here.
  """

  @behaviour Plug

  import Plug.Conn

  alias ServiceRadarWebNGWeb.Auth.NarrowScopes

  require Logger

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{assigns: %{oauth_token_scope: value}} = conn, _opts) when is_binary(value) do
    scopes = NarrowScopes.parse(value)

    if NarrowScopes.allowed?(scopes, conn.method, conn.request_path) do
      conn
    else
      Logger.warning(
        "Narrow-scoped token refused outside its grant: scopes=#{inspect(scopes)} " <>
          "method=#{conn.method} path=#{conn.request_path}"
      )

      deny(conn, scopes)
    end
  end

  def call(conn, _opts), do: conn

  # The token is valid, so this is an authorization failure, not an
  # authentication one. Report the scopes the token actually holds rather than a
  # single `required` value: there is no one scope that would have let this
  # request through, and naming one would send a CLI author looking for a grant
  # that does not exist.
  defp deny(conn, scopes) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(
      403,
      Jason.encode!(%{
        error: "insufficient_scope",
        message: "token scope does not permit this endpoint",
        granted: scopes
      })
    )
    |> halt()
  end
end
