defmodule ServiceRadarUIExample.Router do
  @moduledoc false

  use Phoenix.Router

  import Phoenix.LiveView.Router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {ServiceRadarUIExample.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug ServiceRadarUIExample.CSP
  end

  scope "/", ServiceRadarUIExample do
    pipe_through :browser

    live_session :gallery, layout: false do
      live "/", GalleryLive
    end
  end
end
