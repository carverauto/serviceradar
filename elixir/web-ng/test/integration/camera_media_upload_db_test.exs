defmodule ServiceRadarWebNG.CameraMediaUploadDBTest do
  use ServiceRadarWebNG.DataCase, async: false

  import Phoenix.ConnTest, only: [build_conn: 0, get: 2, json_response: 2]
  import Phoenix.LiveViewTest
  import Plug.Conn
  import Plug.Test

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Camera.ArchiveBinding
  alias ServiceRadar.Camera.ArchiveStorageConfig, as: Config
  alias ServiceRadar.Camera.ArchiveUploadDispatch
  alias ServiceRadar.Camera.ArchiveUploadIntent
  alias ServiceRadar.Camera.ArchiveUploads
  alias ServiceRadar.Camera.RecorderOwnership
  alias ServiceRadar.Camera.RecordingBlock
  alias ServiceRadar.Camera.RecordingBlocks
  alias ServiceRadar.Camera.RecordingControl
  alias ServiceRadar.Camera.RecordingDescriptor
  alias ServiceRadar.Camera.Source
  alias ServiceRadar.Identity.RBAC.Cache
  alias ServiceRadar.Test.CameraRelayFixtures, as: Fixtures
  alias ServiceRadarCoreElx.CameraRecording.ArchivePublication
  alias ServiceRadarCoreElx.CameraRecording.MediaUpload
  alias ServiceRadarCoreElx.CameraRecording.Spool
  alias ServiceRadarCoreElx.CameraRecording.Storage
  alias ServiceRadarCoreElx.Test.StorageHTTPFixture, as: Provider
  alias ServiceRadarWebNG.ArchiveStorageHTTP
  alias ServiceRadarWebNG.AshTestHelpers
  alias ServiceRadarWebNG.Auth.Guardian
  alias ServiceRadarWebNGWeb.ControlPlaneRuntimeRouter

  require Ash.Query

  @moduletag :web_ng_shared_fixture_db
  @moduletag :tmp_dir
  @moduletag sandbox: :unboxed
  @moduletag timeout: 120_000

  @bytes :binary.copy("invented joined media;", 7000)
  @second_bytes "independent synthetic second fragment"
  @reader_token "synthetic-joined-web-to-reader-token"
  @endpoint ServiceRadarWebNGWeb.Endpoint
  @admin_token "synthetic-joined-media-administration-token"
  @account_token "synthetic-joined-account-administration-token"
  @recorder_token "synthetic-joined-recorder-to-storage-token"

  setup %{tmp_dir: directory} = test do
    {:ok, _} = Application.ensure_all_started(:ssl)
    installation = ArchiveStorageHTTP.installation(directory)
    origin = %{deployment_ref: installation.document["deployment_ref"], generation: 1}
    preserve_configuration()

    Application.put_env(:serviceradar_web_ng, :control_plane_runtime,
      token: @account_token,
      media: [token: @admin_token, deployment_ref: origin.deployment_ref, generation: "1"]
    )

    Fixtures.preserve_recording_control(origin.deployment_ref)
    context = Fixtures.context()

    destination =
      Ecto.UUID.generate() |> Fixtures.archive_destination() |> Map.put("endpoint", "https://objects.example.test")

    {:ok, binding} = ArchiveBinding.register(destination, context.opts)
    on_exit(fn -> cleanup_archive(context.source.id, binding.id) end)
    spool = Path.join(directory, "spool")
    File.mkdir!(spool)
    File.chmod!(spool, 0o700)
    {block, block_directory} = frozen_block(context, spool, test)
    Application.put_env(:serviceradar_core_elx, :camera_recording_storage_id, block.storage_id)

    runtime = ArchiveStorageHTTP.start!(installation)
    certificates = certificates()
    store = start_supervised!({Agent, fn -> %{requests: [], objects: %{}} end})

    provider_port =
      Provider.start(certificates.server_config, fn request ->
        # This independent connection must see the real committed grant before
        # provider bytes arrive. The fixture supplies no core response or grant.
        role = request_role(request)
        grant = committed_grant(block.id, role)
        request = Map.merge(request, %{grant: grant, role: role})
        response = Agent.get_and_update(store, &provider(&1, request))

        if request.method == "GET" do
          effect = Agent.get_and_update(store, &{Map.get(&1, :read_effect), Map.delete(&1, :read_effect)})
          if effect, do: effect.()
        end

        response
      end)

    desired = desired(binding, block, destination, installation.document)
    storage_port = free_port()

    purposes =
      if test[:publication],
        do: Map.new([:init, :media, :manifest], &{&1, purpose_desired(desired, &1)}),
        else: %{media: desired}

    config = storage_config(directory, runtime, certificates, desired, storage_port, test[:publication])

    config =
      put_in(
        config.provider,
        Map.merge(config.provider, %{proxy: Provider.proxy(provider_port), cacerts: certificates.client_config[:cacerts]})
      )

    peer_directory = Path.join(directory, "isolated-storage")
    File.mkdir!(peer_directory)
    peer = start_storage_peer(config, peer_directory)

    for {kind, desired} <- purposes do
      pending = admin(:get, origin, binding.id, %{}, kind)
      assert pending["state"] == "pending"
      assert is_binary(pending["nonce"])

      applied =
        admin(:put, origin, binding.id, %{"schema_version" => 1, "desired" => desired, "nonce" => pending["nonce"]}, kind)

      assert applied["state"] == "applied"
      assert applied["archive_readiness"] == "unavailable"
    end

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

    if test[:archive_reads], do: start_reader(directory, binding, destination, provider_port, certificates)

    Map.merge(context, %{
      block: block,
      binding: binding,
      directory: block_directory,
      spool: spool,
      store: store,
      peer: peer,
      origin: origin,
      storage_port: storage_port,
      client_tls: certificates.client_config
    })
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

    assert {:error, :archive_reconciliation_required} = ArchivePublication.complete_once(context.block.id)
    assert Agent.get(context.store, & &1.requests) == []
    assert dispatch(context) == retained
    assert directory_bytes(context.directory) == before
  end

  @tag publication: true
  test "the production callers publish independent init and exact manifest proofs through one isolated service",
       context do
    before = directory_bytes(context.directory)
    token = recording_reader_token()
    path = "/api/cameras/#{context.source.id}/recordings/#{context.block.id}"
    inventory_path = "/api/cameras/#{context.source.id}/recordings"

    assert token |> recording_response(inventory_path) |> json_response(200) == %{
             "data" => %{"schema_version" => 1, "items" => [], "next_cursor" => nil}
           }

    assert token |> recording_response(path) |> json_response(200) == %{
             "data" => %{
               "schema_version" => 1,
               "block_id" => context.block.id,
               "camera_source_id" => context.source.id,
               "stream_profile_id" => context.block.stream_profile_id,
               "archive_status" => "unavailable",
               "published_at" => nil,
               "descriptor" => nil
             }
           }

    page_conn = Phoenix.ConnTest.init_test_session(build_conn(), %{"user_token" => token})
    {:ok, view, _html} = live(page_conn, "/cameras/#{context.source.id}/recordings")
    assert has_element?(view, "#camera-recordings-empty")
    refute has_element?(view, "#camera-archive-player")
    assert_no_camera_relay(context.source.id)

    assert Agent.get(context.store, & &1.requests) == []
    assert {:ok, %{"status" => "media_verified"}} = MediaUpload.upload_once(context.block.id)
    media = dispatch(context)
    assert {:ok, %{status: :init_required}} = ArchiveUploads.publication_status(context.block.id, context.opts)

    assert {:ok, receipt} = ArchivePublication.complete_once(context.block.id)
    assert_publication(context, receipt)
    assert_objects(context)
    assert dispatch(context, :media) == media
    assert directory_bytes(context.directory) == before
    assert {:ok, published} = Ash.get(RecordingBlock, context.block.id, context.opts)

    remove_local_inputs(context)
    requests = Agent.get(context.store, & &1.requests)
    assert {:ok, ^receipt} = ArchivePublication.complete_once(context.block.id)
    assert Agent.get(context.store, & &1.requests) == requests
    assert_publication(context, receipt)
    assert {:ok, ^published} = Ash.get(RecordingBlock, context.block.id, context.opts)

    response = recording_response(token, path)

    assert json_response(response, 200) == %{
             "data" => %{
               "schema_version" => 1,
               "block_id" => context.block.id,
               "camera_source_id" => context.source.id,
               "stream_profile_id" => context.block.stream_profile_id,
               "archive_status" => "available",
               "published_at" => receipt["published_at"],
               "descriptor" => context.block.descriptor
             }
           }

    assert Agent.get(context.store, & &1.requests) == requests
    assert {:ok, ^published} = Ash.get(RecordingBlock, context.block.id, context.opts)

    inventory = recording_response(token, inventory_path)

    assert json_response(inventory, 200) == %{
             "data" => %{
               "schema_version" => 1,
               "items" => [
                 %{
                   "block_id" => context.block.id,
                   "camera_source_id" => context.source.id,
                   "stream_profile_id" => context.block.stream_profile_id,
                   "published_at" => receipt["published_at"]
                 }
               ],
               "next_cursor" => nil
             }
           }

    assert get_resp_header(inventory, "cache-control") == ["private, no-store"]
    assert get_resp_header(inventory, "x-content-type-options") == ["nosniff"]
    assert recording_response(token, inventory_path <> "?limit=20").resp_body == inventory.resp_body

    view |> element("#refresh-recordings") |> render_click()
    assert has_element?(view, "#recording-#{context.block.id}")
    refute has_element?(view, "#camera-archive-player")
    view |> element("#select-recording-#{context.block.id}") |> render_click()
    assert has_element?(view, "#camera-archive-player[data-playlist-path='#{path}/playlist.m3u8?first=0&count=1']")
    assert has_element?(view, "video[data-role='archive-video'][controls][playsinline]")
    refute has_element?(view, "video[autoplay]")
    assert has_element?(view, "#previous-recording-window[disabled]")
    assert has_element?(view, "#next-recording-window[disabled]")
    assert has_element?(view, "#camera-recording-time-note", "No capture-time timeline")
    assert Agent.get(context.store, & &1.requests) == requests
    assert_no_camera_relay(context.source.id)

    {:ok, %{"sub" => "user:" <> page_user_id}} = Guardian.decode_and_verify(token)
    page_user_uuid = Ecto.UUID.dump!(page_user_id)

    assert %{num_rows: 1} =
             ServiceRadar.Repo.query!("UPDATE platform.ng_users SET role = 'viewer' WHERE id = $1", [page_user_uuid])

    Cache.put(page_user_id, MapSet.new(["devices.view", "devices.cameras.recordings.view"]))
    render_click(view, "select_recording", %{"id" => context.block.id})
    assert has_element?(view, "#camera-recordings-error", "permission")
    refute has_element?(view, "#camera-archive-player")
    assert Agent.get(context.store, & &1.requests) == requests

    assert %{num_rows: 1} =
             ServiceRadar.Repo.query!("UPDATE platform.ng_users SET role = 'admin' WHERE id = $1", [page_user_uuid])

    Cache.invalidate(page_user_id)
    view |> element("#refresh-recordings") |> render_click()
    view |> element("#select-recording-#{context.block.id}") |> render_click()
    assert has_element?(view, "#camera-archive-player")

    for query <- [
          "limit=0",
          "limit=21",
          "limit=01",
          "limit=-1",
          "limit=1.0",
          "limit=",
          "limit[]=1",
          "cursor=",
          "cursor=not-a-cursor",
          "cursor[]=x",
          "cursor=" <> String.duplicate("x", 513)
        ] do
      invalid = recording_response(token, inventory_path <> "?" <> query)
      assert json_response(invalid, 400)["error"] == "invalid_request"
      assert get_resp_header(invalid, "cache-control") == ["private, no-store"]
    end

    other_source = other_recording_source(context)
    wrong_source = recording_response(token, "/api/cameras/#{other_source.id}/recordings/#{context.block.id}")
    assert json_response(wrong_source, 404)["error"] == "recording_not_found"

    assert token |> recording_response("/api/cameras/#{other_source.id}/recordings") |> json_response(200) == %{
             "data" => %{"schema_version" => 1, "items" => [], "next_cursor" => nil}
           }

    manifest = dispatch(context, :manifest)

    assert {:error, :archive_upload_response_conflict} =
             ArchiveUploads.observe_response(
               published,
               manifest.id,
               %{"status" => 503},
               actor: SystemActor.system(:camera_archive_storage)
             )

    render_click(view, "select_recording", %{"id" => context.block.id})
    assert has_element?(view, "#camera-recordings-error", "no longer available")
    refute has_element?(view, "#camera-archive-player")
    view |> element("#refresh-recordings") |> render_click()
    assert has_element?(view, "#camera-recordings-empty")
    assert_no_camera_relay(context.source.id)

    conflicted = recording_response(token, path)

    assert json_response(conflicted, 200) == %{
             "data" => %{
               "schema_version" => 1,
               "block_id" => context.block.id,
               "camera_source_id" => context.source.id,
               "stream_profile_id" => context.block.stream_profile_id,
               "archive_status" => "reconciliation_required",
               "published_at" => nil,
               "descriptor" => nil
             }
           }

    assert {:ok, %{status: :reconciliation_required, result: ^receipt}} =
             ArchiveUploads.publication_status(context.block.id, context.opts)

    assert token |> recording_response(inventory_path) |> json_response(200) == %{
             "data" => %{"schema_version" => 1, "items" => [], "next_cursor" => nil}
           }

    assert {:ok, ^published} = Ash.get(RecordingBlock, context.block.id, context.opts)
    assert Agent.get(context.store, & &1.requests) == requests
  end

  @tag publication: true
  test "verified manifest recovery publishes after stop without recorder configuration or local spool", context do
    assert {:ok, %{"status" => "media_verified"}} = MediaUpload.upload_once(context.block.id)
    opts = [actor: SystemActor.system(:camera_archive_storage)]
    assert {:ok, lease} = RecordingBlocks.acquire_upload(context.block.id, Ecto.UUID.generate(), 30_000, opts)

    try do
      assert_storage_upload(context, :init, lease, "i")
      assert {:ok, %{bytes: bytes}} = ArchiveUploads.prepare_manifest(lease, opts)
      assert bytes == expected_manifest(context)
      assert_storage_upload(context, :manifest, lease, bytes)
    after
      assert {:ok, :released} = RecordingBlocks.release_upload(lease, opts)
    end

    assert_objects(context)

    assert {:ok, %{status: :archive_verified, result: nil}} =
             ArchiveUploads.publication_status(context.block.id, context.opts)

    assert {:ok, block} = Ash.get(RecordingBlock, context.block.id, context.opts)
    assert is_nil(block.archive_manifest_dispatch_id)
    assert is_nil(block.archive_manifest_verification_sha256)
    assert is_nil(block.archive_published_at)

    assert {:ok, %{"stop_enforced" => true}} =
             RecordingControl.stop(
               context.origin,
               %{"contract_version" => 1, "revision" => "1", "admission" => "stopped"},
               context.opts
             )

    remove_local_inputs(context)
    requests = Agent.get(context.store, & &1.requests)
    assert {:ok, receipt} = ArchivePublication.complete_once(context.block.id)
    assert_publication(context, receipt)
    assert Agent.get(context.store, & &1.requests) == requests
    assert {:ok, %{state: :sealed, upload_epoch: epoch}} = Ash.get(RecordingBlock, context.block.id, context.opts)
    assert epoch > lease.upload_epoch
  end

  @tag publication: true
  test "stopped missing init returns recording_stopped without local inputs or provider traffic", context do
    assert {:ok, %{"status" => "media_verified"}} = MediaUpload.upload_once(context.block.id)
    assert {:ok, %{status: :init_required}} = ArchiveUploads.publication_status(context.block.id, context.opts)
    requests = Agent.get(context.store, & &1.requests)
    stop_recording(context)
    remove_local_inputs(context)

    assert {:error, :recording_stopped} = ArchivePublication.complete_once(context.block.id)
    assert Agent.get(context.store, & &1.requests) == requests
    assert role_intents(context, :init) == []
    assert {:ok, %{status: :init_required}} = ArchiveUploads.publication_status(context.block.id, context.opts)
  end

  @tag publication: true
  test "stopped missing manifest returns recording_stopped without local inputs or provider traffic", context do
    assert {:ok, %{"status" => "media_verified"}} = MediaUpload.upload_once(context.block.id)
    opts = [actor: SystemActor.system(:camera_archive_storage)]
    assert {:ok, lease} = RecordingBlocks.acquire_upload(context.block.id, Ecto.UUID.generate(), 30_000, opts)

    try do
      assert_storage_upload(context, :init, lease, "i")
    after
      assert {:ok, :released} = RecordingBlocks.release_upload(lease, opts)
    end

    assert {:ok, %{status: :manifest_required}} = ArchiveUploads.publication_status(context.block.id, context.opts)
    requests = Agent.get(context.store, & &1.requests)
    stop_recording(context)
    remove_local_inputs(context)

    assert {:error, :recording_stopped} = ArchivePublication.complete_once(context.block.id)
    assert Agent.get(context.store, & &1.requests) == requests
    assert role_intents(context, :manifest) == []
    assert {:ok, %{status: :manifest_required}} = ArchiveUploads.publication_status(context.block.id, context.opts)
  end

  @tag publication: true, archive_reads: true
  test "archived fragments require current permission and proofs after isolated provider reads", context do
    token = recording_reader_token()
    path = "/api/cameras/#{context.source.id}/recordings/#{context.block.id}"
    playlist = path <> "/playlist.m3u8"
    requests = Agent.get(context.store, & &1.requests)
    assert recording_response(token, playlist).status == 409
    assert Agent.get(context.store, & &1.requests) == requests
    assert {:ok, _} = MediaUpload.upload_once(context.block.id)
    assert {:ok, _} = ArchivePublication.complete_once(context.block.id)
    remove_local_inputs(context)
    stop_recording(context)
    assert {:ok, published} = Ash.get(RecordingBlock, context.block.id, context.opts)

    requests = Agent.get(context.store, & &1.requests)
    response = recording_response(token, playlist, "application/vnd.apple.mpegurl")
    assert response.status == 200
    assert get_resp_header(response, "content-type") == ["application/vnd.apple.mpegurl"]
    assert get_resp_header(response, "x-content-type-options") == ["nosniff"]
    assert recording_response(token, playlist <> "?first=0&count=64").resp_body == response.resp_body
    assert playlist_segments(response.resp_body) == ["fragments/0", "fragments/1"]

    final_window = recording_response(token, playlist <> "?first=1&count=64")
    assert final_window.status == 200
    assert playlist_segments(final_window.resp_body) == ["fragments/1"]

    for query <- ["first=2", "first=4095"] do
      assert recording_response(token, playlist <> "?" <> query).status == 416
    end

    for query <- [
          "first=-1",
          "first=01",
          "count=01",
          "count=1.0",
          "first=",
          "count=",
          "first[]=0",
          "count[]=1",
          "count=0",
          "count=65",
          "first=4096"
        ] do
      assert recording_response(token, playlist <> "?" <> query).status == 400
    end

    unauthorized = build_conn() |> put_req_header("accept", "application/vnd.apple.mpegurl") |> get(playlist)
    assert unauthorized.status == 401
    other = other_recording_source(context)
    foreign = "/api/cameras/#{other.id}/recordings/#{context.block.id}/playlist.m3u8"
    assert recording_response(token, foreign).status == 404
    assert Agent.get(context.store, & &1.requests) == requests

    initial = recording_response(token, path <> "/init", "video/mp4")
    assert initial.status == 200
    assert initial.resp_body == "i"
    assert get_resp_header(initial, "content-type") == ["video/mp4"]
    assert get_resp_header(initial, "x-content-type-options") == ["nosniff"]

    first = recording_response(token, path <> "/fragments/0", "video/mp4")
    second = recording_response(token, path <> "/fragments/1", "video/mp4")
    assert first.status == 200
    assert first.resp_body == @bytes
    assert second.status == 200
    assert second.resp_body == @second_bytes
    [request | _] = requests = Agent.get(context.store, & &1.requests)
    total = byte_size(@bytes) + byte_size(@second_bytes)
    assert request.method == "GET"
    assert request.headers["range"] == "bytes=#{byte_size(@bytes)}-#{total - 1}"
    assert request.headers["if-match"] == ~s("joined-media-etag")
    assert request.target =~ "?versionId=joined-version-1"
    assert {:ok, ^published} = Ash.get(RecordingBlock, context.block.id, context.opts)

    for suffix <- ["/fragments/2", "/fragments/4095"] do
      assert recording_response(token, path <> suffix).status == 416
    end

    for suffix <- ["/fragments/-1", "/fragments/01", "/fragments/4096"] do
      assert recording_response(token, path <> suffix).status == 400
    end

    ranged =
      build_conn()
      |> put_req_header("authorization", "Bearer " <> token)
      |> put_req_header("range", "bytes=0-")
      |> get(path <> "/fragments/0")

    assert json_response(ranged, 400)["error"] == "invalid_request"

    playlist_ranged =
      build_conn()
      |> put_req_header("authorization", "Bearer " <> token)
      |> put_req_header("range", "bytes=0-")
      |> get(playlist)

    assert json_response(playlist_ranged, 400)["error"] == "invalid_request"
    assert Agent.get(context.store, & &1.requests) == requests

    {:ok, %{"sub" => "user:" <> user_id}} = Guardian.decode_and_verify(token)
    user_uuid = Ecto.UUID.dump!(user_id)

    Agent.update(context.store, fn state ->
      Map.put(state, :read_effect, fn ->
        assert %{num_rows: 1} =
                 ServiceRadar.Repo.query!("UPDATE platform.ng_users SET role = 'viewer' WHERE id = $1", [user_uuid])
      end)
    end)

    revoked = recording_response(token, path <> "/fragments/1")
    assert json_response(revoked, 403)["error"] == "forbidden"
    assert length(Agent.get(context.store, & &1.requests)) == length(requests) + 1
    requests = Agent.get(context.store, & &1.requests)
    assert recording_response(token, path <> "/init").status == 403
    assert recording_response(token, playlist).status == 403
    assert Agent.get(context.store, & &1.requests) == requests

    assert %{num_rows: 1} =
             ServiceRadar.Repo.query!("UPDATE platform.ng_users SET role = 'admin' WHERE id = $1", [user_uuid])

    Cache.invalidate(user_id)
    manifest = dispatch(context, :manifest)

    Agent.update(context.store, fn state ->
      Map.put(state, :read_effect, fn ->
        assert {:error, :archive_upload_response_conflict} =
                 ArchiveUploads.observe_response(published, manifest.id, %{"status" => 503},
                   actor: SystemActor.system(:camera_archive_storage)
                 )
      end)
    end)

    conflicted = recording_response(token, path <> "/fragments/0")
    assert json_response(conflicted, 409)["error"] == "recording_unavailable"
    assert length(Agent.get(context.store, & &1.requests)) == length(requests) + 1
    requests = Agent.get(context.store, & &1.requests)
    assert recording_response(token, path <> "/init").status == 409
    assert recording_response(token, playlist).status == 409
    assert Agent.get(context.store, & &1.requests) == requests
    assert {:ok, ^published} = Ash.get(RecordingBlock, context.block.id, context.opts)
  end

  @tag publication: true, archive_reads: true
  test "closing a public read cannot bypass the occupied provider slot", context do
    token = recording_reader_token()
    assert {:ok, _} = MediaUpload.upload_once(context.block.id)
    assert {:ok, _} = ArchivePublication.complete_once(context.block.id)
    remove_local_inputs(context)
    stop_recording(context)
    assert {:ok, published} = Ash.get(RecordingBlock, context.block.id, context.opts)

    server = start_supervised!({Bandit, plug: @endpoint, ip: {127, 0, 0, 1}, port: 0})
    {:ok, {_address, port}} = ThousandIsland.listener_info(server)
    path = "/api/cameras/#{context.source.id}/recordings/#{context.block.id}"
    first_path = path <> "/fragments/0"
    parent = self()
    handler = make_ref()

    :ok =
      :telemetry.attach(
        handler,
        [:phoenix, :endpoint, :start],
        fn _, _, %{conn: conn}, {parent, first_path} ->
          if conn.request_path == first_path, do: send(parent, {:archive_request_started, self()})
        end,
        {parent, first_path}
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    Agent.update(context.store, fn state ->
      Map.put(state, :read_effect, fn ->
        send(parent, {:archive_provider_waiting, self()})
        assert_receive :release_archive_read, 8_000
      end)
    end)

    requests = Agent.get(context.store, & &1.requests)
    {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 2_000)
    on_exit(fn -> :gen_tcp.close(socket) end)

    :ok =
      :gen_tcp.send(socket, [
        "GET ",
        first_path,
        " HTTP/1.1\r\nHost: localhost\r\n",
        "Authorization: Bearer ",
        token,
        "\r\nAccept: video/mp4\r\nConnection: close\r\n\r\n"
      ])

    assert_receive {:archive_request_started, owner}, 2_000
    monitor = Process.monitor(owner)
    assert_receive {:archive_provider_waiting, provider}, 5_000
    on_exit(fn -> send(provider, :release_archive_read) end)
    assert [held | ^requests] = Agent.get(context.store, & &1.requests)
    assert held.method == "GET"
    assert held.headers["range"] == "bytes=0-#{byte_size(@bytes) - 1}"
    assert :ok = :gen_tcp.close(socket)

    request = fn suffix ->
      Req.get!(
        url: "http://127.0.0.1:#{port}" <> path <> suffix,
        headers: [{"authorization", "Bearer " <> token}, {"accept", "video/mp4"}],
        retry: false,
        redirect: false,
        decode_body: false,
        receive_timeout: 2_000,
        connect_options: [timeout: 2_000]
      )
    end

    for suffix <- ["/init", "/fragments/1"] do
      response = request.(suffix)
      assert response.status == 503
      assert Jason.decode!(response.body) == %{"error" => "archive_read_unavailable"}
      assert response.headers["cache-control"] == ["private, no-store"]
      assert Agent.get(context.store, & &1.requests) == [held | requests]
    end

    send(provider, :release_archive_read)
    assert_receive {:DOWN, ^monitor, :process, ^owner, _}, 5_000

    # Public completion and isolated admission release occur in different processes.
    response =
      Enum.reduce_while(1..10, nil, fn _, _ ->
        response = request.("/fragments/1")

        if response.status == 503 do
          assert Jason.decode!(response.body) == %{"error" => "archive_read_unavailable"}
          assert response.headers["cache-control"] == ["private, no-store"]
          assert Agent.get(context.store, & &1.requests) == [held | requests]
          {:cont, nil}
        else
          {:halt, response}
        end
      end)

    assert response, "the isolated reader did not release admission after the held response completed"
    assert response.status == 200
    assert response.body == @second_bytes
    assert response.headers["content-type"] == ["video/mp4"]
    assert response.headers["cache-control"] == ["private, no-store"]
    assert [next, ^held | ^requests] = Agent.get(context.store, & &1.requests)
    assert next.method == "GET"
    assert next.headers["range"] == "bytes=#{byte_size(@bytes)}-#{byte_size(@bytes) + byte_size(@second_bytes) - 1}"
    assert {:ok, ^published} = Ash.get(RecordingBlock, context.block.id, context.opts)
  end

  @tag publication: true, archive_reads: true, hls_media: true
  test "an independent HLS consumer follows the authenticated server playlist and decodes the published colors",
       context do
    token = recording_reader_token()
    assert {:ok, _} = MediaUpload.upload_once(context.block.id)
    assert {:ok, _} = ArchivePublication.complete_once(context.block.id)
    remove_local_inputs(context)
    stop_recording(context)
    assert {:ok, published} = Ash.get(RecordingBlock, context.block.id, context.opts)

    server = start_supervised!({Bandit, plug: @endpoint, ip: {127, 0, 0, 1}, port: 0})
    {:ok, {_address, port}} = ThousandIsland.listener_info(server)
    path = "/api/cameras/#{context.source.id}/recordings/#{context.block.id}/playlist.m3u8"
    url = "http://127.0.0.1:#{port}" <> path
    requests = Agent.get(context.store, & &1.requests)

    response = recording_response(token, path)
    assert response.status == 200
    assert playlist_segments(response.resp_body) == ["fragments/0", "fragments/1", "fragments/2"]
    assert Agent.get(context.store, & &1.requests) == requests

    # These tools receive only the playlist URL. They resolve EXT-X-MAP and
    # segment URIs over the real Endpoint; no test code feeds media to a decoder.
    probe_args =
      hls_input_options(token) ++
        [
          "-select_streams",
          "v:0",
          "-show_frames",
          "-show_entries",
          "frame=best_effort_timestamp_time,width,height",
          "-of",
          "json",
          url <> "?first=1&count=1"
        ]

    assert {probe, 0} = System.cmd(media_tool("ffprobe"), probe_args)
    assert %{"frames" => frames} = Jason.decode!(probe)
    assert length(frames) == 30

    for {frame, index} <- Enum.with_index(frames) do
      assert frame["width"] == 64
      assert frame["height"] == 64
      assert abs(String.to_float(frame["best_effort_timestamp_time"]) - (2 + index / 15)) < 0.000_002
    end

    decode_args =
      ["-nostdin", "-xerror", "-filter_threads", "1"] ++
        hls_input_options(token) ++
        [
          "-i",
          url,
          "-map",
          "0:v:0",
          "-threads",
          "1",
          "-fps_mode",
          "passthrough",
          "-f",
          "rawvideo",
          "-pix_fmt",
          "rgb24",
          "pipe:1"
        ]

    assert {pixels, 0} = System.cmd(media_tool("ffmpeg"), decode_args)
    assert byte_size(pixels) == 90 * 64 * 64 * 3

    frames = for <<frame::binary-size(12_288) <- pixels>>, do: frame

    for {frame, index} <- Enum.with_index(frames) do
      channels = frame |> binary_part((32 * 64 + 32) * 3, 3) |> :binary.bin_to_list()
      expected = div(index, 30)
      assert Enum.at(channels, expected) > 220

      assert Enum.all?(Enum.reject(Enum.with_index(channels), fn {_, channel} -> channel == expected end), fn {value, _} ->
               value < 30
             end)
    end

    after_requests = Agent.get(context.store, & &1.requests)
    reads = Enum.take(after_requests, length(after_requests) - length(requests))
    assert Enum.all?(reads, &(&1.method == "GET" and &1.role in [:init, :media]))
    assert Enum.any?(reads, &(&1.role == :init))
    assert Enum.any?(reads, &(&1.role == :media))
    assert {:ok, ^published} = Ash.get(RecordingBlock, context.block.id, context.opts)
  end

  defp playlist_segments(body) do
    body |> String.split("\n", trim: true) |> Enum.reject(&String.starts_with?(&1, "#"))
  end

  defp hls_input_options(token) do
    # The checkpoint exposes complete authorized fragments, not caller byte
    # ranges or parallel prefetch. This proves a sequential HLS consumer with
    # partial requests disabled, not default FFmpeg or browser compatibility.
    # FFmpeg 7.0.2 counts the first segment open against max_reload, even for
    # VOD, so zero returns EOF before fetching media. Allow one per read_data
    # call. Its initially zero last_seq_no also counts sequence zero as a hold;
    # a limit of two permits that first read and resets on sequence advancement.
    [
      "-v",
      "error",
      "-threads",
      "1",
      "-protocol_whitelist",
      "http,tcp",
      "-rw_timeout",
      "5000000",
      "-seekable",
      "0",
      "-http_seekable",
      "0",
      "-http_multiple",
      "0",
      "-http_persistent",
      "0",
      "-seg_max_retry",
      "0",
      "-max_reload",
      "1",
      "-m3u8_hold_counters",
      "2",
      "-headers",
      "Authorization: Bearer " <> token <> "\r\n"
    ]
  end

  defp media_tool(name), do: runfile("third_party/membrane/media_test_tools/" <> name)

  defp runfile(relative) do
    Path.join([System.fetch_env!("TEST_SRCDIR"), System.fetch_env!("TEST_WORKSPACE"), relative])
  end

  defp assert_no_camera_relay(source_id) do
    assert %{rows: [[0]]} =
             ServiceRadar.Repo.query!(
               "SELECT count(*) FROM platform.camera_relay_sessions WHERE camera_source_id = $1",
               [Ecto.UUID.dump!(source_id)]
             )
  end

  defp recording_response(token, path, accept \\ "application/json") do
    response =
      build_conn() |> put_req_header("authorization", "Bearer " <> token) |> put_req_header("accept", accept) |> get(path)

    assert get_resp_header(response, "cache-control") == ["private, no-store"]
    response
  end

  defp recording_reader_token do
    user = AshTestHelpers.admin_user_fixture()

    on_exit(fn ->
      id = Ecto.UUID.dump!(user.id)
      Cache.invalidate(user.id)
      ServiceRadar.Repo.query!("DELETE FROM platform.api_tokens WHERE user_id = $1", [id])
      ServiceRadar.Repo.query!("DELETE FROM platform.ng_users WHERE id = $1", [id])

      assert %{rows: [[0, 0]]} =
               ServiceRadar.Repo.query!(
                 "SELECT (SELECT count(*) FROM platform.ng_users WHERE id = $1), " <>
                   "(SELECT count(*) FROM platform.api_tokens WHERE user_id = $1)",
                 [id]
               )
    end)

    {:ok, token, _claims} = Guardian.create_access_token(user)
    token
  end

  defp other_recording_source(context) do
    source =
      Source
      |> Ash.Changeset.for_create(:create, %{
        device_uid: context.source.device_uid,
        vendor: "synthetic",
        vendor_camera_id: Ecto.UUID.generate(),
        display_name: "Synthetic archive isolation camera"
      })
      |> Ash.create!(context.opts)

    on_exit(fn ->
      id = Ecto.UUID.dump!(source.id)
      ServiceRadar.Repo.query!("DELETE FROM platform.camera_sources WHERE id = $1", [id])

      assert %{rows: [[0]]} =
               ServiceRadar.Repo.query!("SELECT count(*) FROM platform.camera_sources WHERE id = $1", [id])
    end)

    source
  end

  defp assert_publication(context, receipt) do
    manifest = dispatch(context, :manifest)
    assert {:ok, block} = Ash.get(RecordingBlock, context.block.id, context.opts)
    assert block.state == :sealed
    assert block.descriptor == context.block.descriptor
    assert block.archive_manifest_dispatch_id == manifest.id
    assert block.archive_manifest_verification_sha256 == manifest.manifest_verification_sha256
    assert %DateTime{} = block.archive_published_at

    assert receipt == %{
             "schema_version" => 1,
             "status" => "archive_published",
             "block_id" => context.block.id,
             "manifest_dispatch_id" => manifest.id,
             "manifest_verification_sha256" => manifest.manifest_verification_sha256,
             "published_at" => DateTime.to_iso8601(block.archive_published_at),
             "recording_readiness" => "unavailable",
             "archive_readiness" => "unavailable"
           }

    assert {:ok, %{status: :available, result: ^receipt, roles: roles}} =
             ArchiveUploads.publication_status(context.block.id, context.opts)

    assert roles == %{init: :verified, media: :verified, manifest: :verified}

    assert %{rows: [[1]]} =
             ServiceRadar.Repo.query!(
               "SELECT count(*) FROM platform.camera_recording_blocks WHERE id = $1 AND archive_published_at IS NOT NULL",
               [Ecto.UUID.dump!(context.block.id)]
             )

    assert {:ok, %{capability_state: :unqualified}} = Ash.get(ArchiveBinding, context.binding.id, context.opts)
  end

  defp assert_objects(context) do
    expected = [{:media, @bytes}, {:init, "i"}, {:manifest, expected_manifest(context)}]
    requests = Agent.get(context.store, &Enum.reverse(&1.requests))
    assert length(requests) == 9
    assert Agent.get(context.store, &map_size(&1.objects)) == 3

    for {{role, bytes}, [put, head, get]} <- Enum.zip(expected, Enum.chunk_every(requests, 3)) do
      dispatch = dispatch(context, role)
      verification = Map.fetch!(dispatch, verification_field(role))
      {etag, version} = object_identity(role)

      assert Enum.map([put, head, get], & &1.method) == ["PUT", "HEAD", "GET"]
      assert Enum.map([put, head, get], & &1.role) == [role, role, role]
      assert put.body == bytes
      assert put.target == "/example-recordings/recordings/v1/#{context.block.block_key}/#{filename(role)}"
      assert put.headers["if-none-match"] == "*"
      assert put.headers["x-amz-server-side-encryption"] == "AES256"
      assert put.headers["x-amz-checksum-sha256"] == Base.encode64(:crypto.hash(:sha256, bytes))
      assert put.headers["authorization"] =~ "AWS4-HMAC-SHA256 "
      assert [[grant_id, marked_at, 1, nil]] = put.grant
      assert Ecto.UUID.load!(grant_id) == dispatch.id
      assert marked_at
      assert head.target == put.target <> "?versionId=" <> version
      assert get.target == head.target
      assert head.headers["if-match"] == etag
      assert get.headers["if-match"] == etag
      assert get.headers["range"] == "bytes=0-#{byte_size(bytes) - 1}"
      assert verification["byte_length"] == byte_size(bytes)
      assert verification["object_sha256"] == digest(bytes)
      assert verification["etag"] == etag
      assert verification["version_id"] == version
      assert verification["encryption"] == "AES256"
      assert is_nil(dispatch.conflict_at)
      assert Agent.get(context.store, &Map.fetch!(&1.objects, put.target)) == bytes
    end

    init = dispatch(context, :init)
    media = dispatch(context, :media)
    manifest = dispatch(context, :manifest)
    assert init.id != media.id && init.id != manifest.id && media.id != manifest.id
    assert init.upload_epoch > media.upload_epoch
    assert is_nil(init.media_authority_revision) && is_nil(init.media_verified_at)
    assert is_nil(media.init_authority_revision) && is_nil(media.init_verified_at)

    assert {:ok, intent} = Ash.get(ArchiveUploadIntent, manifest.archive_upload_intent_id, context.opts)
    assert intent.init_dispatch_id == init.id
    assert intent.init_verification_sha256 == init.init_verification_sha256
    assert intent.media_dispatch_id == media.id
    assert intent.media_verification_sha256 == media.media_verification_sha256
    assert intent.object_sha256 == digest(expected_manifest(context))
  end

  defp assert_storage_upload(context, role, lease, bytes) do
    wire_lease = %{
      "id" => lease.id,
      "upload_token" => lease.upload_token,
      "upload_epoch" => Integer.to_string(lease.upload_epoch),
      "descriptor_sha256" => lease.descriptor_sha256
    }

    {body, content_type, headers} =
      case role do
        :init ->
          {Jason.encode!(%{"schema_version" => 1, "lease" => wire_lease, "init_base64" => Base.encode64(bytes)}),
           "application/json", []}

        :manifest ->
          {bytes, "application/octet-stream", [{"x-serviceradar-upload-lease", Jason.encode!(wire_lease)}]}
      end

    assert {:ok, %{status: 200, body: receipt}} =
             Req.request(
               method: :post,
               url: "https://localhost:#{context.storage_port}/v1/#{role}-uploads",
               headers: [{"authorization", "Bearer " <> @recorder_token}, {"content-type", content_type}] ++ headers,
               body: body,
               retry: false,
               receive_timeout: 30_000,
               connect_options: [
                 transport_opts: context.client_tls ++ [verify: :verify_peer, server_name_indication: ~c"localhost"]
               ]
             )

    assert receipt == %{
             "schema_version" => 1,
             "status" => "#{role}_verified",
             "dispatch_id" => dispatch(context, role).id,
             "recording_readiness" => "unavailable",
             "archive_readiness" => "unavailable"
           }
  end

  defp stop_recording(context) do
    assert {:ok, %{"stop_enforced" => true}} =
             RecordingControl.stop(
               context.origin,
               %{"contract_version" => 1, "revision" => "1", "admission" => "stopped"},
               context.opts
             )
  end

  defp role_intents(context, role) do
    ArchiveUploadIntent
    |> Ash.Query.filter(recording_block_id == ^context.block.id and object_role == ^role)
    |> Ash.read!(context.opts)
  end

  defp remove_local_inputs(context) do
    File.rm!(System.fetch_env!("VMS_MEDIA_UPLOAD_CONFIG"))
    System.delete_env("VMS_MEDIA_UPLOAD_CONFIG")
    Application.delete_env(:serviceradar_core_elx, :camera_recording_storage_id)
    File.rm_rf!(context.spool)
    refute File.exists?(context.spool)
  end

  # Literal canonical v1 order and invented byte identities are independent of
  # the production manifest encoder used by both preparation and publication.
  defp expected_manifest(context) do
    identity = RecordingBlock.identity(context.block)
    prefix = "recordings/v1/#{context.block.block_key}/"

    IO.iodata_to_binary([
      ~s({"format":{"codec":"avc1.42c00a","timescale":90000},"fragments":[{"duration_ns":1000000000,"length":),
      Integer.to_string(byte_size(@bytes)),
      ~s(,"motion":"unknown","offset":0,"sequence":0,"sha256":"#{digest(@bytes)}","start_ns":0,"tail_duration_source":null}],),
      ~s("identity":{"block_sequence":#{identity["block_sequence"]},"clock":{"clock_epoch":"synthetic-joined-clock",),
      ~s("dts_source":"pts_no_reordering","timebase":90000,"utc_mapping":"unknown"},"profile":),
      Jason.encode!(identity["profile"]),
      ~s(,"recorder_epoch":#{identity["recorder_epoch"]},"source_id":),
      Jason.encode!(identity["source_id"]),
      ~s(},"init":{"etag":),
      Jason.encode!(~s("joined-init-etag")),
      ~s(,"key":"#{prefix}init.mp4","length":1,"sha256":"#{digest("i")}","version_id":"joined-init-version-1"},),
      ~s("media":{"etag":),
      Jason.encode!(~s("joined-media-etag")),
      ~s(,"key":"#{prefix}media.m4s","length":#{byte_size(@bytes)},"sha256":"#{digest(@bytes)}","version_id":"joined-version-1"},"version":1})
    ])
  end

  defp start_storage_peer(config, directory, mode \\ :upload) do
    {:ok, peer, _} = :peer.start_link(%{connection: :standard_io, args: [~c"+S", ~c"2:2"]})
    Process.unlink(peer)

    on_exit(fn ->
      monitor = Process.monitor(peer)

      :peer.call(
        peer,
        Code,
        :eval_string,
        [
          "name = if mode == :read, do: ServiceRadarCoreElx.CameraStorage.ReadService, else: ServiceRadarCoreElx.CameraStorage.Service; if pid = Process.whereis(name), do: Supervisor.stop(pid, :normal, 5000)",
          [mode: mode]
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
          {:ok, supervisor} =
            if mode == :read,
              do: ServiceRadarCoreElx.CameraStorage.Service.start_read_link(config),
              else: ServiceRadarCoreElx.CameraStorage.Service.start_link(config)
          Process.unlink(supervisor)
          session = if mode == :read, do: ServiceRadarCoreElx.CameraStorage.ReadSession, else: ServiceRadarCoreElx.CameraStorage.Session
          _ = :sys.get_state(session)
          %{distributed: Node.alive?(), repo: Process.whereis(ServiceRadar.Repo),
            applications: Enum.map(Application.started_applications(), &elem(&1, 0))}
          """,
          [config: config, mode: mode]
        ],
        15_000
      )

    assert isolation.distributed == false
    assert isolation.repo == nil
    refute :serviceradar_core in isolation.applications
    refute :serviceradar_core_elx in isolation.applications
    peer
  end

  defp frozen_block(context, root, test) do
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

    {initial, fragments, format} = recording_media(test)
    {:ok, storage} = Storage.initialize(root, block.storage_id)
    {:ok, spool} = Spool.create(storage, RecordingBlock.identity(block), initial)

    spool =
      Enum.reduce(fragments, spool, fn {bytes, metadata}, spool ->
        {:ok, spool, _} = Spool.append(spool, bytes, metadata)
        spool
      end)

    {:ok, spool} = Spool.seal(spool)
    {:ok, descriptor} = RecordingDescriptor.from_snapshot(Spool.snapshot(spool), format)
    {:ok, block} = RecordingBlocks.freeze(owner, claim, block, descriptor, context.opts)
    {:ok, :released} = RecorderOwnership.release(owner, claim, context.opts)
    {block, Spool.snapshot(spool).directory}
  end

  defp recording_media(%{hls_media: true}) do
    fixture =
      "elixir/serviceradar_core_elx/recording_browser_fixture.json" |> runfile() |> File.read!() |> Jason.decode!()

    initial = Base.decode64!(fixture["init"])
    avc = fixture["codecs"]["avc1"]
    codecs = %{avc1: %{profile: avc["profile"], compatibility: avc["compatibility"], level: avc["level"]}}
    format = %{sha256: digest(initial), timescale: 90_000, codecs: codecs}

    fragments =
      Enum.map(fixture["fragments"], fn fragment ->
        metadata = %{start_ns: fragment["start_ns"], duration_ns: fragment["duration_ns"]}

        metadata =
          if Map.has_key?(fragment, "tail_duration_source"),
            do: Map.put(metadata, :tail_duration_source, fragment["tail_duration_source"]),
            else: metadata

        {Base.decode64!(fragment["base64"]), metadata}
      end)

    {initial, fragments, format}
  end

  defp recording_media(test) do
    first = {@bytes, %{start_ns: 0, duration_ns: 1_000_000_000}}
    second = {@second_bytes, %{start_ns: 1_000_000_000, duration_ns: 1_000_000_000}}
    fragments = if test[:archive_reads], do: [first, second], else: [first]
    format = %{sha256: digest("i"), timescale: 90_000, codecs: %{avc1: %{profile: 66, compatibility: 192, level: 10}}}
    {"i", fragments, format}
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

  defp purpose_desired(desired, :media), do: desired

  defp purpose_desired(desired, role) do
    {limit, bytes, milliseconds} =
      case role do
        :init -> {"max_init_bytes", 1_048_576, 5_000}
        :manifest -> {"max_manifest_bytes", 2_097_152, 30_000}
      end

    desired
    |> Map.put("operation", "#{role}_put_verified_v1")
    |> Map.put("limits", %{limit => bytes, "max_operation_ms" => milliseconds, "max_in_flight" => 1})
  end

  defp start_reader(directory, binding, destination, provider_port, provider_certificates) do
    certificates = certificates()
    port = free_port()

    credential = %{
      "reference" => "synthetic-archive-reader",
      "generation" => 1,
      "access_key_id" => "synthetic-read-only-key",
      "secret_access_key" => "invented-read-only-key-material"
    }

    reader_token = write_file(directory, "reader-token", @reader_token)

    document = %{
      "schema_version" => 1,
      "binding_id" => binding.id,
      "destination" => destination,
      "provider_credentials_file" => write_file(directory, "reader-provider.json", Jason.encode!(credential)),
      "listener" =>
        directory
        |> tls_files("reader-server", certificates.server_config)
        |> Map.merge(%{
          "port" => port,
          "token_file" => reader_token,
          "reader_certificate_sha256" => digest(certificates.client_config[:cert])
        })
    }

    assert {:ok, config} = Config.load_read_storage(write_file(directory, "reader-storage.json", Jason.encode!(document)))

    config =
      put_in(
        config.provider,
        Map.merge(config.provider, %{
          proxy: Provider.proxy(provider_port),
          cacerts: provider_certificates.client_config[:cacerts]
        })
      )

    peer_directory = Path.join(directory, "isolated-reader")
    File.mkdir!(peer_directory)
    start_storage_peer(config, peer_directory, :read)

    client = %{
      "schema_version" => 1,
      "binding_id" => binding.id,
      "destination_sha256" => binding.destination_sha256,
      "storage" =>
        directory
        |> tls_files("reader-client", certificates.client_config)
        |> Map.merge(%{"base_url" => "https://localhost:#{port}", "token_file" => reader_token})
    }

    System.put_env("VMS_ARCHIVE_READER_CONFIG", write_file(directory, "reader-client.json", Jason.encode!(client)))
  end

  defp storage_config(directory, runtime, certificates, desired, port, publication?) do
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

    document =
      if publication? do
        document
        |> Map.put("schema_version", 2)
        |> Map.delete("desired")
        |> Map.put("purposes", Map.new([:init, :media, :manifest], &{Atom.to_string(&1), purpose_desired(desired, &1)}))
      else
        document
      end

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
    path = URI.parse(request.target).path
    {etag, version} = object_identity(request.role)

    headers = %{
      "etag" => etag,
      "x-amz-version-id" => version,
      "x-amz-server-side-encryption" => "AES256"
    }

    case request.method do
      "PUT" ->
        if request.headers["if-none-match"] == "*" and not Map.has_key?(state.objects, path) and
             map_size(state.objects) < 3 do
          {{200, headers, ""}, %{state | objects: Map.put(state.objects, path, request.body)}}
        else
          {{412, %{}, ""}, state}
        end

      "HEAD" ->
        object = Map.fetch!(state.objects, path)
        {{200, Map.put(headers, "content-length", Integer.to_string(byte_size(object))), ""}, state}

      "GET" ->
        object = Map.fetch!(state.objects, path)
        [_, first, last] = Regex.run(~r/\Abytes=(\d+)-(\d+)\z/, request.headers["range"])
        first = String.to_integer(first)
        last = String.to_integer(last)
        bytes = binary_part(object, first, last - first + 1)
        {{206, Map.put(headers, "content-range", "bytes #{first}-#{last}/#{byte_size(object)}"), bytes}, state}
    end
  end

  defp committed_grant(block_id, role) do
    {authority, verified} =
      case role do
        :init -> {"init_authority_revision", "init_verified_at"}
        :media -> {"media_authority_revision", "media_verified_at"}
        :manifest -> {"manifest_authority_revision", "manifest_verified_at"}
      end

    ServiceRadar.Repo.query!(
      "SELECT d.id, d.marked_at, d.#{authority}, d.#{verified} " <>
        "FROM platform.camera_archive_upload_dispatches d " <>
        "JOIN platform.camera_archive_upload_intents i ON i.id = d.archive_upload_intent_id " <>
        "WHERE i.recording_block_id = $1 AND i.object_role = $2",
      [Ecto.UUID.dump!(block_id), Atom.to_string(role)]
    ).rows
  end

  defp request_role(request) do
    case Path.basename(URI.parse(request.target).path) do
      "init.mp4" -> :init
      "media.m4s" -> :media
      "manifest.json" -> :manifest
    end
  end

  defp object_identity(:init), do: {~s("joined-init-etag"), "joined-init-version-1"}
  defp object_identity(:media), do: {~s("joined-media-etag"), "joined-version-1"}
  defp object_identity(:manifest), do: {~s("joined-manifest-etag"), "joined-manifest-version-1"}
  defp verification_field(:init), do: :init_verification
  defp verification_field(:media), do: :media_verification
  defp verification_field(:manifest), do: :manifest_verification
  defp filename(:init), do: "init.mp4"
  defp filename(:media), do: "media.m4s"
  defp filename(:manifest), do: "manifest.json"

  defp dispatch(context) do
    [intent] = ArchiveUploadIntent |> Ash.Query.filter(recording_block_id == ^context.block.id) |> Ash.read!(context.opts)
    assert intent.object_role == :media

    [dispatch] =
      ArchiveUploadDispatch |> Ash.Query.filter(archive_upload_intent_id == ^intent.id) |> Ash.read!(context.opts)

    dispatch
  end

  defp dispatch(context, role) do
    [intent] =
      ArchiveUploadIntent
      |> Ash.Query.filter(recording_block_id == ^context.block.id and object_role == ^role)
      |> Ash.read!(context.opts)

    [dispatch] =
      ArchiveUploadDispatch |> Ash.Query.filter(archive_upload_intent_id == ^intent.id) |> Ash.read!(context.opts)

    dispatch
  end

  defp admin(method, origin, id, body, kind) do
    response =
      method
      |> conn("/v1/media/#{kind}-authorities/" <> id, Jason.encode!(body))
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
        "SELECT id FROM platform.camera_archive_upload_dispatches WHERE archive_upload_intent_id IN " <>
          "(SELECT i.id FROM platform.camera_archive_upload_intents i JOIN platform.camera_recording_blocks b " <>
          "ON b.id = i.recording_block_id WHERE b.camera_source_id = $1)",
        [source]
      )

    ServiceRadar.Repo.query!(
      "UPDATE platform.camera_recording_blocks SET archive_manifest_dispatch_id = NULL, " <>
        "archive_manifest_verification_sha256 = NULL, archive_published_at = NULL WHERE camera_source_id = $1",
      [source]
    )

    ServiceRadar.Repo.query!(
      "DELETE FROM platform.camera_archive_upload_dispatches WHERE archive_upload_intent_id IN " <>
        "(SELECT i.id FROM platform.camera_archive_upload_intents i JOIN platform.camera_recording_blocks b " <>
        "ON b.id = i.recording_block_id WHERE b.camera_source_id = $1 AND i.object_role = 'manifest')",
      [source]
    )

    ServiceRadar.Repo.query!(
      "DELETE FROM platform.camera_archive_upload_intents WHERE object_role = 'manifest' AND recording_block_id IN " <>
        "(SELECT id FROM platform.camera_recording_blocks WHERE camera_source_id = $1)",
      [source]
    )

    ServiceRadar.Repo.query!("DELETE FROM platform.camera_archive_upload_dispatches WHERE id = ANY($1::uuid[])", [
      List.flatten(dispatches)
    ])

    ServiceRadar.Repo.query!(
      "DELETE FROM platform.camera_archive_upload_intents WHERE recording_block_id IN (SELECT id FROM platform.camera_recording_blocks WHERE camera_source_id = $1)",
      [source]
    )

    ServiceRadar.Repo.query!("DELETE FROM platform.camera_recording_blocks WHERE camera_source_id = $1", [source])

    ServiceRadar.Repo.query!("DELETE FROM platform.camera_archive_media_authorities WHERE archive_binding_id = $1", [
      binding
    ])

    ServiceRadar.Repo.query!("DELETE FROM platform.camera_archive_init_authorities WHERE archive_binding_id = $1", [
      binding
    ])

    ServiceRadar.Repo.query!("DELETE FROM platform.camera_archive_manifest_authorities WHERE archive_binding_id = $1", [
      binding
    ])

    ServiceRadar.Repo.query!("DELETE FROM platform.camera_archive_bindings WHERE id = $1", [binding])

    assert %{rows: [[0, 0, 0, 0, 0, 0, 0]]} =
             ServiceRadar.Repo.query!(
               "SELECT (SELECT count(*) FROM platform.camera_archive_upload_dispatches WHERE id = ANY($1::uuid[])), " <>
                 "(SELECT count(*) FROM platform.camera_archive_upload_intents WHERE archive_binding_id = $2), " <>
                 "(SELECT count(*) FROM platform.camera_recording_blocks WHERE camera_source_id = $3), " <>
                 "(SELECT count(*) FROM platform.camera_archive_media_authorities WHERE archive_binding_id = $2), " <>
                 "(SELECT count(*) FROM platform.camera_archive_init_authorities WHERE archive_binding_id = $2), " <>
                 "(SELECT count(*) FROM platform.camera_archive_manifest_authorities WHERE archive_binding_id = $2), " <>
                 "(SELECT count(*) FROM platform.camera_archive_bindings WHERE id = $2)",
               [List.flatten(dispatches), binding, source]
             )
  end

  defp preserve_configuration do
    runtime = Application.get_env(:serviceradar_web_ng, :control_plane_runtime)
    storage_id = Application.get_env(:serviceradar_core_elx, :camera_recording_storage_id)
    recorder = System.get_env("VMS_MEDIA_UPLOAD_CONFIG")
    reader = System.get_env("VMS_ARCHIVE_READER_CONFIG")

    on_exit(fn ->
      restore_application(:serviceradar_web_ng, :control_plane_runtime, runtime)
      restore_application(:serviceradar_core_elx, :camera_recording_storage_id, storage_id)

      if recorder,
        do: System.put_env("VMS_MEDIA_UPLOAD_CONFIG", recorder),
        else: System.delete_env("VMS_MEDIA_UPLOAD_CONFIG")

      if reader,
        do: System.put_env("VMS_ARCHIVE_READER_CONFIG", reader),
        else: System.delete_env("VMS_ARCHIVE_READER_CONFIG")
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
