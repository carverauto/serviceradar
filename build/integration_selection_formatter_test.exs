ExUnit.start()

formatter_path =
  Path.expand(
    "../elixir/serviceradar_core/test/support/integration_selection_formatter.ex",
    __DIR__
  )

if File.exists?(formatter_path), do: Code.require_file(formatter_path)

defmodule ServiceRadar.IntegrationSelectionFormatterTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.IntegrationSelectionFormatter

  @output_env "SERVICERADAR_INTEGRATION_SELECTION_OUTPUT"
  @moduletag :capture_log

  test "is available as an ExUnit formatter" do
    assert Code.ensure_loaded?(IntegrationSelectionFormatter)
    assert function_exported?(IntegrationSelectionFormatter, :start_link, 1)
  end

  setup do
    path =
      Path.join(
        System.tmp_dir!(),
        "integration-selection-#{System.unique_integer([:positive])}.txt"
      )

    previous = System.get_env(@output_env)
    previous_trap_exit = Process.flag(:trap_exit, true)
    System.put_env(@output_env, path)

    on_exit(fn ->
      restore_env(@output_env, previous)
      Process.flag(:trap_exit, previous_trap_exit)
      File.rm(path)
    end)

    {:ok, path: path}
  end

  test "writes selected normal and skipped tests in stable sorted order while omitting exclusions",
       %{
         path: path
       } do
    {:ok, formatter} = IntegrationSelectionFormatter.start_link([])
    Process.unlink(formatter)

    on_exit(fn ->
      refute Process.alive?(formatter)
    end)

    on_exit(fn ->
      if Process.alive?(formatter), do: GenServer.stop(formatter)
    end)

    emit(formatter, exunit_test(Selection.ZetaTest, :"normal zeta"))
    emit(formatter, exunit_test(Selection.AlphaTest, :"skipped alpha", {:skipped, :requested}))
    emit(formatter, exunit_test(Selection.FilteredTest, :excluded, {:excluded, :integration}))
    finish(formatter)

    assert await_file(path) ==
             "Selection.AlphaTest|skipped alpha\nSelection.ZetaTest|normal zeta\n"
  end

  test "rejects a duplicate selected identity", %{path: _path} do
    {:ok, formatter} = IntegrationSelectionFormatter.start_link([])
    monitor = Process.monitor(formatter)
    selected = exunit_test(Selection.DuplicateTest, :"same identity")

    emit(formatter, selected)
    emit(formatter, selected)
    finish(formatter)

    assert_receive {:DOWN, ^monitor, :process, ^formatter,
                    {%ArgumentError{message: message}, _stacktrace}}

    assert message =~ "duplicate selected test identity"
  end

  test "fails closed when no output destination is configured", %{path: _path} do
    System.delete_env(@output_env)

    assert {:error, {%ArgumentError{message: message}, _stacktrace}} =
             IntegrationSelectionFormatter.start_link([])

    assert message =~ @output_env
  end

  test "fails closed when the configured output destination is blank", %{path: _path} do
    System.put_env(@output_env, "   ")

    assert {:error, {%ArgumentError{message: message}, _stacktrace}} =
             IntegrationSelectionFormatter.start_link([])

    assert message =~ @output_env
  end

  test "rejects selected identities that cannot be represented unambiguously", %{path: _path} do
    {:ok, formatter} = IntegrationSelectionFormatter.start_link([])
    monitor = Process.monitor(formatter)

    emit(formatter, exunit_test(Selection.AmbiguousTest, :"contains|pipe"))
    finish(formatter)

    assert_receive {:DOWN, ^monitor, :process, ^formatter,
                    {%ArgumentError{message: message}, _stacktrace}}

    assert message =~ "ambiguous selected test identity"
  end

  defp emit(formatter, test), do: GenServer.cast(formatter, {:test_finished, test})
  defp finish(formatter), do: GenServer.cast(formatter, {:suite_finished, %{}})

  defp exunit_test(module, name, state \\ nil) do
    %ExUnit.Test{module: module, name: name, state: state}
  end

  defp await_file(path, attempts \\ 25)

  defp await_file(path, attempts) when attempts > 0 do
    case File.read(path) do
      {:ok, contents} ->
        contents

      {:error, :enoent} ->
        Process.sleep(10)
        await_file(path, attempts - 1)
    end
  end

  defp await_file(path, 0), do: File.read!(path)

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
