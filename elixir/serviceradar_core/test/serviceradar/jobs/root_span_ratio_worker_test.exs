defmodule ServiceRadar.Jobs.RootSpanRatioWorkerTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Jobs.RootSpanRatioWorker

  @threshold 0.85
  @min_spans 1000

  describe "evaluate/4" do
    test "skips when total is below the floor" do
      assert RootSpanRatioWorker.evaluate(0, 0, @min_spans, @threshold) == :skip
      assert RootSpanRatioWorker.evaluate(999, 999, @min_spans, @threshold) == :skip
    end

    test "evaluates exactly at the floor" do
      assert {:ok, ratio} = RootSpanRatioWorker.evaluate(1000, 100, @min_spans, @threshold)
      assert_in_delta ratio, 0.1, 1.0e-9
    end

    test "healthy ratio below the threshold" do
      assert {:ok, ratio} = RootSpanRatioWorker.evaluate(10_000, 500, @min_spans, @threshold)
      assert_in_delta ratio, 0.05, 1.0e-9
    end

    test "ratio exactly at the threshold is not a breach (strictly greater)" do
      assert {:ok, ratio} = RootSpanRatioWorker.evaluate(10_000, 8_500, @min_spans, @threshold)
      assert_in_delta ratio, 0.85, 1.0e-9
    end

    test "ratio above the threshold breaches" do
      assert {:breach, ratio} =
               RootSpanRatioWorker.evaluate(10_000, 8_501, @min_spans, @threshold)

      assert_in_delta ratio, 0.8501, 1.0e-9
    end

    test "all-root pathology breaches" do
      assert {:breach, ratio} =
               RootSpanRatioWorker.evaluate(5_000, 5_000, @min_spans, @threshold)

      assert ratio == 1.0
    end

    test "zero roots is healthy" do
      assert {:ok, +0.0} = RootSpanRatioWorker.evaluate(5_000, 0, @min_spans, @threshold)
    end

    test "respects a custom floor and threshold" do
      assert RootSpanRatioWorker.evaluate(99, 99, 100, 0.5) == :skip
      assert {:breach, _} = RootSpanRatioWorker.evaluate(100, 51, 100, 0.5)
      assert {:ok, _} = RootSpanRatioWorker.evaluate(100, 50, 100, 0.5)
    end
  end
end
