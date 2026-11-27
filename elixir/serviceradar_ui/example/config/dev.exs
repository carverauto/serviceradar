import Config

config :serviceradar_ui_example, ServiceRadarUIExample.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4000],
  debug_errors: true,
  code_reloader: false,
  check_origin: false,
  server: true

config :logger, level: :info
