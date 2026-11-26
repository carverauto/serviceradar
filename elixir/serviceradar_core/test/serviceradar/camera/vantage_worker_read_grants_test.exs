defmodule ServiceRadar.Camera.VantageWorkerReadGrantsTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Camera.ArchiveBinding
  alias ServiceRadar.Camera.ArchiveCredentialResolver
  alias ServiceRadar.Camera.VantageJob
  alias ServiceRadar.Camera.VisualIndexJob
  alias ServiceRadar.Camera.VisualWorkerReadGrants

  @job_id "00000000-0000-4000-8000-000000000301"
  @catalog_id "00000000-0000-4000-8000-000000000302"
  @block_id "00000000-0000-4000-8000-000000000303"
  @cam_id "00000000-0000-4000-8000-000000000304"
  @prof_id "00000000-0000-4000-8000-000000000305"
  @binding_id "00000000-0000-4000-8000-000000000306"
  @storage_id "00000000-0000-4000-8000-000000000307"
  @secret_id "00000000-0000-4000-8000-000000000308"
  @desc_sha String.duplicate("a", 64)
  @init_sha String.duplicate("b", 64)
  @f0_sha String.duplicate("c", 64)
  @f2_sha String.duplicate("d", 64)
  @media_sha String.duplicate("e", 64)

  test "issues scoped read grant for :vantage_worker identity and VantageJob sampled_targets with redacted secret" do
    installation = %{deployment_ref: "dep-1", generation: 1, purpose: :vantage_worker}
    secret = "test-vantage-reader-secret-000000000"

    req = %{
      "schema_version" => 1,
      "job_id" => @job_id,
      "catalog_entry_id" => @catalog_id,
      "descriptor_sha256" => @desc_sha
    }

    job =
      struct(VantageJob,
        id: @job_id,
        pipeline_id: "io.serviceradar.vantage-alpr.vehicle-plate",
        pipeline_version: "1.0.0",
        catalog_entry_id: @catalog_id,
        camera_source_id: @cam_id,
        stream_profile_id: @prof_id,
        state: :dispatched,
        descriptor_sha256: @desc_sha,
        sampled_targets: [
          %{"target_key" => "track:1", "fragment_sequence" => 2},
          %{"target_key" => "track:2", "fragment_sequence" => 0},
          %{"target_key" => "track:1", "fragment_sequence" => 2}
        ]
      )

    assert {:ok, plan} =
             VisualWorkerReadGrants.issue_read_grant(
               installation,
               req,
               loaders: grant_loaders(job, playable_entry(), secret),
               now: ~U[2026-11-25 12:00:00Z]
             )

    assert plan.backing == :archive
    assert Enum.map(plan.fragments, & &1["sequence"]) == [0, 2]
    assert Enum.sort(plan.grant["allowed_methods"]) == ["GET", "HEAD"]
    refute inspect(plan) =~ secret
    refute Jason.encode!(plan) =~ secret
  end

  test "returns :recording_gone and triggers job cancellation for quarantined or deleted VantageJob entry" do
    installation = %{deployment_ref: "dep-1", generation: 1, purpose: :vantage_worker}
    parent = self()

    job =
      struct(VantageJob,
        id: @job_id,
        pipeline_id: "io.serviceradar.vantage-alpr.vehicle-plate",
        catalog_entry_id: @catalog_id,
        descriptor_sha256: @desc_sha,
        state: :dispatched,
        sampled_targets: [%{"fragment_sequence" => 0}]
      )

    gone_entry = %{
      playable_entry()
      | local_state: :reclaimed,
        archive_state: :not_required
    }

    loaders =
      Map.put(grant_loaders(job, gone_entry, "unused"), :cancel_job_fn, fn cancelled_job, req ->
        send(parent, {:cancelled, cancelled_job.id, req.catalog_entry_id})
        :ok
      end)

    assert {:error, :recording_gone} =
             VisualWorkerReadGrants.issue_read_grant(
               installation,
               %{
                 "job_id" => @job_id,
                 "catalog_entry_id" => @catalog_id,
                 "descriptor_sha256" => @desc_sha
               },
               loaders: loaders
             )

    assert_received {:cancelled, @job_id, @catalog_id}
  end

  test "rejects unauthorized worker domains and malformed read-grant request fields" do
    assert {:error, :unauthorized_worker} =
             VisualWorkerReadGrants.issue_read_grant(
               %{purpose: :media},
               %{
                 "job_id" => @job_id,
                 "catalog_entry_id" => @catalog_id,
                 "descriptor_sha256" => @desc_sha
               }
             )

    installation = %{purpose: :vantage_worker}

    assert {:error, :invalid_job_id} =
             VisualWorkerReadGrants.issue_read_grant(installation, %{
               "job_id" => "not-uuid",
               "catalog_entry_id" => @catalog_id,
               "descriptor_sha256" => @desc_sha
             })

    assert {:error, :invalid_catalog_entry_id} =
             VisualWorkerReadGrants.issue_read_grant(installation, %{
               "job_id" => @job_id,
               "catalog_entry_id" => "not-uuid",
               "descriptor_sha256" => @desc_sha
             })

    assert {:error, :invalid_descriptor_sha256} =
             VisualWorkerReadGrants.issue_read_grant(installation, %{
               "job_id" => @job_id,
               "catalog_entry_id" => @catalog_id,
               "descriptor_sha256" => "short"
             })
  end

  test "isolates :vantage_worker from VisualIndexJob while allowing :media_worker on both VisualIndexJob and Ramp 1 VantageJob" do
    req = %{
      "schema_version" => 1,
      "job_id" => @job_id,
      "catalog_entry_id" => @catalog_id,
      "descriptor_sha256" => @desc_sha
    }

    vi_job =
      struct(VisualIndexJob,
        id: @job_id,
        catalog_entry_id: @catalog_id,
        camera_source_id: @cam_id,
        stream_profile_id: @prof_id,
        state: :dispatched,
        descriptor_sha256: @desc_sha,
        sampled_fragments: [%{"sequence" => 0}]
      )

    vantage_job =
      struct(VantageJob,
        id: @job_id,
        pipeline_id: "io.serviceradar.vantage-alpr.vehicle-plate",
        pipeline_version: "1.0.0",
        catalog_entry_id: @catalog_id,
        camera_source_id: @cam_id,
        stream_profile_id: @prof_id,
        state: "dispatched",
        descriptor_sha256: @desc_sha,
        sampled_targets: [%{"target_key" => "track:1", "fragment_sequence" => 0}]
      )

    secret = "test-secret-000000000000"

    vi_loaders =
      vi_job
      |> grant_loaders(playable_entry(), secret)
      |> Map.delete(:vantage_job_loader)
      |> Map.put(:job_loader, fn _ -> {:ok, vi_job} end)

    assert {:error, :job_not_found} =
             VisualWorkerReadGrants.issue_read_grant(%{purpose: :vantage_worker}, req,
               loaders: vi_loaders
             )

    assert {:ok, vi_plan} =
             VisualWorkerReadGrants.issue_read_grant(%{purpose: :media_worker}, req,
               loaders: vi_loaders,
               now: ~U[2026-11-25 12:00:00Z]
             )

    assert vi_plan.backing == :archive

    ramp1_loaders =
      vantage_job
      |> grant_loaders(playable_entry(), secret)
      |> Map.put(:job_loader, fn _ -> {:ok, nil} end)

    assert {:ok, ramp1_plan} =
             VisualWorkerReadGrants.issue_read_grant(%{purpose: :media_worker}, req,
               loaders: ramp1_loaders,
               now: ~U[2026-11-25 12:00:00Z]
             )

    assert ramp1_plan.backing == :archive
  end

  test "build_local_grant uses entry.nvr_member and fails cleanly when nvr_member is nil or blank" do
    req = %{
      "schema_version" => 1,
      "job_id" => @job_id,
      "catalog_entry_id" => @catalog_id,
      "descriptor_sha256" => @desc_sha
    }

    job =
      struct(VantageJob,
        id: @job_id,
        pipeline_id: "io.serviceradar.vantage-alpr.vehicle-plate",
        catalog_entry_id: @catalog_id,
        descriptor_sha256: @desc_sha,
        state: :dispatched,
        sampled_targets: [%{"fragment_sequence" => 0}]
      )

    local_entry = %{
      playable_entry()
      | archive_state: :not_required,
        local_state: :present,
        nvr_member: "nvr-local-01"
    }

    assert {:ok, local_plan} =
             VisualWorkerReadGrants.issue_read_grant(%{purpose: :vantage_worker}, req,
               loaders: %{
                 vantage_job_loader: fn _ -> {:ok, job} end,
                 entry_loader: fn _ -> {:ok, local_entry} end
               }
             )

    assert local_plan.backing == :local
    assert local_plan.nvr_member == "nvr-local-01"
    assert local_plan.local["nvr_member"] == "nvr-local-01"

    for blank <- [nil, "", "   "] do
      missing_member_entry = %{local_entry | nvr_member: blank}

      assert {:error, :recording_unavailable} =
               VisualWorkerReadGrants.issue_read_grant(%{purpose: :vantage_worker}, req,
                 loaders: %{
                   vantage_job_loader: fn _ -> {:ok, job} end,
                   entry_loader: fn _ -> {:ok, missing_member_entry} end
                 }
               )
    end
  end

  defp playable_entry do
    %{
      id: @catalog_id,
      recording_block_id: @block_id,
      camera_source_id: @cam_id,
      stream_profile_id: @prof_id,
      storage_id: @storage_id,
      nvr_member: "nvr-0",
      block_key: "block-0001",
      local_state: :present,
      archive_state: :verified,
      archive_binding_id: @binding_id,
      quarantine_reason: nil,
      descriptor_sha256: @desc_sha,
      descriptor: %{
        "init" => %{"length" => 1024, "sha256" => @init_sha},
        "media" => %{"length" => 65_536, "sha256" => @media_sha},
        "fragments" => [
          %{
            "sequence" => 0,
            "offset" => 0,
            "length" => 4096,
            "start_ns" => 0,
            "duration_ns" => 1_000_000_000,
            "sha256" => @f0_sha
          },
          %{
            "sequence" => 2,
            "offset" => 8192,
            "length" => 4096,
            "start_ns" => 2_000_000_000,
            "duration_ns" => 1_000_000_000,
            "sha256" => @f2_sha
          }
        ]
      }
    }
  end

  defp grant_loaders(job, entry, secret_key) do
    %{
      vantage_job_loader: fn _id -> {:ok, job} end,
      entry_loader: fn _id -> {:ok, entry} end,
      binding_loader: fn _id ->
        {:ok,
         struct(ArchiveBinding,
           id: @binding_id,
           schema_version: 2,
           provisioning_ref: "prov-synthetic-01",
           generation: 1,
           purpose: "recording",
           provider: "s3_compatible",
           endpoint: "https://objects.example.com",
           region: "us-east-1",
           bucket: "synthetic-archive",
           namespace: "nvr/archive-v2",
           archive_format_version: 1,
           required_encryption: "sse_s3_aes256"
         )}
      end,
      receipt_loader: fn _entry ->
        {:ok,
         %{
           recording_block_id: @block_id,
           archive_binding_id: @binding_id,
           objects: [
             %{
               "name" => "init.mp4",
               "key" => "nvr/archive-v2/#{@storage_id}/block-0001/init.mp4",
               "length" => 1024,
               "sha256" => @init_sha
             },
             %{
               "name" => "media.m4s",
               "key" => "nvr/archive-v2/#{@storage_id}/block-0001/media.m4s",
               "length" => 65_536,
               "sha256" => @media_sha
             }
           ]
         }}
      end,
      credential_resolver: fn binding, _role, ttl ->
        {:ok, grant_attrs} =
          ArchiveCredentialResolver.grant_attrs(binding, :reader, @secret_id, ttl_seconds: ttl)

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
      end
    }
  end
end
