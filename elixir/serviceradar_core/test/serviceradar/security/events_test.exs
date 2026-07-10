defmodule ServiceRadar.Security.EventsTest do
  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Repo
  alias ServiceRadar.Security.Events
  alias ServiceRadar.Security.SecurityEvent

  setup do
    # Keep the application-owned recorder inside this test's sandbox lifetime.
    _ = Events.flush()
    on_exit(fn -> Events.flush() end)
    :ok
  end

  describe "record/1" do
    test "returns immediately and flush is a persistence barrier" do
      correlation_id = "security-events-flush-#{System.unique_integer([:positive])}"

      assert :ok =
               Events.record(%{
                 kind: :rate_limit_denied,
                 correlation_id: correlation_id
               })

      assert :ok = Events.flush()

      assert %{rows: [[1]]} =
               Repo.query!(
                 "SELECT count(*) FROM platform.security_events WHERE correlation_id = $1",
                 [correlation_id]
               )
    end

    test "is non-blocking even when the recorder is busy" do
      for _ <- 1..50 do
        assert :ok = Events.record(%{kind: :rate_limit_denied, ip: "203.0.113.1"})
      end

      assert :ok = Events.flush()
    end
  end

  describe "overflow" do
    @tag :capture_log
    test "counts the in-flight batch against capacity and flush waits for it" do
      ref = make_ref()
      parent = self()

      :telemetry.attach(
        {__MODULE__, ref},
        [:serviceradar, :security, :events, :dropped],
        fn _event, measurements, _meta, _config ->
          send(parent, {ref, measurements})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach({__MODULE__, ref}) end)

      task_supervisor = start_supervised!(Task.Supervisor)

      persist_fun = fn batch ->
        send(parent, {:persist_started, self(), batch})

        receive do
          :finish_persistence -> :ok
        end
      end

      recorder =
        start_supervised!(
          {Events,
           name: nil,
           max_queue: 3,
           flush_interval: :infinity,
           persist_fun: persist_fun,
           task_supervisor: task_supervisor}
        )

      assert :ok = Events.record(%{kind: :rate_limit_denied}, recorder)
      assert :ok = Events.record(%{kind: :rate_limit_denied}, recorder)
      send(recorder, :flush)

      assert_receive {:persist_started, persistence_pid, batch}, 500
      assert length(batch) == 2

      assert :ok = Events.record(%{kind: :rate_limit_denied}, recorder)
      assert :ok = Events.record(%{kind: :rate_limit_denied}, recorder)
      assert_receive {^ref, %{count: 1}}, 500

      flush_task = Task.async(fn -> Events.flush(recorder) end)
      assert Task.yield(flush_task, 50) == nil
      refute_receive {:persist_started, _pid, _batch}, 50

      send(persistence_pid, :finish_persistence)

      assert_receive {:persist_started, persistence_pid, batch}, 500
      assert length(batch) == 1
      assert Task.yield(flush_task, 50) == nil

      send(persistence_pid, :finish_persistence)
      assert Task.await(flush_task, 500) == :ok
    end

    @tag :capture_log
    test "reports an abnormally terminated persistence batch as dropped" do
      ref = make_ref()
      parent = self()

      :telemetry.attach(
        {__MODULE__, ref},
        [:serviceradar, :security, :events, :dropped],
        fn _event, measurements, metadata, _config ->
          send(parent, {ref, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach({__MODULE__, ref}) end)

      task_supervisor = start_supervised!(Task.Supervisor)

      recorder =
        start_supervised!(
          {Events,
           name: nil,
           max_queue: 2,
           flush_interval: :infinity,
           persist_fun: fn _batch -> exit(:persistence_failed) end,
           task_supervisor: task_supervisor}
        )

      assert :ok = Events.record(%{kind: :rate_limit_denied}, recorder)
      assert :ok = Events.record(%{kind: :rate_limit_denied}, recorder)
      assert :ok = Events.flush(recorder)

      assert_receive {
        ^ref,
        %{count: 2},
        %{reason: :persistence_failed, source: :persistence_task}
      }
    end
  end

  describe "kinds/0 and severities/0" do
    test "expose the supported kinds and severities for callers/UI" do
      kinds = SecurityEvent.kinds()
      severities = SecurityEvent.severities()

      assert :rate_limit_denied in kinds
      assert :csp_violation in kinds
      assert :policy_denied in kinds
      assert :lockout_triggered in kinds
      assert severities == [:info, :warning, :critical]
    end
  end
end
