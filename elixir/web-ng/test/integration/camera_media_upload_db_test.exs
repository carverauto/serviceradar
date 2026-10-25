defmodule ServiceRadarWebNG.CameraMediaUploadDBTest do
  use ServiceRadarWebNG.DataCase, async: false

  import Plug.Conn
  import Plug.Test

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Camera.ArchiveBinding
  alias ServiceRadar.Camera.ArchiveUploadDispatch
  alias ServiceRadar.Camera.ArchiveUploadIntent
  alias ServiceRadar.Camera.RecorderOwnership
  alias ServiceRadar.Camera.RecordingBlock
  alias ServiceRadar.Camera.RecordingBlocks
  alias ServiceRadar.Camera.RecordingDescriptor
  alias ServiceRadar.Test.CameraRelayFixtures, as: Fixtures
  alias ServiceRadarCoreElx.CameraRecording.MediaUpload
  alias ServiceRadarCoreElx.CameraRecording.Spool
  alias ServiceRadarCoreElx.CameraRecording.Storage
  alias ServiceRadarCoreElx.CameraStorage.Config
  alias ServiceRadarCoreElx.Test.StorageHTTPFixture, as: Provider
  alias ServiceRadarWebNG.ArchiveStorageHTTP
  alias ServiceRadarWebNGWeb.ControlPlaneRuntimeRouter

  require Ash.Query

  @moduletag :web_ng_shared_fixture_db
  @moduletag :tmp_dir
  @moduletag sandbox: :unboxed
  @moduletag timeout: 120_000

  @bytes :binary.copy("invented joined media;", 7000)
  @admin_token "synthetic-joined-media-administration-token"
  @account_token "synthetic-joined-account-administration-token"
  @recorder_token "synthetic-joined-recorder-to-storage-token"

  setup %{tmp_dir: directory} do
    {:ok, _} = Application.ensure_all_started(:ssl)
    installation = ArchiveStorageHTTP.installation(directory)
    origin = %{deployment_ref: installation.document["deployment_ref"], generation: 1}
    preserve_configuration()

    Application.put_env(:serviceradar_web_ng, :control_plane_runtime,
      token: @account_token,
      media: [token: @admin_token, deployment_ref: origin.deployment_ref, generation: "1"]
    )

    Fixtures.preserve_recording_control()
    context = Fixtures.context()

    destination =
      Ecto.UUID.generate() |> Fixtures.archive_destination() |> Map.put("endpoint", "https://objects.example.test")

    {:ok, binding} = ArchiveBinding.register(destination, context.opts)
    on_exit(fn -> cleanup_archive(context.source.id, binding.id) end)
    spool = Path.join(directory, "spool")
    File.mkdir!(spool)
    File.chmod!(spool, 0o700)
    {block, block_directory} = frozen_block(context, spool)
    Application.put_env(:serviceradar_core_elx, :camera_recording_storage_id, block.storage_id)

    runtime = ArchiveStorageHTTP.start!(installation)
    certificates = certificates()
    store = start_supervised!({Agent, fn -> %{requests: [], object: nil} end})

    provider_port =
      Provider.start(certificates.server_config, fn request ->
        # This independent connection must see the real committed grant before
        # provider bytes arrive. The fixture supplies no core response or grant.
        grant =
          ServiceRadar.Repo.query!(
            "SELECT d.id, d.marked_at, d.media_authority_revision, d.media_verified_at " <>
              "FROM platform.camera_archive_upload_dispatches d " <>
              "JOIN platform.camera_archive_upload_intents i ON i.id = d.archive_upload_intent_id " <>
              "WHERE i.recording_block_id = $1 AND i.object_role = 'media'",
            [Ecto.UUID.dump!(block.id)]
          ).rows

        Agent.get_and_update(store, &provider(&1, Map.put(request, :grant, grant)))
      end)

    desired = desired(binding, block, destination, installation.document)
    storage_port = free_port()
    config = storage_config(directory, runtime, certificates, desired, storage_port)

    config =
      put_in(
        config.provider,
        Map.merge(config.provider, %{proxy: Provider.proxy(provider_port), cacerts: certificates.client_config[:cacerts]})
      )

    peer_directory = Path.join(directory, "isolated-storage")
    File.mkdir!(peer_directory)
    peer = start_storage_peer(config, peer_directory)
    pending = admin(:get, origin, binding.id)
    assert pending["state"] == "pending"
    assert is_binary(pending["nonce"])

    applied = admin(:put, origin, binding.id, %{"schema_version" => 1, "desired" => desired, "nonce" => pending["nonce"]})
    assert applied["state"] == "applied"
    assert applied["archive_readiness"] == "unavailable"

    recorder = %{
      "schema_version" => 1,
      "spool_root" => spool,
      "binding_id" => binding.id,
      "storage" =>
        directory
        |> tls_files("recorder", certificates.client_config)
        |> Map.merge(%{
          "base_url" => "https://localhost:#{storage_port}",
          "token_file" => write_file(directory, "recorder-token", @recorder_token)
        })
    }

    System.put_env("VMS_MEDIA_UPLOAD_CONFIG", write_file(directory, "recorder.json", Jason.encode!(recorder)))
    Map.merge(context, %{block: block, binding: binding, directory: block_directory, store: store, peer: peer})
  end

  test "the real recorder and isolated HTTPS service retain verified media through committed core grants", context do
    before = directory_bytes(context.directory)
    assert {:ok, result} = MediaUpload.upload_once(context.block.id)
    dispatch = dispatch(context)

    assert result == %{
             "schema_version" => 1,
             "status" => "media_verified",
             "dispatch_id" => dispatch.id,
             "recording_readiness" => "unavailable",
             "archive_readiness" => "unavailable"
           }

    assert dispatch.dispatcher_actor_id == SystemActor.system(:camera_archive_storage).id
    assert dispatch.marked_at && dispatch.media_verified_at
    assert dispatch.media_verification["byte_length"] == byte_size(@bytes)
    assert dispatch.media_verification["object_sha256"] == digest(@bytes)
    assert dispatch.media_verification["etag"] == ~s("joined-media-etag")
    assert dispatch.media_verification["version_id"] == "joined-version-1"
    assert dispatch.media_verification["encryption"] == "AES256"
    assert is_nil(dispatch.init_verified_at) && is_nil(dispatch.init_authority_revision)
    assert is_nil(dispatch.media_verification_conflict_at) && is_nil(dispatch.conflict_at)
    assert {:ok, %{state: :sealed, descriptor: descriptor}} = Ash.get(RecordingBlock, context.block.id, context.opts)
    assert descriptor == context.block.descriptor
    assert {:ok, %{capability_state: :unqualified}} = Ash.get(ArchiveBinding, context.binding.id, context.opts)
    assert directory_bytes(context.directory) == before

    assert [put, head, get] = Agent.get(context.store, &Enum.reverse(&1.requests))
    assert Enum.map([put, head, get], & &1.method) == ["PUT", "HEAD", "GET"]
    assert put.body == @bytes
    assert put.target == "/example-recordings/recordings/v1/#{context.block.block_key}/media.m4s"
    assert put.headers["if-none-match"] == "*"
    assert put.headers["x-amz-server-side-encryption"] == "AES256"
    assert put.headers["authorization"] =~ "AWS4-HMAC-SHA256 "
    assert [[grant_id, marked_at, 1, nil]] = put.grant
    assert Ecto.UUID.load!(grant_id) == dispatch.id
    assert marked_at
    assert head.target == put.target <> "?versionId=joined-version-1"
    assert get.target == head.target

    assert {:error, :media_upload_unavailable} = MediaUpload.upload_once(context.block.id)
    assert Agent.get(context.store, &length(&1.requests)) == 3
    retained = dispatch(context)
    assert retained.id == dispatch.id && retained.marked_at == dispatch.marked_at
    assert retained.media_verification == dispatch.media_verification
    assert retained.media_verified_at == dispatch.media_verified_at
    assert {:ok, %{state: :sealed}} = Ash.get(RecordingBlock, context.block.id, context.opts)
    assert directory_bytes(context.directory) == before
  end

  test "same-length substituted local bytes cannot obtain a real grant or send a provider request", context do
    File.write!(Path.join(context.directory, "media.m4s"), :binary.copy("x", byte_size(@bytes)))
    before = directory_bytes(context.directory)

    assert {:error, :media_upload_unavailable} = MediaUpload.upload_once(context.block.id)
    retained = dispatch(context)
    assert is_nil(retained.marked_at)
    assert is_nil(retained.media_authority_revision)
    assert is_nil(retained.media_verified_at)
    assert is_nil(retained.response_at)
    assert Agent.get(context.store, & &1.requests) == []
    assert {:ok, %{state: :sealed}} = Ash.get(RecordingBlock, context.block.id, context.opts)
    assert directory_bytes(context.directory) == before
  end

  defp start_storage_peer(config, directory) do
    {:ok, peer, _} = :peer.start_link(%{connection: :standard_io, args: [~c"+S", ~c"2:2"]})
    Process.unlink(peer)

    on_exit(fn ->
      monitor = Process.monitor(peer)

      :peer.call(
        peer,
        Code,
        :eval_string,
        [
          "if pid = Process.whereis(ServiceRadarCoreElx.CameraStorage.Service), do: Supervisor.stop(pid, :normal, 5000)"
        ],
        10_000
      )

      refute File.exists?(Path.join(directory, "vms-media-staging"))
      :peer.stop(peer)
      assert_receive {:DOWN, ^monitor, :process, ^peer, :normal}, 10_000
    end)

    :ok = :peer.call(peer, :code, :add_paths, [:code.get_path()])
    {:ok, _} = :peer.call(peer, Application, :ensure_all_started, [:elixir])
    {:ok, _} = :peer.call(peer, Application, :ensure_all_started, [:ssl])
    :ok = :peer.call(peer, System, :put_env, ["TMPDIR", directory])

    {isolation, _} =
      :peer.call(
        peer,
        Code,
        :eval_string,
        [
          """
          {:ok, supervisor} = ServiceRadarCoreElx.CameraStorage.Service.start_link(config)
          Process.unlink(supervisor)
          _ = :sys.get_state(ServiceRadarCoreElx.CameraStorage.Session)
          %{distributed: Node.alive?(), repo: Process.whereis(ServiceRadar.Repo),
            applications: Enum.map(Application.started_applications(), &elem(&1, 0))}
          """,
          [config: config]
        ],
        15_000
      )

    assert isolation.distributed == false
    assert isolation.repo == nil
    refute :serviceradar_core in isolation.applications
    refute :serviceradar_core_elx in isolation.applications
    peer
  end

  defp frozen_block(context, root) do
    {:ok, relay} = Fixtures.open(context)
    {:ok, relay} = Fixtures.activate(context, relay)
    owner = Fixtures.owner(context)

    {:ok, claim} =
      RecorderOwnership.acquire(
        owner,
        Ecto.UUID.generate(),
        relay.media_ingest_id,
        Ecto.UUID.generate(),
        30_000,
        context.opts
      )

    clock = %{
      "clock_epoch" => "synthetic-joined-clock",
      "timebase" => 90_000,
      "dts_source" => "pts_no_reordering",
      "utc_mapping" => "unknown"
    }

    {:ok, block} = RecorderOwnership.reserve_block(owner, claim, clock, context.opts)

    {:ok, storage} = Storage.initialize(root, block.storage_id)
    {:ok, spool} = Spool.create(storage, RecordingBlock.identity(block), "i")
    {:ok, spool, _} = Spool.append(spool, @bytes, %{start_ns: 0, duration_ns: 1_000_000_000})
    {:ok, spool} = Spool.seal(spool)
    format = %{sha256: digest("i"), timescale: 90_000, codecs: %{avc1: %{profile: 66, compatibility: 192, level: 10}}}
    {:ok, descriptor} = RecordingDescriptor.from_snapshot(Spool.snapshot(spool), format)
    {:ok, block} = RecordingBlocks.freeze(owner, claim, block, descriptor, context.opts)
    {:ok, :released} = RecorderOwnership.release(owner, claim, context.opts)
    {block, Spool.snapshot(spool).directory}
  end

  defp desired(binding, block, destination, installation) do
    now = System.system_time(:millisecond)

    %{
      "schema_version" => 1,
      "revision" => "1",
      "binding_id" => binding.id,
      "local_storage_id" => block.storage_id,
      "operation" => "media_put_verified_v1",
      "protection_mode" => "sse_s3_aes256",
      "limits" => %{"max_media_bytes" => 1_048_576, "max_operation_ms" => 30_000, "max_in_flight" => 1},
      "qualification_report" => %{
        "schema_version" => 1,
        "binding_id" => binding.id,
        "destination" => destination,
        "provider_resource_id" => "synthetic-joined-resource",
        "endpoint_type" => "synthetic-s3",
        "credential" => %{
          "reference" => installation["credential_reference"],
          "generation" => 1,
          "storage_service_id" => installation["storage_service_id"]
        },
        "policy_revision" => "synthetic-joined-policy",
        "operation_mode" => "mediated_immutable_archive_v1",
        "issued_at_ms" => now - 1000,
        "expires_at_ms" => now + 60_000,
        "result_ref" => "synthetic-joined-evidence",
        "checks" =>
          Map.new(
            ~w(intended_operations anonymous_access_denied foreign_environment_access_denied recorder_privilege_boundary reader_privilege_boundary private_acl_policy endpoint_tls_redirect_boundary browser_cors put_aes256_attestation multipart_aes256_attestation put_missing_aes256_denied put_noncompliant_aes256_denied multipart_missing_aes256_denied multipart_noncompliant_aes256_denied atomic_put_no_overwrite atomic_completion_no_overwrite integrity_object_identity conditional_ranges multipart_recovery),
            &{&1, "passed"}
          )
      }
    }
  end

  defp storage_config(directory, runtime, certificates, desired, port) do
    runtime_tls = tls_files(directory, "runtime-client", runtime.client)
    listener_tls = tls_files(directory, "storage-server", certificates.server_config)

    credential = %{
      "reference" => runtime.document["credential_reference"],
      "generation" => 1,
      "access_key_id" => "synthetic-joined-writer",
      "secret_access_key" => "invented-joined-key-material"
    }

    document = %{
      "schema_version" => 1,
      "deployment_ref" => runtime.document["deployment_ref"],
      "generation" => "1",
      "desired" => desired,
      "provider_credentials_file" => write_file(directory, "provider.json", Jason.encode!(credential)),
      "listener" =>
        Map.merge(listener_tls, %{
          "port" => port,
          "token_file" => write_file(directory, "recorder-token", @recorder_token),
          "recorder_certificate_sha256" => digest(certificates.client_config[:cert])
        }),
      "runtime" =>
        Map.merge(runtime_tls, %{
          "base_url" => "https://localhost:#{runtime.port}",
          "token_file" => write_file(directory, "runtime-token", runtime.token)
        })
    }

    assert {:ok, config} = Config.load(write_file(directory, "storage.json", Jason.encode!(document)))
    config
  end

  defp certificates do
    algorithm = [digest: :sha256, key: {:namedCurve, :secp256r1}]
    san = {:Extension, {2, 5, 29, 17}, false, [dNSName: ~c"localhost", dNSName: ~c"objects.example.test"]}

    :public_key.pkix_test_data(%{
      server_chain: %{root: algorithm, intermediates: [], peer: algorithm ++ [extensions: [san]]},
      client_chain: %{root: algorithm, intermediates: [], peer: algorithm}
    })
  end

  defp tls_files(directory, name, tls) do
    {type, key} = tls[:key]

    %{
      "certfile" =>
        write_file(directory, name <> ".crt", :public_key.pem_encode([{:Certificate, tls[:cert], :not_encrypted}])),
      "keyfile" => write_file(directory, name <> ".key", :public_key.pem_encode([{type, key, :not_encrypted}])),
      "cacertfile" =>
        write_file(
          directory,
          name <> "-ca.crt",
          :public_key.pem_encode(Enum.map(tls[:cacerts], &{:Certificate, &1, :not_encrypted}))
        )
    }
  end

  defp provider(state, request) do
    state = %{state | requests: [request | state.requests]}

    headers = %{
      "etag" => ~s("joined-media-etag"),
      "x-amz-version-id" => "joined-version-1",
      "x-amz-server-side-encryption" => "AES256"
    }

    case request.method do
      "PUT" ->
        {{200, headers, ""}, %{state | object: request.body}}

      "HEAD" ->
        {{200, Map.put(headers, "content-length", Integer.to_string(byte_size(state.object))), ""}, state}

      "GET" ->
        {{206, Map.put(headers, "content-range", "bytes 0-#{byte_size(state.object) - 1}/#{byte_size(state.object)}"),
          state.object}, state}
    end
  end

  defp dispatch(context) do
    [intent] = ArchiveUploadIntent |> Ash.Query.filter(recording_block_id == ^context.block.id) |> Ash.read!(context.opts)
    assert intent.object_role == :media

    [dispatch] =
      ArchiveUploadDispatch |> Ash.Query.filter(archive_upload_intent_id == ^intent.id) |> Ash.read!(context.opts)

    dispatch
  end

  defp admin(method, origin, id, body \\ %{}) do
    response =
      method
      |> conn("/v1/media/media-authorities/" <> id, Jason.encode!(body))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-serviceradar-control-plane-authorization", "Bearer " <> @admin_token)
      |> put_req_header("x-serviceradar-deployment-ref", origin.deployment_ref)
      |> put_req_header("x-serviceradar-media-generation", "1")
      |> ControlPlaneRuntimeRouter.call([])

    assert response.status == 200
    Jason.decode!(response.resp_body)
  end

  defp cleanup_archive(source_id, binding_id) do
    source = Ecto.UUID.dump!(source_id)
    binding = Ecto.UUID.dump!(binding_id)

    %{rows: dispatches} =
      ServiceRadar.Repo.query!(
        "DELETE FROM platform.camera_archive_upload_dispatches WHERE archive_upload_intent_id IN " <>
          "(SELECT i.id FROM platform.camera_archive_upload_intents i JOIN platform.camera_recording_blocks b " <>
          "ON b.id = i.recording_block_id WHERE b.camera_source_id = $1) RETURNING id",
        [source]
      )

    ServiceRadar.Repo.query!(
      "DELETE FROM platform.camera_archive_upload_intents WHERE recording_block_id IN (SELECT id FROM platform.camera_recording_blocks WHERE camera_source_id = $1)",
      [source]
    )

    ServiceRadar.Repo.query!("DELETE FROM platform.camera_recording_blocks WHERE camera_source_id = $1", [source])

    ServiceRadar.Repo.query!("DELETE FROM platform.camera_archive_media_authorities WHERE archive_binding_id = $1", [
      binding
    ])

    ServiceRadar.Repo.query!("DELETE FROM platform.camera_archive_bindings WHERE id = $1", [binding])

    assert %{rows: [[0, 0, 0, 0, 0]]} =
             ServiceRadar.Repo.query!(
               "SELECT (SELECT count(*) FROM platform.camera_archive_upload_dispatches WHERE id = ANY($1::uuid[])), " <>
                 "(SELECT count(*) FROM platform.camera_archive_upload_intents WHERE archive_binding_id = $2), " <>
                 "(SELECT count(*) FROM platform.camera_recording_blocks WHERE camera_source_id = $3), " <>
                 "(SELECT count(*) FROM platform.camera_archive_media_authorities WHERE archive_binding_id = $2), " <>
                 "(SELECT count(*) FROM platform.camera_archive_bindings WHERE id = $2)",
               [List.flatten(dispatches), binding, source]
             )
  end

  defp preserve_configuration do
    runtime = Application.get_env(:serviceradar_web_ng, :control_plane_runtime)
    storage_id = Application.get_env(:serviceradar_core_elx, :camera_recording_storage_id)
    recorder = System.get_env("VMS_MEDIA_UPLOAD_CONFIG")

    on_exit(fn ->
      restore_application(:serviceradar_web_ng, :control_plane_runtime, runtime)
      restore_application(:serviceradar_core_elx, :camera_recording_storage_id, storage_id)

      if recorder,
        do: System.put_env("VMS_MEDIA_UPLOAD_CONFIG", recorder),
        else: System.delete_env("VMS_MEDIA_UPLOAD_CONFIG")
    end)
  end

  defp restore_application(app, key, nil), do: Application.delete_env(app, key)
  defp restore_application(app, key, value), do: Application.put_env(app, key, value)
  defp directory_bytes(path), do: Map.new(File.ls!(path), &{&1, File.read!(Path.join(path, &1))})
  defp digest(bytes), do: :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)

  defp write_file(directory, name, bytes) do
    path = Path.join(directory, name)
    File.write!(path, bytes)
    path
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, {_, port}} = :inet.sockname(socket)
    :ok = :gen_tcp.close(socket)
    port
  end
end
