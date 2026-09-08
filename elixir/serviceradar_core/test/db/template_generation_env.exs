# Only the keyed lifecycle loads this preloader, before config/test.exs.
# The legacy singleton keeps its own preloader until rollout is qualified.
Code.require_file(Path.expand("template_generation.exs", __DIR__))
Code.require_file(Path.expand("../../config/test_database_guard.exs", __DIR__))

manifest =
  __DIR__
  |> Path.join("../../../../build/schema_template/manifest.json")
  |> File.read!()
  |> JSON.decode!()
  |> ServiceRadar.DB.TemplateGeneration.validate_manifest!()

database = Map.fetch!(manifest, "database")
fixture = ServiceRadar.DB.FixtureConfig.resolve!(database)
ServiceRadar.DB.TestDatabaseGuard.authorize_template_lifecycle!(database)
System.put_env("SERVICERADAR_TEST_DATABASE_URL", fixture.url)

if fixture.ca_pem do
  System.put_env("SERVICERADAR_TEST_DATABASE_CA_CERT", fixture.ca_pem)
end

if fixture.tls_server_name do
  System.put_env("SERVICERADAR_TEST_DATABASE_SERVER_NAME", fixture.tls_server_name)
end
