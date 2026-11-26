defmodule ServiceRadarWebNGWeb.Api.CameraTimelineControllerDBTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false
  use ServiceRadarWebNG.AshTestHelpers

  alias Ecto.Adapters.SQL
  alias ServiceRadar.Camera.ArchiveDestinations
  alias ServiceRadar.Camera.CameraRecordingPolicy
  alias ServiceRadar.Camera.IngestOwnership
  alias ServiceRadar.Camera.NVRArchiveReceipt
  alias ServiceRadar.Camera.RecorderClaim
  alias ServiceRadar.Camera.RecordingAccessAudit
  alias ServiceRadar.Camera.RecordingArchiveSettings
  alias ServiceRadar.Camera.RecordingBlock
  alias ServiceRadar.Camera.RecordingBlocks
  alias ServiceRadar.Camera.RecordingCatalogEntry
  alias ServiceRadar.Camera.RecordingEventClips
  alias ServiceRadar.Camera.RecordingGap
  alias ServiceRadar.Camera.RelaySessionLifecycle
  alias ServiceRadar.Camera.RelaySessionManager
  alias ServiceRadar.Camera.Source
  alias ServiceRadar.Camera.StreamProfile
  alias ServiceRadar.Camera.VisualFrame
  alias ServiceRadar.Credentials.CredentialSecretBuilder
  alias ServiceRadar.Credentials.NativeDescriptors
  alias ServiceRadar.Credentials.NetworkCredentialSecret
  alias ServiceRadar.Identity.RBAC.Cache
  alias ServiceRadar.Identity.RoleProfile
  alias ServiceRadar.Repo
  alias ServiceRadar.Test.CameraRelayFixtures, as: Fixtures
  alias ServiceRadarRecordingMetadata.Descriptor
  alias ServiceRadarWebNG.CameraTimelineAdmission

  require Ash.Query

  @moduletag :web_ng_shared_fixture_db
  @moduletag :tmp_dir

  @registered_storage_id "00000000-0000-4000-8000-000000000051"
  @provisional_storage_id "00000000-0000-4000-8000-000000000052"
  @base_dt ~U[2026-11-16 14:00:00.000000Z]
  @base_us DateTime.to_unix(@base_dt, :microsecond)

  setup %{conn: conn, tmp_dir: directory} do
    Fixtures.recording_recovery_gate(directory)
    actor = system_actor()
    insert_local_storage_binding(@registered_storage_id)

    {viewer, viewer_profile} =
      user_with_permissions(["devices.view", "devices.cameras.recordings.view"], actor)

    {live_only_user, _} =
      user_with_permissions(["devices.view", "devices.cameras.view"], actor)

    %{
      conn: log_in_user(conn, viewer),
      anon_conn: build_conn(),
      live_only_conn: log_in_user(build_conn(), live_only_user),
      viewer: viewer,
      viewer_profile: viewer_profile,
      actor: actor
    }
  end

  test "coverage and playlist enforce RBAC, headers, bounds, EXT-X-MAP reuse, discontinuities, quarantine exclusion, and append-only access audit",
       %{
         conn: conn,
         anon_conn: anon_conn,
         live_only_conn: live_only_conn,
         viewer: viewer,
         actor: actor
       } do
    ctx = create_timeline_fixture(actor)
    from_us = @base_us - 1_000_000
    to_us = @base_us + 20_000_000

    # 1. Anonymous -> 401; live-only user -> 403 forbidden on all timeline endpoints
    assert get(anon_conn, ~p"/api/cameras/#{ctx.source.id}/timeline?from=#{from_us}&to=#{to_us}").status ==
             401

    for path <- [
          ~p"/api/cameras/#{ctx.source.id}/timeline?from=#{from_us}&to=#{to_us}",
          ~p"/api/cameras/#{ctx.source.id}/timeline/playlist.m3u8?from=#{from_us}&to=#{to_us}",
          ~p"/api/cameras/#{ctx.source.id}/timeline/blocks/#{ctx.archived_entry.id}/init",
          ~p"/api/cameras/#{ctx.source.id}/timeline/blocks/#{ctx.archived_entry.id}/fragments/0"
        ] do
      denied = get(live_only_conn, path)
      assert json_response(denied, 403) == %{"error" => "forbidden"}
      assert get_resp_header(denied, "cache-control") == ["private, no-store"]
      assert get_resp_header(denied, "x-content-type-options") == ["nosniff"]
    end

    # 2. Coverage bounds (> 31 days refused with 416) and valid coverage response
    over_31d = from_us + 32 * 86_400 * 1_000_000

    wide_resp = get(conn, ~p"/api/cameras/#{ctx.source.id}/timeline?from=#{from_us}&to=#{over_31d}")
    assert json_response(wide_resp, 416) == %{"error" => "recording_window_not_satisfiable"}

    cov_resp =
      get(
        conn,
        ~p"/api/cameras/#{ctx.source.id}/timeline?from=#{from_us}&to=#{to_us}&bucket_count=20"
      )

    assert get_resp_header(cov_resp, "cache-control") == ["private, no-store"]
    assert get_resp_header(cov_resp, "x-content-type-options") == ["nosniff"]
    %{"data" => cov} = json_response(cov_resp, 200)

    assert cov["time_basis"] == "received"
    assert cov["time_uncertainty"] == "unmeasured"
    assert length(cov["buckets"]) == 20

    block_ids = Enum.map(cov["blocks"], & &1["id"])
    assert ctx.archived_entry.id in block_ids
    assert ctx.local_entry.id in block_ids
    assert ctx.provisional_entry.id in block_ids
    refute ctx.quarantined_entry.id in block_ids

    gap_reasons = Enum.map(cov["gaps"], & &1["reason"])
    assert "handover_overflow" in gap_reasons
    assert "quarantined" in gap_reasons

    # 3. Client Range header rejected on playlist; > 60m playlist window rejected with 416
    ranged_playlist =
      viewer
      |> authed_conn()
      |> put_req_header("range", "bytes=0-128")
      |> get(~p"/api/cameras/#{ctx.source.id}/timeline/playlist.m3u8?from=#{from_us}&to=#{to_us}")

    assert json_response(ranged_playlist, 400) == %{"error" => "invalid_request"}

    over_60m = from_us + 3_600_000_001

    too_wide_pl =
      get(conn, ~p"/api/cameras/#{ctx.source.id}/timeline/playlist.m3u8?from=#{from_us}&to=#{over_60m}")

    assert json_response(too_wide_pl, 416) == %{"error" => "recording_window_not_satisfiable"}

    # 4. Valid multi-block playlist reuses EXT-X-MAP for identical init_sha256, marks gap discontinuity,
    #    excludes quarantined entries, and writes an append-only RecordingAccessAudit row!
    pl_resp =
      get(
        conn,
        ~p"/api/cameras/#{ctx.source.id}/timeline/playlist.m3u8?from=#{from_us}&to=#{to_us}&source=auto"
      )

    assert pl_resp.status == 200
    assert get_resp_header(pl_resp, "cache-control") == ["private, no-store"]
    assert get_resp_header(pl_resp, "x-content-type-options") == ["nosniff"]
    playlist = pl_resp.resp_body

    assert playlist =~ "#EXT-X-VERSION:7"
    assert playlist =~ ~s(#EXT-X-MAP:URI="blocks/#{ctx.archived_entry.id}/init?source=auto")
    # Consecutive block sharing init_sha256 reuses map (even across gap discontinuity!)
    refute playlist =~ ~s(#EXT-X-MAP:URI="blocks/#{ctx.local_entry.id}/init?source=auto")
    # Provisional block has a distinct init_sha256 -> emits new EXT-X-MAP
    assert playlist =~ ~s(#EXT-X-MAP:URI="blocks/#{ctx.provisional_entry.id}/init?source=auto")
    assert playlist =~ "#EXT-X-DISCONTINUITY"
    refute playlist =~ ctx.quarantined_entry.id

    {:ok, audits} = RecordingAccessAudit.list_for_camera(ctx.source.id, actor: actor)
    assert [audit] = Enum.filter(audits, &(&1.event_kind == :playlist_window))
    assert audit.actor_id == viewer.id
    assert audit.window_start_us == from_us
    assert audit.window_end_us == to_us
    assert audit.source_mode == :auto
    assert audit.time_basis == :received
    assert audit.segment_count == 3

    # Verify PostgreSQL append-only trigger rejects UPDATE and DELETE on camera_recording_access_audits
    audit_bin = Ecto.UUID.dump!(audit.id)

    assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
             SQL.query(
               Repo,
               "UPDATE platform.camera_recording_access_audits SET segment_count = 99 WHERE id = $1",
               [audit_bin]
             )

    assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
             SQL.query(
               Repo,
               "DELETE FROM platform.camera_recording_access_audits WHERE id = $1",
               [audit_bin]
             )
  end

  test "copy resolution handles local, provisional, archive fallback, local SHA-256 mismatch marking missing, forced source modes, quarantined refusal, and credential redaction",
       %{conn: conn, viewer: viewer, actor: actor} do
    ctx = create_timeline_fixture(actor)

    # 1. Quarantined entry is NEVER served (409 recording_unavailable)
    q_resp =
      get(conn, ~p"/api/cameras/#{ctx.source.id}/timeline/blocks/#{ctx.quarantined_entry.id}/init")

    assert json_response(q_resp, 409) == %{"error" => "recording_unavailable"}

    # 2. Range header on fragment rejected (400)
    ranged_frag =
      viewer
      |> authed_conn()
      |> put_req_header("range", "bytes=0-10")
      |> get(~p"/api/cameras/#{ctx.source.id}/timeline/blocks/#{ctx.local_entry.id}/fragments/0")

    assert json_response(ranged_frag, 400) == %{"error" => "invalid_request"}

    # 3. Auto mode on registered local storage -> 200 with X-Recording-Copy: local
    local_ok_conn =
      viewer
      |> authed_conn()
      |> put_private(:camera_timeline_readers, %{
        local: fn _plan, _deadline -> {:ok, ctx.frag_bytes} end,
        archive: fn _plan, _deadline -> flunk("archive should not be called when local succeeds") end
      })
      |> get(~p"/api/cameras/#{ctx.source.id}/timeline/blocks/#{ctx.local_entry.id}/fragments/0?source=auto")

    assert local_ok_conn.status == 200
    assert local_ok_conn.resp_body == ctx.frag_bytes
    assert get_resp_header(local_ok_conn, "x-recording-copy") == ["local"]

    # 4. Auto mode on unregistered local storage -> 200 with X-Recording-Copy: local; provisional
    prov_conn =
      viewer
      |> authed_conn()
      |> put_private(:camera_timeline_readers, %{
        local: fn _plan, _deadline -> {:ok, ctx.provisional_frag_bytes} end
      })
      |> get(~p"/api/cameras/#{ctx.source.id}/timeline/blocks/#{ctx.provisional_entry.id}/fragments/0?source=auto")

    assert prov_conn.status == 200
    assert get_resp_header(prov_conn, "x-recording-copy") == ["local; provisional"]

    # 5. Auto mode falls back to verified archive on local timeout/unavailable AND redacts reader credential on inspect
    test_pid = self()

    fallback_conn =
      viewer
      |> authed_conn()
      |> put_private(:camera_timeline_readers, %{
        local: fn _plan, _deadline -> {:error, :timeout} end,
        archive: fn plan, _deadline ->
          send(test_pid, {:archive_plan_inspected, inspect(plan)})
          {:ok, ctx.frag_bytes}
        end
      })
      |> get(~p"/api/cameras/#{ctx.source.id}/timeline/blocks/#{ctx.local_entry.id}/fragments/0?source=auto")

    assert fallback_conn.status == 200
    assert fallback_conn.resp_body == ctx.frag_bytes
    assert get_resp_header(fallback_conn, "x-recording-copy") == ["archive"]

    assert_received {:archive_plan_inspected, inspected_plan}
    refute inspected_plan =~ "SYNTHETICTIMELINEKEY"
    refute inspected_plan =~ ctx.secret_access_key

    # 6. Reclaimed local copy in auto mode serves directly from verified archive
    reclaimed_conn =
      viewer
      |> authed_conn()
      |> put_private(:camera_timeline_readers, %{
        local: fn _plan, _deadline -> flunk("reclaimed entry has no local plan") end,
        archive: fn _plan, _deadline -> {:ok, ctx.frag_bytes} end
      })
      |> get(~p"/api/cameras/#{ctx.source.id}/timeline/blocks/#{ctx.archived_entry.id}/fragments/0?source=auto")

    assert reclaimed_conn.status == 200
    assert get_resp_header(reclaimed_conn, "x-recording-copy") == ["archive"]

    # 7. Forced source=local on reclaimed block -> 409 recording_unavailable (NO fallback to verified archive!)
    forced_local_reclaimed =
      viewer
      |> authed_conn()
      |> put_private(:camera_timeline_readers, %{
        archive: fn _plan, _deadline -> flunk("forced local must never fall back to archive") end
      })
      |> get(~p"/api/cameras/#{ctx.source.id}/timeline/blocks/#{ctx.archived_entry.id}/fragments/0?source=local")

    assert json_response(forced_local_reclaimed, 409) == %{"error" => "recording_unavailable"}

    # 8. Forced source=archive on unarchived (pending) block -> 409 recording_unavailable (NO fallback to local!)
    forced_archive_unverified =
      viewer
      |> authed_conn()
      |> put_private(:camera_timeline_readers, %{
        local: fn _plan, _deadline -> flunk("forced archive must never fall back to local") end
      })
      |> get(~p"/api/cameras/#{ctx.source.id}/timeline/blocks/#{ctx.provisional_entry.id}/fragments/0?source=archive")

    assert json_response(forced_archive_unverified, 409) == %{"error" => "recording_unavailable"}

    # 9. Local SHA-256 mismatch: refuses bad bytes, marks local_state = :missing in CNPG, and serves verified archive!
    corrupted_bytes = :binary.copy("corrupted!", div(byte_size(ctx.frag_bytes), 10)) <> "xx"

    integrity_fallback_conn =
      viewer
      |> authed_conn()
      |> put_private(:camera_timeline_readers, %{
        local: fn _plan, _deadline -> {:ok, corrupted_bytes} end,
        archive: fn _plan, _deadline -> {:ok, ctx.frag_bytes} end
      })
      |> get(~p"/api/cameras/#{ctx.source.id}/timeline/blocks/#{ctx.local_entry.id}/fragments/0?source=auto")

    assert integrity_fallback_conn.status == 200
    assert integrity_fallback_conn.resp_body == ctx.frag_bytes
    assert get_resp_header(integrity_fallback_conn, "x-recording-copy") == ["archive"]

    reloaded_local = Ash.get!(RecordingCatalogEntry, ctx.local_entry.id, actor: actor)
    assert reloaded_local.local_state == :missing

    # 10. Local SHA-256 mismatch when archive is NOT verified -> 409 recording_integrity_failed
    #     and local_state = :missing
    integrity_unarchived_conn =
      viewer
      |> authed_conn()
      |> put_private(:camera_timeline_readers, %{
        local: fn _plan, _deadline -> {:ok, "corrupted-unarchived-bytes"} end
      })
      |> get(~p"/api/cameras/#{ctx.source.id}/timeline/blocks/#{ctx.provisional_entry.id}/fragments/0?source=auto")

    assert json_response(integrity_unarchived_conn, 409) == %{
             "error" => "recording_integrity_failed"
           }

    reloaded_prov = Ash.get!(RecordingCatalogEntry, ctx.provisional_entry.id, actor: actor)
    assert reloaded_prov.local_state == :missing
  end

  test "returns 503 with Retry-After when in-flight limit is reached and refuses bytes on mid-playback permission revocation",
       %{viewer: viewer, viewer_profile: viewer_profile, actor: actor} do
    ctx = create_timeline_fixture(actor)
    admission_table = CameraTimelineAdmission.new_table(:controller_admission_test)
    admission_opts = [table: admission_table, max_per_session: 1, max_per_node: 2]

    # Pre-occupy the single session slot for {viewer.id, ctx.source.id}
    {:ok, held_slot} = CameraTimelineAdmission.acquire(viewer.id, ctx.source.id, admission_opts)

    busy_conn =
      viewer
      |> authed_conn()
      |> put_private(:camera_timeline_admission, admission_opts)
      |> put_private(:camera_timeline_readers, %{
        local: fn _plan, _deadline -> flunk("reader must not run when admission is exhausted") end
      })
      |> get(~p"/api/cameras/#{ctx.source.id}/timeline/blocks/#{ctx.local_entry.id}/fragments/0")

    assert json_response(busy_conn, 503) == %{"error" => "playback_capacity_exhausted"}
    assert get_resp_header(busy_conn, "retry-after") == ["1"]

    CameraTimelineAdmission.release(held_slot)

    # Mid-playback permission revocation AFTER bytes are fetched BEFORE 200 response is sent!
    revoked_mid_flight =
      viewer
      |> authed_conn()
      |> put_private(:camera_timeline_admission, admission_opts)
      |> put_private(:camera_timeline_readers, %{
        local: fn _plan, _deadline ->
          # Revoke recording-read permission while the fragment read is in flight
          viewer_profile
          |> Ash.Changeset.for_update(:update, %{permissions: ["devices.view"]},
            actor: actor,
            context: %{privilege_boundary_owned: true}
          )
          |> Ash.update!()

          # Even if stale permission remains in RBAC cache, authorize_current must catch DB revocation!
          Cache.put(
            viewer.id,
            MapSet.new(["devices.view", "devices.cameras.recordings.view"])
          )

          {:ok, ctx.frag_bytes}
        end
      })
      |> get(~p"/api/cameras/#{ctx.source.id}/timeline/blocks/#{ctx.local_entry.id}/fragments/0")

    assert json_response(revoked_mid_flight, 403) == %{"error" => "forbidden"}

    assert CameraTimelineAdmission.counts(viewer.id, ctx.source.id, admission_opts) == %{
             session: 0,
             node: 0
           }

    # Subsequent fragment requests from an already-issued playlist are also refused (403)
    subsequent_conn =
      viewer
      |> authed_conn()
      |> put_private(:camera_timeline_readers, %{
        local: fn _plan, _deadline -> flunk("reader must not run after revocation") end
      })
      |> get(~p"/api/cameras/#{ctx.source.id}/timeline/blocks/#{ctx.archived_entry.id}/fragments/0")

    assert json_response(subsequent_conn, 403) == %{"error" => "forbidden"}
  end

  test "thumbnail endpoint enforces RBAC, cross-camera IDOR refusal, quarantine exclusion, 200 image/jpeg serving, and 404 when missing",
       %{
         conn: conn,
         anon_conn: anon_conn,
         live_only_conn: live_only_conn,
         actor: actor
       } do
    ctx = create_timeline_fixture(actor)
    opts = [actor: actor]

    block_jpeg =
      <<0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, "JFIF", 0x00, 0x01, 0x01, 0x00, 0x01, 0xFF, 0xD9>>

    frame_jpeg =
      <<0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, "JFIF", 0x00, 0x01, 0x01, 0x00, 0x02, 0xFF, 0xD9>>

    {:ok, _updated_entry} =
      ctx.local_entry
      |> Ash.Changeset.for_update(:set_thumbnail, %{thumbnail_jpeg: block_jpeg}, opts)
      |> Ash.update(opts)

    {:ok, frame} =
      VisualFrame
      |> Ash.Changeset.for_create(
        :upsert_frame,
        %{
          catalog_entry_id: ctx.local_entry.id,
          camera_source_id: ctx.source.id,
          stream_profile_id: ctx.local_entry.stream_profile_id,
          fragment_sequence: 0,
          media_pts_ns: 0,
          timeline_ts_us: ctx.local_entry.timeline_start_us + 500_000,
          time_basis: :received,
          scene_suppressed: false,
          detector_model_id: "yolox-s",
          detector_model_version: "2026.1",
          detections: [
            %{"object_class" => "person", "confidence" => 0.94, "dominant_colors" => ["blue"]}
          ],
          thumbnail_jpeg: frame_jpeg
        },
        opts
      )
      |> Ash.create(opts)

    # Verify default Ash queries do NOT select thumbnail_jpeg bytes while has_thumbnail works
    loaded_entry =
      RecordingCatalogEntry
      |> Ash.Query.for_read(:read, %{}, opts)
      |> Ash.Query.filter(id == ^ctx.local_entry.id)
      |> Ash.Query.load([:has_thumbnail])
      |> Ash.read_one!(opts)

    assert loaded_entry.has_thumbnail == true
    assert match?(%Ash.NotLoaded{}, loaded_entry.thumbnail_jpeg)

    loaded_frame =
      VisualFrame
      |> Ash.Query.for_read(:read, %{}, opts)
      |> Ash.Query.filter(id == ^frame.id)
      |> Ash.Query.load([:has_thumbnail])
      |> Ash.read_one!(opts)

    assert loaded_frame.has_thumbnail == true
    assert match?(%Ash.NotLoaded{}, loaded_frame.thumbnail_jpeg)

    # Verify RecordingEventClips projects authenticated thumbnail URLs from CNPG
    {:ok, %{clips: clips}} =
      RecordingEventClips.list_clips(
        ctx.source.id,
        %{from_us: @base_us - 1_000_000, to_us: @base_us + 20_000_000},
        opts
      )

    person_clip = Enum.find(clips, &(&1.category == :person))

    assert person_clip.thumbnail_url ==
             "/api/cameras/#{ctx.source.id}/timeline/thumbnails/frame/#{frame.id}.jpg"

    archived_rec_clip =
      Enum.find(clips, &(&1.category == :recording and &1.catalog_entry_id == ctx.archived_entry.id))

    assert archived_rec_clip.thumbnail_url == nil

    # 1. Anonymous -> 401; live-only user -> 403 forbidden
    frame_path = "/api/cameras/#{ctx.source.id}/timeline/thumbnails/frame/#{frame.id}.jpg"
    block_path = "/api/cameras/#{ctx.source.id}/timeline/thumbnails/block/#{ctx.local_entry.id}.jpg"

    assert get(anon_conn, frame_path).status == 401

    denied = get(live_only_conn, frame_path)
    assert json_response(denied, 403) == %{"error" => "forbidden"}
    assert get_resp_header(denied, "cache-control") == ["private, no-store"]
    assert get_resp_header(denied, "x-content-type-options") == ["nosniff"]

    # 2. Authorized viewer receives 200 image/jpeg with private cache headers
    frame_resp = get(conn, frame_path)
    assert frame_resp.status == 200
    assert get_resp_header(frame_resp, "content-type") == ["image/jpeg"]
    assert get_resp_header(frame_resp, "cache-control") == ["private, max-age=300"]
    assert get_resp_header(frame_resp, "x-content-type-options") == ["nosniff"]
    assert frame_resp.resp_body == frame_jpeg

    block_resp = get(conn, block_path)
    assert block_resp.status == 200
    assert get_resp_header(block_resp, "content-type") == ["image/jpeg"]
    assert get_resp_header(block_resp, "cache-control") == ["private, max-age=300"]
    assert get_resp_header(block_resp, "x-content-type-options") == ["nosniff"]
    assert block_resp.resp_body == block_jpeg

    # 3. Missing thumbnail (entry without thumbnail_jpeg) -> 404
    missing_resp =
      get(conn, "/api/cameras/#{ctx.source.id}/timeline/thumbnails/block/#{ctx.archived_entry.id}.jpg")

    assert json_response(missing_resp, 404) == %{"error" => "thumbnail_not_found"}
    assert get_resp_header(missing_resp, "cache-control") == ["private, no-store"]

    # 4. Quarantined entry -> 404 (non-vacuous: attach a real JPEG frame on the quarantined entry
    #    AND verify the BEFORE UPDATE trigger purges thumbnail_jpeg when a playable entry is quarantined)
    {:ok, quarantined_frame} =
      VisualFrame
      |> Ash.Changeset.for_create(
        :upsert_frame,
        %{
          catalog_entry_id: ctx.quarantined_entry.id,
          camera_source_id: ctx.source.id,
          stream_profile_id: ctx.local_entry.stream_profile_id,
          fragment_sequence: 0,
          media_pts_ns: 0,
          timeline_ts_us: ctx.local_entry.timeline_start_us + 900_000,
          time_basis: :received,
          scene_suppressed: false,
          detector_model_id: "yolox-s",
          detector_model_version: "2026.1",
          detections: [],
          thumbnail_jpeg: frame_jpeg
        },
        opts
      )
      |> Ash.create(opts)

    quarantined_frame_resp =
      get(
        conn,
        "/api/cameras/#{ctx.source.id}/timeline/thumbnails/frame/#{quarantined_frame.id}.jpg"
      )

    assert json_response(quarantined_frame_resp, 404) == %{"error" => "thumbnail_not_found"}

    {:ok, _prov_with_thumb} =
      ctx.provisional_entry
      |> Ash.Changeset.for_update(:set_thumbnail, %{thumbnail_jpeg: block_jpeg}, opts)
      |> Ash.update(opts)

    prov_block_path =
      "/api/cameras/#{ctx.source.id}/timeline/thumbnails/block/#{ctx.provisional_entry.id}.jpg"

    assert get(conn, prov_block_path).status == 200

    {:ok, _quarantined_prov} =
      RecordingCatalogEntry.quarantine_in_place(
        ctx.provisional_entry,
        %{
          quarantine_reason: :binding_compromised,
          quarantine_receipt: %{"reason" => "synthetic-test"},
          quarantined_bytes: ctx.provisional_entry.media_bytes
        },
        opts
      )

    purged_entry =
      RecordingCatalogEntry
      |> Ash.Query.for_read(:read, %{}, opts)
      |> Ash.Query.filter(id == ^ctx.provisional_entry.id)
      |> Ash.Query.select([:id, :thumbnail_jpeg])
      |> Ash.read_one!(opts)

    assert purged_entry.thumbnail_jpeg == nil
    assert json_response(get(conn, prov_block_path), 404) == %{"error" => "thumbnail_not_found"}

    # 5. Cross-camera IDOR refusal -> 404 when requesting camera A's frame/block under camera B
    other_key = Ecto.UUID.generate()

    {:ok, other_source} =
      Source.create_source(
        %{
          device_uid: "sr:synthetic-other-cam-#{other_key}",
          vendor: "synthetic",
          vendor_camera_id: other_key,
          display_name: "Synthetic Other Camera",
          assigned_agent_id: "agent-example",
          assigned_gateway_id: "gateway-example"
        },
        opts
      )

    idor_frame =
      get(conn, "/api/cameras/#{other_source.id}/timeline/thumbnails/frame/#{frame.id}.jpg")

    assert json_response(idor_frame, 404) == %{"error" => "thumbnail_not_found"}

    idor_block =
      get(
        conn,
        "/api/cameras/#{other_source.id}/timeline/thumbnails/block/#{ctx.local_entry.id}.jpg"
      )

    assert json_response(idor_block, 404) == %{"error" => "thumbnail_not_found"}

    # 6. Invalid kind or invalid UUID -> 400
    bad_kind =
      get(conn, "/api/cameras/#{ctx.source.id}/timeline/thumbnails/invalid/#{frame.id}.jpg")

    assert json_response(bad_kind, 400) == %{"error" => "invalid_request"}

    bad_id =
      get(conn, "/api/cameras/#{ctx.source.id}/timeline/thumbnails/frame/not-a-uuid.jpg")

    assert json_response(bad_id, 400) == %{"error" => "invalid_request"}
  end

  test "serves authenticated Vantage observation crop JPEG and fails closed on nil crop, quarantine, or missing permission",
       %{
         conn: conn,
         actor: actor
       } do
    alias ServiceRadar.Camera.VantageObservation

    ctx = create_timeline_fixture(actor)

    valid_jfif =
      <<0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, "JFIF", 0x00, 0x01, 0x01, 0x00, 0x00, 0x01, 0x00, 0x01>> <>
        <<0x00, 0x00, 0xFF, 0xC0, 0x00, 0x0B, 0x08, 0x00, 0x10, 0x00, 0x10, 0x01, 0x01, 0x11>> <>
        <<0x00, 0xFF, 0xDA, 0x00, 0x08, 0x01, 0x01, 0x00, 0x00, 0x3F, 0x00, 0xFF, 0xD9>>

    base_attrs = %{
      pack_id: "io.serviceradar.vantage-alpr",
      pipeline_id: "io.serviceradar.vantage-alpr.vehicle-plate",
      pipeline_version: "1.0.0",
      worker_kind: "camera_vlm",
      model_id: "qwen3.5-4b",
      model_version: "1.0",
      camera_source_id: ctx.source.id,
      stream_profile_id: ctx.profile.id,
      source_mode: :recorded_block,
      timeline_ts_us: @base_us + 5_500_000,
      time_basis: :received,
      category: "license_plate",
      label: "SR-0100",
      confidence: 0.94,
      signal_schema_id: "alpr_plate_read",
      signal_schema_version: "1.0.0",
      display_contract_id: "alpr_plate_read"
    }

    playable_obs =
      VantageObservation
      |> Ash.Changeset.for_create(
        :upsert_observation,
        Map.merge(base_attrs, %{
          observation_key: "crop-ok-#{System.unique_integer([:positive])}",
          catalog_entry_id: ctx.local_entry.id,
          crop_jpeg: valid_jfif
        }),
        actor: actor
      )
      |> Ash.create!()

    nil_crop_obs =
      VantageObservation
      |> Ash.Changeset.for_create(
        :upsert_observation,
        Map.merge(base_attrs, %{
          observation_key: "crop-nil-#{System.unique_integer([:positive])}",
          catalog_entry_id: ctx.local_entry.id,
          crop_jpeg: nil
        }),
        actor: actor
      )
      |> Ash.create!()

    quarantined_obs =
      VantageObservation
      |> Ash.Changeset.for_create(
        :upsert_observation,
        Map.merge(base_attrs, %{
          observation_key: "crop-quar-#{System.unique_integer([:positive])}",
          catalog_entry_id: ctx.quarantined_entry.id,
          crop_jpeg: valid_jfif
        }),
        actor: actor
      )
      |> Ash.create!()

    ok_resp =
      get(conn, "/api/cameras/#{ctx.source.id}/timeline/thumbnails/vantage/#{playable_obs.id}.jpg")

    assert ok_resp.status == 200
    assert ok_resp.resp_body == valid_jfif
    assert get_resp_header(ok_resp, "content-type") == ["image/jpeg"]

    nil_resp =
      get(conn, "/api/cameras/#{ctx.source.id}/timeline/thumbnails/vantage/#{nil_crop_obs.id}.jpg")

    assert json_response(nil_resp, 404) == %{"error" => "thumbnail_not_found"}

    quar_resp =
      get(conn, "/api/cameras/#{ctx.source.id}/timeline/thumbnails/vantage/#{quarantined_obs.id}.jpg")

    assert json_response(quar_resp, 404) == %{"error" => "thumbnail_not_found"}

    {no_rec_user, _profile} = user_with_permissions(["devices.view"], actor)

    denied_resp =
      no_rec_user
      |> authed_conn()
      |> get("/api/cameras/#{ctx.source.id}/timeline/thumbnails/vantage/#{playable_obs.id}.jpg")

    assert denied_resp.status == 403
  end

  defp authed_conn(user), do: log_in_user(build_conn(), user)

  defp create_timeline_fixture(actor) do
    opts = [actor: actor]
    key = Ecto.UUID.generate()
    secret_access_key = String.duplicate("k", 32)

    {:ok, built_secret} =
      CredentialSecretBuilder.build(
        NativeDescriptors.s3_compatible(),
        "access_key",
        %{
          "access_key_id" => "SYNTHETICTIMELINEKEY",
          "secret_access_key" => secret_access_key
        },
        %{name: "Synthetic Timeline Reader #{System.unique_integer([:positive])}"}
      )

    reader_secret = NetworkCredentialSecret.create_secret!(built_secret, opts)

    {:ok, binding} =
      ArchiveDestinations.register_operator(
        %{
          name: "timeline-dest-#{System.unique_integer([:positive])}",
          endpoint: "https://objects.example.com",
          region: "example-1",
          bucket: "synthetic-timeline-archive",
          namespace: "recordings/v1"
        },
        opts
      )

    {:ok, _settings} =
      RecordingArchiveSettings.save_settings(
        %{
          active_archive_binding_id: binding.id,
          archive_enabled: true,
          writer_credential_secret_id: reader_secret.id,
          reader_credential_secret_id: reader_secret.id
        },
        opts
      )

    {:ok, source} =
      Source.create_source(
        %{
          device_uid: "sr:synthetic-tl-cam-#{key}",
          vendor: "synthetic",
          vendor_camera_id: key,
          display_name: "Synthetic Timeline Camera",
          assigned_agent_id: "agent-example",
          assigned_gateway_id: "gateway-example"
        },
        opts
      )

    {:ok, profile} =
      StreamProfile.create_profile(
        %{
          camera_source_id: source.id,
          profile_name: "main-timeline",
          codec_hint: "h264",
          relay_eligible: true
        },
        opts
      )

    {:ok, _policy} =
      CameraRecordingPolicy
      |> Ash.Changeset.for_create(
        :create,
        %{
          camera_source_id: source.id,
          stream_profile_id: profile.id,
          mode: :continuous,
          nvr_member: "serviceradar-nvr-0"
        },
        opts
      )
      |> Ash.create(opts)

    {:ok, sub_profile} =
      StreamProfile.create_profile(
        %{
          camera_source_id: source.id,
          profile_name: "sub-provisional",
          codec_hint: "h264",
          relay_eligible: true
        },
        opts
      )

    live_reg = open_claim_for_storage(source, profile, @registered_storage_id, "reg-#{key}", opts)

    live_prov =
      open_claim_for_storage(source, sub_profile, @provisional_storage_id, "prov-#{key}", opts)

    init_bytes = :binary.copy("init-box", 16)
    init_sha = sha256_hex(init_bytes)
    frag_bytes = :binary.copy("synthetic-fmp4-frag!", 20)
    frag_sha = sha256_hex(frag_bytes)

    # Block 0: Reclaimed locally, verified in archive (@base_dt .. +2s)
    block_0 = reserve_block(live_reg, 0, "epoch-tl-1", opts)
    desc_0 = single_frag_descriptor(block_0, init_bytes, init_sha, frag_bytes, frag_sha, 0)

    {:ok, entry_0} =
      RecordingBlocks.freeze_and_catalog(
        live_reg.owner,
        live_reg.claim,
        block_0,
        desc_0,
        %{first_unit_pts: 0, first_unit_received_at: @base_dt, reanchored: false},
        opts
      )

    receipt_0 =
      record_receipt(binding, block_0, @registered_storage_id, init_bytes, init_sha, frag_bytes, frag_sha, actor)

    now = DateTime.utc_now()

    entry_0 =
      entry_0
      |> Ash.Changeset.for_update(
        :transition_archive_state,
        %{
          archive_state: :verified,
          archive_state_at: now,
          archived_at: now,
          nvr_archive_receipt_id: receipt_0.id,
          archive_binding_id: binding.id
        },
        opts
      )
      |> Ash.update!(opts)
      |> Ash.Changeset.for_update(
        :transition_local_state,
        %{local_state: :reclaimed, local_state_at: now},
        opts
      )
      |> Ash.update!(opts)

    # Gap between Block 0 and Block 1 (+2s .. +5s)
    RecordingGap.record(
      %{
        camera_source_id: source.id,
        stream_profile_id: profile.id,
        storage_id: @registered_storage_id,
        clock_epoch: "epoch-tl-1",
        start_us: @base_us + 2_000_000,
        end_us: @base_us + 5_000_000,
        media_gap_ns: 3_000_000_000,
        time_basis: :received,
        reason: :handover_overflow
      },
      opts
    )

    # Block 1: Present locally AND verified in archive, sharing init_sha with Block 0 (+5s .. +7s)
    block_1 = reserve_block(live_reg, 1, "epoch-tl-1", opts)
    desc_1 = single_frag_descriptor(block_1, init_bytes, init_sha, frag_bytes, frag_sha, 5_000_000_000)

    {:ok, entry_1} =
      RecordingBlocks.freeze_and_catalog(
        live_reg.owner,
        live_reg.claim,
        block_1,
        desc_1,
        %{
          first_unit_pts: 450_000,
          first_unit_received_at: DateTime.shift(@base_dt, second: 5),
          reanchored: false
        },
        opts
      )

    receipt_1 =
      record_receipt(binding, block_1, @registered_storage_id, init_bytes, init_sha, frag_bytes, frag_sha, actor)

    entry_1 =
      entry_1
      |> Ash.Changeset.for_update(
        :transition_archive_state,
        %{
          archive_state: :verified,
          archive_state_at: now,
          archived_at: now,
          nvr_archive_receipt_id: receipt_1.id,
          archive_binding_id: binding.id
        },
        opts
      )
      |> Ash.update!(opts)

    # Block 2: Provisional storage (no LocalStorageBinding), pending archive, distinct init (+8s .. +10s)
    prov_init_bytes = :binary.copy("provinit", 16)
    prov_init_sha = sha256_hex(prov_init_bytes)
    prov_frag_bytes = :binary.copy("provisional-fmp4-bytes!!", 12)
    prov_frag_sha = sha256_hex(prov_frag_bytes)

    block_2 = reserve_block(live_prov, 0, "epoch-tl-1", opts)

    desc_2 =
      single_frag_descriptor(block_2, prov_init_bytes, prov_init_sha, prov_frag_bytes, prov_frag_sha, 8_000_000_000)

    {:ok, entry_2} =
      RecordingBlocks.freeze_and_catalog(
        live_prov.owner,
        live_prov.claim,
        block_2,
        desc_2,
        %{
          first_unit_pts: 720_000,
          first_unit_received_at: DateTime.shift(@base_dt, second: 8),
          reanchored: false
        },
        opts
      )

    # Quarantined entry (+12s .. +14s) + corresponding quarantined gap (R2)
    q_key = sha256_hex("synth-quarantined-#{key}")

    {:ok, quarantined_entry} =
      RecordingCatalogEntry.register_quarantined(
        %{
          camera_source_id: source.id,
          stream_profile_id: profile.id,
          storage_id: @registered_storage_id,
          block_key: q_key,
          timeline_start_us: @base_us + 12_000_000,
          timeline_end_us: @base_us + 14_000_000,
          media_start_ns: 12_000_000_000,
          media_end_ns: 14_000_000_000,
          time_basis: :received,
          quarantine_reason: :unrecoverable_journal,
          quarantine_receipt: %{"partition" => "_quarantine/#{q_key}"},
          quarantined_bytes: 1_024,
          archive_state: :not_required
        },
        opts
      )

    RecordingGap.record(
      %{
        camera_source_id: source.id,
        stream_profile_id: profile.id,
        storage_id: @registered_storage_id,
        start_us: @base_us + 12_000_000,
        end_us: @base_us + 14_000_000,
        time_basis: :received,
        reason: :quarantined
      },
      opts
    )

    %{
      source: source,
      profile: profile,
      binding: binding,
      archived_entry: entry_0,
      local_entry: entry_1,
      provisional_entry: entry_2,
      quarantined_entry: quarantined_entry,
      frag_bytes: frag_bytes,
      provisional_frag_bytes: prov_frag_bytes,
      secret_access_key: secret_access_key
    }
  end

  defp open_claim_for_storage(source, profile, storage_id, tag, opts) do
    actor = opts[:actor]

    {:ok, session} =
      RelaySessionManager.request_open(source.id, profile.id,
        actor: actor,
        control_gateway_resolver: fn _agent, gateway -> {:ok, gateway} end,
        dispatch_open: fn _agent, _payload, open_opts, _requester ->
          {:ok, open_opts[:command_id]}
        end
      )

    assignment =
      Map.take(session, [:agent_id, :gateway_id, :camera_source_id, :stream_profile_id])

    {:ok, session} =
      RelaySessionLifecycle.activate_session(session.id, "synth-tl-#{tag}", assignment, opts)

    {:ok, owner} = IngestOwnership.for_relay(session.id, opts)
    claim_token = Ecto.UUID.generate()
    {:ok, consumer} = IngestOwnership.acquire_consumer(owner, :recorder, claim_token, 60_000, opts)

    initial_claim =
      case RecorderClaim
           |> Ash.Query.filter(ingest_owner_id == ^owner.id)
           |> Ash.read_one!(opts) do
        nil ->
          RecorderClaim
          |> Ash.Changeset.for_create(:initialize, %{ingest_owner_id: owner.id}, opts)
          |> Ash.create!(opts)

        existing ->
          existing
      end

    claim =
      initial_claim
      |> Ash.Changeset.for_update(
        :transition,
        %{
          claim_token: claim_token,
          ingest_epoch: owner.epoch,
          recorder_epoch: initial_claim.recorder_epoch + 1,
          next_block_sequence: 4,
          relay_session_id: owner.relay_session_id,
          media_ingest_id: session.media_ingest_id,
          storage_id: storage_id,
          consumer_id: consumer.id,
          lease_expires_at: consumer.expires_at,
          state: :active
        },
        opts
      )
      |> Ash.update!(opts)

    %{owner: owner, claim: claim}
  end

  defp reserve_block(live_ctx, sequence, clock_epoch, opts) do
    clock = %{
      "clock_epoch" => clock_epoch,
      "timebase" => 90_000,
      "dts_source" => "pts_no_reordering",
      "utc_mapping" => "unknown"
    }

    attrs = %{
      camera_source_id: live_ctx.owner.camera_source_id,
      stream_profile_id: live_ctx.owner.stream_profile_id,
      ingest_owner_id: live_ctx.owner.id,
      ingest_epoch: live_ctx.owner.epoch,
      recorder_claim_id: live_ctx.claim.id,
      recorder_epoch: live_ctx.claim.recorder_epoch,
      block_sequence: sequence,
      relay_session_id: live_ctx.claim.relay_session_id,
      media_ingest_id: live_ctx.claim.media_ingest_id,
      storage_id: live_ctx.claim.storage_id,
      clock: clock
    }

    identity = RecordingBlock.identity(attrs)

    RecordingBlock
    |> Ash.Changeset.for_create(
      :reserve,
      Map.put(attrs, :block_key, Descriptor.block_key(identity)),
      opts
    )
    |> Ash.create!(opts)
  end

  defp single_frag_descriptor(block, init_bytes, init_sha, frag_bytes, frag_sha, start_ns) do
    %{
      "version" => 1,
      "identity" => RecordingBlock.identity(block),
      "format" => %{"codec" => "avc1.42001e", "timescale" => 90_000},
      "init" => %{
        "length" => byte_size(init_bytes),
        "sha256" => init_sha
      },
      "media" => %{
        "length" => byte_size(frag_bytes),
        "sha256" => frag_sha
      },
      "fragments" => [
        %{
          "sequence" => 0,
          "offset" => 0,
          "length" => byte_size(frag_bytes),
          "start_ns" => start_ns,
          "duration_ns" => 2_000_000_000,
          "sha256" => frag_sha,
          "tail_duration_source" => nil,
          "motion" => "unknown"
        }
      ]
    }
  end

  defp record_receipt(binding, block, storage_id, init_bytes, init_sha, frag_bytes, frag_sha, actor) do
    receipt_bytes =
      Jason.encode!(%{
        "version" => 2,
        "storage_id" => storage_id,
        "block_key" => block.block_key,
        "destination_sha256" => binding.destination_sha256,
        "verified_at_ms" => DateTime.to_unix(DateTime.utc_now(), :millisecond),
        "objects" => [
          %{
            "name" => "init.mp4",
            "key" => "#{binding.namespace}/#{storage_id}/#{block.block_key}/init.mp4",
            "length" => byte_size(init_bytes),
            "sha256" => init_sha,
            "etag" => "\"etag-init-#{block.id}\"",
            "version_id" => "synth-init-v1"
          },
          %{
            "name" => "media.m4s",
            "key" => "#{binding.namespace}/#{storage_id}/#{block.block_key}/media.m4s",
            "length" => byte_size(frag_bytes),
            "sha256" => frag_sha,
            "etag" => "\"etag-media-#{block.id}\"",
            "version_id" => "synth-media-v1"
          }
        ]
      })

    {:ok, receipt} =
      NVRArchiveReceipt.record(
        binding.id,
        receipt_bytes,
        %{recording_block_id: block.id},
        actor: actor
      )

    receipt
  end

  defp insert_local_storage_binding(storage_id) do
    now = DateTime.utc_now()

    SQL.query!(
      Repo,
      """
      INSERT INTO platform.camera_local_storage_bindings (
        id, schema_version, storage_id, generation, provider_resource_ref,
        profile_sha256, binding_sha256, provisioned_by, inserted_at
      ) VALUES ($1, 1, $2, 1, $3, $4, $5, 'synthetic-provisioner', $6)
      ON CONFLICT DO NOTHING
      """,
      [
        Ecto.UUID.dump!(Ecto.UUID.generate()),
        Ecto.UUID.dump!(storage_id),
        "pvc://synthetic-nvr-0",
        sha256_hex("synth-profile-#{storage_id}"),
        sha256_hex("synth-binding-#{storage_id}"),
        now
      ]
    )
  end

  defp user_with_permissions(permissions, actor) do
    user = user_fixture()

    profile =
      RoleProfile
      |> Ash.Changeset.for_create(
        :create,
        %{name: "Synthetic timeline api #{Ecto.UUID.generate()}", permissions: permissions},
        actor: actor,
        context: %{privilege_boundary_owned: true}
      )
      |> Ash.create!()

    user =
      user
      |> Ash.Changeset.for_update(:update_role_profile, %{role_profile_id: profile.id}, actor: actor)
      |> Ash.update!()

    Cache.put(user.id, MapSet.new(permissions))
    on_exit(fn -> Cache.invalidate(user.id) end)
    {user, profile}
  end

  defp sha256_hex(bytes), do: :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)
end
