defmodule ServiceRadar.ExUnitInterruptionGuardTest do
  @moduledoc """
  Guards the test-runner behavior that an ExUnit process interrupted by SIGTERM
  before it completes must exit nonzero.

  The guard lives in test/test_helper.exs: the BEAM's default SIGTERM handler
  shuts down gracefully and exits 0, so the Bazel wrapper would otherwise record
  PASSED on a run that never printed a suite summary. System.at_exit hooks do not
  run for a signal, so the runner traps SIGTERM and halts nonzero instead.

  These tests exercise an actual child ExUnit process through that helper and
  assert the observable exit code, so a regression in the guard fails here
  rather than silently accepting an interrupted run.
  """

  use ExUnit.Case, async: false

  @child_timeout 60_000
  @ready_marker "INTERRUPT_TEST_READY"

  test "a SIGTERM-interrupted run exits nonzero" do
    {status, output} = run_interrupted_child()

    assert status != 0, "interrupted run exited #{status}, expected nonzero:\n#{output}"
  end

  test "a passing suite exits zero" do
    {status, output} = run_child(passing_suite_code())

    assert status == 0, "passing suite exited #{status}, expected 0:\n#{output}"
  end

  test "a failing suite exits nonzero" do
    {status, output} = run_child(failing_suite_code())

    assert status != 0, "failing suite exited #{status}, expected nonzero:\n#{output}"
  end

  # Spawns a child BEAM that runs the given suite through test/test_helper.exs,
  # then SIGTERMs it once the slow test announces it has started.
  defp run_interrupted_child do
    {port, _} = open_child(interrupted_suite_code())
    output = await_marker(port, @ready_marker)
    {:os_pid, pid} = Port.info(port, :os_pid)

    System.cmd("kill", ["-TERM", Integer.to_string(pid)])

    collect(port, output)
  end

  defp run_child(code) do
    {port, _} = open_child(code)
    collect(port, "")
  end

  defp open_child(code) do
    elixir = System.find_executable("elixir") || flunk("elixir executable not found on PATH")

    # Same pattern as the bootstrap subprocess: hand the parent's code path to a
    # plain `elixir` child so the helper and its dependencies resolve under both
    # `mix test` and the Bazel sandbox.
    code_paths = Enum.flat_map(:code.get_path(), &["-pa", List.to_string(&1)])

    port =
      Port.open({:spawn_executable, elixir}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: code_paths ++ ["-r", "test/test_helper.exs", "-e", code],
        env: blank_database_env(),
        cd: File.cwd!()
      ])

    {port, ""}
  end

  defp await_marker(port, marker), do: await_marker(port, marker, "")

  defp await_marker(port, marker, acc) do
    receive do
      {^port, {:data, data}} ->
        acc = acc <> data

        if String.contains?(acc, marker) do
          acc
        else
          await_marker(port, marker, acc)
        end

      {^port, {:exit_status, status}} ->
        flunk("child exited #{status} before emitting #{inspect(marker)}:\n#{acc}")
    after
      @child_timeout -> flunk("timed out waiting for #{inspect(marker)}:\n#{acc}")
    end
  end

  defp collect(port, acc) do
    receive do
      {^port, {:data, data}} -> collect(port, acc <> data)
      {^port, {:exit_status, status}} -> {status, acc}
    after
      @child_timeout -> flunk("child did not exit within #{@child_timeout}ms:\n#{acc}")
    end
  end

  # A blank value counts as absent in test/test_helper.exs (see database_available?/0
  # there), so the child always takes the database-free unit branch regardless of
  # what the parent's environment holds. Port.open's :env option takes charlists.
  defp blank_database_env do
    Enum.map(
      ~w(
      SRQL_TEST_DATABASE_URL
      SERVICERADAR_TEST_DATABASE_URL
      SRQL_TEST_DATABASE_URL_FILE
      SERVICERADAR_TEST_DATABASE_URL_FILE
    ),
      &{String.to_charlist(&1), ~c""}
    )
  end

  defp interrupted_suite_code do
    """
    defmodule ExUnitInterruptionGuardSlowTest do
      use ExUnit.Case

      test "interrupted before completion" do
        IO.puts(#{inspect(@ready_marker)})
        Process.sleep(60_000)
      end
    end
    """
  end

  defp passing_suite_code do
    ~S'''
    defmodule ExUnitInterruptionGuardPassingTest do
      use ExUnit.Case

      test "passes" do
        assert 1 + 1 == 2
      end
    end
    '''
  end

  defp failing_suite_code do
    ~S'''
    defmodule ExUnitInterruptionGuardFailingTest do
      use ExUnit.Case

      test "fails" do
        assert false
      end
    end
    '''
  end
end
