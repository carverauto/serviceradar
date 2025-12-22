defmodule ServiceRadarWebNGWeb.Router do
  use ServiceRadarWebNGWeb, :router

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

  pipeline :dev_routes do
    plug :ensure_dev_routes_enabled
  end

  pipeline :admin_basic_auth do
    plug ServiceRadarWebNGWeb.Plugs.BasicAuth
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

  scope "/dev" do
    pipe_through [:browser, :dev_routes]

    live_dashboard "/dashboard", metrics: ServiceRadarWebNGWeb.Telemetry
    forward "/mailbox", Plug.Swoosh.MailboxPreview
  end

  scope "/admin", ServiceRadarWebNGWeb do
    pipe_through [:browser, :require_authenticated_user, :admin_basic_auth]

    live_session :admin_jobs,
      on_mount: [{ServiceRadarWebNGWeb.UserAuth, :require_authenticated}] do
      live "/jobs", Admin.JobLive.Index, :index
    end

    oban_dashboard("/jobs/oban",
      oban_name: Oban,
      as: :admin_oban_dashboard,
      resolver: ServiceRadarWebNGWeb.ObanResolver
    )
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
      live "/pollers", PollerLive.Index, :index
      live "/pollers/:poller_id", PollerLive.Show, :show
      live "/agents", AgentLive.Index, :index
      live "/agents/:uid", AgentLive.Show, :show
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
    end

    post "/users/update-password", UserSessionController, :update_password
  end

  scope "/", ServiceRadarWebNGWeb do
    pipe_through [:browser]

    live_session :current_user,
      on_mount: [{ServiceRadarWebNGWeb.UserAuth, :mount_current_scope}] do
      live "/users/register", UserLive.Registration, :new
      live "/users/log-in", UserLive.Login, :new
      live "/users/log-in/:token", UserLive.Confirmation, :new
    end

    post "/users/log-in", UserSessionController, :create
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
end
