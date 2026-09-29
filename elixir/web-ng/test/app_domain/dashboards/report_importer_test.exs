defmodule ServiceRadarWebNG.Dashboards.ReportImporterTest do
  # Refusals that happen before anything is written, so they need no database.
  # What an accepted import persists is covered by report_import_db_test.exs.
  use ExUnit.Case, async: false

  alias ServiceRadar.Dashboards.AuthoredDashboard
  alias ServiceRadarWebNG.Dashboards.Definition
  alias ServiceRadarWebNG.Dashboards.ReportImporter
  alias ServiceRadarWebNG.ReportSourceStub, as: Stub

  @moduletag :db_free

  @sha String.duplicate("a", 40)

  setup do
    previous =
      for key <- [:github_token, :plugin_verification],
          into: %{},
          do: {key, Application.get_env(:serviceradar_web_ng, key)}

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> Application.delete_env(:serviceradar_web_ng, key)
        {key, value} -> Application.put_env(:serviceradar_web_ng, key, value)
      end)
    end)

    :ok
  end

  defp install(routes), do: on_exit(Stub.install(routes))

  # The boundary applies whenever a GitHub token is configured, including one a CI
  # runner exports as GITHUB_TOKEN, so tests aimed at a later check trust the repo.
  defp trust_acme_reports do
    Application.put_env(:serviceradar_web_ng, :plugin_verification, trusted_github_repositories: ["acme/reports"])
  end

  describe "upload" do
    test "is refused with exactly the message the shared validator gives" do
      definition =
        "fleet-report"
        |> Stub.definition()
        |> Jason.decode!()
        |> Map.update!("panels", fn [panel] -> [panel, Map.put(panel, "title", "Overlapping")] end)

      {:error, expected} = Definition.validate(definition, "fleet-report.json")

      assert {:error, ^expected} =
               ReportImporter.import_upload(Jason.encode!(definition), "fleet-report.json", scope: nil)

      assert expected =~ "overlap"
    end

    test "refuses a body over the size limit before decoding it" do
      body = String.duplicate(" ", ReportImporter.max_definition_bytes() + 1)

      assert {:error, message} = ReportImporter.import_upload(body, "big.json", scope: nil)
      assert message =~ "larger than"
    end

    test "names the file when the body is not JSON" do
      assert {:error, message} = ReportImporter.import_upload("{nope", "broken.json", scope: nil)
      assert message =~ "broken.json"
      assert message =~ "invalid JSON"
    end
  end

  describe "github" do
    test "refuses a repository outside the trusted boundary without fetching anything" do
      install(%{})
      Application.put_env(:serviceradar_web_ng, :github_token, "synthetic-token")
      Application.put_env(:serviceradar_web_ng, :plugin_verification, trusted_github_repositories: ["acme/other"])

      assert {:error, message} =
               ReportImporter.import_github(
                 %{"repo_url" => "https://github.com/acme/reports", "path" => "fleet.json"},
                 scope: nil
               )

      assert message =~ "not in the trusted GitHub repositories"
      refute_received {:report_source_stub_request, _url}
    end

    test "refuses an unsigned commit when signed imports are required, before reading the definition" do
      install(%{Stub.commit_url("acme", "reports", "main") => Stub.commit_body(@sha, false)})

      Application.put_env(:serviceradar_web_ng, :plugin_verification,
        require_gpg_for_github: true,
        trusted_github_repositories: ["acme/reports"]
      )

      assert {:error, message} =
               ReportImporter.import_github(
                 %{"repo_url" => "https://github.com/acme/reports", "ref" => "main", "path" => "fleet.json"},
                 scope: nil
               )

      assert message =~ "not signed"
      assert_received {:report_source_stub_request, "https://api.github.com/" <> _}
      refute_received {:report_source_stub_request, "https://raw.githubusercontent.com/" <> _}
    end

    test "refuses a definition path that leaves the repository" do
      install(%{})
      trust_acme_reports()

      assert {:error, message} =
               ReportImporter.import_github(
                 %{"repo_url" => "https://github.com/acme/reports", "path" => "../outside.json"},
                 scope: nil
               )

      assert message =~ "relative path"
    end

    test "requires a repository URL" do
      assert {:error, "GitHub repository URL is required"} =
               ReportImporter.import_github(%{"path" => "fleet.json"}, scope: nil)
    end
  end

  describe "first party" do
    test "reports a release that publishes no report index" do
      install(%{Stub.commit_url("carverauto", "serviceradar", "v0.0.1") => Stub.commit_body(@sha, true)})

      assert {:error, message} = ReportImporter.import_first_party("fleet-report", scope: nil, release_tag: "v0.0.1")
      assert message =~ "Release v0.0.1 does not publish a report index"
    end

    test "refuses a slug the release index does not list" do
      index_url = Stub.raw_url("carverauto", "serviceradar", @sha, "elixir/web-ng/priv/dashboards/index.json")

      install(%{
        Stub.commit_url("carverauto", "serviceradar", "v0.0.1") => Stub.commit_body(@sha, true),
        index_url => Stub.index([{"other-report", "other-report.json", true}])
      })

      assert {:error, message} = ReportImporter.import_first_party("fleet-report", scope: nil, release_tag: "v0.0.1")
      assert message =~ ~s(does not list a report "fleet-report")
    end

    test "names a missing release tag" do
      install(%{})

      assert {:error, message} = ReportImporter.import_first_party("fleet-report", scope: nil, release_tag: "v0.0.2")
      assert message =~ "Release v0.0.2 was not found"
    end
  end

  describe "provenance on the resource" do
    test "is accepted by the import action" do
      changeset =
        Ash.Changeset.for_create(AuthoredDashboard, :import, %{
          dashboard_ref: 1_234_567,
          title: "Imported",
          source_type: :upload,
          content_hash: String.duplicate("0", 64)
        })

      assert changeset.valid?
    end

    test "cannot be written through an ordinary edit" do
      changeset = Ash.Changeset.for_update(%AuthoredDashboard{title: "Edited"}, :update, %{source_type: :github})

      refute changeset.valid?
      assert Enum.any?(changeset.errors, &match?(%Ash.Error.Invalid.NoSuchInput{input: :source_type}, &1))
    end
  end
end
