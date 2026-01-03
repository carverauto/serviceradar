defmodule ServiceRadarWebNGWeb.Router do
  use ServiceRadarWebNGWeb, :router
  use AshAuthentication.Phoenix.Router
  import AshAdmin.Router

  import Oban.Web.Router
  import Phoenix.LiveDashboard.Router
  import ServiceRadarWebNGWeb.UserAuth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {ServiceRadarWebNGWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_scope_for_user
    plug :set_ash_actor
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :api_auth do
    plug :accepts, ["json"]
    plug :fetch_session
    plug :protect_from_forgery
    plug :fetch_current_scope_for_user
    plug :require_authenticated_user
  end

  # API authentication for CLI/external tools (API key or bearer token)
  pipeline :api_key_auth do
    plug :accepts, ["json"]
    plug ServiceRadarWebNGWeb.Plugs.ApiAuth
  end

  pipeline :dev_routes do
    plug :ensure_dev_routes_enabled
  end

  pipeline :admin_basic_auth do
    plug ServiceRadarWebNGWeb.Plugs.BasicAuth
  end

  # API pipeline for token-gated endpoints (no session auth required)
  pipeline :api_token_auth do
    plug :accepts, ["json"]
  end

  # JSON:API pipeline for Ash resources (v2 API)
  pipeline :ash_json_api do
    plug :accepts, ["json"]
    plug :fetch_session
    plug :fetch_current_scope_for_user
    plug :set_ash_actor
    plug ServiceRadarWebNGWeb.Plugs.ApiErrorHandler
  end

  scope "/", ServiceRadarWebNGWeb do
    pipe_through :browser

    get "/", PageController, :home
  end

  # Other scopes may use custom stacks.
  scope "/api", ServiceRadarWebNG.Api do
    pipe_through :api_auth

    post "/query", QueryController, :execute
    get "/devices", DeviceController, :index
    get "/devices/ocsf/export", DeviceController, :ocsf_export
    get "/devices/:uid", DeviceController, :show
  end

  # Edge onboarding admin API (API key or bearer token auth)
  scope "/api/admin", ServiceRadarWebNG.Api do
    pipe_through :api_key_auth

    # Package defaults and templates
    get "/edge-packages/defaults", EdgeController, :defaults
    get "/component-templates", EdgeController, :templates

    # Package CRUD
    get "/edge-packages", EdgeController, :index
    post "/edge-packages", EdgeController, :create
    get "/edge-packages/:id", EdgeController, :show
    delete "/edge-packages/:id", EdgeController, :delete

    # Package events
    get "/edge-packages/:id/events", EdgeController, :events

    # Package actions
    post "/edge-packages/:id/revoke", EdgeController, :revoke

    # NATS platform administration (super admin)
    post "/nats/bootstrap-token", NatsController, :generate_bootstrap_token
    post "/nats/bootstrap", NatsController, :bootstrap
    get "/nats/status", NatsController, :status
    get "/nats/tenants", NatsController, :tenants
    post "/nats/tenants/:id/reprovision", NatsController, :reprovision

    # Collector package management (tenant admin)
    get "/collectors", CollectorController, :index
    post "/collectors", CollectorController, :create
    get "/collectors/:id", CollectorController, :show
    post "/collectors/:id/revoke", CollectorController, :revoke

    # Tenant NATS account & credentials
    get "/nats/account", CollectorController, :account_status
    get "/nats/credentials", CollectorController, :credentials
  end

  # Edge package download - token-gated (no session auth required)
  # This allows CLI tools to download packages using only the download token
  scope "/api/admin", ServiceRadarWebNG.Api do
    pipe_through :api_token_auth

    post "/edge-packages/:id/download", EdgeController, :download
    post "/collectors/:id/download", CollectorController, :download
  end

  # Edge package bundle download - public endpoint with token in query param
  # Allows one-liner curl commands for zero-touch provisioning
  scope "/api", ServiceRadarWebNG.Api do
    pipe_through :api

    get "/edge-packages/:id/bundle", EdgeController, :bundle
    get "/collectors/:id/bundle", CollectorController, :bundle

    # Collector enrollment endpoint for serviceradar-cli
    # Usage: serviceradar-cli enroll --token <token>
    # Token decodes to: GET /api/enroll/:package_id?token=<secret>
    get "/enroll/:package_id", EnrollController, :enroll
  end

  # Ash JSON:API v2 endpoints
  scope "/api/v2" do
    pipe_through :ash_json_api

    forward "/", ServiceRadarWebNGWeb.AshJsonApiRouter
  end

  scope "/dev" do
    pipe_through [:browser, :dev_routes]

    live_dashboard "/dashboard",
      metrics: ServiceRadarWebNGWeb.Telemetry,
      additional_pages: [
        broadway: {BroadwayDashboard, pipelines: [ServiceRadar.EventWriter.Pipeline]}
      ]

    forward "/mailbox", Plug.Swoosh.MailboxPreview

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
    pipe_through [:browser, :require_authenticated_user]

    live_session :admin,
      on_mount: [{ServiceRadarWebNGWeb.UserAuth, :require_authenticated}] do
      live "/jobs", Admin.JobLive.Index, :index
      live "/jobs/:id", Admin.JobLive.Show, :show
      live "/edge-packages", Admin.EdgePackageLive.Index, :index
      live "/edge-packages/new", Admin.EdgePackageLive.Index, :new
      live "/edge-packages/:id", Admin.EdgePackageLive.Index, :show
      live "/integrations", Admin.IntegrationLive.Index, :index
      live "/integrations/new", Admin.IntegrationLive.Index, :new
      live "/integrations/:id", Admin.IntegrationLive.Index, :show
      live "/integrations/:id/edit", Admin.IntegrationLive.Index, :edit
      live "/cluster", Admin.ClusterLive.Index, :index
      live "/nats", Admin.NatsLive.Index, :index
      live "/nats/tenants/:id", Admin.NatsLive.Show, :show
      live "/collectors", Admin.CollectorLive.Index, :index
      live "/collectors/:id", Admin.CollectorLive.Index, :show
      live "/edge-sites", Admin.EdgeSitesLive.Index, :index
      live "/edge-sites/new", Admin.EdgeSitesLive.Index, :new
      live "/edge-sites/:id", Admin.EdgeSitesLive.Show, :show
    end

    oban_dashboard("/oban",
      oban_name: Oban,
      as: :admin_oban_dashboard,
      resolver: ServiceRadarWebNGWeb.ObanResolver
    )
  end

  ## AshAuthentication routes
  # These routes handle password, magic link, and OAuth callbacks

  scope "/", ServiceRadarWebNGWeb do
    pipe_through :browser

    sign_out_route(AuthController, "/auth/sign-out")

    # Interactive magic link sign-in (require_interaction? is set in the strategy)
    magic_sign_in_route(ServiceRadar.Identity.User, :magic_link,
      auth_routes_prefix: "/auth",
      overrides: [ServiceRadarWebNGWeb.AuthOverrides, AshAuthentication.Phoenix.Overrides.Default],
      live_view: ServiceRadarWebNGWeb.AuthLive.MagicLinkSignIn,
      on_mount: [{ServiceRadarWebNGWeb.UserAuth, :mount_current_scope}],
      path: "/auth/user/magic_link",
      token_as_route_param?: false
    )

    reset_route(path: "/auth/password-reset", auth_routes_prefix: "/auth")

    auth_routes(AuthController, ServiceRadar.Identity.User, path: "/auth")
  end

  ## Authentication routes

  scope "/", ServiceRadarWebNGWeb do
    pipe_through [:browser, :require_authenticated_user]

    # Redirect /dashboard to /analytics
    get "/dashboard", PageController, :redirect_to_analytics

    live_session :require_authenticated_user,
      on_mount: [{ServiceRadarWebNGWeb.UserAuth, :require_authenticated}] do
      live "/analytics", AnalyticsLive.Index, :index
      live "/devices", DeviceLive.Index, :index
      live "/devices/:uid", DeviceLive.Show, :show

      # Connected agents view (tenant-scoped, visible to all authenticated users)
      live "/agents", AgentLive.Index, :index
      live "/agents/:uid", AgentLive.Show, :show

      # Legacy routes
      live "/pollers", PollerLive.Index, :index
      live "/pollers/:poller_id", PollerLive.Show, :show
      live "/events", EventLive.Index, :index
      live "/events/:event_id", EventLive.Show, :show
      live "/observability", LogLive.Index, :index
      live "/observability/metrics/:span_id", MetricLive.Show, :show
      live "/logs", LogLive.Index, :index
      live "/logs/:log_id", LogLive.Show, :show
      live "/services", ServiceLive.Index, :index
      live "/interfaces", InterfaceLive.Index, :index
      live "/users/settings", UserLive.Settings, :edit
      live "/users/settings/confirm-email/:token", UserLive.Settings, :confirm_email

      # Cluster visibility for all authenticated users
      live "/settings/cluster", Settings.ClusterLive.Index, :index

      # Infrastructure view - all authenticated users can see Connected Agents tab
      # Platform admins (super_admin role) can see all tabs (nodes, gateways)
      live "/infrastructure", InfrastructureLive.Index, :index
      live "/infrastructure/nodes/:node_name", NodeLive.Show, :show
    end

    post "/users/update-password", UserSessionController, :update_password
    post "/tenants/switch/:tenant_id", TenantController, :switch
  end

  scope "/", ServiceRadarWebNGWeb do
    pipe_through [:browser]

    # AshAuthentication.Phoenix sign-in LiveView
    ash_authentication_live_session :authentication,
      on_mount: [{ServiceRadarWebNGWeb.UserAuth, :mount_current_scope}] do
      live "/users/log-in", AuthLive.SignIn, :sign_in
    end

    # Custom registration with organization creation
    live_session :registration,
      on_mount: [{ServiceRadarWebNGWeb.UserAuth, :mount_current_scope}] do
      live "/users/register", AuthLive.Register
    end

    # Legacy session routes (kept for logout and magic link token handling)
    delete "/users/log-out", UserSessionController, :delete
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

  # Set the Ash actor and tenant from the current user for policy enforcement
  # Includes partition context from request header or session
  defp set_ash_actor(conn, _opts) do
    case conn.assigns[:current_scope] do
      %{user: user} when not is_nil(user) ->
        partition_id = get_partition_id_from_request(conn)

        actor = %{
          id: user.id,
          tenant_id: user.tenant_id,
          role: user.role,
          email: user.email
        }

        actor = if partition_id, do: Map.put(actor, :partition_id, partition_id), else: actor

        conn
        |> assign(:ash_actor, actor)
        |> assign(:current_partition_id, partition_id)
        |> Ash.PlugHelpers.set_actor(actor)
        |> Ash.PlugHelpers.set_tenant(user.tenant_id)

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
