defmodule ServiceRadar.Camera.CameraRecordingVantageHooksUnitTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Camera.ArchiveCredentialResolver
  alias ServiceRadar.Camera.CameraRecordingPolicies
  alias ServiceRadar.Camera.VisualWorkerReadGrants
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

  describe "VisualWorkerReadGrants execution-time fragment grants and 410 Gone (1.6)" do
    test "returns {:error, :recording_gone} for missing, quarantined, or reclaimed+deleted entries" do
      installation = %{deployment_ref: "dep-1", generation: 1, purpose: :media_worker}

      req = %{
        "schema_version" => 1,
        "job_id" => @job_id,
        "fragment_sequences" => "0,2",
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
        "fragment_sequences" => "0,2",
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
        "fragment_sequences" => "0,2",
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
        "fragment_sequences" => "0,2",
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

    test "grants requested or all descriptor fragments, echoes job_id, and never needs a job row" do
      installation = %{deployment_ref: "dep-1", generation: 1, purpose: :media_worker}

      local_entry =
        Map.merge(playable_archive_entry(), %{
          local_state: :present,
          archive_state: :not_required,
          archive_binding_id: nil
        })

      base = %{"catalog_entry_id" => @catalog_id, "descriptor_sha256" => @desc_sha}

      issue =
        &VisualWorkerReadGrants.issue_read_grant(installation, &1,
          loaders: grant_loaders(local_entry)
        )

      assert {:ok, all} = issue.(base)
      assert Enum.map(all.fragments, & &1["sequence"]) == [0, 1, 1_001, 2]
      assert all.job_id == ""

      assert {:ok, picked} =
               issue.(Map.merge(base, %{"job_id" => @job_id, "fragment_sequences" => "2,0"}))

      assert Enum.map(picked.fragments, & &1["sequence"]) == [0, 2]
      assert picked.job_id == @job_id

      assert {:error, :fragment_not_found} = issue.(Map.put(base, "fragment_sequences", "7"))

      assert {:error, :too_many_fragments} =
               issue.(Map.put(base, "fragment_sequences", Enum.join(0..64, ",")))

      for bad <- ["", "0,0", "-1", "0,", "a", [0]] do
        assert {:error, :invalid_read_grant_request} =
                 issue.(Map.put(base, "fragment_sequences", bad)),
               "accepted fragment_sequences #{inspect(bad)}"
      end

      assert {:error, :invalid_read_grant_request} =
               issue.(Map.put(base, "job_id", String.duplicate("j", 129)))
    end
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
    %{
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
end
