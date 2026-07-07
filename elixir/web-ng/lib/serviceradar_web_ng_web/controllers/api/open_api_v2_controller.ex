defmodule ServiceRadarWebNGWeb.Api.OpenApiV2Controller do
  @moduledoc """
  Serves the Ash JSON:API v2 OpenAPI document at `/api/v2/open_api`.

  This route is authenticated (see the `:api_docs_spec` pipeline in the router):
  the spec is an internal developer artifact, not a public document. The
  external developer portal now sources the spec from the ServiceRadar repo
  rather than fetching it live, so there is no longer any reason to keep it
  publicly reachable.

  The document is served with the *global* bearer-auth requirement removed so
  the in-app SwaggerUI console defaults to seamless session authentication (the
  logged-in user's cookie + CSRF token) instead of prompting for a pasted JWT.
  The bearer security *scheme* itself is retained as an optional fallback for
  non-browser clients.
  """
  use ServiceRadarWebNGWeb, :controller

  # Keep in sync with `ServiceRadarWebNGWeb.AshJsonApiRouter`.
  @domains [
    ServiceRadar.Inventory,
    ServiceRadar.Infrastructure,
    ServiceRadar.Monitoring
  ]

  def show(conn, _params) do
    spec =
      AshJsonApi.OpenApi.spec(
        [
          domains: @domains,
          open_api_title: "ServiceRadar API",
          open_api_version: "2.0.0",
          # `route_href/3` prepends this to every operation path so "Try it out"
          # targets `/api/v2/<resource>` (where the JSON:API router is mounted).
          prefix: "/api/v2",
          phoenix_endpoint: conn.private[:phoenix_endpoint] || ServiceRadarWebNGWeb.Endpoint,
          modify_open_api: {__MODULE__, :seamless_session_auth, []}
        ],
        conn
      )

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(spec))
  end

  @doc false
  # Drop the *global* bearer-auth requirement so SwaggerUI does not force a
  # manual "Authorize / paste JWT" step. Each "Try it out" call is authenticated
  # by the logged-in user's session cookie (same-origin, with credentials) and
  # the CSRF token attached by SwaggerUI's request interceptor; the resource's
  # Ash policies then authorize it. The bearer scheme stays defined under
  # `components.securitySchemes` so manual bearer entry remains available as an
  # optional fallback for non-browser API clients.
  def seamless_session_auth(spec, _conn, _opts) do
    %{spec | security: []}
  end
end
