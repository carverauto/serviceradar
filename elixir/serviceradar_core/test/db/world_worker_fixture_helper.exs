# This runner uses the migrated serial_0 scratch clone after the ordinary lanes.
# It starts only Repo and Oban; schema changes belong to the migration targets.
alias ServiceradarConfig.Manager
alias ServiceradarConfig.Manager.Identity

Code.require_file("../../config/test_database_guard.exs", __DIR__)

# An interrupted ExUnit run must fail, not pass: SIGTERM otherwise shuts the
# BEAM down gracefully with exit 0 (see test/test_helper.exs).
case System.trap_signal(:sigterm, fn ->
  IO.puts(:stderr, "SIGTERM received before ExUnit completed; failing the run")
  System.halt(1)
end) do
  {:ok, _id} -> :ok
  {:error, :not_sup} -> :ok
end

{:ok, %{kind: "ci"} = identity} = Identity.from_env()
config_path = Path.join(System.fetch_env!("TEST_TMPDIR"), "config/environments/ci.binpb")

{:ok, manager} =
  Manager.load(identity, %{"ci" => File.read!(config_path)}, fn _ -> {:error, :no_mount} end)

dgraph = Manager.dgraph(manager)
target = "DGRAPH_URL" |> System.fetch_env!() |> URI.parse()
query = URI.decode_query(target.query || "")

if !(target.scheme == "dgraph" and target.host == dgraph.host and target.port == dgraph.port and
       query["sslmode"] == "verify-ca" and
       Enum.sort(Map.keys(query)) == ["namespace", "sslmode", "sslrootcert"] and
       match?({namespace, ""} when namespace > 0, Integer.parse(query["namespace"] || "")) and
       File.regular?(query["sslrootcert"] || "")) do
  raise "world worker fixture requires the owned nonzero namespace on typed CI Dgraph with verified TLS"
end

repo_options = Application.fetch_env!(:serviceradar_core, ServiceRadar.Repo)
ssl_options = Keyword.fetch!(repo_options, :ssl)
true = Keyword.fetch!(ssl_options, :verify) == :verify_peer

ServiceRadar.DB.TestDatabaseGuard.validate!(Keyword.fetch!(repo_options, :url),
  tls_server_name: Keyword.fetch!(ssl_options, :server_name_indication),
  ssl_mode: "verify-full",
  ca_configured?:
    Keyword.has_key?(ssl_options, :cacerts) or Keyword.has_key?(ssl_options, :cacertfile)
)

for app <- [:postgrex, :ecto_sql, :ash_postgres, :oban] do
  {:ok, _} = Application.ensure_all_started(app)
end

# The dedicated scale case may hold an auto-mode sandbox connection for its
# full test deadline, covering sequential publication and reload plus setup.
# Production stages retain their own shorter timeouts.
{:ok, repo} = ServiceRadar.Repo.start_link(ownership_timeout: 1_200_000)
Process.unlink(repo)
:ok = Ecto.Adapters.SQL.Sandbox.mode(ServiceRadar.Repo, :auto)
{:ok, oban} = Oban.start_link(Application.fetch_env!(:serviceradar_core, Oban))
Process.unlink(oban)

ExUnit.start(exclude: [:test], include: [:world_worker_fixture], max_cases: 1, timeout: 1_200_000)

ExUnit.after_suite(fn %{total: total, excluded: excluded, skipped: skipped} ->
  Supervisor.stop(oban)
  ServiceRadar.Repo.stop()
  selected = total - excluded - skipped

  if selected != 1 do
    IO.puts(
      :stderr,
      "FAILED: world worker fixture executed #{selected} tests; expected exactly 1"
    )

    System.at_exit(fn _ -> System.halt(1) end)
  end
end)
