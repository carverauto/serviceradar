defmodule ServiceRadarCoreElx.CameraRecording.ArchiveBlockJobTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Ash.Error.Changes.InvalidArgument
  alias ServiceRadar.Camera.ArchiveDestination
  alias ServiceRadar.Camera.NVRArchiveReceipt
  alias ServiceRadar.Camera.RecordingPubSub
  alias ServiceRadarCoreElx.CameraRecording.ArchiveBlockJob
  alias ServiceRadarCoreElx.CameraRecording.NVRArchive
  alias ServiceRadarCoreElx.Test.StorageHTTPFixture, as: Fixture
  alias ServiceRadarRecordingMetadata.CanonicalJSON

  @moduletag :tmp_dir

  @entry_id "00000000-0000-4000-8000-000000000101"
  @block_row_id "00000000-0000-4000-8000-000000000102"
  @camera_id "00000000-0000-4000-8000-000000000103"
  @profile_id "00000000-0000-4000-8000-000000000104"
  @member "serviceradar-nvr-0"
  @storage_id "00000000-0000-4000-8000-000000000011"
  @recovery_generation "00000000-0000-4000-8000-000000000021"
  @binding_id "00000000-0000-4000-8000-000000000031"
  @secret_id "00000000-0000-4000-8000-000000000041"
  @block_key String.duplicate("0123456789abcdef", 4)
  @token "synthetic-nvr-archive-token-0123456789"
  @access_key_id "EXAMPLEARCHIVEWRITER01"
  @secret_access_key "invented-archive-writer-secret-material"
  @fixed_now ~U[2026-11-22 05:00:00.000000Z]

  @destination %{
    "host" => "objects.example.com",
    "region" => "example-region-1",
    "bucket" => "example-archive",
    "object_prefix" => "recordings/v1"
  }

  describe "Oban worker configuration and backoff" do
    test "uses dedicated nvr_archive queue and uniqueness without executing orphan stall" do
      opts = ArchiveBlockJob.__opts__()

      assert opts[:queue] == :nvr_archive
      assert opts[:max_attempts] == 20

      unique = Keyword.fetch!(opts, :unique)
      assert unique[:period] == :infinity
      assert unique[:keys] == [:catalog_entry_id]
      assert unique[:states] == [:available, :scheduled, :retryable]
      refute :executing in unique[:states]
    end

    test "computes jittered exponential backoff from 30s doubling to 30m cap" do
      assert ArchiveBlockJob.retry_backoff_seconds(1, fn -> 0.0 end) == 30
      assert ArchiveBlockJob.retry_backoff_seconds(2, fn -> 0.0 end) == 60
      assert ArchiveBlockJob.retry_backoff_seconds(3, fn -> 0.0 end) == 120
      assert ArchiveBlockJob.retry_backoff_seconds(4, fn -> 0.0 end) == 240
      assert ArchiveBlockJob.retry_backoff_seconds(5, fn -> 0.0 end) == 480
      assert ArchiveBlockJob.retry_backoff_seconds(6, fn -> 0.0 end) == 960
      assert ArchiveBlockJob.retry_backoff_seconds(7, fn -> 0.0 end) == 1_800
      assert ArchiveBlockJob.retry_backoff_seconds(15, fn -> 0.0 end) == 1_800

      # With jitter (up to +20%), stays within [base, min(base*1.2, 1800)]
      assert ArchiveBlockJob.retry_backoff_seconds(1, fn -> 0.5 end) == 33
      assert ArchiveBlockJob.retry_backoff_seconds(7, fn -> 1.0 end) == 1_800

      job_backoff = ArchiveBlockJob.backoff(%Oban.Job{attempt: 2})
      assert job_backoff in 60..72
    end

    test "cancels jobs with missing or invalid catalog_entry_id" do
      assert {:cancel, :invalid_catalog_entry_id} = ArchiveBlockJob.perform(%Oban.Job{args: %{}})
      assert {:cancel, :invalid_catalog_entry_id} = ArchiveBlockJob.run("not-a-uuid")
    end
  end

  describe "happy path and end-to-end NVRArchive integration" do
    test "archives a pending block through NVRArchive, validates receipt bytes, and commits verified state", ctx do
      {:ok, _} = Application.ensure_all_started(:ssl)
      prev_enabled = Application.get_env(:serviceradar_core_elx, :camera_recording_enabled)
      prev_gate = Application.get_env(:serviceradar_core, :nvr_recovery_gate)

      on_exit(fn ->
        Application.put_env(:serviceradar_core_elx, :camera_recording_enabled, prev_enabled)
        Application.put_env(:serviceradar_core, :nvr_recovery_gate, prev_gate)
      end)

      dir = Path.expand(ctx.tmp_dir)
      gate_path = Path.join(dir, "recovery-state.json")
      File.write!(gate_path, ~s({"generation":"#{@recovery_generation}","state":"ready"}))
      Application.put_env(:serviceradar_core, :nvr_recovery_gate, %{generation: @recovery_generation, path: gate_path})
      Application.put_env(:serviceradar_core_elx, :camera_recording_enabled, true)

      certs = generate_certs()
      parent = self()

      port =
        Fixture.start(certs.server_config, fn request ->
          send(parent, {:nvr_request, request})
          {200, %{"content-type" => "application/json"}, Jason.encode!(receipt())}
        end)

      archive_opts = nvr_opts(dir, certs, port, secret())
      binding = archive_binding()

      opts =
        entry()
        |> base_opts(
          binding: binding,
          archive_opts: archive_opts,
          archive_fn: &NVRArchive.archive_block/5,
          commit_verified_fn: fn committed_entry, committed_binding, receipt_bytes, now ->
            send(parent, {:committed, committed_entry.id, committed_binding.id, receipt_bytes, now})
            {:ok, :verified}
          end
        )
        |> Keyword.delete(:member_resolver)

      {result, log} = with_log(fn -> ArchiveBlockJob.run(@entry_id, opts) end)

      assert result == :ok
      assert_receive {:nvr_request, request}
      assert request.target == "/v1/blocks/#{@block_key}/archive"

      assert_receive {:committed, @entry_id, @binding_id, receipt_bytes, @fixed_now}
      assert {:ok, expected_canonical} = CanonicalJSON.encode(receipt())
      assert receipt_bytes == expected_canonical
      assert {:ok, parsed} = NVRArchiveReceipt.parse_receipt_bytes(receipt_bytes)
      assert parsed.storage_id == @storage_id
      assert parsed.block_key == @block_key
      assert length(parsed.objects) == 3

      refute log =~ @access_key_id
      refute log =~ @secret_access_key
    end

    # credo:disable-for-next-line Jump.CredoChecks.TooManyAssertions
    test "classifies mTLS NVR wire refusals, tampered receipts, busy 503, and closed gate", ctx do
      {:ok, _} = Application.ensure_all_started(:ssl)
      prev_enabled = Application.get_env(:serviceradar_core_elx, :camera_recording_enabled)
      prev_gate = Application.get_env(:serviceradar_core, :nvr_recovery_gate)

      on_exit(fn ->
        Application.put_env(:serviceradar_core_elx, :camera_recording_enabled, prev_enabled)
        Application.put_env(:serviceradar_core, :nvr_recovery_gate, prev_gate)
      end)

      dir = Path.expand(ctx.tmp_dir)
      gate_path = Path.join(dir, "recovery-state.json")
      File.write!(gate_path, ~s({"generation":"#{@recovery_generation}","state":"ready"}))
      Application.put_env(:serviceradar_core, :nvr_recovery_gate, %{generation: @recovery_generation, path: gate_path})
      Application.put_env(:serviceradar_core_elx, :camera_recording_enabled, true)

      certs = generate_certs()
      parent = self()
      {:ok, reply_agent} = Agent.start_link(fn -> nil end)

      port =
        Fixture.start(certs.server_config, fn request ->
          send(parent, {:nvr_request, request.target})
          Agent.get(reply_agent, & &1)
        end)

      archive_opts = nvr_opts(dir, certs, port, secret())
      binding = archive_binding()

      transition_fn = fn _entry, attrs ->
        send(parent, {:transitioned, attrs})
        {:ok, entry(attrs)}
      end

      wire_opts = fn ->
        entry()
        |> base_opts(
          binding: binding,
          archive_opts: archive_opts,
          archive_fn: &NVRArchive.archive_block/5,
          transition_entry_fn: transition_fn,
          rand_fn: fn -> 0.0 end
        )
        |> Keyword.delete(:member_resolver)
      end

      json_headers = %{"content-type" => "application/json"}

      # 503 archive_busy over mTLS snoozes without mutating catalog state.
      Agent.update(reply_agent, fn _ -> {503, json_headers, Jason.encode!(%{"error" => "archive_busy"})} end)
      {busy_res, busy_log} = with_log(fn -> ArchiveBlockJob.run(@entry_id, wire_opts.()) end)
      assert {:snooze, busy_seconds} = busy_res
      assert busy_seconds in 10..15
      assert_receive {:nvr_request, "/v1/blocks/" <> _}
      refute_received {:transitioned, _}
      refute busy_log =~ @access_key_id
      refute busy_log =~ @secret_access_key

      # 409 archive_receipt_conflict and 422 over mTLS transition to failed_terminal and discard.
      for {status, err} <- [{409, "archive_receipt_conflict"}, {422, "block_too_large"}] do
        Agent.update(reply_agent, fn _ -> {status, json_headers, Jason.encode!(%{"error" => err})} end)
        {res, log} = with_log(fn -> ArchiveBlockJob.run(@entry_id, wire_opts.()) end)
        assert {:discard, ^err} = res
        assert_receive {:nvr_request, "/v1/blocks/" <> _}
        assert_receive {:transitioned, %{archive_state: :failed_terminal, archive_last_error_class: ^err}}
        refute log =~ @access_key_id
        refute log =~ @secret_access_key
      end

      # 502 archive_failed over mTLS transitions to failed_retryable and snoozes.
      Agent.update(reply_agent, fn _ -> {502, json_headers, Jason.encode!(%{"error" => "archive_failed"})} end)
      {err_res, err_log} = with_log(fn -> ArchiveBlockJob.run(@entry_id, wire_opts.()) end)
      assert {:snooze, 30} = err_res
      assert_receive {:nvr_request, "/v1/blocks/" <> _}
      assert_receive {:transitioned, %{archive_state: :failed_retryable, archive_last_error_class: "archive_failed"}}
      refute err_log =~ @access_key_id
      refute err_log =~ @secret_access_key

      # 200 with mismatched block_id is rejected by ServiceRadarNVRClient.Wire as :outcome_unknown.
      tampered = Map.put(receipt(), "block_id", String.duplicate("fedcba9876543210", 4))
      Agent.update(reply_agent, fn _ -> {200, json_headers, Jason.encode!(tampered)} end)
      {tampered_res, tampered_log} = with_log(fn -> ArchiveBlockJob.run(@entry_id, wire_opts.()) end)
      assert {:snooze, 30} = tampered_res
      assert_receive {:nvr_request, "/v1/blocks/" <> _}
      assert_receive {:transitioned, %{archive_state: :failed_retryable, archive_last_error_class: "outcome_unknown"}}
      refute tampered_log =~ @access_key_id
      refute tampered_log =~ @secret_access_key

      # Closed recovery gate snoozes 60s without contacting NVR or mutating catalog state.
      File.write!(gate_path, ~s({"generation":"#{@recovery_generation}","state":"closed"}))
      {closed_res, closed_log} = with_log(fn -> ArchiveBlockJob.run(@entry_id, wire_opts.()) end)
      assert {:snooze, 60} = closed_res
      refute_received {:nvr_request, _}
      refute_received {:transitioned, _}
      refute closed_log =~ @access_key_id
      refute closed_log =~ @secret_access_key
    end
  end

  describe "idempotent skips and Transition 5" do
    test "skips cleanly without uploading when entry is absent, already verified, not_required, or not locally present" do
      parent = self()

      archive_fn = fn _member, _key, _binding, _secret, _opts ->
        send(parent, :unexpected_archive_call)
        {:ok, receipt()}
      end

      assert :ok =
               ArchiveBlockJob.run(@entry_id,
                 entry_loader: fn @entry_id -> {:ok, nil} end,
                 archive_fn: archive_fn
               )

      for overrides <- [
            %{archive_state: :verified},
            %{archive_state: :not_required},
            %{archive_state: :failed_terminal},
            %{archive_state: :deleted},
            %{local_state: :reclaimed},
            %{archive_state: :failed_retryable, local_state: :reclaimed},
            %{local_state: :missing},
            %{local_state: :quarantined}
          ] do
        opts = base_opts(entry(overrides), archive_fn: archive_fn)
        assert :ok = ArchiveBlockJob.run(@entry_id, opts)
      end

      refute_received :unexpected_archive_call
    end

    test "transitions to not_required when deployment archiving is disabled or policy is local_only" do
      parent = self()

      transition_fn = fn _entry, attrs ->
        send(parent, {:transitioned, attrs})
        {:ok, entry(attrs)}
      end

      archive_fn = fn _member, _key, _binding, _secret, _opts ->
        send(parent, :unexpected_archive_call)
        {:ok, receipt()}
      end

      assert :ok =
               ArchiveBlockJob.run(
                 @entry_id,
                 base_opts(entry(),
                   settings: settings(%{archive_enabled: false}),
                   archive_fn: archive_fn,
                   transition_entry_fn: transition_fn
                 )
               )

      assert_receive {:transitioned, %{archive_state: :not_required, archive_last_error_class: nil}}

      assert :ok =
               ArchiveBlockJob.run(
                 @entry_id,
                 base_opts(entry(),
                   policy: %{storage: :local_only},
                   archive_fn: archive_fn,
                   transition_entry_fn: transition_fn
                 )
               )

      assert_receive {:transitioned, %{archive_state: :not_required, archive_last_error_class: nil}}
      refute_received :unexpected_archive_call
    end

    test "retries without uploading when camera policy lookup fails, while nil policy remains owed" do
      parent = self()

      transition_fn = fn _entry, attrs ->
        send(parent, {:transitioned, attrs})
        {:ok, entry(attrs)}
      end

      archive_fn = fn _member, _key, _binding, _secret, _opts ->
        send(parent, :archive_called)
        {:ok, receipt()}
      end

      assert {:snooze, 30} =
               ArchiveBlockJob.run(
                 @entry_id,
                 base_opts(entry(),
                   policy_loader: fn _entry -> {:error, :db_unavailable} end,
                   archive_fn: archive_fn,
                   transition_entry_fn: transition_fn,
                   rand_fn: fn -> 0.0 end
                 )
               )

      refute_received :archive_called

      assert_receive {:transitioned,
                      %{
                        archive_state: :failed_retryable,
                        archive_attempts: 1,
                        archive_last_error_class: "db_unavailable"
                      }}

      assert :ok =
               ArchiveBlockJob.run(
                 @entry_id,
                 base_opts(entry(),
                   policy_loader: fn _entry -> {:ok, nil} end,
                   archive_fn: archive_fn
                 )
               )

      assert_receive :archive_called
    end
  end

  describe "held jobs, transient retry/snooze, and terminal refusals" do
    test "snoozes without mutating catalog state when archive uploads are held or NVR is busy" do
      parent = self()

      transition_fn = fn _entry, attrs ->
        send(parent, {:unexpected_transition, attrs})
        {:ok, entry(attrs)}
      end

      assert {:snooze, 60} =
               ArchiveBlockJob.run(
                 @entry_id,
                 base_opts(entry(),
                   archive_uploads_held_fn: fn -> {true, :recording_suspended} end,
                   transition_entry_fn: transition_fn
                 )
               )

      assert {:snooze, 12} =
               ArchiveBlockJob.run(
                 @entry_id,
                 base_opts(entry(),
                   busy_snooze_seconds: 12,
                   archive_fn: fn _m, _k, _b, _s, _o ->
                     {:error, {:archive_status, 503, %{"error" => "archive_busy"}}}
                   end,
                   transition_entry_fn: transition_fn
                 )
               )

      assert {:snooze, 60} =
               ArchiveBlockJob.run(
                 @entry_id,
                 base_opts(entry(),
                   archive_fn: fn _m, _k, _b, _s, _o -> {:error, :nvr_recovery_closed} end,
                   transition_entry_fn: transition_fn
                 )
               )

      refute_received {:unexpected_transition, _}
    end

    test "transitions to failed_retryable and snoozes with exponential backoff for retryable failures" do
      parent = self()

      transition_fn = fn _entry, attrs ->
        send(parent, {:transitioned, attrs})
        {:ok, entry(attrs)}
      end

      cases = [
        {{:error, {:archive_status, 502, %{"error" => "archive_failed"}}}, "archive_failed"},
        {{:error, {:archive_status, 503, %{"error" => "archive_unavailable"}}}, "archive_unavailable"},
        {{:error, {:archive_status, 400, %{"error" => "invalid_archive_request"}}}, "invalid_archive_request"},
        {{:error, {:archive_status, 404, %{"error" => "block_not_found"}}}, "block_not_found"},
        {{:error, {:archive_status, 409, %{"error" => "block_not_sealed"}}}, "block_not_sealed"},
        {{:error, :invalid_archive_binding}, "invalid_archive_binding"},
        {{:error, :invalid_archive_request}, "invalid_archive_request"},
        {{:error, :invalid_block_id}, "invalid_block_id"},
        {{:error, :outcome_unknown}, "outcome_unknown"},
        {{:error, {:archive_credential_unavailable, :credential_secret_inactive}},
         "credential_credential_secret_inactive"}
      ]

      for {archive_result, expected_class} <- cases do
        opts =
          base_opts(entry(%{archive_attempts: 2}),
            archive_fn: fn _m, _k, _b, _s, _o -> archive_result end,
            transition_entry_fn: transition_fn,
            rand_fn: fn -> 0.0 end
          )

        assert {:snooze, 120} = ArchiveBlockJob.run(@entry_id, opts)

        assert_receive {:transitioned,
                        %{
                          archive_state: :failed_retryable,
                          archive_attempts: 3,
                          archive_last_error_class: ^expected_class,
                          archive_state_at: @fixed_now
                        }}
      end

      # Missing writer credential secret on settings
      assert {:snooze, 30} =
               ArchiveBlockJob.run(
                 @entry_id,
                 base_opts(entry(),
                   settings: settings(%{writer_credential_secret_id: nil}),
                   transition_entry_fn: transition_fn,
                   rand_fn: fn -> 0.0 end
                 )
               )

      assert_receive {:transitioned,
                      %{
                        archive_state: :failed_retryable,
                        archive_attempts: 1,
                        archive_last_error_class: "archive_credential_unavailable"
                      }}

      # Missing active archive binding is retryable rather than permanently terminal
      assert {:snooze, 30} =
               ArchiveBlockJob.run(
                 @entry_id,
                 base_opts(entry(%{archive_binding_id: nil}),
                   settings: settings(%{active_archive_binding_id: nil}),
                   transition_entry_fn: transition_fn,
                   rand_fn: fn -> 0.0 end
                 )
               )

      assert_receive {:transitioned,
                      %{
                        archive_state: :failed_retryable,
                        archive_attempts: 1,
                        archive_last_error_class: "archive_binding_missing"
                      }}
    end

    test "retries indefinitely past 20 attempts via snooze capped at 1800s without exhausting max_attempts" do
      parent = self()

      transition_fn = fn _entry, attrs ->
        send(parent, {:transitioned, attrs})
        {:ok, entry(attrs)}
      end

      opts =
        base_opts(entry(%{archive_state: :failed_retryable, archive_attempts: 25}),
          archive_fn: fn _m, _k, _b, _s, _o -> {:error, :outcome_unknown} end,
          transition_entry_fn: transition_fn,
          rand_fn: fn -> 0.0 end
        )

      assert {:snooze, 1_800} = ArchiveBlockJob.run(@entry_id, opts)

      assert_receive {:transitioned,
                      %{
                        archive_state: :failed_retryable,
                        archive_attempts: 26,
                        archive_last_error_class: "outcome_unknown"
                      }}
    end

    test "held and busy snoozes do not advance failure backoff when the hold ends" do
      current = entry(%{archive_attempts: 0})

      assert {:snooze, 60} =
               ArchiveBlockJob.run(
                 @entry_id,
                 base_opts(current,
                   archive_uploads_held_fn: fn -> {true, :recording_suspended} end
                 )
               )

      assert {:snooze, 30} =
               ArchiveBlockJob.run(
                 @entry_id,
                 base_opts(current,
                   archive_fn: fn _m, _k, _b, _s, _o -> {:error, :outcome_unknown} end,
                   rand_fn: fn -> 0.0 end
                 )
               )
    end

    test "snoozes on catalog load or state transition database failures instead of discarding" do
      assert {:snooze, 30} =
               ArchiveBlockJob.run(
                 @entry_id,
                 rand_fn: fn -> 0.0 end,
                 entry_loader: fn @entry_id -> {:error, :db_unavailable} end
               )

      failing_transition = fn _entry, _attrs -> {:error, :db_unavailable} end

      assert {:snooze, 60} =
               ArchiveBlockJob.run(
                 @entry_id,
                 base_opts(entry(%{archive_attempts: 1}),
                   archive_fn: fn _m, _k, _b, _s, _o ->
                     {:error, {:archive_status, 409, %{"error" => "archive_receipt_conflict"}}}
                   end,
                   transition_entry_fn: failing_transition,
                   rand_fn: fn -> 0.0 end
                 )
               )

      assert {:snooze, 30} =
               ArchiveBlockJob.run(
                 @entry_id,
                 base_opts(entry(),
                   settings: settings(%{archive_enabled: false}),
                   transition_entry_fn: failing_transition,
                   rand_fn: fn -> 0.0 end
                 )
               )
    end

    test "transitions to failed_terminal and discards on 409 archive_receipt_conflict or 422" do
      parent = self()

      transition_fn = fn _entry, attrs ->
        send(parent, {:transitioned, attrs})
        {:ok, entry(attrs)}
      end

      terminal_cases = [
        {{:error, {:archive_status, 409, %{"error" => "archive_receipt_conflict"}}}, "archive_receipt_conflict"},
        {{:error, {:archive_status, 422, %{"error" => "block_too_large"}}}, "block_too_large"}
      ]

      for {archive_result, expected_class} <- terminal_cases do
        opts =
          base_opts(entry(),
            archive_fn: fn _m, _k, _b, _s, _o -> archive_result end,
            transition_entry_fn: transition_fn
          )

        {result, _log} = with_log(fn -> ArchiveBlockJob.run(@entry_id, opts) end)

        assert {:discard, ^expected_class} = result

        assert_receive {:transitioned,
                        %{
                          archive_state: :failed_terminal,
                          archive_attempts: 1,
                          archive_last_error_class: ^expected_class,
                          archive_state_at: @fixed_now
                        }}
      end
    end

    test "transitions to failed_terminal and discards on Ash retained-receipt conflict errors from commit" do
      parent = self()

      transition_fn = fn _entry, attrs ->
        send(parent, {:transitioned, attrs})
        {:ok, entry(attrs)}
      end

      conflict_arg =
        InvalidArgument.exception(
          field: :receipt_bytes,
          message: "nvr archive receipt conflicts with retained record"
        )

      conflict_shapes = [
        # Exact shape rolled back by Ash.Changeset.with_hooks inside Repo.transaction
        conflict_arg,
        # Exact shape returned by Ash.create / Ash.Error.to_error_class
        Ash.Error.to_error_class(conflict_arg),
        # Exact shape rolled back by Ash.Actions.Helpers.rollback_if_in_transaction
        Ash.Changeset.add_error(Ash.Changeset.new(NVRArchiveReceipt), conflict_arg)
      ]

      for error_shape <- conflict_shapes do
        opts =
          base_opts(entry(),
            commit_verified_fn: fn _entry, _binding, _bytes, _now -> {:error, error_shape} end,
            transition_entry_fn: transition_fn,
            rand_fn: fn -> 0.0 end
          )

        {result, _log} = with_log(fn -> ArchiveBlockJob.run(@entry_id, opts) end)

        assert {:discard, "archive_receipt_conflict"} = result

        assert_receive {:transitioned,
                        %{
                          archive_state: :failed_terminal,
                          archive_attempts: 1,
                          archive_last_error_class: "archive_receipt_conflict",
                          archive_state_at: @fixed_now
                        }}
      end

      non_conflict_shapes = [
        InvalidArgument.exception(field: :receipt_bytes, message: "must be 1..8192 bytes"),
        Ash.Error.to_error_class(
          InvalidArgument.exception(
            field: :archive_binding_id,
            message: "receipt destination fields do not match archive binding"
          )
        )
      ]

      for error_shape <- non_conflict_shapes do
        opts =
          base_opts(entry(),
            commit_verified_fn: fn _entry, _binding, _bytes, _now -> {:error, error_shape} end,
            transition_entry_fn: transition_fn,
            rand_fn: fn -> 0.0 end
          )

        assert {:snooze, 30} = ArchiveBlockJob.run(@entry_id, opts)

        assert_receive {:transitioned,
                        %{
                          archive_state: :failed_retryable,
                          archive_attempts: 1,
                          archive_last_error_class: "archive_commit_failed",
                          archive_state_at: @fixed_now
                        }}
      end
    end
  end

  describe "NVRWorker best-effort enqueue_for_entry/2" do
    test "enqueues when archive_state is :pending and skips when :not_required or :verified" do
      parent = self()

      insert_opts = [
        available_fun: fn -> true end,
        insert_fun: fn changeset ->
          send(parent, {:oban_insert, changeset})
          {:ok, %Oban.Job{id: 42, queue: "nvr_archive", args: changeset.changes.args}}
        end
      ]

      assert {:ok, %Oban.Job{id: 42}} =
               ArchiveBlockJob.enqueue_for_entry(%{id: @entry_id, archive_state: :pending}, insert_opts)

      assert_receive {:oban_insert, changeset}
      assert changeset.changes.queue == "nvr_archive"
      assert changeset.changes.args == %{"catalog_entry_id" => @entry_id}

      assert :skipped =
               ArchiveBlockJob.enqueue_for_entry(%{id: @entry_id, archive_state: :not_required}, insert_opts)

      assert :skipped =
               ArchiveBlockJob.enqueue_for_entry(%{id: @entry_id, archive_state: :verified}, insert_opts)

      assert :skipped =
               ArchiveBlockJob.enqueue_for_entry(%{id: @entry_id, archive_state: :awaiting_binding}, insert_opts)

      refute_received {:oban_insert, _}
    end

    test "never raises or stalls caller when Oban is unavailable or insert fails" do
      assert {:error, :oban_unavailable} =
               ArchiveBlockJob.enqueue_for_entry(
                 %{id: @entry_id, archive_state: :pending},
                 available_fun: fn -> false end
               )

      {result, _log} =
        with_log(fn ->
          ArchiveBlockJob.enqueue_for_entry(
            %{id: @entry_id, archive_state: :pending},
            available_fun: fn -> true end,
            insert_fun: fn _job -> raise "boom" end
          )
        end)

      assert {:error, {:oban_unavailable, "boom"}} = result
    end
  end

  describe "PubSub timeline update broadcasts" do
    test "broadcasts archive_verified and archive_failed_terminal on ServiceRadar.PubSub when running" do
      if Process.whereis(ServiceRadar.PubSub) == nil do
        start_supervised!({Phoenix.PubSub, name: ServiceRadar.PubSub})
      end

      assert :ok = RecordingPubSub.subscribe(@camera_id)

      on_exit(fn ->
        RecordingPubSub.unsubscribe(@camera_id)
      end)

      assert :ok =
               ArchiveBlockJob.run(
                 @entry_id,
                 base_opts(entry(),
                   archive_fn: fn _m, _k, _b, _s, _o -> {:ok, receipt()} end,
                   commit_verified_fn: fn _entry, _binding, _bytes, _now -> {:ok, :verified} end
                 )
               )

      assert_receive {:camera_recording_updated, %{camera_source_id: @camera_id, reason: :archive_verified}}

      assert {:discard, "archive_receipt_conflict"} =
               ArchiveBlockJob.run(
                 @entry_id,
                 base_opts(entry(),
                   archive_fn: fn _m, _k, _b, _s, _o ->
                     {:error, {:archive_status, 409, %{"error" => "archive_receipt_conflict"}}}
                   end,
                   transition_entry_fn: fn _entry, attrs -> {:ok, entry(attrs)} end
                 )
               )

      assert_receive {:camera_recording_updated, %{camera_source_id: @camera_id, reason: :archive_failed_terminal}}
    end
  end

  defp base_opts(catalog_entry, overrides) do
    defaults = [
      entry_loader: fn @entry_id -> {:ok, catalog_entry} end,
      settings_loader: fn -> {:ok, Keyword.get(overrides, :settings, settings())} end,
      policy_loader: fn _entry -> {:ok, Keyword.get(overrides, :policy, %{storage: :local_and_archive})} end,
      archive_uploads_held_fn: fn -> {false, nil} end,
      binding_loader: fn @binding_id -> {:ok, Keyword.get(overrides, :binding, archive_binding())} end,
      member_resolver: fn @storage_id -> {:ok, @member} end,
      archive_fn: fn _m, _k, _b, _s, _o -> {:ok, receipt()} end,
      commit_verified_fn: fn _entry, _binding, _bytes, _now -> {:ok, :verified} end,
      transition_entry_fn: fn entry, attrs -> {:ok, Map.merge(entry, attrs)} end,
      now_fn: fn -> @fixed_now end
    ]

    overrides
    |> Keyword.drop([:settings, :policy, :binding])
    |> then(&Keyword.merge(defaults, &1))
  end

  defp entry(overrides \\ %{}) do
    Map.merge(
      %{
        id: @entry_id,
        recording_block_id: @block_row_id,
        camera_source_id: @camera_id,
        stream_profile_id: @profile_id,
        storage_id: @storage_id,
        block_key: @block_key,
        local_state: :present,
        archive_state: :pending,
        archive_binding_id: @binding_id,
        nvr_archive_receipt_id: nil,
        archive_attempts: 0,
        archive_last_error_class: nil
      },
      overrides
    )
  end

  defp settings(overrides \\ %{}) do
    Map.merge(
      %{
        archive_enabled: true,
        active_archive_binding_id: @binding_id,
        writer_credential_secret_id: @secret_id
      },
      overrides
    )
  end

  defp archive_binding do
    {:ok, attributes} =
      ArchiveDestination.attributes(%{
        "schema_version" => 1,
        "provisioning_ref" => "example-archive-binding",
        "generation" => 1,
        "purpose" => "recording",
        "provider" => "s3_compatible",
        "endpoint" => "https://objects.example.com",
        "region" => "example-region-1",
        "bucket" => "example-archive",
        "namespace" => "recordings/v1",
        "archive_format_version" => 1,
        "required_encryption" => "sse_s3_aes256"
      })

    Map.put(attributes, :id, @binding_id)
  end

  defp secret do
    %{id: @secret_id, provider: "s3_compatible", credential_kind: :opaque, enabled: true, deleted_at: nil}
  end

  defp receipt do
    prefix = "recordings/v1/#{@storage_id}/#{@block_key}/"

    %{
      "version" => 1,
      "storage_id" => @storage_id,
      "block_id" => @block_key,
      "destination" => @destination,
      "objects" =>
        Enum.map(["init.mp4", "media.m4s", "descriptor.json"], fn name ->
          %{
            "name" => name,
            "key" => prefix <> name,
            "length" => 4_096,
            "sha256" => String.duplicate("ab", 32),
            "etag" => ~s("example-etag")
          }
        end),
      "verified_at_ms" => 1_763_164_800_000
    }
  end

  defp generate_certs do
    algorithm = [{:digest, :sha256}, {:key, {:namedCurve, :secp256r1}}]
    san = {:Extension, {2, 5, 29, 17}, false, [dNSName: ~c"localhost"]}

    :public_key.pkix_test_data(%{
      server_chain: %{root: algorithm, intermediates: [], peer: algorithm ++ [extensions: [san]]},
      client_chain: %{root: algorithm, intermediates: [], peer: algorithm}
    })
  end

  defp nvr_opts(dir, certs, port, secret) do
    client = certs.client_config
    {key_type, key_der} = client[:key]
    roots = Enum.map(client[:cacerts], &{:Certificate, &1, :not_encrypted})
    ca = write(dir, "ca.pem", :public_key.pem_encode(roots))
    cert = write(dir, "client.pem", :public_key.pem_encode([{:Certificate, client[:cert], :not_encrypted}]))
    key = write(dir, "client-key.pem", :public_key.pem_encode([{key_type, key_der, :not_encrypted}]))
    token = write(dir, "nvr-token", @token)

    config =
      write(
        dir,
        "nvr-client.json",
        Jason.encode!(%{
          "version" => 1,
          "port" => port,
          "ca_file" => ca,
          "cert_file" => cert,
          "key_file" => key,
          "members" => %{@member => %{"host" => "localhost", "storage_id" => @storage_id}}
        })
      )

    payload = Jason.encode!(%{"access_key_id" => @access_key_id, "secret_access_key" => @secret_access_key})

    [
      config_file: config,
      token_file: token,
      secret_loader: fn @secret_id, _opts -> {:ok, secret} end,
      grant_issuer: fn attrs, _opts -> {:ok, attrs} end,
      broker: fn _grant, _opts -> {:ok, %{secret: secret, value: payload}} end
    ]
  end

  defp write(dir, name, bytes) do
    path = Path.join(dir, name)
    File.write!(path, bytes)
    path
  end
end
