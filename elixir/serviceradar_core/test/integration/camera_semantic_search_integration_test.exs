defmodule ServiceRadar.Camera.CameraSemanticSearchIntegrationTest do
  use ServiceRadar.DataCase, async: false

  alias Ash.Error.Forbidden
  alias Broadway.Message
  alias Ecto.Adapters.SQL
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Camera.ArchiveDestinations
  alias ServiceRadar.Camera.CameraRecordingPolicies
  alias ServiceRadar.Camera.IngestOwner
  alias ServiceRadar.Camera.NVRArchiveReceipt
  alias ServiceRadar.Camera.RecorderOwnership
  alias ServiceRadar.Camera.RecordingAccessAudit
  alias ServiceRadar.Camera.RecordingArchiveSettings
  alias ServiceRadar.Camera.RecordingBlock
  alias ServiceRadar.Camera.RecordingBlocks
  alias ServiceRadar.Camera.RecordingCatalogEntry
  alias ServiceRadar.Camera.RecordingHolds
  alias ServiceRadar.Camera.RelaySessionLifecycle
  alias ServiceRadar.Camera.RelaySessionManager
  alias ServiceRadar.Camera.SemanticSearch
  alias ServiceRadar.Camera.Source
  alias ServiceRadar.Camera.StreamProfile
  alias ServiceRadar.Camera.VisualEmbedding
  alias ServiceRadar.Camera.VisualFrame
  alias ServiceRadar.Camera.VisualIndexBackfill
  alias ServiceRadar.Camera.VisualIndexDispatcher
  alias ServiceRadar.Camera.VisualIndexJob
  alias ServiceRadar.Camera.VisualIndexResultProjector
  alias ServiceRadar.Camera.VisualWorkerReadGrants
  alias ServiceRadar.Credentials.CredentialSecretBuilder
  alias ServiceRadar.Credentials.NativeDescriptors
  alias ServiceRadar.Credentials.NetworkCredentialSecret
  alias ServiceRadar.EventWriter.Processors.CameraVisualIndexResults
  alias ServiceRadar.EventWriter.TerminalMessageError
  alias ServiceRadar.EventWriter.TransientMessageError
  alias ServiceRadar.Repo
  alias ServiceRadar.Test.CameraRelayFixtures, as: Fixtures
  alias ServiceRadar.TestSupport
  alias ServiceRadarRecordingMetadata.Descriptor

  require Ash.Query

  @moduletag :integration
  @moduletag :tmp_dir

  @clock %{
    "clock_epoch" => "synthetic-clock-epoch",
    "timebase" => 90_000,
    "dts_source" => "pts_no_reordering",
    "utc_mapping" => "unknown"
  }

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    SemanticSearch.clear_query_cache()
    :ok
  end

  test "CameraRecordingPolicy persists visual_index_* fields with PaperTrail versions and SQL CHECK constraints (1.1)" do
    actor = SystemActor.system(:semantic_policy_test)
    {cam, prof} = create_camera_and_profile(actor, "Gate North Camera")

    admin = %{
      id: "admin-vi-policy",
      role: :admin,
      permissions: MapSet.new(["settings.recording.view", "settings.recording.manage"])
    }

    assert {:ok, policy} =
             CameraRecordingPolicies.upsert_policy(
               %{
                 camera_source_id: cam.id,
                 stream_profile_id: prof.id,
                 mode: :continuous,
                 nvr_member: "nvr-0",
                 storage: :local_only,
                 visual_index_mode: :keyframes,
                 visual_index_min_interval_ms: 3_000,
                 visual_index_max_frames_per_block: 32
               },
               actor: admin
             )

    assert policy.visual_index_mode == :keyframes
    assert policy.visual_index_min_interval_ms == 3_000
    assert policy.visual_index_max_frames_per_block == 32

    assert %{rows: [[version_count]]} =
             SQL.query!(
               Repo,
               "SELECT count(*) FROM platform.camera_recording_policies_versions WHERE version_source_id = $1",
               [Ecto.UUID.dump!(policy.id)]
             )

    assert version_count >= 1

    assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
             SQL.query(
               Repo,
               "UPDATE platform.camera_recording_policies SET visual_index_min_interval_ms = 100 WHERE id = $1",
               [Ecto.UUID.dump!(policy.id)]
             )
  end

  test "freeze_and_catalog and freeze_historical admit outbox VisualIndexJob only when visual_index_mode == :keyframes, dispatch metadata-only JetStream envelopes, and reconcile MaxDeliver exhaustion (1.4)",
       %{tmp_dir: tmp_dir} do
    _gate = Fixtures.recording_recovery_gate(tmp_dir)
    actor = SystemActor.system(:semantic_outbox_test)
    {cam_on, prof_on} = create_camera_and_profile(actor, "Loading Bay Camera")
    {cam_off, prof_off} = create_camera_and_profile(actor, "Lobby Off Camera")

    admin = %{
      id: "admin-outbox",
      role: :admin,
      permissions: MapSet.new(["settings.recording.view", "settings.recording.manage"])
    }

    {:ok, _pol_on} =
      CameraRecordingPolicies.upsert_policy(
        %{
          camera_source_id: cam_on.id,
          stream_profile_id: prof_on.id,
          mode: :continuous,
          nvr_member: "nvr-0",
          storage: :local_only,
          visual_index_mode: :keyframes,
          visual_index_min_interval_ms: 2_000,
          visual_index_max_frames_per_block: 16
        },
        actor: admin
      )

    {:ok, _pol_off} =
      CameraRecordingPolicies.upsert_policy(
        %{
          camera_source_id: cam_off.id,
          stream_profile_id: prof_off.id,
          mode: :continuous,
          nvr_member: "nvr-0",
          storage: :local_only,
          visual_index_mode: :off
        },
        actor: admin
      )

    # 1. Historical freeze after writer retirement on indexing-enabled policy
    {owner_on, claim_on, block_on} = reserve_synthetic_block(cam_on, prof_on, actor)
    assert {:ok, :released} = RecorderOwnership.release(owner_on, claim_on, actor: actor)
    desc_on = multi_keyframe_descriptor(block_on)

    assert {:ok, entry_on} =
             RecordingBlocks.freeze_historical(
               block_on,
               desc_on,
               %{
                 timeline_start_us: 1_750_000_000_000_000,
                 timeline_end_us: 1_750_000_006_000_000,
                 time_basis: :received,
                 local_state: :present,
                 archive_state: :not_required
               },
               actor: actor,
               reconciler_ready?: true
             )

    jobs_on =
      VisualIndexJob
      |> Ash.Query.filter(catalog_entry_id == ^entry_on.id)
      |> Ash.read!(actor: actor)

    assert [job] = jobs_on
    assert job.state == :pending
    assert job.job_kind == :live
    assert Enum.map(job.sampled_fragments, & &1["sequence"]) == [0, 2]

    # 2. Live freeze_and_catalog on policy with visual_index_mode == :off creates ZERO VisualIndexJob rows
    {owner_off, claim_off, block_off} = reserve_synthetic_block(cam_off, prof_off, actor)
    desc_off = multi_keyframe_descriptor(block_off)

    assert {:ok, entry_off} =
             RecordingBlocks.freeze_and_catalog(
               owner_off,
               claim_off,
               block_off,
               desc_off,
               %{
                 first_unit_pts: 0,
                 first_unit_received_at: ~U[2026-11-17 12:00:00.000000Z],
                 reanchored: false
               },
               actor: actor
             )

    assert [] ==
             VisualIndexJob
             |> Ash.Query.filter(catalog_entry_id == ^entry_off.id)
             |> Ash.read!(actor: actor)

    # 3. Dispatch publishes metadata-only envelope and transitions job to :dispatched
    test_pid = self()

    assert {:ok, dispatched} =
             VisualIndexDispatcher.dispatch_job(job,
               publisher: fn subject, payload, opts ->
                 send(test_pid, {:published_visual_job, subject, payload, opts})
                 :ok
               end
             )

    assert dispatched.state == :dispatched
    assert dispatched.attempt_count == 1
    assert_received {:published_visual_job, "media.jobs.visual_index.v1", payload_bin, pub_opts}
    assert Keyword.get(pub_opts, :msg_id) == "visual-index:#{job.id}"
    assert {"Nats-Expected-Stream", "CAMERA_MEDIA_JOBS"} in pub_opts[:headers]
    refute payload_bin =~ "secret"

    # 4. Exhausted retries reconcile to :failed_terminal and emit TripwireHealth check
    assert {:ok, failed_job} =
             VisualIndexDispatcher.reconcile_exhausted_job(
               dispatched,
               "max_deliver_exhausted",
               tripwire_recorder: fn check_id, healthy?, meta, _opts ->
                 send(test_pid, {:tripwire, check_id, healthy?, meta})
                 :ok
               end
             )

    assert failed_job.state == :failed_terminal
    assert failed_job.last_error_class == "max_deliver_exhausted"

    assert_received {:tripwire, "camera.visual_index.failed_terminal", false,
                     %{"job_id" => job_id_str}}

    assert job_id_str == to_string(job.id)
  end

  test "VisualWorkerReadGrants issues CNPG SecretBroker reader-only archive grants with zero leaked secrets and 410s deleted/quarantined blocks (1.6)",
       %{tmp_dir: tmp_dir} do
    _gate = Fixtures.recording_recovery_gate(tmp_dir)
    actor = SystemActor.system(:semantic_grants_test)
    {cam, prof} = create_camera_and_profile(actor, "Archive Grant Camera")

    admin = %{
      id: "admin-grants",
      role: :admin,
      permissions:
        MapSet.new([
          "settings.recording.view",
          "settings.recording.manage",
          "settings.credentials.manage"
        ])
    }

    synthetic_secret = String.duplicate("s", 32)
    slug = "vi-grant-#{System.unique_integer([:positive])}"

    {:ok, built_secret} =
      CredentialSecretBuilder.build(
        NativeDescriptors.s3_compatible(),
        "access_key",
        %{
          "access_key_id" => "AKIA_SYNTHETIC_READER",
          "secret_access_key" => synthetic_secret
        },
        %{name: "s3-reader-#{slug}"}
      )

    secret = NetworkCredentialSecret.create_secret!(built_secret, actor: actor)

    {:ok, binding} =
      ArchiveDestinations.register_operator(
        %{
          name: slug,
          endpoint: "https://objects.example.com",
          region: "us-east-1",
          bucket: "synthetic-archive",
          namespace: "nvr/archive-v2"
        },
        actor: admin
      )

    {:ok, _settings} =
      RecordingArchiveSettings.save_settings(
        %{
          archive_enabled: true,
          active_archive_binding_id: binding.id,
          writer_credential_secret_id: secret.id,
          reader_credential_secret_id: secret.id
        },
        actor: admin
      )

    {:ok, _pol} =
      CameraRecordingPolicies.upsert_policy(
        %{
          camera_source_id: cam.id,
          stream_profile_id: prof.id,
          mode: :continuous,
          nvr_member: "nvr-0",
          storage: :local_and_archive,
          visual_index_mode: :keyframes
        },
        actor: admin
      )

    {owner, claim, block} = reserve_synthetic_block(cam, prof, actor)
    desc = multi_keyframe_descriptor(block)

    {:ok, entry} =
      RecordingBlocks.freeze_and_catalog(
        owner,
        claim,
        block,
        desc,
        %{
          first_unit_pts: 0,
          first_unit_received_at: ~U[2026-11-17 12:05:00.000000Z],
          reanchored: false
        },
        actor: actor
      )

    receipt_bytes =
      Jason.encode!(%{
        "version" => 2,
        "storage_id" => entry.storage_id,
        "block_key" => entry.block_key,
        "destination_sha256" => binding.destination_sha256,
        "verified_at_ms" => DateTime.to_unix(DateTime.utc_now(), :millisecond),
        "objects" => [
          %{
            "name" => "init.mp4",
            "key" => "#{binding.namespace}/#{entry.storage_id}/#{entry.block_key}/init.mp4",
            "length" => desc["init"]["length"],
            "sha256" => desc["init"]["sha256"],
            "etag" => "\"init-etag\"",
            "version_id" => "v1"
          },
          %{
            "name" => "media.m4s",
            "key" => "#{binding.namespace}/#{entry.storage_id}/#{entry.block_key}/media.m4s",
            "length" => desc["media"]["length"],
            "sha256" => desc["media"]["sha256"],
            "etag" => "\"media-etag\"",
            "version_id" => "v1"
          }
        ]
      })

    {:ok, receipt} =
      NVRArchiveReceipt.record(
        binding.id,
        receipt_bytes,
        %{recording_block_id: entry.recording_block_id},
        actor: actor
      )

    now = DateTime.utc_now()

    {:ok, verified_entry} =
      entry
      |> Ash.Changeset.for_update(
        :transition_archive_state,
        %{
          archive_state: :verified,
          archive_state_at: now,
          archived_at: now,
          nvr_archive_receipt_id: receipt.id,
          archive_binding_id: binding.id
        },
        actor: actor
      )
      |> Ash.update(actor: actor)

    [job] =
      VisualIndexJob
      |> Ash.Query.filter(catalog_entry_id == ^verified_entry.id)
      |> Ash.read!(actor: actor)

    installation = %{purpose: :media_worker}

    req = %{
      "schema_version" => 1,
      "job_id" => to_string(job.id),
      "catalog_entry_id" => to_string(verified_entry.id),
      "descriptor_sha256" => verified_entry.descriptor_sha256
    }

    assert {:ok, plan} = VisualWorkerReadGrants.issue_read_grant(installation, req)
    assert plan.backing == :archive
    assert Enum.sort(plan.grant["allowed_methods"]) == ["GET", "HEAD"]
    assert is_binary(plan.init["presigned_url"])
    assert is_binary(plan.media["presigned_url"])
    assert plan.archive["init_presigned_url"] == plan.init["presigned_url"]
    assert plan.archive["media_presigned_url"] == plan.media["presigned_url"]
    assert plan.init["presigned_url"] =~ "X-Amz-Algorithm=AWS4-HMAC-SHA256"
    assert plan.init["presigned_url"] =~ "X-Amz-SignedHeaders=host"
    assert plan.init["presigned_url"] =~ "versionId=v1"
    refute inspect(plan) =~ synthetic_secret
    refute Jason.encode!(plan) =~ synthetic_secret
    assert plan.credential.secret_access_key == synthetic_secret

    # Quarantine entry in place -> subsequent read grant returns {:error, :recording_gone} (410)
    {:ok, _quarantined} =
      verified_entry
      |> Ash.Changeset.for_update(
        :quarantine_in_place,
        %{
          quarantine_reason: :binding_compromised,
          quarantine_receipt: %{"reason" => "synthetic_compromise"},
          quarantined_bytes: 3_072,
          local_state_at: now,
          archive_state: :not_required,
          archive_state_at: now
        },
        actor: actor
      )
      |> Ash.update(actor: actor)

    assert {:error, :recording_gone} = VisualWorkerReadGrants.issue_read_grant(installation, req)
  end

  test "end-to-end ResultProjector idempotency, pgvector HNSW cosine search, pre-k-NN camera scope isolation, frame overlay, and append-only RecordingAccessAudit (3.1, 3.2, 3.3)",
       %{tmp_dir: tmp_dir} do
    _gate = Fixtures.recording_recovery_gate(tmp_dir)
    actor = SystemActor.system(:semantic_e2e_test)
    {cam_authorized, prof_authorized} = create_camera_and_profile(actor, "Gate C2 / Camera 07")
    {cam_forbidden, prof_forbidden} = create_camera_and_profile(actor, "Restricted Vault Camera")

    entry_auth =
      create_indexed_playable_entry(
        cam_authorized,
        prof_authorized,
        1_750_001_000_000_000,
        actor
      )

    entry_forb =
      create_indexed_playable_entry(
        cam_forbidden,
        prof_forbidden,
        1_750_001_000_000_000,
        actor
      )

    [job_auth] =
      VisualIndexJob
      |> Ash.Query.filter(catalog_entry_id == ^entry_auth.id)
      |> Ash.read!(actor: actor)

    [job_forb] =
      VisualIndexJob
      |> Ash.Query.filter(catalog_entry_id == ^entry_forb.id)
      |> Ash.read!(actor: actor)

    red_person_vec = basis_vector(768, 0)
    parking_scene_vec = basis_vector(768, 1)

    auth_result_envelope = %{
      "schema" => "media.results.visual_index.v1",
      "job_id" => to_string(job_auth.id),
      "catalog_entry_id" => to_string(entry_auth.id),
      "camera_source_id" => to_string(cam_authorized.id),
      "stream_profile_id" => to_string(prof_authorized.id),
      "descriptor_sha256" => entry_auth.descriptor_sha256,
      "detector_model_id" => "rtdetr-r18",
      "detector_model_version" => "2026.1",
      "embedder_model_id" => "siglip-b16-384",
      "embedder_model_version" => "2026.1",
      "embedding_dim" => 768,
      "frames" => [
        %{
          "fragment_sequence" => 0,
          "media_pts_ns" => 0,
          "scene_suppressed" => false,
          "detections" => [
            %{
              "object_class" => "person",
              "confidence" => 0.89,
              "bbox" => [0.12, 0.18, 0.34, 0.86],
              "dominant_colors" => ["red"]
            }
          ],
          "embeddings" => [
            %{
              "region_kind" => "scene",
              "region_index" => 0,
              "embedding" => parking_scene_vec
            },
            %{
              "region_kind" => "crop",
              "region_index" => 1,
              "object_class" => "person",
              "confidence" => 0.89,
              "bbox" => [0.12, 0.18, 0.34, 0.86],
              "dominant_colors" => ["red"],
              "embedding" => red_person_vec
            }
          ]
        },
        %{
          "fragment_sequence" => 2,
          "media_pts_ns" => 2_500_000_000,
          "scene_suppressed" => false,
          "detections" => [
            %{
              "object_class" => "person",
              "confidence" => 0.94,
              "bbox" => [0.16, 0.19, 0.38, 0.87],
              "dominant_colors" => ["red"]
            }
          ],
          "embeddings" => [
            %{
              "region_kind" => "crop",
              "region_index" => 1,
              "object_class" => "person",
              "confidence" => 0.94,
              "bbox" => [0.16, 0.19, 0.38, 0.87],
              "dominant_colors" => ["red"],
              "embedding" => red_person_vec
            }
          ]
        }
      ]
    }

    assert {:ok, %{frame_count: 2, embedding_count: 3}} =
             VisualIndexResultProjector.ingest_result(auth_result_envelope)

    assert {:ok, %{frame_count: 2, embedding_count: 3}} =
             VisualIndexResultProjector.ingest_result(auth_result_envelope)

    assert 2 ==
             VisualFrame
             |> Ash.Query.filter(catalog_entry_id == ^entry_auth.id)
             |> Ash.count!(actor: actor)

    assert 3 ==
             VisualEmbedding
             |> Ash.Query.filter(catalog_entry_id == ^entry_auth.id)
             |> Ash.count!(actor: actor)

    forb_result_envelope = %{
      auth_result_envelope
      | "job_id" => to_string(job_forb.id),
        "catalog_entry_id" => to_string(entry_forb.id),
        "camera_source_id" => to_string(cam_forbidden.id),
        "stream_profile_id" => to_string(prof_forbidden.id),
        "descriptor_sha256" => entry_forb.descriptor_sha256
    }

    assert {:ok, _} = VisualIndexResultProjector.ingest_result(forb_result_envelope)

    scoped_investigator = %{
      user: %{id: "investigator-e2e", email: "inv@example.test"},
      permissions: MapSet.new(["devices.view", "devices.cameras.recordings.view"]),
      authorized_camera_source_ids: [cam_authorized.id]
    }

    assert {:error, %Forbidden{}} =
             SemanticSearch.search(
               %{
                 query: "person in red dress",
                 camera_source_id: cam_forbidden.id,
                 from_us: 1_750_000_990_000_000,
                 to_us: 1_750_001_020_000_000
               },
               scope: scoped_investigator,
               text_embedder: fn _q, _ctx -> {:ok, red_person_vec} end
             )

    assert {:ok, search_resp} =
             SemanticSearch.search(
               %{
                 query: "person in red dress",
                 object_class: "person",
                 color: "red",
                 from_us: 1_750_000_990_000_000,
                 to_us: 1_750_001_020_000_000
               },
               scope: scoped_investigator,
               bypass_cache: true,
               text_embedder: fn _q, _ctx -> {:ok, red_person_vec} end
             )

    assert [hit] = search_resp.results
    assert hit.camera_source_id == cam_authorized.id
    assert hit.camera_display_name == "Gate C2 / Camera 07"
    assert hit.time_basis == "received"
    assert hit.score >= 0.99
    assert hit.object_class == "person"
    assert hit.dominant_colors == ["red"]
    assert hit.clip_start_us <= hit.best_timeline_ts_us
    assert hit.clip_end_us > hit.best_timeline_ts_us
    assert length(hit.frame_detections) == 2

    assert {:ok, [overlay_det]} =
             SemanticSearch.get_frame_overlay(
               cam_authorized.id,
               hit.visual_frame_id,
               scope: scoped_investigator
             )

    assert overlay_det.object_class == "person"
    assert length(overlay_det.bbox) == 4

    audits =
      RecordingAccessAudit
      |> Ash.Query.filter(actor_id == "investigator-e2e" and event_kind == :semantic_search)
      |> Ash.read!(actor: actor)

    assert [audit] = audits
    assert is_nil(audit.camera_source_id)
    assert audit.details["query_text"] == "person in red dress"
    assert audit.details["result_count"] == 1

    assert {:error, %Postgrex.Error{}} =
             SQL.query(
               Repo,
               "DELETE FROM platform.camera_recording_access_audits WHERE id = $1",
               [Ecto.UUID.dump!(audit.id)]
             )
  end

  test "trg_camera_recording_catalog_purge_visual_index immediately purges embeddings on tombstone deletion and quarantine while RecordingHold preserves searchable clips and Backfill skips non-playable entries (1.3 & 3.4)",
       %{tmp_dir: tmp_dir} do
    _gate = Fixtures.recording_recovery_gate(tmp_dir)
    actor = SystemActor.system(:semantic_purge_test)
    {cam, prof} = create_camera_and_profile(actor, "Retention Coupling Camera")

    entry_tombstone =
      create_indexed_playable_entry(cam, prof, 1_750_002_000_000_000, actor)

    entry_quarantine =
      create_indexed_playable_entry(cam, prof, 1_750_002_020_000_000, actor)

    entry_held =
      create_indexed_playable_entry(cam, prof, 1_750_002_040_000_000, actor)

    target_vec = basis_vector(768, 5)

    for entry <- [entry_tombstone, entry_quarantine, entry_held] do
      ingest_single_crop_result(entry, target_vec, actor)
    end

    hold_actor = %{
      id: "hold-investigator",
      role: :admin,
      permissions:
        MapSet.new([
          "devices.view",
          "devices.cameras.recordings.view",
          "devices.cameras.recordings.hold"
        ])
    }

    assert {:ok, hold} =
             RecordingHolds.place_hold(
               %{
                 camera_source_id: cam.id,
                 stream_profile_id: prof.id,
                 start_us: 1_750_002_039_000_000,
                 end_us: 1_750_002_050_000_000,
                 kind: :investigation,
                 reason: "Preserve incident clip for semantic search test"
               },
               actor: hold_actor
             )

    assert hold.state == :accepted
    now = DateTime.utc_now()

    # 1. Terminal retention deletion on entry_tombstone (local_state: :reclaimed, archive_state: :not_required)
    #    while the 90-day catalog tombstone row REMAINS in platform.camera_recording_catalog!
    {:ok, tombstoned} =
      entry_tombstone
      |> Ash.Changeset.for_update(
        :transition_local_state,
        %{local_state: :reclaimed, local_state_at: now},
        actor: actor
      )
      |> Ash.update(actor: actor)

    assert tombstoned.local_state == :reclaimed
    assert tombstoned.archive_state == :not_required

    assert {:ok, %RecordingCatalogEntry{}} =
             Ash.get(RecordingCatalogEntry, entry_tombstone.id, actor: actor)

    assert 0 ==
             VisualFrame
             |> Ash.Query.filter(catalog_entry_id == ^entry_tombstone.id)
             |> Ash.count!(actor: actor)

    assert 0 ==
             VisualEmbedding
             |> Ash.Query.filter(catalog_entry_id == ^entry_tombstone.id)
             |> Ash.count!(actor: actor)

    # 2. In-place quarantine on entry_quarantine immediately purges frames & embeddings
    #    and rejects any late worker result!
    {:ok, quarantined} =
      entry_quarantine
      |> Ash.Changeset.for_update(
        :quarantine_in_place,
        %{
          quarantine_reason: :unattributable,
          quarantine_receipt: %{"reason" => "synthetic_unattributable"},
          quarantined_bytes: 3_072,
          local_state_at: now,
          archive_state: :not_required,
          archive_state_at: now
        },
        actor: actor
      )
      |> Ash.update(actor: actor)

    assert quarantined.local_state == :quarantined

    assert 0 ==
             VisualFrame
             |> Ash.Query.filter(catalog_entry_id == ^entry_quarantine.id)
             |> Ash.count!(actor: actor)

    assert 0 ==
             VisualEmbedding
             |> Ash.Query.filter(catalog_entry_id == ^entry_quarantine.id)
             |> Ash.count!(actor: actor)

    assert {:error, :recording_gone} =
             VisualIndexResultProjector.ingest_result(
               build_single_crop_envelope(entry_quarantine, target_vec)
             )

    # 3. Held entry remains intact & searchable; tombstoned & quarantined entries never appear!
    assert {:ok, search_resp} =
             SemanticSearch.search(
               %{
                 query: "yellow package",
                 camera_source_id: cam.id,
                 from_us: 1_750_001_990_000_000,
                 to_us: 1_750_002_060_000_000
               },
               scope: %{
                 user: hold_actor,
                 permissions: hold_actor.permissions,
                 authorized_camera_source_ids: [cam.id]
               },
               bypass_cache: true,
               text_embedder: fn _q, _ctx -> {:ok, target_vec} end
             )

    assert [surviving_hit] = search_resp.results
    assert surviving_hit.catalog_entry_id == entry_held.id

    # 4. Model-upgrade backfill enqueues ONLY entry_held (skipping tombstoned & quarantined entries!)
    assert {:ok, backfill_summary} =
             VisualIndexBackfill.enqueue_model_backfill(%{
               camera_source_id: cam.id,
               embedder_model_id: "siglip-b16-384",
               embedder_model_version: "2026.2",
               embedding_dim: 768
             })

    assert backfill_summary.enqueued_count == 1

    v2_jobs =
      VisualIndexJob
      |> Ash.Query.filter(camera_source_id == ^cam.id and embedder_model_version == "2026.2")
      |> Ash.read!(actor: actor)

    assert [v2_job] = v2_jobs
    assert v2_job.catalog_entry_id == entry_held.id
    assert v2_job.job_kind == :backfill

    # 5. Superseded embedding batch cleanup removes old 2026.1 rows once active model advances to 2026.2
    assert {:ok, %{deleted_embeddings_count: deleted_embs}} =
             VisualIndexBackfill.cleanup_superseded_embeddings(%{
               keep_model_id: "siglip-b16-384",
               keep_model_version: "2026.2",
               batch_size: 100
             })

    assert deleted_embs >= 1

    assert 0 ==
             VisualEmbedding
             |> Ash.Query.filter(catalog_entry_id == ^entry_held.id and model_version == "2026.1")
             |> Ash.count!(actor: actor)
  end

  describe "scheduled outbox relay" do
    test "publishes a pending job once and marks it dispatched only after the PubAck",
         %{tmp_dir: tmp_dir} do
      _gate = Fixtures.recording_recovery_gate(tmp_dir)
      actor = SystemActor.system(:semantic_relay_test)
      {cam, prof} = create_camera_and_profile(actor, "Relay Camera")
      entry = create_indexed_playable_entry(cam, prof, 1_750_002_000_000_000, actor)
      job = job_for(entry, actor)
      test_pid = self()

      publisher = fn subject, payload, opts ->
        published = Jason.decode!(payload)

        if published["job_id"] == to_string(job.id) do
          # Still pending while the publish is in flight.
          send(test_pid, {:published, subject, opts[:msg_id], reload(job, actor).state})
        end

        {:ok, %{stream: "CAMERA_MEDIA_JOBS", seq: 1}}
      end

      assert {:ok, _summary} = VisualIndexDispatcher.relay(publisher: publisher)
      assert_received {:published, "media.jobs.visual_index.v1", msg_id, :pending}
      assert msg_id == "visual-index:#{job.id}"

      dispatched = reload(job, actor)
      assert dispatched.state == :dispatched
      assert dispatched.attempt_count == 1

      assert {:ok, _summary} = VisualIndexDispatcher.relay(publisher: publisher)
      refute_received {:published, _subject, _msg_id, _state}
      assert reload(job, actor).attempt_count == 1
    end

    test "a publish the stream does not acknowledge leaves the jobs pending and stops the pass",
         %{tmp_dir: tmp_dir} do
      _gate = Fixtures.recording_recovery_gate(tmp_dir)
      actor = SystemActor.system(:semantic_relay_unacked_test)
      {cam_a, prof_a} = create_camera_and_profile(actor, "Unacked Camera A")
      {cam_b, prof_b} = create_camera_and_profile(actor, "Unacked Camera B")
      entry_a = create_indexed_playable_entry(cam_a, prof_a, 1_750_003_000_000_000, actor)
      entry_b = create_indexed_playable_entry(cam_b, prof_b, 1_750_003_000_000_000, actor)
      jobs = [job_for(entry_a, actor), job_for(entry_b, actor)]
      test_pid = self()

      publisher = fn _subject, _payload, _opts ->
        send(test_pid, :publish_attempted)
        {:error, :timeout}
      end

      assert {:ok, %{publish_error: :timeout, dispatched_count: 0}} =
               VisualIndexDispatcher.dispatch_pending_jobs(publisher: publisher)

      assert_received :publish_attempted
      refute_received :publish_attempted

      wrong_stream = fn _, _, _ -> {:ok, %{stream: "SYNTHETIC_OTHER", seq: 1}} end

      for job <- jobs do
        assert {:error, {:publish_failed, _}} =
                 VisualIndexDispatcher.dispatch_job(job, publisher: wrong_stream)

        assert %{state: :pending, attempt_count: 0} = reload(job, actor)
      end
    end

    test "a relay stops after ten batches of 100 even with larger limits",
         %{tmp_dir: tmp_dir} do
      _gate = Fixtures.recording_recovery_gate(tmp_dir)
      actor = SystemActor.system(:relay_limit_test)
      {cam, prof} = create_camera_and_profile(actor, "Relay Limit Camera")
      entry = create_indexed_playable_entry(cam, prof, 1_750_003_200_000_000, actor)

      SQL.query!(
        Repo,
        """
        INSERT INTO platform.camera_visual_index_jobs
          (catalog_entry_id, camera_source_id, stream_profile_id, descriptor_sha256, embedder_model_version)
        SELECT catalog_entry_id, camera_source_id, stream_profile_id, descriptor_sha256, 'limit-' || n
        FROM platform.camera_visual_index_jobs CROSS JOIN generate_series(1, 1000) AS n
        WHERE catalog_entry_id = $1
        """,
        [Ecto.UUID.dump!(entry.id)]
      )

      assert {:ok, %{dispatched_count: 1_000}} =
               VisualIndexDispatcher.relay(
                 limit: 250,
                 max_batches: 100,
                 publisher: fn _, _, _ -> :ok end
               )

      assert VisualIndexJob
             |> Ash.Query.filter(catalog_entry_id == ^entry.id and state == :pending)
             |> Ash.count!(actor: actor) >= 1
    end

    test "two relays that read the same job advance it once under one message id",
         %{tmp_dir: tmp_dir} do
      _gate = Fixtures.recording_recovery_gate(tmp_dir)
      actor = SystemActor.system(:semantic_relay_race_test)
      {cam, prof} = create_camera_and_profile(actor, "Concurrent Relay Camera")
      entry = create_indexed_playable_entry(cam, prof, 1_750_004_000_000_000, actor)
      read_by_both = job_for(entry, actor)
      test_pid = self()

      publisher = fn _subject, _payload, opts ->
        send(test_pid, {:msg_id, opts[:msg_id]})
        :ok
      end

      assert {:ok, %{state: :dispatched, attempt_count: 1}} =
               VisualIndexDispatcher.dispatch_job(read_by_both, publisher: publisher)

      assert {:error, :dispatch_superseded} =
               VisualIndexDispatcher.dispatch_job(read_by_both, publisher: publisher)

      expected = "visual-index:#{read_by_both.id}"
      assert_received {:msg_id, ^expected}
      assert_received {:msg_id, ^expected}
      assert %{state: :dispatched, attempt_count: 1} = reload(read_by_both, actor)
    end

    test "a dispatched job is re-published only once the jobs stream can no longer hold it",
         %{tmp_dir: tmp_dir} do
      _gate = Fixtures.recording_recovery_gate(tmp_dir)
      actor = SystemActor.system(:semantic_relay_expiry_test)
      {cam, prof} = create_camera_and_profile(actor, "Backlogged Camera")
      entry = create_indexed_playable_entry(cam, prof, 1_750_005_000_000_000, actor)
      job = job_for(entry, actor)
      dispatched_at = ~U[2026-11-20 08:00:00.000000Z]
      test_pid = self()

      publisher = fn _subject, payload, opts ->
        if Jason.decode!(payload)["job_id"] == to_string(job.id) do
          assert {"Nats-Expected-Stream", "CAMERA_MEDIA_JOBS"} in opts[:headers]
          send(test_pid, {:published, opts[:msg_id]})
        end

        :ok
      end

      assert {:ok, %{state: :dispatched}} =
               VisualIndexDispatcher.dispatch_job(job, publisher: publisher, now: dispatched_at)

      assert_received {:published, _first}

      # Still queued behind a worker backlog five minutes later.
      assert {:ok, _} =
               VisualIndexDispatcher.reconcile_expired_dispatched_jobs(
                 publisher: publisher,
                 now: DateTime.shift(dispatched_at, minute: 5)
               )

      refute_received {:published, _}
      assert reload(job, actor).attempt_count == 1

      # Past the stream's 72-hour retention the message cannot be queued any more.
      assert {:ok, _} =
               VisualIndexDispatcher.reconcile_expired_dispatched_jobs(
                 publisher: publisher,
                 now: DateTime.shift(dispatched_at, second: 72 * 3_600 + 1)
               )

      retry_msg_id = "visual-index:#{job.id}:2"
      assert_received {:published, ^retry_msg_id}
      assert %{state: :dispatched, attempt_count: 2} = reload(job, actor)
    end

    test "legacy backfill rows wait for both retention and deadline before retry or exhaustion",
         %{tmp_dir: tmp_dir} do
      _gate = Fixtures.recording_recovery_gate(tmp_dir)
      actor = SystemActor.system(:legacy_backfill_test)
      {cam, prof} = create_camera_and_profile(actor, "Legacy Backfill Camera")
      entry = create_indexed_playable_entry(cam, prof, 1_750_005_100_000_000, actor)
      job = job_for(entry, actor)
      sent = ~U[2026-11-10 12:00:00.000000Z]

      publisher = fn subject, _, opts ->
        assert subject == "media.jobs.visual_index.backfill.v1"
        assert {"Nats-Expected-Stream", "CAMERA_MEDIA_JOBS"} in opts[:headers]
        send(self(), :backfill_published)
        :ok
      end

      for budget <- [1, 2],
          {deadline, now} <- [{60, 300}, {73 * 3_600, 72 * 3_600}] do
        SQL.query!(
          Repo,
          """
          UPDATE platform.camera_visual_index_jobs SET state = 'dispatched', job_kind = 'backfill',
            attempt_count = 1, max_attempts = $2, dispatched_at = $3, deadline_at = $4 WHERE id = $1
          """,
          [
            Ecto.UUID.dump!(job.id),
            budget,
            DateTime.to_naive(sent),
            DateTime.to_naive(DateTime.shift(sent, second: deadline))
          ]
        )

        opts = [publisher: publisher, now: DateTime.shift(sent, second: now)]

        assert {:ok, %{attempt_count: 1, state: :dispatched}} =
                 VisualIndexDispatcher.dispatch_job(job.id, opts)

        assert {:ok, _} = VisualIndexDispatcher.reconcile_expired_dispatched_jobs(opts)
        refute_received :backfill_published
        assert %{attempt_count: 1, state: :dispatched} = reload(job, actor)
      end

      assert {:ok, %{attempt_count: 2, state: :dispatched}} =
               VisualIndexDispatcher.dispatch_job(job.id,
                 publisher: publisher,
                 now: DateTime.shift(sent, hour: 73)
               )

      assert_received :backfill_published
    end
  end

  describe "visual index result consumer" do
    test "stores a result and acknowledges it and its replay",
         %{tmp_dir: tmp_dir} do
      _gate = Fixtures.recording_recovery_gate(tmp_dir)
      actor = SystemActor.system(:semantic_consumer_test)
      {cam, prof} = create_camera_and_profile(actor, "Result Consumer Camera")
      entry = create_indexed_playable_entry(cam, prof, 1_750_006_000_000_000, actor)
      job = job_for(entry, actor)

      message =
        entry
        |> build_single_crop_envelope(basis_vector(768, 3))
        |> Map.put("job_id", to_string(job.id))
        |> result_message()

      assert {:ok, 1} = CameraVisualIndexResults.process_batch([message])
      assert reload(job, actor).state == :completed
      counts = projection_counts(entry, actor)
      assert counts == {1, 1}

      assert {:ok, 1} = CameraVisualIndexResults.process_batch([message])
      assert projection_counts(entry, actor) == counts
    end

    test "acknowledges a result whose recording is gone only after cancellation succeeds",
         %{tmp_dir: tmp_dir} do
      _gate = Fixtures.recording_recovery_gate(tmp_dir)
      actor = SystemActor.system(:semantic_consumer_gone_test)
      {cam, prof} = create_camera_and_profile(actor, "Lost Copy Camera")
      entry = create_indexed_playable_entry(cam, prof, 1_750_007_000_000_000, actor)
      job = job_for(entry, actor)

      # The only copy went missing while the worker ran; nothing purges on this state.
      {:ok, _} =
        SQL.query(
          Repo,
          "UPDATE platform.camera_recording_catalog SET local_state = 'missing' WHERE id = $1",
          [Ecto.UUID.dump!(entry.id)]
        )

      message =
        entry
        |> build_single_crop_envelope(basis_vector(768, 4))
        |> Map.put("job_id", to_string(job.id))
        |> result_message()

      SQL.query!(Repo, """
      ALTER TABLE platform.camera_visual_index_jobs ADD CONSTRAINT synthetic_refused_cancel
      CHECK (state <> 'cancelled') NOT VALID
      """)

      assert {:incomplete, 0, [{^message, %TransientMessageError{}}]} =
               CameraVisualIndexResults.process_batch([message])

      assert reload(job, actor).state == :pending

      SQL.query!(
        Repo,
        "ALTER TABLE platform.camera_visual_index_jobs DROP CONSTRAINT synthetic_refused_cancel"
      )

      assert {:ok, 1} = CameraVisualIndexResults.process_batch([message])
      assert %{state: :cancelled} = reload(job, actor)
      assert projection_counts(entry, actor) == {0, 0}
    end

    test "a failed matching-job read rolls back the projection", %{tmp_dir: tmp_dir} do
      _gate = Fixtures.recording_recovery_gate(tmp_dir)
      actor = SystemActor.system(:result_lookup_test)
      {cam, prof} = create_camera_and_profile(actor, "Lookup Camera")
      entry = create_indexed_playable_entry(cam, prof, 1_750_007_200_000_000, actor)
      job = job_for(entry, actor)
      envelope = build_single_crop_envelope(entry, basis_vector(768, 3))

      SQL.query!(
        Repo,
        "ALTER TABLE platform.camera_visual_index_jobs RENAME COLUMN completed_at TO synthetic_unavailable"
      )

      for result <- [envelope, Map.put(envelope, "job_id", job.id)] do
        message = result_message(result)

        assert {:incomplete, 0, [{^message, %TransientMessageError{}}]} =
                 CameraVisualIndexResults.process_batch([message])

        assert projection_counts(entry, actor) == {0, 0}
      end
    end

    test "invalid wire results fail only an unambiguously named job", %{tmp_dir: tmp_dir} do
      _gate = Fixtures.recording_recovery_gate(tmp_dir)
      actor = SystemActor.system(:result_decode_test)
      {cam, prof} = create_camera_and_profile(actor, "Decode Camera")
      entry = create_indexed_playable_entry(cam, prof, 1_750_007_300_000_000, actor)
      job = job_for(entry, actor)

      envelope =
        entry
        |> build_single_crop_envelope(basis_vector(768, 3))
        |> Map.put("job_id", job.id)

      valid = result_message(envelope)

      for bytes <- [
            Jason.encode!(Map.put(envelope, "padding", String.duplicate("x", 4_194_304))),
            String.replace_prefix(valid.data, "{", ~s({"job_id":"#{Ecto.UUID.generate()}",))
          ] do
        message = %{valid | data: bytes}

        assert {:incomplete, 0,
                [{^message, %TerminalMessageError{reason: :invalid_result_envelope}}]} =
                 CameraVisualIndexResults.process_batch([message])

        assert reload(job, actor).state == :pending
        assert projection_counts(entry, actor) == {0, 0}
      end

      duplicate_field =
        String.replace(
          valid.data,
          ~s("fragment_sequence":),
          ~s("fragment_sequence":1,"fragment_sequence":)
        )

      message = %{valid | data: duplicate_field}

      assert {:incomplete, 0,
              [{^message, %TerminalMessageError{reason: :invalid_result_envelope}}]} =
               CameraVisualIndexResults.process_batch([message])

      assert %{state: :failed_terminal, last_error_class: "invalid_result_envelope"} =
               reload(job, actor)

      assert projection_counts(entry, actor) == {0, 0}
    end

    test "terminates a result that can never be stored and fails its job",
         %{tmp_dir: tmp_dir} do
      _gate = Fixtures.recording_recovery_gate(tmp_dir)
      actor = SystemActor.system(:semantic_consumer_poison_test)
      {cam, prof} = create_camera_and_profile(actor, "Poison Result Camera")
      entry = create_indexed_playable_entry(cam, prof, 1_750_008_000_000_000, actor)
      job = job_for(entry, actor)

      message =
        entry
        |> build_single_crop_envelope(basis_vector(768, 5))
        |> Map.merge(%{
          "job_id" => to_string(job.id),
          "descriptor_sha256" => String.duplicate("ab", 32)
        })
        |> result_message()

      assert {:incomplete, 0,
              [{^message, %TerminalMessageError{reason: :descriptor_sha256_mismatch}}]} =
               CameraVisualIndexResults.process_batch([message])

      assert %{state: :failed_terminal, last_error_class: "descriptor_sha256_mismatch"} =
               reload(job, actor)

      assert projection_counts(entry, actor) == {0, 0}
    end
  end

  # ---------------------------------------------------------------------------
  # Synthetic DB test helpers
  # ---------------------------------------------------------------------------

  defp job_for(entry, actor) do
    [job] =
      VisualIndexJob
      |> Ash.Query.filter(catalog_entry_id == ^entry.id)
      |> Ash.read!(actor: actor)

    job
  end

  defp reload(job, actor), do: VisualIndexJob.get_by_id!(job.id, actor: actor)

  defp result_message(envelope) do
    %Message{
      data: Jason.encode!(envelope),
      metadata: %{subject: "media.results.visual_index.v1"},
      acknowledger: Broadway.NoopAcknowledger.init()
    }
  end

  defp projection_counts(entry, actor) do
    {VisualFrame |> Ash.Query.filter(catalog_entry_id == ^entry.id) |> Ash.count!(actor: actor),
     VisualEmbedding
     |> Ash.Query.filter(catalog_entry_id == ^entry.id)
     |> Ash.count!(actor: actor)}
  end

  defp create_camera_and_profile(actor, display_name) do
    uid = Ecto.UUID.generate()

    {:ok, cam} =
      Source.create_source(
        %{
          device_uid: "sr:synthetic-cam-#{uid}",
          vendor: "synthetic",
          vendor_camera_id: uid,
          display_name: display_name,
          assigned_agent_id: "agent-synthetic",
          assigned_gateway_id: "gateway-synthetic"
        },
        actor: actor
      )

    {:ok, prof} =
      StreamProfile.create_profile(
        %{
          camera_source_id: cam.id,
          profile_name: "main",
          relay_eligible: true
        },
        actor: actor
      )

    {cam, prof}
  end

  defp reserve_synthetic_block(cam, prof, actor) do
    opts = [actor: actor]

    {:ok, session} =
      RelaySessionManager.request_open(cam.id, prof.id,
        actor: actor,
        control_gateway_resolver: fn _a, g -> {:ok, g} end,
        dispatch_open: fn _a, _p, o, _r -> {:ok, o[:command_id]} end
      )

    active =
      if session.status == :active and is_binary(session.media_ingest_id) do
        session
      else
        ingest_id = session.media_ingest_id || Ecto.UUID.generate()

        assignment =
          Map.take(session, [:agent_id, :gateway_id, :camera_source_id, :stream_profile_id])

        {:ok, activated} =
          RelaySessionLifecycle.activate_session(
            session.id,
            ingest_id,
            assignment,
            opts
          )

        activated
      end

    owner =
      IngestOwner
      |> Ash.Query.filter(camera_source_id == ^cam.id and stream_profile_id == ^prof.id)
      |> Ash.read_one!(opts)

    {:ok, claim} =
      case ServiceRadar.Camera.RecorderClaim
           |> Ash.Query.filter(ingest_owner_id == ^owner.id and state == :active)
           |> Ash.read_one!(opts) do
        nil ->
          RecorderOwnership.acquire(
            owner,
            Ecto.UUID.generate(),
            active.media_ingest_id,
            Ecto.UUID.generate(),
            30_000,
            opts
          )

        existing_claim ->
          {:ok, existing_claim}
      end

    {:ok, block} = RecorderOwnership.reserve_block(owner, claim, @clock, opts)
    {owner, claim, block}
  end

  defp multi_keyframe_descriptor(block) do
    init_sha = sha256("synthetic-init-#{block.id}")
    f0_sha = sha256("synthetic-f0-#{block.id}")
    f1_sha = sha256("synthetic-f1-#{block.id}")
    f2_sha = sha256("synthetic-f2-#{block.id}")
    media_sha = sha256("synthetic-media-#{block.id}")

    desc = %{
      "version" => 1,
      "identity" => RecordingBlock.identity(block),
      "format" => %{"codec" => "avc1.42c00a", "timescale" => 90_000},
      "init" => %{"length" => 256, "sha256" => init_sha},
      "media" => %{"length" => 3_072, "sha256" => media_sha},
      "fragments" => [
        %{
          "sequence" => 0,
          "offset" => 0,
          "length" => 1_024,
          "start_ns" => 0,
          "duration_ns" => 1_000_000_000,
          "sha256" => f0_sha,
          "tail_duration_source" => nil,
          "motion" => "unknown"
        },
        %{
          "sequence" => 1,
          "offset" => 1_024,
          "length" => 1_024,
          "start_ns" => 1_000_000_000,
          "duration_ns" => 1_500_000_000,
          "sha256" => f1_sha,
          "tail_duration_source" => nil,
          "motion" => "unknown"
        },
        %{
          "sequence" => 2,
          "offset" => 2_048,
          "length" => 1_024,
          "start_ns" => 2_500_000_000,
          "duration_ns" => 2_000_000_000,
          "sha256" => f2_sha,
          "tail_duration_source" => nil,
          "motion" => "unknown"
        }
      ]
    }

    {:ok, _} = Descriptor.encode(desc)
    desc
  end

  defp create_indexed_playable_entry(cam, prof, start_us, actor) do
    admin = %{
      id: "admin-helper",
      role: :admin,
      permissions: MapSet.new(["settings.recording.view", "settings.recording.manage"])
    }

    {:ok, _pol} =
      CameraRecordingPolicies.upsert_policy(
        %{
          camera_source_id: cam.id,
          stream_profile_id: prof.id,
          mode: :continuous,
          nvr_member: "nvr-0",
          storage: :local_only,
          visual_index_mode: :keyframes
        },
        actor: admin
      )

    {owner, claim, block} = reserve_synthetic_block(cam, prof, actor)
    desc = multi_keyframe_descriptor(block)
    first_dt = DateTime.from_unix!(start_us, :microsecond)

    {:ok, entry} =
      RecordingBlocks.freeze_and_catalog(
        owner,
        claim,
        block,
        desc,
        %{
          first_unit_pts: 0,
          first_unit_received_at: first_dt,
          reanchored: false
        },
        actor: actor
      )

    entry
  end

  defp ingest_single_crop_result(entry, vec, actor) do
    [job] =
      VisualIndexJob
      |> Ash.Query.filter(catalog_entry_id == ^entry.id)
      |> Ash.read!(actor: actor)

    envelope =
      entry
      |> build_single_crop_envelope(vec)
      |> Map.put("job_id", to_string(job.id))

    {:ok, _} = VisualIndexResultProjector.ingest_result(envelope)
  end

  defp build_single_crop_envelope(entry, vec) do
    %{
      "schema" => "media.results.visual_index.v1",
      "catalog_entry_id" => to_string(entry.id),
      "camera_source_id" => to_string(entry.camera_source_id),
      "stream_profile_id" => to_string(entry.stream_profile_id),
      "descriptor_sha256" => entry.descriptor_sha256,
      "detector_model_id" => "rtdetr-r18",
      "detector_model_version" => "2026.1",
      "embedder_model_id" => "siglip-b16-384",
      "embedder_model_version" => "2026.1",
      "embedding_dim" => 768,
      "frames" => [
        %{
          "fragment_sequence" => 0,
          "media_pts_ns" => 0,
          "scene_suppressed" => false,
          "detections" => [
            %{
              "object_class" => "package",
              "confidence" => 0.91,
              "bbox" => [0.2, 0.4, 0.5, 0.8],
              "dominant_colors" => ["yellow"]
            }
          ],
          "embeddings" => [
            %{
              "region_kind" => "crop",
              "region_index" => 1,
              "object_class" => "package",
              "confidence" => 0.91,
              "bbox" => [0.2, 0.4, 0.5, 0.8],
              "dominant_colors" => ["yellow"],
              "embedding" => vec
            }
          ]
        }
      ]
    }
  end

  defp basis_vector(dim, one_index) do
    for idx <- 0..(dim - 1) do
      if idx == one_index, do: 1.0, else: 0.0
    end
  end

  defp sha256(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
end
