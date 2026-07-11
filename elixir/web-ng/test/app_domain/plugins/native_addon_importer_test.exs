defmodule ServiceRadarWebNG.Plugins.NativeAddonImporterTest do
  @moduledoc """
  End-to-end test for the web-ng native add-on import orchestration (issue 3425,
  add-native-addon-build-signing §4.1). A fake `ForgejoOciClient` HTTP backend
  serves a release, the `serviceradar-native-addon-index.json` asset, the OCI
  manifest, and the bundle + per-arch tarball/signature blobs by digest; Cosign and
  the datasvc upload are stubbed. The real `ServiceRadar.Plugins.NativeAddonImporter`
  core then verifies each tarball's sha256 + agent-release ed25519 signature, mirrors
  it, and persists a staged `AddonPackage`. Mirrors `first_party_importer_test.exs`
  for the Wasm path.
  """

  use ServiceRadarWebNG.DataCase, async: false

  import ExUnit.CaptureLog

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Plugins.AddonPackage
  alias ServiceRadar.Plugins.NativeAddonArtifactMirror
  alias ServiceRadarWebNG.Plugins.AddonPackages
  alias ServiceRadarWebNG.Plugins.NativeAddonImporter
  alias ServiceRadarWebNG.Plugins.NativeAddonSyncWorker

  require Ash.Query

  @repo_url "https://code.carverauto.dev/carverauto/serviceradar"
  @index_asset_name "serviceradar-native-addon-index.json"
  @oci_repository "serviceradar/native-addon-sample"
  @oci_ref "registry.carverauto.dev/#{@oci_repository}:v1.0.0"
  @oci_digest "sha256:" <> String.duplicate("a", 64)

  @manifest_yaml """
  id: sample-addon
  name: Sample Addon
  version: 1.0.0
  kind: native
  delivery: pushed-artifact
  supervision: agent-sidecar
  capabilities:
    - submit_result
  exec:
    binary: serviceradar-sample-addon
    install_path: /usr/local/lib/serviceradar/bin
  requires: {}
  """

  defmodule FakeCosignVerifier do
    @moduledoc false

    def verify(%{ref: ref, digest: digest}) do
      Process.put(:native_addon_cosign_verified, {ref, digest})
      :ok
    end
  end

  defmodule FakeOciClient do
    @moduledoc false

    def get(url, _opts) do
      cond do
        String.contains?(url, "/api/v1/repos/carverauto/serviceradar/releases/tags/v1.0.0") ->
          {:ok, %Req.Response{status: 200, body: Process.get(:native_addon_release)}}

        String.contains?(url, "/api/v1/repos/carverauto/serviceradar/releases?per_page=") ->
          {:ok, %Req.Response{status: 200, body: Process.get(:native_addon_recent_releases, [])}}

        String.ends_with?(url, "/serviceradar-native-addon-index.json") ->
          {:ok, %Req.Response{status: 200, body: Process.get(:native_addon_index_body)}}

        String.contains?(url, "/manifests/") ->
          Process.put(
            :native_addon_manifest_requests,
            Process.get(:native_addon_manifest_requests, 0) + 1
          )

          {:ok,
           %Req.Response{
             status: Process.get(:native_addon_manifest_status, 200),
             body: Process.get(:native_addon_manifest),
             headers: %{"docker-content-digest" => [Process.get(:native_addon_oci_digest)]}
           }}

        blob = blob_for(url) ->
          {:ok, %Req.Response{status: 200, body: blob}}

        true ->
          {:ok, %Req.Response{status: 404, body: ""}}
      end
    end

    defp blob_for(url) do
      case Regex.run(~r{/blobs/(.+)$}, url) do
        [_full, digest] -> Map.get(Process.get(:native_addon_blobs, %{}), digest)
        _ -> nil
      end
    end
  end

  setup do
    original_logger_level = Logger.level()
    original_http_client = Application.get_env(:serviceradar_web_ng, :first_party_plugin_import_http_client)
    original_cosign = Application.get_env(:serviceradar_web_ng, :first_party_plugin_cosign_verifier)
    original_public_key = Application.get_env(:serviceradar_web_ng, :native_addon_release_public_key)
    original_upload = Application.get_env(:serviceradar_web_ng, :native_addon_artifact_upload)
    original_native_addon_import = Application.get_env(:serviceradar_web_ng, :native_addon_import)

    {public_key, private_key} = :crypto.generate_key(:eddsa, :ed25519)
    test_pid = self()

    Logger.configure(level: :info)

    Application.put_env(:serviceradar_web_ng, :first_party_plugin_import_http_client, FakeOciClient)
    Application.put_env(:serviceradar_web_ng, :first_party_plugin_cosign_verifier, FakeCosignVerifier)
    Application.put_env(:serviceradar_web_ng, :native_addon_release_public_key, Base.encode16(public_key, case: :lower))

    Application.put_env(:serviceradar_web_ng, :native_addon_artifact_upload, fn metadata, data, _opts ->
      send(test_pid, {:uploaded, metadata.key, byte_size(data)})
      {:ok, %{key: metadata.key}}
    end)

    on_exit(fn ->
      Logger.configure(level: original_logger_level)
      restore_env(:first_party_plugin_import_http_client, original_http_client)
      restore_env(:first_party_plugin_cosign_verifier, original_cosign)
      restore_env(:native_addon_release_public_key, original_public_key)
      restore_env(:native_addon_artifact_upload, original_upload)
      restore_env(:native_addon_import, original_native_addon_import)
    end)

    {:ok, public_key: public_key, private_key: private_key}
  end

  test "imports a verified native add-on into a staged AddonPackage", %{private_key: private_key} do
    install_fixtures(private_key)

    assert {:ok, package} =
             NativeAddonImporter.import(%{
               "repo_url" => @repo_url,
               "release_tag" => "v1.0.0",
               "addon_id" => "sample-addon",
               "version" => "1.0.0"
             })

    assert package.addon_id == "sample-addon"
    assert package.version == "1.0.0"
    assert package.name == "Sample Addon"
    assert package.status == :staged
    assert package.kind == :native
    assert package.delivery == :pushed_artifact
    assert package.supervision == :agent_sidecar
    assert package.binary == "serviceradar-sample-addon"
    assert package.source_oci_ref == @oci_ref
    assert package.source_oci_digest == @oci_digest
    assert package.source_release_tag == "v1.0.0"
    assert package.verification_status == "verified"

    artifact = package.artifacts["linux/amd64"]
    assert is_map(artifact)
    assert artifact["sha256"] == tarball_sha256()
    assert artifact["signature"] == signature_hex(private_key)

    expected_key =
      NativeAddonArtifactMirror.object_key("sample-addon", "1.0.0", "linux", "amd64", tarball_sha256())

    assert artifact["object_key"] == expected_key

    # Cosign was consulted on the manifest digest before any blob was pulled,
    # and the verified tarball was mirrored through the injected upload.
    assert Process.get(:native_addon_cosign_verified) == {@oci_ref, @oci_digest}
    assert_received {:uploaded, ^expected_key, size}
    assert size == byte_size(tarball())
  end

  test "lists native add-ons from recent release indexes", %{private_key: private_key} do
    install_fixtures(private_key)

    assert {:ok, [addon]} = NativeAddonImporter.list_recent_addons(%{"repo_url" => @repo_url}, 10)

    assert addon.addon_id == "sample-addon"
    assert addon.version == "1.0.0"
    assert addon.release_tag == "v1.0.0"
    assert addon.repo_url == @repo_url
    assert addon.oci_ref == @oci_ref
    assert addon.oci_digest == @oci_digest
    assert addon.import_ready? == true
  end

  test "sync worker imports every discovered native add-on and only auto-approves configured ids", %{
    private_key: private_key
  } do
    install_fixtures(private_key)

    Application.put_env(:serviceradar_web_ng, :native_addon_import,
      repo_url: @repo_url,
      index_asset_name: @index_asset_name,
      auto_sync_enabled: false,
      addon_ids: ["not-a-catalog-gate"],
      auto_approve_addon_ids: ["sample-addon"],
      sync_release_limit: 10,
      sync_interval_seconds: 3_600
    )

    assert :ok = NativeAddonSyncWorker.perform(%Oban.Job{args: %{"force" => true, "limit" => 10}})

    actor = SystemActor.system(:native_addon_sync_test)

    assert {:ok, %AddonPackage{} = package} =
             AddonPackage
             |> Ash.Query.for_read(:read, %{}, actor: actor)
             |> Ash.Query.filter(addon_id == "sample-addon" and version == "1.0.0")
             |> Ash.read_one(actor: actor)

    assert package.status == :approved
    assert package.approved_by == "system:native_addon_sync"
    assert package.approved_capabilities == ["submit_result"]
    assert package.source_release_tag == "v1.0.0"
    assert is_map(package.artifacts["linux/amd64"])
  end

  test "sync worker keeps all incomplete jobs unique" do
    changes = NativeAddonSyncWorker.new(%{}).changes

    assert MapSet.new(changes.unique.states) ==
             MapSet.new([:available, :scheduled, :executing, :retryable, :suspended])

    assert NativeAddonSyncWorker.timeout(%Oban.Job{}) == to_timeout(minute: 10)
  end

  test "sync worker skips an exact verified package before fetching a removed historical manifest", %{
    private_key: private_key
  } do
    install_fixtures(private_key)
    configure_sync_worker()

    assert :ok = NativeAddonSyncWorker.perform(%Oban.Job{args: %{"force" => true, "limit" => 10}})

    Process.put(:native_addon_manifest_requests, 0)
    Process.put(:native_addon_manifest_status, 404)

    log =
      capture_log([level: :info], fn ->
        assert :ok =
                 NativeAddonSyncWorker.perform(%Oban.Job{
                   args: %{"force" => true, "limit" => 10}
                 })
      end)

    assert log =~ "import_ready=1 imported=0 skipped=1 failed=0"
    assert Process.get(:native_addon_manifest_requests) == 0
    assert length(sample_packages()) == 1
  end

  test "sync worker fetches a package that is missing locally", %{private_key: private_key} do
    install_fixtures(private_key)
    configure_sync_worker()
    Process.put(:native_addon_manifest_requests, 0)
    Process.put(:native_addon_manifest_status, 404)

    log =
      capture_log([level: :info], fn ->
        assert :ok =
                 NativeAddonSyncWorker.perform(%Oban.Job{
                   args: %{"force" => true, "limit" => 10}
                 })
      end)

    assert log =~ "import_ready=1 imported=0 skipped=0 failed=1"
    assert Process.get(:native_addon_manifest_requests) == 1
    assert sample_packages() == []
  end

  test "sync worker reports an immutable source conflict instead of skipping or overwriting", %{
    private_key: private_key
  } do
    install_fixtures(private_key)
    configure_sync_worker()

    assert :ok = NativeAddonSyncWorker.perform(%Oban.Job{args: %{"force" => true, "limit" => 10}})
    [original] = sample_packages()

    changed_digest = "sha256:" <> String.duplicate("f", 64)

    Process.put(
      :native_addon_index_body,
      Jason.encode!(index_map(oci_digest: changed_digest))
    )

    Process.put(:native_addon_manifest_requests, 0)

    log =
      capture_log([level: :info], fn ->
        assert :ok =
                 NativeAddonSyncWorker.perform(%Oban.Job{
                   args: %{"force" => true, "limit" => 10}
                 })
      end)

    assert log =~ "import_ready=1 imported=0 skipped=0 failed=1"
    assert Process.get(:native_addon_manifest_requests) == 0

    [persisted] = sample_packages()
    assert persisted.id == original.id
    assert persisted.source_oci_digest == @oci_digest
  end

  test "sync_first_party_addons is idempotent: the second run skips already-imported packages", %{
    private_key: private_key
  } do
    install_fixtures(private_key)

    assert {:ok, first} =
             AddonPackages.sync_first_party_addons(
               repo_url: @repo_url,
               release_tag: "v1.0.0",
               limit: 10
             )

    assert first.imported == 1
    assert first.skipped == 0
    assert first.failed == []

    assert {:ok, second} =
             AddonPackages.sync_first_party_addons(
               repo_url: @repo_url,
               release_tag: "v1.0.0",
               limit: 10
             )

    assert second.imported == 0
    assert second.skipped == 1
    assert second.failed == []

    # Still exactly one package row for the entry — nothing was duplicated.
    actor = SystemActor.system(:native_addon_sync_test)

    packages =
      AddonPackage
      |> Ash.Query.for_read(:read, %{}, actor: actor)
      |> Ash.Query.filter(addon_id == "sample-addon" and version == "1.0.0")
      |> Ash.read!(actor: actor)

    assert length(packages) == 1
  end

  test "rejects a tarball signed with a key other than the release key" do
    {_pub, wrong_private_key} = :crypto.generate_key(:eddsa, :ed25519)
    install_fixtures(wrong_private_key)

    assert {:error, :invalid_signature} =
             NativeAddonImporter.import(%{
               "repo_url" => @repo_url,
               "release_tag" => "v1.0.0",
               "addon_id" => "sample-addon",
               "version" => "1.0.0"
             })

    refute_received {:uploaded, _key, _size}
  end

  test "rejects an index entry whose tarball digest is not in the cosign-verified manifest",
       %{private_key: private_key} do
    install_fixtures(private_key)

    # Point the entry's tarball at a digest absent from the manifest layers; the
    # web-ng layer must refuse to fetch a blob the verified manifest doesn't carry.
    index = index_map(orphan_tarball_digest: "sha256:" <> String.duplicate("f", 64))
    Process.put(:native_addon_index_body, Jason.encode!(index))

    assert {:error, {:digest_not_in_manifest, _digest}} =
             NativeAddonImporter.import(%{
               "repo_url" => @repo_url,
               "release_tag" => "v1.0.0",
               "addon_id" => "sample-addon",
               "version" => "1.0.0"
             })

    refute_received {:uploaded, _key, _size}
  end

  test "rejects a blob whose bytes do not match its manifest-declared digest", %{private_key: private_key} do
    install_fixtures(private_key)

    # The registry serves tampered bundle bytes under the (still manifest-declared)
    # bundle digest; membership passes but the content re-hash must reject it.
    blobs = Process.get(:native_addon_blobs)
    Process.put(:native_addon_blobs, Map.put(blobs, bundle_digest(), "tampered-bundle-bytes"))

    assert {:error, {:blob_digest_mismatch, _digest}} =
             NativeAddonImporter.import(%{
               "repo_url" => @repo_url,
               "release_tag" => "v1.0.0",
               "addon_id" => "sample-addon",
               "version" => "1.0.0"
             })

    refute_received {:uploaded, _key, _size}
  end

  # --- fixtures -----------------------------------------------------------------

  defp install_fixtures(private_key) do
    Process.put(:native_addon_private_key, private_key)
    Process.put(:native_addon_release, release())
    Process.put(:native_addon_recent_releases, [release()])
    Process.put(:native_addon_oci_digest, @oci_digest)
    Process.put(:native_addon_manifest_requests, 0)
    Process.put(:native_addon_manifest_status, 200)
    Process.put(:native_addon_manifest, oci_manifest())
    Process.put(:native_addon_index_body, Jason.encode!(index_map([])))

    Process.put(:native_addon_blobs, %{
      bundle_digest() => bundle(),
      tarball_digest() => tarball(),
      signature_digest(private_key) => signature_hex(private_key)
    })
  end

  defp release do
    %{
      "tag_name" => "v1.0.0",
      "name" => "ServiceRadar v1.0.0",
      "html_url" => "https://code.carverauto.dev/carverauto/serviceradar/releases/tag/v1.0.0",
      "assets" => [
        %{
          "name" => @index_asset_name,
          "browser_download_url" =>
            "https://code.carverauto.dev/carverauto/serviceradar/releases/download/v1.0.0/#{@index_asset_name}"
        }
      ]
    }
  end

  defp index_map(opts) do
    private_key = Process.get(:native_addon_private_key)
    tarball_digest = Keyword.get(opts, :orphan_tarball_digest, tarball_digest())
    oci_digest = Keyword.get(opts, :oci_digest, @oci_digest)

    %{
      "schema_version" => 1,
      "addons" => [
        %{
          "addon_id" => "sample-addon",
          "version" => "1.0.0",
          "oci_ref" => @oci_ref,
          "oci_digest" => oci_digest,
          "bundle_digest" => bundle_digest(),
          "artifacts" => [
            %{
              "os" => "linux",
              "arch" => "amd64",
              "tarball_digest" => tarball_digest,
              "signature_digest" => signature_digest(private_key),
              "tarball_sha256" => tarball_sha256()
            }
          ]
        }
      ]
    }
  end

  defp oci_manifest do
    %{
      "schemaVersion" => 2,
      "mediaType" => "application/vnd.oci.image.manifest.v1+json",
      "layers" => [
        %{"mediaType" => "application/zip", "digest" => bundle_digest(), "size" => byte_size(bundle())},
        %{
          "mediaType" => "application/vnd.serviceradar.native-addon.artifact.v1+gzip",
          "digest" => tarball_digest(),
          "size" => byte_size(tarball())
        },
        %{
          "mediaType" => "application/vnd.serviceradar.native-addon.artifact-signature.v1+hex",
          "digest" => signature_digest(Process.get(:native_addon_private_key)),
          "size" => byte_size(signature_hex(Process.get(:native_addon_private_key)))
        }
      ]
    }
  end

  defp bundle do
    case Process.get(:native_addon_bundle) do
      nil ->
        path = Path.join(System.tmp_dir!(), "sr-native-addon-#{System.unique_integer([:positive])}.zip")

        try do
          {:ok, _zip} =
            :zip.create(String.to_charlist(path), [
              {~c"addon.yaml", @manifest_yaml},
              {~c"config.schema.json", Jason.encode!(%{"type" => "object"})}
            ])

          payload = File.read!(path)
          Process.put(:native_addon_bundle, payload)
          payload
        after
          File.rm(path)
        end

      payload ->
        payload
    end
  end

  defp tarball, do: "fake-linux-amd64-native-addon-tarball-bytes"

  defp tarball_sha256, do: :sha256 |> :crypto.hash(tarball()) |> Base.encode16(case: :lower)

  defp signature_hex(private_key) do
    :eddsa
    |> :crypto.sign(:none, tarball(), [private_key, :ed25519])
    |> Base.encode16(case: :lower)
  end

  defp bundle_digest, do: digest(bundle())
  defp tarball_digest, do: digest(tarball())
  defp signature_digest(private_key), do: digest(signature_hex(private_key))

  defp digest(bytes), do: "sha256:" <> (:sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower))

  defp configure_sync_worker do
    Application.put_env(:serviceradar_web_ng, :native_addon_import,
      repo_url: @repo_url,
      index_asset_name: @index_asset_name,
      auto_sync_enabled: false,
      auto_approve_addon_ids: ["sample-addon"],
      sync_release_limit: 10,
      sync_interval_seconds: 3_600
    )
  end

  defp sample_packages do
    actor = SystemActor.system(:native_addon_sync_test)

    AddonPackage
    |> Ash.Query.for_read(:read, %{}, actor: actor)
    |> Ash.Query.filter(addon_id == "sample-addon" and version == "1.0.0")
    |> Ash.read!(actor: actor)
  end

  defp restore_env(key, nil), do: Application.delete_env(:serviceradar_web_ng, key)
  defp restore_env(key, value), do: Application.put_env(:serviceradar_web_ng, key, value)
end
