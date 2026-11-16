defmodule ServiceRadar.Camera.NVROperatorSettingsUnitTest do
  use ExUnit.Case, async: true

  alias Ash.Error.Forbidden
  alias ServiceRadar.Camera.ArchiveDestinations
  alias ServiceRadar.Camera.NVRArchiveReceipt
  alias ServiceRadar.Camera.RecordingArchiveSettings
  alias ServiceRadar.Camera.RecordingBlocks
  alias ServiceRadar.Camera.RecordingOperation

  @storage_id "00000000-0000-4000-8000-000000000011"
  @binding_id "00000000-0000-4000-8000-000000000012"
  @writer_id "00000000-0000-4000-8000-000000000013"
  @reader_id "00000000-0000-4000-8000-000000000014"
  @camera_id "00000000-0000-4000-8000-000000000015"
  @retention_id "00000000-0000-4000-8000-000000000016"
  @block_key String.duplicate("a", 64)
  @dest_sha String.duplicate("b", 64)

  describe "ArchiveDestinations.register_operator/2 and validate_operator_input/1" do
    test "enforces settings.recording.manage before persisting and builds operator:<name> refs" do
      valid_attrs = %{
        name: "primary",
        endpoint: "https://objects.example.com",
        region: "example-1",
        bucket: "example-archive",
        namespace: "recordings/v1"
      }

      viewer = %{
        id: "user-viewer",
        role: :viewer,
        permissions: MapSet.new(["settings.recording.view"])
      }

      assert {:error, %Forbidden{}} =
               ArchiveDestinations.register_operator(valid_attrs,
                 actor: viewer,
                 register_fn: fn _ -> flunk("must not persist for unpermitted caller") end
               )

      manager = %{
        id: "user-manager",
        role: :admin,
        permissions: MapSet.new(["settings.recording.manage"])
      }

      assert {:ok, persisted} =
               ArchiveDestinations.register_operator(valid_attrs,
                 actor: manager,
                 register_fn: fn normalized -> {:ok, normalized} end
               )

      assert persisted == %{
               provisioning_ref: "operator:primary",
               endpoint: "https://objects.example.com",
               region: "example-1",
               bucket: "example-archive",
               namespace: "recordings/v1"
             }
    end

    test "returns field-specific errors for invalid name, endpoint, region, bucket, and namespace" do
      invalid = %{
        "name" => "UPPER_BAD",
        "endpoint" => "https://192.0.2.10",
        "region" => "EXAMPLE_1",
        "bucket" => "no",
        "key_prefix" => "/leading-slash"
      }

      assert {:error, error} = ArchiveDestinations.validate_operator_input(invalid)
      fields = Enum.map(error.errors, & &1.field)

      assert :name in fields
      assert :endpoint in fields
      assert :region in fields
      assert :bucket in fields
      assert :namespace in fields

      # Non-operator provisioning_ref is also rejected on :name.
      assert {:error, non_operator_err} =
               ArchiveDestinations.validate_operator_input(%{
                 provisioning_ref: "cloud:tenant-01",
                 endpoint: "https://objects.example.com",
                 region: "example-1",
                 bucket: "example-archive",
                 namespace: "recordings/v1"
               })

      assert Enum.any?(non_operator_err.errors, &(&1.field == :name))

      # Non-443 port, path, and http scheme identify :endpoint specifically.
      for bad_endpoint <- [
            "http://objects.example.com",
            "https://objects.example.com:8443",
            "https://objects.example.com/custom-path"
          ] do
        assert {:error, ep_err} =
                 ArchiveDestinations.validate_operator_input(%{
                   name: "primary",
                   endpoint: bad_endpoint,
                   region: "example-1",
                   bucket: "example-archive",
                   namespace: "recordings/v1"
                 })

        assert Enum.map(ep_err.errors, & &1.field) == [:endpoint]
      end
    end
  end

  describe "RecordingArchiveSettings defaults and overview" do
    test "returns deployment code defaults and redacted credential status without exposing secrets" do
      defaults = RecordingArchiveSettings.default_settings()
      assert defaults.id == "deployment"
      assert defaults.archive_enabled == false
      assert is_nil(defaults.active_archive_binding_id)
      assert is_nil(defaults.writer_credential_secret_id)
      assert is_nil(defaults.reader_credential_secret_id)
      assert is_nil(defaults.retention_credential_secret_id)
      assert defaults.local_high_water_percent == 90
      assert defaults.local_low_water_percent == 80
      assert defaults.max_local_age_mode == :limited
      assert defaults.max_local_age_seconds == 86_400
      assert defaults.local_window_alert_mode == :enabled
      assert defaults.local_window_alert_seconds == 3_600
      assert is_nil(defaults.local_only_full_policy)
      assert defaults.local_only_target_mode == :target
      assert defaults.local_only_retention_target_seconds == 604_800
      assert defaults.local_only_max_age_mode == :unlimited
      assert is_nil(defaults.local_only_max_age_seconds)
      assert defaults.archive_retention_mode == :limited
      assert defaults.archive_retention_days == 30
      assert defaults.object_budget_mode == :unlimited
      assert is_nil(defaults.object_budget_bytes)
      assert defaults.object_high_water_percent == 90
      assert defaults.object_low_water_percent == 80
      assert is_nil(defaults.object_capacity_policy)

      assert RecordingArchiveSettings.effective_local_only_full_policy(defaults) ==
               :stop_when_full

      assert RecordingArchiveSettings.effective_object_capacity_policy(defaults) ==
               :stop_archiving

      assert RecordingArchiveSettings.shorter_archive_than_local?(defaults) == false

      # Unpermitted user cannot read overview.
      unpermitted = %{id: "user-none", role: :viewer, permissions: MapSet.new()}

      assert {:error, %Forbidden{}} =
               RecordingArchiveSettings.get_overview(actor: unpermitted)

      # Split-duty user holding settings.recording.manage (without settings.credentials.manage)
      # receives only redacted credential name and availability status.
      recording_manager = %{
        id: "user-rec-mgr",
        role: :operator,
        permissions: MapSet.new(["settings.recording.manage"])
      }

      persisted = %RecordingArchiveSettings{
        id: "deployment",
        active_archive_binding_id: @binding_id,
        writer_credential_secret_id: @writer_id,
        reader_credential_secret_id: @reader_id,
        archive_enabled: true
      }

      loaders = %{
        settings_loader: fn -> {:ok, persisted} end,
        binding_loader: fn @binding_id -> {:ok, %{id: @binding_id}} end,
        secret_loader: fn
          @writer_id ->
            {:ok,
             %{
               id: @writer_id,
               name: "Archive Writer S3",
               provider: "s3_compatible",
               credential_kind: :opaque,
               secret_payload: "MUST_NEVER_BE_RETURNED"
             }}

          @reader_id ->
            {:ok,
             %{
               id: @reader_id,
               name: "Archive Reader S3",
               provider: "s3_compatible",
               credential_kind: :opaque,
               enabled: false
             }}
        end
      }

      assert {:ok, overview} =
               RecordingArchiveSettings.get_overview(
                 actor: recording_manager,
                 loaders: loaders
               )

      assert overview.persisted? == true
      assert overview.storage_mode == :local_and_archive

      assert overview.writer_credential == %{
               id: @writer_id,
               name: "Archive Writer S3",
               status: :available,
               reason: nil
             }

      refute Map.has_key?(overview.writer_credential, :secret_payload)

      assert overview.reader_credential == %{
               id: @reader_id,
               name: "Archive Reader S3",
               status: :inactive,
               reason: :credential_secret_inactive
             }

      assert overview.archive_ready? == false

      assert overview.unavailable_reason ==
               {:reader_credential_unavailable, :credential_secret_inactive}

      # Default local-only state (archive_enabled: false, no binding, no secrets) is normal,
      # reporting storage_mode: :local_only and unavailable_reason: nil.
      assert {:ok, local_only_overview} =
               RecordingArchiveSettings.get_overview(
                 actor: recording_manager,
                 loaders: %{settings_loader: fn -> {:ok, nil} end}
               )

      assert local_only_overview.persisted? == false
      assert local_only_overview.storage_mode == :local_only
      assert local_only_overview.archive_ready? == false
      assert is_nil(local_only_overview.unavailable_reason)

      # Enabling archive without an active destination surfaces :missing_active_destination.
      assert {:ok, missing_dest_overview} =
               RecordingArchiveSettings.get_overview(
                 actor: recording_manager,
                 loaders: %{
                   settings_loader: fn ->
                     {:ok,
                      %RecordingArchiveSettings{
                        id: "deployment",
                        active_archive_binding_id: nil,
                        archive_enabled: true
                      }}
                   end
                 }
               )

      assert missing_dest_overview.storage_mode == :local_only
      assert missing_dest_overview.archive_ready? == false
      assert missing_dest_overview.unavailable_reason == :missing_active_destination
    end

    test "inspect_credential_secret/2 rejects wrong provider, wrong kind, deleted, or disabled external provider" do
      assert {:ok, %{status: :invalid, reason: :credential_provider_mismatch}} =
               RecordingArchiveSettings.inspect_credential_secret(@writer_id, %{
                 secret_loader: fn _ ->
                   {:ok, %{name: "SNMP", provider: "snmp_v2c", credential_kind: :opaque}}
                 end
               })

      assert {:ok, %{status: :invalid, reason: :credential_kind_mismatch}} =
               RecordingArchiveSettings.inspect_credential_secret(@writer_id, %{
                 secret_loader: fn _ ->
                   {:ok, %{name: "Token", provider: "s3_compatible", credential_kind: :api_token}}
                 end
               })

      assert {:ok, %{status: :inactive, reason: :credential_secret_inactive}} =
               RecordingArchiveSettings.inspect_credential_secret(@writer_id, %{
                 secret_loader: fn _ ->
                   {:ok,
                    %{
                      name: "External S3",
                      provider: "s3_compatible",
                      credential_kind: :opaque,
                      source_type: :external_reference,
                      secret_provider_id: "00000000-0000-4000-8000-000000000099"
                    }}
                 end,
                 provider_loader: fn _ -> {:ok, %{enabled: false}} end
               })
    end
  end

  describe "NVRArchiveReceipt.parse_receipt_bytes/1" do
    test "parses bounded canonical receipt JSON and rejects oversized or malformed payloads" do
      receipt_bytes =
        Jason.encode!(%{
          "storage_id" => @storage_id,
          "block_id" => @block_key,
          "destination_sha256" => @dest_sha,
          "verified_at_ms" => 1_763_200_000_123,
          "objects" => [
            %{
              "name" => "init.mp4",
              "key" => "recordings/v1/#{@storage_id}/#{@block_key}/init.mp4",
              "length" => 1024,
              "sha256" => String.duplicate("c", 64),
              "etag" => "\"etag-init\""
            },
            %{
              "name" => "media.m4s",
              "key" => "recordings/v1/#{@storage_id}/#{@block_key}/media.m4s",
              "length" => 65_536,
              "sha256" => String.duplicate("d", 64),
              "etag" => "\"etag-media\""
            }
          ]
        })

      assert {:ok, parsed} = NVRArchiveReceipt.parse_receipt_bytes(receipt_bytes)
      assert parsed.version == 1
      assert parsed.storage_id == @storage_id
      assert parsed.block_key == @block_key
      assert length(parsed.objects) == 2
      refute Map.has_key?(hd(parsed.objects), "version_id")
      assert DateTime.to_unix(parsed.verified_at, :millisecond) == 1_763_200_000_123

      # Receipt version 2 preserves per-object version_id (both string and explicit nil).
      v2_receipt_bytes =
        Jason.encode!(%{
          "version" => 2,
          "storage_id" => @storage_id,
          "block_id" => @block_key,
          "destination_sha256" => @dest_sha,
          "verified_at_ms" => 1_763_200_000_456,
          "objects" => [
            %{
              "name" => "init.mp4",
              "key" => "recordings/v1/#{@storage_id}/#{@block_key}/init.mp4",
              "length" => 1024,
              "sha256" => String.duplicate("c", 64),
              "etag" => "\"etag-init\"",
              "version_id" => "synth-ver-0001"
            },
            %{
              "name" => "media.m4s",
              "key" => "recordings/v1/#{@storage_id}/#{@block_key}/media.m4s",
              "length" => 65_536,
              "sha256" => String.duplicate("d", 64),
              "etag" => "\"etag-media\"",
              "version_id" => nil
            },
            %{
              "name" => "descriptor.json",
              "key" => "recordings/v1/#{@storage_id}/#{@block_key}/descriptor.json",
              "length" => 512,
              "sha256" => String.duplicate("e", 64),
              "etag" => "\"etag-desc\""
            }
          ]
        })

      assert {:ok, parsed_v2} = NVRArchiveReceipt.parse_receipt_bytes(v2_receipt_bytes)
      assert parsed_v2.version == 2
      [init_obj, media_obj, desc_obj] = parsed_v2.objects
      assert init_obj["version_id"] == "synth-ver-0001"
      assert Map.fetch(media_obj, "version_id") == {:ok, nil}
      assert Map.fetch(desc_obj, "version_id") == :error

      # Unsupported receipt versions and malformed object version_ids are rejected.
      for bad_version <- [0, 3, "2", -1] do
        bad_ver_bytes =
          Jason.encode!(%{
            "version" => bad_version,
            "storage_id" => @storage_id,
            "block_id" => @block_key,
            "verified_at_ms" => 1_763_200_000_123,
            "objects" => [init_obj]
          })

        assert {:error, {:receipt_bytes, "receipt version must be 1 or 2"}} =
                 NVRArchiveReceipt.parse_receipt_bytes(bad_ver_bytes)
      end

      for bad_vid <- ["", 123, "bad space", "bad\nline", String.duplicate("v", 1025)] do
        bad_vid_bytes =
          Jason.encode!(%{
            "version" => 2,
            "storage_id" => @storage_id,
            "block_id" => @block_key,
            "verified_at_ms" => 1_763_200_000_123,
            "objects" => [Map.put(init_obj, "version_id", bad_vid)]
          })

        assert {:error, {:receipt_bytes, msg}} =
                 NVRArchiveReceipt.parse_receipt_bytes(bad_vid_bytes)

        assert msg =~ "version_id"
      end

      assert {:error, {:receipt_bytes, _}} = NVRArchiveReceipt.parse_receipt_bytes("")

      assert {:error, {:receipt_bytes, _}} =
               NVRArchiveReceipt.parse_receipt_bytes(String.duplicate("x", 8193))

      assert {:error, {:receipt_bytes, _}} =
               NVRArchiveReceipt.parse_receipt_bytes(
                 Jason.encode!(%{"storage_id" => @storage_id})
               )
    end
  end

  describe "RecordingOperation validations and effective_state/2" do
    test "effective_state reads outcome_unknown when running past deadline_at and preserves terminal states" do
      started = ~U[2026-11-15 12:00:00.000000Z]
      deadline = ~U[2026-11-15 12:05:00.000000Z]

      running = %{state: :running, started_at: started, deadline_at: deadline}

      assert RecordingOperation.effective_state(running, ~U[2026-11-15 12:04:59.999999Z]) ==
               :running

      assert RecordingOperation.effective_state(running, ~U[2026-11-15 12:05:00.000000Z]) ==
               :running

      assert RecordingOperation.effective_state(running, ~U[2026-11-15 12:05:00.000001Z]) ==
               :outcome_unknown

      for terminal <- [:succeeded, :failed, :outcome_unknown] do
        assert RecordingOperation.effective_state(
                 %{state: terminal, deadline_at: deadline},
                 ~U[2026-11-15 13:00:00.000000Z]
               ) == terminal
      end
    end

    test "rejects credential keys in result_summary and invalid start deadlines independently" do
      system = %{id: "system:test", role: :system}

      summary_changeset =
        Ash.Changeset.for_create(
          RecordingOperation,
          :start,
          %{
            kind: :destination_test,
            actor_id: "admin-1",
            member_name: "serviceradar-nvr-0",
            started_at: ~U[2026-11-15 12:05:00.000000Z],
            deadline_at: ~U[2026-11-15 12:10:00.000000Z],
            result_summary: %{"nested" => %{"secret_access_key" => "invented"}}
          },
          actor: system
        )

      refute summary_changeset.valid?
      assert Enum.map(summary_changeset.errors, & &1.field) == [:result_summary]

      deadline_changeset =
        Ash.Changeset.for_create(
          RecordingOperation,
          :start,
          %{
            kind: :destination_test,
            actor_id: "admin-1",
            member_name: "serviceradar-nvr-0",
            started_at: ~U[2026-11-15 12:05:00.000000Z],
            deadline_at: ~U[2026-11-15 12:04:00.000000Z],
            result_summary: %{"stage" => "starting"}
          },
          actor: system
        )

      refute deadline_changeset.valid?
      assert Enum.map(deadline_changeset.errors, & &1.field) == [:deadline_at]
    end
  end

  describe "RecordingBlocks.operator_page/3 and scope.permissions authorization" do
    test "preserves scope.permissions for custom RBAC profiles when actor: is omitted" do
      custom_view_scope = %{
        user: %{id: "u1", role: :operator},
        permissions: MapSet.new(["settings.recording.view"])
      }

      assert {:ok, overview} =
               RecordingArchiveSettings.get_overview(
                 scope: custom_view_scope,
                 loaders: %{settings_loader: fn -> {:ok, nil} end}
               )

      assert overview.persisted? == false

      assert {:error, :invalid_camera_source_id} =
               RecordingBlocks.operator_page("not-a-uuid", [], scope: custom_view_scope)

      custom_manage_scope = %{
        user: %{id: "u2", role: :operator},
        permissions: MapSet.new(["settings.recording.manage"])
      }

      assert {:ok, registered} =
               ArchiveDestinations.register_operator(
                 %{
                   name: "scoped-dest",
                   endpoint: "https://objects.example.com",
                   region: "example-1",
                   bucket: "example-archive",
                   namespace: "recordings/v1"
                 },
                 scope: custom_manage_scope,
                 register_fn: fn normalized -> {:ok, normalized} end
               )

      assert registered.provisioning_ref == "operator:scoped-dest"
    end

    test "denies callers without settings.recording.view including footage-only viewers" do
      footage_only = %{
        id: "user-footage",
        role: :viewer,
        permissions: MapSet.new(["devices.cameras.recordings.view"])
      }

      assert {:error, %Forbidden{}} =
               RecordingBlocks.operator_page(@camera_id, [], actor: footage_only)

      viewer = %{
        id: "user-recording-viewer",
        role: :admin,
        permissions: MapSet.new(["settings.recording.view"])
      }

      assert {:error, :invalid_camera_source_id} =
               RecordingBlocks.operator_page("not-a-uuid", [], actor: viewer)

      assert {:error, :invalid_page_limit} =
               RecordingBlocks.operator_page(@camera_id, [limit: 0], actor: viewer)

      {:error, :invalid_storage_id} =
        RecordingBlocks.operator_page(
          @camera_id,
          [storage_ids: ["not-a-uuid"]],
          actor: viewer
        )
    end
  end

  describe "RecordingArchiveSettings E1 mode+value, watermark, and confirmation validations" do
    test "validates every E1 mode+value pair, watermarks, split-permission retention credential, and confirmation stamps" do
      admin = %{
        id: "admin-retention",
        role: :admin,
        permissions: MapSet.new(["settings.recording.manage", "settings.credentials.manage"])
      }

      recording_only = %{
        id: "operator-retention",
        role: :operator,
        permissions: MapSet.new(["settings.recording.manage"])
      }

      loaders = %{
        binding_loader: fn @binding_id -> {:ok, %{id: @binding_id}} end,
        secret_loader: fn @retention_id ->
          {:ok,
           %{
             id: @retention_id,
             name: "Retention S3",
             provider: "s3_compatible",
             credential_kind: :opaque
           }}
        end
      }

      # Split-permission denial on retention_credential_secret_id without settings.credentials.manage
      split_cs =
        RecordingArchiveSettings.preview_changeset(
          %{retention_credential_secret_id: @retention_id},
          actor: recording_only,
          loaders: loaders
        )

      refute split_cs.valid?
      assert Enum.map(split_cs.errors, & &1.field) == [:retention_credential_secret_id]

      # Enabling archive_enabled without an active binding is refused on :archive_enabled
      no_binding_cs =
        RecordingArchiveSettings.preview_changeset(
          %{archive_enabled: true, active_archive_binding_id: nil},
          actor: admin,
          loaders: loaders
        )

      refute no_binding_cs.valid?
      assert :archive_enabled in Enum.map(no_binding_cs.errors, & &1.field)

      # Invalid watermark bounds (high out of 50..95; low > high - 5; low < 40)
      for {bad_attrs, expected_field} <- [
            {%{local_high_water_percent: 96}, :local_high_water_percent},
            {%{local_high_water_percent: 85, local_low_water_percent: 81},
             :local_low_water_percent},
            {%{local_low_water_percent: 39}, :local_low_water_percent},
            {%{object_high_water_percent: 49}, :object_high_water_percent},
            {%{object_high_water_percent: 80, object_low_water_percent: 76},
             :object_low_water_percent},
            {%{max_local_age_mode: :limited, max_local_age_seconds: nil}, :max_local_age_seconds},
            {%{max_local_age_mode: :limited, max_local_age_seconds: 3_599},
             :max_local_age_seconds},
            {%{max_local_age_mode: :unlimited, max_local_age_seconds: 86_400},
             :max_local_age_seconds},
            {%{local_window_alert_mode: :enabled, local_window_alert_seconds: 59},
             :local_window_alert_seconds},
            {%{local_window_alert_mode: :disabled, local_window_alert_seconds: 3_600},
             :local_window_alert_seconds},
            {%{local_only_target_mode: :target, local_only_retention_target_seconds: nil},
             :local_only_retention_target_seconds},
            {%{local_only_target_mode: :none, local_only_retention_target_seconds: 86_400},
             :local_only_retention_target_seconds},
            {%{local_only_max_age_mode: :limited, local_only_max_age_seconds: nil},
             :local_only_max_age_seconds},
            {%{local_only_max_age_mode: :unlimited, local_only_max_age_seconds: 7_200},
             :local_only_max_age_seconds},
            {%{archive_retention_mode: :limited, archive_retention_days: 0},
             :archive_retention_days},
            {%{archive_retention_mode: :limited, archive_retention_days: 3_651},
             :archive_retention_days},
            {%{archive_retention_mode: :unlimited, archive_retention_days: 30},
             :archive_retention_days},
            {%{
               object_budget_mode: :limited,
               object_budget_bytes: nil,
               object_capacity_policy: :reap_oldest
             }, :object_budget_bytes},
            {%{
               object_budget_mode: :limited,
               object_budget_bytes: 1_073_741_823,
               object_capacity_policy: :reap_oldest
             }, :object_budget_bytes},
            {%{object_budget_mode: :unlimited, object_budget_bytes: 1_073_741_824},
             :object_budget_bytes},
            {%{
               object_budget_mode: :limited,
               object_budget_bytes: 1_073_741_824,
               object_capacity_policy: nil
             }, :object_capacity_policy}
          ] do
        cs = RecordingArchiveSettings.preview_changeset(bad_attrs, actor: admin, loaders: loaders)
        refute cs.valid?, "expected #{inspect(bad_attrs)} to be invalid"
        assert expected_field in Enum.map(cs.errors, & &1.field)
      end

      # Shorter archive retention than max_local_age is ACCEPTED with advisory warning flag
      now = ~U[2026-11-16 12:30:00.000000Z]

      valid_cs =
        RecordingArchiveSettings.preview_changeset(
          %{
            retention_credential_secret_id: @retention_id,
            max_local_age_mode: :limited,
            max_local_age_seconds: 172_800,
            archive_retention_mode: :limited,
            archive_retention_days: 1,
            local_only_full_policy: :overwrite_oldest,
            object_budget_mode: :limited,
            object_budget_bytes: 10_737_418_240,
            object_capacity_policy: :reap_oldest
          },
          actor: admin,
          loaders: loaders,
          now: now
        )

      assert valid_cs.valid?

      assert Ash.Changeset.get_attribute(valid_cs, :local_only_full_policy_confirmed_by_id) ==
               "admin-retention"

      assert Ash.Changeset.get_attribute(valid_cs, :local_only_full_policy_confirmed_at) == now

      assert Ash.Changeset.get_attribute(valid_cs, :object_capacity_policy_confirmed_by_id) ==
               "admin-retention"

      assert Ash.Changeset.get_attribute(valid_cs, :object_capacity_policy_confirmed_at) == now

      assert RecordingArchiveSettings.shorter_archive_than_local?(%{
               max_local_age_mode: :limited,
               max_local_age_seconds: 172_800,
               archive_retention_mode: :limited,
               archive_retention_days: 1
             }) == true

      # get_overview exposes retention_credential and object_retention_enforced?
      assert {:ok, enforced_overview} =
               RecordingArchiveSettings.get_overview(
                 actor: recording_only,
                 loaders:
                   Map.put(loaders, :settings_loader, fn ->
                     {:ok,
                      %{
                        RecordingArchiveSettings.default_settings()
                        | retention_credential_secret_id: @retention_id,
                          max_local_age_mode: :limited,
                          max_local_age_seconds: 172_800,
                          archive_retention_mode: :limited,
                          archive_retention_days: 1
                      }}
                   end)
               )

      assert enforced_overview.object_retention_enforced? == true
      assert enforced_overview.shorter_archive_than_local? == true
      assert enforced_overview.retention_credential.name == "Retention S3"
    end
  end
end
