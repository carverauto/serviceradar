defmodule ServiceRadar.Storage.StorageEntitlementsUnitTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Camera.CameraRecordingPolicies
  alias ServiceRadar.Camera.CameraRecordingPolicy
  alias ServiceRadar.Camera.RecordingArchiveSettings
  alias ServiceRadar.Camera.RecordingHolds
  alias ServiceRadar.Storage.StorageEntitlement
  alias ServiceRadar.Storage.StorageEntitlements
  alias ServiceRadar.Storage.StorageUsageReports

  @moduletag :db_free

  @deployment_ref "00000000-0000-4000-8000-000000000901"

  defp valid_entitlement_doc(overrides \\ %{}) do
    base = %{
      "schema_version" => 1,
      "deployment_ref" => @deployment_ref,
      "revision" => 7,
      "issued_at" => "2026-11-17T10:00:00Z",
      "consumers" => %{
        "recordings" => %{
          "enabled" => true,
          "allocation_bytes" => 500_000_000_000,
          "overage" => %{"mode" => "off"},
          "capacity_policy" => "reap_oldest",
          "retention" => %{"max_days" => 365, "default_days" => 30},
          "limits" => %{"max_recording_cameras" => 4}
        }
      }
    }

    Map.merge(base, overrides)
  end

  defp entitlement_struct(attrs \\ %{}) do
    base = %StorageEntitlement{
      id: "deployment",
      schema_version: 1,
      deployment_ref: @deployment_ref,
      generation: 1,
      revision: 7,
      document_sha256: String.duplicate("a", 64),
      issued_at: ~U[2026-11-17 10:00:00.000000Z],
      applied_at: ~U[2026-11-17 10:00:05.000000Z],
      recordings_present: true,
      recordings_enabled: true,
      recordings_allocation_bytes: 500_000_000_000,
      recordings_overage_mode: :off,
      recordings_overage_cap_bytes: nil,
      recordings_capacity_policy: :reap_oldest,
      recordings_retention_max_days: 365,
      recordings_retention_default_days: 30,
      recordings_max_cameras: 2,
      recordings_pending: nil,
      warehouse_present: false,
      warehouse_enabled: false,
      warehouse_consumer: nil
    }

    Map.merge(base, attrs)
  end

  defp manager_actor do
    %{
      id: "operator-entitlement-unit",
      role: :admin,
      permissions:
        MapSet.new([
          "settings.recording.view",
          "settings.recording.manage",
          "settings.recording.operate",
          "settings.credentials.manage"
        ])
    }
  end

  test "F.3/F.4: validate_document strictly validates schema v1 and refuses unknown fields at every level" do
    assert {:ok, parsed} = StorageEntitlements.validate_document(valid_entitlement_doc())
    assert parsed.revision == 7
    assert parsed.recordings.enabled == true
    assert parsed.recordings.allocation_bytes == 500_000_000_000
    assert parsed.recordings.overage_mode == :off
    assert parsed.recordings.capacity_policy == :reap_oldest
    assert parsed.recordings.retention_max_days == 365
    assert parsed.recordings.max_recording_cameras == 4
    assert String.length(parsed.document_sha256) == 64

    # Missing "recordings" consumer is treated as enabled: false (design.md:2509)
    warehouse_only =
      valid_entitlement_doc(%{
        "consumers" => %{
          "warehouse" => %{
            "enabled" => true,
            "allocation_bytes" => 100_000_000_000,
            "overage" => %{"mode" => "metered", "cap_bytes" => 200_000_000_000},
            "capacity_policy" => "reap_oldest",
            "retention" => %{"max_days" => 90, "default_days" => 30}
          }
        }
      })

    assert {:ok, parsed_wh} = StorageEntitlements.validate_document(warehouse_only)
    assert parsed_wh.recordings.present? == false
    assert parsed_wh.recordings.enabled == false
    assert parsed_wh.warehouse.present? == true
    assert parsed_wh.warehouse.enabled == true

    # Unknown schema version and unknown fields at every nesting level are refused
    invalid_cases = [
      valid_entitlement_doc(%{"schema_version" => 2}),
      Map.put(valid_entitlement_doc(), "unknown_top", true),
      valid_entitlement_doc(%{"consumers" => %{"analytics" => %{"enabled" => true}}}),
      put_in(valid_entitlement_doc(), ["consumers", "recordings", "unknown_rec"], 1),
      put_in(valid_entitlement_doc(), ["consumers", "recordings", "overage", "extra"], 1),
      put_in(valid_entitlement_doc(), ["consumers", "recordings", "retention", "extra"], 1),
      put_in(valid_entitlement_doc(), ["consumers", "recordings", "limits", "extra"], 1),
      put_in(
        valid_entitlement_doc(),
        ["consumers", "recordings", "pending"],
        %{"effective_at" => "2026-11-18T10:00:00Z", "allocation_bytes" => 100, "extra" => 1}
      ),
      put_in(
        valid_entitlement_doc(),
        ["consumers", "recordings", "pending"],
        %{
          "effective_at" => "2026-11-18T10:00:00Z",
          "retention" => %{"max_days" => 30, "extra" => 1}
        }
      )
    ]

    for bad_doc <- invalid_cases do
      assert {:error, :invalid_storage_entitlement} =
               StorageEntitlements.validate_document(bad_doc)
    end
  end

  test "F.4/F.9: self-hosted install is unaffected while hosted install holds archive jobs until entitlement is applied" do
    # Self-hosted: unaffected even if no entitlement row exists
    self_state =
      StorageEntitlements.effective_state(
        hosted_install?: false,
        loaders: %{entitlement_loader: fn -> {:ok, nil} end}
      )

    assert self_state.hosted? == false
    assert self_state.applied? == false
    assert self_state.waiting_for_entitlement? == false
    assert self_state.archive_jobs_held? == false

    assert {false, nil} =
             StorageEntitlements.archive_uploads_held?(
               hosted_install?: false,
               loaders: %{entitlement_loader: fn -> {:ok, nil} end}
             )

    # Self-hosted refuses apply_document
    assert {:error, :self_hosted_install} =
             StorageEntitlements.apply_document(
               %{deployment_ref: @deployment_ref, generation: 1},
               valid_entitlement_doc(),
               actor: SystemActor.system(:test),
               hosted_install?: false
             )

    # Hosted BEFORE first entitlement: waiting_for_entitlement? and archive_jobs_held? are true!
    hosted_waiting =
      StorageEntitlements.effective_state(
        hosted_install?: true,
        loaders: %{entitlement_loader: fn -> {:ok, nil} end}
      )

    assert hosted_waiting.hosted? == true
    assert hosted_waiting.applied? == false
    assert hosted_waiting.waiting_for_entitlement? == true
    assert hosted_waiting.archive_jobs_held? == true
    assert hosted_waiting.archive_jobs_hold_reason == :waiting_for_entitlement

    assert {true, :waiting_for_entitlement} =
             StorageEntitlements.archive_uploads_held?(
               hosted_install?: true,
               loaders: %{entitlement_loader: fn -> {:ok, nil} end}
             )

    # Suspension via RecordingControl durable stop holds archive jobs even after entitlement is applied
    ent = entitlement_struct()

    assert {true, :recording_suspended} =
             StorageEntitlements.archive_uploads_held?(
               hosted_install?: true,
               loaders: %{
                 entitlement_loader: fn -> {:ok, ent} end,
                 recording_control_loader: fn -> {:ok, %{stopped: true}} end
               }
             )
  end

  test "F.5/F.7/F.8: RecordingArchiveSettings & CameraRecordingPolicies enforce plan bounds, lowered max_days effective minimum, camera limits, and Cloud custody" do
    ent = entitlement_struct(%{recordings_retention_max_days: 365, recordings_max_cameras: 2})
    loaders = %{entitlement_loader: fn -> {:ok, ent} end}

    # Stored archive_retention_days = 400 before max_days lowered to 365:
    stored = %{RecordingArchiveSettings.default_settings() | archive_retention_days: 400}

    eff_ret =
      RecordingArchiveSettings.effective_archive_retention(
        stored,
        StorageEntitlements.effective_state(hosted_install?: true, loaders: loaders)
      )

    assert eff_ret.configured_days == 400
    assert eff_ret.effective_days == 365
    assert eff_ret.capped_by_plan? == true
    assert eff_ret.summary_label == "configured 400 days, effective 365 days (plan maximum)"

    # Saving > 365 days, :unlimited, or object budget/policy fields is refused with "limited by your plan"
    cs_over =
      RecordingArchiveSettings.preview_changeset(
        %{archive_retention_mode: :limited, archive_retention_days: 400},
        existing: stored,
        actor: manager_actor(),
        hosted_install?: true,
        loaders: loaders
      )

    refute cs_over.valid?
    assert Enum.any?(cs_over.errors, &(Exception.message(&1) =~ "limited by your plan"))

    cs_unlim =
      RecordingArchiveSettings.preview_changeset(
        %{archive_retention_mode: :unlimited, archive_retention_days: nil},
        existing: stored,
        actor: manager_actor(),
        hosted_install?: true,
        loaders: loaders
      )

    refute cs_unlim.valid?
    assert Enum.any?(cs_unlim.errors, &(Exception.message(&1) =~ "limited by your plan"))

    cs_budget =
      RecordingArchiveSettings.preview_changeset(
        %{
          object_budget_mode: :limited,
          object_budget_bytes: 100_000_000_000,
          object_capacity_policy: :stop_archiving
        },
        existing: stored,
        actor: manager_actor(),
        hosted_install?: true,
        loaders: loaders
      )

    refute cs_budget.valid?
    assert Enum.any?(cs_budget.errors, &(Exception.message(&1) =~ "limited by your plan"))

    # Watermarks and <= 365 days remain editable!
    cs_valid =
      RecordingArchiveSettings.preview_changeset(
        %{
          archive_retention_mode: :limited,
          archive_retention_days: 180,
          object_high_water_percent: 88,
          object_low_water_percent: 75
        },
        existing: stored,
        actor: manager_actor(),
        hosted_install?: true,
        loaders: loaders
      )

    assert cs_valid.valid?

    # Cloud-managed credential slot and non-operator ArchiveBinding cannot be replaced/cleared by operator
    cloud_secret_id = "00000000-0000-4000-8000-000000000501"
    cloud_binding_id = "00000000-0000-4000-8000-000000000502"

    cloud_settings = %{
      RecordingArchiveSettings.default_settings()
      | writer_credential_secret_id: cloud_secret_id,
        active_archive_binding_id: cloud_binding_id
    }

    cloud_loaders =
      Map.merge(loaders, %{
        secret_loader: fn ^cloud_secret_id ->
          {:ok,
           %{
             id: cloud_secret_id,
             name: "Cloud Writer",
             provider: "s3_compatible",
             credential_kind: :opaque,
             managed_by: :control_plane,
             rotation_state: :active
           }}
        end,
        binding_loader: fn id ->
          ref = if id == cloud_binding_id, do: "cloud:recordings-v1", else: "operator:custom"
          {:ok, %{id: id, provisioning_ref: ref}}
        end
      })

    cs_cloud_clear =
      RecordingArchiveSettings.preview_changeset(
        %{writer_credential_secret_id: nil, active_archive_binding_id: nil},
        existing: cloud_settings,
        actor: manager_actor(),
        hosted_install?: true,
        loaders: cloud_loaders
      )

    refute cs_cloud_clear.valid?

    assert Enum.any?(
             cs_cloud_clear.errors,
             &(Exception.message(&1) =~ "Managed by ServiceRadar Cloud")
           )

    # Camera limit (max_recording_cameras = 2): 3rd continuous policy is refused with "limited by your plan"
    cam1 = "00000000-0000-4000-8000-000000000601"
    cam2 = "00000000-0000-4000-8000-000000000602"
    cam3 = "00000000-0000-4000-8000-000000000603"
    prof3 = "00000000-0000-4000-8000-000000000703"

    policy_loaders = %{
      entitlement_loader: fn -> {:ok, ent} end,
      source_loader: fn id -> {:ok, %{id: id}} end,
      profile_loader: fn ^prof3 ->
        {:ok, %{id: prof3, camera_source_id: cam3, relay_eligible: true}}
      end,
      policies_loader: fn ->
        {:ok,
         [
           %CameraRecordingPolicy{
             id: "00000000-0000-7000-8000-000000000001",
             camera_source_id: cam1,
             mode: :continuous
           },
           %CameraRecordingPolicy{
             id: "00000000-0000-7000-8000-000000000002",
             camera_source_id: cam2,
             mode: :continuous
           }
         ]}
      end
    }

    cs_cam_limit =
      CameraRecordingPolicies.preview_changeset(
        %{
          camera_source_id: cam3,
          stream_profile_id: prof3,
          mode: :continuous,
          nvr_member: "nvr-0"
        },
        actor: manager_actor(),
        hosted_install?: true,
        loaders: policy_loaders
      )

    refute cs_cam_limit.valid?
    assert Enum.any?(cs_cam_limit.errors, &(Exception.message(&1) =~ "limited by your plan"))
  end

  test "F.4/F.5: pending decrease projects retention & deletion impact before effective_at and applies at effective_at" do
    t_eff = ~U[2026-11-18 12:00:00.000000Z]

    ent =
      entitlement_struct(%{
        recordings_allocation_bytes: 750_000_000_000,
        recordings_pending: %{
          "effective_at" => DateTime.to_iso8601(t_eff),
          "allocation_bytes" => 450_000_000_000,
          "retention" => %{"max_days" => 30}
        }
      })

    # 40 GB/day policy, 80% low water:
    # Before effective_at: low_water = 600 GB -> T = 15.0 days, steady = 600 GB
    # Pending: low_water = 360 GB -> T = 9.0 days, steady = 360 GB -> 240 GB projected deletion!
    before_state =
      StorageEntitlements.effective_state(
        hosted_install?: true,
        now: ~U[2026-11-18 11:59:59.000000Z],
        loaders: %{entitlement_loader: fn -> {:ok, ent} end},
        projection_inputs: %{
          policies: [%{id: "p1", rate_bytes_per_day: 40_000_000_000.0, retention_days: 60}],
          usage_bytes: 570_000_000_000,
          object_low_water_percent: 80,
          object_high_water_percent: 90
        }
      )

    assert before_state.recordings.allocation_bytes == 750_000_000_000
    assert before_state.recordings.retention_max_days == 365
    assert before_state.recordings.pending_applied? == false
    assert is_map(before_state.pending)
    assert_in_delta before_state.pending_projection.current_effective_days, 15.0, 0.001
    assert_in_delta before_state.pending_projection.projected_effective_days, 9.0, 0.001
    assert before_state.pending_projection.projected_bytes_to_delete == 240_000_000_000

    # At effective_at: pending applies automatically!
    after_state =
      StorageEntitlements.effective_state(
        hosted_install?: true,
        now: t_eff,
        loaders: %{entitlement_loader: fn -> {:ok, ent} end}
      )

    assert after_state.recordings.allocation_bytes == 450_000_000_000
    assert after_state.recordings.hard_limit_bytes == 450_000_000_000
    assert after_state.recordings.retention_max_days == 30
    assert after_state.recordings.pending_applied? == true
    assert is_nil(after_state.pending)
    assert is_nil(after_state.pending_projection)
  end

  test "F.6/F.9: StorageUsageReports bounds closed UTC days with zero camera names, and held_objects_manifest paginates deterministically" do
    now = ~U[2026-11-17 12:00:00Z]
    actor = SystemActor.system(:unit_test)

    # Rejects future, unclosed explicit end date, and > 31-day range
    assert {:error, :invalid_usage_date_range} =
             StorageUsageReports.query_closed_days(%{"from" => "2026-11-18"},
               actor: actor,
               now: now
             )

    assert {:error, :invalid_usage_date_range} =
             StorageUsageReports.query_closed_days(
               %{"from" => "2026-11-16", "to" => "2026-11-17"},
               actor: actor,
               now: now
             )

    assert {:error, :invalid_usage_date_range} =
             StorageUsageReports.query_closed_days(
               %{"from" => "2026-10-01", "to" => "2026-11-05"},
               actor: actor,
               now: now
             )

    binding_id = "00000000-0000-4000-8000-000000000801"
    receipt_id = "00000000-0000-4000-8000-000000000802"
    cam_id = "00000000-0000-4000-8000-000000000803"
    prof_id = "00000000-0000-4000-8000-000000000804"
    entry_id = "00000000-0000-7000-8000-000000000805"
    hold_id = "00000000-0000-7000-8000-000000000806"

    usage_loaders = %{
      settings_loader: fn ->
        {:ok,
         %{
           RecordingArchiveSettings.default_settings()
           | archive_enabled: true,
             active_archive_binding_id: binding_id,
             object_budget_mode: :limited,
             object_budget_bytes: 100_000_000_000,
             object_capacity_policy: :reap_oldest
         }}
      end,
      bindings_loader: fn ->
        {:ok,
         [%{id: binding_id, endpoint: "https://objects.example.com", bucket: "example-bucket"}]}
      end,
      receipts_loader: fn ->
        {:ok,
         [
           %{
             id: receipt_id,
             archive_binding_id: binding_id,
             objects: [
               %{
                 "name" => "init.mp4",
                 "key" => "rec/init.mp4",
                 "length" => 1000,
                 "sha256" => String.duplicate("b", 64)
               },
               %{
                 "name" => "part.m4s",
                 "key" => "rec/part.m4s",
                 "length" => 4000,
                 "sha256" => String.duplicate("c", 64)
               },
               %{
                 "name" => "desc.json",
                 "key" => "rec/desc.json",
                 "length" => 500,
                 "sha256" => String.duplicate("d", 64)
               }
             ]
           }
         ]}
      end,
      catalog_loader: fn ->
        {:ok,
         [
           %{
             id: entry_id,
             storage_id: "00000000-0000-4000-8000-000000000811",
             block_key: String.duplicate("e", 64),
             camera_source_id: cam_id,
             stream_profile_id: prof_id,
             timeline_start_us: 1_700_000_000_000_000,
             timeline_end_us: 1_700_000_060_000_000,
             local_state: :present,
             archive_state: :verified,
             archive_binding_id: binding_id,
             nvr_archive_receipt_id: receipt_id,
             sealed_at: ~U[2026-11-16 08:00:00Z],
             archived_at: ~U[2026-11-16 08:05:00Z]
           }
         ]}
      end,
      holds_loader: fn ->
        {:ok,
         [
           %{
             id: hold_id,
             camera_source_id: cam_id,
             stream_profile_id: prof_id,
             start_us: 1_700_000_000_000_000,
             end_us: 1_700_000_120_000_000,
             kind: :investigation,
             state: :accepted,
             accepted_at: ~U[2026-11-16 09:00:00Z],
             unavailable_blocks: []
           }
         ]}
      end,
      policies_loader: fn ->
        {:ok,
         [
           %{
             id: "00000000-0000-7000-8000-000000000809",
             camera_source_id: cam_id,
             stream_profile_id: prof_id,
             camera_name: "SENSITIVE-LOBBY-CAM-NAME",
             mode: :continuous,
             storage: :local_and_archive,
             nominal_bitrate_bps: 2_000_000
           }
         ]}
      end
    }

    assert {:ok, report} =
             StorageUsageReports.query_closed_days(
               %{"from" => "2026-11-16"},
               actor: actor,
               now: now,
               hosted_install?: false,
               loaders: usage_loaders
             )

    encoded = Jason.encode!(report)
    refute encoded =~ "SENSITIVE-LOBBY-CAM-NAME"
    refute encoded =~ cam_id

    assert [
             %{
               "date" => "2026-11-16",
               "report_revision" => 1,
               "consumers" => %{"recordings" => rec}
             }
           ] =
             report["days"]

    assert rec["retained_bytes_end"] == 5500
    assert rec["added_bytes"] == 5500
    assert rec["held_bytes"] == 5500
    assert rec["object_count"] == 3
    assert [%{"policy_ref" => policy_ref}] = rec["rates"]
    assert policy_ref =~ ~r/\A[0-9a-f]{64}\z/

    # Held-object manifest via loaders
    assert {:ok, manifest} =
             RecordingHolds.held_objects_manifest(
               %{"limit" => 1},
               actor: actor,
               loaders: usage_loaders
             )

    assert manifest["held_block_count"] == 1
    assert is_nil(manifest["next_cursor"])
    assert [%{"hold_id" => ^hold_id, "blocks" => [%{"objects" => objs}]}] = manifest["holds"]
    assert length(objs) == 3
    assert Enum.map(objs, & &1["length"]) == [1000, 4000, 500]
    assert Enum.map(objs, & &1["size"]) == [1000, 4000, 500]

    assert {:error, :invalid_hold_manifest_cursor} =
             RecordingHolds.held_objects_manifest(%{"cursor" => "not-valid"},
               actor: actor,
               loaders: usage_loaders
             )
  end
end
