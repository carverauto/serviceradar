defmodule ServiceRadarWebNG.Plugins.PackagesTest do
  use ServiceRadarWebNG.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import ServiceRadarWebNG.AshTestHelpers, only: [admin_user_fixture: 0, system_actor: 0]

  alias Oban.Job
  alias ServiceRadar.Plugins.Plugin
  alias ServiceRadar.Plugins.PluginAssignment
  alias ServiceRadar.Plugins.PluginPackage
  alias ServiceRadar.Repo
  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.Plugins.FirstPartySyncWorker
  alias ServiceRadarWebNG.Plugins.Packages
  alias ServiceRadarWebNG.Plugins.Storage
  alias ServiceRadarWebNG.Plugins.UploadSignature

  require Ash.Query

  @repo_url "https://code.carverauto.dev/carverauto/serviceradar"
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
        String.contains?(url, "/api/v1/repos/carverauto/serviceradar/releases?per_page=") ->
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

        String.contains?(url, "/api/v1/repos/carverauto/serviceradar/releases/tags/v1.0.1") ->
          {:ok, %Req.Response{status: 200, body: PackagesTest.first_party_release("v1.0.1")}}

        String.contains?(url, "/api/v1/repos/carverauto/serviceradar/releases/tags/v1.0.2") ->
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
    opts = [actor: system_actor(), repo_url: @repo_url, limit: 10]

    assert {:ok, %{imported: 1, failed: []}} = Packages.sync_first_party_plugins(opts)
    assert {:ok, %{imported: 1, failed: []}} = Packages.sync_first_party_plugins(opts)

    packages = Packages.list(%{"plugin_id" => "first-party-dedupe"}, actor: system_actor())
    assert [%PluginPackage{} = package] = packages
    assert package.source_type == :first_party
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

    assignment =
      PluginAssignment
      |> Ash.Changeset.for_create(
        :create,
        %{
          agent_uid: agent_uid,
          plugin_package_id: approved_old.id,
          enabled: true,
          interval_seconds: 60,
          timeout_seconds: 10,
          params: %{}
        },
        actor: system_actor()
      )
      |> Ash.create!()

    assert {:ok, approved_new} = Packages.approve(new_package.id, %{}, actor: system_actor())

    reloaded_assignment =
      PluginAssignment
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(id == ^assignment.id)
      |> Ash.read_one!(actor: system_actor())

    assert reloaded_assignment.enabled == true

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

  def first_party_release(tag \\ "v1.0.1") do
    %{
      "tag_name" => tag,
      "name" => "ServiceRadar #{tag}",
      "html_url" => "https://code.carverauto.dev/carverauto/serviceradar/releases/tag/#{tag}",
      "assets" => [
        %{
          "name" => "serviceradar-wasm-plugin-index.json",
          "browser_download_url" =>
            "https://code.carverauto.dev/carverauto/serviceradar/releases/download/#{tag}/serviceradar-wasm-plugin-index.json"
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
            "https://code.carverauto.dev/carverauto/serviceradar/releases/download/#{tag}/first-party-dedupe#{suffix}.zip",
          "upload_signature_url" =>
            "https://code.carverauto.dev/carverauto/serviceradar/releases/download/#{tag}/first-party-dedupe#{suffix}.upload-signature.json",
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
end
