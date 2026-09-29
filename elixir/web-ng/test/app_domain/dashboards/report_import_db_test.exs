defmodule ServiceRadarWebNG.Dashboards.ReportImportDbTest do
  use ServiceRadarWebNG.DataCase, async: false

  import Ecto.Query
  import ServiceRadarWebNG.AshTestHelpers, only: [admin_user_fixture: 0]

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Dashboards.AuthoredDashboard
  alias ServiceRadar.Repo
  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.Dashboards.ReportImporter
  alias ServiceRadarWebNG.ReportSourceStub, as: Stub

  require Ash.Query

  @moduletag :web_ng_shared_fixture_db

  @sha String.duplicate("c", 40)
  @release "v0.0.1"
  @dir "elixir/web-ng/priv/dashboards"

  setup do
    # The boundary applies whenever a GitHub token is configured, including one a
    # CI runner exports as GITHUB_TOKEN, so the repository these tests use is trusted.
    previous_policy = Application.get_env(:serviceradar_web_ng, :plugin_verification)
    Application.put_env(:serviceradar_web_ng, :plugin_verification, trusted_github_repositories: ["acme/reports"])

    on_exit(fn ->
      if previous_policy,
        do: Application.put_env(:serviceradar_web_ng, :plugin_verification, previous_policy),
        else: Application.delete_env(:serviceradar_web_ng, :plugin_verification)
    end)

    marker = "rpt#{System.unique_integer([:positive])}"
    user = admin_user_fixture()
    %{marker: marker, user: user, scope: Scope.for_user(user)}
  end

  defp install(routes), do: on_exit(Stub.install(routes))

  defp first_party_routes(reports) do
    files =
      Map.new(reports, fn {slug, body, _enabled} ->
        {Stub.raw_url("carverauto", "serviceradar", @sha, "#{@dir}/#{slug}.json"), body}
      end)

    Map.merge(files, %{
      Stub.commit_url("carverauto", "serviceradar", @release) => Stub.commit_body(@sha, true),
      Stub.raw_url("carverauto", "serviceradar", @sha, "#{@dir}/index.json") =>
        Stub.index(Enum.map(reports, fn {slug, _body, enabled} -> {slug, "#{slug}.json", enabled} end))
    })
  end

  defp load(slug) do
    AuthoredDashboard
    |> Ash.Query.for_read(:by_slug, %{slug: slug})
    |> Ash.Query.load([:panels])
    |> Ash.read_one!(actor: SystemActor.system(:report_import_db_test))
  end

  defp sha256(body), do: :sha256 |> :crypto.hash(body) |> Base.encode16(case: :lower)

  test "a first-party import records the release, commit, path, hash and signature it came from", %{
    marker: marker,
    scope: scope,
    user: user
  } do
    slug = "#{marker}-fleet"
    body = Stub.definition(slug)
    install(first_party_routes([{slug, body, false}]))

    assert {:ok, %{outcome: :created}} = ReportImporter.import_first_party(slug, scope: scope, release_tag: @release)

    dashboard = load(slug)
    assert dashboard.source_type == :first_party
    assert dashboard.source_repo_url == "https://github.com/carverauto/serviceradar"
    assert dashboard.source_release_tag == @release
    assert dashboard.source_commit == @sha
    assert dashboard.source_path == "#{@dir}/#{slug}.json"
    assert dashboard.content_hash == sha256(body)
    assert dashboard.signature["verified"] == true
    assert dashboard.owner_id == user.id
    assert [%{srql_query: "in:devices limit:10"}] = dashboard.panels
  end

  test "listing a release marks which of its reports are already installed", %{marker: marker, scope: scope} do
    installed = "#{marker}-installed"
    available = "#{marker}-available"

    install(
      first_party_routes([
        {installed, Stub.definition(installed), true},
        {available, Stub.definition(available), false}
      ])
    )

    assert {:ok, _} = ReportImporter.import_first_party(installed, scope: scope, release_tag: @release)
    assert {:ok, catalog} = ReportImporter.list_first_party(release_tag: @release)

    assert catalog.release_tag == @release
    assert catalog.commit == @sha

    assert %{installed?: true, enabled_by_default: true, title: "Report " <> _, panel_count: 1, error: nil} =
             Enum.find(catalog.reports, &(&1.slug == installed))

    assert %{installed?: false, enabled_by_default: false} = Enum.find(catalog.reports, &(&1.slug == available))
  end

  test "re-importing a customised report keeps the operator's edit and its original provenance", %{
    marker: marker,
    scope: scope
  } do
    slug = "#{marker}-custom"

    assert {:ok, %{outcome: :created}} =
             ReportImporter.import_upload(Stub.definition(slug), "#{slug}.json", scope: scope)

    [panel] = load(slug).panels
    edited = "in:devices hostname:#{marker} limit:5"

    Repo.update_all(
      from(p in "authored_dashboard_panels", prefix: "platform", where: p.id == type(^panel.id, Ecto.UUID)),
      set: [srql_query: edited]
    )

    newer = Stub.definition(slug, "in:devices limit:50")

    install(%{
      Stub.commit_url("acme", "reports", "main") => Stub.commit_body(@sha, true),
      Stub.raw_url("acme", "reports", @sha, "#{slug}.json") => newer
    })

    assert {:ok, %{outcome: :kept}} =
             ReportImporter.import_github(
               %{"repo_url" => "https://github.com/acme/reports", "ref" => "main", "path" => "#{slug}.json"},
               scope: scope
             )

    dashboard = load(slug)
    assert [%{srql_query: ^edited}] = dashboard.panels
    assert dashboard.source_type == :upload
    assert dashboard.content_hash == sha256(Stub.definition(slug))
  end

  test "a GitHub import records the requested ref, resolved commit, path and signature", %{
    marker: marker,
    scope: scope
  } do
    slug = "#{marker}-github"
    body = Stub.definition(slug)

    install(%{
      Stub.commit_url("acme", "reports", "release-2") => Stub.commit_body(@sha, true),
      Stub.raw_url("acme", "reports", @sha, "reports/#{slug}.json") => body
    })

    assert {:ok, %{outcome: :created}} =
             ReportImporter.import_github(
               %{
                 "repo_url" => "https://github.com/acme/reports",
                 "ref" => "release-2",
                 "path" => "reports/#{slug}.json"
               },
               scope: scope
             )

    dashboard = load(slug)
    assert dashboard.source_type == :github
    assert dashboard.source_repo_url == "https://github.com/acme/reports"
    assert dashboard.source_ref == "release-2"
    assert dashboard.source_commit == @sha
    assert dashboard.source_path == "reports/#{slug}.json"
    assert dashboard.content_hash == sha256(body)
    assert %{"verified" => true, "signer" => "release-bot", "commit" => @sha} = dashboard.signature
    assert dashboard.source_release_tag == nil
  end

  test "an upload records its content hash and no signature", %{marker: marker, scope: scope} do
    slug = "#{marker}-upload"
    body = Stub.definition(slug)

    assert {:ok, %{outcome: :created, dashboard: created}} =
             ReportImporter.import_upload(body, "#{slug}.json", scope: scope)

    dashboard = load(slug)
    assert dashboard.id == created.id
    assert dashboard.source_type == :upload
    assert dashboard.content_hash == sha256(body)
    assert dashboard.signature == %{}
    assert dashboard.source_commit == nil
    assert dashboard.source_repo_url == nil
  end
end
