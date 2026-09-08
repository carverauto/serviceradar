defmodule ServiceRadarWebNGWeb.DeviceLive.DeviceTaskDataTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNGWeb.DeviceLive.DeviceTaskData

  @moduletag :db_free

  describe "run/3 crash containment" do
    test "a raising task does not kill the caller and is omitted from the results" do
      specs = [
        DeviceTaskData.spec(10_000, :ok_one, fn -> :first end),
        DeviceTaskData.spec(10_000, :boom, fn -> raise "pool exhausted" end),
        DeviceTaskData.spec(10_000, :ok_two, fn -> :second end)
      ]

      results = DeviceTaskData.run(specs, 5_000)

      assert results == %{ok_one: :first, ok_two: :second}
    end

    test "a task that exits does not kill the caller" do
      specs = [
        DeviceTaskData.spec(10_000, :ok, fn -> :fine end),
        DeviceTaskData.spec(10_000, :gone, fn -> exit(:boom) end)
      ]

      results = DeviceTaskData.run(specs, 5_000)

      assert results == %{ok: :fine}
    end

    test "a nested Task.async child crash is contained (the production shape)" do
      # FlowData.load_device_flow_summary/3 spawns Task.async INSIDE a task.
      # A grandchild crash must not propagate past the fan-out boundary.
      specs = [
        DeviceTaskData.spec(10_000, :ok, fn -> :fine end),
        DeviceTaskData.spec(10_000, :nested, fn ->
          # The window only has to outlast a scheduling stall, never a healthy
          # run: the grandchild's crash normally kills this task through
          # Task.async's link in microseconds, so yield_many never waits. At
          # 1_000 a stalled VM could leave the grandchild unscheduled for the
          # whole window; yield_many then returned [{task, nil}], :nested
          # completed NORMALLY, and the assertion below saw
          # %{ok: :fine, nested: [{%Task{}, nil}]}. Kept under run/3's 5_000ms
          # batch budget so the test still cannot hang.
          Task.yield_many([Task.async(fn -> raise "grandchild" end)], 4_000)
        end)
      ]

      results = DeviceTaskData.run(specs, 5_000)

      assert results == %{ok: :fine}
    end

    test "caller survives when every task crashes" do
      specs =
        for i <- 1..5 do
          DeviceTaskData.spec(10_000, :"t#{i}", fn -> raise "boom #{i}" end)
        end

      assert DeviceTaskData.run(specs, 5_000) == %{}
      assert Process.alive?(self())
    end
  end

  describe "run/3 bounded concurrency" do
    test "never runs more than max_concurrency tasks at once" do
      parent = self()
      max = 3

      specs =
        for i <- 1..12 do
          DeviceTaskData.spec(10_000, :"t#{i}", fn ->
            send(parent, {:start, i})
            Process.sleep(30)
            send(parent, {:stop, i})
            i
          end)
        end

      results = DeviceTaskData.run(specs, 10_000, max_concurrency: max)

      assert map_size(results) == 12
      assert peak_concurrency(24) <= max
    end
  end

  describe "run/3 batch deadline" do
    test "stops collecting once the batch budget is spent instead of per-task" do
      # Six 300ms tasks, one at a time, on a 500ms batch budget. The old
      # Task.yield_many/2 call enforced a whole-batch deadline; async_stream's
      # :timeout is per element, so without an explicit halt this would run the
      # full ~1800ms and blow every caller's supplemental timeout.
      specs =
        for i <- 1..6 do
          DeviceTaskData.spec(10_000, :"slow#{i}", fn ->
            Process.sleep(300)
            i
          end)
        end

      {elapsed_us, results} =
        :timer.tc(fn -> DeviceTaskData.run(specs, 500, max_concurrency: 1) end)

      elapsed_ms = div(elapsed_us, 1000)

      assert map_size(results) < 6, "expected the batch to be cut short, got #{map_size(results)}"
      assert elapsed_ms < 1_500, "batch ran #{elapsed_ms}ms, deadline was not enforced"
    end
  end

  defp peak_concurrency(events_expected) do
    1..events_expected
    |> Enum.reduce({0, 0}, fn _, {current, peak} ->
      receive do
        {:start, _} -> {current + 1, max(peak, current + 1)}
        {:stop, _} -> {current - 1, peak}
      after
        5_000 -> {current, peak}
      end
    end)
    |> elem(1)
  end
end
