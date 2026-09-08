defmodule ServiceRadarWebNGWeb.Router do
  use ServiceRadarWebNGWeb, :router

  import AshAdmin.Router
  import Oban.Web.Router
  import Phoenix.LiveDashboard.Router
  import ServiceRadarWebNGWeb.UserAuth

  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.Mcp
  alias ServiceRadarWebNGWeb.Plugs.ApiAuth
  alias ServiceRadarWebNGWeb.Plugs.ConfineNarrowScope
  alias ServiceRadarWebNGWeb.Plugs.GatewayAuth
  alias ServiceRadarWebNGWeb.Plugs.LockoutCheck
  alias ServiceRadarWebNGWeb.Plugs.McpAshContext
  alias ServiceRadarWebNGWeb.Plugs.McpEnabled
  alias ServiceRadarWebNGWeb.Plugs.McpRequirePermission
  alias ServiceRadarWebNGWeb.Plugs.McpRequireUser
  alias ServiceRadarWebNGWeb.Plugs.McpSessionAudit
  alias ServiceRadarWebNGWeb.Plugs.McpWwwAuthenticate
  alias ServiceRadarWebNGWeb.Plugs.RateLimit
  alias ServiceRadarWebNGWeb.Plugs.RateLimit.Bodies
  alias ServiceRadarWebNGWeb.Plugs.RequireOauthScope
  alias ServiceRadarWebNGWeb.Plugs.SecurityHeaders
  alias ServiceRadarWebNGWeb.Settings.ShellHook

  @frame_src if Mix.env() == :dev, do: "'self'", else: "'none'"
  @csp "default-src 'self'; " <>
         "script-src 'self' blob: 'wasm-unsafe-eval'; " <>
         "style-src 'self' 'unsafe-inline'; " <>
         "img-src 'self' data: https://api.mapbox.com https://*.tiles.mapbox.com https://*.tile.openstreetmap.org https://*.basemaps.cartocdn.com; " <>
         "font-src 'self' data:; " <>
         "media-src 'none'; " <>
         "connect-src 'self' https: wss:; " <>
         "worker-src 'self' blob:; " <>
         "child-src blob:; " <>
         "frame-src #{@frame_src}; " <>
         "frame-ancestors 'none'; " <>
         "object-src 'none'; " <>
         "base-uri 'self'; " <>
         "form-action 'self'"

  @api_docs_csp "default-src 'self'; " <>
                  "script-src 'self' blob: 'wasm-unsafe-eval' https://cdnjs.cloudflare.com https://cdn.jsdelivr.net; " <>
                  "style-src 'self' 'unsafe-inline' https://cdnjs.cloudflare.com https://fonts.googleapis.com; " <>
                  "img-src 'self' data: https:; " <>
                  "font-src 'self' data: https://fonts.gstatic.com; " <>
                  "media-src 'none'; " <>
                  "connect-src 'self' https: wss:; " <>
                  "worker-src 'self' blob:; " <>
                  "child-src blob:; " <>
                  "frame-src #{@frame_src}; " <>
                  "frame-ancestors 'none'; " <>
                  "object-src 'none'; " <>
                  "base-uri 'self'; " <>
                  "form-action 'self'"

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {ServiceRadarWebNGWeb.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers, %{"content-security-policy" => @csp})
    plug(SecurityHeaders)
    # Passive proxy mode: allow an upstream gateway to authenticate users by
    # injecting a JWT on each request. This plug is a no-op unless
    # auth_settings.mode == passive_proxy.
    plug(GatewayAuth)
    plug(:fetch_current_scope_for_user)
    plug(:set_ash_actor)
  end

  # Authenticated browser pipeline without content negotiation.
  # Used for binary endpoints where clients may send non-HTML Accept headers.
  pipeline :browser_raw_auth do
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_secure_browser_headers, %{"content-security-policy" => @csp})
    plug(SecurityHeaders)
    plug(:require_same_origin_websocket)
    plug(GatewayAuth)
    plug(:fetch_current_scope_for_user)
    plug(:set_ash_actor)
    plug(:require_authenticated_user)
    # Every route on this pipeline is a binary/stream endpoint that upgrades to a
    # websocket. `fetch_current_scope_for_user` performs a sliding-session
    # refresh that dirties the session; without this, the session-cookie
    # `before_send` fires during `Plug.Conn.upgrade_adapter/3` and raises
    # `Plug.Conn.AlreadySentError` (plug 1.20 rejects cookie writes at state
    # `:upgraded`), 500-ing the upgrade so the stream never connects.
    plug(ServiceRadarWebNGWeb.Plugs.IgnoreSessionWrites)
  end

  pipeline :api do
    plug(:accepts, ["json"])
    plug(SecurityHeaders)
  end

  # Interactive API docs UIs (SwaggerUI / ReDoc). These are internal developer
  # tools, not public pages, so they require an authenticated user session.
  # `require_authenticated_user` redirects unauthenticated browsers to log in.
  # The SwaggerUI mounted on this pipeline is configured as an RBAC-backed API
  # console — see the `/api/v2/swaggerui` route below.
  pipeline :api_docs_ui do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {ServiceRadarWebNGWeb.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers, %{"content-security-policy" => @api_docs_csp})
    plug(SecurityHeaders)
    plug(GatewayAuth)
    plug(:fetch_current_scope_for_user)
    plug(:set_ash_actor)
    plug(:require_authenticated_user)
  end

  # OpenAPI spec (JSON) for the `/api/v2` JSON:API. Authenticated: the spec is an
  # internal developer artifact, not a public document. `fetch_current_scope_for_user`
  # accepts either a browser session cookie (used by the in-app SwaggerUI console)
  # or an `Authorization: Bearer` token, and `require_authenticated_user_api`
  # returns a 401 JSON body (rather than an HTML redirect) for anonymous callers.
  pipeline :api_docs_spec do
    plug(:accepts, ["json"])
    plug(SecurityHeaders)
    plug(:fetch_session)
    plug(GatewayAuth)
    plug(:fetch_current_scope_for_user)
    plug(:require_authenticated_user_api)
  end

  pipeline :api_auth do
    plug(:accepts, ["json"])
    plug(SecurityHeaders)
    plug(:fetch_session)
    plug(:skip_csrf_protection_for_bearer_auth)
    plug(:protect_from_forgery)
    plug(:fetch_current_scope_for_user)
    plug(:set_ash_actor)
    plug(:require_authenticated_user_api)
  end

  # API authentication for CLI/external tools (API key or bearer token)
  pipeline :api_key_auth do
    plug(:accepts, ["json"])
    plug(SecurityHeaders)
    plug(ApiAuth)
    # Confines CLI device-flow tokens to the routes their narrow scope was
    # granted for. Coarse client-credential scopes, API keys and sessions pass
    # through untouched. See `Auth.NarrowScopes`.
    plug(ConfineNarrowScope)
  end

  # MCP streamable HTTP. Default-off (`McpEnabled`), user-bound API
  # credentials with the `mcp` OAuth scope, never legacy static keys.
  pipeline :mcp do
    plug(:accepts, ["json"])
    plug(SecurityHeaders)
    plug(McpEnabled)
    plug(McpWwwAuthenticate)
    # Register before_send before auth plugs so 401/403 still emit mcp_auth_failed.
    plug(McpSessionAudit)
    plug(ApiAuth)
    plug(McpRequireUser)
    plug(RequireOauthScope, scope: "mcp")
    plug(McpRequirePermission)
    plug(RateLimit, bucket: :mcp, subject: :ip_and_actor, response_mode: :json)
    plug(McpAshContext)
  end

  pipeline :dev_routes do
    plug(:ensure_dev_routes_enabled)
  end

  pipeline :admin_basic_auth do
    plug(ServiceRadarWebNGWeb.Plugs.BasicAuth)
  end

  pipeline :oban_access do
    plug(:require_oban_access)
  end

  # API pipeline for token-gated endpoints (no session auth required)
  pipeline :api_token_auth do
    plug(:accepts, ["json"])
    plug(SecurityHeaders)
  end

  # Deliberately excludes fetch_session, current-user/JWT authentication, and
  # API-key authentication. The controller accepts only its one-time callback
  # bearer and rebuilds current authority from immutable persisted identity.
  pipeline :automation_callback do
    plug(ServiceRadarWebNGWeb.Plugs.AutomationCallbackResponseHeaders)
    plug(ServiceRadarWebNGWeb.Plugs.AutomationCallbackRequestGuard)
    plug(SecurityHeaders)
  end

  # Notification action links (design D7 Phase 1, task 1.6.3). Deliberately
  # excludes fetch_session, every auth plug, and `protect_from_forgery`: the
  # per-delivery capability token in the URL IS the authorisation, and a CSRF
  # token would add a cookie dependency to a page routinely opened straight from
  # a mail client while buying nothing (an attacker who could forge the
  # submission would need the token to address it, and holding it could POST
  # directly). HTML rather than JSON, because a human clicked a link.
  pipeline :notification_action do
    plug(:accepts, ["html"])
    plug(:put_root_layout, html: {ServiceRadarWebNGWeb.Layouts, :root})
    plug(:put_secure_browser_headers, %{"content-security-policy" => @csp})
    plug(SecurityHeaders)
  end

  # Token-scope gate for the CLI dashboard-publish endpoints. Layered on top of
  # `:api_key_auth` so the bearer token is validated first, then this plug
  # rejects any request whose `scopes` claim does not include
  # `dashboard.publish`. The fallback `cli.dashboard.publish` permission lets
  # the existing Settings → Dashboard Packages LiveView upload modal continue
  # to work (session-auth, no JWT, no `oauth_token_scope` assign).
  pipeline :require_dashboard_publish_scope do
    plug(RequireOauthScope,
      scope: "dashboard.publish",
      fallback_permission: "cli.dashboard.publish"
    )
  end

  pipeline :require_plugin_publish_scope do
    plug(RequireOauthScope,
      scope: "plugin.publish",
      fallback_permission: "plugins.stage"
    )
  end

  # Named rate-limit pipelines backed by ServiceRadar.Security.RateLimiter
  # (cluster-aware ETS with :pg broadcast). Scopes opt in by piping through
  # the appropriate pipeline; limits and windows come from
  # `config :serviceradar_core, ServiceRadar.Security.RateLimiter`.
  # Wiring onto specific routes happens alongside the per-controller
  # migration that removes inline RateLimiter checks (rollout step).
  pipeline :rate_limit_auth_local do
    plug(RateLimit,
      bucket: :auth_local,
      subject: :ip,
      response_mode: :auto,
      html_redirect_to: "/users/log-in",
      html_flash_template: "Too many login attempts. Please try again in {retry_after} seconds."
    )

    plug(LockoutCheck,
      actor_id_param: "email",
      response_mode: :auto,
      html_redirect_to: "/users/log-in"
    )
  end

  pipeline :rate_limit_password_reset do
    plug(RateLimit,
      bucket: :auth_password_reset,
      subject: :ip,
      response_mode: :auto,
      html_redirect_to: "/auth/password-reset",
      html_flash_template: "Too many password reset requests. Please try again in {retry_after} seconds."
    )
  end

  pipeline :rate_limit_auth_oidc do
    plug(RateLimit,
      bucket: :auth_oidc_callback,
      subject: :ip,
      response_mode: :auto,
      html_redirect_to: "/users/log-in"
    )
  end

  pipeline :rate_limit_auth_saml do
    plug(RateLimit,
      bucket: :auth_saml_callback,
      subject: :ip,
      response_mode: :auto,
      html_redirect_to: "/users/log-in"
    )
  end

  pipeline :rate_limit_cli_device_auth do
    plug(RateLimit,
      bucket: :cli_device_auth,
      subject: :ip,
      response_mode: :json,
      json_body_builder: &Bodies.cli_device_auth/1
    )
  end

  pipeline :rate_limit_dashboard_publish do
    plug(RateLimit,
      bucket: :dashboard_publish,
      subject: :ip_and_actor,
      response_mode: :json
    )
  end

  pipeline :rate_limit_plugin_upload do
    plug(RateLimit, bucket: :plugin_upload, subject: :ip_and_actor)
  end

  pipeline :rate_limit_oauth_password do
    plug(RateLimit,
      bucket: :oauth_password_grant,
      subject: :ip,
      response_mode: :json
    )

    plug(LockoutCheck,
      actor_id_param: "username",
      response_mode: :json
    )
  end

  pipeline :rate_limit_oauth_client_credentials do
    plug(RateLimit,
      bucket: :oauth_client_credentials,
      subject: :ip,
      response_mode: :json
    )
  end

  pipeline :rate_limit_api_default do
    plug(RateLimit, bucket: :api_default, subject: :ip)
  end

  pipeline :rate_limit_automation_callback do
    plug(RateLimit,
      bucket: :automation_callback_grant,
      subject: :ip,
      response_mode: :json,
      json_body_builder: &Bodies.automation_callback/1
    )
  end

  # The action-link endpoint is unauthenticated, so a per-IP limit is the only
  # thing that makes guessing a 43-character secret cost anything (task 1.6.5).
  # `:json` rather than `:auto`: the HTML denial path redirects to the login
  # page, which for a link clicked out of an email would read as "your
  # acknowledgement needs an account" - the opposite of what happened.
  # Inbound provider interactions (design D7 phase 2, task 4.3.0b). Accepts the
  # content types providers actually send - Slack posts urlencoded, others post
  # JSON - which is why this cannot reuse `:notification_action`, whose
  # `accepts ["html"]` would answer a provider POST with 406.
  #
  # Deliberately excludes fetch_session, every auth plug, and
  # `protect_from_forgery`: the request arrives from a provider with no cookie
  # and no CSRF token, and the provider's signature over the raw body IS the
  # authorisation. The routes below sit under `/api/notifications/callbacks/`,
  # which `ServiceRadarWebNGWeb.Api.RawBodyReader` buffers - without that the
  # signature would be checked against a re-encoded body and never match.
  pipeline :notification_callback do
    plug(:accepts, ["json", "urlencoded"])
    plug(SecurityHeaders)
  end

  # Its own bucket, not the action-link one. A provider retrying a delivery must
  # not exhaust the budget an on-call engineer needs to click Acknowledge.
  pipeline :rate_limit_notification_callback do
    plug(RateLimit,
      bucket: :notification_callback,
      subject: :ip,
      response_mode: :json
    )
  end

  pipeline :rate_limit_notification_action do
    plug(RateLimit,
      bucket: :notification_action,
      subject: :ip,
      response_mode: :json
    )
  end

  # CSP violation reports are sent by the browser as
  # `application/csp-report` (or `application/reports+json`). The standard
  # `:api` pipeline calls `:accepts ["json"]`, which would reject those
  # content types, so we give the report endpoint its own minimal
  # pipeline. The endpoint itself is intentionally unauthenticated.
  pipeline :csp_report do
    plug(:accepts, ["json", "csp-report", "reports+json"])
    plug(SecurityHeaders)
  end

  scope "/", ServiceRadarWebNGWeb do
    get("/health", HealthController, :ready)
    get("/health/live", HealthController, :live)
    get("/health/ready", HealthController, :ready)
    get("/metrics", MetricsController, :index)
  end

  scope "/api/security", ServiceRadarWebNGWeb do
    pipe_through([:csp_report, :rate_limit_api_default])

    post("/csp-report", CspReportController, :create)
  end

  scope "/api/northbound", ServiceRadarWebNGWeb.Api do
    pipe_through([:api, :rate_limit_api_default])

    post("/action-callbacks/:job_id", NorthboundActionCallbackController, :create)
  end

  # Acknowledge / Snooze / Resolve from inside a notification (design D7 Phase 1,
  # task 1.6.3). `ServiceRadar.Notifications.ActionLinks` builds these URLs; the
  # path names neither the alert nor the action, both of which are bound into the
  # token and read back off the persisted row.
  #
  # The GET renders a confirmation interstitial and changes NOTHING. Mail
  # scanners and link previewers fetch every URL in a message before a human sees
  # it, so an acting GET would let a spam filter acknowledge the fleet. Only the
  # POST redeems.
  scope "/api/notifications", ServiceRadarWebNGWeb.Api do
    pipe_through([:notification_action, :rate_limit_notification_action])

    get("/actions/:token", NotificationActionController, :show)
    post("/actions/:token", NotificationActionController, :create)
  end

  # The provider segment is part of the path so each provider gets a distinct URL
  # to register with, and so the prefix stays under
  # `/api/notifications/callbacks/` - RawBodyReader matches on
  # `String.starts_with?`, so a route at the bare `/api/notifications/callbacks`
  # would NOT be buffered and every signature check would fail confusingly.
  scope "/api/notifications/callbacks", ServiceRadarWebNGWeb.Api do
    pipe_through([:notification_callback, :rate_limit_notification_callback])

    post("/:provider", NotificationCallbackController, :create)
  end

  scope "/api/v1/automation", ServiceRadarWebNGWeb.Api do
    pipe_through([:automation_callback, :rate_limit_automation_callback])

    post(
      "/callback-grants/:grant_id/actions/remote_access.ssh_ca.bundle.read",
      AutomationCallbackGrantController,
      :consume_ssh_ca_bundle
    )
  end

  scope "/api/docs", ServiceRadarWebNGWeb.Api do
    pipe_through(:api)

    get("/v1/admin/openapi.json", OpenapiController, :published_admin_v1)
  end

  # JSON:API pipeline for Ash resources (v2 API)
  pipeline :ash_json_api do
    plug(:accepts, ["json"])
    plug(SecurityHeaders)
    plug(:fetch_session)
    plug(:skip_csrf_protection_for_bearer_auth)
    plug(:protect_from_forgery)
    plug(:fetch_current_scope_for_user)
    plug(:set_ash_actor)
    plug(ServiceRadarWebNGWeb.Plugs.ApiErrorHandler)
  end

  scope "/", ServiceRadarWebNGWeb do
    pipe_through(:browser)

    get("/", PageController, :home)
  end

  # Mobile God-View Streaming Scope
  scope "/v1", ServiceRadarWebNGWeb.Api do
    pipe_through(:api_auth)

    get("/stream/:session_id", StreamController, :connect)
  end

  # FieldSurvey mobile clients authenticate with OAuth/API bearer tokens and
  # stream Arrow IPC frames over WebSockets.
  scope "/v1", ServiceRadarWebNGWeb.Api do
    pipe_through(:api_key_auth)

    get("/field-survey/auth-check", FieldSurveyStreamController, :auth_check)
    get("/field-survey/:session_id/rf-observations", FieldSurveyStreamController, :rf_observations)
    get("/field-survey/:session_id/pose-samples", FieldSurveyStreamController, :pose_samples)
    get("/field-survey/:session_id/spectrum-observations", FieldSurveyStreamController, :spectrum_observations)
    post("/field-survey/:session_id/room-artifacts", FieldSurveyStreamController, :room_artifacts)
  end

  scope "/v1", ServiceRadarWebNGWeb.Api do
    pipe_through(:browser_raw_auth)

    get("/camera-relay-sessions/:id/stream", CameraRelayStreamController, :connect)
    get("/proxmox/console-sessions/:id/stream", ProxmoxConsoleStreamController, :connect)
    get("/remote-access/sessions/:id/stream", RemoteAccessStreamController, :connect)
  end

  scope "/.well-known", ServiceRadarWebNGWeb do
    pipe_through(:api)

    get("/oauth-protected-resource", OAuthMetadataController, :protected_resource)
    get("/oauth-protected-resource/mcp", OAuthMetadataController, :protected_resource)
    get("/oauth-authorization-server", OAuthMetadataController, :authorization_server)
  end

  scope "/mcp" do
    pipe_through(:mcp)

    forward("/", AshAi.Mcp.Router,
      otp_app: :serviceradar_web_ng,
      tools: Mcp.v1_tools(),
      mcp_resources: Mcp.v1_resources(),
      protocol_version_statement: "2025-03-26",
      mcp_name: "serviceradar",
      tool_argument_transformer: &Mcp.wrap_tool_arguments/3,
      instructions: Mcp.instructions()
    )
  end

  # Other scopes may use custom stacks.
  scope "/api", ServiceRadarWebNGWeb.Api do
    pipe_through([:api_auth, :rate_limit_api_default])

    post("/query", QueryController, :execute)
    get("/srql/catalog", SrqlCatalogController, :show)
    get("/addon-fleet", AddonFleetController, :index)
    get("/devices", DeviceController, :index)
    get("/devices/ocsf/export", DeviceController, :ocsf_export)
    get("/devices/:uid", DeviceController, :show)
    patch("/devices/:uid/metadata", DeviceController, :update_metadata)
    post("/camera-relay-sessions", CameraRelaySessionController, :create)
    get("/camera-relay-sessions/:id", CameraRelaySessionController, :show)
    post("/camera-relay-sessions/:id/close", CameraRelaySessionController, :close)
    post("/proxmox/console-sessions", ProxmoxConsoleSessionController, :create)
    get("/proxmox/console-sessions/:id", ProxmoxConsoleSessionController, :show)
    post("/proxmox/console-sessions/:id/close", ProxmoxConsoleSessionController, :close)
    get("/remote-access/host-keys", RemoteAccessHostKeyController, :index)
    post("/remote-access/host-keys/observations", RemoteAccessHostKeyController, :observe)
    post("/remote-access/host-keys/:id/trust", RemoteAccessHostKeyController, :trust)
    post("/remote-access/host-keys/:id/reject", RemoteAccessHostKeyController, :reject)
    post("/remote-access/host-keys/:id/revoke", RemoteAccessHostKeyController, :revoke)
    post("/remote-access/host-keys/:id/rotate", RemoteAccessHostKeyController, :rotate)
    get("/remote-access/desktop-targets", RemoteAccessDesktopTargetController, :index)
    post("/remote-access/app-sessions", RemoteAccessTargetIntentController, :create_app)
    post("/remote-access/tcp-sessions", RemoteAccessTargetIntentController, :create_tcp)
    post("/remote-access/sessions", RemoteAccessSessionController, :create)
    get("/remote-access/devices/:device_uid/ssh-options", RemoteAccessSessionController, :ssh_options)
    get("/remote-access/sessions/:id", RemoteAccessSessionController, :show)
    post("/remote-access/sessions/:id/close", RemoteAccessSessionController, :close)
    post("/remote-access/sessions/:id/webrtc/session", RemoteDesktopWebRTCController, :create_session)

    post(
      "/remote-access/sessions/:id/webrtc/session/:viewer_session_id/answer",
      RemoteDesktopWebRTCController,
      :submit_answer
    )

    post(
      "/remote-access/sessions/:id/webrtc/session/:viewer_session_id/candidates",
      RemoteDesktopWebRTCController,
      :add_candidate
    )

    delete(
      "/remote-access/sessions/:id/webrtc/session/:viewer_session_id",
      RemoteDesktopWebRTCController,
      :close_session
    )

    get("/remote-access/file-transfers", RemoteAccessFileTransferController, :index)
    post("/remote-access/file-transfers", RemoteAccessFileTransferController, :create)
    get("/remote-access/recordings/:id", RemoteAccessRecordingController, :show)
    get("/remote-access/recordings/:id/events", RemoteAccessRecordingController, :events)
    get("/remote-access/recordings/:id/export", RemoteAccessRecordingController, :export)
    delete("/remote-access/recordings/:id", RemoteAccessRecordingController, :delete)
    post("/camera-relay-sessions/:id/webrtc/session", CameraRelayWebRTCController, :create_session)

    post(
      "/camera-relay-sessions/:id/webrtc/session/:viewer_session_id/answer",
      CameraRelayWebRTCController,
      :submit_answer
    )

    post(
      "/camera-relay-sessions/:id/webrtc/session/:viewer_session_id/candidates",
      CameraRelayWebRTCController,
      :add_candidate
    )

    delete(
      "/camera-relay-sessions/:id/webrtc/session/:viewer_session_id",
      CameraRelayWebRTCController,
      :close_session
    )

    get("/spatial/samples", SpatialController, :index)
    get("/spatial/scene", SpatialController, :scene)
    get("/spatial/room-artifacts", SpatialController, :room_artifacts)
    get("/spatial/room-artifacts/:id/download", SpatialController, :download_room_artifact)
    get("/spatial/field-surveys/:session_id/export", SpatialController, :field_survey_export)
  end

  # Admin API (session/JWT auth)
  scope "/api/admin", ServiceRadarWebNGWeb.Api do
    pipe_through(:api_auth)

    get("/openapi", OpenapiController, :admin)

    get("/users", UserController, :index)
    get("/users/:id", UserController, :show)
    post("/users", UserController, :create)
    patch("/users/:id", UserController, :update)
    post("/users/:id/deactivate", UserController, :deactivate)
    post("/users/:id/reactivate", UserController, :reactivate)
    post("/users/:id/local-login", UserController, :set_local_login)

    # The provider applications whose signatures authorise an inbound
    # notification callback (task 4.3.1a). Authorisation is the resource's own
    # `notifications.providers.manage` policy, reached through the request scope.
    get("/notification-callback-apps", NotificationCallbackAppController, :index)
    post("/notification-callback-apps", NotificationCallbackAppController, :create)

    post(
      "/notification-callback-apps/:id/rotate-secret",
      NotificationCallbackAppController,
      :rotate_secret
    )

    delete("/notification-callback-apps/:id", NotificationCallbackAppController, :delete)

    get("/authorization-settings", AuthorizationSettingsController, :show)
    put("/authorization-settings", AuthorizationSettingsController, :update)
    get("/bmp-settings", BmpSettingsController, :show)
    put("/bmp-settings", BmpSettingsController, :update)

    get("/role-profiles/catalog", RoleProfileController, :catalog)
    get("/role-profiles", RoleProfileController, :index)
    get("/role-profiles/:id", RoleProfileController, :show)
    post("/role-profiles", RoleProfileController, :create)
    patch("/role-profiles/:id", RoleProfileController, :update)
    delete("/role-profiles/:id", RoleProfileController, :delete)
    get("/camera-analysis-workers", CameraAnalysisWorkerController, :index)
    get("/camera-analysis-workers/:id", CameraAnalysisWorkerController, :show)
    post("/camera-analysis-workers", CameraAnalysisWorkerController, :create)
    patch("/camera-analysis-workers/:id", CameraAnalysisWorkerController, :update)
    post("/camera-analysis-workers/:id/enable", CameraAnalysisWorkerController, :enable)
    post("/camera-analysis-workers/:id/disable", CameraAnalysisWorkerController, :disable)
    get("/remote-access/desktop-targets", RemoteAccessDesktopTargetController, :admin_index)
    post("/remote-access/desktop-targets", RemoteAccessDesktopTargetController, :admin_create)
    get("/remote-access/desktop-targets/:id", RemoteAccessDesktopTargetController, :admin_show)
    patch("/remote-access/desktop-targets/:id", RemoteAccessDesktopTargetController, :admin_update)
    post("/remote-access/desktop-targets/:id/enable", RemoteAccessDesktopTargetController, :admin_enable)
    post("/remote-access/desktop-targets/:id/disable", RemoteAccessDesktopTargetController, :admin_disable)

    post("/topology/route-analysis", TopologyController, :route_analysis)
  end

  # Ad-hoc scan API for external tools (API key or bearer token auth)
  scope "/api/v1", ServiceRadarWebNGWeb.Api do
    pipe_through(:api_key_auth)

    post("/scans", ScanController, :create)
    get("/scans/:id", ScanController, :show)
    get("/scans/:id/results", ScanController, :results)

    post("/validation-runs", ValidationRunController, :create)
    get("/validation-runs/:id", ValidationRunController, :show)
    get("/validation-runs/:id/results", ValidationRunController, :results)

    # Address -> device uid, without the probe. A validation run also resolves identity,
    # but only as a step before scanning; a caller that wants the id and not the scan
    # had no way to ask for it.
    get("/identity/resolve", IdentityController, :resolve)
    post("/identity/resolve", IdentityController, :resolve_batch)
  end

  # Edge onboarding admin API (API key or bearer token auth)
  scope "/api/admin", ServiceRadarWebNGWeb.Api do
    pipe_through(:api_key_auth)

    # Package defaults and templates
    get("/edge-packages/defaults", EdgeController, :defaults)
    get("/component-templates", EdgeController, :templates)

    # Package CRUD
    get("/edge-packages", EdgeController, :index)
    post("/edge-packages", EdgeController, :create)
    get("/edge-packages/:id", EdgeController, :show)
    delete("/edge-packages/:id", EdgeController, :delete)

    # Package events
    get("/edge-packages/:id/events", EdgeController, :events)

    # Package actions
    post("/edge-packages/:id/revoke", EdgeController, :revoke)
    post("/gateways/:gateway_id/agent-certs/:component_id/revoke", EdgeController, :revoke_agent_certificate)

    # Plugin registry
    get("/plugins", PluginController, :index)
    post("/plugins", PluginController, :create)
    get("/plugins/:id", PluginController, :show)
    patch("/plugins/:id", PluginController, :update)

    # Plugin packages
    get("/plugin-packages", PluginPackageController, :index)
    get("/plugin-packages/:id", PluginPackageController, :show)
    post("/plugin-packages/:id/download-url", PluginPackageController, :download_url)
    post("/plugin-packages/:id/approve", PluginPackageController, :approve)
    post("/plugin-packages/:id/deny", PluginPackageController, :deny)
    post("/plugin-packages/:id/revoke", PluginPackageController, :revoke)
    post("/plugin-packages/:id/restage", PluginPackageController, :restage)

    # Plugin assignments
    get("/plugin-assignments", PluginAssignmentController, :index)
    post("/plugin-assignments", PluginAssignmentController, :create)
    get("/plugin-assignments/:id", PluginAssignmentController, :show)
    patch("/plugin-assignments/:id", PluginAssignmentController, :update)
    delete("/plugin-assignments/:id", PluginAssignmentController, :delete)

    # Credential secrets and rules (same auth as plugin assignments)
    get("/network-credential-secrets", NetworkCredentialSecretController, :index)
    post("/network-credential-secrets", NetworkCredentialSecretController, :create)
    get("/network-credential-secrets/:id", NetworkCredentialSecretController, :show)
    patch("/network-credential-secrets/:id", NetworkCredentialSecretController, :update)
    post("/network-credential-secrets/:id/rotate", NetworkCredentialSecretController, :rotate)

    get("/network-credential-rules", NetworkCredentialRuleController, :index)
    post("/network-credential-rules", NetworkCredentialRuleController, :create)
    get("/network-credential-rules/:id", NetworkCredentialRuleController, :show)
    patch("/network-credential-rules/:id", NetworkCredentialRuleController, :update)
    post("/network-credential-rules/:id/enable", NetworkCredentialRuleController, :enable)
    post("/network-credential-rules/:id/disable", NetworkCredentialRuleController, :disable)

    get("/ansible-controllers", AnsibleControllerController, :index)
    post("/ansible-controllers", AnsibleControllerController, :create)
    get("/ansible-controllers/:id", AnsibleControllerController, :show)
    patch("/ansible-controllers/:id", AnsibleControllerController, :update)
    post("/ansible-controllers/:id/enable", AnsibleControllerController, :enable)
    post("/ansible-controllers/:id/disable", AnsibleControllerController, :disable)

    # Collector package management
    get("/collectors", CollectorController, :index)
    post("/collectors", CollectorController, :create)
    get("/collectors/:id", CollectorController, :show)
    post("/collectors/:id/revoke", CollectorController, :revoke)

    # NATS account & credentials
    get("/nats/account", CollectorController, :account_status)
    get("/nats/credentials", CollectorController, :credentials)
  end

  ## CLI plugin publish (stage + bundle upload token).
  # A sibling of the /api/admin block above so the publish-scope pipeline gates
  # only these two write calls. `GET /plugin-packages/:id` deliberately stays in
  # the general block: it is read-only, a session viewer holds `plugins.view`
  # rather than `plugins.stage`, and RequireOauthScope's fallback would 403
  # them. Narrow-scoped CLI tokens still reach it only via `Auth.NarrowScopes`.
  scope "/api/admin", ServiceRadarWebNGWeb.Api do
    pipe_through([:api_key_auth, :require_plugin_publish_scope])

    post("/plugin-packages", PluginPackageController, :create)
    post("/plugin-packages/:id/upload-url", PluginPackageController, :upload_url)
  end

  # Edge package download - token-gated (no session auth required)
  # This allows CLI tools to download packages using only the download token
  scope "/api/admin", ServiceRadarWebNGWeb.Api do
    pipe_through(:api_token_auth)

    post("/edge-packages/:id/download", EdgeController, :download)
    post("/collectors/:id/download", CollectorController, :download)
  end

  # Edge package bundle download - public endpoint with token in header/body
  # Allows one-liner curl commands for zero-touch provisioning without URL token leakage
  scope "/api", ServiceRadarWebNGWeb.Api do
    pipe_through(:api)

    post("/edge-packages/:id/bundle", EdgeController, :bundle)
    post("/collectors/:id/bundle", CollectorController, :bundle)
    put("/plugin-packages/:id/blob", PluginPackageController, :upload_blob)
    post("/plugin-packages/:id/blob/download", PluginPackageController, :download_blob)
    post("/addon-packages/:id/blob/download", AddonPackageController, :download_blob)
  end

  # OpenAPI spec — authenticated (session cookie OR bearer). Defined before the
  # JSON:API data forward below so `/api/v2/open_api` resolves here.
  scope "/api/v2", ServiceRadarWebNGWeb.Api do
    pipe_through(:api_docs_spec)

    get("/open_api", OpenApiV2Controller, :show)
  end

  # Interactive docs UIs — authenticated internal tools.
  #
  # SwaggerUI is an RBAC-backed API console: because the user is already logged
  # in to web-ng, "Try it out" runs AS THE LOGGED-IN USER with zero token
  # wrangling. `with_credentials: true` makes SwaggerUI send the request with
  # same-origin credentials (the session cookie), and the plug's built-in
  # request interceptor attaches the `x-csrf-token` header for same-origin
  # requests. So calls to `/api/*` and `/api/v2/*` authenticate via the user's
  # session and are authorized by each resource's Ash policies (RBAC). The spec
  # served at `/api/v2/open_api` drops the global bearer-auth requirement, so the
  # "Authorize / paste JWT" step is not required (it remains an optional fallback
  # via `persist_authorization`).
  scope "/api/v2" do
    pipe_through(:api_docs_ui)

    forward("/swaggerui", OpenApiSpex.Plug.SwaggerUI,
      path: "/api/v2/open_api",
      default_model_expand_depth: 4,
      with_credentials: true,
      persist_authorization: true
    )

    forward("/redoc", Redoc.Plug.RedocUI, spec_url: "/api/v2/open_api")
  end

  # Ash JSON:API v2 DATA endpoints (`/api/v2/<resource>`).
  #
  # The pipeline sets the Ash actor (from a session cookie or bearer token) but
  # does NOT require authentication at the router layer: access is gated by each
  # resource's Ash policies. Every JSON:API-exposed resource uses
  # `authorizers: [Ash.Policy.Authorizer]` with read policies that require a
  # viewer role or an explicit permission, and Ash forbids by default, so a nil
  # (unauthenticated) actor reads nothing. The OpenAPI spec is NOT served here —
  # it is gated separately above (`/api/v2/open_api`).
  scope "/api/v2" do
    pipe_through(:ash_json_api)

    forward("/", ServiceRadarWebNGWeb.AshJsonApiRouter)
  end

  scope "/dev" do
    pipe_through([:browser, :dev_routes])

    live_dashboard("/dashboard",
      metrics: ServiceRadarWebNGWeb.Telemetry,
      additional_pages: [
        broadway: {BroadwayDashboard, pipelines: [ServiceRadar.EventWriter.Pipeline]}
      ]
    )

    forward("/mailbox", Plug.Swoosh.MailboxPreview)

    # AshAdmin for Ash resource management (dev/staging only)
    ash_admin("/ash",
      domains: [
        ServiceRadar.Identity,
        ServiceRadar.Inventory,
        ServiceRadar.Infrastructure,
        ServiceRadar.Monitoring,
        ServiceRadar.Edge
      ],
      actor: fn conn ->
        # Get actor from session for AshAdmin
        case conn.assigns[:current_scope] do
          %{user: user} when not is_nil(user) -> user
          _ -> nil
        end
      end
    )
  end

  scope "/admin", ServiceRadarWebNGWeb do
    pipe_through([:browser, :require_authenticated_user])

    live_session :admin,
      on_mount: [{ServiceRadarWebNGWeb.UserAuth, :require_authenticated}, ShellHook] do
      live("/jobs", Admin.JobLive.Index, :index)
      live("/jobs/:id", Admin.JobLive.Show, :show)
      live("/edge-packages", Admin.EdgePackageLive.Index, :index)
      live("/edge-packages/new", Admin.EdgePackageLive.Index, :new)
      live("/edge-packages/:id", Admin.EdgePackageLive.Index, :show)
      live("/plugins", Admin.PluginPackageLive.Index, :index)
      live("/plugins/new", Admin.PluginPackageLive.Index, :new)
      live("/plugins/:id", Admin.PluginPackageLive.Index, :show)
      live("/addons", Admin.AddonPackageLive.Index, :index)
      live("/addons/:id", Admin.AddonPackageLive.Index, :show)
      live("/cluster", Admin.ClusterLive.Index, :index)
      live("/collectors", Admin.CollectorLive.Index, :index)
      live("/collectors/:id", Admin.CollectorLive.Index, :show)
      live("/edge-sites", Admin.EdgeSitesLive.Index, :index)
      live("/edge-sites/new", Admin.EdgeSitesLive.Index, :new)
      live("/edge-sites/:id", Admin.EdgeSitesLive.Show, :show)
    end

    scope "/" do
      pipe_through([:oban_access])

      oban_dashboard("/oban",
        oban_name: Oban,
        as: :admin_oban_dashboard,
        resolver: ServiceRadarWebNGWeb.ObanResolver
      )
    end
  end

  ## OAuth2 Token Endpoint
  # Client credentials grant for API access

  scope "/oauth", ServiceRadarWebNGWeb do
    pipe_through(:api)

    post("/token", OAuthController, :token)
    post("/backchannel-logout", OAuthBackchannelLogoutController, :create)
  end

  scope "/oauth", ServiceRadarWebNGWeb do
    pipe_through(:browser)

    get("/authorize", OAuthAuthorizeController, :new)
  end

  ## CLI device-code auth (RFC 8628)
  # No session auth — these are called directly from @carverauto/serviceradar-cli.
  # The /cli/auth/device LiveView (browser-side approval) lives in the
  # browser scope below.

  scope "/api/v1/cli/auth", ServiceRadarWebNGWeb do
    pipe_through([:api_token_auth, :rate_limit_cli_device_auth])

    post("/device", CliAuthController, :device)
    post("/token", CliAuthController, :token)
  end

  ## CLI dashboard publish (multipart upload + lifecycle).
  # Bearer-token gated on `dashboard.publish` scope; per-action RBAC enforced
  # inside the controller (`cli.dashboard.publish` for create,
  # `cli.dashboard.enable` / `cli.dashboard.disable` for the lifecycle calls).
  scope "/api/v1", ServiceRadarWebNGWeb do
    pipe_through([:api_key_auth, :require_dashboard_publish_scope])

    post("/dashboard-packages", DashboardPackagePublishController, :create)
    post("/dashboard-packages/:id/enable", DashboardPackagePublishController, :enable)
    post("/dashboard-packages/:id/disable", DashboardPackagePublishController, :disable)
  end

  scope "/api/v1", ServiceRadarWebNGWeb.Api do
    pipe_through(:api_key_auth)

    get("/source-inventory", SourceInventoryController, :index)
  end

  ## Authentication routes
  # Password login, logout, and password reset. Credential-bearing
  # POSTs are split into their own sub-scopes so they get the
  # appropriate rate-limit + lockout pipelines layered on top of
  # `:browser`. The form-render GETs and sign-out / registration
  # routes stay in the unmetered `:browser` scope.

  scope "/auth", ServiceRadarWebNGWeb do
    pipe_through(:browser)

    # Sign out
    delete("/sign-out", AuthController, :delete)

    # Password reset (form renders, no credential check)
    get("/password-reset", AuthController, :new_reset_request)
    get("/password-reset/:token", AuthController, :show_reset_form)

    # Registration (if enabled)
    post("/register", AuthController, :register)

    # SSO initiation + non-callback metadata
    get("/oidc", OIDCController, :request)
    get("/saml", SAMLController, :request)
    get("/saml/metadata", SAMLController, :metadata)
  end

  # Local password sign-in — rate limited + lockout-gated.
  scope "/auth", ServiceRadarWebNGWeb do
    pipe_through([:browser, :rate_limit_auth_local])

    post("/sign-in", AuthController, :create)
    post("/local/sign-in", AuthController, :local_sign_in)
  end

  # Password reset submissions — rate limited, no lockout check.
  scope "/auth", ServiceRadarWebNGWeb do
    pipe_through([:browser, :rate_limit_password_reset])

    post("/password-reset", AuthController, :request_reset)
    put("/password-reset/:token", AuthController, :reset_password)
  end

  # OIDC callback — rate limited.
  scope "/auth", ServiceRadarWebNGWeb do
    pipe_through([:browser, :rate_limit_auth_oidc])

    get("/oidc/callback", OIDCController, :callback)
  end

  # SAML callback — rate limited.
  scope "/auth", ServiceRadarWebNGWeb do
    pipe_through([:browser, :rate_limit_auth_saml])

    post("/saml/consume", SAMLController, :consume)
  end

  ## Authenticated routes

  scope "/", ServiceRadarWebNGWeb do
    pipe_through([:browser_raw_auth])

    get("/topology/snapshot/latest", TopologySnapshotController, :show)
    get("/god_view_exec.wasm", WasmAssetController, :plain)
    get("/god_view_exec-:digest", WasmAssetController, :hashed)
    get("/dashboard-packages/:id/renderer", DashboardPackageAssetController, :show)
    get("/dashboard-packages/:id/renderer.wasm", DashboardPackageAssetController, :show)
  end

  scope "/", ServiceRadarWebNGWeb do
    pipe_through([:browser, :require_authenticated_user])

    get("/users/settings", PageController, :redirect_to_settings_profile)
    get("/flows", PageController, :redirect_to_observability_flows)
    get("/flows/visualize", PageController, :redirect_to_observability_flows)
    get("/observability/flows", PageController, :redirect_to_observability_flows)
    get("/observability/flows/visualize", PageController, :redirect_to_observability_flows)
    get("/dashboard/:dashboard_id/panels/:panel_id/export.csv", AuthoredDashboardExportController, :panel_csv)
    get("/scans/:id/export.csv", ScanExportController, :csv)
    get("/scans/:id/export.xlsx", ScanExportController, :xlsx)

    get(
      "/settings/networks/integrations/runs/:id/export.csv",
      ArmisNorthboundRunExportController,
      :csv
    )

    live_session :require_authenticated_user,
      on_mount: [
        {ServiceRadarWebNGWeb.UserAuth, :require_authenticated},
        ShellHook
      ] do
      live("/analytics", AuthoredDashboardLive.Index, :index)
      live("/dashboard", DashboardLive.Index, :index)
      live("/dashboard/new-devices", DeviceLive.Index, :new_devices)
      live("/dashboard/:dashboard_id", AuthoredDashboardLive.Show, :show)
      live("/dashboards", DashboardHubLive.Index, :index)
      live("/dashboards/:route_slug", DashboardPackageLive.Show, :show)
      live("/security", SecurityLive.Index, :index)
      live("/security/threat-intel", Security.ThreatIntelLive.Index, :index)
      live("/devices", DeviceLive.Index, :index)
      live("/devices/wifi", DeviceLive.Wifi, :index)
      live("/devices/:uid", DeviceLive.Show, :show)
      live("/devices/:uid/proxmox-console", ProxmoxConsoleLive.Show, :show)
      live("/devices/:uid/remote-access/ssh", RemoteAccessLive.SSH, :show)
      live("/devices/:uid/remote-access/rdp", RemoteAccessLive.RDP, :show)
      live("/remote-access/targets", RemoteAccessLive.Targets, :index)
      live("/remote-access/applications/:target_id", RemoteAccessLive.Application, :show)
      live("/remote-access/tcp-targets/:target_id", RemoteAccessLive.TCP, :show)
      live("/devices/:device_uid/interfaces/:interface_uid", InterfaceLive.Show, :show)
      live("/interfaces", InterfaceLive.Index, :index)

      # Connected agents view (instance-scoped, visible to all authenticated users)
      live("/agents", AgentLive.Index, :index)
      live("/agents/:uid", AgentLive.Show, :show)

      # Gateways
      live("/gateways", GatewayLive.Index, :index)
      live("/gateways/:gateway_id", GatewayLive.Show, :show)

      # Kubernetes public VIP / Gateway ownership inventory
      live("/inventory/public-endpoints", PublicEndpointsLive.Index, :index)
      live("/events", EventLive.Index, :index)
      live("/events/:event_id", EventLive.Show, :show)
      live("/alerts", AlertLive.Index, :index)
      live("/alerts/:alert_id", AlertLive.Show, :show)
      # Unified observability list — path encodes tab intent (URL = intent).
      # Detail routes for metrics/traces keep their :id segments below.
      live("/observability", LogLive.Index, :index)
      live("/observability/logs", LogLive.Index, :logs)
      live("/observability/traces", LogLive.Index, :traces)
      live("/observability/metrics", LogLive.Index, :metrics)
      live("/observability/events", LogLive.Index, :events)
      live("/observability/alerts", LogLive.Index, :alerts)
      live("/observability/netflows", LogLive.Index, :netflows)
      live("/observability/flows/attributed", Flows.AttributedLive, :index)
      live("/observability/bmp", BmpLive.Index, :index)
      live("/observability/bgp", BGPLive.Index, :index)
      live("/observability/health", ObservabilityHealthLive.Index, :index)
      live("/observability/camera-relays", CameraRelayLive.Index, :index)
      live("/observability/camera-relays/workers", CameraAnalysisWorkerLive.Index, :index)
      live("/observability/camera-analysis-workers", CameraAnalysisWorkerLive.Index, :legacy)
      live("/cameras", CameraLive.Index, :index)
      live("/cameras/:camera_source_id", CameraLive.Show, :show)
      live("/observability/metrics/:span_id", MetricLive.Show, :show)
      live("/observability/traces/:trace_id", TraceLive.Show, :show)
      # Legacy alias — same LiveView as /observability/logs
      live("/logs", LogLive.Index, :logs)
      live("/logs/:log_id", LogLive.Show, :show)
      live("/services", ServiceLive.Index, :index)
      live("/services/check", ServiceLive.Show, :show)
      live("/topology", TopologyLive.GodView, :index)
      live("/spatial", SpatialLive.Index, :index)
      live("/netflow-map", MapLive.NetflowMap, :index)
      live("/spatial/field-surveys", SpatialLive.FieldSurveyReview, :index)
      live("/spatial/field-surveys/:session_id", SpatialLive.FieldSurveyReview, :show)

      # Ad-hoc network scan
      live("/scans", ScanLive, :index)

      # MTR Diagnostics
      live("/diagnostics/mtr", DiagnosticsLive.Mtr, :index)
      live("/diagnostics/mtr/compare", DiagnosticsLive.MtrCompare, :compare)
      live("/diagnostics/mtr/:trace_id", DiagnosticsLive.MtrTrace, :show)
      live("/settings/profile", UserLive.Settings, :edit)
      live("/settings/api-credentials", UserLive.ApiCredentials, :index)
      live("/settings/mcp-sessions", Settings.McpSessionsLive, :index)
      live("/settings/cli-sessions", Settings.CliSessionsLive, :index)
      live("/oauth/consent", OAuthConsentLive)
      live("/settings/cli-auth", Settings.CliAuthPolicyLive, :index)
      live("/settings/user-groups", Settings.UserGroupsLive, :index)

      live("/settings/audit/events", Settings.AuditLive.Events, :index)
      live("/settings/audit/events/:event_id", Settings.AuditLive.EventShow, :show)
      live("/settings/audit/lockouts", Settings.AuditLive.Lockouts, :index)
      live("/settings/audit/history", Settings.AuditLive.History, :index)
      live("/users/settings/confirm-email/:token", UserLive.Settings, :confirm_email)

      # Cluster visibility for all authenticated users
      live("/settings/cluster", Settings.ClusterLive.Index, :index)
      live("/settings/cluster/nodes/:node_name", NodeLive.Show, :show)
      live("/settings/rules", Settings.RulesLive.Index, :index)
      live("/settings/anomaly-detection", Settings.AnomalyDetectionLive, :index)

      # Notification platform. The tab is a nested path segment so it is
      # deep-linkable and shareable; both paths resolve to the same LiveView,
      # and `/settings/notifications` patches to the first permitted tab.
      live("/settings/notifications", Settings.NotificationsLive.Index, :index)
      live("/settings/notifications/:tab", Settings.NotificationsLive.Index, :tab)

      # Network sweep configuration
      live("/settings/networks", Settings.NetworksLive.Index, :index)
      live("/settings/networks/groups/new", Settings.NetworksLive.Index, :new_group)
      live("/settings/networks/groups/:id", Settings.NetworksLive.Index, :show_group)
      live("/settings/networks/groups/:id/edit", Settings.NetworksLive.Index, :edit_group)
      live("/settings/networks/profiles/new", Settings.NetworksLive.Index, :new_profile)
      live("/settings/networks/profiles/:id/edit", Settings.NetworksLive.Index, :edit_profile)
      live("/settings/networks/discovery", Settings.NetworksLive.Index, :discovery)
      live("/settings/networks/discovery/new", Settings.NetworksLive.Index, :new_mapper_job)
      live("/settings/networks/discovery/:id/edit", Settings.NetworksLive.Index, :edit_mapper_job)
      live("/settings/networks/device-enrichment", Settings.DeviceEnrichmentRulesLive, :index)
      live("/settings/networks/hostname-rdns", Settings.DeviceHostnameRdnsLive, :index)
      live("/settings/networks/availability-sources", Settings.AvailabilitySourceProfilesLive, :index)
      live("/settings/networks/visibility-profiles", Settings.VisibilityProfilesLive.Index, :index)
      live("/settings/networks/visibility-profiles/new", Settings.VisibilityProfilesLive.Index, :new_profile)
      live("/settings/networks/visibility-profiles/:id/edit", Settings.VisibilityProfilesLive.Index, :edit_profile)
      live("/settings/networks/composite-checks", Settings.CompositeChecksLive.Index, :index)
      live("/settings/networks/composite-checks/new", Settings.CompositeChecksLive.Index, :new)

      live(
        "/settings/networks/composite-checks/:id/edit",
        Settings.CompositeChecksLive.Index,
        :edit
      )

      live("/settings/networks/credentials", Settings.NetworkCredentialRulesLive, :index)
      live("/settings/networks/credentials/new", Settings.NetworkCredentialRulesLive, :new)
      live("/settings/networks/credentials/:id/edit", Settings.NetworkCredentialRulesLive, :edit)
      live("/settings/networks/host-keys", Settings.RemoteAccessHostKeysLive, :index)
      live("/settings/networks/desktop-targets", Settings.RemoteAccessDesktopTargetsLive, :index)
      live("/settings/networks/desktop-targets/new", Settings.RemoteAccessDesktopTargetsLive, :new)
      live("/settings/networks/desktop-targets/:id/edit", Settings.RemoteAccessDesktopTargetsLive, :edit)
      live("/settings/networks/recordings", Settings.RemoteAccessRecordingsLive, :index)
      live("/settings/networks/recordings/:id", Settings.RemoteAccessRecordingsLive, :show)
      live("/settings/networks/bmp", Settings.BmpLive.Index, :index)
      live("/settings/networks/field-survey", Settings.FieldSurveyLive.Index, :index)
      live("/settings/networks/mtr", Settings.MtrProfilesLive.Index, :index)
      live("/settings/networks/mtr/new", Settings.MtrProfilesLive.Index, :new_profile)
      live("/settings/networks/mtr/:id/edit", Settings.MtrProfilesLive.Index, :edit_profile)

      # Flow settings (directionality + enrichment configuration)
      live("/settings/flows", Settings.NetflowLive.Index, :index)
      live("/settings/flows/new", Settings.NetflowLive.Index, :new)
      live("/settings/flows/:id/edit", Settings.NetflowLive.Index, :edit)
      live("/settings/flows/app-rules/new", Settings.NetflowLive.Index, :new_app_rule)
      live("/settings/flows/app-rules/:id/edit", Settings.NetflowLive.Index, :edit_app_rule)
      live("/settings/mail", Settings.MailLive, :index)

      # Integration sources configuration
      live("/settings/networks/integrations", Settings.IntegrationsLive.Index, :index)
      live("/settings/networks/integrations/new", Settings.IntegrationsLive.Index, :new)
      live("/settings/networks/integrations/:id", Settings.IntegrationsLive.Index, :show)
      live("/settings/networks/integrations/:id/edit", Settings.IntegrationsLive.Index, :edit)
      live("/settings/networks/prefix-tags", Settings.PrefixTagsLive, :index)
      live("/settings/networks/threat-intel", Settings.ThreatIntelLive.Index, :index)

      # Security settings
      live(
        "/settings/security/vulnerability-feeds",
        Settings.SecurityLive.VulnerabilityFeeds,
        :index
      )

      # Sysmon profiles configuration
      live("/settings/sysmon", Settings.SysmonProfilesLive.Index, :index)
      live("/settings/sysmon/new", Settings.SysmonProfilesLive.Index, :new_profile)
      live("/settings/sysmon/:id/edit", Settings.SysmonProfilesLive.Index, :edit_profile)

      # Endpoint inventory settings
      live("/settings/agents/endpoint-inventory", Settings.EndpointInventoryLive.Index, :index)

      # "Send your telemetry" onboarding (OTLP endpoints, ingestion keys,
      # exporter snippets, first-data checker)
      live("/settings/agents/telemetry-onboarding", Settings.TelemetryOnboardingLive, :index)

      # SNMP profiles configuration
      live("/settings/snmp", Settings.SNMPProfilesLive.Index, :index)
      live("/settings/snmp/new", Settings.SNMPProfilesLive.Index, :new_profile)
      live("/settings/snmp/:id/edit", Settings.SNMPProfilesLive.Index, :edit_profile)

      # Agent deployment
      live("/settings/agents/releases", Settings.AgentsLive.Releases, :index)
      live("/settings/agents/deploy", Settings.AgentsLive.Deploy, :index)
      live("/settings/agents/plugins", Admin.PluginPackageLive.Index, :index)
      live("/settings/agents/plugins/new", Admin.PluginPackageLive.Index, :new)
      live("/settings/agents/plugins/:id", Admin.PluginPackageLive.Index, :show)
      live("/settings/agents/addons", Admin.AddonPackageLive.Index, :index)
      live("/settings/agents/addons/fleet", Admin.AddonFleetLive.Index, :index)
      live("/settings/agents/addons/:id", Admin.AddonPackageLive.Index, :show)
      live("/settings/dashboards/packages", Admin.DashboardPackageLive.Index, :index)
      live("/settings/dashboards/packages/new", Admin.DashboardPackageLive.Index, :new)
      live("/settings/dashboards/packages/:id", Admin.DashboardPackageLive.Index, :show)

      # Zen Rule Editor - visual JDM editor for rule logic
      live("/settings/rules/zen/new", Settings.ZenRuleEditorLive, :new)
      live("/settings/rules/zen/:id", Settings.ZenRuleEditorLive, :edit)
      live("/settings/rules/zen/clone/:clone_id", Settings.ZenRuleEditorLive, :clone)

      get("/infrastructure", PageController, :redirect_to_settings_cluster)
      get("/infrastructure/nodes/:node_name", PageController, :redirect_to_settings_cluster_node)
    end

    live_session :require_authenticated_user_with_permit,
      on_mount: [
        {ServiceRadarWebNGWeb.UserAuth, :require_authenticated},
        Permit.Phoenix.LiveView.AuthorizeHook,
        ShellHook
      ] do
      # Authentication settings (admin only - enforced by Permit policies)
      live("/settings/authentication", Settings.AuthenticationLive, :index)
      live("/settings/auth/users", Settings.AuthUsersLive, :index)
      live("/settings/auth/users/:id", Settings.AuthUserLive.Show, :show)
      live("/settings/auth/rbac", Settings.RbacLive, :index)
      live("/settings/auth/authorization", Settings.AuthorizationLive, :index)

      # Ansible settings (controllers, repositories, and retention)
      live("/settings/ansible", Settings.AnsibleLive, :index)

      # Ansible operations (read-only browsing of playbook execution history)
      live("/ansible/operations", AnsibleLive.OperationsIndex, :index)
      live("/ansible/operations/:id", AnsibleLive.OperationsShow, :show)

      # Ansible launch (ad-hoc operation dispatch, takes ?devices=uid1,uid2)
      live("/ansible/launch", AnsibleLive.LaunchLive, :new)

      # Ansible playbook catalog browser (read-only)
      live("/ansible/catalog", AnsibleLive.CatalogIndex, :index)
    end

    post("/users/update-password", UserSessionController, :update_password)
  end

  # Public authentication pages (login, register)
  scope "/", ServiceRadarWebNGWeb do
    pipe_through(:browser)

    live_session :authentication,
      on_mount: [{ServiceRadarWebNGWeb.UserAuth, :mount_current_scope}] do
      live("/users/log-in", AuthLive.SignIn, :sign_in)
      live("/auth/local", AuthLive.LocalSignIn, :local_sign_in)
      # CLI device-code approval — handles its own redirect-to-log-in so
      # the user_code stays pinned through authentication.
      live("/cli/auth/device", CliDeviceAuthorizeLive)
    end
  end

  scope "/", ServiceRadarWebNGWeb do
    pipe_through([:browser])

    # Legacy session routes (kept for logout handling)
    delete("/users/log-out", UserSessionController, :delete)
  end

  defp ensure_dev_routes_enabled(conn, _opts) do
    if Application.get_env(:serviceradar_web_ng, :dev_routes, false) do
      conn
    else
      conn
      |> Plug.Conn.send_resp(:not_found, "Not Found")
      |> Plug.Conn.halt()
    end
  end

  defp skip_csrf_protection_for_bearer_auth(conn, _opts) do
    case Plug.Conn.get_req_header(conn, "authorization") do
      ["Bearer " <> _] -> Plug.Conn.put_private(conn, :plug_skip_csrf_protection, true)
      ["bearer " <> _] -> Plug.Conn.put_private(conn, :plug_skip_csrf_protection, true)
      _ -> conn
    end
  end

  defp require_same_origin_websocket(conn, _opts) do
    if websocket_upgrade?(conn) and cross_origin_websocket?(conn) do
      conn
      |> Plug.Conn.send_resp(:forbidden, "Forbidden")
      |> Plug.Conn.halt()
    else
      conn
    end
  end

  defp websocket_upgrade?(conn) do
    upgrade =
      conn
      |> Plug.Conn.get_req_header("upgrade")
      |> List.first()
      |> to_string()
      |> String.downcase()

    connection =
      conn
      |> Plug.Conn.get_req_header("connection")
      |> Enum.join(",")
      |> String.downcase()

    upgrade == "websocket" and String.contains?(connection, "upgrade")
  end

  defp cross_origin_websocket?(conn) do
    case Plug.Conn.get_req_header(conn, "origin") do
      # Non-browser API clients often omit Origin; authentication still gates
      # the websocket route, so only browser cross-origin attempts are rejected.
      [] -> false
      [origin | _] -> not same_request_origin?(conn, origin)
    end
  end

  defp same_request_origin?(conn, origin) do
    case URI.parse(origin) do
      %URI{scheme: scheme, host: host} = uri when scheme in ["http", "https"] and is_binary(host) ->
        String.downcase(host) == String.downcase(conn.host) and effective_origin_port(uri) == conn.port

      _other ->
        false
    end
  end

  defp effective_origin_port(%URI{port: nil, scheme: "https"}), do: 443
  defp effective_origin_port(%URI{port: nil, scheme: "http"}), do: 80
  defp effective_origin_port(%URI{port: port}), do: port

  # Set the Ash actor from the current user for policy enforcement
  # Includes partition context from request header or session
  defp set_ash_actor(conn, _opts) do
    case conn.assigns[:current_scope] do
      %Scope{user: user, permissions: scope_permissions} when not is_nil(user) ->
        partition_id = get_partition_id_from_request(conn)

        permissions =
          case scope_permissions do
            %MapSet{} -> scope_permissions
            _ -> ServiceRadar.Identity.RBAC.permissions_for_user(user)
          end

        actor = %{
          id: user.id,
          role: user.role,
          email: user.email,
          role_profile_id: user.role_profile_id,
          permissions: permissions
        }

        actor = if partition_id, do: Map.put(actor, :partition_id, partition_id), else: actor

        conn
        |> assign(:ash_actor, actor)
        |> assign(:current_partition_id, partition_id)
        |> Ash.PlugHelpers.set_actor(actor)

      _ ->
        conn
    end
  end

  # Extract partition ID from X-Partition-Id header or session
  defp get_partition_id_from_request(conn) do
    case Plug.Conn.get_req_header(conn, "x-partition-id") do
      [partition_id | _] when byte_size(partition_id) > 0 ->
        cast_uuid(partition_id)

      _ ->
        conn
        |> Plug.Conn.get_session(:current_partition_id)
        |> cast_uuid()
    end
  end

  defp cast_uuid(nil), do: nil

  defp cast_uuid(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> uuid
      :error -> nil
    end
  end
end
