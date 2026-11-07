defmodule ServiceRadar.NetworkDiscovery.TopologyProjectionWorkerTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias ServiceRadar.NetworkDiscovery.TopologyProjectionWorker

  @transient_abort_reason "dgraph (transient): Transaction Aborted: the server aborted this " <>
                            "transaction (Aborted: Transaction has been aborted. Please retry); " <>
                            "retry in a new transaction"

  @non_transient_reason "dgraph: canonical page lacks a consistent transaction timestamp"

  describe "transient_abort?/1" do
    test "matches Dgraph transaction abort messages" do
      assert TopologyProjectionWorker.transient_abort?(@transient_abort_reason)

      assert TopologyProjectionWorker.transient_abort?(
               "Transaction Aborted: the server aborted this transaction"
             )

      assert TopologyProjectionWorker.transient_abort?(
               "Aborted: Transaction has been aborted. Please retry"
             )

      assert TopologyProjectionWorker.transient_abort?({:dgraph_error, @transient_abort_reason})
    end

    test "rejects non-abort errors" do
      refute TopologyProjectionWorker.transient_abort?(@non_transient_reason)
      refute TopologyProjectionWorker.transient_abort?("dgraph url is not configured")

      refute TopologyProjectionWorker.transient_abort?(
               "dgraph (transient): connect to https://192.0.2.10:8080: connection refused"
             )

      refute TopologyProjectionWorker.transient_abort?(:timeout)
    end
  end

  describe "record_outcome/4 failure logging" do
    test "transient transaction abort while retries remain logs at info and not warning" do
      job = %Oban.Job{attempt: 1, max_attempts: 10}
      measurements = %{duration_ms: 12, queue_wait_ms: 4}
      metadata_keys = [:device_id, :attempt, :max_attempts, :reason]

      assert TopologyProjectionWorker.failure_log_level(job, @transient_abort_reason) == :info

      warning_log =
        capture_log([level: :warning, metadata: metadata_keys], fn ->
          assert {:error, @transient_abort_reason} =
                   TopologyProjectionWorker.record_outcome(
                     {:error, @transient_abort_reason},
                     "sr:device-retry-1",
                     job,
                     measurements
                   )
        end)

      refute warning_log =~ "Topology projection failed"
      refute warning_log =~ "sr:device-retry-1"

      info_log =
        capture_log([level: :info, metadata: metadata_keys], fn ->
          assert {:error, @transient_abort_reason} =
                   TopologyProjectionWorker.record_outcome(
                     {:error, @transient_abort_reason},
                     "sr:device-retry-1",
                     job,
                     measurements
                   )
        end)

      assert info_log =~ "[info]"
      assert info_log =~ "Topology projection failed; the graph lags CNPG until it succeeds"
      assert info_log =~ "device_id=sr:device-retry-1"
      assert info_log =~ "attempt=1"
      assert info_log =~ "max_attempts=10"
      assert info_log =~ "Transaction Aborted"
    end

    test "transient transaction abort when retries are exhausted logs at warning" do
      job = %Oban.Job{attempt: 10, max_attempts: 10}
      measurements = %{duration_ms: 18, queue_wait_ms: 6}
      metadata_keys = [:device_id, :attempt, :max_attempts, :reason]

      assert TopologyProjectionWorker.failure_log_level(job, @transient_abort_reason) == :warning

      warning_log =
        capture_log([level: :warning, metadata: metadata_keys], fn ->
          assert {:error, @transient_abort_reason} =
                   TopologyProjectionWorker.record_outcome(
                     {:error, @transient_abort_reason},
                     "sr:device-exhausted-10",
                     job,
                     measurements
                   )
        end)

      assert warning_log =~ "[warning]"
      assert warning_log =~ "Topology projection failed; the graph lags CNPG until it succeeds"
      assert warning_log =~ "device_id=sr:device-exhausted-10"
      assert warning_log =~ "attempt=10"
      assert warning_log =~ "max_attempts=10"
      assert warning_log =~ "Transaction Aborted"
    end

    test "non-transient error on attempt 1 of 10 logs at warning" do
      job = %Oban.Job{attempt: 1, max_attempts: 10}
      measurements = %{duration_ms: 9, queue_wait_ms: 2}
      metadata_keys = [:device_id, :attempt, :max_attempts, :reason]

      assert TopologyProjectionWorker.failure_log_level(job, @non_transient_reason) == :warning

      warning_log =
        capture_log([level: :warning, metadata: metadata_keys], fn ->
          assert {:error, @non_transient_reason} =
                   TopologyProjectionWorker.record_outcome(
                     {:error, @non_transient_reason},
                     "sr:device-non-transient-1",
                     job,
                     measurements
                   )
        end)

      assert warning_log =~ "[warning]"
      assert warning_log =~ "Topology projection failed; the graph lags CNPG until it succeeds"
      assert warning_log =~ "device_id=sr:device-non-transient-1"
      assert warning_log =~ "attempt=1"
      assert warning_log =~ "max_attempts=10"
      assert warning_log =~ "canonical page lacks a consistent transaction timestamp"
    end
  end
end
