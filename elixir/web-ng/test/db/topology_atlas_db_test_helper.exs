# The guarded lifecycle supplies the migrated serial_0 clone and verified TLS
# configuration. Start only the Repo: the general helper performs schema DDL.
Code.require_file("../../../serviceradar_core/config/test_database_guard.exs", __DIR__)

repo_options = Application.fetch_env!(:serviceradar_core, ServiceRadar.Repo)
ssl_options = Keyword.fetch!(repo_options, :ssl)
true = Keyword.fetch!(ssl_options, :verify) == :verify_peer

ServiceRadar.DB.TestDatabaseGuard.validate!(Keyword.fetch!(repo_options, :url),
  tls_server_name: Keyword.fetch!(ssl_options, :server_name_indication),
  ssl_mode: "verify-full",
  ca_configured?: Keyword.has_key?(ssl_options, :cacerts) or Keyword.has_key?(ssl_options, :cacertfile)
)

for app <- [:postgrex, :ecto_sql, :ash_postgres] do
  {:ok, _} = Application.ensure_all_started(app)
end

{:ok, repo} = ServiceRadar.Repo.start_link()
Process.unlink(repo)
:ok = Ecto.Adapters.SQL.Sandbox.mode(ServiceRadar.Repo, :manual)

ExUnit.start(exclude: [:test], include: [:topology_atlas_db], max_cases: 1)

ExUnit.after_suite(fn %{total: total, excluded: excluded, skipped: skipped} ->
  ServiceRadar.Repo.stop()
  selected = total - excluded - skipped

  if selected != 6 do
    IO.puts(:stderr, "FAILED: the topology atlas target executed #{selected} tests; expected exactly 6")
    System.at_exit(fn _ -> System.halt(1) end)
  end
end)
