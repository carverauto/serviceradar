defmodule ServiceRadarWebNGWeb.Router do
  use ServiceRadarWebNGWeb, :router

  import AshAdmin.Router
  import Oban.Web.Router
  import Phoenix.LiveDashboard.Router
  import ServiceRadarWebNGWeb.UserAuth

  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNGWeb.Plugs.GatewayAuth

  @frame_src if Mix.env() == :dev, do: "'self'", else: "'none'"
  @csp "default-src 'self'; " <>
         "script-src 'self' blob: 'wasm-unsafe-eval'; " <>
         "style-src 'self' 'unsafe-inline'; " <>
         "img-src 'self' data: https://api.mapbox.com https://*.tiles.mapbox.com https://*.tile.openstreetmap.org https://*.basemaps.cartocdn.com; " <>
         "font-src 'self' data:; " <>
         "connect-src 'self' https: wss:; " <>
         "worker-src 'self' blob:; " <>
         "child-src blob:; " <>
         "frame-src #{@frame_src}; " <>
         "object-src 'none'; " <>
         "base-uri 'self'; " <>
         "form-action 'self'"

  @api_docs_csp "default-src 'self'; " <>
                  "script-src 'self' blob: 'wasm-unsafe-eval' https://cdnjs.cloudflare.com https://cdn.jsdelivr.net; " <>
                  "style-src 'self' 'unsafe-inline' https://cdnjs.cloudflare.com https://fonts.googleapis.com; " <>
                  "img-src 'self' data: https:; " <>
                  "font-src 'self' data: https://fonts.gstatic.com; " <>
                  "connect-src 'self' https: wss:; " <>
                  "worker-src 'self' blob:; " <>
                  "child-src blob:; " <>
                  "frame-src #{@frame_src}; " <>
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
    plug(GatewayAuth)
    plug(:fetch_current_scope_for_user)
    plug(:set_ash_actor)
    plug(:require_authenticated_user)
  end

  pipeline :api do
    plug(:accepts, ["json"])
  end

  pipeline :api_docs_ui do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {ServiceRadarWebNGWeb.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers, %{"content-security-policy" => @api_docs_csp})
    plug(GatewayAuth)
    plug(:fetch_current_scope_for_user)
    plug(:set_ash_actor)
  end

  pipeline :api_auth do
    plug(:accepts, ["json"])
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
    plug(ServiceRadarWebNGWeb.Plugs.ApiAuth)
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
  end

  scope "/", ServiceRadarWebNGWeb do
    get("/health", HealthController, :ready)
    get("/health/live", HealthController, :live)
    get("/health/ready", HealthController, :ready)
    get("/metrics", MetricsController, :index)
  end

  scope "/api/docs", ServiceRadarWebNGWeb.Api do
    pipe_through(:api)

    get("/v1/admin/openapi.json", OpenapiController, :published_admin_v1)
  end

  # JSON:API pipeline for Ash resources (v2 API)
  pipeline :ash_json_api do
    plug(:accepts, ["json"])
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
  end

  # Other scopes may use custom stacks.
  scope "/api", ServiceRadarWebNGWeb.Api do
    pipe_through(:api_auth)

    post("/query", QueryController, :execute)
    get("/devices", DeviceController, :index)
    get("/devices/ocsf/export", DeviceController, :ocsf_export)
    get("/devices/:uid", DeviceController, :show)
    post("/camera-relay-sessions", CameraRelaySessionController, :create)
    get("/camera-relay-sessions/:id", CameraRelaySessionController, :show)
    post("/camera-relay-sessions/:id/close", CameraRelaySessionController, :close)
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

    post("/topology/route-analysis", TopologyController, :route_analysis)
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

    # Plugin registry
    get("/plugins", PluginController, :index)
    post("/plugins", PluginController, :create)
    get("/plugins/:id", PluginController, :show)
    patch("/plugins/:id", PluginController, :update)

    # Plugin packages
    get("/plugin-packages", PluginPackageController, :index)
    post("/plugin-packages", PluginPackageController, :create)
    get("/plugin-packages/:id", PluginPackageController, :show)
    post("/plugin-packages/:id/upload-url", PluginPackageController, :upload_url)
    post("/plugin-packages/:id/download-url", PluginPackageController, :download_url)
    post("/plugin-packages/:id/approve", PluginPackageController, :approve)
    post("/plugin-packages/:id/deny", PluginPackageController, :deny)
    post("/plugin-packages/:id/revoke", PluginPackageController, :revoke)
    post("/plugin-packages/:id/restage", PluginPackageController, :restage)

    # Plugin assignments
    get("/plugin-assignments", PluginAssignmentController, :index)
    post("/plugin-assignments", PluginAssignmentController, :create)
    patch("/plugin-assignments/:id", PluginAssignmentController, :update)
    delete("/plugin-assignments/:id", PluginAssignmentController, :delete)

    # Collector package management
    get("/collectors", CollectorController, :index)
    post("/collectors", CollectorController, :create)
    get("/collectors/:id", CollectorController, :show)
    post("/collectors/:id/revoke", CollectorController, :revoke)

    # NATS account & credentials
    get("/nats/account", CollectorController, :account_status)
    get("/nats/credentials", CollectorController, :credentials)
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
  end

  scope "/api/v2" do
    pipe_through(:api_docs_ui)

    forward("/swaggerui", OpenApiSpex.Plug.SwaggerUI,
      path: "/api/v2/open_api",
      default_model_expand_depth: 4
    )

    forward("/redoc", Redoc.Plug.RedocUI, spec_url: "/api/v2/open_api")
  end

  # Ash JSON:API v2 endpoints
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
      on_mount: [{ServiceRadarWebNGWeb.UserAuth, :require_authenticated}] do
      live("/jobs", Admin.JobLive.Index, :index)
      live("/jobs/:id", Admin.JobLive.Show, :show)
      live("/edge-packages", Admin.EdgePackageLive.Index, :index)
      live("/edge-packages/new", Admin.EdgePackageLive.Index, :new)
      live("/edge-packages/:id", Admin.EdgePackageLive.Index, :show)
      live("/plugins", Admin.PluginPackageLive.Index, :index)
      live("/plugins/new", Admin.PluginPackageLive.Index, :new)
      live("/plugins/:id", Admin.PluginPackageLive.Index, :show)
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
  end

  ## Authentication routes
  # Password login, logout, and password reset

  scope "/auth", ServiceRadarWebNGWeb do
    pipe_through(:browser)

    # Password login
    post("/sign-in", AuthController, :create)

    # Sign out
    delete("/sign-out", AuthController, :delete)

    # Password reset
    get("/password-reset", AuthController, :new_reset_request)
    post("/password-reset", AuthController, :request_reset)
    get("/password-reset/:token", AuthController, :show_reset_form)
    put("/password-reset/:token", AuthController, :reset_password)

    # Registration (if enabled)
    post("/register", AuthController, :register)

    # OIDC SSO
    get("/oidc", OIDCController, :request)
    get("/oidc/callback", OIDCController, :callback)

    # Local admin backdoor (for use when proxy/SSO auth is primary)
    post("/local/sign-in", AuthController, :local_sign_in)

    # SAML SSO
    get("/saml", SAMLController, :request)
    post("/saml/consume", SAMLController, :consume)
    get("/saml/metadata", SAMLController, :metadata)
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
    get("/analytics", PageController, :redirect_to_dashboard)
    live_session :require_authenticated_user,
      on_mount: [
        {ServiceRadarWebNGWeb.UserAuth, :require_authenticated}
      ] do
      live("/dashboard", DashboardLive.Index, :index)
      live("/dashboards/:route_slug", DashboardPackageLive.Show, :show)
      live("/devices", DeviceLive.Index, :index)
      live("/devices/:uid", DeviceLive.Show, :show)
      live("/devices/:device_uid/interfaces/:interface_uid", InterfaceLive.Show, :show)
      live("/interfaces", InterfaceLive.Index, :index)

      # Connected agents view (instance-scoped, visible to all authenticated users)
      live("/agents", AgentLive.Index, :index)
      live("/agents/:uid", AgentLive.Show, :show)

      # Gateways
      live("/gateways", GatewayLive.Index, :index)
      live("/gateways/:gateway_id", GatewayLive.Show, :show)
      live("/events", EventLive.Index, :index)
      live("/events/:event_id", EventLive.Show, :show)
      live("/alerts", AlertLive.Index, :index)
      live("/alerts/:alert_id", AlertLive.Show, :show)
      live("/observability", LogLive.Index, :index)
      live("/observability/bmp", BmpLive.Index, :index)
      live("/observability/bgp", BGPLive.Index, :index)
      live("/observability/camera-relays", CameraRelayLive.Index, :index)
      live("/observability/camera-relays/workers", CameraAnalysisWorkerLive.Index, :index)
      live("/observability/camera-analysis-workers", CameraAnalysisWorkerLive.Index, :legacy)
      live("/cameras", CameraLive.Index, :index)
      live("/cameras/:camera_source_id", CameraLive.Show, :show)
      live("/observability/metrics/:span_id", MetricLive.Show, :show)
      live("/logs", LogLive.Index, :index)
      live("/logs/:log_id", LogLive.Show, :show)
      live("/services", ServiceLive.Index, :index)
      live("/services/check", ServiceLive.Show, :show)
      live("/topology", TopologyLive.GodView, :index)
      live("/spatial", SpatialLive.Index, :index)
      live("/netflow-map", MapLive.NetflowMap, :index)
      live("/spatial/field-surveys", SpatialLive.FieldSurveyReview, :index)
      live("/spatial/field-surveys/:session_id", SpatialLive.FieldSurveyReview, :show)

      # MTR Diagnostics
      live("/diagnostics/mtr", DiagnosticsLive.Mtr, :index)
      live("/diagnostics/mtr/compare", DiagnosticsLive.MtrCompare, :compare)
      live("/diagnostics/mtr/:trace_id", DiagnosticsLive.MtrTrace, :show)
      live("/settings/profile", UserLive.Settings, :edit)
      live("/settings/api-credentials", UserLive.ApiCredentials, :index)
      live("/users/settings/confirm-email/:token", UserLive.Settings, :confirm_email)

      # Cluster visibility for all authenticated users
      live("/settings/cluster", Settings.ClusterLive.Index, :index)
      live("/settings/cluster/nodes/:node_name", NodeLive.Show, :show)
      live("/settings/rules", Settings.RulesLive.Index, :index)

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

      # Integration sources configuration
      live("/settings/networks/integrations", Settings.IntegrationsLive.Index, :index)
      live("/settings/networks/integrations/new", Settings.IntegrationsLive.Index, :new)
      live("/settings/networks/integrations/:id", Settings.IntegrationsLive.Index, :show)
      live("/settings/networks/integrations/:id/edit", Settings.IntegrationsLive.Index, :edit)
      live("/settings/networks/threat-intel", Settings.ThreatIntelLive.Index, :index)

      # Sysmon profiles configuration
      live("/settings/sysmon", Settings.SysmonProfilesLive.Index, :index)
      live("/settings/sysmon/new", Settings.SysmonProfilesLive.Index, :new_profile)
      live("/settings/sysmon/:id/edit", Settings.SysmonProfilesLive.Index, :edit_profile)

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
        Permit.Phoenix.LiveView.AuthorizeHook
      ] do
      # Authentication settings (admin only - enforced by Permit policies)
      live("/settings/authentication", Settings.AuthenticationLive, :index)
      live("/settings/auth/users", Settings.AuthUsersLive, :index)
      live("/settings/auth/users/:id", Settings.AuthUserLive.Show, :show)
      live("/settings/auth/rbac", Settings.RbacLive, :index)
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
