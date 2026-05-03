defmodule ServiceRadarWebNG.Plugins.GitHubImporterTest do
  use ExUnit.Case, async: false

  alias ServiceRadarWebNG.Plugins.GitHubImporter
  alias ServiceRadarWebNG.Plugins.GitHubImporterTest
  alias ServiceRadarWebNG.Plugins.Storage

  @repo_url "https://github.com/acme/demo"
  @manifest_yaml """
  id: http-check
  name: HTTP Check
  version: 1.0.0
  entrypoint: run_check
  outputs: serviceradar.plugin_result.v1
  capabilities:
    - submit_result
  resources:
    requested_cpu_ms: 1000
    requested_memory_mb: 64
  permissions:
    allowed_domains: []
  """
  @alias_manifest """
  defaults: &defaults
    id: bad
  <<: *defaults
  """

  @wasm_blob <<0, 1, 2, 3, 4>>
  @dashboard_renderer "export function mountDashboard(element, host) { element.dataset.dashboard = host.package.name; }"
  @large_wasm :binary.copy(<<1>>, Storage.max_upload_bytes() + 1)

  def manifest_yaml, do: @manifest_yaml
  def alias_manifest, do: @alias_manifest
  def wasm_blob, do: @wasm_blob
  def dashboard_renderer, do: @dashboard_renderer
  def large_wasm, do: @large_wasm

  def dashboard_manifest_json do
    Jason.encode!(%{
      "id" => "com.test.github-dashboard",
      "name" => "GitHub Dashboard",
      "version" => "1.0.0",
      "renderer" => %{
        "kind" => "browser_module",
        "interface_version" => "dashboard-browser-module-v1",
        "artifact" => "dashboard-renderer.js",
        "sha256" => Storage.sha256(@dashboard_renderer),
        "trust" => "trusted",
        "exports" => ["mountDashboard"]
      },
      "data_frames" => [
        %{
          "id" => "sites",
          "query" => "in:wifi_sites limit:1",
          "encoding" => "json_rows"
        }
      ],
      "capabilities" => ["srql.execute", "map.deck.render", "navigation.open"],
      "settings_schema" => %{},
      "source" => %{"homepage" => "https://github.com/acme/demo"}
    })
  end

  defmodule MockClient do
    @moduledoc false

    def get(url, _opts) do
      cond do
        String.contains?(url, "api.github.com/repos/acme/demo/commits/") ->
          {:ok,
           %Req.Response{
             status: 200,
             body: %{
               "sha" => String.duplicate("a", 40),
               "commit" => %{
                 "verification" => %{
                   "verified" => true,
                   "reason" => "valid",
                   "signer" => %{"login" => "octo"}
                 }
               }
             }
           }}

        String.contains?(url, "api.github.com/repos/acme/demo") ->
          {:ok, %Req.Response{status: 200, body: %{"default_branch" => "main"}}}

        String.contains?(url, "raw.githubusercontent.com/acme/demo/#{String.duplicate("a", 40)}/plugin.yaml") ->
          {:ok,
           %Req.Response{
             status: 200,
             body: GitHubImporterTest.manifest_yaml()
           }}

        String.contains?(url, "raw.githubusercontent.com/acme/demo/#{String.duplicate("a", 40)}/plugin.wasm") ->
          {:ok,
           %Req.Response{
             status: 200,
             body: GitHubImporterTest.wasm_blob()
           }}

        String.contains?(url, "raw.githubusercontent.com/acme/demo/#{String.duplicate("a", 40)}/dashboard.json") ->
          {:ok,
           %Req.Response{
             status: 200,
             body: GitHubImporterTest.dashboard_manifest_json()
           }}

        String.contains?(
          url,
          "raw.githubusercontent.com/acme/demo/#{String.duplicate("a", 40)}/dashboard-renderer.js"
        ) ->
          {:ok,
           %Req.Response{
             status: 200,
             body: GitHubImporterTest.dashboard_renderer()
           }}

        true ->
          {:ok, %Req.Response{status: 404, body: ""}}
      end
    end
  end

  defmodule UnverifiedClient do
    @moduledoc false

    def get(url, _opts) do
      cond do
        String.contains?(url, "api.github.com/repos/acme/demo/commits/") ->
          {:ok,
           %Req.Response{
             status: 200,
             body: %{
               "sha" => String.duplicate("a", 40),
               "commit" => %{
                 "verification" => %{
                   "verified" => false,
                   "reason" => "unsigned"
                 }
               }
             }
           }}

        String.contains?(url, "api.github.com/repos/acme/demo") ->
          {:ok, %Req.Response{status: 200, body: %{"default_branch" => "main"}}}

        String.contains?(url, "raw.githubusercontent.com/acme/demo/#{String.duplicate("a", 40)}/plugin.yaml") ->
          {:ok,
           %Req.Response{
             status: 200,
             body: GitHubImporterTest.manifest_yaml()
           }}

        String.contains?(url, "raw.githubusercontent.com/acme/demo/#{String.duplicate("a", 40)}/plugin.wasm") ->
          {:ok,
           %Req.Response{
             status: 200,
             body: GitHubImporterTest.wasm_blob()
           }}

        true ->
          {:ok, %Req.Response{status: 404, body: ""}}
      end
    end
  end

  defmodule OversizedClient do
    @moduledoc false

    def get(url, opts), do: GitHubImporterTest.handle(url, opts, GitHubImporterTest.large_wasm())
  end

  defmodule AliasManifestClient do
    @moduledoc false

    def get(url, opts) do
      if String.contains?(url, "raw.githubusercontent.com") and String.ends_with?(url, "/plugin.yaml") do
        {:ok, %Req.Response{status: 200, body: GitHubImporterTest.alias_manifest()}}
      else
        GitHubImporterTest.handle(url, opts, GitHubImporterTest.wasm_blob())
      end
    end
  end

  defmodule RepoAwareClient do
    @moduledoc false

    def get(url, opts), do: GitHubImporterTest.handle(url, opts, GitHubImporterTest.wasm_blob())
  end

  setup do
    original_client = Application.get_env(:serviceradar_web_ng, :github_http_client)
    original_policy = Application.get_env(:serviceradar_web_ng, :plugin_verification)
    original_token = Application.get_env(:serviceradar_web_ng, :github_token)

    Application.put_env(:serviceradar_web_ng, :github_http_client, MockClient)

    Application.put_env(:serviceradar_web_ng, :plugin_verification,
      require_gpg_for_github: false,
      allow_unsigned_uploads: true
    )

    on_exit(fn ->
      restore_env(:github_http_client, original_client)
      restore_env(:plugin_verification, original_policy)
      restore_env(:github_token, original_token)
    end)

    :ok
  end

  test "fetches manifest, wasm, and verification metadata" do
    assert {:ok, result} =
             GitHubImporter.fetch(%{
               source_repo_url: @repo_url,
               source_commit: ""
             })

    assert result.manifest["id"] == "http-check"
    assert result.content_hash == Storage.sha256(@wasm_blob)
    assert result.gpg_key_id == "octo"
    assert result.gpg_verified_at
    assert result.source_commit == String.duplicate("a", 40)
  end

  test "fetches dashboard manifest, renderer artifact, and verification metadata" do
    assert {:ok, result} =
             GitHubImporter.fetch_dashboard(%{
               source_repo_url: @repo_url,
               source_commit: ""
             })

    assert result.manifest["id"] == "com.test.github-dashboard"
    assert result.manifest_json == dashboard_manifest_json()
    assert result.renderer_artifact == @dashboard_renderer
    assert result.content_hash == Storage.sha256(@dashboard_renderer)
    assert result.gpg_key_id == "octo"
    assert result.gpg_verified_at
    assert result.source_commit == String.duplicate("a", 40)
    assert result.source_manifest_path == "dashboard.json"
    assert result.source_renderer_path == "dashboard-renderer.js"
  end

  test "rejects unverified commits when policy requires gpg" do
    Application.put_env(:serviceradar_web_ng, :github_http_client, UnverifiedClient)

    Application.put_env(:serviceradar_web_ng, :plugin_verification,
      require_gpg_for_github: true,
      allow_unsigned_uploads: true
    )

    assert {:error, :verification_required} =
             GitHubImporter.fetch(%{
               source_repo_url: @repo_url
             })
  end

  test "rejects verified commits when trusted signer allowlist is missing" do
    Application.put_env(:serviceradar_web_ng, :plugin_verification,
      require_gpg_for_github: true,
      allow_unsigned_uploads: true,
      trusted_github_signers: []
    )

    assert {:error, :trusted_signers_not_configured} =
             GitHubImporter.fetch(%{
               source_repo_url: @repo_url
             })
  end

  test "rejects verified commits from untrusted signers" do
    Application.put_env(:serviceradar_web_ng, :plugin_verification,
      require_gpg_for_github: true,
      allow_unsigned_uploads: true,
      trusted_github_signers: ["trusted-maintainer"]
    )

    assert {:error, :untrusted_signer} =
             GitHubImporter.fetch(%{
               source_repo_url: @repo_url
             })
  end

  test "accepts verified commits from trusted signers" do
    Application.put_env(:serviceradar_web_ng, :plugin_verification,
      require_gpg_for_github: true,
      allow_unsigned_uploads: true,
      trusted_github_signers: ["octo"]
    )

    assert {:ok, result} =
             GitHubImporter.fetch(%{
               source_repo_url: @repo_url
             })

    assert result.gpg_key_id == "octo"
  end

  test "rejects oversized wasm blobs before import succeeds" do
    Application.put_env(:serviceradar_web_ng, :github_http_client, OversizedClient)

    assert {:error, :payload_too_large} =
             GitHubImporter.fetch(%{
               source_repo_url: @repo_url
             })
  end

  test "rejects authenticated imports outside trusted repository boundaries" do
    Application.put_env(:serviceradar_web_ng, :github_token, "secret-token")
    Application.put_env(:serviceradar_web_ng, :github_http_client, RepoAwareClient)

    Application.put_env(:serviceradar_web_ng, :plugin_verification, trusted_github_owners: ["trusted-owner"])

    assert {:error, :untrusted_repo} =
             GitHubImporter.fetch(%{
               source_repo_url: @repo_url
             })
  end

  test "accepts authenticated imports for trusted repositories" do
    Application.put_env(:serviceradar_web_ng, :github_token, "secret-token")
    Application.put_env(:serviceradar_web_ng, :github_http_client, RepoAwareClient)

    Application.put_env(:serviceradar_web_ng, :plugin_verification, trusted_github_repositories: ["acme/demo"])

    assert {:ok, result} =
             GitHubImporter.fetch(%{
               source_repo_url: @repo_url
             })

    assert result.source_commit == String.duplicate("a", 40)
  end

  test "rejects invalid git refs" do
    assert {:error, :invalid_ref} =
             GitHubImporter.fetch(%{
               source_repo_url: @repo_url,
               source_commit: "../bad"
             })
  end

  test "rejects traversal-style manifest paths" do
    assert {:error, :invalid_manifest_path} =
             GitHubImporter.fetch(%{
               source_repo_url: @repo_url,
               manifest_path: "../plugin.yaml"
             })
  end

  test "rejects hostile yaml aliases in manifests" do
    Application.put_env(:serviceradar_web_ng, :github_http_client, AliasManifestClient)

    assert {:error, {:invalid_manifest, errors}} =
             GitHubImporter.fetch(%{
               source_repo_url: @repo_url
             })

    assert "yaml anchors and aliases are not allowed" in errors
  end

  def handle(url, _opts, wasm_blob) do
    cond do
      String.contains?(url, "api.github.com/repos/acme/demo/commits/") ->
        MockClient.get(url, [])

      String.contains?(url, "api.github.com/repos/acme/demo") ->
        MockClient.get(url, [])

      String.contains?(url, "raw.githubusercontent.com/acme/demo/#{String.duplicate("a", 40)}/plugin.yaml") ->
        {:ok, %Req.Response{status: 200, body: GitHubImporterTest.manifest_yaml()}}

      String.contains?(url, "raw.githubusercontent.com/acme/demo/#{String.duplicate("a", 40)}/plugin.wasm") ->
        {:ok, %Req.Response{status: 200, body: wasm_blob}}

      true ->
        {:ok, %Req.Response{status: 404, body: ""}}
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:serviceradar_web_ng, key)
  defp restore_env(key, value), do: Application.put_env(:serviceradar_web_ng, key, value)
end
