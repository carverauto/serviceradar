defmodule ServiceRadarWebNG.ApiTokenUsageTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ServiceRadarWebNG.ApiTokenUsage

  setup do
    # Under `mix test` the application runs its own recorder under this name.
    if Process.whereis(ApiTokenUsage) do
      :ok = Supervisor.terminate_child(ServiceRadarWebNG.Supervisor, ApiTokenUsage)
      on_exit(fn -> Supervisor.restart_child(ServiceRadarWebNG.Supervisor, ApiTokenUsage) end)
    end

    task_supervisor = start_supervised!(Task.Supervisor)
    %{task_supervisor: task_supervisor}
  end

  test "a burst of uses of one token becomes one write carrying the count and latest IP", ctx do
    start_recorder!(ctx, recording_writer())
    token = token("burst")

    for n <- 1..25, do: :ok = ApiTokenUsage.record(token, "192.0.2.#{n}")
    :ok = ApiTokenUsage.flush()

    assert_received {:usage_written, "burst", "192.0.2.25", 25}
    refute_received {:usage_written, _, _, _}
  end

  test "each token is written once per flush and only when it was used", ctx do
    start_recorder!(ctx, recording_writer())

    :ok = ApiTokenUsage.record(token("first"), "192.0.2.1")
    :ok = ApiTokenUsage.record(token("second"), "198.51.100.1")
    :ok = ApiTokenUsage.record(token("first"), "192.0.2.2")
    :ok = ApiTokenUsage.flush()

    assert_received {:usage_written, "first", "192.0.2.2", 2}
    assert_received {:usage_written, "second", "198.51.100.1", 1}

    :ok = ApiTokenUsage.flush()
    refute_received {:usage_written, _, _, _}
  end

  test "a failed or hung write is logged and recording keeps working", ctx do
    test_pid = self()

    writer = fn
      %{id: "hangs"}, _ip, _uses ->
        Process.sleep(:infinity)

      %{id: "fails"}, _ip, _uses ->
        {:error, :synthetic_failure}

      %{id: id}, ip, uses ->
        send(test_pid, {:usage_written, id, ip, uses})
        :ok
    end

    start_recorder!(ctx, writer, write_timeout_ms: 100)

    :ok = ApiTokenUsage.record(token("fails"), "192.0.2.1")
    :ok = ApiTokenUsage.record(token("hangs"), "192.0.2.2")

    log = capture_log(fn -> :ok = ApiTokenUsage.flush() end)
    assert log =~ "synthetic_failure"
    assert log =~ "hangs"

    :ok = ApiTokenUsage.record(token("works"), "192.0.2.3")
    :ok = ApiTokenUsage.flush()
    assert_received {:usage_written, "works", "192.0.2.3", 1}
  end

  test "usage recorded before shutdown is written on the way down", ctx do
    start_recorder!(ctx, recording_writer())
    :ok = ApiTokenUsage.record(token("shutdown"), "192.0.2.9")

    :ok = stop_supervised(ApiTokenUsage)

    assert_received {:usage_written, "shutdown", "192.0.2.9", 1}
  end

  test "without the recorder, recording is a no-op" do
    assert ApiTokenUsage.record(token("absent"), "192.0.2.1") == :unavailable
  end

  defp start_recorder!(ctx, writer, opts \\ []) do
    start_supervised!(
      {ApiTokenUsage,
       Keyword.merge(
         [writer: writer, task_supervisor: ctx.task_supervisor, flush_interval_ms: to_timeout(hour: 1)],
         opts
       )}
    )
  end

  defp recording_writer do
    test_pid = self()

    fn %{id: id}, ip, uses ->
      send(test_pid, {:usage_written, id, ip, uses})
      :ok
    end
  end

  defp token(id), do: %{id: id, name: "synthetic-#{id}"}
end
