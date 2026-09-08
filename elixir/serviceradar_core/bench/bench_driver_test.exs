defmodule ServiceRadar.Bench.BenchDriverTest do
  @moduledoc """
  Runs the Elixir benches so they cannot rot (#3855).

  These are plain scripts that self-execute on load: nothing ran them, so like the Go benchmarks
  they compiled review and then went stale. This drives them the way the Go runner drives a test
  binary's benchmarks -- it asserts they still EXECUTE, and asserts nothing about their numbers.

  ## Which benches run here, and which cannot

    * `event_writer_pull_buffering` -- self-contained, no database or broker. Runs.
    * `metric_fixture_profile` -- needs a MetricBatch corpus, generated here rather than
      committed. Runs.
    * `metric_fixture_cnpg_insert` -- NOT here. It uses `Repo` and `BulkInsert`, so it needs a
      live database and belongs in the integration tier behind the CNPG fixture lifecycle, not
      in a unit-speed benchmark sweep. Fixtures alone do not make it runnable, which is why the
      generator above does not close it.

  ## Sized down, deliberately

  Both benches take their workload from the environment, and this driver sets it small: the
  point is that they still run, not that a number is stable enough to compare. The defaults
  (100,000 messages for the buffering bench) would make the sweep the reason nobody runs it.
  """
  # NOT tagged :benchmark at the ExUnit level. The Bazel target carries that tag for CI
  # selection; repeating it here would mean a helper that excludes :benchmark -- which
  # test/test_helper.exs does in every branch -- silently skips these and reports green.
  use ExUnit.Case, async: false

  @bench_dir Path.expand("..", __DIR__) |> Path.join("bench")

  setup do
    # Each bench reads its configuration from the environment and self-executes on require, so
    # the variables are set before the load and cleared afterwards -- a leaked value would
    # silently change the next bench's workload.
    on_exit(fn ->
      for key <- [
            "METRIC_FIXTURE_PROFILE_DIR",
            "EVENT_WRITER_BUFFER_BENCH_MESSAGES",
            "EVENT_WRITER_BUFFER_BENCH_PAYLOAD_BYTES"
          ] do
        System.delete_env(key)
      end
    end)

    :ok
  end

  test "the event-writer pull buffering bench still runs" do
    System.put_env("EVENT_WRITER_BUFFER_BENCH_MESSAGES", "2000")
    System.put_env("EVENT_WRITER_BUFFER_BENCH_PAYLOAD_BYTES", "256")

    output = capture_bench("event_writer_pull_buffering.exs")

    # Asserts on a RESULT line, not the header. The bench prints its parameters before doing any
    # work, so matching the header would pass on a bench that printed its banner and then
    # measured nothing.
    assert output =~ "messages_per_second=",
           "the bench printed no results, so it did not finish its measured section"
  end

  test "the metric fixture profile bench still runs, over a generated corpus" do
    Code.require_file(Path.join(@bench_dir, "metric_fixture_generator.exs"))

    unique = System.unique_integer([:positive])
    dir = Path.join(System.tmp_dir!(), "serviceradar-bench-metric-fixtures-#{unique}")
    on_exit(fn -> File.rm_rf(dir) end)

    paths = ServiceRadar.Bench.MetricFixtureGenerator.write!(dir)

    # NOT VACUOUS. If the generator wrote nothing, the bench would read an empty directory,
    # report zeroes, and pass -- measuring nothing while looking healthy.
    assert length(paths) > 0, "the generator produced no fixtures"

    System.put_env("METRIC_FIXTURE_PROFILE_DIR", dir)

    output = capture_bench("metric_fixture_profile.exs")

    # Asserts the bench CONSUMED the corpus, not merely that it printed a report. Matching
    # `fixture_dir=` alone would pass on a bench pointed at an EMPTY directory: it would report
    # zeroes and exit 0, measuring nothing while looking healthy. Tying the count back to what
    # the generator wrote is what makes the two halves agree.
    assert output =~ "files=#{length(paths)}",
           "the bench did not report reading #{length(paths)} fixtures, so it did not process " <>
             "the generated corpus:\n#{output}"

    # A corpus that decoded to no points would produce per-point averages of zero and still
    # print a well-formed report.
    assert decoded_points(output) > 0,
           "the bench decoded zero metric points, so the fixtures carried no payload:\n#{output}"
  end

  # Returns 0 when the line is absent, so a bench that never printed it fails the assertion
  # rather than crashing on a nil match.
  defp decoded_points(output) do
    case Regex.run(~r/^metric_points=(\d+)$/m, output) do
      [_, count] -> String.to_integer(count)
      nil -> 0
    end
  end

  # The scripts end in a bare call, so requiring the file runs the bench. Compiled fresh each
  # time because Code.require_file/1 is a no-op for a path already loaded, and a second bench in
  # the same VM would then silently not run.
  defp capture_bench(script) do
    path = Path.join(@bench_dir, script)
    Code.unrequire_files([path])

    ExUnit.CaptureIO.capture_io(fn -> Code.require_file(path) end)
  end
end
