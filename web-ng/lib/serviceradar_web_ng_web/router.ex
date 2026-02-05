defmodule ServiceRadarWebNGWeb.Router do
  use ServiceRadarWebNGWeb, :router
  import AshAdmin.Router

  import Oban.Web.Router
  import Phoenix.LiveDashboard.Router
  import ServiceRadarWebNGWeb.UserAuth

  alias ServiceRadarWebNG.Accounts.Scope

  @csp "default-src 'self'; " <>
         "script-src 'self'; " <>
         "style-src 'self' 'unsafe-inline'; " <>
         "img-src 'self' data:; " <>
         "font-src 'self' data:; " <>
         "connect-src 'self' https: wss:; " <>
         "frame-src 'none'; " <>
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
    plug(:fetch_current_scope_for_user)
    plug(:set_ash_actor)
  end

  pipeline :api do
    plug(:accepts, ["json"])
  end

  pipeline :api_auth do
    plug(:accepts, ["json"])
    plug(:fetch_session)
    plug(:protect_from_forgery)
    plug(:fetch_current_scope_for_user)
    plug(:require_authenticated_user)
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

  # JSON:API pipeline for Ash resources (v2 API)
  pipeline :ash_json_api do
    plug(:accepts, ["json"])
    plug(:fetch_session)
    plug(:fetch_current_scope_for_user)
    plug(:set_ash_actor)
    plug(ServiceRadarWebNGWeb.Plugs.ApiErrorHandler)
  end

  scope "/", ServiceRadarWebNGWeb do
    pipe_through(:browser)

    get("/", PageController, :home)
  end

  # Other scopes may use custom stacks.
  scope "/api", ServiceRadarWebNG.Api do
    pipe_through(:api_auth)

    post("/query", QueryController, :execute)
    get("/devices", DeviceController, :index)
    get("/devices/ocsf/export", DeviceController, :ocsf_export)
    get("/devices/:uid", DeviceController, :show)
  end

  # Admin API (session/JWT auth)
  scope "/api/admin", ServiceRadarWebNG.Api do
    pipe_through(:api_auth)

    get("/users", UserController, :index)
    get("/users/:id", UserController, :show)
    post("/users", UserController, :create)
    patch("/users/:id", UserController, :update)
    post("/users/:id/deactivate", UserController, :deactivate)
    post("/users/:id/reactivate", UserController, :reactivate)

    get("/authorization-settings", AuthorizationSettingsController, :show)
    put("/authorization-settings", AuthorizationSettingsController, :update)
  end

  # Edge onboarding admin API (API key or bearer token auth)
  scope "/api/admin", ServiceRadarWebNG.Api do
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
  scope "/api/admin", ServiceRadarWebNG.Api do
    pipe_through(:api_token_auth)

    post("/edge-packages/:id/download", EdgeController, :download)
    post("/collectors/:id/download", CollectorController, :download)
  end

  # Edge package bundle download - public endpoint with token in query param
  # Allows one-liner curl commands for zero-touch provisioning
  scope "/api", ServiceRadarWebNG.Api do
    pipe_through(:api)

    get("/edge-packages/:id/bundle", EdgeController, :bundle)
    get("/collectors/:id/bundle", CollectorController, :bundle)
    put("/plugin-packages/:id/blob", PluginPackageController, :upload_blob)
    get("/plugin-packages/:id/blob", PluginPackageController, :download_blob)

    # Legacy collector enrollment endpoint (bundle download is preferred)
    # Token decodes to: GET /api/enroll/collector/:package_id?token=<secret>
    get("/enroll/collector/:package_id", CollectorEnrollController, :enroll)
    # Legacy collector enrollment path
    get("/enroll/:package_id", CollectorEnrollController, :enroll)
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
    get("/sign-out", AuthController, :delete)
    delete("/sign-out", AuthController, :delete)

    # Password reset
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
    pipe_through([:browser, :require_authenticated_user])

    # Redirect /dashboard to /analytics
    get("/dashboard", PageController, :redirect_to_analytics)
    get("/users/settings", PageController, :redirect_to_settings_profile)

    live_session :require_authenticated_user,
      on_mount: [
        {ServiceRadarWebNGWeb.UserAuth, :require_authenticated},
        Permit.Phoenix.LiveView.AuthorizeHook
      ] do
      live("/analytics", AnalyticsLive.Index, :index)
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
      live("/observability/metrics/:span_id", MetricLive.Show, :show)
      live("/logs", LogLive.Index, :index)
      live("/logs/:log_id", LogLive.Show, :show)
      live("/services", ServiceLive.Index, :index)
      live("/netflows", LogLive.Index, :index)
      live("/services/check", ServiceLive.Show, :show)
      live("/settings/profile", UserLive.Settings, :edit)
      live("/settings/api-credentials", UserLive.ApiCredentials, :index)
      live("/users/settings/confirm-email/:token", UserLive.Settings, :confirm_email)

      # Cluster visibility for all authenticated users
      live("/settings/cluster", Settings.ClusterLive.Index, :index)
      live("/settings/cluster/nodes/:node_name", NodeLive.Show, :show)
      live("/settings/rules", Settings.RulesLive.Index, :index)

      # Authentication settings (admin only - enforced by Permit policies)
      live("/settings/authentication", Settings.AuthenticationLive, :index)
      live("/settings/auth/users", Settings.AuthUsersLive, :index)
      live("/settings/auth/authorization", Settings.AuthorizationLive, :index)

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

      # Integration sources configuration
      live("/settings/networks/integrations", Settings.IntegrationsLive.Index, :index)
      live("/settings/networks/integrations/new", Settings.IntegrationsLive.Index, :new)
      live("/settings/networks/integrations/:id", Settings.IntegrationsLive.Index, :show)
      live("/settings/networks/integrations/:id/edit", Settings.IntegrationsLive.Index, :edit)

      # Sysmon profiles configuration
      live("/settings/sysmon", Settings.SysmonProfilesLive.Index, :index)
      live("/settings/sysmon/new", Settings.SysmonProfilesLive.Index, :new_profile)
      live("/settings/sysmon/:id/edit", Settings.SysmonProfilesLive.Index, :edit_profile)

      # SNMP profiles configuration
      live("/settings/snmp", Settings.SNMPProfilesLive.Index, :index)
      live("/settings/snmp/new", Settings.SNMPProfilesLive.Index, :new_profile)
      live("/settings/snmp/:id/edit", Settings.SNMPProfilesLive.Index, :edit_profile)

      # Agent deployment
      live("/settings/agents/deploy", Settings.AgentsLive.Deploy, :index)
      live("/settings/agents/plugins", Admin.PluginPackageLive.Index, :index)
      live("/settings/agents/plugins/new", Admin.PluginPackageLive.Index, :new)
      live("/settings/agents/plugins/:id", Admin.PluginPackageLive.Index, :show)

      # Zen Rule Editor - visual JDM editor for rule logic
      live("/settings/rules/zen/new", Settings.ZenRuleEditorLive, :new)
      live("/settings/rules/zen/:id", Settings.ZenRuleEditorLive, :edit)
      live("/settings/rules/zen/clone/:clone_id", Settings.ZenRuleEditorLive, :clone)

      get("/infrastructure", PageController, :redirect_to_settings_cluster)
      get("/infrastructure/nodes/:node_name", PageController, :redirect_to_settings_cluster_node)
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

  # Set the Ash actor from the current user for policy enforcement
  # Includes partition context from request header or session
  defp set_ash_actor(conn, _opts) do
    case conn.assigns[:current_scope] do
      %Scope{user: user} when not is_nil(user) ->
        partition_id = get_partition_id_from_request(conn)

        actor = %{
          id: user.id,
          role: user.role,
          email: user.email
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
