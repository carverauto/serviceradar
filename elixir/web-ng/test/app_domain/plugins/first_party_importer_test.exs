defmodule ServiceRadarWebNG.Plugins.FirstPartyImporterTest do
  use ExUnit.Case, async: false

  alias ServiceRadarWebNG.Plugins.FirstPartyImporter
  alias ServiceRadarWebNG.Plugins.Storage
  alias ServiceRadarWebNG.Plugins.UploadSignature

  @repo_url "https://code.carverauto.dev/carverauto/serviceradar"
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

  defmodule ForgejoClient do
    @moduledoc false

    alias ServiceRadarWebNG.Plugins.FirstPartyImporterTest

    def get(url, _opts) do
      cond do
        String.contains?(url, "/api/v1/repos/carverauto/serviceradar/releases?per_page=") ->
          releases =
            if Process.get(:first_party_releases_without_index) do
              [%{"tag_name" => "v1.2.3", "assets" => []}]
            else
              [FirstPartyImporterTest.release()]
            end

          {:ok, %Req.Response{status: 200, body: releases}}

        String.contains?(url, "/api/v1/repos/carverauto/serviceradar/releases/tags/v1.2.3") ->
          {:ok, %Req.Response{status: 200, body: FirstPartyImporterTest.release()}}

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

    def get(url, _opts) do
      cond do
        String.contains?(url, "/api/v1/repos/carverauto/serviceradar/releases?per_page=") ->
          ForgejoClient.get(url, [])

        String.contains?(url, "/api/v1/repos/carverauto/serviceradar/releases/tags/v1.2.3") ->
          ForgejoClient.get(url, [])

        String.ends_with?(url, "/serviceradar-wasm-plugin-index.json") ->
          {:ok, %Req.Response{status: 200, body: Jason.encode!(FirstPartyImporterTest.oci_index())}}

        String.ends_with?(url, "/v2/serviceradar/wasm-plugin-hello-wasm/manifests/v1.2.3") ->
          {:ok,
           %Req.Response{
             status: 200,
             body: FirstPartyImporterTest.oci_manifest(),
             headers: %{"docker-content-digest" => [FirstPartyImporterTest.oci_manifest_digest()]}
           }}

        String.ends_with?(url, "/v2/serviceradar/wasm-plugin-hello-wasm/blobs/sha256:bundle-layer") ->
          {:ok, %Req.Response{status: 200, body: FirstPartyImporterTest.bundle()}}

        String.ends_with?(url, "/v2/serviceradar/wasm-plugin-hello-wasm/blobs/sha256:signature-layer") ->
          {:ok, %Req.Response{status: 200, body: Jason.encode!(FirstPartyImporterTest.upload_signature())}}

        true ->
          {:ok, %Req.Response{status: 404, body: ""}}
      end
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
    original_cosign_verifier = Application.get_env(:serviceradar_web_ng, :first_party_plugin_cosign_verifier)
    original_storage = Application.get_env(:serviceradar_web_ng, :plugin_storage)
    {public_key, private_key} = :crypto.generate_key(:eddsa, :ed25519)
    tmp = Path.join(System.tmp_dir!(), "sr-first-party-plugin-test-#{System.unique_integer([:positive])}")

    Application.put_env(:serviceradar_web_ng, :plugin_verification,
      require_gpg_for_github: false,
      allow_unsigned_uploads: false,
      trusted_upload_signing_keys: %{"test-signer" => Base.encode64(public_key)}
    )

    Application.put_env(:serviceradar_web_ng, :first_party_plugin_import_http_client, ForgejoClient)

    Application.put_env(:serviceradar_web_ng, :plugin_storage,
      backend: :filesystem,
      base_path: tmp,
      signing_secret: "test-secret"
    )

    Process.put(:first_party_private_key, private_key)
    Process.put(:first_party_bundle, nil)
    Process.put(:first_party_bundle_digest_override, nil)
    Process.put(:first_party_index_body, nil)
    Process.put(:first_party_bundle_redirect, false)
    Process.put(:first_party_signature, nil)
    Process.put(:cosign_verified_artifact, nil)
    Process.put(:first_party_releases_without_index, false)

    on_exit(fn ->
      File.rm_rf(tmp)
      restore_env(:plugin_verification, original_verification)
      restore_env(:first_party_plugin_import_http_client, original_import_client)
      restore_env(:first_party_plugin_cosign_verifier, original_cosign_verifier)
      restore_env(:plugin_storage, original_storage)
    end)

    :ok
  end

  test "lists import-ready plugins from the Forgejo release index" do
    assert {:ok, [plugin]} = FirstPartyImporter.list_recent_plugins(%{"repo_url" => @repo_url}, 10)
    assert plugin.plugin_id == "hello-wasm"
    assert plugin.version == "1.2.3"
    assert plugin.release_tag == "v1.2.3"
    assert plugin.import_ready?
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
    assert {:error, "Forgejo repository URL must look like https://code.carverauto.dev/<owner>/<repo>"} =
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

  def release do
    %{
      "tag_name" => "v1.2.3",
      "name" => "ServiceRadar v1.2.3",
      "html_url" => "https://code.carverauto.dev/carverauto/serviceradar/releases/tag/v1.2.3",
      "assets" => [
        %{
          "name" => "serviceradar-wasm-plugin-index.json",
          "browser_download_url" =>
            "https://code.carverauto.dev/carverauto/serviceradar/releases/download/v1.2.3/serviceradar-wasm-plugin-index.json"
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
          "bundle_url" => "https://code.carverauto.dev/carverauto/serviceradar/releases/download/v1.2.3/hello-wasm.zip",
          "upload_signature_url" =>
            "https://code.carverauto.dev/carverauto/serviceradar/releases/download/v1.2.3/hello-wasm.upload-signature.json",
          "bundle_digest" => Process.get(:first_party_bundle_digest_override) || Storage.sha256(bundle()),
          "oci_ref" => "registry.carverauto.dev/serviceradar/wasm-plugin-hello-wasm:v1.2.3"
        }
      ]
    }
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
        path = Path.join(System.tmp_dir!(), "hello-wasm-#{System.unique_integer([:positive])}.zip")

        try do
          {:ok, _zip} =
            :zip.create(String.to_charlist(path), [
              {~c"plugin.yaml", @manifest_yaml},
              {~c"plugin.wasm", @wasm},
              {~c"config.schema.json", Jason.encode!(%{"type" => "object"})},
              {~c"display_contract.json", Jason.encode!(%{"schema_version" => 1})}
            ])

          payload = File.read!(path)
          Process.put(:first_party_bundle, payload)
          payload
        after
          File.rm(path)
        end

      payload ->
        payload
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
