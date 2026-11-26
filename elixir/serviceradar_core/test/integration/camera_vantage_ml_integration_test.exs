defmodule ServiceRadar.Camera.CameraVantageMLIntegrationTest do
  use ServiceRadar.DataCase, async: false

  alias Ash.Error.Forbidden
  alias Broadway.Message
  alias Ecto.Adapters.SQL
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Camera.CameraRecordingPolicies
  alias ServiceRadar.Camera.IngestOwner
  alias ServiceRadar.Camera.RecorderClaim
  alias ServiceRadar.Camera.RecorderOwnership
  alias ServiceRadar.Camera.RecordingArchiveSettings
  alias ServiceRadar.Camera.RecordingBlock
  alias ServiceRadar.Camera.RecordingBlocks
  alias ServiceRadar.Camera.RecordingCatalogEntry
  alias ServiceRadar.Camera.RecordingHolds
  alias ServiceRadar.Camera.RelaySessionLifecycle
  alias ServiceRadar.Camera.RelaySessionManager
  alias ServiceRadar.Camera.Source
  alias ServiceRadar.Camera.StreamProfile
  alias ServiceRadar.Camera.VantageJob
  alias ServiceRadar.Camera.VantageObservation
  alias ServiceRadar.Camera.VantageObservationProjector
  alias ServiceRadar.Camera.VantagePipeline
  alias ServiceRadar.Camera.VantagePipelineDispatcher
  alias ServiceRadar.Camera.VantageWorkerHeartbeat
  alias ServiceRadar.Camera.VantageWorkerRegistration
  alias ServiceRadar.Camera.VisualIndexJob
  alias ServiceRadar.Camera.VisualIndexResultProjector
  alias ServiceRadar.Dashboards.DashboardInstance
  alias ServiceRadar.Dashboards.DashboardPackage
  alias ServiceRadar.EventWriter.Processors.CameraVantageObservations
  alias ServiceRadar.EventWriter.TerminalMessageError
  alias ServiceRadar.Repo
  alias ServiceRadar.Test.CameraRelayFixtures, as: Fixtures
  alias ServiceRadar.TestSupport
  alias ServiceRadarRecordingMetadata.Descriptor

  require Ash.Query

  @moduletag :integration
  @moduletag :tmp_dir

  @clock %{
    "clock_epoch" => "synthetic-vantage-clock",
    "timebase" => 90_000,
    "dts_source" => "pts_no_reordering",
    "utc_mapping" => "unknown"
  }

  @valid_jfif <<0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, "JFIF", 0x00, 0x01, 0x01, 0x00, 0x00, 0x01,
                0x00, 0x01, 0x00, 0x00, 0xFF, 0xC0, 0x00, 0x0B, 0x08, 0x00, 0x10, 0x00, 0x10,
                0x01, 0x01, 0x11, 0x00, 0xFF, 0xDA, 0x00, 0x08, 0x01, 0x01, 0x00, 0x00, 0x3F,
                0x00, 0xFF, 0xD9>>

  @alpr_schema %{
    "type" => "object",
    "required" => ["plate_text", "region"],
    "properties" => %{
      "plate_text" => %{"type" => "string", "pattern" => "^[A-Z0-9-]{2,12}$"},
      "region" => %{"type" => "string", "minLength" => 2}
    },
    "additionalProperties" => true
  }

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    prior_flag = System.get_env("SERVICERADAR_VANTAGE_PIPELINES_ENABLED")
    System.put_env("SERVICERADAR_VANTAGE_PIPELINES_ENABLED", "true")

    on_exit(fn ->
      case prior_flag do
        nil -> System.delete_env("SERVICERADAR_VANTAGE_PIPELINES_ENABLED")
        val -> System.put_env("SERVICERADAR_VANTAGE_PIPELINES_ENABLED", val)
      end
    end)

    :ok
  end

  test "Stage 1 projection admits VantageJob, EventWriter projects idempotently with search_tsv & OCSF, and schema violations fail job",
       %{tmp_dir: tmp_dir} do
    _gate = Fixtures.recording_recovery_gate(tmp_dir)
    actor = SystemActor.system(:vantage_integration_test)
    {cam, prof} = create_camera_and_profile(actor, "Gate West 01")

    {:ok, pipeline} =
      VantagePipeline
      |> Ash.Changeset.for_create(
        :upsert,
        %{
          pipeline_id: "io.serviceradar.vantage-alpr.vehicle-plate",
          version: "1.0.0",
          name: "Synthetic ALPR Vehicle Plate",
          enabled: true,
          source_mode: :recorded_block,
          trigger_kind: :on_stage1_detection,
          camera_selector: %{
            "mode" => "camera_source_ids",
            "camera_source_ids" => [to_string(cam.id)]
          },
          object_classes: ["vehicle"],
          min_confidence: 0.55,
          input_mode: :detection_crop,
          signal_schema_id: "alpr_plate_read",
          signal_schema_version: "1.0.0",
          signal_schema: @alpr_schema,
          display_contract_id: "alpr_plate_read",
          emit_ocsf_events: true,
          pack_id: "io.serviceradar.vantage-alpr",
          pack_version: "1.0.0",
          managed: true
        },
        actor: actor
      )
      |> Ash.create(actor: actor)

    entry = create_indexed_playable_entry(cam, prof, 1_760_000_000_000_000, actor)

    [vi_job] =
      VisualIndexJob
      |> Ash.Query.filter(catalog_entry_id == ^entry.id)
      |> Ash.read!(actor: actor)

    vi_envelope = %{
      "schema" => "media.results.visual_index.v1",
      "schema_version" => 1,
      "job_id" => to_string(vi_job.id),
      "catalog_entry_id" => to_string(entry.id),
      "descriptor_sha256" => entry.descriptor_sha256,
      "detector_model_id" => "yolox-s",
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
              "object_class" => "vehicle",
              "confidence" => 0.87,
              "bbox" => [0.3, 0.45, 0.55, 0.8],
              "dominant_colors" => ["silver"],
              "track_id" => 1
            }
          ],
          "embeddings" => []
        }
      ]
    }

    assert {:ok, _} = VisualIndexResultProjector.ingest_result(vi_envelope)

    [v_job] =
      VantageJob
      |> Ash.Query.filter(catalog_entry_id == ^entry.id and pipeline_id == ^pipeline.pipeline_id)
      |> Ash.read!(actor: actor)

    assert v_job.target_key == "track:1"
    assert v_job.state == :pending

    valid_vantage = %{
      "schema_version" => "vantage.result.v1",
      "source_mode" => "recorded_block",
      "job_id" => to_string(v_job.id),
      "catalog_entry_id" => to_string(entry.id),
      "descriptor_sha256" => entry.descriptor_sha256,
      "camera_source_id" => to_string(cam.id),
      "stream_profile_id" => to_string(prof.id),
      "pack_id" => "io.serviceradar.vantage-alpr",
      "pipeline_id" => pipeline.pipeline_id,
      "pipeline_version" => pipeline.version,
      "worker_kind" => "camera_vlm",
      "worker_id" => "media-worker-01",
      "model_id" => "qwen3.5-4b",
      "model_version" => "2026.1",
      "capability" => "vantage.alpr.v1",
      "observations" => [
        %{
          "observation_key" => "obs:#{entry.id}:track-1",
          "fragment_sequence" => 0,
          "frame_sequence" => 0,
          "media_pts_ns" => 0,
          "timeline_ts_us" => entry.timeline_start_us,
          "time_basis" => "received",
          "track_id" => "1",
          "category" => "license_plate",
          "label" => "SR-0100",
          "confidence" => 0.94,
          "bbox" => [0.32, 0.58, 0.48, 0.66],
          "crop_jpeg_b64" => Base.encode64(@valid_jfif),
          "attributes" => %{"plate_text" => "SR-0100", "region" => "US-CO"},
          "signal_schema_id" => "alpr_plate_read",
          "signal_schema_version" => "1.0.0",
          "display_contract_id" => "alpr_plate_read"
        }
      ]
    }

    parent = self()

    ocsf_opts = [
      publish: fn subject, body, opts ->
        send(parent, {:ocsf_published, subject, Jason.decode!(body), opts})
        :ok
      end,
      suppress?: fn _ -> false end
    ]

    assert {:ok, %{observation_count: 1}} =
             VantageObservationProjector.ingest_result(Jason.encode!(valid_vantage),
               ocsf_opts: ocsf_opts
             )

    assert_received {:ocsf_published, "events.internal.camera", ocsf_event, _}
    assert ocsf_event["class_uid"] == 1008

    assert ocsf_event["metadata"]["service_radar"]["signal_schema"]["schema_id"] ==
             "alpr_plate_read"

    # Idempotent replay via EventWriter processor acknowledges without duplicating rows
    msg = %Message{
      data: Jason.encode!(valid_vantage),
      metadata: %{subject: "media.results.vantage.v1"},
      acknowledger: Broadway.NoopAcknowledger.init()
    }

    assert {:ok, 0} = CameraVantageObservations.process_batch([msg])

    assert %{rows: [[1]]} =
             SQL.query!(
               Repo,
               "SELECT count(*) FROM platform.camera_vantage_observations WHERE catalog_entry_id = $1 AND search_tsv @@ plainto_tsquery('english', 'SR-0100')",
               [Ecto.UUID.dump!(entry.id)]
             )

    completed_job = VantageJob.get_by_id!(v_job.id, actor: actor)
    assert completed_job.state == :completed

    # Check DB crop_jpeg <= 32768 constraint (camera_vantage_observations_crop_jpeg_size)
    oversized_crop =
      binary_part(@valid_jfif, 0, byte_size(@valid_jfif) - 2) <>
        :binary.copy(<<0x00>>, 32_769 - byte_size(@valid_jfif)) <> <<0xFF, 0xD9>>

    assert byte_size(oversized_crop) == 32_769

    assert {:error,
            %Postgrex.Error{
              postgres: %{
                code: :check_violation,
                constraint: "camera_vantage_observations_crop_jpeg_size"
              }
            }} =
             Repo.transaction(fn ->
               case SQL.query(
                      Repo,
                      "UPDATE platform.camera_vantage_observations SET crop_jpeg = $1 WHERE catalog_entry_id = $2",
                      [oversized_crop, Ecto.UUID.dump!(entry.id)]
                    ) do
                 {:error, err} -> Repo.rollback(err)
                 {:ok, res} -> res
               end
             end)

    # Check schema violation and nested JSON out_of_range failing active jobs cleanly
    {:ok, bad_job} =
      VantageJob
      |> Ash.Changeset.for_create(
        :enqueue,
        %{
          vantage_pipeline_id: pipeline.id,
          pipeline_id: pipeline.pipeline_id,
          pipeline_version: pipeline.version,
          catalog_entry_id: entry.id,
          camera_source_id: cam.id,
          stream_profile_id: prof.id,
          target_key: "track:bad-schema",
          target_runner: "camera_vlm",
          subject: "media.jobs.vantage.vlm.v1",
          descriptor_sha256: entry.descriptor_sha256
        },
        actor: actor
      )
      |> Ash.create(actor: actor)

    invalid_payload =
      valid_vantage
      |> Map.put("job_id", to_string(bad_job.id))
      |> put_in(["observations", Access.at(0), "observation_key"], "obs:#{entry.id}:bad-schema")
      |> put_in(["observations", Access.at(0), "attributes", "plate_text"], "bad plate!")

    bad_msg = %Message{
      data: Jason.encode!(invalid_payload),
      metadata: %{subject: "media.results.vantage.v1"},
      acknowledger: Broadway.NoopAcknowledger.init()
    }

    assert {:incomplete, 0, [{^bad_msg, %TerminalMessageError{reason: :signal_schema_violation}}]} =
             CameraVantageObservations.process_batch([bad_msg])

    failed_job = VantageJob.get_by_id!(bad_job.id, actor: actor)
    assert failed_job.state == :failed_terminal
    assert failed_job.last_error_class == "signal_schema_violation"

    {:ok, oor_job} =
      VantageJob
      |> Ash.Changeset.for_create(
        :enqueue,
        %{
          vantage_pipeline_id: pipeline.id,
          pipeline_id: pipeline.pipeline_id,
          pipeline_version: pipeline.version,
          catalog_entry_id: entry.id,
          camera_source_id: cam.id,
          stream_profile_id: prof.id,
          target_key: "track:oor-nested",
          target_runner: "camera_vlm",
          subject: "media.jobs.vantage.vlm.v1",
          descriptor_sha256: entry.descriptor_sha256
        },
        actor: actor
      )
      |> Ash.create(actor: actor)

    oor_json =
      valid_vantage
      |> Map.put("job_id", to_string(oor_job.id))
      |> put_in(["observations", Access.at(0), "observation_key"], "obs:#{entry.id}:oor-nested")
      |> put_in(["observations", Access.at(0), "attributes"], %{
        "nested" => %{"big" => "__OOR_FLOAT__"}
      })
      |> Jason.encode!()
      |> String.replace("\"__OOR_FLOAT__\"", "1e99999")

    oor_msg = %Message{
      data: oor_json,
      metadata: %{subject: "media.results.vantage.v1"},
      acknowledger: Broadway.NoopAcknowledger.init()
    }

    assert {:incomplete, 0, [{^oor_msg, %TerminalMessageError{reason: :invalid_result_envelope}}]} =
             CameraVantageObservations.process_batch([oor_msg])

    assert %{state: :failed_terminal, last_error_class: "invalid_result_envelope"} =
             VantageJob.get_by_id!(oor_job.id, actor: actor)
  end

  test "quarantine and terminal deletion purge VantageObservations and cancel pending jobs while RecordingHold preserves them",
       %{tmp_dir: tmp_dir} do
    _gate = Fixtures.recording_recovery_gate(tmp_dir)
    actor = SystemActor.system(:vantage_lifecycle_test)
    {cam, prof} = create_camera_and_profile(actor, "Gate West 01 Lifecycle")

    {:ok, _pipeline} =
      VantagePipeline
      |> Ash.Changeset.for_create(
        :upsert,
        %{
          pipeline_id: "io.serviceradar.vantage-alpr.vehicle-plate",
          version: "1.0.1",
          name: "Synthetic ALPR Lifecycle",
          enabled: true,
          source_mode: :recorded_block,
          trigger_kind: :on_sealed_block,
          signal_schema_id: "alpr_plate_read",
          signal_schema_version: "1.0.0",
          signal_schema: @alpr_schema,
          display_contract_id: "alpr_plate_read"
        },
        actor: actor
      )
      |> Ash.create(actor: actor)

    entry = create_indexed_playable_entry(cam, prof, 1_760_000_100_000_000, actor)

    [v_job] =
      VantageJob
      |> Ash.Query.filter(catalog_entry_id == ^entry.id)
      |> Ash.read!(actor: actor)

    {:ok, obs} =
      VantageObservation
      |> Ash.Changeset.for_create(
        :upsert_observation,
        %{
          observation_key: "obs:lifecycle:#{entry.id}",
          pipeline_id: "io.serviceradar.vantage-alpr.vehicle-plate",
          pipeline_version: "1.0.1",
          worker_kind: "camera_vlm",
          model_id: "qwen3.5-4b",
          model_version: "2026.1",
          job_id: v_job.id,
          catalog_entry_id: entry.id,
          camera_source_id: cam.id,
          stream_profile_id: prof.id,
          source_mode: :recorded_block,
          fragment_sequence: 0,
          media_pts_ns: 0,
          timeline_ts_us: entry.timeline_start_us,
          time_basis: :received,
          category: "license_plate",
          label: "TEST-742",
          confidence: 0.91,
          attributes: %{"plate_text" => "TEST-742", "region" => "US-CO"},
          signal_schema_id: "alpr_plate_read",
          signal_schema_version: "1.0.0",
          display_contract_id: "alpr_plate_read",
          search_text: "TEST-742 US-CO"
        },
        actor: actor
      )
      |> Ash.create(actor: actor)

    hold_actor = %{
      id: "hold-operator",
      role: :operator,
      permissions: MapSet.new(["devices.view", "devices.cameras.recordings.hold"])
    }

    assert {:ok, %{hold: hold}} =
             RecordingHolds.place_hold(
               %{
                 camera_source_id: cam.id,
                 stream_profile_id: prof.id,
                 start_us: entry.timeline_start_us,
                 end_us: entry.timeline_end_us,
                 reason: "Synthetic ALPR incident hold"
               },
               actor: hold_actor
             )

    # Active RecordingHold blocks local copy deletion intent, preserving the observation
    admin_actor = %{
      id: "admin-retention",
      role: :admin,
      permissions: MapSet.new(["settings.recording.manage"])
    }

    assert {:error, _} =
             RecordingHolds.begin_copy_deletion_intent(
               entry.id,
               :local,
               :local_retention,
               actor: admin_actor
             )

    assert {:ok, %VantageObservation{}} = VantageObservation.get_by_id(obs.id, actor: actor)

    # Release hold and transition catalog entry to reclaimed + not_required -> purge trigger fires
    assert {:ok, _released} =
             RecordingHolds.release_hold(hold.id, "Synthetic hold complete", actor: hold_actor)

    {:ok, pending_job} =
      VantageJob
      |> Ash.Changeset.for_create(
        :enqueue,
        %{
          pipeline_id: "io.serviceradar.vantage-alpr.vehicle-plate",
          pipeline_version: "1.0.1",
          catalog_entry_id: entry.id,
          camera_source_id: cam.id,
          stream_profile_id: prof.id,
          target_key: "track:pending-purge",
          target_runner: "camera_vlm",
          subject: "media.jobs.vantage.vlm.v1",
          descriptor_sha256: entry.descriptor_sha256
        },
        actor: actor
      )
      |> Ash.create(actor: actor)

    SQL.query!(
      Repo,
      "UPDATE platform.camera_recording_catalog SET local_state = 'reclaimed', archive_state = 'not_required' WHERE id = $1",
      [Ecto.UUID.dump!(entry.id)]
    )

    assert {:ok, nil} =
             VantageObservation.get_by_id(obs.id, actor: actor, not_found_error?: false)

    cancelled = VantageJob.get_by_id!(pending_job.id, actor: actor)
    assert cancelled.state == :cancelled

    # Live-tap observation (catalog_entry_id: nil) is unaffected by catalog purge trigger
    {:ok, live_obs} =
      VantageObservation
      |> Ash.Changeset.for_create(
        :upsert_observation,
        %{
          observation_key: "obs:live-tap:#{cam.id}",
          pipeline_id: "io.serviceradar.vantage-alpr.vehicle-plate",
          pipeline_version: "1.0.1",
          worker_kind: "external_rust",
          model_id: "bay-align-onnx",
          model_version: "1.0.0",
          camera_source_id: cam.id,
          stream_profile_id: prof.id,
          source_mode: :live_keyframe_tap,
          frame_sequence: 1,
          timeline_ts_us: entry.timeline_start_us + 500,
          time_basis: :received,
          category: "license_plate",
          label: "SR-0100",
          confidence: 0.93,
          attributes: %{"plate_text" => "SR-0100", "region" => "US-CO"},
          signal_schema_id: "alpr_plate_read",
          signal_schema_version: "1.0.0",
          display_contract_id: "alpr_plate_read",
          search_text: "SR-0100"
        },
        actor: actor
      )
      |> Ash.create(actor: actor)

    # Quarantine transition (local_state = 'quarantined') immediately purges observations & cancels pending jobs
    entry_quarantine = create_indexed_playable_entry(cam, prof, 1_760_000_200_000_000, actor)

    {:ok, q_obs} =
      VantageObservation
      |> Ash.Changeset.for_create(
        :upsert_observation,
        %{
          observation_key: "obs:quarantine:#{entry_quarantine.id}",
          pipeline_id: "io.serviceradar.vantage-alpr.vehicle-plate",
          pipeline_version: "1.0.1",
          worker_kind: "camera_vlm",
          model_id: "qwen3.5-4b",
          model_version: "2026.1",
          catalog_entry_id: entry_quarantine.id,
          camera_source_id: cam.id,
          stream_profile_id: prof.id,
          source_mode: :recorded_block,
          fragment_sequence: 0,
          media_pts_ns: 0,
          timeline_ts_us: entry_quarantine.timeline_start_us,
          time_basis: :received,
          category: "license_plate",
          label: "TEST-742",
          confidence: 0.9,
          attributes: %{"plate_text" => "TEST-742", "region" => "US-CO"},
          signal_schema_id: "alpr_plate_read",
          signal_schema_version: "1.0.0",
          display_contract_id: "alpr_plate_read",
          search_text: "TEST-742"
        },
        actor: actor
      )
      |> Ash.create(actor: actor)

    {:ok, q_job} =
      VantageJob
      |> Ash.Changeset.for_create(
        :enqueue,
        %{
          pipeline_id: "io.serviceradar.vantage-alpr.vehicle-plate",
          pipeline_version: "1.0.1",
          catalog_entry_id: entry_quarantine.id,
          camera_source_id: cam.id,
          stream_profile_id: prof.id,
          target_key: "track:quarantine-purge",
          target_runner: "camera_vlm",
          subject: "media.jobs.vantage.vlm.v1",
          descriptor_sha256: entry_quarantine.descriptor_sha256
        },
        actor: actor
      )
      |> Ash.create(actor: actor)

    SQL.query!(
      Repo,
      "UPDATE platform.camera_recording_catalog SET local_state = 'quarantined', quarantine_reason = 'unattributable' WHERE id = $1",
      [Ecto.UUID.dump!(entry_quarantine.id)]
    )

    assert {:ok, nil} =
             VantageObservation.get_by_id(q_obs.id, actor: actor, not_found_error?: false)

    assert %{state: :cancelled, last_error_class: "source_deleted_or_quarantined"} =
             VantageJob.get_by_id!(q_job.id, actor: actor)

    # ON DELETE CASCADE on RecordingCatalogEntry deletion removes linked observations and jobs
    entry_cascade = create_indexed_playable_entry(cam, prof, 1_760_000_300_000_000, actor)

    {:ok, c_obs} =
      VantageObservation
      |> Ash.Changeset.for_create(
        :upsert_observation,
        %{
          observation_key: "obs:cascade:#{entry_cascade.id}",
          pipeline_id: "io.serviceradar.vantage-alpr.vehicle-plate",
          pipeline_version: "1.0.1",
          worker_kind: "camera_vlm",
          model_id: "qwen3.5-4b",
          model_version: "2026.1",
          catalog_entry_id: entry_cascade.id,
          camera_source_id: cam.id,
          stream_profile_id: prof.id,
          source_mode: :recorded_block,
          fragment_sequence: 0,
          media_pts_ns: 0,
          timeline_ts_us: entry_cascade.timeline_start_us,
          time_basis: :received,
          category: "license_plate",
          label: "SR-0100",
          confidence: 0.9,
          attributes: %{"plate_text" => "SR-0100", "region" => "US-CO"},
          signal_schema_id: "alpr_plate_read",
          signal_schema_version: "1.0.0",
          display_contract_id: "alpr_plate_read",
          search_text: "SR-0100"
        },
        actor: actor
      )
      |> Ash.create(actor: actor)

    {:ok, c_job} =
      VantageJob
      |> Ash.Changeset.for_create(
        :enqueue,
        %{
          pipeline_id: "io.serviceradar.vantage-alpr.vehicle-plate",
          pipeline_version: "1.0.1",
          catalog_entry_id: entry_cascade.id,
          camera_source_id: cam.id,
          stream_profile_id: prof.id,
          target_key: "track:cascade-delete",
          target_runner: "camera_vlm",
          subject: "media.jobs.vantage.vlm.v1",
          descriptor_sha256: entry_cascade.descriptor_sha256
        },
        actor: actor
      )
      |> Ash.create(actor: actor)

    SQL.query!(
      Repo,
      "DELETE FROM platform.camera_recording_catalog WHERE id = $1",
      [Ecto.UUID.dump!(entry_cascade.id)]
    )

    assert {:ok, nil} =
             VantageObservation.get_by_id(c_obs.id, actor: actor, not_found_error?: false)

    assert {:ok, nil} = VantageJob.get_by_id(c_job.id, actor: actor, not_found_error?: false)

    assert {:ok, %VantageObservation{}} =
             VantageObservation.get_by_id(live_obs.id, actor: actor)
  end

  test "DashboardPackage/DashboardInstance provenance columns and dashboards.packages.manage policy persist cleanly" do
    system_actor = SystemActor.system(:vantage_dashboard_test)

    manager_actor = %{
      id: "pkg-manager",
      role: :operator,
      permissions: MapSet.new(["dashboards.packages.manage", "dashboards.packages.view_all"])
    }

    {:ok, pkg} =
      DashboardPackage
      |> Ash.Changeset.for_create(
        :create,
        %{
          dashboard_id: "io.serviceradar.vantage-alpr.console",
          name: "ALPR Console",
          version: "1.0.0",
          manifest: %{
            "schema_version" => 1,
            "dashboard_id" => "io.serviceradar.vantage-alpr.console",
            "name" => "ALPR Console",
            "version" => "1.0.0",
            "entry" => "renderer.js"
          },
          renderer: %{"type" => "browser_module", "entry" => "renderer.js"},
          content_hash: String.duplicate("c", 64),
          pack_id: "io.serviceradar.vantage-alpr",
          pack_version: "1.0.0",
          managed: true,
          template_fingerprint: String.duplicate("d", 64)
        },
        actor: system_actor
      )
      |> Ash.create(actor: system_actor)

    assert pkg.pack_id == "io.serviceradar.vantage-alpr"
    assert pkg.managed == true

    assert {:ok, instance} =
             DashboardInstance
             |> Ash.Changeset.for_create(
               :create,
               %{
                 dashboard_package_id: pkg.id,
                 name: "ALPR Console Instance",
                 route_slug: "alpr-console-synthetic-#{System.unique_integer([:positive])}",
                 enabled: true,
                 pack_id: "io.serviceradar.vantage-alpr",
                 pack_version: "1.0.0",
                 managed: true,
                 template_fingerprint: String.duplicate("d", 64)
               },
               actor: manager_actor
             )
             |> Ash.create(actor: manager_actor)

    assert instance.pack_id == "io.serviceradar.vantage-alpr"
    assert instance.managed == true

    # Negative RBAC checks: actor lacking dashboards.packages.manage/publish/enable is denied
    viewer_actor = %{
      id: "pkg-viewer-only",
      role: :viewer,
      permissions: MapSet.new(["dashboards.packages.view_all", "devices.view"])
    }

    assert {:error, %Forbidden{}} =
             DashboardInstance
             |> Ash.Changeset.for_create(
               :create,
               %{
                 dashboard_package_id: pkg.id,
                 name: "Unauthorized Instance",
                 route_slug: "alpr-console-unauth-#{System.unique_integer([:positive])}",
                 enabled: true
               },
               actor: viewer_actor
             )
             |> Ash.create(actor: viewer_actor)

    # Negative RBAC checks on VantagePipeline & VantageObservation
    assert {:error, %Forbidden{}} = Ash.read(VantagePipeline, actor: viewer_actor)
    assert {:error, %Forbidden{}} = Ash.read(VantageObservation, actor: viewer_actor)

    assert {:error, %Forbidden{}} =
             VantagePipeline
             |> Ash.Changeset.for_create(
               :create,
               %{
                 pipeline_id: "io.serviceradar.vantage-alpr.unauth",
                 version: "1.0.0",
                 name: "Unauthorized Pipeline",
                 signal_schema_id: "alpr_plate_read",
                 signal_schema_version: "1.0.0",
                 display_contract_id: "alpr_plate_read"
               },
               actor: viewer_actor
             )
             |> Ash.create(actor: viewer_actor)

    footage_viewer = %{
      id: "footage-viewer",
      role: :operator,
      permissions: MapSet.new(["devices.view", "devices.cameras.recordings.view"])
    }

    assert {:ok, _} = Ash.read(VantagePipeline, actor: footage_viewer)
    assert {:ok, _} = Ash.read(VantageObservation, actor: footage_viewer)

    assert {:error, %Forbidden{}} =
             VantagePipeline
             |> Ash.Changeset.for_create(
               :create,
               %{
                 pipeline_id: "io.serviceradar.vantage-alpr.unauth-write",
                 version: "1.0.0",
                 name: "Unauthorized Write Pipeline",
                 signal_schema_id: "alpr_plate_read",
                 signal_schema_version: "1.0.0",
                 display_contract_id: "alpr_plate_read"
               },
               actor: footage_viewer
             )
             |> Ash.create(actor: footage_viewer)

    assert {:error, %Forbidden{}} =
             VantageObservation
             |> Ash.Changeset.for_create(
               :upsert_observation,
               %{
                 observation_key: "obs:unauth:#{System.unique_integer([:positive])}",
                 pipeline_id: "io.serviceradar.vantage-alpr.vehicle-plate",
                 pipeline_version: "1.0.0",
                 worker_kind: "camera_vlm",
                 model_id: "qwen3.5-4b",
                 model_version: "2026.1",
                 camera_source_id: Ecto.UUID.generate(),
                 stream_profile_id: Ecto.UUID.generate(),
                 source_mode: :live_keyframe_tap,
                 timeline_ts_us: 1_760_000_000_000_000,
                 time_basis: :received,
                 category: "license_plate",
                 label: "SR-0100",
                 confidence: 0.9,
                 signal_schema_id: "alpr_plate_read",
                 signal_schema_version: "1.0.0",
                 display_contract_id: "alpr_plate_read"
               },
               actor: footage_viewer
             )
             |> Ash.create(actor: footage_viewer)
  end

  test "VantageWorkerRegistration persists heartbeats and queries active_for_capability" do
    actor = SystemActor.system(:vantage_worker_reg_test)
    now = DateTime.utc_now()

    assert {:ok, reg} =
             VantageWorkerRegistration
             |> Ash.Changeset.for_create(
               :upsert_heartbeat,
               %{
                 worker_id: "vantage-worker-alpr-01",
                 worker_kind: :external_rust,
                 protocol_version: "vantage.worker.v1",
                 capabilities: ["vantage.alpr.v1"],
                 supported_source_modes: ["recorded_block", "live_keyframe_tap"],
                 execution_backend: "onnx",
                 architecture: "arm64",
                 model_id: "fast-alpr-onnx",
                 model_version: "1.0.0",
                 max_concurrency: 4,
                 active_jobs: 1,
                 health: :ready,
                 last_heartbeat_at: now,
                 expires_at: DateTime.shift(now, second: 30)
               },
               actor: actor
             )
             |> Ash.create(actor: actor)

    assert {:ok, [found]} =
             VantageWorkerRegistration.active_for_capability("vantage.alpr.v1", now, actor: actor)

    assert found.id == reg.id
  end

  test "VantagePipelineDispatcher CNPG relay performs Ramp 1 <-> Ramp 2 routing, HOLD upgrade, and stale recovery",
       %{
         tmp_dir: dir
       } do
    Fixtures.recording_recovery_gate(dir)
    actor = SystemActor.system(:vantage_dispatch_db_test)
    {cam, prof} = create_camera_and_profile(actor, "Gate West 01")
    entry = create_indexed_playable_entry(cam, prof, 1_760_000_000_000_000, actor)
    now = DateTime.utc_now()
    parent = self()

    {:ok, fallback_pipeline} =
      VantagePipeline
      |> Ash.Changeset.for_create(
        :create,
        %{
          pipeline_id: "io.serviceradar.vantage-alpr.fallback-flow",
          version: "1.0.0",
          name: "ALPR Ramp 1 to Ramp 2",
          source_mode: :recorded_block,
          trigger_kind: :on_stage1_detection,
          input_mode: :detection_crop,
          runner: :external_worker,
          capability: "vantage.alpr.v1",
          fallback_runner: "camera_vlm",
          roi_polygons: [%{"name" => "lane", "points" => [[0.1, 0.1], [0.9, 0.1], [0.9, 0.9]]}],
          signal_schema_id: "alpr_plate_read",
          signal_schema_version: "1.0.0",
          display_contract_id: "alpr_plate_read"
        },
        actor: actor
      )
      |> Ash.create(actor: actor)

    {:ok, strict_pipeline} =
      VantagePipeline
      |> Ash.Changeset.for_create(
        :create,
        %{
          pipeline_id: "io.serviceradar.vantage-alpr.strict-flow",
          version: "1.0.0",
          name: "ALPR Strict External",
          source_mode: :recorded_block,
          trigger_kind: :on_stage1_detection,
          input_mode: :detection_crop,
          runner: :external_worker,
          capability: "vantage.alpr.v1",
          fallback_runner: nil,
          signal_schema_id: "alpr_plate_read",
          signal_schema_version: "1.0.0",
          display_contract_id: "alpr_plate_read"
        },
        actor: actor
      )
      |> Ash.create(actor: actor)

    {:ok, job_fallback} =
      VantageJob
      |> Ash.Changeset.for_create(
        :enqueue,
        %{
          vantage_pipeline_id: fallback_pipeline.id,
          pipeline_id: fallback_pipeline.pipeline_id,
          pipeline_version: fallback_pipeline.version,
          catalog_entry_id: entry.id,
          camera_source_id: cam.id,
          stream_profile_id: prof.id,
          target_key: "track:ramp-fallback",
          target_runner: "vantage.alpr.v1",
          subject: "media.jobs.vantage.vantage_alpr_v1.v1",
          descriptor_sha256: entry.descriptor_sha256,
          sampled_targets: [
            %{
              "target_key" => "track:ramp-fallback",
              "fragment_sequence" => 0,
              "media_pts_ns" => 0,
              "timeline_ts_us" => entry.timeline_start_us,
              "category" => "vehicle",
              "confidence" => 0.91,
              "bbox" => [0.2, 0.2, 0.6, 0.6]
            }
          ]
        },
        actor: actor
      )
      |> Ash.create(actor: actor)

    {:ok, job_held} =
      VantageJob
      |> Ash.Changeset.for_create(
        :enqueue,
        %{
          vantage_pipeline_id: strict_pipeline.id,
          pipeline_id: strict_pipeline.pipeline_id,
          pipeline_version: strict_pipeline.version,
          catalog_entry_id: entry.id,
          camera_source_id: cam.id,
          stream_profile_id: prof.id,
          target_key: "track:ramp-hold",
          target_runner: "vantage.alpr.v1",
          subject: "media.jobs.vantage.vantage_alpr_v1.v1",
          descriptor_sha256: entry.descriptor_sha256,
          sampled_targets: [
            %{
              "target_key" => "track:ramp-hold",
              "fragment_sequence" => 0,
              "media_pts_ns" => 0,
              "timeline_ts_us" => entry.timeline_start_us,
              "category" => "vehicle",
              "confidence" => 0.89,
              "bbox" => [0.25, 0.25, 0.65, 0.65]
            }
          ]
        },
        actor: actor
      )
      |> Ash.create(actor: actor)

    publisher = fn subject, encoded, pub_opts ->
      send(parent, {:jetstream_publish, subject, Jason.decode!(encoded), pub_opts})
      {:ok, %{stream: "CAMERA_MEDIA_JOBS", seq: System.unique_integer([:positive])}}
    end

    # Pass 1: No external worker -> fallback_pipeline dispatches to Ramp 1 (camera_vlm), strict_pipeline HOLDS pending
    assert {:ok, summary_1} =
             VantagePipelineDispatcher.relay(
               enabled?: true,
               now: now,
               publisher: publisher
             )

    assert summary_1.dispatched_count == 1
    assert summary_1.held_count == 1

    assert_received {:jetstream_publish, "media.jobs.vantage.vlm.v1", env1, opts1}
    assert env1["job_id"] == job_fallback.id
    assert env1["roi_polygons"] == [[[0.1, 0.1], [0.9, 0.1], [0.9, 0.9]]]
    assert opts1[:msg_id] == "vantage-job:#{job_fallback.id}:0"

    assert %{state: :dispatched, target_runner: "camera_vlm", attempt_count: 1} =
             VantageJob.get_by_id!(job_fallback.id, actor: actor)

    assert %{state: :pending, attempt_count: 0} = VantageJob.get_by_id!(job_held.id, actor: actor)

    # Pass 2: Register an unsaturated v1 worker via VantageWorkerHeartbeat -> strict job upgrades cleanly to Ramp 2!
    later = DateTime.shift(now, second: 5)

    assert {:ok, _reg} =
             VantageWorkerHeartbeat.ingest_heartbeat(
               %{
                 "schema_version" => "vantage.heartbeat.v1",
                 "worker_id" => "vantage-alpr-db-01",
                 "worker_kind" => "external_rust",
                 "protocol_version" => "vantage.worker.v1",
                 "capabilities" => ["vantage.alpr.v1"],
                 "supported_source_modes" => ["recorded_block"],
                 "execution_backend" => "onnx",
                 "architecture" => "arm64",
                 "model_id" => "fast-alpr",
                 "model_version" => "1.0.0",
                 "max_concurrency" => 2,
                 "active_jobs" => 0,
                 "health" => "ready",
                 "sent_at_us" => DateTime.to_unix(later, :microsecond)
               },
               now: later,
               broadcast?: false
             )

    assert {:ok, summary_2} =
             VantagePipelineDispatcher.relay(
               enabled?: true,
               now: later,
               publisher: publisher
             )

    assert summary_2.dispatched_count == 1
    assert_received {:jetstream_publish, "media.jobs.vantage.vantage_alpr_v1.v1", env2, opts2}
    assert env2["job_id"] == job_held.id
    refute Map.has_key?(env2, "vlm_config")
    assert opts2[:msg_id] == "vantage-job:#{job_held.id}:0"

    assert %{state: :dispatched, target_runner: "vantage.alpr.v1", attempt_count: 1} =
             VantageJob.get_by_id!(job_held.id, actor: actor)

    # Pass 3: Expire the heartbeat and dispatch deadline for job_fallback -> re-dispatches cleanly at attempt_count 2,
    # while strict job_held (no eligible worker, fallback nil) transitions back via :requeue_pending!
    expired_time = DateTime.shift(later, minute: 2)

    assert {:ok, summary_3} =
             VantagePipelineDispatcher.relay(
               enabled?: true,
               now: expired_time,
               publisher: publisher
             )

    assert summary_3.dispatched_count >= 1
    assert summary_3.held_count == 1
    assert_received {:jetstream_publish, "media.jobs.vantage.vlm.v1", _env3, opts3}
    assert opts3[:msg_id] == "vantage-job:#{job_fallback.id}:1"

    assert %{state: :dispatched, attempt_count: 2} =
             VantageJob.get_by_id!(job_fallback.id, actor: actor)

    assert %{
             state: :pending,
             deadline_at: nil,
             attempt_count: 1,
             last_error_class: "no_eligible_worker"
           } = VantageJob.get_by_id!(job_held.id, actor: actor)

    # Pass 4: Real CNPG pagination/exclusion + :live over :backfill + parameter_overrides -> pipeline_config
    {:ok, vlm_pipe} =
      VantagePipeline
      |> Ash.Changeset.for_create(
        :create,
        %{
          pipeline_id: "io.serviceradar.vantage-alpr.db-vlm-prio",
          version: "1.0.0",
          name: "DB VLM Priority",
          source_mode: :recorded_block,
          trigger_kind: :on_stage1_detection,
          input_mode: :detection_crop,
          runner: :camera_vlm,
          parameter_overrides: %{"config" => %{"min_confidence" => 0.82}},
          signal_schema_id: "alpr_plate_read",
          signal_schema_version: "1.0.0",
          display_contract_id: "alpr_plate_read"
        },
        actor: actor
      )
      |> Ash.create(actor: actor)

    for idx <- 1..2 do
      {:ok, _} =
        VantageJob
        |> Ash.Changeset.for_create(
          :enqueue,
          %{
            vantage_pipeline_id: strict_pipeline.id,
            pipeline_id: strict_pipeline.pipeline_id,
            pipeline_version: strict_pipeline.version,
            catalog_entry_id: entry.id,
            camera_source_id: cam.id,
            stream_profile_id: prof.id,
            target_key: "track:db-held-#{idx}",
            job_kind: :live,
            target_runner: "vantage.alpr.v1",
            subject: "media.jobs.vantage.vantage_alpr_v1.v1",
            descriptor_sha256: entry.descriptor_sha256
          },
          actor: actor
        )
        |> Ash.create(actor: actor)
    end

    {:ok, vlm_backfill} =
      VantageJob
      |> Ash.Changeset.for_create(
        :enqueue,
        %{
          vantage_pipeline_id: vlm_pipe.id,
          pipeline_id: vlm_pipe.pipeline_id,
          pipeline_version: vlm_pipe.version,
          catalog_entry_id: entry.id,
          camera_source_id: cam.id,
          stream_profile_id: prof.id,
          target_key: "track:db-vlm-backfill",
          job_kind: :backfill,
          target_runner: "camera_vlm",
          subject: "media.jobs.vantage.vlm.backfill.v1",
          descriptor_sha256: entry.descriptor_sha256
        },
        actor: actor
      )
      |> Ash.create(actor: actor)

    {:ok, vlm_live} =
      VantageJob
      |> Ash.Changeset.for_create(
        :enqueue,
        %{
          vantage_pipeline_id: vlm_pipe.id,
          pipeline_id: vlm_pipe.pipeline_id,
          pipeline_version: vlm_pipe.version,
          catalog_entry_id: entry.id,
          camera_source_id: cam.id,
          stream_profile_id: prof.id,
          target_key: "track:db-vlm-live",
          job_kind: :live,
          target_runner: "camera_vlm",
          subject: "media.jobs.vantage.vlm.v1",
          descriptor_sha256: entry.descriptor_sha256
        },
        actor: actor
      )
      |> Ash.create(actor: actor)

    assert {:ok, summary_4} =
             VantagePipelineDispatcher.relay(
               enabled?: true,
               batch_size: 1,
               now: DateTime.shift(expired_time, second: 5),
               publisher: publisher
             )

    assert summary_4.dispatched_count == 1
    assert_received {:jetstream_publish, "media.jobs.vantage.vlm.v1", env4, _opts4}
    assert env4["job_id"] == vlm_live.id
    assert env4["pipeline_config"] == %{"min_confidence" => 0.82}
    assert %{state: :pending} = VantageJob.get_by_id!(vlm_backfill.id, actor: actor)
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
        %{camera_source_id: cam.id, profile_name: "main", relay_eligible: true},
        actor: actor
      )

    {cam, prof}
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
          RelaySessionLifecycle.activate_session(session.id, ingest_id, assignment, actor: actor)

        activated
      end

    owner =
      IngestOwner
      |> Ash.Query.filter(camera_source_id == ^cam.id and stream_profile_id == ^prof.id)
      |> Ash.read_one!(actor: actor)

    {:ok, claim} =
      case RecorderClaim
           |> Ash.Query.filter(ingest_owner_id == ^owner.id and state == :active)
           |> Ash.read_one!(actor: actor) do
        nil ->
          RecorderOwnership.acquire(
            owner,
            Ecto.UUID.generate(),
            active.media_ingest_id,
            Ecto.UUID.generate(),
            30_000,
            actor: actor
          )

        existing_claim ->
          {:ok, existing_claim}
      end

    {:ok, block} = RecorderOwnership.reserve_block(owner, claim, @clock, actor: actor)

    init_sha = sha256("synthetic-init-#{block.id}")
    f0_sha = sha256("synthetic-f0-#{block.id}")
    media_sha = sha256("synthetic-media-#{block.id}")

    desc = %{
      "version" => 1,
      "identity" => RecordingBlock.identity(block),
      "format" => %{"codec" => "avc1.42c00a", "timescale" => 90_000},
      "init" => %{"length" => 256, "sha256" => init_sha},
      "media" => %{"length" => 1_024, "sha256" => media_sha},
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
        }
      ]
    }

    {:ok, _} = Descriptor.encode(desc)

    {:ok, entry} =
      RecordingBlocks.freeze_and_catalog(
        owner,
        claim,
        block,
        desc,
        %{
          first_unit_pts: 0,
          first_unit_received_at: DateTime.from_unix!(start_us, :microsecond),
          reanchored: false
        },
        actor: actor
      )

    entry
  end

  defp sha256(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
end
