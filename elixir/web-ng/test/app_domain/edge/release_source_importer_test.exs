defmodule ServiceRadarWebNG.Edge.ReleaseSourceImporterTest do
  use ExUnit.Case, async: false

  alias ServiceRadarWebNG.Edge.ReleaseSourceImporter

  @moduletag :unit
  @moduletag :db_free

  @manifest %{
    "version" => "1.2.3",
    "artifacts" => [
      %{
        "os" => "linux",
        "arch" => "amd64",
        "format" => "tar.gz",
        "entrypoint" => "serviceradar-agent",
        "url" =>
          "https://github.com/carverauto/serviceradar/releases/download/v1.2.3/serviceradar-agent-linux-amd64.tar.gz",
        "sha256" => String.duplicate("a", 64)
      }
    ]
  }

  @signature "signed-manifest"

  def manifest_json, do: Jason.encode!(@manifest)
  def signature, do: @signature

  defmodule GitHubClient do
    @moduledoc false

    alias ServiceRadarWebNG.Edge.ReleaseSourceImporterTest

    def get(url, _opts) do
      cond do
        String.contains?(url, "api.github.com/repos/carverauto/serviceradar/releases?per_page=") ->
          query = url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
          per_page = Map.fetch!(query, "per_page")

          {:ok,
           %Req.Response{
             status: 200,
             body: Enum.take(releases(), String.to_integer(per_page))
           }}

        String.contains?(url, "api.github.com/repos/carverauto/serviceradar/releases/tags/v1.2.3") ->
          {:ok,
           %Req.Response{
             status: 200,
             body: %{
               "tag_name" => "v1.2.3",
               "name" => "ServiceRadar 1.2.3",
               "body" => "GitHub release notes",
               "html_url" => "https://github.com/carverauto/serviceradar/releases/tag/v1.2.3",
               "assets" => [
                 %{
                   "name" => "serviceradar-agent-release-manifest.json",
                   "browser_download_url" =>
                     "https://github.com/carverauto/serviceradar/releases/download/v1.2.3/serviceradar-agent-release-manifest.json"
                 },
                 %{
                   "name" => "serviceradar-agent-release-manifest.sig",
                   "browser_download_url" =>
                     "https://github.com/carverauto/serviceradar/releases/download/v1.2.3/serviceradar-agent-release-manifest.sig"
                 }
               ]
             }
           }}

        String.ends_with?(url, "/serviceradar-agent-release-manifest.json") ->
          {:ok, %Req.Response{status: 200, body: ReleaseSourceImporterTest.manifest_json()}}

        String.ends_with?(url, "/serviceradar-agent-release-manifest.sig") ->
          {:ok, %Req.Response{status: 200, body: ReleaseSourceImporterTest.signature()}}

        true ->
          {:ok, %Req.Response{status: 404, body: ""}}
      end
    end

    # Newest first, as GitHub lists them. More add-on releases precede the
    # agent releases than the browser shows, so the agent releases are only
    # found when the scan reads past the visible limit.
    defp releases do
      addon_releases =
        for patch <- 9..5//-1 do
          %{
            "tag_name" => "netprobe-v0.2.#{patch}",
            "name" => "Native add-on netprobe 0.2.#{patch}",
            "body" => "Add-on only release",
            "html_url" => "https://github.com/carverauto/serviceradar/releases/tag/netprobe-v0.2.#{patch}",
            "published_at" => "2026-03-29T1#{patch}:00:00Z",
            "assets" => [
              %{"name" => "serviceradar-native-addon-index.json"},
              %{"name" => "serviceradar-native-addon-index.sig"}
            ]
          }
        end

      addon_releases ++
        [
          %{
            "tag_name" => "v1.2.4",
            "name" => "ServiceRadar 1.2.4",
            "body" => "Newest release",
            "html_url" => "https://github.com/carverauto/serviceradar/releases/tag/v1.2.4",
            "published_at" => "2026-03-28T20:00:00Z",
            "assets" => [
              %{"name" => "serviceradar-agent-release-manifest.json"},
              %{"name" => "serviceradar-agent-release-manifest.sig"}
            ]
          },
          %{
            "tag_name" => "v1.2.3",
            "name" => "ServiceRadar 1.2.3",
            "body" => "Missing manifest asset",
            "html_url" => "https://github.com/carverauto/serviceradar/releases/tag/v1.2.3",
            "published_at" => "2026-03-27T20:00:00Z",
            "assets" => [
              %{"name" => "serviceradar-agent-release-manifest.sig"}
            ]
          }
        ]
    end
  end

  setup do
    original_client = Application.get_env(:serviceradar_web_ng, :agent_release_import_http_client)

    on_exit(fn ->
      if is_nil(original_client) do
        Application.delete_env(:serviceradar_web_ng, :agent_release_import_http_client)
      else
        Application.put_env(:serviceradar_web_ng, :agent_release_import_http_client, original_client)
      end
    end)

    :ok
  end

  test "imports a GitHub release manifest and signature" do
    Application.put_env(:serviceradar_web_ng, :agent_release_import_http_client, GitHubClient)

    assert {:ok, attrs} =
             ReleaseSourceImporter.import(%{
               "repo_url" => "https://github.com/carverauto/serviceradar",
               "release_tag" => "v1.2.3"
             })

    assert attrs.version == "1.2.3"
    assert attrs.signature == @signature
    assert attrs.release_notes == "GitHub release notes"
    assert attrs.manifest == @manifest
    assert get_in(attrs, [:metadata, "source", "provider"]) == "github"

    assert get_in(attrs, [:metadata, "source", "repo_url"]) ==
             "https://github.com/carverauto/serviceradar"
  end

  test "rejects repository URLs on untrusted hosts" do
    assert {:error, "GitHub repository URL must look like https://github.com/<owner>/<repo>"} =
             ReleaseSourceImporter.import(%{
               "repo_url" => "https://forgejo.example.com/acme/serviceradar",
               "release_tag" => "v9.9.9"
             })
  end

  test "rejects Forgejo repository URLs for agent release import" do
    assert {:error, "GitHub repository URL must look like https://github.com/<owner>/<repo>"} =
             ReleaseSourceImporter.import(%{
               "repo_url" => "https://code.carverauto.dev/carverauto/serviceradar",
               "release_tag" => "v1.2.3"
             })
  end

  test "returns a helpful error when the release asset is missing" do
    Application.put_env(:serviceradar_web_ng, :agent_release_import_http_client, GitHubClient)

    assert {:error, "Release asset missing.sig was not found"} =
             ReleaseSourceImporter.import(%{
               "repo_url" => "https://github.com/carverauto/serviceradar",
               "release_tag" => "v1.2.3",
               "signature_asset_name" => "missing.sig"
             })
  end

  test "lists recent releases with import readiness" do
    Application.put_env(:serviceradar_web_ng, :agent_release_import_http_client, GitHubClient)

    assert {:ok, [latest, previous]} =
             ReleaseSourceImporter.list_recent_releases(%{
               "repo_url" => "https://github.com/carverauto/serviceradar"
             })

    assert latest.tag == "v1.2.4"
    assert latest.import_ready?
    assert latest.manifest_present?
    assert latest.signature_present?

    assert previous.tag == "v1.2.3"
    refute previous.import_ready?
    refute previous.manifest_present?
    assert previous.signature_present?
  end

  test "recent release browser ignores add-on only releases" do
    Application.put_env(:serviceradar_web_ng, :agent_release_import_http_client, GitHubClient)

    assert {:ok, releases} =
             ReleaseSourceImporter.list_recent_releases(%{
               "repo_url" => "https://github.com/carverauto/serviceradar"
             })

    refute Enum.any?(releases, &String.starts_with?(&1.tag, "netprobe-"))
  end

  # Visible list is 5. The scan window is that limit times 10, capped at 50
  # (ReleaseSourceImporter's documented recent-release scan). Five add-on
  # releases sit in front, then a draft that carries the agent assets, then
  # enough published agent releases that a correct browser keeps only five.
  defmodule ScanWindowClient do
    @moduledoc false

    def get(url, _opts) do
      query = url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
      per_page = Map.fetch!(query, "per_page")
      Process.put(:agent_release_scan_per_page, per_page)

      {:ok,
       %Req.Response{
         status: 200,
         body: Enum.take(releases(), String.to_integer(per_page))
       }}
    end

    defp releases do
      addons =
        for patch <- 5..1//-1 do
          %{
            "tag_name" => "netprobe-v0.3.#{patch}",
            "name" => "Native add-on netprobe 0.3.#{patch}",
            "draft" => false,
            "assets" => [
              %{"name" => "serviceradar-native-addon-index.json"},
              %{"name" => "serviceradar-native-addon-index.sig"}
            ]
          }
        end

      draft = %{
        "tag_name" => "v9.0.0",
        "name" => "ServiceRadar 9.0.0 draft",
        "draft" => true,
        "prerelease" => false,
        "assets" => [
          %{"name" => "serviceradar-agent-release-manifest.json"},
          %{"name" => "serviceradar-agent-release-manifest.sig"}
        ]
      }

      published =
        for patch <- 4..0//-1 do
          %{
            "tag_name" => "v8.0.#{patch}",
            "name" => "ServiceRadar 8.0.#{patch}",
            "draft" => false,
            "assets" => [
              %{"name" => "serviceradar-agent-release-manifest.json"},
              %{"name" => "serviceradar-agent-release-manifest.sig"}
            ]
          }
        end

      addons ++ [draft | published]
    end
  end

  test "keeps a draft behind add-on releases and still shows only five" do
    Application.put_env(:serviceradar_web_ng, :agent_release_import_http_client, ScanWindowClient)

    assert {:ok, releases} =
             ReleaseSourceImporter.list_recent_releases(%{
               "repo_url" => "https://github.com/carverauto/serviceradar"
             })

    # Default visible limit is 5, so the scan asks GitHub for 50, not 5.
    assert Process.get(:agent_release_scan_per_page) == "50"

    assert Enum.map(releases, & &1.tag) == ["v9.0.0", "v8.0.4", "v8.0.3", "v8.0.2", "v8.0.1"]

    assert hd(releases).draft?
    assert hd(releases).import_ready?
    refute Enum.any?(releases, &String.starts_with?(&1.tag, "netprobe-"))
    refute Enum.any?(releases, &(&1.tag == "v8.0.0"))
  end
end
