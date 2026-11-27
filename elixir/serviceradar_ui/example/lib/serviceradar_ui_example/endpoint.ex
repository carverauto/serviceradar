defmodule ServiceRadarUIExample.Endpoint do
  @moduledoc false

  use Phoenix.Endpoint, otp_app: :serviceradar_ui_example

  @session_options [
    store: :cookie,
    key: "_serviceradar_ui_example_key",
    signing_salt: "example-session-salt",
    same_site: "Lax"
  ]

  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]],
    longpoll: [connect_info: [session: @session_options]]

  plug Plug.Static,
    at: "/",
    from: :serviceradar_ui_example,
    gzip: false,
    only: ~w(app.js)

  plug Plug.Static,
    at: "/serviceradar_ui",
    from: {:serviceradar_ui, "priv/static"},
    gzip: false,
    only: ~w(serviceradar_ui.js serviceradar_ui.js.map theme_init.js world-110m.json)

  plug Plug.Static,
    at: "/serviceradar_ui/css",
    from: {:serviceradar_ui, "priv/css"},
    gzip: false,
    only: ~w(tokens.css components.css)

  plug Plug.Static,
    at: "/vendor",
    from: {:phoenix, "priv/static"},
    gzip: false,
    only: ~w(phoenix.mjs)

  plug Plug.Static,
    at: "/vendor",
    from: {:phoenix_live_view, "priv/static"},
    gzip: false,
    only: ~w(phoenix_live_view.esm.js)

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options
  plug ServiceRadarUIExample.Router
end
