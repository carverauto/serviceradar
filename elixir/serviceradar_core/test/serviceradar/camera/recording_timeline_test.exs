defmodule ServiceRadar.Camera.RecordingTimelineTest do
  use ExUnit.Case, async: true

  alias Ash.Error.Forbidden
  alias ServiceRadar.Camera.RecordingAccessAudit
  alias ServiceRadar.Camera.RecordingTimeline
  alias ServiceRadar.Camera.RecordingTimeline.RedactedCredential

  @camera_id "00000000-0000-4000-8000-000000000901"
  @profile_id "00000000-0000-4000-8000-000000000902"
  @unregistered_storage_id "00000000-0000-4000-8000-000000000903"
  @registered_storage_id "00000000-0000-4000-8000-000000000904"
  @binding_id "00000000-0000-4000-8000-000000000905"
  @base_us 1_763_300_000_000_000

  @footage_viewer %{
    id: "u-footage-viewer",
    role: :viewer,
    permissions: MapSet.new(["devices.view", "devices.cameras.recordings.view"])
  }

  @live_only_viewer %{
    id: "u-live-only",
    role: :viewer,
    permissions: MapSet.new(["devices.view", "devices.cameras.view"])
  }

  defp digest(tag) do
    :sha256 |> :crypto.hash("synthetic-timeline-#{tag}") |> Base.encode16(case: :lower)
  end

  defp synthetic_descriptor(tag, opts \\ []) do
    init_len = Keyword.get(opts, :init_length, 512)
    frag_len = Keyword.get(opts, :fragment_length, 4_096)

    %{
      "version" => 1,
      "format" => %{"codec" => "avc1.42c01f", "timescale" => 90_000},
      "init" => %{"length" => init_len, "sha256" => digest("#{tag}-init")},
      "media" => %{"length" => frag_len * 2, "sha256" => digest("#{tag}-media")},
      "fragments" => [
        %{
          "sequence" => 0,
          "offset" => 0,
          "length" => frag_len,
          "start_ns" => 0,
          "duration_ns" => 2_000_000_000,
          "sha256" => digest("#{tag}-frag-0")
        },
        %{
          "sequence" => 1,
          "offset" => frag_len,
          "length" => frag_len,
          "start_ns" => 2_000_000_000,
          "duration_ns" => 2_000_000_000,
          "sha256" => digest("#{tag}-frag-1")
        }
      ]
    }
  end

  describe "coverage/3 bounds, RBAC, R2 quarantine exclusion, copy states, provisional?, and time basis" do
    test "enforces 31-day span, bucket_count bounds, and recording-view RBAC" do
      over_31d_us = @base_us + 31 * 86_400 * 1_000_000 + 1

      assert {:error, :timeline_window_too_large} =
               RecordingTimeline.coverage(
                 @camera_id,
                 %{from_us: @base_us, to_us: over_31d_us},
                 actor: @footage_viewer,
                 loaders: %{catalog_loader: fn -> {:ok, []} end}
               )

      assert {:error, :invalid_timeline_window} =
               RecordingTimeline.coverage(
                 @camera_id,
                 %{from_us: @base_us, to_us: @base_us},
                 actor: @footage_viewer,
                 loaders: %{catalog_loader: fn -> {:ok, []} end}
               )

      for bad_buckets <- [0, -1, 1_441, "bad"] do
        assert {:error, :invalid_bucket_count} =
                 RecordingTimeline.coverage(
                   @camera_id,
                   %{from_us: @base_us, to_us: @base_us + 60_000_000, bucket_count: bad_buckets},
                   actor: @footage_viewer,
                   loaders: %{catalog_loader: fn -> {:ok, []} end}
                 )
      end

      assert {:error, %Forbidden{}} =
               RecordingTimeline.coverage(
                 @camera_id,
                 %{from_us: @base_us, to_us: @base_us + 60_000_000},
                 actor: @live_only_viewer,
                 loaders: %{catalog_loader: fn -> {:ok, []} end}
               )
    end

    test "excludes quarantined catalog rows, classifies copy states & provisional?, marks re-anchors, and reports received/unmeasured" do
      window_end = @base_us + 120_000_000

      entries = [
        # 1. local_and_archived on registered storage (provisional?: false)
        %{
          id: "00000000-0000-4000-8000-000000000911",
          recording_block_id: "00000000-0000-4000-8000-000000000921",
          camera_source_id: @camera_id,
          stream_profile_id: @profile_id,
          storage_id: @registered_storage_id,
          block_key: String.duplicate("1", 64),
          anchor_id: "anchor-1",
          reanchored: false,
          contiguous_with_previous: true,
          timeline_start_us: @base_us,
          timeline_end_us: @base_us + 10_000_000,
          media_start_ns: 0,
          media_end_ns: 10_000_000_000,
          fragment_count: 5,
          media_bytes: 1_000_000,
          local_state: :present,
          archive_state: :verified,
          archive_binding_id: @binding_id,
          time_basis: :received,
          time_uncertainty_us: nil
        },
        # 2. pending_archive on unregistered storage (provisional?: true) + reanchored without gap!
        %{
          id: "00000000-0000-4000-8000-000000000912",
          recording_block_id: "00000000-0000-4000-8000-000000000922",
          camera_source_id: @camera_id,
          stream_profile_id: @profile_id,
          storage_id: @unregistered_storage_id,
          block_key: String.duplicate("2", 64),
          anchor_id: "anchor-2",
          reanchored: true,
          contiguous_with_previous: true,
          timeline_start_us: @base_us + 10_000_000,
          timeline_end_us: @base_us + 20_000_000,
          media_start_ns: 10_000_000_000,
          media_end_ns: 20_000_000_000,
          fragment_count: 5,
          media_bytes: 1_000_000,
          local_state: :present,
          archive_state: :pending,
          archive_binding_id: @binding_id,
          time_basis: :received,
          time_uncertainty_us: nil
        },
        # 3. local_only_after_archive (archive_state == :deleted while local_state == :present)
        %{
          id: "00000000-0000-4000-8000-000000000913",
          recording_block_id: "00000000-0000-4000-8000-000000000923",
          camera_source_id: @camera_id,
          stream_profile_id: @profile_id,
          storage_id: @registered_storage_id,
          block_key: String.duplicate("3", 64),
          timeline_start_us: @base_us + 20_000_000,
          timeline_end_us: @base_us + 30_000_000,
          media_start_ns: 20_000_000_000,
          media_end_ns: 30_000_000_000,
          fragment_count: 5,
          media_bytes: 1_000_000,
          local_state: :present,
          archive_state: :deleted,
          archive_deleted_reason: :object_retention,
          archive_binding_id: @binding_id,
          time_basis: :received,
          time_uncertainty_us: nil
        },
        # 4. local_only (archive_state == :not_required and archive_binding_id == nil)
        %{
          id: "00000000-0000-4000-8000-000000000914",
          recording_block_id: "00000000-0000-4000-8000-000000000924",
          camera_source_id: @camera_id,
          stream_profile_id: @profile_id,
          storage_id: @registered_storage_id,
          block_key: String.duplicate("4", 64),
          timeline_start_us: @base_us + 30_000_000,
          timeline_end_us: @base_us + 40_000_000,
          media_start_ns: 30_000_000_000,
          media_end_ns: 40_000_000_000,
          fragment_count: 5,
          media_bytes: 1_000_000,
          local_state: :present,
          archive_state: :not_required,
          archive_binding_id: nil,
          time_basis: :received,
          time_uncertainty_us: nil
        },
        # 5. archive_only (local_state == :reclaimed and archive_state == :verified)
        %{
          id: "00000000-0000-4000-8000-000000000915",
          recording_block_id: "00000000-0000-4000-8000-000000000925",
          camera_source_id: @camera_id,
          stream_profile_id: @profile_id,
          storage_id: @registered_storage_id,
          block_key: String.duplicate("5", 64),
          timeline_start_us: @base_us + 40_000_000,
          timeline_end_us: @base_us + 50_000_000,
          media_start_ns: 40_000_000_000,
          media_end_ns: 50_000_000_000,
          fragment_count: 5,
          media_bytes: 1_000_000,
          local_state: :reclaimed,
          archive_state: :verified,
          archive_binding_id: @binding_id,
          time_basis: :received,
          time_uncertainty_us: nil
        },
        # 6. deleted_by_retention (local_state == :reclaimed and archive_state == :deleted)
        %{
          id: "00000000-0000-4000-8000-000000000916",
          recording_block_id: "00000000-0000-4000-8000-000000000926",
          camera_source_id: @camera_id,
          stream_profile_id: @profile_id,
          storage_id: @registered_storage_id,
          block_key: String.duplicate("6", 64),
          timeline_start_us: @base_us + 50_000_000,
          timeline_end_us: @base_us + 60_000_000,
          media_start_ns: 50_000_000_000,
          media_end_ns: 60_000_000_000,
          fragment_count: 5,
          media_bytes: 1_000_000,
          local_state: :reclaimed,
          archive_state: :deleted,
          archive_deleted_reason: :object_retention,
          archive_binding_id: @binding_id,
          time_basis: :received,
          time_uncertainty_us: nil
        },
        # 7. QUARANTINED catalog entry MUST NEVER appear in blocks or playable buckets (R2)!
        %{
          id: "00000000-0000-4000-8000-000000000917",
          recording_block_id: "00000000-0000-4000-8000-000000000927",
          camera_source_id: @camera_id,
          stream_profile_id: @profile_id,
          storage_id: @registered_storage_id,
          block_key: String.duplicate("7", 64),
          timeline_start_us: @base_us + 60_000_000,
          timeline_end_us: @base_us + 70_000_000,
          media_start_ns: 60_000_000_000,
          media_end_ns: 70_000_000_000,
          fragment_count: 5,
          media_bytes: 1_000_000,
          local_state: :quarantined,
          quarantine_reason: :binding_without_history,
          archive_state: :pending,
          time_basis: :received,
          time_uncertainty_us: nil
        }
      ]

      gaps = [
        %{
          id: "00000000-0000-4000-8000-000000000931",
          camera_source_id: @camera_id,
          stream_profile_id: @profile_id,
          start_us: @base_us + 60_000_000,
          end_us: @base_us + 70_000_000,
          reason: :quarantined,
          detail_class: "corrupt_tail",
          time_basis: :received,
          time_uncertainty_us: nil
        }
      ]

      assert {:ok, cov} =
               RecordingTimeline.coverage(
                 @camera_id,
                 %{from_us: @base_us, to_us: window_end, bucket_count: 12},
                 actor: @footage_viewer,
                 loaders: %{
                   catalog_loader: fn -> {:ok, entries} end,
                   gaps_loader: fn -> {:ok, gaps} end,
                   holds_loader: fn -> {:ok, []} end,
                   policies_loader: fn -> {:ok, []} end,
                   registered_storage_ids: [@registered_storage_id]
                 }
               )

      assert cov.time_basis == "received"
      assert cov.time_uncertainty == "unmeasured"
      refute cov.time_uncertainty in [0, "0"]
      assert cov.scheduled_continuous? == false

      # Quarantined entry 7 is strictly excluded from blocks:
      assert length(cov.blocks) == 6
      refute Enum.any?(cov.blocks, &(&1.id == "00000000-0000-4000-8000-000000000917"))

      by_key = Map.new(cov.blocks, &{String.first(&1.block_key), &1})
      assert by_key["1"].copy_state == :local_and_archived
      assert by_key["1"].provisional? == false
      assert by_key["2"].copy_state == :pending_archive
      assert by_key["2"].provisional? == true
      assert by_key["2"].reanchored? == true
      assert by_key["3"].copy_state == :local_only_after_archive
      assert by_key["4"].copy_state == :local_only
      assert by_key["5"].copy_state == :archive_only
      assert by_key["6"].copy_state == :deleted_by_retention

      # Re-anchor boundary recorded without media gap:
      assert [%{entry_id: "00000000-0000-4000-8000-000000000912", at_us: reanchor_at}] =
               cov.reanchors

      assert reanchor_at == @base_us + 10_000_000

      # 12 buckets of 10s each:
      bucket_states = Enum.map(cov.buckets, & &1.state)

      assert bucket_states == [
               :local_and_archived,
               :pending_archive,
               :local_only_after_archive,
               :local_only,
               :archive_only,
               :deleted_by_retention,
               :gap,
               :not_scheduled,
               :not_scheduled,
               :not_scheduled,
               :not_scheduled,
               :not_scheduled
             ]

      assert Enum.at(cov.buckets, 6).gap_reasons == [:quarantined]
    end
  end

  describe "issue_playlist_window/3 and resolve_read_plans/5" do
    test "enforces <= 60m window, filters by source_mode, writes audit, enforces no-fallback on forced source, and redacts credentials" do
      assert {:error, :playlist_window_too_large} =
               RecordingTimeline.issue_playlist_window(
                 @camera_id,
                 %{from_us: @base_us, to_us: @base_us + 3_600_000_001},
                 actor: @footage_viewer,
                 loaders: %{catalog_loader: fn -> {:ok, []} end}
               )

      desc_dual = synthetic_descriptor("dual")
      desc_arch = synthetic_descriptor("arch")
      dual_key = String.duplicate("a", 64)
      arch_key = String.duplicate("b", 64)
      quarantined_key = String.duplicate("f", 64)

      entries = [
        %{
          id: "00000000-0000-4000-8000-000000000941",
          recording_block_id: "00000000-0000-4000-8000-000000000951",
          camera_source_id: @camera_id,
          stream_profile_id: @profile_id,
          storage_id: @unregistered_storage_id,
          block_key: dual_key,
          timeline_start_us: @base_us,
          timeline_end_us: @base_us + 4_000_000,
          media_start_ns: 0,
          media_end_ns: 4_000_000_000,
          fragment_count: 2,
          media_bytes: 8_192,
          init_sha256: desc_dual["init"]["sha256"],
          descriptor_sha256: digest("dual-desc"),
          local_state: :present,
          archive_state: :verified,
          archive_binding_id: @binding_id,
          time_basis: :received,
          frozen_descriptor: desc_dual
        },
        %{
          id: "00000000-0000-4000-8000-000000000942",
          recording_block_id: "00000000-0000-4000-8000-000000000952",
          camera_source_id: @camera_id,
          stream_profile_id: @profile_id,
          storage_id: @registered_storage_id,
          block_key: arch_key,
          timeline_start_us: @base_us + 4_000_000,
          timeline_end_us: @base_us + 8_000_000,
          media_start_ns: 4_000_000_000,
          media_end_ns: 8_000_000_000,
          fragment_count: 2,
          media_bytes: 8_192,
          init_sha256: desc_arch["init"]["sha256"],
          descriptor_sha256: digest("arch-desc"),
          local_state: :reclaimed,
          archive_state: :verified,
          archive_binding_id: @binding_id,
          time_basis: :received,
          frozen_descriptor: desc_arch
        },
        %{
          id: "00000000-0000-4000-8000-000000000943",
          recording_block_id: "00000000-0000-4000-8000-000000000953",
          camera_source_id: @camera_id,
          stream_profile_id: @profile_id,
          storage_id: @registered_storage_id,
          block_key: quarantined_key,
          timeline_start_us: @base_us + 8_000_000,
          timeline_end_us: @base_us + 12_000_000,
          local_state: :quarantined,
          quarantine_reason: :unrecoverable_journal,
          archive_state: :verified,
          frozen_descriptor: synthetic_descriptor("quar")
        }
      ]

      test_pid = self()

      assert {:ok, window} =
               RecordingTimeline.issue_playlist_window(
                 @camera_id,
                 %{from_us: @base_us, to_us: @base_us + 15_000_000, source_mode: :auto},
                 actor: @footage_viewer,
                 loaders: %{
                   catalog_loader: fn -> {:ok, entries} end,
                   gaps_loader: fn -> {:ok, []} end,
                   audit_writer: fn audit_attrs ->
                     send(test_pid, {:audit_written, audit_attrs})
                     {:ok, audit_attrs}
                   end
                 }
               )

      assert Enum.map(window.entries, & &1.id) == [
               "00000000-0000-4000-8000-000000000941",
               "00000000-0000-4000-8000-000000000942"
             ]

      assert window.segment_count == 4

      assert_received {:audit_written,
                       %{
                         event_kind: :playlist_window,
                         actor_id: "u-footage-viewer",
                         segment_count: 4
                       }}

      # Forced :local excludes reclaimed entry 942:
      assert {:ok, local_window} =
               RecordingTimeline.issue_playlist_window(
                 @camera_id,
                 %{from_us: @base_us, to_us: @base_us + 15_000_000, source_mode: :local},
                 actor: @footage_viewer,
                 record_audit?: false,
                 loaders: %{catalog_loader: fn -> {:ok, entries} end}
               )

      assert Enum.map(local_window.entries, & &1.id) == ["00000000-0000-4000-8000-000000000941"]

      # Read plan resolution: quarantined entry is strictly refused!
      binding = %{
        id: @binding_id,
        provider: "s3_compatible",
        endpoint: "https://objects.example.com",
        region: "example-1",
        bucket: "synthetic-timeline-bucket",
        namespace: "recordings/v1",
        required_encryption: "sse_s3_aes256",
        destination_sha256: digest("dest")
      }

      receipt_dual = %{
        objects: [
          %{
            "name" => "init.mp4",
            "key" => "recordings/v1/#{@unregistered_storage_id}/#{dual_key}/init.mp4",
            "length" => 512,
            "sha256" => desc_dual["init"]["sha256"],
            "etag" => "\"etag-init\"",
            "version_id" => "v1"
          },
          %{
            "name" => "media.m4s",
            "key" => "recordings/v1/#{@unregistered_storage_id}/#{dual_key}/media.m4s",
            "length" => 8_192,
            "sha256" => desc_dual["media"]["sha256"],
            "etag" => "\"etag-media\"",
            "version_id" => "v2"
          }
        ]
      }

      synthetic_access_key = String.duplicate("k", 24)
      synthetic_secret_key = String.duplicate("z", 36)

      plan_loaders = %{
        catalog_loader: fn -> {:ok, entries} end,
        binding_loader: fn @binding_id -> {:ok, binding} end,
        receipt_loader: fn _entry -> {:ok, receipt_dual} end
      }

      assert {:error, :recording_unavailable} =
               RecordingTimeline.resolve_read_plans(
                 @camera_id,
                 "00000000-0000-4000-8000-000000000943",
                 {:fragment, 0},
                 :auto,
                 actor: @footage_viewer,
                 loaders: plan_loaders
               )

      # Forced :local on reclaimed archive-only entry 942 has NO fallback -> :recording_unavailable!
      assert {:error, :recording_unavailable} =
               RecordingTimeline.resolve_read_plans(
                 @camera_id,
                 "00000000-0000-4000-8000-000000000942",
                 {:fragment, 0},
                 :local,
                 actor: @footage_viewer,
                 loaders: plan_loaders
               )

      # Auto mode on dual entry 941 returns [local (provisional), archive (with RedactedCredential)]:
      assert {:ok, [local_plan, archive_plan]} =
               RecordingTimeline.resolve_read_plans(
                 @camera_id,
                 "00000000-0000-4000-8000-000000000941",
                 {:fragment, 1},
                 :auto,
                 actor: @footage_viewer,
                 credential_resolver: fn _b, :reader ->
                   {:ok,
                    %{
                      "reference" =>
                        "network_credential_secret:00000000-0000-4000-8000-000000000999",
                      "generation" => 3,
                      "access_key_id" => synthetic_access_key,
                      "secret_access_key" => synthetic_secret_key
                    }}
                 end,
                 loaders: plan_loaders
               )

      assert local_plan.copy == :local
      assert local_plan.provisional? == true
      assert local_plan.recording_copy_header == "local; provisional"
      assert local_plan.expected_length == 4_096
      assert local_plan.expected_sha256 == digest("dual-frag-1")

      assert archive_plan.copy == :archive
      assert archive_plan.first == 4_096
      assert archive_plan.last == 8_191
      assert archive_plan.version_id == "v2"
      assert %RedactedCredential{} = archive_plan.credential
      assert archive_plan.credential.access_key_id == synthetic_access_key

      inspected = inspect([local_plan, archive_plan])
      refute inspected =~ synthetic_access_key
      refute inspected =~ synthetic_secret_key
    end

    test "RecordingAccessAudit rejects invalid windows and secret keys in details" do
      invalid_window =
        Ash.Changeset.for_create(RecordingAccessAudit, :record, %{
          event_kind: :playlist_window,
          actor_id: "u-footage-viewer",
          camera_source_id: @camera_id,
          window_start_us: 500,
          window_end_us: 500
        })

      refute invalid_window.valid?

      forbidden_details =
        Ash.Changeset.for_create(RecordingAccessAudit, :record, %{
          event_kind: :playlist_window,
          actor_id: "u-footage-viewer",
          camera_source_id: @camera_id,
          window_start_us: 100,
          window_end_us: 500,
          details: %{"nested" => %{"secret_access_key" => "forbidden"}}
        })

      refute forbidden_details.valid?
    end
  end
end
