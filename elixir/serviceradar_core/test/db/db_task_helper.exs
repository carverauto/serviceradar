# ExUnit helper for the database lifecycle targets (:setup_db, :teardown_db).
#
# Deliberately NOT test/test_helper.exs: that one starts the whole application via
# ServiceRadar.TestSupport.start_core!, and these tasks must run with the application
# down -- migrations have to be applied *before* anything boots against the schema, which
# is why the old flow ran `mix ash.migrate` and then `mix test --no-start`.
#
# The shared //build:elixir_test_config_loader.exs has already loaded config/config.exs and
# every application's .app env. ServiceRadar.Repo's connection settings are not there: they
# are built in config/runtime.exs, which reads the database URL out of the environment, so
# that file has to be evaluated too.
ExUnit.start()

runtime_config = "config/runtime.exs"

if File.exists?(runtime_config) do
  runtime_config
  |> Config.Reader.read!(env: :test, target: :host)
  |> Application.put_all_env()
end

# config/test.exs configures ServiceRadar.Repo with `pool: Ecto.Adapters.SQL.Sandbox`,
# which is right for the suite and wrong here. The sandbox hands one checked-out connection
# to an owning process and reclaims it after :ownership_timeout (120s by default), so a
# migration run longer than that is killed mid-way:
#
#   ** (DBConnection.ConnectionError) owner ... timed out because it owned the connection
#      for longer than 120000ms (set via the :ownership_timeout option)
#
# and the retry then trips over the half-applied schema ("relation edge_sites already
# exists"). Dropping :pool restores the normal pool, which has no owner and no reclaim.
repo_opts =
  :serviceradar_core
  |> Application.get_env(ServiceRadar.Repo, [])
  |> Keyword.drop([:pool, :ownership_timeout, :pool_size])
  |> Keyword.put(:timeout, :infinity)
  |> Keyword.put(:pool_size, 2)

Application.put_env(:serviceradar_core, ServiceRadar.Repo, repo_opts)
