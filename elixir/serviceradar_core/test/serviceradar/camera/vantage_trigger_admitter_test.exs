defmodule ServiceRadar.Camera.VantageTriggerAdmitterTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Camera.RecordingCatalogEntry
  alias ServiceRadar.Camera.VantagePipeline
  alias ServiceRadar.Camera.VantageTriggerAdmitter
  alias ServiceRadar.Camera.VisualIndexResultEnvelope

  @cam_id "11111111-1111-4111-8111-111111111111"
  @prof_id "22222222-2222-4222-8222-222222222222"
  @entry_id "33333333-3333-4333-8333-333333333333"
  @block_id "44444444-4444-4444-8444-444444444444"
  @policy_id "55555555-5555-4555-8555-555555555555"
  @digest String.duplicate("b", 64)

  test "returns empty list immediately when Vantage pipelines are disabled" do
    loader_called? = fn _trigger -> flunk("pipelines_loader must not be called when disabled") end

    assert {:ok, []} =
             VantageTriggerAdmitter.admit_for_stage1_detections(
               playable_entry(),
               [sample_frame()],
               env_fetch: fn _, default -> default end,
               pipelines_loader: loader_called?
             )
  end

  test "VisualIndexResultEnvelope preserves track_id transiently on vantage_detections while keeping detections unchanged" do
    envelope = %{
      schema: "media.results.visual_index.v1",
      schema_version: 1,
      catalog_entry_id: @entry_id,
      descriptor_sha256: @digest,
      detector_model_id: "yolox-s",
      detector_model_version: "2026.1",
      embedder_model_id: "siglip-b16-384",
      embedder_model_version: "2026.1",
      embedding_dim: 512,
      frames: [
        %{
          fragment_sequence: 1,
          media_pts_ns: 1_000_000_000,
          scene_suppressed: false,
          detections: [
            %{
              object_class: "vehicle",
              confidence: 0.87,
              bbox: [0.3, 0.45, 0.55, 0.8],
              dominant_colors: ["silver"],
              track_id: 42
            }
          ],
          embeddings: []
        }
      ]
    }

    assert {:ok, _, {:ok, %{frames: [parsed]}}} = VisualIndexResultEnvelope.validate(envelope)
    assert [persisted] = parsed.detections
    refute Map.has_key?(persisted, "track_id")
    assert [%{"track_id" => 42, "object_class" => "vehicle"}] = parsed.vantage_detections
  end

  describe "Stage 1 detection trigger admission" do
    test "admits idempotent track-grouped job only for matching class, confidence, ROI polygon, and camera selector" do
      pipeline =
        base_pipeline(%{
          camera_selector: %{"mode" => "srql", "srql" => "tag:gate-entry"},
          object_classes: ["vehicle"],
          min_confidence: 0.55,
          roi_polygons: [%{"points" => [[0.2, 0.4], [0.7, 0.4], [0.7, 0.9], [0.2, 0.9]]}],
          max_frames_per_track: 2
        })

      frames = [
        %{
          fragment_sequence: 1,
          media_pts_ns: 1_000_000_000,
          vantage_detections: [
            # Matching vehicle inside ROI on track 7
            %{
              "object_class" => "vehicle",
              "confidence" => 0.87,
              "bbox" => [0.3, 0.5, 0.55, 0.8],
              "track_id" => 7
            },
            # Non-matching class inside ROI
            %{
              "object_class" => "person",
              "confidence" => 0.95,
              "bbox" => [0.35, 0.55, 0.45, 0.75],
              "track_id" => 8
            },
            # Vehicle outside ROI polygon
            %{
              "object_class" => "vehicle",
              "confidence" => 0.91,
              "bbox" => [0.02, 0.05, 0.12, 0.2],
              "track_id" => 9
            }
          ]
        },
        %{
          fragment_sequence: 2,
          media_pts_ns: 2_000_000_000,
          vantage_detections: [
            # Higher-confidence observation for track 7
            %{
              "object_class" => "vehicle",
              "confidence" => 0.93,
              "bbox" => [0.32, 0.52, 0.56, 0.82],
              "track_id" => 7
            }
          ]
        },
        %{
          fragment_sequence: 3,
          media_pts_ns: 3_000_000_000,
          vantage_detections: [
            # Lowest-confidence observation for track 7 (must be trimmed by max_frames_per_track: 2)
            %{
              "object_class" => "vehicle",
              "confidence" => 0.61,
              "bbox" => [0.31, 0.51, 0.52, 0.78],
              "track_id" => 7
            }
          ]
        }
      ]

      parent = self()

      assert {:ok, [job]} =
               VantageTriggerAdmitter.admit_for_stage1_detections(
                 playable_entry(),
                 frames,
                 enabled?: true,
                 pipelines: [pipeline],
                 source: %{
                   id: @cam_id,
                   device_uid: "dev-gate-01",
                   display_name: "Gate West 01",
                   metadata: %{}
                 },
                 device: %{uid: "dev-gate-01", tags: %{"gate-entry" => true}},
                 recent_job_count_fn: fn _, _ -> 0 end,
                 enqueue_fn: fn attrs ->
                   send(parent, {:enqueued, attrs})
                   {:ok, attrs}
                 end
               )

      assert job.target_key == "track:7"
      assert job.subject == "media.jobs.vantage.vlm.v1"
      assert job.target_runner == "camera_vlm"
      assert length(job.sampled_targets) == 2
      assert Enum.map(job.sampled_targets, & &1["fragment_sequence"]) == [1, 2]
    end

    test "respects source detection_roi_grid ignore_cells when pipeline roi_polygons is empty" do
      pipeline =
        base_pipeline(%{roi_polygons: [], object_classes: ["vehicle"], min_confidence: 0.5})

      ignored_frame = %{
        fragment_sequence: 1,
        media_pts_ns: 1_000_000_000,
        vantage_detections: [
          %{
            "object_class" => "vehicle",
            "confidence" => 0.9,
            # Center (0.1, 0.1) falls in cell [0, 0] on a 2x2 grid
            "bbox" => [0.05, 0.05, 0.15, 0.15],
            "track_id" => 11
          }
        ]
      }

      source_with_grid = %{
        id: @cam_id,
        metadata: %{
          "detection_roi_grid" => %{"rows" => 2, "cols" => 2, "ignore_cells" => [[0, 0]]}
        }
      }

      assert {:ok, []} =
               VantageTriggerAdmitter.admit_for_stage1_detections(
                 playable_entry(),
                 [ignored_frame],
                 enabled?: true,
                 pipelines: [pipeline],
                 source: source_with_grid,
                 recent_job_count_fn: fn _, _ -> 0 end,
                 enqueue_fn: fn _ -> flunk("must not enqueue inside ignored ROI cell") end
               )
    end

    test "sheds excess admissions and emits telemetry when max_jobs_per_minute is exceeded" do
      handler = "vantage-drop-test-#{System.unique_integer([:positive])}"
      parent = self()

      :telemetry.attach(
        handler,
        [:serviceradar, :camera, :vantage, :admission_dropped],
        fn _event, measurements, metadata, _ ->
          send(parent, {:dropped, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      pipeline = base_pipeline(%{max_jobs_per_minute: 1, object_classes: ["vehicle"]})

      frames = [
        %{
          fragment_sequence: 1,
          media_pts_ns: 1_000_000_000,
          vantage_detections: [
            %{
              "object_class" => "vehicle",
              "confidence" => 0.9,
              "bbox" => [0.1, 0.1, 0.3, 0.3],
              "track_id" => 1
            },
            %{
              "object_class" => "vehicle",
              "confidence" => 0.9,
              "bbox" => [0.5, 0.5, 0.8, 0.8],
              "track_id" => 2
            }
          ]
        }
      ]

      assert {:ok, [admitted]} =
               VantageTriggerAdmitter.admit_for_stage1_detections(
                 playable_entry(),
                 frames,
                 enabled?: true,
                 pipelines: [pipeline],
                 source: %{id: @cam_id, metadata: %{}},
                 recent_job_count_fn: fn _, _ -> 0 end,
                 enqueue_fn: fn attrs -> {:ok, attrs} end
               )

      assert admitted.target_key == "track:1"
      assert_received {:dropped, %{count: 1}, %{pipeline_id: _, reason: :rate_limit_exceeded}}
    end

    test "routes external_worker to capability subject when worker is active and falls back to camera_vlm otherwise" do
      pipeline =
        base_pipeline(%{
          runner: :external_worker,
          capability: "vantage.alpr.v1",
          fallback_runner: "camera_vlm"
        })

      assert {:ok, [external_job]} =
               VantageTriggerAdmitter.admit_for_stage1_detections(
                 playable_entry(),
                 [sample_frame()],
                 enabled?: true,
                 pipelines: [pipeline],
                 source: %{id: @cam_id, metadata: %{}},
                 recent_job_count_fn: fn _, _ -> 0 end,
                 worker_active_fn: fn "vantage.alpr.v1", _now -> true end,
                 enqueue_fn: fn attrs -> {:ok, attrs} end
               )

      assert external_job.target_runner == "vantage.alpr.v1"
      assert external_job.subject == "media.jobs.vantage.vantage_alpr_v1.v1"

      assert {:ok, [fallback_job]} =
               VantageTriggerAdmitter.admit_for_stage1_detections(
                 playable_entry(),
                 [sample_frame()],
                 enabled?: true,
                 pipelines: [pipeline],
                 source: %{id: @cam_id, metadata: %{}},
                 recent_job_count_fn: fn _, _ -> 0 end,
                 worker_active_fn: fn "vantage.alpr.v1", _now -> false end,
                 enqueue_fn: fn attrs -> {:ok, attrs} end
               )

      assert fallback_job.target_runner == "camera_vlm"
      assert fallback_job.subject == "media.jobs.vantage.vlm.v1"
    end

    test "supports quote-aware SRQL selectors with spaces and rejects unclosed quotes" do
      entry = playable_entry()
      source = %{id: @cam_id, display_name: "Gate West 01", metadata: %{"tags" => ["gate-entry"]}}
      device = %{uid: "dev-gate-01", tags: %{"gate-entry" => true}}

      assert VantageTriggerAdmitter.matches_camera_selector?(
               %{camera_selector: %{"mode" => "srql", "srql" => ~s(display_name:"Gate West 01")}},
               entry,
               source,
               device
             )

      assert VantageTriggerAdmitter.matches_camera_selector?(
               %{
                 camera_selector: %{
                   "mode" => "srql",
                   "srql" => "display_name:'Gate West 01' tag:\"gate-entry\""
                 }
               },
               entry,
               source,
               device
             )

      refute VantageTriggerAdmitter.matches_camera_selector?(
               %{camera_selector: %{"mode" => "srql", "srql" => ~s(display_name:"Gate East 02")}},
               entry,
               source,
               device
             )

      refute VantageTriggerAdmitter.matches_camera_selector?(
               %{camera_selector: %{"mode" => "srql", "srql" => ~s(display_name:"Gate West 01)}},
               entry,
               source,
               device
             )
    end

    test "treats empty/whitespace/non-scalar track_id as nil, enforces [0, 1] bbox bounds, and guards malformed lists" do
      pipeline =
        base_pipeline(%{
          object_classes: ["vehicle"],
          roi_polygons: [%{"points" => "not-a-list"}],
          max_jobs_per_minute: 10
        })

      frames = [
        %{
          fragment_sequence: 1,
          media_pts_ns: 1_000_000_000,
          vantage_detections: [
            # Empty track_id must not collapse onto "track:"
            %{
              "object_class" => "vehicle",
              "confidence" => 0.9,
              "bbox" => [0.0, 0.0, 0.4, 0.4],
              "track_id" => ""
            },
            # Whitespace track_id must not collapse onto "track:"
            %{
              "object_class" => "vehicle",
              "confidence" => 0.9,
              "bbox" => [0.5, 0.5, 1.0, 1.0],
              "track_id" => "   "
            },
            # Non-String.Chars track_id (map) must not raise Protocol.UndefinedError
            %{
              "object_class" => "vehicle",
              "confidence" => 0.9,
              "bbox" => [0.2, 0.2, 0.6, 0.6],
              "track_id" => %{"bad" => 1}
            },
            # Out-of-bounds [0.0, 1.0] bboxes must be rejected
            %{
              "object_class" => "vehicle",
              "confidence" => 0.95,
              "bbox" => [-0.1, 0.1, 0.5, 0.5],
              "track_id" => "oob-1"
            },
            %{
              "object_class" => "vehicle",
              "confidence" => 0.95,
              "bbox" => [0.1, 0.1, 1.2, 0.5],
              "track_id" => "oob-2"
            }
          ]
        },
        %{
          fragment_sequence: 2,
          media_pts_ns: 2_000_000_000,
          vantage_detections: "not-a-list"
        }
      ]

      assert {:ok, jobs} =
               VantageTriggerAdmitter.admit_for_stage1_detections(
                 playable_entry(),
                 frames,
                 enabled?: true,
                 pipelines: [pipeline],
                 source: %{id: @cam_id, metadata: %{}},
                 recent_job_count_fn: fn _, _ -> 0 end,
                 enqueue_fn: fn attrs -> {:ok, attrs} end
               )

      assert Enum.map(jobs, & &1.target_key) == [
               "frame:1:det:0",
               "frame:1:det:1",
               "frame:1:det:2"
             ]

      assert Enum.all?(jobs, fn job -> hd(job.sampled_targets)["track_id"] == nil end)

      assert {:ok, []} =
               VantageTriggerAdmitter.admit_for_stage1_detections(
                 playable_entry(),
                 [
                   %{fragment_sequence: 1, media_pts_ns: 1_000_000_000, vantage_detections: "bad"}
                 ],
                 enabled?: true,
                 pipelines: [base_pipeline(%{roi_polygons: "not-a-list"})],
                 source: %{id: @cam_id, metadata: %{}},
                 recent_job_count_fn: fn _, _ -> 0 end,
                 enqueue_fn: fn _ -> flunk("must not enqueue on malformed detections") end
               )
    end
  end

  describe "Sealed-block trigger admission" do
    test "admits on_sealed_block job keyed by target_key block" do
      pipeline = base_pipeline(%{trigger_kind: :on_sealed_block})

      descriptor = %{
        "fragments" => [
          %{"sequence" => 0, "has_idr" => true, "media_pts_ns" => 1_000_000_000},
          %{"sequence" => 1, "has_idr" => false, "media_pts_ns" => 2_000_000_000}
        ]
      }

      assert {:ok, [job]} =
               VantageTriggerAdmitter.admit_for_sealed_block(
                 playable_entry(),
                 descriptor,
                 enabled?: true,
                 pipelines: [pipeline],
                 source: %{id: @cam_id, metadata: %{}},
                 recent_job_count_fn: fn _, _ -> 0 end,
                 enqueue_fn: fn attrs -> {:ok, attrs} end
               )

      assert job.target_key == "block"
      assert [%{"fragment_sequence" => 0}] = job.sampled_targets
    end

    test "extracts distinct fragment timestamps from start_ns and pts_ns in real descriptors" do
      pipeline = base_pipeline(%{trigger_kind: :on_sealed_block, max_frames_per_track: 3})

      descriptor = %{
        "fragments" => [
          %{"sequence" => 0, "has_idr" => true, "start_ns" => 1_000_000_000},
          %{"sequence" => 1, "has_idr" => true, "start_ns" => 3_500_000_000},
          %{"sequence" => 2, "has_idr" => true, "pts_ns" => 5_000_000_000}
        ]
      }

      assert {:ok, [job]} =
               VantageTriggerAdmitter.admit_for_sealed_block(
                 playable_entry(),
                 descriptor,
                 enabled?: true,
                 pipelines: [pipeline],
                 source: %{id: @cam_id, metadata: %{}},
                 recent_job_count_fn: fn _, _ -> 0 end,
                 enqueue_fn: fn attrs -> {:ok, attrs} end
               )

      assert Enum.map(job.sampled_targets, & &1["fragment_sequence"]) == [0, 1, 2]

      assert Enum.map(job.sampled_targets, & &1["media_pts_ns"]) == [
               1_000_000_000,
               3_500_000_000,
               5_000_000_000
             ]

      assert Enum.map(job.sampled_targets, & &1["timeline_ts_us"]) == [
               1_760_000_000_000_000,
               1_760_000_002_500_000,
               1_760_000_004_000_000
             ]
    end

    test "returns empty list without enqueueing when fragments is empty or malformed" do
      pipeline = base_pipeline(%{trigger_kind: :on_sealed_block})

      for bad_desc <- [
            %{"fragments" => []},
            %{"fragments" => "not-a-list"},
            %{"fragments" => ["bad"]}
          ] do
        assert {:ok, []} =
                 VantageTriggerAdmitter.admit_for_sealed_block(
                   playable_entry(),
                   bad_desc,
                   enabled?: true,
                   pipelines: [pipeline],
                   source: %{id: @cam_id, metadata: %{}},
                   recent_job_count_fn: fn _, _ -> 0 end,
                   enqueue_fn: fn _ -> flunk("must not enqueue empty-target sealed block job") end
                 )
      end
    end

    test "guards nil timeline_start_us and timeline_end_us, populates pipeline_config from parameter_overrides, and rejects invalid external_worker capabilities across both admission paths" do
      nil_timeline_entry =
        struct(RecordingCatalogEntry,
          id: @entry_id,
          recording_block_id: @block_id,
          camera_source_id: @cam_id,
          stream_profile_id: @prof_id,
          policy_id: @policy_id,
          descriptor_sha256: @digest,
          local_state: :present,
          archive_state: :not_required,
          quarantine_reason: nil,
          media_start_ns: nil,
          first_unit_received_at: nil,
          timeline_start_us: nil,
          timeline_end_us: nil
        )

      wrapped_stage1_pipeline =
        struct(VantagePipeline,
          id: Ecto.UUID.generate(),
          pipeline_id: "io.serviceradar.vantage-alpr.stage1-nil-ts",
          version: "1.0.0",
          enabled: true,
          source_mode: :recorded_block,
          trigger_kind: :on_stage1_detection,
          camera_selector: %{"mode" => "all"},
          object_classes: ["vehicle"],
          min_confidence: 0.5,
          roi_polygons: [],
          input_mode: :detection_crop,
          crop_policy: %{},
          max_jobs_per_minute: 60,
          max_frames_per_track: 3,
          runner: :camera_vlm,
          capability: nil,
          fallback_runner: nil,
          vlm_config: %{},
          signal_schema_id: "alpr_plate_read",
          signal_schema_version: "1.0.0",
          display_contract_id: "alpr_plate_read",
          parameter_overrides: %{"config" => %{"min_confidence" => 0.77}, "enabled" => true}
        )

      assert {:ok, [stage1_job]} =
               VantageTriggerAdmitter.admit_for_stage1_detections(
                 nil_timeline_entry,
                 [sample_frame()],
                 enabled?: true,
                 nudge_dispatch?: false,
                 pipelines: [wrapped_stage1_pipeline],
                 source: %{id: @cam_id, metadata: %{}},
                 recent_job_count_fn: fn _, _ -> 0 end,
                 enqueue_fn: fn attrs -> {:ok, attrs} end
               )

      assert hd(stage1_job.sampled_targets)["timeline_ts_us"] == 0
      assert stage1_job.job_payload["pipeline_config"] == %{"min_confidence" => 0.77}

      sealed_pipeline =
        struct(VantagePipeline, %{
          Map.from_struct(wrapped_stage1_pipeline)
          | trigger_kind: :on_sealed_block,
            parameter_overrides: %{"regions" => ["west"]}
        })

      descriptor = %{
        "fragments" => [
          %{"sequence" => 0, "has_idr" => true, "media_pts_ns" => 1_000_000_000},
          %{"sequence" => 1, "has_idr" => true, "media_pts_ns" => nil}
        ]
      }

      assert {:ok, [sealed_job]} =
               VantageTriggerAdmitter.admit_for_sealed_block(
                 nil_timeline_entry,
                 descriptor,
                 enabled?: true,
                 nudge_dispatch?: false,
                 pipelines: [sealed_pipeline],
                 source: %{id: @cam_id, metadata: %{}},
                 recent_job_count_fn: fn _, _ -> 0 end,
                 enqueue_fn: fn attrs -> {:ok, attrs} end
               )

      assert Enum.all?(sealed_job.sampled_targets, fn t ->
               is_integer(t["timeline_ts_us"]) and t["timeline_ts_us"] >= 0
             end)

      assert sealed_job.job_payload["pipeline_config"] == %{"regions" => ["west"]}

      for bad_cap <- ["   ", "!!!", "", nil, "Vantage.ALPR", "bad cap"] do
        assert_raise ArgumentError, fn ->
          VantageTriggerAdmitter.job_subject(:external_worker, bad_cap, :live)
        end

        bad_stage1_pipe =
          base_pipeline(%{
            runner: :external_worker,
            capability: bad_cap,
            fallback_runner: "camera_vlm"
          })

        assert {:error, :invalid_capability} =
                 VantageTriggerAdmitter.admit_for_stage1_detections(
                   playable_entry(),
                   [sample_frame()],
                   enabled?: true,
                   nudge_dispatch?: false,
                   pipelines: [bad_stage1_pipe],
                   source: %{id: @cam_id, metadata: %{}},
                   recent_job_count_fn: fn _, _ -> 0 end,
                   enqueue_fn: fn _ -> flunk("must not enqueue invalid capability") end
                 )

        bad_sealed_pipe =
          base_pipeline(%{
            trigger_kind: :on_sealed_block,
            runner: :external_worker,
            capability: bad_cap,
            fallback_runner: nil
          })

        assert {:error, :invalid_capability} =
                 VantageTriggerAdmitter.admit_for_sealed_block(
                   playable_entry(),
                   descriptor,
                   enabled?: true,
                   nudge_dispatch?: false,
                   pipelines: [bad_sealed_pipe],
                   source: %{id: @cam_id, metadata: %{}},
                   recent_job_count_fn: fn _, _ -> 0 end,
                   enqueue_fn: fn _ -> flunk("must not enqueue invalid capability") end
                 )
      end

      # VantagePipeline resource validation enforces capability format & requirement
      for bad_cap <- ["   ", "!!!", "bad cap", "Vantage.ALPR", nil] do
        changeset =
          Ash.Changeset.for_create(VantagePipeline, :create, %{
            pipeline_id: "io.serviceradar.vantage.invalid-cap",
            version: "1.0.0",
            name: "Invalid Cap",
            runner: :external_worker,
            capability: bad_cap,
            signal_schema_id: "alpr_plate_read",
            signal_schema_version: "1.0.0",
            display_contract_id: "alpr_plate_read"
          })

        refute changeset.valid?
      end

      valid_changeset =
        Ash.Changeset.for_create(VantagePipeline, :create, %{
          pipeline_id: "io.serviceradar.vantage.valid-cap",
          version: "1.0.0",
          name: "Valid Cap",
          runner: :external_worker,
          capability: "vantage.alpr.v1",
          signal_schema_id: "alpr_plate_read",
          signal_schema_version: "1.0.0",
          display_contract_id: "alpr_plate_read"
        })

      assert valid_changeset.valid?
    end
  end

  defp playable_entry do
    struct(RecordingCatalogEntry,
      id: @entry_id,
      recording_block_id: @block_id,
      camera_source_id: @cam_id,
      stream_profile_id: @prof_id,
      policy_id: @policy_id,
      descriptor_sha256: @digest,
      local_state: :present,
      archive_state: :not_required,
      quarantine_reason: nil,
      media_start_ns: 1_000_000_000,
      timeline_start_us: 1_760_000_000_000_000,
      timeline_end_us: 1_760_000_010_000_000
    )
  end

  defp sample_frame do
    %{
      fragment_sequence: 1,
      media_pts_ns: 1_000_000_000,
      vantage_detections: [
        %{
          "object_class" => "vehicle",
          "confidence" => 0.87,
          "bbox" => [0.3, 0.45, 0.55, 0.8],
          "track_id" => 1
        }
      ]
    }
  end

  defp base_pipeline(overrides) do
    Map.merge(
      %{
        id: Ecto.UUID.generate(),
        pipeline_id: "io.serviceradar.vantage-alpr.vehicle-plate",
        version: "1.0.0",
        enabled: true,
        source_mode: :recorded_block,
        trigger_kind: :on_stage1_detection,
        camera_selector: %{"mode" => "all"},
        object_classes: ["vehicle"],
        min_confidence: 0.55,
        roi_polygons: [],
        input_mode: :detection_crop,
        crop_policy: %{"padding_ratio" => 0.15, "min_bbox_width_px" => 96},
        max_jobs_per_minute: 60,
        max_frames_per_track: 3,
        runner: :camera_vlm,
        capability: nil,
        fallback_runner: nil,
        vlm_config: %{},
        signal_schema_id: "alpr_plate_read",
        signal_schema_version: "1.0.0",
        display_contract_id: "alpr_plate_read"
      },
      overrides
    )
  end
end
