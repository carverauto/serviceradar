defmodule ServiceRadar.Camera.CameraRecordingPolicyAndHealthTest do
  use ExUnit.Case, async: true

  alias Ash.Error.Forbidden
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Camera.CameraRecordingPolicies
  alias ServiceRadar.Camera.CameraRecordingPolicy
  alias ServiceRadar.Camera.NVRStorageSettings
  alias ServiceRadar.Camera.RecordingArchiveSettings
  alias ServiceRadar.Camera.RecordingBlocks
  alias ServiceRadar.Camera.RecordingHealth
  alias ServiceRadar.Camera.RecordingHolds

  @gb 1_000_000_000
  @mib 1_048_576

  describe "CameraRecordingPolicies profile_estimate/1, preview_changeset/2, and what_if_preview/2" do
    test "computes A1 profile bitrate, bytes/day, 1.02 archive overhead, and block-closing bounds" do
      # Low bitrate (120 kbit/s = 15 kB/s): closes on 270s time bound -> 320 blocks/day
      low =
        CameraRecordingPolicies.profile_estimate(%{
          metadata: %{"observed_bitrate_bps" => 120_000}
        })

      assert low.bitrate_bps == 120_000
      assert low.basis == :observed
      assert low.bytes_per_sec == 15_000.0
      assert low.bytes_per_day == 15_000.0 * 86_400
      assert_in_delta low.archive_bytes_per_day, 15_000.0 * 86_400 * 1.02, 1.0
      assert low.block_seconds == 270.0
      assert_in_delta low.blocks_per_day, 320.0, 0.001

      # 4 Mbit/s nominal (500 kB/s): closes on 12 MiB byte bound (~25.165s -> ~3,433.2 blocks/day)
      high =
        CameraRecordingPolicies.profile_estimate(%{
          metadata: %{"nominal_bitrate_kbps" => 4_000}
        })

      assert high.bitrate_bps == 4_000_000
      assert high.basis == :nominal
      assert high.bytes_per_sec == 500_000.0
      assert_in_delta high.block_seconds, 12 * @mib / 500_000.0, 0.001
      assert_in_delta high.blocks_per_day, 86_400.0 / (12 * @mib / 500_000.0), 0.01

      # Never streamed / unknown bitrate
      unknown = CameraRecordingPolicies.profile_estimate(%{metadata: %{}})

      assert unknown == %{
               bitrate_bps: nil,
               basis: :unknown,
               bytes_per_sec: nil,
               bytes_per_day: nil,
               archive_bytes_per_day: nil,
               block_seconds: nil,
               blocks_per_day: nil
             }
    end

    test "validates relay_eligible profile, camera ownership, nvr_member format, and retention override pairs" do
      cam_a = "00000000-0000-4000-8000-000000000010"
      cam_b = "00000000-0000-4000-8000-000000000011"
      prof_ok = "00000000-0000-4000-8000-000000000020"
      prof_ineligible = "00000000-0000-4000-8000-000000000021"
      prof_other_cam = "00000000-0000-4000-8000-000000000022"

      loaders = %{
        source_loader: fn
          ^cam_a -> {:ok, %{id: cam_a}}
          _ -> {:ok, nil}
        end,
        profile_loader: fn
          ^prof_ok ->
            {:ok, %{id: prof_ok, camera_source_id: cam_a, relay_eligible: true}}

          ^prof_ineligible ->
            {:ok, %{id: prof_ineligible, camera_source_id: cam_a, relay_eligible: false}}

          ^prof_other_cam ->
            {:ok, %{id: prof_other_cam, camera_source_id: cam_b, relay_eligible: true}}

          _ ->
            {:ok, nil}
        end,
        settings_loader: fn ->
          {:ok, %{RecordingArchiveSettings.default_settings() | archive_enabled: true}}
        end
      }

      admin = %{
        id: "admin-pol",
        role: :admin,
        permissions: MapSet.new(["settings.recording.manage"])
      }

      # Non-relay-eligible profile rejected
      ineligible_cs =
        CameraRecordingPolicies.preview_changeset(
          %{
            camera_source_id: cam_a,
            stream_profile_id: prof_ineligible,
            mode: :continuous,
            nvr_member: "nvr-0"
          },
          actor: admin,
          loaders: loaders
        )

      refute ineligible_cs.valid?
      assert Enum.any?(ineligible_cs.errors, &(Exception.message(&1) =~ "relay-eligible"))

      # Profile belonging to different camera rejected
      wrong_cam_cs =
        CameraRecordingPolicies.preview_changeset(
          %{
            camera_source_id: cam_a,
            stream_profile_id: prof_other_cam,
            mode: :off
          },
          actor: admin,
          loaders: loaders
        )

      refute wrong_cam_cs.valid?
      assert Enum.any?(wrong_cam_cs.errors, &(Exception.message(&1) =~ "does not belong"))

      # Continuous mode requires valid [a-z0-9][a-z0-9-]{0,62} nvr_member
      missing_member_cs =
        CameraRecordingPolicies.preview_changeset(
          %{
            camera_source_id: cam_a,
            stream_profile_id: prof_ok,
            mode: :continuous,
            nvr_member: ""
          },
          actor: admin,
          loaders: loaders
        )

      refute missing_member_cs.valid?
      assert Enum.any?(missing_member_cs.errors, &(Map.get(&1, :field) == :nvr_member))

      bad_member_cs =
        CameraRecordingPolicies.preview_changeset(
          %{
            camera_source_id: cam_a,
            stream_profile_id: prof_ok,
            mode: :continuous,
            nvr_member: "UPPERCASE_INVALID"
          },
          actor: admin,
          loaders: loaders
        )

      refute bad_member_cs.valid?
      assert Enum.any?(bad_member_cs.errors, &(Map.get(&1, :field) == :nvr_member))

      # Override mode+days validation
      bad_override_cs =
        CameraRecordingPolicies.preview_changeset(
          %{
            camera_source_id: cam_a,
            stream_profile_id: prof_ok,
            mode: :continuous,
            nvr_member: "nvr-0",
            archive_retention_override_mode: :limited,
            archive_retention_days_override: 5_000
          },
          actor: admin,
          loaders: loaders
        )

      refute bad_override_cs.valid?

      assert Enum.any?(
               bad_override_cs.errors,
               &(Map.get(&1, :field) == :archive_retention_days_override)
             )

      # Valid create defaults storage to :local_and_archive when archive_enabled == true
      valid_cs =
        CameraRecordingPolicies.preview_changeset(
          %{
            camera_source_id: cam_a,
            stream_profile_id: prof_ok,
            mode: :continuous,
            nvr_member: "nvr-0",
            archive_retention_override_mode: :limited,
            archive_retention_days_override: 14
          },
          actor: admin,
          loaders: loaders
        )

      assert valid_cs.valid?
      assert Ash.Changeset.get_attribute(valid_cs, :storage) == :local_and_archive

      assert CameraRecordingPolicy.default_storage_for_settings(%{archive_enabled: false}) ==
               :local_only
    end

    test "what_if_preview/2 projects local window, ~2x capture throughput, blocks/day, session limit 16, and object retention with warnings (C1a & C3a)" do
      unpermitted = %{id: "u-none", role: :viewer, permissions: MapSet.new()}

      assert {:error, %Forbidden{}} =
               CameraRecordingPolicies.what_if_preview(%{}, actor: unpermitted)

      viewer = %{
        id: "u-view",
        role: :viewer,
        permissions: MapSet.new(["settings.recording.view"])
      }

      settings = %{
        RecordingArchiveSettings.default_settings()
        | archive_enabled: true,
          active_archive_binding_id: "00000000-0000-4000-8000-000000000099",
          local_window_alert_mode: :enabled,
          local_window_alert_seconds: 21_600,
          object_budget_mode: :limited,
          object_budget_bytes: 10_000 * @gb,
          object_high_water_percent: 90,
          object_low_water_percent: 80,
          object_capacity_policy: :reap_oldest,
          archive_retention_mode: :limited,
          archive_retention_days: 60
      }

      # 16 existing continuous 2 Mbit/s cameras on nvr-0
      existing_policies =
        for idx <- 1..16 do
          %{
            id: "00000000-0000-4000-8000-#{String.pad_leading(Integer.to_string(idx), 12, "0")}",
            camera_source_id:
              "00000000-0000-4000-8001-#{String.pad_leading(Integer.to_string(idx), 12, "0")}",
            stream_profile_id:
              "00000000-0000-4000-8002-#{String.pad_leading(Integer.to_string(idx), 12, "0")}",
            mode: :continuous,
            nvr_member: "nvr-0",
            storage: :local_and_archive,
            archive_retention_override_mode: :inherit,
            archive_retention_days_override: nil,
            stream_profile: %{
              id:
                "00000000-0000-4000-8002-#{String.pad_leading(Integer.to_string(idx), 12, "0")}",
              metadata: %{"observed_bitrate_bps" => 2_000_000}
            }
          }
        end

      # Adding 17th camera (4 Mbit/s, limited 7d override) on nvr-0 with 16.8 GiB budget:
      candidate = %{
        camera_source_id: "00000000-0000-4000-8001-000000000099",
        stream_profile_id: "00000000-0000-4000-8002-000000000099",
        mode: :continuous,
        nvr_member: "nvr-0",
        storage: :local_and_archive,
        archive_retention_override_mode: :limited,
        archive_retention_days_override: 7,
        stream_profile: %{
          id: "00000000-0000-4000-8002-000000000099",
          metadata: %{"observed_bitrate_bps" => 4_000_000}
        }
      }

      assert {:ok, preview} =
               CameraRecordingPolicies.what_if_preview(candidate,
                 actor: viewer,
                 settings: settings,
                 local_budget_bytes: 16_800_000_000,
                 measured_archive_goodput_bytes_per_sec: 3_000_000.0,
                 loaders: %{
                   policies_loader: fn -> {:ok, existing_policies} end
                 }
               )

      # 17 continuous sessions > 16 limit
      assert preview.projected_sessions == 17
      assert preview.max_sessions == 16
      assert preview.sessions_exceed_limit? == true

      # Capture rate = 16 * 250 kB/s + 500 kB/s = 4,500,000 B/s; provider throughput = 2x = 9,000,000 B/s
      assert_in_delta preview.archive_capture_rate_bytes_per_sec, 4_500_000.0, 1.0
      assert_in_delta preview.provider_throughput_needed_bytes_per_sec, 9_000_000.0, 1.0
      assert_in_delta preview.measured_provider_throughput_bytes_per_sec, 6_000_000.0, 1.0
      assert preview.throughput_exceeds_measured? == true

      # Local window on 16.8 GB budget (low water 13.44 GB) / 4.5 MB/s ~= 2,986 s (< 6h alert 21,600s)
      assert_in_delta preview.local_projection.window_low_seconds,
                      13_440_000_000 / 4_500_000.0,
                      1.0

      assert preview.local_projection.below_window_alert? == true

      # Object retention: 17 policies solved piecewise; candidate has 7d override (time-bound),
      # while 60d inherited policies are capacity-bound!
      assert preview.candidate_object_policy.configured_days == 7
      assert preview.candidate_object_policy.effective_days == 7
      assert preview.candidate_object_policy.binding_bound == :time
      assert preview.object_projection.capacity_days < 60

      assert :local_window_below_alert in preview.warnings
      assert :sessions_exceed_limit in preview.warnings
      assert :provider_throughput_exceeds_measured in preview.warnings
    end
  end

  describe "NVRStorageSettings bounds and C1a pinned-bytes floor" do
    test "derives chart install defaults (85% minus max(64 MiB, 1%)) and enforces pinned_bytes + 32 MiB floor without counting archive-verified holds" do
      # 100 GiB PVC -> 1% reserve (~1.073 GiB), ~83 GiB budget; 20 GiB -> ~204.8 MiB reserve
      d_100 = NVRStorageSettings.derive_install_defaults(100 * 1_073_741_824)
      assert d_100.reserve_bytes == div(100 * 1_073_741_824, 100)
      assert d_100.budget_bytes == div(100 * 1_073_741_824 * 85, 100) - d_100.reserve_bytes

      d_small = NVRStorageSettings.derive_install_defaults(2 * 1_073_741_824)
      assert d_small.reserve_bytes == 67_108_864

      storage_id = "00000000-0000-4000-8000-000000000301"
      cam_id = "00000000-0000-4000-8000-000000000302"

      settings = %{
        RecordingArchiveSettings.default_settings()
        | archive_enabled: true,
          local_only_full_policy: :overwrite_oldest
      }

      catalog_entries = [
        # Archive-verified & held -> pins :archive, so local copy (50 MiB) is EVICTABLE (0 local pin!)
        %{
          id: "00000000-0000-4000-8000-000000000401",
          camera_source_id: cam_id,
          storage_id: storage_id,
          block_key: String.duplicate("a", 64),
          timeline_start_us: 1_000_000,
          timeline_end_us: 5_000_000,
          local_state: :present,
          archive_state: :verified,
          media_bytes: 50 * @mib
        },
        # Pending upload -> P1 (20 MiB)
        %{
          id: "00000000-0000-4000-8000-000000000402",
          camera_source_id: cam_id,
          storage_id: storage_id,
          block_key: String.duplicate("b", 64),
          timeline_start_us: 5_000_000,
          timeline_end_us: 9_000_000,
          local_state: :present,
          archive_state: :pending,
          media_bytes: 20 * @mib
        },
        # Local-only & held under overwrite_oldest -> P4 (10 MiB)
        %{
          id: "00000000-0000-4000-8000-000000000403",
          camera_source_id: cam_id,
          storage_id: storage_id,
          block_key: String.duplicate("c", 64),
          timeline_start_us: 9_000_000,
          timeline_end_us: 12_000_000,
          local_state: :present,
          archive_state: :not_required,
          media_bytes: 10 * @mib
        },
        # Quarantined -> P5 (5 MiB)
        %{
          id: "00000000-0000-4000-8000-000000000404",
          storage_id: storage_id,
          block_key: String.duplicate("d", 64),
          local_state: :quarantined,
          archive_state: :not_required,
          quarantined_bytes: 5 * @mib
        }
      ]

      holds = [
        %{
          id: "00000000-0000-4000-8000-000000000501",
          camera_source_id: cam_id,
          stream_profile_id: nil,
          start_us: 0,
          end_us: 20_000_000,
          state: :accepted,
          unavailable_blocks: []
        }
      ]

      loaders = %{
        settings_loader: fn -> {:ok, settings} end,
        catalog_loader: fn -> {:ok, catalog_entries} end,
        holds_loader: fn -> {:ok, holds} end
      }

      pinned = NVRStorageSettings.pinned_bytes_for_storage(storage_id, loaders: loaders)
      # P1 (20 MiB) + P4 (10 MiB) + P5 (5 MiB) = 35 MiB; min_budget = 35 MiB + 32 MiB = 67 MiB
      assert pinned.p1 == 20 * @mib
      assert pinned.p4 == 10 * @mib
      assert pinned.p5 == 5 * @mib
      assert pinned.total_pinned_bytes == 35 * @mib
      assert pinned.min_budget_bytes == 67 * @mib

      admin = %{
        id: "admin-storage",
        role: :admin,
        permissions: MapSet.new(["settings.recording.manage"])
      }

      # Budget below 67 MiB refused, naming pinned_bytes
      below_floor_cs =
        NVRStorageSettings.preview_changeset(
          storage_id,
          %{budget_mode: :custom, budget_bytes: 66 * @mib},
          actor: admin,
          loaders: loaders
        )

      refute below_floor_cs.valid?

      assert Enum.any?(
               below_floor_cs.errors,
               &(Exception.message(&1) =~ "pinned_bytes=#{35 * @mib}")
             )

      # Budget above install_ceiling_bytes or volume_capacity - reserve refused
      above_ceiling_cs =
        NVRStorageSettings.preview_changeset(
          storage_id,
          %{budget_mode: :custom, budget_bytes: 900 * @mib},
          actor: admin,
          install_ceiling_bytes: 800 * @mib,
          loaders: loaders
        )

      refute above_ceiling_cs.valid?
      assert Enum.any?(above_ceiling_cs.errors, &(Exception.message(&1) =~ "install ceiling"))

      # Reserve below 64 MiB or above 10% of volume refused
      low_reserve_cs =
        NVRStorageSettings.preview_changeset(
          storage_id,
          %{reserve_mode: :custom, reserve_bytes: 32 * @mib},
          actor: admin,
          loaders: loaders
        )

      refute low_reserve_cs.valid?

      high_reserve_cs =
        NVRStorageSettings.preview_changeset(
          storage_id,
          %{reserve_mode: :custom, reserve_bytes: 250 * @mib},
          actor: admin,
          volume_capacity_bytes: 2_000 * @mib,
          loaders: loaders
        )

      refute high_reserve_cs.valid?

      assert Enum.any?(
               high_reserve_cs.errors,
               &(Exception.message(&1) =~ "10% of volume capacity")
             )

      # Valid custom budget & reserve within bounds passes
      valid_cs =
        NVRStorageSettings.preview_changeset(
          storage_id,
          %{
            budget_mode: :custom,
            budget_bytes: 500 * @mib,
            reserve_mode: :custom,
            reserve_bytes: 100 * @mib
          },
          actor: admin,
          install_ceiling_bytes: 800 * @mib,
          volume_capacity_bytes: 1_000 * @mib,
          loaders: loaders
        )

      assert valid_cs.valid?
    end
  end

  describe "RecordingHealth.summary/1 and default_summary/1 (E.3 / R.10)" do
    test "authorizes recording read permissions and aggregates backlog, gaps, per-storage windows, dispositions, and active alerts" do
      base_summary = RecordingHealth.default_summary()
      assert base_summary.archive_backlog.reconciler_status == :awaiting_reconciler
      assert base_summary.gaps_24h.total_24h_count == 0
      assert base_summary.alerts == []

      unpermitted = %{id: "u-none", role: :viewer, permissions: MapSet.new()}
      assert {:error, %Forbidden{}} = RecordingHealth.summary(actor: unpermitted)

      viewer = %{
        id: "u-health-viewer",
        role: :viewer,
        permissions: MapSet.new(["settings.recording.view"])
      }

      now = ~U[2026-11-16 18:00:00Z]
      now_us = DateTime.to_unix(now, :microsecond)
      sid = "00000000-0000-4000-8000-000000000601"
      cam_id = "00000000-0000-4000-8000-000000000602"
      prof_id = "00000000-0000-4000-8000-000000000603"
      binding_id = "00000000-0000-4000-8000-000000000604"

      settings = %{
        RecordingArchiveSettings.default_settings()
        | archive_enabled: true,
          active_archive_binding_id: binding_id,
          local_only_full_policy: :overwrite_oldest
      }

      catalog_entries = [
        %{
          id: "00000000-0000-4000-8000-000000000701",
          camera_source_id: cam_id,
          stream_profile_id: prof_id,
          storage_id: sid,
          block_key: String.duplicate("1", 64),
          local_state: :present,
          archive_state: :awaiting_binding,
          media_bytes: 4_000_000,
          sealed_at: DateTime.shift(now, minute: -90)
        },
        %{
          id: "00000000-0000-4000-8000-000000000702",
          camera_source_id: cam_id,
          stream_profile_id: prof_id,
          storage_id: sid,
          block_key: String.duplicate("2", 64),
          local_state: :present,
          archive_state: :failed_retryable,
          archive_binding_id: binding_id,
          media_bytes: 5_000_000,
          sealed_at: DateTime.shift(now, minute: -30)
        },
        %{
          id: "00000000-0000-4000-8000-000000000703",
          camera_source_id: cam_id,
          stream_profile_id: prof_id,
          storage_id: sid,
          block_key: String.duplicate("3", 64),
          local_state: :present,
          archive_state: :failed_terminal,
          archive_binding_id: binding_id,
          archive_last_error_class: "archive_receipt_conflict",
          media_bytes: 6_000_000,
          sealed_at: DateTime.shift(now, minute: -10)
        },
        %{
          id: "00000000-0000-4000-8000-000000000704",
          storage_id: sid,
          block_key: String.duplicate("4", 64),
          local_state: :quarantined,
          quarantine_reason: :unattributable,
          quarantined_bytes: 2_000_000,
          archive_state: :not_required,
          quarantine_receipt: %{"partition" => ".quarantine"},
          local_state_at: DateTime.shift(now, minute: -20)
        }
      ]

      gaps = [
        %{
          id: "00000000-0000-4000-8000-000000000801",
          camera_source_id: cam_id,
          storage_id: sid,
          start_us: now_us - 3_600_000_000,
          end_us: now_us - 3_500_000_000,
          reason: :handover_overflow,
          time_basis: :received
        },
        %{
          id: "00000000-0000-4000-8000-000000000802",
          camera_source_id: cam_id,
          storage_id: sid,
          start_us: now_us - 120_000_000,
          end_us: nil,
          reason: :nvr_refused,
          detail_class: "nvr_spool_budget_exhausted",
          time_basis: :received
        }
      ]

      dispositions = [
        %{
          operation_id: "00000000-0000-4000-8000-000000000901",
          storage_id: sid,
          block_key: String.duplicate("a", 64),
          copy: :local,
          reason: :budget,
          step: :verified_absent,
          inserted_at: DateTime.shift(now, hour: -1)
        },
        %{
          operation_id: "00000000-0000-4000-8000-000000000902",
          storage_id: sid,
          block_key: String.duplicate("b", 64),
          copy: :archive,
          reason: :object_retention,
          step: :failed,
          error_class: "provider_timeout",
          inserted_at: DateTime.shift(now, minute: -15)
        }
      ]

      storage_settings = [
        struct(NVRStorageSettings,
          storage_id: sid,
          budget_mode: :custom,
          budget_bytes: 50 * @gb,
          reserve_mode: :install_default,
          reserve_bytes: nil,
          revision: 2,
          applied_revision: 1,
          sync_state: :pending
        )
      ]

      policies = [
        %{
          id: "00000000-0000-4000-8000-000000000950",
          camera_source_id: cam_id,
          stream_profile_id: prof_id,
          mode: :continuous,
          nvr_member: "nvr-0",
          storage: :local_and_archive,
          stream_profile: %{id: prof_id, metadata: %{"observed_bitrate_bps" => 4_000_000}}
        }
      ]

      health_events = [
        # Latest event for nvr.<sid>.archive_backlog_age is unhealthy -> included!
        %{
          entity_type: :core,
          entity_id: "nvr.#{sid}.archive_backlog_age",
          new_state: :unhealthy,
          metadata: %{"severity" => "warning", "oldest_age_seconds" => 5400},
          recorded_at: DateTime.shift(now, minute: -5)
        },
        # Latest event for storage.recordings.object_used_percent is healthy -> auto-cleared!
        %{
          entity_type: :core,
          entity_id: "storage.recordings.object_used_percent",
          new_state: :healthy,
          metadata: %{},
          recorded_at: DateTime.shift(now, minute: -1)
        },
        %{
          entity_type: :core,
          entity_id: "storage.recordings.object_used_percent",
          new_state: :unhealthy,
          metadata: %{"severity" => "warning"},
          recorded_at: DateTime.shift(now, minute: -20)
        }
      ]

      assert {:ok, health} =
               RecordingHealth.summary(
                 actor: viewer,
                 now: now,
                 member_by_storage_id: %{sid => "nvr-0"},
                 loaders: %{
                   settings_loader: fn -> {:ok, settings} end,
                   catalog_loader: fn -> {:ok, catalog_entries} end,
                   gaps_loader: fn -> {:ok, gaps} end,
                   dispositions_loader: fn -> {:ok, dispositions} end,
                   storage_settings_loader: fn -> {:ok, storage_settings} end,
                   policies_loader: fn -> {:ok, policies} end,
                   health_events_loader: fn -> {:ok, health_events} end
                 }
               )

      assert health.archive_backlog.unarchived_count == 3
      assert health.archive_backlog.unarchived_bytes == 15_000_000
      assert health.archive_backlog.oldest_unarchived_age_seconds == 5_400
      assert health.archive_backlog.awaiting_binding_count == 1
      assert health.archive_backlog.failed_retryable_count == 1
      assert health.archive_backlog.failed_terminal_count == 1
      assert health.archive_backlog.quarantined_count == 1
      assert health.archive_backlog.quarantined_bytes == 2_000_000
      assert [%{quarantine_reason: :unattributable}] = health.archive_backlog.quarantined_entries

      assert health.gaps_24h.total_24h_count == 2
      assert health.gaps_24h.open_gaps_count == 1
      assert health.gaps_24h.by_reason.handover_overflow == 1
      assert health.gaps_24h.by_reason.nvr_refused == 1

      assert [member] = health.storage_members
      assert member.storage_id == sid
      assert member.member_name == "nvr-0"
      assert member.desired_settings.revision == 2
      assert member.desired_settings.applied_revision == 1
      assert member.pinned_bytes == 17_000_000
      assert member.local_present_bytes == 15_000_000
      assert member.assigned_continuous_cameras == 1
      assert member.live_status_state == :unknown_until_nvr_status

      assert health.retention_and_dispositions.recent_dispositions_24h == 2
      assert health.retention_and_dispositions.verified_absent_24h == 1
      assert health.retention_and_dispositions.failed_dispositions_24h == 1

      assert [%{error_class: "provider_timeout"}] =
               health.retention_and_dispositions.recent_failures_24h

      assert [%{check_id: check_id, severity: "warning"}] = health.alerts
      assert check_id == "nvr.#{sid}.archive_backlog_age"
    end

    test "R.3 & R.10: aggregates reservation resolution counts, unattributable evidence & disposition states, missing archive hold coverage, and enforces operate RBAC before DB I/O" do
      base_summary = RecordingHealth.default_summary()

      assert base_summary.reservations == %{
               total_count: 0,
               unresolved_count: 0,
               adopted_count: 0,
               block_absent_count: 0,
               unrecoverable_count: 0,
               unrecoverable_journal_count: 0,
               by_state: %{
                 unresolved: 0,
                 adopted: 0,
                 block_absent: 0,
                 unrecoverable_journal: 0
               },
               by_storage: %{}
             }

      assert base_summary.quarantined_entries == []
      assert base_summary.unattributable_blocks == []
      assert base_summary.missing_archive_entries == []

      now = ~U[2026-11-16 19:00:00Z]
      now_us = DateTime.to_unix(now, :microsecond)
      sid = "00000000-0000-4000-8000-000000000610"
      cam_id = "00000000-0000-4000-8000-000000000611"
      prof_id = "00000000-0000-4000-8000-000000000612"
      binding_id = "00000000-0000-4000-8000-000000000613"
      hold_id = "00000000-0000-4000-8000-000000000614"

      viewer = %{
        id: "u-viewer",
        role: :viewer,
        permissions: MapSet.new(["settings.recording.view"])
      }

      manager = %{
        id: "u-manager",
        role: :operator,
        permissions: MapSet.new(["settings.recording.view", "settings.recording.manage"])
      }

      operator = %{
        id: "u-operator",
        role: :operator,
        permissions: MapSet.new(["settings.recording.operate"])
      }

      sys = SystemActor.system(:recon_unit_test)

      # 1. Pure RBAC & history-pause guards before any DB connection is touched:
      synthetic_entry_id = "00000000-0000-4000-8000-000000000699"

      for non_operate <- [viewer, manager] do
        assert {:error, %Forbidden{}} =
                 RecordingHolds.request_quarantine_delete(
                   synthetic_entry_id,
                   %{confirm: true},
                   actor: non_operate
                 )

        assert {:error, %Forbidden{}} =
                 RecordingHolds.request_quarantine_export(
                   synthetic_entry_id,
                   %{},
                   actor: non_operate
                 )

        assert {:error, %Forbidden{}} =
                 RecordingHolds.accept_missing_archive_loss(
                   synthetic_entry_id,
                   %{},
                   actor: non_operate
                 )

        assert {:error, %Forbidden{}} =
                 RecordingHolds.request_missing_archive_rearchive(
                   synthetic_entry_id,
                   %{},
                   actor: non_operate
                 )

        assert {:error, %Forbidden{}} =
                 RecordingBlocks.freeze_historical(synthetic_entry_id, %{}, actor: non_operate)

        assert {:error, %Forbidden{}} =
                 RecordingBlocks.adopt_rotated_block(
                   synthetic_entry_id,
                   String.duplicate("a", 64),
                   %{},
                   actor: non_operate
                 )

        assert {:error, %Forbidden{}} =
                 RecordingBlocks.resolve_reservation_absent(
                   synthetic_entry_id,
                   actor: non_operate
                 )

        assert {:error, %Forbidden{}} =
                 RecordingBlocks.resolve_reservation_unrecoverable(
                   synthetic_entry_id,
                   actor: non_operate
                 )
      end

      assert {:error, :confirmation_required} =
               RecordingHolds.request_quarantine_delete(
                 synthetic_entry_id,
                 %{confirm: false},
                 actor: operator
               )

      assert {:error, :storage_awaiting_history_reconciliation} =
               RecordingBlocks.freeze_historical(
                 synthetic_entry_id,
                 %{},
                 actor: sys,
                 awaiting_history_reconciliation?: true
               )

      assert {:error, :storage_awaiting_history_reconciliation} =
               RecordingBlocks.adopt_rotated_block(
                 synthetic_entry_id,
                 String.duplicate("a", 64),
                 %{},
                 actor: sys,
                 awaiting_history_reconciliation?: true
               )

      # 2. RecordingHealth.summary/1 loader aggregation for R.3 & R.10:
      catalog_entries = [
        %{
          id: "00000000-0000-4000-8000-000000000711",
          storage_id: sid,
          block_key: String.duplicate("a", 64),
          local_state: :quarantined,
          quarantine_reason: :unattributable,
          quarantined_bytes: 3_000_000,
          quarantine_evidence: %{"reason" => "clock_epoch_mismatch"},
          quarantine_receipt: %{"partition_path" => ".quarantine/aaa"},
          archive_state: :not_required,
          local_state_at: DateTime.shift(now, minute: -10)
        },
        %{
          id: "00000000-0000-4000-8000-000000000712",
          storage_id: sid,
          block_key: String.duplicate("b", 64),
          local_state: :reclaiming,
          quarantine_reason: :unrecoverable_journal,
          quarantined_bytes: 1_500_000,
          operator_disposition_state: :delete_requested,
          operator_decision: %{"action" => "delete_intent", "actor_id" => "u-operator"},
          quarantine_receipt: %{"partition_path" => ".quarantine/bbb"},
          archive_state: :not_required,
          local_state_at: DateTime.shift(now, minute: -5)
        },
        %{
          id: "00000000-0000-4000-8000-000000000713",
          storage_id: sid,
          block_key: String.duplicate("c", 64),
          local_state: :reclaimed,
          quarantine_reason: :unattributable,
          quarantined_bytes: 900_000,
          operator_disposition_state: :disposed,
          quarantine_receipt: %{"partition_path" => ".quarantine/ccc"},
          archive_state: :not_required,
          local_state_at: DateTime.shift(now, minute: -30)
        },
        %{
          id: "00000000-0000-4000-8000-000000000714",
          camera_source_id: cam_id,
          stream_profile_id: prof_id,
          storage_id: sid,
          block_key: String.duplicate("d", 64),
          timeline_start_us: now_us - 600_000_000,
          timeline_end_us: now_us - 580_000_000,
          local_state: :present,
          archive_state: :missing,
          archive_binding_id: binding_id,
          archive_last_error_class: "object_changed",
          media_bytes: 8_000_000,
          sealed_at: DateTime.shift(now, minute: -10),
          archive_state_at: DateTime.shift(now, minute: -2)
        }
      ]

      holds = [
        %{
          id: hold_id,
          camera_source_id: cam_id,
          stream_profile_id: prof_id,
          start_us: now_us - 700_000_000,
          end_us: now_us - 500_000_000,
          kind: :investigation,
          state: :accepted,
          unavailable_blocks: []
        }
      ]

      reservation_rows = [
        %{storage_id: sid, reconciliation_state: :unresolved, count: 2},
        %{storage_id: sid, reconciliation_state: :adopted, count: 9},
        %{storage_id: sid, reconciliation_state: :block_absent, count: 1},
        %{storage_id: sid, reconciliation_state: :unrecoverable_journal, count: 3}
      ]

      assert {:ok, health} =
               RecordingHealth.summary(
                 actor: viewer,
                 now: now,
                 member_by_storage_id: %{sid => "nvr-0"},
                 loaders: %{
                   settings_loader: fn -> {:ok, RecordingArchiveSettings.default_settings()} end,
                   catalog_loader: fn -> {:ok, catalog_entries} end,
                   holds_loader: fn -> {:ok, holds} end,
                   reservations_loader: fn -> {:ok, reservation_rows} end
                 }
               )

      assert health.reservations.total_count == 15
      assert health.reservations.unresolved_count == 2
      assert health.reservations.adopted_count == 9
      assert health.reservations.block_absent_count == 1
      assert health.reservations.unrecoverable_count == 3
      assert health.reservations.unrecoverable_journal_count == 3
      assert health.storage_by_id[sid].reservations.unresolved_count == 2

      # Reclaimed quarantine entry is excluded; active quarantined + delete_requested remain visible:
      assert length(health.quarantined_entries) == 2
      assert health.unattributable_count == 1
      assert [unattr_item] = health.unattributable_blocks
      assert unattr_item.evidence_summary == "Unattributable: clock_epoch_mismatch"
      assert unattr_item.operator_disposition_state == :awaiting_operator

      deleting_item =
        Enum.find(health.quarantined_entries, &(&1.quarantine_reason == :unrecoverable_journal))

      assert deleting_item.operator_disposition_state == :delete_requested

      assert health.missing_archive_count == 1
      assert [missing_item] = health.missing_archive_entries
      assert missing_item.held? == true
      assert missing_item.hold_count == 1
      assert missing_item.hold_ids == [hold_id]
      assert missing_item.requires_hold_permission? == true
      assert missing_item.local_copy_present? == true
      assert missing_item.rearchive_eligible? == true
    end
  end
end
