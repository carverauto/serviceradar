import Config

config :logger, level: :warning

# Lint-only CI sets SERVICERADAR_SKIP_NIF_COMPILATION so `mix compile` of the
# object storage path dependency does not shell out to cargo. Bazel skips the
# NIF through extra_config on //elixir/serviceradar_nvr:erlang_app_prod.
if System.get_env("SERVICERADAR_SKIP_NIF_COMPILATION") == "1" do
  config :serviceradar_object_storage, ServiceRadarObjectStorage, skip_compilation?: true
end
