defmodule ServiceRadarWebNG.Plugins.GitHubImporterTest do
  use ExUnit.Case, async: false

  alias ServiceRadarWebNG.Plugins.GitHubImporter
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

  @wasm_blob <<0, 1, 2, 3, 4>>

  defmodule MockClient do
    def get(url, _opts) do
      cond do
        String.contains?(url, "api.github.com/repos/acme/demo/commits/") ->
          {:ok,
           %Req.Response{
             status: 200,
             body: %{
               "sha" => "abc123",
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

        String.contains?(url, "raw.githubusercontent.com/acme/demo/main/plugin.yaml") ->
          {:ok, %Req.Response{status: 200, body: @manifest_yaml}}

        String.contains?(url, "raw.githubusercontent.com/acme/demo/main/plugin.wasm") ->
          {:ok, %Req.Response{status: 200, body: @wasm_blob}}

        true ->
          {:ok, %Req.Response{status: 404, body: ""}}
      end
    end
  end

  defmodule UnverifiedClient do
    def get(url, _opts) do
      cond do
        String.contains?(url, "api.github.com/repos/acme/demo/commits/") ->
          {:ok,
           %Req.Response{
             status: 200,
             body: %{
               "sha" => "abc123",
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

        String.contains?(url, "raw.githubusercontent.com/acme/demo/main/plugin.yaml") ->
          {:ok, %Req.Response{status: 200, body: @manifest_yaml}}

        String.contains?(url, "raw.githubusercontent.com/acme/demo/main/plugin.wasm") ->
          {:ok, %Req.Response{status: 200, body: @wasm_blob}}

        true ->
          {:ok, %Req.Response{status: 404, body: ""}}
      end
    end
  end

  setup do
    original_client = Application.get_env(:serviceradar_web_ng, :github_http_client)
    original_policy = Application.get_env(:serviceradar_web_ng, :plugin_verification)

    Application.put_env(:serviceradar_web_ng, :github_http_client, MockClient)
    Application.put_env(:serviceradar_web_ng, :plugin_verification,
      require_gpg_for_github: false,
      allow_unsigned_uploads: true
    )

    on_exit(fn ->
      if is_nil(original_client) do
        Application.delete_env(:serviceradar_web_ng, :github_http_client)
      else
        Application.put_env(:serviceradar_web_ng, :github_http_client, original_client)
      end

      if is_nil(original_policy) do
        Application.delete_env(:serviceradar_web_ng, :plugin_verification)
      else
        Application.put_env(:serviceradar_web_ng, :plugin_verification, original_policy)
      end
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
    assert result.gpg_verified_at != nil
    assert result.source_commit == "abc123"
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
end
