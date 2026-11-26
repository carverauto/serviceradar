defmodule ServiceRadar.Camera.CameraSemanticSearchUnitTest do
  use ExUnit.Case, async: true

  alias Ash.Error.Forbidden
  alias ServiceRadar.Camera.ArchiveCredentialResolver
  alias ServiceRadar.Camera.CameraRecordingPolicies
  alias ServiceRadar.Camera.RecordingArchiveSettings
  alias ServiceRadar.Camera.RecordingHealth
  alias ServiceRadar.Camera.SemanticSearch
  alias ServiceRadar.Camera.VisualIndexDispatcher
  alias ServiceRadar.Camera.VisualIndexDispatchWorker
  alias ServiceRadar.Camera.VisualIndexJob
  alias ServiceRadar.Camera.VisualIndexResultEnvelope
  alias ServiceRadar.Camera.VisualWorkerReadGrants
  alias ServiceRadar.EventWriter.Processors.CameraVisualIndexResults
  alias ServiceRadar.EventWriter.TerminalMessageError
  alias ServiceRadar.Storage.StorageEntitlement
  alias ServiceRadar.Storage.StorageEntitlements

  @cam_a "00000000-0000-4000-8000-000000000101"
  @cam_b "00000000-0000-4000-8000-000000000102"
  @prof_a "00000000-0000-4000-8000-000000000201"
  @prof_b "00000000-0000-4000-8000-000000000202"
  @storage_id "00000000-0000-4000-8000-000000000301"
  @binding_id "00000000-0000-4000-8000-000000000401"
  @secret_id "00000000-0000-4000-8000-000000000501"
  @catalog_id "00000000-0000-7000-8000-000000000601"
  @block_id "00000000-0000-4000-8000-000000000701"
  @job_id "00000000-0000-7000-8000-000000000801"
  @frame_1 "00000000-0000-7000-8000-000000000901"
  @frame_2 "00000000-0000-7000-8000-000000000902"
  @frame_3 "00000000-0000-7000-8000-000000000903"

  @block_key String.duplicate("11", 32)
  @desc_sha String.duplicate("22", 32)
  @init_sha String.duplicate("33", 32)
  @frag0_sha String.duplicate("44", 32)
  @frag1_sha String.duplicate("55", 32)
  @frag2_sha String.duplicate("66", 32)
  @media_sha String.duplicate("88", 32)

  describe "CameraRecordingPolicy visual_index_* bounds and StorageEntitlement ceilings (1.1)" do
    test "validates visual_index_min_interval_ms and visual_index_max_frames_per_block bounds" do
      loaders = policy_loaders(nil, [])

      valid_cs =
        CameraRecordingPolicies.preview_changeset(
          %{
            camera_source_id: @cam_a,
            stream_profile_id: @prof_a,
            mode: :continuous,
            nvr_member: "nvr-0",
            storage: :local_only,
            visual_index_mode: :keyframes,
            visual_index_min_interval_ms: 4_000,
            visual_index_max_frames_per_block: 32
          },
          loaders: loaders
        )

      assert valid_cs.valid?

      too_fast_cs =
        CameraRecordingPolicies.preview_changeset(
          %{
            camera_source_id: @cam_a,
            stream_profile_id: @prof_a,
            mode: :continuous,
            nvr_member: "nvr-0",
            storage: :local_only,
            visual_index_mode: :keyframes,
            visual_index_min_interval_ms: 250
          },
          loaders: loaders
        )

      refute too_fast_cs.valid?
      assert Enum.any?(too_fast_cs.errors, &(&1.field == :visual_index_min_interval_ms))

      too_many_frames_cs =
        CameraRecordingPolicies.preview_changeset(
          %{
            camera_source_id: @cam_a,
            stream_profile_id: @prof_a,
            mode: :continuous,
            nvr_member: "nvr-0",
            storage: :local_only,
            visual_index_mode: :keyframes,
            visual_index_max_frames_per_block: 1024
          },
          loaders: loaders
        )

      refute too_many_frames_cs.valid?

      assert Enum.any?(
               too_many_frames_cs.errors,
               &(&1.field == :visual_index_max_frames_per_block)
             )
    end

    test "enforces optional StorageEntitlement visual_indexing_enabled and max_visual_index_cameras while absent limits are no-ops" do
      now = ~U[2026-11-17 16:00:00Z]

      base_ent =
        struct(StorageEntitlement, %{
          id: "deployment",
          schema_version: 1,
          deployment_ref: "dep-synthetic-1",
          generation: 1,
          revision: 1,
          document_sha256: String.duplicate("aa", 32),
          issued_at: now,
          applied_at: now,
          recordings_present: true,
          recordings_enabled: true,
          recordings_allocation_bytes: 100_000_000_000,
          recordings_overage_mode: :off,
          recordings_capacity_policy: :stop_archiving,
          warehouse_present: false,
          warehouse_enabled: false
        })

      disabled_ent = %{base_ent | recordings_visual_indexing_enabled: false}

      blocked_cs =
        CameraRecordingPolicies.preview_changeset(
          %{
            camera_source_id: @cam_a,
            stream_profile_id: @prof_a,
            mode: :continuous,
            nvr_member: "nvr-0",
            storage: :local_only,
            visual_index_mode: :keyframes
          },
          hosted_install?: true,
          loaders: policy_loaders(disabled_ent, [])
        )

      refute blocked_cs.valid?

      assert Enum.any?(blocked_cs.errors, fn err ->
               err.field == :visual_index_mode and
                 String.contains?(Exception.message(err), "plan")
             end)

      capped_ent = %{
        base_ent
        | recordings_visual_indexing_enabled: true,
          recordings_max_visual_index_cameras: 1
      }

      existing_policies = [
        %{
          id: "00000000-0000-4000-8000-000000000999",
          camera_source_id: @cam_b,
          stream_profile_id: @prof_b,
          mode: :continuous,
          visual_index_mode: :keyframes
        }
      ]

      over_cap_cs =
        CameraRecordingPolicies.preview_changeset(
          %{
            camera_source_id: @cam_a,
            stream_profile_id: @prof_a,
            mode: :continuous,
            nvr_member: "nvr-0",
            storage: :local_only,
            visual_index_mode: :keyframes
          },
          hosted_install?: true,
          loaders: policy_loaders(capped_ent, existing_policies)
        )

      refute over_cap_cs.valid?

      assert Enum.any?(over_cap_cs.errors, fn err ->
               err.field == :visual_index_mode and
                 String.contains?(Exception.message(err), "limited by your plan")
             end)

      legacy_ent = %{
        base_ent
        | recordings_visual_indexing_enabled: nil,
          recordings_max_visual_index_cameras: nil
      }

      noop_cs =
        CameraRecordingPolicies.preview_changeset(
          %{
            camera_source_id: @cam_a,
            stream_profile_id: @prof_a,
            mode: :continuous,
            nvr_member: "nvr-0",
            storage: :local_only,
            visual_index_mode: :keyframes
          },
          hosted_install?: true,
          loaders: policy_loaders(legacy_ent, existing_policies)
        )

      assert noop_cs.valid?
    end

    test "StorageEntitlements effective_state projects optional visual_indexing_enabled and max_visual_index_cameras" do
      now = ~U[2026-11-17 16:00:00Z]

      row =
        struct(StorageEntitlement, %{
          id: "deployment",
          schema_version: 1,
          deployment_ref: "dep-synthetic-1",
          generation: 1,
          revision: 3,
          document_sha256: String.duplicate("aa", 32),
          issued_at: now,
          applied_at: now,
          recordings_present: true,
          recordings_enabled: true,
          recordings_allocation_bytes: 100_000_000_000,
          recordings_overage_mode: :off,
          recordings_overage_cap_bytes: nil,
          recordings_capacity_policy: :stop_archiving,
          recordings_retention_max_days: 30,
          recordings_retention_default_days: 14,
          recordings_max_cameras: 10,
          recordings_visual_indexing_enabled: true,
          recordings_max_visual_index_cameras: 4,
          recordings_pending: nil,
          warehouse_present: false,
          warehouse_enabled: false
        })

      eff =
        StorageEntitlements.effective_state(
          hosted_install?: true,
          now: now,
          loaders: %{
            entitlement_loader: fn -> {:ok, row} end,
            recording_control_loader: fn -> {:ok, nil} end
          }
        )

      assert eff.applied? == true
      assert eff.recordings.visual_indexing_enabled == true
      assert eff.recordings.max_visual_index_cameras == 4
    end
  end

  describe "VisualIndexDispatcher keyframe sampling, metadata-only envelope, and health summary (1.4)" do
    test "samples only IDR keyframes honoring min_interval_ms and max_frames and builds credential-free envelope" do
      descriptor = sample_descriptor()

      sampled = VisualIndexDispatcher.sample_descriptor_fragments(descriptor, 2_000, 64)
      assert Enum.map(sampled, & &1["sequence"]) == [0, 2]

      capped = VisualIndexDispatcher.sample_descriptor_fragments(descriptor, 500, 1)
      assert Enum.map(capped, & &1["sequence"]) == [0]

      job = %{
        id: @job_id,
        catalog_entry_id: @catalog_id,
        camera_source_id: @cam_a,
        stream_profile_id: @prof_a,
        job_kind: :live,
        attempt_count: 1,
        max_attempts: 5,
        detector_model_id: "yolox-s",
        detector_model_version: "2026.1",
        embedder_model_id: "siglip-b16-384",
        embedder_model_version: "2026.1",
        embedding_dim: 768,
        sampled_fragments: sampled,
        descriptor_sha256: @desc_sha
      }

      assert {:ok, subject, payload_bin, decoded} =
               VisualIndexDispatcher.build_envelope(job, now: ~U[2026-11-17 16:30:00Z])

      assert subject == "media.jobs.visual_index.v1"
      assert Jason.decode!(payload_bin) == decoded
      assert decoded["schema_version"] == 1
      assert decoded["job_id"] == @job_id
      assert decoded["catalog_entry_id"] == @catalog_id
      assert decoded["descriptor_sha256"] == @desc_sha
      assert decoded["fragment_count"] == 2
      assert decoded["sampled_fragment_sequences"] == [0, 2]

      refute Map.has_key?(decoded, "secret_access_key")
      refute Map.has_key?(decoded, "access_key_id")
      refute Map.has_key?(decoded, "media_bytes")
      refute Map.has_key?(decoded, "roi_grid")
    end

    test "includes compact roi_grid in job envelope when camera source has detection_roi_grid ignore cells" do
      descriptor = sample_descriptor()
      sampled = VisualIndexDispatcher.sample_descriptor_fragments(descriptor, 2_000, 64)

      job = %{
        id: @job_id,
        catalog_entry_id: @catalog_id,
        camera_source_id: @cam_a,
        stream_profile_id: @prof_a,
        job_kind: :live,
        attempt_count: 0,
        max_attempts: 5,
        detector_model_id: "yolox-s",
        detector_model_version: "2026.1",
        embedder_model_id: "siglip-b16-384",
        embedder_model_version: "2026.1",
        embedding_dim: 768,
        sampled_fragments: sampled,
        descriptor_sha256: @desc_sha
      }

      # 12x8 grid: cell 0 -> [0, 0], cell 13 -> [1, 1], cell 25 -> [2, 1] (also in focus so excluded)
      source_with_roi = %{
        id: @cam_a,
        metadata: %{
          "detection_roi_grid" => %{
            "version" => 1,
            "rows" => 8,
            "cols" => 12,
            "focus" => [25],
            "ignore" => [13, 0, 25]
          }
        }
      }

      assert {:ok, _subject, payload_bin, decoded} =
               VisualIndexDispatcher.build_envelope(job,
                 now: ~U[2026-11-17 16:30:00Z],
                 camera_source: source_with_roi
               )

      assert byte_size(payload_bin) <= 4_096

      assert decoded["roi_grid"] == %{
               "rows" => 8,
               "cols" => 12,
               "ignore_cells" => [[0, 0], [1, 1]]
             }

      # Empty ignore list omits roi_grid completely
      source_focus_only = %{
        id: @cam_a,
        metadata: %{
          "detection_roi_grid" => %{
            "version" => 1,
            "rows" => 8,
            "cols" => 12,
            "focus" => [0, 1],
            "ignore" => []
          }
        }
      }

      assert {:ok, _subject, _bin, decoded_empty} =
               VisualIndexDispatcher.build_envelope(job,
                 now: ~U[2026-11-17 16:30:00Z],
                 camera_source: source_focus_only
               )

      refute Map.has_key?(decoded_empty, "roi_grid")
    end

    test "a catalog lookup failure prevents live and backfill publication on initial dispatch and retry" do
      now = ~U[2026-01-05 00:00:00Z]
      expired = ~U[2026-01-01 00:00:00Z]
      publisher = fn _, _, _ -> flunk("published without checking the catalog entry") end
      loaders = %{entry_loader: fn @catalog_id -> {:error, :catalog_unavailable} end}

      for kind <- [:live, :backfill], state <- [:pending, :dispatched] do
        job = %VisualIndexJob{
          id: @job_id,
          catalog_entry_id: @catalog_id,
          job_kind: kind,
          state: state,
          attempt_count: 1,
          max_attempts: 5,
          deadline_at: expired,
          updated_at: expired,
          dispatched_at: expired
        }

        assert {:error, :catalog_unavailable} =
                 VisualIndexDispatcher.dispatch_job(job,
                   loaders: loaders,
                   publisher: publisher,
                   now: now
                 )
      end
    end

    test "legacy dispatch start cannot expire a job before its acknowledged update ages out" do
      start = ~U[2026-01-01 00:00:00Z]
      ack = DateTime.shift(start, second: 3)
      tick = DateTime.shift(start, day: 3, second: 1)

      for max_attempts <- [1, 2] do
        job = %VisualIndexJob{
          id: @job_id,
          catalog_entry_id: @catalog_id,
          state: :dispatched,
          attempt_count: 1,
          max_attempts: max_attempts,
          dispatched_at: start,
          updated_at: ack,
          deadline_at: DateTime.shift(start, minute: 1)
        }

        assert {:ok, ^job} = VisualIndexDispatcher.dispatch_job(job, now: tick)
      end
    end

    test "RecordingHealth.summary/1 aggregates visual_indexing queue states and active model" do
      now = ~U[2026-11-17 16:30:00Z]
      oldest_pending = ~U[2026-11-17 16:25:00Z]

      loaders = %{
        settings_loader: fn ->
          {:ok, RecordingArchiveSettings.default_settings()}
        end,
        entitlement_loader: fn -> {:ok, nil} end,
        catalog_entries_loader: fn -> {:ok, []} end,
        archive_bindings_loader: fn -> {:ok, []} end,
        holds_loader: fn -> {:ok, []} end,
        reservations_loader: fn ->
          {:ok, %{unresolved_count: 0, oldest_age_seconds: nil, items: []}}
        end,
        policies_loader: fn ->
          {:ok,
           [
             %{
               id: "00000000-0000-4000-8000-000000000991",
               camera_source_id: @cam_a,
               stream_profile_id: @prof_a,
               mode: :continuous,
               nvr_member: "nvr-0",
               storage: :local_only,
               visual_index_mode: :keyframes
             }
           ]}
        end,
        storage_settings_loader: fn -> {:ok, []} end,
        local_storage_bindings_loader: fn -> {:ok, []} end,
        gaps_loader: fn _ -> {:ok, []} end,
        dispositions_loader: fn _ -> {:ok, []} end,
        visual_index_jobs_loader: fn ->
          {:ok,
           [
             %{state: :pending, job_kind: :live, count: 3, oldest_inserted_at: oldest_pending},
             %{state: :dispatched, job_kind: :backfill, count: 2, oldest_inserted_at: now},
             %{state: :completed, job_kind: :live, count: 14}
           ]}
        end,
        alerts_loader: fn -> {:ok, []} end
      }

      assert {:ok, summary} =
               RecordingHealth.summary(
                 actor: %{id: "op-1", role: :system},
                 now: now,
                 loaders: loaders
               )

      vi = summary.visual_indexing
      assert vi.enabled_policy_count == 1
      assert vi.pending_count == 3
      assert vi.dispatched_count == 2
      assert vi.completed_count == 14
      assert vi.failed_terminal_count == 0
      assert vi.backlog_count == 5
      assert vi.oldest_pending_age_seconds == 300
      assert vi.worker_health_status == :healthy
      assert vi.active_model.embedder_model_id == "siglip-b16-384"
      assert vi.active_model.embedding_dim == 768
    end

    test "VisualIndexDispatchWorker coalesces pending ticks without blocking on executing jobs" do
      changeset = VisualIndexDispatchWorker.new(%{})
      unique = Ecto.Changeset.get_change(changeset, :unique)

      assert Ecto.Changeset.get_field(changeset, :queue) == "maintenance"
      assert Ecto.Changeset.get_field(changeset, :max_attempts) == 1
      assert unique.period == :infinity
      assert Enum.sort(unique.states) == [:available, :scheduled]
      refute :executing in unique.states
    end

    test "VisualIndexDispatchWorker.enqueue/1 enqueues immediately when enabled and is :noop when disabled" do
      parent = self()

      assert :noop =
               VisualIndexDispatchWorker.enqueue(
                 enabled_fn: fn -> false end,
                 insert_fn: fn _cs ->
                   flunk("should not insert when visual indexing is disabled")
                 end
               )

      assert {:ok, :enqueued} =
               VisualIndexDispatchWorker.enqueue(
                 enabled_fn: fn -> true end,
                 insert_fn: fn cs ->
                   send(parent, {:inserted, cs})
                   {:ok, :enqueued}
                 end
               )

      assert_receive {:inserted, %Ecto.Changeset{} = cs}

      assert Ecto.Changeset.get_field(cs, :worker) ==
               "ServiceRadar.Camera.VisualIndexDispatchWorker"

      assert Ecto.Changeset.get_field(cs, :queue) == "maintenance"
    end

    test "VisualIndexDispatcher.nudge_dispatch/1 invokes dispatch_enqueuer and stays best-effort on errors" do
      parent = self()

      assert :ok =
               VisualIndexDispatcher.nudge_dispatch(
                 dispatch_enqueuer: fn ->
                   send(parent, :nudged)
                   {:ok, :queued}
                 end
               )

      assert_receive :nudged

      assert :ok =
               VisualIndexDispatcher.nudge_dispatch(
                 dispatch_enqueuer: fn -> {:error, :oban_unavailable} end
               )
    end
  end

  describe "VisualWorkerReadGrants execution-time fragment grants and 410 Gone (1.6)" do
    test "returns {:error, :recording_gone} for missing, quarantined, or reclaimed+deleted entries" do
      installation = %{deployment_ref: "dep-1", generation: 1, purpose: :media_worker}

      req = %{
        "schema_version" => 1,
        "job_id" => @job_id,
        "catalog_entry_id" => @catalog_id,
        "descriptor_sha256" => @desc_sha
      }

      assert {:error, :recording_gone} =
               VisualWorkerReadGrants.issue_read_grant(installation, req,
                 loaders: grant_loaders(nil)
               )

      quarantined_entry =
        Map.merge(playable_archive_entry(), %{
          local_state: :quarantined,
          quarantine_reason: :unattributable_block
        })

      assert {:error, :recording_gone} =
               VisualWorkerReadGrants.issue_read_grant(installation, req,
                 loaders: grant_loaders(quarantined_entry)
               )

      deleted_tombstone =
        Map.merge(playable_archive_entry(), %{
          local_state: :reclaimed,
          archive_state: :deleted
        })

      assert {:error, :recording_gone} =
               VisualWorkerReadGrants.issue_read_grant(installation, req,
                 loaders: grant_loaders(deleted_tombstone)
               )
    end

    test "issues archive range plan with <= 4 MiB coalescing, GET/HEAD-only CredentialBrokerGrant, 5m SigV4 pre-signed URLs, and zero leaked secrets" do
      installation = %{deployment_ref: "dep-1", generation: 1, purpose: :media_worker}
      synthetic_secret_key = "test-reader-secret-key-0000000000"
      signed_at = ~U[2026-11-17 12:00:00Z]

      req = %{
        "schema_version" => 1,
        "job_id" => @job_id,
        "catalog_entry_id" => @catalog_id,
        "descriptor_sha256" => @desc_sha
      }

      entry = playable_archive_entry()
      loaders = grant_loaders(entry, synthetic_secret_key)

      assert {:ok, plan} =
               VisualWorkerReadGrants.issue_read_grant(installation, req,
                 loaders: loaders,
                 now: signed_at,
                 ttl_seconds: 300
               )

      assert plan.backing == :archive
      assert plan.source == "archive"
      assert plan.init_sha256 == @init_sha
      assert Enum.map(plan.fragments, & &1["sequence"]) == [0, 2]
      assert Enum.all?(plan.coalesced_ranges, &(&1["length"] <= 4 * 1_048_576))

      assert is_map(plan.grant)
      assert plan.grant["role"] == "reader"
      assert Enum.sort(plan.grant["allowed_methods"]) == ["GET", "HEAD"]
      refute "PUT" in plan.grant["allowed_methods"]
      refute "DELETE" in plan.grant["allowed_methods"]

      init_url = plan.archive["init_presigned_url"]
      media_url = plan.archive["media_presigned_url"]
      assert is_binary(init_url)
      assert is_binary(media_url)
      assert plan.init["presigned_url"] == init_url
      assert plan.media["presigned_url"] == media_url

      init_uri = URI.parse(init_url)
      init_query = URI.decode_query(init_uri.query)
      assert init_uri.scheme == "https"
      assert init_uri.host == "objects.example.com"

      assert init_uri.path ==
               "/synthetic-archive/nvr/archive-v2/#{@storage_id}/#{@block_key}/init.mp4"

      assert init_query["X-Amz-Algorithm"] == "AWS4-HMAC-SHA256"

      assert init_query["X-Amz-Credential"] ==
               "test-reader-access-key/20261117/us-east-1/s3/aws4_request"

      assert init_query["X-Amz-Date"] == "20261117T120000Z"
      assert init_query["X-Amz-Expires"] == "300"
      assert init_query["X-Amz-SignedHeaders"] == "host"
      assert init_query["versionId"] == "synth-init-v1"
      assert init_query["X-Amz-Signature"] =~ ~r/\A[0-9a-f]{64}\z/

      media_uri = URI.parse(media_url)
      media_query = URI.decode_query(media_uri.query)

      assert media_uri.path ==
               "/synthetic-archive/nvr/archive-v2/#{@storage_id}/#{@block_key}/media.m4s"

      assert media_query["X-Amz-Algorithm"] == "AWS4-HMAC-SHA256"
      assert media_query["X-Amz-Expires"] == "300"
      assert media_query["X-Amz-SignedHeaders"] == "host"
      assert media_query["versionId"] == "synth-media-v1"
      assert media_query["X-Amz-Signature"] =~ ~r/\A[0-9a-f]{64}\z/
      assert media_query["X-Amz-Signature"] != init_query["X-Amz-Signature"]

      expected_init_url =
        [
          access_key_id: "test-reader-access-key",
          secret_access_key: synthetic_secret_key,
          region: "us-east-1",
          service: "s3",
          datetime: signed_at,
          method: :get,
          url:
            "https://objects.example.com/synthetic-archive/nvr/archive-v2/#{@storage_id}/#{@block_key}/init.mp4",
          expires: 300,
          headers: [],
          query: [{"versionId", "synth-init-v1"}]
        ]
        |> Req.Utils.aws_sigv4_url()
        |> URI.to_string()

      assert init_url == expected_init_url

      refute inspect(plan) =~ synthetic_secret_key
      encoded_json = Jason.encode!(plan)
      refute encoded_json =~ synthetic_secret_key
      decoded_plan = Jason.decode!(encoded_json)
      refute Map.has_key?(decoded_plan["credential"], "secret_access_key")
      refute Map.has_key?(decoded_plan["credential"], "access_key_id")
      refute Map.has_key?(decoded_plan["credential"], "session_token")
    end

    test "signs optional X-Amz-Security-Token and omits versionId when unversioned while keeping credential redacted" do
      installation = %{deployment_ref: "dep-1", generation: 1, purpose: :media_worker}
      synthetic_secret_key = "test-reader-secret-key-0000000000"
      synthetic_session_token = "test-sts-session-token-001"
      signed_at = ~U[2026-11-17 12:30:00Z]

      req = %{
        "schema_version" => 1,
        "job_id" => @job_id,
        "catalog_entry_id" => @catalog_id,
        "descriptor_sha256" => @desc_sha
      }

      base_loaders = grant_loaders(playable_archive_entry(), synthetic_secret_key)

      unversioned_sts_loaders = %{
        base_loaders
        | receipt_loader: fn _entry ->
            {:ok,
             %{
               recording_block_id: @block_id,
               archive_binding_id: @binding_id,
               objects: [
                 %{
                   "name" => "init.mp4",
                   "key" => "nvr/archive-v2/#{@storage_id}/#{@block_key}/init.mp4",
                   "length" => 1_024,
                   "sha256" => @init_sha,
                   "etag" => "\"etag-init\""
                 },
                 %{
                   "name" => "media.m4s",
                   "key" => "nvr/archive-v2/#{@storage_id}/#{@block_key}/media.m4s",
                   "length" => 212_992,
                   "sha256" => @media_sha,
                   "etag" => "\"etag-media\""
                 }
               ]
             }}
          end,
          credential_resolver: fn binding, _role, ttl ->
            {:ok, grant_attrs} =
              ArchiveCredentialResolver.grant_attrs(binding, :reader, @secret_id,
                ttl_seconds: ttl
              )

            {:ok,
             %{
               grant: grant_attrs,
               credential: %{
                 "secret_id" => @secret_id,
                 "generation" => 2,
                 "access_key_id" => "test-reader-access-key",
                 "secret_access_key" => synthetic_secret_key,
                 "session_token" => synthetic_session_token
               }
             }}
          end
      }

      assert {:ok, plan} =
               VisualWorkerReadGrants.issue_read_grant(installation, req,
                 loaders: unversioned_sts_loaders,
                 now: signed_at,
                 ttl_seconds: 900
               )

      init_query =
        plan.init["presigned_url"] |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

      assert init_query["X-Amz-Expires"] == "900"
      assert init_query["X-Amz-Security-Token"] == synthetic_session_token
      assert init_query["X-Amz-SignedHeaders"] == "host"
      refute Map.has_key?(init_query, "versionId")

      refute inspect(plan.credential) =~ synthetic_secret_key
      refute inspect(plan.credential) =~ synthetic_session_token
      refute Jason.encode!(plan.credential) =~ synthetic_secret_key
      refute Jason.encode!(plan.credential) =~ synthetic_session_token
    end

    test "issues local analysis_read pool plan when block is local_only / unarchived" do
      installation = %{deployment_ref: "dep-1", generation: 1, purpose: :media_worker}

      req = %{
        "schema_version" => 1,
        "job_id" => @job_id,
        "catalog_entry_id" => @catalog_id,
        "descriptor_sha256" => @desc_sha
      }

      local_entry =
        Map.merge(playable_archive_entry(), %{
          local_state: :present,
          archive_state: :not_required,
          archive_binding_id: nil
        })

      assert {:ok, plan} =
               VisualWorkerReadGrants.issue_read_grant(installation, req,
                 loaders: grant_loaders(local_entry)
               )

      assert plan.backing == :local
      assert plan.read_pool == "analysis_read"
      assert plan.nvr_member == "nvr-0"
      assert plan.init["path"] == "/v1/blocks/#{@block_key}/init"
    end
  end

  describe "SemanticSearch RBAC, scope pre-filtering, ETS cache, 250ms fail-closed RPC, and coalescing (3.2 & 3.3)" do
    setup do
      SemanticSearch.clear_query_cache()
      :ok
    end

    test "denies live-only viewer lacking devices.cameras.recordings.view before touching embedder" do
      embedder_calls = :counters.new(1, [:atomics])

      live_only_scope = %{
        user: %{id: "viewer-live-only", email: "viewer@example.test"},
        permissions: MapSet.new(["devices.view", "devices.cameras.view"])
      }

      assert {:error, %Forbidden{}} =
               SemanticSearch.search(
                 %{query: "person in red jacket"},
                 scope: live_only_scope,
                 text_embedder: fn _q, _ctx ->
                   :counters.add(embedder_calls, 1, 1)
                   {:ok, unit_vec(768)}
                 end,
                 loaders: %{
                   sources: [%{id: @cam_a, display_name: "Gate North", device_uid: "dev-a"}]
                 }
               )

      assert :counters.get(embedder_calls, 1) == 0
    end

    test "denies explicit camera_source_id outside caller's authorized Source scope before vector search" do
      embedder_calls = :counters.new(1, [:atomics])
      vector_calls = :counters.new(1, [:atomics])

      scoped_caller = %{
        user: %{id: "investigator-1", email: "inv@example.test"},
        permissions: MapSet.new(["devices.view", "devices.cameras.recordings.view"])
      }

      assert {:error, %Forbidden{}} =
               SemanticSearch.search(
                 %{query: "white cargo van", camera_source_id: @cam_b},
                 scope: scoped_caller,
                 text_embedder: fn _q, _ctx ->
                   :counters.add(embedder_calls, 1, 1)
                   {:ok, unit_vec(768)}
                 end,
                 loaders: %{
                   sources: [%{id: @cam_a, display_name: "Gate North", device_uid: "dev-a"}],
                   embeddings_loader: fn _vec, _spec ->
                     :counters.add(vector_calls, 1, 1)
                     {:ok, []}
                   end
                 }
               )

      assert :counters.get(embedder_calls, 1) == 0
      assert :counters.get(vector_calls, 1) == 0
    end

    test "fails closed with :search_embedder_unavailable when text embedder exceeds deadline" do
      caller = %{
        user: %{id: "investigator-1"},
        permissions: MapSet.new(["devices.view", "devices.cameras.recordings.view"])
      }

      assert {:error, :search_embedder_unavailable} =
               SemanticSearch.search(
                 %{query: "forklift near loading dock"},
                 scope: caller,
                 bypass_cache: true,
                 embedder_timeout_ms: 40,
                 text_embedder: fn _q, _ctx ->
                   Process.sleep(200)
                   {:ok, unit_vec(768)}
                 end,
                 loaders: %{
                   sources: [%{id: @cam_a, display_name: "Dock A", device_uid: "dev-a"}]
                 }
               )
    end

    test "caches query text embeddings in ETS, coalesces adjacent keyframes within 6s, and emits :semantic_search audit" do
      embedder_calls = :counters.new(1, [:atomics])
      test_pid = self()

      caller = %{
        user: %{id: "investigator-42"},
        permissions: MapSet.new(["devices.view", "devices.cameras.recordings.view"])
      }

      candidates = [
        %{
          id: "00000000-0000-7000-8000-000000000a01",
          visual_frame_id: @frame_1,
          catalog_entry_id: @catalog_id,
          camera_source_id: @cam_a,
          stream_profile_id: @prof_a,
          timeline_ts_us: 10_000_000,
          region_kind: "crop",
          region_index: 1,
          object_class: "person",
          confidence: 0.88,
          bbox: %{"x1" => 0.1, "y1" => 0.2, "x2" => 0.3, "y2" => 0.8},
          dominant_colors: ["red"],
          time_basis: "received",
          detections: [],
          catalog_start_us: 0,
          catalog_end_us: 60_000_000,
          score: 0.84
        },
        %{
          id: "00000000-0000-7000-8000-000000000a02",
          visual_frame_id: @frame_2,
          catalog_entry_id: @catalog_id,
          camera_source_id: @cam_a,
          stream_profile_id: @prof_a,
          timeline_ts_us: 12_000_000,
          region_kind: "crop",
          region_index: 1,
          object_class: "person",
          confidence: 0.93,
          bbox: %{"x1" => 0.15, "y1" => 0.2, "x2" => 0.35, "y2" => 0.82},
          dominant_colors: ["red"],
          time_basis: "received",
          detections: [],
          catalog_start_us: 0,
          catalog_end_us: 60_000_000,
          score: 0.91
        },
        %{
          id: "00000000-0000-7000-8000-000000000a03",
          visual_frame_id: @frame_3,
          catalog_entry_id: @catalog_id,
          camera_source_id: @cam_a,
          stream_profile_id: @prof_a,
          timeline_ts_us: 25_000_000,
          region_kind: "scene",
          region_index: 0,
          object_class: nil,
          confidence: nil,
          bbox: nil,
          dominant_colors: [],
          time_basis: "received",
          detections: [],
          catalog_start_us: 0,
          catalog_end_us: 60_000_000,
          score: 0.72
        }
      ]

      opts = [
        scope: caller,
        now: ~U[2026-11-17 00:01:00Z],
        text_embedder: fn _q, _ctx ->
          :counters.add(embedder_calls, 1, 1)
          {:ok, unit_vec(768)}
        end,
        loaders: %{
          sources: [%{id: @cam_a, display_name: "Bay 4 Camera", device_uid: "dev-bay-4"}],
          embeddings_loader: fn _vec, spec ->
            send(test_pid, {:queried_cameras, spec.camera_source_ids})
            {:ok, candidates}
          end,
          audit_writer: fn audit ->
            send(test_pid, {:search_audit, audit})
            {:ok, audit}
          end
        }
      ]

      assert {:ok, resp1} =
               SemanticSearch.search(
                 %{query: "  Person   in RED coat  ", from_us: 0, to_us: 60_000_000},
                 opts
               )

      assert {:ok, _resp2} =
               SemanticSearch.search(
                 %{query: "person in red coat", from_us: 0, to_us: 60_000_000},
                 opts
               )

      assert :counters.get(embedder_calls, 1) == 1
      assert_received {:queried_cameras, [@cam_a]}

      assert [top_clip, second_clip] = resp1.results
      assert top_clip.visual_frame_id == @frame_2
      assert top_clip.best_timeline_ts_us == 12_000_000
      assert top_clip.clip_start_us == 8_000_000
      assert top_clip.clip_end_us == 14_000_000
      assert top_clip.score == 0.91
      assert top_clip.camera_display_name == "Bay 4 Camera"
      assert top_clip.time_basis == "received"
      assert top_clip.bbox == [0.15, 0.2, 0.35, 0.82]
      assert length(top_clip.frame_detections) == 2

      assert second_clip.visual_frame_id == @frame_3
      assert second_clip.best_timeline_ts_us == 25_000_000
      assert second_clip.region_kind == "scene"

      assert_received {:search_audit, audit}
      assert audit.event_kind == :semantic_search
      assert audit.actor_id == "investigator-42"
      assert audit.camera_source_id == nil
      assert audit.details["result_count"] == 2
      assert audit.details["authorized_camera_count"] == 1
    end

    test "defaults min_score to 0.04 for SigLIP cosine similarity and allows caller overrides" do
      test_pid = self()

      caller = %{
        user: %{id: "investigator-siglip"},
        permissions: MapSet.new(["devices.view", "devices.cameras.recordings.view"])
      }

      opts = [
        scope: caller,
        now: ~U[2026-11-17 00:01:00Z],
        bypass_cache: true,
        text_embedder: fn _q, _ctx -> {:ok, unit_vec(768)} end,
        loaders: %{
          sources: [%{id: @cam_a, display_name: "Yard Cam", device_uid: "dev-yard"}],
          embeddings_loader: fn _vec, spec ->
            send(test_pid, {:min_score, spec.parsed.min_score})
            {:ok, []}
          end,
          audit_writer: fn audit -> {:ok, audit} end
        }
      ]

      assert {:ok, _} =
               SemanticSearch.search(
                 %{query: "black dog", from_us: 0, to_us: 60_000_000},
                 opts
               )

      assert_received {:min_score, 0.04}

      assert {:ok, _} =
               SemanticSearch.search(
                 %{query: "black dog", min_score: 0.12, from_us: 0, to_us: 60_000_000},
                 opts
               )

      assert_received {:min_score, 0.12}
    end
  end

  test "every worker payload field rejects an invalid value before disposition" do
    envelope = worker_result()
    frame = [:frames, Access.at(0)]
    detection = frame ++ [:detections, Access.at(0)]
    crop = frame ++ [:embeddings, Access.at(0)]
    track = [:tracks, Access.at(0)]

    for {path, value} <- [
          {[:schema], nil},
          {[:schema_version], 1.0},
          {[:job_id], nil},
          {[:catalog_entry_id], <<0::128>>},
          {[:descriptor_sha256], 123},
          {[:detector_model_id], false},
          {[:detector_model_version], "a\0b"},
          {[:embedder_model_id], nil},
          {[:embedder_model_version], 1},
          {[:model_id], false},
          {[:model_version], nil},
          {[:embedding_dim], 512.0},
          {[:frames], %{}},
          {[:tracks], nil},
          {[:tracks, Access.at(0)], false},
          {frame ++ [:fragment_sequence], 4_294_967_296},
          {frame ++ [:media_pts_ns], -1},
          {frame ++ [:scene_suppressed], "false"},
          {frame ++ [:detections], false},
          {frame ++ [:embeddings], false},
          {detection ++ [:object_class], false},
          {detection ++ [:confidence], "0.5"},
          {detection ++ [:bbox], [1.0, 0.0, 0.5, 1.0]},
          {detection ++ [:dominant_colors], [123]},
          {detection ++ [:track_id], -1},
          {crop ++ [:region_kind], :crop},
          {crop ++ [:region_index], 0.5},
          {crop ++ [:object_class], false},
          {crop ++ [:confidence], 1},
          {crop ++ [:bbox], %{}},
          {crop ++ [:dominant_colors], false},
          {crop ++ [:track_id], "1"},
          {crop ++ [:embedding], unit_vec(768)},
          {crop ++ [:embedding, Access.at(0)], 1},
          {track ++ [:track_id], -1},
          {track ++ [:object_class], ""},
          {track ++ [:first_seen_offset_ms], "0"},
          {track ++ [:last_seen_offset_ms], 0.5},
          {track ++ [:dwell_ms], 9_223_372_036_854_775_808},
          {track ++ [:frame_count], -1},
          {track ++ [:peak_confidence], 1.1}
        ] do
      outcome = VisualIndexResultEnvelope.validate(put_in(envelope, path, value))

      assert match?({:error, _}, outcome) or match?({:ok, _, {:error, _}}, outcome),
             "accepted invalid value at #{inspect(path)}"
    end

    assert {:ok, _, {:ok, %{frames: [parsed], tracks: [summary]}}} =
             VisualIndexResultEnvelope.validate(Map.put(envelope, :future_field, %{}))

    assert summary.track_id == 1
    assert [%{region_kind: :crop, embedding: vector}] = parsed.embeddings
    assert Ash.Vector.to_list(vector) == unit_vec(512)

    assert [stored_detection] = parsed.detections

    assert stored_detection |> Map.keys() |> Enum.sort() == [
             "bbox",
             "confidence",
             "dominant_colors",
             "object_class"
           ]

    optional_omitted =
      envelope
      |> Map.drop([:job_id, :tracks])
      |> update_in(detection, &Map.delete(&1, :track_id))

    assert {:ok, %{job_id: nil}, {:ok, %{frames: [parsed_no_track], tracks: []}}} =
             VisualIndexResultEnvelope.validate(optional_omitted)

    assert [no_track_detection] = parsed_no_track.detections
    refute Map.has_key?(no_track_detection, "track_id")

    for {parent, key} <- [
          {[], :schema},
          {[], :schema_version},
          {frame, :scene_suppressed},
          {frame, :detections},
          {frame, :embeddings},
          {detection, :dominant_colors},
          {crop, :region_index},
          {crop, :dominant_colors}
        ] do
      omitted =
        case parent do
          [] -> Map.delete(envelope, key)
          path -> update_in(envelope, path, &Map.delete(&1, key))
        end

      assert {:ok, _, {:error, :invalid_result_envelope}} =
               VisualIndexResultEnvelope.validate(omitted),
             "accepted omitted required field #{inspect(parent ++ [key])}"
    end

    for {parent, canonical, alias_key, alias_value} <- [
          {frame, :fragment_sequence, :fragment_index, 1},
          {frame, :media_pts_ns, :media_offset_ns, 0},
          {detection, :object_class, :class, "parcel"},
          {detection, :object_class, :label, "parcel"},
          {detection, :confidence, :score, 0.75},
          {detection, :bbox, :bbox_norm, [0.0, 0.1, 0.5, 0.9]},
          {crop, :region_kind, :embedding_kind, "crop"},
          {crop, :region_index, :crop_index, 1},
          {crop, :dominant_colors, :attributes, %{dominant_colors: ["blue"]}},
          {crop, :embedding, :vector, unit_vec(512)}
        ] do
      aliased =
        update_in(envelope, parent, fn map ->
          map |> Map.delete(canonical) |> Map.put(alias_key, alias_value)
        end)

      assert {:ok, _, {:error, :invalid_result_envelope}} =
               VisualIndexResultEnvelope.validate(aliased),
             "accepted legacy alias #{inspect(alias_key)} for #{inspect(parent ++ [canonical])}"
    end

    aliased_optional =
      update_in(envelope, crop, fn map ->
        map
        |> Map.drop([:confidence, :bbox])
        |> Map.merge(%{detector_confidence: 0.75, bbox_norm: [0.0, 0.1, 0.5, 0.9]})
      end)

    assert {:ok, _, {:ok, %{frames: [%{embeddings: [parsed_crop]}]}}} =
             VisualIndexResultEnvelope.validate(aliased_optional)

    assert parsed_crop.confidence == nil
    assert parsed_crop.bbox == nil
  end

  test "a bare job ID cannot authorize a terminal job update" do
    message = %Broadway.Message{
      data: Jason.encode!(%{"job_id" => @job_id}),
      acknowledger: Broadway.NoopAcknowledger.init()
    }

    assert {:incomplete, 0, [{^message, %TerminalMessageError{reason: :invalid_result_envelope}}]} =
             CameraVisualIndexResults.process_batch([message])
  end

  # ---------------------------------------------------------------------------
  # Synthetic fixture helpers (zero live/captured values, low-entropy digests)
  # ---------------------------------------------------------------------------

  defp worker_result do
    detection = %{
      object_class: "parcel",
      confidence: 0.75,
      bbox: [0.0, 0.1, 0.5, 0.9],
      dominant_colors: ["blue"],
      track_id: 1
    }

    crop = Map.merge(detection, %{region_kind: "crop", region_index: 1, embedding: unit_vec(512)})

    frame = %{
      fragment_sequence: 1,
      media_pts_ns: 0,
      scene_suppressed: false,
      detections: [detection],
      embeddings: [crop]
    }

    track = %{
      track_id: 1,
      object_class: "parcel",
      first_seen_offset_ms: 0,
      last_seen_offset_ms: 5,
      dwell_ms: 5,
      frame_count: 1,
      peak_confidence: 0.75
    }

    %{
      schema: "media.results.visual_index.v1",
      schema_version: 1,
      job_id: @job_id,
      catalog_entry_id: @catalog_id,
      descriptor_sha256: @desc_sha,
      detector_model_id: "detector",
      detector_model_version: "1",
      embedder_model_id: "embedder",
      embedder_model_version: "1",
      model_id: "embedder",
      model_version: "1",
      embedding_dim: 512,
      frames: [frame],
      tracks: [track]
    }
  end

  defp policy_loaders(entitlement, existing_policies) do
    %{
      source_loader: fn id ->
        {:ok, %{id: id}}
      end,
      profile_loader: fn id ->
        {:ok,
         %{
           id: id,
           camera_source_id: if(id == @prof_b, do: @cam_b, else: @cam_a),
           relay_eligible: true
         }}
      end,
      settings_loader: fn ->
        {:ok, %{archive_enabled: false}}
      end,
      entitlement_loader: fn ->
        {:ok, entitlement}
      end,
      recording_control_loader: fn ->
        {:ok, nil}
      end,
      policies_loader: fn ->
        {:ok, existing_policies}
      end
    }
  end

  defp sample_descriptor do
    %{
      "version" => 1,
      "init" => %{
        "offset" => 0,
        "length" => 1_024,
        "sha256" => @init_sha
      },
      "fragments" => [
        %{
          "sequence" => 0,
          "offset" => 0,
          "length" => 65_536,
          "start_ns" => 0,
          "duration_ns" => 1_000_000_000,
          "keyframe" => true,
          "sha256" => @frag0_sha
        },
        %{
          "sequence" => 1,
          "offset" => 65_536,
          "length" => 65_536,
          "start_ns" => 1_000_000_000,
          "duration_ns" => 1_500_000_000,
          "keyframe" => true,
          "sha256" => @frag1_sha
        },
        %{
          "sequence" => 1_001,
          "offset" => 131_072,
          "length" => 16_384,
          "start_ns" => 2_200_000_000,
          "duration_ns" => 300_000_000,
          "keyframe" => false,
          "sha256" => @frag1_sha
        },
        %{
          "sequence" => 2,
          "offset" => 147_456,
          "length" => 65_536,
          "start_ns" => 2_500_000_000,
          "duration_ns" => 2_000_000_000,
          "keyframe" => true,
          "sha256" => @frag2_sha
        }
      ]
    }
  end

  defp playable_archive_entry do
    %{
      id: @catalog_id,
      recording_block_id: @block_id,
      camera_source_id: @cam_a,
      stream_profile_id: @prof_a,
      storage_id: @storage_id,
      block_key: @block_key,
      descriptor_sha256: @desc_sha,
      local_state: :reclaimed,
      archive_state: :verified,
      archive_binding_id: @binding_id,
      quarantine_reason: nil,
      timeline_start_us: 1_700_000_000_000_000,
      timeline_end_us: 1_700_000_010_000_000,
      media_start_ns: 0,
      media_end_ns: 4_500_000_000,
      time_basis: :received
    }
  end

  defp grant_loaders(entry, secret_key \\ "test-reader-secret-key-0000000000") do
    sampled = VisualIndexDispatcher.sample_descriptor_fragments(sample_descriptor(), 2_000, 64)

    %{
      job_loader: fn id ->
        if id == @job_id do
          {:ok,
           %{
             id: @job_id,
             catalog_entry_id: @catalog_id,
             camera_source_id: @cam_a,
             stream_profile_id: @prof_a,
             state: :dispatched,
             descriptor_sha256: @desc_sha,
             sampled_fragments: sampled
           }}
        else
          {:ok, nil}
        end
      end,
      entry_loader: fn _id ->
        {:ok, entry}
      end,
      block_loader: fn _id ->
        {:ok,
         %{
           id: @block_id,
           descriptor: sample_descriptor(),
           descriptor_sha256: @desc_sha
         }}
      end,
      binding_loader: fn _id ->
        {:ok,
         %{
           id: @binding_id,
           schema_version: 2,
           provisioning_ref: "operator:primary",
           generation: 1,
           purpose: "recording",
           provider: "s3_compatible",
           endpoint: "https://objects.example.com",
           region: "us-east-1",
           bucket: "synthetic-archive",
           namespace: "nvr/archive-v2",
           addressing_style: :path,
           archive_format_version: 1,
           required_encryption: "sse_s3_aes256",
           destination_sha256: nil
         }}
      end,
      receipt_loader: fn _entry ->
        {:ok,
         %{
           recording_block_id: @block_id,
           archive_binding_id: @binding_id,
           objects: [
             %{
               "name" => "init.mp4",
               "key" => "nvr/archive-v2/#{@storage_id}/#{@block_key}/init.mp4",
               "length" => 1_024,
               "sha256" => @init_sha,
               "etag" => "\"etag-init\"",
               "version_id" => "synth-init-v1"
             },
             %{
               "name" => "media.m4s",
               "key" => "nvr/archive-v2/#{@storage_id}/#{@block_key}/media.m4s",
               "length" => 212_992,
               "sha256" => @media_sha,
               "etag" => "\"etag-media\"",
               "version_id" => "synth-media-v1"
             }
           ]
         }}
      end,
      credential_resolver: fn binding, role, ttl ->
        assert role == :reader

        {:ok, grant_attrs} =
          ArchiveCredentialResolver.grant_attrs(
            binding,
            :reader,
            @secret_id,
            ttl_seconds: ttl
          )

        {:ok,
         %{
           grant: grant_attrs,
           credential: %{
             "secret_id" => @secret_id,
             "generation" => 1,
             "access_key_id" => "test-reader-access-key",
             "secret_access_key" => secret_key
           }
         }}
      end,
      policy_loader: fn _entry ->
        {:ok, %{nvr_member: "nvr-0"}}
      end
    }
  end

  defp unit_vec(dim) do
    [1.0 | List.duplicate(0.0, dim - 1)]
  end

  describe "SemanticSearch Vantage observation fusion & embedder fallback" do
    test "fuses plate_text attribute & FTS observation hits independently and preserves audit when embedder is unavailable" do
      obs_1 = "00000000-0000-7000-8000-000000000951"
      obs_2 = "00000000-0000-7000-8000-000000000952"

      caller = %{
        user: %{id: "investigator-alpr"},
        permissions: MapSet.new(["devices.view", "devices.cameras.recordings.view"])
      }

      parent = self()

      obs_hit_1 = %{
        id: obs_1,
        catalog_entry_id: @catalog_id,
        camera_source_id: @cam_a,
        stream_profile_id: @prof_a,
        timeline_ts_us: 1_700_000_012_000_000,
        time_basis: "received",
        category: "license_plate",
        label: "SR-0100",
        confidence: 0.94,
        bbox: [0.32, 0.58, 0.48, 0.66],
        attributes: %{"plate_text" => "SR-0100", "region" => "US-CO"},
        signal_schema_id: "alpr_plate_read",
        display_contract_id: "alpr_plate_read",
        pipeline_id: "io.serviceradar.vantage-alpr.vehicle-plate",
        pipeline_version: "1.0.0",
        track_id: "track-1",
        has_crop: true,
        catalog_start_us: 1_700_000_000_000_000,
        catalog_end_us: 1_700_000_060_000_000,
        text_rank: 0.9,
        match_sources: ["observation_attribute", "observation_fts"]
      }

      obs_hit_2 = %{
        obs_hit_1
        | id: obs_2,
          timeline_ts_us: 1_700_000_045_000_000,
          label: "TEST-742",
          attributes: %{"plate_text" => "TEST-742", "region" => "US-CO"},
          text_rank: 0.4
      }

      assert {:ok, resp} =
               SemanticSearch.search(
                 %{
                   query: "plate_text:SR-0100",
                   from_us: 1_700_000_000_000_000,
                   to_us: 1_700_000_120_000_000
                 },
                 scope: caller,
                 now: ~U[2026-11-24 00:01:00Z],
                 bypass_cache: true,
                 text_embedder: fn _q, _ctx -> {:error, :search_embedder_unavailable} end,
                 loaders: %{
                   sources: [%{id: @cam_a, display_name: "Gate West 01", device_uid: "dev-gw01"}],
                   observations_loader: fn _q, ctx ->
                     assert ctx.attribute_filters == [{"plate_text", "SR-0100"}]
                     assert ctx.free_text == ""
                     assert ctx.camera_source_ids == [@cam_a]
                     {:ok, [obs_hit_1, obs_hit_2]}
                   end,
                   audit_writer: fn audit ->
                     send(parent, {:audit_recorded, audit})
                     {:ok, audit}
                   end
                 }
               )

      assert [first, second] = resp.results
      assert first.vantage_observation_id == obs_1
      assert first.best_timeline_ts_us == 1_700_000_012_000_000
      assert first.observation_label == "SR-0100"
      assert first.has_crop == true
      assert second.vantage_observation_id == obs_2
      assert second.best_timeline_ts_us == 1_700_000_045_000_000

      assert_receive {:audit_recorded, audit}
      assert audit.event_kind == :semantic_search
      assert audit.details["observation_result_count"] == 2
    end

    test "still fails closed with :search_embedder_unavailable when no observations match" do
      caller = %{
        user: %{id: "investigator-alpr"},
        permissions: MapSet.new(["devices.view", "devices.cameras.recordings.view"])
      }

      assert {:error, :search_embedder_unavailable} =
               SemanticSearch.search(
                 %{
                   query: "SR-0100",
                   from_us: 1_700_000_000_000_000,
                   to_us: 1_700_000_120_000_000
                 },
                 scope: caller,
                 now: ~U[2026-11-24 00:01:00Z],
                 bypass_cache: true,
                 text_embedder: fn _q, _ctx -> {:error, :search_embedder_unavailable} end,
                 loaders: %{
                   sources: [%{id: @cam_a, display_name: "Gate West 01", device_uid: "dev-gw01"}],
                   observations_loader: fn _q, _ctx -> {:ok, []} end,
                   skip_db_audit: true
                 }
               )
    end
  end
end
