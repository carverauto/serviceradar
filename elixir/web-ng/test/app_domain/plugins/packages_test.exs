defmodule ServiceRadarWebNG.Plugins.PackagesTest do
  use ServiceRadarWebNG.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import ServiceRadarWebNG.AshTestHelpers, only: [admin_user_fixture: 0, system_actor: 0]

  alias Oban.Job
  alias ServiceRadar.Edge.AgentCommandBus
  alias ServiceRadar.Plugins.Plugin
  alias ServiceRadar.Plugins.PluginAssignment
  alias ServiceRadar.Plugins.PluginPackage
  alias ServiceRadar.ProcessRegistry
  alias ServiceRadar.Repo
  alias ServiceRadar.SNMPProfiles.SNMPOIDTemplate
  alias ServiceRadar.SNMPProfiles.SNMPProfile
  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.Plugins.FirstPartySyncWorker
  alias ServiceRadarWebNG.Plugins.Packages
  alias ServiceRadarWebNG.Plugins.Storage
  alias ServiceRadarWebNG.Plugins.UploadSignature

  require Ash.Query

  @repo_url "https://github.com/carverauto/serviceradar"
  @manifest %{
    "id" => "unifi-protect-camera",
    "name" => "UniFi Protect Camera",
    "version" => "0.1.0",
    "entrypoint" => "run_check",
    "outputs" => "serviceradar.plugin_result.v1",
    "capabilities" => ["get_config", "submit_result"],
    "resources" => %{
      "requested_cpu_ms" => 1000,
      "requested_memory_mb" => 64
    },
    "permissions" => %{"allowed_domains" => ["192.168.1.1"]}
  }
  @first_party_manifest_yaml """
  id: first-party-dedupe
  name: First-party Dedupe
  version: 1.0.1
  entrypoint: run_check
  runtime: wasi-preview1
  outputs: serviceradar.plugin_result.v1
  capabilities:
    - get_config
  resources:
    requested_cpu_ms: 1000
    requested_memory_mb: 64
  """
  @first_party_manifest %{
    "id" => "first-party-dedupe",
    "name" => "First-party Dedupe",
    "version" => "1.0.1",
    "entrypoint" => "run_check",
    "runtime" => "wasi-preview1",
    "outputs" => "serviceradar.plugin_result.v1",
    "capabilities" => ["get_config"],
    "resources" => %{"requested_cpu_ms" => 1000, "requested_memory_mb" => 64}
  }
  @first_party_wasm "first-party wasm payload"

  defmodule FirstPartyPackagesClient do
    @moduledoc false

    alias ServiceRadarWebNG.Plugins.PackagesTest

    def get(url, _opts) do
      cond do
        String.contains?(url, "api.github.com/repos/carverauto/serviceradar/releases?per_page=") ->
          Process.put(
            :first_party_recent_release_requests,
            Process.get(:first_party_recent_release_requests, 0) + 1
          )

          if Process.get(:first_party_recent_releases_missing) do
            {:ok, %Req.Response{status: 404, body: ""}}
          else
            releases =
              if Process.get(:first_party_duplicate_releases) do
                [
                  PackagesTest.first_party_release("v1.0.2"),
                  PackagesTest.first_party_release("v1.0.1")
                ]
              else
                [PackagesTest.first_party_release()]
              end

            {:ok, %Req.Response{status: 200, body: releases}}
          end

        String.contains?(url, "api.github.com/repos/carverauto/serviceradar/releases/tags/v1.0.1") ->
          {:ok, %Req.Response{status: 200, body: PackagesTest.first_party_release("v1.0.1")}}

        String.contains?(url, "api.github.com/repos/carverauto/serviceradar/releases/tags/v1.0.2") ->
          {:ok, %Req.Response{status: 200, body: PackagesTest.first_party_release("v1.0.2")}}

        String.contains?(url, "/download/v1.0.2/serviceradar-wasm-plugin-index.json") ->
          {:ok,
           %Req.Response{
             status: 200,
             body: Jason.encode!(PackagesTest.first_party_index("v1.0.2"))
           }}

        String.ends_with?(url, "/serviceradar-wasm-plugin-index.json") ->
          {:ok, %Req.Response{status: 200, body: Jason.encode!(PackagesTest.first_party_index())}}

        String.ends_with?(url, "/first-party-dedupe-v1.0.2.zip") ->
          {:ok, %Req.Response{status: 200, body: PackagesTest.first_party_bundle("v1.0.2")}}

        String.ends_with?(url, "/first-party-dedupe.zip") ->
          {:ok, %Req.Response{status: 200, body: PackagesTest.first_party_bundle()}}

        String.ends_with?(url, "/first-party-dedupe-v1.0.2.upload-signature.json") ->
          {:ok,
           %Req.Response{
             status: 200,
             body: Jason.encode!(PackagesTest.first_party_upload_signature("v1.0.2"))
           }}

        String.ends_with?(url, "/first-party-dedupe.upload-signature.json") ->
          {:ok,
           %Req.Response{
             status: 200,
             body: Jason.encode!(PackagesTest.first_party_upload_signature())
           }}

        true ->
          {:ok, %Req.Response{status: 404, body: ""}}
      end
    end
  end

  setup do
    original = Application.get_env(:serviceradar_web_ng, :plugin_storage)
    original_policy = Application.get_env(:serviceradar_web_ng, :plugin_verification)

    original_import_client =
      Application.get_env(:serviceradar_web_ng, :first_party_plugin_import_http_client)

    tmp = Path.join(System.tmp_dir!(), "sr-plugin-storage-#{System.unique_integer([:positive])}")
    store_name = :"sr_plugin_packages_test_#{System.unique_integer([:positive])}"
    {public_key, private_key} = :crypto.generate_key(:eddsa, :ed25519)
    {:ok, _store} = ServiceRadarWebNG.PluginStorageTestClient.start_link(store_name)

    Application.put_env(:serviceradar_web_ng, :plugin_storage,
      backend: :jetstream,
      jetstream_client: ServiceRadarWebNG.PluginStorageTestClient,
      test_store: store_name,
      signing_secret: "test-secret"
    )

    Application.put_env(:serviceradar_web_ng, :plugin_verification,
      require_gpg_for_github: false,
      allow_unsigned_uploads: false,
      trusted_upload_signing_keys: %{"packages-test" => Base.encode64(public_key)}
    )

    Application.put_env(
      :serviceradar_web_ng,
      :first_party_plugin_import_http_client,
      FirstPartyPackagesClient
    )

    Process.put(:first_party_private_key, private_key)
    Process.put(:first_party_package_bundle, nil)
    Process.put(:first_party_package_signature, nil)
    Process.put(:first_party_duplicate_releases, false)
    Process.put(:first_party_recent_releases_missing, false)
    Process.put(:first_party_recent_release_requests, 0)

    on_exit(fn ->
      File.rm_rf(tmp)

      if is_nil(original) do
        Application.delete_env(:serviceradar_web_ng, :plugin_storage)
      else
        Application.put_env(:serviceradar_web_ng, :plugin_storage, original)
      end

      if is_nil(original_policy) do
        Application.delete_env(:serviceradar_web_ng, :plugin_verification)
      else
        Application.put_env(:serviceradar_web_ng, :plugin_verification, original_policy)
      end

      if is_nil(original_import_client) do
        Application.delete_env(:serviceradar_web_ng, :first_party_plugin_import_http_client)
      else
        Application.put_env(
          :serviceradar_web_ng,
          :first_party_plugin_import_http_client,
          original_import_client
        )
      end
    end)

    :ok
  end

  test "upload_blob updates blob metadata when called with an actor" do
    _plugin = create_plugin()
    package = create_package()
    payload = "updated-wasm-binary"

    assert {:ok, updated} =
             Packages.upload_blob(package, payload, actor: system_actor())

    assert updated.wasm_object_key == Storage.object_key_for(package)
    assert updated.content_hash == Storage.sha256(payload)
    assert Storage.blob_exists?(updated.wasm_object_key)
    assert {:ok, {:binary, ^payload}} = Storage.fetch_blob(updated.wasm_object_key)
  end

  test "create ignores caller-supplied wasm object keys" do
    _plugin = create_plugin()
    scope = Scope.for_user(admin_user_fixture())

    assert {:ok, package} =
             Packages.create(
               %{
                 plugin_id: "unifi-protect-camera",
                 name: "UniFi Protect Camera",
                 version: "0.1.0",
                 entrypoint: "run_check",
                 outputs: "serviceradar.plugin_result.v1",
                 manifest: @manifest,
                 config_schema: %{},
                 signature: %{},
                 wasm_object_key: "../../shared/other-package.wasm"
               },
               scope: scope
             )

    assert package.wasm_object_key in [nil, ""]
  end

  test "create stores normalized signal schemas from manifest metadata" do
    _plugin = create_plugin()
    scope = Scope.for_user(admin_user_fixture())

    signal_schema = %{
      "id" => "com.carverauto.unifi.event",
      "version" => "1.0.0",
      "signal_type" => "event",
      "payload_kind" => "ocsf_event",
      "payload_schema" => "schemas/unifi_event.schema.json",
      "display_contract" => "display/unifi_event.display.json",
      "display_contract_id" => "com.carverauto.unifi.event.display",
      "display_contract_version" => "1.0.0"
    }

    manifest = Map.put(@manifest, "signal_schemas", [signal_schema])

    assert {:ok, package} =
             Packages.create(
               %{
                 plugin_id: "unifi-protect-camera",
                 name: "UniFi Protect Camera",
                 version: "0.1.0",
                 entrypoint: "run_check",
                 outputs: "serviceradar.plugin_result.v1",
                 manifest: manifest,
                 config_schema: %{},
                 signature: %{}
               },
               scope: scope
             )

    assert [stored_schema] = package.signal_schemas
    assert stored_schema["id"] == "com.carverauto.unifi.event"
    assert stored_schema["display_contract"] == "display/unifi_event.display.json"
  end

  test "upload_blob_file writes to the canonical object key even if the package was poisoned" do
    _plugin = create_plugin()
    package = create_package()
    payload = "updated-wasm-binary"

    upload_path =
      Path.join(System.tmp_dir!(), "sr-plugin-upload-#{System.unique_integer([:positive])}.wasm")

    File.write!(upload_path, payload)

    on_exit(fn -> File.rm(upload_path) end)

    poisoned =
      package
      |> Ash.Changeset.for_update(
        :update,
        %{wasm_object_key: "plugins/other-package/1.0.0/shared.wasm"},
        actor: system_actor()
      )
      |> Ash.update!()

    assert {:ok, updated} =
             Packages.upload_blob_file(poisoned, upload_path, actor: system_actor())

    assert updated.wasm_object_key == Storage.object_key_for(package)
    assert updated.content_hash == Storage.sha256(payload)
    assert Storage.blob_exists?(updated.wasm_object_key)
    refute Storage.blob_exists?("plugins/other-package/1.0.0/shared.wasm")
  end

  test "sync_first_party_plugins deduplicates an already imported plugin/version/digest" do
    trusted_keys =
      :serviceradar_web_ng
      |> Application.fetch_env!(:plugin_verification)
      |> Keyword.fetch!(:trusted_upload_signing_keys)

    opts = [
      actor: system_actor(),
      repo_url: @repo_url,
      index_asset_name: "serviceradar-wasm-plugin-index.json",
      github_token: "test-token",
      trusted_upload_signing_keys: trusted_keys,
      limit: 10
    ]

    assert {:ok, %{imported: 1, failed: []}} = Packages.sync_first_party_plugins(opts)

    assert {:ok, %{imported: 0, skipped: 1, failed: []}} =
             Packages.sync_first_party_plugins(opts)

    packages = Packages.list(%{"plugin_id" => "first-party-dedupe"}, actor: system_actor())
    assert [%PluginPackage{} = package] = packages
    assert package.source_type == :first_party
    assert package.source_repo_url == @repo_url
    assert package.source_release_tag == "v1.0.1"
    assert package.source_bundle_digest == Storage.sha256(first_party_bundle())
    assert Storage.blob_exists?(package.wasm_object_key)
  end

  test "sync_first_party_plugins replaces an existing package for the same plugin version" do
    _plugin =
      Plugin
      |> Ash.Changeset.for_create(
        :create,
        %{
          plugin_id: "first-party-dedupe",
          name: "First-party Dedupe",
          description: "Existing upload"
        },
        actor: system_actor()
      )
      |> Ash.create!()

    existing =
      PluginPackage
      |> Ash.Changeset.for_create(
        :create,
        %{
          plugin_id: "first-party-dedupe",
          name: "First-party Dedupe",
          version: "1.0.1",
          entrypoint: "run_check",
          runtime: "wasi-preview1",
          outputs: "serviceradar.plugin_result.v1",
          manifest: @first_party_manifest,
          config_schema: %{},
          signature: %{},
          content_hash: Storage.sha256("old local wasm")
        },
        actor: system_actor()
      )
      |> Ash.create!()

    opts = [actor: system_actor(), repo_url: @repo_url, limit: 10]

    assert {:ok, %{imported: 1, failed: []}} = Packages.sync_first_party_plugins(opts)

    assert [%PluginPackage{} = package] =
             Packages.list(%{"plugin_id" => "first-party-dedupe"}, actor: system_actor())

    assert package.id == existing.id
    assert package.source_type == :first_party
    assert package.source_release_tag == "v1.0.1"
    assert package.source_bundle_digest == Storage.sha256(first_party_bundle())
    assert package.content_hash == Storage.sha256(@first_party_wasm)
    assert Storage.blob_exists?(package.wasm_object_key)
  end

  test "sync_first_party_plugins keeps newest release when plugin/version appears in older releases" do
    Process.put(:first_party_duplicate_releases, true)

    opts = [actor: system_actor(), repo_url: @repo_url, limit: 10]

    assert {:ok, %{discovered: 2, import_ready: 1, imported: 1, failed: []}} =
             Packages.sync_first_party_plugins(opts)

    assert [%PluginPackage{} = package] =
             Packages.list(%{"plugin_id" => "first-party-dedupe"}, actor: system_actor())

    assert package.source_release_tag == "v1.0.2"
    assert package.source_bundle_digest == Storage.sha256(first_party_bundle("v1.0.2"))
    assert package.content_hash == Storage.sha256(first_party_wasm("v1.0.2"))
  end

  test "admin sync imports nothing when the selected release is missing" do
    assert {:error, reason} =
             Packages.sync_first_party_plugins(
               actor: system_actor(),
               repo_url: @repo_url,
               release_tag: "v9.8.7"
             )

    assert reason =~ "Release tag v9.8.7 was not found"
    assert Process.get(:first_party_recent_release_requests) == 0
    assert [] = Packages.list(%{"plugin_id" => "first-party-dedupe"}, actor: system_actor())
  end

  test "periodic first-party sync anchors discovery to the deployed release" do
    original_release_version = System.get_env("SERVICERADAR_RELEASE_VERSION")
    System.put_env("SERVICERADAR_RELEASE_VERSION", "v1.0.1")

    on_exit(fn -> restore_system_env("SERVICERADAR_RELEASE_VERSION", original_release_version) end)

    assert :ok =
             FirstPartySyncWorker.perform(%Job{
               args: %{"force" => true, "repo_url" => @repo_url, "limit" => 10}
             })

    assert Process.get(:first_party_recent_release_requests) == 0

    assert [%PluginPackage{} = package] =
             Packages.list(%{"plugin_id" => "first-party-dedupe"}, actor: system_actor())

    assert package.source_release_tag == "v1.0.1"
  end

  test "periodic first-party sync falls back to recent releases when the deployed tag is unpublished" do
    original_release_version = System.get_env("SERVICERADAR_RELEASE_VERSION")
    System.put_env("SERVICERADAR_RELEASE_VERSION", "v1.4.51")

    on_exit(fn -> restore_system_env("SERVICERADAR_RELEASE_VERSION", original_release_version) end)

    assert :ok =
             FirstPartySyncWorker.perform(%Job{
               args: %{"force" => true, "repo_url" => @repo_url, "limit" => 10}
             })

    assert Process.get(:first_party_recent_release_requests) >= 1

    assert [%PluginPackage{} = package] =
             Packages.list(%{"plugin_id" => "first-party-dedupe"}, actor: system_actor())

    assert package.source_release_tag == "v1.0.1"
  end

  test "periodic first-party sync does not fail the job when GitHub has no plugin catalog" do
    original_release_version = System.get_env("SERVICERADAR_RELEASE_VERSION")
    System.put_env("SERVICERADAR_RELEASE_VERSION", "v1.4.51")
    Process.put(:first_party_recent_releases_missing, true)

    on_exit(fn -> restore_system_env("SERVICERADAR_RELEASE_VERSION", original_release_version) end)

    assert :ok =
             FirstPartySyncWorker.perform(%Job{
               args: %{"force" => true, "repo_url" => @repo_url, "limit" => 10}
             })

    assert Process.get(:first_party_recent_release_requests) >= 1
    assert [] = Packages.list(%{"plugin_id" => "first-party-dedupe"}, actor: system_actor())
  end

  test "periodic first-party sync schedules a successor while the current job executes" do
    original_config = Application.get_env(:serviceradar_web_ng, :first_party_plugin_import, [])

    Application.put_env(
      :serviceradar_web_ng,
      :first_party_plugin_import,
      Keyword.merge(original_config,
        auto_sync_enabled: true,
        repo_url: @repo_url,
        sync_release_limit: 10,
        sync_interval_seconds: 3_600
      )
    )

    on_exit(fn ->
      Application.put_env(:serviceradar_web_ng, :first_party_plugin_import, original_config)
    end)

    now = DateTime.utc_now()

    executing =
      %{}
      |> Job.new(worker: FirstPartySyncWorker, queue: :web_maintenance)
      |> Ecto.Changeset.change(
        state: "executing",
        attempt: 1,
        max_attempts: 3,
        attempted_at: now,
        inserted_at: now,
        scheduled_at: now
      )
      |> Repo.insert!()

    assert :ok = FirstPartySyncWorker.perform(%{executing | args: %{}})

    worker_jobs =
      Repo.all(
        from(job in Job,
          where: job.worker == ^inspect(FirstPartySyncWorker),
          order_by: [asc: job.id]
        )
      )

    successor = Enum.find(worker_jobs, &(&1.id != executing.id and &1.state == "scheduled"))

    assert successor,
           "expected a scheduled successor, got: #{inspect(Enum.map(worker_jobs, &{&1.id, &1.state, &1.conflict?}))}"

    refute successor.conflict?
    assert DateTime.after?(successor.scheduled_at, DateTime.utc_now())
  end

  test "approve keeps previously approved versions available for assignment upgrades" do
    plugin_id = "multi-approved-package-#{System.unique_integer([:positive])}"
    _plugin = create_plugin(plugin_id)
    old_package = create_package(plugin_id, "1.0.0")
    new_package = create_package(plugin_id, "1.0.1")

    assert {:ok, approved_old} = Packages.approve(old_package.id, %{}, actor: system_actor())
    assert approved_old.status == :approved

    assert {:ok, approved_new} = Packages.approve(new_package.id, %{}, actor: system_actor())
    assert approved_new.status == :approved

    reloaded_old =
      PluginPackage
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(id == ^old_package.id)
      |> Ash.read_one!(actor: system_actor())

    assert reloaded_old.status == :approved
    assert reloaded_old.denied_reason in [nil, ""]
  end

  test "approve does not disable existing assignments for older approved package versions" do
    plugin_id = "multi-enabled-package-assignment-#{System.unique_integer([:positive])}"
    agent_uid = "agent-multi-enabled-package-assignment-#{System.unique_integer([:positive])}"
    _plugin = create_plugin(plugin_id)
    old_package = create_package(plugin_id, "1.0.0")
    new_package = create_package(plugin_id, "1.0.1")

    assert {:ok, approved_old} = Packages.approve(old_package.id, %{}, actor: system_actor())

    # This test owns package approval behavior, not assignment creation. Insert
    # the already-existing row directly so the fixture does not dispatch an
    # unrelated asynchronous agent-config rebuild after the sandbox owner exits.
    assignment_id = Ecto.UUID.generate()
    now = DateTime.utc_now()

    assert {1, nil} =
             Repo.insert_all(
               "plugin_assignments",
               [
                 %{
                   id: Ecto.UUID.dump!(assignment_id),
                   agent_uid: agent_uid,
                   partition_id: "packages-test",
                   plugin_id: plugin_id,
                   plugin_package_id: Ecto.UUID.dump!(approved_old.id),
                   source: "manual",
                   enabled: true,
                   interval_seconds: 60,
                   timeout_seconds: 10,
                   params: %{},
                   permissions_override: %{},
                   resources_override: %{},
                   inserted_at: now,
                   updated_at: now
                 }
               ],
               prefix: "platform"
             )

    assert {:ok, approved_new} = Packages.approve(new_package.id, %{}, actor: system_actor())

    reloaded_assignment =
      PluginAssignment
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(id == ^assignment_id)
      |> Ash.read_one!(actor: system_actor())

    assert reloaded_assignment.enabled == true
    register_control_session!(agent_uid, "packages-test")

    assert {:error, error} =
             PluginAssignment
             |> Ash.Changeset.for_create(
               :create,
               %{
                 agent_uid: agent_uid,
                 plugin_package_id: approved_new.id,
                 enabled: true,
                 interval_seconds: 60,
                 timeout_seconds: 10,
                 params: %{}
               },
               actor: system_actor()
             )
             |> Ash.create()

    assert Exception.message(error) =~ "plugin is already enabled for this agent"
  end

  test "approve materializes inert plugin SNMP rows" do
    actor = system_actor()
    package = create_snmp_package()

    assert {:ok, approved} = Packages.approve(package.id, %{}, actor: actor)
    assert approved.status == :approved

    [profile] = snmp_profiles_for(package.id, actor)
    assert profile.enabled == false
    assert profile.plugin_package_id == package.id
    assert is_nil(profile.credential_secret_id)

    [template] = snmp_templates_for(package.id, actor)
    assert template.plugin_package_id == package.id
    assert template.vendor == "plugin"
  end

  test "revoke and restage disable operator-enabled plugin SNMP profiles" do
    actor = system_actor()
    package = create_snmp_package()

    assert {:ok, _} = Packages.approve(package.id, %{}, actor: actor)
    [profile] = snmp_profiles_for(package.id, actor)

    {:ok, _} =
      profile
      |> Ash.Changeset.for_update(:update, %{enabled: true}, actor: actor)
      |> Ash.update(actor: actor)

    assert {:ok, _} =
             Packages.revoke(package.id, %{denied_reason: "revoked"}, actor: actor)

    assert [%{enabled: false}] = snmp_profiles_for(package.id, actor)

    assert {:ok, restaged} = Packages.restage(package.id, actor: actor)
    assert restaged.status == :staged
    assert [%{enabled: false}] = snmp_profiles_for(package.id, actor)

    [profile] = snmp_profiles_for(package.id, actor)

    {:ok, _} =
      profile
      |> Ash.Changeset.for_update(:update, %{enabled: true}, actor: actor)
      |> Ash.update(actor: actor)

    assert {:ok, denied} =
             Packages.deny(package.id, %{denied_reason: "denied"}, actor: actor)

    assert denied.status == :denied
    assert [%{enabled: false}] = snmp_profiles_for(package.id, actor)
  end

  test "re-approving after revoke does not re-arm plugin SNMP profiles" do
    actor = system_actor()
    package = create_snmp_package()

    assert {:ok, _} = Packages.approve(package.id, %{}, actor: actor)
    [profile] = snmp_profiles_for(package.id, actor)

    {:ok, _} =
      profile
      |> Ash.Changeset.for_update(:update, %{enabled: true}, actor: actor)
      |> Ash.update(actor: actor)

    assert {:ok, _} =
             Packages.revoke(package.id, %{denied_reason: "revoked"}, actor: actor)

    assert {:ok, _} = Packages.restage(package.id, actor: actor)
    assert {:ok, _} = Packages.approve(package.id, %{}, actor: actor)
    assert [%{enabled: false}] = snmp_profiles_for(package.id, actor)
  end

  defp register_control_session!(agent_uid, partition_id) do
    if !ProcessRegistry.registry_present?() do
      start_supervised!(
        {Horde.Registry,
         name: ProcessRegistry.registry_name(),
         keys: :unique,
         members: :auto,
         delta_crdt_options: [sync_interval: 100, max_sync_size: 200]}
      )
    end

    assert {:ok, _pid} =
             ProcessRegistry.register(
               {:agent_control, partition_id, agent_uid, node()},
               %{
                 agent_id: agent_uid,
                 partition_id: partition_id,
                 gateway_node: node(),
                 capabilities: ["wasm"]
               }
             )

    assert_control_partition(agent_uid, partition_id, 40)
  end

  defp assert_control_partition(_agent_uid, _partition_id, 0), do: flunk("control-session partition did not converge")

  defp assert_control_partition(agent_uid, partition_id, attempts) do
    case AgentCommandBus.resolve_control_session_evidence(partition_id, agent_uid, nil) do
      {:ok, %{agent_id: ^agent_uid, partition_id: ^partition_id}} ->
        :ok

      _other ->
        Process.sleep(10)
        assert_control_partition(agent_uid, partition_id, attempts - 1)
    end
  end

  def first_party_release(tag \\ "v1.0.1") do
    index_url =
      "https://github.com/carverauto/serviceradar/releases/download/#{tag}/serviceradar-wasm-plugin-index.json"

    %{
      "tag_name" => tag,
      "name" => "ServiceRadar #{tag}",
      "html_url" => "https://github.com/carverauto/serviceradar/releases/tag/#{tag}",
      "assets" => [
        %{
          "name" => "serviceradar-wasm-plugin-index.json",
          "url" => index_url,
          "browser_download_url" => index_url
        }
      ]
    }
  end

  def first_party_index(tag \\ "v1.0.1") do
    suffix = if tag == "v1.0.1", do: "", else: "-#{tag}"

    %{
      "schema_version" => 1,
      "plugins" => [
        %{
          "plugin_id" => "first-party-dedupe",
          "name" => "First-party Dedupe",
          "version" => "1.0.1",
          "bundle_url" =>
            "https://github.com/carverauto/serviceradar/releases/download/#{tag}/first-party-dedupe#{suffix}.zip",
          "upload_signature_url" =>
            "https://github.com/carverauto/serviceradar/releases/download/#{tag}/first-party-dedupe#{suffix}.upload-signature.json",
          "bundle_digest" => Storage.sha256(first_party_bundle(tag)),
          "oci_ref" => "registry.carverauto.dev/serviceradar/wasm-plugin-first-party-dedupe:v1.0.1"
        }
      ]
    }
  end

  def first_party_bundle(tag \\ "v1.0.1") do
    cache_key = {:first_party_package_bundle, tag}

    case Process.get(cache_key) ||
           if(tag == "v1.0.1", do: Process.get(:first_party_package_bundle)) do
      nil ->
        path =
          Path.join(
            System.tmp_dir!(),
            "first-party-dedupe-#{System.unique_integer([:positive])}.zip"
          )

        try do
          {:ok, _zip} =
            :zip.create(String.to_charlist(path), [
              {~c"plugin.yaml", @first_party_manifest_yaml},
              {~c"plugin.wasm", first_party_wasm(tag)}
            ])

          payload = File.read!(path)
          Process.put(cache_key, payload)
          if tag == "v1.0.1", do: Process.put(:first_party_package_bundle, payload)
          payload
        after
          File.rm(path)
        end

      payload ->
        payload
    end
  end

  def first_party_wasm("v1.0.1"), do: @first_party_wasm
  def first_party_wasm(tag), do: "#{@first_party_wasm} #{tag}"

  def first_party_upload_signature(tag \\ "v1.0.1") do
    cache_key = {:first_party_package_signature, tag}

    case Process.get(cache_key) ||
           if(tag == "v1.0.1", do: Process.get(:first_party_package_signature)) do
      nil ->
        signature =
          @first_party_manifest
          |> UploadSignature.verification_payload(Storage.sha256(first_party_wasm(tag)))
          |> then(&:crypto.sign(:eddsa, :none, &1, [Process.get(:first_party_private_key), :ed25519]))
          |> Base.encode64()

        payload = %{
          "algorithm" => "ed25519",
          "key_id" => "packages-test",
          "signature" => signature
        }

        Process.put(cache_key, payload)
        if tag == "v1.0.1", do: Process.put(:first_party_package_signature, payload)
        payload

      payload ->
        payload
    end
  end

  defp create_plugin(plugin_id \\ "unifi-protect-camera") do
    Plugin
    |> Ash.Changeset.for_create(
      :create,
      %{
        plugin_id: plugin_id,
        name: "UniFi Protect Camera",
        description: "Test plugin"
      },
      actor: system_actor()
    )
    |> Ash.create!()
  end

  defp create_package(plugin_id \\ "unifi-protect-camera", version \\ "0.1.0") do
    manifest = %{@manifest | "id" => plugin_id, "version" => version}

    PluginPackage
    |> Ash.Changeset.for_create(
      :create,
      %{
        plugin_id: plugin_id,
        name: "UniFi Protect Camera",
        version: version,
        entrypoint: "run_check",
        outputs: "serviceradar.plugin_result.v1",
        manifest: manifest,
        config_schema: %{},
        signature: %{},
        source_type: :github,
        source_commit: "test-#{plugin_id}-#{version}"
      },
      actor: system_actor()
    )
    |> Ash.create!()
  end

  defp create_snmp_package do
    suffix = System.unique_integer([:positive])
    plugin_id = "snmp-req-pkg-#{suffix}"
    name = "SNMP Req #{suffix}"
    requirement = snmp_requirement()
    manifest = Map.merge(@manifest, %{"id" => plugin_id, "name" => name, "snmp_requirements" => [requirement]})

    create_plugin(plugin_id)

    PluginPackage
    |> Ash.Changeset.for_create(
      :create,
      %{
        plugin_id: plugin_id,
        name: name,
        version: "0.1.0",
        entrypoint: "run_check",
        outputs: "serviceradar.plugin_result.v1",
        manifest: manifest,
        snmp_requirements: [requirement],
        config_schema: %{},
        signature: %{},
        source_type: :github,
        source_commit: "test-#{plugin_id}-0.1.0"
      },
      actor: system_actor()
    )
    |> Ash.create!()
  end

  defp snmp_requirement do
    %{
      "name" => "clearpass-node-health",
      "description" => "Node health from CLEARPASS-MIB.",
      "category" => "system",
      "default_poll_interval_seconds" => 300,
      "target_hint" => "in:devices device_type:clearpass",
      "oids" => [
        %{
          "oid" => ".1.3.6.1.4.1.14823.1.6.1.1.1.1.1.16.0",
          "name" => "node_cpu_pct",
          "data_type" => "gauge"
        }
      ]
    }
  end

  defp snmp_profiles_for(package_id, actor) do
    {:ok, rows} =
      SNMPProfile
      |> Ash.Query.filter(plugin_package_id == ^package_id)
      |> Ash.read(actor: actor)

    rows
  end

  defp snmp_templates_for(package_id, actor) do
    {:ok, rows} =
      SNMPOIDTemplate
      |> Ash.Query.filter(plugin_package_id == ^package_id)
      |> Ash.read(actor: actor)

    rows
  end

  defp restore_system_env(key, nil), do: System.delete_env(key)
  defp restore_system_env(key, value), do: System.put_env(key, value)
end
