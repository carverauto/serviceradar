defmodule ServiceRadar.Inventory.AdvisoryFeeds.FeedWorkerTimeoutTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Inventory.AdvisoryFeeds.FeedWorker

  test "nist-nvd2 is allowed a 60-minute Oban timeout" do
    assert FeedWorker.timeout(%Oban.Job{args: %{"feed" => "nist-nvd2"}}) == 3_600_000
  end

  test "other feeds keep the 3-minute timeout" do
    assert FeedWorker.timeout(%Oban.Job{args: %{"feed" => "vulncheck-kev"}}) == 180_000
  end

  describe "backoff/1" do
    # The regression. On 2026-08-22 a brief VulnCheck timeout consumed all three
    # attempts of a nist-nvd2 run inside 65 seconds (03:08:28, 03:09:12,
    # 03:09:33) under Oban's default backoff, discarding the job and leaving the
    # feed idle until the next 6-hour tick. Every retry sampled the same
    # one-minute window of upstream health, which is the part that made it
    # useless.
    test "spreads retries across a window that can outlast an upstream blip" do
      total = Enum.sum(Enum.map(1..3, &FeedWorker.backoff(job(&1))))

      assert total > 30 * 60,
             "three retries inside #{total}s would sample one short window of upstream " <>
               "health, which is exactly how a transient failure killed the feed"
    end

    test "each attempt waits longer than the last" do
      delays = Enum.map(1..3, &FeedWorker.backoff(job(&1)))

      assert delays == Enum.sort(delays), "backoff must be monotonic, got #{inspect(delays)}"
      assert Enum.all?(delays, &(&1 >= 60)), "no retry should land inside a minute"
    end

    test "stays within one 6-hour refresh cycle" do
      # Worst case: every attempt burns the full nist-nvd2 timeout before failing.
      timeout_s = div(FeedWorker.timeout(%Oban.Job{args: %{"feed" => "nist-nvd2"}}), 1000)
      attempts = 4
      worst = attempts * timeout_s + Enum.sum(Enum.map(1..3, &FeedWorker.backoff(job(&1))))

      assert worst < 6 * 60 * 60,
             "a failing run must finish retrying before the next cycle is due, got #{worst}s"
    end

    test "jitter keeps each delay near its base without collapsing to a constant" do
      # Three feeds share one upstream; identical delays would retry in lockstep.
      samples = Enum.map(1..50, fn _ -> FeedWorker.backoff(job(1)) end)

      assert Enum.min(samples) >= 108 and Enum.max(samples) <= 132,
             "expected ~120s +/-10%, got #{Enum.min(samples)}..#{Enum.max(samples)}"

      assert Enum.uniq(samples) != [hd(samples)], "delays must be jittered, not constant"
    end

    test "attempts past the schedule clamp to the longest delay" do
      assert_in_delta FeedWorker.backoff(job(9)), FeedWorker.backoff(job(3)), 400
    end

    defp job(attempt), do: %Oban.Job{attempt: attempt, args: %{"feed" => "nist-nvd2"}}
  end
end
