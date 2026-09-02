defmodule ServiceRadar.Security.EventsTest do
  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Repo
  alias ServiceRadar.Security.Events
  alias ServiceRadar.Security.SecurityEvent

  setup do
    task_supervisor =
      start_supervised!(
        Supervisor.child_spec(Task.Supervisor,
          id: {:security_events_task_supervisor, make_ref()}
        )
      )

    recorder = start_recorder(task_supervisor)
    {:ok, recorder: recorder, task_supervisor: task_supervisor}
  end

  describe "record/1" do
    test "returns immediately and flush is a persistence barrier", %{recorder: recorder} do
      correlation_id = "security-events-flush-#{System.unique_integer([:positive])}"

      assert :ok =
               Events.record(
                 %{
                   kind: :rate_limit_denied,
                   correlation_id: correlation_id
                 },
                 recorder
               )

      assert :ok = Events.flush(recorder)

      assert %{rows: [[1]]} =
               Repo.query!(
                 "SELECT count(*) FROM platform.security_events WHERE correlation_id = $1",
                 [correlation_id]
               )
    end

    test "is non-blocking even when the recorder is busy", %{recorder: recorder} do
      for _ <- 1..50 do
        assert :ok =
                 Events.record(
                   %{kind: :rate_limit_denied, ip: "203.0.113.1"},
                   recorder
                 )
      end

      assert :ok = Events.flush(recorder)
    end
  end

  describe "overflow" do
    @tag :capture_log
    test "counts the in-flight batch against capacity and flush waits for it", %{
      task_supervisor: task_supervisor
    } do
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

      persist_fun = fn batch ->
        send(parent, {:persist_started, self(), batch})

        receive do
          :finish_persistence -> :ok
        end
      end

      recorder =
        start_recorder(task_supervisor,
          max_queue: 3,
          persist_fun: persist_fun
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
    test "reports an abnormally terminated persistence batch as dropped", %{
      task_supervisor: task_supervisor
    } do
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

      recorder =
        start_recorder(
          task_supervisor,
          max_queue: 2,
          persist_fun: fn _batch -> exit(:persistence_failed) end
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
      assert :mcp_auth_failed in kinds
      assert :mcp_session_initialized in kinds
      assert :mcp_tool_called in kinds
      assert :mcp_tool_denied in kinds
      assert severities == [:info, :warning, :critical]
    end
  end

  defp start_recorder(task_supervisor, opts \\ []) do
    opts =
      Keyword.merge(
        [name: nil, flush_interval: :infinity, task_supervisor: task_supervisor],
        opts
      )

    {Events, opts}
    |> Supervisor.child_spec(id: {:security_events_recorder, make_ref()})
    |> start_supervised!()
  end
end
