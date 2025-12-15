defmodule ServiceRadarWebNGWeb.Router do
  use ServiceRadarWebNGWeb, :router

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

  scope "/", ServiceRadarWebNGWeb do
    pipe_through :browser

    get "/", PageController, :home
  end

  # Other scopes may use custom stacks.
  scope "/api", ServiceRadarWebNG.Api do
    pipe_through :api_auth

    post "/query", QueryController, :execute
    get "/devices", DeviceController, :index
    get "/devices/:device_id", DeviceController, :show
  end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:serviceradar_web_ng, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: ServiceRadarWebNGWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
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
      live "/devices/:device_id", DeviceLive.Show, :show
      live "/pollers", PollerLive.Index, :index
      live "/events", EventLive.Index, :index
      live "/logs", LogLive.Index, :index
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
end
