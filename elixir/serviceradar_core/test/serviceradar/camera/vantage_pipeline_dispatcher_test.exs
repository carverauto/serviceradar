defmodule ServiceRadar.Camera.VantagePipelineDispatcherTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Camera.VantagePipeline
  alias ServiceRadar.Camera.VantagePipelineDispatcher
  alias ServiceRadar.Camera.VantagePipelineDispatchWorker
  alias ServiceRadar.Camera.VantageTriggerAdmitter
  alias ServiceRadar.Jobs.CoreCrontab

  @cam_id "00000000-0000-4000-8000-000000000101"
  @prof_id "00000000-0000-4000-8000-000000000102"
  @cat_id "00000000-0000-4000-8000-000000000103"
  @job_id "00000000-0000-4000-8000-000000000201"
  @digest String.duplicate("a", 64)
  @now ~U[2026-11-25 00:00:00Z]

  describe "deployment_enabled?/1 and CoreCrontab wiring" do
    test "enables relay and crontab entry only when SERVICERADAR_VANTAGE_PIPELINES_ENABLED=true" do
      refute VantagePipelineDispatcher.deployment_enabled?(fn _, default -> default end)

      assert VantagePipelineDispatcher.deployment_enabled?(
               fn "SERVICERADAR_VANTAGE_PIPELINES_ENABLED", _ -> "true" end
             )

      off_entries = CoreCrontab.cron_entries(fn _, default -> default end)

      refute Enum.any?(off_entries, fn {_cron, worker, _opts} ->
               worker == VantagePipelineDispatchWorker
             end)

      on_entries =
        CoreCrontab.cron_entries(fn
          "SERVICERADAR_VANTAGE_PIPELINES_ENABLED", _ -> "true"
          _, default -> default
        end)

      assert Enum.any?(on_entries, fn
               {"* * * * *", VantagePipelineDispatchWorker, [queue: :maintenance]} -> true
               _ -> false
             end)
    end
  end

  describe "resolve_route/4 Ramp 1 <-> Ramp 2 routing & worker eligibility" do
    test "routes external_worker pipeline to Ramp 2 subject when ready unsaturated matching worker exists" do
      pipeline = external_pipeline(fallback_runner: "camera_vlm")
      worker = ready_worker()

      assert {:dispatch, route} =
               VantagePipelineDispatcher.resolve_route(pipeline, :live, @now, workers: [worker])

      assert route.runner_kind == :external_worker
      assert route.target_runner == "vantage.alpr.v1"
      assert route.subject == "media.jobs.vantage.vantage_alpr_v1.v1"
      assert route.fallback? == false

      assert {:dispatch, backfill_route} =
               VantagePipelineDispatcher.resolve_route(pipeline, :backfill, @now,
                 workers: [worker]
               )

      assert backfill_route.subject == "media.jobs.vantage.vantage_alpr_v1.backfill.v1"
    end

    test "falls back to camera_vlm for recorded_block when no eligible worker exists and fallback_runner is camera_vlm" do
      pipeline = external_pipeline(fallback_runner: "camera_vlm", source_mode: :recorded_block)

      ineligible = [
        ready_worker(%{expires_at: DateTime.shift(@now, second: -5)}),
        ready_worker(%{health: :draining}),
        ready_worker(%{active_jobs: 4, max_concurrency: 4}),
        ready_worker(%{supported_source_modes: ["live_keyframe_tap"]}),
        ready_worker(%{capabilities: ["vantage.other.v1"]})
      ]

      assert {:dispatch, route} =
               VantagePipelineDispatcher.resolve_route(pipeline, :live, @now, workers: ineligible)

      assert route.runner_kind == :camera_vlm
      assert route.target_runner == "camera_vlm"
      assert route.subject == "media.jobs.vantage.vlm.v1"
      assert route.fallback? == true
    end

    test "holds as pending when no eligible worker exists and fallback_runner is nil or source_mode is live_keyframe_tap" do
      assert {:hold, :no_eligible_worker} ==
               VantagePipelineDispatcher.resolve_route(
                 external_pipeline(fallback_runner: nil),
                 :live,
                 @now,
                 workers: []
               )

      assert {:hold, :no_eligible_worker} ==
               VantagePipelineDispatcher.resolve_route(
                 external_pipeline(
                   fallback_runner: "camera_vlm",
                   source_mode: :live_keyframe_tap
                 ),
                 :live,
                 @now,
                 workers: []
               )
    end
  end

  describe "build_envelope/3 wire normalization and 4 KiB cap" do
    test "normalizes roi_polygons, sampled_targets time_basis, vlm_config omission/defaults, and respects 4 KiB ceiling" do
      ext_pipeline =
        external_pipeline(%{
          roi_polygons: [%{"name" => "gate", "points" => [[0.1, 0.1], [0.9, 0.1], [0.9, 0.9]]}],
          vlm_config: %{}
        })

      job =
        base_job(%{
          target_runner: "vantage.alpr.v1",
          subject: "media.jobs.vantage.vantage_alpr_v1.v1",
          sampled_targets: [
            %{
              "target_key" => "track:7",
              "track_id" => nil,
              "fragment_sequence" => 1,
              "media_pts_ns" => 1_000_000,
              "timeline_ts_us" => 1_760_000_000_000_000,
              "category" => "vehicle",
              "confidence" => 0.92,
              "bbox" => [0.25, 0.4, 0.55, 0.72]
            }
          ]
        })

      assert {:ok, "media.jobs.vantage.vantage_alpr_v1.v1", encoded, env} =
               VantagePipelineDispatcher.build_envelope(job, ext_pipeline, time_basis: :received)

      assert byte_size(encoded) <= 4096
      assert env["schema_version"] == "vantage.job.v1"
      assert env["capability"] == "vantage.alpr.v1"
      assert env["roi_polygons"] == [[[0.1, 0.1], [0.9, 0.1], [0.9, 0.9]]]
      refute Map.has_key?(env, "vlm_config")
      assert [target] = env["sampled_targets"]
      assert target["time_basis"] == "received"
      assert target["track_id"] == "track:7"

      # Full-frame on_sealed_block fallback envelope with Ramp 1 camera_vlm includes defaults
      full_frame_pipeline =
        external_pipeline(%{
          input_mode: :full_frame,
          fallback_runner: "camera_vlm",
          vlm_config: %{"prompt" => "Read plate text"}
        })

      sealed_job =
        base_job(%{
          target_runner: "camera_vlm",
          subject: "media.jobs.vantage.vlm.v1",
          sampled_targets: [
            %{
              "target_key" => "block",
              "fragment_sequence" => 0,
              "media_pts_ns" => 0,
              "timeline_ts_us" => 1_760_000_000_000_000
            }
          ]
        })

      assert {:ok, "media.jobs.vantage.vlm.v1", vlm_encoded, vlm_env} =
               VantagePipelineDispatcher.build_envelope(
                 sealed_job,
                 full_frame_pipeline,
                 target_runner: "camera_vlm",
                 subject: "media.jobs.vantage.vlm.v1",
                 time_basis: :camera_reported
               )

      assert byte_size(vlm_encoded) <= 4096
      assert vlm_env["vlm_config"]["prompt"] == "Read plate text"
      assert vlm_env["vlm_config"]["model_profile"] == "vlm_default"
      assert vlm_env["vlm_config"]["max_tokens"] == 256
      assert vlm_env["vlm_config"]["temperature"] == 0.0

      assert [frame_target] = vlm_env["sampled_targets"]
      assert frame_target["time_basis"] == "camera_reported"
      assert frame_target["category"] == "frame"
      assert frame_target["bbox"] == [0.0, 0.0, 1.0, 1.0]

      # Oversized sampled_targets trims gracefully under 4096 bytes
      many_targets =
        for i <- 0..49 do
          %{
            "target_key" => "track:#{i}",
            "track_id" => "track:#{i}",
            "fragment_sequence" => i,
            "media_pts_ns" => i * 1_000_000,
            "timeline_ts_us" => 1_760_000_000_000_000 + i,
            "category" => "vehicle",
            "confidence" => 0.9,
            "bbox" => [0.1, 0.1, 0.4, 0.4]
          }
        end

      assert {:ok, _, trimmed_encoded, trimmed_env} =
               VantagePipelineDispatcher.build_envelope(
                 base_job(%{sampled_targets: many_targets}),
                 ext_pipeline
               )

      assert byte_size(trimmed_encoded) <= 4096
      assert length(trimmed_env["sampled_targets"]) < 50
      assert trimmed_env["sampled_targets"] != []
    end

    test "hydrates pipeline_config from VantagePipeline parameter_overrides (both Reconciler-wrapped and direct) and merges stored payload" do
      wrapped_pipeline =
        struct(VantagePipeline, %{
          pipeline_id: "io.serviceradar.vantage-alpr.vehicle-plate",
          version: "1.0.0",
          runner: :external_worker,
          capability: "vantage.alpr.v1",
          source_mode: :recorded_block,
          input_mode: :detection_crop,
          signal_schema_id: "alpr_plate_read",
          signal_schema_version: "1.0.0",
          display_contract_id: "alpr_plate_read",
          parameter_overrides: %{
            "config" => %{"confidence_threshold" => 0.85},
            "enabled" => false
          }
        })

      job =
        base_job(%{
          job_payload: %{
            "pipeline_config" => %{"region" => "us-co", "confidence_threshold" => 0.5}
          }
        })

      assert {:ok, _subj, _encoded, wrapped_env} =
               VantagePipelineDispatcher.build_envelope(job, wrapped_pipeline)

      assert wrapped_env["pipeline_config"] == %{
               "region" => "us-co",
               "confidence_threshold" => 0.85
             }

      direct_pipeline =
        struct(VantagePipeline, %{
          pipeline_id: "io.serviceradar.vantage-alpr.vehicle-plate",
          version: "1.0.0",
          runner: :external_worker,
          capability: "vantage.alpr.v1",
          source_mode: :recorded_block,
          input_mode: :detection_crop,
          signal_schema_id: "alpr_plate_read",
          signal_schema_version: "1.0.0",
          display_contract_id: "alpr_plate_read",
          parameter_overrides: %{"min_confidence" => 0.77}
        })

      assert {:ok, _subj, _encoded, direct_env} =
               VantagePipelineDispatcher.build_envelope(base_job(%{}), direct_pipeline)

      assert direct_env["pipeline_config"] == %{"min_confidence" => 0.77}
    end
  end

  describe "relay/1 Ramp 1 -> Ramp 2 transition, HOLD, stale recovery, and recording_gone" do
    test "holds pending when no worker and nil fallback, then upgrades to Ramp 2 once worker registers" do
      pipeline = external_pipeline(fallback_runner: nil)
      job = base_job(%{attempt_count: 0, state: :pending})
      parent = self()

      # Pass 1: no workers -> held, never publishes, never increments attempt_count
      assert {:ok, hold_summary} =
               VantagePipelineDispatcher.relay(
                 enabled?: true,
                 now: @now,
                 pipeline: pipeline,
                 workers: [],
                 pending_jobs: [job],
                 expired_jobs: [],
                 catalog_entry: playable_entry(),
                 publisher: fn _subj, _body, _opts -> flunk("must not publish while held") end,
                 mark_dispatched_fn: fn _, _, _, _ -> flunk("must not mark_dispatched") end
               )

      assert hold_summary.held_count == 1
      assert hold_summary.dispatched_count == 0

      # Pass 2: v1 worker registers -> dispatches on Ramp 2 with deterministic Nats-Msg-Id
      assert {:ok, ramp2_summary} =
               VantagePipelineDispatcher.relay(
                 enabled?: true,
                 now: @now,
                 pipeline: pipeline,
                 workers: [ready_worker()],
                 pending_jobs: [job],
                 expired_jobs: [],
                 catalog_entry: playable_entry(),
                 publisher: fn subject, encoded, pub_opts ->
                   send(parent, {:published, subject, Jason.decode!(encoded), pub_opts})
                   {:ok, %{stream: "CAMERA_MEDIA_JOBS", seq: 11}}
                 end,
                 mark_dispatched_fn: fn _j, attrs, :pending, 0 ->
                   send(parent, {:marked, attrs})
                   {:ok, Map.merge(job, attrs)}
                 end
               )

      assert ramp2_summary.dispatched_count == 1
      assert_received {:published, "media.jobs.vantage.vantage_alpr_v1.v1", payload, pub_opts}
      assert pub_opts[:msg_id] == "vantage-job:#{@job_id}:0"
      assert payload["capability"] == "vantage.alpr.v1"
      assert_received {:marked, attrs}
      assert attrs.target_runner == "vantage.alpr.v1"
      assert attrs.subject == "media.jobs.vantage.vantage_alpr_v1.v1"
    end

    test "recovers expired dispatched jobs by falling back to Ramp 1 or marking failed_terminal at max_attempts" do
      pipeline = external_pipeline(fallback_runner: "camera_vlm")
      parent = self()

      recoverable_job =
        base_job(%{
          state: :dispatched,
          attempt_count: 1,
          max_attempts: 5,
          deadline_at: DateTime.shift(@now, second: -10)
        })

      exhausted_job =
        base_job(%{
          id: "00000000-0000-4000-8000-000000000202",
          state: :dispatched,
          attempt_count: 5,
          max_attempts: 5,
          deadline_at: DateTime.shift(@now, second: -10)
        })

      assert {:ok, summary} =
               VantagePipelineDispatcher.relay(
                 enabled?: true,
                 now: @now,
                 pipeline: pipeline,
                 workers: [],
                 pending_jobs: [],
                 expired_jobs: [recoverable_job, exhausted_job],
                 catalog_entry: playable_entry(),
                 publisher: fn subject, _encoded, pub_opts ->
                   send(parent, {:republished, subject, pub_opts})
                   {:ok, %{stream: "CAMERA_MEDIA_JOBS", seq: 22}}
                 end,
                 mark_dispatched_fn: fn _j, attrs, :dispatched, 1 ->
                   send(parent, {:redispatched_attrs, attrs})
                   {:ok, attrs}
                 end,
                 mark_failed_terminal_fn: fn j, err_class, :dispatched, 5 ->
                   send(parent, {:failed_terminal, j.id, err_class})
                   {:ok, j}
                 end,
                 tripwire_fn: fn check_id, healthy?, meta ->
                   send(parent, {:tripwire, check_id, healthy?, meta})
                   :ok
                 end
               )

      assert summary.dispatched_count == 1
      assert summary.failed_terminal_count == 1
      assert_received {:republished, "media.jobs.vantage.vlm.v1", pub_opts}
      assert pub_opts[:msg_id] == "vantage-job:#{@job_id}:1"
      assert_received {:redispatched_attrs, %{target_runner: "camera_vlm"}}

      assert_received {:failed_terminal, "00000000-0000-4000-8000-000000000202",
                       "max_deliver_exhausted"}

      assert_received {:tripwire, "camera_vantage_pipeline_dispatch", false, _meta}
    end

    test "cancels pending or expired jobs when catalog entry is recording_gone" do
      job = base_job(%{state: :pending})
      gone_entry = %{id: @cat_id, local_state: :reclaimed, archive_state: :not_required}
      parent = self()

      assert {:ok, summary} =
               VantagePipelineDispatcher.relay(
                 enabled?: true,
                 now: @now,
                 pipeline: external_pipeline(),
                 workers: [ready_worker()],
                 pending_jobs: [job],
                 expired_jobs: [],
                 catalog_entry: gone_entry,
                 publisher: fn _, _, _ -> flunk("must not publish recording_gone job") end,
                 mark_cancelled_fn: fn _j, "recording_gone", :pending, 0 ->
                   send(parent, :cancelled_gone)
                   {:ok, job}
                 end
               )

      assert summary.cancelled_count == 1
      assert_received :cancelled_gone
    end

    test "prioritizes :live over :backfill and bypasses >100 held head-of-line jobs via paginated exclusion" do
      held_pipeline =
        external_pipeline(%{
          pipeline_id: "io.serviceradar.vantage.held-pipe",
          version: "1.0.0",
          capability: "vantage.offline.v1",
          fallback_runner: nil
        })

      vlm_pipeline =
        external_pipeline(%{
          pipeline_id: "io.serviceradar.vantage.vlm-pipe",
          version: "1.0.0",
          runner: :camera_vlm,
          capability: "vantage.vlm.v1",
          fallback_runner: nil
        })

      held_backfill =
        for i <- 1..150 do
          base_job(%{
            id: "00000000-0000-4000-8000-#{String.pad_leading(Integer.to_string(i), 12, "0")}",
            pipeline_id: held_pipeline.pipeline_id,
            pipeline_version: held_pipeline.version,
            job_kind: :backfill,
            target_key: "held:#{i}",
            inserted_at: DateTime.shift(@now, second: i - 500)
          })
        end

      healthy_backfill =
        for i <- 1..5 do
          base_job(%{
            id: "00000000-0000-4000-8001-#{String.pad_leading(Integer.to_string(i), 12, "0")}",
            pipeline_id: vlm_pipeline.pipeline_id,
            pipeline_version: vlm_pipeline.version,
            job_kind: :backfill,
            target_key: "bf:#{i}",
            target_runner: "camera_vlm",
            subject: "media.jobs.vantage.vlm.backfill.v1",
            inserted_at: DateTime.shift(@now, second: i)
          })
        end

      healthy_live =
        for i <- 1..5 do
          base_job(%{
            id: "00000000-0000-4000-8002-#{String.pad_leading(Integer.to_string(i), 12, "0")}",
            pipeline_id: vlm_pipeline.pipeline_id,
            pipeline_version: vlm_pipeline.version,
            job_kind: :live,
            target_key: "live:#{i}",
            target_runner: "camera_vlm",
            subject: "media.jobs.vantage.vlm.v1",
            inserted_at: DateTime.shift(@now, second: 100 + i)
          })
        end

      all_jobs = held_backfill ++ healthy_backfill ++ healthy_live
      parent = self()

      pending_loader = fn limit, filter_opts ->
        kind = Keyword.fetch!(filter_opts, :job_kind)
        cursor = Keyword.get(filter_opts, :cursor)
        excluded = Keyword.get(filter_opts, :exclude_pipelines, MapSet.new())

        page =
          all_jobs
          |> Enum.filter(fn j ->
            j.job_kind == kind and
              not MapSet.member?(excluded, {j.pipeline_id, j.pipeline_version}) and
              case cursor do
                {c_ts, c_id} ->
                  DateTime.after?(j.inserted_at, c_ts) or
                    (DateTime.compare(j.inserted_at, c_ts) == :eq and j.id > c_id)

                nil ->
                  true
              end
          end)
          |> Enum.sort_by(&{DateTime.to_unix(&1.inserted_at, :microsecond), &1.id})
          |> Enum.take(limit)

        {:ok, page}
      end

      assert {:ok, summary} =
               VantagePipelineDispatcher.relay(
                 enabled?: true,
                 now: @now,
                 batch_size: 7,
                 workers: [],
                 catalog_entry: playable_entry(),
                 loaders: %{
                   pending_jobs_loader: pending_loader,
                   expired_jobs_loader: fn _now, _limit, _filter_opts -> {:ok, []} end,
                   pipeline_loader: fn job ->
                     if job.pipeline_id == held_pipeline.pipeline_id,
                       do: {:ok, held_pipeline},
                       else: {:ok, vlm_pipeline}
                   end
                 },
                 publisher: fn subject, encoded, _opts ->
                   decoded = Jason.decode!(encoded)
                   send(parent, {:dispatched, decoded["job_id"], subject})
                   {:ok, %{stream: "CAMERA_MEDIA_JOBS", seq: System.unique_integer([:positive])}}
                 end,
                 mark_dispatched_fn: fn job, attrs, :pending, 0 ->
                   {:ok, Map.merge(job, attrs)}
                 end
               )

      assert summary.dispatched_count == 7

      dispatched =
        for _ <- 1..7 do
          assert_received {:dispatched, id, subject}
          {id, subject}
        end

      # First 5 must be all 5 :live jobs, followed by the 2 oldest :backfill jobs
      assert dispatched |> Enum.take(5) |> Enum.map(&elem(&1, 1)) ==
               List.duplicate("media.jobs.vantage.vlm.v1", 5)

      assert dispatched |> Enum.drop(5) |> Enum.map(&elem(&1, 1)) ==
               List.duplicate("media.jobs.vantage.vlm.backfill.v1", 2)
    end

    test "requeues expired held dispatched jobs via :requeue_pending without double-counting in the same tick" do
      pipeline = external_pipeline(fallback_runner: nil)
      parent = self()

      expired_held_job =
        base_job(%{
          id: @job_id,
          state: :dispatched,
          attempt_count: 1,
          max_attempts: 5,
          deadline_at: DateTime.shift(@now, second: -15)
        })

      assert {:ok, summary} =
               VantagePipelineDispatcher.relay(
                 enabled?: true,
                 now: @now,
                 pipeline: pipeline,
                 workers: [],
                 expired_jobs: [expired_held_job],
                 # Simulate loader returning the same job if it were re-queried in pending phase
                 pending_jobs: [Map.put(expired_held_job, :state, :pending)],
                 catalog_entry: playable_entry(),
                 publisher: fn _s, _b, _o -> flunk("must not publish held expired job") end,
                 mark_pending_fn: fn job, error_class, :dispatched, 1 ->
                   send(parent, {:requeued, job.id, error_class})

                   {:ok,
                    Map.merge(job, %{
                      state: :pending,
                      deadline_at: nil,
                      last_error_class: error_class
                    })}
                 end
               )

      assert summary.held_count == 1
      assert summary.dispatched_count == 0
      assert_received {:requeued, @job_id, "no_eligible_worker"}
    end

    test "marks :envelope_too_large jobs failed_terminal and rejects invalid PubAcks fail-closed" do
      pipeline =
        external_pipeline(%{
          runner: :camera_vlm,
          roi_polygons:
            for i <- 1..120 do
              %{"points" => [[0.01, 0.01], [0.02 + i * 0.001, 0.01], [0.02, 0.03]]}
            end
        })

      oversized_job = base_job(%{target_runner: "camera_vlm", state: :pending})
      parent = self()

      assert {:ok, large_summary} =
               VantagePipelineDispatcher.relay(
                 enabled?: true,
                 now: @now,
                 pipeline: pipeline,
                 pending_jobs: [oversized_job],
                 expired_jobs: [],
                 catalog_entry: playable_entry(),
                 publisher: fn _s, _b, _o -> flunk("must not publish oversized envelope") end,
                 mark_failed_terminal_fn: fn j, "envelope_too_large", :pending, 0 ->
                   send(parent, {:terminal_oversized, j.id})
                   {:ok, j}
                 end,
                 tripwire_fn: fn _check, false, meta ->
                   send(parent, {:tripwire_oversized, meta["error_class"]})
                   :ok
                 end
               )

      assert large_summary.failed_terminal_count == 1
      assert large_summary.publish_error == nil
      assert_received {:terminal_oversized, @job_id}
      assert_received {:tripwire_oversized, "envelope_too_large"}

      small_pipeline = external_pipeline(%{runner: :camera_vlm, roi_polygons: []})
      small_job = base_job(%{target_runner: "camera_vlm", state: :pending})

      for bad_ack <- [
            {:ok, %{stream: "WRONG_STREAM", seq: 1}},
            {:ok, %{stream: "CAMERA_MEDIA_JOBS", seq: 0}},
            {:ok, :ack}
          ] do
        assert {:ok, err_summary} =
                 VantagePipelineDispatcher.relay(
                   enabled?: true,
                   now: @now,
                   pipeline: small_pipeline,
                   pending_jobs: [small_job],
                   expired_jobs: [],
                   catalog_entry: playable_entry(),
                   publisher: fn _s, _b, _o -> bad_ack end,
                   mark_dispatched_fn: fn _, _, _, _ ->
                     flunk("must not mark_dispatched on invalid PubAck #{inspect(bad_ack)}")
                   end
                 )

        assert {:invalid_puback, ^bad_ack} = err_summary.publish_error
        assert err_summary.dispatched_count == 0
      end
    end
  end

  describe "VantageTriggerAdmitter dispatch nudge" do
    test "invokes dispatch_enqueuer after admitting jobs unless nudge_dispatch?: false" do
      parent = self()

      entry =
        struct(ServiceRadar.Camera.RecordingCatalogEntry, %{
          id: @cat_id,
          recording_block_id: @job_id,
          camera_source_id: @cam_id,
          stream_profile_id: @prof_id,
          descriptor_sha256: @digest,
          local_state: :present,
          archive_state: :not_required,
          media_start_ns: 1_000_000_000,
          timeline_start_us: 1_760_000_000_000_000,
          timeline_end_us: 1_760_000_010_000_000
        })

      pipeline =
        external_pipeline(%{
          trigger_kind: :on_sealed_block,
          input_mode: :full_frame,
          fallback_runner: "camera_vlm"
        })

      descriptor = %{
        "fragments" => [%{"sequence" => 0, "has_idr" => true, "start_ns" => 1_000_000_000}]
      }

      assert {:ok, [_job]} =
               VantageTriggerAdmitter.admit_for_sealed_block(
                 entry,
                 descriptor,
                 enabled?: true,
                 pipelines: [pipeline],
                 source: %{id: @cam_id, metadata: %{}},
                 recent_job_count_fn: fn _, _ -> 0 end,
                 workers: [],
                 enqueue_fn: fn attrs -> {:ok, attrs} end,
                 dispatch_enqueuer: fn ->
                   send(parent, :nudged)
                   :ok
                 end
               )

      assert_received :nudged

      assert {:ok, [_job]} =
               VantageTriggerAdmitter.admit_for_sealed_block(
                 entry,
                 descriptor,
                 enabled?: true,
                 nudge_dispatch?: false,
                 pipelines: [pipeline],
                 source: %{id: @cam_id, metadata: %{}},
                 recent_job_count_fn: fn _, _ -> 0 end,
                 workers: [],
                 enqueue_fn: fn attrs -> {:ok, attrs} end,
                 dispatch_enqueuer: fn -> flunk("must not nudge when nudge_dispatch?: false") end
               )
    end
  end

  defp external_pipeline(overrides \\ %{}) do
    Map.merge(
      %{
        id: Ecto.UUID.generate(),
        pack_id: "vantage-alpr",
        pipeline_id: "io.serviceradar.vantage-alpr.vehicle-plate",
        version: "1.0.0",
        enabled: true,
        runner: :external_worker,
        capability: "vantage.alpr.v1",
        fallback_runner: nil,
        source_mode: :recorded_block,
        trigger_kind: :on_stage1_detection,
        input_mode: :detection_crop,
        roi_polygons: [],
        crop_policy: %{
          "padding_ratio" => 0.15,
          "min_bbox_width_px" => 96,
          "max_dimension" => 640,
          "max_bytes" => 98_304
        },
        signal_schema_id: "alpr_plate_read",
        signal_schema_version: "1.0.0",
        display_contract_id: "alpr_plate_read",
        budget_ms: 4500,
        max_jobs_per_minute: 60,
        max_frames_per_track: 3,
        camera_selector: %{"mode" => "all"},
        object_classes: [],
        min_confidence: nil,
        pipeline_config: %{"regions" => ["us"]},
        vlm_config: %{}
      },
      Map.new(overrides)
    )
  end

  defp ready_worker(overrides \\ %{}) do
    Map.merge(
      %{
        worker_id: "alpr-worker-01",
        worker_kind: :external_rust,
        capabilities: ["vantage.alpr.v1"],
        supported_source_modes: ["recorded_block"],
        health: :ready,
        active_jobs: 0,
        max_concurrency: 4,
        expires_at: DateTime.shift(@now, second: 30)
      },
      overrides
    )
  end

  defp playable_entry do
    %{
      id: @cat_id,
      local_state: :present,
      archive_state: :not_required,
      time_basis: :received
    }
  end

  defp base_job(overrides) do
    Map.merge(
      %{
        id: @job_id,
        pipeline_id: "io.serviceradar.vantage-alpr.vehicle-plate",
        pipeline_version: "1.0.0",
        catalog_entry_id: @cat_id,
        camera_source_id: @cam_id,
        stream_profile_id: @prof_id,
        target_key: "track:7",
        job_kind: :live,
        state: :pending,
        attempt_count: 0,
        max_attempts: 5,
        target_runner: "vantage.alpr.v1",
        subject: "media.jobs.vantage.vantage_alpr_v1.v1",
        descriptor_sha256: @digest,
        sampled_targets: [],
        job_payload: %{},
        deadline_at: DateTime.shift(@now, second: 30)
      },
      overrides
    )
  end
end
