import Config

config :serviceradar_ui_example, ServiceRadarUIExample.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  http: [ip: {127, 0, 0, 1}, port: 4000],
  secret_key_base: "dev-only-example-secret-key-base-not-a-credential-0123456789abcdef",
  render_errors: [formats: [html: ServiceRadarUIExample.ErrorHTML], layout: false],
  pubsub_server: ServiceRadarUIExample.PubSub,
  live_view: [signing_salt: "example-lv-salt-not-a-secret"],
  check_origin: false,
  server: false

config :phoenix, :json_library, Jason
config :logger, level: :warning

import_config "#{config_env()}.exs"
