defmodule ServiceRadarWebNG.Edge.ReleaseSourceImporterTest do
  use ExUnit.Case, async: false

  alias ServiceRadarWebNG.Edge.ReleaseSourceImporter

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
                   "browser_download_url" => "https://downloads.example/github/manifest.json"
                 },
                 %{
                   "name" => "serviceradar-agent-release-manifest.sig",
                   "browser_download_url" => "https://downloads.example/github/manifest.sig"
                 }
               ]
             }
           }}

        String.ends_with?(url, "/github/manifest.json") ->
          {:ok, %Req.Response{status: 200, body: ReleaseSourceImporterTest.manifest_json()}}

        String.ends_with?(url, "/github/manifest.sig") ->
          {:ok, %Req.Response{status: 200, body: ReleaseSourceImporterTest.signature()}}

        true ->
          {:ok, %Req.Response{status: 404, body: ""}}
      end
    end
  end

  defmodule ForgejoClient do
    @moduledoc false

    alias ServiceRadarWebNG.Edge.ReleaseSourceImporterTest

    def get(url, _opts) do
      cond do
        String.contains?(url, "/repos/acme/serviceradar/releases/tags/") ->
          {:ok,
           %Req.Response{
             status: 200,
             body: %{
               "tag_name" => "v9.9.9",
               "name" => "Forgejo Release",
               "body" => "Forgejo release notes",
               "html_url" => "https://forgejo.example.com/acme/serviceradar/releases/tag/v9.9.9",
               "assets" => [
                 %{
                   "name" => "custom-manifest.json",
                   "browser_download_url" => "https://forgejo.example.com/assets/custom-manifest.json"
                 },
                 %{
                   "name" => "custom-manifest.sig",
                   "browser_download_url" => "https://forgejo.example.com/assets/custom-manifest.sig"
                 }
               ]
             }
           }}

        String.ends_with?(url, "/custom-manifest.json") ->
          {:ok, %Req.Response{status: 200, body: ReleaseSourceImporterTest.manifest_json()}}

        String.ends_with?(url, "/custom-manifest.sig") ->
          {:ok, %Req.Response{status: 200, body: ReleaseSourceImporterTest.signature()}}

        true ->
          {:ok, %Req.Response{status: 404, body: ""}}
      end
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
               "provider" => "github",
               "repo_url" => "https://github.com/carverauto/serviceradar",
               "release_tag" => "v1.2.3"
             })

    assert attrs.version == "1.2.3"
    assert attrs.signature == @signature
    assert attrs.release_notes == "GitHub release notes"
    assert attrs.manifest == @manifest
    assert get_in(attrs, [:metadata, "source", "provider"]) == "github"
    assert get_in(attrs, [:metadata, "source", "repo_url"]) == "https://github.com/carverauto/serviceradar"
  end

  test "imports a Forgejo release manifest with custom asset names" do
    Application.put_env(:serviceradar_web_ng, :agent_release_import_http_client, ForgejoClient)

    assert {:ok, attrs} =
             ReleaseSourceImporter.import(%{
               "provider" => "forgejo",
               "repo_url" => "https://forgejo.example.com/acme/serviceradar",
               "release_tag" => "v9.9.9",
               "manifest_asset_name" => "custom-manifest.json",
               "signature_asset_name" => "custom-manifest.sig"
             })

    assert attrs.version == "1.2.3"
    assert get_in(attrs, [:metadata, "source", "provider"]) == "forgejo"

    assert get_in(attrs, [:metadata, "source", "repo_url"]) ==
             "https://forgejo.example.com/acme/serviceradar"
  end

  test "returns a helpful error when the release asset is missing" do
    Application.put_env(:serviceradar_web_ng, :agent_release_import_http_client, GitHubClient)

    assert {:error, "Release asset missing.sig was not found"} =
             ReleaseSourceImporter.import(%{
               "provider" => "github",
               "repo_url" => "https://github.com/carverauto/serviceradar",
               "release_tag" => "v1.2.3",
               "signature_asset_name" => "missing.sig"
             })
  end
end
