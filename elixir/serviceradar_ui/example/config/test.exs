import Config

config :serviceradar_ui_example, ServiceRadarUIExample.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  debug_errors: false,
  server: false

config :logger, level: :warning
