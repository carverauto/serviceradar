import Config

# Lint-only CI sets SERVICERADAR_SKIP_NIF_COMPILATION so `mix compile` of this
# project does not shell out to cargo. Bazel already skips the NIF via
# extra_config on //elixir/serviceradar_object_storage:erlang_app. See
# elixir/web-ng/config/config.exs for the full rationale.
if System.get_env("SERVICERADAR_SKIP_NIF_COMPILATION") == "1" do
  config :serviceradar_object_storage, ServiceRadarObjectStorage, skip_compilation?: true
end
