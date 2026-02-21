defmodule ServiceRadarWebNG.Auth.Pipeline do
  @moduledoc """
  Guardian authentication pipeline for web requests.

  This pipeline handles JWT verification and user loading for
  authenticated routes. It integrates with the existing Scope
  system for authorization.

  ## Usage

  Add to router pipelines:

      pipeline :api_auth do
        plug ServiceRadarWebNG.Auth.Pipeline
      end

  Or use specific plugs:

      plug ServiceRadarWebNG.Auth.Pipeline.VerifyHeader
      plug ServiceRadarWebNG.Auth.Pipeline.LoadResource

  ## Token Sources

  The pipeline checks for tokens in this order:
  1. Authorization header (Bearer token)
  2. Session (for browser requests)
  """

  use Guardian.Plug.Pipeline,
    otp_app: :serviceradar_web_ng,
    module: ServiceRadarWebNG.Auth.Guardian,
    error_handler: ServiceRadarWebNG.Auth.ErrorHandler

  # Verify token from Authorization header (optional - allows unauthenticated)
  plug Guardian.Plug.VerifyHeader, claims: %{"typ" => "access"}, allow_blank: true

  # Verify token from session (for browser requests)
  plug Guardian.Plug.VerifySession, claims: %{"typ" => "access"}, allow_blank: true

  # Load the user resource
  plug Guardian.Plug.LoadResource, allow_blank: true
end

defmodule ServiceRadarWebNG.Auth.Pipeline.Browser do
  @moduledoc """
  Guardian pipeline optimized for browser sessions.

  Uses session-based token storage with optional header verification.
  """

  use Guardian.Plug.Pipeline,
    otp_app: :serviceradar_web_ng,
    module: ServiceRadarWebNG.Auth.Guardian,
    error_handler: ServiceRadarWebNG.Auth.ErrorHandler

  # Check session first for browser requests
  plug Guardian.Plug.VerifySession, claims: %{"typ" => "access"}, allow_blank: true

  # Also allow header-based auth for API-like browser requests
  plug Guardian.Plug.VerifyHeader, claims: %{"typ" => "access"}, allow_blank: true

  # Load the user resource
  plug Guardian.Plug.LoadResource, allow_blank: true
end

defmodule ServiceRadarWebNG.Auth.Pipeline.API do
  @moduledoc """
  Guardian pipeline for API requests.

  Strictly requires valid tokens - no session support.
  Accepts both access tokens and API tokens.
  """

  use Guardian.Plug.Pipeline,
    otp_app: :serviceradar_web_ng,
    module: ServiceRadarWebNG.Auth.Guardian,
    error_handler: ServiceRadarWebNG.Auth.ErrorHandler

  # Verify token from Authorization header (required)
  plug Guardian.Plug.VerifyHeader, claims: %{}, allow_blank: true

  # Load the user resource
  plug Guardian.Plug.LoadResource, allow_blank: true

  # Require authentication
  plug Guardian.Plug.EnsureAuthenticated
end

defmodule ServiceRadarWebNG.Auth.Pipeline.RefreshToken do
  @moduledoc """
  Guardian pipeline for refresh token endpoints.

  Validates refresh tokens specifically for token exchange.
  """

  use Guardian.Plug.Pipeline,
    otp_app: :serviceradar_web_ng,
    module: ServiceRadarWebNG.Auth.Guardian,
    error_handler: ServiceRadarWebNG.Auth.ErrorHandler

  # Verify refresh token from Authorization header
  plug Guardian.Plug.VerifyHeader, claims: %{"typ" => "refresh"}

  # Load the user resource
  plug Guardian.Plug.LoadResource
end
