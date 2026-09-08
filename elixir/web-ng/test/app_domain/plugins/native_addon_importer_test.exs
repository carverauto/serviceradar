defmodule ServiceRadarWebNG.Plugins.NativeAddonImporterTest do
  @moduledoc """
  End-to-end test for the web-ng native add-on import orchestration (issue 3425,
  add-native-addon-build-signing §4.1). A fake `FirstPartyReleaseClient` HTTP backend
  serves a release, the `serviceradar-native-addon-index.json` asset, the OCI
  manifest, and the bundle + per-arch tarball/signature blobs by digest; Cosign and
  the datasvc upload are stubbed. The real `ServiceRadar.Plugins.NativeAddonImporter`
  core then verifies each tarball's sha256 + agent-release ed25519 signature, mirrors
  it, and persists a staged `AddonPackage`. Mirrors `first_party_importer_test.exs`
  for the Wasm path.
  """

  use ServiceRadarWebNG.DataCase, async: false

  import Ecto.Query
  import ExUnit.CaptureLog

  alias Oban.Job
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Plugins.AddonPackage
  alias ServiceRadar.Plugins.NativeAddonArtifactMirror
  alias ServiceRadar.Repo
  alias ServiceRadarWebNG.Plugins.AddonPackages
  alias ServiceRadarWebNG.Plugins.NativeAddonImporter
  alias ServiceRadarWebNG.Plugins.NativeAddonSyncWorker

  require Ash.Query

  @repo_url "https://github.com/carverauto/serviceradar"
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
        String.contains?(url, "api.github.com/repos/carverauto/serviceradar/releases/tags/v1.0.0") ->
          {:ok, %Req.Response{status: 200, body: Process.get(:native_addon_release)}}

        String.contains?(url, "api.github.com/repos/carverauto/serviceradar/releases?per_page=") ->
          Process.put(
            :native_addon_recent_release_requests,
            Process.get(:native_addon_recent_release_requests, 0) + 1
          )

          Process.get(:native_addon_recent_releases_result) ||
            {:ok, %Req.Response{status: 200, body: Process.get(:native_addon_recent_releases, [])}}

        String.ends_with?(url, "/serviceradar-native-addon-index.json") ->
          {:ok, %Req.Response{status: 200, body: Process.get(:native_addon_index_body)}}

        String.contains?(url, "/manifests/") ->
          Process.put(
            :native_addon_manifest_requests,
            Process.get(:native_addon_manifest_requests, 0) + 1
          )

          Process.get(:native_addon_manifest_result) ||
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
    assert artifact["signature_digest"] == signature_digest(private_key, "amd64")

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

  test "lists native add-ons from an exact release without consulting recent releases", %{
    private_key: private_key
  } do
    install_fixtures(private_key)
    Process.put(:native_addon_recent_releases, [])
    Process.put(:native_addon_recent_release_requests, 0)

    assert {:ok, [addon]} =
             NativeAddonImporter.list_release_addons(%{"repo_url" => @repo_url}, "v1.0.0")

    assert addon.addon_id == "sample-addon"
    assert addon.version == "1.0.0"
    assert addon.release_tag == "v1.0.0"
    assert Process.get(:native_addon_recent_release_requests) == 0
  end

  test "sync worker anchors automatic discovery to the deployed release", %{
    private_key: private_key
  } do
    install_fixtures(private_key)
    configure_sync_worker()
    Process.put(:native_addon_recent_releases, [])
    Process.put(:native_addon_recent_release_requests, 0)
    original_release_version = System.get_env("SERVICERADAR_RELEASE_VERSION")
    System.put_env("SERVICERADAR_RELEASE_VERSION", "v1.0.0")

    on_exit(fn -> restore_system_env("SERVICERADAR_RELEASE_VERSION", original_release_version) end)

    assert :ok = NativeAddonSyncWorker.perform(%Job{args: %{"force" => true}})
    assert Process.get(:native_addon_recent_release_requests) == 0
    assert [%AddonPackage{source_release_tag: "v1.0.0"}] = sample_packages()
  end

  test "sync worker falls back to recent releases when the deployed tag is unpublished", %{
    private_key: private_key
  } do
    install_fixtures(private_key)
    configure_sync_worker()
    Process.put(:native_addon_recent_release_requests, 0)
    original_release_version = System.get_env("SERVICERADAR_RELEASE_VERSION")
    System.put_env("SERVICERADAR_RELEASE_VERSION", "v1.4.51")

    on_exit(fn -> restore_system_env("SERVICERADAR_RELEASE_VERSION", original_release_version) end)

    assert :ok = NativeAddonSyncWorker.perform(%Job{args: %{"force" => true}})
    assert Process.get(:native_addon_recent_release_requests) >= 1
    assert [%AddonPackage{source_release_tag: "v1.0.0"}] = sample_packages()
  end

  test "sync worker does not fail the job when GitHub has no native add-on catalog", %{
    private_key: private_key
  } do
    install_fixtures(private_key)
    configure_sync_worker()
    Process.put(:native_addon_recent_releases_result, {:ok, %Req.Response{status: 404, body: ""}})
    original_release_version = System.get_env("SERVICERADAR_RELEASE_VERSION")
    System.put_env("SERVICERADAR_RELEASE_VERSION", "v1.4.51")

    on_exit(fn -> restore_system_env("SERVICERADAR_RELEASE_VERSION", original_release_version) end)

    assert :ok = NativeAddonSyncWorker.perform(%Job{args: %{"force" => true}})
    assert [] = sample_packages()
  end

  test "sync worker does not fail the job when the deployed release publishes no add-on index", %{
    private_key: private_key
  } do
    install_fixtures(private_key)
    configure_sync_worker()
    Process.put(:native_addon_release, Map.put(release(), "assets", []))
    Process.put(:native_addon_recent_release_requests, 0)
    original_release_version = System.get_env("SERVICERADAR_RELEASE_VERSION")
    System.put_env("SERVICERADAR_RELEASE_VERSION", "v1.0.0")

    on_exit(fn -> restore_system_env("SERVICERADAR_RELEASE_VERSION", original_release_version) end)

    assert :ok = NativeAddonSyncWorker.perform(%Job{args: %{"force" => true}})
    assert Process.get(:native_addon_recent_release_requests) == 0
    assert [] = sample_packages()
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

    assert :ok = NativeAddonSyncWorker.perform(%Job{args: %{"force" => true, "limit" => 10}})

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

  test "a concurrent incomplete row is repaired and auto-approved by policy", %{
    private_key: private_key
  } do
    install_fixtures(private_key)

    assert {:ok, [addon]} =
             NativeAddonImporter.list_recent_addons(%{"repo_url" => @repo_url}, 10)

    actor = SystemActor.system(:native_addon_sync_test)
    test_pid = self()

    Application.put_env(
      :serviceradar_web_ng,
      :native_addon_artifact_upload,
      fn metadata, data, _opts ->
        seeded =
          case Process.get(:native_addon_race_package) do
            nil ->
              package =
                AddonPackage
                |> Ash.Changeset.for_create(
                  :create,
                  %{
                    addon_id: "sample-addon",
                    version: "1.0.0",
                    name: "Concurrent incomplete import",
                    source_type: :first_party,
                    source_oci_ref: nil,
                    source_oci_digest: nil,
                    artifacts: %{},
                    verification_status: "partial",
                    verification_error: "artifact mirror incomplete"
                  },
                  actor: actor
                )
                |> Ash.create!()

              Process.put(:native_addon_race_package, package)
              package

            package ->
              package
          end

        send(test_pid, {:race_package_seeded, seeded.id})
        send(test_pid, {:uploaded, metadata.key, byte_size(data)})
        {:ok, %{key: metadata.key}}
      end
    )

    assert {:ok, repaired, :imported} =
             AddonPackages.import_first_party_addon(addon,
               auto_approve_addon_ids: ["sample-addon"]
             )

    assert %AddonPackage{} = seeded = Process.get(:native_addon_race_package)
    assert_received {:race_package_seeded, seeded_id}
    assert seeded_id == seeded.id
    assert repaired.id == seeded.id
    assert repaired.status == :approved
    assert repaired.verification_status == "verified"
    assert is_nil(repaired.verification_error)
    assert repaired.source_oci_ref == @oci_ref
    assert repaired.source_oci_digest == @oci_digest
    assert repaired.approved_by == "system:native_addon_sync"
    assert repaired.approved_capabilities == ["submit_result"]
    assert is_map(repaired.artifacts["linux/amd64"])

    Process.put(:native_addon_manifest_requests, 0)
    Process.put(:native_addon_manifest_status, 404)

    assert {:ok, reused, :skipped} = AddonPackages.import_first_party_addon(addon)
    assert reused.id == seeded.id
    assert reused.status == :approved
    assert Process.get(:native_addon_manifest_requests) == 0
  end

  test "sync worker default uniqueness remains valid for Oban 2.23" do
    changes = NativeAddonSyncWorker.new(%{}).changes

    assert MapSet.new(changes.unique.states) ==
             MapSet.new([:available, :scheduled, :executing, :retryable, :suspended])

    assert NativeAddonSyncWorker.timeout(%Job{}) == to_timeout(minute: 10)
  end

  test "periodic sync queues its successor while the current job is executing", %{
    private_key: private_key
  } do
    install_fixtures(private_key)
    configure_sync_worker(auto_sync_enabled: true)
    Process.put(:native_addon_recent_releases, [])

    executing = insert_executing_sync_job!()
    assert Keyword.fetch!(Application.fetch_env!(:serviceradar_web_ng, :native_addon_import), :auto_sync_enabled)

    assert :ok = NativeAddonSyncWorker.perform(%{executing | args: %{}})

    worker_jobs =
      Repo.all(
        from(job in Job,
          where: job.worker == ^inspect(NativeAddonSyncWorker),
          order_by: [asc: job.id]
        )
      )

    successor = Enum.find(worker_jobs, &(&1.id != executing.id and &1.state == "scheduled"))

    assert successor,
           "expected a scheduled successor, got: #{inspect(Enum.map(worker_jobs, &{&1.id, &1.state, &1.conflict?}))}"

    refute successor.conflict?
    assert DateTime.after?(successor.scheduled_at, DateTime.utc_now())
  end

  test "bootstrap recognizes an executing periodic job while manual sync remains available" do
    executing = insert_executing_sync_job!()

    assert {:ok, :already_scheduled} = NativeAddonSyncWorker.ensure_scheduled()

    assert {:ok, manual} = NativeAddonSyncWorker.enqueue_now(limit: 1)
    refute manual.conflict?
    assert manual.id != executing.id
    assert manual.state == "available"
  end

  test "a suspended manual sync does not suppress periodic bootstrap" do
    manual = insert_sync_job!("suspended", %{"force" => true, "limit" => 1})

    assert {:ok, bootstrap} = NativeAddonSyncWorker.ensure_scheduled()
    refute bootstrap.conflict?
    assert bootstrap.id != manual.id
    assert bootstrap.state == "scheduled"
    refute Map.get(bootstrap.args, "force")

    assert {:ok, :already_scheduled} = NativeAddonSyncWorker.ensure_scheduled()
  end

  test "manual sync uniqueness blocks overlap while one is executing" do
    executing = insert_executing_sync_job!(%{"force" => true, "limit" => 1})

    assert {:ok, duplicate} = NativeAddonSyncWorker.enqueue_now(limit: 2)
    assert duplicate.conflict?
    assert duplicate.id == executing.id

    force_jobs =
      Repo.all(
        from(job in Job,
          where: job.worker == ^inspect(NativeAddonSyncWorker),
          where: fragment("COALESCE(?->>'force', 'false') = 'true'", job.args)
        )
      )

    assert Enum.map(force_jobs, & &1.id) == [executing.id]
  end

  test "a transient discovery failure does not enqueue a periodic successor" do
    configure_sync_worker(auto_sync_enabled: true)
    Process.put(:native_addon_recent_releases_result, {:error, :temporary_registry_failure})
    executing = insert_executing_sync_job!()

    assert {:error, :temporary_registry_failure} =
             NativeAddonSyncWorker.perform(%{executing | args: %{}})

    worker_jobs =
      Repo.all(
        from(job in Job,
          where: job.worker == ^inspect(NativeAddonSyncWorker),
          order_by: [asc: job.id]
        )
      )

    assert Enum.map(worker_jobs, & &1.id) == [executing.id]
  end

  test "sync worker skips an exact verified package before fetching a removed historical manifest", %{
    private_key: private_key
  } do
    install_fixtures(private_key)
    configure_sync_worker()

    assert :ok = NativeAddonSyncWorker.perform(%Job{args: %{"force" => true, "limit" => 10}})
    [package] = sample_packages()
    persisted = package.artifacts["linux/amd64"]

    assert persisted["signature"] == String.trim(signature_blob(private_key, "amd64"))
    assert persisted["signature_digest"] == signature_digest(private_key, "amd64")

    legacy_artifact = Map.delete(persisted, "signature_digest")

    update_sample_package!(package, %{
      artifacts: Map.put(package.artifacts, "linux/amd64", legacy_artifact)
    })

    Process.put(:native_addon_manifest_requests, 0)
    Process.put(:native_addon_manifest_status, 404)

    log =
      capture_sync_log(fn ->
        assert :ok =
                 NativeAddonSyncWorker.perform(%Job{
                   args: %{"force" => true, "limit" => 10}
                 })
      end)

    assert log =~ "import_ready=1 imported=0 skipped=1 failed=0"
    assert Process.get(:native_addon_manifest_requests) == 0
    assert length(sample_packages()) == 1
  end

  test "sync worker repairs a nonempty package and restores policy approval", %{
    private_key: private_key
  } do
    install_fixtures(private_key, platforms: ["amd64", "arm64"])
    configure_sync_worker()

    assert :ok = NativeAddonSyncWorker.perform(%Job{args: %{"force" => true, "limit" => 10}})
    [approved] = sample_packages()
    assert approved.status == :approved

    incomplete_artifacts = Map.delete(approved.artifacts, "linux/arm64")

    update_sample_package!(approved, %{
      artifacts: incomplete_artifacts,
      verification_error: "linux/arm64 mirror missing"
    })

    Process.put(:native_addon_manifest_requests, 0)

    log =
      capture_sync_log(fn ->
        assert :ok = NativeAddonSyncWorker.perform(%Job{args: %{"force" => true, "limit" => 10}})
      end)

    assert log =~ "import_ready=1 imported=1 skipped=0 failed=0"
    assert Process.get(:native_addon_manifest_requests) == 1

    [repaired] = sample_packages()
    assert repaired.status == :approved

    assert repaired.artifacts |> Map.keys() |> MapSet.new() ==
             MapSet.new(["linux/amd64", "linux/arm64"])

    assert is_nil(repaired.verification_error)
    assert repaired.approved_by == "system:native_addon_sync"
    assert repaired.approved_capabilities == ["submit_result"]
  end

  test "sync worker repairs an otherwise exact package with a verification error", %{
    private_key: private_key
  } do
    install_fixtures(private_key)
    configure_sync_worker()

    assert {:ok, package} =
             NativeAddonImporter.import(%{
               "repo_url" => @repo_url,
               "release_tag" => "v1.0.0",
               "addon_id" => "sample-addon",
               "version" => "1.0.0"
             })

    update_sample_package!(package, %{verification_error: "prior verification failed"})
    Process.put(:native_addon_manifest_requests, 0)

    log =
      capture_sync_log(fn ->
        assert :ok =
                 NativeAddonSyncWorker.perform(%Job{args: %{"force" => true, "limit" => 10}})
      end)

    assert log =~ "import_ready=1 imported=1 skipped=0 failed=0"
    assert Process.get(:native_addon_manifest_requests) == 1

    [repaired] = sample_packages()
    assert repaired.status == :approved
    assert is_nil(repaired.verification_error)
    assert repaired.artifacts == package.artifacts
  end

  for reviewed_status <- [:staged, :approved, :denied, :revoked] do
    test "a repaired #{reviewed_status} package preserves the authoritative review policy", %{
      private_key: private_key
    } do
      reviewed_status = unquote(reviewed_status)
      install_fixtures(private_key)
      configure_sync_worker(auto_approve_addon_ids: ["sample-addon"])

      assert {:ok, package} =
               NativeAddonImporter.import(%{
                 "repo_url" => @repo_url,
                 "release_tag" => "v1.0.0",
                 "addon_id" => "sample-addon",
                 "version" => "1.0.0"
               })

      package = move_package_to_status!(package, reviewed_status)

      corrupt_artifact =
        package.artifacts
        |> Map.fetch!("linux/amd64")
        |> Map.put("object_key", "native-addons/sample-addon/1.0.0/linux/amd64/corrupt.tar.gz")

      update_sample_package!(package, %{
        artifacts: Map.put(package.artifacts, "linux/amd64", corrupt_artifact)
      })

      assert :ok =
               NativeAddonSyncWorker.perform(%Job{args: %{"force" => true, "limit" => 10}})

      [repaired] = sample_packages()

      expected_status = expected_review_status(reviewed_status)

      assert repaired.status == expected_status

      if expected_status == :approved do
        assert repaired.approved_by == "system:native_addon_sync"
        assert repaired.approved_capabilities == ["submit_result"]
      else
        assert is_binary(repaired.denied_reason)
      end

      Process.put(:native_addon_manifest_requests, 0)

      log =
        capture_sync_log(fn ->
          assert :ok =
                   NativeAddonSyncWorker.perform(%Job{
                     args: %{"force" => true, "limit" => 10}
                   })
        end)

      assert log =~ "import_ready=1 imported=0 skipped=1 failed=0"
      assert Process.get(:native_addon_manifest_requests) == 0

      [stable] = sample_packages()
      assert stable.status == expected_status
    end
  end

  test "sync worker repairs a platform whose persisted tarball digest is wrong", %{
    private_key: private_key
  } do
    install_fixtures(private_key, platforms: ["amd64", "arm64"])
    configure_sync_worker()

    assert :ok = NativeAddonSyncWorker.perform(%Job{args: %{"force" => true, "limit" => 10}})
    [approved] = sample_packages()

    wrong_arm64 =
      approved.artifacts
      |> Map.fetch!("linux/arm64")
      |> Map.put("sha256", String.duplicate("0", 64))

    update_sample_package!(approved, %{
      artifacts: Map.put(approved.artifacts, "linux/arm64", wrong_arm64)
    })

    Process.put(:native_addon_manifest_requests, 0)

    log =
      capture_sync_log(fn ->
        assert :ok = NativeAddonSyncWorker.perform(%Job{args: %{"force" => true, "limit" => 10}})
      end)

    assert log =~ "import_ready=1 imported=1 skipped=0 failed=0"
    assert Process.get(:native_addon_manifest_requests) == 1

    [repaired] = sample_packages()
    assert repaired.status == :approved
    assert repaired.artifacts["linux/arm64"]["sha256"] == tarball_sha256("arm64")
  end

  test "sync worker repairs a platform whose persisted object key is wrong", %{
    private_key: private_key
  } do
    install_fixtures(private_key)
    configure_sync_worker()

    assert :ok = NativeAddonSyncWorker.perform(%Job{args: %{"force" => true, "limit" => 10}})
    [approved] = sample_packages()

    wrong_artifact =
      approved.artifacts
      |> Map.fetch!("linux/amd64")
      |> Map.put("object_key", "native-addons/sample-addon/1.0.0/linux/amd64/stale.tar.gz")

    update_sample_package!(approved, %{
      artifacts: Map.put(approved.artifacts, "linux/amd64", wrong_artifact)
    })

    Process.put(:native_addon_manifest_requests, 0)

    log =
      capture_sync_log(fn ->
        assert :ok = NativeAddonSyncWorker.perform(%Job{args: %{"force" => true, "limit" => 10}})
      end)

    assert log =~ "import_ready=1 imported=1 skipped=0 failed=0"
    assert Process.get(:native_addon_manifest_requests) == 1

    [repaired] = sample_packages()
    assert repaired.status == :approved

    assert repaired.artifacts["linux/amd64"]["object_key"] ==
             NativeAddonArtifactMirror.object_key(
               "sample-addon",
               "1.0.0",
               "linux",
               "amd64",
               tarball_sha256()
             )
  end

  test "sync worker repairs a mutated signature even when its persisted digest is stale", %{
    private_key: private_key
  } do
    install_fixtures(private_key)
    configure_sync_worker()

    assert :ok = NativeAddonSyncWorker.perform(%Job{args: %{"force" => true, "limit" => 10}})
    [approved] = sample_packages()

    mutated_artifact =
      approved.artifacts
      |> Map.fetch!("linux/amd64")
      |> Map.put("signature", String.duplicate("0", 128))

    update_sample_package!(approved, %{
      artifacts: Map.put(approved.artifacts, "linux/amd64", mutated_artifact)
    })

    Process.put(:native_addon_manifest_requests, 0)

    log =
      capture_sync_log(fn ->
        assert :ok = NativeAddonSyncWorker.perform(%Job{args: %{"force" => true, "limit" => 10}})
      end)

    assert log =~ "import_ready=1 imported=1 skipped=0 failed=0"
    assert Process.get(:native_addon_manifest_requests) == 1

    [repaired] = sample_packages()
    assert repaired.status == :approved
    assert repaired.artifacts["linux/amd64"]["signature"] == signature_hex(private_key)
    assert repaired.artifacts["linux/amd64"]["signature_digest"] == signature_digest(private_key, "amd64")
  end

  test "sync worker fetches a package that is missing locally", %{private_key: private_key} do
    install_fixtures(private_key)
    configure_sync_worker()
    Process.put(:native_addon_manifest_requests, 0)
    Process.put(:native_addon_manifest_status, 404)

    log =
      capture_sync_log(fn ->
        assert :ok =
                 NativeAddonSyncWorker.perform(%Job{
                   args: %{"force" => true, "limit" => 10}
                 })
      end)

    assert log =~ "import_ready=1 imported=0 skipped=0 failed=1"
    assert log =~ "First-party native add-on package sync failed"
    assert log =~ "addon_id=sample-addon"
    assert log =~ "addon_version=1.0.0"
    assert log =~ "reason={:oci_manifest_http_error, 404}"
    assert Process.get(:native_addon_manifest_requests) == 1
    assert sample_packages() == []
  end

  test "sync worker reports an immutable source conflict after verifying the discovered envelope", %{
    private_key: private_key
  } do
    install_fixtures(private_key)
    configure_sync_worker()

    assert :ok = NativeAddonSyncWorker.perform(%Job{args: %{"force" => true, "limit" => 10}})
    [original] = sample_packages()

    changed_digest = "sha256:" <> String.duplicate("f", 64)

    Process.put(
      :native_addon_index_body,
      Jason.encode!(index_map(oci_digest: changed_digest))
    )

    Process.put(:native_addon_manifest_requests, 0)

    log =
      capture_sync_log(fn ->
        assert :ok =
                 NativeAddonSyncWorker.perform(%Job{
                   args: %{"force" => true, "limit" => 10}
                 })
      end)

    assert log =~ "import_ready=1 imported=0 skipped=0 failed=1"
    assert Process.get(:native_addon_manifest_requests) == 1

    [persisted] = sample_packages()
    assert persisted.id == original.id
    assert persisted.source_oci_digest == @oci_digest
  end

  test "sync worker repairs missing source metadata once and then reuses it", %{
    private_key: private_key
  } do
    install_fixtures(private_key)
    configure_sync_worker(auto_approve_addon_ids: ["sample-addon"])

    assert :ok = NativeAddonSyncWorker.perform(%Job{args: %{"force" => true, "limit" => 10}})
    [approved] = sample_packages()
    assert approved.status == :approved

    update_sample_package!(approved, %{
      source_oci_ref: nil,
      source_oci_digest: nil
    })

    Process.put(:native_addon_manifest_requests, 0)

    repair_log =
      capture_sync_log(fn ->
        assert :ok = NativeAddonSyncWorker.perform(%Job{args: %{"force" => true, "limit" => 10}})
      end)

    assert repair_log =~ "import_ready=1 imported=1 skipped=0 failed=0"
    assert Process.get(:native_addon_manifest_requests) == 1

    [repaired] = sample_packages()
    assert repaired.id == approved.id
    assert repaired.status == :approved
    assert repaired.source_oci_ref == @oci_ref
    assert repaired.source_oci_digest == @oci_digest
    assert repaired.approved_by == "system:native_addon_sync"

    Process.put(:native_addon_manifest_requests, 0)
    Process.put(:native_addon_manifest_status, 404)

    reuse_log =
      capture_sync_log(fn ->
        assert :ok = NativeAddonSyncWorker.perform(%Job{args: %{"force" => true, "limit" => 10}})
      end)

    assert reuse_log =~ "import_ready=1 imported=0 skipped=1 failed=0"
    assert Process.get(:native_addon_manifest_requests) == 0

    [reused] = sample_packages()
    assert reused.id == repaired.id
    assert reused.status == :approved
    assert reused.source_oci_ref == @oci_ref
    assert reused.source_oci_digest == @oci_digest
  end

  test "sync worker preserves a partial mismatched provenance conflict after verification", %{
    private_key: private_key
  } do
    install_fixtures(private_key)
    configure_sync_worker()

    assert :ok = NativeAddonSyncWorker.perform(%Job{args: %{"force" => true, "limit" => 10}})
    [package] = sample_packages()

    wrong_digest = "sha256:" <> String.duplicate("e", 64)

    update_sample_package!(package, %{
      source_oci_ref: nil,
      source_oci_digest: wrong_digest
    })

    Process.put(:native_addon_manifest_requests, 0)

    log =
      capture_sync_log(fn ->
        assert :ok = NativeAddonSyncWorker.perform(%Job{args: %{"force" => true, "limit" => 10}})
      end)

    assert log =~ "import_ready=1 imported=0 skipped=0 failed=1"
    assert log =~ "native_addon_version_source_conflict"
    assert log =~ "addon_id=sample-addon"
    assert byte_size(log) < 1_500
    assert Process.get(:native_addon_manifest_requests) == 1

    [persisted] = sample_packages()
    assert is_nil(persisted.source_oci_ref)
    assert persisted.source_oci_digest == wrong_digest
  end

  test "sync worker logs a bounded package failure and preserves partial success", %{
    private_key: private_key
  } do
    install_fixtures(private_key)
    configure_sync_worker()

    assert :ok = NativeAddonSyncWorker.perform(%Job{args: %{"force" => true, "limit" => 10}})

    [sample_entry] = index_map([])["addons"]

    missing_entry =
      sample_entry
      |> Map.put("addon_id", "missing-addon")
      |> Map.put("oci_ref", "registry.carverauto.dev/serviceradar/missing-addon:v1.0.0")

    Process.put(
      :native_addon_index_body,
      Jason.encode!(%{"schema_version" => 1, "addons" => [sample_entry, missing_entry]})
    )

    Process.put(:native_addon_manifest_status, 404)
    Process.put(:native_addon_manifest_requests, 0)

    log =
      capture_sync_log(fn ->
        assert :ok = NativeAddonSyncWorker.perform(%Job{args: %{"force" => true, "limit" => 10}})
      end)

    assert log =~ "import_ready=2 imported=0 skipped=1 failed=1"
    assert log =~ "First-party native add-on package sync failed"
    assert log =~ "addon_id=missing-addon"
    assert log =~ "reason={:oci_manifest_http_error, 404}"
    assert byte_size(log) < 1_500
    assert Process.get(:native_addon_manifest_requests) == 1
    assert length(sample_packages()) == 1
  end

  test "sync worker recursively redacts secrets in discovery failures" do
    configure_sync_worker()

    private_key = "-----BEGIN OPENSSH PRIVATE KEY-----\nprivate-key-secret\n-----END OPENSSH PRIVATE KEY-----"

    secrets = [
      "api-token-secret",
      "password-secret",
      "private-key-secret",
      "inline-secret",
      "json-secret",
      "bearer-map-secret",
      "basic-map-secret",
      "client-secret-value",
      "access-key-value",
      "provider-bootstrap-secret",
      "raw-bearer-secret",
      "raw-basic-secret",
      "raw-github-token-secret",
      "url-user-secret",
      "url-password-secret",
      "url-token-secret",
      "query-token-secret",
      "query-api-key-secret"
    ]

    Process.put(
      :native_addon_recent_releases_result,
      {:error,
       {:transport,
        %{
          "Proxy-Authorization" => "Basic basic-map-secret",
          api_token: "api-token-secret",
          authorization: "Bearer bearer-map-secret",
          client_secret: "client-secret-value",
          access_key: "access-key-value",
          provider_bootstrap: "provider-bootstrap-secret",
          nested: [
            %{"password" => "password-secret"},
            %{private_key: private_key},
            "passphrase=inline-secret",
            ~s({"api_token":"json-secret"}),
            "Authorization: Bearer raw-bearer-secret",
            "Authorization=Basic raw-basic-secret",
            "Authorization: token raw-github-token-secret",
            "https://url-user-secret:url-password-secret@example.test/path",
            "https://url-token-secret@example.test/token-only",
            "https://example.test/path?access_token=query-token-secret&api_key=query-api-key-secret"
          ]
        }}}
    )

    log =
      capture_sync_log(fn ->
        assert {:error, {:transport, _details}} =
                 NativeAddonSyncWorker.perform(%Job{args: %{"force" => true, "limit" => 10}})
      end)

    assert log =~ "First-party native add-on sync failed"
    assert log =~ "REDACTED"

    Enum.each(secrets, fn secret ->
      refute log =~ secret
    end)

    assert byte_size(log) < 1_500
  end

  test "sync worker preserves keyed tuple context while redacting GitHub credentials" do
    configure_sync_worker()

    Process.put(
      :native_addon_recent_releases_result,
      {:error,
       {:transport,
        [
          {"authorization", "token GITHUB_SENTINEL"},
          {:api_token, "API_SENTINEL"}
        ]}}
    )

    log =
      capture_sync_log(fn ->
        assert {:error, {:transport, _details}} =
                 NativeAddonSyncWorker.perform(%Job{args: %{"force" => true, "limit" => 10}})
      end)

    assert log =~ "authorization"
    assert log =~ "api_token"
    assert log =~ "REDACTED"
    refute log =~ "GITHUB_SENTINEL"
    refute log =~ "API_SENTINEL"
    assert byte_size(log) < 1_500
  end

  test "sync worker sanitizes and bounds untrusted package metadata", %{
    private_key: private_key
  } do
    install_fixtures(private_key)
    configure_sync_worker()

    addon_secret = "addon-secret"
    version_secret = "version-secret"
    [sample_entry] = index_map([])["addons"]

    untrusted_entry =
      sample_entry
      |> Map.put("addon_id", "api_token=#{addon_secret}" <> String.duplicate("x", 600))
      |> Map.put("version", "password=#{version_secret}" <> String.duplicate("y", 600))

    Process.put(
      :native_addon_index_body,
      Jason.encode!(%{"schema_version" => 1, "addons" => [untrusted_entry]})
    )

    log =
      capture_sync_log(fn ->
        assert :ok = NativeAddonSyncWorker.perform(%Job{args: %{"force" => true, "limit" => 10}})
      end)

    assert log =~ "First-party native add-on package sync failed"
    assert log =~ "api_token=REDACTED"
    assert log =~ "password=REDACTED"
    refute log =~ addon_secret
    refute log =~ version_secret
    refute log =~ String.duplicate("x", 200)
    refute log =~ String.duplicate("y", 200)
    assert byte_size(log) < 2_000
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

    Process.put(:native_addon_manifest_requests, 0)
    Process.put(:native_addon_manifest_status, 404)

    assert {:ok, second} =
             AddonPackages.sync_first_party_addons(
               repo_url: @repo_url,
               release_tag: "v1.0.0",
               limit: 10
             )

    assert second.imported == 0
    assert second.skipped == 1
    assert second.failed == []
    assert Process.get(:native_addon_manifest_requests) == 0

    # Still exactly one package row for the entry — nothing was duplicated.
    actor = SystemActor.system(:native_addon_sync_test)

    packages =
      AddonPackage
      |> Ash.Query.for_read(:read, %{}, actor: actor)
      |> Ash.Query.filter(addon_id == "sample-addon" and version == "1.0.0")
      |> Ash.read!(actor: actor)

    assert length(packages) == 1
  end

  for {label, source_release_tag} <- [{"nil", nil}, {"older", "v0.9.0"}] do
    test "single-package context reuses exact OCI identity with #{label} release provenance", %{
      private_key: private_key
    } do
      source_release_tag = unquote(source_release_tag)
      install_fixtures(private_key)

      assert {:ok, [addon]} =
               NativeAddonImporter.list_recent_addons(%{"repo_url" => @repo_url}, 10)

      assert {:ok, imported, :imported} = AddonPackages.import_first_party_addon(addon)
      assert imported.source_release_tag == "v1.0.0"

      update_sample_package!(imported, %{source_release_tag: source_release_tag})
      Process.put(:native_addon_manifest_requests, 0)
      Process.put(:native_addon_manifest_status, 404)

      assert {:ok, reused, :skipped} = AddonPackages.import_first_party_addon(addon)
      assert reused.id == imported.id
      assert reused.source_release_tag == source_release_tag
      assert Process.get(:native_addon_manifest_requests) == 0
    end
  end

  test "sync_first_party_addons repairs an exact-version package with a corrupt object key", %{
    private_key: private_key
  } do
    install_fixtures(private_key)

    assert {:ok, %{imported: 1}} =
             AddonPackages.sync_first_party_addons(
               repo_url: @repo_url,
               release_tag: "v1.0.0",
               limit: 10
             )

    [package] = sample_packages()

    corrupt =
      package.artifacts
      |> Map.fetch!("linux/amd64")
      |> Map.put("object_key", "wrong/object/key")

    update_sample_package!(package, %{
      artifacts: Map.put(package.artifacts, "linux/amd64", corrupt)
    })

    Process.put(:native_addon_manifest_requests, 0)

    assert {:ok, summary} =
             AddonPackages.sync_first_party_addons(
               repo_url: @repo_url,
               release_tag: "v1.0.0",
               limit: 10
             )

    assert summary.imported == 1
    assert summary.skipped == 0
    assert summary.failed == []
    assert Process.get(:native_addon_manifest_requests) == 1

    [repaired] = sample_packages()
    assert repaired.status == :staged

    assert repaired.artifacts["linux/amd64"]["object_key"] ==
             NativeAddonArtifactMirror.object_key(
               "sample-addon",
               "1.0.0",
               "linux",
               "amd64",
               tarball_sha256()
             )
  end

  test "sync_first_party_addons reuses verified content from a later OCI envelope", %{
    private_key: private_key
  } do
    install_fixtures(private_key)

    assert {:ok, %{imported: 1}} =
             AddonPackages.sync_first_party_addons(
               repo_url: @repo_url,
               release_tag: "v1.0.0",
               limit: 10
             )

    later_ref = "registry.carverauto.dev/#{@oci_repository}:v1.0.1"
    later_digest = "sha256:" <> String.duplicate("f", 64)

    Process.put(:native_addon_oci_digest, later_digest)

    Process.put(
      :native_addon_index_body,
      Jason.encode!(index_map(oci_ref: later_ref, oci_digest: later_digest))
    )

    Process.put(:native_addon_manifest_requests, 0)

    assert {:ok, summary} =
             AddonPackages.sync_first_party_addons(
               repo_url: @repo_url,
               release_tag: "v1.0.0",
               limit: 10
             )

    assert summary.imported == 0
    assert summary.skipped == 1
    assert summary.failed == []
    assert Process.get(:native_addon_manifest_requests) == 1
    assert Process.get(:native_addon_cosign_verified) == {later_ref, later_digest}

    [persisted] = sample_packages()
    assert persisted.source_oci_ref == @oci_ref
    assert persisted.source_oci_digest == @oci_digest
    assert persisted.source_metadata["bundle_digest"] == bundle_digest()
  end

  test "sync_first_party_addons rejects changed bundle content under a later OCI envelope", %{
    private_key: private_key
  } do
    install_fixtures(private_key)

    assert {:ok, %{imported: 1}} =
             AddonPackages.sync_first_party_addons(
               repo_url: @repo_url,
               release_tag: "v1.0.0",
               limit: 10
             )

    changed_bundle =
      bundle_with_manifest(String.replace(@manifest_yaml, "name: Sample Addon", "name: Changed Addon"))

    later_ref = "registry.carverauto.dev/#{@oci_repository}:v1.0.1"
    later_digest = "sha256:" <> String.duplicate("e", 64)

    Process.put(:native_addon_bundle, changed_bundle)
    Process.put(:native_addon_manifest, oci_manifest())
    Process.put(:native_addon_oci_digest, later_digest)

    Process.put(
      :native_addon_blobs,
      Map.put(Process.get(:native_addon_blobs), digest(changed_bundle), changed_bundle)
    )

    Process.put(
      :native_addon_index_body,
      Jason.encode!(index_map(oci_ref: later_ref, oci_digest: later_digest))
    )

    Process.put(:native_addon_manifest_requests, 0)

    assert {:ok, summary} =
             AddonPackages.sync_first_party_addons(
               repo_url: @repo_url,
               release_tag: "v1.0.0",
               limit: 10
             )

    assert summary.imported == 0
    assert summary.skipped == 0

    assert [
             %{
               error:
                 {:native_addon_version_source_conflict,
                  %{reason: :oci_source_mismatch, existing_source_type: :first_party}}
             }
           ] = summary.failed

    assert Process.get(:native_addon_manifest_requests) == 0
    [persisted] = sample_packages()
    assert persisted.name == "Sample Addon"
    assert persisted.source_oci_ref == @oci_ref
    assert persisted.source_oci_digest == @oci_digest
  end

  for source_type <- [:upload, :github] do
    test "sync_first_party_addons never overwrites a #{source_type}-owned version with nil OCI fields", %{
      private_key: private_key
    } do
      source_type = unquote(source_type)
      install_fixtures(private_key)
      actor = SystemActor.system(:native_addon_sync_test)

      {:ok, owned} =
        AddonPackage
        |> Ash.Changeset.for_create(
          :create,
          %{
            addon_id: "sample-addon",
            version: "1.0.0",
            name: "Externally owned",
            source_type: source_type,
            source_oci_ref: nil,
            source_oci_digest: nil,
            artifacts: %{},
            verification_status: "verified"
          },
          actor: actor
        )
        |> Ash.create()

      Process.put(:native_addon_manifest_requests, 0)

      assert {:ok, summary} =
               AddonPackages.sync_first_party_addons(
                 repo_url: @repo_url,
                 release_tag: "v1.0.0",
                 limit: 10
               )

      assert summary.imported == 0
      assert summary.skipped == 0

      assert [
               %{
                 error:
                   {:native_addon_version_source_conflict,
                    %{reason: :source_type_owned, existing_source_type: ^source_type}}
               }
             ] = summary.failed

      assert Process.get(:native_addon_manifest_requests) == 0
      {:ok, persisted} = Ash.get(AddonPackage, owned.id, actor: actor)
      assert persisted.source_type == source_type
      assert persisted.artifacts == %{}
    end
  end

  test "sync_first_party_addons replaces an unverified seeder placeholder with the real artifact", %{
    private_key: private_key
  } do
    # Reproduces GitHub #4039. The in-cluster seeder pre-creates a first-party row
    # for a version it cannot verify, carrying NO source identity. That row used to
    # take the source-conflict path, so the importer refused to deliver its own
    # signed artifact for the very version the seeder had announced -- freezing
    # every seeded add-on at its last pre-seeder version.
    install_fixtures(private_key)
    actor = SystemActor.system(:native_addon_sync_test)

    {:ok, placeholder} =
      AddonPackage
      |> Ash.Changeset.for_create(
        :create,
        %{
          addon_id: "sample-addon",
          version: "1.0.0",
          name: "Seeded placeholder",
          source_type: :first_party,
          source_oci_ref: nil,
          source_oci_digest: nil,
          artifacts: %{},
          verification_status: "seeded"
        },
        actor: actor
      )
      |> Ash.create()

    assert {:ok, summary} =
             AddonPackages.sync_first_party_addons(
               repo_url: @repo_url,
               release_tag: "v1.0.0",
               limit: 10
             )

    assert summary.imported == 1
    assert summary.failed == []

    # Gate on the artefact, not the summary: the row must now carry the real,
    # verified source. A summary that says "imported" while the row still has nil
    # OCI fields is exactly the failure this test exists to catch.
    {:ok, persisted} = Ash.get(AddonPackage, placeholder.id, actor: actor)
    assert persisted.source_type == :first_party
    assert persisted.verification_status == "verified"
    assert persisted.source_oci_ref == @oci_ref
    assert persisted.source_oci_digest == @oci_digest
  end

  test "sync_first_party_addons still refuses a VERIFIED first-party version whose source differs", %{
    private_key: private_key
  } do
    # The narrowing in #4039 must not disarm the guard it sits next to. A row that
    # was genuinely verified against a different source is a real claim, and the
    # importer must keep refusing it rather than overwriting silently.
    install_fixtures(private_key)
    actor = SystemActor.system(:native_addon_sync_test)

    {:ok, claimed} =
      AddonPackage
      |> Ash.Changeset.for_create(
        :create,
        %{
          addon_id: "sample-addon",
          version: "1.0.0",
          name: "Verified elsewhere",
          source_type: :first_party,
          source_oci_ref: "registry.example.test/other/sample-addon:v9.9.9",
          source_oci_digest: "sha256:" <> String.duplicate("a", 64),
          artifacts: %{},
          verification_status: "verified"
        },
        actor: actor
      )
      |> Ash.create()

    assert {:ok, summary} =
             AddonPackages.sync_first_party_addons(
               repo_url: @repo_url,
               release_tag: "v1.0.0",
               limit: 10
             )

    assert summary.imported == 0

    assert [
             %{
               error:
                 {:native_addon_version_source_conflict,
                  %{reason: :oci_source_mismatch, existing_source_type: :first_party}}
             }
           ] = summary.failed

    {:ok, persisted} = Ash.get(AddonPackage, claimed.id, actor: actor)
    assert persisted.source_oci_ref == "registry.example.test/other/sample-addon:v9.9.9"
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

  test "sync worker canonicalizes platform keys and reuses the persisted artifact", %{
    private_key: private_key
  } do
    install_fixtures(private_key, platforms: ["AMD64"])
    configure_sync_worker()

    assert :ok = NativeAddonSyncWorker.perform(%Job{args: %{"force" => true, "limit" => 10}})

    [package] = sample_packages()
    assert Map.keys(package.artifacts) == ["linux/amd64"]
    refute Map.has_key?(package.artifacts, "linux/AMD64")

    expected_key =
      NativeAddonArtifactMirror.object_key(
        "sample-addon",
        "1.0.0",
        "linux",
        "amd64",
        tarball_sha256("AMD64")
      )

    assert package.artifacts["linux/amd64"]["object_key"] == expected_key
    assert_received {:uploaded, ^expected_key, _size}

    Process.put(:native_addon_manifest_requests, 0)
    Process.put(:native_addon_manifest_status, 404)

    log =
      capture_sync_log(fn ->
        assert :ok = NativeAddonSyncWorker.perform(%Job{args: %{"force" => true, "limit" => 10}})
      end)

    assert log =~ "import_ready=1 imported=0 skipped=1 failed=0"
    assert Process.get(:native_addon_manifest_requests) == 0
    assert Map.keys(hd(sample_packages()).artifacts) == ["linux/amd64"]
  end

  test "rejects duplicate normalized artifact platforms before mirroring", %{
    private_key: private_key
  } do
    install_fixtures(private_key, platforms: ["amd64", "AMD64"])

    assert {:error, {:duplicate_artifact_platform, "linux/amd64"}} =
             NativeAddonImporter.import(%{
               "repo_url" => @repo_url,
               "release_tag" => "v1.0.0",
               "addon_id" => "sample-addon",
               "version" => "1.0.0"
             })

    refute_received {:uploaded, _key, _size}
    assert sample_packages() == []
  end

  test "rejects a cosign-verified bundle whose manifest identity differs from its index entry", %{
    private_key: private_key
  } do
    install_fixtures(private_key)
    mismatched_yaml = String.replace(@manifest_yaml, "id: sample-addon", "id: different-addon")
    mismatched_bundle = bundle_with_manifest(mismatched_yaml)
    Process.put(:native_addon_bundle, mismatched_bundle)

    Process.put(:native_addon_index_body, Jason.encode!(index_map([])))
    Process.put(:native_addon_manifest, oci_manifest())

    Process.put(
      :native_addon_blobs,
      :native_addon_blobs
      |> Process.get()
      |> Map.put(bundle_digest(), mismatched_bundle)
    )

    assert {:error,
            {:native_addon_identity_mismatch, %{entry_addon_id: "sample-addon", manifest_addon_id: "different-addon"}}} =
             NativeAddonImporter.import(%{
               "repo_url" => @repo_url,
               "release_tag" => "v1.0.0",
               "addon_id" => "sample-addon",
               "version" => "1.0.0"
             })

    refute_received {:uploaded, _key, _size}
    assert sample_packages() == []
  end

  # --- fixtures -----------------------------------------------------------------

  defp install_fixtures(private_key, opts \\ []) do
    platforms = Keyword.get(opts, :platforms, ["amd64"])

    Process.put(:native_addon_private_key, private_key)
    Process.put(:native_addon_platforms, platforms)
    Process.put(:native_addon_release, release())
    Process.put(:native_addon_recent_releases, [release()])
    Process.put(:native_addon_oci_digest, @oci_digest)
    Process.put(:native_addon_manifest_requests, 0)
    Process.put(:native_addon_manifest_status, 200)
    Process.put(:native_addon_manifest, oci_manifest())
    Process.put(:native_addon_index_body, Jason.encode!(index_map(platforms: platforms)))

    artifact_blobs =
      Enum.reduce(platforms, %{bundle_digest() => bundle()}, fn arch, blobs ->
        blobs
        |> Map.put(tarball_digest(arch), tarball(arch))
        |> Map.put(signature_digest(private_key, arch), signature_blob(private_key, arch))
      end)

    Process.put(:native_addon_blobs, artifact_blobs)
  end

  defp release do
    %{
      "tag_name" => "v1.0.0",
      "name" => "ServiceRadar v1.0.0",
      "html_url" => "https://github.com/carverauto/serviceradar/releases/tag/v1.0.0",
      "assets" => [
        %{
          "name" => @index_asset_name,
          "browser_download_url" =>
            "https://github.com/carverauto/serviceradar/releases/download/v1.0.0/#{@index_asset_name}"
        }
      ]
    }
  end

  defp index_map(opts) do
    private_key = Process.get(:native_addon_private_key)
    platforms = Keyword.get(opts, :platforms, Process.get(:native_addon_platforms, ["amd64"]))
    oci_digest = Keyword.get(opts, :oci_digest, @oci_digest)
    oci_ref = Keyword.get(opts, :oci_ref, @oci_ref)

    artifacts =
      Enum.map(platforms, fn arch ->
        tarball_digest =
          if arch == "amd64" do
            Keyword.get(opts, :orphan_tarball_digest, tarball_digest(arch))
          else
            tarball_digest(arch)
          end

        %{
          "os" => "linux",
          "arch" => arch,
          "tarball_digest" => tarball_digest,
          "signature_digest" => signature_digest(private_key, arch),
          "tarball_sha256" => tarball_sha256(arch)
        }
      end)

    %{
      "schema_version" => 1,
      "addons" => [
        %{
          "addon_id" => "sample-addon",
          "version" => "1.0.0",
          "oci_ref" => oci_ref,
          "oci_digest" => oci_digest,
          "bundle_digest" => bundle_digest(),
          "artifacts" => artifacts
        }
      ]
    }
  end

  defp oci_manifest do
    platforms = Process.get(:native_addon_platforms, ["amd64"])

    artifact_layers =
      Enum.flat_map(platforms, fn arch ->
        [
          %{
            "mediaType" => "application/vnd.serviceradar.native-addon.artifact.v1+gzip",
            "digest" => tarball_digest(arch),
            "size" => byte_size(tarball(arch))
          },
          %{
            "mediaType" => "application/vnd.serviceradar.native-addon.artifact-signature.v1+hex",
            "digest" => signature_digest(Process.get(:native_addon_private_key), arch),
            "size" => byte_size(signature_blob(Process.get(:native_addon_private_key), arch))
          }
        ]
      end)

    %{
      "schemaVersion" => 2,
      "mediaType" => "application/vnd.oci.image.manifest.v1+json",
      "layers" =>
        [%{"mediaType" => "application/zip", "digest" => bundle_digest(), "size" => byte_size(bundle())}] ++
          artifact_layers
    }
  end

  defp bundle do
    case Process.get(:native_addon_bundle) do
      nil ->
        payload = bundle_with_manifest(@manifest_yaml)
        Process.put(:native_addon_bundle, payload)
        payload

      payload ->
        payload
    end
  end

  defp bundle_with_manifest(manifest_yaml) do
    path = Path.join(System.tmp_dir!(), "sr-native-addon-#{System.unique_integer([:positive])}.zip")

    try do
      {:ok, _zip} =
        :zip.create(String.to_charlist(path), [
          {~c"addon.yaml", manifest_yaml},
          {~c"config.schema.json", Jason.encode!(%{"type" => "object"})}
        ])

      File.read!(path)
    after
      File.rm(path)
    end
  end

  defp tarball(arch \\ "amd64"), do: "fake-linux-#{arch}-native-addon-tarball-bytes"

  defp tarball_sha256(arch \\ "amd64") do
    :sha256 |> :crypto.hash(tarball(arch)) |> Base.encode16(case: :lower)
  end

  defp signature_hex(private_key, arch \\ "amd64") do
    :eddsa
    |> :crypto.sign(:none, tarball(arch), [private_key, :ed25519])
    |> Base.encode16(case: :lower)
  end

  defp signature_blob(private_key, arch), do: signature_hex(private_key, arch) <> "\n"

  defp bundle_digest, do: digest(bundle())
  defp tarball_digest(arch), do: digest(tarball(arch))
  defp signature_digest(private_key, arch), do: digest(signature_blob(private_key, arch))

  defp digest(bytes), do: "sha256:" <> (:sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower))

  defp configure_sync_worker(overrides \\ []) do
    config =
      Keyword.merge(
        [
          repo_url: @repo_url,
          index_asset_name: @index_asset_name,
          auto_sync_enabled: false,
          auto_approve_addon_ids: ["sample-addon"],
          sync_release_limit: 10,
          sync_interval_seconds: 3_600
        ],
        overrides
      )

    Application.put_env(:serviceradar_web_ng, :native_addon_import, config)
  end

  defp sample_packages do
    actor = SystemActor.system(:native_addon_sync_test)

    AddonPackage
    |> Ash.Query.for_read(:read, %{}, actor: actor)
    |> Ash.Query.filter(addon_id == "sample-addon" and version == "1.0.0")
    |> Ash.read!(actor: actor)
  end

  defp update_sample_package!(package, attrs) do
    package
    |> Ash.Changeset.for_update(:update, attrs, actor: SystemActor.system(:native_addon_sync_test))
    |> Ash.update!()
  end

  defp move_package_to_status!(package, :staged), do: package

  defp move_package_to_status!(package, :approved) do
    package
    |> Ash.Changeset.for_update(
      :approve,
      %{approved_capabilities: package.capabilities, approved_by: "reviewer"},
      actor: SystemActor.system(:native_addon_sync_test)
    )
    |> Ash.update!()
  end

  defp move_package_to_status!(package, :denied) do
    package
    |> Ash.Changeset.for_update(
      :deny,
      %{denied_reason: "reviewed"},
      actor: SystemActor.system(:native_addon_sync_test)
    )
    |> Ash.update!()
  end

  defp move_package_to_status!(package, :revoked) do
    package
    |> move_package_to_status!(:approved)
    |> Ash.Changeset.for_update(
      :revoke,
      %{denied_reason: "revoked"},
      actor: SystemActor.system(:native_addon_sync_test)
    )
    |> Ash.update!()
  end

  defp expected_review_status(status) when status in [:denied, :revoked], do: status
  defp expected_review_status(_status), do: :approved

  defp insert_executing_sync_job!(args \\ %{}) do
    insert_sync_job!("executing", args)
  end

  defp insert_sync_job!(state, args) do
    now = DateTime.utc_now()

    args
    |> Job.new(worker: NativeAddonSyncWorker, queue: :web_maintenance)
    |> Ecto.Changeset.change(
      state: state,
      attempt: 1,
      max_attempts: 3,
      attempted_at: now,
      inserted_at: now,
      scheduled_at: now
    )
    |> Repo.insert!()
  end

  defp capture_sync_log(fun) do
    capture_log(
      [
        level: :info,
        format: "$message $metadata\n",
        metadata: [:addon_id, :addon_version, :release_tag, :reason]
      ],
      fun
    )
  end

  defp restore_system_env(key, nil), do: System.delete_env(key)
  defp restore_system_env(key, value), do: System.put_env(key, value)

  defp restore_env(key, nil), do: Application.delete_env(:serviceradar_web_ng, key)
  defp restore_env(key, value), do: Application.put_env(:serviceradar_web_ng, key, value)
end
