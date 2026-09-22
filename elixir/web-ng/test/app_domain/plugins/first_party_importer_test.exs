defmodule ServiceRadarWebNG.Plugins.FirstPartyImporterTest do
  use ExUnit.Case, async: false

  alias ServiceRadarWebNG.Plugins.FirstPartyImporter
  alias ServiceRadarWebNG.Plugins.FirstPartyReleaseClient
  alias ServiceRadarWebNG.Plugins.FirstPartySyncWorker
  alias ServiceRadarWebNG.Plugins.Packages
  alias ServiceRadarWebNG.Plugins.Storage
  alias ServiceRadarWebNG.Plugins.UploadSignature

  @moduletag :unit
  @moduletag :db_free

  @repo_url "https://github.com/carverauto/serviceradar"
  @manifest_yaml """
  id: hello-wasm
  name: Hello Wasm
  version: 1.2.3
  entrypoint: run_check
  runtime: wasi-preview1
  outputs: serviceradar.plugin_result.v1
  capabilities:
    - get_config
    - submit_result
  resources:
    requested_cpu_ms: 1000
    requested_memory_mb: 64
  """
  @manifest %{
    "id" => "hello-wasm",
    "name" => "Hello Wasm",
    "version" => "1.2.3",
    "entrypoint" => "run_check",
    "runtime" => "wasi-preview1",
    "outputs" => "serviceradar.plugin_result.v1",
    "capabilities" => ["get_config", "submit_result"],
    "resources" => %{
      "requested_cpu_ms" => 1000,
      "requested_memory_mb" => 64
    }
  }
  @wasm "hello wasm payload"
  @display_contract %{
    "id" => "com.example.activity.display",
    "version" => "1.0.0",
    "schema_id" => "com.example.activity",
    "schema_version" => "1.0.0",
    "widgets" => [
      %{"type" => "summary", "title" => "title", "message" => "message"}
    ]
  }

  defmodule GitHubReleaseClient do
    @moduledoc false

    alias ServiceRadarWebNG.Plugins.FirstPartyImporterTest

    def get(url, _opts) do
      cond do
        String.contains?(url, "api.github.com/repos/carverauto/serviceradar/releases?per_page=") ->
          Process.put(
            :first_party_recent_release_requests,
            Process.get(:first_party_recent_release_requests, 0) + 1
          )

          releases =
            if Process.get(:first_party_releases_without_index) do
              [%{"tag_name" => "v1.2.3", "assets" => []}]
            else
              [FirstPartyImporterTest.release()]
            end

          {:ok, %Req.Response{status: 200, body: releases}}

        String.contains?(url, "api.github.com/repos/carverauto/serviceradar/releases/tags/v1.2.3") ->
          release =
            if Process.get(:first_party_release_without_index_asset) do
              Map.put(FirstPartyImporterTest.release(), "assets", [])
            else
              FirstPartyImporterTest.release()
            end

          {:ok, %Req.Response{status: 200, body: release}}

        String.ends_with?(url, "/serviceradar-wasm-plugin-index.json") ->
          {:ok,
           %Req.Response{
             status: 200,
             body: Process.get(:first_party_index_body) || Jason.encode!(FirstPartyImporterTest.index())
           }}

        String.ends_with?(url, "/hello-wasm.zip") and Process.get(:first_party_bundle_redirect) ->
          {:ok,
           %Req.Response{
             status: 302,
             headers: %{"location" => ["https://example.com/hello-wasm.zip"]},
             body: ""
           }}

        String.ends_with?(url, "/hello-wasm.zip") ->
          {:ok, %Req.Response{status: 200, body: FirstPartyImporterTest.bundle()}}

        String.ends_with?(url, "/hello-wasm.upload-signature.json") ->
          {:ok, %Req.Response{status: 200, body: Jason.encode!(FirstPartyImporterTest.upload_signature())}}

        true ->
          {:ok, %Req.Response{status: 404, body: ""}}
      end
    end
  end

  defmodule OciClient do
    @moduledoc false

    alias ServiceRadarWebNG.Plugins.FirstPartyImporterTest

    def get(url, opts) do
      cond do
        String.contains?(url, "api.github.com/repos/carverauto/serviceradar/releases?per_page=") ->
          GitHubReleaseClient.get(url, [])

        String.contains?(url, "api.github.com/repos/carverauto/serviceradar/releases/tags/v1.2.3") ->
          GitHubReleaseClient.get(url, [])

        String.ends_with?(url, "/serviceradar-wasm-plugin-index.json") ->
          {:ok, %Req.Response{status: 200, body: Jason.encode!(FirstPartyImporterTest.oci_index())}}

        String.contains?(url, "/service/token") ->
          Process.put(:registry_token_auth_header, header(opts, "authorization"))
          {:ok, %Req.Response{status: 200, body: %{"token" => "registry-token"}}}

        String.ends_with?(url, "/v2/serviceradar/wasm-plugin-hello-wasm/manifests/v1.2.3") ->
          if Process.get(:first_party_registry_auth_challenge) && header(opts, "authorization") != "Bearer registry-token" do
            {:ok,
             %Req.Response{
               status: 401,
               body: "",
               headers: %{
                 "www-authenticate" => [
                   ~s(Bearer realm="https://registry.carverauto.dev/service/token",service="harbor-registry",scope="repository:serviceradar/wasm-plugin-hello-wasm:pull")
                 ]
               }
             }}
          else
            {:ok,
             %Req.Response{
               status: 200,
               body: FirstPartyImporterTest.oci_manifest(),
               headers: %{"docker-content-digest" => [FirstPartyImporterTest.oci_manifest_digest()]}
             }}
          end

        String.ends_with?(url, "/v2/serviceradar/wasm-plugin-hello-wasm/blobs/sha256:bundle-layer") ->
          {:ok, %Req.Response{status: 200, body: FirstPartyImporterTest.bundle()}}

        String.ends_with?(url, "/v2/serviceradar/wasm-plugin-hello-wasm/blobs/sha256:signature-layer") ->
          {:ok, %Req.Response{status: 200, body: Jason.encode!(FirstPartyImporterTest.upload_signature())}}

        true ->
          {:ok, %Req.Response{status: 404, body: ""}}
      end
    end

    defp header(opts, name) do
      opts
      |> Keyword.get(:headers, [])
      |> Enum.find_value(fn {key, value} ->
        if String.downcase(to_string(key)) == name, do: value
      end)
    end
  end

  defmodule FakeCosignVerifier do
    @moduledoc false

    def verify(%{ref: ref, digest: digest}) do
      Process.put(:cosign_verified_artifact, {ref, digest})
      :ok
    end
  end

  setup do
    original_verification = Application.get_env(:serviceradar_web_ng, :plugin_verification)
    original_import_client = Application.get_env(:serviceradar_web_ng, :first_party_plugin_import_http_client)
    original_import_config = Application.get_env(:serviceradar_web_ng, :first_party_plugin_import)
    original_cosign_verifier = Application.get_env(:serviceradar_web_ng, :first_party_plugin_cosign_verifier)
    original_storage = Application.get_env(:serviceradar_web_ng, :plugin_storage)
    {public_key, private_key} = :crypto.generate_key(:eddsa, :ed25519)
    tmp = Path.join(System.tmp_dir!(), "sr-first-party-plugin-test-#{System.unique_integer([:positive])}")

    Application.put_env(:serviceradar_web_ng, :plugin_verification,
      require_gpg_for_github: false,
      allow_unsigned_uploads: false,
      trusted_upload_signing_keys: %{"test-signer" => Base.encode64(public_key)}
    )

    Application.put_env(:serviceradar_web_ng, :first_party_plugin_import_http_client, GitHubReleaseClient)

    Application.put_env(:serviceradar_web_ng, :plugin_storage,
      backend: :filesystem,
      base_path: tmp,
      signing_secret: "test-secret"
    )

    Process.put(:first_party_private_key, private_key)
    Process.put(:first_party_public_key, public_key)
    Process.put(:first_party_bundle, nil)
    Process.put(:first_party_bundle_digest_override, nil)
    Process.put(:first_party_index_body, nil)
    Process.put(:first_party_bundle_redirect, false)
    Process.put(:first_party_signature, nil)
    Process.put(:cosign_verified_artifact, nil)
    Process.put(:first_party_releases_without_index, false)
    Process.put(:first_party_release_without_index_asset, false)
    Process.put(:first_party_recent_release_requests, 0)
    Process.put(:first_party_registry_auth_challenge, false)
    Process.put(:registry_token_auth_header, nil)

    on_exit(fn ->
      File.rm_rf(tmp)
      restore_env(:plugin_verification, original_verification)
      restore_env(:first_party_plugin_import_http_client, original_import_client)
      restore_env(:first_party_plugin_import, original_import_config)
      restore_env(:first_party_plugin_cosign_verifier, original_cosign_verifier)
      restore_env(:plugin_storage, original_storage)
    end)

    :ok
  end

  test "lists import-ready plugins from the GitHub release index" do
    assert {:ok, [plugin]} = FirstPartyImporter.list_recent_plugins(%{"repo_url" => @repo_url}, 10)
    assert plugin.plugin_id == "hello-wasm"
    assert plugin.version == "1.2.3"
    assert plugin.release_tag == "v1.2.3"
    assert plugin.import_ready?
  end

  test "lists plugins from an exact release without consulting recent releases" do
    Process.put(:first_party_releases_without_index, true)

    assert {:ok, [plugin]} =
             FirstPartyImporter.list_release_plugins(%{"repo_url" => @repo_url}, "v1.2.3")

    assert plugin.plugin_id == "hello-wasm"
    assert plugin.version == "1.2.3"
    assert plugin.release_tag == "v1.2.3"
    assert plugin.import_ready?
  end

  test "auto-sync discovery falls back to recent releases when the deployed tag is unpublished" do
    Process.put(:first_party_recent_release_requests, 0)

    assert {:ok, [plugin], nil} =
             FirstPartyImporter.list_plugins_for_sync(%{"repo_url" => @repo_url},
               release_tag: "v1.4.51",
               limit: 10
             )

    assert plugin.plugin_id == "hello-wasm"
    assert plugin.release_tag == "v1.2.3"
    assert Process.get(:first_party_recent_release_requests) >= 1
  end

  test "auto-sync discovery stays on the deployed tag when that release exists" do
    Process.put(:first_party_recent_release_requests, 0)
    Process.put(:first_party_releases_without_index, true)

    assert {:ok, [plugin], "v1.2.3"} =
             FirstPartyImporter.list_plugins_for_sync(%{"repo_url" => @repo_url},
               release_tag: "v1.2.3",
               limit: 10
             )

    assert plugin.release_tag == "v1.2.3"
    assert Process.get(:first_party_recent_release_requests) == 0
  end

  test "admin sync reports a missing selected release without consulting the recent feed" do
    Process.put(:first_party_recent_release_requests, 0)

    assert {:error, reason} =
             Packages.sync_first_party_plugins(repo_url: @repo_url, release_tag: "v9.8.7")

    assert reason =~ "Release tag v9.8.7 was not found"
    assert Process.get(:first_party_recent_release_requests) == 0
  end

  test "auto-sync discovery keeps the admin all-releases sentinel on its exact-only lookup" do
    Process.put(:first_party_recent_release_requests, 0)

    assert {:error, reason} =
             FirstPartyImporter.list_plugins_for_sync(%{"repo_url" => @repo_url},
               release_tag: FirstPartyReleaseClient.admin_all_releases_sentinel(),
               limit: 10
             )

    # The sentinel is not a GitHub tag: the 404 must surface as it did before
    # the unattended-sync fallback existed, never silently import another feed.
    assert reason =~ "Release tag #{FirstPartyReleaseClient.admin_all_releases_sentinel()} was not found"
    assert Process.get(:first_party_recent_release_requests) == 0
  end

  test "a deployed release that publishes no plugin index asset does not fail the sync job" do
    Process.put(:first_party_release_without_index_asset, true)
    Process.put(:first_party_recent_release_requests, 0)

    assert {:error, reason} =
             FirstPartyImporter.list_plugins_for_sync(%{"repo_url" => @repo_url},
               release_tag: "v1.2.3",
               limit: 10
             )

    # The release exists, so discovery must NOT switch to another release's
    # catalog -- but the job must not burn its Oban attempts on it either.
    assert Process.get(:first_party_recent_release_requests) == 0
    assert :ok = FirstPartySyncWorker.aggregate_results([{:error, reason}])
  end

  # A third-party repository publishes release assets and has NO oci_ref. The
  # readiness rule required one, so such entries were fetchable but permanently
  # filtered out, surfacing as "scanned N releases, but no import-ready plugin
  # entries were found". Every other fixture here carries both bundle_url and
  # oci_ref, which is why this went unnoticed.
  test "a release-asset entry with no oci_ref is import-ready" do
    Process.put(:first_party_index_body, Jason.encode!(release_asset_index()))

    assert {:ok, [plugin]} = FirstPartyImporter.list_recent_plugins(%{"repo_url" => @repo_url}, 10)
    assert plugin.plugin_id == "hello-wasm"
    assert is_nil(plugin.oci_ref) or plugin.oci_ref == ""
    assert plugin.import_ready?
  end

  # fetch_direct_artifact/2 fails without the signature URL, so treating such an
  # entry as ready would move the failure from discovery to import, where it
  # reads as a broken bundle rather than an incomplete index.
  test "a release-asset entry missing its signature URL is not import-ready" do
    index = release_asset_index()
    [entry] = index["plugins"]
    stripped = %{index | "plugins" => [Map.delete(entry, "upload_signature_url")]}
    Process.put(:first_party_index_body, Jason.encode!(stripped))

    assert {:ok, [plugin]} = FirstPartyImporter.list_recent_plugins(%{"repo_url" => @repo_url}, 10)
    refute plugin.import_ready?
  end

  test "summarizes recent releases without first-party plugin index assets" do
    Process.put(:first_party_releases_without_index, true)

    assert {:ok,
            %{
              plugins: [],
              scanned_releases: 1,
              indexed_releases: 0,
              index_asset_name: "serviceradar-wasm-plugin-index.json"
            }} = FirstPartyImporter.list_recent_plugins_with_summary(%{"repo_url" => @repo_url}, 10)
  end

  test "imports a verified first-party bundle" do
    assert {:ok, import} =
             FirstPartyImporter.import(%{
               "repo_url" => @repo_url,
               "release_tag" => "v1.2.3",
               "plugin_id" => "hello-wasm",
               "version" => "1.2.3"
             })

    assert import.manifest_struct.id == "hello-wasm"
    assert import.manifest_struct.version == "1.2.3"
    assert import.wasm == @wasm
    assert import.content_hash == Storage.sha256(@wasm)
    assert import.source_release_tag == "v1.2.3"
    assert import.verification_status == "verified"
  end

  describe "per-repository trusted signing keys" do
    test "verifies against the repository's key even when the global config has none" do
      # The point of repositories being records: trust travels with the source,
      # not with a single deployment-wide map.
      public_key = Process.get(:first_party_public_key)

      Application.put_env(:serviceradar_web_ng, :plugin_verification,
        require_gpg_for_github: false,
        allow_unsigned_uploads: false,
        trusted_upload_signing_keys: %{}
      )

      assert {:ok, import} =
               FirstPartyImporter.import(%{
                 "repo_url" => @repo_url,
                 "release_tag" => "v1.2.3",
                 "plugin_id" => "hello-wasm",
                 "version" => "1.2.3",
                 "trusted_upload_signing_keys" => %{"test-signer" => Base.encode64(public_key)}
               })

      assert import.verification_status == "verified"
    end

    test "rejects a bundle signed by another repository's key" do
      # Repository B publishes a bundle that repository A signed. Before this
      # change the global map made that indistinguishable from a legitimate
      # import; now B's key is the only one that counts for B's catalog.
      {other_public_key, _other_private_key} = :crypto.generate_key(:eddsa, :ed25519)

      assert {:error, reason} =
               FirstPartyImporter.import(%{
                 "repo_url" => @repo_url,
                 "release_tag" => "v1.2.3",
                 "plugin_id" => "hello-wasm",
                 "version" => "1.2.3",
                 "trusted_upload_signing_keys" => %{"test-signer" => Base.encode64(other_public_key)}
               })

      assert reason in [:invalid_signature, :unknown_signing_key]
    end

    test "rejects when the repository's key id does not match the signature" do
      public_key = Process.get(:first_party_public_key)

      assert {:error, reason} =
               FirstPartyImporter.import(%{
                 "repo_url" => @repo_url,
                 "release_tag" => "v1.2.3",
                 "plugin_id" => "hello-wasm",
                 "version" => "1.2.3",
                 "trusted_upload_signing_keys" => %{"someone-else" => Base.encode64(public_key)}
               })

      # Distinct from :invalid_signature: the key id in the signature is not one
      # this repository trusts, which is a different fault from a bad signature
      # under a trusted key.
      assert reason == :untrusted_signer
    end
  end

  test "rejects mismatched bundle digests" do
    Process.put(:first_party_bundle_digest_override, String.duplicate("a", 64))

    assert {:error, :bundle_digest_mismatch} =
             FirstPartyImporter.import(%{
               "repo_url" => @repo_url,
               "release_tag" => "v1.2.3",
               "plugin_id" => "hello-wasm",
               "version" => "1.2.3"
             })
  end

  test "rejects oversized resources before extracting the bundle" do
    Process.put(
      :first_party_bundle,
      bundle_with_entries([
        {~c"docs/oversized.md", String.duplicate("x", 4 * 1024 * 1024 + 1)}
      ])
    )

    assert {:error, {:invalid_bundle, :bundle_entry_too_large}} =
             FirstPartyImporter.import(%{
               "repo_url" => @repo_url,
               "release_tag" => "v1.2.3",
               "plugin_id" => "hello-wasm",
               "version" => "1.2.3"
             })
  end

  test "rejects the package when a display contract is invalid" do
    Process.put(
      :first_party_bundle,
      bundle_with_entries([
        {~c"display/event_log_activity.display.json", Jason.encode!(%{"widgets" => []})}
      ])
    )

    assert {:error, {:invalid_display_contracts, errors}} =
             FirstPartyImporter.import(%{
               "repo_url" => @repo_url,
               "release_tag" => "v1.2.3",
               "plugin_id" => "hello-wasm",
               "version" => "1.2.3"
             })

    assert Enum.any?(errors, &String.contains?(&1, "display/event_log_activity.display.json"))
  end

  test "rejects malformed first-party import index assets" do
    Process.put(:first_party_index_body, "[not-an-object]")

    assert {:error, "Plugin import index asset is not valid JSON"} =
             FirstPartyImporter.list_recent_plugins(%{"repo_url" => @repo_url}, 10)
  end

  test "rejects untrusted artifact redirects" do
    Process.put(:first_party_bundle_redirect, true)

    assert {:error, "plugin import asset URL is not trusted"} =
             FirstPartyImporter.import(%{
               "repo_url" => @repo_url,
               "release_tag" => "v1.2.3",
               "plugin_id" => "hello-wasm",
               "version" => "1.2.3"
             })
  end

  test "rejects untrusted repository URLs" do
    assert {:error, "GitHub repository URL must look like https://github.com/<owner>/<repo>"} =
             FirstPartyImporter.list_recent_plugins(%{"repo_url" => "https://example.com/repo"}, 10)
  end

  test "rejects invalid upload signatures" do
    Process.put(:first_party_signature, %{
      "algorithm" => "ed25519",
      "key_id" => "test-signer",
      "signature" => Base.encode64("not a valid signature")
    })

    assert {:error, _reason} =
             FirstPartyImporter.import(%{
               "repo_url" => @repo_url,
               "release_tag" => "v1.2.3",
               "plugin_id" => "hello-wasm",
               "version" => "1.2.3"
             })
  end

  test "imports an OCI artifact only after Cosign and upload signature verification" do
    Application.put_env(:serviceradar_web_ng, :first_party_plugin_import_http_client, OciClient)
    Application.put_env(:serviceradar_web_ng, :first_party_plugin_cosign_verifier, FakeCosignVerifier)

    assert {:ok, import} =
             FirstPartyImporter.import(%{
               "repo_url" => @repo_url,
               "release_tag" => "v1.2.3",
               "plugin_id" => "hello-wasm",
               "version" => "1.2.3"
             })

    assert import.source_oci_ref == "registry.carverauto.dev/serviceradar/wasm-plugin-hello-wasm:v1.2.3"
    assert import.source_oci_digest == oci_manifest_digest()
    assert import.source_metadata["cosign_verified"] == true

    assert Process.get(:cosign_verified_artifact) ==
             {import.source_oci_ref, oci_manifest_digest()}
  end

  test "uses Docker registry credentials to answer OCI bearer challenges" do
    Application.put_env(:serviceradar_web_ng, :first_party_plugin_import_http_client, OciClient)
    Application.put_env(:serviceradar_web_ng, :first_party_plugin_cosign_verifier, FakeCosignVerifier)

    Application.put_env(:serviceradar_web_ng, :first_party_plugin_import,
      registry_docker_config_json:
        Jason.encode!(%{
          "auths" => %{
            "registry.carverauto.dev" => %{"auth" => Base.encode64("robot:secret")}
          }
        })
    )

    Process.put(:first_party_registry_auth_challenge, true)

    assert {:ok, import} =
             FirstPartyImporter.import(%{
               "repo_url" => @repo_url,
               "release_tag" => "v1.2.3",
               "plugin_id" => "hello-wasm",
               "version" => "1.2.3"
             })

    assert import.source_oci_digest == oci_manifest_digest()
    assert Process.get(:registry_token_auth_header) == "Basic #{Base.encode64("robot:secret")}"
  end

  def release do
    %{
      "tag_name" => "v1.2.3",
      "name" => "ServiceRadar v1.2.3",
      "html_url" => "https://github.com/carverauto/serviceradar/releases/tag/v1.2.3",
      "assets" => [
        %{
          "name" => "serviceradar-wasm-plugin-index.json",
          "browser_download_url" =>
            "https://github.com/carverauto/serviceradar/releases/download/v1.2.3/serviceradar-wasm-plugin-index.json"
        }
      ]
    }
  end

  def index do
    %{
      "schema_version" => 1,
      "plugins" => [
        %{
          "plugin_id" => "hello-wasm",
          "name" => "Hello Wasm",
          "version" => "1.2.3",
          "bundle_url" => "https://github.com/carverauto/serviceradar/releases/download/v1.2.3/hello-wasm.zip",
          "upload_signature_url" =>
            "https://github.com/carverauto/serviceradar/releases/download/v1.2.3/hello-wasm.upload-signature.json",
          "bundle_digest" => Process.get(:first_party_bundle_digest_override) || Storage.sha256(bundle()),
          "oci_ref" => "registry.carverauto.dev/serviceradar/wasm-plugin-hello-wasm:v1.2.3"
        }
      ]
    }
  end

  @doc "The index shape a third-party repository publishes: assets, no OCI."
  def release_asset_index do
    index = index()
    [entry] = index["plugins"]
    %{index | "plugins" => [Map.delete(entry, "oci_ref")]}
  end

  def oci_index do
    %{
      "schema_version" => 1,
      "plugins" => [
        %{
          "plugin_id" => "hello-wasm",
          "name" => "Hello Wasm",
          "version" => "1.2.3",
          "oci_ref" => "registry.carverauto.dev/serviceradar/wasm-plugin-hello-wasm:v1.2.3",
          "oci_digest" => oci_manifest_digest(),
          "bundle_digest" => Storage.sha256(bundle()),
          "upload_signature_digest" => Storage.sha256(Jason.encode!(upload_signature()))
        }
      ]
    }
  end

  def oci_manifest_digest, do: "sha256:" <> String.duplicate("b", 64)

  def oci_manifest do
    %{
      "schemaVersion" => 2,
      "mediaType" => "application/vnd.oci.image.manifest.v1+json",
      "layers" => [
        %{
          "mediaType" => "application/zip",
          "digest" => "sha256:bundle-layer",
          "size" => byte_size(bundle())
        },
        %{
          "mediaType" => "application/vnd.serviceradar.wasm-plugin.upload-signature.v1+json",
          "digest" => "sha256:signature-layer",
          "size" => byte_size(Jason.encode!(upload_signature()))
        }
      ]
    }
  end

  def bundle do
    case Process.get(:first_party_bundle) do
      nil ->
        payload = bundle_with_entries([])
        Process.put(:first_party_bundle, payload)
        payload

      payload ->
        payload
    end
  end

  def bundle_with_entries(extra_entries) do
    path = Path.join(System.tmp_dir!(), "hello-wasm-#{System.unique_integer([:positive])}.zip")

    try do
      base_entries =
        [
          {~c"plugin.yaml", @manifest_yaml},
          {~c"plugin.wasm", @wasm},
          {~c"config.schema.json", Jason.encode!(%{"type" => "object"})},
          {~c"display_contract.json", Jason.encode!(%{"schema_version" => 1})},
          {~c"display/event_log_activity.display.json", Jason.encode!(@display_contract)},
          {~c"schemas/ocsf_event_log_activity.schema.json", Jason.encode!(%{"type" => "object"})}
        ]

      replacement_names = MapSet.new(extra_entries, fn {name, _payload} -> to_string(name) end)
      base_entries = Enum.reject(base_entries, fn {name, _payload} -> to_string(name) in replacement_names end)

      {:ok, _zip} =
        :zip.create(
          String.to_charlist(path),
          base_entries ++ extra_entries
        )

      File.read!(path)
    after
      File.rm(path)
    end
  end

  def upload_signature do
    case Process.get(:first_party_signature) do
      nil ->
        signature =
          @manifest
          |> UploadSignature.verification_payload(Storage.sha256(@wasm))
          |> then(&:crypto.sign(:eddsa, :none, &1, [Process.get(:first_party_private_key), :ed25519]))
          |> Base.encode64()

        payload = %{
          "algorithm" => "ed25519",
          "key_id" => "test-signer",
          "signature" => signature
        }

        Process.put(:first_party_signature, payload)
        payload

      payload ->
        payload
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:serviceradar_web_ng, key)
  defp restore_env(key, value), do: Application.put_env(:serviceradar_web_ng, key, value)
end
