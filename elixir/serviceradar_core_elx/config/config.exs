import Config

config :serviceradar_core_elx,
  namespace: ServiceRadarCoreElx

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id, :node]

import_config "#{config_env()}.exs"
